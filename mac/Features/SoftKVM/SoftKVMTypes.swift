import Foundation

struct WindowsMouseReadiness: Equatable, Sendable {
    let connectionID: UUID
    let remoteName: String
    let driverABI: UInt16
    let screenMetrics: MouseScreenMetrics
    let keyboardSupported: Bool
}

enum SoftKVMStatus: Equatable, Sendable {
    case disabled
    case checking
    case macReady(remoteName: String)
    case macWaiting(reason: String)
    case switchingToWindows
    case windowsReady(remoteName: String)
    case windowsWaiting(reason: String)
    case switchingToMac
    case recoveryNeeded(reason: String)

    var detail: String {
        switch self {
        case .disabled:
            "不会切换 Philips，也不会开放跨屏路由。"
        case .checking:
            "正在只读核对显示拓扑和恢复状态。"
        case let .macReady(remoteName):
            "Mac 三屏基线正常，Windows \(remoteName) 已连接；物理画面未程序确认。"
        case let .macWaiting(reason):
            "Mac 三屏基线正常。\(reason)"
        case .switchingToWindows:
            "正在迁移窗口、请求 DP1 并软断开 Philips。"
        case let .windowsReady(remoteName):
            "DP1 已请求，当前连接 \(remoteName) 的输入路由已开放；物理画面未程序确认。"
        case let .windowsWaiting(reason):
            "DP1 已请求且 Philips 已从 macOS 软断开。\(reason)"
        case .switchingToMac:
            "正在收回输入、恢复 Philips 和窗口。"
        case let .recoveryNeeded(reason):
            "穿越路由已关闭。\(reason)"
        }
    }

    var actionTitle: String {
        switch self {
        case .disabled, .macReady, .macWaiting:
            "切到 Windows"
        case .windowsReady, .windowsWaiting:
            "切回 Mac"
        case .checking:
            "正在检查…"
        case .switchingToWindows, .switchingToMac:
            "正在切换…"
        case .recoveryNeeded:
            "恢复到 Mac"
        }
    }

    var actionEnabled: Bool {
        switch self {
        case .macReady:
            true
        case .windowsReady, .windowsWaiting, .recoveryNeeded:
            true
        case .disabled, .checking, .macWaiting, .switchingToWindows, .switchingToMac:
            false
        }
    }

    var isBusy: Bool {
        switch self {
        case .checking, .switchingToWindows, .switchingToMac:
            true
        case .disabled, .macReady, .macWaiting, .windowsReady, .windowsWaiting,
             .recoveryNeeded:
            false
        }
    }

    var shortcutAcknowledgement: String {
        switch self {
        case .macReady:
            "正在切到 Windows，请稍候。"
        case .windowsReady, .windowsWaiting:
            "正在切回 Mac，请稍候。"
        case .recoveryNeeded:
            "正在恢复到 Mac，请稍候。"
        case .switchingToWindows:
            "切到 Windows 的操作正在进行，请稍候。"
        case .switchingToMac:
            "切回 Mac 的操作正在进行，请稍候。"
        case .checking:
            "正在检查显示状态，请稍候。"
        case .disabled:
            "KVM 当前已关闭。"
        case let .macWaiting(reason):
            "当前暂不能切到 Windows：\(reason)"
        }
    }
}

enum SoftKVMCoordinatorError: LocalizedError {
    case permission(String)
    case inputStillHeld
    case staleWindowsConnection
    case sessionUnavailable
    case routeUnavailable(String)
    case remoteShutdownUnavailable
    case remoteShutdownSendFailed
    case remoteShutdownReturnToMacFailed(String)

    var errorDescription: String? {
        switch self {
        case let .permission(reason):
            reason
        case .inputStillHeld:
            "快捷键、修饰键或鼠标按钮仍被按住，未开始切换显示器。"
        case .staleWindowsConnection:
            "Windows 输入连接在显示切换期间发生变化，跨屏路由保持关闭。"
        case .sessionUnavailable:
            "显示器已经切到 Windows，但 macOS 用户会话当前不允许接管输入，跨屏路由保持关闭。"
        case let .routeUnavailable(reason):
            reason
        case .remoteShutdownUnavailable:
            "Windows 关机能力当前未连接。"
        case .remoteShutdownSendFailed:
            "关机信号未能发送到 Windows。"
        case let .remoteShutdownReturnToMacFailed(reason):
            "关机信号已经发出，但飞利浦未能切回 Mac：\(reason)"
        }
    }
}
