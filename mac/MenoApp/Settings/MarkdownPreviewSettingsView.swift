import SwiftUI

@MainActor
struct MarkdownPreviewSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "Markdown 预览",
                subtitle: "设置首次打开时的默认窗口大小；手动调整窗口后，会继续使用最后一次大小。"
            )
            sizeSection
        }
    }

    private var sizeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionTitle("默认窗口大小")
            VStack(spacing: 0) {
                sizeRow(
                    title: "宽度",
                    value: Binding(
                        get: { model.markdownPreviewDefaultWidth },
                        set: { model.setMarkdownPreviewDefaultWidth($0) }
                    ),
                    range: MarkdownPreviewWindowPreferences.widthRange
                )
                Divider()
                sizeRow(
                    title: "高度",
                    value: Binding(
                        get: { model.markdownPreviewDefaultHeight },
                        set: { model.setMarkdownPreviewDefaultHeight($0) }
                    ),
                    range: MarkdownPreviewWindowPreferences.heightRange
                )
                Divider()
                HStack {
                    Spacer()
                    Button("恢复推荐大小") {
                        model.restoreRecommendedMarkdownPreviewSize()
                    }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 46)
            }
            .settingsPanel()
        }
    }

    private func sizeRow(
        title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 96)
            Text("像素")
                .foregroundStyle(.secondary)
            Stepper(title, value: value, in: range, step: 50)
                .labelsHidden()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
    }
}
