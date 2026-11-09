import Foundation

struct SearchQuality: Equatable, Comparable {
    let weakest: Int
    let total: Int
    static func < (a: SearchQuality, b: SearchQuality) -> Bool {
        a.weakest == b.weakest ? a.total < b.total : a.weakest < b.weakest
    }
}

enum WindowSearch {
    /// At most this many apps and settings pages join one search.
    static let launcherLimit = 8
    private final class Index {
        let direct: [String]
        let pinyin: [String]
        let initials: [String]
        let identifier: String
        let words: [String]
        init(_ w: WindowDescriptor) {
            let names = [w.appName, w.title, w.subtitle ?? ""].map(WindowSearch.normalized).filter { !$0.isEmpty }
            // "wifi" finds "Wi‑Fi" and "airdrop" finds "Air-Drop": names again without hyphens and dots.
            direct = names + names.map { $0.components(separatedBy: WindowSearch.joiners).joined() }.filter { !names.contains($0) }
            let latin = [w.appName, w.title].map { WindowSearch.normalized($0.applyingTransform(.toLatin, reverse: false) ?? $0) }
            pinyin = latin.map { $0.components(separatedBy: .whitespacesAndNewlines).joined() }.filter { !$0.isEmpty }
            initials = latin.map { $0.components(separatedBy: .whitespacesAndNewlines).compactMap(\.first).map(String.init).joined() }.filter { !$0.isEmpty }
            identifier = WindowSearch.normalized(w.bundleID)
            words = Array(Set((direct + latin).flatMap { $0.components(separatedBy: CharacterSet.alphanumerics.inverted) } + pinyin)).filter { $0.count >= 3 && $0.count <= 49 }
        }
    }
    private final class IndexCache {
        private struct Entry { let value: Index; var accessed: UInt64 }
        private var entries: [String: Entry] = [:]
        private var clock: UInt64 = 0
        private let lock = NSLock()
        func value(for window: WindowDescriptor) -> Index {
            let key = "\(window.appName)\u{0}\(window.title)\u{0}\(window.bundleID)\u{0}\(window.subtitle ?? "")"
            lock.lock(); defer { lock.unlock() }
            clock &+= 1
            if var entry = entries[key] { entry.accessed = clock; entries[key] = entry; return entry.value }
            let value = Index(window)
            if entries.count >= 800, let oldest = entries.min(by: { $0.value.accessed < $1.value.accessed })?.key { entries.removeValue(forKey: oldest) }
            entries[key] = Entry(value: value, accessed: clock)
            return value
        }
    }
    private static let cache = IndexCache()
    fileprivate static let joiners = CharacterSet(charactersIn: "-‐‑‒–—_·・.")
    static func normalized(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current).lowercased()
    }
    private static func index(_ window: WindowDescriptor) -> Index {
        cache.value(for: window)
    }
    static func matches(_ window: WindowDescriptor, query: String, allowTypos: Bool = true) -> Bool {
        rank(window, tokens: normalized(query).split(whereSeparator: { $0.isWhitespace }).map(String.init), allowTypos: allowTypos) != nil
    }
    private static func rank(_ window: WindowDescriptor, tokens: [String], allowTypos: Bool) -> SearchQuality? {
        guard !tokens.isEmpty else { return .init(weakest: 0, total: 0) }
        let entry = index(window)
        var scores: [Int] = []
        for token in tokens {
            let score: Int
            // Within each kind, a whole match beats the start of a name, which beats the middle of one.
            if entry.direct.contains(token) { score = 0 }
            else if entry.direct.contains(where: { $0.hasPrefix(token) }) { score = 1 }
            else if entry.direct.contains(where: { $0.contains(token) }) { score = 2 }
            else if entry.pinyin.contains(token) { score = 3 }
            else if entry.pinyin.contains(where: { $0.hasPrefix(token) }) { score = 4 }
            else if entry.pinyin.contains(where: { $0.contains(token) }) { score = 5 }
            else if entry.initials.contains(token) { score = 6 }
            else if entry.initials.contains(where: { $0.hasPrefix(token) }) { score = 7 }
            else if entry.initials.contains(where: { $0.contains(token) }) { score = 8 }
            else if entry.identifier.contains(token) { score = 9 }
            else if allowTypos, (4...48).contains(token.count), token.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) }),
                    entry.words.contains(where: { oneEditApart(token, $0) }) { score = 10 }
            else { return nil }
            scores.append(score)
        }
        return .init(weakest: scores.max() ?? 0, total: scores.reduce(0, +))
    }
    /// Whether a window is placed after the others by its scheme (minimized, hidden, full screen, no window).
    static func isAtEnd(_ w: WindowDescriptor, settings: UserSettings, profile: ShortcutProfile) -> Bool {
        let minimized = profile.minimized ?? (settings.showMinimized ? .show : .hide)
        let hidden = profile.hidden ?? (settings.showHidden ? .show : .hide)
        let windowless = profile.windowless ?? (settings.showWindowlessApps ? .atEnd : .hide)
        return (w.windowless && windowless == .atEnd) || (w.minimized && minimized == .atEnd) ||
            (w.hidden && hidden == .atEnd) || (w.fullscreen && profile.fullscreen == .atEnd)
    }
    /// How a window matched the query, shown beside the search field.
    static func matchKind(_ window: WindowDescriptor, query: String, allowTypos: Bool = true) -> MatchKind? {
        let tokens = normalized(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty, let quality = rank(window, tokens: tokens, allowTypos: allowTypos) else { return nil }
        switch quality.weakest {
        case 0...2: return .name
        case 3...5: return .pinyin
        case 6...8: return .initials
        case 9: return .identifier
        default: return .typo
        }
    }
    /// Character ranges (offsets into `Array(text)`) that the query matched, for highlighting.
    /// Tries the text itself, then full pinyin, then pinyin initials; typo matches are not highlighted.
    static func highlights(in text: String, query: String) -> [Range<Int>] {
        let tokens = normalized(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty, !text.isEmpty else { return [] }
        let readings = TextReadings.of(text)
        var found: [Range<Int>] = []
        for token in tokens {
            if let range = readings.direct.find(token) ?? readings.pinyin.find(token) ?? readings.initials.find(token) { found.append(range) }
        }
        var merged: [Range<Int>] = []
        for range in found.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound { merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound) }
            else { merged.append(range) }
        }
        return merged
    }
    // Bounded single edit, including adjacent transposition; short queries remain exact.
    static func oneEditApart(_ first: String, _ second: String) -> Bool {
        let a = Array(first), b = Array(second)
        guard abs(a.count - b.count) <= 1 else { return false }
        if a.count == b.count {
            let differences = a.indices.filter { a[$0] != b[$0] }
            if differences.count <= 1 { return true }
            guard differences.count == 2 else { return false }
            let i = differences[0], j = differences[1]
            return j == i + 1 && a[i] == b[j] && a[j] == b[i]
        }
        let short = a.count < b.count ? a : b, long = a.count < b.count ? b : a
        var i = 0, j = 0, skipped = false
        while i < short.count && j < long.count {
            if short[i] == long[j] { i += 1; j += 1 }
            else { if skipped { return false }; skipped = true; j += 1 }
        }
        return true
    }
    static func filtered(_ windows: [WindowDescriptor], settings: UserSettings, profile: ShortcutProfile,
                         frontPID: Int32?, displayID: UInt32?, query: String,
                         cursorX: Double? = nil, cursorY: Double? = nil, expandedApp: Int32? = nil) -> [WindowDescriptor] {
        let excluded = settings.exclusions.components(separatedBy: .newlines).map(normalized).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let minimized = profile.minimized ?? (settings.showMinimized ? .show : .hide)
        let hidden = profile.hidden ?? (settings.showHidden ? .show : .hide)
        let windowless = profile.windowless ?? (settings.showWindowlessApps ? .atEnd : .hide)
        let cursorWindow = windows.filter { w in
            guard w.onCurrentSpace, !w.minimized, !w.hidden, let x = cursorX, let y = cursorY else { return false }
            return w.frame?.contains(x: x, y: y) == true
        }.min { $0.zOrder < $1.zOrder }
        let tokens = normalized(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var quality: [String: SearchQuality] = [:]
        var candidates = windows.filter { w in
            // Browser tabs only join a search; plain ⌥Tab keeps showing windows.
            if w.searchOnly && tokens.isEmpty { return false }
            if windowless == .hide && w.windowless { return false }
            if minimized == .hide && w.minimized { return false }
            if hidden == .hide && w.hidden { return false }
            if profile.fullscreen == .hide && w.fullscreen { return false }
            if !profile.separateTabs && w.tabGroup != nil && !w.tabRepresentative { return false }
            if profile.scope == .currentApp && w.pid != frontPID { return false }
            if profile.scope == .otherApps && w.pid == frontPID { return false }
            if profile.scope == .underCursor && w.id != cursorWindow?.id { return false }
            if profile.scope == .appUnderCursor && w.pid != cursorWindow?.pid { return false }
            if profile.currentScreenOnly && w.displayID != displayID && !w.searchOnly { return false }
            if profile.spaceScope == .visible && !w.onCurrentSpace { return false }
            if profile.spaceScope == .other && (w.onCurrentSpace || w.windowless || w.searchOnly) { return false }
            if settings.advanced.exceptions.contains(where: { $0.hides(w) }) { return false }
            let text = normalized("\(w.appName) \(w.bundleID) \(w.title)")
            if excluded.contains(where: { text.contains($0.trimmingCharacters(in: .whitespaces)) }) { return false }
            guard let rank = rank(w, tokens: tokens, allowTypos: settings.advanced.searchTypos) else { return false }
            quality[w.id] = rank
            return true
        }
        func isAtEnd(_ w: WindowDescriptor) -> Bool { WindowSearch.isAtEnd(w, settings: settings, profile: profile) }
        let originalOrder = Dictionary(windows.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        // Pinned windows come right after the current window, so a quick ⌥Tab still returns to the previous one.
        let hasPinned = tokens.isEmpty && candidates.contains { $0.pinned }
        let currentID = hasPinned && profile.order == .recent ? candidates.max { $0.lastFocused < $1.lastFocused }?.id : nil
        func pinRank(_ w: WindowDescriptor) -> Int { w.id == currentID ? 0 : (w.pinned ? 1 : 2) }
        candidates.sort { a, b in
            if !tokens.isEmpty && settings.advanced.searchRanking, let ar = quality[a.id], let br = quality[b.id], ar != br { return ar < br }
            // Equally good matches: windows that are already open come before things to open.
            if !tokens.isEmpty && (a.launcher == nil) != (b.launcher == nil) { return a.launcher == nil }
            // Between two things to open, the shorter name is the closer match: 蓝牙 before 蓝牙文件交换.
            if !tokens.isEmpty, a.launcher != nil, b.launcher != nil, a.title.count != b.title.count { return a.title.count < b.title.count }
            if !tokens.isEmpty && settings.advanced.searchRanking {
                if a.lastFocused != b.lastFocused { return a.lastFocused > b.lastFocused }
                return (originalOrder[a.id] ?? 0) < (originalOrder[b.id] ?? 0)
            }
            if isAtEnd(a) != isAtEnd(b) { return !isAtEnd(a) }
            if hasPinned && pinRank(a) != pinRank(b) { return pinRank(a) < pinRank(b) }
            switch profile.order {
            case .recent: if a.lastFocused != b.lastFocused { return a.lastFocused > b.lastFocused }
            case .created: if a.created != b.created { return a.created > b.created }
            case .alphabetical:
                let c = "\(a.appName) \(a.displayTitle)".localizedStandardCompare("\(b.appName) \(b.displayTitle)")
                if c != .orderedSame { return c == .orderedAscending }
            case .space:
                let ai = a.spaceNumbers.min() ?? Int.max, bi = b.spaceNumbers.min() ?? Int.max
                if ai != bi { return ai < bi }
            }
            return (originalOrder[a.id] ?? 0) < (originalOrder[b.id] ?? 0)
        }
        // Things to open fill in after the windows; a short query should not flood the list with apps.
        var launchers = 0
        candidates = candidates.filter { candidate in
            guard candidate.launcher != nil else { return true }
            launchers += 1
            return launchers <= WindowSearch.launcherLimit
        }
        if profile.grouping == .onePerApp {
            var seen = Set<Int32>(); candidates = candidates.filter { $0.searchOnly || seen.insert($0.pid).inserted }
        }
        // Grouping folds each app into one entry; ↓ expands an app, and searching always lists every window.
        if profile.grouping == .byApp && tokens.isEmpty {
            if let expandedApp {
                candidates = candidates.filter { $0.pid == expandedApp }
            } else {
                var counts: [Int32: Int] = [:]
                for w in candidates where !w.windowless { counts[w.pid, default: 0] += 1 }
                var seen = Set<Int32>()
                candidates = candidates.filter { seen.insert($0.pid).inserted }.map { w in
                    var grouped = w; grouped.groupCount = counts[w.pid] ?? 0; return grouped
                }
            }
        }
        return candidates
    }
}

enum MatchKind: Int {
    case name, pinyin, initials, identifier, typo
    var label: String {
        switch self {
        case .name: return "名称"
        case .pinyin: return "拼音"
        case .initials: return "拼音首字母"
        case .identifier: return "应用标识"
        case .typo: return "拼写容错"
        }
    }
}

/// A text written three ways (as is, as pinyin, as pinyin initials), each mapped back to the
/// original characters so a match can be highlighted where the reader sees it.
struct TextReadings {
    struct Reading {
        let characters: [Character]
        /// For each character above, the index of the original character it came from.
        let owners: [Int]
        func find(_ token: String) -> Range<Int>? {
            let needle = Array(token)
            guard !needle.isEmpty, needle.count <= characters.count else { return nil }
            for start in 0...(characters.count - needle.count) where characters[start] == needle[0] {
                if Array(characters[start..<(start + needle.count)]) == needle {
                    return owners[start]..<(owners[start + needle.count - 1] + 1)
                }
            }
            return nil
        }
    }
    let direct: Reading
    let pinyin: Reading
    let initials: Reading
    private static var cache: [String: TextReadings] = [:]
    private static let lock = NSLock()
    static func of(_ text: String) -> TextReadings {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[text] { return cached }
        if cache.count > 2000 { cache.removeAll(keepingCapacity: true) }
        let value = TextReadings(text)
        cache[text] = value
        return value
    }
    private init(_ text: String) {
        var direct: [Character] = [], directOwners: [Int] = []
        var pinyin: [Character] = [], pinyinOwners: [Int] = []
        var initials: [Character] = [], initialOwners: [Int] = []
        var wordStart = true
        for (index, character) in text.enumerated() {
            let plain = WindowSearch.normalized(String(character))
            for unit in plain { direct.append(unit); directOwners.append(index) }
            if character.isWhitespace { wordStart = true; continue }
            if character.unicodeScalars.first?.properties.isIdeographic == true {
                let syllable = WindowSearch.normalized(String(character).applyingTransform(.toLatin, reverse: false) ?? String(character))
                    .filter { !$0.isWhitespace }
                for unit in syllable { pinyin.append(unit); pinyinOwners.append(index) }
                if let first = syllable.first { initials.append(first); initialOwners.append(index) }
                wordStart = false
            } else {
                for unit in plain { pinyin.append(unit); pinyinOwners.append(index) }
                if wordStart, let first = plain.first { initials.append(first); initialOwners.append(index) }
                wordStart = false
            }
        }
        self.direct = Reading(characters: direct, owners: directOwners)
        self.pinyin = Reading(characters: pinyin, owners: pinyinOwners)
        self.initials = Reading(characters: initials, owners: initialOwners)
    }
}
