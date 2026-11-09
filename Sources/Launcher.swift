import AppKit
import UniformTypeIdentifiers

/// Something the search panel can open that is not a window: an installed app that is not running, a page of
/// System Settings or a system command. Read from disk in the background, so a search never waits for it.
struct LaunchEntry: Equatable {
    let kind: LaunchKind
    /// Shown as the title: the app's or page's name in the system language.
    let name: String
    /// Its English name when that differs, so "wechat" finds 微信 and "bluetooth" finds 蓝牙.
    let alias: String?
    let bundleID: String
    let url: URL
    /// More words it can be found by, which are not shown.
    var keywords: String? = nil
    var id: String { "launch:\(kind == .app ? "app" : (kind == .setting ? "setting" : "command")):\(bundleID)" }
}

/// The user's files whose names hold what was typed, from Spotlight. It looks once for each pause in the typing and
/// then stops, so nothing runs while the panel is closed.
final class FileSearch {
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?
    private var pending: DispatchWorkItem?
    private(set) var results: [WindowHandle] = []
    var onUpdate: (() -> Void)?

    func search(_ text: String) {
        pending?.cancel(); pending = nil
        let tokens = FileSearchPolicy.tokens(text)
        guard !tokens.isEmpty else {
            stop()
            if !results.isEmpty { results = []; onUpdate?() }
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.start(tokens) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
    func cancel() {
        pending?.cancel(); pending = nil
        stop()
        results = []
    }
    private func stop() {
        query?.stop(); query = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
    private func start(_ tokens: [String]) {
        stop()
        let search = NSMetadataQuery()
        search.searchScopes = [NSMetadataQueryUserHomeScope]
        search.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: tokens.map { NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*\($0)*") })
        search.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: search, queue: .main) { [weak self] _ in self?.finish() }
        query = search
        if !search.start() { stop() }
    }
    private func finish() {
        guard let query else { return }
        query.disableUpdates()
        var paths: [String] = [], types: [String: String] = [:]
        for index in 0..<min(query.resultCount, FileSearchPolicy.looked) {
            guard let item = query.result(at: index) as? NSMetadataItem, let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            paths.append(path)
            types[path] = item.value(forAttribute: NSMetadataItemContentTypeKey) as? String
        }
        stop()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        results = FileSearchPolicy.kept(paths, home: home).map { path in
            var descriptor = WindowDescriptor(id: "file:\(path)", windowID: nil, pid: 0, appName: FileSearchPolicy.place(of: path, home: home), bundleID: "",
                                              title: (path as NSString).lastPathComponent, minimized: false, hidden: false, onCurrentSpace: true, displayID: nil, aspectRatio: 1.6)
            descriptor.launcher = .file
            descriptor.launchTarget = path
            // By the kind of file, so that listing a result never touches anything inside Documents or Desktop.
            let icon = NSWorkspace.shared.icon(for: types[path].flatMap { UTType($0) } ?? .data)
            return WindowHandle(descriptor: descriptor, ax: nil, icon: icon)
        }
        onUpdate?()
    }
}

final class LaunchCatalog {
    private(set) var entries: [LaunchEntry] = []
    private var loadedAt: TimeInterval = -1_000_000
    private var loading = false
    private var icons: [String: NSImage] = [:]
    private let queue = DispatchQueue(label: "Glance.launchCatalog", qos: .utility)
    /// Called on the main queue after a fresh read, so an open search can show the results.
    var onUpdate: (() -> Void)?

    /// Reads the disk again at most every ten minutes, or when an app was installed or removed.
    func refreshIfNeeded(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard !loading, force || now - loadedAt > 600 else { return }
        loading = true
        queue.async { [weak self] in
            let found = Self.scanApps() + Self.scanSettingsPages() + Self.commands()
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                self.loadedAt = ProcessInfo.processInfo.systemUptime
                if found != self.entries { self.entries = found; self.onUpdate?() }
            }
        }
    }

    /// Search results for apps that are not running, for settings pages and for system commands.
    func results(apps: Bool, settingsPages: Bool, commands: Bool = false) -> [WindowHandle] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return entries.filter { entry in
            switch entry.kind {
            case .app: return apps && !running.contains(entry.bundleID)
            case .setting: return settingsPages
            case .command: return commands
            default: return false
            }
        }.map { entry in
            var descriptor = WindowDescriptor(id: entry.id, windowID: nil, pid: 0, appName: entry.alias ?? entry.name, bundleID: entry.bundleID,
                                              title: entry.name, minimized: false, hidden: false, onCurrentSpace: true, displayID: nil, aspectRatio: 1.6)
            descriptor.launcher = entry.kind
            descriptor.subtitle = entry.keywords
            return WindowHandle(descriptor: descriptor, ax: nil, icon: icon(for: entry))
        }
    }

    private func icon(for entry: LaunchEntry) -> NSImage {
        if entry.kind == .command, let symbol = SystemCommand(rawValue: entry.bundleID)?.symbol,
           let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) { return image }
        let path = entry.kind == .app ? entry.url.path : Self.settingsAppPath
        if let cached = icons[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        icons[path] = image
        return image
    }

    /// Opens an entry; returns false when it no longer exists.
    @discardableResult func open(_ id: String) -> Bool {
        guard let entry = entries.first(where: { $0.id == id }) else { return false }
        switch entry.kind {
        case .app:
            guard FileManager.default.fileExists(atPath: entry.url.path) else { refreshIfNeeded(force: true); return false }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: entry.url, configuration: configuration)
        case .setting:
            NSWorkspace.shared.open(entry.url)
        default:
            return false
        }
        return true
    }

    private static func commands() -> [LaunchEntry] {
        SystemCommand.allCases.map { command in
            LaunchEntry(kind: .command, name: command.title, alias: command.english, bundleID: command.rawValue,
                        url: URL(fileURLWithPath: "/"), keywords: command.keywords)
        }
    }

    // MARK: Reading the disk

    static let settingsAppPath = "/System/Applications/System Settings.app"

    private static func scanApps() -> [LaunchEntry] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        // Earlier folders win when the same app is in two places.
        let roots = ["/Applications", "/Applications/Utilities", "\(home)/Applications", "/System/Applications",
                     "/System/Applications/Utilities", "/System/Library/CoreServices/Applications"]
        var seen = Set<String>(), result: [LaunchEntry] = []
        func consider(_ url: URL) {
            guard url.pathExtension == "app", let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !seen.contains(id) else { return }
            let info = bundle.infoDictionary ?? [:]
            // Helpers that run without a window or menu bar icon cannot be "opened" in a useful way.
            if info["LSBackgroundOnly"] as? Bool == true || id == MenuBarPolicy.ownBundle { return }
            seen.insert(id)
            let name = fileManager.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            let english = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
            result.append(LaunchEntry(kind: .app, name: name, alias: english.caseInsensitiveCompare(name) == .orderedSame ? nil : english,
                                      bundleID: id, url: url))
        }
        for root in roots {
            let folder = URL(fileURLWithPath: root)
            guard let items = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for item in items {
                if item.pathExtension == "app" { consider(item); continue }
                // One folder level down, for suites such as "Microsoft Office" or "Adobe Photoshop 2026".
                guard root == "/Applications" || root.hasSuffix("/Applications"),
                      (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                for inner in (try? fileManager.contentsOfDirectory(at: item, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] where inner.pathExtension == "app" {
                    consider(inner)
                }
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// System Settings pages are app extensions; their identifiers open the page directly.
    private static func scanSettingsPages() -> [LaunchEntry] {
        let folder = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions")
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var seen = Set<String>(), result: [LaunchEntry] = []
        for item in items where item.pathExtension == "appex" {
            guard let bundle = Bundle(url: item), let id = bundle.bundleIdentifier, !seen.contains(id) else { continue }
            let info = bundle.infoDictionary ?? [:]
            let attributes = info["EXAppExtensionAttributes"] as? [String: Any]
            guard (attributes?["EXExtensionPointIdentifier"] as? String)?.hasPrefix("com.apple.Settings.extension") == true else { continue }
            // Pages the system only shows in special cases (follow-up suggestions, connected headphones).
            if id.contains("FollowUp") || id.contains("HeadphoneSettings") { continue }
            let raw = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? ""
            let english = englishName(bundle) ?? tidy(raw)
            var found = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.localizedInfoDictionary?["CFBundleName"] as? String)
            if found == nil || found == raw || found == english { found = tableName(bundle, languages: nil) ?? found }
            let localized = found ?? english
            guard !localized.isEmpty, let url = URL(string: "x-apple.systempreferences:\(id)") else { continue }
            seen.insert(id)
            result.append(LaunchEntry(kind: .setting, name: localized, alias: english.caseInsensitiveCompare(localized) == .orderedSame || english.isEmpty ? nil : english,
                                      bundleID: id, url: url))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A page's English name from its English localization, so "bluetooth" or "lock screen" finds it
    /// whatever language the Mac uses.
    private static func englishName(_ bundle: Bundle) -> String? {
        let keys = ["CFBundleDisplayName", "CFBundleName"]
        if let path = bundle.path(forResource: "InfoPlist", ofType: "strings", inDirectory: nil, forLocalization: "en"),
           let strings = NSDictionary(contentsOfFile: path) as? [String: Any] {
            for key in keys { if let name = strings[key] as? String, !name.isEmpty { return name } }
        }
        return tableName(bundle, languages: ["en"])
    }

    /// Newer system bundles keep every language in one table, InfoPlist.loctable. Without `languages`,
    /// the Mac's own language order is used.
    private static func tableName(_ bundle: Bundle, languages: [String]?) -> String? {
        guard let url = bundle.url(forResource: "InfoPlist", withExtension: "loctable"),
              let table = NSDictionary(contentsOf: url) as? [String: Any],
              let language = Bundle.preferredLocalizations(from: Array(table.keys), forPreferences: languages).first,
              let names = table[language] as? [String: Any] else { return nil }
        for key in ["CFBundleDisplayName", "CFBundleName"] { if let name = names[key] as? String, !name.isEmpty { return name } }
        return nil
    }

    /// Turns an internal bundle name into words: "DateAndTime Extension" → "Date And Time".
    static func tidy(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespaces)
        for suffix in ["SettingsExtension", "Settings Extension", "Settings", "Extension"] where name.hasSuffix(suffix) && name.count > suffix.count {
            name = String(name.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        var words = "", previous: Character?
        for character in name {
            if let previous, character.isUppercase, previous.isLowercase { words.append(" ") }
            words.append(character); previous = character
        }
        return words
    }
}
