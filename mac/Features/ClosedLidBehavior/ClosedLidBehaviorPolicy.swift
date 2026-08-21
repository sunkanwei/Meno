import Foundation

enum ClosedLidBehaviorStatus: Equatable {
    case followingSystem
    case monitoring(ClosedLidMode)
    case keepingRunning
    case sleepRequested
    case failed(String)

    var title: String {
        switch self {
        case .followingSystem:
            return "正在跟随系统"
        case .monitoring:
            return "已就绪，等待合盖"
        case .keepingRunning:
            return "已合盖，电脑仍在运行"
        case .sleepRequested:
            return "已合盖，正在进入系统睡眠"
        case .failed:
            return "出现异常，已恢复系统默认行为"
        }
    }

    var detail: String {
        switch self {
        case .followingSystem:
            return "Meno 当前不干预合盖行为。"
        case let .monitoring(mode):
            return mode.detail
        case .keepingRunning:
            return "MacBook 当前已合上；电脑继续运行，所有显示器保持关闭。"
        case .sleepRequested:
            return "Meno 已请求标准系统睡眠，后续电源管理由 macOS 决定。"
        case let .failed(message):
            return message
        }
    }
}

enum MenoLidState: Equatable, Sendable {
    case open
    case closed
    case unavailable
}

enum ClosedLidMode: String, CaseIterable, Identifiable, Sendable {
    case followSystem
    case keepRunning
    case sleep
    case shutdown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .followSystem:
            return "跟随系统"
        case .keepRunning:
            return "合盖继续运行"
        case .sleep:
            return "合盖立即睡眠"
        case .shutdown:
            return "合盖自动关机"
        }
    }

    var detail: String {
        switch self {
        case .followSystem:
            return "Meno 不干预合盖行为，由 macOS 按当前电源和外接设备状态决定。"
        case .keepRunning:
            return "合上 MacBook 后，电脑继续运行，同时关闭所有显示器。"
        case .sleep:
            return "合上 MacBook 后，立即请求标准系统睡眠；后续电源管理由 macOS 决定。"
        case .shutdown:
            return "合上 MacBook 后，清除会话恢复名单并立即关机；未保存的内容可能丢失。"
        }
    }
}

enum ClosedLidBehaviorAction: Equatable, Sendable {
    case followSystem
    case monitor(ClosedLidMode)
    case keepRunning(requestDisplaySleep: Bool)
    case sleep(requestSystemSleep: Bool)
    case failSafe
}

enum ClosedLidBehaviorPolicy {
    static func action(
        for lidState: MenoLidState,
        mode: ClosedLidMode,
        requestDisplaySleep: Bool,
        requestSystemSleep: Bool
    ) -> ClosedLidBehaviorAction {
        guard mode != .followSystem else {
            return .followSystem
        }

        switch lidState {
        case .open:
            return .monitor(mode)
        case .closed:
            switch mode {
            case .followSystem:
                return .followSystem
            case .keepRunning:
                return .keepRunning(requestDisplaySleep: requestDisplaySleep)
            case .sleep:
                return .sleep(requestSystemSleep: requestSystemSleep)
            case .shutdown:
                return .monitor(.shutdown)
            }
        case .unavailable:
            return .failSafe
        }
    }
}

enum ClosedLidReconcileReason: String, Equatable, Sendable {
    case initialization
    case lidStateChanged
    case displayConfigurationChanged
    case displaysWoke
    case systemWoke
    case systemWillSleep
}

struct ClosedLidReconcileRequest: Equatable, Sendable {
    let reason: ClosedLidReconcileReason
    let requestsDisplaySleep: Bool
    let requestsSystemSleep: Bool
}

struct PendingClosedLidReconcile: Sendable {
    private(set) var reason: ClosedLidReconcileReason?
    private(set) var requestsDisplaySleep = false
    private(set) var requestsSystemSleep = false

    mutating func merge(
        reason: ClosedLidReconcileReason,
        requestDisplaySleep: Bool,
        requestSystemSleep: Bool
    ) {
        self.reason = reason
        requestsDisplaySleep = requestsDisplaySleep || requestDisplaySleep
        requestsSystemSleep = requestsSystemSleep || requestSystemSleep
    }

    mutating func consume() -> ClosedLidReconcileRequest? {
        guard let reason else { return nil }
        let request = ClosedLidReconcileRequest(
            reason: reason,
            requestsDisplaySleep: requestsDisplaySleep,
            requestsSystemSleep: requestsSystemSleep
        )
        reset()
        return request
    }

    mutating func reset() {
        reason = nil
        requestsDisplaySleep = false
        requestsSystemSleep = false
    }
}
