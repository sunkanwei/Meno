import Foundation
import Network

// Shared NWConnection frame plumbing for the three companion channels
// (clipboard, mouse, microphone): state handling, the bounded receive loop,
// frame decoding and terminal failure reporting. Channel-specific state,
// readiness and cleanup stay in the owning connection.
final class CompanionFrameTransport: @unchecked Sendable {
    private static let maximumReceiveLength = 65_536

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let onFrame: (ClipboardFrame) throws -> Void
    private let onActivity: () -> Void
    private let onClosed: (String?) -> Void
    private var decoder = ClipboardFrameDecoder()
    private var didClose = false

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        onFrame: @escaping (ClipboardFrame) throws -> Void,
        onActivity: @escaping () -> Void,
        onClosed: @escaping (String?) -> Void
    ) {
        self.connection = connection
        self.queue = queue
        self.onFrame = onFrame
        self.onActivity = onActivity
        self.onClosed = onClosed
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                receiveNext()
            case let .failed(error):
                close(error.localizedDescription)
            case .cancelled:
                close(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func cancel() {
        connection.cancel()
    }

    func close(_ reason: String?) {
        guard !didClose else { return }
        didClose = true
        onClosed(reason)
        connection.cancel()
    }

    private func receiveNext() {
        guard !didClose else { return }
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: Self.maximumReceiveLength
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                onActivity()
                do {
                    for frame in try decoder.append(data) {
                        try onFrame(frame)
                    }
                } catch {
                    close(error.localizedDescription)
                    return
                }
            }
            if let error {
                close(error.localizedDescription)
                return
            }
            if isComplete {
                close(nil)
                return
            }
            receiveNext()
        }
    }
}
