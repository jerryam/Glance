import Foundation

protocol NamedPreference: RawRepresentable, Codable, CaseIterable, Identifiable, Hashable where RawValue == String {
    var label: String { get }
}
extension NamedPreference { var id: String { rawValue } }

enum VisibilityPolicy: String, NamedPreference {
    case show, hide, atEnd
    var label: String { switch self { case .show: return "显示"; case .hide: return "隐藏"; case .atEnd: return "放在末尾" } }
}
enum ReleaseBehavior: String, NamedPreference {
    case focus, hold, search
    var label: String { switch self { case .focus: return "切换窗口"; case .hold: return "保持打开"; case .search: return "进入搜索" } }
}
enum SpaceScope: String, NamedPreference {
    case all, visible, other
    var label: String { switch self { case .all: return "所有桌面"; case .visible: return "当前桌面"; case .other: return "其他桌面" } }
}
enum WindowOrder: String, NamedPreference {
    case recent, created, alphabetical, space
    var label: String { switch self { case .recent: return "最近使用"; case .created: return "最近创建"; case .alphabetical: return "名称顺序"; case .space: return "桌面顺序" } }
}
enum WindowGrouping: String, NamedPreference {
    case all, onePerApp, byApp
    var label: String {
        switch self {
        case .all: return "所有窗口"
        case .onePerApp: return "每个应用一个窗口"
        case .byApp: return "按应用合成一组（↓ 展开）"
        }
    }
}
enum FocusMethod: String, NamedPreference {
    case windowServer, accessibility
    var label: String { self == .windowServer ? "系统窗口服务（推荐）" : "辅助功能接口（旧方式）" }
}
enum TitleDisplay: String, NamedPreference {
    case window, app, both
    var label: String { switch self { case .window: return "窗口标题"; case .app: return "应用名称"; case .both: return "应用名称与窗口标题" } }
    func text(_ window: WindowDescriptor) -> String {
        switch self {
        case .window: return window.displayTitle
        case .app: return window.appName
        case .both: return window.title.isEmpty ? window.appName : "\(window.appName) — \(window.title)"
        }
    }
}
enum TitleCut: String, NamedPreference {
    case start, middle, end
    var label: String { switch self { case .start: return "开头"; case .middle: return "中间"; case .end: return "末尾" } }
}
enum PanelScreen: String, NamedPreference {
    case active, mouse, menuBar
    var label: String { switch self { case .active: return "活动窗口所在屏幕"; case .mouse: return "鼠标所在屏幕"; case .menuBar: return "菜单栏所在屏幕" } }
}
enum FollowCursor: String, NamedPreference {
    case never, always, differentScreen
    var label: String { switch self { case .never: return "不移动"; case .always: return "总是跟随"; case .differentScreen: return "仅跨屏幕时跟随" } }
}
enum GestureChoice: String, NamedPreference {
    case disabled, threeHorizontal, threeVertical, fourHorizontal, fourVertical
    var label: String {
        switch self {
        case .disabled: return "关闭"
        case .threeHorizontal: return "三指水平滑动"
        case .threeVertical: return "三指垂直滑动"
        case .fourHorizontal: return "四指水平滑动"
        case .fourVertical: return "四指垂直滑动"
        }
    }
    var fingers: Int { self == .threeHorizontal || self == .threeVertical ? 3 : 4 }
    var horizontal: Bool { self == .threeHorizontal || self == .fourHorizontal }
}
enum MenuIconChoice: String, NamedPreference {
    case outline, filled, colored
    var label: String { switch self { case .outline: return "线条"; case .filled: return "实心"; case .colored: return "彩色" } }
}
enum ExceptionHide: String, NamedPreference {
    case never, always, windowless, title
    var label: String { switch self { case .never: return "不隐藏"; case .always: return "始终隐藏"; case .windowless: return "没有窗口时隐藏"; case .title: return "标题匹配时隐藏" } }
}
enum ExceptionIgnore: String, NamedPreference {
    case never, always, fullscreen
    var label: String { switch self { case .never: return "始终响应"; case .always: return "不响应"; case .fullscreen: return "全屏时不响应" } }
}
enum PanelInputMode: String, NamedPreference {
    case search, traditional
    var label: String { self == .search ? "直接输入搜索" : "传统单键操作" }
}
struct AppException: Codable, Equatable, Identifiable {
    var id = UUID()
    var bundleID = ""
    var name = ""
    var hide: ExceptionHide = .never
    var ignore: ExceptionIgnore = .never
    var titles = ""
    func matches(bundle: String) -> Bool {
        let pattern = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !pattern.isEmpty else { return false }
        return pattern.hasSuffix("*") ? bundle.lowercased().hasPrefix(String(pattern.dropLast())) : pattern == bundle.lowercased()
    }
    func hides(_ window: WindowDescriptor) -> Bool {
        guard matches(bundle: window.bundleID) else { return false }
        switch hide {
        case .never: return false
        case .always: return true
        case .windowless: return window.windowless
        case .title:
            return titles.components(separatedBy: .newlines).contains {
                let token = WindowSearch.normalized($0.trimmingCharacters(in: .whitespaces))
                return !token.isEmpty && WindowSearch.normalized(window.title).contains(token)
            }
        }
    }
    func ignores(bundle: String, fullscreen: Bool) -> Bool {
        matches(bundle: bundle) && (ignore == .always || (ignore == .fullscreen && fullscreen))
    }
    static var defaults: [AppException] {
        var finder = AppException(); finder.bundleID = "com.apple.finder"; finder.name = "访达"; finder.hide = .windowless
        let remote = ["com.apple.ScreenSharing", "com.microsoft.rdc.macos", "com.teamviewer.TeamViewer",
                      "com.vmware.fusion", "com.utmapp.UTM", "com.parallels.*", "org.virtualbox.app.VirtualBoxVM"]
        return [finder, uuRemote] + remote.map { bundle in var r = AppException(); r.bundleID = bundle; r.ignore = .fullscreen; return r }
    }
    static var uuRemote: AppException {
        var rule = AppException(); rule.bundleID = "com.netease.uuremote"; rule.name = "UU 远程"; rule.ignore = .fullscreen
        return rule
    }
}
enum PanelCommand: String, CaseIterable, Identifiable, Codable {
    case confirm, cancel, next, previous, search, close, minimize, fullscreen, quitApp, hideApp, preview
    case tileLeft, tileRight, maximize, nextScreen, togglePin
    var id: String { rawValue }
    var label: String {
        switch self {
        case .confirm: return "切换窗口"; case .cancel: return "取消"; case .search: return "搜索"
        case .next: return "下一个窗口"; case .previous: return "上一个窗口"
        case .close: return "关闭窗口"; case .minimize: return "最小化 / 还原"; case .fullscreen: return "全屏 / 退出"
        case .quitApp: return "退出应用"; case .hideApp: return "隐藏 / 显示应用"; case .preview: return "大图预览"
        case .tileLeft: return "放到左半屏"; case .tileRight: return "放到右半屏"; case .maximize: return "填满屏幕"
        case .nextScreen: return "移到下一块屏幕"; case .togglePin: return "置顶 / 取消置顶"
        }
    }
    var defaultCode: UInt32 {
        switch self { case .confirm: return 36; case .cancel: return 53; case .next, .previous: return 48; case .search: return 1; case .close: return 13
        case .minimize: return 46; case .fullscreen: return 3; case .quitApp: return 12; case .hideApp: return 4; case .preview: return 49
        case .tileLeft: return 123; case .tileRight: return 124; case .maximize: return 126; case .nextScreen: return 125; case .togglePin: return 35 }
    }
    var defaultModifiers: ShortcutModifiers {
        switch self {
        case .previous: return .shift
        case .tileLeft, .tileRight, .maximize, .nextScreen: return [.control, .command]
        case .togglePin: return .command
        default: return []
        }
    }
}
struct PanelBinding: Codable, Equatable, Identifiable {
    let command: PanelCommand
    var keyCode: UInt32
    var modifiers: ShortcutModifiers = []
    var enabled = true
    var id: String { command.rawValue }
    var isSupported: Bool {
        KeyChoice.isSupportedKey(keyCode) && modifiers.rawValue < 16 && (keyCode != KeyChoice.modifierOnly || !modifiers.isEmpty)
    }
    static var defaults: [PanelBinding] { PanelCommand.allCases.map { .init(command: $0, keyCode: $0.defaultCode, modifiers: $0.defaultModifiers) } }
}
/// 设置 › 鼠标与触控板 › Dock 预览: an app's windows above its Dock icon, like the Windows taskbar.
struct DockPreviewSettings: Codable, Equatable {
    var enabled = true
    /// Milliseconds the pointer rests on an icon before the preview opens.
    var delay = 300
    var includeMinimized = true
    /// New pictures while the panel is open. Off until asked for, like the next one: 2.5.0 added both without a run
    /// on a real Mac.
    var liveThumbnails = false
    /// Resting on a card shows that window's picture at the window's own place.
    var peekWindow = false
    static let delayRange = 0...1000
    init() {}
    private enum CodingKeys: String, CodingKey { case enabled, delay, includeMinimized, liveThumbnails, peekWindow }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        delay = try c.decodeIfPresent(Int.self, forKey: .delay) ?? 300
        includeMinimized = try c.decodeIfPresent(Bool.self, forKey: .includeMinimized) ?? true
        liveThumbnails = try c.decodeIfPresent(Bool.self, forKey: .liveThumbnails) ?? false
        peekWindow = try c.decodeIfPresent(Bool.self, forKey: .peekWindow) ?? false
    }
}

/// 设置 › 搜索与按键 › 全局窗口快捷键: what a shortcut does to the window in front, without opening the panel.
enum WindowLayoutCommand: String, CaseIterable, Identifiable, Codable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case leftThird, centerThird, rightThird
    // Added last: a command's place in this list is its hotkey slot, so the others keep theirs.
    case maximize, center, restore, nextScreen
    var id: String { rawValue }
    var label: String {
        switch self {
        case .leftHalf: return "左半屏"; case .rightHalf: return "右半屏"; case .topHalf: return "上半屏"; case .bottomHalf: return "下半屏"
        case .topLeft: return "左上四分之一"; case .topRight: return "右上四分之一"
        case .bottomLeft: return "左下四分之一"; case .bottomRight: return "右下四分之一"
        case .leftThird: return "左三分之一"; case .centerThird: return "中间三分之一"; case .rightThird: return "右三分之一"
        case .maximize: return "填满屏幕"; case .center: return "居中"; case .restore: return "还原"
        case .nextScreen: return "移到下一块屏幕"
        }
    }
    /// nil for 还原, which goes back to a remembered place rather than to a place on the screen.
    var kind: WindowArrangement.Kind? {
        switch self {
        case .leftHalf: return .left; case .rightHalf: return .right; case .topHalf: return .top; case .bottomHalf: return .bottom
        case .topLeft: return .topLeft; case .topRight: return .topRight; case .bottomLeft: return .bottomLeft; case .bottomRight: return .bottomRight
        case .leftThird: return .leftThird; case .centerThird: return .centerThird; case .rightThird: return .rightThird
        case .maximize: return .maximize; case .center: return .center; case .restore: return nil
        case .nextScreen: return .nextScreen
        }
    }
    /// ⌃⌥ with the arrows for halves, U I J K for quarters, D F G for thirds, Return to fill, C to centre, Delete to restore.
    /// ⌃⌥⌘→ moves to the next screen, as in other window managers: ⌃⌥→ is already the right half.
    var defaultHotkey: MenuBarHotkey {
        let code: UInt32
        switch self {
        case .leftHalf: code = 123; case .rightHalf: code = 124; case .topHalf: code = 126; case .bottomHalf: code = 125
        case .topLeft: code = 32; case .topRight: code = 34; case .bottomLeft: code = 38; case .bottomRight: code = 40
        case .leftThird: code = 2; case .centerThird: code = 3; case .rightThird: code = 5
        case .maximize: code = 36; case .center: code = 8; case .restore: code = 51
        case .nextScreen: return MenuBarHotkey(keyCode: 124, modifiers: [.control, .option, .command], enabled: true)
        }
        return MenuBarHotkey(keyCode: code, modifiers: [.control, .option], enabled: true)
    }
    /// How the hotkey registry knows this command; the menu bar commands use the slots below these.
    static let firstSlot = 10
    var slot: Int { Self.firstSlot + (Self.allCases.firstIndex(of: self) ?? 0) }
    init?(slot: Int) {
        let index = slot - Self.firstSlot
        guard Self.allCases.indices.contains(index) else { return nil }
        self = Self.allCases[index]
    }
}
struct WindowShortcut: Codable, Equatable, Identifiable {
    let command: WindowLayoutCommand
    var hotkey: MenuBarHotkey
    var id: String { command.rawValue }
}
struct WindowShortcutSettings: Codable, Equatable {
    /// Off until asked for: turned on, it claims fifteen key combinations in every app.
    var enabled = false
    var shortcuts = WindowLayoutCommand.allCases.map { WindowShortcut(command: $0, hotkey: $0.defaultHotkey) }
    /// The shortcuts to register.
    var active: [WindowShortcut] { enabled ? shortcuts.filter { $0.hotkey.enabled } : [] }
    init() {}
    private enum CodingKeys: String, CodingKey { case enabled, shortcuts }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        var saved: [WindowLayoutCommand: WindowShortcut] = [:]
        // A shortcut for a command this version does not have is left out alone, and the others are kept.
        let listed = (try? c.decodeIfPresent([TolerantElement<WindowShortcut>].self, forKey: .shortcuts))?.compactMap { $0.value } ?? []
        for shortcut in listed where saved[shortcut.command] == nil {
            saved[shortcut.command] = shortcut
        }
        // One per command, in a fixed order. A command added later starts on its own key, unless that key is taken.
        let taken = Set(saved.values.filter { $0.hotkey.enabled }.map { $0.hotkey.combinationKey })
        shortcuts = WindowLayoutCommand.allCases.map { command in
            if let shortcut = saved[command] { return shortcut }
            var shortcut = WindowShortcut(command: command, hotkey: command.defaultHotkey)
            if taken.contains(shortcut.hotkey.combinationKey) { shortcut.hotkey.enabled = false }
            return shortcut
        }
    }
}

/// Where a web search goes. Choosing the row hands the address to the default browser; 一瞥 itself sends nothing.
enum WebSearchEngine: String, Codable, CaseIterable, Identifiable {
    case baidu, bing, google, duckDuckGo
    var id: String { rawValue }
    var label: String {
        switch self {
        case .baidu: return "百度"
        case .bing: return "必应"
        case .google: return "Google"
        case .duckDuckGo: return "DuckDuckGo"
        }
    }
    /// Everything but these is encoded: left as it is, + reads as a space and & or # would change the address.
    private static let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    func url(for query: String) -> URL? {
        guard let text = query.addingPercentEncoding(withAllowedCharacters: Self.plain) else { return nil }
        switch self {
        case .baidu: return URL(string: "https://www.baidu.com/s?wd=" + text)
        case .bing: return URL(string: "https://www.bing.com/search?q=" + text)
        case .google: return URL(string: "https://www.google.com/search?q=" + text)
        case .duckDuckGo: return URL(string: "https://duckduckgo.com/?q=" + text)
        }
    }
}

/// A web address typed into the search. Only http and https: a search result must never run a script or read a file.
enum WebAddress {
    private static let endings: Set<String> = ["com", "cn", "net", "org", "io", "edu", "gov"]
    static func url(from text: String) -> URL? {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, typed.count <= 2000, !typed.contains(where: { $0.isWhitespace }) else { return nil }
        let lower = typed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: typed), url.host?.isEmpty == false else { return nil }
            return url
        }
        guard !typed.contains(":") else { return nil }
        let host = String(typed.split(separator: "/", omittingEmptySubsequences: false).first ?? "").lowercased()
        let parts = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        // main.swift and report.pdf are names of files, and com.apple.mail is an identifier, not a place on the web.
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }),
              parts[0] == "www" || endings.contains(parts[parts.count - 1]) else { return nil }
        guard let url = URL(string: "https://\(typed)"), url.host?.isEmpty == false else { return nil }
        return url
    }
}

/// Double pinyin layouts the search understands.
enum ShuangpinScheme: String, Codable, CaseIterable, Identifiable {
    case off, xiaohe, ziranma, microsoft
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "不使用"
        case .xiaohe: return "小鹤"
        case .ziranma: return "自然码"
        case .microsoft: return "微软 / 搜狗"
        }
    }
}

/// One entry of a saved list. An entry this version cannot read, such as a command a later version added, is left
/// out alone: thrown, it would take the rest of the list and every other setting with it.
struct TolerantElement<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

struct AdvancedSettings: Codable, Equatable {
    var preferencesRevision = 3
    var inputMode: PanelInputMode = .search
    var searchRanking = true
    var searchTypos = true
    var searchLearning = true
    var searchSkips = true
    var shuangpin = ShuangpinScheme.off
    var searchCommands = true
    /// Off until asked for, like `searchWeb`: 2.5.0 added both without a run on a real Mac.
    var searchFiles = false
    var searchCalculator = true
    var searchWeb = false
    var webEngine = WebSearchEngine.baidu
    var showSearchHint = true
    var shiftSelectsPrevious = true
    var voiceOverKeepsOpen = true
    var gestureAvoidsSystem = false
    var independentGesture: ShortcutProfile? = nil
    var focusMethod: FocusMethod = .windowServer
    var commandLineEnabled = false
    var dockBadges = true
    var restartAfterCrash = true
    var browserTabs = false
    /// Apps that are not running, and System Settings pages, appear in search.
    var searchApps = true
    var searchSettingsPages = true
    var numberHints = true
    var titleDisplay: TitleDisplay = .window
    var titleCut: TitleCut = .end
    var panelScreen: PanelScreen = .active
    var followCursor: FollowCursor = .never
    var gesture: GestureChoice = .disabled
    var gestureProfile = 0
    var haptics = true
    var arrowKeys = true
    var vimKeys = false
    var autoPreview = false
    var backgroundPreviews = false
    var statusBadges = true
    var spaceNumbers = false
    var tileButtons = true
    var showMenuIcon = true
    var menuIcon: MenuIconChoice = .outline
    var showDelay = 100
    var fadeOut = false
    var previewFadeIn = true
    var bindings = PanelBinding.defaults
    var exceptions = AppException.defaults
    /// After the displays change, put back the saved layout made on displays like the ones there are now. Off
    /// until asked for: it moves windows without being told to each time.
    var restoreLayoutOnScreenChange = false
    init() {}
    private enum CodingKeys: String, CodingKey {
        case preferencesRevision, inputMode, searchRanking, searchTypos, searchLearning, searchSkips, shuangpin
        case searchCommands, searchFiles, searchCalculator, searchWeb, webEngine
        case showSearchHint, shiftSelectsPrevious, voiceOverKeepsOpen, gestureAvoidsSystem, independentGesture
        case focusMethod, commandLineEnabled, dockBadges, restartAfterCrash, browserTabs, searchApps, searchSettingsPages, numberHints
        case titleDisplay, titleCut, panelScreen, followCursor, gesture, gestureProfile, haptics, arrowKeys, vimKeys
        case autoPreview, backgroundPreviews, statusBadges, spaceNumbers, tileButtons, showMenuIcon, menuIcon
        case showDelay, fadeOut, previewFadeIn, bindings, exceptions, restoreLayoutOnScreenChange
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let revision = try c.decodeIfPresent(Int.self, forKey: .preferencesRevision) ?? 0
        preferencesRevision = max(3, revision)
        // Read with `try?`, here and below: a choice this version does not know, saved by a later one, falls back alone.
        inputMode = (try? c.decodeIfPresent(PanelInputMode.self, forKey: .inputMode)) ?? .search
        searchRanking = try c.decodeIfPresent(Bool.self, forKey: .searchRanking) ?? true
        searchTypos = try c.decodeIfPresent(Bool.self, forKey: .searchTypos) ?? true
        searchLearning = try c.decodeIfPresent(Bool.self, forKey: .searchLearning) ?? true
        searchSkips = try c.decodeIfPresent(Bool.self, forKey: .searchSkips) ?? true
        // A scheme or an engine this version does not know, from a later one, falls back alone: thrown, it would
        // take every other setting with it.
        shuangpin = (try? c.decodeIfPresent(ShuangpinScheme.self, forKey: .shuangpin)) ?? .off
        searchCommands = try c.decodeIfPresent(Bool.self, forKey: .searchCommands) ?? true
        searchFiles = try c.decodeIfPresent(Bool.self, forKey: .searchFiles) ?? false
        searchCalculator = try c.decodeIfPresent(Bool.self, forKey: .searchCalculator) ?? true
        searchWeb = try c.decodeIfPresent(Bool.self, forKey: .searchWeb) ?? false
        webEngine = (try? c.decodeIfPresent(WebSearchEngine.self, forKey: .webEngine)) ?? .baidu
        // The 2.5.0 test build, at revision 2, had both on from the start and saved them so: a saved "on" from then
        // is not a choice. From revision 3 they start off, and what was saved before is turned off with them.
        if revision < 3 { searchFiles = false; searchWeb = false }
        showSearchHint = try c.decodeIfPresent(Bool.self, forKey: .showSearchHint) ?? true
        shiftSelectsPrevious = try c.decodeIfPresent(Bool.self, forKey: .shiftSelectsPrevious) ?? true
        voiceOverKeepsOpen = try c.decodeIfPresent(Bool.self, forKey: .voiceOverKeepsOpen) ?? true
        gestureAvoidsSystem = try c.decodeIfPresent(Bool.self, forKey: .gestureAvoidsSystem) ?? false
        independentGesture = try? c.decodeIfPresent(ShortcutProfile.self, forKey: .independentGesture)
        focusMethod = (try? c.decodeIfPresent(FocusMethod.self, forKey: .focusMethod)) ?? .windowServer
        // Before 1.6 the command port was always open; it now starts closed until enabled in 设置 › 通用.
        commandLineEnabled = try c.decodeIfPresent(Bool.self, forKey: .commandLineEnabled) ?? false
        dockBadges = try c.decodeIfPresent(Bool.self, forKey: .dockBadges) ?? true
        restartAfterCrash = try c.decodeIfPresent(Bool.self, forKey: .restartAfterCrash) ?? true
        browserTabs = try c.decodeIfPresent(Bool.self, forKey: .browserTabs) ?? false
        searchApps = try c.decodeIfPresent(Bool.self, forKey: .searchApps) ?? true
        searchSettingsPages = try c.decodeIfPresent(Bool.self, forKey: .searchSettingsPages) ?? true
        numberHints = try c.decodeIfPresent(Bool.self, forKey: .numberHints) ?? true
        titleDisplay = (try? c.decodeIfPresent(TitleDisplay.self, forKey: .titleDisplay)) ?? .window
        titleCut = (try? c.decodeIfPresent(TitleCut.self, forKey: .titleCut)) ?? .end
        panelScreen = (try? c.decodeIfPresent(PanelScreen.self, forKey: .panelScreen)) ?? .active
        followCursor = (try? c.decodeIfPresent(FollowCursor.self, forKey: .followCursor)) ?? .never
        gesture = (try? c.decodeIfPresent(GestureChoice.self, forKey: .gesture)) ?? .disabled
        gestureProfile = try c.decodeIfPresent(Int.self, forKey: .gestureProfile) ?? 0
        haptics = try c.decodeIfPresent(Bool.self, forKey: .haptics) ?? true
        arrowKeys = try c.decodeIfPresent(Bool.self, forKey: .arrowKeys) ?? true
        vimKeys = try c.decodeIfPresent(Bool.self, forKey: .vimKeys) ?? false
        autoPreview = try c.decodeIfPresent(Bool.self, forKey: .autoPreview) ?? false
        backgroundPreviews = try c.decodeIfPresent(Bool.self, forKey: .backgroundPreviews) ?? false
        statusBadges = try c.decodeIfPresent(Bool.self, forKey: .statusBadges) ?? true
        spaceNumbers = try c.decodeIfPresent(Bool.self, forKey: .spaceNumbers) ?? false
        tileButtons = try c.decodeIfPresent(Bool.self, forKey: .tileButtons) ?? true
        showMenuIcon = try c.decodeIfPresent(Bool.self, forKey: .showMenuIcon) ?? true
        menuIcon = (try? c.decodeIfPresent(MenuIconChoice.self, forKey: .menuIcon)) ?? .outline
        showDelay = try c.decodeIfPresent(Int.self, forKey: .showDelay) ?? 100
        fadeOut = try c.decodeIfPresent(Bool.self, forKey: .fadeOut) ?? false
        previewFadeIn = try c.decodeIfPresent(Bool.self, forKey: .previewFadeIn) ?? true
        // An entry that cannot be read, such as a command from a later version, is left out alone.
        bindings = (try? c.decodeIfPresent([TolerantElement<PanelBinding>].self, forKey: .bindings))?.compactMap { $0.value } ?? PanelBinding.defaults
        for var binding in PanelBinding.defaults where !bindings.contains(where: { $0.command == binding.command }) {
            if bindings.contains(where: { $0.enabled && $0.keyCode == binding.keyCode && $0.modifiers == binding.modifiers }) { binding.enabled = false }
            bindings.append(binding)
        }
        exceptions = (try? c.decodeIfPresent([TolerantElement<AppException>].self, forKey: .exceptions))?.compactMap { $0.value } ?? AppException.defaults
        if revision < 2 && !exceptions.contains(where: { $0.matches(bundle: "com.netease.uuremote") }) {
            exceptions.append(.uuRemote)
        }
        restoreLayoutOnScreenChange = try c.decodeIfPresent(Bool.self, forKey: .restoreLayoutOnScreenChange) ?? false
    }
}
struct WindowRect: Codable, Equatable {
    let x: Double, y: Double, width: Double, height: Double
    func contains(x pointX: Double, y pointY: Double) -> Bool {
        pointX >= x && pointY >= y && pointX < x + width && pointY < y + height
    }
}
enum ReleaseDecision {
    static func action(behavior: ReleaseBehavior, sticky: Bool, held: Bool) -> ReleaseBehavior? {
        guard !sticky, !held else { return nil }
        return behavior
    }
}
enum PanelInputPolicy {
    static func command(code: UInt32, flags: ShortcutModifiers, held: ShortcutModifiers, sticky: Bool,
                        searching: Bool, bindings: [PanelBinding], mode: PanelInputMode = .traditional) -> PanelCommand? {
        let normalized = flags.subtracting(held)
        // Explicit combinations take priority; holding the trigger modifiers must
        // still allow ordinary panel commands after the panel has been pinned.
        let candidates = flags == normalized ? [flags] : [flags, normalized]
        for flags in candidates {
        for b in bindings where b.enabled && b.keyCode == code && b.modifiers == flags {
            if mode == .search && isTextKey(code) && flags.subtracting(.shift).isEmpty { continue }
            if searching && flags.isEmpty && ![PanelCommand.confirm, .cancel, .next, .previous].contains(b.command) { continue }
            return b.command
        }
        }
        return nil
    }
    static func isTextKey(_ code: UInt32) -> Bool {
        (code < 51 && ![36, 48, 49].contains(code)) || [65, 67, 69, 75, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92, 95].contains(code)
    }
    static func alias(code: UInt32, flags: ShortcutModifiers, held: ShortcutModifiers, bindings: [PanelBinding]) -> PanelCommand? {
        let flags = flags.subtracting(held.intersection(.option))
        let command: PanelCommand?
        switch (code, flags) {
        case (13, .command): command = .close
        case (46, .command): command = .minimize
        case (3, [.command, .shift]): command = .fullscreen
        case (12, .command): command = .quitApp
        case (4, .command): command = .hideApp
        default: command = nil
        }
        return command.flatMap { value in bindings.contains(where: { $0.command == value && $0.enabled }) ? value : nil }
    }
}

enum GestureResult: Equatable { case start(Int), move(Int), end }
struct GestureTracker {
    var choice: GestureChoice = .disabled
    private var anchor: (x: Double, y: Double)?
    private var lastStep = 0
    private var started = false
    private var rejected = false
    var isActive: Bool { started }
    mutating func rebase() { if !started { anchor = nil; lastStep = 0 } }
    init(choice: GestureChoice = .disabled) { self.choice = choice }
    mutating func update(fingers: Int, x: Double, y: Double) -> GestureResult? {
        guard choice != .disabled else { return nil }
        guard x.isFinite, y.isFinite else { return nil }
        if fingers <= 1 {
            let ended = started; anchor = nil; lastStep = 0; started = false
            rejected = false
            return ended ? .end : nil
        }
        if fingers > choice.fingers && !started { rejected = true }
        guard !rejected else { return nil }
        guard fingers == choice.fingers else {
            let ended = started; anchor = nil; lastStep = 0; started = false
            return ended ? .end : nil
        }
        guard let anchor else { self.anchor = (x, y); return nil }
        let distance = choice.horizontal ? x - anchor.x : y - anchor.y
        let perpendicular = choice.horizontal ? y - anchor.y : x - anchor.x
        if !started && abs(perpendicular) > 0.08 && abs(perpendicular) > abs(distance) {
            rejected = true; return nil
        }
        // Start early enough to claim this swipe before a system gesture opens.
        guard started || abs(distance) >= 0.025 else { return nil }
        let step = abs(distance) < 0.025 ? 0 : (distance >= 0 ? 1 : -1) * max(1, Int(abs(distance) / 0.10))
        guard step != lastStep else { return nil }
        let delta = step - lastStep; lastStep = step
        if !started { started = true; return .start(delta) }
        return .move(delta)
    }
}
