import SwiftUI

@MainActor
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var selection = SettingsDestination.permissionsAndNotifications

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("通用") {
                    Label("权限与通知", systemImage: "checkmark.shield")
                        .tag(SettingsDestination.permissionsAndNotifications)
                    Label("键盘快捷键", systemImage: "keyboard")
                        .tag(SettingsDestination.keyboardShortcuts)
                    Label("滚轮方向", systemImage: "computermouse")
                        .tag(SettingsDestination.scrolling)
                    Label("菜单栏", systemImage: "menubar.rectangle")
                        .tag(SettingsDestination.menuBarGlass)
                    Label("快捷运行", systemImage: "play.square.stack")
                        .tag(SettingsDestination.quickRun)
                    Label("屏幕衔接", systemImage: "rectangle.2.swap")
                        .tag(SettingsDestination.displayHandoff)
                    Label("合盖行为", systemImage: "laptopcomputer")
                        .tag(SettingsDestination.closedLidBehavior)
                }
                Section("Windows") {
                    Label("Windows Agent", systemImage: "server.rack")
                        .tag(SettingsDestination.windowsAgent)
                    Label("KVM", systemImage: "display.2")
                        .tag(SettingsDestination.kvm)
                }
                Section("Finder") {
                    Label("右键菜单", systemImage: "contextualmenu.and.cursorarrow")
                        .tag(SettingsDestination.finderContextMenu)
                    Label("Markdown 预览", systemImage: "doc.richtext")
                        .tag(SettingsDestination.markdownPreview)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 205, max: 240)
        } detail: {
            switch selection {
            case .permissionsAndNotifications:
                PermissionsAndNotificationsSettingsView(model: model)
            case .scrolling:
                ScrollingSettingsView(model: model)
            case .menuBarGlass:
                MenuBarGlassSettingsView(model: model)
            case .quickRun:
                QuickRunSettingsView(controller: model.quickRun)
            case .closedLidBehavior:
                ClosedLidBehaviorSettingsView(model: model)
            case .windowsAgent:
                WindowsAgentSettingsView(controller: model.windowsAgent)
            case .kvm:
                CrossScreenMouseSettingsView(model: model)
            case .displayHandoff:
                DisplayHandoffSettingsView(model: model)
            case .keyboardShortcuts:
                KeyboardShortcutsSettingsView(model: model)
            case .finderContextMenu:
                FinderContextMenuSettingsView(model: model)
            case .markdownPreview:
                MarkdownPreviewSettingsView(model: model)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(
            minWidth: 760,
            maxWidth: .infinity,
            minHeight: 520,
            maxHeight: .infinity
        )
        .background {
            NativeGlassBackground()
                .ignoresSafeArea()
        }
    }
}

private enum SettingsDestination: Hashable {
    case permissionsAndNotifications
    case scrolling
    case menuBarGlass
    case quickRun
    case closedLidBehavior
    case windowsAgent
    case kvm
    case displayHandoff
    case keyboardShortcuts
    case finderContextMenu
    case markdownPreview
}
