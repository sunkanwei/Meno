import Foundation
import Network

final class WindowsCompanionServer: @unchecked Sendable {
    typealias ConnectionHandler = @Sendable (NWConnection) -> Void
    typealias ClipboardConnectionHandler = @Sendable (NWConnection, UInt16?) -> Void
    typealias MouseConnectionHandler = @Sendable (NWConnection) -> Void
    typealias StateHandler = @Sendable (Result<Void, Error>) -> Void
    typealias AudioStateHandler = @Sendable (Result<UInt16, Error>) -> Void

    private let queue = DispatchQueue(label: "com.sunkanwei.Meno.WindowsCompanionDiscovery")
    private let audioEnabled: Bool
    private let onClipboardConnection: ClipboardConnectionHandler
    private let onMouseConnection: MouseConnectionHandler
    private let onAudioConnection: ConnectionHandler
    private let onState: StateHandler
    private let onAudioState: AudioStateHandler
    private var clipboardListener: NWListener?
    private var mouseListener: NWListener?
    private var audioListener: NWListener?
    private var udpListener: NWListener?
    private var clipboardPort: NWEndpoint.Port?
    private var mousePort: NWEndpoint.Port?
    private var audioPort: NWEndpoint.Port?
    private var clipboardReady = false
    private var mouseReady = false
    private var audioSettled = false
    private var udpReady = false
    private var discoveryConnections: [ObjectIdentifier: NWConnection] = [:]

    init(
        audioEnabled: Bool,
        onClipboardConnection: @escaping ClipboardConnectionHandler,
        onMouseConnection: @escaping MouseConnectionHandler,
        onAudioConnection: @escaping ConnectionHandler,
        onState: @escaping StateHandler,
        onAudioState: @escaping AudioStateHandler
    ) {
        self.audioEnabled = audioEnabled
        self.onClipboardConnection = onClipboardConnection
        self.onMouseConnection = onMouseConnection
        self.onAudioConnection = onAudioConnection
        self.onState = onState
        self.onAudioState = onAudioState
    }

    func start() {
        queue.async { [weak self] in
            self?.startListeners()
        }
    }

    func stop() {
        queue.sync {
            self.stopListeners()
        }
    }

    private func startListeners() {
        stopListeners()
        audioSettled = !audioEnabled
        do {
            let clipboardListener = try makeTCPListener(
                onConnection: { [weak self] connection in
                    guard let self, audioSettled else {
                        connection.cancel()
                        return
                    }
                    onClipboardConnection(connection, audioPort?.rawValue)
                },
                onReady: { [weak self] listener in
                    guard let self, let port = listener.port else {
                        self?.fail(CompanionDiscoveryError.missingClipboardPort)
                        return
                    }
                    clipboardPort = port
                    clipboardReady = true
                    reportReadyIfNeeded()
                }
            )
            let mouseListener = try makeTCPListener(
                noDelay: true,
                onConnection: { [onMouseConnection] connection in
                    onMouseConnection(connection)
                },
                onReady: { [weak self] listener in
                    guard let self, let port = listener.port else {
                        self?.fail(CompanionDiscoveryError.missingMousePort)
                        return
                    }
                    mousePort = port
                    mouseReady = true
                    reportReadyIfNeeded()
                }
            )

            if audioEnabled {
                do {
                    let audioListener = try makeTCPListener(
                        noDelay: true,
                        onConnection: onAudioConnection,
                        onReady: { [weak self] listener in
                            guard let self, let port = listener.port else {
                                self?.audioFailed(CompanionDiscoveryError.missingAudioPort)
                                return
                            }
                            audioPort = port
                            audioSettled = true
                            onAudioState(.success(port.rawValue))
                            reportReadyIfNeeded()
                        },
                        onFailure: { [weak self] error in
                            self?.audioFailed(error)
                        }
                    )
                    self.audioListener = audioListener
                    audioListener.start(queue: queue)
                } catch {
                    audioFailed(error)
                }
            }

            let udpParameters = NWParameters.udp
            udpParameters.allowLocalEndpointReuse = true
            guard let discoveryPort = NWEndpoint.Port(rawValue: ClipboardWire.discoveryPort) else {
                throw CompanionDiscoveryError.invalidDiscoveryPort
            }
            let udpListener = try NWListener(using: udpParameters, on: discoveryPort)
            udpListener.newConnectionHandler = { [weak self] connection in
                self?.receiveDiscovery(on: connection)
            }
            udpListener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    udpReady = true
                    reportReadyIfNeeded()
                case let .failed(error):
                    fail(error)
                default:
                    break
                }
            }

            self.clipboardListener = clipboardListener
            self.mouseListener = mouseListener
            self.udpListener = udpListener
            clipboardListener.start(queue: queue)
            mouseListener.start(queue: queue)
            udpListener.start(queue: queue)
        } catch {
            fail(error)
        }
    }

    private func makeTCPListener(
        noDelay: Bool = false,
        onConnection: @escaping ConnectionHandler,
        onReady: @escaping @Sendable (NWListener) -> Void,
        onFailure: (@Sendable (Error) -> Void)? = nil
    ) throws -> NWListener {
        let parameters: NWParameters
        if noDelay {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.noDelay = true
            parameters = NWParameters(tls: nil, tcp: tcpOptions)
            parameters.serviceClass = .responsiveData
        } else {
            parameters = .tcp
        }
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = onConnection
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            switch state {
            case .ready:
                onReady(listener)
            case let .failed(error):
                if let onFailure {
                    onFailure(error)
                } else {
                    fail(error)
                }
            default:
                break
            }
        }
        return listener
    }

    private func receiveDiscovery(on connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        discoveryConnections[identifier] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                connection.receiveMessage { [weak self, weak connection] data, _, _, error in
                    guard let self, let connection else { return }
                    guard error == nil,
                          let data,
                          ClipboardWire.isDiscoverPacket(data),
                          audioSettled,
                          let clipboardPort,
                          let mousePort else {
                        finishDiscovery(connection, identifier: identifier)
                        return
                    }
                    let response = ClipboardWire.discoveryPacket(
                        type: 2,
                        clipboardPort: clipboardPort.rawValue,
                        mousePort: mousePort.rawValue
                    )
                    connection.send(content: response, completion: .contentProcessed { [weak self] _ in
                        self?.finishDiscovery(connection, identifier: identifier)
                    })
                }
            case .failed, .cancelled:
                finishDiscovery(connection, identifier: identifier)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func finishDiscovery(_ connection: NWConnection, identifier: ObjectIdentifier) {
        guard discoveryConnections.removeValue(forKey: identifier) != nil else { return }
        connection.cancel()
    }

    private func reportReadyIfNeeded() {
        guard clipboardReady, mouseReady, audioSettled, udpReady else { return }
        onState(.success(()))
    }

    private func audioFailed(_ error: Error) {
        audioListener?.cancel()
        audioListener = nil
        audioPort = nil
        audioSettled = true
        onAudioState(.failure(error))
        reportReadyIfNeeded()
    }

    private func fail(_ error: Error) {
        stopListeners()
        onState(.failure(error))
    }

    private func stopListeners() {
        clipboardListener?.cancel()
        mouseListener?.cancel()
        audioListener?.cancel()
        udpListener?.cancel()
        clipboardListener = nil
        mouseListener = nil
        audioListener = nil
        udpListener = nil
        clipboardPort = nil
        mousePort = nil
        audioPort = nil
        clipboardReady = false
        mouseReady = false
        audioSettled = false
        udpReady = false
        for connection in discoveryConnections.values {
            connection.cancel()
        }
        discoveryConnections.removeAll()
    }
}

private enum CompanionDiscoveryError: LocalizedError {
    case invalidDiscoveryPort
    case missingClipboardPort
    case missingMousePort
    case missingAudioPort

    var errorDescription: String? {
        switch self {
        case .invalidDiscoveryPort:
            return "局域网发现端口无效。"
        case .missingClipboardPort:
            return "系统没有分配剪贴板连接端口。"
        case .missingMousePort:
            return "系统没有分配跨屏鼠标连接端口。"
        case .missingAudioPort:
            return "系统没有分配麦克风连接端口。"
        }
    }
}
