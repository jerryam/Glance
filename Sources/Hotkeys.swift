import AppKit
import Carbon

private func carbonModifiers(_ flags: ShortcutModifiers) -> UInt32 {
    var result: UInt32 = 0
    if flags.contains(.option) { result |= UInt32(optionKey) }
    if flags.contains(.control) { result |= UInt32(controlKey) }
    if flags.contains(.command) { result |= UInt32(cmdKey) }
    if flags.contains(.shift) { result |= UInt32(shiftKey) }
    return result
}

extension ShortcutModifiers {
    var eventFlags: NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if contains(.option) { result.insert(.option) }
        if contains(.control) { result.insert(.control) }
        if contains(.command) { result.insert(.command) }
        if contains(.shift) { result.insert(.shift) }
        return result
    }
}

final class HotkeyRegistry {
    private var registered: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var handlerStatus: OSStatus = noErr
    var onTrigger: ((Int, Bool) -> Void)?
    var onRelease: (() -> Void)?
    /// Shortcuts outside the switching schemes (the menu bar commands), by slot.
    var onExtra: ((Int) -> Void)?
    private(set) var errors: [String] = []
    private var profiles: [ShortcutProfile] = []
    private var extras: [(slot: Int, hotkey: MenuBarHotkey)] = []
    private var suspended = false
    var isSuspended: Bool { suspended }
    init() {
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let context = Unmanaged.passUnretained(self).toOpaque()
        handlerStatus = InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            guard id.signature == 0x57484F50 else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<HotkeyRegistry>.fromOpaque(userData).takeUnretainedValue()
            if id.id >= 201 {
                if GetEventKind(event) == UInt32(kEventHotKeyPressed) { owner.onExtra?(Int(id.id) - 201) }
                return noErr
            }
            if GetEventKind(event) == UInt32(kEventHotKeyReleased) { owner.onRelease?(); return noErr }
            let reverse = id.id >= 101
            let index = Int(id.id) - (reverse ? 101 : 1)
            owner.onTrigger?(index, reverse)
            return noErr
        }, specs.count, &specs, context, &handler)
    }
    deinit { clear(); if let handler { RemoveEventHandler(handler) } }
    private func clear() { registered.forEach { UnregisterEventHotKey($0) }; registered.removeAll() }
    func configure(_ profiles: [ShortcutProfile], extras: [(slot: Int, hotkey: MenuBarHotkey)] = []) {
        self.profiles = profiles
        self.extras = extras
        rebuild()
    }
    func setSuspended(_ value: Bool) {
        guard suspended != value else { return }
        suspended = value; rebuild()
    }
    /// The switching shortcuts the system is delivering right now.
    var activeTriggers: [ShortcutProfile] { suspended ? [] : profiles }
    @discardableResult func handleModifiers(previous: ShortcutModifiers, current: ShortcutModifiers) -> Bool {
        guard !suspended, previous != current, !current.subtracting(previous).isEmpty else { return false }
        for profile in profiles where profile.enabled && profile.keyCode == KeyChoice.modifierOnly {
            if current == profile.modifiers { onTrigger?(profile.id, false); return true }
            if !profile.modifiers.contains(.shift) && current == profile.modifiers.union(.shift) {
                onTrigger?(profile.id, true); return true
            }
        }
        return false
    }
    private func rebuild() {
        clear(); errors.removeAll()
        guard !suspended else { return }
        guard handlerStatus == noErr else {
            errors.append("无法连接系统快捷键服务（\(handlerStatus)）。请重新启动一瞥。")
            return
        }
        for profile in profiles where profile.enabled {
            register(profile, reverse: false)
            if !profile.modifiers.contains(.shift) { register(profile, reverse: true) }
        }
        for extra in extras where extra.hotkey.enabled && extra.hotkey.isValid {
            let identifier = EventHotKeyID(signature: 0x57484F50, id: UInt32(201 + extra.slot))
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(extra.hotkey.keyCode, carbonModifiers(extra.hotkey.modifiers), identifier, GetEventDispatcherTarget(), 0, &reference)
            if result == noErr, let reference { registered.append(reference) }
            else { errors.append("\(extra.slot >= WindowLayoutCommand.firstSlot ? "窗口" : "菜单栏")快捷键 \(extra.hotkey.label) 被系统或其他应用占用（\(result)）。") }
        }
    }
    private func register(_ profile: ShortcutProfile, reverse: Bool) {
        guard profile.keyCode != KeyChoice.modifierOnly else { return }
        let modifiers = reverse ? profile.modifiers.union(.shift) : profile.modifiers
        let identifier = EventHotKeyID(signature: 0x57484F50, id: UInt32(profile.id + (reverse ? 101 : 1)))
        var reference: EventHotKeyRef?
        let result = RegisterEventHotKey(profile.keyCode, carbonModifiers(modifiers), identifier, GetEventDispatcherTarget(), 0, &reference)
        if result == noErr, let reference { registered.append(reference) }
        else { errors.append("\(modifiers.symbols)\(KeyChoice.label(for: profile.keyCode)) 被系统或其他应用占用（\(result)）。") }
    }
}
