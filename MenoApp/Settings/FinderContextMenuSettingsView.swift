import SwiftUI

@MainActor
struct FinderContextMenuSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "右键菜单",
                subtitle: "在当前文件夹或选中的文件夹中创建文档、打开终端。"
            )
            moduleSection
            terminalSection
        }
        .onAppear {
            model.refreshTerminalApplications()
        }
    }

    private var moduleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionTitle("功能")
            HStack(spacing: 8) {
                Text("启用 Finder 右键菜单")
                InfoHint("包含在终端中打开、文本文档和 Markdown 文档。多选、选中文件、废纸篓或无法确定目标文件夹时不显示；新文件不会覆盖已有文件。")
                Spacer()
                Toggle(
                    "启用",
                    isOn: Binding(
                        get: { model.finderContextMenuEnabled },
                        set: { model.setFinderContextMenuEnabled($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 46)
            .settingsPanel()
        }
    }

    private var terminalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionTitle("终端")
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("默认终端")
                    InfoHint("检测已安装且能直接打开文件夹的终端。")
                    Spacer()
                    Picker(
                        "默认终端",
                        selection: Binding(
                            get: { model.selectedTerminalBundleIdentifier },
                            set: { model.setSelectedTerminalBundleIdentifier($0) }
                        )
                    ) {
                        ForEach(model.terminalApplications) { terminal in
                            Text(terminalName(terminal)).tag(terminal.bundleIdentifier)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(minWidth: 190)
                    .disabled(!model.finderContextMenuEnabled || model.terminalApplications.isEmpty)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 46)

                Divider()

                HStack {
                    Text("已检测到 \(model.terminalApplications.count) 个终端")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        model.refreshTerminalApplications()
                    } label: {
                        Label("重新检测", systemImage: "arrow.clockwise")
                    }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 46)
            }
            .settingsPanel()
        }
    }

    private func terminalName(_ terminal: TerminalApplication) -> String {
        if terminal.bundleIdentifier == FinderContextMenuPreferences.systemTerminalBundleIdentifier {
            return "系统终端（Terminal）"
        }
        return terminal.displayName
    }
}
