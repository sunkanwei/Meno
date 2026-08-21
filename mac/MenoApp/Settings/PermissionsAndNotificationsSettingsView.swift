import SwiftUI

@MainActor
struct PermissionsAndNotificationsSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "权限与通知",
                subtitle: "管理 Meno 的必要系统权限、系统组件和操作提示。"
            )
            permissionSection
            systemComponentSection
            notificationSection
        }
    }

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionTitle("权限")
            VStack(spacing: 0) {
                permissionRow(
                    title: "辅助功能",
                    granted: accessibilityFullyGranted,
                    help: accessibilityHelp,
                    action: { model.requestAccessibilityPermission() }
                )
                Divider()
                permissionRow(
                    title: "输入监听",
                    granted: model.inputMonitoringGranted,
                    help: "用于监听 Finder 收到的必要按键和系统滚轮事件，不记录输入内容。",
                    action: { model.requestInputMonitoringPermission() }
                )
                Divider()
                finderAutomationPermissionRow
                Divider()
                HStack {
                    Spacer()
                    Button {
                        model.refreshPermissionsAndRuntime()
                    } label: {
                        Label("重新检查", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 38)
            }
            .settingsPanel()
        }
    }

    private var systemComponentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionTitle("系统组件")
            HStack(spacing: 8) {
                Text("Finder 扩展")
                InfoHint("用于 Finder 右键菜单，由系统管理。启用扩展且 Meno 正在运行时，可在文件夹空白处或单个文件夹上使用“在终端中打开”和“新建文档”。")
                Spacer()
                Button("打开设置") {
                    model.openFinderExtensionSettings()
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 46)
            .settingsPanel()
        }
    }

    private var notificationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionTitle("通知")
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("操作与系统提醒")
                    InfoHint("文件操作使用 Meno 即时提示；KVM 切换和 Windows 跨屏就绪使用系统通知。")
                    Spacer()
                    Text(notificationStatusText)
                        .font(.callout)
                        .foregroundStyle(notificationStatusColor)
                    Toggle(
                        "操作与系统提醒",
                        isOn: Binding(
                            get: { model.notificationsEnabled },
                            set: { model.setNotificationsEnabled($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(model.notificationPermissionPending)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 46)

                Divider()
                HStack(spacing: 8) {
                    Text("粘贴时播放音效")
                    InfoHint("关闭后仍会显示粘贴动画，只是不再播放声音。")
                    Spacer()
                    Toggle(
                        "粘贴时播放音效",
                        isOn: Binding(
                            get: { model.pasteSoundEnabled },
                            set: { model.setPasteSoundEnabled($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 46)

                if showsNotificationActions {
                    Divider()
                    HStack(spacing: 10) {
                        if model.notificationAuthorization.needsSystemSettings {
                            Button("通知设置") {
                                model.openNotificationSettings()
                            }
                        }
                        if model.notificationsEnabled && model.notificationAuthorization.canShowBanner {
                            Button("发送测试通知") {
                                model.sendTestNotification()
                            }
                            .disabled(model.notificationTestPending)
                        }
                        Spacer()
                        Button {
                            model.refreshNotificationAuthorization()
                        } label: {
                            Label("重新检查", systemImage: "arrow.clockwise")
                        }
                    }
                    .controlSize(.small)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 42)
                }

                if let message = model.notificationTestMessage {
                    Divider()
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .settingsPanel()
        }
    }

    private func permissionRow(
        title: String,
        granted: Bool,
        help: String,
        action: @MainActor @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
            InfoHint(help)
            Spacer()
            if granted {
                Label("已允许", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("去设置", action: action)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
    }

    private var finderAutomationPermissionRow: some View {
        HStack(spacing: 12) {
            Text("自动化（控制 Finder）")
            InfoHint("用于把桌面新建文档放到鼠标位置，并在 KVM 切换后恢复仍由 Mac 使用的屏幕上的桌面图标位置。")
            Spacer()

            switch model.finderAutomationPermissionStatus {
            case .checking:
                ProgressView()
                    .controlSize(.small)
            case .allowed:
                Label("已允许", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .notDetermined:
                Button("申请权限") {
                    model.requestFinderAutomationPermission()
                }
            case .denied:
                Button("去设置") {
                    model.openFinderAutomationSettings()
                }
            case .finderUnavailable:
                Label("Finder 未运行", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            case .unavailable:
                Label("无法检查", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
    }

    private var accessibilityFullyGranted: Bool {
        model.accessibilityGranted && model.postEventGranted
    }

    private var accessibilityHelp: String {
        let reading = model.accessibilityGranted ? "已允许" : "未允许"
        let posting = model.postEventGranted ? "已允许" : "未允许"
        return "用于确认 Finder 焦点并发送 Finder 原生命令。辅助功能读取\(reading)，命令发送\(posting)。"
    }

    private var notificationStatusText: String {
        switch model.notificationAuthorization {
        case .checking:
            return "正在检查系统状态"
        case .notDetermined:
            return "尚未请求系统权限"
        case .allowed:
            return model.notificationsEnabled ? "提醒已开启" : "已关闭"
        case .denied:
            return model.notificationsEnabled ? "即时提示可用，系统未允许" : "系统未允许"
        case .bannersDisabled:
            return model.notificationsEnabled ? "即时提示可用，系统横幅已关闭" : "系统横幅已关闭"
        case .unavailable:
            return model.notificationsEnabled ? "即时提示可用，系统通知不可用" : "系统通知不可用"
        }
    }

    private var notificationStatusColor: Color {
        switch model.notificationAuthorization {
        case .allowed:
            return model.notificationsEnabled ? .green : .secondary
        case .denied, .bannersDisabled:
            return .orange
        case .checking, .notDetermined, .unavailable:
            return .secondary
        }
    }

    private var showsNotificationActions: Bool {
        model.notificationAuthorization.needsSystemSettings
            || (model.notificationsEnabled && model.notificationAuthorization.canShowBanner)
    }
}
