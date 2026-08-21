import XCTest

final class CodexMCPConfigTests: XCTestCase {
    func testAddsWindowsAgentWithoutChangingExistingServers() {
        let original = """
        model = "gpt-5"

        [mcp_servers.hora]
        command = "/Applications/HORA"
        """
        let url = URL(string: "http://192.168.1.104:45900/mcp")!

        let result = CodexMCPConfigDocument.upsertingWindowsAgent(in: original, url: url)

        XCTAssertTrue(result.changed)
        XCTAssertTrue(result.text.contains("[mcp_servers.hora]\ncommand = \"/Applications/HORA\""))
        XCTAssertTrue(result.text.contains("[mcp_servers.windows_agent]\nurl = \"http://192.168.1.104:45900/mcp\""))
    }

    func testUpdatesOnlyWindowsAgentURL() {
        let original = """
        [mcp_servers.windows_agent]
        url = "http://192.168.1.10:45900/mcp"
        enabled = true

        [mcp_servers.hora]
        command = "/Applications/HORA"
        """
        let url = URL(string: "http://192.168.1.104:45900/mcp")!

        let result = CodexMCPConfigDocument.upsertingWindowsAgent(in: original, url: url)

        XCTAssertTrue(result.changed)
        XCTAssertTrue(result.text.contains("enabled = true"))
        XCTAssertTrue(result.text.contains("url = \"http://192.168.1.104:45900/mcp\""))
        XCTAssertTrue(result.text.contains("[mcp_servers.hora]"))
    }

    func testLeavesMatchingConfigurationUnchanged() {
        let original = """
        [mcp_servers.windows_agent]
        url = "http://192.168.1.104:45900/mcp"
        """
        let url = URL(string: "http://192.168.1.104:45900/mcp")!

        let result = CodexMCPConfigDocument.upsertingWindowsAgent(in: original, url: url)

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.text, original)
        XCTAssertEqual(CodexMCPConfigDocument.configuredURL(in: result.text), url)
    }
}
