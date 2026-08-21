@preconcurrency import CoreGraphics
import Darwin

enum MacCursorOwnership {
    private typealias ConnectionID = Int32
    private typealias DefaultConnection = @convention(c) () -> ConnectionID
    private typealias SetConnectionProperty = @convention(c) (
        ConnectionID,
        ConnectionID,
        CFString,
        CFTypeRef
    ) -> CGError
    private typealias SuppressionSetter = @convention(c) (CFTimeInterval) -> CGError

    private enum Symbols {
        nonisolated(unsafe) static let handle = dlopen(nil, RTLD_LAZY)
        static let defaultConnection: DefaultConnection? = symbol(
            "_CGSDefaultConnection",
            as: DefaultConnection.self
        )
        static let setConnectionProperty: SetConnectionProperty? = symbol(
            "CGSSetConnectionProperty",
            as: SetConnectionProperty.self
        )
        static let suppressionSetter: SuppressionSetter? = symbol(
            "CGSetLocalEventsSuppressionInterval",
            as: SuppressionSetter.self
        )
        static let allAvailable = defaultConnection != nil
            && setConnectionProperty != nil
            && suppressionSetter != nil

        private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let handle, let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
    }

    enum BackgroundControlResult {
        case enabled
        case unavailable
        case failed(CGError)

        var succeeded: Bool {
            if case .enabled = self { return true }
            return false
        }

        var logValue: Int32 {
            switch self {
            case .enabled: 0
            case .unavailable: -1
            case let .failed(error): error.rawValue
            }
        }
    }

    struct CaptureToken {
        fileprivate init() {}
    }

    struct CaptureResult {
        let token: CaptureToken?
        let backgroundControl: BackgroundControlResult
        let hideError: CGError?
        let detachError: CGError?
        let rollbackAssociationError: CGError?
        let rollbackShowError: CGError?
    }

    struct RestoreResult {
        let backgroundControl: BackgroundControlResult
        let suppressionError: CGError?
        let warpError: CGError?
        let associationError: CGError
        let showError: CGError

        var succeeded: Bool {
            backgroundControl.succeeded
                && suppressionError == .success
                && (warpError == nil || warpError == .success)
                && associationError == .success
                && showError == .success
        }
    }

    struct SystemOperations {
        let enableBackgroundControl: () -> BackgroundControlResult
        let hideCursor: () -> CGError
        let showCursor: () -> CGError
        let associateMouseAndCursor: (Bool) -> CGError
        let reduceSuppressionInterval: () -> CGError?
        let warpCursor: (CGPoint) -> CGError
    }

    static func prepareBackgroundControl() -> BackgroundControlResult {
        guard Symbols.allAvailable else { return .unavailable }
        return enableBackgroundCursorControl()
    }

    static func currentLocation() -> CGPoint? {
        CGEvent(source: nil)?.location
    }

    static func warpLocalCursor(to point: CGPoint) -> CGError {
        // Keep physical input responsive immediately after repositioning the
        // system cursor for a display transition.
        _ = reduceLocalEventSuppressionInterval()
        return CGWarpMouseCursorPosition(point)
    }

    static func capture() -> CaptureResult {
        guard Symbols.allAvailable else {
            return CaptureResult(
                token: nil,
                backgroundControl: .unavailable,
                hideError: nil,
                detachError: nil,
                rollbackAssociationError: nil,
                rollbackShowError: nil
            )
        }
        return capture(using: liveSystemOperations)
    }

    static func capture(using operations: SystemOperations) -> CaptureResult {
        let backgroundControl = operations.enableBackgroundControl()
        guard backgroundControl.succeeded else {
            return CaptureResult(
                token: nil,
                backgroundControl: backgroundControl,
                hideError: nil,
                detachError: nil,
                rollbackAssociationError: nil,
                rollbackShowError: nil
            )
        }

        let hideError = operations.hideCursor()
        guard hideError == .success else {
            return CaptureResult(
                token: nil,
                backgroundControl: backgroundControl,
                hideError: hideError,
                detachError: nil,
                rollbackAssociationError: nil,
                rollbackShowError: nil
            )
        }

        let detachError = operations.associateMouseAndCursor(false)
        guard detachError == .success else {
            let rollbackAssociationError = operations.associateMouseAndCursor(true)
            return CaptureResult(
                token: nil,
                backgroundControl: backgroundControl,
                hideError: hideError,
                detachError: detachError,
                rollbackAssociationError: rollbackAssociationError,
                rollbackShowError: operations.showCursor()
            )
        }
        return CaptureResult(
            token: CaptureToken(),
            backgroundControl: backgroundControl,
            hideError: hideError,
            detachError: detachError,
            rollbackAssociationError: nil,
            rollbackShowError: nil
        )
    }

    static func restore(_ capture: CaptureToken, at point: CGPoint?) -> RestoreResult {
        restore(capture, at: point, using: liveSystemOperations)
    }

    static func restore(
        _ capture: CaptureToken,
        at point: CGPoint?,
        using operations: SystemOperations
    ) -> RestoreResult {
        let backgroundControl = operations.enableBackgroundControl()
        // Prevent the system's post-warp suppression window from delaying
        // physical mouse movement when control returns to this Mac.
        let suppressionError = operations.reduceSuppressionInterval()
        let associationError = operations.associateMouseAndCursor(true)
        let warpError = point.map(operations.warpCursor)
        let showError = operations.showCursor()
        return RestoreResult(
            backgroundControl: backgroundControl,
            suppressionError: suppressionError,
            warpError: warpError,
            associationError: associationError,
            showError: showError
        )
    }

    private static var liveSystemOperations: SystemOperations {
        SystemOperations(
            enableBackgroundControl: enableBackgroundCursorControl,
            hideCursor: { CGDisplayHideCursor(CGMainDisplayID()) },
            showCursor: { CGDisplayShowCursor(CGMainDisplayID()) },
            associateMouseAndCursor: {
                CGAssociateMouseAndMouseCursorPosition($0 ? 1 : 0)
            },
            reduceSuppressionInterval: reduceLocalEventSuppressionInterval,
            warpCursor: CGWarpMouseCursorPosition
        )
    }

    private static func reduceLocalEventSuppressionInterval() -> CGError? {
        Symbols.suppressionSetter?(0.0001)
    }

    private static func enableBackgroundCursorControl() -> BackgroundControlResult {
        guard let defaultConnection = Symbols.defaultConnection,
              let setConnectionProperty = Symbols.setConnectionProperty else {
            return .unavailable
        }
        let connection = defaultConnection()
        let error = setConnectionProperty(
            connection,
            connection,
            "SetsCursorInBackground" as CFString,
            kCFBooleanTrue
        )
        return error == .success ? .enabled : .failed(error)
    }
}
