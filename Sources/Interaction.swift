import Foundation

enum WindowNavigation {
    static func linear(index: Int, count: Int, step: Int) -> Int {
        guard count > 0 else { return 0 }
        let current = min(max(0, index), count - 1)
        return (current + step % count + count) % count
    }
    static func vertical(index: Int, count: Int, columns: Int, down: Bool) -> Int {
        guard count > 0 else { return 0 }
        let columns = max(1, columns), current = min(max(0, index), count - 1)
        let column = current % columns
        let rowsInColumn = (count - 1 - column) / columns + 1
        let row = linear(index: current / columns, count: rowsInColumn, step: down ? 1 : -1)
        return column + row * columns
    }
}

enum ModifierNavigation {
    static func command(previous: ShortcutModifiers, current: ShortcutModifiers, held: ShortcutModifiers,
                        bindings: [PanelBinding], shiftSelectsPrevious: Bool, searching: Bool) -> PanelCommand? {
        guard previous != current, !current.subtracting(previous).isEmpty else { return nil }
        let normalized = current.subtracting(held)
        let oldNormalized = previous.subtracting(held)
        for binding in bindings where binding.enabled && binding.keyCode == KeyChoice.modifierOnly {
            if (current == binding.modifiers && previous != binding.modifiers) ||
               (normalized == binding.modifiers && oldNormalized != binding.modifiers) { return binding.command }
        }
        if shiftSelectsPrevious && !searching && normalized == .shift && oldNormalized != .shift,
           bindings.contains(where: { $0.enabled && $0.command == .previous && $0.keyCode == 48 && $0.modifiers == .shift }) {
            return .previous
        }
        return nil
    }
}

/// How much of the screen the switcher may use. Proportional, so large displays show more windows.
enum PanelSizing {
    static let widthShare = 0.86
    static let heightShare = 0.82
    static func available(visibleWidth: Double, visibleHeight: Double, chrome: Double) -> (width: Double, height: Double) {
        (max(500, visibleWidth * widthShare - PanelChrome.horizontal), max(180, visibleHeight * heightShare - chrome))
    }
    /// Search uses a fixed list-and-preview layout, so its size depends only on the screen.
    static func search(visibleWidth: Double, visibleHeight: Double) -> (width: Double, height: Double) {
        let width = min(1120, max(760, visibleWidth * 0.72)), height = min(700, max(460, visibleHeight * 0.68))
        return (min(width, visibleWidth - 36), min(height, visibleHeight - 36))
    }
}

/// Fixed heights around the window cards, shared by the panel view and the frame calculation.
enum PanelChrome {
    static let horizontal = 32.0        // 16 on each side, so cards sit concentric with the panel corners
    static let top = 16.0
    static let toolbar = 50.0           // shown while the panel stays open
    static let permission = 30.0
    static let contentBottom = 16.0
    static let message = 30.0
    static let selectionBar = 66.0      // the selected window's title and key hints
    static func vertical(toolbar: Bool, permission: Bool, message: Bool) -> Double {
        top + (toolbar ? Self.toolbar : 0) + (permission ? Self.permission : 0) + contentBottom
            + (message ? Self.message : 0) + selectionBar
    }
}

/// Thumbnail cards whose width follows each window's shape, wrapped into centred rows.
/// A tall chat window gets a narrow card and a wide editor a wide one, at one shared height.
struct FlowLayout: Equatable {
    /// Item indices per row, top to bottom.
    let rows: [[Int]]
    /// Card width per item, including the card's own padding.
    let widths: [Double]
    let thumbnailHeight: Double
    let gap: Double
    /// Padding, the title row and the space under the thumbnail.
    static let cardChrome = 48.0
    static let cardPadding = 20.0
    static let minimumCardWidth = 120.0
    /// Room around the cards for the selection ring and the lift of the selected card.
    static let verticalInset = 6.0
    static let horizontalInset = 4.0
    var cardHeight: Double { thumbnailHeight + Self.cardChrome }
    var contentWidth: Double { rows.indices.map(rowWidth).max() ?? 0 }
    var contentHeight: Double { rows.isEmpty ? 0 : Double(rows.count) * cardHeight + Double(rows.count - 1) * gap }
    var widestThumbnail: Double { (widths.max() ?? 0) - Self.cardPadding }
    func rowWidth(_ row: Int) -> Double {
        let items = rows[row]
        return items.reduce(0) { $0 + widths[$1] } + Double(max(0, items.count - 1)) * gap
    }
    static func cardWidth(aspect: Double, thumbnailHeight: Double) -> Double {
        let shape = aspect.isFinite && aspect > 0 ? min(2.4, max(0.62, aspect)) : 1.6
        return max(minimumCardWidth, (thumbnailHeight * shape).rounded()) + cardPadding
    }
    /// Greedy wrapping: a row takes cards until the next would not fit.
    static func wrap(_ widths: [Double], maxWidth: Double, gap: Double) -> [[Int]] {
        var rows: [[Int]] = [], current: [Int] = [], used = 0.0
        for (index, width) in widths.enumerated() {
            let needed = current.isEmpty ? width : used + gap + width
            if !current.isEmpty && needed > maxWidth + 0.5 { rows.append(current); current = [index]; used = width }
            else { current.append(index); used = needed }
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }
    static func calculate(aspects: [Double], availableWidth: Double, availableHeight: Double,
                          preferredHeight: Double, adaptive: Bool, gap: Double = 14) -> FlowLayout {
        func build(_ height: Double) -> FlowLayout {
            let widths = aspects.map { min(max(minimumCardWidth + cardPadding, availableWidth), cardWidth(aspect: $0, thumbnailHeight: height)) }
            return FlowLayout(rows: wrap(widths, maxWidth: availableWidth, gap: gap), widths: widths, thumbnailHeight: height, gap: gap)
        }
        guard adaptive, !aspects.isEmpty else { return build(min(260, max(70, preferredHeight))) }
        // The largest thumbnails that still fit every window on screen; past that, the panel scrolls.
        let largest = min(220, availableHeight - cardChrome)
        var height = largest
        while height >= 80 {
            let layout = build(height)
            if layout.contentHeight <= availableHeight + 0.5 { return layout }
            height -= 4
        }
        return build(80)
    }
    /// ↑ / ↓: the card in the next row whose centre is closest, wrapping from the last row to the first.
    func vertical(from index: Int, down: Bool) -> Int {
        guard rows.count > 1, let row = rows.firstIndex(where: { $0.contains(index) }) else { return index }
        let target = (row + (down ? 1 : -1) + rows.count) % rows.count
        let x = center(of: index, in: row)
        return rows[target].min { abs(center(of: $0, in: target) - x) < abs(center(of: $1, in: target) - x) } ?? index
    }
    private func center(of index: Int, in row: Int) -> Double {
        var x = (contentWidth - rowWidth(row)) / 2
        for item in rows[row] {
            if item == index { return x + widths[item] / 2 }
            x += widths[item] + gap
        }
        return x
    }
}

/// ⌘1 … ⌘9 jump straight to a window.
enum DigitKeys {
    private static let codes: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    static func index(for code: UInt32) -> Int? { codes.firstIndex(of: code) }
}

/// Whether the system ⌘Tab switcher has to step aside for one of the configured shortcuts.
enum NativeSwitcherPolicy {
    static func replacesCommandTab(_ profiles: [ShortcutProfile]) -> Bool {
        profiles.contains { $0.enabled && $0.keyCode == 48 && ($0.modifiers == .command || $0.modifiers == [.command, .shift]) }
    }
}

/// Target frames for the window arrangement commands, in top-left screen coordinates.
enum WindowArrangement {
    enum Kind { case left, right, maximize, nextScreen }
    static func screenIndex(of window: WindowRect, in screens: [WindowRect]) -> Int {
        let centerX = window.x + window.width / 2, centerY = window.y + window.height / 2
        if let index = screens.firstIndex(where: { $0.contains(x: centerX, y: centerY) }) { return index }
        func overlap(_ s: WindowRect) -> Double {
            max(0, min(s.x + s.width, window.x + window.width) - max(s.x, window.x)) *
            max(0, min(s.y + s.height, window.y + window.height) - max(s.y, window.y))
        }
        return screens.indices.max { overlap(screens[$0]) < overlap(screens[$1]) } ?? 0
    }
    static func frame(_ kind: Kind, window: WindowRect, screens: [WindowRect]) -> WindowRect? {
        guard !screens.isEmpty else { return nil }
        let index = screenIndex(of: window, in: screens)
        let screen = screens[index]
        let half = (screen.width / 2).rounded(.down)
        switch kind {
        case .left: return WindowRect(x: screen.x, y: screen.y, width: half, height: screen.height)
        case .right: return WindowRect(x: screen.x + screen.width - half, y: screen.y, width: half, height: screen.height)
        case .maximize: return screen
        case .nextScreen:
            guard screens.count > 1 else { return nil }
            let next = screens[(index + 1) % screens.count]
            // Keep the window's relative position, and shrink it only when it would not fit.
            let width = min(window.width, next.width), height = min(window.height, next.height)
            let relativeX = (window.x - screen.x) / max(1, screen.width), relativeY = (window.y - screen.y) / max(1, screen.height)
            let x = min(max(next.x + relativeX * next.width, next.x), next.x + next.width - width)
            let y = min(max(next.y + relativeY * next.height, next.y), next.y + next.height - height)
            return WindowRect(x: x, y: y, width: width, height: height)
        }
    }
}

struct ActivityTimerPlan: Equatable {
    let preview: Bool
    let background: Bool
    let list: Bool
    let release: Bool
    init(showing: Bool, demo: Bool, previews: Bool, thumbnails: Bool, largePreview: Bool, background: Bool, transient: Bool = false) {
        preview = showing && !demo && previews && (thumbnails || largePreview)
        self.background = !showing && background
        list = showing && !demo
        release = showing && !demo && transient
    }
}

enum PanelKeyCapturePolicy {
    static func captures(command: PanelCommand?, panelIsKey: Bool, searching: Bool, markedText: Bool, registeredTrigger: Bool = false) -> Bool {
        guard !markedText, !registeredTrigger, let command else { return false }
        // Cancellation must still work during a focus handoff. Normal text stays with AppKit/IME.
        if command == .cancel { return true }
        guard !panelIsKey, !searching else { return false }
        return [.confirm, .next, .previous].contains(command)
    }
}

enum GlobalShortcutMatch {
    static func matches(code: UInt32, flags: ShortcutModifiers, profile: ShortcutProfile) -> Bool {
        guard profile.enabled, profile.keyCode != KeyChoice.modifierOnly, profile.keyCode == code else { return false }
        return flags == profile.modifiers || (!profile.modifiers.contains(.shift) && flags == profile.modifiers.union(.shift))
    }
}

enum PendingReleasePolicy {
    static func keepPendingCommit(previous: Bool, triggerPressed: Bool, triggerHeld: Bool) -> Bool {
        previous && !triggerPressed && !triggerHeld
    }
}

enum WindowEligibility {
    static func accepts(role: String, subrole: String, width: Double, height: Double, minimized: Bool,
                        hidden: Bool, hasWindowID: Bool) -> Bool {
        guard role == "AXWindow" || role == "AXDialog", width.isFinite, height.isFinite else { return false }
        if ["AXFloatingWindow", "AXSystemFloatingWindow", "AXUnknown"].contains(subrole) { return false }
        // A valid window may have zero geometry while hidden/minimized (for example WeChat).
        if width >= 60 && height >= 45 { return true }
        return hasWindowID && (minimized || hidden)
    }
}

enum WindowDiscoveryPolicy {
    /// WindowServer retains surfaces for closed windows and auxiliary UI. A screenshot is not a live window.
    static func includesUnboundSurface(accessibilityTrusted: Bool) -> Bool { !accessibilityTrusted }
    static func includesWindowlessApp(accessibilityTrusted: Bool, windowListAvailable: Bool, liveWindowCount: Int) -> Bool {
        accessibilityTrusted && windowListAvailable && liveWindowCount == 0
    }
}

enum CompactLayout {
    static func calculate(style: SwitcherStyle, count: Int, availableWidth: Double, availableHeight: Double,
                          preferredWidth: Double, adaptive: Bool) -> ThumbnailLayout {
        let scale = min(1.57, max(0.65, preferredWidth / 230))
        if style == .titles {
            let height = adaptive ? (count > 12 ? 42.0 : 49.0) : min(72, max(40, 49 * scale))
            return .init(columns: 1, width: min(availableWidth, 850 * (adaptive ? 1 : scale)), height: height)
        }
        let gap = 12.0, count = max(1, count)
        var width = min(222, max(110, 142 * scale))
        if adaptive {
            var best = 110.0
            for columns in 1...min(count, 9) {
                let rows = ceil(Double(count) / Double(columns))
                let w = min(180, min((availableWidth - Double(columns - 1) * gap) / Double(columns),
                                    (availableHeight - (rows - 1) * gap) / rows * 142 / 151))
                if w >= 110 && w > best { best = w }
            }
            width = best
        }
        let columns = min(count, max(1, Int((availableWidth + gap) / (width + gap))))
        return .init(columns: columns, width: width, height: width * 151 / 142)
    }
}

struct SettingSearchEntry: Identifiable {
    let section: Int
    let title: String
    let searchable: String
    var id: String { "\(section):\(title)" }
    init(_ section: Int, _ title: String, _ keywords: String = "") {
        self.section = section; self.title = title
        searchable = SettingSearchIndex.normalize(title + " " + keywords)
    }
}
enum SettingSearchIndex {
    static func normalize(_ text: String) -> String {
        let plain = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let latin = text.applyingTransform(.toLatin, reverse: false)?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) ?? text
        return plain.lowercased() + " " + latin.replacingOccurrences(of: " ", with: "").lowercased()
    }
    // Sections: 0 切换方案, 1 搜索与按键, 2 外观与预览, 3 鼠标与触控板, 4 例外, 5 权限, 6 通用, 7 菜单栏.
    static let entries: [SettingSearchEntry] = [
        .init(0, "方案", "名称 快捷键 松开 新建 删除 ⌘Tab command tab F13 功能键 shortcut"),
        .init(0, "显示哪些窗口", "应用 桌面 屏幕 最小化 隐藏 全屏 没有窗口 标签页 范围"),
        .init(0, "排序与外观", "排序 分组 合成一组 每个应用 样式 主题 尺寸 预览"),
        .init(1, "面板输入方式", "直接 搜索 传统 单键"), .init(1, "显示面板搜索提示", "search hint"),
        .init(1, "搜索优先显示名称直接匹配的窗口", "排序 匹配 拼音"),
        .init(1, "容忍英文或完整拼音的一处拼写错误", "容错 拼音 typo pinyin"),
        .init(1, "搜索时包含浏览器标签页", "Safari Chrome Edge 标签 tab 浏览器 网页 网址"),
        .init(1, "搜索时包含未打开的应用", "启动 打开 开始菜单 start launcher 应用程序"),
        .init(1, "搜索时包含系统设置页面", "系统设置 偏好设置 蓝牙 网络 显示器 settings preferences"),
        .init(1, "按 Shift 单独反向选择", "反向 上一个 单修饰键"),
        .init(1, "使用方向键选择窗口", "arrow"), .init(1, "使用 H / J / K / L 选择窗口", "vim"),
        .init(1, "面板中的快捷键 · 点击按键可重新录制", "录制 关闭 退出 最小化 按键 半屏 填满 屏幕 置顶"),
        .init(2, "外观", "液态玻璃 liquid glass"), .init(2, "显示样式", "图标 缩略图 列表 style"),
        .init(2, "主题", "浅色 深色 跟随系统 theme"), .init(2, "显示标题", "窗口 应用 名称"),
        .init(2, "过长标题省略位置", "截断 开头 中间 末尾"),
        .init(2, "卡片与列表自动适应窗口数量", "自动尺寸 adaptive"), .init(2, "窗口内容参考尺寸", "缩略图 宽度 大小 尺寸"),
        .init(2, "显示窗口状态图标", "隐藏 最小化 状态 徽标"), .init(2, "显示桌面编号", "space"),
        .init(2, "悬停时在卡片上显示关闭、最小化和全屏按钮", "操作按钮"),
        .init(2, "在应用图标上显示 Dock 未读数", "角标 badge 未读 提醒 微信 邮件"),
        .init(2, "停留或搜索时显示 ⌘1–9 编号", "数字 编号 直达 快速"),
        .init(2, "面板打开时更新选中窗口的预览", "实时 缩略图 live preview"),
        .init(2, "自动放大选中窗口的预览", "大图 预览"), .init(2, "后台保留最新预览（约每 5 秒更新）", "后台 缓存 省电"),
        .init(2, "放大预览淡入", "动画"), .init(2, "面板显示在", "屏幕 鼠标 菜单栏"),
        .init(2, "显示延迟", "delay"), .init(2, "关闭面板时淡出", "动画"),
        .init(3, "Dock 预览", "任务栏 缩略图 taskbar 悬停 预览 Windows"),
        .init(3, "指针停在 Dock 图标上时显示窗口预览", "任务栏 缩略图 taskbar hover dock preview"),
        .init(3, "显示前等待", "延迟 delay Dock 预览"), .init(3, "包含最小化的窗口", "Dock 预览 最小化"),
        .init(3, "鼠标悬停时改变选中窗口", "hover"), .init(3, "切换后移动鼠标", "光标 跨屏"),
        .init(3, "触控板手势", "三指 四指 gesture trackpad 冲突 调度中心"),
        .init(3, "尝试拦截已识别的手势（实验性）", "手势 冲突 Mission Control 调度中心"),
        .init(3, "手势使用独立窗口方案", "手势 筛选"), .init(3, "切换时触控板震动反馈", "haptic"),
        .init(4, "默认筛选 · 每个方案可单独覆盖", "包含 隐藏 最小化"),
        .init(4, "应用例外", "UU远程 远程 桌面 虚拟机 规则 忽略 标识"), .init(4, "窗口关键词排除", "排除 标题"),
        .init(5, "权限与隐私", "屏幕录制 辅助功能 screen recording 入门 引导"),
        .init(6, "切换窗口的方式", "窗口服务 辅助功能 聚焦 焦点 focus skylight"),
        .init(6, "VoiceOver 开启时保持面板打开", "旁白 屏幕朗读 辅助功能"),
        .init(6, "显示菜单栏图标"), .init(6, "菜单栏图标", "彩色 实心 线条"), .init(6, "登录时自动启动", "开机 login startup"),
        .init(6, "允许命令行列出和切换窗口", "命令行 终端 CLI terminal list 安全"),
        .init(6, "备份与迁移", "导出 导入 备份 恢复 迁移 默认 export import backup reset"),
        .init(7, "管理菜单栏图标", "隐藏 收起 图标 状态栏 Ice Bartender menu bar 刘海"),
        .init(7, "图标分组", "显示 隐藏 始终隐藏 拖动 分组 应用"),
        .init(7, "由系统管理的图标", "时钟 控制中心 Siri"),
        .init(7, "显示方式", "点按 悬停 指针 空白处 自动收回 快捷键 hover"),
        .init(7, "指针停在菜单栏空白处时显示", "悬停 hover 鼠标"),
        .init(7, "在搜索中包含菜单栏图标", "搜索 打开 菜单")
    ]
    static func results(_ query: String) -> [SettingSearchEntry] {
        let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return [] }
        return entries.filter { entry in terms.allSatisfy { entry.searchable.contains($0) } }.sorted { a, b in
            let exactA = a.title.lowercased().contains(query.lowercased()), exactB = b.title.lowercased().contains(query.lowercased())
            if exactA != exactB { return exactA }
            return (a.section, a.title) < (b.section, b.title)
        }
    }
}

struct RefreshTicketQueue<Callback> {
    private var revision = 0
    private var pending: [(Int, Callback)] = []
    var latestPending: Int? { pending.last?.0 }
    mutating func append(_ callback: Callback) -> Int {
        revision += 1; pending.append((revision, callback)); return revision
    }
    mutating func finish(upTo revision: Int) -> [Callback] {
        let callbacks = pending.prefix { $0.0 <= revision }.map { $0.1 }
        pending.removeFirst(callbacks.count)
        return callbacks
    }
}

struct SettingsEditSession<Value: Equatable> {
    var draft: Value
    private(set) var saved: Value
    var isDirty: Bool { draft != saved }
    init(_ value: Value) { draft = value; saved = value }
    mutating func synchronize(_ value: Value) {
        if !isDirty { draft = value }
        saved = value
    }
    mutating func commit() { saved = draft }
    mutating func discard() { draft = saved }
}

struct PreviewRequestQueue<Key: Hashable> {
    private(set) var keys: [Key] = []
    mutating func enqueue(_ key: Key, urgent: Bool) {
        if let index = keys.firstIndex(of: key) {
            if !urgent { return }
            keys.remove(at: index)
        }
        if urgent { keys.insert(key, at: 0) } else { keys.append(key) }
    }
    mutating func pop(excluding blocked: Set<Key> = []) -> Key? {
        guard let index = keys.firstIndex(where: { !blocked.contains($0) }) else { return nil }
        return keys.remove(at: index)
    }
    mutating func removeAll() { keys.removeAll() }
}

struct PreviewCacheBudget<Key: Hashable> {
    let maximumBytes: Int
    let maximumCount: Int
    private var costs: [Key: Int] = [:]
    private var order: [Key] = []
    private(set) var totalBytes = 0
    init(maximumBytes: Int = 32 * 1024 * 1024, maximumCount: Int = 64) {
        self.maximumBytes = max(0, maximumBytes); self.maximumCount = max(0, maximumCount)
    }
    mutating func store(_ key: Key, bytes: Int) -> [Key] {
        totalBytes -= costs[key] ?? 0
        costs[key] = max(0, bytes); totalBytes += costs[key] ?? 0
        order.removeAll { $0 == key }; order.append(key)
        var removed: [Key] = []
        while totalBytes > maximumBytes || costs.count > maximumCount {
            guard !order.isEmpty else { break }
            let oldest = order.removeFirst()
            totalBytes -= costs.removeValue(forKey: oldest) ?? 0; removed.append(oldest)
        }
        return removed
    }
    mutating func retain(_ keys: Set<Key>) {
        for key in Array(costs.keys) where !keys.contains(key) { totalBytes -= costs.removeValue(forKey: key) ?? 0 }
        order.removeAll { !keys.contains($0) }
    }
}

struct LatencySeries {
    private(set) var values: [Double] = []
    let limit: Int
    init(limit: Int = 120) { self.limit = max(1, limit) }
    mutating func record(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        values.append(milliseconds)
        if values.count > limit { values.removeFirst(values.count - limit) }
    }
    var summary: [String: Double] {
        guard !values.isEmpty else { return [:] }
        let sorted = values.sorted()
        func percentile(_ p: Double) -> Double { sorted[max(0, Int(ceil(Double(sorted.count) * p)) - 1)] }
        return ["count": Double(values.count), "p50_ms": percentile(0.5), "p95_ms": percentile(0.95), "maximum_ms": sorted.last ?? 0]
    }
}

final class RuntimeDiagnostics {
    static let shared = RuntimeDiagnostics()
    private var timings: [String: LatencySeries] = [:]
    func record(_ name: String, since start: TimeInterval) {
        var series = timings[name] ?? LatencySeries()
        series.record(milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000)
        timings[name] = series
    }
    var summary: [String: [String: Double]] { timings.mapValues(\.summary) }
}
