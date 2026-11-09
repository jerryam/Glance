import Foundation
import AppKit
import Darwin

final class WindowCommandServer {
    private var port: CFMessagePort?
    private var source: CFRunLoopSource?
    private let engine: WindowEngine
    private var revision = 0
    private var ready = 0
    var beforeFocus: (() -> Void)?
    var onReopen: (() -> Void)?
    var diagnostics: (() -> [String: Any])?
    /// 设置 › 通用 › 命令行. Listing, focusing and diagnostics answer only when this returns true;
    /// single-instance hand-off (reopen / restart) always works.
    var commandsEnabled: () -> Bool = { false }
    static var name: String { "com.jethro.windowhop.commands.\(getuid())" }
    init(engine: WindowEngine) {
        self.engine = engine
        var context = CFMessagePortContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        port = CFMessagePortCreateLocal(nil, Self.name as CFString, { _, message, data, info in
            guard let info else { return nil }
            let owner = Unmanaged<WindowCommandServer>.fromOpaque(info).takeUnretainedValue()
            let result = owner.receive(message, data: data as Data? ?? Data())
            return Unmanaged.passRetained(result as CFData)
        }, &context, nil)
        if let port { source = CFMessagePortCreateRunLoopSource(nil, port, 0) }
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
    }
    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CFMessagePortInvalidate(port) }
    }
    private func json(_ object: Any) -> Data { (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8) }
    private func receive(_ message: Int32, data: Data) -> Data {
        if [0, 1, 2, 5].contains(message) && !commandsEnabled() {
            return json(["error": "命令行接口未开启。请在一瞥的 设置 › 通用 中打开“允许命令行列出和切换窗口”。"])
        }
        if message == 0 {
            revision += 1; let requested = revision
            engine.refresh(frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier) { [weak self] _ in self?.ready = requested }
            return Data(String(requested).utf8)
        }
        if message == 1 {
            guard let expected = Int(String(data: data, encoding: .utf8) ?? ""), ready >= expected else { return Data("pending".utf8) }
            let windows: [[String: Any]] = engine.windows.map { handle in
                let d = handle.descriptor
                return ["id": d.id, "windowID": d.windowID.map { Int($0) } as Any? ?? NSNull(), "pid": d.pid,
                        "app": d.appName, "bundleID": d.bundleID, "title": d.title, "minimized": d.minimized,
                        "hidden": d.hidden, "fullscreen": d.fullscreen, "windowless": d.windowless,
                        "spaceNumbers": d.spaceNumbers, "spaceKnown": d.spaceKnown, "tab": !d.tabRepresentative, "controllable": d.controllable]
            }
            return json(windows)
        }
        if message == 2, let id = String(data: data, encoding: .utf8), let handle = engine.windows.first(where: { $0.id == id }) {
            if let error = WindowControl.perform(.focus, on: handle) { return json(["error": error]) }
            beforeFocus?()
            engine.markFocused(handle); return json(["focused": id])
        }
        if message == 3 { DispatchQueue.main.async { [weak self] in self?.onReopen?() }; return json(["running": true]) }
        if message == 4 { DispatchQueue.main.async { NSApp.terminate(nil) }; return json(["restarting": true]) }
        if message == 5 { return json(diagnostics?() ?? [:]) }
        return json(["error": "未找到窗口，请重新列出窗口编号。"])
    }
    private static func send(_ remote: CFMessagePort, _ id: Int32, _ body: Data = Data()) -> Data? {
        var result: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(remote, id, body as CFData, 2, 3, CFRunLoopMode.defaultMode.rawValue, &result)
        return status == kCFMessagePortSuccess ? result?.takeRetainedValue() as Data? : nil
    }
    static func handOffToExistingInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
        guard !others.isEmpty else { return false }
        func exited() -> Bool {
            others.allSatisfy { kill($0.processIdentifier, 0) != 0 && errno == ESRCH }
        }
        // An older copy at another path (such as WindowHop.app from before the rename) shares the bundle
        // identifier. Ask it to quit and take over, instead of handing this launch to the old version.
        let ownPath = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        let olderCopy = others.contains { $0.bundleURL.map { $0.resolvingSymlinksInPath().standardizedFileURL.path != ownPath } ?? false }
        let restarting = CommandLine.arguments.contains("--restart") || olderCopy
        for _ in 0..<30 {
            if let remote = CFMessagePortCreateRemote(nil, name as CFString),
               let response = send(remote, restarting ? 4 : 3),
               let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
               object[restarting ? "restarting" : "running"] as? Bool == true {
                if !restarting { return true }
                for _ in 0..<60 {
                    if exited() { return false }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                fputs("原实例未退出，请在一瞥中确认未保存的设置。\n", stderr); return true
            }
            if exited() { return false }
            Thread.sleep(forTimeInterval: 0.05)
        }
        fputs("一瞥已经运行，但暂时无法连接；请稍后重试。\n", stderr); return true
    }
    static func runClientIfRequested() -> Bool {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.contains("--list") || args.contains("--detailed-list") || args.contains("--focus") || args.contains("--diagnostics") || args.contains("--help") else { return false }
        if args.contains("--help") {
            print("一瞥命令行：\n  --list / --detailed-list  输出窗口 JSON\n  --focus <id>              切换到指定窗口\n  --diagnostics             读取本次运行的耗时、缓存和权限状态\n请先启动 Glance.app 并开启辅助功能权限。"); return true
        }
        if let index = args.firstIndex(of: "--focus"), index + 1 >= args.count || args[index + 1].hasPrefix("--") {
            fputs("请填写 --list 中的 id。\n", stderr); exit(1)
        }
        guard let remote = CFMessagePortCreateRemote(nil, name as CFString) else { fputs("请先启动一瞥。\n", stderr); exit(1) }
        func failIfRefused(_ response: Data) {
            if let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any], let error = object["error"] as? String {
                fputs(error + "\n", stderr); exit(1)
            }
        }
        if args.contains("--diagnostics") {
            guard let result = send(remote, 5) else { fputs("一瞥暂时没有响应。\n", stderr); exit(1) }
            failIfRefused(result)
            print(String(data: result, encoding: .utf8) ?? "{}"); return true
        }
        guard let ticket = send(remote, 0) else { fputs("一瞥暂时没有响应。\n", stderr); exit(1) }
        failIfRefused(ticket)
        var list: Data?
        for _ in 0..<50 {
            if let response = send(remote, 1, ticket), response != Data("pending".utf8) { list = response; break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let list else { fputs("读取窗口超时，请稍后重试。\n", stderr); exit(1) }
        if let index = args.firstIndex(of: "--focus") {
            guard index + 1 < args.count else { fputs("请填写 --list 中的 id。\n", stderr); exit(1) }
            guard let result = send(remote, 2, Data(args[index + 1].utf8)) else { exit(1) }
            print(String(data: result, encoding: .utf8) ?? "{}")
            if let object = try? JSONSerialization.jsonObject(with: result) as? [String: Any], object["error"] != nil { exit(1) }
            return true
        }
        print(String(data: list, encoding: .utf8) ?? "[]"); return true
    }
}
