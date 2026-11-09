import SwiftUI
import AppKit
import ApplicationServices

/// 设置 › 菜单栏: which apps' icons stay in the menu bar, and how hidden ones come back.
struct MenuBarPage: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var menuBar: MenuBarController
    var recordingChanged: (Bool) -> Void
    @State private var target: MenuBarSection?

    private var settings: MenuBarSettings { model.draft.menuBar }
    private var assignable: [MenuBarItem] { menuBar.items.filter(\.assignable) }
    private var fixed: [MenuBarItem] { menuBar.items.filter { !$0.assignable && $0.id != "fixed:own" && $0.present } }

    var body: some View {
        SettingsForm {
            if !MenuBarController.isSupported {
                Section {
                    Label("隐藏菜单栏图标需要 macOS 27 或更高版本。", systemImage: "info.circle").foregroundStyle(.secondary)
                }
            } else {
                Section { status }
                Section {
                    SettingsToggle("管理菜单栏图标", isOn: $model.draft.menuBar.enabled)
                    SettingsNote("把不常用的图标拖进“隐藏”或“始终隐藏”。同一个应用的图标会一起显示或隐藏；按住 ⌘ 拖动菜单栏里的图标可以调整顺序。")
                }
                if settings.enabled {
                    ForEach(MenuBarSection.allCases) { section in
                        Section {
                            tray(section)
                        } header: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(section.label)
                                Text(section.summary).font(.system(size: 11, weight: .regular)).foregroundStyle(.secondary)
                            }.modifier(SettingSearchMark(title: section == .visible ? "图标分组" : section.label))
                        }
                    }
                    if !fixed.isEmpty {
                        SettingsGroup("由系统管理的图标") {
                            ChipFlow(spacing: 8) {
                                ForEach(fixed) { item in chip(item, draggable: false) }
                            }.padding(.vertical, 4)
                            SettingsNote("时钟、控制中心和 Siri 由 macOS 管理，不能单独隐藏。隐藏其他图标时，“专注模式”等系统图标也可能一起收起，这是系统的限制。")
                        }
                    }
                    behaviour
                }
            }
        }
        .onAppear { menuBar.scan() }
    }

    // MARK: Status

    @ViewBuilder private var status: some View {
        let hiddenApps = settings.sections.filter { $0.value != .visible }.count
        if !menuBar.available {
            note("这台 Mac 的系统没有提供隐藏菜单栏图标的接口，所有图标保持显示。", symbol: "exclamationmark.triangle.fill", color: .orange)
        } else if !AXIsProcessTrusted() {
            HStack {
                note("需要辅助功能权限才能读取菜单栏里的图标。", symbol: "lock.shield", color: .orange)
                Spacer()
                Button("前往权限页") { model.selectedTab = SettingsModel.permissionsTab }
            }
        } else if let problem = menuBar.problem {
            HStack {
                note(problem, symbol: "exclamationmark.triangle.fill", color: .orange)
                Spacer()
                Button("重试") { menuBar.retry() }
            }
        } else {
            HStack {
                note(!settings.enabled ? "已关闭，所有图标都会显示。"
                     : hiddenApps == 0 ? "还没有隐藏任何图标。" : "正在隐藏 \(hiddenApps) 项的图标。",
                     symbol: settings.enabled && hiddenApps > 0 ? "checkmark.circle.fill" : "menubar.rectangle",
                     color: settings.enabled && hiddenApps > 0 ? .green : .secondary)
                Spacer()
                if menuBar.scanning { ProgressView().controlSize(.small) }
                Button("重新读取") { menuBar.scan() }.disabled(menuBar.scanning)
            }
        }
    }

    private func note(_ text: String, symbol: String, color: Color) -> some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: symbol).foregroundStyle(color) }
    }

    // MARK: Sections

    private func items(in section: MenuBarSection) -> [MenuBarItem] {
        assignable.filter { settings.section(of: $0.id) == section }
    }

    private func move(_ ids: [String], to section: MenuBarSection) -> Bool {
        let valid = ids.filter { MenuBarPolicy.isAssignable($0) }
        guard !valid.isEmpty else { return false }
        for id in valid { model.draft.menuBar.sections[id] = section == .visible ? nil : section }
        return true
    }

    private func tray(_ section: MenuBarSection) -> some View {
        let list = items(in: section)
        let highlighted = target == section
        return Group {
            if list.isEmpty {
                Text(section == .visible ? "所有图标都已隐藏。" : "把图标拖到这里。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            } else {
                ChipFlow(spacing: 8) {
                    ForEach(list) { item in chip(item, draggable: true) }
                }.padding(.vertical, 4)
            }
        }
        .contentShape(Rectangle())
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(highlighted ? Color.accentColor : Color.clear, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .background(highlighted ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(-6)
        .dropDestination(for: String.self) { ids, _ in move(ids, to: section) } isTargeted: { inside in
            if inside { target = section } else if target == section { target = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(section.label)：\(list.count) 项")
    }

    @ViewBuilder private func chip(_ item: MenuBarItem, draggable: Bool) -> some View {
        let view = HStack(spacing: 6) {
            Group {
                if let icon = menuBar.icon(for: item) { Image(nsImage: icon).resizable().interpolation(.high).scaledToFit() }
                else { Image(systemName: "app.dashed").foregroundStyle(.secondary) }
            }.frame(width: 18, height: 18)
            Text(item.name).font(.system(size: 12)).lineLimit(1)
            if !item.present && item.bundle != nil {
                Text("未运行").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9).frame(height: 28)
        .background(.quaternary, in: Capsule(style: .continuous))
        .opacity(item.present || item.bundle == nil ? 1 : 0.6)
        .help(item.bundle ?? item.name)
        if draggable {
            view
                .draggable(item.id) {
                    Label(item.name, systemImage: "menubar.rectangle").padding(6).background(.regularMaterial, in: Capsule())
                }
                .contextMenu {
                    ForEach(MenuBarSection.allCases) { section in
                        Button("移到“\(section.label)”") { _ = move([item.id], to: section) }
                            .disabled(settings.section(of: item.id) == section)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(settings.section(of: item.id).label)
                .accessibilityActions {
                    ForEach(MenuBarSection.allCases) { section in
                        Button("移到“\(section.label)”") { _ = move([item.id], to: section) }
                    }
                }
        } else {
            view.accessibilityElement(children: .combine)
        }
    }

    // MARK: Behaviour

    private var behaviour: some View {
        SettingsGroup("显示方式") {
            SettingsNote("点按菜单栏里的一瞥图标显示“隐藏”组的图标，按住 ⌥ 点按显示全部；右键点按打开一瞥菜单。")
            SettingsToggle("指针停在菜单栏空白处时显示", isOn: $model.draft.menuBar.revealOnHover)
            SettingsChoice("点按或快捷键显示后", selection: $model.draft.menuBar.rehideSeconds) {
                ForEach(MenuBarSettings.rehideChoices, id: \.self) { seconds in
                    Text(seconds == 0 ? "保持显示，再点一次收起" : "\(seconds) 秒后自动收回").tag(seconds)
                }
            }
            SettingsNote("指针停在菜单栏里或某个菜单还开着时不会收起；悬停或从搜索打开的图标在指针离开菜单栏后收起。")
            hotkeyRow("显示或收起隐藏的图标", hotkey: $model.draft.menuBar.toggleHotkey)
            hotkeyRow("显示全部图标", hotkey: $model.draft.menuBar.showAllHotkey)
            SettingsToggle("在搜索中包含菜单栏图标", isOn: $model.draft.menuBar.searchable)
            SettingsNote("在一瞥的搜索里输入应用名称（支持拼音），回车即可打开它的菜单栏菜单；隐藏的图标会先显示出来。")
        }
    }

    private func hotkeyRow(_ title: String, hotkey: Binding<MenuBarHotkey>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                KeyRecorder(code: hotkey.keyCode, modifiers: hotkey.modifiers, recordingChanged: recordingChanged, allowsModifierOnly: false)
                    .frame(width: 140)
                Toggle(title, isOn: hotkey.enabled).labelsHidden().toggleStyle(.switch)
            }
        }.modifier(SettingSearchMark(title: title))
    }
}

/// Lays chips out in rows, wrapping to the width available.
struct ChipFlow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { y += row + spacing; x = 0; row = 0 }
            x += size.width + spacing; row = max(row, size.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { y += row + spacing; x = bounds.minX; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; row = max(row, size.height)
        }
    }
}
