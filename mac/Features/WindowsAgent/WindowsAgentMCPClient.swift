import Foundation

struct WindowsAgentMCPClient: Sendable {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        session = URLSession(configuration: configuration)
    }

    func health(at endpoint: WindowsAgentEndpoint) async throws -> WindowsAgentHealth {
        guard let url = endpoint.url else { throw WindowsAgentMCPError.invalidEndpoint }
        let initialize = try await post(
            url: url,
            sessionID: nil,
            body: [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "protocolVersion": "2025-03-26",
                    "capabilities": [:],
                    "clientInfo": ["name": "Meno", "version": "0.1.0"],
                ],
            ]
        )
        guard let sessionID = initialize.response.value(forHTTPHeaderField: "mcp-session-id"),
              !sessionID.isEmpty else {
            throw WindowsAgentMCPError.missingSession
        }
        _ = try extractResult(from: initialize.data, id: 1)

        _ = try await post(
            url: url,
            sessionID: sessionID,
            body: ["jsonrpc": "2.0", "method": "notifications/initialized"]
        )
        let health = try await post(
            url: url,
            sessionID: sessionID,
            body: [
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/call",
                "params": ["name": "health", "arguments": [:]],
            ]
        )
        let result = try extractResult(from: health.data, id: 2)
        guard let structured = result["structuredContent"] else {
            throw WindowsAgentMCPError.missingHealth
        }
        let data = try JSONSerialization.data(withJSONObject: structured)
        let decoded = try JSONDecoder().decode(WindowsAgentHealth.self, from: data)
        await terminate(url: url, sessionID: sessionID)
        return decoded
    }

    private func post(
        url: URL,
        sessionID: String?,
        body: [String: Any]
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WindowsAgentMCPError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw WindowsAgentMCPError.http(http.statusCode, message)
        }
        return (data, http)
    }

    private func extractResult(from data: Data, id: Int) throws -> [String: Any] {
        let objects = try jsonRPCObjects(from: data)
        guard let response = objects.first(where: { ($0["id"] as? Int) == id }) else {
            throw WindowsAgentMCPError.invalidResponse
        }
        if let error = response["error"] as? [String: Any] {
            throw WindowsAgentMCPError.remote(error["message"] as? String ?? "未知错误")
        }
        guard let result = response["result"] as? [String: Any] else {
            throw WindowsAgentMCPError.invalidResponse
        }
        return result
    }

    private func jsonRPCObjects(from data: Data) throws -> [[String: Any]] {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return [object]
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw WindowsAgentMCPError.invalidResponse
        }
        return text.components(separatedBy: .newlines).compactMap { line in
            guard line.hasPrefix("data:") else { return nil }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload.hasPrefix("{"), let payloadData = payload.data(using: .utf8) else {
                return nil
            }
            return try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        }
    }

    private func terminate(url: URL, sessionID: String) async {
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        _ = try? await session.data(for: request)
    }
}

private enum WindowsAgentMCPError: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case missingSession
    case missingHealth
    case http(Int, String)
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "连接地址无效。"
        case .invalidResponse: "Windows Agent 返回了无法识别的数据。"
        case .missingSession: "Windows Agent 没有建立 MCP 会话。"
        case .missingHealth: "Windows Agent 没有返回健康状态。"
        case let .http(code, message): "Windows Agent 返回 \(code)：\(message)"
        case let .remote(message): "Windows Agent 返回错误：\(message)"
        }
    }
}
