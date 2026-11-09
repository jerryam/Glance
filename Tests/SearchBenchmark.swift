import Foundation

@main
struct SearchBenchmark {
    static func main() throws {
        var settings = UserSettings.defaults
        settings.advanced.exceptions = []
        let profile = settings.shortcuts[0]
        var results: [[String: Any]] = []
        for count in [30, 60, 180, 600] {
            let windows = (0..<count).map { i -> WindowDescriptor in
                var d = WindowDescriptor(id: "test:\(count):\(i)", windowID: UInt32(i), pid: Int32(i % 12 + 1),
                    appName: ["Safari", "微信", "访达", "Editor"][i % 4], bundleID: "test.app.\(i % 12)",
                    title: ["项目资料与收件箱", "Safari documentation", "代码与测试笔记", "设计参考与工作资料"][i % 4] + " \(count) \(i)",
                    minimized: i % 8 == 0, hidden: false, onCurrentSpace: true, displayID: 1, aspectRatio: 1.6)
                d.lastFocused = Double(i); return d
            }
            func run(_ query: String) -> Double {
                let start = ProcessInfo.processInfo.systemUptime
                _ = WindowSearch.filtered(windows, settings: settings, profile: profile, frontPID: nil, displayID: 1, query: query)
                return (ProcessInfo.processInfo.systemUptime - start) * 1000
            }
            let cold = run("shoujianxiang")
            var warm = LatencySeries(limit: 120)
            for _ in 0..<10 { _ = run("safrai") }
            for i in 0..<60 { warm.record(milliseconds: run(["safari", "shoujianxiang", "sjx", "safrai", "微信", "missing"][i % 6])) }
            results.append(["windows": count, "cold_pinyin_ms": cold, "warm_filter": warm.summary])
        }
        let payload: [String: Any] = ["measurement": "Synthetic Foundation filtering only; excludes enumeration, rendering and keypress latency", "results": results]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
