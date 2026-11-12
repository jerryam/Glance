import Foundation

/// Times `WindowSearch.filtered` on made-up lists: `scripts/search-benchmark.sh` builds and runs it. With a path as
/// its argument it also writes the numbers there as JSON. It measures the filtering alone, not reading windows,
/// drawing or the keyboard, and it judges nothing: the numbers are for reading.
@main
struct SearchBenchmark {
    static let names = ["微信", "企业微信", "网易云音乐", "文件管理器", "系统设置", "访达", "备忘录", "日历", "Google Chrome", "Visual Studio Code",
                        "Safari浏览器", "终端", "活动监视器", "重庆银行", "QQ音乐", "腾讯会议", "钉钉", "飞书", "Xcode", "Microsoft Excel",
                        "Final Cut Pro", "蓝牙", "显示器", "网络", "声音", "键盘", "触控板", "隐私与安全性", "通用", "桌面与程序坞"]
    /// A name, full pinyin, initials, mixed typing, skipped letters, a typo, and one that matches nothing, which
    /// has to try every way of matching on every entry.
    static let queries = ["safari", "weixin", "wx", "微xin", "wxin", "chrm", "safrai", "wenjian", "xtsz", "重qing", "zzqqzz"]

    static func windows(_ count: Int, tag: String) -> [WindowDescriptor] {
        (0..<count).map { i -> WindowDescriptor in
            var d = WindowDescriptor(id: "window:\(tag):\(i)", windowID: UInt32(i), pid: Int32(i % 12 + 1),
                appName: ["Safari", "微信", "访达", "Editor"][i % 4], bundleID: "test.app.\(i % 12)",
                title: ["项目资料与收件箱", "Safari documentation", "代码与测试笔记", "设计参考与工作资料"][i % 4] + " \(tag) \(i)",
                minimized: i % 8 == 0, hidden: false, onCurrentSpace: true, displayID: 1, aspectRatio: 1.6)
            d.lastFocused = Double(i)
            return d
        }
    }
    /// Apps that are not running and settings pages, each with a name of its own, as the search index sees them.
    static func launchers(_ count: Int, tag: String) -> [WindowDescriptor] {
        (0..<count).map { i -> WindowDescriptor in
            let name = names[i % names.count] + " \(tag) \(i)"
            var d = WindowDescriptor(id: "launch:\(tag):\(i)", windowID: nil, pid: 0, appName: name, bundleID: "bench.\(tag).\(i)", title: name,
                                     minimized: false, hidden: false, onCurrentSpace: true, displayID: nil, aspectRatio: 1.6)
            d.launcher = i % 3 == 0 ? .setting : .app
            return d
        }
    }

    static func measure(_ label: String, _ items: [WindowDescriptor], settings: UserSettings) -> [String: Any] {
        let profile = settings.shortcuts[0]
        func run(_ query: String) -> Double {
            let start = ProcessInfo.processInfo.systemUptime
            _ = WindowSearch.filtered(items, settings: settings, profile: profile, frontPID: nil, displayID: 1, query: query)
            return (ProcessInfo.processInfo.systemUptime - start) * 1000
        }
        // The first search builds the index of every entry.
        let cold = run(queries[0])
        for query in queries { _ = run(query) }
        var warm = LatencySeries(limit: 600)
        var slowestQuery = "", slowestTime = 0.0
        for _ in 0..<20 {
            for query in queries {
                let time = run(query)
                warm.record(milliseconds: time)
                if time > slowestTime { slowestTime = time; slowestQuery = query }
            }
        }
        let summary = warm.summary
        func text(_ value: Double?) -> String { String(format: "%8.3f", value ?? -1) }
        let padded = label.padding(toLength: 44, withPad: " ", startingAt: 0)
        let p50 = text(summary["p50_ms"]), p95 = text(summary["p95_ms"]), longest = text(summary["maximum_ms"])
        print("\(padded) cold \(text(cold))  p50 \(p50)  p95 \(p95)  max \(longest)  slowest: \(slowestQuery)")
        return ["case": label, "entries": items.count, "cold_ms": cold, "warm": summary, "slowest_query": slowestQuery, "slowest_ms": slowestTime]
    }

    static func main() throws {
        var settings = UserSettings.defaults
        settings.advanced.exceptions = []
        var shuangpin = settings
        shuangpin.advanced.shuangpin = .xiaohe
        print("Search benchmark, milliseconds for one search. \(queries.count) queries, 20 rounds each.")
        var results: [[String: Any]] = []
        for count in [30, 60, 180, 600] {
            results.append(measure("\(count) windows", windows(count, tag: "w\(count)"), settings: settings))
        }
        results.append(measure("40 windows + 400 apps and settings", windows(40, tag: "a") + launchers(400, tag: "a"), settings: settings))
        // More than 800 entries: what the index cache could hold until it was changed to keep 1500 to 3000.
        results.append(measure("40 windows + 1200 apps and settings", windows(40, tag: "b") + launchers(1200, tag: "b"), settings: settings))
        results.append(measure("40 windows + 400, double pinyin on", windows(40, tag: "c") + launchers(400, tag: "c"), settings: shuangpin))
        let payload: [String: Any] = ["measurement": "Synthetic filtering only; excludes enumeration, rendering and keypress latency", "queries": queries, "results": results]
        if CommandLine.arguments.count > 1 {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
    }
}
