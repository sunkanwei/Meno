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
    private let onMouseReadinessChanged: (WindowsMouseReadiness?) -> Void
    private let onWindowsOnline: () -> Void
    private var clipboardEnabled = false
    private var mouseServiceEnabled = false
    private var systemIsSleeping = false
    private var server: WindowsCompanionServer?
    private var serverID: UUID?
    private var clipboardConnection: ClipboardConnection?
    private var clipboardPeer: (name: String, address: String)?
    private var mouseConnection: MouseConnection?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var wakeWorkItem: DispatchWorkItem?

    private lazy var monitor = ClipboardMonitor { [weak self] content in
        guard let self, clipboardEnabled else { return }
        clipboardConnection?.send(content)
    }

    init(
        crossScreenMouse: CrossScreenMouseController,
        onClipboardStatusChanged: @escaping (ClipboardSharingStatus) -> Void,
        onMouseReadinessChanged: @escaping (WindowsMouseReadiness?) -> Void,
        onWindowsOnline: @escaping () -> Void
    ) {
        self.crossScreenMouse = crossScreenMouse
        self.onClipboardStatusChanged = onClipboardStatusChanged
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
            startIfNeeded()
            onClipboardStatusChanged(.listening)
        } else {
            monitor.stop()
            clipboardConnection?.stop()
            clipboardConnection = nil
            clipboardPeer = nil
            onClipboardStatusChanged(.off)
            stopIfUnused()
        }
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
        wakeWorkItem?.cancel()
        wakeWorkItem = nil
        crossScreenMouse.stopForApplicationExit()
        stopRuntime()
    }

    private var hasEnabledFeature: Bool {
        clipboardEnabled || mouseServiceEnabled
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
            onClipboardConnection: { [weak self] networkConnection in
                Task { @MainActor [weak self] in
                    self?.acceptClipboard(
                        networkConnection,
                        from: serverID
                    )
                }
            },
            onMouseConnection: { [weak self] networkConnection in
                Task { @MainActor [weak self] in
                    self?.acceptMouse(
                        networkConnection,
                        from: serverID
                    )
                }
            },
            onState: { [weak self] result in
                Task { @MainActor [weak self] in
                    self?.serverStateChanged(result, from: serverID)
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
        from serverID: UUID
    ) {
        guard IncomingConnectionAdmission.allows(
            serviceEnabled: clipboardEnabled,
            systemIsSleeping: systemIsSleeping,
            serverMatches: self.serverID == serverID,
            slotIsOccupied: clipboardConnection != nil
        ) else {
            networkConnection.cancel()
            return
        }
        let connectionID = UUID()
        let connection = ClipboardConnection(
            id: connectionID,
            connection: networkConnection,
            localName: localName,
            supportedCapabilities: [.windowsOnline, .textClipboard, .pngClipboard, .fileClipboard],
            onReady: { [weak self] name in
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
                }
            },
            onDisconnect: { [weak self] reason in
                Task { @MainActor [weak self] in
                    guard let self,
                          clipboardConnection?.id == connectionID else { return }
                    monitor.stop()
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

    private func acceptMouse(
        _ networkConnection: NWConnection,
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
                }
            },
            onAcquired: { [weak self] controlID in
                Task { @MainActor [weak self] in
                    guard let self,
                          mouseConnection?.id == connectionID else { return }
                    crossScreenMouse.remoteDidAcquire(
                        connectionID: connectionID,
                        controlID: controlID
                    )
                }
            },
            onReleased: { [weak self] controlID in
                Task { @MainActor [weak self] in
                    guard let self,
                          mouseConnection?.id == connectionID else { return }
                    crossScreenMouse.remoteDidRelease(
                        connectionID: connectionID,
                        controlID: controlID
                    )
                }
            },
            onLeave: { [weak self] controlID, normalizedY in
                Task { @MainActor [weak self] in
                    guard let self,
                          mouseConnection?.id == connectionID else { return }
                    crossScreenMouse.remoteDidLeave(
                        connectionID: connectionID,
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
        case let .failure(error):
            self.serverID = nil
            server = nil
            clipboardConnection?.stop()
            clipboardConnection = nil
            clipboardPeer = nil
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
                    self?.crossScreenMouse.prepareForSystemTransition()
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
                guard hasEnabledFeature else { return }
                startIfNeeded()
            }
        }
        wakeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: workItem)
    }
}
