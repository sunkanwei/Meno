import AppKit
import SwiftUI

struct SettingsPage<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                content
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.clear)
    }
}

struct SettingsPageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

struct SettingsSectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.headline)
    }
}

struct InfoHint: View {
    let text: String
    @State private var hovering = false

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Image(systemName: "info.circle")
            .foregroundStyle(.secondary)
            .onHover { hovering = $0 }
            .popover(isPresented: $hovering, arrowEdge: .trailing) {
                Text(text)
                    .font(.callout)
                    .padding(12)
                    .frame(width: 280, alignment: .leading)
            }
    }
}

extension View {
    func settingsPanel() -> some View {
        background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
    }
}

struct NativeGlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
