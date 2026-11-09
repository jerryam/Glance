import AppKit
import ApplicationServices
import ScreenCaptureKit
import Combine

final class SettingsStore: ObservableObject {
    @Published private(set) var value: UserSettings
    var onChange: (() -> Void)?
    /// Set when the stored configuration had to be repaired or could not be read at launch.
    private(set) var loadNotice: String?
    // Storage keys keep the pre-rename prefix so settings carry over from 窗间 / WindowHop.
    static let key = "WindowHop.settings.v1"
    static let backupKey = "WindowHop.settings.v1.backup"
    var hadSavedSettings: Bool { UserDefaults.standard.data(forKey: Self.key) != nil }
    init() {
        let store = UserDefaults.standard
        guard let data = store.data(forKey: Self.key) else { value = .defaults; return }
        if let saved = try? JSONDecoder().decode(UserSettings.self, from: data) {
            if saved.validationError() == nil {
                value = saved
            } else {
                // Keep the original bytes so nothing is lost, then repair instead of resetting everything.
                store.set(data, forKey: Self.backupKey); keepsLoadBackup = true
                let repaired = saved.repaired()
                value = repaired.validationError() == nil ? repaired : .defaults
                loadNotice = "部分设置无效，已自动修正；原配置已备份，可在 通用 › 备份与迁移 中恢复。"
            }
        } else {
            store.set(data, forKey: Self.backupKey); keepsLoadBackup = true
            value = .defaults
            loadNotice = "设置无法读取，暂时使用默认设置；原配置已备份，可在 通用 › 备份与迁移 中恢复。"
        }
    }
    func save(_ settings: UserSettings) {
        guard settings.validationError() == nil else { return }
        guard settings != value else { return }
        value = settings
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.key) }
        onChange?()
    }
    /// Settings apply as they are edited, so the backup is taken once, before the first change of an
    /// editing session. A backup made by repairing at launch is kept for the rest of this run.
    func snapshotBackup() {
        guard !keepsLoadBackup, let data = UserDefaults.standard.data(forKey: Self.key) else { return }
        UserDefaults.standard.set(data, forKey: Self.backupKey)
    }
    private var keepsLoadBackup = false
    /// The configuration from before the most recent editing session, or the original one that was repaired.
    func backup() -> UserSettings? {
        guard let data = UserDefaults.standard.data(forKey: Self.backupKey),
              let settings = try? JSONDecoder().decode(UserSettings.self, from: data) else { return nil }
        return settings.repaired()
    }
}

func axAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
}

func axFrame(_ element: AXUIElement) -> CGRect? {
    guard let p = axAttribute(element, kAXPositionAttribute), let s = axAttribute(element, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}

final class WindowHandle: Identifiable {
    let descriptor: WindowDescriptor
    let ax: AXUIElement?
    let icon: NSImage?
    let tab: AXUIElement?
    let browserTab: BrowserTabRef?
    var id: String { descriptor.id }
    init(descriptor: WindowDescriptor, ax: AXUIElement?, icon: NSImage?, tab: AXUIElement? = nil, browserTab: BrowserTabRef? = nil) {
        self.descriptor = descriptor; self.ax = ax; self.icon = icon; self.tab = tab; self.browserTab = browserTab
    }
    func with(_ descriptor: WindowDescriptor) -> WindowHandle {
        WindowHandle(descriptor: descriptor, ax: ax, icon: icon, tab: tab, browserTab: browserTab)
    }
}

private struct CGEntry {
    let id: UInt32
    let pid: Int32
    let title: String
    let frame: CGRect
    let visible: Bool
}

private struct RunningAppInfo {
    let pid: Int32
    let name: String
    let bundle: String
    let hidden: Bool
    let icon: NSImage?
}

final class WindowEngine: ObservableObject {
    @Published private(set) var windows: [WindowHandle] = []
    private let worker = DispatchQueue(label: "Glance.enumeration", qos: .userInitiated)
    private var refreshRequests = RefreshTicketQueue<([WindowHandle]) -> Void>()
    private var refreshing = false
    private var queuedFrontPID: Int32?
    private var focusHistory: [String: TimeInterval] = [:]
    private var appHistory: [Int32: TimeInterval] = [:]
    private var lastTracked = ""
    private var firstSeen: [String: TimeInterval] = [:]
    private var axObservers: [Int32: AXObserver] = [:]
    private var watchedWindows: [Int32: [AXUIElement]] = [:]
    private(set) var observerEventCounts: [String: Int] = [:]
    private(set) var suppressedSurfaceCount = 0
    private(set) var unavailableWindowListCount = 0
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lastForeground = ""
    private var focusDebounce: DispatchWorkItem?
    var onForegroundChange: (() -> Void)?
    var onWindowsChange: (() -> Void)?
    /// (window id, new title) for a title change that did not need a full re-read.
    var onTitleChange: ((String, String) -> Void)?
    /// Scanning every window for tab groups costs dozens of accessibility calls; only done when a
    /// switching scheme shows tabs separately.
    var scanTabs = false
    var observedWindowCount: Int { watchedWindows.values.reduce(0) { $0 + $1.count } }
    var suspendTracking = false
    private var activationObserver: NSObjectProtocol?

    init() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if !self.suspendTracking && app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                self.appHistory[app.processIdentifier] = Date.timeIntervalSinceReferenceDate
            }
            let previous = self.lastForeground
            self.watchApplications()
            self.trackFocus()
            if self.lastForeground == previous { self.onForegroundChange?() }
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.watchApplications(); self?.trackFocus(); self?.onWindowsChange?()
            })
        }
        watchApplications()
    }
    deinit {
        focusDebounce?.cancel()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        axObservers.values.forEach { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource($0), .commonModes) }
    }
    func refreshObservers() { watchApplications(); trackFocus() }
    private static let windowNotifications = [kAXUIElementDestroyedNotification, kAXTitleChangedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXResizedNotification, kAXMovedNotification]
    private func watchWindow(_ window: AXUIElement, pid: Int32) {
        guard let observer = axObservers[pid], !(watchedWindows[pid] ?? []).contains(where: { CFEqual($0, window) }) else { return }
        for name in Self.windowNotifications {
            _ = AXObserverAddNotification(observer, window, name as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        watchedWindows[pid, default: []].append(window)
    }
    private func windowEvent(_ window: AXUIElement, notification: String) {
        observerEventCounts[notification, default: 0] += 1
        if notification == kAXTitleChangedNotification {
            // Only that entry changes; re-reading every app for a ticking title would waste work.
            AXUIElementSetMessagingTimeout(window, 0.1)
            guard let title = axAttribute(window, kAXTitleAttribute) as? String,
                  let index = windows.firstIndex(where: { $0.tab == nil && $0.ax.map { CFEqual($0, window) } == true }) else { return }
            var descriptor = windows[index].descriptor
            guard descriptor.title != title else { return }
            descriptor.title = title
            windows[index] = windows[index].with(descriptor)
            onTitleChange?(descriptor.id, title)
            return
        }
        // Moving or resizing alone does not change which windows exist.
        if notification == kAXMovedNotification || notification == kAXResizedNotification { return }
        if notification == kAXUIElementDestroyedNotification {
            windows.removeAll { handle in handle.ax.map { CFEqual($0, window) } == true }
            for pid in Array(watchedWindows.keys) { watchedWindows[pid]?.removeAll { CFEqual($0, window) } }
        }
        focusDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.trackFocus() }
        focusDebounce = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
        onWindowsChange?()
    }
    private func watchApplications() {
        guard AXIsProcessTrusted() else { return }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        let pids = Set(apps.map(\.processIdentifier))
        for pid in Array(axObservers.keys) where !pids.contains(pid) {
            if let observer = axObservers.removeValue(forKey: pid) { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
            watchedWindows.removeValue(forKey: pid)
            focusHistory = focusHistory.filter { key, _ in !key.hasPrefix("\(pid)|") }
            appHistory.removeValue(forKey: pid)
        }
        for app in apps where axObservers[app.processIdentifier] == nil {
            var observer: AXObserver?
            guard AXObserverCreate(app.processIdentifier, { _, element, name, context in
                guard let context else { return }
                let engine = Unmanaged<WindowEngine>.fromOpaque(context).takeUnretainedValue()
                let notification = name as String
                DispatchQueue.main.async { [weak engine] in engine?.windowEvent(element, notification: notification) }
            }, &observer) == .success, let observer else { continue }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.15)
            // Some apps only deliver descendant-window notifications through the application element.
            // Keep direct window subscriptions as a fallback for apps with narrower notification support.
            for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                         kAXWindowCreatedNotification, kAXApplicationActivatedNotification] + Self.windowNotifications {
                _ = AXObserverAddNotification(observer, element, name as CFString, Unmanaged.passUnretained(self).toOpaque())
            }
            axObservers[app.processIdentifier] = observer
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
    }
    func shortcutsIgnored(_ rules: [AppException]) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        let rules = rules.filter { $0.matches(bundle: app.bundleIdentifier ?? "") }
        if rules.contains(where: { $0.ignore == .always }) { return true }
        guard rules.contains(where: { $0.ignore == .fullscreen }), AXIsProcessTrusted() else { return false }
        let ax = AXUIElementCreateApplication(app.processIdentifier); AXUIElementSetMessagingTimeout(ax, 0.10)
        guard let focused = axAttribute(ax, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        return (axAttribute(focused as! AXUIElement, "AXFullScreen") as? NSNumber)?.boolValue == true
    }
    private func trackFocus() {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.15)
        guard let focused = axAttribute(element, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            let foreground = "\(app.processIdentifier):false"
            if foreground != lastForeground { lastForeground = foreground; onForegroundChange?() }
            return
        }
        let title = axAttribute(focused as! AXUIElement, kAXTitleAttribute) as? String ?? ""
        let window = focused as! AXUIElement
        watchWindow(window, pid: app.processIdentifier)
        let key = NativeBridge.windowID(window).map { "cg:\($0)" } ?? "\(app.processIdentifier)|\(title)"
        let full = (axAttribute(window, "AXFullScreen") as? NSNumber)?.boolValue ?? false
        let foreground = "\(app.processIdentifier):\(full)"
        if foreground != lastForeground { lastForeground = foreground; onForegroundChange?() }
        // Freeze MRU while selecting, but continue detecting remote fullscreen changes.
        guard !suspendTracking else { return }
        guard key != lastTracked else { return }
        lastTracked = key
        focusHistory[key] = Date.timeIntervalSinceReferenceDate
    }
    func refresh(frontPID: Int32?, completion: @escaping ([WindowHandle]) -> Void) {
        let request = refreshRequests.append(completion)
        queuedFrontPID = frontPID
        guard !refreshing else { return }
        enumerate(frontPID: frontPID, request: request)
    }
    func cachedSnapshot() -> [WindowHandle] {
        windows.compactMap { handle in
            guard let app = NSRunningApplication(processIdentifier: handle.descriptor.pid), !app.isTerminated else { return nil }
            var descriptor = handle.descriptor
            descriptor.hidden = app.isHidden
            descriptor.lastFocused = max(descriptor.lastFocused, focusHistory[descriptor.id] ?? 0,
                                         focusHistory["\(descriptor.pid)|\(descriptor.title)"] ?? 0)
            return WindowHandle(descriptor: descriptor, ax: handle.ax, icon: handle.icon, tab: handle.tab)
        }
    }
    private func enumerate(frontPID: Int32?, request: Int) {
        let start = ProcessInfo.processInfo.systemUptime
        refreshing = true
        let trusted = AXIsProcessTrusted()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID }.map {
            RunningAppInfo(pid: $0.processIdentifier, name: $0.localizedName ?? "应用", bundle: $0.bundleIdentifier ?? "", hidden: $0.isHidden, icon: $0.icon)
        }
        let displays: [(UInt32, CGRect)] = NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (id.uint32Value, CGDisplayBounds(id.uint32Value))
        }
        let history = focusHistory, activated = appHistory, firstSeen = self.firstSeen, scanTabs = self.scanTabs
        worker.async { [weak self] in
            let dictionaries = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let entries: [CGEntry] = dictionaries.compactMap { d in
                guard (d[kCGWindowLayer as String] as? Int ?? 1) == 0,
                      let id = d[kCGWindowNumber as String] as? UInt32,
                      let pid = d[kCGWindowOwnerPID as String] as? Int32,
                      let bounds = d[kCGWindowBounds as String] as? [String: Any],
                      let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.width >= 60, frame.height >= 45 else { return nil }
                return CGEntry(id: id, pid: pid, title: d[kCGWindowName as String] as? String ?? "", frame: frame, visible: d[kCGWindowIsOnscreen as String] as? Bool ?? false)
            }
            let spaces = NativeBridge.spaces()
            let cgOrder = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.id, $0.offset) })
            var handles: [WindowHandle] = [], currentID: String?
            var suppressedSurfaces = 0, unavailableWindowLists = 0
            func decorate(_ input: WindowDescriptor, rect: CGRect, ax: AXUIElement?) -> WindowDescriptor {
                var d = input
                d.fullscreen = ax.flatMap { (axAttribute($0, "AXFullScreen") as? NSNumber)?.boolValue } ?? false
                d.frame = WindowRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
                d.spaces = d.windowID.map { spaces.ids(for: $0) } ?? []
                d.spaceKnown = !d.spaces.isEmpty
                d.spaceNumbers = d.spaces.compactMap { spaces.numbers[$0] }
                d.created = firstSeen[d.id] ?? Date.timeIntervalSinceReferenceDate
                d.lastFocused = history[d.id] ?? history["\(d.pid)|\(d.title)"] ?? activated[d.pid] ?? 0
                d.controllable = ax != nil || d.windowless
                d.zOrder = d.windowID.flatMap { cgOrder[$0] } ?? Int.max
                return d
            }
            // Each app is read on its own thread, so one slow or hung app no longer delays all the others.
            struct AppScan { var handles: [WindowHandle] = []; var currentID: String?; var suppressed = 0; var unavailable = 0 }
            func scan(_ app: RunningAppInfo) -> AppScan {
                var result = AppScan()
                let cgWindows = entries.filter { $0.pid == app.pid }
                let appAX = AXUIElementCreateApplication(app.pid)
                if trusted { AXUIElementSetMessagingTimeout(appAX, 0.20) }
                var windowValue: CFTypeRef?
                let windowStatus = trusted ? AXUIElementCopyAttributeValue(appAX, kAXWindowsAttribute as CFString, &windowValue) : .apiDisabled
                let windowListAvailable = windowStatus == .success && windowValue is [AXUIElement]
                if trusted && !windowListAvailable { result.unavailable += 1 }
                var axWindows = windowValue as? [AXUIElement] ?? []
                let focused = trusted ? axAttribute(appAX, kAXFocusedWindowAttribute) : nil
                if let focused, CFGetTypeID(focused) == AXUIElementGetTypeID(), !axWindows.contains(where: { CFEqual($0, focused) }) {
                    axWindows.append(focused as! AXUIElement)
                }
                var used = Set<UInt32>()
                for ax in axWindows {
                    AXUIElementSetMessagingTimeout(ax, 0.15)
                    let title = axAttribute(ax, kAXTitleAttribute) as? String ?? ""
                    let frame = axFrame(ax) ?? .zero
                    let minimized = (axAttribute(ax, kAXMinimizedAttribute) as? NSNumber)?.boolValue ?? false
                    let role = axAttribute(ax, kAXRoleAttribute) as? String ?? ""
                    let subrole = axAttribute(ax, kAXSubroleAttribute) as? String ?? ""
                    let nativeID = NativeBridge.windowID(ax)
                    guard WindowEligibility.accepts(role: role, subrole: subrole, width: Double(frame.width), height: Double(frame.height),
                        minimized: minimized, hidden: app.hidden, hasWindowID: nativeID != nil) else {
                        if let nativeID { used.insert(nativeID) }
                        continue
                    }
                    let candidates = cgWindows.filter { !used.contains($0.id) }
                    let match = nativeID.flatMap { id in candidates.first { $0.id == id } } ?? candidates.min { lhs, rhs in
                        Self.matchScore(lhs, title: title, frame: frame) < Self.matchScore(rhs, title: title, frame: frame)
                    }.flatMap { Self.matchScore($0, title: title, frame: frame) < 100 ? $0 : nil }
                    let windowID = nativeID ?? match?.id
                    if let windowID { used.insert(windowID) }
                    let rect = match?.frame ?? frame
                    let display = displays.max { lhs, rhs in lhs.1.intersection(rect).area < rhs.1.intersection(rect).area }?.0
                    let id = windowID.map { "cg:\($0)" } ?? "ax:\(app.pid):\(CFHash(ax))"
                    let windowSpaces = windowID.map { spaces.ids(for: $0) } ?? []
                    let visibleSpace = windowSpaces.isEmpty ? (match?.visible ?? false) : !spaces.visible.isDisjoint(with: windowSpaces)
                    var description = decorate(WindowDescriptor(id: id, windowID: windowID, pid: app.pid, appName: app.name, bundleID: app.bundle,
                                                       title: title.isEmpty ? (match?.title ?? "") : title, minimized: minimized, hidden: app.hidden,
                                                       onCurrentSpace: visibleSpace, displayID: display, aspectRatio: Double(rect.width / max(1, rect.height))), rect: rect, ax: ax)
                    let tabs = scanTabs ? NativeBridge.tabs(in: ax) : []
                    if tabs.count > 1 { description.tabGroup = id }
                    result.handles.append(.init(descriptor: description, ax: ax, icon: app.icon))
                    for (tabIndex, tab) in tabs.enumerated() where (axAttribute(tab, kAXValueAttribute) as? NSNumber)?.boolValue != true {
                        let tabTitle = axAttribute(tab, kAXTitleAttribute) as? String ?? axAttribute(tab, kAXDescriptionAttribute) as? String ?? "标签页 \(tabIndex + 1)"
                        var d = decorate(WindowDescriptor(id: "\(id):tab:\(tabIndex)", windowID: windowID, pid: app.pid, appName: app.name, bundleID: app.bundle,
                            title: tabTitle, minimized: minimized, hidden: app.hidden, onCurrentSpace: visibleSpace, displayID: display, aspectRatio: description.aspectRatio), rect: rect, ax: ax)
                        d.tabGroup = id; d.tabRepresentative = false
                        result.handles.append(.init(descriptor: d, ax: ax, icon: app.icon, tab: tab))
                    }
                    if app.pid == frontPID, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID(), CFEqual(focused, ax) { result.currentID = id }
                }
                if trusted { result.suppressed += cgWindows.filter { !used.contains($0.id) && !$0.title.isEmpty }.count }
                for cg in cgWindows where WindowDiscoveryPolicy.includesUnboundSurface(accessibilityTrusted: trusted) && !used.contains(cg.id) && !cg.title.isEmpty {
                    let display = displays.max { lhs, rhs in lhs.1.intersection(cg.frame).area < rhs.1.intersection(cg.frame).area }?.0
                    let ids = spaces.ids(for: cg.id)
                    let visible = ids.isEmpty ? cg.visible : !spaces.visible.isDisjoint(with: ids)
                    result.handles.append(.init(descriptor: decorate(.init(id: "cg:\(cg.id)", windowID: cg.id, pid: app.pid, appName: app.name, bundleID: app.bundle,
                                                          title: cg.title, minimized: false, hidden: app.hidden, onCurrentSpace: visible,
                                                          displayID: display, aspectRatio: Double(cg.frame.width / max(1, cg.frame.height))), rect: cg.frame, ax: nil), ax: nil, icon: app.icon))
                }
                if WindowDiscoveryPolicy.includesWindowlessApp(accessibilityTrusted: trusted, windowListAvailable: windowListAvailable,
                    liveWindowCount: result.handles.count) {
                    result.handles.append(.init(descriptor: decorate(.init(id: "app:\(app.pid)", windowID: nil, pid: app.pid, appName: app.name,
                                                          bundleID: app.bundle, title: "", minimized: false, hidden: app.hidden,
                                                          onCurrentSpace: true, displayID: nil, aspectRatio: 1.6, windowless: true), rect: .zero, ax: nil), ax: nil, icon: app.icon))
                }
                return result
            }
            var scans = [AppScan](repeating: AppScan(), count: apps.count)
            scans.withUnsafeMutableBufferPointer { buffer in
                let slots = buffer
                DispatchQueue.concurrentPerform(iterations: apps.count) { index in slots[index] = scan(apps[index]) }
            }
            for scanned in scans {
                handles += scanned.handles
                if currentID == nil { currentID = scanned.currentID }
                suppressedSurfaces += scanned.suppressed; unavailableWindowLists += scanned.unavailable
            }
            let front = currentID ?? handles.first { $0.descriptor.pid == frontPID && $0.descriptor.onCurrentSpace }?.id
            if let front, let index = handles.firstIndex(where: { $0.id == front }) {
                let old = handles[index]; var d = old.descriptor; d.lastFocused = Date.timeIntervalSinceReferenceDate
                handles[index] = WindowHandle(descriptor: d, ax: old.ax, icon: old.icon, tab: old.tab)
            }
            handles.sort { a, b in
                if a.descriptor.windowless != b.descriptor.windowless { return !a.descriptor.windowless }
                if a.id == front { return b.id != front }
                if b.id == front { return false }
                let ah = a.descriptor.lastFocused, bh = b.descriptor.lastFocused
                if ah != bh { return ah > bh }
                let ai = a.descriptor.windowID.flatMap { cgOrder[$0] } ?? Int.max
                let bi = b.descriptor.windowID.flatMap { cgOrder[$0] } ?? Int.max
                if ai != bi { return ai < bi }
                return a.id < b.id
            }
            let result = handles
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let ids = Set(result.map(\.id))
                self.firstSeen = self.firstSeen.filter { ids.contains($0.key) }
                for handle in result where self.firstSeen[handle.id] == nil { self.firstSeen[handle.id] = handle.descriptor.created }
                self.windows = result
                self.suppressedSurfaceCount = suppressedSurfaces; self.unavailableWindowListCount = unavailableWindowLists
                self.watchApplications()
                let validIDs = Set(result.map(\.id))
                self.focusHistory = self.focusHistory.filter { validIDs.contains($0.key) || !$0.key.hasPrefix("cg:") }
                for handle in result {
                    if let ax = handle.ax { self.watchWindow(ax, pid: handle.descriptor.pid) }
                }
                for pid in Array(self.watchedWindows.keys) {
                    let valid = result.filter { $0.descriptor.pid == pid }.compactMap(\.ax)
                    guard let observer = self.axObservers[pid] else { continue }
                    let removed = (self.watchedWindows[pid] ?? []).filter { window in !valid.contains(where: { CFEqual($0, window) }) }
                    for window in removed {
                        for name in Self.windowNotifications { _ = AXObserverRemoveNotification(observer, window, name as CFString) }
                    }
                    self.watchedWindows[pid]?.removeAll { window in removed.contains(where: { CFEqual($0, window) }) }
                }
                RuntimeDiagnostics.shared.record("enumeration", since: start)
                let callbacks = self.refreshRequests.finish(upTo: request)
                self.refreshing = false
                callbacks.forEach { $0(result) }
                if !self.refreshing, let next = self.refreshRequests.latestPending {
                    self.enumerate(frontPID: self.queuedFrontPID, request: next)
                }
            }
        }
    }
    private static func matchScore(_ cg: CGEntry, title: String, frame: CGRect) -> Double {
        let delta = abs(cg.frame.minX - frame.minX) + abs(cg.frame.minY - frame.minY) + abs(cg.frame.width - frame.width) + abs(cg.frame.height - frame.height)
        return Double(delta) + ((!title.isEmpty && !cg.title.isEmpty && cg.title != title) ? 1000 : 0)
    }
    func markFocused(_ handle: WindowHandle) {
        let key = handle.id
        focusHistory[key] = Date.timeIntervalSinceReferenceDate; lastTracked = key
    }
}

private extension CGRect { var area: CGFloat { isNull ? 0 : max(0, width) * max(0, height) } }

final class PreviewCapture {
    private struct Job { let generation: Int; let windowID: UInt32; let full: Bool }
    private var generation = 0
    /// Shareable windows are reused for a short while: listing them costs tens of milliseconds each time.
    private var shareable: [UInt32: SCWindow] = [:]
    private var shareableFetchedAt: TimeInterval = -1_000
    private var fetchingShareable = false
    private var handles: [UInt32: WindowHandle] = [:]
    private var queue = PreviewRequestQueue<UInt32>()
    private var pendingFull: UInt32?
    // Physical captures survive cancellation until their callbacks return.
    private var inFlight: [UUID: Job] = [:]
    private var receive: ((String, NSImage) -> Void)?
    /// Full-resolution frames for the large preview. They bypass the thumbnail cache budget.
    var receiveFull: ((String, NSImage) -> Void)?
    /// Pixel width of thumbnail captures, from the card size and the display's backing scale.
    var thumbnailPixelWidth = 640
    var activeCount: Int { inFlight.count }
    var queuedCount: Int { queue.keys.count + (pendingFull == nil ? 0 : 1) }
    func cancel() {
        generation += 1; queue.removeAll(); handles.removeAll(); pendingFull = nil; receive = nil
    }
    func prepare(_ entries: [WindowHandle], prioritized: [String], receive: @escaping (String, NSImage) -> Void) {
        cancel()
        guard CGPreflightScreenCaptureAccess() else { return }
        self.receive = receive
        handles = Dictionary(entries.compactMap { entry in
            entry.descriptor.windowID.map { ($0, entry) }
        }, uniquingKeysWith: { first, _ in first })
        // Selection is first; entries outside the viewport are captured only on demand.
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in prioritized { if let handle = byID[id] { request(handle, urgent: false) } }
        refreshShareable(force: false)
    }
    /// `full` asks for a frame at the window's real pixel size, used by the large preview.
    func request(_ handle: WindowHandle, urgent: Bool = true, full: Bool = false) {
        guard receive != nil, let id = handle.descriptor.windowID, !handle.descriptor.minimized,
              !inFlight.values.contains(where: { $0.generation == generation && $0.windowID == id && $0.full == full }) else { return }
        handles[id] = handle
        if full { pendingFull = id } else { queue.enqueue(id, urgent: urgent) }
        pump()
    }
    private func refreshShareable(force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if !force && !shareable.isEmpty && now - shareableFetchedAt < 2.5 { pump(); return }
        guard !fetchingShareable else { return }
        fetchingShareable = true
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { [weak self] content, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.fetchingShareable = false
                if let content {
                    self.shareable = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
                    self.shareableFetchedAt = ProcessInfo.processInfo.systemUptime
                }
                self.pump()
            }
        }
    }
    private func pump() {
        guard !shareable.isEmpty, receive != nil else { return }
        var missing: [UInt32] = []
        var missingFull: UInt32?
        if let id = pendingFull, inFlight.count < 2, !inFlight.values.contains(where: { $0.windowID == id && $0.full }) {
            pendingFull = nil
            if let handle = handles[id], let window = shareable[id] { start(handle, window: window, full: true) }
            else if handles[id] != nil { missingFull = id }
        }
        while inFlight.count < 2 {
            let blocked = Set(inFlight.values.map(\.windowID))
            guard let id = queue.pop(excluding: blocked) else { break }
            guard let handle = handles[id], !handle.descriptor.minimized else { continue }
            guard let window = shareable[id] else { missing.append(id); continue }
            start(handle, window: window, full: false)
        }
        // A window opened after the last listing is not shareable yet: list once more, then retry it.
        if (!missing.isEmpty || missingFull != nil) && ProcessInfo.processInfo.systemUptime - shareableFetchedAt > 1 {
            for id in missing { queue.enqueue(id, urgent: false) }
            if let missingFull { pendingFull = missingFull }
            refreshShareable(force: true)
        }
    }
    private func start(_ handle: WindowHandle, window: SCWindow, full: Bool) {
        let id = window.windowID
        let token = UUID(), request = generation, startTime = ProcessInfo.processInfo.systemUptime
        inFlight[token] = Job(generation: request, windowID: id, full: full)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        if full {
            // Real pixel size, with the longer side capped so a single frame stays a few tens of MiB at most.
            let scale = max(1, Double(filter.pointPixelScale))
            var width = max(320, Double(window.frame.width) * scale), height = max(200, Double(window.frame.height) * scale)
            let shrink = min(1, 3200 / max(width, height))
            width *= shrink; height *= shrink
            configuration.width = Int(width); configuration.height = Int(height)
        } else {
            let width = min(1280, max(320, thumbnailPixelWidth))
            configuration.width = width
            configuration.height = max(120, min(width * 4 / 3, Int(Double(width) / max(0.3, handle.descriptor.aspectRatio))))
        }
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { [weak self] image, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.removeValue(forKey: token)
                if request == self.generation, let image {
                    RuntimeDiagnostics.shared.record(full ? "capture_full" : "capture", since: startTime)
                    let picture = NSImage(cgImage: image, size: .zero)
                    if full { self.receiveFull?(handle.id, picture) } else { self.receive?(handle.id, picture) }
                }
                self.pump()
            }
        }
    }
}

enum WindowAction { case focus, close, minimize, fullscreen, quitApp, hideApp, tileLeft, tileRight, maximize, nextScreen }
enum WindowControl {
    /// 设置 › 通用 › 切换窗口的方式. The window-server path falls back automatically when unavailable.
    static var preferWindowServer = true
    static func element(for handle: WindowHandle) -> AXUIElement? {
        if let ax = handle.ax { return ax }
        let app = AXUIElementCreateApplication(handle.descriptor.pid); AXUIElementSetMessagingTimeout(app, 0.2)
        let windows = axAttribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        if let id = handle.descriptor.windowID, let match = windows.first(where: { NativeBridge.windowID($0) == id }) { return match }
        let matches = windows.filter { (axAttribute($0, kAXTitleAttribute) as? String) == handle.descriptor.title }
        return matches.count == 1 ? matches[0] : nil
    }
    static func perform(_ action: WindowAction, on handle: WindowHandle) -> String? {
        guard let app = NSRunningApplication(processIdentifier: handle.descriptor.pid) else { return "这个窗口已经关闭。" }
        if action == .quitApp { return app.terminate() ? nil : "应用未接受退出请求，请在应用中确认未保存的内容。" }
        if action == .hideApp { return (app.isHidden ? app.unhide() : app.hide()) ? nil : "应用没有接受隐藏或显示请求。" }
        if let browserTab = handle.browserTab {
            guard action == .focus else { return "浏览器标签页请先切换过去，再在浏览器里操作。" }
            app.unhide()
            BrowserTabs.activate(browserTab)
            return nil
        }
        guard AXIsProcessTrusted() else { return "请先为“一瞥”开启辅助功能权限。" }
        let ax = element(for: handle)
        if let ax { AXUIElementSetMessagingTimeout(ax, 0.15) }
        if action == .focus {
            // Reject an unbound surface before yielding key focus to another application.
            if !handle.descriptor.windowless && ax == nil { return "这个窗口已关闭或暂时不可切换，请重新选择。" }
            app.unhide()
            if handle.descriptor.windowless, let url = app.bundleURL {
                NSApp.yieldActivation(to: app)
                return NSWorkspace.shared.open(url) ? nil : "暂时无法重新打开这个应用。"
            }
            if let tab = handle.tab {
                AXUIElementSetMessagingTimeout(tab, 0.15)
                if AXUIElementPerformAction(tab, kAXPressAction as CFString) != .success { return "这个标签页已变化，请重新打开切换面板。" }
            }
            if let ax, (axAttribute(ax, kAXMinimizedAttribute) as? NSNumber)?.boolValue == true,
               AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse) != .success {
                return "这个窗口暂时无法还原。"
            }
            if preferWindowServer, let windowID = handle.descriptor.windowID,
               NativeBridge.frontWindow(pid: handle.descriptor.pid, windowID: windowID) {
                // Raise within the app's own window stack; the window server already made it front and key.
                if let ax { _ = AXUIElementPerformAction(ax, kAXRaiseAction as CFString) }
                return nil
            }
            NSApp.yieldActivation(to: app)
            if let ax {
                let appAX = AXUIElementCreateApplication(handle.descriptor.pid)
                AXUIElementSetMessagingTimeout(appAX, 0.15)
                AXUIElementSetAttributeValue(appAX, kAXFocusedWindowAttribute as CFString, ax)
                AXUIElementSetAttributeValue(ax, kAXMainAttribute as CFString, kCFBooleanTrue)
                let result = AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
                if result != .success && !handle.descriptor.windowless { return "应用暂时无法切换到这个窗口（\(result.rawValue)）。" }
            }
            guard app.activate(options: []) else { return "应用没有接受切换请求，请重试。" }
            if let ax { AXUIElementPerformAction(ax, kAXRaiseAction as CFString) }
            return nil
        }
        guard let ax else { return "该应用没有提供此窗口的控制接口。" }
        let result: AXError
        switch action {
        case .focus: return nil
        case .close:
            if handle.tab != nil { return "请先切换到这个标签页，再在应用中关闭。" }
            guard let button = axAttribute(ax, kAXCloseButtonAttribute), CFGetTypeID(button) == AXUIElementGetTypeID() else { return "该窗口没有关闭按钮。" }
            AXUIElementSetMessagingTimeout(button as! AXUIElement, 0.15)
            result = AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        case .minimize:
            let minimized = (axAttribute(ax, kAXMinimizedAttribute) as? NSNumber)?.boolValue ?? false
            result = AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, minimized ? kCFBooleanFalse : kCFBooleanTrue)
        case .fullscreen:
            let full = (axAttribute(ax, "AXFullScreen") as? NSNumber)?.boolValue ?? false
            result = AXUIElementSetAttributeValue(ax, "AXFullScreen" as CFString, full ? kCFBooleanFalse : kCFBooleanTrue)
        case .quitApp, .hideApp: return nil
        case .tileLeft: return arrange(ax, .left)
        case .tileRight: return arrange(ax, .right)
        case .maximize: return arrange(ax, .maximize)
        case .nextScreen: return arrange(ax, .nextScreen)
        }
        return result == .success ? nil : "该应用暂不支持这个窗口操作（\(result.rawValue)）。"
    }
    /// Screen areas below the menu bar and beside the Dock, in the same top-left coordinates the
    /// accessibility interface uses for window positions.
    static func screenAreas() -> [WindowRect] {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return [] }
        return NSScreen.screens.map { screen in
            let area = screen.visibleFrame
            return WindowRect(x: Double(area.minX), y: Double(primaryHeight - area.maxY), width: Double(area.width), height: Double(area.height))
        }
    }
    private static func arrange(_ ax: AXUIElement, _ kind: WindowArrangement.Kind) -> String? {
        if (axAttribute(ax, "AXFullScreen") as? NSNumber)?.boolValue == true { return "全屏窗口不能调整位置，请先退出全屏。" }
        guard let frame = axFrame(ax) else { return "暂时读不到这个窗口的位置。" }
        let current = WindowRect(x: Double(frame.minX), y: Double(frame.minY), width: Double(frame.width), height: Double(frame.height))
        guard let target = WindowArrangement.frame(kind, window: current, screens: screenAreas()) else {
            return kind == .nextScreen ? "只有一块屏幕，无法移到下一块屏幕。" : "没有找到可用的屏幕。"
        }
        var origin = CGPoint(x: target.x, y: target.y)
        var size = CGSize(width: target.width, height: target.height)
        guard let position = AXValueCreate(.cgPoint, &origin), let dimension = AXValueCreate(.cgSize, &size) else { return "无法设置窗口位置。" }
        // Move first so the new size fits the destination screen, then size, then move again for apps that clamp.
        let moved = AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, position)
        let sized = AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString, dimension)
        _ = AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, position)
        return moved == .success || sized == .success ? nil : "该应用不允许调整这个窗口（\(sized.rawValue)）。"
    }
}
