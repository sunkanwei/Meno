import SwiftUI

@MainActor
struct WindowsAgentSettingsView: View {
    @ObservedObject var controller: WindowsAgentController

    var body: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "Windows Agent",
                subtitle: "自动发现 Windows 调查服务，并让 Codex 保持正确连接。"
            )
            connectionSection
            codexSection
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionTitle("连接")
            VStack(spacing: 0) {
                statusRow(
                    title: "服务状态",
                    value: controller.phase.title,
                    symbol: "server.rack",
                    color: phaseColor,
                    detail: controller.phase.detail
                )
                Divider()
                valueRow(title: "局域网地址", value: controller.endpoint?.displayAddress ?? "尚未发现")
                Divider()
                valueRow(title: "服务版本", value: controller.health?.version ?? "—")
                Divider()
                valueRow(title: "连接协议", value: controller.health?.protocolName ?? "MCP")
                Divider()
                HStack {
                    if let date = controller.lastCheckedAt {
                        Text("上次检查：\(date.formatted(date: .omitted, time: .standard))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("尚未完成检查")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("重新检查") {
                        controller.refresh()
                    }
                    .disabled(controller.endpoint == nil || controller.phase == .checking)
                }
                .padding(14)
            }
            .settingsPanel()
        }
    }

    private var codexSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionTitle("Codex")
            VStack(spacing: 0) {
                statusRow(
                    title: "连接配置",
                    value: controller.codexStatus.title,
                    symbol: "link",
                    color: codexColor,
                    detail: controller.codexStatus.detail
                )
                Divider()
                HStack(spacing: 12) {
                    Text("Meno 只维护连接地址；Windows 调查与代码协作由 Codex 直接连接 Windows Agent 完成。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("修复连接") {
                        controller.synchronizeCodexNow()
                    }
                    .disabled(controller.endpoint == nil)
                }
                .padding(14)
            }
            .settingsPanel()
        }
    }

    private func statusRow(
        title: String,
        value: String,
        symbol: String,
        color: Color,
        detail: String
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 18)
            Text(title)
            InfoHint(detail)
            Spacer()
            Text(value)
                .foregroundStyle(color)
        }
        .padding(14)
    }

    private func valueRow(title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .padding(14)
    }

    private var phaseColor: Color {
        switch controller.phase {
        case .connected: .green
        case .unavailable: .red
        case .checking: .orange
        case .searching, .stopped: .secondary
        }
    }

    private var codexColor: Color {
        switch controller.codexStatus {
        case .current: .green
        case .updated: .orange
        case .failed: .red
        case .checking: .secondary
        }
    }
}
