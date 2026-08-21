import SwiftUI

@MainActor
struct ScrollingSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "滚轮方向",
                subtitle: "保留内置触控板的系统方向，让其他滚轮设备使用反向垂直滚动。"
            )
            VStack(alignment: .leading, spacing: 10) {
                SettingsSectionTitle("功能")
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text("启用滚轮方向调整")
                        InfoHint("内置触控板保持系统滚动方向，其他滚轮设备反转垂直方向；水平滚动、速度、平滑度、加速度和按键保持系统行为；无法识别来源时原样放行。")
                        Spacer()
                        Circle()
                            .fill(statusColor)
                            .frame(width: 7, height: 7)
                        Toggle(
                            "启用",
                            isOn: Binding(
                                get: { model.scrollingEnabled },
                                set: { model.setScrollingEnabled($0) }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 46)

                    if showsStatusDetail {
                        Divider()
                        Text(model.scrollingStatus.detail)
                            .font(.callout)
                            .foregroundStyle(model.scrollingStatus.isFailure ? .red : .secondary)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .settingsPanel()
            }
        }
    }

    private var statusColor: Color {
        switch model.scrollingStatus {
        case .running:
            return .green
        case .failed:
            return .red
        case .off, .waitingForPermissions:
            return .secondary
        }
    }

    private var showsStatusDetail: Bool {
        switch model.scrollingStatus {
        case .waitingForPermissions, .failed:
            return true
        case .off, .running:
            return false
        }
    }
}

private extension ScrollingStatus {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
