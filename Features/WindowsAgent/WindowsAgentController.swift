import Combine
import Darwin
import Foundation

@MainActor
final class WindowsAgentController: NSObject, ObservableObject {
    @Published private(set) var phase: WindowsAgentPhase = .stopped
    @Published private(set) var endpoint: WindowsAgentEndpoint?
    @Published private(set) var health: WindowsAgentHealth?
    @Published private(set) var codexStatus: CodexWindowsAgentConfigurationStatus = .checking
    @Published private(set) var lastCheckedAt: Date?

    private let browser = NetServiceBrowser()
    private let client = WindowsAgentMCPClient()
    private let configStore = CodexMCPConfigStore()
    private var services: [String: NetService] = [:]
    private var refreshTask: Task<Void, Never>?
    private var timer: Timer?
    private var started = false

    var menuTitle: String {
        switch phase {
        case .connected: "已连接"
        case .checking: "正在检查"
        case .searching: "正在查找"
        case .unavailable: "不可用"
        case .stopped: "已停止"
        }
    }

    func start() {
        guard !started else { return }
        started = true
        browser.delegate = self
        phase = .searching

        if let configured = configStore.configuredEndpoint() {
            endpoint = configured
            refresh()
        }
        browser.searchForServices(ofType: "_meno-agent._tcp.", inDomain: "local.")
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard started else { return }
        guard let endpoint else {
            phase = .searching
            return
        }
        refreshTask?.cancel()
        phase = .checking
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await client.health(at: endpoint)
                guard !Task.isCancelled, self.endpoint == endpoint else { return }
                health = result
                lastCheckedAt = Date()
                phase = .connected
                synchronizeCodex(with: endpoint)
            } catch {
                guard !Task.isCancelled, self.endpoint == endpoint else { return }
                health = nil
                lastCheckedAt = Date()
                phase = .unavailable(error.localizedDescription)
            }
        }
    }

    func synchronizeCodexNow() {
        guard let endpoint else {
            codexStatus = .failed("尚未发现 Windows Agent，无法写入连接地址。")
            return
        }
        synchronizeCodex(with: endpoint)
    }

    func stopForApplicationExit() {
        started = false
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        refreshTask = nil
        browser.stop()
        for service in services.values {
            service.stop()
        }
        services.removeAll()
        phase = .stopped
    }

    private func synchronizeCodex(with endpoint: WindowsAgentEndpoint) {
        do {
            let changed = try configStore.synchronize(endpoint: endpoint)
            if changed {
                codexStatus = .updated
            } else if codexStatus != .updated {
                codexStatus = .current
            }
        } catch {
            codexStatus = .failed(error.localizedDescription)
        }
    }

    private func acceptResolved(_ service: NetService) {
        guard service.port > 0,
              let port = UInt16(exactly: service.port),
              let host = preferredNumericHost(from: service.addresses ?? []) else { return }
        let endpoint = WindowsAgentEndpoint(
            name: service.name,
            host: host,
            port: port,
            path: servicePath(from: service)
        )
        guard self.endpoint != endpoint else {
            if phase != .connected { refresh() }
            return
        }
        self.endpoint = endpoint
        health = nil
        refresh()
    }

    private func servicePath(from service: NetService) -> String {
        guard let data = service.txtRecordData() else { return "/mcp" }
        let values = NetService.dictionary(fromTXTRecord: data)
        guard let pathData = values["path"],
              let path = String(data: pathData, encoding: .utf8),
              !path.isEmpty else { return "/mcp" }
        return path.hasPrefix("/") ? path : "/\(path)"
    }

    private func preferredNumericHost(from addresses: [Data]) -> String? {
        let resolved = addresses.compactMap(numericHost)
        return resolved.first(where: { $0.family == AF_INET })?.host
            ?? resolved.first?.host
    }

    private func numericHost(from data: Data) -> (host: String, family: Int32)? {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            let address = baseAddress.assumingMemoryBound(to: sockaddr.self)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(data.count),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { return nil }
            let bytes = host.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
            return (String(decoding: bytes, as: UTF8.self), Int32(address.pointee.sa_family))
        }
    }

    private func serviceKey(_ service: NetService) -> String {
        "\(service.name)|\(service.type)|\(service.domain)"
    }
}

extension WindowsAgentController: NetServiceBrowserDelegate {
    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        let reference = NetServiceReference(service)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let service = reference.value
            let key = serviceKey(service)
            services[key] = service
            service.delegate = self
            service.resolve(withTimeout: 6)
        }
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        let reference = NetServiceReference(service)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let service = reference.value
            services.removeValue(forKey: serviceKey(service))?.stop()
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        Task { @MainActor [weak self] in
            guard let self, endpoint == nil else { return }
            phase = .unavailable("无法启动局域网发现，请检查本地网络权限。")
        }
    }
}

extension WindowsAgentController: NetServiceDelegate {
    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        let reference = NetServiceReference(sender)
        Task { @MainActor [weak self] in
            self?.acceptResolved(reference.value)
        }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        Task { @MainActor [weak self] in
            guard let self, endpoint == nil else { return }
            phase = .searching
        }
    }
}

private struct NetServiceReference: @unchecked Sendable {
    let value: NetService

    init(_ value: NetService) {
        self.value = value
    }
}
