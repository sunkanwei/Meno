import XCTest

final class WindowsAgentHealthTests: XCTestCase {
    func testDecodesMinimalModelIndependentHealth() throws {
        let data = Data(
            #"{"status":"ok","service":"windows-agent","version":"1.0.0","protocol":"mcp-streamable-http"}"#.utf8
        )

        let health = try JSONDecoder().decode(WindowsAgentHealth.self, from: data)

        XCTAssertEqual(health.status, "ok")
        XCTAssertEqual(health.service, "windows-agent")
        XCTAssertEqual(health.version, "1.0.0")
        XCTAssertEqual(health.protocolName, "mcp-streamable-http")
    }

    func testIgnoresLegacyAndFutureModelFields() throws {
        let data = Data(
            #"{"status":"ok","service":"windows-agent","version":"0.1.0","protocol":"mcp-streamable-http","ollama":{"available":true},"qwen_code":{"available":true},"local_model":"qwen","cloud_model":"deepseek","providers":["future"]}"#.utf8
        )

        let health = try JSONDecoder().decode(WindowsAgentHealth.self, from: data)

        XCTAssertEqual(health.status, "ok")
        XCTAssertEqual(health.service, "windows-agent")
    }
}
