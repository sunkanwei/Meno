import AppKit
import Network
import OSLog

enum ClipboardSharingStatus: Equatable {
    case off
    case listening
    case connected(name: String, address: String)
    case failed(String)

    var detail: String {
        switch self {
        case .off:
            return "不会读取或发送本机剪贴板。"
        case .listening:
            return "正在物理局域网内等待 MenoClipboard。"
        case let .connected(name, address):
            return "\(name)（\(address)）可以与这台 Mac 双向同步双方支持的剪贴板内容。"
        case let .failed(message):
            return message
        }
    }
}

@MainActor
final class WindowsCompanionController {
    private let logger = Logger(subsystem: "com.sunkanwei.Meno", category: "WindowsCompanion")
    private let crossScreenMouse: CrossScreenMouseController
    private let onClipboardStatusChanged: (ClipboardSharingStatus) -> Void
    private let onMicrophoneStatusChanged: (MicrophoneSharingStatus) -> Void
    private let onMouseReadinessChanged: (WindowsMouseReadiness?) -> Void
    private let onWindowsOnline: () -> Void
    private var clipboardEnabled = false
    private var microphoneEnabled = false
    private var mouseServiceEnabled = false
    private var systemIsSleeping = false
    private var server: WindowsCompanionServer?
    private var serverID: UUID?
    private var clipboardConnection: ClipboardConnection?
    private var clipboardPeer: (name: String, address: String)?
    private var mouseConnection: MouseConnection?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var wakeWorkItem: DispatchWorkItem?

    private lazy var microphoneSharing = MicrophoneSharingController(
        onStatusChanged: { [weak self] status in
            self?.onMicrophoneStatusChanged(status)
        },
        onAvailabilityChanged: { [weak self] _ in
            self?.microphoneAvailabilityChanged()
        }
    )

    private lazy var monitor = ClipboardMonitor { [weak self] content in
        guard let self, clipboardEnabled else { return }
        clipboardConnection?.send(content)
    }

    init(
        crossScreenMouse: CrossScreenMouseController,
        onClipboardStatusChanged: @escaping (ClipboardSharingStatus) -> Void,
        onMicrophoneStatusChanged: @escaping (MicrophoneSharingStatus) -> Void,
        onMouseReadinessChanged: @escaping (WindowsMouseReadiness?) -> Void,
        onWindowsOnline: @escaping () -> Void
    ) {
        self.crossScreenMouse = crossScreenMouse
        self.onClipboardStatusChanged = onClipboardStatusChanged
        self.onMicrophoneStatusChanged = onMicrophoneStatusChanged
        self.onMouseReadinessChanged = onMouseReadinessChanged
        self.onWindowsOnline = onWindowsOnline
        FileClipboardCache.refreshProtectedPathsAndCleanup()
        observePowerState()
    }

    func setClipboardEnabled(_ enabled: Bool) {
        guard clipboardEnabled != enabled else {
            if enabled { startIfNeeded() }
            return
        }
        clipboardEnabled = enabled
        if enabled {
            if let connection = clipboardConnection {
                microphoneSharing.stopRuntime()
                connection.stop()
                clipboardConnection = nil
                clipboardPeer = nil
            }
            startIfNeeded()
            onClipboardStatusChanged(.listening)
        } else {
            monitor.stop()
            microphoneSharing.stopRuntime()
            clipboardConnection?.stop()
            clipboardConnection = nil
            clipboardPeer = nil
            onClipboardStatusChanged(.off)
            stopIfUnused()
        }
    }

    func setMicrophoneEnabled(_ enabled: Bool) {
        if !enabled {
            crossScreenMouse.releaseMicrophoneActivationIfNeeded()
        }
        guard microphoneEnabled != enabled else {
            if enabled { microphoneSharing.refreshAuthorization() }
            return
        }
        microphoneEnabled = enabled
        microphoneSharing.setEnabled(enabled)
        if enabled, microphoneSharing.canNegotiate {
            startIfNeeded()
        } else if !enabled {
            stopIfUnused()
        }
    }

    func setMicrophoneActivationHeld(_ held: Bool) {
        microphoneSharing.setActivationHeld(held)
    }

    func openMicrophoneSettings() {
        microphoneSharing.openSystemSettings()
    }

    func setMouseServiceEnabled(_ enabled: Bool) {
        mouseServiceEnabled = enabled
        crossScreenMouse.setEnabled(enabled)
        if enabled {
            startIfNeeded()
        } else {
            stopMouseRuntime()
            stopIfUnused()
        }
    }

    func restartListening() {
        guard hasEnabledFeature, !systemIsSleeping else { return }
        stopRuntime()
        startIfNeeded()
    }

    func stopForApplicationExit() {
        clipboardEnabled = false
        mouseServiceEnabled = false
        microphoneEnabled = false
        wakeWorkItem?.cancel()
        wakeWorkItem = nil
        crossScreenMouse.stopForApplicationExit()
        microphoneSharing.stopForApplicationExit()
        stopRuntime()
    }

    private var hasEnabledFeature: Bool {
        clipboardEnabled || mouseServiceEnabled || microphoneSharing.canNegotiate
    }

    private func startIfNeeded() {
        guard hasEnabledFeature, !systemIsSleeping, server == nil else { return }
        if mouseServiceEnabled {
            crossScreenMouse.setRuntimeFailure(nil)
        }
        if clipboardEnabled {
            onClipboardStatusChanged(.listening)
        }
        let serverID = UUID()
        let server = WindowsCompanionServer(
            audioEnabled: microphoneSharing.canNegotiate,
            onClipboardConnection: { [weak self] networkConnection, audioPort in
                Task { @MainActor [weak self] in
                    self?.acceptClipboard(
                        networkConnection,
                        audioPort: audioPort,
                        from: serverID
                    )
                }
            },
            onMouseConnection: { [weak self] networkConnection, noDelayEnabled in
                Task { @MainActor [weak self] in
                    self?.acceptMouse(
                        networkConnection,
                        noDelayEnabled: noDelayEnabled,
                        from: serverID
                    )
                }
            },
            onAudioConnection: { [weak self] networkConnection in
                Task { @MainActor [weak self] in
                    self?.acceptAudio(networkConnection, from: serverID)
                }
            },
            onState: { [weak self] result in
                Task { @MainActor [weak self] in
                    self?.serverStateChanged(result, from: serverID)
                }
            },
            onAudioState: { [weak self] result in
                Task { @MainActor [weak self] in
                    self?.audioListenerStateChanged(result, from: serverID)
                }
            }
        )
        self.serverID = serverID
        self.server = server
        server.start()
    }

    private func stopIfUnused() {
        if !hasEnabledFeature {
            stopRuntime()
        }
    }

    private func stopRuntime() {
        monitor.stop()
        clipboardConnection?.stop()
        clipboardConnection = nil
        clipboardPeer = nil
        microphoneSharing.stopRuntime()
        stopMouseRuntime()
        serverID = nil
        server?.stop()
        server = nil
    }

    private func stopMouseRuntime() {
        onMouseReadinessChanged(nil)
        let mouseConnection = mouseConnection
        crossScreenMouse.setConnection(nil)
        mouseConnection?.stop()
        self.mouseConnection = nil
    }

    private func acceptClipboard(
        _ networkConnection: NWConnection,
        audioPort: UInt16?,
        from serverID: UUID
    ) {
        guard IncomingConnectionAdmission.allows(
            serviceEnabled: clipboardEnabled || microphoneSharing.canNegotiate,
            systemIsSleeping: systemIsSleeping,
            serverMatches: self.serverID == serverID,
            slotIsOccupied: clipboardConnection != nil
        ) else {
            networkConnection.cancel()
            return
        }
        let connectionID = UUID()
        var supportedCapabilities: Set<CompanionCapability> = [.windowsOnline]
        if clipboardEnabled {
            supportedCapabilities.formUnion([.textClipboard, .pngClipboard, .fileClipboard])
        }
        if microphoneSharing.canNegotiate, audioPort != nil {
            supportedCapabilities.insert(.macMicrophone)
        }
        let connection = ClipboardConnection(
            id: connectionID,
            connection: networkConnection,
            localName: localName,
            supportedCapabilities: supportedCapabilities,
            audioPort: supportedCapabilities.contains(.macMicrophone) ? audioPort : nil,
            onReady: { [weak self] name, capabilities in
                Task { @MainActor [weak self] in
                    guard let self,
                          clipboardConnection?.id == connectionID else { return }
                    clipboardPeer = (
                        name,
                        clipboardConnection?.remoteAddress ?? ""
                    )
                    if clipboardEnabled {
                        monitor.start()
                        onClipboardStatusChanged(
                            .connected(
                                name: name,
                                address: clipboardPeer?.address ?? ""
                            )
                        )
                    }
                    microphoneSharing.controlReady(
                        connectionID: connectionID,
                        microphoneNegotiated: capabilities.contains(.macMicrophone)
                    )
                    let capabilityIDs = capabilities.map(\.rawValue).sorted().map(String.init)
                        .joined(separator: ",")
                    let connectedMessage = "Windows control connected to \(name); "
                        + "negotiated capabilities=[\(capabilityIDs)]"
                    logger.info("\(connectedMessage, privacy: .public)")
                }
            },
            onContent: { [weak self] content in
                Task { @MainActor [weak self] in
                    guard let self,
                          clipboardEnabled,
                          clipboardConnection?.id == connectionID else { return }
                    monitor.writeRemote(content)
                }
            },
            onFiles: { [weak self] urls, completion in
                Task { @MainActor [weak self] in
                    guard let self,
                          clipboardEnabled,
                          clipboardConnection?.id == connectionID else {
                        completion(false)
                        return
                    }
                    completion(monitor.writeRemoteFiles(urls))
                }
            },
            onWindowsOnline: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self,
                          clipboardConnection?.id == connectionID else { return }
                    self.onWindowsOnline()
                    self.logger.info("Windows online notification received")
                }
            },
            onDisconnect: { [weak self] reason in
                Task { @MainActor [weak self] in
                    guard let self,
                          clipboardConnection?.id == connectionID else { return }
                    monitor.stop()
                    microphoneSharing.controlDisconnected(connectionID: connectionID)
                    clipboardConnection = nil
                    clipboardPeer = nil
                    if clipboardEnabled, !systemIsSleeping {
                        onClipboardStatusChanged(.listening)
                    }
                    if let reason {
                        logger.error("Clipboard connection ended: \(reason, privacy: .public)")
                    }
                }
            }
        )
        clipboardConnection = connection
        connection.start()
    }

    private func acceptAudio(_ networkConnection: NWConnection, from serverID: UUID) {
        guard self.serverID == serverID, !systemIsSleeping,
              microphoneSharing.canNegotiate else {
            networkConnection.cancel()
            return
        }
        microphoneSharing.acceptAudio(networkConnection, localName: localName)
    }

    private func acceptMouse(
        _ networkConnection: NWConnection,
        noDelayEnabled: Bool,
        from serverID: UUID
    ) {
        guard IncomingConnectionAdmission.allows(
            serviceEnabled: mouseServiceEnabled,
            systemIsSleeping: systemIsSleeping,
            serverMatches: self.serverID == serverID,
            slotIsOccupied: mouseConnection != nil
        ) else {
            networkConnection.cancel()
            return
        }
        let connectionID = UUID()
        let connection = MouseConnection(
            id: connectionID,
            connection: networkConnection,
            noDelayEnabled: noDelayEnabled,
            localName: localName,
            onReady: { [weak self] peer in
                Task { @MainActor [weak self] in
                    guard let self,
                          mouseConnection?.id == connectionID,
                          let mouseConnection else { return }
                    let driverFailure = peer.driverAvailable ? nil
                        : "Windows 已连接，但 Meno Virtual Mouse 驱动尚未安装、需要重启，或版本不匹配。共享剪贴板不受影响。"
                    crossScreenMouse.setConnection(
                        mouseConnection,
                        peer: peer,
                        runtimeFailure: driverFailure
                    )
                    if peer.driverAvailable {
                        onMouseReadinessChanged(
                            WindowsMouseReadiness(
                                connectionID: connectionID,
                                remoteName: peer.name,
                                driverABI: peer.driverABI,
                                screenMetrics: peer.screenMetrics,
                                keyboardSupported: peer.keyboardSupported
                            )
                        )
                    } else {
                        onMouseReadinessChanged(nil)
                    }
                    logger.info("Mouse channel connected to \(peer.name, privacy: .public)")
                }
            },
            onAcquired: { [weak self] controlID in
                Task { @MainActor [weak self] in
                    guard let self,
                          mouseConnection?.id == connectionID else { return }
                    crossScreenMouse.remoteDidAcquire(controlID: controlID)
                }
            },
            onReleased: { [weak self] controlID in
                Task { @MainActor [weak self] in
                    guard let self,
                          mouseConnection?.id == connectionID else { return }
                    crossScreenMouse.remoteDidRelease(controlID: controlID)
                }
            },
            onLeave: { [weak self] controlID, normalizedY in
                Task { @MainActor [weak self] in
                    guard let self,
                          mouseConnection?.id == connectionID else { return }
                    crossScreenMouse.remoteDidLeave(
                        controlID: controlID,
                        normalizedY: normalizedY
                    )
                }
            },
            onDriverUnavailable: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self,
                          mouseConnection?.id == connectionID else { return }
                    crossScreenMouse.driverDidBecomeUnavailable(
                        "Windows 的 Meno Virtual Mouse 驱动已经失效；请在 Windows 托盘中选择“修复鼠标驱动”。共享剪贴板不受影响。"
                    )
                    onMouseReadinessChanged(nil)
                }
            },
            onDisconnect: { [weak self] reason in
                Task { @MainActor [weak self] in
                    guard let self,
                          mouseConnection?.id == connectionID else { return }
                    mouseConnection = nil
                    onMouseReadinessChanged(nil)
                    crossScreenMouse.setConnection(nil)
                    if let reason {
                        logger.error("Mouse connection ended: \(reason, privacy: .public)")
                    }
                }
            }
        )
        mouseConnection = connection
        connection.start()
    }

    private var localName: String {
        Host.current().localizedName ?? "Mac"
    }

    private func serverStateChanged(_ result: Result<Void, Error>, from serverID: UUID) {
        guard hasEnabledFeature, !systemIsSleeping, self.serverID == serverID else { return }
        switch result {
        case .success:
            if mouseServiceEnabled {
                crossScreenMouse.setRuntimeFailure(nil)
            }
            if clipboardEnabled, clipboardConnection == nil {
                onClipboardStatusChanged(.listening)
            }
            logger.info("Windows companion discovery is listening")
        case let .failure(error):
            self.serverID = nil
            server = nil
            clipboardConnection?.stop()
            clipboardConnection = nil
            clipboardPeer = nil
            microphoneSharing.serverFailed(error.localizedDescription)
            stopMouseRuntime()
            monitor.stop()
            if clipboardEnabled {
                onClipboardStatusChanged(.failed(error.localizedDescription))
            }
            if mouseServiceEnabled {
                crossScreenMouse.setRuntimeFailure(error.localizedDescription)
            }
            logger.error("Windows companion discovery failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func audioListenerStateChanged(
        _ result: Result<UInt16, Error>,
        from serverID: UUID
    ) {
        guard self.serverID == serverID, microphoneSharing.canNegotiate else { return }
        switch result {
        case .success:
            microphoneSharing.listenerReady()
        case let .failure(error):
            microphoneSharing.listenerFailed(error.localizedDescription)
            logger.error("Microphone listener failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func microphoneAvailabilityChanged() {
        if server != nil {
            stopRuntime()
        }
        startIfNeeded()
    }

    private func observePowerState() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    systemIsSleeping = true
                    wakeWorkItem?.cancel()
                    wakeWorkItem = nil
                    stopRuntime()
                }
            }
        )
        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.sessionDidResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.crossScreenMouse.prepareForSystemTransition(forceStopMicrophone: true)
                }
            }
        )
        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.resumeAfterWake()
                }
            }
        )
    }

    private func resumeAfterWake() {
        systemIsSleeping = false
        wakeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !systemIsSleeping else { return }
                if microphoneEnabled {
                    microphoneSharing.refreshAuthorization()
                }
                guard hasEnabledFeature else { return }
                startIfNeeded()
            }
        }
        wakeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: workItem)
    }
}
