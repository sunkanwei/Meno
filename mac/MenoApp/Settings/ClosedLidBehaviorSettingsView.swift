import SwiftUI

@MainActor
struct ClosedLidBehaviorSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "合盖行为",
                subtitle: "选择合上 MacBook 后，电脑如何处理。"
            )

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    SettingsSectionTitle("模式")
                    InfoHint(currentModeSummary)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Picker(
                        "合盖模式",
                        selection: Binding(
                            get: { model.closedLidMode },
                            set: { model.setClosedLidMode($0) }
                        )
                    ) {
                        ForEach(ClosedLidMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)

                    Divider()

                    HStack(spacing: 8) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 7, height: 7)
                        Text(model.closedLidBehaviorStatus.title)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(statusColor)
                        InfoHint(model.closedLidBehaviorStatus.detail)
                        Spacer()
                    }

                    if model.closedLidMode == .shutdown {
                        Divider()

                        HStack(spacing: 8) {
                            Text(model.closedLidShutdownHelperStatus.title)
                                .font(.callout.weight(.medium))
                            InfoHint(model.closedLidShutdownHelperStatus.detail)
                            Spacer()
                            if !model.closedLidShutdownHelperStatus.isReady,
                               model.closedLidShutdownHelperStatus != .installing {
                                Button("安装关机助手") {
                                    model.installClosedLidShutdownHelper()
                                }
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsPanel()
            }
        }
    }

    private var statusColor: Color {
        switch model.closedLidBehaviorStatus {
        case .keepingRunning, .sleepRequested:
            return .green
        case .failed:
            return .red
        case .followingSystem, .monitoring:
            return .secondary
        }
    }

    private var currentModeSummary: String {
        modeDetails.joined(separator: "\n")
    }

    private var modeDetails: [String] {
        switch model.closedLidMode {
        case .followSystem:
            return [
                "Meno 不干预合盖行为。",
                "是否睡眠由 macOS、供电状态和外接设备共同决定。"
            ]
        case .keepRunning:
            return [
                "MacBook 打开时，保持系统原有的电源行为。",
                "MacBook 合上时，电脑继续运行，同时关闭所有显示器。",
                "仍可手动让电脑睡眠；低电量和过热保护不受影响。"
            ]
        case .sleep:
            return [
                "MacBook 合上时，立即请求标准系统睡眠。",
                "不会修改系统的待机、休眠或唤醒设置。",
                "睡眠后的电源管理和深度待机时机由 macOS 决定。"
            ]
        case .shutdown:
            return [
                "MacBook 合上时，系统立即开始关机。",
                "普通应用不能取消或无限拖延关机。",
                "下次开机时，不恢复关机前打开的应用。",
                "未保存的内容可能丢失；你已选择接受这个代价。"
            ]
        }
    }
}
