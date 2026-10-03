import XCTest
@testable import Polycall

/// `polycall_ffi_run_config` / `polycall_ffi_describe` through the Swift API.
final class ConfigTests: XCTestCase {
    /// Repository root (this file is tests/PolycallTests/ConfigTests.swift).
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    var dir: URL!

    override func setUpWithError() throws {
        dir = TestSupport.tempDir("config")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func file(_ name: String, _ text: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try TestSupport.write(text, to: url)
        return url.path
    }

    func testShippedConfigFilesAreValidStrict() throws {
        for name in ["swift-polycallrc", "examples/swift-polycallrc"] {
            let path = Self.repoRoot.appendingPathComponent(name).path
            try Polycall.runConfig(path)                       // documented entry point (run = 1)
            try Polycall.runConfig(path, strict: true)
            try Polycall.runConfig(path, strict: false)
            XCTAssertEqual(try Polycall.runConfigStatus(path), 0)
        }
    }

    func testMissingFileIsNotFound() {
        assertPolycallError(.notFound) {
            try Polycall.runConfig(dir.appendingPathComponent("does-not-exist-polycallrc").path)
        }
        XCTAssertEqual(try Polycall.runConfigStatus(dir.appendingPathComponent("nope").path),
                       PolycallStatus.notFound.rawValue)
    }

    func testEmptyPathIsInvalidArgument() {
        assertPolycallError(.invalidArgument) { try Polycall.runConfig("") }
    }

    func testInvalidValueIsConfigErrorNamingTheKey() throws {
        let path = try file("bad-polycallrc", "max_connections=lots\n")
        let error = assertPolycallError(.config) { try Polycall.runConfig(path, strict: false) }
        XCTAssertTrue(error?.detail.contains("max_connections") ?? false, "\(String(describing: error))")
        assertPolycallError(.config) { try Polycall.runConfig(path) }
    }

    func testUnknownKeyIsWarningLenientAndErrorStrict() throws {
        let path = try file("unknown-polycallrc", "log_level=info\nmystery_key=1\n")
        try Polycall.runConfig(path, strict: false)
        let error = assertPolycallError(.config) { try Polycall.runConfig(path, strict: true) }
        XCTAssertTrue(error?.detail.contains("mystery_key") ?? false, "\(String(describing: error))")
        assertPolycallError(.config) { try Polycall.runConfig(path) }   // documented default is strict
    }

    func testTLSIsUnsupportedWhenStrict() throws {
        let path = try file("tls-polycallrc", "tls_enabled=true\ncert_file=/x/c.pem\nkey_file=/x/k.pem\n")
        try Polycall.runConfig(path, strict: false)
        assertPolycallError(.unsupported) { try Polycall.runConfig(path, strict: true) }
    }

    func testNonASCIIPath() throws {
        let path = try file("\u{00DC}nic\u{00F8}d\u{00E9}-\u{65E5}\u{672C}-polycallrc", "log_level=info\nmax_connections=10\n")
        try Polycall.runConfig(path)
        let json = try Polycall.describe(path)
        XCTAssertTrue(json.contains("max_connections"), json)
    }

    func testDescribePolycallfile() throws {
        let path = try file("Polycallfile", """
            server node 8080:8084
            network start
            workspace_root=/opt/x
            log_directory=/var/log/x
            daemon_endpoint=127.0.0.1:0
            auth_token_env=POLYCALL_DEV_TOKEN
            peer_node_id=alpha
            peer beta 127.0.0.1:9002

            """)
        try Polycall.runConfig(path)
        let json = try Polycall.describe(path)
        XCTAssertTrue(json.contains("\"beta\":\"127.0.0.1:9002\""), json)
        XCTAssertTrue(json.contains("\"layer\":\"project\""), json)
        XCTAssertNotNil(TestSupport.jsonObject(json), "describe returns valid JSON")
    }

    func testDescribeMissingFile() {
        assertPolycallError(.notFound) { try Polycall.describe(dir.appendingPathComponent("nope").path) }
    }
}
