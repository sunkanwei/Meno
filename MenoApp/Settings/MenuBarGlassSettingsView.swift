import SwiftUI

@MainActor
struct MenuBarGlassSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "菜单栏",
                subtitle: "在系统主显示器顶部绘制点击穿透的毛玻璃底板。"
            )
            VStack(alignment: .leading, spacing: 10) {
                SettingsSectionTitle("外观")
                HStack(spacing: 8) {
                    Text("悬浮玻璃效果")
                    InfoHint("始终跟随系统主显示器。固定样式：高度 30 · 左右边距 4 · 顶部偏移 0 · 圆角 12；窗口点击穿透。")
                    Spacer()
                    Text(model.menuBarGlassStatus.title)
                        .font(.callout)
                        .foregroundStyle(statusColor)
                    Toggle(
                        "启用",
                        isOn: Binding(
                            get: { model.menuBarGlassEnabled },
                            set: { model.setMenuBarGlassEnabled($0) }
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
    }

    private var statusColor: Color {
        switch model.menuBarGlassStatus {
        case .running:
            return .green
        case .failed:
            return .red
        case .off:
            return .secondary
        }
    }
}
