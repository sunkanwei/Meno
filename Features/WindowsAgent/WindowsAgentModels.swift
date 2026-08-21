import Foundation

struct WindowsAgentEndpoint: Equatable, Sendable {
    let name: String
    let host: String
    let port: UInt16
    let path: String

    var url: URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        components.path = path.hasPrefix("/") ? path : "/\(path)"
        return components.url
    }

    var displayAddress: String {
        "\(host):\(port)"
    }
}

struct WindowsAgentHealth: Decodable, Equatable, Sendable {
    let status: String
    let service: String
    let version: String?
    let protocolName: String?

    private enum CodingKeys: String, CodingKey {
        case status
        case service
        case version
        case protocolName = "protocol"
    }
}

enum WindowsAgentPhase: Equatable, Sendable {
    case stopped
    case searching
    case checking
    case connected
    case unavailable(String)

    var title: String {
        switch self {
        case .stopped: "已停止"
        case .searching: "正在查找"
        case .checking: "正在检查"
        case .connected: "已连接"
        case .unavailable: "暂时不可用"
        }
    }

    var detail: String {
        switch self {
        case .stopped:
            "Meno 没有运行 Windows Agent 发现服务。"
        case .searching:
            "正在家庭局域网中查找 Windows Agent。"
        case .checking:
            "已经发现 Windows Agent，正在核对服务状态。"
        case .connected:
            "Windows Agent 可用，Codex 可以直接连接。"
        case let .unavailable(message):
            message
        }
    }
}

enum CodexWindowsAgentConfigurationStatus: Equatable, Sendable {
    case checking
    case current
    case updated
    case failed(String)

    var title: String {
        switch self {
        case .checking: "正在检查"
        case .current: "配置正常"
        case .updated: "已自动更新"
        case .failed: "配置失败"
        }
    }

    var detail: String {
        switch self {
        case .checking:
            "正在核对 Codex 的 Windows Agent 地址。"
        case .current:
            "Codex 已使用当前 Windows Agent 地址。"
        case .updated:
            "Codex 地址已更新；正在运行的旧任务可能需要重新打开。"
        case let .failed(message):
            message
        }
    }
}
