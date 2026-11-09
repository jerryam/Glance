import AppKit
import ApplicationServices

// MARK: - Dock badges

/// Reads the unread counts the Dock shows on app icons (Mail, WeChat, …) through accessibility.
enum DockBadges {
    /// App bundle path → badge text. Call off the main thread: it talks to the Dock process.
    static func read() -> [String: String] {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [:] }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let children = axAttribute(app, kAXChildrenAttribute) as? [AXUIElement],
              let list = children.first(where: { (axAttribute($0, kAXRoleAttribute) as? String) == (kAXListRole as String) }),
              let items = axAttribute(list, kAXChildrenAttribute) as? [AXUIElement] else { return [:] }
        var result: [String: String] = [:]
        for item in items {
            AXUIElementSetMessagingTimeout(item, 0.1)
            guard (axAttribute(item, kAXSubroleAttribute) as? String) == "AXApplicationDockItem",
                  let label = axAttribute(item, "AXStatusLabel") as? String, !label.isEmpty,
                  let url = axAttribute(item, kAXURLAttribute) as? URL else { continue }
            result[url.standardizedFileURL.path] = label
        }
        return result
    }
}

// MARK: - Full-screen front app

/// Watches whether the front app has taken over the screen, so background work can stop while a game runs. It looks
/// when the front app or Space changes; then every two seconds while the screen is taken over, and otherwise only as
/// the pointer moves, so in normal use it never wakes 一瞥 by itself.
final class FrontFullscreenWatch {
    private(set) var active = false
    var onChange: (() -> Void)?
    private static let interval: TimeInterval = 2
    private let queue = DispatchQueue(label: "Glance.frontFullscreen", qos: .utility)
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var looking = false
    private var lookedAt: TimeInterval = -1_000

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.look()
                // A game usually takes over the screen a moment after it comes to the front.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.look() }
            })
        }
    }
    deinit {
        timer?.invalidate()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }
    func lookIfDue() {
        if ProcessInfo.processInfo.systemUptime - lookedAt >= Self.interval { look() }
    }
    func look() {
        guard !looking else { return }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { apply(false); return }
        looking = true
        lookedAt = ProcessInfo.processInfo.systemUptime
        let pid = app.processIdentifier
        // Each signal misses some games, so any one of them counts.
        let options = NSApp.currentSystemPresentationOptions
        let menuBarHidden = options.contains(.fullScreen) || options.contains(.hideMenuBar)
        queue.async {
            let value = FrontFullscreenPolicy.isActive(windowFullscreen: Self.focusedWindowIsFullscreen(pid), menuBarHidden: menuBarHidden,
                                                       frontWindows: Self.windows(of: pid), displays: Self.displays())
            DispatchQueue.main.async { [weak self] in
                self?.looking = false
                self?.apply(value)
            }
        }
    }
    private func apply(_ value: Bool) {
        if !value { timer?.invalidate(); timer = nil }
        else if timer == nil {
            let repeating = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.look() }
            repeating.tolerance = 0.5
            RunLoop.main.add(repeating, forMode: .common)
            timer = repeating
        }
        guard value != active else { return }
        active = value
        onChange?()
    }
    private static func focusedWindowIsFullscreen(_ pid: Int32) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        guard let focused = axAttribute(app, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        AXUIElementSetMessagingTimeout(focused as! AXUIElement, 0.1)
        return (axAttribute(focused as! AXUIElement, "AXFullScreen") as? NSNumber)?.boolValue == true
    }
    private static func windows(of pid: Int32) -> [(layer: Int, frame: WindowRect)] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { window -> (layer: Int, frame: WindowRect)? in
            guard window[kCGWindowOwnerPID as String] as? Int32 == pid, let layer = window[kCGWindowLayer as String] as? Int,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return (layer: layer, frame: WindowRect(x: Double(rect.minX), y: Double(rect.minY), width: Double(rect.width), height: Double(rect.height)))
        }
    }
    private static func displays() -> [WindowRect] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16), count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { id in
            let rect = CGDisplayBounds(id)
            return WindowRect(x: Double(rect.minX), y: Double(rect.minY), width: Double(rect.width), height: Double(rect.height))
        }
    }
}

// MARK: - Browser tabs

struct BrowserTabRef {
    let bundleID: String
    let windowID: Int
    /// 1-based, as the browsers' scripting interfaces count tabs.
    let tabIndex: Int
    let chromium: Bool
    /// What the tab showed when it was listed, to tell whether it is still at that position.
    let url: String
    let title: String
}

/// Lists and activates Safari / Chromium tabs through Automation (osascript, JavaScript flavour).
/// Only runs when 设置 › 通用 › 浏览器标签页 is on; macOS asks once per browser for permission.
enum BrowserTabs {
    private struct Browser { let bundleID: String; let chromium: Bool }
    private static let browsers = [Browser(bundleID: "com.apple.Safari", chromium: false),
                                   Browser(bundleID: "com.google.Chrome", chromium: true),
                                   Browser(bundleID: "com.microsoft.edgemac", chromium: true),
                                   Browser(bundleID: "com.brave.Browser", chromium: true),
                                   Browser(bundleID: "com.vivaldi.Vivaldi", chromium: true)]
    private static let queue = DispatchQueue(label: "Glance.browserTabs", qos: .userInitiated, attributes: .concurrent)
    private struct WindowTabs: Decodable { let id: Int; let active: Int; let titles: [String?]; let urls: [String?] }
    private struct RunningBrowser {
        let browser: Browser; let pid: Int32; let name: String; let hidden: Bool; let icon: NSImage?
        /// A relaunched browser is a new key: tabs found in its old process cannot be switched to.
        var key: String { "\(browser.bundleID)|\(pid)" }
    }
    private static var running: [RunningBrowser] {
        browsers.compactMap { browser -> RunningBrowser? in
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID).first(where: { !$0.isTerminated }) else { return nil }
            return RunningBrowser(browser: browser, pid: app.processIdentifier, name: app.localizedName ?? browser.bundleID, hidden: app.isHidden, icon: app.icon)
        }
    }
    /// Which browsers are running now, always in the same order, under the keys `list` answers with.
    static var runningKeys: [String] { running.map(\.key) }

    /// Asks every running browser at once and delivers each answer on the main queue as it arrives: nil when that
    /// browser did not answer. The active tab of each window is left out because the window itself is already listed.
    static func list(_ answer: @escaping (_ browser: String, _ tabs: [WindowHandle]?) -> Void) {
        // Never address a browser that is not running: scripting it would launch it.
        for item in running {
            queue.async {
                let tabs = tabs(of: item)
                DispatchQueue.main.async { answer(item.key, tabs) }
            }
        }
    }
    private static func tabs(of item: RunningBrowser) -> [WindowHandle]? {
        guard let output = runScript(listScript(item.browser)), let data = output.data(using: .utf8),
              let windows = try? JSONDecoder().decode([WindowTabs].self, from: data) else { return nil }
        var handles: [WindowHandle] = []
        for window in windows {
            for (offset, title) in window.titles.enumerated() where offset + 1 != window.active {
                let address = offset < window.urls.count ? (window.urls[offset] ?? "") : ""
                var descriptor = WindowDescriptor(id: "tab:\(item.browser.bundleID):\(window.id):\(offset + 1)", windowID: nil, pid: item.pid,
                                                  appName: item.name, bundleID: item.browser.bundleID,
                                                  title: (title ?? "").isEmpty ? address : (title ?? ""), minimized: false, hidden: item.hidden,
                                                  onCurrentSpace: true, displayID: nil, aspectRatio: 1.6)
                descriptor.browserTab = true
                descriptor.subtitle = URL(string: address)?.host ?? address
                let reference = BrowserTabRef(bundleID: item.browser.bundleID, windowID: window.id, tabIndex: offset + 1, chromium: item.browser.chromium,
                                              url: address, title: title ?? "")
                handles.append(WindowHandle(descriptor: descriptor, ax: nil, icon: item.icon, browserTab: reference))
            }
        }
        return handles
    }
    /// Tabs may have moved since they were listed: the listed position counts only if it still shows that
    /// address, then the address is looked up, then the title. Reports on the main queue whether the tab is in front.
    static func activate(_ tab: BrowserTabRef, completion: @escaping (Bool) -> Void) {
        // Integers go into the script as they are; a tab's address and title only as JSON strings.
        guard let url = BrowserTabScript.literal(tab.url), let title = BrowserTabScript.literal(tab.title) else { completion(false); return }
        let titles = tab.chromium ? "w.tabs.title()" : "w.tabs.name()"
        let select = tab.chromium ? "w.activeTabIndex = index + 1;" : "w.currentTab = w.tabs[index];"
        let script = """
        (() => {
          const app = Application('\(tab.bundleID)');
          const w = app.windows.byId(\(tab.windowID));
          const urls = w.tabs.url().map(u => u || '');
          let index = \(tab.tabIndex - 1);
          if (urls[index] !== \(url)) {
            index = urls.indexOf(\(url));
            if (index < 0 && \(title) !== '') index = \(titles).indexOf(\(title));
            if (index < 0) return 'gone';
          }
          \(select)
          w.index = 1;
          app.activate();
          return 'ok';
        })()
        """
        queue.async {
            let answer = runScript(script, timeout: 5)
            DispatchQueue.main.async { completion(answer == "ok") }
        }
    }
    private static func listScript(_ browser: Browser) -> String {
        let active = browser.chromium ? "w.activeTabIndex()" : "w.currentTab.index()"
        let titles = browser.chromium ? "w.tabs.title()" : "w.tabs.name()"
        return """
        (() => {
          const app = Application('\(browser.bundleID)');
          const out = [];
          for (const w of app.windows()) {
            try { out.push({ id: w.id(), active: \(active), titles: \(titles), urls: w.tabs.url() }); } catch (e) {}
          }
          return JSON.stringify(out);
        })()
        """
    }
    /// Runs a JavaScript for Automation snippet in a child process, so a slow or blocked browser never
    /// stalls 一瞥. The first run per browser waits for the user's permission answer.
    private static func runScript(_ script: String, timeout: TimeInterval = 12) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Trackpad gesture conflicts

/// The system recognises its own swipes before any app sees them, so 一瞥 cannot reliably block them.
/// Like AltTab, it points out a conflicting system gesture and links to Trackpad settings instead.
enum GestureConflict {
    private static let domains = ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"]
    private static func value(_ key: String) -> Int? {
        domains.compactMap { (CFPreferencesCopyAppValue(key as CFString, $0 as CFString) as? NSNumber)?.intValue }.max()
    }
    /// Best effort, from the preferences the system writes; nil when no conflict is known.
    static func warning(for choice: GestureChoice) -> String? {
        var notes: [String] = []
        switch choice {
        case .disabled: return nil
        case .threeHorizontal:
            if value("TrackpadThreeFingerHorizSwipeGesture") == 2 { notes.append("系统已把三指左右轻扫用于在全屏幕应用之间切换") }
        case .fourHorizontal:
            if value("TrackpadFourFingerHorizSwipeGesture") == 2 { notes.append("系统已把四指左右轻扫用于在全屏幕应用之间切换") }
        case .threeVertical:
            if value("TrackpadThreeFingerVertSwipeGesture") == 2 { notes.append("系统已把三指上下轻扫用于调度中心和应用 Exposé") }
        case .fourVertical:
            if value("TrackpadFourFingerVertSwipeGesture") == 2 { notes.append("系统已把四指上下轻扫用于调度中心和应用 Exposé") }
        }
        if choice.fingers == 3, value("TrackpadThreeFingerDrag") == 1 { notes.append("辅助功能中的三指拖移已开启") }
        return notes.isEmpty ? nil : notes.joined(separator: "；") + "。请在触控板设置中改用其他手指数或关闭对应手势。"
    }
    static func openTrackpadSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension"), NSWorkspace.shared.open(url) { return }
        _ = NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Trackpad.prefPane"))
    }
}

// MARK: - First-run guide

/// Remembers whether the switcher has been opened at least once, for the guide on the permissions page.
final class OnboardingProgress: ObservableObject {
    static let shared = OnboardingProgress()
    private static let key = "WindowHop.onboarding.tried"
    @Published private(set) var tried = UserDefaults.standard.bool(forKey: OnboardingProgress.key)
    func markTried() {
        guard !tried else { return }
        tried = true
        UserDefaults.standard.set(true, forKey: Self.key)
    }
}
