import AppKit
import ApplicationServices

final class GestureMonitor {
    private var detector: CFMachPort?
    private var absorber: CFMachPort?
    private var sources: [CFRunLoopSource] = []
    private var tracker = GestureTracker()
    private var choice: GestureChoice = .disabled
    private var avoidsSystem = true
    private var claimed = false
    private var absorbThisEvent = false
    private var identities: Set<String> = []
    var onGesture: ((GestureResult) -> Bool)?
    private(set) var error = ""
    deinit { stop() }
    private func stop() {
        for source in sources { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        for tap in [detector, absorber].compactMap({ $0 }) { CFMachPortInvalidate(tap) }
        sources = []; detector = nil; absorber = nil; identities = []; claimed = false; absorbThisEvent = false
    }
    func configure(_ choice: GestureChoice, avoidsSystem: Bool) {
        guard choice != self.choice || avoidsSystem != self.avoidsSystem || (choice != .disabled && detector == nil) else { return }
        stop(); self.choice = choice; self.avoidsSystem = avoidsSystem; tracker = GestureTracker(choice: choice); error = ""
        guard choice != .disabled else { return }
        guard AXIsProcessTrusted() else { error = "手势需要先开启辅助功能权限。"; return }
        let mask = CGEventMask(1) << NSEvent.EventType.gesture.rawValue
        // Only the chosen, accepted swipe is absorbed. Detect passively so pointer movement remains free.
        if avoidsSystem {
            absorber = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask, callback: { _, type, event, context in
                    guard let context else { return Unmanaged.passUnretained(event) }
                    let owner = Unmanaged<GestureMonitor>.fromOpaque(context).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        if owner.claimed, let tap = owner.absorber { CGEvent.tapEnable(tap: tap, enable: true) }
                        return Unmanaged.passUnretained(event)
                    }
                    let swallow = owner.absorbThisEvent
                    if !owner.claimed, let tap = owner.absorber { CGEvent.tapEnable(tap: tap, enable: false) }
                    return swallow ? nil : Unmanaged.passUnretained(event)
                }, userInfo: Unmanaged.passUnretained(self).toOpaque())
            guard absorber != nil else { error = "系统未允许手势避让，请检查辅助功能权限。"; stop(); return }
        }
        // Created after the absorbing tap, so the passive verdict is ready for the same event.
        detector = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<GestureMonitor>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = owner.detector { CGEvent.tapEnable(tap: tap, enable: true) }
                } else if let native = NSEvent(cgEvent: event) { owner.receive(native) }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard detector != nil else { error = "系统未允许读取触控板手势，请检查辅助功能权限。"; stop(); return }
        for tap in [absorber, detector].compactMap({ $0 }) {
            if let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) {
                sources.append(source); CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        if let absorber { CGEvent.tapEnable(tap: absorber, enable: false) }
        if let detector { CGEvent.tapEnable(tap: detector, enable: true) }
    }
    private func receive(_ event: NSEvent) {
        let touches = event.allTouches().filter { $0.type == .indirect && $0.phase.intersection(.touching) != [] }
        let ids = Set(touches.map { String(describing: $0.identity) })
        let wasClaimed = claimed
        if ids != identities && touches.count == choice.fingers && !tracker.isActive {
            tracker.rebase()
        }
        identities = ids
        let count = touches.count
        let x = touches.reduce(0.0) { $0 + $1.normalizedPosition.x } / Double(max(1, count))
        let y = touches.reduce(0.0) { $0 + $1.normalizedPosition.y } / Double(max(1, count))
        if let result = tracker.update(fingers: count, x: x, y: y) {
            switch result {
            case .start: claimed = onGesture?(result) ?? false
            case .move: if claimed { _ = onGesture?(result) }
            case .end: if claimed { _ = onGesture?(result) }; claimed = false
            }
        }
        absorbThisEvent = avoidsSystem && (claimed || wasClaimed)
        if absorbThisEvent, let absorber { CGEvent.tapEnable(tap: absorber, enable: true) }
    }
}
