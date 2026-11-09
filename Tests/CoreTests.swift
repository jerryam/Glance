import Foundation

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
        print("\(passed) checks passed")
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
    }
}
