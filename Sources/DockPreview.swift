import AppKit
import SwiftUI
import ApplicationServices

/// Dock 预览: rest the pointer on an app in the Dock and its windows appear beside the icon, like the
/// thumbnails on the Windows taskbar. Click a window to switch to it; the × on a card closes it.
///
/// The Dock tells Accessibility which icon is under the pointer (its list's selected child), and that
/// notification is the only signal used: no event tap and no polling of the Dock. While the panel is
/// open, a light timer follows the pointer so the panel stays while you move from the icon onto it.
final class DockPreviewState: ObservableObject {
    @Published var appName = ""
    @Published var appIcon: NSImage?
    @Published var items: [WindowHandle] = []
    @Published var images: [String: NSImage] = [:]
    @Published var flow = FlowLayout(rows: [], widths: [], thumbnailHeight: 112, gap: DockPreviewMetrics.gap)
    @Published var hoveredID: String?
    @Published var message = ""
    /// Without Screen Recording the cards show the app icon instead of a picture.
    @Published var canCapture = true
    /// Window titles on the cards; off when every title is just the app's name, which the header shows.
    @Published var showsTitles = true
    var onOpen: ((WindowHandle) -> Void)?
    var onClose: ((WindowHandle) -> Void)?
}

enum DockPreviewMetrics {
    static let padding: CGFloat = 14
    static let header: CGFloat = 26
    static let headerGap: CGFloat = 10
    static let gap = 10.0
    /// Thumbnails shrink from the first height towards the last until every window fits.
    static let thumbnailHeights: [Double] = [170, 150, 132, 116, 100, 84]
    /// A card's padding and, when shown, its title row.
    static func cardChrome(titles: Bool) -> Double { titles ? FlowLayout.cardChrome : FlowLayout.cardPadding }
    static func cardsHeight(_ flow: FlowLayout, titles: Bool) -> Double {
        flow.rows.isEmpty ? 0 : Double(flow.rows.count) * (flow.thumbnailHeight + cardChrome(titles: titles)) + Double(flow.rows.count - 1) * flow.gap
    }
    /// Distance between the Dock icon and the panel.
    static let iconGap: CGFloat = 8
}

final class DockPreviewController {
    enum Edge: String { case bottom, left, right }
    struct Target: Equatable {
        let path: String
        let pids: [Int32]
        let name: String
        let icon: NSImage?
        /// The icon in screen coordinates (origin bottom left).
        let iconFrame: NSRect
        let edge: Edge
        static func == (a: Target, b: Target) -> Bool { a.path == b.path && a.pids == b.pids && a.iconFrame == b.iconFrame && a.edge == b.edge }
    }

    private(set) var settings = DockPreviewSettings()
    /// The windows of these processes, from the switcher's window list.
    var windows: ((Set<Int32>) -> [WindowHandle])?
    /// Re-reads the window list, then calls back on the main queue.
    var refreshWindows: ((@escaping () -> Void) -> Void)?
    /// A capture the switcher already holds, so a card has a picture at once.
    var cachedImage: ((String) -> NSImage?)?
    /// True while the switcher is open: the two never show together.
    var isBlocked: (() -> Bool)?
    var onFocus: ((WindowHandle) -> Void)?
    /// Returns an error message, or nil when the window was asked to close.
    var onClose: ((WindowHandle) -> String?)?
    var appearance: NSAppearance? { didSet { panel?.appearance = appearance } }
    /// Development log (`--dock-preview-log`).
    var log: ((String) -> Void)?

    private(set) var attached = false
    private(set) var shown: Target?
    var isVisible: Bool { panel?.isVisible == true }
    var panelFrame: NSRect? { isVisible ? panel?.frame : nil }
    var panelWindow: NSWindow? { panel }

    private let state = DockPreviewState()
    private let capture = PreviewCapture()
    private var panel: PreviewPanel?
    private var observer: AXObserver?
    private var dockPID: pid_t = 0
    private var list: AXUIElement?
    private var pending: DispatchWorkItem?
    private var watchTimer: Timer?
    private var retryTimer: Timer?
    private var clickMonitor: Any?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var hoveredPath: String?
    /// The app whose icon or preview was just clicked: it does not open again until the pointer leaves the icon.
    private var suppressedPath: String?
    private var suppressTimer: Timer?
    private var outsideSince: TimeInterval?
    private var generation = 0
    /// The Dock itself (its list of icons) when the preview opened, in screen coordinates.
    private var dockFrame: NSRect?
    private var imageCache: [String: NSImage] = [:]
    private var cacheOrder: [String] = []

    init() {
        state.onOpen = { [weak self] handle in self?.open(handle) }
        state.onClose = { [weak self] handle in self?.close(handle) }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == "com.apple.dock" else { return }
                // A relaunched Dock builds its list a moment after it starts.
                self?.detach(); self?.hide()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.ensureAttached() }
            })
        }
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.detach(); self?.ensureAttached()
        })
    }

    func configure(_ settings: DockPreviewSettings) {
        self.settings = settings
        if settings.enabled { ensureAttached() } else { detach(); hide(); retryTimer?.invalidate(); retryTimer = nil }
    }

    // MARK: Following the Dock

    /// Subscribes to the Dock's hover notification; retries every few seconds until Accessibility is on
    /// and the Dock is running.
    func ensureAttached() {
        guard settings.enabled else { return }
        if attached, let dock = NSRunningApplication(processIdentifier: dockPID), !dock.isTerminated { return }
        detach()
        if attach() {
            retryTimer?.invalidate(); retryTimer = nil
            log?("attached dock=\(dockPID)")
        } else if retryTimer == nil {
            retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                guard let self else { return }
                if self.attach() { self.retryTimer?.invalidate(); self.retryTimer = nil; self.log?("attached dock=\(self.dockPID) (retry)") }
            }
        }
    }

    private func attach() -> Bool {
        guard settings.enabled, AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return false }
        let pid = dock.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let children = axAttribute(app, kAXChildrenAttribute) as? [AXUIElement],
              let found = children.first(where: { (axAttribute($0, kAXRoleAttribute) as? String) == (kAXListRole as String) }) else { return false }
        var created: AXObserver?
        guard AXObserverCreate(pid, { _, _, _, context in
            guard let context else { return }
            let controller = Unmanaged<DockPreviewController>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { controller.selectionChanged() }
        }, &created) == .success, let created else { return false }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(created, found, kAXSelectedChildrenChangedNotification as CFString, context) == .success else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created; list = found; dockPID = pid; attached = true
        return true
    }

    private func detach() {
        if let observer, let list {
            AXObserverRemoveNotification(observer, list, kAXSelectedChildrenChangedNotification as CFString)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil; list = nil; attached = false
        pending?.cancel(); pending = nil
    }

    deinit {
        detach()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    /// The Dock moved its highlight: to another icon, or off the icons altogether.
    private func selectionChanged() {
        guard settings.enabled, let list else { return }
        AXUIElementSetMessagingTimeout(list, 0.2)
        guard let item = (axAttribute(list, kAXSelectedChildrenAttribute) as? [AXUIElement])?.first else {
            // Off the icons: the pointer may be on its way to the panel, which the watch timer judges.
            hoveredPath = nil; pending?.cancel(); pending = nil
            log?("hover none")
            return
        }
        let target = self.target(for: item)
        if target?.path != hoveredPath { suppressedPath = nil }
        hoveredPath = target?.path
        log?("hover \(target.map { "\($0.name) pids=\($0.pids) edge=\($0.edge.rawValue)" } ?? "non-app")")
        pending?.cancel(); pending = nil
        guard let target, !target.pids.isEmpty, target.path != suppressedPath, !(isBlocked?() ?? false) else {
            // Another kind of icon (a folder, the Trash) or an app that is not open.
            if isVisible { hide(reason: "other icon") }
            return
        }
        if isVisible {
            // Moving along the Dock with the panel open switches at once, as on Windows.
            if shown?.path != target.path || shown?.iconFrame != target.iconFrame { present(target) }
            return
        }
        let work = DispatchWorkItem { [weak self] in
            // The Dock does not always report the pointer leaving, so check it is still on the icon.
            guard let self, self.hoveredPath == target.path, Self.isNear(target.iconFrame) else { return }
            self.present(target)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(settings.delay), execute: work)
    }

    private func target(for item: AXUIElement) -> Target? {
        AXUIElementSetMessagingTimeout(item, 0.2)
        guard (axAttribute(item, kAXSubroleAttribute) as? String) == "AXApplicationDockItem",
              let url = axAttribute(item, kAXURLAttribute) as? URL, let frame = axFrame(item) else { return nil }
        let path = url.standardizedFileURL.path
        let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL.path == path && !$0.isTerminated }
        let name = apps.first?.localizedName ?? (axAttribute(item, kAXTitleAttribute) as? String) ?? FileManager.default.displayName(atPath: path)
        let icon = Self.cocoaRect(frame)
        return Target(path: path, pids: apps.map(\.processIdentifier).sorted(), name: name, icon: apps.first?.icon,
                      iconFrame: icon, edge: dockEdge(icon: icon))
    }

    private static func isNear(_ icon: NSRect) -> Bool { icon.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation) }

    /// Keeps an app's preview closed until the pointer has left its icon: after a click on the icon or
    /// on one of its windows, the preview should not pop straight back up.
    private func suppress(_ target: Target) {
        suppressedPath = target.path
        suppressTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if !Self.isNear(target.iconFrame) || self.suppressedPath != target.path {
                if self.suppressedPath == target.path { self.suppressedPath = nil }
                timer.invalidate(); self.suppressTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        suppressTimer = timer
    }

    /// Which side of the screen the Dock is on, from the shape of its list.
    private func dockEdge(icon: NSRect) -> Edge {
        let screen = NSScreen.screens.first { $0.frame.intersects(icon) } ?? NSScreen.main
        if let list, let frame = axFrame(list), frame.width < frame.height, let screen {
            return Self.cocoaRect(frame).midX < screen.frame.midX ? .left : .right
        }
        return .bottom
    }

    /// Accessibility frames are measured from the top left of the main display; windows from the bottom left.
    static func cocoaRect(_ rect: CGRect) -> NSRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: Showing

    private func list(for target: Target) -> [WindowHandle] {
        let pids = Set(target.pids)
        return (windows?(pids) ?? []).filter { handle in
            let d = handle.descriptor
            return pids.contains(d.pid) && !d.windowless && !d.searchOnly && d.tabRepresentative && d.windowID != nil
                && (settings.includeMinimized || !d.minimized)
        }.sorted { a, b in
            // Order of opening, so each window keeps its place from one look to the next, as on Windows.
            (a.descriptor.windowID ?? .max) < (b.descriptor.windowID ?? .max)
        }
    }

    private func present(_ target: Target) {
        guard settings.enabled, !(isBlocked?() ?? false) else { return }
        let items = list(for: target)
        guard !items.isEmpty else {
            log?("no windows for \(target.name)")
            if isVisible { hide(reason: "no windows") }
            // The window list may simply be behind: look again once.
            refreshWindows? { [weak self] in
                guard let self, self.hoveredPath == target.path, !self.isVisible, !self.list(for: target).isEmpty else { return }
                self.present(target)
            }
            return
        }
        generation += 1
        let switching = isVisible && shown?.path != target.path
        shown = target
        dockFrame = list.flatMap(axFrame).map(Self.cocoaRect)
        fill(items, target: target)
        let panel = self.panel ?? makePanel()
        let size = contentSize(for: target)
        panel.setFrame(position(size: size, target: target), display: true)
        if !panel.isVisible {
            panel.alphaValue = 1
            startWatching()
        }
        panel.orderFrontRegardless()
        log?("show \(target.name) windows=\(items.count) frame=\(NSStringFromRect(panel.frame)) dock=\(dockFrame.map(NSStringFromRect) ?? "-")\(switching ? " (switched)" : "")")
        // The cached list is shown at once; a fresh read follows in case windows opened or closed.
        let generation = self.generation
        refreshWindows? { [weak self] in
            guard let self, self.generation == generation, self.isVisible, let shown = self.shown else { return }
            let fresh = self.list(for: shown)
            guard fresh.map(\.id) != self.state.items.map(\.id) else { return }
            if fresh.isEmpty { self.hide(reason: "windows closed"); return }
            self.fill(fresh, target: shown)
            self.panel?.setFrame(self.position(size: self.contentSize(for: shown), target: shown), display: true)
        }
    }

    private func fill(_ items: [WindowHandle], target: Target) {
        state.appName = target.name
        state.appIcon = target.icon ?? items.first?.icon
        state.message = ""
        state.canCapture = CGPreflightScreenCaptureAccess()
        state.hoveredID = nil
        state.showsTitles = items.contains { !$0.descriptor.title.isEmpty && $0.descriptor.title != target.name && $0.descriptor.title != $0.descriptor.appName }
        state.items = items
        var images: [String: NSImage] = [:]
        for item in items { if let image = imageCache[item.id] ?? cachedImage?(item.id) { images[item.id] = image } }
        state.images = images
        state.flow = layout(for: items, target: target)
        let scale = (NSScreen.screens.first { $0.frame.intersects(target.iconFrame) } ?? NSScreen.main)?.backingScaleFactor ?? 2
        capture.thumbnailPixelWidth = Int((state.flow.widestThumbnail * Double(scale)).rounded())
        capture.prepare(items, prioritized: items.map(\.id)) { [weak self] id, image in
            guard let self else { return }
            self.remember(id, image)
            if self.state.items.contains(where: { $0.id == id }) { self.state.images[id] = image }
        }
    }

    private func remember(_ id: String, _ image: NSImage) {
        imageCache[id] = image
        cacheOrder.removeAll { $0 == id }; cacheOrder.append(id)
        while cacheOrder.count > 40 { imageCache.removeValue(forKey: cacheOrder.removeFirst()) }
    }

    /// The largest thumbnails that keep every window within the screen beside the Dock.
    private func layout(for items: [WindowHandle], target: Target) -> FlowLayout {
        let area = availableArea(for: target)
        let chrome = Double(DockPreviewMetrics.padding * 2)
        let header = Double(DockPreviewMetrics.header + DockPreviewMetrics.headerGap)
        let width = Double(area.width) - chrome, height = Double(area.height) - chrome - header
        let aspects = items.map(\.descriptor.aspectRatio)
        var result = FlowLayout.calculate(aspects: aspects, availableWidth: width, availableHeight: height, preferredHeight: DockPreviewMetrics.thumbnailHeights[0],
                                          adaptive: false, gap: DockPreviewMetrics.gap)
        let titles = state.showsTitles
        for thumbnail in DockPreviewMetrics.thumbnailHeights.dropFirst()
            where DockPreviewMetrics.cardsHeight(result, titles: titles) > height || result.rows.count > 2 {
            result = FlowLayout.calculate(aspects: aspects, availableWidth: width, availableHeight: height, preferredHeight: thumbnail,
                                          adaptive: false, gap: DockPreviewMetrics.gap)
        }
        return result
    }

    /// The part of the screen the panel may use: everything beside the Dock, less a margin.
    private func availableArea(for target: Target) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(target.iconFrame) } ?? NSScreen.main
        let full = (screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)).insetBy(dx: 10, dy: 10)
        let visible = screen?.visibleFrame ?? full
        let gap = DockPreviewMetrics.iconGap
        let icon = target.iconFrame
        // The panel sits right against the Dock, so the Dock's own name label above the icon is behind
        // the panel rather than showing the name a second time underneath it.
        let dock = dockFrame
        switch target.edge {
        case .bottom:
            var bottom = icon.maxY + gap
            if let dock, dock.maxY >= icon.maxY - 1, dock.maxY <= icon.maxY + 30 { bottom = dock.maxY + 1 }
            return NSRect(x: full.minX, y: bottom, width: full.width, height: min(visible.maxY, full.maxY) - bottom)
        case .left:
            var left = icon.maxX + gap
            if let dock, dock.maxX >= icon.maxX - 1, dock.maxX <= icon.maxX + 30 { left = dock.maxX + 1 }
            return NSRect(x: left, y: full.minY, width: full.maxX - left, height: min(visible.maxY, full.maxY) - full.minY)
        case .right:
            var right = icon.minX - gap
            if let dock, dock.minX <= icon.minX + 1, dock.minX >= icon.minX - 30 { right = dock.minX - 1 }
            return NSRect(x: full.minX, y: full.minY, width: right - full.minX, height: min(visible.maxY, full.maxY) - full.minY)
        }
    }

    private func contentSize(for target: Target) -> NSSize {
        let flow = state.flow
        let header = DockPreviewMetrics.header + DockPreviewMetrics.headerGap
        let width = max(220, CGFloat(flow.contentWidth)) + DockPreviewMetrics.padding * 2
        let height = CGFloat(DockPreviewMetrics.cardsHeight(flow, titles: state.showsTitles)) + header + DockPreviewMetrics.padding * 2
        return NSSize(width: width.rounded(.up), height: height.rounded(.up))
    }

    /// Every window the Dock has on screen, for the development log.
    func dockWindowsDescription() -> String {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return "" }
        return info.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == dockPID }.compactMap { window -> String? in
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any], let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return "layer=\((window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0) alpha=\((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) \(NSStringFromRect(Self.cocoaRect(rect)))"
        }.joined(separator: "; ")
    }

    /// Centred on the icon, on the screen side of the Dock, and kept within the screen.
    private func position(size: NSSize, target: Target) -> NSRect {
        let area = availableArea(for: target), icon = target.iconFrame
        var origin: NSPoint
        switch target.edge {
        case .bottom: origin = NSPoint(x: icon.midX - size.width / 2, y: area.minY)
        case .left: origin = NSPoint(x: area.minX, y: icon.midY - size.height / 2)
        case .right: origin = NSPoint(x: area.maxX - size.width, y: icon.midY - size.height / 2)
        }
        origin.x = min(max(origin.x, area.minX), max(area.minX, area.maxX - size.width))
        origin.y = min(max(origin.y, area.minY), max(area.minY, area.maxY - size.height))
        return NSRect(origin: origin, size: size)
    }

    private func makePanel() -> PreviewPanel {
        let panel = PreviewPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 220),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "一瞥 · Dock 预览"
        // isFloatingPanel resets the level to “floating”, below the Dock, so it goes first. Above the Dock,
        // the panel hides the Dock's own name label instead of the label covering the panel.
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .utilityWindow
        panel.appearance = appearance
        panel.isReleasedWhenClosed = false
        self.panel = panel
        return panel
    }

    /// Installed by AppDelegate, which owns the glass container.
    func install(content: (DockPreviewState) -> NSView) {
        let panel = self.panel ?? makePanel()
        panel.contentView = content(state)
    }

    func hide(reason: String = "") {
        pending?.cancel(); pending = nil
        stopWatching()
        guard let panel, panel.isVisible else { shown = nil; return }
        panel.orderOut(nil)
        capture.cancel()
        shown = nil
        state.hoveredID = nil
        log?("hide\(reason.isEmpty ? "" : " (\(reason))")")
    }

    // MARK: While open

    private func startWatching() {
        stopWatching()
        outsideSince = nil
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in self?.watchPointer() }
        RunLoop.main.add(timer, forMode: .common)
        watchTimer = timer
        // A click anywhere else, the Dock icon included, closes the panel, as on Windows.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            guard let self, let shown = self.shown else { return }
            if Self.isNear(shown.iconFrame) { self.suppress(shown) }
            self.hide(reason: "click")
        }
    }

    private func stopWatching() {
        watchTimer?.invalidate(); watchTimer = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    /// Keeps the panel while the pointer is on the icon, on the panel or between the two.
    private func watchPointer() {
        guard let panel, panel.isVisible, let shown else { stopWatching(); return }
        if isBlocked?() == true { hide(reason: "switcher"); return }
        let point = NSEvent.mouseLocation
        if Self.keepsOpen(point: point, icon: shown.iconFrame, panel: panel.frame, edge: shown.edge) { outsideSince = nil; return }
        let now = ProcessInfo.processInfo.systemUptime
        guard let since = outsideSince else { outsideSince = now; return }
        if now - since > 0.25 { hide(reason: "pointer left") }
    }

    static func keepsOpen(point: NSPoint, icon: NSRect, panel: NSRect, edge: Edge) -> Bool {
        if panel.insetBy(dx: -6, dy: -6).contains(point) || icon.insetBy(dx: -2, dy: -2).contains(point) { return true }
        // The strip between the icon and the panel, as wide as the icon.
        let bridge: NSRect
        switch edge {
        case .bottom: bridge = NSRect(x: icon.minX, y: icon.maxY - 1, width: icon.width, height: max(0, panel.minY - icon.maxY) + 2)
        case .left: bridge = NSRect(x: icon.maxX - 1, y: icon.minY, width: max(0, panel.minX - icon.maxX) + 2, height: icon.height)
        case .right: bridge = NSRect(x: panel.maxX - 1, y: icon.minY, width: max(0, icon.minX - panel.maxX) + 2, height: icon.height)
        }
        return bridge.contains(point)
    }

    // MARK: Actions

    private func open(_ handle: WindowHandle) {
        if let shown { suppress(shown) }
        hide(reason: "open")
        onFocus?(handle)
    }

    private func close(_ handle: WindowHandle) {
        if let error = onClose?(handle) { state.message = error; return }
        log?("close \(handle.id)")
        // Give the app a moment to close it (or to ask about unsaved changes), then read the list again.
        let generation = self.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.generation == generation, self.isVisible else { return }
            self.refreshWindows? { [weak self] in
                guard let self, self.generation == generation, self.isVisible, let shown = self.shown else { return }
                let fresh = self.list(for: shown)
                if fresh.isEmpty { self.hide(reason: "last window closed"); return }
                guard fresh.map(\.id) != self.state.items.map(\.id) else { return }
                self.fill(fresh, target: shown)
                self.panel?.setFrame(self.position(size: self.contentSize(for: shown), target: shown), display: true)
            }
        }
    }

    // MARK: Development

    /// Points at an app's Dock icon (for the self-test): its frame in screen coordinates, or nil.
    func dockIconFrame(bundleID: String) -> NSRect? {
        guard let list, let items = axAttribute(list, kAXChildrenAttribute) as? [AXUIElement],
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              let path = app.bundleURL?.standardizedFileURL.path else { return nil }
        for item in items where (axAttribute(item, kAXSubroleAttribute) as? String) == "AXApplicationDockItem" {
            if let url = axAttribute(item, kAXURLAttribute) as? URL, url.standardizedFileURL.path == path, let frame = axFrame(item) {
                return Self.cocoaRect(frame)
            }
        }
        return nil
    }
}

// MARK: - The panel's content

struct DockPreviewView: View {
    @ObservedObject var state: DockPreviewState
    var body: some View {
        VStack(alignment: .leading, spacing: DockPreviewMetrics.headerGap) {
            HStack(spacing: 8) {
                if let icon = state.appIcon { Image(nsImage: icon).resizable().interpolation(.high).frame(width: 20, height: 20) }
                Text(state.appName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if !state.message.isEmpty {
                    Text(state.message).font(.system(size: 11)).foregroundStyle(.red).lineLimit(1)
                } else {
                    Text("\(state.items.count) 个窗口").font(.system(size: 11)).foregroundStyle(GlanceDesign.secondary)
                }
                Spacer(minLength: 0)
            }.frame(height: DockPreviewMetrics.header)
            VStack(alignment: .center, spacing: CGFloat(state.flow.gap)) {
                ForEach(Array(state.flow.rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: CGFloat(state.flow.gap)) {
                        ForEach(row, id: \.self) { index in
                            if state.items.indices.contains(index) {
                                DockPreviewCard(state: state, item: state.items[index],
                                                width: CGFloat(state.flow.widths[index]), thumbnailHeight: CGFloat(state.flow.thumbnailHeight))
                            }
                        }
                    }
                }
            }.frame(maxWidth: .infinity)
        }
        .padding(DockPreviewMetrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .modifier(GlancePanelBackdrop())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(state.appName) 的窗口")
    }
}

private struct DockPreviewCard: View {
    @ObservedObject var state: DockPreviewState
    let item: WindowHandle
    let width: CGFloat
    let thumbnailHeight: CGFloat
    private var hovered: Bool { state.hoveredID == item.id }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.showsTitles {
                HStack(spacing: 6) {
                    Text(item.descriptor.displayTitle).font(.system(size: 12, weight: hovered ? .bold : .semibold)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 2)
                    if item.descriptor.minimized { Image(systemName: "minus.circle").font(.system(size: 11)).foregroundStyle(GlanceDesign.secondary).help("已最小化") }
                    if !item.descriptor.onCurrentSpace { Image(systemName: "square.on.square").font(.system(size: 11)).foregroundStyle(GlanceDesign.secondary).help("在其他桌面") }
                }.frame(height: 20)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quinary)
                if let image = state.images[item.id] {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit().padding(4)
                } else {
                    VStack(spacing: 6) {
                        if let icon = item.icon { Image(nsImage: icon).resizable().frame(width: 30, height: 30) }
                        Text(item.descriptor.minimized ? "窗口已最小化" : (state.canCapture ? "正在读取预览" : "需要屏幕录制权限")).font(.system(size: 11)).foregroundStyle(GlanceDesign.secondary)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .frame(width: max(40, width - CGFloat(FlowLayout.cardPadding)), height: thumbnailHeight)
            .opacity(item.descriptor.minimized || item.descriptor.hidden ? 0.6 : 1)
        }
        .padding(10)
        .frame(width: width, height: thumbnailHeight + CGFloat(DockPreviewMetrics.cardChrome(titles: state.showsTitles)), alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: GlanceDesign.cardRadius, style: .continuous)
                .fill(hovered ? GlanceDesign.raised : Color.clear)
        }
        .overlay {
            if hovered {
                RoundedRectangle(cornerRadius: GlanceDesign.cardRadius + 1, style: .continuous)
                    .stroke(GlanceDesign.accent, lineWidth: 2).padding(-1)
            }
        }
        .overlay(alignment: .topTrailing) {
            if hovered {
                Button { state.onClose?(item) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.red.opacity(0.9))
                        .frame(width: 22, height: 22).contentShape(Circle())
                }
                .buttonStyle(.plain).padding(3).modifier(FloatingCapsule())
                .help("关闭窗口").accessibilityLabel("关闭窗口：\(item.descriptor.displayTitle)")
                .offset(x: 6, y: -6)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: GlanceDesign.cardRadius, style: .continuous))
        .onTapGesture { state.onOpen?(item) }
        .onHover { inside in
            if inside { state.hoveredID = item.id } else if state.hoveredID == item.id { state.hoveredID = nil }
        }
        .help(item.descriptor.displayTitle)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.descriptor.displayTitle)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { state.onOpen?(item) }
    }
}

/// Accepts the first click: the panel never becomes key, so without this a click would only focus it.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
