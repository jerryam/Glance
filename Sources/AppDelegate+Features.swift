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
        var liveWindowIDs = Set<UInt32>(), runningApps: [Int32: String] = [:]
        if pins.contains(where: { !ids.contains($0.id) }) {
            let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
            liveWindowIDs = Set(info.compactMap { $0[kCGWindowNumber as String] as? UInt32 })
            for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
                runningApps[app.processIdentifier] = app.bundleIdentifier ?? ""
            }
        }
        let resolved = PinPolicy.resolve(pins, windows: windows, runningApps: runningApps, liveWindowIDs: liveWindowIDs)
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
        state.extraItems = (advanced.browserTabs ? browserTabs.all : []) + menuBar.searchResults()
            + launcher.results(apps: advanced.searchApps, settingsPages: advanced.searchSettingsPages)
        if !state.query.isEmpty { state.refilter(reset: false) }
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
