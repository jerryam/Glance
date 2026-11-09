import AppKit
import ApplicationServices

/// Keeps panel control keys reachable when a nonactivating panel loses key-window status.
/// The tap stays disabled outside a panel session and never records typed text.
///
/// While the tap is enabled, every key on the system waits for its answer. So it runs on its own thread and
/// answers from the state the main thread last published, instead of waiting for a main thread that may be busy.
/// What it captures still reaches the main thread, in order, as soon as that thread is free.
final class PanelInputMonitor {
    private let lock = NSLock()
    private var tap: CFMachPort?
    private var thread: BackgroundRunLoop?
    private var source: CFRunLoopSource?
    private var idleObserver: CFRunLoopObserver?
    private var live = false
    private var snapshot = PanelKeySnapshot()
    private var captured = 0, modifierEvents = 0, recoveries = 0
    private(set) var error = ""
    var enabled: Bool { lock.withLock { live } }
    var capturedKeyCount: Int { lock.withLock { captured } }
    var modifierEventCount: Int { lock.withLock { modifierEvents } }
    var recoveryCount: Int { lock.withLock { recoveries } }
    /// Asked on the main thread each time it runs out of work, while the tap is enabled.
    var currentState: (() -> PanelKeySnapshot)?
    /// On the main queue, with the generation of the panel session the event was decided for.
    var onKey: ((CGEvent, Int) -> Void)?
    var onModifiers: ((NSEvent.ModifierFlags, Int) -> Void)?
    deinit {
        if let source { thread?.remove(source) }
        if let tap { CFMachPortInvalidate(tap) }
        if let idleObserver { CFRunLoopObserverInvalidate(idleObserver) }
        thread?.finish()
    }
    func setEnabled(_ value: Bool) {
        if value && tap == nil { prepare() }
        let on = value && tap != nil
        if on { publish() }
        lock.withLock { live = on }
        if let tap { CGEvent.tapEnable(tap: tap, enable: on) }
        watchIdle(on)
    }
    private func publish() {
        guard let state = currentState?() else { return }
        lock.withLock { snapshot = state }
    }
    /// A fresh copy whenever the main thread has finished what it was doing, and no work at all while the panel is closed.
    private func watchIdle(_ on: Bool) {
        if on && idleObserver == nil {
            let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, _ in
                self?.publish()
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            idleObserver = observer
        } else if !on, let observer = idleObserver {
            CFRunLoopObserverInvalidate(observer)
            idleObserver = nil
        }
    }
    private func prepare() {
        guard AXIsProcessTrusted() else { error = "面板按键接收需要已授权的辅助功能权限。"; return }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<PanelInputMonitor>.fromOpaque(context).takeUnretainedValue()
                return autoreleasepool { owner.decide(type, event) }
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            error = "系统暂未允许面板按键接收，请重新检查辅助功能权限。"; return
        }
        // A new tap starts enabled, and with nothing reading it the keyboard would wait for it.
        CGEvent.tapEnable(tap: created, enable: false)
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0) else {
            CFMachPortInvalidate(created); error = "面板按键接收初始化失败。"; return
        }
        let thread = self.thread ?? BackgroundRunLoop(name: "Glance.panelKeys", qos: .userInteractive)
        thread.add(source)
        lock.withLock { tap = created }
        self.thread = thread; self.source = source
        error = ""
    }
    /// On the tap's thread. Uses nothing but the event and the published state.
    private func decide(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let (resume, port): (Bool, CFMachPort?) = lock.withLock { recoveries += 1; return (live, tap) }
            if resume, let port { CGEvent.tapEnable(tap: port, enable: true) }
            return pass
        }
        let (on, state): (Bool, PanelKeySnapshot) = lock.withLock { (live, snapshot) }
        guard on else { return pass }
        let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)), generation = state.generation
        if type == .flagsChanged {
            lock.withLock { modifierEvents += 1 }
            DispatchQueue.main.async { [weak self] in self?.onModifiers?(flags, generation) }
            return pass
        }
        let code = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        guard type == .keyDown, state.captures(code: code, flags: ShortcutModifiers(eventFlags: flags)), let copy = event.copy() else { return pass }
        lock.withLock { captured += 1 }
        DispatchQueue.main.async { [weak self] in self?.onKey?(copy, generation) }
        return nil
    }
}
