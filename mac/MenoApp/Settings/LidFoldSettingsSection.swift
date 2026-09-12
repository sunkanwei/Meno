import SwiftUI

@MainActor
struct LidFoldSettingsSection: View {
    @ObservedObject var controller: LidFoldController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("翻盖动效", isOn: Binding(
                get: { controller.enabled },
                set: { controller.setEnabled($0) }
            ))
            .toggleStyle(.switch)
            Text("内建屏幕随 MacBook 开合逐渐扩散、模糊和淡出。外接屏仅在合盖时联动，合严后保持纯黑，等待屏幕关闭。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(controller.status)
                .font(.callout)
                .foregroundStyle(.secondary)
            if controller.needsPermission {
                Button("打开屏幕录制设置") { controller.openPermissionSettings() }
            }
            if controller.enabled {
                Text("按 Esc 或点击动效画面即可关闭。外接屏重新开盖时直接恢复桌面。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsPanel()
    }
}
