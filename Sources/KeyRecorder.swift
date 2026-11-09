import AppKit
import SwiftUI
import Carbon

enum KeyboardKeyName {
    static func label(for code: UInt32) -> String {
        // Standard Mac key symbols for the keys people bind most.
        if code == 48 { return "⇥" }
        if code == 36 { return "↩" }
        let fallback = KeyChoice.label(for: code)
        guard code < 51 && ![36, 48, 49].contains(code),
              let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return fallback }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return fallback }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var state: UInt32 = 0, length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit), &state, characters.count, &length, &characters)
        guard status == noErr, length > 0 else { return fallback }
        return String(decoding: characters.prefix(length), as: UTF16.self).uppercased()
    }
}

extension ShortcutProfile {
    var displayShortcut: String { modifiers.symbols + KeyboardKeyName.label(for: keyCode) }
}

extension ShortcutModifiers {
    init(eventFlags: NSEvent.ModifierFlags) {
        self = []
        if eventFlags.contains(.option) { insert(.option) }
        if eventFlags.contains(.control) { insert(.control) }
        if eventFlags.contains(.command) { insert(.command) }
        if eventFlags.contains(.shift) { insert(.shift) }
    }
}
final class RecordingButton: NSButton {
    var receive: ((UInt32, ShortcutModifiers) -> Void)?
    var recordingChanged: ((Bool) -> Void)?
    var recording = false
    var normalTitle = ""
    var allowsModifierOnly = false
    private var pendingModifiers: ShortcutModifiers = []
    override var acceptsFirstResponder: Bool { true }
    func cancelRecording() {
        guard recording else { return }
        recording = false; title = normalTitle; recordingChanged?(false)
        pendingModifiers = []
    }
    @objc func begin() {
        if recording { cancelRecording(); return }
        pendingModifiers = []; recording = true; title = "请按快捷键…"; recordingChanged?(true); window?.makeFirstResponder(self)
    }
    private func finish(_ event: NSEvent) {
        if event.keyCode != 53 { receive?(UInt32(event.keyCode), ShortcutModifiers(eventFlags: event.modifierFlags)) }
        recording = false; title = normalTitle; recordingChanged?(false)
    }
    override func keyDown(with event: NSEvent) { if recording { finish(event) } else { super.keyDown(with: event) } }
    override func flagsChanged(with event: NSEvent) {
        guard recording, allowsModifierOnly else { super.flagsChanged(with: event); return }
        let flags = ShortcutModifiers(eventFlags: event.modifierFlags)
        if !flags.isEmpty { pendingModifiers.formUnion(flags); title = pendingModifiers.symbols + "…" }
        else if !pendingModifiers.isEmpty {
            receive?(KeyChoice.modifierOnly, pendingModifiers)
            cancelRecording()
        }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        finish(event); return true
    }
    override func resignFirstResponder() -> Bool {
        cancelRecording()
        return super.resignFirstResponder()
    }
}
struct KeyRecorder: NSViewRepresentable {
    @Binding var code: UInt32
    @Binding var modifiers: ShortcutModifiers
    var recordingChanged: (Bool) -> Void = { _ in }
    var allowsModifierOnly = true
    static func dismantleNSView(_ view: RecordingButton, coordinator: Void) { view.cancelRecording() }
    func makeNSView(context: Context) -> RecordingButton {
        let view = RecordingButton(); view.bezelStyle = .rounded
        view.target = view; view.action = #selector(RecordingButton.begin)
        view.setAccessibilityLabel("录制快捷键")
        updateNSView(view, context: context); return view
    }
    func updateNSView(_ view: RecordingButton, context: Context) {
        view.normalTitle = modifiers.symbols + KeyboardKeyName.label(for: code)
        if !view.recording { view.title = view.normalTitle }
        view.receive = { code = $0; modifiers = $1 }
        view.recordingChanged = recordingChanged
        view.allowsModifierOnly = allowsModifierOnly
    }
}
