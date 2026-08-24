import AppKit
import SwiftUI

@MainActor
struct QuickRunSettingsView: View {
    @ObservedObject var controller: QuickRunController

    var body: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "快捷运行",
                subtitle: "从指定目录手动运行一次性 zsh 脚本，不打开终端。"
            )
            directorySection
            usageSection
        }
        .onAppear {
            controller.refresh()
        }
    }

    private var directorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionTitle("脚本目录")
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(controller.directoryURL.path)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Text(directoryStatus)
                            .font(.callout)
                            .foregroundStyle(
                                controller.directoryIssue == nil ? Color.secondary : Color.red
                            )
                    }
                    Spacer()
                    Button("选择目录…", action: chooseDirectory)
                }
                .padding(14)

                Divider()

                HStack(spacing: 10) {
                    Button {
                        NSWorkspace.shared.open(controller.directoryURL)
                    } label: {
                        Label("打开目录", systemImage: "folder")
                    }
                    .disabled(controller.directoryIssue != nil)

                    Button("恢复默认") {
                        controller.restoreDefaultDirectory()
                    }
                    .disabled(controller.isUsingDefaultDirectory)

                    Spacer()

                    Button {
                        controller.refresh()
                    } label: {
                        Label("重新读取", systemImage: "arrow.clockwise")
                    }
                }
                .controlSize(.small)
                .padding(.horizontal, 14)
                .frame(minHeight: 42)
            }
            .settingsPanel()
        }
    }

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionTitle("使用规则")
            VStack(alignment: .leading, spacing: 8) {
                Label("只读取当前目录第一层的 .zsh 文件。", systemImage: "doc.text")
                Label("只有从菜单中亲自点击后才会运行，不会自动执行。", systemImage: "hand.tap")
                Label("脚本不能等待输入或作为长期后台服务运行。", systemImage: "stopwatch")
                Label("同一个脚本结束前不能重复启动。", systemImage: "checkmark.shield")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsPanel()
        }
    }

    private var directoryStatus: String {
        if let issue = controller.directoryIssue {
            return issue
        }
        return "已发现 \(controller.scripts.count) 个脚本"
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择快捷运行脚本目录"
        panel.prompt = "选择"
        panel.message = "Meno 只会显示所选目录第一层的 .zsh 文件。"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = controller.directoryIssue == nil
            ? controller.directoryURL
            : controller.directoryURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        controller.setDirectory(url)
    }
}
