import AppKit

/// Features added in 1.6: the system ⌘Tab hand-off, pinned windows, dropping files on a card,
/// Dock badges, browser tabs in search and expanding an app group.
extension AppDelegate {
    // MARK: Shortcuts and the system ⌘Tab switcher

    func applyHotkeys(reconfigure: Bool) {
        let ignored = engine.shortcutsIgnored(settings.value.advanced.exceptions)
        // While recording, ⌘Tab must reach the recorder, so the system switcher steps aside then too.
        let disableNative = recording || (NativeSwitcherPolicy.replacesCommandTab(settings.value.shortcuts) && !ignored)
        if disableNative { setNativeSwitcher(disabled: true) }   // free ⌘Tab before registering it
        if reconfigure {
            // Menu bar shortcuts are only claimed where hiding works, so they never take keys for nothing.
            let bar = settings.value.menuBar
            var extras: [(slot: Int, hotkey: MenuBarHotkey)] = menuBar.available && bar.enabled
                ? [(0, bar.toggleHotkey), (1, bar.showAllHotkey)] : []
            extras += settings.value.windowShortcuts.active.map { (slot: $0.command.slot, hotkey: $0.hotkey) }
            hotkeys.configure(settings.value.shortcuts, extras: extras)
        }
        hotkeys.setSuspended(recording || ignored)
        if !disableNative { setNativeSwitcher(disabled: false) }
    }
    func setNativeSwitcher(disabled: Bool) {
        guard nativeSwitcherDisabled != disabled else { return }
        nativeSwitcherDisabled = disabled
        NativeBridge.setSystemAppSwitcher(enabled: !disabled)
    }

    // MARK: Global window shortcuts

    /// Nothing is on screen to say why a shortcut did nothing, so a failure beeps, like a failed switch from the
    /// Dock preview, and the reason goes to the diagnostics.
    func performWindowShortcut(_ command: WindowLayoutCommand) {
        // With the panel open the selected window is the one meant, and the panel can report the outcome.
        if showing { perform(command.action); return }
        // 一瞥 does not arrange its own windows: its accessibility answers would have to come from this main thread.
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != ProcessInfo.processInfo.processIdentifier else {
            windowShortcutError = "前台没有可以调整的窗口（一瞥自己的窗口除外）。"
            NSSound.beep()
            return
        }
        WindowControl.performOnFocusedWindow(command, of: pid) { [weak self] error in
            self?.windowShortcutError = error ?? ""
            if error != nil { NSSound.beep() }
        }
    }

    // MARK: Reopening after a crash

    static let crashRestartsKey = "WindowHop.crashRestarts.v1"
    /// Only the times are kept, to tell one crash from a run of them.
    func noteCrashRestart() {
        let store = UserDefaults.standard, now = Date.timeIntervalSinceReferenceDate
        crashRestarts = CrashRestartPolicy.recent(store.array(forKey: Self.crashRestartsKey) as? [Double] ?? [], now: now)
        guard CommandLine.arguments.contains(CrashRestartPolicy.argument) else { return }
        crashRestarts = CrashRestartPolicy.recording(restartAt: now, history: crashRestarts)
        store.set(crashRestarts, forKey: Self.crashRestartsKey)
        guard !CrashRestartPolicy.allowsAnother(crashRestarts, now: now) else { return }
        crashRestartStopped = true
        DispatchQueue.main.async { [weak self] in
            self?.showNotice("一瞥在 \(Int(CrashRestartPolicy.window / 60)) 分钟内意外退出了 \(CrashRestartPolicy.limit) 次。这次运行中如果再退出，不会再自动重新打开。\n崩溃报告可以在“控制台”应用的“崩溃报告”里找到。")
        }
    }
    func applyCrashRestart() {
        let path = Bundle.main.bundleURL.path
        if settings.value.advanced.restartAfterCrash, !crashRestartStopped, CrashRestartPolicy.applies(arguments: CommandLine.arguments, bundlePath: path) {
            CrashRestart.arm(appPath: path)
        } else { CrashRestart.disarm() }
    }

    // MARK: Pinned windows

    static let pinsKey = "WindowHop.pinned.v2"
    static let legacyPinsKey = "WindowHop.pinned.v1"
    /// Saved pins count only once a fresh read has matched them to real windows; see syncPins.
    func loadPins() {
        let store = UserDefaults.standard
        if let data = store.data(forKey: Self.pinsKey), let saved = try? JSONDecoder().decode([WindowPin].self, from: data) { pins = saved }
        else { pins = (store.stringArray(forKey: Self.legacyPinsKey) ?? []).map(WindowPin.init(legacyID:)) }
    }
    func savePins() {
        if let data = try? JSONEncoder().encode(pins) { UserDefaults.standard.set(data, forKey: Self.pinsKey) }
    }
    func togglePin(_ id: String) {
        guard showing, !state.isDemo, let item = state.items.first(where: { $0.id == id }), !item.descriptor.searchOnly, !item.descriptor.settingsWindow else { return }
        let wasPinned = pinnedIDs.contains(id)
        pins = wasPinned ? pins.filter { $0.id != id } : PinPolicy.adding(WindowPin(item.descriptor), to: pins)
        pinnedIDs = PinPolicy.boundIDs(pins)
        savePins()
        state.pinnedIDs = pinnedIDs
        state.sticky = true; pendingCommit = false; pendingFocusID = nil
        state.setMessage(wasPinned ? "已取消置顶“\(item.descriptor.displayTitle)”。" : "已置顶“\(item.descriptor.displayTitle)”，它会排在当前窗口之后。")
        state.refilter(reset: false)
        syncActivityTimers()
    }
    /// Matches the saved pins to the windows of a fresh read. A pin is forgotten only when the window server
    /// no longer knows its window, not when a refresh missed it.
    func syncPins(_ handles: [WindowHandle]) {
        guard !pins.isEmpty else { return }
        let windows = handles.map(\.descriptor), ids = Set(windows.map(\.id))
        // Only a pin with a process behind it, whose window this read did not find, needs to know which apps run.
        // A pin that waits for its app to come back has none, and may wait for days: it must cost nothing per read.
        // The window numbers are the ones this same read got from the window server.
        var runningApps: [Int32: String] = [:]
        if pins.contains(where: { $0.pid != 0 && !ids.contains($0.id) }) {
            for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
                runningApps[app.processIdentifier] = app.bundleIdentifier ?? ""
            }
        }
        let resolved = PinPolicy.resolve(pins, windows: windows, runningApps: runningApps, liveWindowIDs: engine.liveWindowIDs)
        if resolved != pins { pins = resolved; savePins() }
        pinnedIDs = PinPolicy.boundIDs(pins)
        state.pinnedIDs = pinnedIDs
    }

    // MARK: Dropping files on a card

    func openDroppedFiles(_ urls: [URL], on id: String) {
        guard showing, !state.isDemo, !urls.isEmpty, let index = state.items.firstIndex(where: { $0.id == id }) else { return }
        let item = state.items[index]
        guard !item.descriptor.menuBarItem, item.descriptor.launcher == nil, !item.descriptor.settingsWindow else { return }
        guard let appURL = NSRunningApplication(processIdentifier: item.descriptor.pid)?.bundleURL else {
            state.setMessage("找不到这个应用，无法打开拖入的文件。", error: true); return
        }
        let appName = item.descriptor.appName
        NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard let error else { return }
            DispatchQueue.main.async { self?.showNotice("无法用 \(appName) 打开拖入的文件：\(error.localizedDescription)") }
        }
        state.selectedIndex = index
        confirm()
    }

    // MARK: Dock badges

    func refreshBadges() {
        guard settings.value.advanced.dockBadges, AXIsProcessTrusted() else { state.badges = [:]; return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - badgesReadAt > 1 else { return }
        badgesReadAt = now
        let generation = showGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let labels = DockBadges.read()
            DispatchQueue.main.async {
                guard let self, self.showing, self.showGeneration == generation else { return }
                var badges: [Int32: String] = [:]
                for app in NSWorkspace.shared.runningApplications {
                    if let path = app.bundleURL?.standardizedFileURL.path, let label = labels[path] { badges[app.processIdentifier] = label }
                }
                self.state.badges = badges
            }
        }
    }

    // MARK: Browser tabs in search

    func loadBrowserTabsIfNeeded() {
        guard showing, !state.isDemo, settings.value.advanced.browserTabs, browserTabsLoadedFor != showGeneration else { return }
        browserTabsLoadedFor = showGeneration
        let generation = showGeneration
        browserTabs.keep(only: BrowserTabs.runningKeys)
        // Last time's tabs show at once; each browser's answer then replaces its own, even after the panel has closed.
        updateExtraItems()
        BrowserTabs.discover { [weak self] in
            guard let self else { return }
            self.browserTabs.keep(only: BrowserTabs.runningKeys)
            BrowserTabs.list { [weak self] browser, tabs in
                guard let self else { return }
                self.browserTabs.update(browser, tabs: tabs)
                if self.showing, self.showGeneration == generation { self.updateExtraItems() }
            }
        }
    }
    /// The panel stays until the browser has answered, so a tab that cannot be reached can say why, like any
    /// other window that cannot be switched to.
    func focusBrowserTab(_ selected: WindowHandle) {
        guard !state.actionPending else { return }
        state.actionPending = true
        let generation = showGeneration
        WindowControl.focusBrowserTab(selected) { [weak self] error in
            guard let self else { return }
            let open = self.showing && self.showGeneration == generation
            if open { self.state.actionPending = false }
            guard let error else {
                if open { self.dismiss() }
                self.engine.markFocused(selected)
                return
            }
            guard open else { return }
            self.pendingCommit = false; self.state.sticky = true; self.state.setMessage(error, error: true); self.relayout()
            self.panel.makeKeyAndOrderFront(nil)
        }
    }
    /// Search-only results: browser tabs and menu bar icons.
    func updateExtraItems() {
        guard showing, !state.isDemo else { return }
        let advanced = settings.value.advanced
        var extra = (advanced.browserTabs ? browserTabs.all : []) + menuBar.searchResults()
        extra += launcher.results(apps: advanced.searchApps, settingsPages: advanced.searchSettingsPages, commands: advanced.searchCommands)
        if advanced.searchFiles { extra += fileSearch.results }
        if LayoutSnapshotPolicy.listedInSearch(commands: advanced.searchCommands, saved: layouts.count) { extra += layoutRows() }
        state.extraItems = extra
        if !state.query.isEmpty { state.refilter(reset: false) }
    }

    // MARK: Window layouts

    static let layoutsKey = "WindowHop.layoutSnapshots.v1"
    static let saveLayoutTarget = "save"
    func loadLayouts() {
        layouts = LayoutSnapshotPolicy.decoded(UserDefaults.standard.data(forKey: Self.layoutsKey))
    }
    private func storeLayouts() {
        if let data = try? JSONEncoder().encode(layouts) { UserDefaults.standard.set(data, forKey: Self.layoutsKey) }
        settingsModel?.layouts = layouts
    }
    func layoutRows() -> [WindowHandle] {
        func row(_ id: String, title: String, alias: String, target: String) -> WindowHandle {
            var descriptor = WindowDescriptor(id: id, windowID: nil, pid: 0, appName: alias, bundleID: "", title: title,
                                              minimized: false, hidden: false, onCurrentSpace: true, displayID: nil, aspectRatio: 1.6)
            descriptor.launcher = .layout
            descriptor.launchTarget = target
            descriptor.subtitle = LayoutSnapshotPolicy.keywords
            return WindowHandle(descriptor: descriptor, ax: nil, icon: NSImage(systemSymbolName: LaunchKind.layout.symbol, accessibilityDescription: nil))
        }
        var rows = [row("layout:save", title: "保存当前窗口布局…", alias: "Save Window Layout", target: Self.saveLayoutTarget)]
        for layout in layouts {
            rows.append(row("layout:\(layout.id.uuidString)", title: "恢复布局：\(layout.name)", alias: "Restore Window Layout", target: layout.id.uuidString))
        }
        return rows
    }
    func fillLayoutsMenu() {
        layoutsMenu.removeAllItems()
        layoutsMenu.addItem(item("保存当前布局…", #selector(saveLayoutFromMenu)))
        if !layouts.isEmpty { layoutsMenu.addItem(.separator()) }
        for layout in layouts {
            let row = item("恢复：\(layout.name)", #selector(restoreLayoutFromMenu(_:)))
            row.representedObject = layout.id.uuidString
            layoutsMenu.addItem(row)
        }
    }
    @objc func saveLayoutFromMenu() { saveCurrentLayout() }
    @objc func restoreLayoutFromMenu(_ sender: NSMenuItem) {
        if let text = sender.representedObject as? String, let id = UUID(uuidString: text) { restoreLayout(id) }
    }
    /// Asks for a name on a turn of its own, as this may be called while the panel closes.
    func saveCurrentLayout() {
        DispatchQueue.main.async { [weak self] in self?.askAndSaveLayout() }
    }
    private func askAndSaveLayout() {
        guard AXIsProcessTrusted() else { showNotice("保存窗口布局需要先为“一瞥”开启辅助功能权限。"); return }
        let suggested = LayoutSnapshotPolicy.suggestedName(among: layouts)
        guard let typed = askLayoutName(title: "保存当前窗口布局", button: "保存", name: suggested) else { return }
        let name = typed.isEmpty ? suggested : typed
        if layouts.contains(where: { $0.name == name }), !confirmLayoutChange("已经有名为“\(name)”的布局，要替换它吗？", button: "替换") { return }
        engine.refresh(frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier) { [weak self] handles in
            guard let self else { return }
            let layout = LayoutSnapshotPolicy.capture(name: name, windows: handles.map(\.descriptor), screens: WindowControl.screenAreas(), now: Date.timeIntervalSinceReferenceDate)
            guard !layout.windows.isEmpty else { self.showNotice("现在没有可以保存的窗口。最小化的窗口、隐藏的应用和全屏窗口不会保存。"); return }
            guard let updated = LayoutSnapshotPolicy.adding(layout, to: self.layouts) else {
                self.showNotice("最多保存 \(LayoutSnapshotPolicy.limit) 个布局，请先在 设置 › 搜索与按键 里删除不用的。")
                return
            }
            self.layouts = updated
            self.storeLayouts()
            self.settingsModel?.note("已保存“\(layout.name)”：\(layout.windows.count) 个窗口。")
        }
    }
    /// Asked for by nobody in particular, so it neither beeps nor shows an alert: the result goes in the settings
    /// window's note and the diagnostics.
    func restoreLayout(_ id: UUID, automatic: Bool = false) {
        guard let layout = layouts.first(where: { $0.id == id }) else { if !automatic { NSSound.beep() }; return }
        guard AXIsProcessTrusted() else {
            if !automatic { showNotice("恢复窗口布局需要先为“一瞥”开启辅助功能权限。") }
            return
        }
        engine.refresh(frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier) { [weak self] handles in
            guard let self else { return }
            let screens = WindowControl.screenAreas()
            let matches = LayoutSnapshotPolicy.match(layout.windows, live: handles.map(\.descriptor))
            let byID = Dictionary(handles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var placements: [(handle: WindowHandle, frame: WindowRect)] = []
            for index in layout.windows.indices {
                guard let liveID = matches[index], let handle = byID[liveID] else { continue }
                placements.append((handle: handle, frame: LayoutSnapshotPolicy.target(of: layout.windows[index].frame, savedScreens: layout.screens, screens: screens)))
            }
            WindowControl.restoreLayout(placements) { [weak self] placed in
                guard let self else { return }
                self.layoutResult = "\(placed)/\(layout.windows.count)"
                if automatic {
                    self.automaticLayoutRestores += 1
                    self.settingsModel?.note(LayoutSnapshotPolicy.automaticSummary(name: layout.name, placed: placed, total: layout.windows.count))
                    return
                }
                let summary = LayoutSnapshotPolicy.summary(placed: placed, total: layout.windows.count)
                // Windows moving say enough when it worked. With none moved, nothing on screen would explain why.
                if placed == 0 { self.showNotice(summary) } else { self.settingsModel?.note(summary) }
            }
        }
    }

    /// The displays, whole, in the same coordinates as the screen areas a layout keeps.
    static func displayFrames() -> [WindowRect] {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return [] }
        return NSScreen.screens.map { screen in
            WindowRect(x: Double(screen.frame.minX), y: Double(primaryHeight - screen.frame.maxY), width: Double(screen.frame.width), height: Double(screen.frame.height))
        }
    }
    /// The system says this for the Dock and the menu bar too, and several times for one display: it is looked
    /// into once things have settled.
    func displaysMayHaveChanged() {
        displayChangeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.displaysSettled() }
        displayChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + LayoutSnapshotPolicy.settleDelay, execute: work)
    }
    private func displaysSettled() {
        displayChangeWork = nil
        let displays = Self.displayFrames()
        let changed = LayoutSnapshotPolicy.displaysChanged(old: knownDisplays, new: displays)
        // Kept up to date with the setting off as well, so turning it on later does not act on an old change.
        if !displays.isEmpty { knownDisplays = displays }
        guard changed, settings.value.advanced.restoreLayoutOnScreenChange,
              let layout = LayoutSnapshotPolicy.automaticChoice(layouts, screens: WindowControl.screenAreas()) else { return }
        restoreLayout(layout.id, automatic: true)
    }
    func renameLayout(_ id: UUID) {
        guard let index = layouts.firstIndex(where: { $0.id == id }) else { return }
        guard let name = askLayoutName(title: "重命名布局", button: "重命名", name: layouts[index].name), !name.isEmpty else { return }
        guard !layouts.contains(where: { $0.name == name && $0.id != id }) else { settingsModel?.note("已经有名为“\(name)”的布局。", error: true); return }
        layouts[index].name = name
        storeLayouts()
    }
    func deleteLayout(_ id: UUID) {
        guard let layout = layouts.first(where: { $0.id == id }), confirmLayoutChange("要删除布局“\(layout.name)”吗？", button: "删除") else { return }
        layouts.removeAll { $0.id == id }
        storeLayouts()
    }
    private func askLayoutName(title: String, button: String, name: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: button); alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return LayoutSnapshotPolicy.cleaned(name: field.stringValue)
    }
    private func confirmLayoutChange(_ question: String, button: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = question
        alert.addButton(withTitle: button); alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: The rest of the start menu

    /// A file search for each pause in the typing. A sum does not stop it: "11-9" is in the names of files too.
    func queryChanged(_ query: String) {
        let (prefix, text) = SearchPrefix.split(query, enabled: settings.value.advanced.searchPrefixes)
        // Behind another kind's mark, files would only be left out again.
        guard showing, !state.isDemo, settings.value.advanced.searchFiles, prefix == nil || prefix == .files else { fileSearch.cancel(); return }
        fileSearch.search(text)
    }
    /// Rows made from what was typed. Nothing here touches the network: a web row is only an address until it is chosen.
    func queryItems(for typed: String) -> [WindowHandle] {
        let advanced = settings.value.advanced
        let (prefix, query) = SearchPrefix.split(typed, enabled: advanced.searchPrefixes)
        guard showing, !state.isDemo, !query.isEmpty, prefix != .commands, prefix != .files else { return [] }
        func row(_ id: String, kind: LaunchKind, title: String, detail: String, target: String) -> WindowHandle {
            var descriptor = WindowDescriptor(id: id, windowID: nil, pid: 0, appName: detail, bundleID: "", title: title,
                                              minimized: false, hidden: false, onCurrentSpace: true, displayID: nil, aspectRatio: 1.6)
            descriptor.launcher = kind
            descriptor.launchTarget = target
            return WindowHandle(descriptor: descriptor, ax: nil, icon: NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil))
        }
        var rows: [WindowHandle] = []
        if advanced.searchCalculator, prefix != .web, let value = Calculator.evaluate(query) {
            let answer = Calculator.format(value)
            rows.append(row("query:calculation", kind: .calculation, title: "= \(answer)", detail: query, target: answer))
        }
        if advanced.searchWeb, prefix != .calculation {
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if let address = WebAddress.url(from: text) {
                rows.append(row("query:web", kind: .web, title: "打开 \(text)", detail: address.host ?? text, target: address.absoluteString))
            } else if text.count <= 200, let url = advanced.webEngine.url(for: text) {
                rows.append(row("query:web", kind: .web, title: "用\(advanced.webEngine.label)搜索“\(text)”", detail: advanced.webEngine.label, target: url.absoluteString))
            }
        }
        return rows
    }
    func openLauncherItem(_ descriptor: WindowDescriptor) -> Bool {
        switch descriptor.launcher {
        case .app, .setting:
            return launcher.open(descriptor.id)
        case .command:
            guard let command = SystemCommand(rawValue: descriptor.bundleID) else { return false }
            runSystemCommand(command)
            return true
        case .file:
            guard let path = descriptor.launchTarget else { return false }
            let url = URL(fileURLWithPath: path)
            // Opening a program or a script would run it.
            if descriptor.revealOnly { NSWorkspace.shared.activateFileViewerSelecting([url]); return true }
            return NSWorkspace.shared.open(url)
        case .web:
            // Only ever built here as http or https; checked again because this is where it leaves for the browser.
            guard let target = descriptor.launchTarget, let url = URL(string: target), ["http", "https"].contains((url.scheme ?? "").lowercased()) else { return false }
            return NSWorkspace.shared.open(url)
        case .layout:
            guard let target = descriptor.launchTarget else { return false }
            if target == Self.saveLayoutTarget { saveCurrentLayout(); return true }
            guard let id = UUID(uuidString: target) else { return false }
            restoreLayout(id)
            return true
        case .calculation:
            guard let answer = descriptor.launchTarget else { return false }
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(answer, forType: .string)
        case nil:
            return false
        }
    }
    func runSystemCommand(_ command: SystemCommand) {
        guard command == .emptyTrash else { Self.start(command); return }
        // On a turn of its own, as this is called while the panel closes.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "要清空废纸篓吗？"
            alert.informativeText = "废纸篓里的所有项目都会被永久删除，不能恢复。"
            alert.addButton(withTitle: "清空废纸篓"); alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn { Self.start(command) }
        }
    }
    private static func start(_ command: SystemCommand) {
        DispatchQueue.global(qos: .userInitiated).async {
            if command == .lockScreen, NativeBridge.lockScreen() { return }
            let program = command.program
            let process = Process()
            process.executableURL = URL(fileURLWithPath: program.path)
            process.arguments = program.arguments
            // Most likely macOS refused the Automation permission: a sound rather than nothing at all.
            process.terminationHandler = { finished in
                if finished.terminationStatus != 0 { DispatchQueue.main.async { NSSound.beep() } }
            }
            do { try process.run() } catch { DispatchQueue.main.async { NSSound.beep() } }
        }
    }

    // MARK: Search habits

    /// Kept apart from the settings, so it is not part of a settings export.
    static let searchHabitsKey = "WindowHop.searchHabits.v1"
    func loadSearchHabits() {
        state.habits = SearchHabits.decoded(UserDefaults.standard.data(forKey: Self.searchHabitsKey))
    }
    func recordSearchChoice(_ selected: WindowHandle) {
        guard state.settings.advanced.searchLearning, !state.query.isEmpty, let target = SearchHabits.target(of: selected.descriptor) else { return }
        state.habits.record(query: state.query, target: target, now: Date.timeIntervalSinceReferenceDate)
        if let data = try? JSONEncoder().encode(state.habits) { UserDefaults.standard.set(data, forKey: Self.searchHabitsKey) }
    }
    func clearSearchHabits() {
        state.habits = SearchHabits()
        UserDefaults.standard.removeObject(forKey: Self.searchHabitsKey)
    }

    // MARK: Grouping by app

    /// Opens the selected app's windows. Returns false when there is nothing to expand.
    func expandSelectedApp() -> Bool {
        guard let selected = state.selected, !selected.descriptor.searchOnly, selected.descriptor.groupCount > 1 else { return false }
        let pid = selected.descriptor.pid
        state.expandedApp = pid
        state.refilter(reset: true)
        // In the current app, the first window is the one already in front; start on the next one.
        if pid == state.frontPID && state.items.count > 1 { state.selectedIndex = 1 }
        return true
    }
    func collapseExpandedApp() {
        guard let pid = state.expandedApp else { return }
        state.expandedApp = nil
        state.refilter(reset: false)
        if let index = state.items.firstIndex(where: { $0.descriptor.pid == pid }) { state.selectedIndex = index }
    }
}
