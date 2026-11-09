import SwiftUI
import AppKit
import ApplicationServices
import ServiceManagement
import Combine
import UniformTypeIdentifiers

// The settings window is built from system parts — a sidebar list, a sidebar search field, grouped
// forms and toolbar buttons — so on macOS 26 and later it takes on Liquid Glass by itself: the sidebar
// floats as glass, toolbar buttons become glass, and controls use the current system shapes.

struct PermissionStatus {
    var accessibility = AXIsProcessTrusted()
    var screenCapture = CGPreflightScreenCaptureAccess()
}

final class PermissionModel: ObservableObject {
    @Published var status = PermissionStatus()
}

/// An SF Symbol on a small amber tile, like the icons beside System Settings rows.
private struct SymbolTile: View {
    let symbol: String
    var size: CGFloat = 30
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.48, weight: .medium)).foregroundStyle(GlanceDesign.accentText)
            .frame(width: size, height: size)
            .background(GlanceDesign.selected, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct PermissionView: View {
    @StateObject private var model = PermissionModel()
    @ObservedObject private var onboarding = OnboardingProgress.shared
    var shortcutLabel = "⌥⇥"
    var requestAccessibility: () -> Void
    var requestScreen: () -> Void
    var demo: () -> Void
    var body: some View {
        SettingsForm {
            Section {
                if model.status.accessibility && model.status.screenCapture && onboarding.tried {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(.green)
                        Text("准备就绪").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Keycap(text: shortcutLabel)
                        Text("开始切换").foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("开始使用").font(.system(size: 13, weight: .semibold))
                        guideStep(1, "开启辅助功能，用来切换和控制窗口", done: model.status.accessibility)
                        guideStep(2, "开启屏幕录制，用来显示窗口预览（也可以稍后再开）", done: model.status.screenCapture)
                        guideStep(3, "试一次：按 \(shortcutLabel)；按住修饰键时继续按可以选择窗口，松开即切换", done: onboarding.tried)
                    }.padding(.vertical, 4)
                }
            }
            SettingsGroup("权限与隐私") {
                permissionRow(title: "辅助功能", subtitle: "定位、切换、还原和控制你选择的窗口。", symbol: "accessibility",
                              granted: model.status.accessibility, action: requestAccessibility)
                permissionRow(title: "屏幕录制", subtitle: "生成窗口预览。画面只留在本机内存。", symbol: "rectangle.dashed.badge.record",
                              granted: model.status.screenCapture, action: requestScreen)
                HStack(alignment: .top, spacing: 12) {
                    SymbolTile(symbol: "lock.shield")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("只在你的 Mac 上运行").font(.system(size: 13, weight: .semibold))
                        Text("无需账号，不上传画面，没有遥测。后台预览默认关闭；权限可随时在系统设置中撤销。")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.vertical, 2)
            }
            Section {
                HStack {
                    Button("查看界面演示", action: demo)
                    Spacer()
                    Button("重新检查") { model.status = PermissionStatus() }
                }
            }
        }.onAppear { model.status = PermissionStatus() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.status = PermissionStatus() }
    }
    private func guideStep(_ number: Int, _ text: String, done: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                if done { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                else { Text("\(number)").font(.system(size: 12, weight: .bold)).foregroundStyle(GlanceDesign.accentText) }
            }.frame(width: 18)
            Text(text).font(.system(size: 12)).foregroundStyle(done ? GlanceDesign.secondary : GlanceDesign.ink)
                .fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine).accessibilityValue(done ? "已完成" : "未完成")
    }
    private func permissionRow(title: String, subtitle: String, symbol: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            SymbolTile(symbol: symbol)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if granted {
                Label("已开启", systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(.green)
            } else {
                Button("前往设置", action: action).buttonStyle(GlanceButtonStyle(primary: true, compact: true))
            }
        }.padding(.vertical, 2)
    }
}

enum SettingsSection: Int, CaseIterable, Identifiable {
    // Raw values stay fixed (settings search and saved tabs use them); declaration order is the sidebar order.
    case profiles = 0, search = 1, appearance = 2, pointer = 3, menuBar = 7, exceptions = 4, permissions = 5, general = 6
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .profiles: return "切换方案"; case .search: return "搜索与按键"; case .appearance: return "外观与预览"
        case .pointer: return "鼠标与触控板"; case .menuBar: return "菜单栏"; case .exceptions: return "例外"; case .permissions: return "权限"; case .general: return "通用"
        }
    }
    var symbol: String {
        switch self {
        case .profiles: return "keyboard"; case .search: return "magnifyingglass"; case .appearance: return "rectangle.grid.2x2"
        case .pointer: return "cursorarrow.motionlines"; case .menuBar: return "menubar.rectangle"; case .exceptions: return "nosign"; case .permissions: return "lock.shield"; case .general: return "gearshape"
        }
    }
    var subtitle: String {
        switch self {
        case .profiles: return "每个方案是一组快捷键，加上它要显示的窗口和排列方式。"
        case .search: return "面板里的输入、搜索和按键，以及全局窗口快捷键。"
        case .appearance: return "卡片、预览、面板位置与动画。"
        case .pointer: return "Dock 预览、鼠标悬停、光标跟随与触控板手势。"
        case .menuBar: return "隐藏不常用的菜单栏图标，需要时再显示。"
        case .exceptions: return "选择显示哪些窗口，以及何时把快捷键让给其他应用。"
        case .permissions: return "窗口控制与预览所需的系统权限，并试一次切换。"
        case .general: return "切换方式、菜单栏、命令行与备份。"
        }
    }
}

/// Settings apply as they are edited. Changes wait a moment so dragging a slider or typing a name
/// does not re-register shortcuts on every step; invalid settings are held back with the reason shown.
final class SettingsModel: ObservableObject {
    static let generalTab = SettingsSection.general.rawValue
    static let permissionsTab = SettingsSection.permissions.rawValue
    @Published var editing: SettingsEditSession<UserSettings>
    /// What 撤销 returns to: the settings as they were when this window was opened.
    @Published private(set) var baseline: UserSettings
    /// The first enabled trigger, shown in the first-run guide.
    @Published var shortcutLabel = "⌥⇥"
    @Published var selectedTab = 0
    @Published var selectedProfile = 0
    @Published var selectedException: UUID?
    /// A note beside the title: an import result, a shortcut conflict, a launch notice.
    @Published var message = ""
    @Published var messageIsError = false
    @Published var search = ""
    @Published var searchTarget = ""
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    var applyHandler: (UserSettings) -> Void = { _ in }
    var errorsHandler: () -> [String] = { [] }
    var beforeFirstApply: () -> Void = {}
    private var appliedThisSession = false
    private var pending: DispatchWorkItem?
    var draft: UserSettings {
        get { editing.draft }
        set { editing.draft = newValue; message = ""; scheduleApply() }
    }
    var invalidReason: String? { editing.draft.validationError() }
    var canUndo: Bool { editing.draft != baseline }
    var isDirty: Bool { editing.isDirty }
    init(_ value: UserSettings) { editing = SettingsEditSession(value); baseline = value }
    /// The window opens: adopt changes made elsewhere and make them the point 撤销 returns to.
    func beginSession(_ value: UserSettings) {
        editing.synchronize(value)
        if !editing.isDirty { baseline = value; appliedThisSession = false }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
    /// A change made outside this window, such as the style buttons on the panel.
    func synchronize(_ value: UserSettings) { editing.synchronize(value) }
    private func scheduleApply() {
        pending?.cancel(); pending = nil
        guard invalidReason == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.applyNow() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
    /// Applies the pending change now. Returns false when the settings are invalid and were not applied.
    @discardableResult func applyNow() -> Bool {
        pending?.cancel(); pending = nil
        guard invalidReason == nil else { return false }
        guard editing.isDirty else { return true }
        if !appliedThisSession { appliedThisSession = true; beforeFirstApply() }
        applyHandler(editing.draft)
        editing.commit()
        let errors = errorsHandler()
        if !errors.isEmpty { note(errors.joined(separator: "\n"), error: true) }
        return true
    }
    func undo() {
        editing.draft = baseline
        message = ""
        applyNow()
    }
    func discardInvalid() { pending?.cancel(); pending = nil; editing.discard() }
    func note(_ text: String, error: Bool = false) { message = text; messageIsError = error }
}

private struct SettingsSearchTargetKey: EnvironmentKey { static let defaultValue = "" }
private extension EnvironmentValues {
    var settingsSearchTarget: String {
        get { self[SettingsSearchTargetKey.self] }
        set { self[SettingsSearchTargetKey.self] = newValue }
    }
}
/// Marks a setting so the settings search can scroll to it and highlight it.
struct SettingSearchMark: ViewModifier {
    let title: String
    @Environment(\.settingsSearchTarget) private var target
    func body(content: Content) -> some View {
        content.id(title).background {
            if target == title {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(GlanceDesign.selected)
                    .padding(.horizontal, -8).padding(.vertical, -5).allowsHitTesting(false)
            }
        }
    }
}

/// A page of settings: a grouped form, the same as System Settings uses.
struct SettingsForm<Content: View>: View {
    let content: Content
    @Environment(\.settingsSearchTarget) private var target
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        ScrollViewReader { proxy in
            Form { content }.formStyle(.grouped)
                .onAppear { if !target.isEmpty { DispatchQueue.main.async { proxy.scrollTo(target, anchor: .center) } } }
                .onChange(of: target) { _, value in if !value.isEmpty { DispatchQueue.main.async { proxy.scrollTo(value, anchor: .center) } } }
        }.toggleStyle(.switch)
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        Section {
            content
        } header: {
            Text(title).modifier(SettingSearchMark(title: title)).accessibilityAddTraits(.isHeader)
        }
    }
}

struct SettingsNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct SettingsToggle: View {
    let title: String
    @Binding var isOn: Bool
    init(_ title: String, isOn: Binding<Bool>) { self.title = title; _isOn = isOn }
    var body: some View {
        Toggle(title, isOn: $isOn).toggleStyle(.switch).modifier(SettingSearchMark(title: title))
    }
}

struct SettingsChoice<Value: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: Value
    var segmented = false
    let content: Content
    init(_ title: String, selection: Binding<Value>, segmented: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title; _selection = selection; self.segmented = segmented; self.content = content()
    }
    var body: some View {
        Group {
            if segmented {
                Picker(title, selection: $selection) { content }.pickerStyle(.segmented)
            } else {
                Picker(title, selection: $selection) { content }.pickerStyle(.menu)
            }
        }.modifier(SettingSearchMark(title: title))
    }
}

struct PreferencePicker<Value: NamedPreference>: View {
    let title: String
    @Binding var value: Value
    var segmented = false
    var body: some View {
        SettingsChoice(title, selection: $value, segmented: segmented) { ForEach(Array(Value.allCases)) { Text($0.label).tag($0) } }
    }
}

private struct SettingsSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: $value, in: range, step: step).frame(minWidth: 160, maxWidth: 280).accessibilityLabel(title)
                Text("\(Int(value)) \(unit)").monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 62, alignment: .trailing)
            }
        }.modifier(SettingSearchMark(title: title))
    }
}

/// A note over the top of the page: an import result, a shortcut conflict, or a change that could not apply.
/// It floats over the scrolling form, so on macOS 26 and later it is glass.
private struct StatusBanner: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        if let reason = model.invalidReason {
            banner(text: reason + "（未生效）", symbol: "exclamationmark.circle.fill", color: .orange) {
                Button("放弃这项修改") { model.discardInvalid() }.controlSize(.small)
            }
        } else if !model.message.isEmpty {
            banner(text: model.message, symbol: model.messageIsError ? "exclamationmark.circle.fill" : "checkmark.circle.fill",
                   color: model.messageIsError ? .orange : .green) {
                Button { model.note("") } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.borderless).help("关闭提示").accessibilityLabel("关闭提示")
            }
        }
    }
    private func banner<Trailing: View>(text: String, symbol: String, color: Color, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            trailing()
        }.padding(.horizontal, 14).padding(.vertical, 10)
            .modifier(GlanceFloatingSurface())
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 4)
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    var requestAccessibility: () -> Void
    var requestScreen: () -> Void
    var demo: () -> Void
    var recordingChanged: (Bool) -> Void = { _ in }
    /// The configuration from before the last editing session, for 通用 › 备份与迁移.
    var backup: () -> UserSettings? = { nil }
    var menuBar: MenuBarController? = nil
    private var section: SettingsSection { SettingsSection(rawValue: model.selectedTab) ?? .profiles }
    private var searching: Bool { !model.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var pageSelection: Binding<Int?> {
        Binding(get: { model.selectedTab }, set: { value in
            guard let value else { return }
            model.selectedTab = value; model.searchTarget = ""
        })
    }
    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 260)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .searchable(text: $model.search, placement: .sidebar, prompt: Text("查找设置"))
        .onChange(of: model.search) { _, _ in findSetting() }
        // No tint here: the window follows the app's accent colour (amber, from the asset catalog), so the
        // sidebar selection, switches and segmented controls match — or the user's own accent colour if set.
        .environment(\.settingsSearchTarget, model.searchTarget)
        .onAppear {
            if !AXIsProcessTrusted() || !CGPreflightScreenCaptureAccess() || !OnboardingProgress.shared.tried { model.selectedTab = SettingsModel.permissionsTab }
        }
    }
    private var sidebar: some View {
        List(selection: pageSelection) {
            Section {
                HStack(spacing: 10) {
                    GlanceMark(size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("一瞥").font(.system(size: 14, weight: .semibold))
                        Text("窗口切换与搜索").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4).accessibilityElement(children: .combine)
            }
            if searching {
                let matches = SettingSearchIndex.results(model.search)
                let heading: String = matches.isEmpty ? "没有匹配的设置" : "找到 \(matches.count) 项设置"
                Section(heading) {
                    ForEach(matches.prefix(8)) { entry in
                        Button { chooseSetting(entry) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title).lineLimit(2)
                                Text(SettingsSection(rawValue: entry.section)?.title ?? "").font(.system(size: 11)).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityLabel("\(entry.title)，\(SettingsSection(rawValue: entry.section)?.title ?? "")")
                    }
                }
            }
            Section {
                ForEach(SettingsSection.allCases) { page in
                    Label(page.title, systemImage: page.symbol).tag(page.rawValue)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 6) {
                Text("本机运行")
                Spacer()
                Text(GlanceDesign.version).monospacedDigit()
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 12)
        }
    }
    private var detail: some View {
        pageContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) { StatusBanner(model: model) }
            .navigationTitle(section.title)
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(action: demo) { Label("预览切换面板", systemImage: "play.rectangle") }
                        .help("用示例窗口打开切换面板")
                    if model.canUndo {
                        Button { model.undo() } label: { Label("撤销", systemImage: "arrow.uturn.backward").labelStyle(.titleAndIcon) }
                            .help("回到打开设置时的状态")
                    }
                }
            }
    }
    /// Under the page title: what the page is for, or that the last change took effect.
    private var subtitle: String {
        if model.invalidReason != nil { return "有一项设置未生效" }
        return model.canUndo ? "修改已生效，可以撤销" : section.subtitle
    }
    @ViewBuilder private var pageContent: some View {
        switch section {
        case .profiles: ProfilesPage(model: model, recordingChanged: recordingChanged)
        case .search: searchKeys
        case .appearance: appearance
        case .pointer: pointer
        case .menuBar:
            if let menuBar { MenuBarPage(model: model, menuBar: menuBar, recordingChanged: recordingChanged) }
        case .exceptions: exceptions
        case .permissions: PermissionView(shortcutLabel: model.shortcutLabel, requestAccessibility: requestAccessibility, requestScreen: requestScreen, demo: demo)
        case .general: general
        }
    }
    private func findSetting() {
        if let first = SettingSearchIndex.results(model.search).first { chooseSetting(first) }
        else { model.searchTarget = "" }
    }
    private func chooseSetting(_ entry: SettingSearchEntry) {
        model.selectedTab = entry.section; model.searchTarget = entry.title
    }
    private var searchKeys: some View {
        SettingsForm {
            SettingsGroup("输入") {
                PreferencePicker(title: "面板输入方式", value: $model.draft.advanced.inputMode, segmented: true)
                SettingsNote(model.draft.advanced.inputMode == .search ? "打开面板后直接输入应用名、窗口名或拼音即可搜索；窗口操作使用 ⌘W、⌘M、⌘⇧F、⌘Q、⌘H。" : "使用 W、M、F、Q、H 等单键操作窗口，按 S 或 ⌘F 开始搜索；搜索框里的字母仍用于输入。")
                SettingsToggle("显示面板搜索提示", isOn: $model.draft.advanced.showSearchHint)
            }
            SettingsGroup("搜索") {
                SettingsToggle("搜索优先显示名称直接匹配的窗口", isOn: $model.draft.advanced.searchRanking)
                SettingsToggle("容忍英文或完整拼音的一处拼写错误", isOn: $model.draft.advanced.searchTypos)
                SettingsNote("名称匹配优先于拼音、首字母和拼写容错；同等匹配优先最近使用的窗口。四个字符起支持一处错字、漏字、多字或相邻字母颠倒。")
                SettingsToggle("搜索时包含浏览器标签页", isOn: $model.draft.advanced.browserTabs)
                SettingsNote("支持 Safari、Chrome、Chrome Beta、Edge、Brave、Vivaldi、Opera 和 Arc，也支持提供相同脚本接口的其他 Chromium 浏览器，比如部分国产浏览器。只在搜索时读取正在运行的浏览器的标签页标题和网址，不读取网页内容；第一次使用时，macOS 会询问是否允许一瞥控制该浏览器。")
                SettingsToggle("搜索时包含未打开的应用", isOn: $model.draft.advanced.searchApps)
                SettingsToggle("搜索时包含系统设置页面", isOn: $model.draft.advanced.searchSettingsPages)
                SettingsNote("像 Windows 的开始菜单一样：输入应用或设置的名称（中文、拼音或英文都可以），回车即可打开，例如“wx”打开微信、“蓝牙”打开蓝牙设置。匹配程度相同时排在已打开的窗口后面，每次最多列出 \(WindowSearch.launcherLimit) 项。")
            }
            SettingsGroup("选择窗口") {
                SettingsToggle("按 Shift 单独反向选择", isOn: $model.draft.advanced.shiftSelectsPrevious)
                SettingsToggle("使用方向键选择窗口", isOn: $model.draft.advanced.arrowKeys)
                SettingsToggle("使用 H / J / K / L 选择窗口", isOn: $model.draft.advanced.vimKeys).disabled(model.draft.advanced.inputMode == .search)
                SettingsNote("H / J / K / L 只在传统单键操作模式中生效，并优先于同键的窗口操作。")
            }
            SettingsGroup("面板中的快捷键 · 点击按键可重新录制") {
                ForEach($model.draft.advanced.bindings) { $binding in
                    LabeledContent(binding.command.label) {
                        HStack(spacing: 10) {
                            KeyRecorder(code: $binding.keyCode, modifiers: $binding.modifiers, recordingChanged: recordingChanged).frame(width: 140)
                            Toggle(binding.command.label, isOn: $binding.enabled).labelsHidden().toggleStyle(.switch)
                        }
                    }
                }
                SettingsNote("直接输入搜索模式中，普通文字按键用于搜索；这里录制的单键操作在传统模式中生效，带修饰键的组合在两种模式中都可用。停用一项操作也会停用它的 ⌘ 快捷键。")
            }
            SettingsGroup("全局窗口快捷键") {
                SettingsToggle("启用全局窗口快捷键", isOn: $model.draft.windowShortcuts.enabled)
                SettingsNote("不用打开面板，在任何应用里调整当前窗口的位置和大小；面板打开时作用于选中的窗口。“还原”回到一瞥调整之前的位置。需要辅助功能权限，一瞥自己的窗口除外；没能调整时会发出提示音。")
                if model.draft.windowShortcuts.enabled {
                    ForEach($model.draft.windowShortcuts.shortcuts) { $shortcut in
                        LabeledContent(shortcut.command.label) {
                            HStack(spacing: 10) {
                                KeyRecorder(code: $shortcut.hotkey.keyCode, modifiers: $shortcut.hotkey.modifiers, recordingChanged: recordingChanged, allowsModifierOnly: false).frame(width: 140)
                                Toggle(shortcut.command.label, isOn: $shortcut.hotkey.enabled).labelsHidden().toggleStyle(.switch)
                            }
                        }
                    }
                }
            }
        }
    }
    private var appearance: some View {
        SettingsForm {
            SettingsGroup("外观") {
                SettingsChoice("显示样式", selection: $model.draft.style, segmented: true) { ForEach(SwitcherStyle.allCases) { Text($0.label).tag($0) } }
                SettingsChoice("主题", selection: $model.draft.theme, segmented: true) { ForEach(ThemeChoice.allCases) { Text($0.label).tag($0) } }
                SettingsNote(GlanceDesign.usesLiquidGlass
                             ? "面板使用系统的液态玻璃材质，会随背后的内容变化；开启“辅助功能 › 显示 › 降低透明度”后改为不透明背景。"
                             : "面板使用系统的半透明材质；开启“辅助功能 › 显示 › 降低透明度”后改为不透明背景。")
                PreferencePicker(title: "显示标题", value: $model.draft.advanced.titleDisplay)
                PreferencePicker(title: "过长标题省略位置", value: $model.draft.advanced.titleCut, segmented: true)
                SettingsToggle("卡片与列表自动适应窗口数量", isOn: $model.draft.adaptiveThumbnails)
                SettingsSlider(title: "窗口内容参考尺寸", value: $model.draft.thumbnailWidth, range: 150...360, step: 10, unit: "点")
                    .disabled(model.draft.adaptiveThumbnails)
                SettingsNote("缩略图卡片的宽度跟随窗口的形状：竖长的聊天窗口窄一些，宽屏编辑器宽一些。")
            }
            SettingsGroup("卡片") {
                SettingsToggle("显示窗口状态图标", isOn: $model.draft.advanced.statusBadges)
                SettingsToggle("显示桌面编号", isOn: $model.draft.advanced.spaceNumbers)
                SettingsToggle("悬停时在卡片上显示关闭、最小化和全屏按钮", isOn: $model.draft.advanced.tileButtons)
                SettingsToggle("在应用图标上显示 Dock 未读数", isOn: $model.draft.advanced.dockBadges)
                SettingsToggle("停留或搜索时显示 ⌘1–9 编号", isOn: $model.draft.advanced.numberHints)
            }
            SettingsGroup("预览") {
                SettingsToggle("面板打开时更新选中窗口的预览", isOn: $model.draft.livePreviews)
                SettingsToggle("自动放大选中窗口的预览", isOn: $model.draft.advanced.autoPreview)
                SettingsToggle("后台保留最新预览（约每 5 秒更新）", isOn: $model.draft.advanced.backgroundPreviews)
                SettingsNote("后台预览默认关闭。开启后可为隐藏、最小化窗口保留最近的画面；图像只在本机内存中缓存。")
                SettingsToggle("放大预览淡入", isOn: $model.draft.advanced.previewFadeIn)
            }
            SettingsGroup("位置与动画") {
                PreferencePicker(title: "面板显示在", value: $model.draft.advanced.panelScreen)
                SettingsSlider(title: "显示延迟", value: Binding(get: { Double(model.draft.advanced.showDelay) }, set: { model.draft.advanced.showDelay = Int($0) }),
                               range: 0...900, step: 25, unit: "毫秒")
                SettingsToggle("关闭面板时淡出", isOn: $model.draft.advanced.fadeOut)
            }
        }
    }
    private var pointer: some View {
        SettingsForm {
            SettingsGroup("Dock 预览") {
                SettingsToggle("指针停在 Dock 图标上时显示窗口预览", isOn: $model.draft.dockPreview.enabled)
                if model.draft.dockPreview.enabled {
                    SettingsChoice("显示前等待", selection: $model.draft.dockPreview.delay) {
                        ForEach([0, 150, 300, 500, 800], id: \.self) { Text($0 == 0 ? "立即" : "\($0) 毫秒").tag($0) }
                    }
                    SettingsToggle("包含最小化的窗口", isOn: $model.draft.dockPreview.includeMinimized)
                }
                SettingsNote("像 Windows 任务栏一样：点按预览切换到那个窗口，悬停时点 × 关闭它；在 Dock 上左右移动可直接换到其他应用。需要辅助功能权限，预览图需要屏幕录制权限。")
            }
            SettingsGroup("鼠标") {
                SettingsToggle("鼠标悬停时改变选中窗口", isOn: $model.draft.mouseHoverEnabled)
                PreferencePicker(title: "切换后移动鼠标", value: $model.draft.advanced.followCursor)
            }
            SettingsGroup("触控板") {
                PreferencePicker(title: "触控板手势", value: $model.draft.advanced.gesture)
                if model.draft.advanced.gesture != .disabled {
                    let conflict = GestureConflict.warning(for: model.draft.advanced.gesture)
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: conflict == nil ? "info.circle" : "exclamationmark.triangle")
                            .foregroundStyle(conflict == nil ? GlanceDesign.secondary : Color.orange)
                        SettingsNote(conflict ?? "系统自己的三指、四指手势会先于一瞥识别。如果切换时同时打开了调度中心或切换了全屏应用，请在触控板设置中改用其他手指数，或关闭对应的系统手势。")
                        Spacer(minLength: 8)
                        Button("打开触控板设置") { GestureConflict.openTrackpadSettings() }.controlSize(.small)
                    }
                    SettingsToggle("尝试拦截已识别的手势（实验性）", isOn: $model.draft.advanced.gestureAvoidsSystem)
                    SettingsToggle("手势使用独立窗口方案", isOn: Binding(get: { model.draft.advanced.independentGesture != nil }, set: {
                        model.draft.advanced.independentGesture = $0 ? .gestureDefaults : nil
                        if !$0 && model.selectedProfile == 9 { model.selectedProfile = model.draft.advanced.gestureProfile }
                    }))
                    if model.draft.advanced.independentGesture != nil {
                        HStack {
                            SettingsNote("触控板方案出现在“切换方案”列表里，可以单独设置窗口范围、排序和外观。")
                            Spacer()
                            Button("编辑触控板方案") { model.selectedTab = SettingsSection.profiles.rawValue; model.selectedProfile = 9 }
                                .controlSize(.small)
                        }
                    } else {
                        SettingsChoice("手势沿用的方案", selection: $model.draft.advanced.gestureProfile) {
                            ForEach(model.draft.shortcuts.filter { $0.enabled || $0.id == model.draft.advanced.gestureProfile }) { profile in
                                Text(profile.displayName).tag(profile.id)
                            }
                        }
                    }
                    SettingsNote("滑动选择窗口，抬手按方案的松键行为处理。手势默认关闭。")
                }
                SettingsToggle("切换时触控板震动反馈", isOn: $model.draft.advanced.haptics)
            }
        }
    }
    private var exceptions: some View {
        SettingsForm {
            SettingsGroup("默认筛选 · 每个方案可单独覆盖") {
                SettingsToggle("包含最小化窗口", isOn: $model.draft.showMinimized)
                SettingsToggle("包含已隐藏应用的窗口", isOn: $model.draft.showHidden)
                SettingsToggle("包含没有窗口的应用（放在末尾）", isOn: $model.draft.showWindowlessApps)
            }
            SettingsGroup("应用例外") {
                HStack(spacing: 10) {
                    Menu("添加正在运行的应用") {
                        ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }, id: \.processIdentifier) { app in
                            Button(app.localizedName ?? "应用") { addException(bundle: app.bundleIdentifier ?? "", name: app.localizedName ?? "") }
                        }
                    }.fixedSize()
                    Button("从应用文件添加…") {
                        let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]; panel.canChooseDirectories = false
                        if panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier {
                            addException(bundle: id, name: url.deletingPathExtension().lastPathComponent)
                        }
                    }
                    Spacer(minLength: 0)
                }
                ForEach($model.draft.advanced.exceptions) { $rule in
                    DisclosureGroup(exceptionTitle(rule)) {
                        TextField("应用标识", text: $rule.bundleID, prompt: Text("末尾可用 *"))
                        PreferencePicker(title: "隐藏窗口", value: $rule.hide)
                        if rule.hide == .title {
                            TextField("标题关键词", text: Binding(get: { rule.titles.replacingOccurrences(of: "\n", with: ",") },
                                set: { rule.titles = $0.replacingOccurrences(of: ",", with: "\n").replacingOccurrences(of: "，", with: "\n") }),
                                prompt: Text("用逗号分隔"))
                        }
                        PreferencePicker(title: "全局快捷键", value: $rule.ignore)
                        HStack {
                            Spacer()
                            Button("删除此规则", role: .destructive) { model.draft.advanced.exceptions.removeAll { $0.id == rule.id } }.controlSize(.small)
                        }
                    }
                }
                SettingsNote("“不响应”会把快捷键交还给当前应用；默认对常见远程桌面和虚拟机应用使用“全屏时不响应”。")
            }
            SettingsGroup("窗口关键词排除") {
                SettingsNote("每行填写一个应用名称、应用标识或窗口标题关键词。")
                TextEditor(text: $model.draft.exclusions).frame(height: 100).font(.system(size: 13))
                    .scrollContentBackground(.hidden).padding(6)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityLabel("窗口关键词排除")
            }
        }
    }
    private var general: some View {
        SettingsForm {
            SettingsGroup("切换方式") {
                PreferencePicker(title: "切换窗口的方式", value: $model.draft.advanced.focusMethod)
                SettingsNote("系统窗口服务直接把选中的窗口设为前台并接收键盘输入，跨桌面或同一应用有多个窗口时更准确；系统不提供这个接口时会自动改用辅助功能接口。")
                SettingsToggle("VoiceOver 开启时保持面板打开", isOn: $model.draft.advanced.voiceOverKeepsOpen)
            }
            SettingsGroup("菜单栏与启动") {
                SettingsToggle("显示菜单栏图标", isOn: $model.draft.advanced.showMenuIcon)
                PreferencePicker(title: "菜单栏图标", value: $model.draft.advanced.menuIcon, segmented: true)
                SettingsToggle("登录时自动启动", isOn: $model.launchAtLogin).onChange(of: model.launchAtLogin) { _, enabled in
                    do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                    catch { model.note("无法设置自动启动：\(error.localizedDescription)", error: true); model.launchAtLogin = SMAppService.mainApp.status == .enabled }
                }
            }
            SettingsGroup("命令行") {
                SettingsToggle("允许命令行列出和切换窗口", isOn: $model.draft.advanced.commandLineEnabled)
                SettingsNote("开启后，本机上的任何程序都能通过 Glance --list 读到所有窗口标题并切换窗口，而不需要自己申请权限。不用命令行时建议保持关闭。")
            }
            SettingsGroup("备份与迁移") {
                HStack(spacing: 8) {
                    Button("导出设置…") { exportSettings() }
                    Button("导入设置…") { importSettings() }
                    Button("恢复到上次修改前") { restoreBackup() }
                    Spacer(minLength: 8)
                    Button("恢复全部默认") { model.draft = .defaults; model.note("已恢复默认设置，可以点右上角的“撤销”退回。") }
                }
                SettingsNote("导出文件包含快捷键、外观、例外规则等全部设置，可用于备份或换电脑。导入、恢复都会立即生效，可以点右上角的“撤销”回到打开设置时的状态。")
            }
        }
    }
    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "一瞥设置.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SettingsArchive.encode(model.draft).write(to: url, options: .atomic)
            model.note("已导出到“\(url.lastPathComponent)”。")
        } catch { model.note("导出失败：\(error.localizedDescription)", error: true) }
    }
    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            model.draft = try SettingsArchive.decode(Data(contentsOf: url))
            model.note("已导入“\(url.lastPathComponent)”。")
        } catch { model.note("无法导入这个文件：它不是一瞥导出的设置。", error: true) }
    }
    private func restoreBackup() {
        guard let previous = backup() else { model.note("还没有可恢复的备份。", error: true); return }
        model.draft = previous
        model.note("已恢复到上次修改前的设置。")
    }
    private func addException(bundle: String, name: String) {
        guard !bundle.isEmpty else { return }
        if model.draft.advanced.exceptions.contains(where: { $0.bundleID == bundle }) { model.note("该应用已有例外规则。", error: true); return }
        var rule = AppException(); rule.bundleID = bundle; rule.name = name
        model.draft.advanced.exceptions.append(rule)
    }
    private func exceptionTitle(_ rule: AppException) -> String {
        if !rule.name.isEmpty { return rule.name }
        let names = ["com.apple.ScreenSharing": "屏幕共享", "com.microsoft.rdc.macos": "微软远程桌面",
                     "com.teamviewer.TeamViewer": "TeamViewer", "com.vmware.fusion": "VMware Fusion",
                     "com.utmapp.UTM": "UTM", "com.parallels.*": "Parallels Desktop",
                     "org.virtualbox.app.VirtualBoxVM": "VirtualBox", "com.netease.uuremote": "UU 远程"]
        return names[rule.bundleID] ?? rule.bundleID
    }
}


// MARK: - Switching schemes

/// The schemes on the left, the selected one's settings on the right; both are grouped forms.
private struct ProfilesPage: View {
    @ObservedObject var model: SettingsModel
    var recordingChanged: (Bool) -> Void
    private var enabled: [ShortcutProfile] { model.draft.shortcuts.filter(\.enabled) }
    /// The scheme being edited: the selected one if it is still in the list, otherwise the first.
    private var currentID: Int {
        if model.selectedProfile == 9 && model.draft.advanced.independentGesture != nil { return 9 }
        if model.draft.shortcuts.contains(where: { $0.id == model.selectedProfile && $0.enabled }) { return model.selectedProfile }
        return enabled.first?.id ?? 0
    }
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Form {
                Section("所有方案") {
                    ForEach(enabled) { profile in
                        row(title: profile.displayName, key: profile.displayShortcut, summary: profile.summary, selected: currentID == profile.id) {
                            model.selectedProfile = profile.id
                        }
                    }
                    if model.draft.advanced.gesture != .disabled {
                        let independent = model.draft.advanced.independentGesture
                        let followed = model.draft.shortcuts.first { $0.id == model.draft.advanced.gestureProfile }
                        row(title: "触控板", key: model.draft.advanced.gesture.label,
                            summary: independent?.summary ?? "沿用“\(followed?.displayName ?? "第一个方案")”",
                            selected: currentID == 9) {
                            if independent != nil { model.selectedProfile = 9 }
                            else { model.selectedProfile = model.draft.advanced.gestureProfile }
                        }
                    }
                }
                Section {
                    if model.draft.withNewProfile() != nil {
                        Button {
                            if let created = model.draft.withNewProfile() { model.draft = created.settings; model.selectedProfile = created.id }
                        } label: { Label("新建方案", systemImage: "plus") }
                    } else {
                        SettingsNote("最多 9 个方案。")
                    }
                }
            }.formStyle(.grouped).frame(width: 290)
            editor
        }
    }
    @ViewBuilder private var editor: some View {
        if currentID == 9, model.draft.advanced.independentGesture != nil {
            ProfileEditor(profile: Binding(get: { model.draft.advanced.independentGesture ?? .gestureDefaults },
                                           set: { model.draft.advanced.independentGesture = $0 }),
                          recordingChanged: recordingChanged, canDelete: false, onDelete: {})
        } else if let index = model.draft.shortcuts.firstIndex(where: { $0.id == currentID }) {
            ProfileEditor(profile: $model.draft.shortcuts[index], recordingChanged: recordingChanged,
                          canDelete: enabled.count > 1 && model.draft.shortcuts[index].enabled) {
                model.draft.shortcuts[index].enabled = false
                model.selectedProfile = model.draft.shortcuts.first(where: \.enabled)?.id ?? 0
            }
        }
    }
    private func row(title: String, key: String, summary: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                Keycap(text: key)
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.accentColor)
                    .frame(width: 12).opacity(selected ? 1 : 0)
            }.padding(.vertical, 2).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("\(title)，\(key)，\(summary)").accessibilityValue(selected ? "正在编辑" : "")
    }
}

struct ProfileEditor: View {
    @Binding var profile: ShortcutProfile
    var recordingChanged: (Bool) -> Void
    var canDelete: Bool
    var onDelete: () -> Void
    private var gesture: Bool { profile.id == 9 }
    var body: some View {
        SettingsForm {
            SettingsGroup("方案") {
                if !gesture {
                    TextField("名称", text: Binding(get: { profile.name ?? "" }, set: { profile.name = $0.isEmpty ? nil : $0 }),
                              prompt: Text(profile.suggestedName))
                        .accessibilityLabel("方案名称")
                    LabeledContent("快捷键") {
                        HStack(spacing: 10) {
                            Text("加 ⇧ 反向").font(.system(size: 12)).foregroundStyle(.secondary)
                            KeyRecorder(code: $profile.keyCode, modifiers: $profile.modifiers, recordingChanged: recordingChanged).frame(width: 150)
                        }
                    }.modifier(SettingSearchMark(title: "快捷键"))
                    SettingsNote("点击录制，按新的组合；只按修饰键时抬手完成录制，Esc 取消。也可以单独使用 F1–F20。")
                    if NativeSwitcherPolicy.replacesCommandTab([profile]) {
                        SettingsNote("使用 ⌘Tab 时，一瞥会暂时停用系统自带的应用切换器；改用其他快捷键或退出一瞥后自动恢复。")
                    }
                    if profile.usesBareKey {
                        SettingsNote("单独的功能键没有可松开的修饰键：面板保持打开，再按一次选择下一个，按回车切换。部分键盘需要同时按 fn 才会发送 F1–F12。")
                    }
                }
                SettingsChoice(gesture ? "抬手之后" : "松开修饰键之后", selection: Binding(get: { profile.releaseBehavior }, set: { profile.release = $0 }), segmented: true) {
                    ForEach(ReleaseBehavior.allCases) { Text($0.label).tag($0) }
                }
            }
            SettingsGroup("显示哪些窗口") {
                SettingsChoice("应用", selection: $profile.scope) { ForEach(WindowScope.allCases) { Text($0.label).tag($0) } }
                SettingsChoice("桌面", selection: Binding(get: { profile.spaceScope }, set: { profile.spaces = $0 }), segmented: true) {
                    ForEach(SpaceScope.allCases) { Text($0.label).tag($0) }
                }
                SettingsToggle("只显示当前屏幕的窗口", isOn: $profile.currentScreenOnly)
                visibility("最小化窗口", value: $profile.minimized)
                visibility("隐藏应用的窗口", value: $profile.hidden)
                SettingsChoice("全屏窗口", selection: $profile.fullscreen) { ForEach(VisibilityPolicy.allCases) { Text($0.label).tag($0) } }
                visibility("没有窗口的应用", value: $profile.windowless)
                SettingsToggle("分别显示系统窗口标签页", isOn: $profile.separateTabs)
                SettingsNote("标签页取决于应用提供的辅助功能接口。“最近创建”按一瞥首次发现窗口的时间排序。")
            }
            SettingsGroup("排序与外观") {
                PreferencePicker(title: "排序", value: $profile.order)
                PreferencePicker(title: "应用分组", value: $profile.grouping)
                SettingsChoice("样式", selection: $profile.styleOverride, segmented: true) {
                    Text("跟随全局").tag(Optional<SwitcherStyle>.none)
                    ForEach(SwitcherStyle.allCases) { Text($0.label).tag(Optional($0)) }
                }
                SettingsChoice("主题", selection: $profile.themeOverride) {
                    Text("跟随全局").tag(Optional<ThemeChoice>.none)
                    ForEach(ThemeChoice.allCases) { Text($0.label).tag(Optional($0)) }
                }
                SettingsChoice("自动适应尺寸", selection: $profile.adaptiveOverride) {
                    Text("跟随全局").tag(Optional<Bool>.none); Text("开启").tag(Optional(true)); Text("关闭").tag(Optional(false))
                }
                SettingsToggle("单独设置卡片尺寸", isOn: Binding(get: { profile.widthOverride != nil }, set: { profile.widthOverride = $0 ? 230 : nil }))
                if profile.widthOverride != nil {
                    SettingsSlider(title: "卡片尺寸", value: Binding(get: { profile.widthOverride ?? 230 }, set: { profile.widthOverride = $0 }),
                                   range: 150...360, step: 10, unit: "点")
                }
                SettingsChoice("自动放大预览", selection: $profile.previewOverride) {
                    Text("跟随全局").tag(Optional<Bool>.none); Text("开启").tag(Optional(true)); Text("关闭").tag(Optional(false))
                }
            }
            if canDelete {
                Section {
                    HStack {
                        Spacer()
                        Button("删除这个方案", role: .destructive, action: onDelete)
                    }
                }
            }
        }.id(profile.id)
    }
    private func visibility(_ title: String, value: Binding<VisibilityPolicy?>) -> some View {
        SettingsChoice(title, selection: value) {
            Text("跟随全局").tag(Optional<VisibilityPolicy>.none)
            ForEach(VisibilityPolicy.allCases) { Text($0.label).tag(Optional($0)) }
        }
    }
}
