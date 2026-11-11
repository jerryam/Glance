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
        /// The app's name and the title, character by character, for typing that no single reading above covers.
        let units: [[SearchUnit]]
        init(_ w: WindowDescriptor, shuangpin: ShuangpinScheme) {
            let names = [w.appName, w.title, w.subtitle ?? ""].map(WindowSearch.normalized).filter { !$0.isEmpty }
            // "wifi" finds "Wi‑Fi" and "airdrop" finds "Air-Drop": names again without hyphens and dots.
            direct = names + names.map { $0.components(separatedBy: WindowSearch.joiners).joined() }.filter { !names.contains($0) }
            let latin = [w.appName, w.title].map { WindowSearch.normalized($0.applyingTransform(.toLatin, reverse: false) ?? $0) }
            pinyin = latin.map { $0.components(separatedBy: .whitespacesAndNewlines).joined() }.filter { !$0.isEmpty }
            initials = latin.map { $0.components(separatedBy: .whitespacesAndNewlines).compactMap(\.first).map(String.init).joined() }.filter { !$0.isEmpty }
            identifier = WindowSearch.normalized(w.bundleID)
            words = Array(Set((direct + latin).flatMap { $0.components(separatedBy: CharacterSet.alphanumerics.inverted) } + pinyin)).filter { $0.count >= 3 && $0.count <= 49 }
            units = [w.appName, w.title].map { SearchUnit.units(of: $0, shuangpin: shuangpin) }.filter { !$0.isEmpty }
        }
        /// 9 for a whole name, 10 for its start, 11 for its middle.
        func mixedScore(_ typed: [Character]) -> Int? {
            var best: Int?
            for name in units {
                guard let range = MixedSearch.contiguous(typed, in: name) else { continue }
                let score = range.lowerBound > 0 ? 11 : (range.upperBound == name.count ? 9 : 10)
                best = min(best ?? score, score)
            }
            return best
        }
    }
    private final class IndexCache {
        private struct Entry { let value: Index; var accessed: UInt64 }
        private var entries: [String: Entry] = [:]
        private var clock: UInt64 = 0
        private let lock = NSLock()
        func value(for window: WindowDescriptor, shuangpin: ShuangpinScheme) -> Index {
            let key = "\(shuangpin.rawValue)\u{0}\(window.appName)\u{0}\(window.title)\u{0}\(window.bundleID)\u{0}\(window.subtitle ?? "")"
            lock.lock(); defer { lock.unlock() }
            clock &+= 1
            if var entry = entries[key] { entry.accessed = clock; entries[key] = entry; return entry.value }
            let value = Index(window, shuangpin: shuangpin)
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
    private static func index(_ window: WindowDescriptor, shuangpin: ShuangpinScheme) -> Index {
        cache.value(for: window, shuangpin: shuangpin)
    }
    static func matches(_ window: WindowDescriptor, query: String, allowTypos: Bool = true, skips: Bool = true, shuangpin: ShuangpinScheme = .off) -> Bool {
        rank(window, tokens: normalized(query).split(whereSeparator: { $0.isWhitespace }).map(String.init), allowTypos: allowTypos, skips: skips, shuangpin: shuangpin) != nil
    }
    private static func rank(_ window: WindowDescriptor, tokens: [String], allowTypos: Bool, skips: Bool, shuangpin: ShuangpinScheme) -> SearchQuality? {
        guard !tokens.isEmpty else { return .init(weakest: 0, total: 0) }
        let entry = index(window, shuangpin: shuangpin)
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
            else if let mixed = entry.mixedScore(Array(token)) { score = mixed }
            else if entry.identifier.contains(token) { score = 12 }
            else if allowTypos, (4...48).contains(token.count), token.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) }),
                    entry.words.contains(where: { oneEditApart(token, $0) }) { score = 13 }
            else if skips, entry.units.contains(where: { MixedSearch.skipping(Array(token), in: $0) != nil }) { score = 14 }
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
    static func matchKind(_ window: WindowDescriptor, query: String, allowTypos: Bool = true, skips: Bool = true, shuangpin: ShuangpinScheme = .off) -> MatchKind? {
        let tokens = normalized(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty, let quality = rank(window, tokens: tokens, allowTypos: allowTypos, skips: skips, shuangpin: shuangpin) else { return nil }
        switch quality.weakest {
        case 0...2: return .name
        case 3...5, 9...11: return .pinyin
        case 6...8: return .initials
        case 12: return .identifier
        case 13: return .typo
        default: return .skipped
        }
    }
    /// Character ranges (offsets into `Array(text)`) that the query matched, for highlighting.
    /// Tries the text itself, then full pinyin, then pinyin initials, then any mix of them; typo matches are not highlighted.
    static func highlights(in text: String, query: String, skips: Bool = true, shuangpin: ShuangpinScheme = .off) -> [Range<Int>] {
        let tokens = normalized(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty, !text.isEmpty else { return [] }
        let readings = TextReadings.of(text, shuangpin: shuangpin)
        var found: [Range<Int>] = []
        for token in tokens {
            if let range = readings.direct.find(token) ?? readings.pinyin.find(token) ?? readings.initials.find(token) { found.append(range) }
            else if let range = MixedSearch.contiguous(Array(token), in: readings.units) { found.append(range) }
            else if skips, let path = MixedSearch.skipping(Array(token), in: readings.units) { found += path.map { $0..<($0 + 1) } }
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
                         cursorX: Double? = nil, cursorY: Double? = nil, expandedApp: Int32? = nil, learned: [String: Double] = [:]) -> [WindowDescriptor] {
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
            if w.launcher?.madeFromQuery == true { quality[w.id] = SearchQuality(weakest: 15, total: 15); return true }
            guard let rank = rank(w, tokens: tokens, allowTypos: settings.advanced.searchTypos, skips: settings.advanced.searchSkips, shuangpin: settings.advanced.shuangpin) else { return false }
            quality[w.id] = rank
            return true
        }
        func isAtEnd(_ w: WindowDescriptor) -> Bool { WindowSearch.isAtEnd(w, settings: settings, profile: profile) }
        let originalOrder = Dictionary(windows.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        // Pinned windows come right after the current window, so a quick ⌥Tab still returns to the previous one.
        let hasPinned = tokens.isEmpty && candidates.contains { $0.pinned }
        let currentID = hasPinned && profile.order == .recent ? candidates.max { $0.lastFocused < $1.lastFocused }?.id : nil
        func pinRank(_ w: WindowDescriptor) -> Int { w.id == currentID ? 0 : (w.pinned ? 1 : 2) }
        var habit: [String: Double] = [:]
        if !tokens.isEmpty && !learned.isEmpty {
            for w in candidates { if let target = SearchHabits.target(of: w), let score = learned[target] { habit[w.id] = score } }
        }
        candidates.sort { a, b in
            if !tokens.isEmpty {
                let first = a.launcher?.place ?? 1, second = b.launcher?.place ?? 1
                if first != second { return first < second }
            }
            // What the user keeps choosing for this search comes first, however well the others' names match.
            if !habit.isEmpty, habit[a.id] != habit[b.id] { return (habit[a.id] ?? 0) > (habit[b.id] ?? 0) }
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
            // Files come limited already, and a sum or a web search is one row each.
            guard candidate.launcher?.place == 1 else { return true }
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

/// Which result the user chooses for what they type, so the one they keep choosing comes first next time. Saved on this
/// Mac only and not part of a settings export. A window is remembered by its app, never by its title or number.
struct SearchHabits: Codable, Equatable {
    struct Pick: Codable, Equatable {
        var weight: Double
        var time: Double
    }
    /// Normalized search text, then what was chosen for it.
    private(set) var queries: [String: [String: Pick]] = [:]

    static let queryLimit = 300
    static let targetLimit = 5
    /// Pasted text is not a habit, and may be something that should not be written down.
    static let longestQuery = 40
    /// Each choice fades the others for that search, so a new habit overtakes an old one within two choices.
    static let fade = 0.7
    /// One choice can be a slip: it takes two in a row to change the order.
    static let threshold = 1.5
    /// A habit left unused for this long counts half.
    static let halfLife = 90.0 * 86_400
    /// What a choice counts for a longer or shorter form of its search: "chrome" also teaches "ch", less strongly.
    static let relatedShare = 0.6
    private static let forgotten = 0.05

    static func decoded(_ data: Data?) -> SearchHabits {
        data.flatMap { try? JSONDecoder().decode(SearchHabits.self, from: $0) } ?? SearchHabits()
    }
    /// What a choice is remembered by. Windows, tabs and apps to open count for their app, which outlives a restart.
    static func target(of window: WindowDescriptor) -> String? {
        if window.menuBarItem || window.launcher == .setting || window.launcher == .command || window.launcher == .layout { return window.id }
        return window.bundleID.isEmpty ? nil : "app:\(window.bundleID)"
    }
    var count: Int { queries.count }
    private static func key(_ query: String) -> String {
        WindowSearch.normalized(query).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    /// A clock set back must not make a habit stronger than it was.
    private static func current(_ pick: Pick, now: Double) -> Double {
        pick.weight * pow(0.5, max(0, now - pick.time) / halfLife)
    }
    private static func lastUse(_ picks: [String: Pick]) -> Double {
        picks.values.map(\.time).max() ?? 0
    }
    mutating func record(query: String, target: String, now: Double) {
        let key = Self.key(query)
        guard !key.isEmpty, key.count <= Self.longestQuery else { return }
        var picks = (queries[key] ?? [:]).mapValues { Pick(weight: Self.current($0, now: now) * Self.fade, time: now) }
        picks[target, default: Pick(weight: 0, time: now)].weight += 1
        let kept = picks.filter { $0.value.weight >= Self.forgotten }.sorted { ($0.value.weight, $0.key) > ($1.value.weight, $1.key) }.prefix(Self.targetLimit)
        queries[key] = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        if queries.count > Self.queryLimit, let oldest = queries.min(by: { Self.lastUse($0.value) < Self.lastUse($1.value) })?.key {
            queries.removeValue(forKey: oldest)
        }
    }
    /// The results that have earned a place ahead of the others for this search, and how strongly.
    func scores(for query: String, now: Double) -> [String: Double] {
        let key = Self.key(query)
        guard !key.isEmpty else { return [:] }
        var best: [String: Double] = [:]
        for (stored, picks) in queries {
            let share: Double
            if stored == key { share = 1 } else if stored.hasPrefix(key) || key.hasPrefix(stored) { share = Self.relatedShare } else { continue }
            for (target, pick) in picks { best[target] = max(best[target] ?? 0, Self.current(pick, now: now) * share) }
        }
        return best.filter { $0.value >= Self.threshold }
    }
}

enum MatchKind: Int {
    case name, pinyin, initials, identifier, typo, skipped
    var label: String {
        switch self {
        case .name: return "名称"
        case .pinyin: return "拼音"
        case .initials: return "拼音首字母"
        case .identifier: return "应用标识"
        case .typo: return "拼写容错"
        case .skipped: return "跳字匹配"
        }
    }
}

/// A sum typed into the search. Written out here rather than left to NSExpression, which raises an exception on bad
/// input and can call methods by name: everything typed into a search has to be safe to try.
enum Calculator {
    private enum Token: Equatable { case number(Double), symbol(Character), name(String) }
    private static let functions: [String: (Double) -> Double] = [
        "sqrt": { $0.squareRoot() }, "abs": { Swift.abs($0) }, "sin": { sin($0) }, "cos": { cos($0) }, "tan": { tan($0) },
        "ln": { log($0) }, "log": { log10($0) }, "round": { $0.rounded() }, "floor": { $0.rounded(.down) }, "ceil": { $0.rounded(.up) },
    ]
    static let longest = 200
    private static let deepest = 40

    private static func tokens(_ text: String) -> [Token]? {
        var result: [Token] = []
        let characters = Array(WindowSearch.normalized(text))
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace { index += 1; continue }
            if character.isNumber || character == "." {
                var end = index
                while end < characters.count, characters[end].isASCII, characters[end].isNumber || characters[end] == "." { end += 1 }
                let word = String(characters[index..<end])
                // 2024-01-01 and 007 are not numbers anyone adds up, and 1.2.3 is not a number at all.
                guard word.first != "0" || word == "0" || word.hasPrefix("0."), let value = Double(word) else { return nil }
                // 0x10 is sixteen written another way, not nothing times ten.
                if word == "0", end < characters.count, characters[end] == "x" { return nil }
                result.append(.number(value)); index = end; continue
            }
            if character.isLetter, character.isASCII {
                var end = index
                while end < characters.count, characters[end].isLetter, characters[end].isASCII { end += 1 }
                result.append(.name(String(characters[index..<end]))); index = end; continue
            }
            switch character {
            case "+", "-", "*", "/", "%", "^", "(", ")": result.append(.symbol(character))
            case "×": result.append(.symbol("*"))
            case "÷": result.append(.symbol("/"))
            case "−": result.append(.symbol("-"))
            case "π": result.append(.name("pi"))
            default: return nil
            }
            index += 1
        }
        return result
    }

    private struct Parser {
        let tokens: [Token]
        var position = 0
        var depth = 0
        /// A lone number is not a sum: only something worked out makes this a result worth showing.
        var worked = false
        init(_ tokens: [Token]) { self.tokens = tokens }
        var next: Token? { position < tokens.count ? tokens[position] : nil }
        mutating func take(_ symbol: Character) -> Bool {
            guard next == .symbol(symbol) else { return false }
            position += 1
            return true
        }
        mutating func sum() -> Double? {
            guard var value = product() else { return nil }
            while true {
                if take("+") { guard let other = product() else { return nil }; value += other; worked = true }
                else if take("-") { guard let other = product() else { return nil }; value -= other; worked = true }
                else { return value }
            }
        }
        mutating func product() -> Double? {
            guard var value = signed() else { return nil }
            while true {
                if take("*") { guard let other = signed() else { return nil }; value *= other; worked = true }
                else if take("/") { guard let other = signed() else { return nil }; value /= other; worked = true }
                else if take("%") { guard let other = signed() else { return nil }; value = fmod(value, other); worked = true }
                else if next == .name("x") {
                    // 3x4, as it is often typed.
                    position += 1
                    guard let other = signed() else { return nil }
                    value *= other; worked = true
                } else { return value }
            }
        }
        mutating func signed() -> Double? {
            depth += 1; defer { depth -= 1 }
            guard depth <= Calculator.deepest else { return nil }
            if take("-") { return signed().map { -$0 } }
            if take("+") { return signed() }
            guard let base = percent() else { return nil }
            guard takePower() else { return base }
            guard let power = signed() else { return nil }
            worked = true
            return pow(base, power)
        }
        /// ^ or **.
        private mutating func takePower() -> Bool {
            if take("^") { return true }
            guard next == .symbol("*"), position + 1 < tokens.count, tokens[position + 1] == .symbol("*") else { return false }
            position += 2
            return true
        }
        /// 50% is a half, also in 50%+1. A value straight after it means the remainder instead: 10 % 3.
        mutating func percent() -> Double? {
            guard var value = primary() else { return nil }
            while next == .symbol("%") {
                let after = position + 1 < tokens.count ? tokens[position + 1] : nil
                switch after {
                case .number?, .name?, .symbol("(")?: return value
                default: position += 1; value /= 100; worked = true
                }
            }
            return value
        }
        mutating func primary() -> Double? {
            guard let token = next else { return nil }
            switch token {
            case .number(let value):
                position += 1
                return value
            case .symbol("("):
                position += 1
                depth += 1; defer { depth -= 1 }
                guard depth <= Calculator.deepest, let value = sum(), take(")") else { return nil }
                return value
            case .name("pi"):
                position += 1
                return Double.pi
            case .name(let name):
                guard let function = Calculator.functions[name] else { return nil }
                position += 1
                depth += 1; defer { depth -= 1 }
                guard depth <= Calculator.deepest, take("("), let value = sum(), take(")") else { return nil }
                worked = true
                return function(value)
            default:
                return nil
            }
        }
    }

    /// The answer, or nil when this is not a sum that works out.
    static func evaluate(_ text: String) -> Double? {
        guard text.count <= longest, let tokens = tokens(text), !tokens.isEmpty else { return nil }
        var parser = Parser(tokens)
        guard let value = parser.sum(), parser.position == tokens.count, parser.worked, value.isFinite else { return nil }
        return value
    }
    /// Whole numbers in full, the rest without the noise of binary fractions: 0.1 + 0.2 is 0.3.
    static func format(_ value: Double) -> String {
        if value == 0 { return "0" }
        if value == value.rounded(), Swift.abs(value) < 1e15 { return String(Int64(value)) }
        return String(format: "%.12g", value)
    }
}

/// One character of a name, and the ways it can be typed.
struct SearchUnit {
    let plain: [Character]
    /// Every pinyin reading of a Chinese character, and its double pinyin keys when a scheme is chosen.
    let readings: [[Character]]
    /// The start of a word, or any Chinese character.
    let wordStart: Bool
    /// Long titles are looked at only this far: a match further on could not be seen in the list anyway.
    static let longestName = 200

    static func units(of text: String, shuangpin: ShuangpinScheme) -> [SearchUnit] {
        var units: [SearchUnit] = []
        var previous: Character?
        for character in text.prefix(longestName) {
            let chinese = character.unicodeScalars.first?.properties.isIdeographic == true
            let wordy = character.isLetter || character.isNumber
            var start = chinese
            if !chinese && wordy {
                if let previous {
                    let previousWordy = previous.isLetter || previous.isNumber
                    let previousChinese = previous.unicodeScalars.first?.properties.isIdeographic == true
                    start = !previousWordy || previousChinese || (previous.isLowercase && character.isUppercase)
                } else { start = true }
            }
            units.append(SearchUnit(plain: Array(WindowSearch.normalized(String(character))),
                                    readings: chinese ? PinyinReadings.forms(of: character, shuangpin: shuangpin) : [], wordStart: start))
            previous = character
        }
        return units
    }
}

/// Typing that mixes the ways of writing a name: "微xin" and "wxin" for 微信, or letters skipped along the way.
enum MixedSearch {
    /// Where one character can carry the typing to from position `t`, furthest first.
    private static func advances(_ unit: SearchUnit, _ token: [Character], _ t: Int) -> [Int] {
        let next = token[t]
        guard unit.plain.first == next || unit.readings.contains(where: { $0.first == next }) else { return [] }
        func typed(_ part: [Character]) -> Bool {
            !part.isEmpty && t + part.count <= token.count && token[t..<(t + part.count)].elementsEqual(part)
        }
        var found: [Int] = []
        if typed(unit.plain) { found.append(t + unit.plain.count) }
        let left = token.count - t
        for reading in unit.readings {
            if typed(reading) { found.append(t + reading.count) }
            // The typing ends part way through this reading: "weix" for 微信.
            else if left < reading.count, reading[0..<left].elementsEqual(token[t...]) { found.append(token.count) }
            // Only the first letter: "wxin" for 微信.
            if reading.count > 1, reading.first == next { found.append(t + 1) }
        }
        return found.sorted(by: >)
    }

    /// The characters used from `start`, one failure remembered per position, so a repetitive name stays quick.
    private static func walk(_ token: [Character], _ units: [SearchUnit], start: Int, end: Int, skipping: Bool, wordStartsOnly: Bool) -> [Int]? {
        let width = token.count + 1
        var failed = [Bool](repeating: false, count: (end - start + 1) * width)
        func step(_ j: Int, _ t: Int) -> [Int]? {
            if t == token.count { return [] }
            guard j < end else { return nil }
            let key = (j - start) * width + t
            if failed[key] { return nil }
            if !wordStartsOnly || units[j].wordStart {
                for next in advances(units[j], token, t) {
                    if let rest = step(j + 1, next) { return [j] + rest }
                }
            }
            if skipping, j > start, let rest = step(j + 1, t) { return rest }
            failed[key] = true
            return nil
        }
        return step(start, 0)
    }

    /// Consecutive characters, each typed in any way.
    static func contiguous(_ token: [Character], in units: [SearchUnit]) -> Range<Int>? {
        guard !token.isEmpty else { return nil }
        for start in units.indices where !advances(units[start], token, 0).isEmpty {
            // Each character uses at least one letter of the typing.
            let end = min(units.count, start + token.count)
            if let path = walk(token, units, start: start, end: end, skipping: false, wordStartsOnly: false), let last = path.last {
                return start..<(last + 1)
            }
        }
        return nil
    }

    /// Characters in order with others skipped: "chrm" for Chrome. It starts at the start of a word and stays close
    /// together. Three letters must all be the starts of words, since short typing fits almost anything otherwise.
    static func skipping(_ token: [Character], in units: [SearchUnit]) -> [Int]? {
        guard (3...48).contains(token.count) else { return nil }
        for start in units.indices where units[start].wordStart && !advances(units[start], token, 0).isEmpty {
            let end = min(units.count, start + token.count * 3 + 3)
            if let path = walk(token, units, start: start, end: end, skipping: true, wordStartsOnly: token.count == 3) { return path }
        }
        return nil
    }
}

/// The readings of a Chinese character. The system's transliteration gives one for each, often the wrong one for
/// the word: 重庆 as zhongqing and 银行 as yinxing.
enum PinyinReadings {
    private static let lock = NSLock()
    private static var cache: [ShuangpinScheme: [Character: [[Character]]]] = [:]
    /// Common characters with more than one reading, without tones; ü is written v.
    private static let multiple: [Character: [String]] = {
        var table: [Character: [String]] = [:]
        let entries = """
        阿 a e;拗 ao niu;扒 ba pa;蚌 bang beng;薄 bo bao;堡 bao bu pu;暴 bao pu;臂 bi bei;辟 bi pi;扁 bian pian;便 bian pian;剥 bo bao;卜 bu bo
        藏 cang zang;参 can shen cen;曾 ceng zeng;差 cha chai ci;查 cha zha;禅 chan shan;颤 chan zhan;长 chang zhang;朝 chao zhao;车 che ju
        称 cheng chen;乘 cheng sheng;澄 cheng deng;匙 chi shi;重 zhong chong;仇 chou qiu;臭 chou xiu;畜 chu xu;传 chuan zhuan;伺 ci si;攒 cuan zan
        撮 cuo zuo;大 da dai;单 dan shan chan;弹 dan tan;得 de dei;的 de di;地 di de;调 diao tiao;都 dou du;度 du duo;读 du dou;囤 dun tun
        恶 e wu;番 fan pan;否 fou pi;给 gei ji;谷 gu yu;龟 gui jun qiu;还 hai huan;合 he ge;和 he huo hu;核 he hu;会 hui kuai;奇 qi ji;系 xi ji
        家 jia jie;夹 jia ga;价 jia jie;见 jian xian;降 jiang xiang;强 qiang jiang;角 jiao jue;脚 jiao jue;校 xiao jiao;觉 jue jiao;解 jie xie
        劲 jin jing;圈 quan juan;卡 ka qia;咳 ke hai;壳 ke qiao;溃 kui hui;落 luo la lao;烙 lao luo;乐 le yue;了 le liao;露 lu lou;绿 lv lu;率 lv shuai
        络 luo lao;脉 mai mo;埋 mai man;蔓 man wan;没 mei mo;秘 mi bi;模 mo mu;摩 mo ma;那 na nei;娜 na nuo;弄 nong long;胖 pang pan;炮 pao bao
        屏 ping bing;曝 pu bao;瀑 pu bao;期 qi ji;栖 qi xi;亲 qin qing;茄 qie jia;区 qu ou;雀 que qiao;色 se shai;杉 shan sha;折 zhe she;什 shen shi
        省 sheng xing;盛 sheng cheng;识 shi zhi;石 shi dan;似 si shi;数 shu shuo;属 shu zhu;说 shuo shui yue;宿 su xiu;缩 suo su;拓 tuo ta;提 ti di
        褪 tui tun;尾 wei yi;蔚 wei yu;吓 xia he;削 xiao xue;血 xue xie;行 xing hang;咽 yan ye;叶 ye xie;钥 yao yue;遗 yi wei;约 yue yao;择 ze zhai
        扎 zha za;粘 zhan nian;着 zhe zhao zhuo;种 zhong chong;幢 zhuang chuang
        """
        for entry in entries.split(whereSeparator: { $0 == ";" || $0.isNewline }) {
            let parts = entry.split(whereSeparator: { $0.isWhitespace })
            if let character = parts.first?.first { table[character] = parts.dropFirst().map(String.init) }
        }
        return table
    }()

    /// Every way the character is read, as typed: lü also as lv.
    static func syllables(of character: Character) -> [String] {
        let raw = String(character).applyingTransform(.toLatin, reverse: false) ?? String(character)
        var all: [String] = []
        let plain = WindowSearch.normalized(raw).filter { !$0.isWhitespace }
        if !plain.isEmpty { all.append(plain) }
        let umlauts: [Character] = ["ü", "ǖ", "ǘ", "ǚ", "ǜ"]
        if raw.contains(where: { umlauts.contains($0) }) {
            all.append(WindowSearch.normalized(String(raw.map { (letter: Character) -> Character in umlauts.contains(letter) ? "v" : letter })).filter { !$0.isWhitespace })
        }
        all += multiple[character] ?? []
        var seen = Set<String>()
        return all.filter { seen.insert($0).inserted }
    }

    static func forms(of character: Character, shuangpin: ShuangpinScheme) -> [[Character]] {
        lock.lock(); defer { lock.unlock() }
        if let known = cache[shuangpin]?[character] { return known }
        let readings = syllables(of: character)
        var forms = readings
        if shuangpin != .off { forms += readings.flatMap { Shuangpin.codes(for: $0, scheme: shuangpin) } }
        var seen = Set<String>()
        let result = forms.filter { seen.insert($0).inserted }.map { Array($0) }
        cache[shuangpin, default: [:]][character] = result
        return result
    }
}

/// Double pinyin: two keys for each syllable. The tables follow the RIME project's schemes for these layouts.
enum Shuangpin {
    private static let tables: [ShuangpinScheme: [String: [String]]] = [
        .xiaohe: table("iu:q ei:w uan:r ue:t ve:t un:y uo:o ie:p ong:s iong:s ing:k uai:k ai:d en:f eng:g iang:l uang:l ang:h ian:m an:j ou:z ia:x ua:x iao:n ao:c ui:v in:b v:v"),
        .ziranma: table("iu:q ia:w ua:w uan:r van:r ue:t ve:t ing:y uai:y uo:o un:p vn:p ong:s iong:s iang:d uang:d en:f eng:g ang:h ian:m an:j iao:c ao:k ai:l ei:z ie:x ui:v ou:b in:n v:v"),
        .microsoft: table("iu:q ia:w ua:w er:r uan:r van:r ue:t,v ve:t,v v:y uai:y uo:o un:p vn:p ong:s iong:s iang:d uang:d en:f eng:g ang:h ian:m an:j iao:c ao:k ai:l ei:z ie:x ui:v ou:b in:n ing:;"),
    ]
    private static func table(_ text: String) -> [String: [String]] {
        var keys: [String: [String]] = ["a": ["a"], "e": ["e"], "i": ["i"], "o": ["o"], "u": ["u"]]
        for pair in text.split(separator: " ") {
            let parts = pair.split(separator: ":")
            if parts.count == 2 { keys[String(parts[0])] = parts[1].split(separator: ",").map(String.init) }
        }
        return keys
    }

    /// The keys for one syllable without tones, or nothing when it is not one the layout has.
    static func codes(for syllable: String, scheme: ShuangpinScheme) -> [String] {
        guard let keys = tables[scheme], let first = syllable.first else { return [] }
        let shortcut = ["zh": "v", "ch": "i", "sh": "u"][String(syllable.prefix(2))]
        let head = shortcut ?? ("bpmfdtnlgkhjqxrzcsyw".contains(first) ? String(first) : nil)
        let tail = String(syllable.dropFirst(shortcut != nil ? 2 : (head != nil ? 1 : 0)))
        var candidates: [String]
        if let head {
            var finals = keys[tail] ?? []
            // After j, q, x and y a written u is really ü.
            if tail == "u", "jqxy".contains(first) { finals += keys["v"] ?? [] }
            candidates = finals.map { head + $0 }
        } else {
            // No consonant to start with: the first letter or, for the Microsoft layout, also o takes its place.
            let starts = scheme == .microsoft ? ["o", String(first)] : [String(first)]
            candidates = starts.flatMap { start in (keys[tail] ?? []).map { start + $0 } }
            if tail.count == 2 { candidates.append(tail) }
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
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
    let units: [SearchUnit]
    private static var cache: [String: TextReadings] = [:]
    private static let lock = NSLock()
    static func of(_ text: String, shuangpin: ShuangpinScheme = .off) -> TextReadings {
        // A character's forms are cached under their own lock, which is never taken the other way round.
        lock.lock(); defer { lock.unlock() }
        let key = "\(shuangpin.rawValue)\u{0}\(text)"
        if let cached = cache[key] { return cached }
        if cache.count > 2000 { cache.removeAll(keepingCapacity: true) }
        let value = TextReadings(text, shuangpin: shuangpin)
        cache[key] = value
        return value
    }
    private init(_ text: String, shuangpin: ShuangpinScheme) {
        units = SearchUnit.units(of: text, shuangpin: shuangpin)
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
