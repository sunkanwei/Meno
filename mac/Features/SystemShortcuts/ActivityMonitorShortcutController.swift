import AppKit
import Carbon.HIToolbox

enum ActivityMonitorShortcutStatus: Equatable {
    case off
    case running
    case failed(String)
}

@MainActor
final class ActivityMonitorShortcutController {
    static let shortcutLabel = "Ctrl+Shift+Esc"

    private static let activityMonitorBundleIdentifier = "com.apple.ActivityMonitor"
    private static let hotKeyID = EventHotKeyID(signature: 0x4D656E6F, id: 1)

    private let onStatusChanged: (ActivityMonitorShortcutStatus) -> Void
    private var enabled = false
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var openGeneration = 0

    init(onStatusChanged: @escaping (ActivityMonitorShortcutStatus) -> Void) {
        self.onStatusChanged = onStatusChanged
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if enabled {
            start()
        } else {
            stop()
            onStatusChanged(.off)
        }
    }

    func stopForApplicationExit() {
        enabled = false
        stop()
    }

    private func start() {
        if hotKeyRef != nil {
            onStatusChanged(.running)
            return
        }

        guard installEventHandler() else {
            stop()
            onStatusChanged(.failed("无法建立系统快捷键监听"))
            return
        }

        var registeredHotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_Escape),
            UInt32(cmdKey | shiftKey),
            Self.hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &registeredHotKey
        )
        guard status == noErr, let registeredHotKey else {
            stop()
            let message = status == eventHotKeyExistsErr
                ? "\(Self.shortcutLabel) 已被其他应用占用"
                : "无法注册 \(Self.shortcutLabel)（错误 \(status)）"
            onStatusChanged(.failed(message))
            return
        }

        hotKeyRef = registeredHotKey
        onStatusChanged(.running)
    }

    private func installEventHandler() -> Bool {
        if eventHandlerRef != nil { return true }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        var installedHandler: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandler,
            1,
            &eventType,
            userData,
            &installedHandler
        )
        guard status == noErr, let installedHandler else { return false }
        eventHandlerRef = installedHandler
        return true
    }

    private func stop() {
        openGeneration += 1
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
        hotKeyRef = nil
        eventHandlerRef = nil
    }

    private func handleHotKey(signature: OSType, id: UInt32) -> OSStatus {
        guard enabled,
              signature == Self.hotKeyID.signature,
              id == Self.hotKeyID.id else {
            return OSStatus(eventNotHandledErr)
        }

        openActivityMonitor()
        return noErr
    }

    private func openActivityMonitor() {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: Self.activityMonitorBundleIdentifier
        ) else {
            onStatusChanged(.failed("找不到活动监视器"))
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        openGeneration += 1
        let generation = openGeneration
        NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: configuration
        ) { [weak self] _, error in
            Task { @MainActor in
                guard let self,
                      self.enabled,
                      self.openGeneration == generation else { return }
                if let error {
                    self.onStatusChanged(.failed("无法打开活动监视器：\(error.localizedDescription)"))
                } else {
                    self.onStatusChanged(.running)
                }
            }
        }
    }

    private static let eventHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }

        var receivedID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &receivedID
        )
        guard status == noErr else { return OSStatus(eventNotHandledErr) }
        let signature = receivedID.signature
        let id = receivedID.id

        let owner = Unmanaged<ActivityMonitorShortcutController>
            .fromOpaque(userData)
            .takeUnretainedValue()
        return MainActor.assumeIsolated {
            owner.handleHotKey(signature: signature, id: id)
        }
    }
}
