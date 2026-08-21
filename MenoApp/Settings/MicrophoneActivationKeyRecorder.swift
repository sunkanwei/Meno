import AppKit
import SwiftUI

@MainActor
struct MicrophoneActivationKeyRecorder: NSViewRepresentable {
    let activationKey: MicrophoneActivationKey
    let onChange: (MicrophoneActivationKey) -> Void
    let onRecordingChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange, onRecordingChanged: onRecordingChanged)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: activationKey.title,
            target: context.coordinator,
            action: #selector(Coordinator.beginRecording(_:))
        )
        button.bezelStyle = .rounded
        button.setAccessibilityLabel("录入麦克风共享按键")
        context.coordinator.button = button
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.onRecordingChanged = onRecordingChanged
        context.coordinator.activationKey = activationKey
        if !context.coordinator.isRecording {
            button.title = activationKey.title
        }
    }

    static func dismantleNSView(_ nsView: NSButton, coordinator: Coordinator) {
        coordinator.stopRecording()
    }

    @MainActor
    final class Coordinator: NSObject {
        var onChange: (MicrophoneActivationKey) -> Void
        var onRecordingChanged: (Bool) -> Void
        var activationKey = MicrophoneActivationKey.defaultValue
        weak var button: NSButton?
        private var monitor: Any?
        private(set) var isRecording = false

        init(
            onChange: @escaping (MicrophoneActivationKey) -> Void,
            onRecordingChanged: @escaping (Bool) -> Void
        ) {
            self.onChange = onChange
            self.onRecordingChanged = onRecordingChanged
        }

        @objc func beginRecording(_ sender: NSButton) {
            stopRecording()
            isRecording = true
            onRecordingChanged(true)
            sender.title = "请按一个按键…"
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .flagsChanged]
            ) { [weak self] event in
                guard let self else { return event }
                if event.type == .keyDown, event.keyCode == 53 {
                    stopRecording()
                    return nil
                }
                if event.type == .keyDown, event.isARepeat {
                    return nil
                }
                guard let candidate = MicrophoneActivationKey.make(event: event) else {
                    NSSound.beep()
                    sender.title = "这个按键无法发送到 Windows，请换一个"
                    return nil
                }
                activationKey = candidate
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
            button?.title = activationKey.title
        }
    }
}
