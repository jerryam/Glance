import Foundation
import ApplicationServices

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
    enum Kind {
        case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight
        case leftThird, centerThird, rightThird, maximize, center, nextScreen
    }
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
        let half = (screen.width / 2).rounded(.down), halfHeight = (screen.height / 2).rounded(.down)
        let rightX = screen.x + screen.width - half, bottomY = screen.y + screen.height - halfHeight
        // The middle third takes what does not divide evenly, so the three meet without a gap.
        let third = (screen.width / 3).rounded(.down)
        switch kind {
        case .left: return WindowRect(x: screen.x, y: screen.y, width: half, height: screen.height)
        case .right: return WindowRect(x: rightX, y: screen.y, width: half, height: screen.height)
        case .top: return WindowRect(x: screen.x, y: screen.y, width: screen.width, height: halfHeight)
        case .bottom: return WindowRect(x: screen.x, y: bottomY, width: screen.width, height: halfHeight)
        case .topLeft: return WindowRect(x: screen.x, y: screen.y, width: half, height: halfHeight)
        case .topRight: return WindowRect(x: rightX, y: screen.y, width: half, height: halfHeight)
        case .bottomLeft: return WindowRect(x: screen.x, y: bottomY, width: half, height: halfHeight)
        case .bottomRight: return WindowRect(x: rightX, y: bottomY, width: half, height: halfHeight)
        case .leftThird: return WindowRect(x: screen.x, y: screen.y, width: third, height: screen.height)
        case .centerThird: return WindowRect(x: screen.x + third, y: screen.y, width: screen.width - third * 2, height: screen.height)
        case .rightThird: return WindowRect(x: screen.x + screen.width - third, y: screen.y, width: third, height: screen.height)
        case .maximize: return screen
        case .center:
            // Keeps the window's size, and shrinks it only when it would not fit.
            let width = min(window.width, screen.width), height = min(window.height, screen.height)
            return WindowRect(x: screen.x + ((screen.width - width) / 2).rounded(.down), y: screen.y + ((screen.height - height) / 2).rounded(.down),
                              width: width, height: height)
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
    /// Where 还原 puts a window. The screen it was on may be gone by now: a place outside every screen
    /// becomes the middle of the screen the window is on, at its saved size.
    static func restored(_ saved: WindowRect, window: WindowRect, screens: [WindowRect]) -> WindowRect {
        let centerX = saved.x + saved.width / 2, centerY = saved.y + saved.height / 2
        if screens.isEmpty || screens.contains(where: { $0.contains(x: centerX, y: centerY) }) { return saved }
        return frame(.center, window: WindowRect(x: window.x, y: window.y, width: saved.width, height: saved.height), screens: screens) ?? saved
    }
}

/// Where each window was before 一瞥 arranged it, for 还原. Several arrangements in a row keep the first place;
/// moving the window by hand in between starts over from there.
struct WindowFrameMemory {
    private struct Entry { let original: WindowRect; let applied: WindowRect }
    private var entries: [UInt32: Entry] = [:]
    private var order: [UInt32] = []
    static let limit = 64
    /// Points of difference that still count as the same place.
    static let tolerance = 2.0
    mutating func recordArrangement(of window: UInt32, from current: WindowRect, to applied: WindowRect) {
        let kept = entries[window].flatMap { Self.same($0.applied, current) ? $0.original : nil }
        entries[window] = Entry(original: kept ?? current, applied: applied)
        order.removeAll { $0 == window }
        order.append(window)
        while order.count > Self.limit { entries.removeValue(forKey: order.removeFirst()) }
    }
    func original(of window: UInt32) -> WindowRect? { entries[window]?.original }
    mutating func forget(_ window: UInt32) {
        entries.removeValue(forKey: window)
        order.removeAll { $0 == window }
    }
    private static func same(_ a: WindowRect, _ b: WindowRect) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
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

/// A panel's first selection is made from the cached list, which can miss a window opened since it was read;
/// every position after that window is then off by one. While the selection is still that first pick, it is
/// made again from the fresh list. A selection changed by hand or a search stays as it is.
enum CachedPickPolicy {
    static func freshIndex(pickedID: String?, selectedID: String?, searching: Bool, steps: Int, count: Int) -> Int? {
        guard let pickedID, pickedID == selectedID, !searching, count > 0 else { return nil }
        return WindowNavigation.linear(index: 0, count: count, step: steps)
    }
}

/// A quick release can switch from the cached list instead of waiting for the read in progress, which takes up to
/// 0.3 seconds when an app is slow. A cached list can miss a window opened since it was read, which moves the
/// selection by one, so this needs a recent read with no window or app event after it, and a selection still
/// made by the trigger alone.
enum QuickCommitPolicy {
    /// As long as the open panel's fallback refresh trusts a list, for apps that omit window notifications.
    static let maximumCacheAge: TimeInterval = 10
    static func commitsNow(selectionUntouched: Bool, cacheAge: TimeInterval, cacheStale: Bool) -> Bool {
        selectionUntouched && !cacheStale && cacheAge <= maximumCacheAge
    }
}

/// Whether the front app has taken over the screen, as a game does. A plain window filling a display does not
/// count: it sits below the menu bar, which can still be reached.
enum FrontFullscreenPolicy {
    static func isActive(windowFullscreen: Bool, menuBarHidden: Bool, frontWindows: [(layer: Int, frame: WindowRect)], displays: [WindowRect]) -> Bool {
        if windowFullscreen || menuBarHidden { return true }
        return frontWindows.contains { window in
            window.layer > 0 && displays.contains { display in
                window.frame.x <= display.x && window.frame.y <= display.y
                    && window.frame.x + window.frame.width >= display.x + display.width
                    && window.frame.y + window.frame.height >= display.y + display.height
            }
        }
    }
}

/// Changes collected until the next flush. Only the first one asks for a flush, so a title that keeps ticking
/// cannot put it off.
struct ChangeBatch<Element> {
    private var elements: [Element] = []
    private var scheduled = false
    /// True when the caller should schedule a flush.
    mutating func add(_ element: Element, same: (Element, Element) -> Bool) -> Bool {
        if !elements.contains(where: { same($0, element) }) { elements.append(element) }
        defer { scheduled = true }
        return !scheduled
    }
    mutating func flush() -> [Element] {
        defer { elements = []; scheduled = false }
        return elements
    }
}

/// What a search knows about each browser's tabs. Last time's tabs show at once and each browser's answer replaces
/// only its own, so a slow browser holds up nothing. A tab closed since is caught when switching to it.
struct BrowserTabCache<Tab> {
    private var order: [String] = []
    private var tabs: [String: [Tab]] = [:]
    /// nil means the browser did not answer, so what is known about it stays.
    mutating func update(_ browser: String, tabs new: [Tab]?) {
        if let new { tabs[browser] = new }
    }
    /// The browsers running now, in a fixed order, so results do not trade places by who answered first.
    mutating func keep(only browsers: [String]) {
        order = browsers
        tabs = tabs.filter { browsers.contains($0.key) }
    }
    var all: [Tab] { order.flatMap { tabs[$0] ?? [] } }
}

/// What the window list reads from one window, in a single round trip to its app.
struct AXWindowFacts {
    var title = "", role = "", subrole = ""
    var frame = CGRect.zero
    var minimized = false, fullscreen = false
    static let attributes: [String] = [kAXTitleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXMinimizedAttribute,
                                       kAXRoleAttribute, kAXSubroleAttribute, "AXFullScreen"]
    init() {}
    /// Values in the order of `attributes`. One the window does not have arrives as an error value and keeps its default.
    init(values: [AnyObject]) {
        func value(_ index: Int) -> AnyObject? {
            guard index < values.count else { return nil }
            let item = values[index]
            if CFGetTypeID(item) == AXValueGetTypeID(), AXValueGetType(item as! AXValue) == .axError { return nil }
            return item
        }
        title = value(0) as? String ?? ""
        var point = CGPoint.zero, size = CGSize.zero
        if let position = value(1), CFGetTypeID(position) == AXValueGetTypeID(), AXValueGetValue(position as! AXValue, .cgPoint, &point),
           let dimension = value(2), CFGetTypeID(dimension) == AXValueGetTypeID(), AXValueGetValue(dimension as! AXValue, .cgSize, &size) {
            frame = CGRect(origin: point, size: size)
        }
        minimized = (value(3) as? NSNumber)?.boolValue ?? false
        role = value(4) as? String ?? ""
        subrole = value(5) as? String ?? ""
        fullscreen = (value(6) as? NSNumber)?.boolValue ?? false
    }
}

/// The settings window stays out of the way while the panel is open. Cancelling the panel over it, or ending
/// the demo started from it, brings it back in front; after a switch it must not cover the new window.
enum SettingsReturnPolicy {
    static func comesToFront(wasKey: Bool, cancelled: Bool, demo: Bool) -> Bool { wasKey && (cancelled || demo) }
}

/// 一瞥 leaves its own process out of the window list. Its settings window joins the switcher through this
/// entry, so it can be reached again after switching away from it.
/// The decisions behind the Dock preview's live pictures, its right-click actions and showing a window in place.
enum DockPreviewPolicy {
    static let liveTick: TimeInterval = 1
    static let hoveredInterval: TimeInterval = 1
    static let otherInterval: TimeInterval = 3
    /// Pictures asked for per tick, so an app with many windows costs no more than one with a few.
    static let perTick = 4
    /// The pointer has not moved for this long: nobody is looking, so no more captures until it does.
    static let liveIdleLimit: TimeInterval = 60
    static let peekDelay: TimeInterval = 0.3
    static let peekHideDelay: TimeInterval = 0.15

    /// Which cards get a new picture now: the one under the pointer first, then whichever has waited longest.
    /// A window that is minimized, hidden or on another desktop keeps its last picture.
    static func dueForRefresh(_ windows: [WindowDescriptor], hovered: String?, capturedAt: [String: TimeInterval], now: TimeInterval) -> [String] {
        let live = windows.filter { !$0.minimized && !$0.hidden && $0.onCurrentSpace && !$0.windowless && $0.windowID != nil }
        func waited(_ id: String) -> TimeInterval { capturedAt[id].map { now - $0 } ?? .infinity }
        let first = live.filter { $0.id == hovered && waited($0.id) >= hoveredInterval - 0.05 }.map(\.id)
        let others = live.filter { $0.id != hovered && waited($0.id) >= otherInterval - 0.05 }
            .sorted { waited($0.id) > waited($1.id) }.map(\.id)
        return Array((first + others).prefix(perTick))
    }

    /// Where a window's picture goes, or nil when the window is not on this desktop to be shown in place.
    static func peekFrame(of window: WindowDescriptor) -> WindowRect? {
        guard !window.minimized, !window.hidden, window.onCurrentSpace, !window.windowless, window.windowID != nil,
              let frame = window.frame, frame.width >= 40, frame.height >= 40 else { return nil }
        return frame
    }

    /// Pressed on one card and let go on another is not a click on either.
    static func middleClickTarget(down: String?, up: String?) -> String? { down == up ? up : nil }

    /// Whether the cards still show the same thing: a window can stay in the list and only change state.
    static func sameCards(_ a: [WindowDescriptor], _ b: [WindowDescriptor]) -> Bool {
        a.map { "\($0.id)|\($0.minimized)|\($0.hidden)" } == b.map { "\($0.id)|\($0.minimized)|\($0.hidden)" }
    }
}

/// Where the windows were when the user asked to remember it. Unlike everything else 一瞥 keeps, this holds window
/// titles, because the user asked for this record and they are what tells two windows of one app apart. It is kept
/// under its own key on this Mac and is not part of a settings export.
struct LayoutSnapshot: Codable, Equatable, Identifiable {
    struct Window: Codable, Equatable {
        let bundleID: String
        let appName: String
        let title: String
        let windowID: UInt32?
        let frame: WindowRect
    }
    let id: UUID
    var name: String
    let created: Double
    /// The screens' areas at the time, in the order the system listed them: what the frames are relative to.
    let screens: [WindowRect]
    let windows: [Window]
}

enum LayoutSnapshotPolicy {
    static let limit = 20
    static let windowLimit = 200
    static let longestName = 40
    /// What finds a layout in the search, besides its name.
    static let keywords = "布局 快照 buju kuaizhao layout snapshot"

    static func decoded(_ data: Data?) -> [LayoutSnapshot] {
        guard let data, let layouts = try? JSONDecoder().decode([LayoutSnapshot].self, from: data) else { return [] }
        return layouts
    }
    static func cleaned(name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(longestName))
    }
    static func suggestedName(among layouts: [LayoutSnapshot]) -> String {
        let names = Set(layouts.map(\.name))
        var number = 1
        while names.contains("布局 \(number)") { number += 1 }
        return "布局 \(number)"
    }
    /// Windows worth remembering: on screen, with a place, and something to find them by later.
    static func capturable(_ window: WindowDescriptor) -> Bool {
        guard restorable(window), !window.minimized, !window.hidden, let frame = window.frame else { return false }
        return frame.width > 0 && frame.height > 0
    }
    /// Windows a layout can move. A minimized window or a hidden app comes back; a full screen window has no place to move to.
    static func restorable(_ window: WindowDescriptor) -> Bool {
        !window.windowless && !window.searchOnly && !window.settingsWindow && !window.fullscreen && window.tabRepresentative && !window.bundleID.isEmpty
    }
    static func capture(name: String, windows: [WindowDescriptor], screens: [WindowRect], now: Double) -> LayoutSnapshot {
        let kept: [LayoutSnapshot.Window] = windows.filter(capturable).prefix(windowLimit).compactMap { window in
            guard let frame = window.frame else { return nil }
            return LayoutSnapshot.Window(bundleID: window.bundleID, appName: window.appName, title: window.title, windowID: window.windowID, frame: frame)
        }
        return LayoutSnapshot(id: UUID(), name: cleaned(name: name), created: now, screens: screens, windows: kept)
    }
    /// The same name replaces the older one. Nil when there is no room for another.
    static func adding(_ layout: LayoutSnapshot, to layouts: [LayoutSnapshot]) -> [LayoutSnapshot]? {
        if let index = layouts.firstIndex(where: { $0.name == layout.name }) {
            var result = layouts
            result[index] = layout
            return result
        }
        return layouts.count < limit ? layouts + [layout] : nil
    }
    /// Which open window each saved one has become, by its position in the snapshot. The same window if it is still
    /// there, then one with the same title, then any other of that app's. No open window is used twice.
    static func match(_ saved: [LayoutSnapshot.Window], live: [WindowDescriptor]) -> [Int: String] {
        var free = live.filter(restorable)
        var result: [Int: String] = [:]
        func pass(_ same: (LayoutSnapshot.Window, WindowDescriptor) -> Bool) {
            for (index, window) in saved.enumerated() where result[index] == nil {
                guard let found = free.firstIndex(where: { $0.bundleID == window.bundleID && same(window, $0) }) else { continue }
                result[index] = free.remove(at: found).id
            }
        }
        pass { $0.windowID != nil && $0.windowID == $1.windowID }
        pass { $0.title == $1.title }
        pass { _, _ in true }
        return result
    }
    /// Where a saved frame belongs on the screens there are now. On the same screen it is exactly where it was, even
    /// partly off screen. On another one it keeps its share of the screen, so a left half stays a left half.
    static func target(of frame: WindowRect, savedScreens: [WindowRect], screens: [WindowRect]) -> WindowRect {
        guard !screens.isEmpty, !savedScreens.isEmpty else { return frame }
        let index = WindowArrangement.screenIndex(of: frame, in: savedScreens)
        let old = savedScreens[index]
        guard old.width > 0, old.height > 0 else { return frame }
        let sameSize = screens.first(where: { $0.width == old.width && $0.height == old.height })
        let new = screens.first(where: { $0 == old }) ?? sameSize ?? (index < screens.count ? screens[index] : screens[0])
        if new == old { return frame }
        let scaleX = new.width / old.width, scaleY = new.height / old.height
        let width = min((frame.width * scaleX).rounded(), new.width), height = min((frame.height * scaleY).rounded(), new.height)
        let x = new.x + ((frame.x - old.x) * scaleX).rounded(), y = new.y + ((frame.y - old.y) * scaleY).rounded()
        return WindowRect(x: min(max(x, new.x), new.x + new.width - width), y: min(max(y, new.y), new.y + new.height - height), width: width, height: height)
    }
    static func summary(placed: Int, total: Int) -> String {
        if placed >= total { return "已恢复 \(placed) 个窗口。" }
        return "已恢复 \(placed) 个窗口，另外 \(total - placed) 个没有恢复：应用没有打开、窗口已经关闭，或应用不允许调整。"
    }
}

/// The start menu's commands. Anything that ends the session asks first: restart, shut down and log out through the
/// system's own dialog, emptying the Trash through 一瞥's.
enum SystemCommand: String, CaseIterable {
    case lockScreen, sleep, displayOff, screenSaver, restart, shutDown, logOut, emptyTrash
    var title: String {
        switch self {
        case .lockScreen: return "锁定屏幕"
        case .sleep: return "睡眠"
        case .displayOff: return "关闭显示器"
        case .screenSaver: return "屏幕保护程序"
        case .restart: return "重新启动…"
        case .shutDown: return "关机…"
        case .logOut: return "退出登录…"
        case .emptyTrash: return "清空废纸篓…"
        }
    }
    var english: String {
        switch self {
        case .lockScreen: return "Lock Screen"
        case .sleep: return "Sleep"
        case .displayOff: return "Turn Display Off"
        case .screenSaver: return "Screen Saver"
        case .restart: return "Restart"
        case .shutDown: return "Shut Down"
        case .logOut: return "Log Out"
        case .emptyTrash: return "Empty Trash"
        }
    }
    /// Other words it goes by. The name's own pinyin is found without help.
    var keywords: String {
        switch self {
        case .lockScreen: return "锁屏 suoping sp"
        case .sleep: return "休眠 待机 xiumian daiji standby"
        case .displayOff: return "关屏 息屏 guanping xiping screen off"
        case .screenSaver: return "屏保 pingbao screensaver"
        case .restart: return "重启 chongqi reboot"
        case .shutDown: return "关闭电脑 shutdown poweroff"
        case .logOut: return "注销 登出 zhuxiao dengchu logout signout"
        case .emptyTrash: return "回收站 删除 huishouzhan trash"
        }
    }
    var symbol: String {
        switch self {
        case .lockScreen: return "lock"
        case .sleep: return "moon"
        case .displayOff: return "display"
        case .screenSaver: return "sparkles.tv"
        case .restart: return "arrow.clockwise"
        case .shutDown: return "power"
        case .logOut: return "rectangle.portrait.and.arrow.right"
        case .emptyTrash: return "trash"
        }
    }
    /// Whether it stops for a confirmation before anything happens.
    var asksFirst: Bool { self == .restart || self == .shutDown || self == .logOut || self == .emptyTrash }
    /// What runs it. Locking first tries a direct call, and turning the display off is what remains if that is gone.
    var program: (path: String, arguments: [String]) {
        func script(_ source: String) -> (path: String, arguments: [String]) { ("/usr/bin/osascript", ["-e", source]) }
        switch self {
        case .lockScreen, .displayOff: return ("/usr/bin/pmset", ["displaysleepnow"])
        case .sleep: return ("/usr/bin/pmset", ["sleepnow"])
        case .screenSaver: return ("/usr/bin/open", ["/System/Library/CoreServices/ScreenSaverEngine.app"])
        // The “show the dialog” events of loginwindow: the system asks, and nothing happens if the answer is no.
        case .restart: return script("tell application \"loginwindow\" to «event aevtrrst»")
        case .shutDown: return script("tell application \"loginwindow\" to «event aevtrsdn»")
        case .logOut: return script("tell application \"loginwindow\" to «event aevtlogo»")
        case .emptyTrash: return script("tell application \"Finder\" to empty trash")
        }
    }
}

/// Which files a search lists. Names come from Spotlight and stay in memory: nothing about them is written down.
enum FileSearchPolicy {
    static let limit = 8
    /// How many Spotlight answers to look through for that many worth listing.
    static let looked = 60
    static let shortest = 2
    /// The words to look for, without the characters Spotlight would read as wildcards.
    static func tokens(_ query: String) -> [String] {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map { word in String(word.filter { !"*?\\\"'".contains($0) }) }.filter { !$0.isEmpty }
        return words.joined().count >= shortest ? Array(words.prefix(5)) : []
    }
    /// The user's own files: not hidden ones, not what apps keep in Library, not apps (which the search lists anyway).
    static func keeps(path: String, home: String) -> Bool {
        guard path.hasPrefix(home + "/"), !path.hasPrefix(home + "/Library/") else { return false }
        let inside = path.dropFirst(home.count + 1).split(separator: "/")
        return !inside.contains { $0.hasPrefix(".") || $0.hasSuffix(".app") }
    }
    static func kept(_ paths: [String], home: String) -> [String] {
        Array(paths.filter { keeps(path: $0, home: home) }.prefix(limit))
    }
    /// Where it is, for the line under its name.
    static func place(of path: String, home: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        if folder == home { return "~" }
        return folder.hasPrefix(home + "/") ? "~" + String(folder.dropFirst(home.count)) : folder
    }
}

/// 设置 › 通用 › 意外退出后自动重新打开: what runs after a crash, and when to stop trying.
enum CrashRestartPolicy {
    /// Tells the new copy why it was opened.
    static let argument = "--restarted-after-crash"
    static let window: TimeInterval = 600
    /// This many reopenings within the window, and the next crash stays closed: reopening is not helping.
    static let limit = 3
    /// The wait lets the crashed copy finish dying, so the new one does not hand over to it and quit.
    static func script(delay: Int = 2, opener: String = "/usr/bin/open") -> String {
        "sleep \(delay); exec \(opener) -n \"$0\" --args \(argument)"
    }
    /// The app's path is an argument, never part of the script, so no character in it can change what runs.
    static func command(appPath: String) -> [String] { ["/bin/sh", "-c", script(), appPath] }
    static func recent(_ history: [Double], now: Double) -> [Double] {
        // A clock set back must not keep old entries alive.
        history.filter { $0 <= now && now - $0 < window }
    }
    static func recording(restartAt now: Double, history: [Double]) -> [Double] { recent(history, now: now) + [now] }
    static func allowsAnother(_ history: [Double], now: Double) -> Bool { recent(history, now: now).count < limit }
    /// A copy started for a test or from the command line, or not from an app bundle, is not reopened.
    static func applies(arguments: [String], bundlePath: String) -> Bool {
        let ordinary = [argument, "--settings", "--restart"]
        return bundlePath.hasSuffix(".app") && arguments.dropFirst().allSatisfy { !$0.hasPrefix("--") || ordinary.contains($0) }
    }
}

enum SettingsWindowEntry {
    static let id = "glance:settings"
    /// The panel orders a visible settings window out while it is open, which is why "set aside" counts as open.
    static func isOpen(visible: Bool, minimized: Bool, setAside: Bool) -> Bool { visible || minimized || setAside }
    /// `lastFocused` is when the window last gained the keyboard. While it has the keyboard it is the current
    /// window, so it sorts first and a quick ⌥Tab goes to the window used before it.
    static func descriptor(pid: Int32, bundleID: String, frame: WindowRect, displayID: UInt32?, minimized: Bool,
                           isKey: Bool, lastFocused: Double, now: Double) -> WindowDescriptor {
        // No window number, so nothing tries to capture it. A window that was set aside comes back on the current desktop.
        var entry = WindowDescriptor(id: id, windowID: nil, pid: pid, appName: "一瞥", bundleID: bundleID, title: "设置", minimized: minimized, hidden: false,
                                     onCurrentSpace: true, displayID: displayID, aspectRatio: frame.width / max(1, frame.height))
        entry.settingsWindow = true
        entry.frame = frame
        entry.lastFocused = isKey ? now : lastFocused
        entry.created = entry.lastFocused
        entry.zOrder = isKey ? -1 : Int.max
        // Lets "glance" and "settings" find it; a subtitle is only shown for tabs and menu bar icons.
        entry.subtitle = "Glance Settings"
        return entry
    }
}

/// When windows and apps were last used, kept across restarts. Only window numbers and app identifiers are saved,
/// never a title: unlike a pin, nobody asked for this to be written down.
struct RecentOrder: Codable, Equatable {
    struct WindowUse: Codable, Equatable {
        let id: String
        let pid: Int32
        let bundleID: String
        let time: Double
    }
    var windows: [WindowUse] = []
    /// App identifier and last use: what is left when a window number no longer means anything.
    var apps: [String: Double] = [:]
}

enum RecentOrderPolicy {
    static let windowLimit = 200
    static let appLimit = 200
    /// Saved this long after the first change, so a busy minute writes a few times and a crash loses little.
    static let saveDelay: TimeInterval = 15
    static func decoded(_ data: Data?) -> RecentOrder {
        data.flatMap { try? JSONDecoder().decode(RecentOrder.self, from: $0) } ?? RecentOrder()
    }
    /// What to save now. An empty list means nothing has been read yet (just launched, or no permission), not that
    /// every window closed, so the windows saved last time stay until a read can replace them.
    static func snapshot(focus: [String: Double], windows: [WindowDescriptor], apps: [String: Double], previous: RecentOrder) -> RecentOrder {
        var uses: [RecentOrder.WindowUse] = [], appTimes = apps
        for window in windows {
            guard let time = focus[window.id] else { continue }
            appTimes[window.bundleID] = max(appTimes[window.bundleID] ?? 0, time)
            // Other ids mean nothing after a restart.
            if window.id.hasPrefix("cg:") { uses.append(.init(id: window.id, pid: window.pid, bundleID: window.bundleID, time: time)) }
        }
        let recentUses = uses.sorted { ($0.time, $0.id) > ($1.time, $1.id) }.prefix(windowLimit)
        let recentApps = appTimes.filter { !$0.key.isEmpty && $0.value > 0 }.sorted { ($0.value, $0.key) > ($1.value, $1.key) }.prefix(appLimit)
        return RecentOrder(windows: windows.isEmpty ? previous.windows : Array(recentUses),
                           apps: Dictionary(uniqueKeysWithValues: recentApps.map { ($0.key, $0.value) }))
    }
    /// A window number is the same window only while the same process of the same app runs: a restarted Mac numbers
    /// its windows from the start again, and hands out process ids again too. A time ahead of the clock, which
    /// has been set back, would otherwise beat the window in front.
    static func restoredFocus(_ order: RecentOrder, runningApps: [Int32: String], now: Double) -> [String: Double] {
        var focus: [String: Double] = [:]
        for window in order.windows where window.time > 0 && runningApps[window.pid] == window.bundleID { focus[window.id] = min(window.time, now) }
        return focus
    }
    static func restoredApps(_ order: RecentOrder, now: Double) -> [String: Double] {
        order.apps.filter { !$0.key.isEmpty && $0.value > 0 }.mapValues { min($0, now) }
    }
    /// The window's own last use, then its app's in this run, then its app's in any earlier run.
    static func lastFocused(_ window: WindowDescriptor, focus: [String: Double], activated: [Int32: Double], apps: [String: Double]) -> Double {
        focus[window.id] ?? focus["\(window.pid)|\(window.title)"] ?? activated[window.pid] ?? apps[window.bundleID] ?? 0
    }
}

enum WindowListChange {
    /// Whether a fresh read changes anything the panel shows. Every read stamps the front window with the
    /// current time, so focus times count only through the order they put the windows in.
    static func matters(from old: [WindowDescriptor], to new: [WindowDescriptor]) -> Bool {
        guard old.count == new.count else { return true }
        return zip(old, new).contains { before, after in
            var stamped = after
            stamped.lastFocused = before.lastFocused
            return before != stamped
        }
    }
}

enum BrowserTabScript {
    /// Text from a web page enters a script only as a JSON string, which it cannot end to become code.
    static func literal(_ text: String) -> String? {
        (try? JSONEncoder().encode(text)).flatMap { String(data: $0, encoding: .utf8) }
    }
    /// Browsers built on Chromium keep different amounts of its scripting interface: Arc has no active tab index and
    /// selects a tab with a command. So the scripts ask what this browser offers, one step at a time.
    static func list(bundleID: String, chromium: Bool) -> String? {
        guard let app = literal(bundleID) else { return nil }
        let active = chromium ? "w.activeTabIndex !== undefined ? w.activeTabIndex() : w.tabs.id().indexOf(w.activeTab.id()) + 1" : "w.currentTab.index()"
        let titles = chromium ? "w.tabs.title()" : "w.tabs.name()"
        return """
        (() => {
          const app = Application(\(app));
          const activeOf = w => { try { return \(active); } catch (e) { return 0; } };
          const out = [];
          for (const w of app.windows()) {
            try { out.push({ id: w.id(), active: activeOf(w), titles: \(titles), urls: w.tabs.url() }); } catch (e) {}
          }
          return JSON.stringify(out);
        })()
        """
    }
    /// Tabs may have moved since they were listed: the listed position counts only if it still shows that
    /// address, then the address is looked up, then the title. Windows are compared as text because a browser
    /// may report its ids either way.
    static func activate(bundleID: String, windowID: String, tabIndex: Int, url: String, title: String, chromium: Bool) -> String? {
        guard let app = literal(bundleID), let window = literal(windowID), let url = literal(url), let title = literal(title) else { return nil }
        let titles = chromium ? "w.tabs.title()" : "w.tabs.name()"
        let select = chromium ? "if (w.activeTabIndex !== undefined) w.activeTabIndex = index + 1; else w.tabs[index].select();" : "w.currentTab = w.tabs[index];"
        return """
        (() => {
          const app = Application(\(app));
          const w = app.windows().find(x => String(x.id()) === \(window));
          if (!w) return 'gone';
          const urls = w.tabs.url().map(u => u || '');
          let index = \(tabIndex - 1);
          if (urls[index] !== \(url)) {
            index = urls.indexOf(\(url));
            if (index < 0 && \(title) !== '') index = \(titles).indexOf(\(title));
            if (index < 0) return 'gone';
          }
          \(select)
          try { w.index = 1; } catch (e) {}
          app.activate();
          return 'ok';
        })()
        """
    }
    /// Larger than any scripting dictionary: another app's file is not read without limit.
    static let dictionaryLimit = 2_000_000
    /// Whether an app's scripting dictionary offers what these scripts use. Chromium's has all three; Safari's says
    /// "current tab", and a terminal's tabs have no address.
    static func offersChromiumTabs(dictionary text: String) -> Bool {
        text.contains("name=\"active tab\"") && text.contains("name=\"tab\"") && text.contains("name=\"URL\"")
    }
}

/// One browser window as the scripts above report it.
struct BrowserWindowTabs: Decodable {
    /// Text in Chromium since 2023 and in Arc, a number in Safari and older Chromium.
    let id: String
    /// 1-based. 0 when the browser cannot say which tab is active, and then every tab is listed.
    let active: Int
    let titles: [String?]
    let urls: [String?]
    private enum CodingKeys: String, CodingKey { case id, active, titles, urls }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let number = try? values.decode(Int.self, forKey: .id) { id = String(number) } else { id = try values.decode(String.self, forKey: .id) }
        active = (try? values.decode(Int.self, forKey: .active)) ?? 0
        titles = try values.decode([String?].self, forKey: .titles)
        urls = try values.decode([String?].self, forKey: .urls)
    }
}

/// A pinned window as it is saved. A window number only means something until the window server restarts, so a
/// pin also remembers the app and the title, to find its window again after the app or the Mac has restarted.
struct WindowPin: Codable, Equatable {
    /// Empty while the pin waits for its app to open that window again.
    var id: String
    var windowID: UInt32?
    /// Zero when no process stands behind the pin: it is waiting, or an older version saved it.
    var pid: Int32
    var bundleID: String
    var title: String
    init(_ window: WindowDescriptor) {
        id = window.id; windowID = window.windowID; pid = window.pid; bundleID = window.bundleID; title = window.title
    }
    /// Versions before 2.3.2 saved only the id.
    init(legacyID: String) {
        id = legacyID; windowID = legacyID.hasPrefix("cg:") ? UInt32(legacyID.dropFirst(3)) : nil; pid = 0; bundleID = ""; title = ""
    }
}

enum PinPolicy {
    static let limit = 32
    static func adding(_ pin: WindowPin, to pins: [WindowPin]) -> [WindowPin] {
        Array((pins.filter { $0.id != pin.id } + [pin]).suffix(limit))
    }
    /// The ids that are pinned right now. A waiting pin has none, so it can never mark another window.
    static func boundIDs(_ pins: [WindowPin]) -> Set<String> { Set(pins.map(\.id).filter { !$0.isEmpty }) }
    /// Which window each pin means after a fresh read. An id counts only for the same process and app, because
    /// a restarted window server hands out the same numbers again. With the process gone, a pin moves to the one
    /// window of that app with its title; with several it does not guess, and waits until there is just one.
    static func resolve(_ pins: [WindowPin], windows: [WindowDescriptor], runningApps: [Int32: String], liveWindowIDs: Set<UInt32>) -> [WindowPin] {
        let byID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func sameWindow(_ pin: WindowPin) -> WindowDescriptor? {
            guard let window = byID[pin.id], pin.pid == 0 || (window.pid == pin.pid && window.bundleID == pin.bundleID) else { return nil }
            return window
        }
        var claimed = Set(pins.compactMap { sameWindow($0)?.id })
        var result: [WindowPin] = []
        for pin in pins {
            if let window = sameWindow(pin) {
                var updated = WindowPin(window)
                if window.title.isEmpty { updated.title = pin.title }
                result.append(updated)
            } else if runningApps[pin.pid] == pin.bundleID {
                // Its process still runs, so the window was closed, or this read only missed it.
                if WindowDiscoveryPolicy.keepsUnanswered(windowID: pin.windowID, liveWindowIDs: liveWindowIDs) { result.append(pin) }
            } else if !pin.bundleID.isEmpty, !pin.title.isEmpty {
                let candidates = windows.filter { $0.bundleID == pin.bundleID && $0.title == pin.title && !claimed.contains($0.id) }
                if candidates.count == 1 {
                    claimed.insert(candidates[0].id)
                    result.append(WindowPin(candidates[0]))
                } else {
                    var waiting = pin
                    waiting.id = ""; waiting.windowID = nil; waiting.pid = 0
                    result.append(waiting)
                }
            }
        }
        return result
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
    /// An app that did not answer keeps its last known windows, except those the window server no longer has.
    /// A window without a number cannot be checked, so it stays until the app answers again.
    static func keepsUnanswered(windowID: UInt32?, liveWindowIDs: Set<UInt32>) -> Bool {
        windowID.map { liveWindowIDs.contains($0) } ?? true
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
        .init(1, "允许跳过中间的字", "跳字 子序列 模糊 fuzzy subsequence 拼音"), .init(1, "双拼方案", "双拼 小鹤 自然码 微软 搜狗 shuangpin 拼音"),
        .init(1, "把常选的结果排到前面", "常用 习惯 学习 记住 搜索记录 清除 排序"),
        .init(1, "搜索时包含浏览器标签页","Safari Chrome Edge Arc Opera 标签 tab 浏览器 网页 网址"),
        .init(1, "搜索时包含未打开的应用", "启动 打开 开始菜单 start launcher 应用程序"),
        .init(1, "搜索时包含系统设置页面", "系统设置 偏好设置 蓝牙 网络 显示器 settings preferences"),
        .init(1, "搜索时包含系统命令", "开始菜单 锁屏 睡眠 关机 重启 注销 废纸篓 lock sleep restart shutdown logout"),
        .init(1, "搜索时查找文件", "开始菜单 文件 文档 聚焦 spotlight file finder"), .init(1, "搜索时计算算式", "开始菜单 计算器 calculator 算式 加减乘除"),
        .init(1, "在结果最后提供网页搜索", "开始菜单 浏览器 百度 必应 google bing web 网址"), .init(1, "搜索引擎", "百度 必应 google bing duckduckgo 网页搜索"),
        .init(1, "按 Shift 单独反向选择", "反向 上一个 单修饰键"),
        .init(1, "使用方向键选择窗口", "arrow"), .init(1, "使用 H / J / K / L 选择窗口", "vim"),
        .init(1, "面板中的快捷键 · 点击按键可重新录制", "录制 关闭 退出 最小化 按键 半屏 填满 屏幕 置顶"),
        .init(1, "启用全局窗口快捷键", "半屏 四分屏 三分屏 分屏 居中 还原 窗口位置 全局 snap tile"),
        .init(1, "窗口布局", "布局 快照 保存 恢复 工作区 多显示器 layout snapshot workspace"),
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
        .init(3, "实时更新预览图", "Dock 预览 缩略图 实时 live"), .init(3, "悬停时在窗口原来的位置显示它", "Dock 预览 悬停 真实窗口 peek"),
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
        .init(6, "意外退出后自动重新打开", "崩溃 闪退 重启 crash restart relaunch"),
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

/// Results collected up to a deadline. Closing ends the wait; whatever arrives later is left to the sender.
final class DeadlineSlots<Value> {
    private let lock = NSLock()
    private var values: [Value?]
    private var closed = false
    init(count: Int) { values = Array(repeating: nil, count: count) }
    /// False when the deadline has already passed.
    func store(_ value: Value, at index: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        values[index] = value
        return true
    }
    func close() -> [Value?] {
        lock.lock(); defer { lock.unlock() }
        closed = true
        return values
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

/// What to do when bringing a window forward failed. A pick from the cached list may only be out of date, so the
/// fresh list gets the final say, once; a pick from the fresh list has nothing further to go on.
enum FocusFailurePolicy {
    enum Action { case waitForFreshList, commitFreshList, report }
    static func action(fromCache: Bool, loading: Bool) -> Action {
        guard fromCache else { return .report }
        return loading ? .waitForFreshList : .commitFreshList
    }
}

/// A thread that only runs a run loop, for event sources whose callbacks must not wait for the main thread.
final class BackgroundRunLoop: Thread {
    private let ready = DispatchSemaphore(value: 0)
    private var loop: CFRunLoop!

    init(name: String, qos: QualityOfService) {
        super.init()
        self.name = name
        qualityOfService = qos
        start()
        ready.wait()
    }
    override func main() {
        loop = CFRunLoopGetCurrent()
        // A run loop with nothing to wait for returns at once.
        let keepAlive = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 1e9, 1e9, 0, 0) { _ in }
        CFRunLoopAddTimer(loop, keepAlive, .commonModes)
        ready.signal()
        CFRunLoopRun()
    }
    /// Runs after whatever was asked for earlier. Nothing drains autoreleased objects on this thread otherwise.
    func perform(_ work: @escaping () -> Void) {
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { autoreleasepool(invoking: work) }
        CFRunLoopWakeUp(loop)
    }
    func add(_ source: CFRunLoopSource) { CFRunLoopAddSource(loop, source, .commonModes) }
    func remove(_ source: CFRunLoopSource) { CFRunLoopRemoveSource(loop, source, .commonModes) }
    func finish() { CFRunLoopStop(loop) }
}

/// What the panel's key tap decides from, on its own thread: a copy the main thread publishes whenever it runs
/// out of work, so that a key gets its answer at once even while the main thread is busy.
struct PanelKeySnapshot {
    var generation = 0
    var held: ShortcutModifiers = []
    var sticky = false
    var searching = false
    var bindings: [PanelBinding] = []
    var mode = PanelInputMode.traditional
    var panelIsKey = false
    var markedText = false
    /// A window is coming forward and the panel is on its way out, so keys go through to that window.
    var focusInFlight = false
    /// The shortcuts registered with the system right now. Those keys arrive by that path and are not the tap's to take.
    var triggers: [ShortcutProfile] = []

    func captures(code: UInt32, flags: ShortcutModifiers) -> Bool {
        guard !focusInFlight else { return false }
        let command = PanelInputPolicy.command(code: code, flags: flags, held: held, sticky: sticky, searching: searching, bindings: bindings, mode: mode)
        return PanelKeyCapturePolicy.captures(command: command, panelIsKey: panelIsKey, searching: searching, markedText: markedText,
                                              registeredTrigger: triggers.contains { GlobalShortcutMatch.matches(code: code, flags: flags, profile: $0) })
    }
}
