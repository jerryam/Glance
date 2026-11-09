import Foundation
import ApplicationServices
import JavaScriptCore

@main
struct CoreTests {
    static var passed = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
        passed += 1; print("PASS: \(message)")
    }
    static func main() {
        let inbox = WindowDescriptor(id: "inbox", windowID: 1, pid: 10, appName: "邮件", bundleID: "com.apple.mail", title: "收件箱", minimized: false, hidden: false, onCurrentSpace: true, displayID: 1, aspectRatio: 1.6)
        let project = WindowDescriptor(id: "project", windowID: 2, pid: 20, appName: "Safari", bundleID: "com.apple.safari", title: "Café — Project Notes", minimized: false, hidden: false, onCurrentSpace: true, displayID: 1, aspectRatio: 1.5)
        let minimized = WindowDescriptor(id: "mini", windowID: 3, pid: 20, appName: "Safari", bundleID: "com.apple.safari", title: "Reference", minimized: true, hidden: false, onCurrentSpace: false, displayID: 2, aspectRatio: 1.5)
        let hidden = WindowDescriptor(id: "hidden", windowID: 4, pid: 30, appName: "音乐", bundleID: "com.apple.Music", title: "播放列表", minimized: false, hidden: true, onCurrentSpace: false, displayID: 1, aspectRatio: 1.3)
        let windows = [inbox, project, minimized, hidden]
        check(WindowSearch.matches(inbox, query: "收件"), "中文标题搜索")
        check(WindowSearch.matches(inbox, query: "shoujianxiang"), "中文拼音搜索")
        check(WindowSearch.matches(project, query: "SAFARI cafe notes"), "多关键词、大小写和重音搜索")
        check(WindowSearch.matches(project, query: "com.apple.safari"), "应用标识搜索")
        check(!WindowSearch.matches(project, query: "safari missing"), "搜索必须匹配每一个关键词")
        check(WindowSearch.matches(project, query: "  \n"), "空白搜索显示全部")
        var settings = UserSettings.defaults
        var profile = settings.shortcuts[0]
        func filter(_ query: String = "") -> [WindowDescriptor] {
            WindowSearch.filtered(windows, settings: settings, profile: profile, frontPID: 20, displayID: 1, query: query)
        }
        check(filter().map(\.id) == windows.map(\.id), "默认包含最小化和隐藏窗口，并保持顺序")
        profile.scope = .currentApp
        check(filter().map(\.id) == ["project", "mini"], "只切换当前应用")
        profile.scope = .otherApps
        check(filter().map(\.id) == ["inbox", "hidden"], "排除当前应用")
        profile.scope = .all; profile.currentScreenOnly = true
        check(!filter().contains(minimized), "当前屏幕筛选")
        profile.currentScreenOnly = false; profile.currentSpaceOnly = true
        check(filter().map(\.id) == ["inbox", "project"], "当前可见桌面筛选")
        profile.currentSpaceOnly = false; settings.showMinimized = false; settings.showHidden = false
        check(filter().map(\.id) == ["inbox", "project"], "隐藏和最小化偏好")
        settings = .defaults; settings.exclusions = "com.apple.music\nreference"
        check(filter().map(\.id) == ["inbox", "project"], "按应用和标题排除")
        settings = .defaults
        check(settings.validationError() == nil && settings.shortcuts.count == 9, "九组默认快捷键配置有效")
        settings.shortcuts[3] = ShortcutProfile(id: 3, enabled: true, keyCode: 48, modifiers: .option, scope: .all, currentSpaceOnly: false, currentScreenOnly: false, keepOpen: false)
        check(settings.validationError() != nil, "阻止重复快捷键")
        settings.shortcuts[3].modifiers = [.option, .shift]
        check(settings.validationError() != nil, "阻止快捷键与 Shift 反向组合冲突")
        settings = .defaults; settings.shortcuts[0].modifiers = []
        check(settings.validationError() != nil, "阻止占用无修饰键的普通输入")
        let encoded = try! JSONEncoder().encode(UserSettings.defaults)
        check(try! JSONDecoder().decode(UserSettings.self, from: encoded) == .defaults, "配置保存与恢复")
        let legacy = Data("{\"style\":\"icons\",\"thumbnailWidth\":250,\"showMinimized\":false}".utf8)
        let migrated = try! JSONDecoder().decode(UserSettings.self, from: legacy)
        check(migrated.style == .icons && migrated.thumbnailWidth == 250 && !migrated.showMinimized && migrated.advanced.showDelay == 100, "旧设置升级保留外观和筛选")
        check(try! JSONDecoder().decode(AdvancedSettings.self, from: Data("{}".utf8)).bindings.count == PanelCommand.allCases.count, "新增设置字段缺失时采用默认值")
        settings = .defaults; profile = settings.shortcuts[0]
        profile.minimized = .atEnd; profile.hidden = .atEnd
        check(filter().suffix(2).map(\.id) == ["mini", "hidden"], "最小化和隐藏窗口放末尾")
        settings.showMinimized = false; profile.minimized = .show
        check(filter().contains(minimized), "每组的显示策略覆盖全局开关")
        profile.minimized = .hide
        check(!filter().contains(minimized), "每组独立隐藏最小化窗口")
        settings = .defaults; profile = settings.shortcuts[0]; profile.spaces = .other
        check(filter().map(\.id) == ["mini", "hidden"], "只显示其他桌面的窗口")
        profile.spaces = .all; profile.grouping = .onePerApp
        check(filter().map(\.id) == ["inbox", "project", "hidden"], "按应用分组保留优先窗口")
        check(filter("reference").map(\.id) == ["mini"], "应用分组不丢失匹配搜索的其他窗口")
        var a = inbox, b = project, c = minimized
        a.lastFocused = 10; b.lastFocused = 30; c.lastFocused = 20
        a.created = 30; b.created = 10; c.created = 20
        a.spaceNumbers = [3]; b.spaceNumbers = [2]; c.spaceNumbers = [1]
        let ordered = [a, b, c]; profile = settings.shortcuts[0]
        func order() -> [String] { WindowSearch.filtered(ordered, settings: settings, profile: profile, frontPID: 20, displayID: 1, query: "").map(\.id) }
        check(order() == ["project", "mini", "inbox"], "按最近聚焦排序")
        profile.order = .created; check(order() == ["inbox", "mini", "project"], "按首次发现时间排序")
        profile.order = .space; check(order() == ["mini", "project", "inbox"], "按桌面编号排序")
        profile.order = .alphabetical
        let nameOrder = WindowSearch.filtered([minimized, project], settings: settings, profile: profile, frontPID: 20, displayID: 1, query: "").map(\.id)
        check(nameOrder == ["project", "mini"], "同一应用按窗口名称排序")
        a.frame = WindowRect(x: 0, y: 0, width: 300, height: 300); b.frame = a.frame; a.zOrder = 5; b.zOrder = 1
        profile.scope = .underCursor
        check(WindowSearch.filtered([a,b], settings: settings, profile: profile, frontPID: 10, displayID: 1, query: "", cursorX: 80, cursorY: 80).map(\.id) == ["project"], "鼠标下的范围选择最上层窗口")
        profile.scope = .appUnderCursor
        check(WindowSearch.filtered([a,b,c], settings: settings, profile: profile, frontPID: 10, displayID: 1, query: "", cursorX: 80, cursorY: 80).map(\.id) == ["project", "mini"], "鼠标下的应用包括该应用其他窗口")
        profile = settings.shortcuts[0]; b.fullscreen = true; profile.fullscreen = .hide
        check(WindowSearch.filtered([a,b], settings: settings, profile: profile, frontPID: 10, displayID: 1, query: "").map(\.id) == ["inbox"], "独立隐藏全屏窗口")
        b.tabGroup = "tabs"; b.tabRepresentative = false; profile.fullscreen = .show
        check(WindowSearch.filtered([a,b], settings: settings, profile: profile, frontPID: 10, displayID: 1, query: "").count == 1, "默认将系统标签页合并")
        profile.separateTabs = true
        check(WindowSearch.filtered([a,b], settings: settings, profile: profile, frontPID: 10, displayID: 1, query: "").count == 2, "可分别显示系统标签页")
        var exception = AppException(); exception.bundleID = "com.apple.*"; exception.hide = .title; exception.titles = "收件\nmissing"
        check(exception.hides(inbox) && !exception.hides(project), "应用通配符和标题例外")
        exception.ignore = .fullscreen
        check(exception.ignores(bundle: "com.apple.safari", fullscreen: true) && !exception.ignores(bundle: "com.apple.safari", fullscreen: false), "全屏例外只在指定应用全屏时生效")
        exception.ignore = .always
        check(!exception.ignores(bundle: "org.example.App", fullscreen: true), "例外规则不影响其他应用")
        exception.bundleID = "com.apple.mail"; settings.advanced.exceptions = [exception]
        profile = settings.shortcuts[0]
        check(!filter().contains(inbox), "例外排除应用指定标题")
        settings = .defaults; profile.styleOverride = .titles; profile.themeOverride = .dark; profile.widthOverride = 310
        profile.adaptiveOverride = false; profile.previewOverride = true; profile.release = .search
        let effective = settings.effective(for: profile)
        check(effective.style == .titles && effective.theme == .dark && effective.thumbnailWidth == 310 && !effective.adaptiveThumbnails && effective.advanced.autoPreview, "每组独立外观覆盖")
        check(settings.style == .thumbnails && !settings.advanced.autoPreview, "独立外观保留全局设置")
        check(ReleaseDecision.action(behavior: .search, sticky: false, held: false) == .search, "松开快捷键进入搜索")
        check(ReleaseDecision.action(behavior: .focus, sticky: true, held: false) == nil, "搜索和固定面板不会在松键时切换")
        check(ReleaseDecision.action(behavior: .hold, sticky: false, held: true) == nil, "修饰键保持时不执行松键动作")
        let bindings = PanelBinding.defaults
        check(PanelInputPolicy.command(code: 13, flags: .option, held: .option, sticky: false, searching: false, bindings: bindings) == .close, "按住触发修饰键仍可关闭窗口")
        check(PanelInputPolicy.command(code: 12, flags: [], held: .option, sticky: true, searching: true, bindings: bindings) == nil, "搜索输入 Q 不退出应用")
        check(PanelInputPolicy.command(code: 48, flags: [.option,.shift], held: .option, sticky: false, searching: false, bindings: bindings) == .previous, "Shift Tab 反向导航")
        check(PanelInputPolicy.command(code: 36, flags: [], held: .option, sticky: true, searching: true, bindings: bindings) == .confirm, "搜索中回车确认窗口")
        settings.advanced.bindings[1].keyCode = 36
        check(settings.validationError() != nil, "阻止重复的面板操作按键")
        check(PanelInputPolicy.command(code: 13, flags: .option, held: .option, sticky: true, searching: false, bindings: bindings) == .close, "固定面板后仍按住 Option 可以继续操作")
        check(PanelInputPolicy.command(code: 48, flags: [.option,.shift], held: .option, sticky: true, searching: false, bindings: bindings) == .previous, "固定面板后 Shift Tab 仍可反向导航")
        check(PanelInputPolicy.command(code: 12, flags: .option, held: .option, sticky: true, searching: true, bindings: bindings) == nil, "按住 Option 搜索 Q 不退出应用")
        var customBindings = bindings
        customBindings[customBindings.firstIndex(where: { $0.command == .fullscreen })!].keyCode = 13
        customBindings[customBindings.firstIndex(where: { $0.command == .fullscreen })!].modifiers = .option
        check(PanelInputPolicy.command(code: 13, flags: .option, held: .option, sticky: true, searching: false, bindings: customBindings) == .fullscreen, "显式自定义组合优先于去掉触发修饰键")
        check(PanelInputPolicy.alias(code: 12, flags: [.control,.command], held: .control, bindings: bindings) == nil, "Control Command Q 不被当成退出应用")
        check(PanelInputPolicy.alias(code: 13, flags: [.command,.shift], held: .option, bindings: bindings) == nil, "额外 Shift 不误触 Command W 操作")
        check(PanelInputPolicy.alias(code: 13, flags: [.command,.option], held: .option, bindings: bindings) == .close, "按住触发 Option 时 Command W 仍可操作窗口")
        customBindings = bindings
        customBindings[customBindings.firstIndex(where: { $0.command == .quitApp })!].enabled = false
        check(PanelInputPolicy.alias(code: 12, flags: .command, held: [], bindings: customBindings) == nil, "禁用退出操作也禁用 Command Q 别名")
        settings = .defaults; settings.shortcuts[0].modifiers = .shift
        check(settings.validationError() != nil, "阻止 Shift 字母全局组合占用普通输入")
        settings.shortcuts[0].modifiers = ShortcutModifiers(rawValue: 17)
        check(settings.validationError() != nil, "拒绝不支持的全局修饰键位")
        check(WindowNavigation.vertical(index: 2, count: 7, columns: 3, down: false) == 5, "不完整末行向上导航保持列位置")
        check(WindowNavigation.vertical(index: 4, count: 7, columns: 3, down: true) == 1, "不完整末行向下导航保持列位置")
        check(WindowNavigation.vertical(index: 6, count: 7, columns: 3, down: true) == 0, "同一列的最后一个窗口向下循环")
        check(WindowNavigation.linear(index: 0, count: 7, step: -1) == 6, "线性反向导航循环到最后一项")
        check(WindowNavigation.vertical(index: 0, count: 0, columns: 0, down: false) == 0, "空列表导航不产生无效索引")
        let reversibleGrid = (1...25).allSatisfy { count in
            (1...8).allSatisfy { columns in
                (0..<count).allSatisfy { index in
                    let next = WindowNavigation.vertical(index: index, count: count, columns: columns, down: true)
                    return next >= 0 && next < count && next % columns == index % columns &&
                        WindowNavigation.vertical(index: next, count: count, columns: columns, down: false) == index
                }
            }
        }
        check(reversibleGrid, "不同窗口数量和列数的垂直导航均可逆且不越界")
        var edits = SettingsEditSession(UserSettings.defaults)
        check(!edits.isDirty, "初始设置没有未保存标记")
        edits.draft.style = .icons
        var external = UserSettings.defaults; external.theme = .dark
        edits.synchronize(external)
        check(edits.isDirty && edits.draft.style == .icons, "重新打开设置保留未保存的修改")
        edits.discard()
        check(!edits.isDirty && edits.draft == external, "放弃修改恢复当前已保存设置")
        edits.draft.style = .titles; edits.commit()
        check(!edits.isDirty && edits.saved.style == .titles, "保存后清除未保存状态")
        edits.synchronize(.defaults)
        check(edits.draft == .defaults, "无未保存修改时跟随外部设置更新")
        var requests = RefreshTicketQueue<String>()
        let first = requests.append("panel")
        _ = requests.append("client1"); let newest = requests.append("client2")
        check(requests.finish(upTo: first) == ["panel"], "持续刷新不能让正在等待的面板请求饥饿")
        check(requests.latestPending == newest, "并发请求合并为下一次最新枚举")
        check(requests.finish(upTo: newest) == ["client1", "client2"], "并发窗口查询均收到完成结果")
        check(requests.finish(upTo: newest).isEmpty && requests.latestPending == nil, "刷新完成回调只交付一次")
        var gesture = GestureTracker(choice: .threeHorizontal)
        check(gesture.update(fingers: 3, x: 0.3, y: 0.5) == nil, "手势开始时不意外切换")
        check(gesture.update(fingers: 3, x: 0.51, y: 0.5) == .start(2), "三指水平滑动触发并选择")
        check(gesture.update(fingers: 3, x: 0.41, y: 0.5) == .move(-1), "手势支持反向移动")
        check(gesture.update(fingers: 0, x: 0, y: 0) == .end, "手势抬手时结束")
        check(gesture.update(fingers: 0, x: 0, y: 0) == nil, "手势结束只触发一次")
        var vertical = GestureTracker(choice: .fourVertical)
        _ = vertical.update(fingers: 4, x: 0.1, y: 0.6)
        check(vertical.update(fingers: 4, x: 0.8, y: 0.6) == nil, "垂直手势忽略水平移动")
        check(vertical.update(fingers: 4, x: 0.8, y: 0.39) == nil, "偏离手势方向后，本次触摸不会再触发")
        _ = vertical.update(fingers: 0, x: 0, y: 0)
        _ = vertical.update(fingers: 4, x: 0.1, y: 0.6)
        check(vertical.update(fingers: 4, x: 0.1, y: 0.39) == .start(-2), "抬手后四指垂直手势重新触发")
        check(TitleDisplay.both.text(inbox) == "邮件 — 收件箱", "标题可包含应用名和窗口名")
        check(TitleDisplay.app.text(inbox) == "邮件", "标题可只显示应用名")
        settings = .defaults
        settings.advanced.autoPreview = true; settings.advanced.gesture = .fourVertical; settings.advanced.followCursor = .differentScreen
        let full = try! JSONEncoder().encode(settings)
        check(try! JSONDecoder().decode(UserSettings.self, from: full) == settings, "新增高级配置完整保存与恢复")
        for count in [1, 4, 8, 12, 30, 80] {
            let layout = ThumbnailLayout.calculate(count: count, availableWidth: 900, availableHeight: 620, preferredWidth: 230, adaptive: true)
            check(Double(layout.columns) * layout.width + Double(layout.columns - 1) * 12 <= 900.5 && layout.width >= 150, "\(count) 个窗口的缩略图不超出屏幕宽度")
        }
        check(UserSettings.defaults.advanced.inputMode == .search, "新版默认直接输入搜索")
        for code: UInt32 in [13, 12, 46, 3, 4, 1] {
            check(PanelInputPolicy.command(code: code, flags: .option, held: .option, sticky: false, searching: false, bindings: bindings, mode: .search) == nil, "直接搜索模式普通文字按键 \(code) 不触发窗口操作")
        }
        check(PanelInputPolicy.command(code: 13, flags: .shift, held: [], sticky: true, searching: false, bindings: [.init(command: .close, keyCode: 13, modifiers: .shift)], mode: .search) == nil, "大写字母也保留用于直接搜索")
        check(PanelInputPolicy.command(code: 48, flags: [.option, .shift], held: .option, sticky: false, searching: false, bindings: bindings, mode: .search) == .previous, "直接搜索模式仍支持反向 Tab")
        check(PanelInputPolicy.command(code: 49, flags: [], held: [], sticky: true, searching: false, bindings: bindings, mode: .search) == .preview, "直接搜索模式保留空格预览")
        var modified = bindings
        modified[modified.firstIndex(where: { $0.command == .close })!].modifiers = .control
        check(PanelInputPolicy.command(code: 13, flags: [.option, .control], held: .option, sticky: true, searching: false, bindings: modified, mode: .search) == .close, "直接搜索保留显式自定义操作组合")
        check(PanelInputPolicy.alias(code: 12, flags: .command, held: [], bindings: bindings) == .quitApp, "搜索模式通过 Command Q 操作选中应用")
        check(WindowSearch.matches(inbox, query: "sjx"), "中文拼音首字母搜索")
        check(WindowSearch.matches(project, query: "safrai"), "相邻字母颠倒容错")
        check(WindowSearch.matches(project, query: "safri"), "漏一个英文字母容错")
        check(WindowSearch.matches(project, query: "safarii"), "多一个英文字母容错")
        check(WindowSearch.matches(project, query: "safary"), "一个英文字母替换容错")
        check(!WindowSearch.matches(project, query: "safary", allowTypos: false), "可关闭拼写容错")
        check(!WindowSearch.matches(project, query: "safxrz"), "多处错误不产生模糊结果")
        check(WindowSearch.matches(inbox, query: "shoujianxang"), "完整拼音也允许漏一个字母")
        check(!WindowSearch.matches(project, query: "sar"), "短查询不启用拼写容错")
        check(!WindowSearch.matches(project, query: "safari impossible"), "容错搜索仍需匹配全部关键词")
        check(!WindowSearch.oneEditApart("abcd", "abxyzcd") && !WindowSearch.oneEditApart("abcd", "badc"), "插入多个字母和两次转置均不匹配")
        func sample(_ id: String, app: String = "Editor", title: String, minimized: Bool = false, focused: Double = 0) -> WindowDescriptor {
            var w = WindowDescriptor(id: id, windowID: nil, pid: 42, appName: app, bundleID: "org.editor", title: title,
                                     minimized: minimized, hidden: false, onCurrentSpace: true, displayID: nil, aspectRatio: 1.6)
            w.lastFocused = focused; return w
        }
        var exact = sample("exact", app: "Safari", title: "Safari", minimized: true, focused: 1)
        let typo = sample("typo", title: "Safary", focused: 99)
        let partial = sample("partial", title: "Notes for Safari", focused: 90)
        settings = .defaults; profile = settings.shortcuts[0]; profile.minimized = .atEnd; profile.order = .created
        let ranked = WindowSearch.filtered([typo, partial, exact], settings: settings, profile: profile, frontPID: nil, displayID: nil, query: "safari")
        check(ranked.map(\.id) == ["exact", "partial", "typo"], "直接名称精确匹配优先于包含匹配和拼写容错，即使窗口最小化")
        let directLatin = sample("latin", title: "shoujianxiang", focused: 1)
        var pinyin = inbox; pinyin.lastFocused = 99
        check(WindowSearch.filtered([pinyin, directLatin], settings: settings, profile: profile, frontPID: nil, displayID: nil, query: "shoujianxiang").map(\.id) == ["latin", "inbox"], "直接文字优先于拼音匹配")
        let same = sample("same", app: "Safari", title: "Safari", focused: 2)
        exact.lastFocused = 10
        check(WindowSearch.filtered([same, exact], settings: settings, profile: profile, frontPID: nil, displayID: nil, query: "safari").map(\.id) == ["exact", "same"], "同等搜索匹配按最近使用排序")
        check(WindowSearch.filtered([same, exact], settings: settings, profile: profile, frontPID: nil, displayID: nil, query: "").map(\.id) == ["same", "exact"], "清空搜索恢复原来的末尾显示策略")
        settings.advanced.searchRanking = false
        check(WindowSearch.filtered([same, exact], settings: settings, profile: profile, frontPID: nil, displayID: nil, query: "safari").map(\.id) == ["same", "exact"], "关闭搜索排序可保持分组配置")
        var legacyAdvanced = AdvancedSettings()
        legacyAdvanced.exceptions = []
        legacyAdvanced.bindings[legacyAdvanced.bindings.firstIndex(where: { $0.command == .close })!].modifiers = .control
        var legacyObject = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyAdvanced)) as! [String: Any]
        for key in ["preferencesRevision", "inputMode", "searchRanking", "searchTypos"] { legacyObject.removeValue(forKey: key) }
        func decodeLegacy() -> AdvancedSettings { try! JSONDecoder().decode(AdvancedSettings.self, from: JSONSerialization.data(withJSONObject: legacyObject)) }
        let upgraded = decodeLegacy()
        check(upgraded.inputMode == .search && upgraded.searchRanking && upgraded.searchTypos, "旧配置迁移采用已确认的新版搜索默认值")
        check(upgraded.bindings == legacyAdvanced.bindings && upgraded.exceptions.contains { $0.ignores(bundle: "com.netease.uuremote", fullscreen: true) }, "迁移保留自定义按键并补上 UU 全屏例外")
        var customUU = AppException(); customUU.bundleID = "com.netease.*"; customUU.ignore = .always
        legacyObject["exceptions"] = try! JSONSerialization.jsonObject(with: JSONEncoder().encode([customUU]))
        let respected = decodeLegacy()
        check(respected.exceptions.count == 1 && respected.exceptions[0].ignore == .always, "用户已有 UU 通配符规则时不覆盖或重复添加")
        var deletedUU = upgraded; deletedUU.exceptions = []
        let deletedAgain = try! JSONDecoder().decode(AdvancedSettings.self, from: JSONEncoder().encode(deletedUU))
        check(deletedAgain.exceptions.isEmpty, "用户删除新版 UU 例外后不会被再次自动添加")
        check(AppException.uuRemote.ignores(bundle: "com.netease.uuremote", fullscreen: true) && !AppException.uuRemote.ignores(bundle: "com.netease.uuremote", fullscreen: false), "UU 仅全屏避让，窗口模式保留 Mac 快捷键")
        var previews = PreviewRequestQueue<Int>()
        for i in 0..<100 { previews.enqueue(i, urgent: false) }
        previews.enqueue(99, urgent: true)
        check(previews.keys.count == 100 && previews.pop() == 99, "选中第 100 个窗口也优先预览，没有前 60 个限制")
        previews.enqueue(1, urgent: true); previews.enqueue(1, urgent: false)
        check(previews.keys.count == 99 && previews.pop(excluding: [1]) == 0 && previews.pop() == 1, "去重并暂时跳过仍在截图的窗口")
        previews.removeAll(); check(previews.pop() == nil, "关闭面板后清空未开始的预览请求")
        var budget = PreviewCacheBudget<String>(maximumBytes: 100, maximumCount: 3)
        check(budget.store("a", bytes: 40).isEmpty && budget.store("b", bytes: 40).isEmpty && budget.totalBytes == 80, "预览缓存准确累计估计字节")
        check(budget.store("a", bytes: 50).isEmpty && budget.store("c", bytes: 40) == ["b"] && budget.totalBytes == 90, "替换图片不重复计费，超容量淘汰最旧图片")
        budget.retain(["c"]); check(budget.totalBytes == 40, "关闭窗口释放其预览缓存预算")
        check(budget.store("huge", bytes: 101) == ["c", "huge"] && budget.totalBytes == 0, "单张超限图片不能突破缓存预算")
        var countBudget = PreviewCacheBudget<Int>(maximumBytes: 100, maximumCount: 2)
        _ = countBudget.store(1, bytes: 0); _ = countBudget.store(2, bytes: 0)
        check(countBudget.store(3, bytes: 0) == [1], "预览数量也有独立上限")
        var timings = LatencySeries(limit: 3)
        for value in [10.0, 20.0, 30.0, 40.0] { timings.record(milliseconds: value) }
        timings.record(milliseconds: .nan); timings.record(milliseconds: -1)
        check(timings.values == [20, 30, 40] && timings.summary["p50_ms"] == 30 && timings.summary["p95_ms"] == 40, "内存诊断有界并过滤无效耗时，计算 P50/P95")
        verifyEnhancements()
        verifyPanelRecovery()
        verifyVersion16()
        verifyVersion20()
        verifyMenuBar()
        verifyPinsAndRecovery()
        verifyOptimizations()
        verifyThreading()
        verifyWindowShortcuts()
        verifySettingsEntry()
        verifyRecentOrder()
        verifyBrowserScripts()
        verifySearchHabits()
        verifyDockPreviewExtras()
        verifyChineseSearch()
        verifyCrashRestart()
        verifyStartMenu()
        verifyLayoutSnapshots()
        print("\(passed) checks passed")
    }
    static func verifyLayoutSnapshots() {
        let place = WindowRect(x: 10, y: 40, width: 300, height: 200)
        let screen = WindowRect(x: 0, y: 25, width: 1440, height: 875)
        func window(_ id: String, bundle: String = "a", title: String = "文档", number: UInt32? = nil, minimized: Bool = false, hidden: Bool = false, frame: WindowRect? = WindowRect(x: 10, y: 40, width: 300, height: 200)) -> WindowDescriptor {
            var d = WindowDescriptor(id: id, windowID: number, pid: 7, appName: bundle, bundleID: bundle, title: title, minimized: minimized, hidden: hidden, onCurrentSpace: true, displayID: nil, aspectRatio: 1.6)
            d.frame = frame
            return d
        }
        func saved(bundle: String = "a", title: String = "文档", number: UInt32? = nil) -> LayoutSnapshot.Window {
            LayoutSnapshot.Window(bundleID: bundle, appName: bundle, title: title, windowID: number, frame: place)
        }
        func layout(_ name: String, _ windows: [LayoutSnapshot.Window] = []) -> LayoutSnapshot {
            LayoutSnapshot(id: UUID(), name: name, created: 0, screens: [screen], windows: windows)
        }

        // What is remembered.
        var fullScreen = window("full"); fullScreen.fullscreen = true
        var noWindow = window("none"); noWindow.windowless = true
        var tab = window("tab"); tab.tabRepresentative = false
        var own = window("own"); own.settingsWindow = true
        var row = window("row"); row.launcher = .app
        let notKept = [fullScreen, noWindow, tab, own, row, window("min", minimized: true), window("hid", hidden: true), window("nof", frame: nil), window("nob", bundle: ""), window("flat", frame: WindowRect(x: 0, y: 0, width: 0, height: 0))]
        for item in notKept { check(!LayoutSnapshotPolicy.capturable(item), "不保存：\(item.id)") }
        let captured = LayoutSnapshotPolicy.capture(name: "  工作  ", windows: notKept + [window("kept", bundle: "b", title: "表格", number: 11)], screens: [screen], now: 5)
        check(captured.name == "工作", "名称去掉首尾空格")
        check(captured.windows == [saved(bundle: "b", title: "表格", number: 11)], "只保存屏幕上的窗口，并记下位置和标题")
        check(captured.screens == [screen] && captured.created == 5, "记下当时的屏幕")
        check(LayoutSnapshotPolicy.capture(name: "x", windows: (0..<500).map { window("w\($0)") }, screens: [], now: 0).windows.count == LayoutSnapshotPolicy.windowLimit, "窗口数量有上限")

        // Names and the list.
        check(LayoutSnapshotPolicy.suggestedName(among: []) == "布局 1", "第一个布局的名称")
        check(LayoutSnapshotPolicy.suggestedName(among: [layout("布局 1"), layout("布局 3")]) == "布局 2", "建议的名称不重复")
        check(LayoutSnapshotPolicy.cleaned(name: " a\n") == "a", "名称去掉换行")
        check(LayoutSnapshotPolicy.cleaned(name: String(repeating: "长", count: 100)).count == LayoutSnapshotPolicy.longestName, "名称长度有上限")
        let first = layout("工作"), second = layout("回家")
        let added = LayoutSnapshotPolicy.adding(second, to: [first])
        check(added == [first, second], "新名称加在后面")
        let again = layout("工作", [saved()])
        check(LayoutSnapshotPolicy.adding(again, to: [first, second]) == [again, second], "同名的布局被替换")
        let full = (0..<LayoutSnapshotPolicy.limit).map { layout("布局\($0)") }
        check(LayoutSnapshotPolicy.adding(layout("再来一个"), to: full) == nil, "布局满了时不会悄悄丢掉旧的")
        check(LayoutSnapshotPolicy.adding(layout("布局0"), to: full)?.count == LayoutSnapshotPolicy.limit, "布局满了也可以替换同名的")
        check(LayoutSnapshotPolicy.decoded(try! JSONEncoder().encode([again, second])) == [again, second], "保存后读取不变")
        check(LayoutSnapshotPolicy.decoded(nil).isEmpty, "没有保存过时是空的")
        check(LayoutSnapshotPolicy.decoded(Data("不是 JSON".utf8)).isEmpty, "数据损坏时是空的")

        // Finding the windows again.
        let matched = LayoutSnapshotPolicy.match([saved(title: "文档", number: 11), saved(title: "表格", number: 12), saved(title: "旧", number: 13), saved(bundle: "c", title: "x", number: 14)],
                                                 live: [window("renamed", title: "改了名", number: 12), window("sameTitle", title: "文档", number: 99), window("other", title: "别的", number: 98), window("wrongApp", bundle: "b", title: "x", number: 14)])
        check(matched == [0: "sameTitle", 1: "renamed", 2: "other"], "先按窗口编号，再按标题，最后按同一个应用")
        check(LayoutSnapshotPolicy.match([saved(title: "1"), saved(title: "2")], live: [window("only")]).count == 1, "一个窗口不会被用两次")
        check(LayoutSnapshotPolicy.match([saved(number: 5)], live: [window("x", bundle: "b", number: 5)]).isEmpty, "其他应用的窗口不算，即使编号相同")
        check(LayoutSnapshotPolicy.match([saved(title: "T"), saved(title: "U", number: 21)], live: [window("x", title: "T", number: 21)]) == [1: "x"], "编号相同的优先于标题相同的")
        check(LayoutSnapshotPolicy.match([saved()], live: [fullScreen]).isEmpty, "不移动全屏窗口")
        check(LayoutSnapshotPolicy.match([saved()], live: [tab]).isEmpty, "不单独移动标签页")
        check(LayoutSnapshotPolicy.match([saved()], live: [noWindow]).isEmpty, "没有窗口的应用不算")
        check(LayoutSnapshotPolicy.match([saved()], live: [own]).isEmpty, "不移动一瞥自己的设置窗口")
        check(LayoutSnapshotPolicy.match([saved()], live: [row]).isEmpty, "搜索结果不算窗口")
        check(LayoutSnapshotPolicy.match([saved()], live: [window("m", minimized: true)]) == [0: "m"], "最小化的窗口可以恢复")
        check(LayoutSnapshotPolicy.match([saved()], live: [window("h", hidden: true)]) == [0: "h"], "隐藏的应用的窗口可以恢复")
        check(LayoutSnapshotPolicy.match([], live: [window("x")]).isEmpty, "空布局不移动任何窗口")

        // Where they go.
        func target(_ frame: WindowRect, _ old: [WindowRect], _ new: [WindowRect]) -> WindowRect { LayoutSnapshotPolicy.target(of: frame, savedScreens: old, screens: new) }
        let partlyOff = WindowRect(x: -100, y: 100, width: 800, height: 600)
        check(target(partlyOff, [screen], [screen]) == partlyOff, "屏幕没变时位置完全不变")
        check(target(place, [], [screen]) == place, "没有记下屏幕时不换算")
        check(target(place, [screen], []) == place, "读不到屏幕时不换算")
        let external = WindowRect(x: 1440, y: 25, width: 1920, height: 1055), movedExternal = WindowRect(x: -1920, y: 25, width: 1920, height: 1055)
        let onExternal = WindowRect(x: 1500, y: 100, width: 800, height: 600)
        check(target(onExternal, [screen, external], [screen, external]) == onExternal, "两块屏幕都没变时位置不变")
        check(target(onExternal, [screen, external], [screen, movedExternal]) == WindowRect(x: -1860, y: 100, width: 800, height: 600), "外接屏换了位置时窗口跟着它")
        let leftHalf = WindowRect(x: 0, y: 25, width: 720, height: 875), bigger = WindowRect(x: 0, y: 25, width: 2880, height: 1750)
        check(target(leftHalf, [screen], [bigger]) == WindowRect(x: 0, y: 25, width: 1440, height: 1750), "换了大小的屏幕上，左半屏还是左半屏")
        let onlyLaptop = target(onExternal, [screen, external], [screen])
        check(onlyLaptop.x >= screen.x && onlyLaptop.x + onlyLaptop.width <= screen.x + screen.width, "外接屏拔掉后窗口横向留在现有屏幕内")
        check(onlyLaptop.y >= screen.y && onlyLaptop.y + onlyLaptop.height <= screen.y + screen.height, "外接屏拔掉后窗口纵向留在现有屏幕内")
        let huge = target(WindowRect(x: 0, y: 25, width: 5000, height: 5000), [screen], [WindowRect(x: 0, y: 25, width: 1000, height: 600)])
        check(huge.width == 1000 && huge.height == 600, "窗口不会大过屏幕")
        check(target(place, [WindowRect(x: 0, y: 0, width: 0, height: 0)], [screen]) == place, "保存的屏幕数据不合理时不换算")

        // Saying what happened.
        check(LayoutSnapshotPolicy.summary(placed: 3, total: 3) == "已恢复 3 个窗口。", "全部恢复")
        check(LayoutSnapshotPolicy.summary(placed: 2, total: 3).contains("另外 1 个"), "说明有几个没有恢复")
        check(LayoutSnapshotPolicy.summary(placed: 0, total: 2).contains("另外 2 个"), "一个也没有恢复")

        // In the search.
        check(LaunchKind.layout.action == "执行" && LaunchKind.command.action == "执行", "布局和命令的回车动作")
        check(LaunchKind.layout.place == LaunchKind.command.place, "布局和系统命令排在一起")
        var result = WindowDescriptor(id: "layout:1", windowID: nil, pid: 0, appName: "Restore Window Layout", bundleID: "", title: "恢复布局：工作", minimized: false, hidden: false, onCurrentSpace: true, displayID: nil, aspectRatio: 1.6)
        result.launcher = .layout
        result.subtitle = LayoutSnapshotPolicy.keywords
        for query in ["工作", "布局", "buju", "layout", "snapshot", "快照"] { check(WindowSearch.matches(result, query: query), "搜索可以找到布局：\(query)") }
        check(SearchHabits.target(of: result) == "layout:1", "搜索习惯只记布局的编号，不记名称")
        check(SettingSearchIndex.results("窗口布局").first?.section == 1, "设置搜索可以找到窗口布局")
        check(SettingSearchIndex.results("快照").first?.title == "窗口布局", "设置搜索可以用“快照”找到窗口布局")
    }
    static func verifyStartMenu() {
        // A sum.
        func sum(_ text: String) -> String? { Calculator.evaluate(text).map(Calculator.format) }
        let sums: [(String, String)] = [
            ("1+2*3", "7"), ("(1+2)*3", "9"), ("10/4", "2.5"), ("7-10", "-3"),
            ("2^10", "1024"), ("2**10", "1024"), ("2^3^2", "512"), ("-2^2", "-4"), ("2^-1", "0.5"), ("2*3**2", "18"),
            ("10%3", "1"), ("10 % 3", "1"), ("50%", "0.5"), ("50%+1", "1.5"), ("200*15%", "30"), ("200+50%*2", "201"),
            ("sqrt(16)+1", "5"), ("abs(-3)+1", "4"), ("round(2.6)", "3"), ("log(100)", "2"), ("floor(2.9)*2", "4"), ("ceil(2.1)", "3"),
            ("1 + 2", "3"), ("３＋４", "7"), ("3×4", "12"), ("8÷2", "4"), ("（1+2）*2", "6"), ("3x4", "12"), ("3X4", "12"), ("5−2", "3"), ("1.5+.5", "2"),
            ("0.1+0.2", "0.3"), ("1/3", "0.333333333333"), ("10^20", "1e+20"), ("1-1", "0"), ("-1+1", "0"), ("0*-1", "0"),
        ]
        for (text, answer) in sums { check(sum(text) == answer, "算式 \(text) = \(answer)") }
        check(sum("pi*2")?.hasPrefix("6.28318530") == true, "圆周率")
        check(sum("π*2")?.hasPrefix("6.28318530") == true, "圆周率可以写成 π")
        let notSums = ["123", "-5", "(5)", "pi", "abc", "", " ", "1+", "+", "*2", "(1+2", "1+2)", "2(3)", "2pi", "1 2", "sqrt", "sqrt(", "sqrt 4", "nosuch(1)", "x", "3x", "%",
                       "2024-01-01", "1.2.3", "007+1", "7-zip", "v1.2", "a+b", "微信+1", "一+一", "1/0", "0/0", "sqrt(-1)", "2^99999", "5%0"]
        for text in notSums { check(sum(text) == nil, "不显示计算结果：\(text)") }
        let deep = String(repeating: "(", count: 90) + "1+1" + String(repeating: ")", count: 90)
        check(sum(deep) == nil, "括号嵌套太深时不计算，也不会崩溃")
        check(sum(String(repeating: "-", count: 150) + "1+1") == nil, "负号太多时不计算，也不会崩溃")
        check(sum(String(repeating: "1+", count: 400) + "1") == nil, "太长时不计算")
        check(sum(String(repeating: "(", count: 10) + "1+1" + String(repeating: ")", count: 10)) == "2", "普通的嵌套可以计算")

        // A web search and a web address.
        check(WebSearchEngine.baidu.url(for: "微信")?.absoluteString == "https://www.baidu.com/s?wd=%E5%BE%AE%E4%BF%A1", "百度搜索的地址")
        check(WebSearchEngine.bing.url(for: "a b")?.absoluteString == "https://www.bing.com/search?q=a%20b", "必应搜索的地址")
        check(WebSearchEngine.google.url(for: "c++")?.absoluteString == "https://www.google.com/search?q=c%2B%2B", "加号不会变成空格")
        check(WebSearchEngine.duckDuckGo.url(for: "a&b=c#d")?.absoluteString == "https://duckduckgo.com/?q=a%26b%3Dc%23d", "特殊字符不会改变地址的结构")
        check(WebSearchEngine.allCases.allSatisfy { $0.url(for: "x")?.scheme == "https" && !$0.label.isEmpty }, "每个搜索引擎都用 https")
        let addresses: [(String, String)] = [
            ("github.com", "https://github.com"), (" docs.python.org/3/ ", "https://docs.python.org/3/"), ("www.example.xyz", "https://www.example.xyz"), ("http://x.org/a?b=1", "http://x.org/a?b=1"),
        ]
        for (text, address) in addresses { check(WebAddress.url(from: text)?.absoluteString == address, "网址：\(text)") }
        check(WebAddress.url(from: "HTTPS://x.dev")?.host == "x.dev", "协议的大小写不影响判断")
        for text in ["javascript:alert(1)", "file:///etc/passwd", "ftp://x.org", "mailto:a@b.com", "x-apple.systempreferences:com", "chrome://settings", "localhost:8080", "http://", "https:// x.org"] {
            check(WebAddress.url(from: text) == nil, "只打开 http 和 https：\(text)")
        }
        for text in ["report.pdf", "main.swift", "com.apple.mail", "hello world", "微信", "1.5", "a..com", ".com", "com", "a@b.com", ""] {
            check(WebAddress.url(from: text) == nil, "不算网址：\(text)")
        }

        // Commands.
        let commands = SystemCommand.allCases
        check(Set(commands.map(\.title)).count == commands.count, "系统命令的名称不重复")
        check(commands.allSatisfy { !$0.english.isEmpty && !$0.keywords.isEmpty && !$0.symbol.isEmpty }, "每个系统命令都有英文名、搜索词和图标")
        check(commands.allSatisfy { $0.program.path.hasPrefix("/usr/bin/") }, "系统命令用系统自带的绝对路径运行")
        check(commands.allSatisfy { $0.asksFirst == $0.title.hasSuffix("…") }, "会先确认的命令名称都带省略号")
        for command in [SystemCommand.restart, .shutDown, .logOut, .emptyTrash] { check(command.asksFirst, "结束会话或删除文件前先确认：\(command.title)") }
        check(SystemCommand.restart.program.arguments.last?.contains("aevtrrst") == true, "重新启动用系统的确认对话框")
        check(SystemCommand.shutDown.program.arguments.last?.contains("aevtrsdn") == true, "关机用系统的确认对话框")
        check(SystemCommand.logOut.program.arguments.last?.contains("aevtlogo") == true, "退出登录用系统的确认对话框")
        for event in ["aevtrest", "aevtshut", "aevtrlgo"] {
            check(!commands.contains { $0.program.arguments.contains { $0.contains(event) } }, "不使用不经确认就执行的事件：\(event)")
        }

        // Files.
        let home = "/Users/me"
        check(FileSearchPolicy.tokens("报告 2026") == ["报告", "2026"], "按空格分开查找")
        for text in ["a", "", "  ", "* ?"] { check(FileSearchPolicy.tokens(text).isEmpty, "至少两个字才查文件：\(text)") }
        check(FileSearchPolicy.tokens("a*b?c") == ["abc"], "通配符不进入查询")
        check(FileSearchPolicy.tokens("\"x'y\\z") == ["xyz"], "引号和反斜杠不进入查询")
        check(FileSearchPolicy.tokens("a b c d e f g").count == 5, "关键词数量有上限")
        for path in ["/Users/me/Documents/报告.pdf", "/Users/me/a.txt"] { check(FileSearchPolicy.keeps(path: path, home: home), "主目录下的文件：\(path)") }
        for path in ["/Users/me/Library/Caches/a.txt", "/Users/me/.ssh/config", "/Users/me/x/.git/a", "/Users/me/Applications/A.app", "/Users/me/A.app/Contents/x.txt", "/Users/other/a.txt", "/Users/melissa/a.txt", "/tmp/a.txt"] {
            check(!FileSearchPolicy.keeps(path: path, home: home), "不列这个文件：\(path)")
        }
        check(FileSearchPolicy.kept((0..<20).map { "/Users/me/\($0).txt" }, home: home).count == FileSearchPolicy.limit, "文件数量有上限")
        check(FileSearchPolicy.place(of: "/Users/me/Documents/a.txt", home: home) == "~/Documents", "子文件夹里的文件")
        check(FileSearchPolicy.place(of: "/Users/me/a.txt", home: home) == "~", "主目录里的文件")
        check(FileSearchPolicy.place(of: "/tmp/a.txt", home: home) == "/tmp", "其他位置的文件")

        // Together in the results.
        func result(_ id: String, title: String, kind: LaunchKind?, bundle: String = "", pid: Int32 = 0) -> WindowDescriptor {
            var d = WindowDescriptor(id: id, windowID: nil, pid: pid, appName: title, bundleID: bundle, title: title, minimized: false, hidden: false, onCurrentSpace: true, displayID: nil, aspectRatio: 1.6)
            d.launcher = kind
            return d
        }
        func list(_ items: [WindowDescriptor], _ text: String) -> [String] {
            let settings = UserSettings.defaults
            return WindowSearch.filtered(items, settings: settings, profile: settings.shortcuts[0], frontPID: nil, displayID: nil, query: text).map(\.id)
        }
        let mixed = [result("web", title: "用百度搜索", kind: .web), result("file", title: "wx 记录.txt", kind: .file), result("window", title: "wx 窗口", kind: nil, bundle: "w", pid: 5),
                     result("app", title: "wx 工具", kind: .app, bundle: "t"), result("command", title: "wx 命令", kind: .command, bundle: "lockScreen"), result("calc", title: "= 7", kind: .calculation)]
        check(list(mixed, "wx") == ["calc", "window", "app", "command", "file", "web"], "算式最前，文件在窗口和应用之后，网页搜索最后")
        check(list(mixed, "") == ["window"], "没有输入时只列窗口")
        check(list([result("web", title: "用百度搜索", kind: .web)], "完全不相关") == ["web"], "网页搜索不要求匹配输入")
        check(list([result("file", title: "报告.txt", kind: .file)], "完全不相关").isEmpty, "输入变化后，不匹配的旧文件结果不再显示")
        let many = (0..<20).map { result("a\($0)", title: "wx\($0)", kind: .app, bundle: "a\($0)") } + (0..<3).map { result("f\($0)", title: "wx\($0).txt", kind: .file) }
            + [result("web", title: "搜索", kind: .web), result("calc", title: "= 1", kind: .calculation)]
        let listed = list(many, "wx")
        check(listed.filter { $0.hasPrefix("a") }.count == WindowSearch.launcherLimit, "应用的数量仍有上限")
        check(listed.filter { $0.hasPrefix("f") }.count == 3, "文件不占应用的名额")
        check(listed.contains("web") && listed.first == "calc", "算式和网页搜索不占应用的名额")
        for kind in [LaunchKind.file, .calculation, .web] { check(SearchHabits.target(of: result("x", title: "x", kind: kind)) == nil, "不进入搜索习惯：\(kind)") }
        check(SearchHabits.target(of: result("launch:command:sleep", title: "睡眠", kind: .command, bundle: "sleep")) == "launch:command:sleep", "系统命令可以进入搜索习惯")
        var command = result("c", title: "锁定屏幕", kind: .command, bundle: "lockScreen")
        command.subtitle = SystemCommand.lockScreen.keywords
        for query in ["锁屏", "suoping", "suodingpingmu", "sdpm"] { check(WindowSearch.matches(command, query: query), "系统命令可以用别名和拼音找到：\(query)") }
        for kind in LaunchKind.allCases { check(!kind.label.isEmpty && !kind.symbol.isEmpty && !kind.hint.isEmpty && !kind.action.isEmpty, "每种结果都有说明：\(kind)") }
        check(LaunchKind.calculation.action == "复制" && LaunchKind.web.action == "打开", "回车的动作")
        check(LaunchKind.web.madeFromQuery && LaunchKind.calculation.madeFromQuery && !LaunchKind.file.madeFromQuery, "只有算式和网页搜索不需要匹配输入")

        // Settings.
        let standard = AdvancedSettings()
        check(standard.searchCommands && standard.searchFiles && standard.searchCalculator && standard.searchWeb, "开始菜单的功能默认开启")
        check(standard.webEngine == .baidu, "默认的搜索引擎")
        var stored = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(standard)) as! [String: Any]
        for key in ["searchCommands", "searchFiles", "searchCalculator", "searchWeb", "webEngine"] { stored.removeValue(forKey: key) }
        check(try! JSONDecoder().decode(AdvancedSettings.self, from: JSONSerialization.data(withJSONObject: stored)) == standard, "旧设置没有这几项时采用默认值")
        var chosen = standard
        chosen.searchWeb = false; chosen.searchFiles = false; chosen.webEngine = .google
        check(try! JSONDecoder().decode(AdvancedSettings.self, from: JSONEncoder().encode(chosen)) == chosen, "开始菜单的设置保存后不变")
        for word in ["计算器", "锁屏", "网页搜索", "聚焦", "必应"] { check(SettingSearchIndex.results(word).first?.section == 1, "设置搜索可以找到新选项：\(word)") }
    }
    static func verifyCrashRestart() {
        let p = CrashRestartPolicy.self
        // The command, run by a real shell with a harmless program in place of `open`.
        func run(_ arguments: [String]) -> String {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: arguments[0])
            process.arguments = Array(arguments.dropFirst())
            process.standardOutput = pipe
            try! process.run()
            process.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }
        for path in ["/Applications/Glance.app", "/tmp/带 空格 的/Glance.app", "/tmp/it's \"odd\" $(touch x); `y`.app"] {
            let output = run(["/bin/sh", "-c", p.script(delay: 0, opener: "/usr/bin/printf '%s|'"), path])
            check(output == "-n|\(path)|--args|--restarted-after-crash|", "重新打开的命令原样传递路径：\(path)")
            let command = p.command(appPath: path)
            check(command.count == 4 && command[0] == "/bin/sh" && command[1] == "-c" && command[3] == path && !command[2].contains(path), "路径只作为参数，不进入脚本")
        }
        check(p.script().hasPrefix("sleep 2;") && p.script().contains("exec /usr/bin/open -n"), "等旧进程退出后再打开一个新进程")

        // Stopping after repeated crashes.
        check(p.allowsAnother([], now: 1000), "没有崩溃记录时可以重新打开")
        let twice = p.recording(restartAt: 1100, history: p.recording(restartAt: 1000, history: []))
        check(twice == [1000, 1100] && p.allowsAnother(twice, now: 1100), "重新打开两次后还可以再开一次")
        let thrice = p.recording(restartAt: 1200, history: twice)
        check(thrice.count == 3 && !p.allowsAnother(thrice, now: 1200), "重新打开三次后不再重开")
        check(p.allowsAnother(thrice, now: 1000 + p.window + 201), "过了时间窗口又可以重新打开")
        check(p.recording(restartAt: 2000, history: [1000, 1500, 1900]) == [1500, 1900, 2000], "记录时丢弃窗口外的旧记录")
        check(p.recent([5000, 900], now: 1000) == [900], "时钟往回调时，未来时间的记录不算数")
        check(p.recent([400, 401], now: 1000) == [401], "正好满一个时间窗口的记录不算数")

        // Which copies are reopened.
        check(p.applies(arguments: ["/A/Glance.app/Contents/MacOS/Glance"], bundlePath: "/A/Glance.app"), "普通启动会重新打开")
        check(p.applies(arguments: ["x", p.argument], bundlePath: "/A/Glance.app") && p.applies(arguments: ["x", "--settings"], bundlePath: "/A/Glance.app"), "崩溃后重开和打开设置也算普通启动")
        check(p.applies(arguments: ["x", "-psn_0_123"], bundlePath: "/A/Glance.app"), "系统传入的单横线参数不影响判断")
        check(!p.applies(arguments: ["x", "--dock-preview-selftest", "/tmp"], bundlePath: "/A/Glance.app") && !p.applies(arguments: ["x", "--demo"], bundlePath: "/A/Glance.app"), "测试启动不重新打开")
        check(!p.applies(arguments: ["x"], bundlePath: "/usr/local/bin"), "不在应用包里运行时不重新打开")

        // Settings.
        check(AdvancedSettings().restartAfterCrash, "默认开启自动重新打开")
        var plain = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(AdvancedSettings())) as! [String: Any]
        plain.removeValue(forKey: "restartAfterCrash")
        check(try! JSONDecoder().decode(AdvancedSettings.self, from: JSONSerialization.data(withJSONObject: plain)).restartAfterCrash, "旧设置没有这一项时默认开启")
        var off = AdvancedSettings(); off.restartAfterCrash = false
        check(try! JSONDecoder().decode(AdvancedSettings.self, from: JSONEncoder().encode(off)) == off, "关掉后保存仍然是关的")
        check(SettingSearchIndex.results("崩溃").first?.section == 6 && SettingSearchIndex.results("闪退").first?.title == "意外退出后自动重新打开", "设置搜索可以找到这个开关")
    }
    static func verifyChineseSearch() {
        func window(_ title: String, app: String = "App") -> WindowDescriptor {
            WindowDescriptor(id: title, windowID: 1, pid: 1, appName: app, bundleID: "org.app", title: title, minimized: false, hidden: false, onCurrentSpace: true, displayID: 1, aspectRatio: 1.5)
        }
        func finds(_ title: String, _ query: String) -> Bool { WindowSearch.matches(window(title), query: query) }

        // Characters with more than one reading.
        check(finds("重庆", "chongqing") && finds("重庆", "zhongqing"), "多音字：重庆的两个读音都能找到")
        check(finds("重庆", "cq") && finds("重庆", "zq"), "多音字的每个读音都能用首字母找到")
        check(finds("中国银行", "yinhang") && finds("中国银行", "zhongguoyinhang") && finds("银行", "yh"), "多音字：银行")
        check(finds("音乐", "yinyue") && finds("音乐", "yinle"), "多音字：音乐")
        check(finds("校长", "xiaozhang") && finds("长城", "changcheng"), "多音字：长")
        check(finds("文件夹", "wenjianjia") && finds("便签", "bianqian") && finds("屏幕", "pingmu"), "多音字：常见的名称")
        check(WindowSearch.matchKind(window("重庆"), query: "chongqing") == .pinyin, "多音字匹配显示为拼音")
        check(WindowSearch.highlights(in: "重庆银行", query: "yinhang") == [2..<4], "多音字匹配高亮对应的汉字")
        check(PinyinReadings.syllables(of: "乐").contains("yue") && PinyinReadings.syllables(of: "乐").contains("le"), "读音表合并系统读音")
        check(Set(PinyinReadings.syllables(of: "重")).count == PinyinReadings.syllables(of: "重").count, "读音不重复")

        // ü typed as v or u.
        check(finds("绿色", "lvse") && finds("绿色", "luse"), "ü 可以输入 v 或 u")
        check(finds("女生", "nvsheng") && finds("女生", "nusheng"), "系统读音里的 ü 也可以输入 v")
        check(finds("旅行", "lvxing") && finds("率", "shuai") && finds("率", "lv"), "ü 和多音字可以同时出现")

        // Mixed typing.
        check(finds("微信", "微xin") && finds("微信", "wei信"), "汉字和全拼混合输入")
        check(finds("微信", "wxin") && finds("微信", "weix") && finds("微信", "微x"), "全拼和首字母混合输入")
        check(finds("收件箱", "收jian箱") && finds("收件箱", "shoujx") && finds("收件箱", "sjxiang"), "三个字也能混合输入")
        check(finds("企业微信", "微xin"), "混合输入可以从名称中间开始")
        check(!finds("微信", "微xun") && !finds("微信", "微a") && !finds("微信", "信微"), "混合输入仍然要求每个字都对上，顺序也不能变")
        check(WindowSearch.matchKind(window("微信"), query: "微xin") == .pinyin, "混合输入显示为拼音")
        check(WindowSearch.highlights(in: "微信", query: "微xin") == [0..<2] && WindowSearch.highlights(in: "企业微信", query: "wxin") == [2..<4], "混合输入高亮对应的汉字")
        check(WindowSearch.matches(window("工作", app: "微信"), query: "wxin"), "应用名也能混合输入")

        // Ranking.
        func order(_ windows: [WindowDescriptor], _ query: String, _ advanced: (inout AdvancedSettings) -> Void = { _ in }) -> [String] {
            var settings = UserSettings.defaults
            advanced(&settings.advanced)
            return WindowSearch.filtered(windows, settings: settings, profile: settings.shortcuts[0], frontPID: nil, displayID: nil, query: query).map(\.id)
        }
        check(order([window("重庆"), window("chongqing notes")], "chongqing") == ["chongqing notes", "重庆"], "名称直接匹配排在多音字前面")
        check(order([window("微小信息"), window("微信")], "微xin").first == "微信", "混合输入连续匹配")
        check(order([window("Chrome 帮助"), window("Chrome")], "chrm").count == 2 && order([window("Chrome"), window("charm")], "chrm") == ["charm", "Chrome"], "拼写容错排在跳字匹配前面")

        // Skipping characters.
        check(finds("Chrome", "chrm") && finds("Safari", "sfri") && finds("Visual Studio Code", "vscode"), "跳字匹配：英文")
        check(finds("文件管理器", "wjq") && finds("文件管理器", "wjglq") && finds("文件管理器", "文管q"), "跳字匹配：中文")
        check(!finds("Chrome", "crm") && !finds("Safari", "sar"), "三个字母必须都是词的开头，否则太容易误中")
        check(finds("PowerPoint Tools", "ppt"), "大小写分开的单词也算词的开头")
        check(!finds("Safari", "afri"), "跳字匹配必须从词的开头开始")
        check(!finds("Another long window title that goes on and on before here bcdefg", "abcd"), "相隔太远的字不算跳字匹配")
        check(!WindowSearch.matches(window("Chrome"), query: "chrm", skips: false), "可以关闭跳字匹配")
        check(WindowSearch.matchKind(window("Chrome"), query: "chrm") == .skipped && MatchKind.skipped.label == "跳字匹配", "跳字匹配有自己的说明")
        check(WindowSearch.highlights(in: "Chrome", query: "chrm") == [0..<3, 4..<5], "跳字匹配高亮用到的字")
        check(WindowSearch.highlights(in: "Chrome", query: "chrm", skips: false).isEmpty, "关闭跳字匹配后不高亮")
        check(!finds(String(repeating: "a", count: 1000), "aaaaaaaaab") && !finds(String(repeating: "重", count: 1000), "chongzhongchongzhongx"), "很长且重复的标题也能很快判断")
        check(finds(String(repeating: "x", count: 300) + "微信", "xxx") && !finds(String(repeating: "x", count: 300) + "微信", "微xin"), "超长标题只看前面一段")

        // Double pinyin.
        func codes(_ syllable: String, _ scheme: ShuangpinScheme) -> [String] { Shuangpin.codes(for: syllable, scheme: scheme) }
        check(codes("wei", .xiaohe) == ["ww"] && codes("xin", .xiaohe) == ["xb"] && codes("shou", .xiaohe) == ["uz"] && codes("jian", .xiaohe) == ["jm"] && codes("xiang", .xiaohe) == ["xl"], "小鹤双拼的韵母")
        check(codes("zhong", .xiaohe) == ["vs"] && codes("chuang", .xiaohe) == ["il"] && codes("shuai", .xiaohe) == ["uk"] && codes("ming", .xiaohe) == ["mk"], "小鹤双拼的声母")
        check(codes("a", .xiaohe) == ["aa"] && codes("ang", .xiaohe) == ["ah"] && codes("eng", .xiaohe) == ["eg"] && codes("o", .xiaohe) == ["oo"], "小鹤双拼的零声母")
        check(Set(codes("ai", .xiaohe)) == ["ad", "ai"] && Set(codes("ou", .xiaohe)) == ["oz", "ou"] && codes("er", .xiaohe) == ["er"], "小鹤双拼的两字母音节")
        check(Set(codes("ju", .xiaohe)) == ["ju", "jv"] && codes("lv", .xiaohe) == ["lv"] && codes("lve", .xiaohe) == ["lt"] && codes("nue", .xiaohe) == ["nt"], "小鹤双拼的 ü")
        check(codes("wei", .ziranma) == ["wz"] && codes("xin", .ziranma) == ["xn"] && codes("shou", .ziranma) == ["ub"] && codes("xiang", .ziranma) == ["xd"] && codes("ming", .ziranma) == ["my"], "自然码的韵母")
        check(codes("dui", .ziranma) == ["dv"] && codes("hua", .ziranma) == ["hw"] && codes("hun", .ziranma) == ["hp"] && codes("ao", .ziranma).contains("ak"), "自然码的其他韵母")
        check(codes("wei", .microsoft) == ["wz"] && codes("ming", .microsoft) == ["m;"] && codes("lv", .microsoft) == ["ly"] && Set(codes("lve", .microsoft)) == ["lt", "lv"], "微软双拼")
        check(Set(codes("a", .microsoft)) == ["oa", "aa"] && Set(codes("er", .microsoft)) == ["or", "er"] && codes("ai", .microsoft).contains("ol"), "微软双拼的零声母")
        check(codes("ng", .xiaohe).isEmpty && codes("", .xiaohe).isEmpty && codes("wei", .off).isEmpty, "没有对应按键的音节不产生编码")
        check(!finds("微信", "wwxb"), "默认不把输入当作双拼")
        check(WindowSearch.matches(window("微信"), query: "wwxb", shuangpin: .xiaohe) && WindowSearch.matches(window("微信"), query: "wzxn", shuangpin: .ziranma) && WindowSearch.matches(window("微信"), query: "wzxn", shuangpin: .microsoft), "三种双拼都能找到微信")
        check(!WindowSearch.matches(window("微信"), query: "wzxn", shuangpin: .xiaohe), "只认选中的双拼方案")
        check(WindowSearch.matches(window("收件箱"), query: "uzjmxl", shuangpin: .xiaohe) && WindowSearch.matches(window("中文"), query: "vswf", shuangpin: .xiaohe), "小鹤双拼能找到更长的名称")
        check(WindowSearch.matches(window("微信"), query: "微xb", shuangpin: .xiaohe) && WindowSearch.matches(window("微信"), query: "weixin", shuangpin: .xiaohe), "选了双拼仍然可以用汉字和全拼")
        check(WindowSearch.matches(window("重庆"), query: "isqk", shuangpin: .xiaohe) && WindowSearch.matches(window("重庆"), query: "vsqk", shuangpin: .xiaohe) && WindowSearch.matches(window("重庆"), query: "isqy", shuangpin: .ziranma), "多音字的每个读音都有双拼")
        check(WindowSearch.highlights(in: "微信", query: "wwxb", shuangpin: .xiaohe) == [0..<2] && WindowSearch.highlights(in: "微信", query: "wwxb").isEmpty, "双拼高亮对应的汉字，同一段文字不受其他方案影响")
        check(WindowSearch.matchKind(window("微信"), query: "wwxb", shuangpin: .xiaohe) == .pinyin, "双拼显示为拼音")

        // Settings.
        check(AdvancedSettings().searchSkips && AdvancedSettings().shuangpin == .off, "默认开启跳字匹配，不使用双拼")
        var plain = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(AdvancedSettings())) as! [String: Any]
        plain.removeValue(forKey: "searchSkips"); plain.removeValue(forKey: "shuangpin")
        let old = try! JSONDecoder().decode(AdvancedSettings.self, from: JSONSerialization.data(withJSONObject: plain))
        check(old.searchSkips && old.shuangpin == .off, "旧设置没有这两项时采用默认值")
        var chosen = AdvancedSettings(); chosen.searchSkips = false; chosen.shuangpin = .ziranma
        check(try! JSONDecoder().decode(AdvancedSettings.self, from: JSONEncoder().encode(chosen)) == chosen, "搜索方式保存后不变")
        check(order([window("微信")], "wwxb") == [] && order([window("微信")], "wwxb", { $0.shuangpin = .xiaohe }) == ["微信"], "选了双拼方案后搜索结果跟着变")
        check(order([window("Chrome")], "chrm") == ["Chrome"] && order([window("Chrome")], "chrm", { $0.searchSkips = false }) == [], "关闭跳字匹配后搜索结果跟着变")
        check(SettingSearchIndex.results("双拼").first?.section == 1 && SettingSearchIndex.results("跳字").first?.section == 1, "设置搜索可以找到新选项")
    }
    static func verifyDockPreviewExtras() {
        func window(_ id: String, minimized: Bool = false, hidden: Bool = false, here: Bool = true, frame: WindowRect? = WindowRect(x: 10, y: 20, width: 800, height: 600)) -> WindowDescriptor {
            var d = WindowDescriptor(id: id, windowID: 7, pid: 1, appName: "应用", bundleID: "a", title: id, minimized: minimized, hidden: hidden, onCurrentSpace: here, displayID: 1, aspectRatio: 1.5)
            d.frame = frame
            return d
        }
        // Settings.
        check(DockPreviewSettings().liveThumbnails && DockPreviewSettings().peekWindow, "实时更新和窗口位置预览默认开启")
        let old = try! JSONDecoder().decode(DockPreviewSettings.self, from: Data(#"{"enabled":false,"delay":150,"includeMinimized":false}"#.utf8))
        check(!old.enabled && old.delay == 150 && !old.includeMinimized && old.liveThumbnails && old.peekWindow, "旧设置没有新字段时保留原值，新开关采用默认值")
        var off = DockPreviewSettings(); off.liveThumbnails = false; off.peekWindow = false
        let back = try! JSONDecoder().decode(DockPreviewSettings.self, from: JSONEncoder().encode(off))
        check(back == off, "关掉的开关保存后仍然是关的")

        // Live pictures.
        let p = DockPreviewPolicy.self
        let cards = [window("a"), window("b"), window("c")]
        check(p.dueForRefresh(cards, hovered: nil, capturedAt: ["a": 100, "b": 100, "c": 100], now: 101).isEmpty, "刚读过的预览图不会马上再读")
        check(p.dueForRefresh(cards, hovered: "b", capturedAt: ["a": 100, "b": 100, "c": 100], now: 101) == ["b"], "指针下的窗口每秒更新，其他窗口要等更久")
        check(p.dueForRefresh(cards, hovered: nil, capturedAt: ["a": 100, "b": 99, "c": 97], now: 103) == ["c", "b", "a"], "等得最久的窗口先更新")
        check(p.dueForRefresh(cards, hovered: "a", capturedAt: ["a": 90, "b": 80, "c": 70], now: 100).first == "a", "指针下的窗口排在等得更久的窗口之前")
        check(p.dueForRefresh(cards, hovered: nil, capturedAt: [:], now: 100).count == 3, "没读过的窗口也会更新")
        let many = (0..<12).map { window("w\($0)") }
        check(p.dueForRefresh(many, hovered: nil, capturedAt: [:], now: 100).count == p.perTick, "窗口再多，每次也只读有限的几个")
        let quiet = [window("mini", minimized: true), window("hid", hidden: true), window("away", here: false)]
        check(p.dueForRefresh(quiet, hovered: "mini", capturedAt: [:], now: 100).isEmpty, "最小化、隐藏和其他桌面的窗口保留原来的画面")
        var noID = WindowDescriptor(id: "x", windowID: nil, pid: 1, appName: "应用", bundleID: "a", title: "x", minimized: false, hidden: false, onCurrentSpace: true, displayID: 1, aspectRatio: 1.5)
        check(p.dueForRefresh([noID], hovered: "x", capturedAt: [:], now: 100).isEmpty, "没有窗口编号的条目无法更新")

        // The window at its own place.
        check(p.peekFrame(of: window("a")) == WindowRect(x: 10, y: 20, width: 800, height: 600), "画面显示在窗口原来的位置")
        check(p.peekFrame(of: window("a", minimized: true)) == nil, "最小化的窗口不显示")
        check(p.peekFrame(of: window("a", hidden: true)) == nil, "隐藏的窗口不显示")
        check(p.peekFrame(of: window("a", here: false)) == nil, "其他桌面的窗口不显示")
        check(p.peekFrame(of: window("a", frame: nil)) == nil, "不知道位置的窗口不显示")
        check(p.peekFrame(of: window("a", frame: WindowRect(x: 0, y: 0, width: 20, height: 20))) == nil, "太小的窗口不显示")
        noID.frame = WindowRect(x: 0, y: 0, width: 400, height: 400)
        check(p.peekFrame(of: noID) == nil, "没有窗口编号的条目读不到画面，不显示")

        // Middle click.
        check(p.middleClickTarget(down: "a", up: "a") == "a", "在同一张卡片上按下和松开算一次中键点按")
        check(p.middleClickTarget(down: "a", up: "b") == nil, "按下和松开不在同一张卡片上不关闭")
        check(p.middleClickTarget(down: nil, up: "a") == nil, "按下时不在卡片上不关闭")
        check(p.middleClickTarget(down: "a", up: nil) == nil, "松开时不在卡片上不关闭")

        // A window that changes state stays in the list.
        check(p.sameCards([window("a")], [window("a")]), "没有变化时不重新排版")
        check(!p.sameCards([window("a")], [window("a", minimized: true)]), "窗口最小化后卡片要更新")
        check(!p.sameCards([window("a")], [window("a", hidden: true)]), "应用隐藏后卡片要更新")
        check(!p.sameCards([window("a"), window("b")], [window("a")]), "窗口关闭后卡片要更新")

        // Findable in settings.
        check(SettingSearchIndex.results("实时更新预览图").first?.section == 3 && SettingSearchIndex.results("悬停时在窗口原来的位置显示它").first?.section == 3, "新开关可以在设置搜索里找到")
    }
    static func verifySearchHabits() {
        let day = 86_400.0, start = 1_000_000.0, a = "app:a", b = "app:b"
        func taught(_ choices: [(query: String, target: String)]) -> SearchHabits {
            var habits = SearchHabits()
            for choice in choices { habits.record(query: choice.query, target: choice.target, now: start) }
            return habits
        }
        func repeated(_ count: Int, _ target: String, _ query: String = "wx") -> [(query: String, target: String)] {
            Array(repeating: (query: query, target: target), count: count)
        }
        check(taught(repeated(1, a)).scores(for: "wx", now: start).isEmpty, "选一次可能是手滑，不改变排序")
        check(taught(repeated(2, a)).scores(for: "wx", now: start)[a] != nil, "同一个搜索选两次后排到前面")
        check(taught(repeated(2, a) + repeated(1, b)).scores(for: "wx", now: start).isEmpty, "改选别的结果后，旧习惯先退下来")
        let changed = taught(repeated(10, a) + repeated(2, b)).scores(for: "wx", now: start)
        check((changed[b] ?? 0) > (changed[a] ?? 0), "用了很久的习惯，改选两次后也会让位")

        let light = taught(repeated(2, a)), strong = taught(repeated(10, a))
        check(light.scores(for: "wx", now: start + 10 * day)[a] != nil, "几天不用，习惯还在")
        check(light.scores(for: "wx", now: start + 30 * day).isEmpty && strong.scores(for: "wx", now: start + 30 * day)[a] != nil, "只选过两次的忘得快，选过很多次的留得久")
        check(strong.scores(for: "wx", now: start + 120 * day).isEmpty, "很久不用的习惯会被忘掉")
        check(light.scores(for: "wx", now: start - 30 * day)[a] == light.scores(for: "wx", now: start)[a], "时钟被调回去时，习惯不会变强")

        check(taught(repeated(4, a, "chrome")).scores(for: "ch", now: start)[a] != nil, "输入全名选得多了，输入开头几个字也算")
        check(taught(repeated(3, a, "chrome")).scores(for: "ch", now: start).isEmpty, "只算一部分：较短的搜索要选得更多才生效")
        check(taught(repeated(4, a, "ch")).scores(for: "chrome", now: start)[a] != nil, "输入开头几个字选得多了，输入全名也算")
        let both = taught(repeated(10, a, "ch") + repeated(10, b, "chess")).scores(for: "ch", now: start)
        check((both[a] ?? 0) > (both[b] ?? 0), "正好是这个搜索选的，比更长的搜索选的更算数")
        check(taught(repeated(10, a)).scores(for: "mail", now: start).isEmpty, "不相关的搜索不受影响")
        check(taught(repeated(10, a)).scores(for: "", now: start).isEmpty && taught(repeated(10, a)).scores(for: "   ", now: start).isEmpty, "没有输入时没有习惯")
        check(taught(repeated(2, a, "  WX ")).scores(for: "wx", now: start)[a] != nil, "忽略大小写和首尾空格")
        check(taught(repeated(2, a, "Wei  Xin")).scores(for: "wei xin", now: start)[a] != nil, "多个空格算一个")

        check(taught(repeated(2, a, String(repeating: "x", count: SearchHabits.longestQuery))).count == 1, "普通长度的搜索会记住")
        check(taught(repeated(2, a, String(repeating: "x", count: SearchHabits.longestQuery + 1))).count == 0, "粘贴的长文本不写进本机存储")
        check(taught(repeated(2, a, "   ")).count == 0, "空白不记录")
        var crowded = SearchHabits()
        for index in 0..<(SearchHabits.queryLimit + 3) { crowded.record(query: "q\(index)", target: a, now: start + Double(index)) }
        check(crowded.count == SearchHabits.queryLimit, "记住的搜索有上限")
        check(crowded.queries["q0"] == nil && crowded.queries["q\(SearchHabits.queryLimit + 2)"] != nil, "超过上限时忘掉最久没用的")
        var busy = SearchHabits()
        for index in 0..<(SearchHabits.targetLimit + 3) { busy.record(query: "wx", target: "app:\(index)", now: start) }
        check(busy.queries["wx"]?.count == SearchHabits.targetLimit, "一个搜索记住的结果有上限")
        check(busy.queries["wx"]?["app:\(SearchHabits.targetLimit + 2)"] != nil, "刚选的结果一定留下")
        let saved = try! JSONEncoder().encode(strong)
        let restored = SearchHabits.decoded(saved)
        check(restored.count == 1 && restored.scores(for: "wx", now: start)[a] != nil, "保存后读回来还在")
        check(SearchHabits.decoded(Data("不是 JSON".utf8)).count == 0 && SearchHabits.decoded(nil).count == 0, "读不出来时从空开始，不影响启动")

        func window(_ id: String, app: String, bundle: String, title: String) -> WindowDescriptor {
            WindowDescriptor(id: id, windowID: nil, pid: 1, appName: app, bundleID: bundle, title: title, minimized: false, hidden: false,
                             onCurrentSpace: true, displayID: 1, aspectRatio: 1.6)
        }
        let wechat = window("cg:1", app: "微信", bundle: "app.wechat", title: "微信"), notes = window("cg:2", app: "备忘录", bundle: "app.notes", title: "wx-notes")
        check(SearchHabits.target(of: wechat) == "app:app.wechat", "窗口按应用记住，不记标题和窗口编号")
        var tab = wechat; tab.browserTab = true
        check(SearchHabits.target(of: tab) == "app:app.wechat", "标签页也按应用记住，不记网址")
        var opener = window("launch:app:app.wx", app: "wx 工具", bundle: "app.wx", title: "wx 工具"); opener.launcher = .app
        check(SearchHabits.target(of: opener) == "app:app.wx", "没打开的应用和打开后的窗口算同一个")
        var page = window("launch:setting:wifi", app: "设置", bundle: "wifi", title: "无线局域网"); page.launcher = .setting
        check(SearchHabits.target(of: page) == "launch:setting:wifi", "设置页面按自己记住")
        var icon = window("menubar:clock", app: "时钟", bundle: "app.clock", title: "时钟"); icon.menuBarItem = true
        check(SearchHabits.target(of: icon) == "menubar:clock", "菜单栏图标按自己记住")
        check(SearchHabits.target(of: window("cg:9", app: "无标识", bundle: "", title: "x")) == nil, "没有应用标识的窗口不记")

        let settings = UserSettings.defaults, profile = settings.shortcuts[0]
        func found(_ windows: [WindowDescriptor], _ query: String, _ learned: [String: Double] = [:]) -> [String] {
            WindowSearch.filtered(windows, settings: settings, profile: profile, frontPID: nil, displayID: 1, query: query, learned: learned).map(\.id)
        }
        check(found([wechat, notes], "wx") == ["cg:2", "cg:1"], "没有习惯时，名称直接匹配排在拼音首字母之前")
        check(found([wechat, notes], "wx", ["app:app.wechat": 1.7]) == ["cg:1", "cg:2"], "常选的结果排到最前，哪怕名称匹配更弱")
        check(found([notes, wechat], "", ["app:app.wechat": 1.7]) == ["cg:2", "cg:1"], "没有输入时，习惯不影响切换顺序")
        let mail = window("cg:3", app: "邮件", bundle: "app.mail", title: "邮件")
        check(found([mail, notes], "wx", ["app:app.mail": 9]) == ["cg:2"], "常选的结果不匹配这次搜索时不会出现")
        let first = window("cg:4", app: "甲", bundle: "app.first", title: "wx 甲"), second = window("cg:5", app: "乙", bundle: "app.second", title: "wx 乙")
        check(found([first, second], "wx", ["app:app.first": 1.6, "app:app.second": 2]) == ["cg:5", "cg:4"], "都常选时，选得多的在前")
        check(found([notes, opener], "wx").first == "cg:2", "没有习惯时，已打开的窗口排在要打开的应用之前")
        check(found([notes, opener], "wx", ["app:app.wx": 1.7]).first == opener.id, "常选的应用即使没打开也排到前面")
        var openers = (0..<WindowSearch.launcherLimit).map { index -> WindowDescriptor in
            var item = window("launch:app:more\(index)", app: "wx\(index)", bundle: "more\(index)", title: "wx\(index)"); item.launcher = .app; return item
        }
        var longName = window("launch:app:long", app: "wx 名字很长的工具", bundle: "app.long", title: "wx 名字很长的工具"); longName.launcher = .app
        openers.append(longName)
        check(!found(openers, "wx").contains("launch:app:long"), "要打开的应用太多时，名字长的排不进去")
        check(found(openers, "wx", ["app:app.long": 1.7]).first == "launch:app:long", "常选的应用不会被上限挤掉")

        check(AdvancedSettings().searchLearning, "默认把常选的结果排到前面")
        let older = try? JSONDecoder().decode(AdvancedSettings.self, from: Data("{}".utf8))
        check(older?.searchLearning == true, "旧版本的设置升级后也开启")
        var off = AdvancedSettings(); off.searchLearning = false
        let reloaded = try? JSONDecoder().decode(AdvancedSettings.self, from: JSONEncoder().encode(off))
        check(reloaded?.searchLearning == false, "关闭后保存下来")
        check(SettingSearchIndex.results("常选").first?.section == 1 && SettingSearchIndex.results("搜索记录").first?.title == "把常选的结果排到前面", "设置搜索可以找到这个开关")
    }
    /// Runs the real scripts in JavaScriptCore against stand-ins for each kind of browser. This proves the scripts parse
    /// and take the right path; only a Mac with the browsers installed can prove the browsers answer the same way.
    static func verifyBrowserScripts() {
        let stubs = #"""
        var requested = '', selected = '', raised = false, activated = false, hacked = false;
        function evil() { hacked = true; }
        function tabList(list) {
          const tabs = list.map(t => ({ select() { selected = t.title; } }));
          tabs.title = () => list.map(t => t.title);
          tabs.name = tabs.title;
          tabs.url = () => list.map(t => t.url);
          tabs.id = () => list.map(t => t.id);
          return tabs;
        }
        function plain(id, list, stuck) {
          const w = { id: () => id, tabs: tabList(list) };
          Object.defineProperty(w, 'index', { set() { if (stuck) throw new Error('stuck'); raised = true; } });
          return w;
        }
        function chromium(id, active, list, stuck) {
          const w = plain(id, list, stuck);
          Object.defineProperty(w, 'activeTabIndex', { get: () => () => active, set(v) { selected = list[v - 1].title; } });
          return w;
        }
        function arc(id, activeID, list) {
          const w = plain(id, list);
          w.activeTab = { id: () => activeID };
          return w;
        }
        function safari(id, active, list) {
          const w = plain(id, list);
          Object.defineProperty(w, 'currentTab', { get: () => ({ index: () => active }), set(tab) { selected = list[w.tabs.indexOf(tab)].title; } });
          return w;
        }
        function Application(id) {
          requested = id;
          return { windows: () => windows, activate() { activated = true; } };
        }
        var sample = [{ id: 'x', title: '甲', url: 'u1' }, { id: 'y', title: '乙', url: 'u2' }, { id: 'z', title: '丙', url: '' }];
        """#
        func run(_ script: String?, windows: String) -> (answer: String, selected: String, raised: Bool, activated: Bool, requested: String, hacked: Bool) {
            guard let script, let context = JSContext() else { return ("没有脚本", "", false, false, "", false) }
            context.evaluateScript(stubs)
            context.evaluateScript("var windows = [\(windows)];")
            let answer = context.evaluateScript(script)
            if let failure = context.exception { return ("脚本出错：\(failure)", "", false, false, "", false) }
            func text(_ name: String) -> String { context.objectForKeyedSubscript(name)?.toString() ?? "" }
            return (answer?.toString() ?? "", text("selected"), text("raised") == "true", text("activated") == "true", text("requested"), text("hacked") == "true")
        }
        func listing(_ windows: String, bundleID: String = "b", chromium: Bool = true) -> String {
            let answer = run(BrowserTabScript.list(bundleID: bundleID, chromium: chromium), windows: windows).answer
            let decoded = try? JSONDecoder().decode([BrowserWindowTabs].self, from: Data(answer.utf8))
            return (decoded ?? []).map { window -> String in
                let titles = window.titles.map { $0 ?? "空" }.joined(separator: ",")
                let urls = window.urls.map { $0 ?? "空" }.joined(separator: ",")
                return "\(window.id)|\(window.active)|\(titles)|\(urls)"
            }.joined(separator: ";")
        }
        let tabs = "甲,乙,丙|u1,u2,"
        check(listing("chromium('w1', 2, sample)") == "w1|2|\(tabs)", "Chromium：窗口编号是文本时也能读出标签页")
        check(listing("chromium(7, 1, sample)") == "7|1|\(tabs)", "较旧的 Chromium：窗口编号是数字时同样能读")
        check(listing("arc('w1', 'y', sample)") == "w1|2|\(tabs)", "Arc：没有当前标签页序号，用当前标签页的编号算出来")
        check(listing("safari(9, 3, sample)", chromium: false) == "9|3|\(tabs)", "Safari 仍然用它自己的接口")
        check(listing("arc('w1', 'none', sample)") == "w1|0|\(tabs)", "找不到当前标签页时记为 0，所有标签页都列出")
        check(listing("plain('w1', sample)") == "w1|0|\(tabs)", "连当前标签页都不提供的浏览器，所有标签页也都列出")
        check(listing("{ id() { throw new Error('closing'); } }, chromium('w2', 1, sample)") == "w2|1|\(tabs)", "读不出的窗口被跳过，不影响其他窗口")
        check(listing("") == "", "没有窗口时列表为空")

        func activate(_ windows: String, windowID: String = "w1", index: Int = 2, url: String = "u2", title: String = "乙", chromium: Bool = true) -> (answer: String, selected: String, raised: Bool, activated: Bool, requested: String, hacked: Bool) {
            run(BrowserTabScript.activate(bundleID: "b", windowID: windowID, tabIndex: index, url: url, title: title, chromium: chromium), windows: windows)
        }
        let direct = activate("chromium('w1', 1, sample)")
        check(direct.answer == "ok" && direct.selected == "乙", "Chromium：用序号切换标签页")
        check(direct.raised && direct.activated, "切换后窗口到最前，浏览器到前台")
        check(activate("arc('w1', 'x', sample)").selected == "乙", "Arc：没有序号时用 select 切换")
        check(activate("safari('w1', 1, sample)", chromium: false).selected == "乙", "Safari：用 currentTab 切换")
        check(activate("chromium(7, 1, sample)", windowID: "7").answer == "ok", "数字编号的窗口也能按文本找到")
        check(activate("chromium('w0', 1, sample), chromium('w1', 1, sample)").answer == "ok", "在多个窗口里找到对应的那个")
        check(activate("chromium('w1', 1, sample, true)").answer == "ok", "窗口提不到最前也算切换成功")
        check(activate("chromium('w1', 1, sample)", index: 1).selected == "乙", "标签页移动后按网址找到")
        check(activate("chromium('w1', 1, sample)", index: 1, url: "changed", title: "甲").selected == "甲", "网址也变了时按标题找到")
        check(activate("safari('w1', 1, sample)", index: 1, url: "changed", title: "丙", chromium: false).selected == "丙", "Safari 按标题找时用它自己的接口")
        check(activate("chromium('w1', 1, sample)", index: 3, url: "").selected == "丙", "没有网址的标签页也能按位置切换")
        let closed = activate("chromium('w1', 1, sample)", index: 1, url: "changed", title: "没有")
        check(closed.answer == "gone" && closed.selected.isEmpty && !closed.activated, "标签页已经关闭时如实报告，不切换")
        check(activate("chromium('w1', 1, sample)", url: "changed", title: "").answer == "gone", "没有标题时不会误配空标题")
        let noWindow = activate("chromium('w1', 1, sample)", windowID: "w9")
        check(noWindow.answer == "gone" && !noWindow.activated, "窗口已经关闭时如实报告")

        for hostile in ["x'); evil(); ('", "\"); evil(); (\"", "`${evil()}`", "\\\"); evil(); //"] {
            let listed = run(BrowserTabScript.list(bundleID: hostile, chromium: true), windows: "")
            check(!listed.hacked && listed.requested == hostile, "应用标识来自别的应用，只能作为字符串进入脚本")
            let chosen = run(BrowserTabScript.activate(bundleID: hostile, windowID: hostile, tabIndex: 1, url: hostile, title: hostile, chromium: true), windows: "chromium('w1', 1, sample)")
            check(!chosen.hacked && chosen.requested == hostile && chosen.answer == "gone", "窗口编号、网址和标题也不能变成代码")
        }

        let dictionary = #"<class name="window"><property name="active tab" code="acTa"/><property name="active tab index" code="acTI"/></class><class name="tab" code="CrTb"><property name="URL" code="URL "/></class>"#
        check(BrowserTabScript.offersChromiumTabs(dictionary: dictionary), "提供 Chromium 脚本接口的应用算浏览器")
        check(!BrowserTabScript.offersChromiumTabs(dictionary: #"<class name="tab"><property name="URL"/><property name="current tab"/></class>"#), "Safari 式的接口不走 Chromium 脚本")
        check(!BrowserTabScript.offersChromiumTabs(dictionary: #"<class name="tab"><property name="selected tab"/></class>"#), "终端这类有标签页但没有网址的应用不算")
        check(!BrowserTabScript.offersChromiumTabs(dictionary: ""), "没有脚本接口的应用不算")
    }
    static func verifyRecentOrder() {
        func window(_ id: String, pid: Int32, bundle: String, title: String = "机密标题") -> WindowDescriptor {
            WindowDescriptor(id: id, windowID: nil, pid: pid, appName: "应用", bundleID: bundle, title: title, minimized: false, hidden: false,
                             onCurrentSpace: true, displayID: 1, aspectRatio: 1.6)
        }
        let safari = "com.apple.Safari", mail = "com.apple.mail"
        let listed = [window("cg:10", pid: 100, bundle: safari), window("cg:20", pid: 200, bundle: mail),
                      window("ax:100:7", pid: 100, bundle: safari), window("cg:30", pid: 100, bundle: safari)]
        let focus = ["cg:10": 300.0, "cg:20": 400.0, "ax:100:7": 500.0, "100|机密标题": 600.0, "cg:99": 700.0]
        let order = RecentOrderPolicy.snapshot(focus: focus, windows: listed, apps: [mail: 450, "com.apple.Notes": 50], previous: RecentOrder())
        check(order.windows.map(\.id) == ["cg:20", "cg:10"], "只保存有窗口编号、用过而且还开着的窗口，最近的在前")
        check(order.windows[0] == RecentOrder.WindowUse(id: "cg:20", pid: 200, bundleID: mail, time: 400), "记下进程和应用，重启后才能确认还是同一个窗口")
        check(order.apps == [safari: 500, mail: 450, "com.apple.Notes": 50], "应用的时间取窗口和应用里最近的一次，没在运行的应用也留着")
        let saved = try! JSONEncoder().encode(order)
        check(!String(decoding: saved, as: UTF8.self).contains("机密"), "窗口标题不写进本机存储")
        check(RecentOrderPolicy.decoded(saved) == order, "保存后读回来不变")
        check(RecentOrderPolicy.decoded(Data("不是 JSON".utf8)) == RecentOrder() && RecentOrderPolicy.decoded(nil) == RecentOrder(), "读不出来时从空开始，不影响启动")
        check(RecentOrderPolicy.snapshot(focus: [:], windows: [], apps: [:], previous: order).windows == order.windows, "还没读到窗口时不丢掉上次保存的窗口")
        check(RecentOrderPolicy.snapshot(focus: [:], windows: listed, apps: [:], previous: order).windows.isEmpty, "读到窗口后，已经关闭的窗口不再保存")

        let many = (0..<(RecentOrderPolicy.windowLimit + 5)).map { window("cg:\($0)", pid: 1, bundle: "app.\($0)") }
        let manyFocus = Dictionary(uniqueKeysWithValues: many.enumerated().map { ($0.element.id, Double($0.offset + 1)) })
        let capped = RecentOrderPolicy.snapshot(focus: manyFocus, windows: many, apps: [:], previous: RecentOrder())
        check(capped.windows.count == RecentOrderPolicy.windowLimit && capped.windows.first?.id == many.last?.id && !capped.windows.contains(where: { $0.id == "cg:0" }), "窗口超过上限时留下最近用过的")
        check(capped.apps.count == RecentOrderPolicy.appLimit && capped.apps["app.0"] == nil && capped.apps[many[many.count - 1].bundleID] != nil, "应用超过上限时留下最近用过的")
        check(RecentOrderPolicy.snapshot(focus: ["cg:1": 5], windows: [window("cg:1", pid: 1, bundle: "")], apps: ["": 9, "zero": 0], previous: RecentOrder()).apps.isEmpty, "没有应用标识或没有时间的不保存")

        let running: [Int32: String] = [100: safari, 200: mail]
        let earlier = RecentOrder(windows: [
            .init(id: "cg:10", pid: 100, bundleID: safari, time: 300),
            .init(id: "cg:20", pid: 201, bundleID: mail, time: 400),
            .init(id: "cg:21", pid: 200, bundleID: "com.apple.Notes", time: 410),
            .init(id: "cg:22", pid: 999, bundleID: "gone", time: 420),
            .init(id: "cg:23", pid: 100, bundleID: safari, time: 900),
            .init(id: "cg:24", pid: 100, bundleID: safari, time: 0)], apps: [mail: 450, "": 460, "late": 900, "zero": 0])
        check(RecentOrderPolicy.restoredFocus(earlier, runningApps: running, now: 500) == ["cg:10": 300, "cg:23": 500], "只认同一进程、同一应用的窗口；进程换了或编号被重用都不算；超前的时间不超过现在")
        check(RecentOrderPolicy.restoredApps(earlier, now: 500) == [mail: 450, "late": 500], "应用时间同样不超过现在，无效的丢弃")

        let known = window("cg:10", pid: 100, bundle: safari, title: "甲")
        func used(focus: [String: Double] = [:], activated: [Int32: Double] = [:], apps: [String: Double] = [:]) -> Double {
            RecentOrderPolicy.lastFocused(known, focus: focus, activated: activated, apps: apps)
        }
        check(used(focus: ["cg:10": 4, "100|甲": 3], activated: [100: 2], apps: [safari: 1]) == 4, "窗口自己的记录优先")
        check(used(focus: ["100|甲": 3], activated: [100: 2], apps: [safari: 1]) == 3, "其次是按标题记下的这次运行里的记录")
        check(used(activated: [100: 2], apps: [safari: 1]) == 2, "然后是应用这次运行里的激活时间")
        check(used(apps: [safari: 1]) == 1, "最后是应用以前保存的时间")
        check(used() == 0, "从没用过的排在最后")

        let settings = UserSettings.defaults, profile = settings.shortcuts[0]
        func relisted(_ windows: [WindowDescriptor], from before: RecentOrder, running: [Int32: String]) -> [String] {
            let restored = RecentOrderPolicy.restoredFocus(before, runningApps: running, now: 1000), apps = RecentOrderPolicy.restoredApps(before, now: 1000)
            let timed = windows.map { item -> WindowDescriptor in
                var copy = item
                copy.lastFocused = RecentOrderPolicy.lastFocused(item, focus: restored, activated: [:], apps: apps)
                return copy
            }
            return WindowSearch.filtered(timed, settings: settings, profile: profile, frontPID: nil, displayID: 1, query: "").map(\.id)
        }
        let current = [window("cg:1", pid: 1, bundle: "app.a"), window("cg:2", pid: 2, bundle: "app.b"), window("cg:3", pid: 2, bundle: "app.b")]
        let before = RecentOrderPolicy.decoded(try! JSONEncoder().encode(RecentOrderPolicy.snapshot(focus: ["cg:3": 300, "cg:1": 200, "cg:2": 100], windows: current, apps: [:], previous: RecentOrder())))
        check(relisted(current, from: before, running: [1: "app.a", 2: "app.b"]) == ["cg:3", "cg:1", "cg:2"], "只重启一瞥：每个窗口都回到原来的位置")
        let reopened = [window("cg:51", pid: 11, bundle: "app.a"), window("cg:52", pid: 12, bundle: "app.b"), window("cg:53", pid: 12, bundle: "app.b"), window("cg:54", pid: 13, bundle: "app.new")]
        check(relisted(reopened, from: before, running: [11: "app.a", 12: "app.b", 13: "app.new"]) == ["cg:52", "cg:53", "cg:51", "cg:54"], "重启电脑：按应用恢复顺序，没用过的应用排在最后")
    }
    static func verifySettingsEntry() {
        check(SettingsWindowEntry.isOpen(visible: true, minimized: false, setAside: false), "显示着的设置窗口进入列表")
        check(SettingsWindowEntry.isOpen(visible: false, minimized: true, setAside: false), "最小化的设置窗口进入列表")
        check(SettingsWindowEntry.isOpen(visible: false, minimized: false, setAside: true), "面板打开时暂时让开的设置窗口进入列表")
        check(!SettingsWindowEntry.isOpen(visible: false, minimized: false, setAside: false), "关闭的设置窗口不进入列表")
        let frame = WindowRect(x: 100, y: 50, width: 980, height: 740)
        func entry(minimized: Bool = false, isKey: Bool = false, lastFocused: Double = 250) -> WindowDescriptor {
            SettingsWindowEntry.descriptor(pid: 99, bundleID: "com.jethro.windowhop", frame: frame, displayID: 1, minimized: minimized,
                                           isKey: isKey, lastFocused: lastFocused, now: 500)
        }
        func window(_ id: String, pid: Int32, lastFocused: Double) -> WindowDescriptor {
            var descriptor = WindowDescriptor(id: id, windowID: UInt32(pid), pid: pid, appName: "应用\(id)", bundleID: "app.\(id)", title: id, minimized: false, hidden: false,
                                              onCurrentSpace: true, displayID: 1, aspectRatio: 1.6)
            descriptor.lastFocused = lastFocused
            return descriptor
        }
        let plain = entry(), id = SettingsWindowEntry.id
        check(plain.settingsWindow && !plain.searchOnly && !plain.windowless && plain.frame == frame, "列表里的普通一项，不搜索也能看到")
        check(plain.windowID == nil, "没有窗口编号，预览和窗口操作都不会碰它")
        check(plain.lastFocused == 250 && entry(isKey: true).lastFocused == 500, "有键盘时算当前窗口，否则按上次使用的时间")
        let a = window("a", pid: 10, lastFocused: 300), b = window("b", pid: 20, lastFocused: 200)
        var settings = UserSettings.defaults
        var profile = settings.shortcuts[0]
        func ids(_ windows: [WindowDescriptor], front: Int32? = 10, display: UInt32? = 1, query: String = "") -> [String] {
            WindowSearch.filtered(windows, settings: settings, profile: profile, frontPID: front, displayID: display, query: query).map(\.id)
        }
        check(ids([a, b, plain]) == ["a", id, "b"], "按最近使用的时间排在其他窗口之间")
        check(ids([a, b, entry(isKey: true)], front: 99) == [id, "a", "b"], "设置窗口在前台时排第一，⌥Tab 回到最近的其他窗口")
        profile.scope = .currentApp
        check(ids([a, plain], front: 10) == ["a"] && ids([a, plain], front: 99) == [id], "“当前应用”只在一瞥自己在前台时列出它")
        profile.scope = .otherApps
        check(ids([a, plain], front: 99) == ["a"] && ids([a, plain], front: 10) == [id], "“其他应用”遵守同样的规则")
        profile.scope = .all
        profile.currentScreenOnly = true
        check(ids([a, plain], display: 1) == ["a", id] && ids([a, plain], display: 2).isEmpty, "“只显示当前屏幕”也对它生效")
        profile.currentScreenOnly = false
        settings.showMinimized = false
        check(ids([a, entry(minimized: true)]) == ["a"] && ids([a, plain]) == ["a", id], "不显示最小化窗口时，最小化的设置窗口也不显示")
        settings.showMinimized = true
        for query in ["设置", "shezhi", "glance", "settings"] {
            check(WindowSearch.matches(plain, query: query), "搜索“\(query)”能找到设置窗口")
        }
        var page = WindowDescriptor(id: "launch:setting:page", windowID: nil, pid: 0, appName: "设置", bundleID: "page", title: "设置", minimized: false, hidden: false,
                                    onCurrentSpace: true, displayID: nil, aspectRatio: 1.6)
        page.launcher = .setting
        check(ids([page, plain], query: "设置").first == id, "搜索时已经打开的设置窗口排在同名的可打开项之前")
    }
    static func verifyWindowShortcuts() {
        // The second screen is offset, and its size does not divide evenly.
        let screens = [WindowRect(x: 0, y: 25, width: 1440, height: 875), WindowRect(x: 1440, y: 100, width: 1001, height: 601)]
        let window = WindowRect(x: 1500, y: 150, width: 400, height: 300)
        func frame(_ kind: WindowArrangement.Kind) -> WindowRect? { WindowArrangement.frame(kind, window: window, screens: screens) }
        check(frame(.top) == WindowRect(x: 1440, y: 100, width: 1001, height: 300), "上半屏用窗口所在的屏幕，贴着可用区域的顶边")
        check(frame(.bottom) == WindowRect(x: 1440, y: 401, width: 1001, height: 300), "下半屏贴着可用区域的底边")
        check(frame(.topLeft) == WindowRect(x: 1440, y: 100, width: 500, height: 300), "左上四分之一")
        check(frame(.topRight) == WindowRect(x: 1941, y: 100, width: 500, height: 300), "右上四分之一")
        check(frame(.bottomLeft) == WindowRect(x: 1440, y: 401, width: 500, height: 300), "左下四分之一")
        check(frame(.bottomRight) == WindowRect(x: 1941, y: 401, width: 500, height: 300), "右下四分之一")
        check(frame(.leftThird) == WindowRect(x: 1440, y: 100, width: 333, height: 601), "左三分之一")
        check(frame(.centerThird) == WindowRect(x: 1773, y: 100, width: 335, height: 601), "中间三分之一吃掉除不尽的部分，三块之间没有缝")
        check(frame(.rightThird) == WindowRect(x: 2108, y: 100, width: 333, height: 601), "右三分之一")
        check(frame(.center) == WindowRect(x: 1740, y: 250, width: 400, height: 300), "居中不改变窗口大小")
        let oversized = WindowRect(x: 1500, y: 150, width: 3000, height: 2000)
        check(WindowArrangement.frame(.center, window: oversized, screens: screens) == screens[1], "比屏幕大的窗口居中时缩到屏幕以内")
        let commands = WindowLayoutCommand.allCases
        let places: [(WindowLayoutCommand, WindowArrangement.Kind)] = [(.leftHalf, .left), (.rightHalf, .right), (.topHalf, .top), (.bottomHalf, .bottom),
            (.topLeft, .topLeft), (.topRight, .topRight), (.bottomLeft, .bottomLeft), (.bottomRight, .bottomRight),
            (.leftThird, .leftThird), (.centerThird, .centerThird), (.rightThird, .rightThird), (.maximize, .maximize), (.center, .center)]
        check(places.allSatisfy { $0.0.kind == $0.1 } && places.count == commands.count - 1 && WindowLayoutCommand.restore.kind == nil, "每个命令对应正确的位置，还原不对应屏幕上的位置")
        check(commands.allSatisfy { !$0.label.isEmpty } && Set(commands.map(\.label)).count == commands.count, "每个命令有自己的名称")
        check(commands.allSatisfy { WindowLayoutCommand(slot: $0.slot) == $0 } && Set(commands.map(\.slot)).count == commands.count, "快捷键位置和命令一一对应")
        check(WindowLayoutCommand(slot: 0) == nil && WindowLayoutCommand(slot: 1) == nil && WindowLayoutCommand(slot: WindowLayoutCommand.firstSlot + commands.count) == nil, "菜单栏快捷键的位置不会被当成窗口命令")

        // 还原
        let start = WindowRect(x: 10, y: 40, width: 500, height: 400), left = WindowRect(x: 0, y: 25, width: 720, height: 875), right = WindowRect(x: 720, y: 25, width: 720, height: 875)
        var memory = WindowFrameMemory()
        check(memory.original(of: 7) == nil, "没有调整过的窗口没有可还原的位置")
        memory.recordArrangement(of: 7, from: start, to: left)
        check(memory.original(of: 7) == start, "第一次调整时记住原来的位置")
        memory.recordArrangement(of: 7, from: left, to: right)
        check(memory.original(of: 7) == start, "连续调整时，还原回到第一次调整之前")
        memory.recordArrangement(of: 7, from: WindowRect(x: right.x + 2, y: right.y - 2, width: right.width, height: right.height - 1), to: left)
        check(memory.original(of: 7) == start, "只差一两点不算手动移动过")
        let dragged = WindowRect(x: 300, y: 300, width: 640, height: 480)
        memory.recordArrangement(of: 7, from: dragged, to: right)
        check(memory.original(of: 7) == dragged, "手动移动过之后，从新的位置重新开始记")
        memory.forget(7)
        check(memory.original(of: 7) == nil, "还原之后忘记这个位置")
        let limit = UInt32(WindowFrameMemory.limit)
        var crowded = WindowFrameMemory()
        for id in 0..<limit { crowded.recordArrangement(of: id, from: start, to: left) }
        crowded.recordArrangement(of: 0, from: left, to: right)
        crowded.recordArrangement(of: limit, from: start, to: left)
        check(crowded.original(of: 0) == start && crowded.original(of: 1) == nil && crowded.original(of: limit) == start, "记满之后忘记最久没调整的窗口")
        check(WindowArrangement.restored(start, window: window, screens: screens) == start, "原来的屏幕还在时回到原来的位置")
        let gone = WindowRect(x: 5000, y: 100, width: 800, height: 600)
        check(WindowArrangement.restored(gone, window: window, screens: screens) == WindowRect(x: 1540, y: 100, width: 800, height: 600), "原来的屏幕不在了就居中，不把窗口放到看不见的地方")
        check(WindowArrangement.restored(gone, window: window, screens: []) == gone, "读不到屏幕时不改动保存的位置")

        // Settings
        let defaults = WindowShortcutSettings()
        check(!defaults.enabled && defaults.active.isEmpty, "默认关闭，不占用任何全局按键")
        check(defaults.shortcuts.map(\.command) == commands && defaults.shortcuts.allSatisfy { $0.hotkey.enabled && $0.hotkey.isValid }, "每个命令都有可用的默认按键")
        check(Set(defaults.shortcuts.map(\.hotkey.combinationKey)).count == commands.count, "默认按键彼此不同")
        var settings = UserSettings.defaults
        settings.windowShortcuts.enabled = true
        settings.menuBar.toggleHotkey.enabled = true; settings.menuBar.showAllHotkey.enabled = true
        check(settings.validationError() == nil && settings.windowShortcuts.active.count == commands.count, "打开后不和默认方案、菜单栏快捷键冲突")
        var conflicted = UserSettings.defaults
        conflicted.windowShortcuts.enabled = true
        conflicted.windowShortcuts.shortcuts[0].hotkey = MenuBarHotkey(keyCode: 48, modifiers: .option, enabled: true)
        check(conflicted.validationError() != nil, "和切换方案相同的按键不能生效")
        conflicted.windowShortcuts.shortcuts[0].hotkey.enabled = false
        check(conflicted.validationError() == nil && conflicted.windowShortcuts.active.count == commands.count - 1, "关掉这一项后不再冲突，也不再注册")
        conflicted.windowShortcuts.shortcuts[0].hotkey.enabled = true; conflicted.windowShortcuts.enabled = false
        check(conflicted.validationError() == nil, "总开关关闭时不占用按键，也不算冲突")
        var doubled = UserSettings.defaults
        doubled.windowShortcuts.enabled = true
        doubled.windowShortcuts.shortcuts[1].hotkey = doubled.windowShortcuts.shortcuts[0].hotkey
        check(doubled.validationError() != nil, "两个窗口命令不能用同一个按键")
        for invalid in [MenuBarHotkey(keyCode: 0, modifiers: [], enabled: true), MenuBarHotkey(keyCode: 0, modifiers: .shift, enabled: true),
                        MenuBarHotkey(keyCode: KeyChoice.modifierOnly, modifiers: .option, enabled: true)] {
            var bad = UserSettings.defaults
            bad.windowShortcuts.enabled = true
            bad.windowShortcuts.shortcuts[0].hotkey = invalid
            check(bad.validationError() != nil, "窗口快捷键不能占用普通打字按键，也不能只按修饰键")
        }
        var broken = UserSettings.defaults
        broken.windowShortcuts.enabled = true
        broken.windowShortcuts.shortcuts[2].hotkey = MenuBarHotkey(keyCode: 48, modifiers: .option, enabled: true)
        broken.windowShortcuts.shortcuts[3].hotkey = MenuBarHotkey(keyCode: 0, modifiers: [], enabled: true)
        let mended = broken.repaired()
        check(mended.validationError() == nil && mended.windowShortcuts.enabled, "修复后设置有效，总开关不变")
        check(!mended.windowShortcuts.shortcuts[2].hotkey.enabled && !mended.windowShortcuts.shortcuts[3].hotkey.enabled && mended.windowShortcuts.active.count == commands.count - 2, "修复时只关闭冲突或无效的那几项")

        // Saved settings
        var custom = WindowShortcutSettings()
        custom.enabled = true
        custom.shortcuts = [WindowShortcut(command: .center, hotkey: WindowLayoutCommand.leftHalf.defaultHotkey), WindowShortcut(command: .center, hotkey: .toggleDefault)]
        let customData = try? JSONEncoder().encode(custom)
        let decoded = customData.flatMap { try? JSONDecoder().decode(WindowShortcutSettings.self, from: $0) }
        check(decoded?.enabled == true && decoded?.shortcuts.map(\.command) == commands, "读取时补上缺的命令、去掉重复的命令，顺序固定")
        check(decoded?.shortcuts.first(where: { $0.command == .center })?.hotkey == WindowLayoutCommand.leftHalf.defaultHotkey, "保留保存的按键")
        check(decoded?.shortcuts.first(where: { $0.command == .leftHalf })?.hotkey.enabled == false, "补上的命令的默认按键已被占用时先关闭")
        check(decoded?.shortcuts.first(where: { $0.command == .rightHalf })?.hotkey == WindowLayoutCommand.rightHalf.defaultHotkey, "补上的其他命令用默认按键")
        let encoded = (try? JSONEncoder().encode(settings)) ?? Data()
        check((try? JSONDecoder().decode(UserSettings.self, from: encoded))?.windowShortcuts == settings.windowShortcuts, "保存后读回来不变")
        var object = ((try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any]) ?? [:]
        func decodedSettings() -> UserSettings? {
            (try? JSONSerialization.data(withJSONObject: object)).flatMap { try? JSONDecoder().decode(UserSettings.self, from: $0) }
        }
        object.removeValue(forKey: "windowShortcuts")
        check(decodedSettings()?.windowShortcuts == WindowShortcutSettings(), "旧版设置读进来时窗口快捷键保持关闭")
        object["windowShortcuts"] = "坏值"
        check(decodedSettings()?.windowShortcuts == WindowShortcutSettings() && decodedSettings()?.menuBar.toggleHotkey.enabled == true, "这一项损坏时不影响其他设置")
        check(SettingSearchIndex.results("四分屏").first?.title == "启用全局窗口快捷键" && SettingSearchIndex.results("四分屏").first?.section == 1, "设置搜索可以找到全局窗口快捷键")
    }
    static func verifyThreading() {
        // The key tap decides on its own thread, from what the main thread last published.
        var keys = PanelKeySnapshot(held: .option, bindings: PanelBinding.defaults, triggers: UserSettings.defaults.shortcuts)
        check(!PanelKeySnapshot().captures(code: PanelCommand.cancel.defaultCode, flags: []), "主线程还没发布状态时，所有按键都放行")
        check(keys.captures(code: PanelCommand.cancel.defaultCode, flags: []), "面板不是关键窗口时，拦截线程接住 Esc")
        check(keys.captures(code: PanelCommand.confirm.defaultCode, flags: []), "面板不是关键窗口时，拦截线程接住回车")
        check(keys.captures(code: PanelCommand.next.defaultCode, flags: PanelCommand.next.defaultModifiers), "面板不是关键窗口时，拦截线程接住下一项")
        check(!keys.captures(code: 48, flags: .option), "已注册的快捷键走系统路径，拦截线程不抢，避免跳两格")
        check(!keys.captures(code: 0, flags: []), "普通文字不被拦截线程拿走")
        keys.triggers = []
        check(keys.captures(code: 48, flags: .option), "快捷键暂停时，这个组合不再算已注册")
        keys.panelIsKey = true
        check(!keys.captures(code: PanelCommand.confirm.defaultCode, flags: []), "面板是关键窗口时，回车走 AppKit，只处理一次")
        check(keys.captures(code: PanelCommand.cancel.defaultCode, flags: []), "面板是关键窗口时，Esc 仍然能取消")
        keys.panelIsKey = false; keys.searching = true
        check(!keys.captures(code: PanelCommand.confirm.defaultCode, flags: []), "搜索时不把别的应用的回车抢过来")
        check(keys.captures(code: PanelCommand.cancel.defaultCode, flags: []), "搜索时 Esc 仍然能取消")
        keys.searching = false; keys.markedText = true
        check(!keys.captures(code: PanelCommand.cancel.defaultCode, flags: []), "输入法组合文字时，Esc 交给输入法")
        keys.markedText = false; keys.focusInFlight = true
        check(!keys.captures(code: PanelCommand.confirm.defaultCode, flags: []), "切换发出后，回车交给正在到前台的窗口")
        check(!keys.captures(code: PanelCommand.cancel.defaultCode, flags: []), "切换发出后，Esc 也不再拦给要关闭的面板")

        check(FocusFailurePolicy.action(fromCache: true, loading: true) == .waitForFreshList, "按旧列表切换失败、新列表还没到时，等新列表决定")
        check(FocusFailurePolicy.action(fromCache: true, loading: false) == .commitFreshList, "按旧列表切换失败、新列表已到时，按新列表再试一次")
        check(FocusFailurePolicy.action(fromCache: false, loading: false) == .report, "按新列表切换仍失败时，保留面板并说明原因")

        // The waits below hold the main thread, as a slow app would have: the work must get done regardless.
        let thread = BackgroundRunLoop(name: "检查", qos: .userInitiated)
        let finished = DispatchSemaphore(value: 0), sourceFired = DispatchSemaphore(value: 0)
        var order: [Int] = [], offMain = false
        thread.perform { order.append(1); offMain = !Thread.isMainThread }
        thread.perform { order.append(2); finished.signal() }
        check(finished.wait(timeout: .now() + 5) == .success, "主线程等待时，后台线程照常工作")
        check(order == [1, 2], "后台线程按交给它的顺序工作")
        check(offMain, "这些工作不在主线程上运行")
        // Event taps and accessibility observers reach their callbacks as run loop sources.
        var context = CFRunLoopSourceContext(version: 0, info: Unmanaged.passUnretained(sourceFired).toOpaque(), retain: nil, release: nil, copyDescription: nil,
                                             equal: nil, hash: nil, schedule: nil, cancel: nil, perform: { info in
            if let info, !Thread.isMainThread { Unmanaged<DispatchSemaphore>.fromOpaque(info).takeUnretainedValue().signal() }
        })
        let source: CFRunLoopSource = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)
        thread.add(source)
        thread.perform { CFRunLoopSourceSignal(source) }
        check(sourceFired.wait(timeout: .now() + 5) == .success, "事件来源的回调在后台线程上运行，不需要主线程")
        thread.remove(source)
        thread.perform { finished.signal() }
        check(finished.wait(timeout: .now() + 5) == .success, "移除事件来源后，线程继续工作，不会因为没事可等而退出")
        thread.finish()
        var waits = 0
        while !thread.isFinished && waits < 500 { Thread.sleep(forTimeInterval: 0.01); waits += 1 }
        check(thread.isFinished, "结束后线程退出")
    }
    static func verifyOptimizations() {
        check(QuickCommitPolicy.commitsNow(selectionUntouched: true, cacheAge: 3, cacheStale: false), "列表刚读过且没有新事件时，快速松键直接切换")
        check(QuickCommitPolicy.commitsNow(selectionUntouched: true, cacheAge: QuickCommitPolicy.maximumCacheAge, cacheStale: false), "列表刚好在信任期限内时，仍然直接切换")
        check(!QuickCommitPolicy.commitsNow(selectionUntouched: false, cacheAge: 3, cacheStale: false), "手动改过选择时，等最新列表")
        check(!QuickCommitPolicy.commitsNow(selectionUntouched: true, cacheAge: 3, cacheStale: true), "读取之后有新窗口或应用事件时，等最新列表")
        check(!QuickCommitPolicy.commitsNow(selectionUntouched: true, cacheAge: QuickCommitPolicy.maximumCacheAge + 0.1, cacheStale: false), "列表太旧时，等最新列表")

        let display = WindowRect(x: 0, y: 0, width: 1920, height: 1080), second = WindowRect(x: 1920, y: 0, width: 1440, height: 900)
        func fullscreen(ax: Bool = false, menuBar: Bool = false, _ windows: [(layer: Int, frame: WindowRect)] = []) -> Bool {
            FrontFullscreenPolicy.isActive(windowFullscreen: ax, menuBarHidden: menuBar, frontWindows: windows, displays: [display, second])
        }
        check(fullscreen(ax: true), "系统全屏窗口算占满屏幕")
        check(fullscreen(menuBar: true), "应用隐藏了菜单栏时算占满屏幕")
        check(fullscreen([(layer: 25, frame: display)]), "高于普通窗口且盖住整块屏幕的窗口算占满屏幕")
        check(fullscreen([(layer: 25, frame: second)]), "盖住第二块屏幕也算占满屏幕")
        check(fullscreen([(layer: 1000, frame: WindowRect(x: -10, y: -10, width: 1940, height: 1100))]), "比屏幕还大的窗口也算占满屏幕")
        check(!fullscreen([(layer: 0, frame: display)]), "普通层级的窗口铺满屏幕时，菜单栏还在，不算占满")
        check(!fullscreen([(layer: 25, frame: WindowRect(x: 0, y: 0, width: 800, height: 600))]), "高层级的小窗口不算占满屏幕")
        check(!fullscreen(), "没有这些迹象时，不算占满屏幕")

        var batch = ChangeBatch<Int>()
        check(batch.add(1, same: ==), "一批里的第一个变化要求安排刷新")
        check(!batch.add(2, same: ==), "同一批后面的变化不再推迟刷新")
        check(!batch.add(1, same: ==), "同一个窗口反复变化也不再安排")
        check(batch.flush() == [1, 2], "一次刷新处理整批变化，同一窗口只算一次")
        check(batch.flush().isEmpty, "刷新后这一批就清空了")
        check(batch.add(3, same: ==), "刷新后的下一个变化重新要求安排")

        var tabs = BrowserTabCache<String>()
        tabs.keep(only: ["safari|1", "chrome|2"])
        tabs.update("chrome|2", tabs: ["c1"])
        check(tabs.all == ["c1"], "先回答的浏览器先显示，不等别的浏览器")
        tabs.update("safari|1", tabs: ["s1", "s2"])
        check(tabs.all == ["s1", "s2", "c1"], "结果按固定顺序排列，不随回答先后变化")
        tabs.update("safari|1", tabs: nil)
        check(tabs.all == ["s1", "s2", "c1"], "浏览器这次没回答时，保留上次的标签页")
        tabs.update("safari|1", tabs: [])
        check(tabs.all == ["c1"], "浏览器回答没有标签页时，清掉它上次的结果")
        tabs.keep(only: ["safari|1", "chrome|9"])
        check(tabs.all.isEmpty, "浏览器退出或重新启动后，不再显示它旧进程的标签页")

        var point = CGPoint(x: 10, y: 20), size = CGSize(width: 300, height: 200), failure = AXError.attributeUnsupported
        let position = AXValueCreate(.cgPoint, &point)!, dimension = AXValueCreate(.cgSize, &size)!, missing = AXValueCreate(.axError, &failure)!
        check(AXWindowFacts.attributes.count == 7, "一次读取取回窗口的七个属性")
        let facts = AXWindowFacts(values: ["报告" as NSString, position, dimension, kCFBooleanTrue, "AXWindow" as NSString, "AXStandardWindow" as NSString, missing])
        check(facts.title == "报告" && facts.role == "AXWindow" && facts.subrole == "AXStandardWindow", "批量读取解析出标题和角色")
        check(facts.frame == CGRect(x: 10, y: 20, width: 300, height: 200), "批量读取解析出窗口位置和大小")
        check(facts.minimized, "批量读取解析出最小化状态")
        check(!facts.fullscreen, "窗口没有的属性保持默认值")
        let unanswered = AXWindowFacts(values: [missing, missing, missing, missing, missing, missing, missing])
        check(unanswered.role.isEmpty && unanswered.frame == .zero, "全部读取失败时不当作有效窗口")
        check(AXWindowFacts(values: [missing]).role.isEmpty, "返回的值比请求的少时不会越界")
        let sizeOnly = AXWindowFacts(values: [missing, missing, dimension, missing, missing, missing, missing])
        check(sizeOnly.frame == .zero, "位置和大小缺一项时不拼出半个窗口")
    }
    static func verifyPinsAndRecovery() {
        check(SettingsReturnPolicy.comesToFront(wasKey: true, cancelled: true, demo: false), "在设置窗口上取消面板后，设置窗口回到前面")
        check(SettingsReturnPolicy.comesToFront(wasKey: true, cancelled: false, demo: true), "演示结束后，设置窗口回到前面")
        check(!SettingsReturnPolicy.comesToFront(wasKey: true, cancelled: false, demo: false), "切换到别的窗口后，设置窗口不遮挡它")
        check(!SettingsReturnPolicy.comesToFront(wasKey: false, cancelled: true, demo: false), "设置窗口原本不在前面时，取消面板不抢走焦点")

        var damaged = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(UserSettings.defaults)) as! [String: Any]
        damaged["showHidden"] = "not-a-bool"; damaged["thumbnailWidth"] = 300
        var advanced = damaged["advanced"] as! [String: Any]
        advanced["browserTabs"] = "not-a-bool"; advanced["commandLineEnabled"] = true
        damaged["advanced"] = advanced
        let damagedData = try! JSONSerialization.data(withJSONObject: damaged)
        check((try? JSONDecoder().decode(UserSettings.self, from: damagedData)) == nil, "有一个值损坏时，整份配置无法读取")
        let salvaged = UserSettings.salvaged(from: damagedData)
        check(salvaged?.thumbnailWidth == 300 && salvaged?.showHidden == true, "损坏的值用默认值，其他值保留")
        check(salvaged?.advanced.commandLineEnabled == true && salvaged?.advanced.browserTabs == false, "分组里有损坏的值时，同组其他值保留")
        check(UserSettings.salvaged(from: Data("not json".utf8)) == nil, "不是 JSON 的内容无法恢复")
        check(UserSettings.salvaged(from: Data("{\"showHidden\":\"x\"}".utf8)) == nil, "没有任何可用的值时无法恢复")

        func pinWindow(_ id: String, _ windowID: UInt32?, pid: Int32, bundle: String = "com.apple.Safari", title: String) -> WindowDescriptor {
            WindowDescriptor(id: id, windowID: windowID, pid: pid, appName: "Safari", bundleID: bundle, title: title, minimized: false, hidden: false, onCurrentSpace: true, displayID: nil, aspectRatio: 1.6)
        }
        func resolve(_ pins: [WindowPin], _ windows: [WindowDescriptor], running: [Int32: String] = [:], live: Set<UInt32> = []) -> [WindowPin] {
            PinPolicy.resolve(pins, windows: windows, runningApps: running, liveWindowIDs: live)
        }
        let safari = "com.apple.Safari"
        let pin = WindowPin(pinWindow("cg:7", 7, pid: 100, title: "报告"))
        check(resolve([pin], [pinWindow("cg:7", 7, pid: 100, title: "报告 2")]).first?.title == "报告 2", "同一个窗口改名后，置顶跟着更新标题")
        check(resolve([pin], [pinWindow("cg:7", 7, pid: 100, title: "")]).first?.title == "报告", "暂时读不到标题时，保留原来的标题")
        let reused = resolve([pin], [pinWindow("cg:7", 7, pid: 200, bundle: "com.other", title: "别的窗口")], running: [200: "com.other"])
        check(reused.count == 1 && PinPolicy.boundIDs(reused).isEmpty, "重启后窗口号被别的应用复用时，不会置顶到它上面")
        check(resolve([pin], [pinWindow("cg:9", 9, pid: 300, title: "报告")]).first?.id == "cg:9", "应用重开后，按应用和标题找回窗口")
        let twins = [pinWindow("cg:8", 8, pid: 300, title: "报告"), pinWindow("cg:9", 9, pid: 300, title: "报告")]
        check(PinPolicy.boundIDs(resolve([pin], twins)).isEmpty, "有两个同名窗口时不猜")
        let first = WindowPin(pinWindow("cg:1", 1, pid: 100, title: "同名")), second = WindowPin(pinWindow("cg:2", 2, pid: 50, title: "同名"))
        check(PinPolicy.boundIDs(resolve([first, second], [pinWindow("cg:1", 1, pid: 100, title: "同名")])) == ["cg:1"], "已被占用的窗口不会再被另一个置顶按标题占用")
        check(resolve([pin], [], running: [100: safari], live: [7]).first?.id == "cg:7", "窗口还在、只是这次没读到时，保留置顶")
        check(resolve([pin], [], running: [100: safari]).isEmpty, "应用还在运行而窗口已关闭时，取消置顶")
        let waiting = resolve([pin], [])
        check(waiting.count == 1 && waiting[0].id.isEmpty, "应用没有运行时，置顶等它重新打开这个窗口")
        check(resolve(waiting, [pinWindow("cg:11", 11, pid: 400, title: "报告")]).first?.id == "cg:11", "等待中的置顶在窗口出现后生效")
        let legacy = resolve([WindowPin(legacyID: "cg:7")], [pinWindow("cg:7", 7, pid: 100, title: "报告")])
        check(legacy.first?.bundleID == safari && legacy.first?.title == "报告", "旧版保存的置顶补上应用和标题")
        check(resolve([WindowPin(legacyID: "cg:7")], []).isEmpty, "旧版保存的置顶找不到窗口时不保留")
        check(resolve([WindowPin(pinWindow("app:100", nil, pid: 100, title: ""))], []).isEmpty, "没有标题的置顶在应用退出后无法找回，不保留")
        check(PinPolicy.adding(pin, to: [pin]).count == 1, "同一个窗口不重复置顶")
        let many = (0..<40).reduce([WindowPin]()) { PinPolicy.adding(WindowPin(pinWindow("cg:\($1)", UInt32($1), pid: 100, title: "窗口")), to: $0) }
        check(many.count == PinPolicy.limit && many.last?.id == "cg:39", "置顶数量有上限，保留最新的")
        let roundTrip = try? JSONDecoder().decode([WindowPin].self, from: JSONEncoder().encode([pin]))
        check(roundTrip == [pin], "置顶可以保存和读取")

        let tricky = "a\"b\\c\nd'); evil(); ('"
        let literal = BrowserTabScript.literal(tricky)
        check(literal.flatMap { try? JSONDecoder().decode(String.self, from: Data($0.utf8)) } == tricky, "标签页文字写入脚本后内容不变")
        check(literal?.hasPrefix("\"") == true && literal?.hasSuffix("\"") == true && literal?.contains("\n") == false, "标签页文字只能作为字符串进入脚本")

        let a = pinWindow("cg:1", 1, pid: 100, title: "甲"), b = pinWindow("cg:2", 2, pid: 100, title: "乙")
        var stamped = a; stamped.lastFocused = 99
        var renamedWindow = a; renamedWindow.title = "丙"
        check(!WindowListChange.matters(from: [a, b], to: [stamped, b]), "只有前台时间戳变化时不重新布局")
        check(WindowListChange.matters(from: [a, b], to: [b, a]), "窗口顺序变化时重新布局")
        check(WindowListChange.matters(from: [a, b], to: [renamedWindow, b]), "标题变化时重新布局")
        check(WindowListChange.matters(from: [a, b], to: [a]), "窗口数量变化时重新布局")
    }
    static func verifyMenuBar() {
        check(MenuBarPolicy.identity(bundle: "com.liguangming.Shadowrocket", identifier: nil) == "bundle:com.liguangming.Shadowrocket", "菜单栏图标按所属应用识别")
        check(MenuBarPolicy.identity(bundle: nil, identifier: "com.apple.menuextra.wifi") == "system:6", "系统的无线局域网图标识别为系统项")
        check(MenuBarPolicy.identity(bundle: "com.apple.TextInputMenuAgent", identifier: nil) == "system:4", "输入法菜单归为系统输入法项")
        check(MenuBarPolicy.identity(bundle: "com.apple.systemuiserver", identifier: nil) == "fixed:com.apple.systemuiserver", "Siri 所在的系统进程不能单独分组")
        check(MenuBarPolicy.identity(bundle: nil, identifier: "com.apple.menuextra.focusmode") == "fixed:com.apple.menuextra.focusmode", "系统不允许单独控制的项目标为系统管理")
        check(MenuBarPolicy.identity(bundle: nil, identifier: nil) == nil && MenuBarPolicy.identity(bundle: nil, identifier: "AXGroup") == nil, "不是菜单栏图标的元素被忽略")
        check(!MenuBarPolicy.isAssignable("bundle:com.jethro.windowhop") && !MenuBarPolicy.isAssignable("system:2") && !MenuBarPolicy.isAssignable("system:8")
              && !MenuBarPolicy.isAssignable("fixed:com.apple.systemuiserver"), "一瞥自己、时钟、控制中心和 Siri 不能隐藏")
        check(MenuBarPolicy.isAssignable("system:6") && MenuBarPolicy.isAssignable("bundle:com.example.app") && !MenuBarPolicy.isAssignable("system:12"), "普通应用和可控系统项可以分组")

        var bar = MenuBarSettings()
        let running: Set<String> = ["com.a", "com.b", "com.c"]
        check(MenuBarPolicy.allowance(settings: bar, running: running, reveal: .none) == nil, "没有隐藏项时不向系统发请求，避免误收起专注模式等系统图标")
        bar.sections = ["bundle:com.a": .hidden, "bundle:com.b": .alwaysHidden, "system:6": .hidden]
        let collapsed = MenuBarPolicy.allowance(settings: bar, running: running, reveal: .none)
        check(collapsed?.bundles == ["com.c", "com.jethro.windowhop"] && collapsed?.systemItems == [0, 1, 2, 3, 4, 5, 7, 8], "收起时隐藏组和始终隐藏组都不显示，一瞥自己始终显示")
        let partly = MenuBarPolicy.allowance(settings: bar, running: running, reveal: .hidden)
        check(partly?.bundles == ["com.a", "com.c", "com.jethro.windowhop"] && partly?.systemItems == Array(0...8), "显示隐藏组时始终隐藏组仍收起")
        check(MenuBarPolicy.allowance(settings: bar, running: running, reveal: .all) == nil, "显示全部时撤销请求")
        bar.sections = ["bundle:com.notrunning": .hidden]
        check(MenuBarPolicy.allowance(settings: bar, running: running, reveal: .none) == nil, "隐藏的应用没有运行时不发请求")
        bar.sections = ["bundle:com.a": .hidden]; bar.enabled = false
        check(MenuBarPolicy.allowance(settings: bar, running: running, reveal: .none) == nil && !bar.hidesAnything, "关闭管理后所有图标显示")
        check(MenuBarReveal.none.shows(.visible) && !MenuBarReveal.none.shows(.hidden) && MenuBarReveal.hidden.shows(.hidden)
              && !MenuBarReveal.hidden.shows(.alwaysHidden) && MenuBarReveal.all.shows(.alwaysHidden), "显示、隐藏、始终隐藏三档的显示规则")

        let legacy = try? JSONDecoder().decode(UserSettings.self, from: Data("{}".utf8))
        check(legacy?.menuBar == MenuBarSettings() && legacy?.menuBar.sections.isEmpty == true, "旧设置没有菜单栏字段时采用默认值，不隐藏任何图标")
        let stored = #"{"menuBar":{"sections":{"bundle:com.a":"hidden","bundle:com.jethro.windowhop":"hidden","system:2":"alwaysHidden","bundle:com.b":"bogus"},"rehideSeconds":20}}"#
        let decoded = try? JSONDecoder().decode(UserSettings.self, from: Data(stored.utf8))
        check(decoded?.menuBar.sections == ["bundle:com.a": .hidden] && decoded?.menuBar.rehideSeconds == 20, "无效或不能隐藏的分组项逐项丢弃，其余保留")
        var roundTrip = UserSettings.defaults
        roundTrip.menuBar.sections = ["bundle:com.a": .alwaysHidden, "system:6": .hidden]; roundTrip.menuBar.revealOnHover = false
        let encoded = try? JSONEncoder().encode(roundTrip)
        check(encoded.flatMap { try? JSONDecoder().decode(UserSettings.self, from: $0) } == roundTrip, "菜单栏设置可以保存和恢复")

        var keys = UserSettings.defaults
        keys.menuBar.toggleHotkey.enabled = true; keys.menuBar.showAllHotkey.enabled = true
        check(keys.validationError() == nil, "默认的菜单栏快捷键 ⌃⌥B 和 ⌃⌥⇧B 不与切换方案冲突")
        keys.menuBar.showAllHotkey = MenuBarHotkey(keyCode: 11, modifiers: [.control, .option], enabled: true)
        check(keys.validationError() != nil, "两个菜单栏快捷键不能相同")
        let fixedKeys = keys.repaired()
        check(fixedKeys.menuBar.toggleHotkey.enabled && !fixedKeys.menuBar.showAllHotkey.enabled && fixedKeys.validationError() == nil, "修复设置时停用冲突的菜单栏快捷键")
        var clash = UserSettings.defaults
        clash.menuBar.toggleHotkey = MenuBarHotkey(keyCode: 48, modifiers: [.option], enabled: true)
        check(clash.validationError() != nil, "菜单栏快捷键不能占用切换方案的 ⌥⇥")
        check(!MenuBarHotkey(keyCode: 11, modifiers: [.shift], enabled: true).isValid && !MenuBarHotkey(keyCode: KeyChoice.modifierOnly, modifiers: [.option], enabled: true).isValid,
              "菜单栏快捷键需要 ⌥、⌃ 或 ⌘ 加一个按键")
        var rehide = UserSettings.defaults; rehide.menuBar.rehideSeconds = 7
        check(rehide.validationError() != nil && rehide.repaired().menuBar.rehideSeconds == 10, "无效的自动收回时间被拒绝并修复")

        check(MenuBarPolicy.hoverZone(menusEnd: 323, iconsStart: 1241, screenWidth: 1920) == 339...1233, "悬停区域在应用菜单和菜单栏图标之间")
        check(MenuBarPolicy.hoverZone(menusEnd: 1200, iconsStart: 1230, screenWidth: 1920) == nil, "空白太窄时不响应悬停")

        var entry = WindowDescriptor(id: "menubar:bundle:com.liguangming.Shadowrocket", windowID: nil, pid: 0, appName: "Shadowrocket",
                                     bundleID: "com.liguangming.Shadowrocket", title: "Shadowrocket", minimized: false, hidden: false,
                                     onCurrentSpace: true, displayID: nil, aspectRatio: 1.6)
        entry.menuBarItem = true
        let profile = UserSettings.defaults.shortcuts[0]
        check(entry.searchOnly, "菜单栏图标不是窗口")
        check(WindowSearch.filtered([entry], settings: .defaults, profile: profile, frontPID: nil, displayID: nil, query: "").isEmpty, "⌥⇥ 不列出菜单栏图标")
        check(WindowSearch.filtered([entry], settings: .defaults, profile: profile, frontPID: nil, displayID: nil, query: "shadow").count == 1, "搜索时可以找到菜单栏图标")
        check(SettingSearchIndex.results("Bartender").first?.section == 7, "设置搜索可以找到菜单栏页")

        // 2.3: apps that are not open and System Settings pages, opened from the search.
        func launchEntry(_ id: String, name: String, alias: String?, kind: LaunchKind) -> WindowDescriptor {
            var d = WindowDescriptor(id: "launch:\(id)", windowID: nil, pid: 0, appName: alias ?? name, bundleID: id, title: name,
                                     minimized: false, hidden: false, onCurrentSpace: true, displayID: nil, aspectRatio: 1.6)
            d.launcher = kind
            return d
        }
        let wechat = launchEntry("com.tencent.xinWeChat", name: "微信", alias: "WeChat", kind: .app)
        let bluetooth = launchEntry("com.apple.BluetoothSettings", name: "蓝牙", alias: "Bluetooth", kind: .setting)
        func search(_ items: [WindowDescriptor], _ query: String) -> [String] {
            WindowSearch.filtered(items, settings: .defaults, profile: profile, frontPID: nil, displayID: nil, query: query).map(\.id)
        }
        let notes = WindowDescriptor(id: "notes", windowID: 8, pid: 50, appName: "备忘录", bundleID: "com.apple.Notes", title: "购物清单",
                                     minimized: false, hidden: false, onCurrentSpace: true, displayID: 1, aspectRatio: 1.6)
        check(wechat.searchOnly && search([wechat, bluetooth, notes], "") == ["notes"], "⌥⇥ 不列出未打开的应用和设置页")
        check(search([wechat], "wechat") == [wechat.id] && search([wechat], "微信") == [wechat.id], "英文名和中文名都能找到应用")
        check(search([wechat], "wx") == [wechat.id] && search([wechat], "weixin") == [wechat.id], "拼音首字母和全拼能找到应用")
        check(search([bluetooth], "蓝牙") == [bluetooth.id] && search([bluetooth], "bluetooth") == [bluetooth.id], "中英文都能找到系统设置页")
        let wifi = launchEntry("com.apple.wifi-settings-extension", name: "Wi\u{2011}Fi", alias: nil, kind: .setting)
        let diagnostics = launchEntry("com.apple.wifi.diagnostics", name: "无线诊断", alias: "Wireless Diagnostics", kind: .app)
        check(search([diagnostics, wifi], "wifi").first == wifi.id, "不带连字符的 wifi 找到 Wi‑Fi 设置页")
        let calculator = launchEntry("com.apple.calculator", name: "计算器", alias: "Calculator", kind: .app)
        let monitor = launchEntry("com.apple.ActivityMonitor", name: "活动监视器", alias: "Activity Monitor", kind: .app)
        check(search([monitor, calculator], "jsq") == [calculator.id, monitor.id], "首字母从头匹配的排在中间匹配之前")
        let bluetoothApp = launchEntry("com.apple.BluetoothFileExchange", name: "蓝牙文件交换", alias: "Bluetooth File Exchange", kind: .app)
        check(search([bluetoothApp, bluetooth], "lanya").first == bluetooth.id, "同样匹配时名称更短的排前面")
        let many = (0..<20).map { launchEntry("com.example.app\($0)", name: "Example \($0)", alias: nil, kind: .app) }
        check(search(many, "example").count == WindowSearch.launcherLimit, "一次搜索最多列出 \(WindowSearch.launcherLimit) 个可打开的项目")
        let mailWindow = WindowDescriptor(id: "w-mail", windowID: 9, pid: 40, appName: "Mail", bundleID: "com.apple.mail", title: "Example inbox",
                                          minimized: false, hidden: false, onCurrentSpace: true, displayID: 1, aspectRatio: 1.6)
        check(search(many + [mailWindow], "example").first == "w-mail", "已打开的窗口排在可打开的项目之前")
        let oldAdvanced = try! JSONDecoder().decode(AdvancedSettings.self, from: Data("{}".utf8))
        check(oldAdvanced.searchApps && oldAdvanced.searchSettingsPages, "旧设置默认在搜索中包含应用和设置页")
        check(SettingSearchIndex.results("开始菜单").first?.section == 1, "设置搜索可以找到“未打开的应用”开关")

        // 2.3: Dock previews.
        let dock = try! JSONDecoder().decode(UserSettings.self, from: try! JSONEncoder().encode(UserSettings.defaults))
        check(dock.dockPreview == DockPreviewSettings() && dock.dockPreview.enabled && dock.dockPreview.delay == 300, "Dock 预览默认开启，延迟 300 毫秒")
        var noDock = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(UserSettings.defaults)) as! [String: Any]
        noDock.removeValue(forKey: "dockPreview")
        let legacyDock = try! JSONDecoder().decode(UserSettings.self, from: JSONSerialization.data(withJSONObject: noDock))
        check(legacyDock.dockPreview == DockPreviewSettings(), "旧设置没有 Dock 预览字段时采用默认值")
        var slow = UserSettings.defaults; slow.dockPreview.delay = 5000
        check(slow.validationError() != nil && slow.repaired().dockPreview.delay == 1000, "Dock 预览延迟超出范围时被拒绝并修复")
        check(SettingSearchIndex.results("任务栏").first?.section == 3, "设置搜索可以找到 Dock 预览")
    }
    static func verifyEnhancements() {
        var value = UserSettings.defaults
        value.shortcuts[2].enabled = true; value.shortcuts[2].keyCode = KeyChoice.modifierOnly; value.shortcuts[2].modifiers = [.control, .option]
        check(value.validationError() == nil, "全局快捷键支持单独的修饰键组合")
        value.shortcuts[2].modifiers = .shift
        check(value.validationError() != nil, "全局单 Shift 仍不能占用正常打字")
        value = .defaults
        value.advanced.bindings[0].keyCode = KeyChoice.modifierOnly
        check(value.validationError() != nil, "拒绝空的单修饰键绑定")
        value.advanced.bindings[0].modifiers = .control
        check(value.validationError() == nil, "面板可明确录制单修饰键操作")
        value.advanced.independentGesture = .gestureDefaults
        value.advanced.independentGesture?.scope = .otherApps
        value.advanced.independentGesture?.styleOverride = .titles
        check(value.validationError() == nil && value.shortcuts.count == 9, "独立手势方案不占用九组键盘快捷键")
        check(try! JSONDecoder().decode(UserSettings.self, from: JSONEncoder().encode(value)) == value, "独立手势与新操作设置可以完整保存恢复")
        value.advanced.independentGesture?.widthOverride = .nan
        check(value.validationError() != nil, "拒绝独立手势方案的无效尺寸")
        let older = try! JSONDecoder().decode(AdvancedSettings.self, from: Data("{}".utf8))
        check(older.independentGesture == nil && older.shiftSelectsPrevious && older.showSearchHint && older.voiceOverKeepsOpen, "旧配置保留手势沿用行为并采用新操作默认值")
        let bindings = PanelBinding.defaults
        func modifier(_ before: ShortcutModifiers, _ now: ShortcutModifiers, search: Bool = false, enabled: Bool = true) -> PanelCommand? {
            ModifierNavigation.command(previous: before, current: now, held: .option, bindings: bindings, shiftSelectsPrevious: enabled, searching: search)
        }
        check(modifier(.option, [.option, .shift]) == .previous, "按住 Option 时单独按 Shift 选择上一个窗口")
        check(modifier([.option, .shift], [.option, .shift]) == nil, "相同修饰键状态不重复选择")
        check(modifier([.option, .shift], .option) == nil, "松开 Shift 不再多走一步")
        check(modifier(.option, [.option, .shift, .command]) == nil, "带额外修饰键不会误触单 Shift 导航")
        check(modifier(.option, [.option, .shift], search: true) == nil, "搜索输入框的 Shift 保留给文字编辑")
        check(modifier(.option, [.option, .shift], enabled: false) == nil, "可关闭单 Shift 反向导航")
        var custom = bindings
        custom[custom.firstIndex(where: { $0.command == .previous })!].enabled = false
        check(ModifierNavigation.command(previous: .option, current: [.option, .shift], held: .option, bindings: custom, shiftSelectsPrevious: true, searching: false) == nil, "禁用反向操作也禁用单 Shift")
        custom = [.init(command: .fullscreen, keyCode: KeyChoice.modifierOnly, modifiers: [.control, .shift])]
        check(ModifierNavigation.command(previous: .option, current: [.option, .control, .shift], held: .option, bindings: custom, shiftSelectsPrevious: false, searching: false) == .fullscreen, "自定义单修饰键组合保留触发 Option 后仍可执行")
        custom = [.init(command: .confirm, keyCode: KeyChoice.modifierOnly, modifiers: .control)]
        check(ModifierNavigation.command(previous: [.control, .shift], current: .control, held: [], bindings: custom, shiftSelectsPrevious: false, searching: false) == nil, "松开额外修饰键不会误执行组合中的单键操作")
        let idle = ActivityTimerPlan(showing: false, demo: false, previews: true, thumbnails: true, largePreview: false, background: false)
        check(!idle.preview && !idle.background && !idle.list, "关闭面板且后台预览关闭时，没有活动定时器")
        let icons = ActivityTimerPlan(showing: true, demo: false, previews: true, thumbnails: false, largePreview: false, background: false)
        check(!icons.preview && icons.list, "图标和标题面板不会持续截图")
        let zoom = ActivityTimerPlan(showing: true, demo: false, previews: true, thumbnails: false, largePreview: true, background: true)
        check(zoom.preview && !zoom.background && zoom.list, "大图预览按需截图，不同时启动后台预览")
        let demo = ActivityTimerPlan(showing: true, demo: true, previews: true, thumbnails: true, largePreview: true, background: true)
        check(!demo.preview && !demo.background && !demo.list, "演示不枚举或截图真实窗口")
        let afterDemo = ActivityTimerPlan(showing: false, demo: true, previews: true, thumbnails: true, largePreview: false, background: true)
        check(afterDemo.background && !afterDemo.preview, "关闭演示后可恢复用户启用的后台预览")
        let small = CompactLayout.calculate(style: .icons, count: 6, availableWidth: 1000, availableHeight: 620, preferredWidth: 150, adaptive: false)
        let large = CompactLayout.calculate(style: .icons, count: 6, availableWidth: 1000, availableHeight: 620, preferredWidth: 360, adaptive: false)
        check(large.width > small.width && large.height > small.height, "图标模式的手动尺寸实际生效")
        let smallRows = CompactLayout.calculate(style: .titles, count: 6, availableWidth: 1000, availableHeight: 620, preferredWidth: 150, adaptive: false)
        let largeRows = CompactLayout.calculate(style: .titles, count: 6, availableWidth: 1000, availableHeight: 620, preferredWidth: 360, adaptive: false)
        check(largeRows.height > smallRows.height && largeRows.width > smallRows.width, "标题列表的行高与宽度随手动尺寸变化")
        for count in [1, 6, 30, 600] {
            let layout = CompactLayout.calculate(style: .icons, count: count, availableWidth: 900, availableHeight: 620, preferredWidth: 230, adaptive: true)
            check(Double(layout.columns) * layout.width + Double(layout.columns - 1) * 12 <= 900 && layout.height >= 110, "\(count) 项的自动图标布局不越过屏幕宽度")
        }
        check(WindowEligibility.accepts(role: "AXWindow", subrole: "AXStandardWindow", width: 800, height: 600, minimized: false, hidden: false, hasWindowID: true), "正常窗口可进入列表")
        check(!WindowEligibility.accepts(role: "AXWindow", subrole: "AXUnknown", width: 800, height: 60, minimized: false, hidden: false, hasWindowID: true), "浏览器查找条等未知子窗口被排除")
        check(!WindowEligibility.accepts(role: "AXWindow", subrole: "AXFloatingWindow", width: 300, height: 300, minimized: false, hidden: false, hasWindowID: true), "浮动工具面板被排除")
        check(WindowEligibility.accepts(role: "AXWindow", subrole: "AXStandardWindow", width: 0, height: 0, minimized: false, hidden: true, hasWindowID: true), "隐藏但有真实编号的零尺寸窗口仍保留")
        check(WindowEligibility.accepts(role: "AXWindow", subrole: "AXStandardWindow", width: 0, height: 0, minimized: true, hidden: false, hasWindowID: true), "零尺寸最小化窗口仍保留")
        check(!WindowEligibility.accepts(role: "AXWindow", subrole: "", width: 0, height: 0, minimized: false, hidden: false, hasWindowID: false), "无编号且无有效尺寸的对象不会冒充窗口")
        check(SettingSearchIndex.results("拼音 错误").first?.title == "容忍英文或完整拼音的一处拼写错误", "设置搜索直接定位到多关键词匹配的选项")
        check(SettingSearchIndex.results("zhen dong").contains { $0.title == "切换时触控板震动反馈" }, "设置搜索支持中文选项的拼音")
        check(SettingSearchIndex.results("screen recording").first?.section == 5, "设置搜索支持常用英文权限名称")
        check(SettingSearchIndex.results("UU远程").first?.section == 4, "设置搜索定位远程应用例外")
        check(SettingSearchIndex.results(" \n ").isEmpty && SettingSearchIndex.results("WindowHop-NoSetting-8234").isEmpty, "空查询和无结果设置查询不会跳到无关页面")
        var gesture = GestureTracker(choice: .threeHorizontal)
        _ = gesture.update(fingers: 3, x: 0.3, y: 0.5)
        check(gesture.update(fingers: 3, x: 0.305, y: 0.5) == nil, "手势轻微抖动不触发")
        check(gesture.update(fingers: 3, x: 0.33, y: 0.5) == .start(1), "识别手势后及时选择首个目标")
        _ = gesture.update(fingers: 0, x: 0, y: 0)
        _ = gesture.update(fingers: 4, x: 0.3, y: 0.5)
        gesture.rebase()
        _ = gesture.update(fingers: 3, x: 0.3, y: 0.5)
        check(gesture.update(fingers: 3, x: 0.6, y: 0.5) == nil, "四指系统手势中途减少为三指不会误触一瞥")
        _ = gesture.update(fingers: 0, x: 0, y: 0)
        _ = gesture.update(fingers: 3, x: 0.3, y: 0.5)
        check(gesture.update(fingers: 3, x: 0.51, y: 0.5) == .start(2), "抬手后手势识别恢复，拒绝状态不会永久卡住")
        check(gesture.update(fingers: 3, x: .nan, y: 0.5) == nil, "忽略无法读取的触摸坐标")
    }
    static func verifyVersion16() {
        // Bare function keys
        var value = UserSettings.defaults
        value.shortcuts[3].enabled = true; value.shortcuts[3].modifiers = []; value.shortcuts[3].keyCode = 105
        check(value.validationError() == nil && value.shortcuts[3].usesBareKey, "单独的 F13 可作为全局快捷键")
        value.shortcuts[3].keyCode = 0
        check(value.validationError() != nil, "单独的字母键仍不能作为全局快捷键")
        // Repair instead of reset
        var broken = UserSettings.defaults
        broken.thumbnailWidth = 9_999; broken.advanced.showDelay = -5; broken.advanced.gestureProfile = 42
        broken.shortcuts[1].keyCode = 48; broken.shortcuts[1].modifiers = .option
        broken.advanced.bindings[1].keyCode = 36
        broken.shortcuts.removeLast()
        check(broken.validationError() != nil, "构造的损坏配置确实无效")
        let fixed = broken.repaired()
        check(fixed.validationError() == nil, "修复后的配置通过校验")
        check(fixed.shortcuts.count == 9 && fixed.shortcuts[0].enabled && !fixed.shortcuts[1].enabled, "冲突的快捷键被停用，保留第一组")
        check(fixed.thumbnailWidth == 230 && fixed.advanced.showDelay == 0 && fixed.advanced.gestureProfile == 0, "超出范围的数值被修正")
        check(fixed.style == broken.style && fixed.advanced.exceptions == broken.advanced.exceptions, "修复时保留其他设置")
        check(fixed.advanced.bindings.filter(\.enabled).count == broken.advanced.bindings.count - 1, "重复的面板按键只停用后出现的一项")
        check(UserSettings.defaults.repaired() == .defaults, "有效配置修复后保持不变")
        // Export / import
        var custom = UserSettings.defaults; custom.style = .titles; custom.advanced.browserTabs = true
        let archive = try! SettingsArchive.encode(custom)
        check((try? SettingsArchive.decode(archive)) == custom, "导出的设置可以原样导入")
        check((try? SettingsArchive.decode(JSONEncoder().encode(custom))) == custom, "也能导入未包装的设置数据")
        check((try? SettingsArchive.decode(Data("{\"hello\":1}".utf8))) == nil, "拒绝导入无关的 JSON 文件")
        check((try? SettingsArchive.decode(Data("not json".utf8))) == nil, "拒绝导入非 JSON 文件")
        // New defaults and migration
        let older = try! JSONDecoder().decode(AdvancedSettings.self, from: Data("{}".utf8))
        check(!older.commandLineEnabled && older.focusMethod == .windowServer && !older.gestureAvoidsSystem, "命令行默认关闭，切换默认走窗口服务，手势拦截默认关闭")
        check(older.dockBadges && older.numberHints && !older.browserTabs, "角标和编号默认开启，浏览器标签页默认关闭")
        check(PanelBinding.defaults.first { $0.command == .tileLeft }?.modifiers == [.control, .command], "窗口整理默认使用 ⌃⌘ 方向键")
        check(UserSettings.defaults.validationError() == nil, "新增面板操作的默认按键不冲突")
        // Browser tabs, pins and grouping
        func window(_ id: String, pid: Int32, title: String, focused: Double, tab: Bool = false) -> WindowDescriptor {
            var w = WindowDescriptor(id: id, windowID: nil, pid: pid, appName: "App\(pid)", bundleID: "org.app\(pid)", title: title,
                                     minimized: false, hidden: false, onCurrentSpace: true, displayID: 1, aspectRatio: 1.6)
            w.lastFocused = focused; w.browserTab = tab; return w
        }
        let settings = UserSettings.defaults
        var profile = settings.shortcuts[0]
        let current = window("current", pid: 1, title: "Editor", focused: 100)
        let previous = window("previous", pid: 2, title: "Mail", focused: 90)
        var pinned = window("pinned", pid: 3, title: "Music", focused: 10); pinned.pinned = true
        var tab = window("tab", pid: 4, title: "Swift Forums", focused: 0, tab: true); tab.subtitle = "forums.swift.org"
        func run(_ list: [WindowDescriptor], _ query: String = "", expanded: Int32? = nil) -> [String] {
            WindowSearch.filtered(list, settings: settings, profile: profile, frontPID: 1, displayID: 1, query: query, expandedApp: expanded).map(\.id)
        }
        check(run([previous, current, pinned]) == ["current", "pinned", "previous"], "置顶窗口排在当前窗口之后")
        check(run([previous, current, window("other", pid: 3, title: "Music", focused: 10)]) == ["current", "previous", "other"], "没有置顶时顺序不变")
        check(!run([current, tab]).contains("tab"), "不搜索时不显示浏览器标签页")
        check(run([current, tab], "swift") == ["tab"] && run([current, tab], "forums.swift") == ["tab"], "搜索标签页标题和网址")
        profile.currentScreenOnly = true
        check(run([current, tab], "swift") == ["tab"], "标签页不受当前屏幕筛选影响")
        profile = settings.shortcuts[0]; profile.grouping = .byApp
        let second = window("second", pid: 1, title: "Notes", focused: 50)
        let grouped = WindowSearch.filtered([current, second, previous], settings: settings, profile: profile, frontPID: 1, displayID: 1, query: "")
        check(grouped.map(\.id) == ["current", "previous"] && grouped[0].groupCount == 2 && grouped[1].groupCount == 1, "按应用合成一组并统计窗口数")
        check(run([current, second, previous], expanded: 1) == ["current", "second"], "展开应用后只显示该应用的窗口")
        check(run([current, second, previous], "notes") == ["second"], "搜索时不合并应用分组")
        // Arrangement
        let screens = [WindowRect(x: 0, y: 25, width: 1440, height: 875), WindowRect(x: 1440, y: 0, width: 1920, height: 1080)]
        let mid = WindowRect(x: 100, y: 100, width: 800, height: 600)
        check(WindowArrangement.frame(.left, window: mid, screens: screens) == WindowRect(x: 0, y: 25, width: 720, height: 875), "放到左半屏")
        check(WindowArrangement.frame(.right, window: mid, screens: screens) == WindowRect(x: 720, y: 25, width: 720, height: 875), "放到右半屏")
        check(WindowArrangement.frame(.maximize, window: mid, screens: screens) == screens[0], "填满当前屏幕可用区域")
        let moved = WindowArrangement.frame(.nextScreen, window: mid, screens: screens)!
        check(moved.x >= 1440 && moved.width == 800 && moved.height == 600, "移到下一块屏幕并保持尺寸")
        let huge = WindowArrangement.frame(.nextScreen, window: WindowRect(x: 1500, y: 10, width: 1900, height: 1000), screens: screens)!
        check(huge.x == 0 && huge.width <= 1440 && huge.height <= 875 && huge.y >= 25, "移到较小的屏幕时缩小并留在屏幕内")
        check(WindowArrangement.frame(.nextScreen, window: mid, screens: [screens[0]]) == nil, "只有一块屏幕时不移动")
        // Sizing, digits, system ⌘Tab
        let small = PanelSizing.available(visibleWidth: 1440, visibleHeight: 875, chrome: 142)
        let large = PanelSizing.available(visibleWidth: 2560, visibleHeight: 1415, chrome: 142)
        check(large.width > 2000 && large.height > 1000 && small.width > 1050, "面板可用尺寸随屏幕大小增长，不再固定 1050 点")
        check(DigitKeys.index(for: 18) == 0 && DigitKeys.index(for: 25) == 8 && DigitKeys.index(for: 29) == nil, "⌘1–9 对应正确的按键")
        var commandTab = UserSettings.defaults.shortcuts
        check(!NativeSwitcherPolicy.replacesCommandTab(commandTab), "默认不接管系统 ⌘Tab")
        commandTab[0].modifiers = .command
        check(NativeSwitcherPolicy.replacesCommandTab(commandTab), "绑定 ⌘Tab 时停用系统切换器")
        commandTab[0].enabled = false
        check(!NativeSwitcherPolicy.replacesCommandTab(commandTab), "停用该组后恢复系统切换器")
    }
    static func verifyVersion20() {
        // Shape-following thumbnail cards
        let aspects = [1.78, 1.6, 0.75, 1.33, 1.6, 1.4, 1.78]
        let flow = FlowLayout.calculate(aspects: aspects, availableWidth: 1100, availableHeight: 600, preferredHeight: 150, adaptive: true)
        check(!flow.rows.isEmpty && flow.rows.flatMap { $0 } == Array(0..<7), "流式布局按顺序放下所有窗口")
        check(flow.contentWidth <= 1100.5 && flow.contentHeight <= 600.5, "流式布局不超出可用区域")
        check(flow.widths[2] < flow.widths[0], "竖长窗口的卡片比宽屏窗口窄")
        let few = FlowLayout.calculate(aspects: [1.6, 1.6], availableWidth: 1100, availableHeight: 600, preferredHeight: 150, adaptive: true)
        let many = FlowLayout.calculate(aspects: Array(repeating: 1.6, count: 30), availableWidth: 1100, availableHeight: 600, preferredHeight: 150, adaptive: true)
        check(few.thumbnailHeight > many.thumbnailHeight, "窗口少时缩略图更大，窗口多时自动缩小")
        let fixed = FlowLayout.calculate(aspects: [1.6, 1.6], availableWidth: 1100, availableHeight: 600, preferredHeight: 120, adaptive: false)
        check(fixed.thumbnailHeight == 120, "关闭自动适应时使用设置的尺寸")
        check(FlowLayout.wrap([100, 100, 100], maxWidth: 250, gap: 10) == [[0, 1], [2]], "放不下的卡片换到下一行")
        check(FlowLayout.cardWidth(aspect: .nan, thumbnailHeight: 100) == 180 && FlowLayout.cardWidth(aspect: 0.2, thumbnailHeight: 100) == 140,
              "无效或极窄的窗口比例使用安全的卡片宽度")
        let grid = FlowLayout(rows: [[0, 1, 2], [3]], widths: [100, 100, 100, 100], thumbnailHeight: 100, gap: 10)
        check(grid.vertical(from: 1, down: true) == 3 && grid.vertical(from: 3, down: false) == 1, "上下键选到相邻行中位置最接近的卡片")
        check(grid.vertical(from: 3, down: true) == 1, "最后一行向下回到第一行")
        let single = FlowLayout(rows: [[0, 1]], widths: [100, 100], thumbnailHeight: 100, gap: 10)
        check(single.vertical(from: 1, down: true) == 1, "只有一行时上下键不移动")
        let empty = FlowLayout.calculate(aspects: [], availableWidth: 900, availableHeight: 500, preferredHeight: 150, adaptive: true)
        check(empty.rows.isEmpty && empty.contentHeight == 0, "没有窗口时流式布局为空")
        // Panel sizes
        let search = PanelSizing.search(visibleWidth: 1440, visibleHeight: 875)
        check(search.width >= 760 && search.width <= 1404 && search.height >= 460 && search.height <= 839, "搜索面板尺寸在屏幕范围内")
        let tiny = PanelSizing.search(visibleWidth: 700, visibleHeight: 480)
        check(tiny.width <= 664 && tiny.height <= 444, "小屏幕上的搜索面板不超出屏幕")
        check(PanelChrome.vertical(toolbar: true, permission: false, message: false) > PanelChrome.vertical(toolbar: false, permission: false, message: false),
              "停留时显示的工具栏计入面板高度")
        // Highlighting and match kinds
        check(WindowSearch.highlights(in: "网线规划.key", query: "wx") == [0..<2], "拼音首字母高亮对应的汉字")
        check(WindowSearch.highlights(in: "收件箱", query: "shoujian") == [0..<2], "完整拼音高亮对应的汉字")
        check(WindowSearch.highlights(in: "Glance 设计参考", query: "设计") == [7..<9], "中文直接匹配高亮")
        check(WindowSearch.highlights(in: "Glance 设计参考", query: "glance sj") == [0..<6, 7..<9], "多个关键词分别高亮")
        check(WindowSearch.highlights(in: "Safari", query: "SAF") == [0..<3], "英文高亮不区分大小写")
        check(WindowSearch.highlights(in: "Safari", query: "safary").isEmpty && WindowSearch.highlights(in: "Safari", query: " ").isEmpty, "拼写容错和空查询不高亮")
        let inbox = WindowDescriptor(id: "inbox", windowID: 1, pid: 10, appName: "邮件", bundleID: "com.apple.mail", title: "收件箱", minimized: false, hidden: false, onCurrentSpace: true, displayID: 1, aspectRatio: 1.6)
        check(WindowSearch.matchKind(inbox, query: "收件") == .name && WindowSearch.matchKind(inbox, query: "shoujian") == .pinyin, "识别名称和拼音匹配")
        check(WindowSearch.matchKind(inbox, query: "sjx") == .initials && WindowSearch.matchKind(inbox, query: "com.apple.mail") == .identifier, "识别首字母和应用标识匹配")
        check(WindowSearch.matchKind(inbox, query: "mailbox missing") == nil && WindowSearch.matchKind(inbox, query: "") == nil, "不匹配或空查询没有匹配方式")
        let minimized = WindowDescriptor(id: "mini", windowID: 2, pid: 10, appName: "邮件", bundleID: "com.apple.mail", title: "草稿", minimized: true, hidden: false, onCurrentSpace: true, displayID: 1, aspectRatio: 1.6)
        var profile = UserSettings.defaults.shortcuts[0]; profile.minimized = .atEnd
        check(WindowSearch.isAtEnd(minimized, settings: .defaults, profile: profile) && !WindowSearch.isAtEnd(inbox, settings: .defaults, profile: profile), "识别放在末尾的窗口")
        // Named schemes
        let defaults = ShortcutProfile.defaults()
        check(defaults[0].displayName == "全部窗口" && defaults[1].displayName == "当前应用" && defaults[2].displayName == "快速搜索", "默认方案按设置得到名称")
        check(ShortcutProfile.gestureDefaults.displayName == "触控板", "触控板方案的名称")
        var named = defaults[0]; named.name = "  工作  "
        check(named.displayName == "工作", "自定义名称去掉首尾空格")
        named.name = "   "
        check(named.displayName == "全部窗口", "空白名称退回自动名称")
        check(defaults[0].summary == "所有应用 · 最近使用 · 松开切换", "方案摘要描述范围、排序和松键行为")
        named.name = "写作"
        check(try! JSONDecoder().decode(ShortcutProfile.self, from: JSONEncoder().encode(named)).name == "写作", "方案名称可以保存和读取")
        check(try! JSONDecoder().decode(ShortcutProfile.self, from: JSONEncoder().encode(defaults[0])).name == nil, "旧配置没有名称时使用自动名称")
        var settings = UserSettings.defaults, added: [Int] = []
        while let created = settings.withNewProfile() {
            check(created.settings.validationError() == nil, "新建第 \(created.id + 1) 个方案后设置仍然有效")
            settings = created.settings; added.append(created.id)
        }
        check(added == Array(2..<9) && settings.shortcuts.allSatisfy(\.enabled), "最多新建到九个方案")
        settings = .defaults; settings.shortcuts[0].keyCode = 49
        if let created = settings.withNewProfile() {
            check(created.settings.validationError() == nil && created.settings.shortcuts[2].keyCode != 49, "新方案避开已被占用的快捷键")
        } else { check(false, "有空位时可以新建方案") }
    }
    static func verifyPanelRecovery() {
        func captures(_ command: PanelCommand?, key: Bool = false, search: Bool = false, marked: Bool = false, registered: Bool = false) -> Bool {
            PanelKeyCapturePolicy.captures(command: command, panelIsKey: key, searching: search, markedText: marked, registeredTrigger: registered)
        }
        check(captures(.cancel, key: true) && captures(.cancel) && captures(.cancel, search: true), "Esc 在切换失败、焦点丢失和搜索时都可取消")
        check(captures(.confirm) && captures(.next) && captures(.previous), "失去面板焦点时仍可确认和选择")
        check(!captures(.confirm, key: true) && !captures(.next, key: true), "正常面板导航保留 AppKit 单一路径")
        check(!captures(.confirm, search: true) && !captures(.next, search: true), "搜索时不把其他应用的导航键抢给面板")
        check(!captures(.cancel, marked: true) && !captures(.confirm, marked: true), "输入法组合文字的取消和确认交给输入法")
        check(!captures(nil) && !captures(.close) && !captures(.quitApp), "焦点丢失时不截获文字或危险窗口操作")
        check(!captures(.next, registered: true) && !captures(.previous, registered: true), "系统注册的正反向触发仍由全局快捷键处理，避免双跳")
        var profile = UserSettings.defaults.shortcuts[0]
        check(GlobalShortcutMatch.matches(code: 48, flags: .option, profile: profile), "Option Tab 被识别为已注册触发键")
        check(GlobalShortcutMatch.matches(code: 48, flags: [.option, .shift], profile: profile), "Shift Option Tab 被识别为已注册反向触发键")
        check(!GlobalShortcutMatch.matches(code: 48, flags: [.option, .command], profile: profile), "额外修饰键不误认为注册快捷键")
        profile.enabled = false
        check(!GlobalShortcutMatch.matches(code: 48, flags: .option, profile: profile), "关闭的组合不会阻止面板按键兜底")
        profile.enabled = true; profile.keyCode = KeyChoice.modifierOnly
        check(!GlobalShortcutMatch.matches(code: KeyChoice.modifierOnly, flags: .option, profile: profile), "纯修饰键组合不占用普通按键处理")
        var pending = true
        pending = PendingReleasePolicy.keepPendingCommit(previous: pending, triggerPressed: true, triggerHeld: true)
        check(!pending, "快速松键后再次触发取消旧的待切换请求")
        check(!PendingReleasePolicy.keepPendingCommit(previous: true, triggerPressed: false, triggerHeld: true), "再次按住触发修饰键也取消旧提交")
        check(PendingReleasePolicy.keepPendingCommit(previous: true, triggerPressed: false, triggerHeld: false), "松键等待枚举时保留确认请求")
        check(!PendingReleasePolicy.keepPendingCommit(previous: false, triggerPressed: false, triggerHeld: false), "重复松键不会凭空创建确认请求")
        let active = ActivityTimerPlan(showing: true, demo: false, previews: false, thumbnails: false, largePreview: false, background: false, transient: true)
        let idle = ActivityTimerPlan(showing: false, demo: false, previews: true, thumbnails: true, largePreview: true, background: false, transient: true)
        let demo = ActivityTimerPlan(showing: true, demo: true, previews: true, thumbnails: true, largePreview: true, background: false, transient: true)
        let pinned = ActivityTimerPlan(showing: true, demo: false, previews: true, thumbnails: true, largePreview: false, background: false, transient: false)
        check(active.release && !active.preview, "松键兜底与是否开启缩略图无关")
        check(!idle.release && !idle.preview && !idle.list && !idle.background, "面板关闭后包括松键兜底在内的活动定时器全部停止")
        check(!demo.release && !pinned.release, "演示、固定和搜索面板不被松键兜底关闭")
        check(!WindowDiscoveryPolicy.includesUnboundSurface(accessibilityTrusted: true), "有辅助功能权限时不把关闭后残留画面当成可切换窗口")
        check(WindowDiscoveryPolicy.includesUnboundSurface(accessibilityTrusted: false), "授权前保留预览和权限引导的窗口信息")
        check(WindowDiscoveryPolicy.includesWindowlessApp(accessibilityTrusted: true, windowListAvailable: true, liveWindowCount: 0), "真实无窗口应用可重新打开")
        check(!WindowDiscoveryPolicy.includesWindowlessApp(accessibilityTrusted: true, windowListAvailable: false, liveWindowCount: 0), "窗口读取失败不冒充无窗口应用")
        check(!WindowDiscoveryPolicy.includesWindowlessApp(accessibilityTrusted: true, windowListAvailable: true, liveWindowCount: 1), "有真实窗口时不再生成应用占位项")
        check(WindowDiscoveryPolicy.keepsUnanswered(windowID: 5, liveWindowIDs: [5]), "没有回应的应用保留仍然存在的窗口")
        check(!WindowDiscoveryPolicy.keepsUnanswered(windowID: 6, liveWindowIDs: [5]), "没有回应的应用不保留已经关闭的窗口")
        check(WindowDiscoveryPolicy.keepsUnanswered(windowID: nil, liveWindowIDs: []), "没有窗口编号的项目等应用回应后再判断")
        check(CachedPickPolicy.freshIndex(pickedID: "b", selectedID: "b", searching: false, steps: 1, count: 4) == 1, "缓存漏掉新窗口时，用最新列表重新选中第二项")
        check(CachedPickPolicy.freshIndex(pickedID: "b", selectedID: "b", searching: false, steps: -1, count: 4) == 3, "反向触发时，用最新列表重新选中最后一项")
        check(CachedPickPolicy.freshIndex(pickedID: "b", selectedID: "c", searching: false, steps: 1, count: 4) == nil, "选择被手动改过后不再重新选中")
        check(CachedPickPolicy.freshIndex(pickedID: nil, selectedID: "b", searching: false, steps: 1, count: 4) == nil, "没有用缓存选中时不改动选择")
        check(CachedPickPolicy.freshIndex(pickedID: "b", selectedID: "b", searching: true, steps: 1, count: 4) == nil, "搜索时不改动选择")
        check(CachedPickPolicy.freshIndex(pickedID: "b", selectedID: "b", searching: false, steps: 1, count: 0) == nil, "最新列表为空时不改动选择")
        let answers = DeadlineSlots<Int>(count: 2)
        check(answers.store(7, at: 0), "截止之前的结果可以写入")
        let collected = answers.close()
        check(collected[0] == 7 && collected[1] == nil && !answers.store(8, at: 1), "截止之后的结果不写入，未回应的位置为空")
    }
}
