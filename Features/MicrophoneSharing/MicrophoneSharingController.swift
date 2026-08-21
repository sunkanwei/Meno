import AVFoundation
import AppKit
import Network
import OSLog

enum MicrophoneSharingStatus: Equatable {
    case off
    case waitingForPermission
    case permissionDenied
    case waitingForWindows(device: String?)
    case ready(device: String?)
    case starting(device: String?)
    case sharing(device: String?)
    case unavailable(String)
    case failed(String)

    var detail: String {
        switch self {
        case .off:
            return "不会读取或发送这台 Mac 的麦克风。"
        case .waitingForPermission:
            return "请在系统提示中允许 Meno 使用麦克风。"
        case .permissionDenied:
            return "请前往“系统设置 → 隐私与安全性 → 麦克风”允许 Meno。"
        case let .waitingForWindows(device):
            return device.map { "当前输入设备：\($0)。等待 Windows 建立音频连接。" }
                ?? "等待 Windows 建立音频连接。"
        case let .ready(device):
            return device.map {
                "Windows 已连接；仅在按住共享按键时使用 \($0)。"
            } ?? "Windows 已连接；仅在按住共享按键时使用当前默认麦克风。"
        case let .starting(device):
            return device.map { "音频连接已建立，正在等待 \($0) 的首帧 PCM 成功写出。" }
                ?? "音频连接已建立，正在等待首帧 PCM 成功写出。"
        case let .sharing(device):
            return device.map { "正在把 \($0) 实时传送到 Windows。" }
                ?? "正在把当前默认麦克风实时传送到 Windows。"
        case let .unavailable(message), let .failed(message):
            return message
        }
    }
}

@MainActor
final class MicrophoneSharingController {
    private let logger = Logger(subsystem: "com.sunkanwei.Meno", category: "MicrophoneSharing")
    private let onStatusChanged: (MicrophoneSharingStatus) -> Void
    private let onAvailabilityChanged: (Bool) -> Void
    private var enabled = false
    private var availableForNegotiation = false
    private var authorizationRequest: Task<Void, Never>?
    private var controlConnectionID: UUID?
    private var audioConnection: MicrophoneConnection?
    private var audioIsReady = false
    private var capture: MicrophoneCapture?
    private var activationHeld = false
    private var captureFailure: String?
    private var listenerFailure: String?
    private var deviceChangeWorkItem: DispatchWorkItem?
    private var startupTimeoutWorkItem: DispatchWorkItem?
    private var latestCaptureMetrics: MicrophoneCaptureMetrics?
    private var latestNetworkMetrics: MicrophoneNetworkMetrics?
    private var isDeliveringPCM = false

    init(
        onStatusChanged: @escaping (MicrophoneSharingStatus) -> Void,
        onAvailabilityChanged: @escaping (Bool) -> Void
    ) {
        self.onStatusChanged = onStatusChanged
        self.onAvailabilityChanged = onAvailabilityChanged
    }

    var canNegotiate: Bool {
        availableForNegotiation
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        authorizationRequest?.cancel()
        authorizationRequest = nil
        if enabled {
            refreshAuthorization(requestIfNeeded: true)
        } else {
            activationHeld = false
            stopRuntime()
            listenerFailure = nil
            setAvailability(false)
            onStatusChanged(.off)
        }
    }

    func refreshAuthorization() {
        guard enabled else { return }
        refreshAuthorization(requestIfNeeded: false)
    }

    func setActivationHeld(_ held: Bool) {
        guard enabled else {
            activationHeld = false
            return
        }
        guard activationHeld != held else { return }
        activationHeld = held
        if held {
            startCaptureIfPossible()
        } else {
            stopCaptureForIdle()
        }
    }

    func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func controlReady(connectionID: UUID, microphoneNegotiated: Bool) {
        guard availableForNegotiation, microphoneNegotiated else {
            if controlConnectionID != nil {
                stopRuntime()
            }
            return
        }
        if controlConnectionID != connectionID {
            stopAudioRuntime()
        }
        controlConnectionID = connectionID
        captureFailure = nil
        listenerFailure = nil
        onStatusChanged(.waitingForWindows(device: MicrophoneCapture.defaultInputDeviceName()))
    }

    func controlDisconnected(connectionID: UUID) {
        guard controlConnectionID == connectionID else { return }
        stopRuntime()
        if availableForNegotiation {
            onStatusChanged(.waitingForWindows(device: MicrophoneCapture.defaultInputDeviceName()))
        }
    }

    func acceptAudio(_ networkConnection: NWConnection, localName: String) {
        guard availableForNegotiation, controlConnectionID != nil,
              audioConnection == nil else {
            networkConnection.cancel()
            return
        }
        let connectionID = UUID()
        let connection = MicrophoneConnection(
            id: connectionID,
            connection: networkConnection,
            localName: localName,
            onReady: { [weak self] name in
                Task { @MainActor [weak self] in
                    self?.audioReady(connectionID: connectionID, peerName: name)
                }
            },
            onDisconnect: { [weak self] reason in
                Task { @MainActor [weak self] in
                    self?.audioDisconnected(connectionID: connectionID, reason: reason)
                }
            },
            onPCMDelivered: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.pcmDelivered(connectionID: connectionID)
                }
            },
            onMetrics: { [weak self] metrics in
                Task { @MainActor [weak self] in
                    guard self?.audioConnection?.id == connectionID else { return }
                    self?.latestNetworkMetrics = metrics
                }
            }
        )
        audioConnection = connection
        connection.start()
    }

    func stopRuntime() {
        controlConnectionID = nil
        stopAudioRuntime()
        if availableForNegotiation {
            onStatusChanged(.waitingForWindows(device: MicrophoneCapture.defaultInputDeviceName()))
        }
    }

    func listenerFailed(_ message: String) {
        listenerFailure = message
        stopRuntime()
        if availableForNegotiation {
            onStatusChanged(.failed(message))
        }
    }

    func serverFailed(_ message: String) {
        listenerFailure = message
        stopRuntime()
        if availableForNegotiation {
            onStatusChanged(.failed(message))
        }
    }

    func listenerReady() {
        listenerFailure = nil
        if availableForNegotiation, controlConnectionID == nil {
            onStatusChanged(.waitingForWindows(device: MicrophoneCapture.defaultInputDeviceName()))
        }
    }

    func stopForApplicationExit() {
        enabled = false
        activationHeld = false
        authorizationRequest?.cancel()
        authorizationRequest = nil
        setAvailability(false)
        stopRuntime()
        onStatusChanged(.off)
    }

    private func refreshAuthorization(requestIfNeeded: Bool) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            setAvailability(true)
            reportCurrentStatus()
        case .notDetermined where requestIfNeeded:
            setAvailability(false)
            onStatusChanged(.waitingForPermission)
            authorizationRequest = Task { [weak self] in
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                guard let self, !Task.isCancelled, enabled else { return }
                authorizationRequest = nil
                if granted {
                    setAvailability(true)
                    reportCurrentStatus()
                } else {
                    setAvailability(false)
                    onStatusChanged(.permissionDenied)
                }
            }
        case .notDetermined:
            setAvailability(false)
            onStatusChanged(.waitingForPermission)
        case .denied, .restricted:
            stopRuntime()
            setAvailability(false)
            onStatusChanged(.permissionDenied)
        @unknown default:
            stopRuntime()
            setAvailability(false)
            onStatusChanged(.failed("无法读取 macOS 麦克风权限状态。"))
        }
    }

    private func setAvailability(_ available: Bool) {
        guard availableForNegotiation != available else { return }
        availableForNegotiation = available
        onAvailabilityChanged(available)
    }

    private func reportCurrentStatus() {
        if let listenerFailure {
            onStatusChanged(.failed(listenerFailure))
        } else if capture != nil, audioConnection != nil, isDeliveringPCM {
            onStatusChanged(.sharing(device: MicrophoneCapture.defaultInputDeviceName()))
        } else if capture != nil, audioConnection != nil {
            onStatusChanged(.starting(device: MicrophoneCapture.defaultInputDeviceName()))
        } else if let captureFailure {
            onStatusChanged(.unavailable(captureFailure))
        } else if audioIsReady, audioConnection != nil {
            onStatusChanged(.ready(device: MicrophoneCapture.defaultInputDeviceName()))
        } else {
            onStatusChanged(.waitingForWindows(device: MicrophoneCapture.defaultInputDeviceName()))
        }
    }

    private func audioReady(connectionID: UUID, peerName: String) {
        guard audioConnection?.id == connectionID,
              controlConnectionID != nil,
              availableForNegotiation else { return }
        captureFailure = nil
        audioIsReady = true
        logger.info("Microphone audio connected to \(peerName, privacy: .public)")
        if activationHeld {
            startCaptureIfPossible()
        } else {
            onStatusChanged(.ready(device: MicrophoneCapture.defaultInputDeviceName()))
        }
    }

    private func startCaptureIfPossible() {
        guard activationHeld, audioIsReady, capture == nil,
              let connectionID = audioConnection?.id else {
            reportCurrentStatus()
            return
        }
        captureFailure = nil
        do {
            try startCapture(connectionID: connectionID)
        } catch {
            captureFailure = error.localizedDescription
            onStatusChanged(.unavailable(error.localizedDescription))
            logger.error("Microphone capture failed: \(error.localizedDescription, privacy: .public)")
            audioConnection?.stop()
        }
    }

    private func stopCaptureForIdle() {
        deviceChangeWorkItem?.cancel()
        deviceChangeWorkItem = nil
        cancelStartupTimeout()
        capture?.stop()
        capture = nil
        isDeliveringPCM = false
        latestCaptureMetrics = nil
        latestNetworkMetrics = nil
        reportCurrentStatus()
    }

    private func startCapture(connectionID: UUID) throws {
        cancelStartupTimeout()
        capture?.stop()
        guard activationHeld, audioIsReady,
              let connection = audioConnection, connection.id == connectionID else { return }
        latestCaptureMetrics = nil
        latestNetworkMetrics = nil
        isDeliveringPCM = false
        connection.armDeliveryConfirmation()
        let capture = MicrophoneCapture(
            onPCM: { [weak connection] payload in
                connection?.sendPCM(payload)
            },
            onFailure: { [weak self] message in
                Task { @MainActor [weak self] in
                    self?.captureFailed(connectionID: connectionID, message: message)
                }
            },
            onDeviceChange: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.scheduleCaptureRestart(connectionID: connectionID)
                }
            },
            onMetrics: { [weak self] metrics in
                Task { @MainActor [weak self] in
                    guard self?.audioConnection?.id == connectionID else { return }
                    self?.latestCaptureMetrics = metrics
                }
            }
        )
        try capture.start()
        self.capture = capture
        onStatusChanged(.starting(device: MicrophoneCapture.defaultInputDeviceName()))
        scheduleStartupTimeout(connectionID: connectionID)
    }

    private func pcmDelivered(connectionID: UUID) {
        guard audioConnection?.id == connectionID, capture != nil else { return }
        cancelStartupTimeout()
        captureFailure = nil
        isDeliveringPCM = true
        onStatusChanged(.sharing(device: MicrophoneCapture.defaultInputDeviceName()))
        logger.info("First microphone PCM frame was written")
    }

    private func scheduleStartupTimeout(connectionID: UUID) {
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.startupTimedOut(connectionID: connectionID)
            }
        }
        startupTimeoutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
    }

    private func cancelStartupTimeout() {
        startupTimeoutWorkItem?.cancel()
        startupTimeoutWorkItem = nil
    }

    private func startupTimedOut(connectionID: UUID) {
        guard audioConnection?.id == connectionID, !isDeliveringPCM else { return }
        let stage = MicrophoneStartupDiagnosis.message(
            capture: latestCaptureMetrics,
            network: latestNetworkMetrics
        )
        let message = "\(stage) 已重置音频连接，等待 Windows 安全重试。"
        captureFailure = message
        onStatusChanged(.unavailable(message))
        logger.error("Microphone startup timed out: \(stage, privacy: .public)")
        capture?.stop()
        capture = nil
        audioConnection?.stop()
    }

    private func captureFailed(connectionID: UUID, message: String) {
        guard audioConnection?.id == connectionID, captureFailure == nil else { return }
        cancelStartupTimeout()
        captureFailure = message
        onStatusChanged(.unavailable(message))
        logger.error("Microphone capture ended: \(message, privacy: .public)")
        capture?.stop()
        capture = nil
        audioConnection?.stop()
    }

    private func scheduleCaptureRestart(connectionID: UUID) {
        guard activationHeld, audioConnection?.id == connectionID else { return }
        deviceChangeWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.restartCapture(connectionID: connectionID)
            }
        }
        deviceChangeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func restartCapture(connectionID: UUID) {
        guard activationHeld, audioConnection?.id == connectionID else {
            stopCaptureForIdle()
            return
        }
        do {
            try startCapture(connectionID: connectionID)
            captureFailure = nil
            logger.info("Microphone input device changed")
        } catch {
            captureFailed(connectionID: connectionID, message: error.localizedDescription)
        }
    }

    private func audioDisconnected(connectionID: UUID, reason: String?) {
        guard audioConnection?.id == connectionID else { return }
        deviceChangeWorkItem?.cancel()
        deviceChangeWorkItem = nil
        cancelStartupTimeout()
        capture?.stop()
        capture = nil
        audioConnection = nil
        audioIsReady = false
        isDeliveringPCM = false
        latestCaptureMetrics = nil
        latestNetworkMetrics = nil
        if let reason {
            logger.error("Microphone connection ended: \(reason, privacy: .public)")
        }
        if let captureFailure {
            onStatusChanged(.unavailable(captureFailure))
        } else if availableForNegotiation, controlConnectionID != nil {
            onStatusChanged(.waitingForWindows(device: MicrophoneCapture.defaultInputDeviceName()))
        }
    }

    private func stopAudioRuntime() {
        deviceChangeWorkItem?.cancel()
        deviceChangeWorkItem = nil
        cancelStartupTimeout()
        capture?.stop()
        capture = nil
        audioConnection?.stop()
        audioConnection = nil
        audioIsReady = false
        captureFailure = nil
        isDeliveringPCM = false
        latestCaptureMetrics = nil
        latestNetworkMetrics = nil
    }
}
