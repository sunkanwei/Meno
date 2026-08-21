import SwiftUI

@MainActor
struct KeyboardShortcutsSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "键盘快捷键",
                subtitle: "为 Finder 增补常用键盘操作，并提供独立的系统快捷键。"
            )
            finderFeatureSection
            finderShortcutsSection
            systemShortcutsSection
        }
    }

    private var finderFeatureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionTitle("Finder")
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("启用 Finder 快捷键")
                    Spacer()
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(model.finderShortcutsStatus.title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Toggle(
                        "Finder",
                        isOn: Binding(
                            get: { model.finderShortcutsEnabled },
                            set: { model.setFinderShortcutsEnabled($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 46)

                if case let .failed(message) = model.finderShortcutsStatus {
                    Divider()
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if model.hasCutState {
                    Divider()
                    Label("当前有一组待移动文件", systemImage: "scissors")
                        .font(.callout)
                        .foregroundStyle(.blue)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .settingsPanel()
        }
    }

    private var finderShortcutsSection: some View {
        VStack(spacing: 0) {
            Group {
                shortcutRow(
                    title: "返回上一级",
                    key: "Backspace",
                    isOn: Binding(
                        get: { model.goToParentEnabled },
                        set: { model.setGoToParentEnabled($0) }
                    )
                )
                Divider()
                shortcutRow(
                    title: "打开所选项目",
                    key: "Enter",
                    help: "只在恰好选中一个文件、文件夹或应用时生效；空格仍用于快速预览。",
                    isOn: Binding(
                        get: { model.openSelectionEnabled },
                        set: { model.setOpenSelectionEnabled($0) }
                    )
                )
                Divider()
                shortcutRow(
                    title: "重命名",
                    key: "F2",
                    help: "如果 F2 被系统用于亮度调节，请使用 Fn+F2。",
                    isOn: Binding(
                        get: { model.renameEnabled },
                        set: { model.setRenameEnabled($0) }
                    )
                )
                Divider()
                shortcutRow(
                    title: "文件剪切与移动",
                    key: "Ctrl+X / Ctrl+V",
                    help: "按系统修饰键交换后的实体 Ctrl 操作；Meno 会把复制结果安全转换为 Finder 的文件移动操作。",
                    isOn: Binding(
                        get: { model.cutAndMoveEnabled },
                        set: { model.setCutAndMoveEnabled($0) }
                    )
                )
                Divider()
                shortcutRow(
                    title: "移到废纸篓",
                    key: "Delete",
                    help: "Finder 窗口和桌面均可使用。外接键盘直接按独立 Delete 键；MacBook 键盘通常使用 Fn+Delete。普通 Backspace 始终是返回上一级，不提供永久删除。",
                    isOn: Binding(
                        get: { model.moveToTrashEnabled },
                        set: { model.setMoveToTrashEnabled($0) }
                    )
                )
            }
            .disabled(!model.finderShortcutsEnabled)
        }
        .settingsPanel()
    }

    private var systemShortcutsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionTitle("系统操作")
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Toggle(
                        "打开活动监视器",
                        isOn: Binding(
                            get: { model.activityMonitorShortcutEnabled },
                            set: { model.setActivityMonitorShortcutEnabled($0) }
                        )
                    )
                    .toggleStyle(.checkbox)
                    InfoHint("系统级快捷键，独立于 Finder 开关。")
                    Spacer()
                    Text(ActivityMonitorShortcutController.shortcutLabel)
                        .font(.system(.callout, design: .rounded).weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 180, alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 44)

                if case let .failed(message) = model.activityMonitorShortcutStatus {
                    Divider()
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .settingsPanel()
        }
    }

    private func shortcutRow(
        title: String,
        key: String,
        help: String? = nil,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 12) {
            Toggle(title, isOn: isOn)
                .toggleStyle(.checkbox)
            if let help {
                InfoHint(help)
            }
            Spacer()
            Text(key)
                .font(.system(.callout, design: .rounded).weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 180, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
    }

    private var statusColor: Color {
        switch model.finderShortcutsStatus {
        case .running:
            return .green
        case .waitingForPermissions:
            return .orange
        case .failed:
            return .red
        case .off:
            return .secondary
        }
    }
}
