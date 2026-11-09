import AppKit
import ApplicationServices

/// Keeps panel control keys reachable when a nonactivating panel loses key-window status.
/// The tap stays disabled outside a panel session and never records typed text.
final class PanelInputMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var enabled = false
    private(set) var error = ""
    private(set) var capturedKeyCount = 0
    private(set) var modifierEventCount = 0
    private(set) var recoveryCount = 0
    var shouldCapture: ((NSEvent) -> Bool)?
    var onKey: ((NSEvent) -> Void)?
    var onModifiers: ((NSEvent.ModifierFlags) -> Void)?
    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
    }
    func setEnabled(_ value: Bool) {
        if value && tap == nil { prepare() }
        enabled = value && tap != nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: enabled) }
    }
    private func prepare() {
        guard AXIsProcessTrusted() else { error = "面板按键接收需要已授权的辅助功能权限。"; return }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<PanelInputMonitor>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    owner.recoveryCount += 1
                    if owner.enabled, let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                guard owner.enabled, let native = NSEvent(cgEvent: event) else { return Unmanaged.passUnretained(event) }
                if type == .flagsChanged { owner.modifierEventCount += 1; owner.onModifiers?(native.modifierFlags) }
                else if type == .keyDown && owner.shouldCapture?(native) == true {
                    owner.capturedKeyCount += 1
                    owner.onKey?(native)
                    return nil
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { error = "系统暂未允许面板按键接收，请重新检查辅助功能权限。"; return }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap); self.tap = nil; error = "面板按键接收初始化失败。"; return
        }
        self.source = source; CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        error = ""
    }
}
