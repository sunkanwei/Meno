import Foundation

enum SoftKVMMouseAvailability: Equatable, Sendable {
    case off
    case needsArrangement
    case waiting
    case standby
    case connected
    case controlling
    case failed(String)
}

enum SoftKVMStateAction: Equatable {
    case disableRoute
    case refresh
}

struct SoftKVMStateMachine {
    private(set) var status: SoftKVMStatus = .disabled
    private(set) var enabled = false
    private(set) var mouseUnavailableReason = "正在等待 Windows 输入通道。"
    private(set) var desiredRouteEnabled = false
    private(set) var activeOperationID: UInt64?
    private(set) var systemIsAwake = true
    private(set) var sessionIsActive = true
    private var mouseAvailability: SoftKVMMouseAvailability?

    var routeMayBeEnabled: Bool {
        systemIsAwake && sessionIsActive
    }

    var operationInProgress: Bool {
        activeOperationID != nil
    }

    var canStartAutomaticRefresh: Bool {
        enabled && routeMayBeEnabled && !operationInProgress
    }

    var invariantViolation: String? {
        if !enabled, desiredRouteEnabled {
            return "disabled state requested an enabled route"
        }
        if desiredRouteEnabled, !routeMayBeEnabled {
            return "route requested while the system session is unavailable"
        }
        if desiredRouteEnabled {
            switch status {
            case .switchingToWindows, .windowsReady:
                break
            case .disabled, .checking, .macReady, .macWaiting, .windowsWaiting,
                 .switchingToMac, .recoveryNeeded:
                return "route requested outside a Windows-ready transition"
            }
        }
        if case .disabled = status, enabled {
            return "enabled state exposed a disabled status"
        }
        return nil
    }

    mutating func start(enabled: Bool) {
        self.enabled = enabled
        desiredRouteEnabled = false
        activeOperationID = nil
        status = enabled ? .checking : .disabled
    }

    mutating func enable() -> Bool {
        guard !enabled else { return false }
        enabled = true
        desiredRouteEnabled = false
        status = .checking
        return true
    }

    mutating func completeDisable(operationID: UInt64) -> Bool {
        guard activeOperationID == operationID else { return false }
        enabled = false
        desiredRouteEnabled = false
        status = .disabled
        return true
    }

    mutating func stop() {
        enabled = false
        desiredRouteEnabled = false
        activeOperationID = nil
        status = .disabled
    }

    mutating func updateReadiness(isAvailable: Bool) -> [SoftKVMStateAction] {
        if !isAvailable {
            switch mouseAvailability {
            case .failed, .needsArrangement, .off:
                break
            case .waiting, .standby, .connected, .controlling, nil:
                mouseUnavailableReason = "正在等待 Windows 输入通道。"
            }
            desiredRouteEnabled = false
            if !operationInProgress {
                switch status {
                case .windowsReady:
                    status = .windowsWaiting(reason: mouseUnavailableReason)
                case .macReady, .macWaiting:
                    status = .macWaiting(reason: mouseUnavailableReason)
                case .disabled, .checking, .switchingToWindows, .windowsWaiting,
                     .switchingToMac, .recoveryNeeded:
                    break
                }
            }
        }

        var actions: [SoftKVMStateAction] = []
        if !isAvailable {
            actions.append(.disableRoute)
        }
        if canStartAutomaticRefresh {
            actions.append(.refresh)
        }
        return actions
    }

    mutating func updateMouseAvailability(
        _ availability: SoftKVMMouseAvailability
    ) -> [SoftKVMStateAction] {
        guard availability != mouseAvailability else { return [] }
        mouseAvailability = availability

        switch availability {
        case let .failed(reason):
            return handleMouseUnavailable(reason: reason)
        case .waiting:
            return handleMouseUnavailable(reason: "正在等待 Windows 输入通道。")
        case .needsArrangement:
            return handleMouseUnavailable(
                reason: "只支持三块已登记屏幕横向相邻、Mac 主屏居中且 Philips 位于左侧或右侧。"
            )
        case .off:
            return handleMouseUnavailable(reason: "Windows 输入服务已关闭。")
        case .standby:
            guard canStartAutomaticRefresh else { return [] }
            switch status {
            case .macWaiting, .windowsReady, .windowsWaiting:
                return [.refresh]
            case .disabled, .checking, .macReady, .switchingToWindows,
                 .switchingToMac, .recoveryNeeded:
                return []
            }
        case .connected, .controlling:
            return []
        }
    }

    mutating func beginOperation(id: UInt64, status: SoftKVMStatus) -> Bool {
        guard activeOperationID == nil else { return false }
        activeOperationID = id
        desiredRouteEnabled = false
        self.status = status
        return true
    }

    mutating func finishOperation(id: UInt64) -> Bool {
        guard activeOperationID == id else { return false }
        activeOperationID = nil
        return true
    }

    mutating func invalidateOperation(reason: String? = nil) {
        let hadOperation = activeOperationID != nil
        activeOperationID = nil
        desiredRouteEnabled = false
        if hadOperation, enabled, let reason {
            status = .recoveryNeeded(reason: reason)
        }
    }

    func isCurrentOperation(_ id: UInt64) -> Bool {
        activeOperationID == id
    }

    mutating func setStatus(_ status: SoftKVMStatus, operationID: UInt64? = nil) -> Bool {
        if let operationID, activeOperationID != operationID {
            return false
        }
        guard self.status != status else { return false }
        self.status = status
        return true
    }

    mutating func setDesiredRouteEnabled(_ enabled: Bool) {
        desiredRouteEnabled = enabled
    }

    mutating func suspend(systemSleeping: Bool, sessionInactive: Bool) {
        if systemSleeping { systemIsAwake = false }
        if sessionInactive { sessionIsActive = false }
        invalidateOperation(reason: "系统状态发生变化，需要重新检查显示与输入状态。")
    }

    mutating func resume(systemWoke: Bool, sessionBecameActive: Bool) {
        if systemWoke { systemIsAwake = true }
        if sessionBecameActive { sessionIsActive = true }
    }

    mutating func forceSafeRecovery(reason: String) {
        desiredRouteEnabled = false
        activeOperationID = nil
        status = enabled ? .recoveryNeeded(reason: reason) : .disabled
    }

    private mutating func handleMouseUnavailable(reason: String) -> [SoftKVMStateAction] {
        mouseUnavailableReason = reason
        guard enabled, !operationInProgress else { return [] }

        switch status {
        case .windowsReady:
            status = .windowsWaiting(reason: reason)
            desiredRouteEnabled = false
            return [.disableRoute]
        case .windowsWaiting:
            status = .windowsWaiting(reason: reason)
            desiredRouteEnabled = false
        case .macReady, .macWaiting:
            status = .macWaiting(reason: reason)
        case .disabled, .checking, .switchingToWindows, .switchingToMac,
             .recoveryNeeded:
            break
        }
        return []
    }
}

@MainActor
final class RunToCompletionEventQueue<Event> {
    private var pending: [(event: Event, handle: (Event) -> Void)] = []
    private var isDraining = false

    func send(_ event: Event, handle: @escaping (Event) -> Void) {
        pending.append((event, handle))
        guard !isDraining else { return }

        isDraining = true
        var index = 0
        while index < pending.count {
            let next = pending[index]
            index += 1
            next.handle(next.event)
        }
        pending.removeAll(keepingCapacity: true)
        isDraining = false
    }
}
