import Foundation

// Menu bar icons (macOS 27 and later): the rules, kept free of AppKit so the core checks can test them.
//
// macOS 27 limits which menu bar items are drawn through an allow-list of apps and system items. Every
// icon of one app therefore shares one setting, and an item is hidden by leaving it off the list.
// 一瞥 never hides its own icon, the clock or Control Center.

/// Where an app's menu bar icons live.
enum MenuBarSection: String, Codable, CaseIterable, Identifiable {
    case visible, hidden, alwaysHidden
    var id: String { rawValue }
    var label: String {
        switch self {
        case .visible: return "显示"
        case .hidden: return "隐藏"
        case .alwaysHidden: return "始终隐藏"
        }
    }
    var summary: String {
        switch self {
        case .visible: return "一直在菜单栏里"
        case .hidden: return "点一瞥图标、按快捷键或把指针停在菜单栏空白处时出现"
        case .alwaysHidden: return "只在按住 ⌥ 点一瞥图标或按“显示全部”快捷键时出现"
        }
    }
}

/// What is shown for now on top of the saved sections.
enum MenuBarReveal: Int, Comparable {
    case none, hidden, all
    static func < (a: MenuBarReveal, b: MenuBarReveal) -> Bool { a.rawValue < b.rawValue }
    func shows(_ section: MenuBarSection) -> Bool {
        switch section {
        case .visible: return true
        case .hidden: return self != .none
        case .alwaysHidden: return self == .all
        }
    }
}

/// A global shortcut for the menu bar commands; off until the user turns it on.
struct MenuBarHotkey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: ShortcutModifiers
    var enabled = false
    var isValid: Bool {
        keyCode != KeyChoice.modifierOnly && KeyChoice.isSupportedKey(keyCode) && modifiers.rawValue < 16
            && !modifiers.intersection([.option, .control, .command]).isEmpty
    }
    var combinationKey: String { "\(modifiers.rawValue):\(keyCode)" }
    var label: String { modifiers.symbols + KeyChoice.label(for: keyCode) }
    /// ⌃⌥B and ⌃⌥⇧B: B for bar; free in most apps.
    static let toggleDefault = MenuBarHotkey(keyCode: 11, modifiers: [.control, .option])
    static let showAllDefault = MenuBarHotkey(keyCode: 11, modifiers: [.control, .option, .shift])
}

struct MenuBarSettings: Codable, Equatable {
    /// 管理菜单栏图标. Off means every icon shows and the 一瞥 icon opens its menu as before.
    var enabled = true
    /// Keyed by item identity: "bundle:<bundle id>" for an app, "system:<n>" for a system item.
    var sections: [String: MenuBarSection] = [:]
    var revealOnHover = true
    /// Seconds before icons shown by a click or shortcut hide again; 0 keeps them until the next click.
    var rehideSeconds = 10
    var toggleHotkey = MenuBarHotkey.toggleDefault
    var showAllHotkey = MenuBarHotkey.showAllDefault
    /// Menu bar icons appear as results in the search panel.
    var searchable = true
    static let rehideChoices = [0, 5, 10, 20, 30]

    init() {}
    private enum CodingKeys: String, CodingKey {
        case enabled, sections, revealOnHover, rehideSeconds, toggleHotkey, showAllHotkey, searchable
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        // An unknown section name drops only that entry, not the whole setting.
        let raw = (try? c.decodeIfPresent([String: String].self, forKey: .sections)) ?? [:]
        sections = raw.reduce(into: [:]) { result, pair in
            if let section = MenuBarSection(rawValue: pair.value), MenuBarPolicy.isAssignable(pair.key) { result[pair.key] = section }
        }
        revealOnHover = try c.decodeIfPresent(Bool.self, forKey: .revealOnHover) ?? true
        rehideSeconds = try c.decodeIfPresent(Int.self, forKey: .rehideSeconds) ?? 10
        toggleHotkey = try c.decodeIfPresent(MenuBarHotkey.self, forKey: .toggleHotkey) ?? .toggleDefault
        showAllHotkey = try c.decodeIfPresent(MenuBarHotkey.self, forKey: .showAllHotkey) ?? .showAllDefault
        searchable = try c.decodeIfPresent(Bool.self, forKey: .searchable) ?? true
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(sections.mapValues(\.rawValue), forKey: .sections)
        try c.encode(revealOnHover, forKey: .revealOnHover)
        try c.encode(rehideSeconds, forKey: .rehideSeconds)
        try c.encode(toggleHotkey, forKey: .toggleHotkey)
        try c.encode(showAllHotkey, forKey: .showAllHotkey)
        try c.encode(searchable, forKey: .searchable)
    }

    var enabledHotkeys: [MenuBarHotkey] { [toggleHotkey, showAllHotkey].filter(\.enabled) }
    func section(of id: String) -> MenuBarSection { sections[id] ?? .visible }
    /// Something is assigned to Hidden or Always Hidden.
    var hidesAnything: Bool { enabled && sections.values.contains { $0 != .visible } }
}

enum MenuBarPolicy {
    static let ownBundle = "com.jethro.windowhop"
    /// The system items macOS lets an allow-list name, by number. 2 (clock) and 8 (Control Center) always stay.
    static let systemItems: [(number: Int, keys: [String], name: String, symbol: String)] = [
        (0, ["battery"], "电池", "battery.100percent"),
        (1, ["bluetooth"], "蓝牙", "antenna.radiowaves.left.and.right"),
        (2, ["clock"], "时钟", "clock"),
        (3, ["display", "displays"], "显示器", "display"),
        (4, ["textinput", "keyboard"], "输入法", "keyboard"),
        (5, ["sound", "volume"], "声音", "speaker.wave.2"),
        (6, ["wifi"], "无线局域网", "wifi"),
        (7, ["screenmirroring", "screen-mirroring"], "屏幕镜像", "rectangle.on.rectangle"),
        (8, ["controlcenter"], "控制中心", "switch.2"),
    ]
    static let fixedSystemItems: Set<Int> = [2, 8]
    /// Processes that draw several unrelated items and cannot be split.
    static let unmanagedBundles: Set<String> = ["com.apple.systemuiserver", "com.apple.MenuBarAgent", "com.apple.controlcenter"]

    static func systemNumber(forIdentifier identifier: String) -> Int? {
        let key = identifier.replacingOccurrences(of: "com.apple.menuextra.", with: "").lowercased()
        return systemItems.first { $0.keys.contains(key) }?.number
    }
    /// The identity of an element found in the menu bar: the app that owns it, or a system item.
    /// Returns nil for things that are not menu bar items at all.
    static func identity(bundle: String?, identifier: String?) -> String? {
        if let bundle, !bundle.isEmpty {
            if bundle == "com.apple.TextInputMenuAgent" { return "system:4" }
            if unmanagedBundles.contains(bundle) { return "fixed:\(bundle)" }
            return "bundle:\(bundle)"
        }
        guard let identifier, identifier.hasPrefix("com.apple.menuextra.") else { return nil }
        if let number = systemNumber(forIdentifier: identifier) { return "system:\(number)" }
        return "fixed:\(identifier)"
    }
    static func bundle(of id: String) -> String? { id.hasPrefix("bundle:") ? String(id.dropFirst(7)) : nil }
    static func systemNumber(of id: String) -> Int? { id.hasPrefix("system:") ? Int(id.dropFirst(7)) : nil }

    /// Whether the user can move this item between sections.
    static func isAssignable(_ id: String) -> Bool {
        if let bundle = bundle(of: id) { return !bundle.isEmpty && bundle != ownBundle && !unmanagedBundles.contains(bundle) }
        if let number = systemNumber(of: id) { return (0...8).contains(number) && !fixedSystemItems.contains(number) }
        return false
    }

    struct Allowance: Equatable {
        var bundles: [String]
        var systemItems: [Int]
    }
    /// What the menu bar may show, or nil when nothing needs hiding: then no request is made at all,
    /// because limiting the menu bar can also tuck away system extras such as Focus.
    static func allowance(settings: MenuBarSettings, running: Set<String>, reveal: MenuBarReveal) -> Allowance? {
        guard settings.enabled else { return nil }
        let hidden = settings.sections.filter { isAssignable($0.key) && !reveal.shows($0.value) }.map(\.key)
        let hiddenBundles = Set(hidden.compactMap(bundle(of:))).intersection(running)
        let hiddenSystems = Set(hidden.compactMap(systemNumber(of:)))
        guard !hiddenBundles.isEmpty || !hiddenSystems.isEmpty else { return nil }
        return Allowance(bundles: running.union([ownBundle]).subtracting(hiddenBundles).sorted(),
                         systemItems: (0...8).filter { !hiddenSystems.contains($0) })
    }

    /// The hover strip: from the end of the front app's menus to the first menu bar icon.
    static func hoverZone(menusEnd: Double?, iconsStart: Double?, screenWidth: Double) -> ClosedRange<Double>? {
        let start = (menusEnd ?? screenWidth * 0.3) + 16
        let end = (iconsStart ?? screenWidth * 0.6) - 8
        return end - start >= 40 ? start...end : nil
    }
}
