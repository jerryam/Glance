import Foundation

enum SwitcherStyle: String, Codable, CaseIterable, Identifiable {
    case thumbnails, icons, titles
    var id: String { rawValue }
    var label: String {
        switch self { case .thumbnails: return "缩略图"; case .icons: return "图标"; case .titles: return "列表" }
    }
}

enum ThemeChoice: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self { case .system: return "跟随系统"; case .light: return "浅色"; case .dark: return "深色" }
    }
}

enum WindowScope: String, Codable, CaseIterable, Identifiable {
    case all, currentApp, otherApps, underCursor, appUnderCursor
    var id: String { rawValue }
    var label: String {
        switch self { case .all: return "所有应用"; case .currentApp: return "当前应用"; case .otherApps: return "其他应用"
        case .underCursor: return "鼠标下的窗口"; case .appUnderCursor: return "鼠标下的应用" }
    }
}

struct ShortcutModifiers: OptionSet, Codable, Hashable {
    var rawValue: UInt32
    static let option = ShortcutModifiers(rawValue: 1)
    static let control = ShortcutModifiers(rawValue: 2)
    static let command = ShortcutModifiers(rawValue: 4)
    static let shift = ShortcutModifiers(rawValue: 8)
    var symbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "") +
        (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

struct KeyChoice: Identifiable, Equatable {
    static let modifierOnly: UInt32 = 0xFFFF
    let code: UInt32
    let label: String
    var id: UInt32 { code }
    static let all: [KeyChoice] = [
        .init(code: 48, label: "Tab"), .init(code: 49, label: "Space"), .init(code: 50, label: "`"),
        .init(code: 0, label: "A"), .init(code: 11, label: "B"), .init(code: 8, label: "C"),
        .init(code: 2, label: "D"), .init(code: 14, label: "E"), .init(code: 3, label: "F"),
        .init(code: 5, label: "G"), .init(code: 4, label: "H"), .init(code: 34, label: "I"),
        .init(code: 38, label: "J"), .init(code: 40, label: "K"), .init(code: 37, label: "L"),
        .init(code: 46, label: "M"), .init(code: 45, label: "N"), .init(code: 31, label: "O"),
        .init(code: 35, label: "P"), .init(code: 12, label: "Q"), .init(code: 15, label: "R"),
        .init(code: 1, label: "S"), .init(code: 17, label: "T"), .init(code: 32, label: "U"),
        .init(code: 9, label: "V"), .init(code: 13, label: "W"), .init(code: 7, label: "X"),
        .init(code: 16, label: "Y"), .init(code: 6, label: "Z"),
        .init(code: 18, label: "1"), .init(code: 19, label: "2"), .init(code: 20, label: "3"),
        .init(code: 21, label: "4"), .init(code: 23, label: "5"), .init(code: 22, label: "6"),
        .init(code: 26, label: "7"), .init(code: 28, label: "8"), .init(code: 25, label: "9"),
        .init(code: 122, label: "F1"), .init(code: 120, label: "F2"), .init(code: 99, label: "F3"),
        .init(code: 118, label: "F4"), .init(code: 96, label: "F5"), .init(code: 97, label: "F6"),
        .init(code: 98, label: "F7"), .init(code: 100, label: "F8"), .init(code: 101, label: "F9"),
        .init(code: 109, label: "F10"), .init(code: 103, label: "F11"), .init(code: 111, label: "F12"),
        .init(code: 105, label: "F13"), .init(code: 107, label: "F14"), .init(code: 113, label: "F15"),
        .init(code: 106, label: "F16"), .init(code: 64, label: "F17"), .init(code: 79, label: "F18"),
        .init(code: 80, label: "F19"), .init(code: 90, label: "F20")
    ]
    /// F1–F20 never produce text, so they may be used as a global trigger without modifiers.
    static let functionKeys: Set<UInt32> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
    /// Physical modifier keys cannot be the key part of a combination.
    static let modifierKeyCodes: Set<UInt32> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
    static func isSupportedKey(_ code: UInt32) -> Bool {
        (code <= 126 || code == modifierOnly) && !modifierKeyCodes.contains(code)
    }
    static func label(for code: UInt32) -> String {
        if code == modifierOnly { return "" }
        if let name = all.first(where: { $0.code == code })?.label { return name }
        return [36: "Return", 53: "Esc", 51: "Delete", 76: "Enter", 123: "←", 124: "→", 125: "↓", 126: "↑",
                27: "-", 24: "+", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/"][code] ?? "键\(code)"
    }
}

struct ShortcutProfile: Codable, Identifiable, Equatable {
    let id: Int
    var enabled: Bool
    var keyCode: UInt32
    var modifiers: ShortcutModifiers
    var scope: WindowScope
    var currentSpaceOnly: Bool
    var currentScreenOnly: Bool
    var keepOpen: Bool
    var release: ReleaseBehavior? = nil
    var spaces: SpaceScope? = nil
    var minimized: VisibilityPolicy? = nil
    var hidden: VisibilityPolicy? = nil
    var fullscreen: VisibilityPolicy = .show
    var windowless: VisibilityPolicy? = nil
    var order: WindowOrder = .recent
    var grouping: WindowGrouping = .all
    var separateTabs = false
    var styleOverride: SwitcherStyle? = nil
    var themeOverride: ThemeChoice? = nil
    var widthOverride: Double? = nil
    var adaptiveOverride: Bool? = nil
    var previewOverride: Bool? = nil
    /// The name shown in 设置 › 切换方案; nil uses a name that follows the scheme's settings.
    var name: String? = nil
    var releaseBehavior: ReleaseBehavior { release ?? (keepOpen ? .hold : .focus) }
    var displayName: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? suggestedName : trimmed
    }
    var suggestedName: String {
        if id == 9 { return "触控板" }
        if releaseBehavior == .search { return "快速搜索" }
        switch scope {
        case .all: return "全部窗口"
        case .currentApp: return "当前应用"
        case .otherApps: return "其他应用"
        case .underCursor: return "鼠标下的窗口"
        case .appUnderCursor: return "鼠标下的应用"
        }
    }
    /// One line for the scheme list, such as “所有应用 · 最近使用 · 松开切换”.
    var summary: String {
        var parts = [scope.label]
        if spaceScope != .all { parts.append(spaceScope.label) }
        parts.append(order.label)
        let lift = id == 9 ? "抬手" : "松开"
        switch releaseBehavior {
        case .focus: parts.append(lift + "切换")
        case .hold: parts.append(lift + "保持打开")
        case .search: parts.append(lift + "进入搜索")
        }
        return parts.joined(separator: " · ")
    }
    var spaceScope: SpaceScope { spaces ?? (currentSpaceOnly ? .visible : .all) }
    var label: String { modifiers.symbols + KeyChoice.label(for: keyCode) }
    /// Global triggers need ⌥, ⌃ or ⌘ so they never swallow typing; a bare F1–F20 key is the exception.
    var hasValidTriggerModifiers: Bool {
        guard modifiers.rawValue < 16 else { return false }
        if !modifiers.intersection([.option, .control, .command]).isEmpty { return true }
        return modifiers.isEmpty && KeyChoice.functionKeys.contains(keyCode)
    }
    /// A bare function key has no modifier to release, so its panel stays open until confirmed.
    var usesBareKey: Bool { modifiers.isEmpty && keyCode != KeyChoice.modifierOnly }
    /// The forward combination, plus the Shift reverse combination that is registered automatically.
    var combinationKeys: [String] {
        let forward = "\(modifiers.rawValue):\(keyCode)"
        return modifiers.contains(.shift) ? [forward] : [forward, "\(modifiers.union(.shift).rawValue):\(keyCode)"]
    }
    init(id: Int, enabled: Bool, keyCode: UInt32, modifiers: ShortcutModifiers, scope: WindowScope,
         currentSpaceOnly: Bool, currentScreenOnly: Bool, keepOpen: Bool) {
        self.id = id; self.enabled = enabled; self.keyCode = keyCode; self.modifiers = modifiers; self.scope = scope
        self.currentSpaceOnly = currentSpaceOnly; self.currentScreenOnly = currentScreenOnly; self.keepOpen = keepOpen
    }
    private enum CodingKeys: String, CodingKey {
        case id, enabled, keyCode, modifiers, scope, currentSpaceOnly, currentScreenOnly, keepOpen
        case release, spaces, minimized, hidden, fullscreen, windowless, order, grouping, separateTabs
        case styleOverride, themeOverride, widthOverride, adaptiveOverride, previewOverride, name
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id); enabled = try c.decode(Bool.self, forKey: .enabled)
        keyCode = try c.decode(UInt32.self, forKey: .keyCode); modifiers = try c.decode(ShortcutModifiers.self, forKey: .modifiers)
        scope = try c.decode(WindowScope.self, forKey: .scope)
        currentSpaceOnly = try c.decodeIfPresent(Bool.self, forKey: .currentSpaceOnly) ?? false
        currentScreenOnly = try c.decodeIfPresent(Bool.self, forKey: .currentScreenOnly) ?? false
        keepOpen = try c.decodeIfPresent(Bool.self, forKey: .keepOpen) ?? false
        release = try c.decodeIfPresent(ReleaseBehavior.self, forKey: .release)
        spaces = try c.decodeIfPresent(SpaceScope.self, forKey: .spaces)
        minimized = try c.decodeIfPresent(VisibilityPolicy.self, forKey: .minimized)
        hidden = try c.decodeIfPresent(VisibilityPolicy.self, forKey: .hidden)
        fullscreen = try c.decodeIfPresent(VisibilityPolicy.self, forKey: .fullscreen) ?? .show
        windowless = try c.decodeIfPresent(VisibilityPolicy.self, forKey: .windowless)
        order = try c.decodeIfPresent(WindowOrder.self, forKey: .order) ?? .recent
        grouping = try c.decodeIfPresent(WindowGrouping.self, forKey: .grouping) ?? .all
        separateTabs = try c.decodeIfPresent(Bool.self, forKey: .separateTabs) ?? false
        styleOverride = try c.decodeIfPresent(SwitcherStyle.self, forKey: .styleOverride)
        themeOverride = try c.decodeIfPresent(ThemeChoice.self, forKey: .themeOverride)
        widthOverride = try c.decodeIfPresent(Double.self, forKey: .widthOverride)
        adaptiveOverride = try c.decodeIfPresent(Bool.self, forKey: .adaptiveOverride)
        previewOverride = try c.decodeIfPresent(Bool.self, forKey: .previewOverride)
        name = try c.decodeIfPresent(String.self, forKey: .name)
    }
    static func defaults() -> [ShortcutProfile] {
        let codes: [UInt32] = [48, 50, 49, 122, 120, 99, 118, 96, 97]
        var profiles: [ShortcutProfile] = []
        for index in 0..<9 {
            let scope: WindowScope = index == 1 ? .currentApp : .all
            profiles.append(ShortcutProfile(id: index, enabled: index < 2, keyCode: codes[index], modifiers: .option, scope: scope,
                                            currentSpaceOnly: false, currentScreenOnly: false, keepOpen: index == 2))
            if index == 2 { profiles[profiles.count - 1].release = .search }
        }
        return profiles
    }
    static var gestureDefaults: ShortcutProfile {
        ShortcutProfile(id: 9, enabled: true, keyCode: 49, modifiers: .option, scope: .all,
                        currentSpaceOnly: false, currentScreenOnly: false, keepOpen: false)
    }
}

struct UserSettings: Codable, Equatable {
    var style: SwitcherStyle = .thumbnails
    var theme: ThemeChoice = .system
    var adaptiveThumbnails = true
    var thumbnailWidth: Double = 230
    var showMinimized = true
    var showHidden = true
    var livePreviews = true
    var mouseHoverEnabled = false
    var showWindowlessApps = true
    var exclusions = ""
    var shortcuts = ShortcutProfile.defaults()
    var advanced = AdvancedSettings()
    var menuBar = MenuBarSettings()
    var dockPreview = DockPreviewSettings()
    var windowShortcuts = WindowShortcutSettings()
    static let defaults = UserSettings()

    init() {}
    private enum CodingKeys: String, CodingKey {
        case style, theme, adaptiveThumbnails, thumbnailWidth, showMinimized, showHidden, livePreviews
        case mouseHoverEnabled, showWindowlessApps, exclusions, shortcuts, advanced, menuBar, dockPreview, windowShortcuts
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        style = try values.decodeIfPresent(SwitcherStyle.self, forKey: .style) ?? .thumbnails
        theme = try values.decodeIfPresent(ThemeChoice.self, forKey: .theme) ?? .system
        adaptiveThumbnails = try values.decodeIfPresent(Bool.self, forKey: .adaptiveThumbnails) ?? true
        thumbnailWidth = try values.decodeIfPresent(Double.self, forKey: .thumbnailWidth) ?? 230
        showMinimized = try values.decodeIfPresent(Bool.self, forKey: .showMinimized) ?? true
        showHidden = try values.decodeIfPresent(Bool.self, forKey: .showHidden) ?? true
        livePreviews = try values.decodeIfPresent(Bool.self, forKey: .livePreviews) ?? true
        mouseHoverEnabled = try values.decodeIfPresent(Bool.self, forKey: .mouseHoverEnabled) ?? false
        showWindowlessApps = try values.decodeIfPresent(Bool.self, forKey: .showWindowlessApps) ?? true
        exclusions = try values.decodeIfPresent(String.self, forKey: .exclusions) ?? ""
        shortcuts = try values.decodeIfPresent([ShortcutProfile].self, forKey: .shortcuts) ?? ShortcutProfile.defaults()
        advanced = try values.decodeIfPresent(AdvancedSettings.self, forKey: .advanced) ?? AdvancedSettings()
        menuBar = (try? values.decodeIfPresent(MenuBarSettings.self, forKey: .menuBar)) ?? MenuBarSettings()
        dockPreview = (try? values.decodeIfPresent(DockPreviewSettings.self, forKey: .dockPreview)) ?? DockPreviewSettings()
        windowShortcuts = (try? values.decodeIfPresent(WindowShortcutSettings.self, forKey: .windowShortcuts)) ?? WindowShortcutSettings()
    }

    func validationError() -> String? {
        guard shortcuts.count == 9, Set(shortcuts.map(\.id)) == Set(0..<9) else { return "需要保留 9 个不同的快捷键位置。" }
        guard thumbnailWidth.isFinite, (150...360).contains(thumbnailWidth), (0...900).contains(advanced.showDelay) else { return "尺寸或显示延迟超出范围。" }
        guard (0..<9).contains(advanced.gestureProfile) else { return "手势对应的快捷键位置无效。" }
        if let gesture = advanced.independentGesture {
            guard gesture.id == 9, gesture.widthOverride.map({ $0.isFinite && (150...360).contains($0) }) ?? true else { return "独立手势方案的尺寸或编号无效。" }
        }
        var combinations = Set<String>()
        for p in shortcuts where p.enabled {
            guard p.hasValidTriggerModifiers else { return "第 \(p.id + 1) 组需要包含 ⌥、⌃ 或 ⌘（单独的 F1–F20 除外），以免占用普通文字输入。" }
            guard KeyChoice.isSupportedKey(p.keyCode) else { return "第 \(p.id + 1) 组的按键不受支持。" }
            if let width = p.widthOverride, !width.isFinite || !(150...360).contains(width) { return "第 \(p.id + 1) 组的尺寸超出范围。" }
            let keys = p.combinationKeys
            guard combinations.insert(keys[0]).inserted else { return "快捷键 \(p.label) 重复。" }
            if keys.count > 1 {
                guard combinations.insert(keys[1]).inserted else { return "\(p.label) 的 Shift 反向快捷键与其他组冲突。" }
            }
        }
        guard MenuBarSettings.rehideChoices.contains(menuBar.rehideSeconds) else { return "菜单栏图标的自动收回时间无效。" }
        guard DockPreviewSettings.delayRange.contains(dockPreview.delay) else { return "Dock 预览的显示延迟超出范围。" }
        for hotkey in menuBar.enabledHotkeys {
            guard hotkey.isValid else { return "菜单栏快捷键 \(hotkey.label) 需要包含 ⌥、⌃ 或 ⌘，并且不能只按修饰键。" }
            guard combinations.insert(hotkey.combinationKey).inserted else { return "菜单栏快捷键 \(hotkey.label) 与其他快捷键重复。" }
        }
        for shortcut in windowShortcuts.active {
            guard shortcut.hotkey.isValid else { return "窗口快捷键 \(shortcut.hotkey.label) 需要包含 ⌥、⌃ 或 ⌘，并且不能只按修饰键。" }
            guard combinations.insert(shortcut.hotkey.combinationKey).inserted else { return "窗口快捷键 \(shortcut.hotkey.label) 与其他快捷键重复。" }
        }
        var panelKeys = Set<String>()
        guard Set(advanced.bindings.map(\.command)).count == advanced.bindings.count else { return "面板操作不能重复配置。" }
        for b in advanced.bindings where b.enabled {
            guard b.isSupported else { return "面板按键不受支持。" }
            guard panelKeys.insert("\(b.modifiers.rawValue):\(b.keyCode)").inserted else { return "面板操作快捷键重复。" }
        }
        return nil
    }
    /// Fixes what can be fixed instead of discarding the whole configuration:
    /// conflicting or invalid shortcuts are disabled, out-of-range values are clamped.
    func repaired() -> UserSettings {
        var result = self
        let defaults = ShortcutProfile.defaults()
        var byID: [Int: ShortcutProfile] = [:]
        for profile in result.shortcuts where (0..<9).contains(profile.id) && byID[profile.id] == nil { byID[profile.id] = profile }
        result.shortcuts = (0..<9).map { byID[$0] ?? defaults[$0] }
        if !result.thumbnailWidth.isFinite || !(150...360).contains(result.thumbnailWidth) { result.thumbnailWidth = 230 }
        result.advanced.showDelay = min(900, max(0, result.advanced.showDelay))
        if !(0..<9).contains(result.advanced.gestureProfile) { result.advanced.gestureProfile = 0 }
        if let gesture = result.advanced.independentGesture {
            if gesture.id != 9 { result.advanced.independentGesture = .gestureDefaults }
            else if let width = gesture.widthOverride, !(width.isFinite && (150...360).contains(width)) {
                result.advanced.independentGesture?.widthOverride = nil
            }
        }
        var combinations = Set<String>()
        for index in result.shortcuts.indices {
            var profile = result.shortcuts[index]
            if let width = profile.widthOverride, !(width.isFinite && (150...360).contains(width)) { profile.widthOverride = nil }
            if profile.enabled {
                let keys = profile.combinationKeys
                if !profile.hasValidTriggerModifiers || !KeyChoice.isSupportedKey(profile.keyCode) || keys.contains(where: { combinations.contains($0) }) {
                    profile.enabled = false
                } else {
                    keys.forEach { combinations.insert($0) }
                }
            }
            result.shortcuts[index] = profile
        }
        if !MenuBarSettings.rehideChoices.contains(result.menuBar.rehideSeconds) { result.menuBar.rehideSeconds = 10 }
        result.dockPreview.delay = min(DockPreviewSettings.delayRange.upperBound, max(DockPreviewSettings.delayRange.lowerBound, result.dockPreview.delay))
        for keyPath in [\MenuBarSettings.toggleHotkey, \MenuBarSettings.showAllHotkey] where result.menuBar[keyPath: keyPath].enabled {
            let hotkey = result.menuBar[keyPath: keyPath]
            if !hotkey.isValid || !combinations.insert(hotkey.combinationKey).inserted { result.menuBar[keyPath: keyPath].enabled = false }
        }
        if result.windowShortcuts.enabled {
            for index in result.windowShortcuts.shortcuts.indices where result.windowShortcuts.shortcuts[index].hotkey.enabled {
                let hotkey = result.windowShortcuts.shortcuts[index].hotkey
                if !hotkey.isValid || !combinations.insert(hotkey.combinationKey).inserted { result.windowShortcuts.shortcuts[index].hotkey.enabled = false }
            }
        }
        var commands = Set<PanelCommand>()
        result.advanced.bindings = result.advanced.bindings.filter { commands.insert($0.command).inserted }
        for command in PanelCommand.allCases where !commands.contains(command) {
            var binding = PanelBinding(command: command, keyCode: command.defaultCode, modifiers: command.defaultModifiers)
            binding.enabled = false
            result.advanced.bindings.append(binding)
        }
        var panelKeys = Set<String>()
        for index in result.advanced.bindings.indices where result.advanced.bindings[index].enabled {
            let binding = result.advanced.bindings[index]
            if !binding.isSupported || !panelKeys.insert("\(binding.modifiers.rawValue):\(binding.keyCode)").inserted {
                result.advanced.bindings[index].enabled = false
            }
        }
        return result
    }
    /// What can still be read from a stored configuration that no longer decodes as a whole, for example one
    /// written by a newer version: every value that decodes is kept, the others stay at their defaults.
    /// Nil when the data holds nothing usable.
    static func salvaged(from data: Data) -> UserSettings? {
        func decoded(_ object: [String: Any]) -> UserSettings? {
            guard let bytes = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            return try? JSONDecoder().decode(UserSettings.self, from: bytes)
        }
        guard let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let defaults = try? JSONEncoder().encode(UserSettings.defaults),
              var result = (try? JSONSerialization.jsonObject(with: defaults)) as? [String: Any] else { return nil }
        var kept = 0
        for key in saved.keys.sorted() where result[key] != nil {
            var trial = result
            trial[key] = saved[key]
            if decoded(trial) != nil { result = trial; kept += 1; continue }
            // One bad value fails a whole group such as `advanced`; the rest of the group can still be kept.
            guard let group = saved[key] as? [String: Any], var merged = result[key] as? [String: Any] else { continue }
            for inner in group.keys.sorted() {
                var attempt = merged
                attempt[inner] = group[inner]
                var whole = result
                whole[key] = attempt
                if decoded(whole) != nil { merged = attempt; kept += 1 }
            }
            result[key] = merged
        }
        return kept > 0 ? decoded(result) : nil
    }
    /// Turns on the first unused scheme slot with a trigger that does not collide with the others.
    func withNewProfile() -> (settings: UserSettings, id: Int)? {
        guard let slot = shortcuts.firstIndex(where: { !$0.enabled }) else { return nil }
        let id = shortcuts[slot].id
        var profile = ShortcutProfile.defaults()[min(8, max(0, id))]
        profile.enabled = true
        let used = Set(shortcuts.filter(\.enabled).flatMap(\.combinationKeys))
        for code in [profile.keyCode, 48, 50, 49, 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111] as [UInt32] {
            var candidate = profile; candidate.keyCode = code; candidate.modifiers = .option
            if candidate.combinationKeys.allSatisfy({ !used.contains($0) }) { profile = candidate; break }
        }
        var result = self
        result.shortcuts[slot] = profile
        return (result, id)
    }
    func effective(for profile: ShortcutProfile) -> UserSettings {
        var result = self
        result.style = profile.styleOverride ?? style
        result.theme = profile.themeOverride ?? theme
        result.thumbnailWidth = profile.widthOverride ?? thumbnailWidth
        result.adaptiveThumbnails = profile.adaptiveOverride ?? adaptiveThumbnails
        result.advanced.autoPreview = profile.previewOverride ?? advanced.autoPreview
        return result
    }
}

/// The file format used by 设置 › 通用 › 导出 / 导入.
struct SettingsArchive: Codable {
    static let formatName = "windowhop.settings"
    var format: String
    var version: Int
    var settings: UserSettings
    static func encode(_ settings: UserSettings) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(SettingsArchive(format: formatName, version: 1, settings: settings))
    }
    enum ImportError: Error { case unrecognized }
    /// Accepts an exported archive or a raw settings object; the result is always repaired and valid.
    static func decode(_ data: Data) throws -> UserSettings {
        if let archive = try? JSONDecoder().decode(SettingsArchive.self, from: data), archive.format == formatName {
            return archive.settings.repaired()
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["shortcuts"] != nil,
              let settings = try? JSONDecoder().decode(UserSettings.self, from: data) else { throw ImportError.unrecognized }
        return settings.repaired()
    }
}

/// What a search result opens when it is not a window.
enum LaunchKind: Equatable, CaseIterable {
    case app, setting, command, file, calculation, web
    var label: String {
        switch self {
        case .app: return "未打开的应用"
        case .setting: return "系统设置"
        case .command: return "系统命令"
        case .file: return "文件"
        case .calculation: return "计算结果"
        case .web: return "用浏览器打开"
        }
    }
    var symbol: String {
        switch self {
        case .app: return "arrow.up.forward.app"
        case .setting: return "gearshape"
        case .command: return "power"
        case .file: return "doc"
        case .calculation: return "equal.circle"
        case .web: return "globe"
        }
    }
    /// What Return does, on a button.
    var action: String { self == .calculation ? "复制" : "打开" }
    /// What Return does, in a sentence.
    var hint: String {
        switch self {
        case .app: return "按 ↩ 打开这个应用"
        case .setting: return "按 ↩ 打开这个设置页"
        case .command: return "按 ↩ 执行这个命令"
        case .file: return "按 ↩ 打开这个文件"
        case .calculation: return "按 ↩ 复制结果"
        case .web: return "按 ↩ 用默认浏览器打开"
        }
    }
    /// Made from what was typed, so there is nothing to match the typing against.
    var madeFromQuery: Bool { self == .calculation || self == .web }
    /// Its place among the results: a sum first, what comes from the disk or the web after the rest.
    var place: Int {
        switch self {
        case .calculation: return 0
        case .app, .setting, .command: return 1
        case .file: return 2
        case .web: return 3
        }
    }
}

struct WindowDescriptor: Identifiable, Equatable {
    let id: String
    let windowID: UInt32?
    let pid: Int32
    let appName: String
    let bundleID: String
    var title: String
    let minimized: Bool
    var hidden: Bool
    let onCurrentSpace: Bool
    let displayID: UInt32?
    let aspectRatio: Double
    var windowless = false
    var fullscreen = false
    var spaces: [UInt64] = []
    var spaceNumbers: [Int] = []
    var spaceKnown = false
    var frame: WindowRect? = nil
    var created: Double = 0
    var lastFocused: Double = 0
    var tabGroup: String? = nil
    var tabRepresentative = true
    var controllable = true
    var zOrder = Int.max
    /// A Safari / Chrome tab listed through Automation; only shown while searching.
    var browserTab = false
    /// An app's or system item's icon in the menu bar (macOS 27); only shown while searching.
    var menuBarItem = false
    /// An app that is not running, or a System Settings page, to open from a search.
    var launcher: LaunchKind? = nil
    /// Not a window: a browser tab, a menu bar icon or something to open, which only join a search.
    var searchOnly: Bool { browserTab || menuBarItem || launcher != nil }
    /// 一瞥's own settings window: listed like a window, but the only thing to do with it is go to it.
    var settingsWindow = false
    /// Secondary text, such as a tab's web address.
    var subtitle: String? = nil
    /// What a result made from the search opens or copies: a file's path, a web address, the answer to a sum.
    var launchTarget: String? = nil
    var pinned = false
    /// Number of windows folded into this entry when grouping by app.
    var groupCount = 0
    var displayTitle: String { title.isEmpty ? appName : title }
}


struct ThumbnailLayout {
    let columns: Int
    let width: Double
    let height: Double
    static func calculate(count: Int, availableWidth: Double, availableHeight: Double, preferredWidth: Double, adaptive: Bool) -> ThumbnailLayout {
        let gap = 12.0
        let maxWidth = max(160, availableWidth)
        let maxHeight = max(130, availableHeight)
        var best = ThumbnailLayout(columns: max(1, Int((maxWidth + gap) / (preferredWidth + gap))), width: preferredWidth, height: preferredWidth * 0.63 + 94)
        guard adaptive && count > 0 else { return best }
        var bestArea = 0.0
        for columns in 1...max(1, min(count, 8)) {
            let rows = ceil(Double(count) / Double(columns))
            let widthByScreen = (maxWidth - Double(columns - 1) * gap) / Double(columns)
            let widthByHeight = ((maxHeight - (rows - 1) * gap) / rows - 94) / 0.63
            let width = max(150, min(270, min(widthByScreen, widthByHeight)))
            let height = width * 0.63 + 94
            guard Double(columns) * width + Double(columns - 1) * gap <= maxWidth + 0.5 else { continue }
            let area = width * width
            if area > bestArea { bestArea = area; best = .init(columns: columns, width: width, height: height) }
        }
        return best
    }
}
