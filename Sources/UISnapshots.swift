import AppKit
import ScreenCaptureKit

/// A development check for the interface: `Glance --ui-snapshots <folder>` shows each settings page and
/// the demo panel in light and dark appearance, in front of a plain backdrop, and saves pictures of them.
/// The capture includes only 一瞥's own windows; nothing else on the screen is recorded. Without Screen Recording,
/// as on a build machine, each window draws itself into its picture instead: `scripts/ui-snapshots-check.sh`.
extension AppDelegate {
    private struct SnapshotStep {
        var name: String?
        var prepare: () -> NSWindow?
    }

    func runUISnapshots() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--ui-snapshots"), index + 1 < arguments.count else { return }
        let folder = URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let backdrop = Self.makeSnapshotBackdrop()
        var steps: [SnapshotStep] = []
        for (dark, suffix) in [(false, "light"), (true, "dark")] {
            steps.append(SnapshotStep(name: nil) { [unowned self] in
                self.dismiss()
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                self.panel.appearance = nil; self.settingsWindow?.appearance = nil; self.previewPanel?.appearance = nil
                Self.saveAppIcon(to: folder.appendingPathComponent("icon-\(suffix).png"))
                return nil
            })
            for section in SettingsSection.allCases {
                steps.append(SnapshotStep(name: "settings-\(section.rawValue)-\(suffix)") { [unowned self] in
                    if self.settingsWindow?.isVisible != true { self.openSettings() }
                    // Keep the window active, so the pictures show its active state.
                    self.settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                    self.settingsWindow?.appearance = nil
                    self.settingsModel?.search = ""; self.settingsModel?.searchTarget = ""
                    self.settingsModel?.selectedTab = section.rawValue
                    return self.settingsWindow
                })
            }
            for style in SwitcherStyle.allCases {
                steps.append(SnapshotStep(name: "panel-\(style.rawValue)-\(suffix)") { [unowned self] in
                    if !self.showing || !self.state.isDemo { self.showDemo() }
                    self.panel.appearance = nil
                    self.state.searchVisible = false; self.state.style = style; self.relayout()
                    return self.panel
                })
            }
            steps.append(SnapshotStep(name: "search-\(suffix)") { [unowned self] in
                self.state.style = .thumbnails
                self.beginSearch()
                self.state.query = "fangda"
                self.relayout()
                return self.panel
            })
            // Opening an app that is not running from the search, with this Mac's real app list.
            steps.append(SnapshotStep(name: "search-launch-\(suffix)") { [unowned self] in
                self.state.extraItems = self.launcher.results(apps: true, settingsPages: true)
                self.state.query = "lanya"
                self.state.refilter(reset: true)
                self.relayout()
                return self.panel
            })
        }
        let canCapture = CGPreflightScreenCaptureAccess()
        var written: [String] = [], missing: [String] = [], drawn = 0
        func run(_ position: Int) {
            guard position < steps.count else {
                dismiss(); settingsWindow?.orderOut(nil); backdrop.orderOut(nil)
                state.query = ""; state.searchVisible = false
                NSApp.appearance = nil
                applySettings()
                var report = written
                if drawn > 0 {
                    report.append("drawn without Screen Recording: \(drawn) of \(written.count). These show each window's own drawing, without glass, shadow or backdrop.")
                }
                report += missing.map { "missing: \($0)" }
                try? (report.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
                return
            }
            let step = steps[position]
            let target = step.prepare()
            guard let name = step.name else { run(position + 1); return }
            guard let target else { missing.append(name + ".png"); run(position + 1); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self else { return }
                let area = target.frame.insetBy(dx: -40, dy: -40)
                backdrop.setFrame(area, display: true)
                backdrop.level = target.level
                backdrop.order(.below, relativeTo: target.windowNumber)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    let url = folder.appendingPathComponent(name + ".png")
                    let finish: (Bool) -> Void = { captured in
                        if captured { written.append(url.lastPathComponent) }
                        else if Self.drawWindow(target, to: url) { written.append(url.lastPathComponent); drawn += 1 }
                        else { missing.append(url.lastPathComponent) }
                        run(position + 1)
                    }
                    if canCapture { self.captureOwnWindows([backdrop, target], area: area, to: url, completion: finish) } else { finish(false) }
                }
            }
        }
        run(0)
    }

    /// The window as it draws itself, frame and contents, on the window's own background colour. It stands in for a
    /// capture of the screen where there is no permission to make one.
    private static func drawWindow(_ window: NSWindow, to url: URL) -> Bool {
        guard let view = window.contentView?.superview ?? window.contentView else { return false }
        let bounds = view.bounds
        guard bounds.width >= 1, bounds.height >= 1, let cached = view.bitmapImageRepForCachingDisplay(in: bounds) else { return false }
        view.cacheDisplay(in: bounds, to: cached)
        guard let flat = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cached.pixelsWide, pixelsHigh: cached.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
                                          hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        // In points before the context is made, so that drawing in points fills every pixel.
        flat.size = bounds.size
        let area = NSRect(origin: .zero, size: bounds.size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: flat)
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(rect: area).fill()
        }
        _ = cached.draw(in: area)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = flat.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    /// The app icon as Finder shows it, at 512 pixels, in the current appearance.
    private static func saveAppIcon(to url: URL) {
        let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 512, bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            icon.draw(in: NSRect(x: 0, y: 0, width: 512, height: 512))
        }
        NSGraphicsContext.restoreGraphicsState()
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// A soft, colourful stand-in for a desktop, so the glass has something to show through.
    private static func makeSnapshotBackdrop() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = true; window.hasShadow = false; window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let image = NSImage(size: NSSize(width: 1600, height: 1000), flipped: false) { rect in
            NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.38, blue: 0.78, alpha: 1), NSColor(srgbRed: 0.55, green: 0.33, blue: 0.75, alpha: 1),
                                NSColor(srgbRed: 0.95, green: 0.55, blue: 0.35, alpha: 1)])?.draw(in: rect, angle: -35)
            for (index, color) in [NSColor.white, .systemTeal, .systemYellow, .white].enumerated() {
                color.withAlphaComponent(0.35).setFill()
                NSBezierPath(ovalIn: NSRect(x: 120 + index * 360, y: 140 + (index % 2) * 420, width: 420, height: 420)).fill()
            }
            NSColor.black.withAlphaComponent(0.55).setFill()
            for row in 0..<12 {
                NSBezierPath(roundedRect: NSRect(x: 80, y: 60 + row * 76, width: 300 + (row % 4) * 220, height: 18), xRadius: 9, yRadius: 9).fill()
            }
            return true
        }
        let view = NSImageView(image: image)
        view.imageScaling = .scaleAxesIndependently
        window.contentView = view
        return window
    }

    /// Captures the given windows of this app, and nothing else, within an area of the screen.
    /// With `includeDock`, the Dock's own windows are included too (for checking the Dock preview against the Dock).
    func captureOwnWindows(_ windows: [NSWindow], area: NSRect, to url: URL, includeDock: Bool = false, completion: @escaping (Bool) -> Void) {
        let screen = windows.last?.screen ?? NSScreen.main
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
            let ids = Set(windows.map { CGWindowID($0.windowNumber) })
            guard let content, let screen,
                  let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else {
                DispatchQueue.main.async { completion(false) }; return
            }
            let own = content.windows.filter {
                (ids.contains($0.windowID) && $0.owningApplication?.processID == getpid())
                    || (includeDock && $0.owningApplication?.bundleIdentifier == "com.apple.dock" && $0.windowLayer == 20)
            }
            let filter = SCContentFilter(display: display, including: own)
            let configuration = SCStreamConfiguration()
            let local = CGRect(x: area.minX - screen.frame.minX, y: screen.frame.maxY - area.maxY, width: area.width, height: area.height)
            configuration.sourceRect = local
            configuration.width = Int(local.width * screen.backingScaleFactor)
            configuration.height = Int(local.height * screen.backingScaleFactor)
            configuration.showsCursor = false
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, _ in
                var saved = false
                if let image, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                    saved = (try? data.write(to: url)) != nil
                }
                DispatchQueue.main.async { completion(saved) }
            }
        }
    }
}
