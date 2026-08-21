import SwiftUI

@MainActor
struct DisplayHandoffSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "屏幕衔接",
                subtitle: "按实际物理高度自动校正横向相邻屏幕及 Windows 接缝。"
            )
            featureSection
        }
    }

    private var featureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionTitle("功能")
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("启用屏幕衔接")
                    InfoHint("按屏幕物理尺寸换算，同一设置同时用于 Mac 与 Windows 接缝；Mac 无对应区域保持系统原生行为。关闭后，Mac 使用系统原生衔接，Windows 使用原有百分比映射。")
                    Spacer()
                    Toggle(
                        "启用",
                        isOn: Binding(
                            get: { model.displayHandoffEnabled },
                            set: { model.setDisplayHandoffEnabled($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 46)

                Divider()

                HStack(alignment: .top, spacing: 8) {
                    Text("对齐方式")
                    InfoHint(model.displayHandoffAlignment.detail)
                    Spacer()
                    Picker(
                        "对齐方式",
                        selection: Binding(
                            get: { model.displayHandoffAlignment },
                            set: { model.setDisplayHandoffAlignment($0) }
                        )
                    ) {
                        ForEach(DisplayHandoffAlignment.allCases) { alignment in
                            Text(alignment.title).tag(alignment)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)
                }
                .padding(14)
                .disabled(!model.displayHandoffEnabled)
            }
            .settingsPanel()
        }
    }
}

private extension DisplayHandoffAlignment {
    var title: String {
        switch self {
        case .top: "顶部对齐"
        case .bottom: "底部对齐"
        }
    }

    var detail: String {
        switch self {
        case .top:
            "所有屏幕以顶部为共同基准；同一物理高度落在距离顶部相同的位置。"
        case .bottom:
            "所有屏幕以底部为共同基准；同一物理高度落在距离底部相同的位置。"
        }
    }
}
