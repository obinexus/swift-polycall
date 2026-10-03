import XCTest
@testable import Polycall

/// A Swift peer exchanging payloads in both directions with the C CLI
/// (`polycall peer serve` / `peer send` / `peer recv`, separate processes).
final class InteropTests: XCTestCase {
    func testSwiftPeerAndCCLIPeerExchangeBothDirections() throws {
        let cli = try TestSupport.requireCLI()
        let dir = TestSupport.tempDir("interop")
        defer { try? FileManager.default.removeItem(at: dir) }
        let epFile = dir.appendingPathComponent("cnode.ep")
        let serve = try TestSupport.start(cli, [
            "peer", "serve", "--node-id", "cnode", "--endpoint", "127.0.0.1:0",
            "--endpoint-file", epFile.path,
        ], log: dir.appendingPathComponent("cnode.log"))
        defer { serve.terminate(); serve.waitUntilExit() }
        let cEP = try TestSupport.waitForFile(epFile)

        let swiftNode = try Peer(nodeID: "swiftnode", bindEndpoint: "127.0.0.1:0", authToken: TestSupport.token)
        defer { try? swiftNode.close() }
        let swiftEP = try swiftNode.endpoint

        // the C node is healthy and answers under its own id
        try swiftNode.register("cnode", endpoint: cEP)
        try swiftNode.ping("cnode")

        // Swift -> C: UTF-8 + embedded NULs, verified by `polycall peer recv`
        let toC: [UInt8] = Array("h\u{e9}llo from swift \u{1F30D}".utf8) + [0, 1, 2, 0, 255]
        try swiftNode.send(to: "cnode", payload: toC, messageID: "s2c-1")
        let recv = try TestSupport.run(cli, ["peer", "recv", "--to", cEP, "-t", "3000"])
        XCTAssertEqual(recv.status, 0, recv.stderr)
        let json = try XCTUnwrap(TestSupport.jsonObject(recv.text), recv.text)
        XCTAssertEqual(json["from"] as? String, "swiftnode")
        XCTAssertEqual(json["id"] as? String, "s2c-1")
        let b64 = try XCTUnwrap(json["payload_b64"] as? String)
        XCTAssertEqual(Data(base64Encoded: b64).map { [UInt8]($0) }, toC)

        // C -> Swift: binary file through `polycall peer send`
        let toSwift: [UInt8] = (0..<300).map { UInt8($0 % 256) }
        let payloadFile = dir.appendingPathComponent("c2s.bin")
        try Data(toSwift).write(to: payloadFile)
        let send = try TestSupport.run(cli, [
            "peer", "send", "--from", "cnode", "--to", swiftEP, "--id", "c2s-1",
            "--payload-file", payloadFile.path,
        ])
        XCTAssertEqual(send.status, 0, send.stderr)
        let message = try swiftNode.recv(timeoutMs: 3000)
        XCTAssertEqual(message.sender, "cnode")
        XCTAssertEqual(message.messageID, "c2s-1")
        XCTAssertEqual(message.payload, toSwift)

        // C -> Swift text payload
        let text = "\u{4e16}\u{754c} from C"
        let send2 = try TestSupport.run(cli, [
            "peer", "send", "--from", "cnode", "--to", swiftEP, "--id", "c2s-2", "--payload", text,
        ])
        XCTAssertEqual(send2.status, 0, send2.stderr)
        let message2 = try swiftNode.recv(timeoutMs: 3000)
        XCTAssertEqual(message2.text, text)
        XCTAssertEqual(message2.messageID, "c2s-2")

        // a CLI sender with the wrong token is rejected by the Swift node
        var env = TestSupport.environment()
        env["POLYCALL_DEV_TOKEN"] = "wrong-token"
        let denied = try TestSupport.run(cli, [
            "peer", "send", "--from", "mallory", "--to", swiftEP, "--payload", "x",
        ], environment: env)
        XCTAssertEqual(denied.status, 7, "CLI exit 7 = authentication rejected: \(denied.stderr)")
        assertPolycallError(.timeout) { try swiftNode.recv(timeoutMs: 200) }
    }

    func testCLIConcurrentSendersToSwiftPeer() throws {
        let cli = try TestSupport.requireCLI()
        let node = try Peer(nodeID: "swift-sink", bindEndpoint: "127.0.0.1:0", authToken: TestSupport.token)
        defer { try? node.close() }
        let ep = try node.endpoint
        let count = 12
        let processes = try (0..<count).map { i -> Process in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = ["peer", "send", "--from", "csender\(i)", "--to", ep, "--id", "cc-\(i)", "--payload", "n\(i)"]
            p.environment = TestSupport.environment()
            try p.run()
            return p
        }
        for p in processes { p.waitUntilExit(); XCTAssertEqual(p.terminationStatus, 0) }
        var got: [String: String] = [:]
        for _ in 0..<count {
            let m = try node.recv(timeoutMs: 5000)
            got[m.messageID] = "\(m.sender):\(m.text ?? "")"
        }
        for i in 0..<count { XCTAssertEqual(got["cc-\(i)"], "csender\(i):n\(i)") }
    }
}
