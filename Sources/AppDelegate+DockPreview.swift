import AppKit
import SwiftUI
import ApplicationServices

/// Wires the Dock preview to the window list, and the development checks for it and for the launcher.
extension AppDelegate {
    func setupDockPreview() {
        dockPreview.install { [unowned self] state in
            let hosting: NSHostingView<AnyView> = FirstClickHostingView(rootView: AnyView(DockPreviewView(state: state).frame(maxWidth: .infinity, maxHeight: .infinity)))
            return self.materialView(hosting, frame: NSRect(x: 0, y: 0, width: 400, height: 220))
        }
        dockPreview.windows = { [weak self] pids in self?.engine.cachedSnapshot().filter { pids.contains($0.descriptor.pid) } ?? [] }
        dockPreview.refreshWindows = { [weak self] done in
            guard let self else { return }
            self.engine.refresh(frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier) { _ in done() }
        }
        dockPreview.cachedImage = { [weak self] id in self?.state.images[id] }
        dockPreview.storeImage = { [weak self] id, image in self?.state.storePreview(id, image: image) }
        dockPreview.isBlocked = { [weak self] in self?.showing ?? false }
        dockPreview.onFocus = { [weak self] handle in self?.focusFromDock(handle) }
        dockPreview.perform = { action, handle, done in WindowControl.performInBackground(action, on: handle, completion: done) }
        if let path = Self.argument(after: "--dock-preview-log") {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            try? Data().write(to: url)
            dockPreview.log = { line in Self.append(line, to: url) }
        }
    }

    func focusFromDock(_ handle: WindowHandle) {
        WindowControl.performInBackground(.focus, on: handle) { [weak self] error in
            guard let self else { return }
            if let error {
                NSSound.beep()
                self.dockPreview.log?("focus failed: \(error)")
                return
            }
            self.engine.markFocused(handle)
        }
    }

    static func argument(after flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else { return nil }
        return arguments[index + 1]
    }

    private static func append(_ line: String, to url: URL) {
        let stamp = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
        guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else { try? data.write(to: url) }
    }

    // MARK: Development checks

    /// `Glance --dock-preview-selftest <folder> [--dock-preview-app <bundle id>]`: moves the pointer onto an
    /// app's Dock icon, onto the preview and away again, and writes what happened plus two pictures of the
    /// preview (this app's own window only) to the folder. The pointer goes back where it was.
    func runDockPreviewSelfTest() {
        guard let folderPath = Self.argument(after: "--dock-preview-selftest") else { return }
        let folder = URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var report: [String: Any] = ["accessibility": AXIsProcessTrusted(), "screenCapture": CGPreflightScreenCaptureAccess(),
                                     "enabled": settings.value.dockPreview.enabled, "delay": settings.value.dockPreview.delay]
        var lines: [String] = []
        let previousLog = dockPreview.log
        dockPreview.log = { line in lines.append(line); previousLog?(line) }
        func finish() {
            report["log"] = lines
            dockPreview.log = previousLog
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: folder.appendingPathComponent("dock-preview-report.json"))
            }
        }
        dockPreview.ensureAttached()
        report["attached"] = dockPreview.attached
        guard dockPreview.attached else { report["error"] = "not attached to the Dock"; finish(); return }
        engine.refresh(frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier) { [weak self] handles in
            guard let self else { return }
            let withWindows = Set(handles.filter { !$0.descriptor.windowless && $0.descriptor.windowID != nil }.map(\.descriptor.bundleID))
            var preferred = [Self.argument(after: "--dock-preview-app"), "com.apple.finder"].compactMap { $0 }
            preferred += handles.map(\.descriptor.bundleID)
            guard let found = preferred.lazy.filter({ withWindows.contains($0) })
                    .compactMap({ id in self.dockPreview.dockIconFrame(bundleID: id).map { (id, $0) } }).first else {
                report["error"] = "no app with windows has a Dock icon"; finish(); return
            }
            let (bundleID, icon) = found
            report["app"] = bundleID
            report["iconFrame"] = NSStringFromRect(icon)
            let original = CGEvent(source: nil)?.location ?? .zero
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            func cg(_ point: NSPoint) -> CGPoint { CGPoint(x: point.x, y: primaryHeight - point.y) }
            var current = original
            func glide(to target: CGPoint, then next: @escaping () -> Void) {
                let start = current, steps = 10
                for step in 1...steps {
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(18 * step)) {
                        let t = CGFloat(step) / CGFloat(steps)
                        let point = CGPoint(x: start.x + (target.x - start.x) * t, y: start.y + (target.y - start.y) * t)
                        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                        if step == steps { current = target; next() }
                    }
                }
            }
            let wait = Double(self.settings.value.dockPreview.delay) / 1000 + 0.9
            let iconPoint = cg(NSPoint(x: icon.midX, y: icon.midY))
            let screenFrame = (NSScreen.screens.first { $0.frame.intersects(icon) } ?? NSScreen.main)?.frame ?? .zero
            let away = cg(NSPoint(x: screenFrame.midX, y: screenFrame.midY))
            func after(_ seconds: Double, _ body: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: body) }
            func snapshot(_ name: String, _ next: @escaping (Bool) -> Void) {
                guard let frame = self.dockPreview.panelFrame, let window = self.dockPreview.panelWindow else { next(false); return }
                self.captureOwnWindows([window], area: frame.insetBy(dx: -24, dy: -24), to: folder.appendingPathComponent(name), completion: next)
            }
            func fail(_ message: String) { report["error"] = message; glide(to: original) { finish() } }
            // With magnification on, icons move as the pointer nears the Dock: aim again at where the icon is now.
            func reachIcon(_ tries: Int = 3, then next: @escaping () -> Void) {
                glide(to: self.dockPreview.dockIconFrame(bundleID: bundleID).map { cg(NSPoint(x: $0.midX, y: $0.midY)) } ?? iconPoint) {
                    after(0.15) {
                        let now = self.dockPreview.dockIconFrame(bundleID: bundleID) ?? icon
                        if tries > 1, !now.insetBy(dx: 4, dy: 4).contains(NSEvent.mouseLocation) { reachIcon(tries - 1, then: next) } else { next() }
                    }
                }
            }
            // 1. Onto the icon: the preview opens after the delay.
            reachIcon {
                after(wait) {
                    report["shownOnIcon"] = self.dockPreview.isVisible
                    guard let frame = self.dockPreview.panelFrame else { fail("preview did not open"); return }
                    report["panelFrame"] = NSStringFromRect(frame)
                    report["panelLevel"] = self.dockPreview.panelWindow?.level.rawValue ?? 0
                    report["dockWindows"] = self.dockPreview.dockWindowsDescription()
                    snapshot("dock-preview.png") { saved in
                        report["snapshot"] = saved
                        // The preview together with the Dock beneath it, to see the Dock's own name label.
                        if let window = self.dockPreview.panelWindow {
                            let area = frame.union(icon).insetBy(dx: -30, dy: -10)
                            self.captureOwnWindows([window], area: area, to: folder.appendingPathComponent("dock-preview-dock.png"), includeDock: true) { _ in }
                        }
                        // 2. Up onto the first card: the preview stays and highlights it.
                        let card = NSPoint(x: frame.minX + DockPreviewMetrics.padding + 60,
                                           y: frame.maxY - DockPreviewMetrics.padding - DockPreviewMetrics.header - DockPreviewMetrics.headerGap - 50)
                        glide(to: cg(card)) {
                            after(0.6) {
                                report["staysOnPanel"] = self.dockPreview.isVisible
                                snapshot("dock-preview-hover.png") { saved in
                                    report["hoverSnapshot"] = saved
                                    // 3. Click the card (only with --dock-preview-click, as it brings the app to the front):
                                    // the preview closes and that app becomes active.
                                    let clicks = CommandLine.arguments.contains("--dock-preview-click")
                                    for type in [CGEventType.leftMouseDown, .leftMouseUp] where clicks {
                                        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: current, mouseButton: .left)?.post(tap: .cghidEventTap)
                                    }
                                    after(0.8) {
                                        if clicks {
                                            report["hiddenAfterClick"] = !self.dockPreview.isVisible
                                            report["frontmostAfterClick"] = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
                                        }
                                        // 4. Away, then back onto the icon: it opens again.
                                        glide(to: away) {
                                            after(0.3) {
                                                reachIcon {
                                                    after(wait) {
                                                        report["shownAgain"] = self.dockPreview.isVisible
                                                        // 5. Away to the middle of the screen: the preview closes.
                                                        glide(to: away) {
                                                            after(0.8) {
                                                                report["hiddenAfterLeaving"] = !self.dockPreview.isVisible
                                                                glide(to: original) { finish() }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// `Glance --launcher-dump <file>`: what the search can open, and how a few sample queries rank.
    func runLauncherDump() {
        guard let path = Self.argument(after: "--launcher-dump") else { return }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        launcher.refreshIfNeeded(force: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            let entries = self.launcher.entries
            let apps = entries.filter { $0.kind == .app }, pages = entries.filter { $0.kind == .setting }
            var report: [String: Any] = [
                "apps": apps.count, "settingsPages": pages.count,
                "appSamples": apps.prefix(300).map { "\($0.name)\($0.alias.map { " / \($0)" } ?? "") [\($0.bundleID)]" },
                "settingsSamples": pages.map { "\($0.name)\($0.alias.map { " / \($0)" } ?? "") [\($0.bundleID)]" },
            ]
            let results = self.launcher.results(apps: true, settingsPages: true)
            var queries: [String: [String]] = [:]
            for query in ["wx", "weixin", "wechat", "蓝牙", "bluetooth", "lanya", "wifi", "safari", "jsq", "jisuanqi", "terminal", "zd", "zhongduan", "显示器", "xsq", "lock screen", "date", "mouse"] {
                queries[query] = WindowSearch.filtered(results.map(\.descriptor), settings: self.settings.value, profile: self.settings.value.shortcuts[0],
                                                       frontPID: nil, displayID: nil, query: query)
                    .prefix(5).map { "\($0.title) (\($0.launcher?.label ?? "窗口"))" }
            }
            report["queries"] = queries
            report["safari"] = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")?.path ?? "not found"
            report["languages"] = Array(Locale.preferredLanguages.prefix(3))
            let extensions = "/System/Library/ExtensionKit/Extensions"
            let battery = ((try? FileManager.default.contentsOfDirectory(atPath: extensions)) ?? [])
                .compactMap { Bundle(path: "\(extensions)/\($0)") }.first { $0.bundleIdentifier == "com.apple.Battery-Settings.extension" }
            if let battery {
                let resources = (try? FileManager.default.contentsOfDirectory(atPath: battery.resourcePath ?? "")) ?? []
                report["batteryBundle"] = ["path": battery.bundlePath, "resources": resources.sorted().prefix(40).map { $0 },
                                           "localizations": battery.localizations, "info": (battery.infoDictionary ?? [:]).keys.sorted()] as [String: Any]
            }
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url) }
        }
    }
}
