import AppKit
import ApplicationServices

/// A development check: `Glance --menubar-probe <file>` writes what the menu bar looks like to
/// Accessibility on this Mac (roles, owners, frames and actions of MenuBarAgent's elements), whether the
/// hiding interface is present, and whether an assertion that hides nothing activates. No window titles
/// or screen contents are recorded; only menu bar element names, which are the visible menu bar labels.
extension AppDelegate {
    func runMenuBarProbe() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--menubar-probe"), index + 1 < arguments.count else { return }
        let url = URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath)
        var report: [String: Any] = [
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "accessibility": AXIsProcessTrusted(),
            "hidingAvailable": GLMenuBarHidingAvailable(),
        ]
        DispatchQueue.global(qos: .utility).async {
            report["agent"] = Self.probeAgentTree()
            report["frontmostMenuBar"] = Self.probeFrontmostMenuBar()
            report["menuBarWindows"] = Self.probeMenuBarWindows()
            let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
            DispatchQueue.main.async {
                // An assertion that allows everything should change nothing on screen; it shows whether
                // activation and the completion callback work from here.
                let started = Date()
                var assertion: AnyObject?
                assertion = GLMenuBarHidingActivate((0...8).map { NSNumber(value: $0) }, Array(Set(running)).sorted()) { error in
                    DispatchQueue.main.async {
                        report["activation"] = ["error": error.map { "\($0)" as Any } ?? NSNull(), "seconds": Date().timeIntervalSince(started)] as [String: Any]
                        GLMenuBarHidingInvalidate(assertion); assertion = nil
                        Self.writeProbe(report, to: url)
                    }
                } as AnyObject?
                report["activationRequested"] = assertion != nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    guard report["activation"] == nil else { return }
                    report["activation"] = "no callback within 6 seconds"
                    GLMenuBarHidingInvalidate(assertion); assertion = nil
                    Self.writeProbe(report, to: url)
                }
            }
        }
    }

    private static func writeProbe(_ report: [String: Any], to url: URL) {
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }

    private static func frame(_ element: AXUIElement) -> [Double]? {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return [point.x, point.y, extent.width, extent.height].map { Double($0) }
    }

    private static func describe(_ element: AXUIElement, depth: Int, budget: inout Int) -> [String: Any] {
        budget -= 1
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        var row: [String: Any] = ["pid": Int(pid)]
        if let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier { row["bundle"] = bundle }
        for key in [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute, kAXHelpAttribute] {
            if let value = attribute(element, key) as? String, !value.isEmpty { row[key] = value }
        }
        if let frame = frame(element) { row["frame"] = frame }
        var actions: CFArray?
        if AXUIElementCopyActionNames(element, &actions) == .success, let names = actions as? [String], !names.isEmpty { row["actions"] = names }
        if depth < 6, budget > 0, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement], !children.isEmpty {
            var described: [[String: Any]] = []
            for child in children where budget > 0 { described.append(describe(child, depth: depth + 1, budget: &budget)) }
            row["children"] = described
        }
        return row
    }

    private static func probeAgentTree() -> Any {
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else { return "MenuBarAgent not running" }
        let root = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.5)
        var budget = 400
        return describe(root, depth: 0, budget: &budget)
    }

    private static func probeFrontmostMenuBar() -> Any {
        guard let front = NSWorkspace.shared.frontmostApplication else { return NSNull() }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let bar = attribute(app, kAXMenuBarAttribute) else { return ["app": front.bundleIdentifier ?? "", "menuBar": "none"] }
        let items = (attribute(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        return ["app": front.bundleIdentifier ?? "",
                "items": items.map { ["title": attribute($0, kAXTitleAttribute) as? String ?? "", "frame": frame($0) ?? []] as [String: Any] }]
    }

    private static func probeMenuBarWindows() -> Any {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.compactMap { window -> [String: Any]? in
            guard let layer = window[kCGWindowLayer as String] as? Int, layer >= 20 && layer <= 30 else { return nil }
            return ["owner": window[kCGWindowOwnerName as String] as? String ?? "", "layer": layer,
                    "bounds": window[kCGWindowBounds as String] ?? [:], "pid": window[kCGWindowOwnerPID as String] ?? 0]
        }
    }
}

/// A development check: `Glance --menubar-selftest <file>` hides one menu bar app for a few seconds
/// without saving anything, checks the menu bar after each step (hide, show, hide, always-hidden, show all)
/// and then restores the saved settings, so every icon ends up as it was.
extension AppDelegate {
    func runMenuBarSelfTest() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--menubar-selftest"), index + 1 < arguments.count else { return }
        let url = URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath)
        var report: [String: Any] = ["available": menuBar.available, "accessibility": AXIsProcessTrusted()]
        let saved = settings.value.menuBar
        menuBar.scan()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            let present = menuBar.items.filter { $0.assignable && $0.present && $0.bundle != nil }
            report["found"] = menuBar.items.map { ["id": $0.id, "name": $0.name, "present": $0.present, "assignable": $0.assignable] as [String: Any] }
            report["searchResults"] = menuBar.searchResults().map(\.descriptor.title)
            let preferred = ["bundle:com.apple.weather.menu", "bundle:com.depthpicture.PixPin"]
            guard let target = present.first(where: { preferred.contains($0.id) }) ?? present.first else {
                report["result"] = "no app icon to test with"; Self.writeProbe(report, to: url); return
            }
            report["target"] = target.name
            var steps: [[String: Any]] = []
            var temporary = saved
            temporary.enabled = true; temporary.revealOnHover = false; temporary.rehideSeconds = 0
            temporary.sections = [target.id: .hidden]
            let plan: [(String, Bool, () -> Void)] = [
                ("hide", false, { self.menuBar.configure(temporary) }),
                ("show hidden", true, { self.menuBar.toggle(all: false) }),
                ("hide again", false, { self.menuBar.toggle(all: false) }),
                ("always hidden, show hidden", false, {
                    temporary.sections = [target.id: .alwaysHidden]; self.menuBar.configure(temporary); self.menuBar.toggle(all: false)
                }),
                ("show all", true, { self.menuBar.toggle(all: true) }),
                ("restore saved settings", true, {
                    if self.menuBar.reveal != .none { self.menuBar.toggle(all: self.menuBar.reveal == .all) }
                    self.menuBar.configure(saved)
                }),
            ]
            func run(_ position: Int) {
                guard position < plan.count else {
                    report["steps"] = steps
                    report["passed"] = steps.allSatisfy { $0["ok"] as? Bool == true }
                    report["problem"] = menuBar.problem ?? NSNull()
                    report["hover"] = menuBar.hoverMeasurements
                    Self.writeProbe(report, to: url)
                    return
                }
                let (name, expected, action) = plan[position]
                let started = Date()
                action()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [self] in
                    let id = target.id
                    DispatchQueue.global(qos: .userInitiated).async {
                        let showing = self.menuBar.isShowing(id)
                        DispatchQueue.main.async {
                            steps.append(["step": name, "expectedShowing": expected, "showing": showing, "ok": showing == expected,
                                          "reveal": self.menuBar.reveal.rawValue, "seconds": Date().timeIntervalSince(started)])
                            run(position + 1)
                        }
                    }
                }
            }
            run(0)
        }
    }
}
