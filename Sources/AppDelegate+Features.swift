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
            let extras: [(slot: Int, hotkey: MenuBarHotkey)] = menuBar.available && bar.enabled
                ? [(0, bar.toggleHotkey), (1, bar.showAllHotkey)] : []
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

    // MARK: Pinned windows

    static let pinsKey = "WindowHop.pinned.v1"
    func loadPins() {
        pinnedIDs = Set(UserDefaults.standard.stringArray(forKey: Self.pinsKey) ?? [])
    }
    func savePins() {
        UserDefaults.standard.set(Array(pinnedIDs).sorted(), forKey: Self.pinsKey)
    }
    func togglePin(_ id: String) {
        guard showing, !state.isDemo, let item = state.items.first(where: { $0.id == id }), !item.descriptor.searchOnly else { return }
        let wasPinned = pinnedIDs.contains(id)
        if wasPinned { pinnedIDs.remove(id) } else { pinnedIDs.insert(id) }
        savePins()
        state.pinnedIDs = pinnedIDs
        state.sticky = true; pendingCommit = false; pendingFocusID = nil
        state.setMessage(wasPinned ? "已取消置顶“\(item.descriptor.displayTitle)”。" : "已置顶“\(item.descriptor.displayTitle)”，它会排在当前窗口之后。")
        state.refilter(reset: false)
        syncActivityTimers()
    }
    /// Forgets pins only for windows the window server no longer knows, not ones a refresh missed.
    func prunePins(validIDs: Set<String>) {
        let missing = pinnedIDs.subtracting(validIDs)
        guard !missing.isEmpty else { return }
        let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let alive = Set(info.compactMap { $0[kCGWindowNumber as String] as? UInt32 })
        let gone = missing.filter { id in
            if id.hasPrefix("cg:"), let number = UInt32(id.dropFirst(3)) { return !alive.contains(number) }
            if id.hasPrefix("app:"), let pid = Int32(id.dropFirst(4)) { return NSRunningApplication(processIdentifier: pid) == nil }
            return true
        }
        guard !gone.isEmpty else { return }
        pinnedIDs.subtract(gone); savePins(); state.pinnedIDs = pinnedIDs
    }

    // MARK: Dropping files on a card

    func openDroppedFiles(_ urls: [URL], on id: String) {
        guard showing, !state.isDemo, !urls.isEmpty, let index = state.items.firstIndex(where: { $0.id == id }) else { return }
        let item = state.items[index]
        guard !item.descriptor.menuBarItem, item.descriptor.launcher == nil else { return }
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
        BrowserTabs.list { [weak self] tabs in
            guard let self, self.showing, self.showGeneration == generation else { return }
            self.browserTabResults = tabs
            self.updateExtraItems()
        }
    }
    /// Search-only results: browser tabs and menu bar icons.
    func updateExtraItems() {
        guard showing, !state.isDemo else { return }
        if browserTabsLoadedFor != showGeneration { browserTabResults = [] }
        let advanced = settings.value.advanced
        state.extraItems = browserTabResults + menuBar.searchResults()
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
