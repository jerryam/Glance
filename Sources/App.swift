import AppKit
import SwiftUI
import ApplicationServices

final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the panel session: showing, input, layout and committing a switch.
/// Previews live in AppDelegate+Preview.swift; drop, badges, pins, browser tabs and the system
/// ⌘Tab hand-off live in AppDelegate+Features.swift.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let settings = SettingsStore()
    let engine = WindowEngine()
    let capture = PreviewCapture()
    let state = SwitcherState()
    let hotkeys = HotkeyRegistry()
    let gestures = GestureMonitor()
    let panelInput = PanelInputMonitor()
    var status: NSStatusItem!
    var statusMenu = NSMenu()
    let menuBar = MenuBarController()
    let launcher = LaunchCatalog()
    let dockPreview = DockPreviewController()
    let frontFullscreen = FrontFullscreenWatch()
    var browserTabs = BrowserTabCache<WindowHandle>()
    var panel: SwitcherPanel!
    var previewPanel: PreviewPanel?
    var settingsWindow: NSWindow?
    var settingsModel: SettingsModel?
    var settingsViewLoaded = false
    /// Reopenings after a crash within the policy's window, and whether they have just gone over its limit.
    var crashRestarts: [Double] = []
    var crashRestartStopped = false
    var loadNoticeShown = false
    var localMonitor: Any?
    var globalMonitor: Any?
    var panelClickMonitor: Any?
    var quickCommitCount = 0
    var waitedCommitCount = 0
    /// Why the last global window shortcut did nothing; empty when it worked.
    var windowShortcutError = ""
    var previewTimer: Timer?
    var backgroundTimer: Timer?
    var panelRefreshTimer: Timer?
    var releaseTimer: Timer?
    var refreshDebounce: DispatchWorkItem?
    var idleRefresh: DispatchWorkItem?
    var idleRefreshedAt: TimeInterval = -1_000
    var idleRefreshCount = 0
    /// The selection made from the cached list, while nothing but the trigger has moved it.
    var cachedPickID: String?
    var settingsSetAside = false
    var settingsWasKey = false
    /// When the settings window last gained the keyboard: its place in the recent order, as for any other window.
    var settingsLastFocused: TimeInterval = 0
    var supportObservers: [NSObjectProtocol] = []
    var previousModifiers: ShortcutModifiers = []
    var modifierRepeat: Timer?
    var modifierRepeatGeneration = 0
    var sleeping = false
    var panelRefreshing = false
    /// A window is being brought forward on the action queue. Until it answers, the panel is on its way out:
    /// a second release or Return must not start another, and keys belong to that window.
    var focusInFlight = false
    /// The panel's show delay ran out during a switch, so it stayed hidden. It appears only if the switch fails.
    var panelOrderDeferred = false
    /// A press of a shortcut during a switch, for the panel that comes after it.
    var triggerAfterFocus: (index: Int, reverse: Bool)?
    var gestureActive = false
    var recording = false
    var commandServer: WindowCommandServer?
    var showing = false
    var showGeneration = 0
    var pendingCommit = false
    var pendingFocusID: String?
    var showStarted: TimeInterval = 0
    var firstPreviewRecorded = false
    var initialStep = 0
    var heldTriggerModifiers: ShortcutModifiers = []
    var screen: NSScreen?
    /// nil until first applied, so launch always puts the system ⌘Tab into a known state.
    var nativeSwitcherDisabled: Bool?
    var pins: [WindowPin] = []
    var pinnedIDs = Set<String>()
    var badgesReadAt: TimeInterval = -1_000
    var browserTabsLoadedFor = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        commandServer = WindowCommandServer(engine: engine)
        commandServer?.beforeFocus = { [weak self] in if self?.showing == true { self?.dismiss() } }
        commandServer?.onReopen = { [weak self] in self?.openSettings() }
        commandServer?.diagnostics = { [weak self] in self?.diagnostics() ?? [:] }
        commandServer?.commandsEnabled = { [weak self] in self?.settings.value.advanced.commandLineEnabled ?? false }
        setupMenu()
        panel = SwitcherPanel(contentRect: NSRect(x: 0, y: 0, width: 850, height: 580),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "一瞥 · 窗口切换"
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        panel.contentView = materialView(NSHostingView(rootView: SwitcherView(state: state).frame(maxWidth: .infinity, maxHeight: .infinity)))
        loadPins()
        engine.restoreRecentOrder()
        loadSearchHabits()
        state.onSelect = { [weak self] index, commit in
            guard let self else { return }
            self.state.selectedIndex = index
            if commit { self.confirm() }
        }
        state.onAction = { [weak self] action in self?.perform(action) }
        state.onWindowAction = { [weak self] index, action in self?.state.selectedIndex = index; self?.perform(action) }
        state.onSelectionChanged = { [weak self] in self?.requestSelectedPreview(); self?.updateAutomaticPreview() }
        state.onPreviewVisibility = { [weak self] ids in
            guard let self, self.showing, !self.state.isDemo, self.state.style == .thumbnails else { return }
            self.requestSelectedPreview()
            for item in self.state.items where ids.contains(item.id) { self.capture.request(item, urgent: false) }
        }
        state.onStyle = { [weak self] style in
            guard let self else { return }
            var value = self.settings.value
            if self.state.profile.id == 9, self.state.profile.styleOverride != nil {
                value.advanced.independentGesture?.styleOverride = style; self.state.profile.styleOverride = style
            } else if self.state.profile.styleOverride != nil, let i = value.shortcuts.firstIndex(where: { $0.id == self.state.profile.id }) {
                value.shortcuts[i].styleOverride = style; self.state.profile.styleOverride = style
            } else { value.style = style }
            self.settings.save(value); self.relayout(); self.syncActivityTimers()
            if self.showing && !self.state.isDemo {
                if self.state.style == .thumbnails || self.previewPanel?.isVisible == true || self.state.settings.advanced.autoPreview { self.preparePreviews(self.state.all) }
                else { self.capture.cancel() }
            }
        }
        state.onLayout = { [weak self] in self?.relayout() }
        state.onPermission = { [weak self] in self?.openSettings() }
        state.onPin = { [weak self] in
            guard let self else { return }
            if self.state.searchVisible { self.state.setMessage("搜索时面板保持打开，按回车切换或 Esc 取消。"); return }
            self.state.sticky.toggle(); self.pendingCommit = false; self.pendingFocusID = nil
            self.syncActivityTimers()
        }
        state.onTogglePin = { [weak self] id in self?.togglePin(id) }
        state.onDropFiles = { [weak self] id, urls in self?.openDroppedFiles(urls, on: id) }
        capture.receiveFull = { [weak self] id, image in
            guard let self, self.showing else { return }
            self.state.zoomImage = ZoomFrame(id: id, image: image)
        }
        hotkeys.onTrigger = { [weak self] index, reverse in self?.trigger(index: index, reverse: reverse) }
        hotkeys.onRelease = { [weak self] in self?.modifiersChanged(Self.logicalModifierFlags) }
        hotkeys.onExtra = { [weak self] slot in
            if let command = WindowLayoutCommand(slot: slot) { self?.performWindowShortcut(command) }
            else { self?.menuBar.toggle(all: slot == 1) }
        }
        launcher.onUpdate = { [weak self] in self?.updateExtraItems() }
        launcher.refreshIfNeeded()
        setupDockPreview()
        menuBar.onRevealChange = { [weak self] in self?.updateStatusButton() }
        menuBar.onPointerMoved = { [weak self] in self?.frontFullscreen.lookIfDue() }
        frontFullscreen.onChange = { [weak self] in
            guard let self else { return }
            self.menuBar.pausedForFullscreen = self.frontFullscreen.active
            self.syncActivityTimers()
            // A read that timed out said "not full screen", and the "ignore when full screen" rule goes by the last read.
            self.engine.refreshObservers()
        }
        frontFullscreen.look()
        panelInput.currentState = { [weak self] in
            guard let self else { return PanelKeySnapshot() }
            return PanelKeySnapshot(generation: self.showGeneration, held: self.heldTriggerModifiers, sticky: self.state.sticky, searching: self.state.searchVisible,
                bindings: self.state.settings.advanced.bindings, mode: self.state.settings.advanced.inputMode, panelIsKey: self.panel.isKeyWindow,
                markedText: (self.panel.firstResponder as? NSTextView)?.hasMarkedText() ?? false, focusInFlight: self.focusInFlight,
                triggers: self.hotkeys.activeTriggers)
        }
        panelInput.onKey = { [weak self] event, generation in
            guard let self, self.showing, self.showGeneration == generation, let native = NSEvent(cgEvent: event) else { return }
            _ = self.handleKey(native)
        }
        panelInput.onModifiers = { [weak self] flags, generation in
            guard let self, self.showing, self.showGeneration == generation else { return }
            self.inputModifiers(flags)
        }
        engine.onForegroundChange = { [weak self] in self?.updateHotkeyGate() }
        engine.onWindowsChange = { [weak self] in self?.schedulePanelRefresh() }
        engine.onCacheStale = { [weak self] in self?.scheduleIdleRefresh() }
        engine.onTitlesChange = { [weak self] changes in self?.updateTitles(changes) }
        gestures.onGesture = { [weak self] result in self?.handleGesture(result) ?? false }
        settings.onChange = { [weak self] in self?.applySettings() }
        noteCrashRestart()
        applySettings()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .flagsChanged {
                if !self.panelInput.enabled { self.inputModifiers(event.modifierFlags) }
                return event
            }
            guard self.showing else { return event }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                if event.window !== self.panel && event.window !== self.previewPanel { self.dismiss() }
                return event
            }
            if event.type == .keyUp { return event }
            return self.handleKey(event) ? nil : event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            if self?.panelInput.enabled != true { self?.inputModifiers(event.modifierFlags) }
        }
        supportObservers.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.stopActivityTimers(); self?.syncActivityTimers()
        })
        supportObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }; self.sleeping = true; if self.showing { self.dismiss() }; self.stopActivityTimers(); self.capture.cancel(); self.engine.saveRecentOrder()
        })
        supportObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }; self.sleeping = false; self.engine.refreshObservers(); self.updateHotkeyGate(); self.syncActivityTimers()
        })
        syncActivityTimers()
        if AXIsProcessTrusted() { engine.refresh(frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier) { [weak self] handles in self?.syncPins(handles) } }
        // Someone upgrading has clearly used the switcher already; only a fresh install gets the guide.
        if settings.hadSavedSettings { OnboardingProgress.shared.markTried() }
        let firstRun = !OnboardingProgress.shared.tried
        if CommandLine.arguments.contains("--launcher-dump") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.runLauncherDump() }
        }
        if CommandLine.arguments.contains("--dock-preview-selftest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.runDockPreviewSelfTest() }
        }
        if CommandLine.arguments.contains("--menubar-selftest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.runMenuBarSelfTest() }
        }
        if CommandLine.arguments.contains("--menubar-probe") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.runMenuBarProbe() }
        }
        if CommandLine.arguments.contains("--ui-snapshots") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.runUISnapshots() }
        }
        else if CommandLine.arguments.contains("--demo") { showDemo() }
        else if CommandLine.arguments.contains("--settings") || !AXIsProcessTrusted() || !CGPreflightScreenCaptureAccess() || firstRun { openSettings() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !showing else { return true }
        // Opening 一瞥 again also finds a settings window that a switch left behind other windows.
        if settingsWindow?.isVisible == true { settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        else { openSettings() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A crash on the way out does not need undoing.
        CrashRestart.disarm()
        engine.saveRecentOrder()
        // Every hidden menu bar icon comes back (macOS also ends the request with the process).
        menuBar.releaseAll()
        // The system ⌘Tab state outlives this process; always hand it back.
        if nativeSwitcherDisabled == true { NativeBridge.setSystemAppSwitcher(enabled: true); nativeSwitcherDisabled = false }
    }

    static var logicalModifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: UInt(CGEventSource.flagsState(.combinedSessionState).rawValue))
    }
    func inputModifiers(_ flags: NSEvent.ModifierFlags) {
        let current = ShortcutModifiers(eventFlags: flags), previous = previousModifiers
        if current != previous { stopModifierRepeat() }
        previousModifiers = current
        let triggered = hotkeys.handleModifiers(previous: previous, current: current)
        if showing && !triggered && !recording && !state.isDemo && !gestureActive,
           let command = ModifierNavigation.command(previous: previous, current: current, held: heldTriggerModifiers,
                bindings: state.settings.advanced.bindings, shiftSelectsPrevious: state.settings.advanced.shiftSelectsPrevious,
                searching: state.searchVisible) {
            execute(command)
            if command == .previous || command == .next { startModifierRepeat(command: command, flags: current) }
        }
        modifiersChanged(flags)
    }
    func startModifierRepeat(command: PanelCommand, flags: ShortcutModifiers) {
        stopModifierRepeat()
        modifierRepeatGeneration += 1; let generation = modifierRepeatGeneration
        let delay = max(0.15, NSEvent.keyRepeatDelay), interval = max(0.03, NSEvent.keyRepeatInterval)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.showing, self.modifierRepeatGeneration == generation, self.previousModifiers == flags else { return }
            self.modifierRepeat = self.activityTimer(interval: interval) { [weak self] in
                guard let self, self.showing, self.previousModifiers == flags else { return }
                self.execute(command)
            }
        }
    }
    func stopModifierRepeat() { modifierRepeatGeneration += 1; modifierRepeat?.invalidate(); modifierRepeat = nil }
    func activityTimer(interval: TimeInterval, action: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in action() }
        timer.tolerance = min(0.2, interval * 0.1)
        RunLoop.main.add(timer, forMode: .common); return timer
    }
    func stopActivityTimers() {
        previewTimer?.invalidate(); previewTimer = nil
        backgroundTimer?.invalidate(); backgroundTimer = nil
        panelRefreshTimer?.invalidate(); panelRefreshTimer = nil
        releaseTimer?.invalidate(); releaseTimer = nil
    }
    func syncActivityTimers() {
        // A click elsewhere closes the panel. Watched only while it is open, so a game's clicks do not wake 一瞥.
        if showing && panelClickMonitor == nil {
            panelClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                if self?.showing == true { self?.dismiss() }
            }
        } else if !showing, let monitor = panelClickMonitor {
            NSEvent.removeMonitor(monitor); panelClickMonitor = nil
        }
        guard !sleeping else { stopActivityTimers(); return }
        let plan = ActivityTimerPlan(showing: showing, demo: state.isDemo, previews: state.settings.livePreviews,
            thumbnails: state.style == .thumbnails || state.searchVisible, largePreview: previewPanel?.isVisible == true,
            background: settings.value.advanced.backgroundPreviews && CGPreflightScreenCaptureAccess() && !frontFullscreen.active,
            transient: !state.sticky && !state.searchVisible && !gestureActive && !state.profile.modifiers.isEmpty)
        panelInput.setEnabled(showing && !recording)
        if !plan.release { releaseTimer?.invalidate(); releaseTimer = nil }
        else if releaseTimer == nil {
            // Active-session backstop: flagsChanged can be lost during a Space/key-window handoff.
            releaseTimer = activityTimer(interval: 0.05) { [weak self] in
                guard let self else { return }
                guard self.showing, !self.state.sticky, !self.state.searchVisible, !self.gestureActive else {
                    self.releaseTimer?.invalidate(); self.releaseTimer = nil; return
                }
                self.modifiersChanged(Self.logicalModifierFlags)
            }
        }
        if !plan.preview { previewTimer?.invalidate(); previewTimer = nil }
        else if previewTimer == nil {
            previewTimer = activityTimer(interval: ProcessInfo.processInfo.isLowPowerModeEnabled ? 2.6 : 1.3) { [weak self] in
                guard let self, let selected = self.state.selected else { return }
                self.capture.request(selected)
                if self.previewPanel?.isVisible == true || self.state.searchVisible { self.capture.request(selected, full: true) }
            }
        }
        if !plan.background {
            if backgroundTimer != nil && !showing { capture.cancel() }
            backgroundTimer?.invalidate(); backgroundTimer = nil
        }
        else if backgroundTimer == nil {
            backgroundTimer = activityTimer(interval: ProcessInfo.processInfo.isLowPowerModeEnabled ? 10 : 5) { [weak self] in
                guard let self else { return }
                self.frontFullscreen.lookIfDue()
                self.engine.refresh(frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier) { [weak self] handles in
                    guard let self, !self.showing, self.settings.value.advanced.backgroundPreviews else { return }
                    self.state.retainPreviews(Set(handles.map(\.id)))
                    self.capture.prepare(handles, prioritized: Array(handles.prefix(12).map(\.id))) { [weak self] id, image in self?.state.storePreview(id, image: image) }
                }
            }
        }
        if !plan.list { panelRefreshTimer?.invalidate(); panelRefreshTimer = nil }
        else if panelRefreshTimer == nil {
            // AX notifications are immediate; this is only a fallback for applications that omit them.
            panelRefreshTimer = activityTimer(interval: 10) { [weak self] in self?.schedulePanelRefresh() }
        }
    }
    func schedulePanelRefresh() {
        guard showing, !state.isDemo else { return }
        refreshDebounce?.cancel()
        let generation = showGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.showing, self.showGeneration == generation, !self.state.loading,
                  !self.state.actionPending, !self.panelRefreshing else { return }
            self.refreshPanel()
        }
        refreshDebounce = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
    /// Keeps the cached list current while the panel is closed, so the next ⌥Tab starts from the windows
    /// that really exist. Only window and app events start it; there is no timer.
    func scheduleIdleRefresh() {
        guard !showing, !sleeping, AXIsProcessTrusted() else { return }
        idleRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.showing, !self.sleeping else { return }
            self.idleRefreshedAt = ProcessInfo.processInfo.systemUptime
            self.idleRefreshCount += 1
            self.engine.refresh(frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier) { [weak self] handles in self?.syncPins(handles) }
        }
        idleRefresh = work
        // Soon after the event, but at most once a second for an app that keeps opening windows.
        let sinceLast = ProcessInfo.processInfo.systemUptime - idleRefreshedAt
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.25, 1 - sinceLast), execute: work)
    }
    /// Title changes only update those entries, and arrive in batches: a ticking title costs one filter and
    /// layout per batch at most.
    func updateTitles(_ changes: [String: String]) {
        guard showing, !state.isDemo else { return }
        var changed = false
        for index in state.all.indices {
            guard let title = changes[state.all[index].id], state.all[index].descriptor.title != title else { continue }
            var descriptor = state.all[index].descriptor
            descriptor.title = title
            state.all[index] = state.all[index].with(descriptor)
            changed = true
        }
        if changed { state.refilter(reset: false) }
    }

    /// The panel background: Liquid Glass on macOS 26 and later, a popover material before that.
    /// The system turns the glass opaque by itself when Reduce Transparency is on.
    func materialView<Content: View>(_ hosting: NSHostingView<Content>, frame: NSRect = NSRect(x: 0, y: 0, width: 850, height: 580)) -> NSView {
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            // Regular glass keeps text legible over any desktop; clear glass is meant for photos and video.
            // The panel is a surface, not a control, so it does not react to the pointer.
            glass.style = .regular
            glass.cornerRadius = GlanceDesign.panelRadius
            glass.autoresizingMask = [.width, .height]
            hosting.frame = glass.bounds
            glass.contentView = hosting
            return glass
        }
        let material = NSVisualEffectView(frame: frame)
        material.material = .popover; material.blendingMode = .behindWindow; material.state = .active
        material.wantsLayer = true; material.layer?.cornerRadius = GlanceDesign.panelRadius; material.layer?.masksToBounds = true
        material.autoresizingMask = [.width, .height]
        hosting.frame = material.bounds
        material.addSubview(hosting)
        return material
    }
    func setupMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(item("切换窗口", #selector(showAll)))
        appMenu.addItem(item("搜索窗口", #selector(showSearch)))
        appMenu.addItem(.separator())
        appMenu.addItem(item("设置…", #selector(openSettings), key: ","))
        appMenu.addItem(item("重新启动一瞥", #selector(relaunch)))
        appMenu.addItem(.separator())
        appMenu.addItem(item("退出一瞥", #selector(quit), key: "q"))
        appItem.submenu = appMenu
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        main.addItem(editItem)
        NSApp.mainMenu = main
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "一瞥")
        status.button?.setAccessibilityLabel("一瞥")
        let menu = NSMenu()
        menu.addItem(item("切换窗口", #selector(showAll)))
        menu.addItem(item("搜索窗口", #selector(showSearch)))
        menu.addItem(.separator())
        let styles = NSMenuItem(title: "显示样式", action: nil, keyEquivalent: "")
        let stylesMenu = NSMenu()
        for (i, style) in SwitcherStyle.allCases.enumerated() {
            let row = item(style.label, #selector(setStyle(_:))); row.tag = i; stylesMenu.addItem(row)
        }
        styles.submenu = stylesMenu; menu.addItem(styles)
        menu.addItem(item("设置与权限…", #selector(openSettings)))
        menu.addItem(item("重新启动一瞥", #selector(relaunch)))
        menu.addItem(.separator())
        menu.addItem(item("退出一瞥", #selector(quit)))
        statusMenu = menu
        // A left click shows hidden menu bar icons when any are hidden; a right click opens this menu.
        status.button?.target = self
        status.button?.action = #selector(statusClicked(_:))
        status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    @objc func statusClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let secondary = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if !secondary && menuBar.handlesIconClick {
            menuBar.toggle(all: event?.modifierFlags.contains(.option) == true)
        } else {
            showStatusMenu()
        }
    }
    func showStatusMenu() {
        // The menu bar commands lead the menu while some icons are hidden.
        statusMenu.items.filter { $0.tag == 900 }.forEach { statusMenu.removeItem($0) }
        var entries: [NSMenuItem] = []
        if !hotkeys.errors.isEmpty { entries += [item("部分快捷键冲突，查看设置…", #selector(openSettings)), NSMenuItem.separator()] }
        if menuBar.handlesIconClick {
            let shown = menuBar.reveal != .none
            let showAll = item("显示全部菜单栏图标", #selector(showAllMenuBarIcons))
            showAll.isEnabled = menuBar.reveal != .all
            entries += [item(shown ? "收起菜单栏图标" : "显示隐藏的菜单栏图标", #selector(toggleMenuBarIcons)), showAll,
                        item("菜单栏图标设置…", #selector(openMenuBarSettings)), NSMenuItem.separator()]
        }
        for (offset, entry) in entries.enumerated() { entry.tag = 900; statusMenu.insertItem(entry, at: offset) }
        status.menu = statusMenu
        status.button?.performClick(nil)
        status.menu = nil
    }
    @objc func toggleMenuBarIcons() { menuBar.toggle(all: false) }
    @objc func showAllMenuBarIcons() { if menuBar.reveal != .all { menuBar.toggle(all: true) } }
    @objc func openMenuBarSettings() {
        openSettings()
        settingsModel?.selectedTab = SettingsSection.menuBar.rawValue
    }
    /// The 一瞥 icon looks pressed while hidden menu bar icons are showing. Its hint goes only to VoiceOver:
    /// as a tooltip it was seen in the middle of a full-screen game, far from the icon.
    func updateStatusButton() {
        status?.button?.highlight(menuBar.reveal != .none)
        let tip: String
        if !hotkeys.errors.isEmpty { tip = "一瞥 · 部分快捷键冲突，请在设置中查看" }
        else if menuBar.handlesIconClick { tip = "一瞥 · 点按显示隐藏的菜单栏图标，按住 ⌥ 显示全部，右键打开菜单" }
        else { tip = "一瞥 · 窗口切换与搜索" }
        status?.button?.setAccessibilityHelp(tip)
    }
    func item(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let result = NSMenuItem(title: title, action: selector, keyEquivalent: key); result.target = self; return result
    }
    func applySettings() {
        settingsModel?.synchronize(settings.value)
        applyCrashRestart()
        menuBar.configure(settings.value.menuBar)
        dockPreview.configure(settings.value.dockPreview)
        WindowControl.preferWindowServer = settings.value.advanced.focusMethod == .windowServer
        engine.scanTabs = settings.value.shortcuts.contains { $0.enabled && $0.separateTabs } ||
            (settings.value.advanced.independentGesture?.separateTabs ?? false)
        if !settings.value.advanced.browserTabs { browserTabs = BrowserTabCache() }
        applyHotkeys(reconfigure: true)
        engine.refreshObservers()
        gestures.configure(settings.value.advanced.gesture, avoidsSystem: settings.value.advanced.gestureAvoidsSystem)
        state.settings = showing ? settings.value.effective(for: state.profile) : settings.value
        if state.style != state.settings.style { state.style = state.settings.style }
        switch state.settings.theme {
        case .system: panel?.appearance = nil; settingsWindow?.appearance = nil; previewPanel?.appearance = nil
        case .light: panel?.appearance = NSAppearance(named: .aqua); settingsWindow?.appearance = panel?.appearance; previewPanel?.appearance = panel?.appearance
        case .dark: panel?.appearance = NSAppearance(named: .darkAqua); settingsWindow?.appearance = panel?.appearance; previewPanel?.appearance = panel?.appearance
        }
        switch settings.value.theme {
        case .system: dockPreview.appearance = nil
        case .light: dockPreview.appearance = NSAppearance(named: .aqua)
        case .dark: dockPreview.appearance = NSAppearance(named: .darkAqua)
        }
        if showing { state.refilter(reset: false) }
        status?.isVisible = settings.value.advanced.showMenuIcon
        let colored = settings.value.advanced.menuIcon == .colored
        let symbol = settings.value.advanced.menuIcon == .filled ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "一瞥")
        image?.isTemplate = !colored
        status?.button?.image = colored ? image?.withSymbolConfiguration(.init(paletteColors: [NSColor(srgbRed: 0.94, green: 0.63, blue: 0.19, alpha: 1)])) : image
        updateStatusButton()
        syncActivityTimers()
    }
    func updateHotkeyGate() { applyHotkeys(reconfigure: false) }
    @discardableResult func handleGesture(_ result: GestureResult) -> Bool {
        if result == .end {
            let wasActive = gestureActive; gestureActive = false
            if wasActive && showing { releaseShortcut() }
            return wasActive
        }
        guard !recording, !engine.shortcutsIgnored(settings.value.advanced.exceptions) else { return false }
        switch result {
        case .start(let step):
            gestureActive = true
            let index = settings.value.advanced.gestureProfile
            guard let profile = settings.value.advanced.independentGesture ?? settings.value.shortcuts.first(where: { $0.id == index }) else { gestureActive = false; return false }
            OnboardingProgress.shared.markTried()
            show(profile: profile, initialStep: step)
        case .move(let step): if gestureActive && showing { stepFromTrigger(step) }
        case .end: break
        }
        return gestureActive
    }
    func trigger(index: Int, reverse: Bool) {
        guard let profile = settings.value.shortcuts.first(where: { $0.id == index && $0.enabled }) else { return }
        OnboardingProgress.shared.markTried()
        if focusInFlight { triggerAfterFocus = (index: index, reverse: reverse); return }
        heldTriggerModifiers = profile.modifiers
        if showing && state.profile.id == index && !state.isDemo {
            pendingCommit = PendingReleasePolicy.keepPendingCommit(previous: pendingCommit, triggerPressed: true, triggerHeld: true)
            pendingFocusID = nil
            stepFromTrigger(reverse ? -1 : 1)
            return
        }
        show(profile: profile, initialStep: reverse ? -1 : 1)
        heldTriggerModifiers = profile.modifiers
        if profile.keyCode == KeyChoice.modifierOnly {
            startModifierRepeat(command: reverse ? .previous : .next, flags: previousModifiers)
        }
    }
    /// One more press of the trigger, or a gesture step, while the panel is open.
    func stepFromTrigger(_ step: Int) {
        if state.loading && state.items.isEmpty { initialStep += step; return }
        // Still on the cached list: count the step, so the fresh list can place the selection again.
        let untouched = state.loading && cachedPickID != nil && state.selected?.id == cachedPickID
        state.move(step)
        if untouched { initialStep += step; cachedPickID = state.selected?.id }
    }
    @objc func showAll() {
        var profile = settings.value.shortcuts[0]; profile.scope = .all; profile.keepOpen = true; profile.release = .hold
        show(profile: profile, initialStep: 0)
    }
    @objc func showSearch() {
        var profile = settings.value.shortcuts[0]; profile.keepOpen = true; profile.release = .hold; profile.scope = .all
        show(profile: profile, initialStep: 0, startSearching: true)
    }
    func show(profile: ShortcutProfile, initialStep: Int, startSearching: Bool = false) {
        showStarted = ProcessInfo.processInfo.systemUptime; firstPreviewRecorded = false
        idleRefresh?.cancel(); idleRefresh = nil
        capture.cancel(); previewPanel?.orderOut(nil); dockPreview.hide(reason: "switcher")
        setSettingsAside()
        state.frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        state.cursor = CGEvent(source: nil)?.location
        screen = preferredScreen(frontPID: state.frontPID)
        state.displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        state.profile = profile; state.settings = settings.value.effective(for: profile)
        heldTriggerModifiers = profile.modifiers.intersection(ShortcutModifiers(eventFlags: NSEvent.modifierFlags))
        state.style = state.settings.style; state.isDemo = false
        switch state.settings.theme {
        case .system: panel.appearance = nil
        case .light: panel.appearance = NSAppearance(named: .aqua)
        case .dark: panel.appearance = NSAppearance(named: .darkAqua)
        }
        state.expandedApp = nil; state.extraItems = []; state.zoomImage = nil; state.dropTargetID = nil
        state.ownItems = settingsEntry()
        state.pinnedIDs = pinnedIDs
        state.searchVisible = startSearching
        state.all = engine.cachedSnapshot(); state.query = ""; state.setMessage("")
        // A bare function key has no modifier to release, so its panel stays until Return, Esc or a click.
        state.sticky = startSearching || profile.usesBareKey || (state.settings.advanced.voiceOverKeepsOpen && NSWorkspace.shared.isVoiceOverEnabled)
        state.setVisiblePreviews([])
        state.actionPending = false; panelRefreshing = false; focusInFlight = false; panelOrderDeferred = false; triggerAfterFocus = nil
        state.loading = true; state.refilter(reset: true)
        let usedCache = !state.items.isEmpty
        if usedCache && !startSearching { state.selectedIndex = WindowNavigation.linear(index: 0, count: state.items.count, step: initialStep) }
        cachedPickID = usedCache && !startSearching ? state.selected?.id : nil
        if usedCache { RuntimeDiagnostics.shared.record("list_cached", since: showStarted) }
        pendingCommit = false; pendingFocusID = nil; self.initialStep = initialStep; showing = true; engine.suspendTracking = true
        showGeneration += 1; let generation = showGeneration
        relayout()
        syncActivityTimers()
        panel.alphaValue = 1
        refreshBadges()
        if startSearching { loadBrowserTabsIfNeeded() }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(state.settings.advanced.showDelay)) { [weak self] in
            guard let self, self.showing, self.showGeneration == generation else { return }
            // Already released and switching: showing the panel now would only make it flash.
            if self.focusInFlight { self.panelOrderDeferred = true; return }
            self.orderPanelFront()
            self.modifiersChanged(Self.logicalModifierFlags)
        }
        engine.refresh(frontPID: state.frontPID) { [weak self] handles in
            guard let self, self.showing, self.showGeneration == generation, !self.state.isDemo else { return }
            var intendedID = self.pendingFocusID
            let selectedBefore = self.state.selected?.id
            self.syncPins(handles)
            self.state.all = handles; self.state.loading = false; self.state.refilter(reset: !usedCache && self.state.query.isEmpty)
            if !usedCache && !self.state.items.isEmpty && !self.state.searchVisible && self.state.query.isEmpty {
                self.state.selectedIndex = (self.initialStep % self.state.items.count + self.state.items.count) % self.state.items.count
            }
            if let index = CachedPickPolicy.freshIndex(pickedID: self.cachedPickID, selectedID: selectedBefore,
                searching: self.state.searchVisible || !self.state.query.isEmpty, steps: self.initialStep, count: self.state.items.count) {
                self.state.selectedIndex = index
                if intendedID == selectedBefore { intendedID = self.state.selected?.id }
            }
            self.cachedPickID = nil
            RuntimeDiagnostics.shared.record("list_fresh", since: self.showStarted)
            self.state.retainPreviews(Set(handles.map(\.id)))
            if self.pendingCommit {
                self.pendingCommit = false; self.pendingFocusID = nil
                if let intendedID {
                    if let index = self.state.items.firstIndex(where: { $0.id == intendedID }) { self.state.selectedIndex = index; self.confirm(); return }
                    self.state.sticky = true
                    self.state.setMessage("刚才选中的窗口已经关闭或不再符合筛选，请重新选择。", error: true); self.relayout()
                } else { self.confirm(); return }
            }
            self.preparePreviews(handles)
            self.updateAutomaticPreview()
        }
    }
    private func orderPanelFront() {
        panel.makeKeyAndOrderFront(nil); panel.orderFrontRegardless()
        RuntimeDiagnostics.shared.record("panel_ordered", since: showStarted)
        if !state.searchVisible { panel.makeFirstResponder(nil) }
    }
    func diagnostics() -> [String: Any] {
        ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
         "permissions": ["accessibility": AXIsProcessTrusted(), "screenCapture": CGPreflightScreenCaptureAccess()],
         "timings": RuntimeDiagnostics.shared.summary, "windowCount": engine.windows.count,
         "previewCacheEstimatedBytes": state.previewBytes, "previewCacheLimitBytes": 32 * 1024 * 1024,
         "previewCapturesActive": capture.activeCount, "previewCapturesQueued": capture.queuedCount,
         "panelVisible": showing, "panelLoading": state.loading, "inputMode": settings.value.advanced.inputMode.rawValue,
         "shortcutsSuspended": hotkeys.isSuspended, "shortcutErrors": hotkeys.errors,
         "focusMethod": settings.value.advanced.focusMethod.rawValue, "systemCommandTabDisabled": nativeSwitcherDisabled == true,
         "tabScanning": engine.scanTabs, "browserTabs": settings.value.advanced.browserTabs, "pinnedWindows": pinnedIDs.count,
         "activityTimers": ["preview": previewTimer != nil, "background": backgroundTimer != nil, "list": panelRefreshTimer != nil, "modifierRepeat": modifierRepeat != nil, "release": releaseTimer != nil],
         "panelInput": ["enabled": panelInput.enabled, "error": panelInput.error, "keyWindow": panel.isKeyWindow,
                        "capturedKeyCount": panelInput.capturedKeyCount, "modifierEventCount": panelInput.modifierEventCount,
                        "recoveryCount": panelInput.recoveryCount,
                        "pendingCommit": pendingCommit, "sticky": state.sticky, "searching": state.searchVisible,
                        "requiredModifiers": state.profile.modifiers.rawValue, "currentModifiers": ShortcutModifiers(eventFlags: Self.logicalModifierFlags).rawValue],
         "windowObservers": engine.observedWindowCount, "windowEventCounts": engine.observerEventCounts,
         "windowDiscovery": ["suppressedSurfaces": engine.suppressedSurfaceCount, "unavailableWindowLists": engine.unavailableWindowListCount,
                             "lateScans": engine.lateScanCount, "idleRefreshes": idleRefreshCount],
         "quickRelease": ["atOnce": quickCommitCount, "waited": waitedCommitCount],
         "windowShortcuts": ["active": settings.value.windowShortcuts.active.count, "lastError": windowShortcutError],
         "recentOrder": engine.recentOrderCounts,
         "searchHabits": state.habits.count,
         "crashRestart": ["armed": CrashRestart.armed, "stopped": crashRestartStopped, "recent": crashRestarts.count],
         "frontFullscreen": frontFullscreen.active, "hoverMonitor": menuBar.hoverMonitorActive,
         "gestureAvoidsSystem": settings.value.advanced.gestureAvoidsSystem,
         "uuFullscreenException": settings.value.advanced.exceptions.contains { $0.matches(bundle: "com.netease.uuremote") && $0.ignore == .fullscreen }]
    }
    func preferredScreen(frontPID: Int32?) -> NSScreen? {
        let screens = NSScreen.screens
        if settings.value.advanced.panelScreen == .mouse {
            return screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        }
        if settings.value.advanced.panelScreen == .menuBar, let uuid = NativeBridge.menuBarDisplay() {
            if let found = screens.first(where: { screen in
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                      let value = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return false }
                return (CFUUIDCreateString(nil, value) as String) == uuid
            }) { return found }
        }
        // Asked of the window server, not the app: the panel must not wait for an app that may not be answering.
        // The list runs front to back, so this is the app's frontmost window, ignoring its tiny helper surfaces.
        if let frontPID, let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for window in list where (window[kCGWindowOwnerPID as String] as? Int32) == frontPID && (window[kCGWindowLayer as String] as? Int) == 0 {
                guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                      let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width >= 60, rect.height >= 45 else { continue }
                return screens.max { a, b in
                    let ai = (a.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
                    let bi = (b.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
                    let ar = CGDisplayBounds(ai).intersection(rect), br = CGDisplayBounds(bi).intersection(rect)
                    return max(0, ar.width) * max(0, ar.height) < max(0, br.width) * max(0, br.height)
                }
            }
        }
        return NSScreen.main ?? screens.first
    }
    func relayout() {
        guard let panel else { return }
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let backingScale = Double((screen ?? NSScreen.main)?.backingScaleFactor ?? 2)
        func place(_ size: NSSize) {
            panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height), display: true)
        }
        // Search is a fixed list-and-preview layout: results change, the frame does not jump.
        if state.searchVisible {
            let size = PanelSizing.search(visibleWidth: Double(visible.width), visibleHeight: Double(visible.height))
            place(NSSize(width: size.width, height: size.height))
            return
        }
        let permissionMissing = !state.isDemo && (!AXIsProcessTrusted() || (state.style == .thumbnails && !CGPreflightScreenCaptureAccess()))
        let chrome = PanelChrome.vertical(toolbar: state.showsToolbar, permission: permissionMissing, message: !state.message.isEmpty)
        let available = PanelSizing.available(visibleWidth: Double(visible.width), visibleHeight: Double(visible.height), chrome: chrome)
        var contentWidth = 0.0, contentHeight = 0.0
        switch state.style {
        case .thumbnails:
            let insetWidth = FlowLayout.horizontalInset * 2, insetHeight = FlowLayout.verticalInset * 2
            let aspects = state.items.map { $0.descriptor.windowless || $0.descriptor.searchOnly ? 1.6 : $0.descriptor.aspectRatio }
            state.flow = FlowLayout.calculate(aspects: aspects, availableWidth: available.width - insetWidth,
                                              availableHeight: available.height - insetHeight,
                                              preferredHeight: state.settings.thumbnailWidth * 0.6, adaptive: state.settings.adaptiveThumbnails)
            contentWidth = state.flow.contentWidth + insetWidth
            contentHeight = min(available.height, state.flow.contentHeight + insetHeight)
            capture.thumbnailPixelWidth = Int(max(state.flow.widestThumbnail, state.flow.thumbnailHeight * 1.6) * backingScale)
        case .icons, .titles:
            let count = max(1, state.items.count)
            state.layout = CompactLayout.calculate(style: state.style, count: count, availableWidth: available.width,
                availableHeight: available.height, preferredWidth: state.settings.thumbnailWidth, adaptive: state.settings.adaptiveThumbnails)
            let gap = state.style == .titles ? 3.0 : 12.0, rows = ceil(Double(count) / Double(state.layout.columns))
            let divider = state.atEndDividerIndex == nil ? 0.0 : 11.0
            contentWidth = Double(state.layout.columns) * state.layout.width + Double(state.layout.columns - 1) * gap + 8
            contentHeight = min(available.height, rows * state.layout.height + (rows - 1) * gap + 8 + divider)
        }
        if state.items.isEmpty { contentHeight = max(contentHeight, 190) }
        place(NSSize(width: min(visible.width - 36, max(560, contentWidth + PanelChrome.horizontal)),
                     height: min(visible.height - 36, max(260, contentHeight + chrome))))
    }
    func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        if !ShortcutModifiers(eventFlags: flags).isSuperset(of: heldTriggerModifiers) { heldTriggerModifiers = [] }
        guard showing, !state.sticky, !state.isDemo, !gestureActive else { return }
        let required = state.profile.modifiers.eventFlags
        if flags.intersection(required) != required { releaseShortcut() }
        else if pendingCommit {
            pendingCommit = PendingReleasePolicy.keepPendingCommit(previous: pendingCommit, triggerPressed: false, triggerHeld: true)
            pendingFocusID = nil
        }
    }
    func releaseShortcut() {
        guard let action = ReleaseDecision.action(behavior: state.profile.releaseBehavior, sticky: state.sticky, held: false) else { return }
        switch action {
        case .focus: confirm()
        case .hold: state.sticky = true; syncActivityTimers()
        case .search: beginSearch()
        }
    }
    func handleKey(_ event: NSEvent) -> Bool {
        // The panel is about to close; a key must not start a search in it or act on the old selection.
        guard !focusInFlight else { return true }
        stopModifierRepeat()
        if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        let code = UInt32(event.keyCode)
        var flags = ShortcutModifiers(eventFlags: event.modifierFlags)
        flags.subtract(heldTriggerModifiers)
        if state.settings.advanced.inputMode == .traditional && state.settings.advanced.vimKeys && !state.searchVisible && flags.isEmpty {
            switch code {
            case 4: state.move(-1); return true
            case 37: state.move(1); return true
            case 38: state.moveVertically(down: true); return true
            case 40: state.moveVertically(down: false); return true
            default: break
            }
        }
        // ⌘1 … ⌘9 switch directly (also while ⌘ is the held trigger); plain digits do the same in traditional mode.
        let commandDigit = ShortcutModifiers(eventFlags: event.modifierFlags).subtracting(heldTriggerModifiers.subtracting(.command)) == .command
        if let digit = DigitKeys.index(for: code),
           commandDigit || (flags.isEmpty && !state.searchVisible && state.settings.advanced.inputMode == .traditional) {
            if digit < state.items.count { state.selectedIndex = digit; confirm() }
            return true
        }
        if let command = PanelInputPolicy.command(code: code, flags: ShortcutModifiers(eventFlags: event.modifierFlags),
            held: heldTriggerModifiers, sticky: state.sticky, searching: state.searchVisible, bindings: state.settings.advanced.bindings,
            mode: state.settings.advanced.inputMode) {
            execute(command); return true
        }
        // When grouping by app, ↓ opens the selected app's windows, as in the system app switcher.
        if code == 125 && flags.isEmpty && !state.searchVisible && state.query.isEmpty && state.profile.grouping == .byApp && state.expandedApp == nil,
           expandSelectedApp() { return true }
        if state.settings.advanced.arrowKeys && flags.isEmpty && (123...126).contains(code) {
            if state.searchVisible && !event.modifierFlags.intersection([.command, .control, .shift]).isEmpty { return false }
            if state.searchVisible && !state.query.isEmpty && (code == 123 || code == 124) { return false }
            switch code {
            case 123: state.move(-1)
            case 124: state.move(1)
            default: state.moveVertically(down: code == 125)
            }
            return true
        }
        let actualFlags = ShortcutModifiers(eventFlags: event.modifierFlags)
        if code == 3 && actualFlags == .command && state.settings.advanced.bindings.contains(where: { $0.command == .search && $0.enabled }) {
            beginSearch(selectAll: true); return true
        }
        if let command = PanelInputPolicy.alias(code: code, flags: actualFlags, held: heldTriggerModifiers, bindings: state.settings.advanced.bindings) {
            execute(command); return true
        }
        if code == 9 && actualFlags.subtracting(heldTriggerModifiers) == .command && !state.searchVisible {
            beginSearch(); sendSearchInput(event); return true
        }
        if actualFlags.contains(.command) { return false }
        if !state.searchVisible, !actualFlags.contains(.control), let text = event.charactersIgnoringModifiers,
           !text.isEmpty, text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            beginSearch(); sendSearchInput(event); return true
        }
        if state.searchVisible && heldTriggerModifiers.contains(.option) && event.modifierFlags.contains(.option) && !event.modifierFlags.contains(.control),
           let text = event.charactersIgnoringModifiers, !text.isEmpty,
           text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            sendSearchInput(event); return true
        }
        return false
    }
    func execute(_ command: PanelCommand) {
        switch command {
        case .confirm: confirm()
        case .cancel:
            // Esc first folds an expanded app back into its group, then closes the panel.
            if state.expandedApp != nil { collapseExpandedApp() } else { dismiss(cancelled: true) }
        case .next: state.move(1)
        case .previous: state.move(-1)
        case .search: beginSearch()
        case .close: perform(.close)
        case .minimize: perform(.minimize)
        case .fullscreen: perform(.fullscreen)
        case .quitApp: perform(.quitApp)
        case .hideApp: perform(.hideApp)
        case .preview: togglePreview()
        case .tileLeft: perform(.tileLeft)
        case .tileRight: perform(.tileRight)
        case .maximize: perform(.maximize)
        case .nextScreen: perform(.nextScreen)
        case .togglePin: if let id = state.selected?.id { togglePin(id) }
        }
    }
    func beginSearch(selectAll: Bool = false) {
        stopModifierRepeat()
        pendingCommit = false; pendingFocusID = nil
        state.sticky = true; state.searchVisible = true
        if state.expandedApp != nil { state.expandedApp = nil; state.refilter(reset: false) }
        state.selectSearchText = selectAll; state.searchFocusRequest += 1; relayout()
        syncActivityTimers()
        launcher.refreshIfNeeded()
        updateExtraItems()
        loadBrowserTabsIfNeeded()
        // The detail pane shows the selected window large; make sure captures are prepared for it.
        if !state.isDemo && !state.loading { preparePreviews(state.all) }
    }
    func sendSearchInput(_ event: NSEvent, attempt: Int = 0) {
        let generation = showGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.015)) { [weak self] in
            guard let self, self.showing, self.showGeneration == generation, self.state.searchVisible else { return }
            guard let editor = self.panel.firstResponder as? NSTextView else {
                if attempt < 4 { self.sendSearchInput(event, attempt: attempt + 1) }
                return
            }
            if event.keyCode == 9, ShortcutModifiers(eventFlags: event.modifierFlags).subtracting(self.heldTriggerModifiers) == .command {
                editor.paste(nil)
            } else if self.heldTriggerModifiers.contains(.option), event.modifierFlags.contains(.option),
                      event.modifierFlags.intersection([.command, .control]).isEmpty, let text = event.charactersIgnoringModifiers {
                editor.insertText(text, replacementRange: editor.selectedRange())
            } else { NSApp.sendEvent(event) }
        }
    }
    func confirm() {
        guard showing, !focusInFlight else { return }
        var fromCache = false
        if state.loading {
            // Already waiting for the fresh list: the release timer asks again every 50 ms, and the list settles it.
            let untouched = !pendingCommit && cachedPickID != nil && state.selected?.id == cachedPickID && !state.searchVisible
            guard QuickCommitPolicy.commitsNow(selectionUntouched: untouched, cacheAge: engine.cacheAge, cacheStale: engine.cacheStale) else {
                if !pendingCommit { waitedCommitCount += 1 }
                pendingCommit = true; pendingFocusID = state.selected?.id; return
            }
            quickCommitCount += 1
            fromCache = true
        }
        guard let selected = state.selected else {
            if !state.sticky && !state.searchVisible { dismiss(cancelled: true) }
            return
        }
        if state.isDemo { dismiss(); return }
        recordSearchChoice(selected)
        if selected.descriptor.menuBarItem {
            let id = selected.id
            dismiss()
            menuBar.openMenu(forSearchResult: id)
            return
        }
        if selected.descriptor.launcher != nil {
            let id = selected.id
            dismiss()
            if !launcher.open(id) { NSSound.beep() }
            return
        }
        if selected.descriptor.settingsWindow {
            dismiss()
            bringSettingsForward()
            moveCursorIfAsked(to: selected)
            return
        }
        if !AXIsProcessTrusted() && selected.browserTab == nil { state.setMessage("请先开启辅助功能权限。", error: true); state.sticky = true; relayout(); return }
        if selected.browserTab != nil { focusBrowserTab(selected); return }
        // The app may not be answering, and the keyboard and panel should not wait with it. The panel stays until
        // it has, so a window that cannot be reached can say why.
        focusInFlight = true; state.actionPending = true
        let generation = showGeneration
        WindowControl.performInBackground(.focus, on: selected) { [weak self] error in
            self?.finishFocus(selected, error: error, fromCache: fromCache, generation: generation)
        }
    }
    private func finishFocus(_ selected: WindowHandle, error: String?, fromCache: Bool, generation: Int) {
        let open = showing && showGeneration == generation
        let nextTrigger = open ? triggerAfterFocus : nil
        if open { focusInFlight = false; state.actionPending = false; triggerAfterFocus = nil }
        guard let error else {
            engine.markFocused(selected)
            guard open else { return }
            dismiss()
            moveCursorIfAsked(to: selected)
            if let nextTrigger { trigger(index: nextTrigger.index, reverse: nextTrigger.reverse) }
            return
        }
        guard open else { return }
        switch FocusFailurePolicy.action(fromCache: fromCache, loading: state.loading) {
        case .waitForFreshList:
            pendingCommit = true; pendingFocusID = selected.id
            if panelOrderDeferred { panelOrderDeferred = false; orderPanelFront() }
        case .commitFreshList:
            confirm()
        case .report:
            pendingCommit = false; state.sticky = true; state.setMessage(error, error: true); relayout()
            panelOrderDeferred = false
            orderPanelFront()
        }
    }
    /// 设置 › 鼠标与触控板 › 切换后移动鼠标.
    private func moveCursorIfAsked(to selected: WindowHandle) {
        let mode = state.settings.advanced.followCursor
        if mode != .never, let rect = selected.descriptor.frame, rect.width > 0,
           mode == .always || selected.descriptor.displayID.map({ !CGDisplayBounds($0).contains(state.cursor ?? .zero) }) == true {
            CGWarpMouseCursorPosition(CGPoint(x: rect.x + rect.width / 2, y: rect.y + rect.height / 2))
        }
    }
    /// The settings window steps aside while the panel is open, and comes back when it closes.
    func setSettingsAside() {
        guard let window = settingsWindow, window.isVisible else { return }
        settingsSetAside = true; settingsWasKey = window.isKeyWindow
        window.orderOut(nil)
    }
    /// The settings window's place in the list, while it is open. Read after it has stepped aside.
    func settingsEntry() -> [WindowHandle] {
        guard let window = settingsWindow,
              SettingsWindowEntry.isOpen(visible: window.isVisible, minimized: window.isMiniaturized, setAside: settingsSetAside) else { return [] }
        let frame = window.frame
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.maxY
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? window.screen
        let descriptor = SettingsWindowEntry.descriptor(pid: ProcessInfo.processInfo.processIdentifier, bundleID: Bundle.main.bundleIdentifier ?? "",
            frame: WindowRect(x: Double(frame.minX), y: Double(primaryHeight - frame.maxY), width: Double(frame.width), height: Double(frame.height)),
            displayID: (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
            minimized: window.isMiniaturized, isKey: settingsSetAside && settingsWasKey,
            lastFocused: settingsLastFocused, now: Date.timeIntervalSinceReferenceDate)
        return [WindowHandle(descriptor: descriptor, ax: nil, icon: NSApp.applicationIconImage)]
    }
    /// Chosen from the list: to the front, whichever state it was left in.
    func bringSettingsForward() {
        guard let window = settingsWindow else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func returnSettings(cancelled: Bool) {
        guard settingsSetAside, let window = settingsWindow else { return }
        settingsSetAside = false
        if SettingsReturnPolicy.comesToFront(wasKey: settingsWasKey, cancelled: cancelled, demo: state.isDemo) {
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        } else { window.orderBack(nil) }
    }
    func dismiss(cancelled: Bool = false) {
        showing = false; pendingCommit = false; pendingFocusID = nil; gestureActive = false; heldTriggerModifiers = []
        focusInFlight = false; panelOrderDeferred = false; triggerAfterFocus = nil
        showGeneration += 1; let generation = showGeneration
        stopModifierRepeat(); refreshDebounce?.cancel(); refreshDebounce = nil
        releaseTimer?.invalidate(); releaseTimer = nil; panelInput.setEnabled(false)
        if state.settings.advanced.fadeOut && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && panel.isVisible {
            NSAnimationContext.runAnimationGroup({ context in context.duration = 0.14; panel.animator().alphaValue = 0 }, completionHandler: { [weak self] in
                guard let self, !self.showing, self.showGeneration == generation else { return }
                self.panel.orderOut(nil); self.panel.alphaValue = 1
            })
        } else { panel.orderOut(nil) }
        previewPanel?.orderOut(nil); capture.cancel(); engine.suspendTracking = false
        state.zoomImage = nil; state.extraItems = []; state.ownItems = []; state.expandedApp = nil; state.dropTargetID = nil
        returnSettings(cancelled: cancelled)
        updateHotkeyGate()
        syncActivityTimers()
    }
    func perform(_ action: WindowAction) {
        guard let selected = state.selected, !state.isDemo, !state.actionPending else { return }
        // A menu bar result can belong to a system process; it only opens its menu.
        guard !selected.descriptor.menuBarItem else { state.setMessage("菜单栏图标只能打开它的菜单，按 ↩ 即可。"); relayout(); return }
        guard selected.descriptor.launcher == nil else { state.setMessage("按 ↩ 打开它。"); relayout(); return }
        // Its process is 一瞥 itself, so "quit the app" here would quit the switcher.
        guard !selected.descriptor.settingsWindow else { state.setMessage("按 ↩ 回到设置窗口，再在那里操作。"); relayout(); return }
        guard !state.loading else { state.setMessage("正在更新窗口，请稍候再操作。"); relayout(); return }
        state.sticky = true
        pendingCommit = false; pendingFocusID = nil
        state.setMessage("")
        state.actionPending = true
        let generation = showGeneration
        WindowControl.performInBackground(action, on: selected) { [weak self] error in
            guard let self, self.showing, self.showGeneration == generation else { return }
            if let error { self.state.actionPending = false; self.state.setMessage(error, error: true); self.relayout(); return }
            self.reportAction(action, on: selected, generation: generation)
        }
    }
    private func reportAction(_ action: WindowAction, on selected: WindowHandle, generation: Int) {
        let title = selected.descriptor.displayTitle
        let feedback: String
        switch action {
        case .close: feedback = "已请求关闭“\(title)”。未保存的内容请在原应用确认。"
        case .quitApp: feedback = "已请求退出 \(selected.descriptor.appName)。未保存的内容请在原应用确认。"
        case .minimize: feedback = selected.descriptor.minimized ? "已请求还原“\(title)”。" : "已请求最小化“\(title)”。"
        case .fullscreen: feedback = selected.descriptor.fullscreen ? "已请求退出全屏。" : "已请求进入全屏。"
        case .hideApp: feedback = selected.descriptor.hidden ? "已请求显示 \(selected.descriptor.appName)。" : "已请求隐藏 \(selected.descriptor.appName)。"
        case .tileLeft: feedback = "已把“\(title)”放到左半屏。"
        case .tileRight: feedback = "已把“\(title)”放到右半屏。"
        case .maximize: feedback = "已让“\(title)”填满屏幕。"
        case .nextScreen: feedback = "已把“\(title)”移到下一块屏幕。"
        case .arrange: feedback = "已调整“\(title)”的位置。"
        case .restoreFrame: feedback = "已把“\(title)”还原到调整之前的位置。"
        case .focus: feedback = ""
        }
        state.setMessage(feedback); relayout()
        DispatchQueue.main.asyncAfter(deadline: .now() + (action == .fullscreen ? 0.8 : 0.2)) { [weak self] in
            guard let self, self.showing, self.showGeneration == generation else { return }
            self.engine.refresh(frontPID: self.state.frontPID) { [weak self] handles in
                guard let self, self.showing, self.showGeneration == generation else { return }
                self.state.actionPending = false
                self.state.all = handles; self.state.refilter(reset: false)
                self.state.retainPreviews(Set(handles.map(\.id))); self.preparePreviews(handles)
            }
        }
    }
    func refreshPanel() {
        panelRefreshing = true; let generation = showGeneration
        engine.refresh(frontPID: state.frontPID) { [weak self] handles in
            guard let self, self.showing, self.showGeneration == generation else { return }
            self.panelRefreshing = false
            guard WindowListChange.matters(from: self.state.all.map(\.descriptor), to: handles.map(\.descriptor)) else { return }
            let oldIDs = Set(self.state.all.map(\.id)), ids = Set(handles.map(\.id))
            self.state.all = handles; self.state.refilter(reset: false)
            self.state.retainPreviews(ids)
            if oldIDs != ids { self.preparePreviews(handles) }
        }
    }
    @objc func setStyle(_ sender: NSMenuItem) {
        var value = settings.value; value.style = SwitcherStyle.allCases[sender.tag]; settings.save(value)
    }
    var shortcutErrors: [String] { hotkeys.errors + (gestures.error.isEmpty ? [] : [gestures.error]) }
    @objc func openSettings() {
        if showing { dismiss() }
        if settingsWindow == nil {
            // A standard window with a unified toolbar. The content runs under the toolbar, so on macOS 26
            // and later the sidebar floats as glass and the toolbar buttons become glass, as in System Settings.
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 740),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "一瞥 · 设置"; window.isReleasedWhenClosed = false
            window.toolbarStyle = .unified
            window.contentMinSize = NSSize(width: 900, height: 660)
            window.delegate = self
            settingsWindow = window
        }
        if settingsModel == nil {
            let model = SettingsModel(settings.value)
            // Changes apply as they are made; the first one in each session backs up the previous settings.
            model.applyHandler = { [weak self] in self?.settings.save($0) }
            model.errorsHandler = { [weak self] in self?.shortcutErrors ?? [] }
            model.clearHabitsHandler = { [weak self] in self?.clearSearchHabits() }
            model.beforeFirstApply = { [weak self] in self?.settings.snapshotBackup() }
            settingsModel = model
        }
        guard let model = settingsModel else { return }
        model.beginSession(settings.value)
        if !model.isDirty && !shortcutErrors.isEmpty { model.note(shortcutErrors.joined(separator: "\n"), error: true) }
        if !loadNoticeShown, let notice = settings.loadNotice {
            loadNoticeShown = true
            model.note(notice, error: true); model.selectedTab = SettingsModel.generalTab
        }
        model.shortcutLabel = settings.value.shortcuts.first(where: { $0.enabled })?.displayShortcut ?? "⌥⇥"
        if settingsViewLoaded {
            settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let view = SettingsView(model: model,
                                requestAccessibility: { [weak self] in self?.requestAccessibility() }, requestScreen: { [weak self] in self?.requestScreen() },
                                demo: { [weak self] in self?.showDemo() }, recordingChanged: { [weak self] value in self?.recording = value; self?.updateHotkeyGate() },
                                backup: { [weak self] in self?.settings.backup() }, menuBar: menuBar)
        // The hosting controller hands the page title and the toolbar buttons from SwiftUI to the window.
        let controller = NSHostingController(rootView: view.frame(maxWidth: .infinity, maxHeight: .infinity))
        controller.sizingOptions = []
        controller.sceneBridgingOptions = [.title, .toolbars]
        settingsWindow?.contentViewController = controller
        settingsViewLoaded = true
        settingsWindow?.setContentSize(NSSize(width: 980, height: 740))
        settingsWindow?.center()
        applySettings(); settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) { recording = false; updateHotkeyGate() }
    func windowDidBecomeKey(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow { settingsLastFocused = Date.timeIntervalSinceReferenceDate }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender !== settingsWindow || resolveUnsavedSettings() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        resolveUnsavedSettings() ? .terminateNow : .terminateCancel
    }
    /// Settings apply as they are edited; only an invalid change can still be pending.
    func resolveUnsavedSettings() -> Bool {
        guard let model = settingsModel, !model.applyNow() else { return true }
        let alert = NSAlert(); alert.messageText = "有一项设置无效，尚未生效"
        alert.informativeText = (model.invalidReason ?? "") + "\n可以继续编辑修正，或放弃这次未生效的修改。"
        alert.addButton(withTitle: "继续编辑"); alert.addButton(withTitle: "放弃未生效的修改")
        if alert.runModal() == .alertSecondButtonReturn { model.discardInvalid(); return true }
        settingsWindow?.makeKeyAndOrderFront(nil)
        return false
    }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    func requestScreen() {
        _ = CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
    @objc func relaunch() {
        guard resolveUnsavedSettings() else { return }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.createsNewApplicationInstance = true; configuration.activates = false
        configuration.arguments = ["--restart"]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { app, error in
            DispatchQueue.main.async { if app == nil { self.showNotice(error?.localizedDescription ?? "暂时无法重新启动。") } }
        }
    }
    @objc func quit() { NSApp.terminate(nil) }
    func showNotice(_ text: String) {
        let alert = NSAlert(); alert.messageText = "一瞥"; alert.informativeText = text; alert.runModal()
    }
    func showDemo() {
        capture.cancel(); previewPanel?.orderOut(nil)
        setSettingsAside()
        screen = NSScreen.main; state.profile = ShortcutProfile.defaults()[2]; state.settings = settings.value
        state.style = settings.value.style; state.frontPID = nil; state.displayID = nil; state.loading = false
        state.searchVisible = false
        state.expandedApp = nil; state.extraItems = []; state.ownItems = []; state.zoomImage = nil; state.pinnedIDs = []; state.badges = [:]
        state.query = ""; state.setMessage(""); state.sticky = true; state.isDemo = true; state.actionPending = false; focusInFlight = false
        pendingCommit = false; pendingFocusID = nil; state.setVisiblePreviews([]); showGeneration += 1
        let examples = [("Safari浏览器", "设计参考与工作资料", "/Applications/Safari.app"), ("访达", "项目文件", "/System/Library/CoreServices/Finder.app"),
                        ("终端", "开发工作区", "/System/Applications/Utilities/Terminal.app"), ("邮件", "收件箱", "/System/Applications/Mail.app"),
                        ("音乐", "专注时的播放列表", "/System/Applications/Music.app"), ("备忘录", "本周计划", "/System/Applications/Notes.app")]
        state.all = examples.enumerated().map { index, example in
            let descriptor = WindowDescriptor(id: "demo:\(index)", windowID: nil, pid: 0, appName: example.0, bundleID: "demo.\(index)", title: example.1,
                                              minimized: index == 4, hidden: false, onCurrentSpace: true, displayID: nil, aspectRatio: 1.6)
            state.storePreview(descriptor.id, image: demoImage(index: index, app: example.0, title: example.1))
            return WindowHandle(descriptor: descriptor, ax: nil, icon: NSWorkspace.shared.icon(forFile: example.2))
        }
        state.refilter(reset: true); showing = true; engine.suspendTracking = true; relayout(); syncActivityTimers()
        panel.makeKeyAndOrderFront(nil); panel.orderFrontRegardless()
    }
    func demoImage(index: Int, app: String, title: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 600, height: 365))
        image.lockFocus()
        let colors: [NSColor] = [.systemBlue, .systemTeal, .systemIndigo, .systemOrange, .systemPink, .systemYellow]
        NSColor(calibratedWhite: 0.97, alpha: 1).setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 600, height: 365)).fill()
        colors[index].withAlphaComponent(0.13).setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 145, height: 335)).fill()
        NSColor(calibratedWhite: 0.9, alpha: 1).setFill(); NSBezierPath(rect: NSRect(x: 0, y: 335, width: 600, height: 30)).fill()
        for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.setFill(); NSBezierPath(ovalIn: NSRect(x: 13 + i * 20, y: 345, width: 10, height: 10)).fill()
        }
        (app as NSString).draw(at: NSPoint(x: 20, y: 280), withAttributes: [.font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: NSColor.darkGray])
        (title as NSString).draw(at: NSPoint(x: 173, y: 277), withAttributes: [.font: NSFont.systemFont(ofSize: 25, weight: .semibold), .foregroundColor: NSColor.darkGray])
        for i in 0..<5 {
            colors[index].withAlphaComponent(i == 0 ? 0.45 : 0.14).setFill()
            NSBezierPath(roundedRect: NSRect(x: 173, y: 225 - i * 36, width: 330 - (i % 2) * 70, height: 16), xRadius: 5, yRadius: 5).fill()
        }
        image.unlockFocus(); return image
    }
}

@main
struct GlanceEntry {
    static func main() {
        if WindowCommandServer.runClientIfRequested() { return }
        if WindowCommandServer.handOffToExistingInstance() { return }
        SystemSwitcherGuard.install()
        // An element read from another one does not inherit its timeout. Without a global one it waits about
        // six seconds on a hung app, on the main thread for most of the calls made while switching.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
