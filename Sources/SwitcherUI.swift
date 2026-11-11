import AppKit
import SwiftUI
import ApplicationServices
import UniformTypeIdentifiers

/// A full-resolution frame of one window for the large preview and the search detail pane.
struct ZoomFrame {
    let id: String
    let image: NSImage
}

final class SwitcherState: ObservableObject {
    @Published var query = "" { didSet { guard query != oldValue else { return }; if !query.isEmpty { sticky = true }; refilter(reset: true); onQueryChange?(query) } }
    var onQueryChange: ((String) -> Void)?
    /// Rows made from what was typed: a sum's answer, a web search.
    var queryItems: ((String) -> [WindowHandle])?
    var onRevealFile: ((String) -> Void)?
    @Published var searchVisible = false
    @Published var items: [WindowHandle] = []
    @Published var selectedIndex = 0 { didSet { if selectedIndex != oldValue { onSelectionChanged?() } } }
    @Published var hoveredID: String?
    @Published var images: [String: NSImage] = [:]
    @Published var style: SwitcherStyle = .thumbnails
    /// Grid for the icon and list styles.
    @Published var layout = ThumbnailLayout(columns: 3, width: 230, height: 239)
    /// Rows of shape-following cards for the thumbnail style.
    @Published var flow = FlowLayout(rows: [], widths: [], thumbnailHeight: 150, gap: 14)
    @Published var loading = false
    /// The panel stays open: the toolbar appears, so the frame is recalculated.
    @Published var sticky = false { didSet { if sticky != oldValue { onLayout?() } } }
    @Published var message = ""
    @Published var messageIsError = false
    @Published var actionPending = false
    @Published var searchFocusRequest = 0
    var selectSearchText = false
    @Published var isDemo = false
    @Published var zoomImage: ZoomFrame?
    /// Dock badge text by process id, such as an unread count.
    @Published var badges: [Int32: String] = [:]
    @Published var dropTargetID: String?
    var all: [WindowHandle] = []
    /// Browser tabs found for this search session; kept apart so window refreshes do not drop them.
    var extraItems: [WindowHandle] = []
    /// 一瞥's own settings window while it is open; window refreshes replace `all`, which never includes it.
    var ownItems: [WindowHandle] = []
    var habits = SearchHabits()
    var pinnedIDs = Set<String>()
    /// When grouping by app, the app whose windows are currently expanded.
    var expandedApp: Int32?
    var settings = UserSettings.defaults
    var profile = ShortcutProfile.defaults()[0]
    var frontPID: Int32?
    var displayID: UInt32?
    var cursor: CGPoint?
    var onSelect: ((Int, Bool) -> Void)?
    var onAction: ((WindowAction) -> Void)?
    var onStyle: ((SwitcherStyle) -> Void)?
    var onLayout: (() -> Void)?
    var onPermission: (() -> Void)?
    var onPin: (() -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onWindowAction: ((Int, WindowAction) -> Void)?
    var onPreviewVisibility: ((Set<String>) -> Void)?
    var onTogglePin: ((String) -> Void)?
    var onDropFiles: ((String, [URL]) -> Void)?
    private(set) var visiblePreviewIDs: Set<String> = []
    private var previewBudget = PreviewCacheBudget<String>()
    var previewBytes: Int { previewBudget.totalBytes }
    var selected: WindowHandle? { items.indices.contains(selectedIndex) ? items[selectedIndex] : nil }
    var showsToolbar: Bool { sticky && !searchVisible }
    /// How the selected result matched, for the pill beside the search field.
    var matchLabel: String? {
        guard searchVisible, !query.isEmpty, let selected else { return nil }
        return WindowSearch.matchKind(selected.descriptor, query: query, allowTypos: settings.advanced.searchTypos, skips: settings.advanced.searchSkips, shuangpin: settings.advanced.shuangpin)?.label
    }
    func isAtEnd(_ d: WindowDescriptor) -> Bool { WindowSearch.isAtEnd(d, settings: settings, profile: profile) }
    /// In the list style, a divider separates windows placed at the end (minimized, no window …).
    var atEndDividerIndex: Int? {
        guard style == .titles, query.isEmpty, !searchVisible else { return nil }
        guard let index = items.firstIndex(where: { isAtEnd($0.descriptor) }), index > 0 else { return nil }
        return index
    }
    func setVisiblePreviews(_ ids: Set<String>) {
        guard ids != visiblePreviewIDs else { return }
        visiblePreviewIDs = ids; onPreviewVisibility?(ids)
    }
    func retainPreviews(_ ids: Set<String>) {
        previewBudget.retain(ids)
        images = images.filter { ids.contains($0.key) }
    }
    func storePreview(_ id: String, image: NSImage) {
        let pixelBytes = image.representations.map { max(1, $0.pixelsWide) * max(1, $0.pixelsHigh) * 4 }.max()
            ?? max(1, Int(image.size.width)) * max(1, Int(image.size.height)) * 4
        // Tabs share their parent window's capture; keep the selected entry most recent.
        let windowID = all.first { $0.id == id }?.descriptor.windowID
        var targets = windowID.map { window in all.filter { $0.descriptor.windowID == window }.map(\.id) } ?? [id]
        if let selectedID = selected?.id, let index = targets.firstIndex(of: selectedID) { targets.remove(at: index); targets.append(selectedID) }
        var updated = images
        for target in targets {
            updated[target] = image
            for evicted in previewBudget.store(target, bytes: pixelBytes) { updated.removeValue(forKey: evicted) }
        }
        images = updated
    }
    func refilter(reset: Bool) {
        let start = ProcessInfo.processInfo.systemUptime
        let source = all + ownItems + extraItems + (queryItems?(query) ?? [])
        let pinned = pinnedIDs
        let descriptors = WindowSearch.filtered(source.map { handle in
                var descriptor = handle.descriptor; descriptor.pinned = pinned.contains(descriptor.id); return descriptor
            }, settings: settings, profile: profile, frontPID: frontPID, displayID: displayID, query: query,
            cursorX: cursor.map { Double($0.x) }, cursorY: cursor.map { Double($0.y) }, expandedApp: expandedApp,
            learned: settings.advanced.searchLearning ? habits.scores(for: query, now: Date.timeIntervalSinceReferenceDate) : [:])
        let handles = Dictionary(source.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let previousID = selected?.id
        // Keep the filtered descriptor (pin and group count) with the handle that the card shows.
        items = descriptors.compactMap { descriptor in handles[descriptor.id].map { $0.with(descriptor) } }
        if reset { selectedIndex = 0 }
        else if let previousID, let index = items.firstIndex(where: { $0.id == previousID }) {
            // Results that arrive later, such as files, never take the selection: Return does what it showed a moment ago.
            selectedIndex = index
        }
        else { selectedIndex = min(selectedIndex, max(0, items.count - 1)) }
        if previousID != selected?.id { onSelectionChanged?() }
        onLayout?()
        RuntimeDiagnostics.shared.record("filter", since: start)
    }
    func move(_ step: Int) {
        guard !items.isEmpty else { return }
        message = ""
        selectedIndex = WindowNavigation.linear(index: selectedIndex, count: items.count, step: step)
        if settings.advanced.haptics { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    }
    func moveVertically(down: Bool) {
        guard !items.isEmpty else { return }
        let target: Int
        if searchVisible || style == .titles {
            target = WindowNavigation.vertical(index: selectedIndex, count: items.count, columns: 1, down: down)
        } else if style == .thumbnails {
            target = min(items.count - 1, flow.vertical(from: selectedIndex, down: down))
        } else {
            target = WindowNavigation.vertical(index: selectedIndex, count: items.count, columns: layout.columns, down: down)
        }
        move(target - selectedIndex)
    }
    func setMessage(_ text: String, error: Bool = false) {
        messageIsError = error; message = text
        if !text.isEmpty && NSWorkspace.shared.isVoiceOverEnabled {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }
    /// The key that runs a panel command, shown as a symbol when it is the default one.
    func keyLabel(_ command: PanelCommand, symbol: String) -> String {
        guard let binding = settings.advanced.bindings.first(where: { $0.command == command && $0.enabled }) else { return symbol }
        if binding.keyCode == command.defaultCode && binding.modifiers == command.defaultModifiers { return symbol }
        return binding.modifiers.symbols + KeyboardKeyName.label(for: binding.keyCode)
    }
    func selectWindow(_ id: String, commit: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        onSelect?(index, commit)
    }
    func actOnWindow(_ id: String, action: WindowAction) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        onWindowAction?(index, action)
    }
    /// Whether ⌘1–9 hints are shown: only when the panel is lingering, never during a quick ⌥Tab.
    func numberHint(for index: Int) -> String? {
        guard settings.advanced.numberHints, index < 9, sticky || searchVisible, !isDemo else { return nil }
        return "⌘\(index + 1)"
    }
    func setDropTarget(_ id: String, active: Bool) {
        if active {
            dropTargetID = id
            if let index = items.firstIndex(where: { $0.id == id }), index != selectedIndex { onSelect?(index, false) }
        } else if dropTargetID == id {
            dropTargetID = nil
        }
    }
    /// Collects the file URLs of a drop and hands them to the app that owns the card.
    func dropFiles(_ providers: [NSItemProvider], on id: String) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        var urls: [URL] = []
        let lock = NSLock(), group = DispatchGroup()
        for provider in fileProviders {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.dropTargetID = nil
            if !urls.isEmpty { self?.onDropFiles?(id, urls) }
        }
        return true
    }
    func hover(_ hovering: Bool, index: Int, id: String) {
        hoveredID = hovering ? id : (hoveredID == id ? nil : hoveredID)
        if hovering && settings.mouseHoverEnabled { selectWindow(id, commit: false) }
    }
    /// Short facts under a window's title: its app, state, desktop and unread count.
    func details(for d: WindowDescriptor, includeApp: Bool = true) -> [String] {
        var parts: [String] = []
        if includeApp { parts.append(d.appName) }
        if d.browserTab { parts.append(d.subtitle.flatMap { $0.isEmpty ? nil : $0 } ?? "浏览器标签页") }
        if d.menuBarItem { parts.append(d.subtitle ?? "菜单栏图标") }
        if let kind = d.launcher {
            // The English name, when the title is localized, then what selecting it does.
            return (includeApp && d.appName != d.title ? [d.appName] : []) + [kind.label]
        }
        if d.groupCount > 1 { parts.append("\(d.groupCount) 个窗口") }
        if d.minimized { parts.append("已最小化") }
        if d.hidden { parts.append("已隐藏") }
        if d.fullscreen { parts.append("全屏") }
        if d.windowless { parts.append("没有打开的窗口") }
        if !d.spaceNumbers.isEmpty { parts.append("桌面 \(d.spaceNumbers.map(String.init).joined(separator: ","))") }
        if d.pinned { parts.append("已置顶") }
        if let badge = badges[d.pid] { parts.append("\(badge) 条提醒") }
        return parts
    }
    func label(for d: WindowDescriptor) -> String {
        var parts = d.displayTitle == d.appName ? [d.appName] : [d.appName, d.displayTitle]
        parts += details(for: d, includeApp: false)
        if !d.tabRepresentative { parts.append("标签页") }
        return parts.joined(separator: "，")
    }
}

private struct WindowAccessibility: ViewModifier {
    @ObservedObject var state: SwitcherState
    let item: WindowHandle
    @AccessibilityFocusState(for: .voiceOver) private var focused: Bool
    private var selected: Bool { state.selected?.id == item.id }
    func body(content: Content) -> some View {
        content.accessibilityLabel(state.label(for: item.descriptor))
            .accessibilityValue("\(selected ? "已选中，" : "")第 \((state.items.firstIndex(where: { $0.id == item.id }) ?? 0) + 1) 项，共 \(state.items.count) 项")
            .accessibilityHint("激活以切换；更多窗口操作可在辅助功能操作菜单中选择。")
            .accessibilityFocused($focused)
            .accessibilityAction(named: Text("最小化或还原窗口")) { if !item.descriptor.windowless { state.actOnWindow(item.id, action: .minimize) } }
            .accessibilityAction(named: Text("进入或退出全屏")) { if !item.descriptor.windowless { state.actOnWindow(item.id, action: .fullscreen) } }
            .accessibilityAction(named: Text("关闭窗口")) { if !item.descriptor.windowless && item.tab == nil { state.actOnWindow(item.id, action: .close) } }
            .accessibilityAction(named: Text("隐藏或显示应用")) { state.actOnWindow(item.id, action: .hideApp) }
            .onChange(of: focused) { _, value in if value { state.selectWindow(item.id, commit: false) } }
            .onChange(of: state.selected?.id) { _, value in
                if NSWorkspace.shared.isVoiceOverEnabled && !state.searchVisible && value == item.id { focused = true }
            }
            .onAppear { if NSWorkspace.shared.isVoiceOverEnabled && selected && !state.searchVisible { focused = true } }
    }
}

private struct ThumbnailFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

extension TitleCut {
    var truncation: Text.TruncationMode { switch self { case .start: return .head; case .middle: return .middle; case .end: return .tail } }
}

/// Text with the characters a search matched marked in amber.
private func highlighted(_ text: String, query: String, advanced: AdvancedSettings) -> AttributedString {
    var result = AttributedString(text)
    guard !query.isEmpty else { return result }
    let characters = result.characters
    for range in WindowSearch.highlights(in: text, query: query, skips: advanced.searchSkips, shuangpin: advanced.shuangpin) where range.upperBound <= characters.count {
        let start = characters.index(characters.startIndex, offsetBy: range.lowerBound)
        let end = characters.index(characters.startIndex, offsetBy: range.upperBound)
        result[start..<end][AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = GlanceDesign.highlight
    }
    return result
}

struct SearchBox: NSViewRepresentable {
    @ObservedObject var state: SwitcherState
    var fontSize: CGFloat = 22
    func makeCoordinator() -> Coordinator { Coordinator(state) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "搜索窗口、应用名称或拼音"
        field.font = .systemFont(ofSize: fontSize, weight: .medium)
        field.controlSize = .large
        field.isBezeled = false
        field.drawsBackground = false
        (field.cell as? NSSearchFieldCell)?.searchButtonCell = nil
        field.focusRingType = .none
        field.sendsSearchStringImmediately = true
        field.maximumRecents = 0
        field.delegate = context.coordinator
        field.setAccessibilityLabel("搜索窗口")
        context.coordinator.focusRequest = state.searchFocusRequest
        DispatchQueue.main.async { Self.focus(field, selectAll: false) }
        return field
    }
    func updateNSView(_ view: NSSearchField, context: Context) {
        if view.stringValue != state.query { view.stringValue = state.query }
        if context.coordinator.focusRequest != state.searchFocusRequest {
            context.coordinator.focusRequest = state.searchFocusRequest
            let selectAll = state.selectSearchText
            DispatchQueue.main.async { Self.focus(view, selectAll: selectAll) }
        }
    }
    private static func focus(_ field: NSSearchField, selectAll: Bool) {
        field.window?.makeFirstResponder(field)
        if selectAll { field.selectText(nil) }
        // An amber caret, matching the selection colour.
        (field.currentEditor() as? NSTextView)?.insertionPointColor = NSColor(srgbRed: 0.94, green: 0.63, blue: 0.19, alpha: 1)
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let state: SwitcherState
        var focusRequest = 0
        init(_ state: SwitcherState) { self.state = state }
        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            state.query = field.stringValue
        }
    }
}

/// Window state as small icons: minimized, hidden, full screen, another desktop, desktop number.
private struct StatusIcons: View {
    let item: WindowDescriptor
    let options: AdvancedSettings
    private var symbols: [(String, String)] {
        guard options.statusBadges else { return [] }
        var result: [(String, String)] = []
        if item.browserTab { result.append(("globe", "浏览器标签页")) }
        if item.menuBarItem { result.append(("menubar.rectangle", "菜单栏图标")) }
        if let kind = item.launcher { result.append((kind.symbol, kind.label)) }
        if item.minimized { result.append(("arrow.down.to.line", "已最小化")) }
        if item.hidden { result.append(("eye.slash", "已隐藏")) }
        if item.fullscreen { result.append(("arrow.up.left.and.arrow.down.right", "全屏")) }
        if item.windowless { result.append(("app.dashed", "没有打开的窗口")) }
        if !item.tabRepresentative { result.append(("rectangle.stack", "标签页")) }
        if !item.onCurrentSpace && !item.minimized && !item.hidden && !item.windowless && !item.searchOnly
            && !(options.spaceNumbers && !item.spaceNumbers.isEmpty) { result.append(("square.on.square.dashed", "在其他桌面")) }
        return result
    }
    var body: some View {
        HStack(spacing: 5) {
            ForEach(symbols, id: \.0) { entry in
                Image(systemName: entry.0).font(.system(size: 10, weight: .semibold)).foregroundStyle(GlanceDesign.secondary).help(entry.1)
            }
            if options.spaceNumbers && !item.spaceNumbers.isEmpty {
                Text(item.spaceNumbers.map(String.init).joined(separator: ","))
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(GlanceDesign.secondary)
                    .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(GlanceDesign.secondary.opacity(0.7), lineWidth: 1))
                    .help("在桌面 \(item.spaceNumbers.map(String.init).joined(separator: ","))")
            }
        }.accessibilityHidden(true)
    }
}

private struct WindowMenu: ViewModifier {
    @ObservedObject var state: SwitcherState
    let item: WindowHandle
    func body(content: Content) -> some View {
        content.contextMenu { WindowActionsMenu(state: state, item: item, includeSwitch: true) }
    }
}

/// Window and app actions for a card's context menu and the ⋯ buttons.
private struct WindowActionsMenu: View {
    @ObservedObject var state: SwitcherState
    let item: WindowHandle
    var includeSwitch = false
    var body: some View {
        Group {
            if includeSwitch {
                Button(item.descriptor.menuBarItem ? "打开菜单" : (item.descriptor.launcher?.action ?? "切换到窗口")) { state.selectWindow(item.id, commit: true) }
            }
            if item.descriptor.launcher == .file, let path = item.descriptor.launchTarget {
                Button("在访达中显示") { state.onRevealFile?(path) }
            }
            if !item.descriptor.searchOnly && !item.descriptor.settingsWindow {
                Button(item.descriptor.pinned ? "取消置顶" : "置顶这个窗口") { state.onTogglePin?(item.id) }
            }
            if !item.descriptor.windowless && !item.descriptor.searchOnly && !item.descriptor.settingsWindow {
                Button(item.descriptor.minimized ? "还原窗口" : "最小化窗口") { state.actOnWindow(item.id, action: .minimize) }
                Button(item.descriptor.fullscreen ? "退出全屏" : "进入全屏") { state.actOnWindow(item.id, action: .fullscreen) }
                Button("关闭窗口") { state.actOnWindow(item.id, action: .close) }.disabled(item.tab != nil)
                Menu("窗口位置") {
                    Button("放到左半屏") { state.actOnWindow(item.id, action: .tileLeft) }
                    Button("放到右半屏") { state.actOnWindow(item.id, action: .tileRight) }
                    Button("填满屏幕") { state.actOnWindow(item.id, action: .maximize) }
                    Button("移到下一块屏幕") { state.actOnWindow(item.id, action: .nextScreen) }.disabled(NSScreen.screens.count < 2)
                }
                Divider()
            }
            // A menu bar result may belong to a system process, and the settings window's app is 一瞥 itself;
            // app actions stay with other apps' real windows.
            if !item.descriptor.menuBarItem && item.descriptor.launcher == nil && !item.descriptor.settingsWindow {
                Button(item.descriptor.hidden ? "显示应用" : "隐藏应用") { state.actOnWindow(item.id, action: .hideApp) }
                Button("退出 \(item.descriptor.appName)") { state.actOnWindow(item.id, action: .quitApp) }
            }
        }.disabled(state.actionPending || state.isDemo || state.loading)
    }
}

/// App icon with the Dock badge (an unread count, for example) in its corner.
private struct BadgedIcon: View {
    let icon: NSImage?
    let size: CGFloat
    let badge: String?
    var body: some View {
        Group {
            if let icon { Image(nsImage: icon).resizable().interpolation(.high) }
            else { Image(systemName: "macwindow").resizable().scaledToFit().foregroundStyle(GlanceDesign.secondary) }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .topTrailing) {
            if let badge {
                Text(badge.count > 4 ? String(badge.prefix(3)) + "…" : badge)
                    .font(.system(size: max(9, size * 0.3), weight: .bold)).foregroundStyle(.white).lineLimit(1)
                    .padding(.horizontal, 4).frame(minWidth: max(15, size * 0.5), minHeight: max(15, size * 0.5))
                    .background(GlanceDesign.badge, in: Capsule())
                    .overlay(Capsule().stroke(GlanceDesign.surface, lineWidth: 1.5))
                    .fixedSize()
                    .offset(x: size * 0.3, y: -size * 0.3)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Pin, folded window count and the ⌘N hint.
private struct CardMarks: View {
    @ObservedObject var state: SwitcherState
    let item: WindowHandle
    let index: Int
    var showsCount = true
    var body: some View {
        HStack(spacing: 5) {
            if item.descriptor.pinned {
                Image(systemName: "pin.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(GlanceDesign.accentText)
                    .help("已置顶").accessibilityHidden(true)
            }
            if showsCount && item.descriptor.groupCount > 1 {
                Text("\(item.descriptor.groupCount) 个窗口").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).frame(height: 18).background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .help("按 ↓ 展开这个应用的窗口")
            }
            if let hint = state.numberHint(for: index) {
                Text(hint).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).frame(height: 18)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Dropping files on a card opens them with that card's app, then switches to it.
private struct CardDrop: ViewModifier {
    @ObservedObject var state: SwitcherState
    let item: WindowHandle
    func body(content: Content) -> some View {
        content.onDrop(of: [UTType.fileURL], isTargeted: Binding(get: { state.dropTargetID == item.id },
                                                                set: { state.setDropTarget(item.id, active: $0) })) { providers in
            state.dropFiles(providers, on: item.id)
        }
    }
}

/// Card background. Idle cards sit straight on the glass; hovering brightens them a little, and the
/// selected card is lit and ringed in amber.
private struct CardSurface: ViewModifier {
    let selected: Bool
    let hovered: Bool
    var radius: CGFloat = GlanceDesign.cardRadius
    var ring: CGFloat = 3
    var lift = true
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(selected ? GlanceDesign.raised : (hovered ? GlanceDesign.hover : Color.clear))
            }
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: radius + ring / 2, style: .continuous)
                        .stroke(GlanceDesign.accent, lineWidth: ring).padding(-ring / 2)
                }
            }
            .shadow(color: .black.opacity(selected ? 0.16 : 0), radius: 12, y: 6)
            .offset(y: selected && lift ? -3 : 0)
    }
}

/// Selection for list rows: an amber wash with a thin amber edge; hovering adds a faint fill.
private struct RowSelection: View {
    let selected: Bool
    let hovered: Bool
    var radius: CGFloat = 12
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if selected {
            shape.fill(GlanceDesign.selected).overlay(shape.stroke(GlanceDesign.accent, lineWidth: 1.5))
        } else {
            shape.fill(.quinary).opacity(hovered ? 1 : 0)
        }
    }
}

/// Small controls and labels that float over a window preview. On macOS 26 and later they are glass,
/// which keeps them legible over any picture; before that, a material capsule.
struct FloatingCapsule: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule(style: .continuous))
        } else {
            content.background(.regularMaterial, in: Capsule(style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
    }
}

private struct TileButtons: View {
    @ObservedObject var state: SwitcherState
    let item: WindowHandle
    var body: some View {
        HStack(spacing: 2) {
            control("最小化 / 还原", symbol: "minus", action: .minimize)
            control("全屏 / 退出", symbol: "arrow.up.left.and.arrow.down.right", action: .fullscreen)
            control("关闭窗口", symbol: "xmark", action: .close).disabled(item.tab != nil)
        }.padding(3).modifier(FloatingCapsule())
            .disabled(state.actionPending || state.isDemo || state.loading)
    }
    private func control(_ title: String, symbol: String, action: WindowAction) -> some View {
        Button { state.actOnWindow(item.id, action: action) } label: {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                .foregroundStyle(action == .close ? AnyShapeStyle(Color.red.opacity(0.9)) : AnyShapeStyle(HierarchicalShapeStyle.primary))
                .frame(width: 22, height: 22).contentShape(Circle())
        }.buttonStyle(.plain).help(title).accessibilityLabel("\(title)：\(item.descriptor.displayTitle)")
    }
}

/// A window preview: the live capture, or the app icon while there is none.
private struct PreviewImage: View {
    @ObservedObject var state: SwitcherState
    let item: WindowHandle
    var iconSize: CGFloat = 36
    var preferSharp = false
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quinary)
            if preferSharp, let zoom = state.zoomImage, zoom.id == item.id {
                Image(nsImage: zoom.image).resizable().interpolation(.high).scaledToFit().padding(4)
            } else if let image = state.images[item.id] {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit().padding(4)
            } else {
                VStack(spacing: 8) {
                    if let icon = item.icon { Image(nsImage: icon).resizable().frame(width: iconSize, height: iconSize) }
                    Text(placeholder).font(.system(size: 11)).foregroundStyle(GlanceDesign.secondary)
                }
            }
        }.clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    private var placeholder: String {
        if item.descriptor.browserTab { return item.descriptor.subtitle ?? "浏览器标签页" }
        if item.descriptor.menuBarItem { return "按 ↩ 打开它的菜单" }
        if let kind = item.descriptor.launcher { return kind.hint }
        if item.descriptor.settingsWindow { return "一瞥的设置窗口" }
        if item.descriptor.windowless { return "没有打开的窗口" }
        if item.descriptor.minimized { return "窗口已最小化" }
        return "暂时没有预览"
    }
}

// MARK: - Cards

private struct ThumbnailCard: View {
    @ObservedObject var state: SwitcherState
    let item: WindowHandle
    let index: Int
    let width: CGFloat
    let thumbnailHeight: CGFloat
    private var selected: Bool { state.selectedIndex == index || state.dropTargetID == item.id }
    var body: some View {
        Button { state.selectWindow(item.id, commit: true) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    BadgedIcon(icon: item.icon, size: 20, badge: state.badges[item.descriptor.pid])
                    Text(state.settings.advanced.titleDisplay.text(item.descriptor))
                        .font(.system(size: 12, weight: selected ? .bold : .semibold)).foregroundStyle(GlanceDesign.ink)
                        .lineLimit(1).truncationMode(state.settings.advanced.titleCut.truncation)
                    Spacer(minLength: 2)
                    StatusIcons(item: item.descriptor, options: state.settings.advanced)
                    CardMarks(state: state, item: item, index: index, showsCount: false)
                }.frame(height: 20)
                PreviewImage(state: state, item: item)
                    .frame(width: max(40, width - FlowLayout.cardPadding), height: thumbnailHeight)
                    .opacity(item.descriptor.minimized || item.descriptor.hidden ? 0.55 : 1)
            }.padding(10).frame(width: width, height: thumbnailHeight + FlowLayout.cardChrome, alignment: .top)
                .modifier(CardSurface(selected: selected, hovered: state.hoveredID == item.id))
        }.buttonStyle(.plain)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: ThumbnailFrames.self, value: [item.id: proxy.frame(in: .named("previewViewport"))])
            })
            .modifier(WindowAccessibility(state: state, item: item))
            .help(item.descriptor.displayTitle)
            .overlay(alignment: .bottomTrailing) {
                if state.settings.advanced.tileButtons && !item.descriptor.windowless && !item.descriptor.searchOnly && !item.descriptor.settingsWindow && state.hoveredID == item.id {
                    TileButtons(state: state, item: item).padding(16)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if item.descriptor.groupCount > 1 {
                    Text("\(item.descriptor.groupCount) 个窗口").font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8).frame(height: 20).modifier(FloatingCapsule()).padding(16)
                }
            }
            .onHover { state.hover($0, index: index, id: item.id) }
            .modifier(WindowMenu(state: state, item: item))
            .modifier(CardDrop(state: state, item: item))
    }
}

private struct IconCard: View {
    @ObservedObject var state: SwitcherState
    let item: WindowHandle
    let index: Int
    private var scale: CGFloat { state.layout.width / 142 }
    private var selected: Bool { state.selectedIndex == index || state.dropTargetID == item.id }
    var body: some View {
        Button { state.selectWindow(item.id, commit: true) } label: {
            VStack(spacing: 10 * scale) {
                BadgedIcon(icon: item.icon, size: 56 * scale, badge: state.badges[item.descriptor.pid])
                    .opacity(state.isAtEnd(item.descriptor) ? 0.6 : 1)
                Text(item.descriptor.appName).font(.system(size: max(11, 12 * scale), weight: selected ? .bold : .semibold))
                    .foregroundStyle(state.isAtEnd(item.descriptor) ? GlanceDesign.secondary : GlanceDesign.ink).lineLimit(1)
                StatusIcons(item: item.descriptor, options: state.settings.advanced).frame(height: 12)
            }.padding(12 * scale).frame(width: state.layout.width, height: state.layout.height)
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 4) {
                        if item.descriptor.groupCount > 1 {
                            Text("\(item.descriptor.groupCount)").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                                .frame(minWidth: 18, minHeight: 18).background(.quaternary, in: Circle())
                                .help("\(item.descriptor.groupCount) 个窗口，按 ↓ 展开")
                        }
                        CardMarks(state: state, item: item, index: index, showsCount: false)
                    }.padding(8)
                }
                .modifier(CardSurface(selected: selected, hovered: state.hoveredID == item.id, ring: 2.5, lift: false))
        }.buttonStyle(.plain).onHover { state.hover($0, index: index, id: item.id) }
            .modifier(WindowMenu(state: state, item: item))
            .modifier(CardDrop(state: state, item: item))
            .modifier(WindowAccessibility(state: state, item: item))
    }
}

private struct TitleRow: View {
    @ObservedObject var state: SwitcherState
    let item: WindowHandle
    let index: Int
    private var scale: CGFloat { state.layout.height / 49 }
    private var selected: Bool { state.selectedIndex == index || state.dropTargetID == item.id }
    var body: some View {
        let dimmed = state.isAtEnd(item.descriptor)
        Button { state.selectWindow(item.id, commit: true) } label: {
            HStack(spacing: 12) {
                BadgedIcon(icon: item.icon, size: 24 * scale, badge: state.badges[item.descriptor.pid]).opacity(dimmed ? 0.6 : 1)
                Text(state.settings.advanced.titleDisplay.text(item.descriptor))
                    .font(.system(size: max(12, 13 * scale), weight: selected ? .bold : (dimmed ? .regular : .semibold)))
                    .foregroundStyle(dimmed ? GlanceDesign.secondary : GlanceDesign.ink)
                    .lineLimit(1).truncationMode(state.settings.advanced.titleCut.truncation)
                CardMarks(state: state, item: item, index: index)
                Spacer(minLength: 8)
                StatusIcons(item: item.descriptor, options: state.settings.advanced)
                Text(item.descriptor.appName).font(.system(size: max(11, 12 * scale))).foregroundStyle(GlanceDesign.secondary).lineLimit(1)
            }.padding(.horizontal, 12).frame(height: state.layout.height)
                .background { RowSelection(selected: selected, hovered: state.hoveredID == item.id, radius: 10) }
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }.buttonStyle(.plain).onHover { state.hover($0, index: index, id: item.id) }
            .modifier(WindowMenu(state: state, item: item))
            .modifier(CardDrop(state: state, item: item))
            .modifier(WindowAccessibility(state: state, item: item))
    }
}

// MARK: - Panel

struct SwitcherView: View {
    @ObservedObject var state: SwitcherState
    var body: some View {
        Group {
            if state.searchVisible { SearchLayout(state: state) } else { BrowseLayout(state: state) }
        }.modifier(GlancePanelBackdrop())
            .overlay {
                // Glass draws its own lit edge; the older material needs a hairline.
                if !GlanceDesign.usesLiquidGlass {
                    RoundedRectangle(cornerRadius: GlanceDesign.panelRadius, style: .continuous).stroke(GlanceDesign.line.opacity(0.5), lineWidth: 0.5)
                }
            }
            .tint(GlanceDesign.control)
    }
}

/// Permission reminder shared by both layouts.
private struct PermissionNotice: View {
    @ObservedObject var state: SwitcherState
    var needsScreen: Bool
    var body: some View {
        if !state.isDemo && (!AXIsProcessTrusted() || (needsScreen && !CGPreflightScreenCaptureAccess())) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                Text(!AXIsProcessTrusted() ? "开启辅助功能，即可切换窗口。" : "开启屏幕录制，即可显示窗口预览。")
                Spacer()
                Button("设置权限") { state.onPermission?() }.buttonStyle(.link).tint(GlanceDesign.accentText)
            }.font(.system(size: 12)).foregroundStyle(GlanceDesign.secondary).frame(height: PanelChrome.permission)
        }
    }
}

/// Quick switching and the panel that stays open: window cards, then the selected window's title.
private struct BrowseLayout: View {
    @ObservedObject var state: SwitcherState
    var body: some View {
        VStack(spacing: 0) {
            if state.showsToolbar {
                BrowseToolbar(state: state).frame(height: PanelChrome.toolbar - 14).padding(.bottom, 14)
            }
            PermissionNotice(state: state, needsScreen: state.style == .thumbnails)
            WindowContent(state: state)
                .padding(.bottom, PanelChrome.contentBottom)
            if !state.message.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: state.messageIsError ? "exclamationmark.circle" : "checkmark.circle")
                    Text(state.message).lineLimit(1)
                    Spacer(minLength: 0)
                }.font(.system(size: 12)).foregroundStyle(state.messageIsError ? Color.orange : GlanceDesign.secondary)
                    .frame(height: PanelChrome.message)
            }
            SelectionBar(state: state)
        }.padding(.top, PanelChrome.top).padding(.horizontal, PanelChrome.horizontal / 2)
    }
}

private struct BrowseToolbar: View {
    @ObservedObject var state: SwitcherState
    private var controlsAvailable: Bool { state.selected != nil && !state.isDemo && !state.actionPending && !state.loading }
    private var style: Binding<SwitcherStyle> {
        Binding(get: { state.style }, set: { style in
            guard state.style != style else { return }
            state.style = style; state.onStyle?(style)
        })
    }
    var body: some View {
        HStack(spacing: 10) {
            GlanceMark(size: 24)
            Text("一瞥").font(.system(size: 14, weight: .semibold))
            Text(state.loading && state.items.isEmpty ? "读取中" : "\(state.items.count) 个窗口")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).frame(height: 22).background(.quaternary, in: Capsule(style: .continuous))
            if state.loading && !state.items.isEmpty { ProgressView().controlSize(.mini).accessibilityLabel("正在更新窗口") }
            Spacer(minLength: 12)
            // The system segmented control, which takes on the current macOS look by itself.
            Picker("显示样式", selection: style) {
                ForEach(SwitcherStyle.allCases) { option in
                    Label(option.label, systemImage: Self.symbol(option)).labelStyle(.iconOnly).tag(option)
                }
            }.pickerStyle(.segmented).labelsHidden().fixedSize().help("显示样式")
            // Related buttons share one capsule, the way toolbar groups do.
            HStack(spacing: 0) {
                Group {
                    Button { state.onAction?(.minimize) } label: { Image(systemName: "minus") }
                        .help("最小化 / 还原（⌘M）").accessibilityLabel("最小化或还原选中窗口")
                    Button { state.onAction?(.close) } label: { Image(systemName: "xmark") }
                        .help("关闭窗口（⌘W）").accessibilityLabel("关闭选中窗口")
                }.buttonStyle(PanelIconButtonStyle())
                    .disabled(!controlsAvailable || state.selected?.descriptor.windowless == true || state.selected?.descriptor.searchOnly == true || state.selected?.descriptor.settingsWindow == true)
                if let selected = state.selected {
                    Menu { WindowActionsMenu(state: state, item: selected) } label: { Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium)) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(Color.secondary).fixedSize().frame(width: 30, height: 28)
                        .help("更多操作").accessibilityLabel("选中窗口的更多操作")
                        .disabled(!controlsAvailable || selected.descriptor.settingsWindow)
                }
            }.padding(2).background(.quinary, in: Capsule(style: .continuous))
            HStack(spacing: 0) {
                Button { state.onPin?() } label: { Image(systemName: "pin.fill") }
                    .buttonStyle(PanelIconButtonStyle(active: true))
                    .help("取消固定，松开快捷键时即切换").accessibilityLabel("取消固定面板")
                Button { state.onPermission?() } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(PanelIconButtonStyle()).help("设置").accessibilityLabel("打开设置")
            }.padding(2).background(.quinary, in: Capsule(style: .continuous))
        }
    }
    static func symbol(_ style: SwitcherStyle) -> String {
        switch style {
        case .thumbnails: return "rectangle.grid.2x2"
        case .icons: return "square.grid.3x3"
        case .titles: return "list.bullet"
        }
    }
}

private struct WindowContent: View {
    @ObservedObject var state: SwitcherState
    var body: some View {
        ScrollViewReader { scroll in
            GeometryReader { viewport in
                ScrollView {
                    if state.loading && state.items.isEmpty {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                    } else if state.items.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "macwindow").font(.system(size: 26, weight: .light)).foregroundStyle(GlanceDesign.accentText)
                                .frame(width: 56, height: 56).background(GlanceDesign.selected, in: RoundedRectangle(cornerRadius: 16))
                            Text("没有符合条件的窗口").font(.system(size: 15, weight: .semibold)).foregroundStyle(GlanceDesign.ink)
                            Text("可以在设置的“切换方案”中调整窗口范围。").font(.system(size: 12)).foregroundStyle(GlanceDesign.secondary)
                        }.frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        switch state.style {
                        case .thumbnails: thumbnails
                        case .icons: icons
                        case .titles: titles
                        }
                    }
                }.coordinateSpace(name: "previewViewport")
                    .scrollIndicators(.automatic)
                    .onPreferenceChange(ThumbnailFrames.self) { frames in
                        let bounds = CGRect(origin: .zero, size: viewport.size)
                        state.setVisiblePreviews(Set(frames.filter { $0.value.intersects(bounds) && !$0.value.isEmpty }.map(\.key)))
                    }
                    .onChange(of: state.selected?.id) { _, id in if let id { scroll.scrollTo(id, anchor: .center) } }
                    .onChange(of: state.style) { _, _ in if let id = state.selected?.id { scroll.scrollTo(id, anchor: .center) } }
            }
        }
    }
    private var thumbnails: some View {
        let flow = state.flow
        return LazyVStack(spacing: flow.gap) {
            ForEach(Array(flow.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: flow.gap) {
                    ForEach(row, id: \.self) { index in
                        if index < state.items.count && index < flow.widths.count {
                            ThumbnailCard(state: state, item: state.items[index], index: index,
                                          width: flow.widths[index], thumbnailHeight: flow.thumbnailHeight).id(state.items[index].id)
                        }
                    }
                }
            }
        }.padding(.vertical, FlowLayout.verticalInset).padding(.horizontal, FlowLayout.horizontalInset).frame(maxWidth: .infinity)
    }
    private var icons: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(state.layout.width), spacing: 12), count: state.layout.columns), spacing: 12) {
            ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in IconCard(state: state, item: item, index: index).id(item.id) }
        }.padding(4)
            // Lazy cells must be recreated when their presentation changes.
            .id(state.style.rawValue)
    }
    private var titles: some View {
        LazyVStack(spacing: 3) {
            ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                if index == state.atEndDividerIndex {
                    Rectangle().fill(.quaternary).frame(height: 1).padding(.horizontal, 12).padding(.vertical, 5)
                }
                TitleRow(state: state, item: item, index: index).id(item.id)
            }
        }.padding(4)
    }
}

/// The selected window's name and position, with the keys that matter right now.
private struct SelectionBar: View {
    @ObservedObject var state: SwitcherState
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 16, weight: .bold)).foregroundStyle(GlanceDesign.ink).lineLimit(1)
                        .truncationMode(state.settings.advanced.titleCut.truncation)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(GlanceDesign.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 16) {
                    if state.isDemo {
                        Text("界面预览").font(.system(size: 12, weight: .medium)).foregroundStyle(GlanceDesign.secondary)
                    } else {
                        ForEach(hints, id: \.1) { hint in KeyboardHint(key: hint.0, title: hint.1) }
                    }
                }.fixedSize()
            }.padding(.horizontal, 6).frame(height: PanelChrome.selectionBar)
        }
    }
    private var title: String {
        guard let selected = state.selected else { return state.loading ? "正在读取窗口…" : "没有窗口" }
        return selected.descriptor.displayTitle
    }
    private var subtitle: String {
        guard let selected = state.selected else { return " " }
        var parts = state.details(for: selected.descriptor)
        parts.append("第 \(state.selectedIndex + 1) 个，共 \(state.items.count) 个")
        return parts.joined(separator: " · ")
    }
    private var hints: [(String, String)] {
        let advanced = state.settings.advanced
        var result: [(String, String)] = []
        if state.sticky {
            result.append((state.keyLabel(.confirm, symbol: "↵"), "切换"))
            if advanced.numberHints { result.append(("⌘1–9", "直达")) }
            result.append((state.keyLabel(.cancel, symbol: "Esc"), "关闭"))
        } else {
            let release: String
            switch state.profile.releaseBehavior {
            case .focus: release = "松开切换"
            case .hold: release = "松开保持"
            case .search: release = "松开搜索"
            }
            result.append((state.profile.modifiers.isEmpty ? "↵" : state.profile.modifiers.symbols, state.profile.modifiers.isEmpty ? "切换" : release))
            if advanced.shiftSelectsPrevious { result.append(("⇧", "反向")) }
        }
        if state.profile.grouping == .byApp && state.query.isEmpty {
            result.append(state.expandedApp == nil ? ("↓", "展开应用") : ("Esc", "收起"))
        }
        if !state.sticky && advanced.showSearchHint {
            result.append(advanced.inputMode == .search ? ("Aa", "直接输入即搜索") : ("⌘F", "搜索"))
        }
        // Each title appears once, so the same key cannot be listed twice.
        var seen = Set<String>()
        return result.filter { seen.insert($0.1).inserted }
    }
}

// MARK: - Search

/// Search: a capsule search field on top, results on the left and the selected window, large, on the right.
/// Areas are set apart by spacing and soft fills rather than hairlines, as elsewhere on Liquid Glass.
private struct SearchLayout: View {
    @ObservedObject var state: SwitcherState
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .medium)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                SearchBox(state: state).frame(height: 36)
                if let label = state.matchLabel {
                    Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(GlanceDesign.accentText)
                        .padding(.horizontal, 10).frame(height: 24).background(GlanceDesign.selected, in: Capsule(style: .continuous))
                        .accessibilityLabel("匹配方式：\(label)")
                }
                if state.loading { ProgressView().controlSize(.small).accessibilityLabel("正在更新窗口") }
                Button { state.onPermission?() } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(PanelIconButtonStyle()).help("设置").accessibilityLabel("打开设置")
            }.padding(.leading, 20).padding(.trailing, 12).frame(height: 54)
                .background(.quaternary, in: Capsule(style: .continuous))
                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)
            PermissionNotice(state: state, needsScreen: true).padding(.horizontal, 26)
            HStack(spacing: 0) {
                SearchResults(state: state).frame(width: 384)
                SearchDetail(state: state)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(.top, 6).padding(.trailing, 12)
            }
            HStack(spacing: 18) {
                KeyboardHint(key: "↑↓", title: "选择")
                if state.settings.advanced.numberHints { KeyboardHint(key: "⌘1–9", title: "直达") }
                KeyboardHint(key: state.keyLabel(.cancel, symbol: "Esc"), title: "关闭")
                Spacer(minLength: 12)
                if !state.message.isEmpty {
                    Label(state.message, systemImage: state.messageIsError ? "exclamationmark.circle" : "checkmark.circle")
                        .font(.system(size: 12)).foregroundStyle(state.messageIsError ? Color.orange : GlanceDesign.secondary).lineLimit(1)
                } else {
                    Text(state.settings.advanced.browserTabs ? "输入拼音、首字母、标题或网址" : "输入拼音、首字母或标题")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 26).frame(height: 46)
        }
    }
}

private struct SearchResults: View {
    @ObservedObject var state: SwitcherState
    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    Text(state.loading && state.items.isEmpty ? "正在读取窗口…" : (state.items.isEmpty ? "没有找到匹配的窗口" : "\(state.items.count) 个结果"))
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(GlanceDesign.secondary)
                        .padding(.horizontal, 10).padding(.top, 2).padding(.bottom, 4)
                    if state.items.isEmpty && !state.loading {
                        Text("试试应用名称、拼音首字母，或更短的关键词。").font(.system(size: 12)).foregroundStyle(GlanceDesign.secondary)
                            .padding(.horizontal, 10)
                    }
                    ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                        SearchRow(state: state, item: item, index: index).id(item.id)
                    }
                }.padding(12)
            }.onChange(of: state.selected?.id) { _, id in if let id { scroll.scrollTo(id, anchor: .center) } }
        }
    }
}

private struct SearchRow: View {
    @ObservedObject var state: SwitcherState
    let item: WindowHandle
    let index: Int
    private var selected: Bool { state.selectedIndex == index || state.dropTargetID == item.id }
    var body: some View {
        Button { state.selectWindow(item.id, commit: true) } label: {
            HStack(spacing: 12) {
                BadgedIcon(icon: item.icon, size: 30, badge: state.badges[item.descriptor.pid])
                VStack(alignment: .leading, spacing: 3) {
                    Text(highlighted(item.descriptor.displayTitle, query: state.query, advanced: state.settings.advanced))
                        .font(.system(size: 14, weight: selected ? .bold : .semibold)).foregroundStyle(GlanceDesign.ink).lineLimit(1)
                    HStack(spacing: 0) {
                        // Something to open without an English name would repeat its title here.
                        let showsApp = !(item.descriptor.launcher != nil && item.descriptor.appName == item.descriptor.title)
                        if showsApp { Text(highlighted(item.descriptor.appName, query: state.query, advanced: state.settings.advanced)) }
                        let rest = state.details(for: item.descriptor, includeApp: false)
                        if !rest.isEmpty { Text((showsApp ? " · " : "") + rest.joined(separator: " · ")) }
                    }.font(.system(size: 12)).foregroundStyle(GlanceDesign.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                CardMarks(state: state, item: item, index: index)
            }.padding(.horizontal, 10).frame(height: 56)
                .background { RowSelection(selected: selected, hovered: state.hoveredID == item.id) }
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }.buttonStyle(.plain).onHover { state.hover($0, index: index, id: item.id) }
            .modifier(WindowMenu(state: state, item: item))
            .modifier(CardDrop(state: state, item: item))
            .modifier(WindowAccessibility(state: state, item: item))
    }
}

private struct SearchDetail: View {
    @ObservedObject var state: SwitcherState
    private var controlsAvailable: Bool { state.selected != nil && !state.isDemo && !state.actionPending && !state.loading }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let item = state.selected {
                PreviewImage(state: state, item: item, iconSize: 64, preferSharp: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .shadow(color: .black.opacity(0.1), radius: 12, y: 6)
                    .opacity(item.descriptor.minimized || item.descriptor.hidden ? 0.7 : 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.descriptor.displayTitle).font(.system(size: 16, weight: .bold)).foregroundStyle(GlanceDesign.ink).lineLimit(2)
                    Text(meta(item.descriptor)).font(.system(size: 12)).foregroundStyle(GlanceDesign.secondary).lineLimit(1)
                }
                HStack(spacing: 8) {
                    // Apps to open, menu bar icons and the settings window only have the one action.
                    let opensSomething = item.descriptor.launcher != nil || item.descriptor.menuBarItem || item.descriptor.settingsWindow
                    if !opensSomething {
                        let windowActions = controlsAvailable && !item.descriptor.windowless && !item.descriptor.searchOnly
                        Button("最小化 ⌘M") { state.onAction?(.minimize) }.buttonStyle(GlanceButtonStyle(compact: true)).disabled(!windowActions)
                        Button("关闭 ⌘W") { state.onAction?(.close) }.buttonStyle(GlanceButtonStyle(compact: true)).disabled(!windowActions || item.tab != nil)
                        Menu { WindowActionsMenu(state: state, item: item) } label: { Image(systemName: "ellipsis") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(Color.secondary).fixedSize().frame(width: 32, height: 28)
                            .help("更多操作").accessibilityLabel("更多窗口操作").disabled(!controlsAvailable)
                    }
                    Spacer(minLength: 8)
                    // In the demo this closes the panel, like Return does.
                    Button(item.descriptor.launcher.map { "\($0.action) ↵" } ?? (item.descriptor.menuBarItem ? "打开菜单 ↵" : "切换 ↵")) {
                        state.onSelect?(state.selectedIndex, true)
                    }.buttonStyle(GlanceButtonStyle(primary: true, compact: true))
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 30, weight: .light)).foregroundStyle(GlanceDesign.accentText)
                    Text(state.query.isEmpty ? "输入后在这里预览窗口" : "没有找到匹配的窗口").font(.system(size: 13)).foregroundStyle(GlanceDesign.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(20)
    }
    private func meta(_ d: WindowDescriptor) -> String {
        var parts = state.details(for: d)
        if let frame = d.frame, frame.width > 0, !d.searchOnly { parts.insert("\(Int(frame.width)) × \(Int(frame.height))", at: min(1, parts.count)) }
        return parts.joined(separator: " · ")
    }
}

struct ZoomPreviewView: View {
    @ObservedObject var state: SwitcherState
    var body: some View {
        VStack(spacing: 14) {
            if let item = state.selected {
                HStack(spacing: 10) {
                    if let icon = item.icon { Image(nsImage: icon).resizable().frame(width: 24, height: 24) }
                    Text(item.descriptor.displayTitle).font(.system(size: 15, weight: .bold)).foregroundStyle(GlanceDesign.ink).lineLimit(1)
                    Spacer()
                    Text(item.descriptor.appName).font(.system(size: 12)).foregroundStyle(GlanceDesign.secondary)
                }
                PreviewImage(state: state, item: item, iconSize: 72, preferSharp: true).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(22).modifier(GlancePanelBackdrop())
    }
}
