import AppKit
import ApplicationServices
import Darwin

// Resolve optional system interfaces at runtime so a missing symbol has a public-API fallback.
enum NativeBridge {
    private static let accessibility = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY)
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as type: T.Type) -> T? {
        guard let handle, let address = dlsym(handle, name) else { return nil }
        return unsafeBitCast(address, to: type)
    }
    static func windowID(_ element: AXUIElement) -> UInt32? {
        typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> Int32
        if let function = symbol(accessibility, "_AXUIElementGetWindow", as: GetWindow.self) {
            var id: UInt32 = 0
            if function(element, &id) == 0 && id != 0 { return id }
        }
        return (axAttribute(element, "AXWindowNumber") as? NSNumber)?.uint32Value
    }
    private static var connection: UInt32? {
        typealias MainConnection = @convention(c) () -> UInt32
        return symbol(skyLight, "CGSMainConnectionID", as: MainConnection.self)?()
    }
    struct Spaces {
        var numbers: [UInt64: Int] = [:]
        var visible = Set<UInt64>()
        var available = false
        func ids(for window: UInt32) -> [UInt64] {
            typealias CopySpaces = @convention(c) (UInt32, Int, CFArray) -> Unmanaged<CFArray>?
            guard available, let connection = NativeBridge.connection,
                  let function = symbol(skyLight, "CGSCopySpacesForWindows", as: CopySpaces.self),
                  let result = function(connection, 7, [NSNumber(value: window)] as CFArray)?.takeRetainedValue() as? [NSNumber] else { return [] }
            return result.map(\.uint64Value)
        }
    }
    static func spaces() -> Spaces {
        typealias CopyDisplays = @convention(c) (UInt32) -> Unmanaged<CFArray>?
        guard let connection, let function = symbol(skyLight, "CGSCopyManagedDisplaySpaces", as: CopyDisplays.self),
              let displays = function(connection)?.takeRetainedValue() as? [[String: Any]] else { return Spaces() }
        var result = Spaces(); result.available = true
        for display in displays {
            if let current = display["Current Space"] as? [String: Any], let id = current["id64"] as? NSNumber { result.visible.insert(id.uint64Value) }
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                if let id = space["id64"] as? NSNumber, result.numbers[id.uint64Value] == nil { result.numbers[id.uint64Value] = result.numbers.count + 1 }
            }
        }
        return result
    }
    /// Fronts one specific window through the window server, then makes it key, the way AltTab, yabai and
    /// Hammerspoon do. Since macOS 14, NSRunningApplication.activate is only a request, which is why
    /// cross-Space and same-app switches could land on the wrong window. Returns false when the private
    /// interface is unavailable or refuses, so the caller can fall back to the public path.
    static func frontWindow(pid: Int32, windowID: UInt32) -> Bool {
        typealias SetFront = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
        typealias PostRecord = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32
        // GetProcessForPID is deprecated and not reliably visible to Swift, so it is resolved like the others.
        typealias ProcessForPID = @convention(c) (Int32, UnsafeMutablePointer<ProcessSerialNumber>) -> Int32
        guard let setFront = symbol(skyLight, "_SLPSSetFrontProcessWithOptions", as: SetFront.self),
              let post = symbol(skyLight, "SLPSPostEventRecordTo", as: PostRecord.self),
              let processForPID = symbol(accessibility, "GetProcessForPID", as: ProcessForPID.self)
                ?? symbol(dlopen(nil, RTLD_LAZY), "GetProcessForPID", as: ProcessForPID.self) else { return false }
        var psn = ProcessSerialNumber()
        guard processForPID(pid, &psn) == 0 else { return false }
        // 0x200: user generated, so the switch is not suppressed; passing the window raises only that window.
        guard setFront(&psn, windowID, 0x200) == 0 else { return false }
        // A synthetic left-mouse-down addressed to the window id (not to a point) makes it key.
        // The point is far outside any window so no content or resize edge is hit; no mouse-up is sent.
        var record = [UInt8](repeating: 0, count: 0x100)
        record[0x04] = 0xf8
        record[0x08] = 0x01
        record[0x3a] = 0x10
        withUnsafeBytes(of: windowID) { raw in for (offset, byte) in raw.enumerated() { record[0x3c + offset] = byte } }
        withUnsafeBytes(of: CGPoint(x: 300_000, y: 300_000)) { raw in for (offset, byte) in raw.enumerated() { record[0x20 + offset] = byte } }
        _ = record.withUnsafeMutableBufferPointer { buffer in post(&psn, buffer.baseAddress!) }
        return true
    }
    /// Turns the system ⌘Tab / ⌘⇧Tab switcher off or on. The state outlives this process, so it must be
    /// restored when 一瞥 quits or stops using ⌘Tab.
    static func setSystemAppSwitcher(enabled: Bool) {
        typealias SetEnabled = @convention(c) (UInt32, Bool) -> Int32
        guard let function = symbol(skyLight, "CGSSetSymbolicHotKeyEnabled", as: SetEnabled.self) else { return }
        _ = function(1, enabled)
        _ = function(2, enabled)
    }
    static func menuBarDisplay() -> String? {
        typealias CopyDisplay = @convention(c) (UInt32) -> Unmanaged<CFString>?
        guard let connection, let function = symbol(skyLight, "CGSCopyActiveMenuBarDisplayIdentifier", as: CopyDisplay.self) else { return nil }
        return function(connection)?.takeRetainedValue() as String?
    }
    static func tabs(in window: AXUIElement) -> [AXUIElement] {
        let deadline = Date().addingTimeInterval(0.08)
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty && visited < 80 && Date() < deadline {
            let (element, depth) = queue.removeFirst(); visited += 1
            let role = axAttribute(element, kAXRoleAttribute) as? String ?? ""
            let children = axAttribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            if role == "AXTabGroup" {
                let tabs = children.filter { (axAttribute($0, kAXRoleAttribute) as? String) == "AXRadioButton" }
                if tabs.count > 1 { return tabs }
            }
            if depth < 2 { queue.append(contentsOf: children.prefix(32).map { ($0, depth + 1) }) }
        }
        return []
    }
}
