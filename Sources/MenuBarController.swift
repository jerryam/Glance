import AppKit
import ApplicationServices

/// One icon found in the menu bar, or remembered from the settings while its app is not running.
struct MenuBarItem: Identifiable, Equatable {
    let id: String
    var name: String
    var bundle: String?
    var symbol: String?
    /// Accessibility frame in screen points, top-left origin.
    var frame: CGRect?
    var present: Bool
    var assignable: Bool { MenuBarPolicy.isAssignable(id) }
}

/// Hides menu bar icons on macOS 27 and later, shows them on request and hides them again.
///
/// Compared with Ice 2's macOS 27 backend, which this follows: the menu bar is read only when apps launch
/// or quit and when the settings page asks, not on a 15-second timer; waking, changing Space or display
/// replaces the current request in place instead of first showing every icon, so nothing flickers; and
/// icons can be opened straight from 一瞥's search.
final class MenuBarController: ObservableObject {
    static var isSupported: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 }

    @Published private(set) var items: [MenuBarItem] = []
    @Published private(set) var reveal: MenuBarReveal = .none
    /// Why hiding is not working right now, for the settings page.
    @Published private(set) var problem: String?
    @Published private(set) var scanning = false
    private(set) var settings = MenuBarSettings()
    /// The 一瞥 icon reflects whether hidden icons are showing.
    var onRevealChange: (() -> Void)?
    /// Every pointer movement while hover is watched, which is when it matters whether watching still makes sense.
    var onPointerMoved: (() -> Void)?
    /// The front app has taken over the screen: the menu bar is out of reach, so hover is not watched at all.
    var pausedForFullscreen = false { didSet { if pausedForFullscreen != oldValue { updateHoverMonitor() } } }
    var hoverMonitorActive: Bool { mouseMonitor != nil }

    var available: Bool { Self.isSupported && GLMenuBarHidingAvailable() }
    /// A left click on the 一瞥 icon shows hidden icons instead of opening the menu.
    var handlesIconClick: Bool { available && settings.hidesAnything && problem == nil }

    private var assertion: AnyObject?
    private var pending: AnyObject?
    private var applied: MenuBarPolicy.Allowance?
    private var generation = 0
    private var timeout: DispatchWorkItem?

    private enum Source { case click, hover, search }
    private var source: Source = .click
    private var lastActivity = Date()
    private var rehideTimer: Timer?

    private var mouseMonitor: Any?
    private var hoverWork: DispatchWorkItem?
    private var menusEnd: Double?
    private var iconsFromRight: Double?
    private var barHeight: Double = 30

    private var started = false
    /// Names seen in the menu bar, kept so a hidden app keeps its name after 一瞥 restarts.
    private var knownNames = UserDefaults.standard.dictionary(forKey: "Glance.menuBarNames") as? [String: String] ?? [:]
    private var observers: [NSObjectProtocol] = []
    private var runningWork: DispatchWorkItem?
    private let queue = DispatchQueue(label: "Glance.menuBar", qos: .utility)
    private var iconCache: [String: NSImage] = [:]

    // MARK: Settings

    func configure(_ value: MenuBarSettings) {
        guard Self.isSupported else { return }
        let first = !started
        settings = value
        if first { start() }
        if !value.enabled && reveal != .none { reveal = .none; stopRehide(); onRevealChange?() }
        mergeSaved()
        apply()
        updateHoverMonitor()
        if first { scan() }
    }

    private func start() {
        started = true
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.runningAppsChanged() })
        }
        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.measureFrontMenus()
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.releaseAll()
        })
        // Replace the request in place: activating the new one before releasing the old keeps hidden icons hidden.
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.apply(force: true) })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.apply(force: true); self?.scan()
        })
    }

    /// A newly launched app must be allowed at once, or its icon would stay hidden until the next change.
    private func runningAppsChanged() {
        runningWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.apply()
            self?.mergeSaved()
            // Its icon appears a moment after launch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self?.scan() }
        }
        runningWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // MARK: Showing and hiding

    /// The 一瞥 icon or a shortcut: show hidden icons (with ⌥, also the always-hidden ones), or hide them again.
    func toggle(all: Bool) {
        guard handlesIconClick else { return }
        let target: MenuBarReveal = all ? .all : .hidden
        setReveal(reveal >= target ? .none : target, source: .click)
    }

    private func setReveal(_ value: MenuBarReveal, source: Source) {
        self.source = source
        lastActivity = Date()
        guard value != reveal else { return }
        reveal = value
        apply()
        if value == .none { stopRehide() } else { startRehide() }
        onRevealChange?()
    }

    private func startRehide() {
        guard rehideTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.checkRehide() }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        rehideTimer = timer
    }
    private func stopRehide() { rehideTimer?.invalidate(); rehideTimer = nil }

    /// Icons stay while the pointer is in the menu bar or one of its menus is open, then hide: a moment
    /// after a hover or a search, or after the chosen delay after a click or shortcut.
    private func checkRehide() {
        guard reveal != .none else { stopRehide(); return }
        if pointerInMenuBar() || Self.menuIsOpen() { lastActivity = Date(); return }
        let idle = Date().timeIntervalSince(lastActivity)
        switch source {
        case .hover, .search: if idle >= 1 { setReveal(.none, source: source) }
        case .click: if settings.rehideSeconds > 0 && idle >= Double(settings.rehideSeconds) { setReveal(.none, source: source) }
        }
    }

    /// Asks macOS for the current allow-list. `force` replaces an identical request, after waking for example.
    func apply(force: Bool = false) {
        guard Self.isSupported, started else { return }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let desired = available ? MenuBarPolicy.allowance(settings: settings, running: running, reveal: reveal) : nil
        if !available && settings.hidesAnything && problem == nil { problem = "这台 Mac 的系统没有提供隐藏菜单栏图标的接口，所有图标保持显示。" }
        guard force || desired != applied else { return }
        guard let desired else { releaseAll(); return }
        generation += 1
        let request = generation
        timeout?.cancel()
        GLMenuBarHidingInvalidate(pending); pending = nil
        applied = desired
        pending = GLMenuBarHidingActivate(desired.systemItems.map { NSNumber(value: $0) }, desired.bundles) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.generation == request else { return }
                self.timeout?.cancel(); self.timeout = nil
                if let error { self.failOpen("macOS 拒绝了隐藏请求：\(error.localizedDescription)"); return }
                // The previous request ends only now, so hidden icons never flash in between.
                GLMenuBarHidingInvalidate(self.assertion)
                self.assertion = self.pending; self.pending = nil
                self.problem = nil
            }
        } as AnyObject?
        guard pending != nil else { failOpen("无法向 macOS 发出隐藏请求，所有图标保持显示。"); return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == request else { return }
            self.failOpen("macOS 没有回应隐藏请求，所有图标保持显示。")
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// Shows every icon: before sleep, on quit and when anything fails.
    func releaseAll() {
        generation += 1
        timeout?.cancel(); timeout = nil
        GLMenuBarHidingInvalidate(assertion); GLMenuBarHidingInvalidate(pending)
        assertion = nil; pending = nil; applied = nil
    }

    private func failOpen(_ message: String) {
        releaseAll()
        problem = message
        if reveal != .none { reveal = .none; stopRehide(); onRevealChange?() }
    }

    /// Lets the settings page try again after a failure.
    func retry() {
        problem = nil
        apply(force: true)
        scan()
    }

    // MARK: Hover

    private func updateHoverMonitor() {
        let wanted = available && settings.revealOnHover && settings.hidesAnything && !pausedForFullscreen
        if wanted && mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in self?.pointerMoved() }
            measureFrontMenus()
        } else if !wanted, let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor); mouseMonitor = nil
            hoverWork?.cancel(); hoverWork = nil
        }
    }

    private func pointerMoved() {
        onPointerMoved?()
        guard reveal == .none else { return }
        guard inHoverZone() else { hoverWork?.cancel(); hoverWork = nil; return }
        guard hoverWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverWork = nil
            if self.reveal == .none && self.inHoverZone() { self.setReveal(.hidden, source: .hover) }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func screen(at point: NSPoint) -> NSScreen? { NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } }

    private func pointerInMenuBar() -> Bool {
        let point = NSEvent.mouseLocation
        guard let screen = screen(at: point) else { return false }
        return point.y >= screen.frame.maxY - barHeight
    }

    /// The empty stretch of the menu bar between the front app's menus and the first icon.
    private func inHoverZone() -> Bool {
        let point = NSEvent.mouseLocation
        guard let screen = screen(at: point), point.y >= screen.frame.maxY - barHeight else { return false }
        let width = Double(screen.frame.width)
        let iconsStart = iconsFromRight.map { width - $0 }
        guard let zone = MenuBarPolicy.hoverZone(menusEnd: menusEnd, iconsStart: iconsStart, screenWidth: width) else { return false }
        return zone.contains(Double(point.x - screen.frame.minX))
    }

    private func measureFrontMenus() {
        guard mouseMonitor != nil, AXIsProcessTrusted(), let front = NSWorkspace.shared.frontmostApplication else { return }
        let pid = front.processIdentifier
        queue.async { [weak self] in
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.3)
            var end: Double?
            if let bar = Self.attribute(app, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() {
                let menus = Self.attribute(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] ?? []
                end = menus.compactMap { Self.frame(of: $0)?.maxX }.max().map(Double.init)
            }
            DispatchQueue.main.async { self?.menusEnd = end }
        }
    }

    /// Any app's menu, including a menu bar icon's, is open.
    static func menuIsOpen() -> Bool {
        let own = getpid()
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { window in
            (window[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.popUpMenuWindow))
                && (window[kCGWindowOwnerPID as String] as? Int32) != own
        }
    }

    // MARK: Reading the menu bar

    /// Reads the menu bar off the main thread. Hidden icons are not in it, so remembered ones are kept.
    func scan() {
        guard Self.isSupported, started, !scanning, AXIsProcessTrusted() else {
            if Self.isSupported && !AXIsProcessTrusted() { mergeSaved() }
            return
        }
        scanning = true
        queue.async { [weak self] in
            let result = Self.snapshot()
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                if let height = result.barHeight, height >= 20 { self.barHeight = height }
                if let left = result.items.compactMap({ $0.frame?.minX }).min(), let width = result.width {
                    self.iconsFromRight = Double(width - left)
                }
                var merged = Dictionary(self.items.filter { !$0.id.hasPrefix("fixed:") }.map { item -> (String, MenuBarItem) in
                    var item = item; item.present = false; return (item.id, item)
                }, uniquingKeysWith: { first, _ in first })
                for item in result.items { merged[item.id] = item }
                self.items = Self.sorted(Array(merged.values))
                let names = result.items.filter { MenuBarPolicy.isAssignable($0.id) }.reduce(into: self.knownNames) { $0[$1.id] = $1.name }
                if names != self.knownNames { self.knownNames = names; UserDefaults.standard.set(names, forKey: "Glance.menuBarNames") }
                self.mergeSaved()
            }
        }
    }

    /// Adds apps that are assigned to a section but not in the menu bar right now, by their app names.
    private func mergeSaved() {
        var known = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in settings.sections.keys where known[id] == nil {
            if let bundle = MenuBarPolicy.bundle(of: id) {
                known[id] = MenuBarItem(id: id, name: knownNames[id] ?? Self.appName(bundle) ?? bundle, bundle: bundle, present: false)
            } else if let number = MenuBarPolicy.systemNumber(of: id), let system = MenuBarPolicy.systemItems.first(where: { $0.number == number }) {
                known[id] = MenuBarItem(id: id, name: system.name, symbol: system.symbol, present: false)
            }
        }
        let sorted = Self.sorted(Array(known.values))
        if sorted != items { items = sorted }
    }

    private static func sorted(_ list: [MenuBarItem]) -> [MenuBarItem] {
        list.sorted { a, b in
            if a.frame != nil && b.frame != nil { return a.frame!.minX < b.frame!.minX }
            if (a.frame == nil) != (b.frame == nil) { return a.frame != nil }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    static func appName(_ bundle: String) -> String? {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first, let name = app.localizedName { return name }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    func icon(for item: MenuBarItem) -> NSImage? {
        if let cached = iconCache[item.id] { return cached }
        var image: NSImage?
        if let bundle = item.bundle, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else if let symbol = item.symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.name)
        }
        if let image { iconCache[item.id] = image }
        return image
    }

    private struct Snapshot { var items: [MenuBarItem]; var barHeight: CGFloat?; var width: CGFloat? }

    private static func attribute(_ element: AXUIElement, _ key: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }
    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }
    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    /// MenuBarAgent draws the menu bar on macOS 27. Each icon is a button owned by its app's process, or,
    /// for system items, an element whose identifier starts with com.apple.menuextra.
    private static func elements(visit: @escaping (AXUIElement, String) -> Bool) -> (barHeight: CGFloat?, width: CGFloat?) {
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else { return (nil, nil) }
        let agentPID = agent.processIdentifier
        let root = AXUIElementCreateApplication(agentPID)
        AXUIElementSetMessagingTimeout(root, 0.3)
        var budget = 300, barHeight: CGFloat?, width: CGFloat?
        var stop = false
        func walk(_ element: AXUIElement, depth: Int) {
            guard !stop, depth <= 4, budget > 0 else { return }
            budget -= 1
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            let bundle = pid != agentPID ? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier : nil
            let identifier = attribute(element, kAXIdentifierAttribute) as? String
            if let id = MenuBarPolicy.identity(bundle: bundle, identifier: identifier.flatMap { $0.hasPrefix("com.apple.menuextra.") ? $0 : nil }) {
                if visit(element, id) { stop = true }
                return
            }
            for child in children(element) { walk(child, depth: depth + 1) }
        }
        for window in children(root) where (attribute(window, kAXRoleAttribute) as? String) == kAXWindowRole {
            if barHeight == nil, let frame = frame(of: window) { barHeight = frame.height; width = frame.width }
            for child in children(window) { walk(child, depth: 0) }
        }
        return (barHeight, width)
    }

    private static func snapshot() -> Snapshot {
        var found: [String: MenuBarItem] = [:]
        let bar = elements { element, id in
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            let app = NSRunningApplication(processIdentifier: pid)
            let bundle = MenuBarPolicy.bundle(of: id) ?? (id.hasPrefix("fixed:com.apple.") && !id.contains("menuextra") ? String(id.dropFirst(6)) : nil)
            let system = MenuBarPolicy.systemNumber(of: id).flatMap { number in MenuBarPolicy.systemItems.first { $0.number == number } }
            let described = (attribute(element, kAXDescriptionAttribute) as? String)?.components(separatedBy: "，").first
            let title = (attribute(element, kAXTitleAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
            let help = (attribute(element, kAXHelpAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
            // Apple's helpers report process names ("WeatherMenu"), and Siri shares SystemUIServer, so for those
            // the item's own label reads better; other apps are named as in the Dock.
            let apple = id.hasPrefix("fixed:") || bundle?.hasPrefix("com.apple.") == true
            let name = system?.name ?? (apple ? (title ?? described ?? help ?? app?.localizedName ?? id)
                                              : (app?.localizedName ?? help ?? title ?? described ?? id))
            let frame = frame(of: element)
            // Shared system processes have no icon of their own worth showing; use a symbol instead.
            let shared = id.hasPrefix("fixed:")
            let symbol = system?.symbol ?? (id == "fixed:com.apple.systemuiserver" ? "waveform.circle" : (shared || bundle == nil ? "menubar.rectangle" : nil))
            var item = found[id] ?? MenuBarItem(id: id, name: name, bundle: shared || bundle == MenuBarPolicy.ownBundle ? nil : bundle,
                                                symbol: symbol, frame: frame, present: true)
            if let frame, let current = item.frame { item.frame = current.union(frame) }
            found[id] = item
            return false
        }
        // 一瞥 itself is neither assignable nor a search result, but it still marks where the icons start.
        var items = Array(found.values)
        if let own = items.first(where: { $0.id == "bundle:\(MenuBarPolicy.ownBundle)" }) {
            items.removeAll { $0.id == own.id }
            if let frame = own.frame { items.append(MenuBarItem(id: "fixed:own", name: "一瞥", frame: frame, present: true)) }
        }
        return Snapshot(items: items, barHeight: bar.barHeight, width: bar.width)
    }

    /// Whether an item is in the menu bar right now. Reads Accessibility; call off the main thread.
    func isShowing(_ id: String) -> Bool {
        var found = false
        _ = Self.elements { _, candidate in
            guard candidate == id else { return false }
            found = true; return true
        }
        return found
    }
    var hoverMeasurements: [String: Any] {
        ["menusEnd": menusEnd as Any, "iconsFromRight": iconsFromRight as Any, "barHeight": barHeight, "monitoring": mouseMonitor != nil]
    }

    // MARK: Search

    /// Menu bar icons as search results. Selecting one opens its menu, showing it first if it is hidden.
    func searchResults() -> [WindowHandle] {
        guard Self.isSupported, settings.enabled, settings.searchable, AXIsProcessTrusted() else { return [] }
        return items.filter { $0.id != "fixed:own" && ($0.present || settings.sections[$0.id] != nil) }.map { item in
            let section = settings.section(of: item.id)
            let pid = item.bundle.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.processIdentifier } ?? 0
            var descriptor = WindowDescriptor(id: "menubar:\(item.id)", windowID: nil, pid: pid, appName: item.name,
                                              bundleID: item.bundle ?? item.id, title: item.name, minimized: false, hidden: false,
                                              onCurrentSpace: true, displayID: nil, aspectRatio: 1.6)
            descriptor.menuBarItem = true
            descriptor.subtitle = section == .visible || !item.assignable ? "菜单栏图标" : "菜单栏图标 · \(section.label)"
            return WindowHandle(descriptor: descriptor, ax: nil, icon: icon(for: item))
        }
    }

    func openMenu(forSearchResult resultID: String) {
        guard resultID.hasPrefix("menubar:") else { return }
        let id = String(resultID.dropFirst(8))
        let needed: MenuBarReveal = settings.section(of: id) == .alwaysHidden ? .all : (settings.section(of: id) == .hidden ? .hidden : .none)
        if handlesIconClick && needed > reveal { setReveal(needed, source: .search) }
        // A just-revealed icon takes a moment to appear; look for it a few times before pressing it.
        queue.async {
            for attempt in 0..<20 {
                var target: AXUIElement?
                _ = Self.elements { element, found in
                    guard found == id else { return false }
                    target = element; return true
                }
                if let target {
                    AXUIElementSetMessagingTimeout(target, 1)
                    if AXUIElementPerformAction(target, kAXPressAction as CFString) != .success {
                        _ = AXUIElementPerformAction(target, kAXShowMenuAction as CFString)
                    }
                    return
                }
                if attempt < 19 { Thread.sleep(forTimeInterval: 0.08) }
            }
            DispatchQueue.main.async { NSSound.beep() }
        }
    }
}
