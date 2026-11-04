import SwiftUI

@MainActor
struct CrossScreenMouseSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "KVM",
                subtitle: "一键切换飞利浦画面与键鼠穿屏，同步屏幕布局，共享剪贴板。"
            )
            featureSection
            switchSection
            statusSection
        }
    }

    private var featureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionTitle("功能")
            VStack(spacing: 0) {
                featureToggleRow(
                    title: "启用 KVM",
                    info: "硬件要求：Philips 的 HDMI2 接 Mac、DP1 接 Windows，位于三屏最左侧或最右侧；主屏可为 MacBook 或优派。Windows 须把 Philips 设为主显示器。",
                    isOn: Binding(
                        get: { model.crossScreenMouseEnabled },
                        set: { model.setCrossScreenMouseEnabled($0) }
                    ),
                    disabled: model.softKVMStatus.isBusy
                )
                Divider()
                featureToggleRow(
                    title: "剪贴板",
                    info: "与 Windows 双向同步文字、单张图片和文件，接收的文件存于 Meno 缓存。不上传云端，不保存历史；仅限可信局域网。",
                    isOn: Binding(
                        get: { model.clipboardSharingEnabled },
                        set: { model.setClipboardSharingEnabled($0) }
                    )
                )
            }
            .settingsPanel()
        }
    }

    private var switchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionTitle("切换")
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("画面、键鼠与屏幕布局")
                    InfoHint(
                        "点击按钮或按快捷键，Meno 会切换并核对飞利浦的 DP（Windows）或 HDMI 2（Mac）输入。"
                            + "按住鼠标按钮时不会穿越屏幕边缘；Ctrl + Alt + Esc 可紧急收回鼠标；"
                            + "Windows 离线时仍可从菜单或快捷键恢复 Mac。"
                    )
                    Spacer()
                    Button(model.softKVMStatus.actionTitle) {
                        model.toggleSoftKVM()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        !model.crossScreenMouseEnabled || !model.softKVMStatus.actionEnabled
                    )
                }
                .padding(14)

                Divider()

                HStack(spacing: 8) {
                    Text("全局快捷键")
                    InfoHint("支持 Shift + F12 或至少两个修饰键，录入时不会触发切换。在 Logitech G HUB 的 DESKTOP - Default 中，可把鼠标侧键映射为同一快捷键（一次性、无延时、无循环）。")
                    Spacer()
                    SoftKVMShortcutRecorder(
                        shortcut: model.softKVMShortcut,
                        onChange: { model.setSoftKVMShortcut($0) },
                        onRecordingChanged: { model.setSoftKVMShortcutRecording($0) }
                    )
                    Button("测试") {
                        model.beginSoftKVMShortcutTest()
                    }
                    .disabled(!model.crossScreenMouseEnabled || model.softKVMStatus.isBusy)
                    Button("恢复默认") {
                        model.setSoftKVMShortcut(.defaultValue)
                    }
                }
                .padding(14)

                if let message = model.softKVMShortcutTestMessage {
                    Divider()
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
            }
            .settingsPanel()
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionTitle("状态")
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    statusItem(
                        name: "KVM",
                        symbol: "display.2",
                        color: softKVMStatusColor,
                        detail: model.softKVMStatus.detail
                    )
                    statusItem(
                        name: "屏幕衔接",
                        symbol: "rectangle.2.swap",
                        color: companionStatusColor,
                        detail: model.crossScreenMouseStatus.detail
                    )
                    statusItem(
                        name: "剪贴板",
                        symbol: "doc.on.clipboard",
                        color: clipboardStatusColor,
                        detail: model.clipboardSharingStatus.detail
                    )
                    Spacer()
                    Button("重新监听") {
                        model.restartWindowsCompanion()
                    }
                    .controlSize(.small)
                    .disabled(!model.crossScreenMouseEnabled && !model.clipboardSharingEnabled)
                }
                .padding(14)
            }
            .settingsPanel()
        }
    }

    private func statusItem(
        name: String,
        symbol: String,
        color: Color,
        detail: String
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(color)
            Text(name)
                .font(.callout)
            InfoHint(detail)
        }
    }

    private func featureToggleRow(
        title: String,
        info: String,
        isOn: Binding<Bool>,
        disabled: Bool = false
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
            InfoHint(info)
            Spacer()
            Toggle("启用", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(disabled)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
    }

    private var softKVMStatusColor: Color {
        switch model.softKVMStatus {
        case .macReady, .windowsReady:
            .green
        case .macWaiting, .windowsWaiting:
            .orange
        case .recoveryNeeded:
            .red
        case .disabled, .checking, .switchingToWindows, .switchingToMac:
            .secondary
        }
    }

    private var companionStatusColor: Color {
        switch model.crossScreenMouseStatus {
        case .standby, .connected, .controlling: .green
        case .waiting, .needsArrangement: .orange
        case .failed: .red
        case .off: .secondary
        }
    }

    private var clipboardStatusColor: Color {
        switch model.clipboardSharingStatus {
        case .connected: .green
        case .failed: .red
        case .off, .listening: .secondary
        }
    }
}
