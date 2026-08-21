import AppKit
import SwiftUI

@MainActor
struct SoftKVMShortcutRecorder: NSViewRepresentable {
    let shortcut: SoftKVMShortcut
    let onChange: (SoftKVMShortcut) -> Void
    let onRecordingChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange, onRecordingChanged: onRecordingChanged)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: shortcut.title,
            target: context.coordinator,
            action: #selector(Coordinator.beginRecording(_:))
        )
        button.bezelStyle = .rounded
        button.setAccessibilityLabel("录入 KVM 全局快捷键")
        context.coordinator.button = button
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.onRecordingChanged = onRecordingChanged
        context.coordinator.shortcut = shortcut
        if !context.coordinator.isRecording {
            button.title = shortcut.title
        }
    }

    static func dismantleNSView(_ nsView: NSButton, coordinator: Coordinator) {
        coordinator.stopRecording()
    }

    @MainActor
    final class Coordinator: NSObject {
        var onChange: (SoftKVMShortcut) -> Void
        var onRecordingChanged: (Bool) -> Void
        var shortcut = SoftKVMShortcut.defaultValue
        weak var button: NSButton?
        private var monitor: Any?
        private(set) var isRecording = false

        init(
            onChange: @escaping (SoftKVMShortcut) -> Void,
            onRecordingChanged: @escaping (Bool) -> Void
        ) {
            self.onChange = onChange
            self.onRecordingChanged = onRecordingChanged
        }

        @objc func beginRecording(_ sender: NSButton) {
            stopRecording()
            isRecording = true
            onRecordingChanged(true)
            sender.title = "请按快捷键…"
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                if event.keyCode == 53 {
                    stopRecording()
                    return nil
                }
                let candidate = SoftKVMShortcut.make(
                    keyCode: event.keyCode,
                    modifiers: event.modifierFlags,
                    label: event.charactersIgnoringModifiers
                )
                guard let candidate else {
                    NSSound.beep()
                    sender.title = "请按 Shift + F12 或使用两个修饰键"
                    return nil
                }
                shortcut = candidate
                onChange(candidate)
                stopRecording()
                return nil
            }
        }

        func stopRecording() {
            let wasRecording = isRecording
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            isRecording = false
            if wasRecording {
                onRecordingChanged(false)
            }
            button?.title = shortcut.title
        }
    }
}
