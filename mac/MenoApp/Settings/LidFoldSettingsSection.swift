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
            Text("开合 MacBook 时，桌面随屏幕角度逐渐扩散、模糊和淡出。停止移动后恢复正常桌面。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(controller.status)
                .font(.callout)
                .foregroundStyle(.secondary)
            if controller.needsPermission {
                Button("打开屏幕录制设置") { controller.openPermissionSettings() }
            }
            if controller.enabled {
                Text("按 Esc 或点击动效画面即可关闭。只作用于内建屏幕。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsPanel()
    }
}
