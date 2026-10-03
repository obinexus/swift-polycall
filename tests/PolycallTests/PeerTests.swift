import XCTest
@testable import Polycall

/// Two real peer nodes in this process (each with its own registry/inbox).
final class PeerTests: XCTestCase {
    var alpha: Peer!
    var beta: Peer!
    var alphaEP = ""
    var betaEP = ""

    override func setUpWithError() throws {
        alpha = try Peer(nodeID: "alpha", bindEndpoint: "127.0.0.1:0", authToken: TestSupport.token)
        beta = try Peer(nodeID: "beta", bindEndpoint: "127.0.0.1:0", authToken: TestSupport.token)
        alphaEP = try alpha.endpoint
        betaEP = try beta.endpoint
        try alpha.register("beta", endpoint: betaEP)
        try beta.register("alpha", endpoint: alphaEP)
    }

    override func tearDownWithError() throws {
        if let alpha, !alpha.isClosed { try alpha.close() }
        if let beta, !beta.isClosed { try beta.close() }
        // XCTest keeps test-case instances alive; drop the peers so they deinit now
        alpha = nil
        beta = nil
    }

    func expectMessage(_ peer: Peer, from: String, id: String, _ payload: [UInt8],
                       file: StaticString = #filePath, line: UInt = #line) throws {
        let message = try peer.recv(timeoutMs: 5000)
        XCTAssertEqual(message.sender, from, file: file, line: line)
        XCTAssertEqual(message.messageID, id, file: file, line: line)
        XCTAssertEqual(message.payload.count, payload.count, file: file, line: line)
        XCTAssertTrue(message.payload == payload, "payload bytes differ", file: file, line: line)
    }

    // MARK: open / handles

    func testOpenArgumentValidation() {
        assertPolycallError(.invalidArgument) { try Peer(nodeID: "") }
        assertPolycallError(.invalidArgument) { try Peer(nodeID: "bad id") }
        assertPolycallError(.invalidArgument) { try Peer(nodeID: String(repeating: "a", count: 64), bindEndpoint: nil) }
        XCTAssertNoThrow(try Peer(nodeID: String(repeating: "a", count: 63), bindEndpoint: nil).close())
        assertPolycallError(.invalidArgument) { try Peer(nodeID: "x", bindEndpoint: "nohostport") }
        assertPolycallError(.config, "non-loopback bind without a token") { try Peer(nodeID: "x", bindEndpoint: "0.0.0.0:0") }
    }

    func testEndpointNodeIDAndSendOnlyNode() throws {
        XCTAssertTrue(alphaEP.hasPrefix("127.0.0.1:"), alphaEP)
        XCTAssertGreaterThan(Int(alphaEP.split(separator: ":").last ?? "") ?? 0, 0)
        XCTAssertNotEqual(alpha.handle, beta.handle)
        XCTAssertGreaterThan(alpha.handle, 0)
        XCTAssertEqual(try beta.nodeID, "beta")
        let sendOnly = try Peer(nodeID: "sender-only", bindEndpoint: nil, authToken: TestSupport.token)
        defer { try? sendOnly.close() }
        XCTAssertEqual(try sendOnly.endpoint, "")
        try sendOnly.send(to: betaEP, text: "from a send-only node", messageID: "so-1")
        try expectMessage(beta, from: "sender-only", id: "so-1", Array("from a send-only node".utf8))
    }

    func testAddressInUse() {
        assertPolycallError(.addressInUse) { try Peer(nodeID: "dup", bindEndpoint: alphaEP) }
    }

    func testDoubleCloseAndCallsAfterClose() throws {
        let node = try Peer(nodeID: "short-lived", bindEndpoint: "127.0.0.1:0", authToken: TestSupport.token)
        try node.close()
        XCTAssertTrue(node.isClosed)
        assertPolycallError(.invalidHandle, "double close") { try node.close() }
        assertPolycallError(.invalidHandle) { try node.endpoint }
        assertPolycallError(.invalidHandle) { try node.nodeID }
        assertPolycallError(.invalidHandle) { try node.send(to: betaEP, text: "x") }
        assertPolycallError(.invalidHandle) { try node.recv(timeoutMs: 0) }
        assertPolycallError(.invalidHandle) { try node.register("p", endpoint: betaEP) }
        assertPolycallError(.invalidHandle) { try node.listJSON() }
        assertPolycallError(.invalidHandle) { try node.health() }
        assertPolycallError(.invalidHandle) { try node.cancel() }
        assertPolycallError(.invalidHandle) { try node.ping(betaEP) }
    }

    func testInvalidHandleValues() {
        for raw: Int32 in [0, -1, Int32.max, alpha.handle &+ 1_000_000] {
            let fake = Peer(unownedHandle: raw)
            assertPolycallError(.invalidHandle, "handle \(raw)") { try fake.endpoint }
            assertPolycallError(.invalidHandle, "handle \(raw)") { try fake.close() }
        }
    }

    // MARK: registry

    func testRegistryOwnershipIsPerNode() throws {
        let gamma = try Peer(nodeID: "gamma", bindEndpoint: "127.0.0.1:0", authToken: TestSupport.token)
        defer { try? gamma.close() }
        XCTAssertEqual(try gamma.list(), [:], "a new node starts with an empty registry")
        XCTAssertEqual(try alpha.list(), ["beta": betaEP])
        try alpha.send(to: try gamma.endpoint, text: "hi", messageID: "own-1")
        _ = try gamma.recv(timeoutMs: 3000)
        XCTAssertEqual(try gamma.list(), [:], "receiving never registers the sender")
        try alpha.register("gamma", endpoint: try gamma.endpoint)
        XCTAssertEqual(try alpha.list().count, 2)
        XCTAssertEqual(try beta.list(), ["alpha": alphaEP], "other node unchanged")
        try alpha.unregister("gamma")
        assertPolycallError(.notFound) { try alpha.unregister("gamma") }
        assertPolycallError(.invalidArgument) { try alpha.register("bad id", endpoint: betaEP) }
        assertPolycallError(.invalidArgument) { try alpha.register("x", endpoint: "127.0.0.1:0") }
        XCTAssertTrue(try alpha.listJSON().contains("\"beta\""))
    }

    // MARK: ping / health

    func testPingAndIdentity() throws {
        try alpha.ping("beta")
        try alpha.ping(betaEP)
        try alpha.register("impostor", endpoint: betaEP)
        assertPolycallError(.protocolError, "beta answering as impostor") { try alpha.ping("impostor") }
        try alpha.unregister("impostor")
        assertPolycallError(.notFound) { try alpha.ping("nobody", timeoutMs: 500) }
        assertPolycallError(.transport) { try alpha.ping("127.0.0.1:1", timeoutMs: 1000) }
    }

    func testHealthJSON() throws {
        let json = try XCTUnwrap(TestSupport.jsonObject(try beta.health()))
        XCTAssertEqual(json["node_id"] as? String, "beta")
        XCTAssertEqual(json["status"] as? String, "ok")
    }

    // MARK: payloads

    func testPayloadsBothDirections() throws {
        try alpha.send(to: "beta", text: "hello beta", messageID: "a2b-1")
        try expectMessage(beta, from: "alpha", id: "a2b-1", Array("hello beta".utf8))
        try beta.send(to: "alpha", text: "hello alpha", messageID: "b2a-1")
        try expectMessage(alpha, from: "beta", id: "b2a-1", Array("hello alpha".utf8))
    }

    func testEmptyUTF8AndBinaryPayloads() throws {
        try alpha.send(to: "beta", payload: [], messageID: "empty-1")
        try expectMessage(beta, from: "alpha", id: "empty-1", [])
        let text = "h\u{e9}llo \u{2014} \u{4e16}\u{754c} \u{1F30D}"
        try alpha.send(to: "beta", text: text, messageID: "utf8-1")
        let m = try beta.recv(timeoutMs: 3000)
        XCTAssertEqual(m.text, text)
        XCTAssertEqual(m.payload, Array(text.utf8))
        let binary = (0..<256).map { UInt8($0) } + [0, 0, 255, 0]
        try alpha.send(to: "beta", payload: binary, messageID: "bin-1")
        try expectMessage(beta, from: "alpha", id: "bin-1", binary)
        try alpha.send(to: "beta", data: Data([0, 1, 0, 2]), messageID: "data-1")
        try expectMessage(beta, from: "alpha", id: "data-1", [0, 1, 0, 2])
    }

    func testMaximumPayloadAndOneByteOver() throws {
        let max = (0..<Polycall.maxPayload).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
        try alpha.send(to: "beta", payload: max, messageID: "max-1", timeoutMs: 15000)
        try expectMessage(beta, from: "alpha", id: "max-1", max)
        assertPolycallError(.tooLarge, "1 MiB + 1") {
            try alpha.send(to: "beta", payload: max + [1], messageID: "over-1")
        }
        assertPolycallError(.timeout, "nothing was sent for the oversized payload") { try beta.recv(timeoutMs: 300) }
    }

    func testTooSmallBufferLeavesMessageQueued() throws {
        try alpha.send(to: "beta", text: "0123456789", messageID: "size-1")
        let error = assertPolycallError(.tooLarge) { try beta.recv(timeoutMs: 3000, capacity: 4) }
        XCTAssertEqual(error?.requiredSize, 10)
        assertPolycallError(.tooLarge) { try beta.recv(timeoutMs: 3000, capacity: 0) }
        try expectMessage(beta, from: "alpha", id: "size-1", Array("0123456789".utf8))
    }

    func testReceiveTimeoutAndPoll() throws {
        let start = Date()
        assertPolycallError(.timeout) { try beta.recv(timeoutMs: 150) }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, 0.1)
        XCTAssertLessThan(elapsed, 3)
        assertPolycallError(.timeout) { try beta.recv(timeoutMs: 0) }
    }

    func testDuplicateMessageIDDeliveredOnce() throws {
        try alpha.send(to: "beta", text: "once", messageID: "dup-1")
        try alpha.send(to: "beta", text: "once", messageID: "dup-1")
        try expectMessage(beta, from: "alpha", id: "dup-1", Array("once".utf8))
        assertPolycallError(.timeout, "no second copy") { try beta.recv(timeoutMs: 300) }
    }

    func testGeneratedMessageID() throws {
        try alpha.send(to: "beta", text: "auto")
        let m = try beta.recv(timeoutMs: 3000)
        XCTAssertFalse(m.messageID.isEmpty)
        XCTAssertEqual(m.text, "auto")
    }

    func testInvalidMessageID() {
        assertPolycallError(.invalidArgument) { try alpha.send(to: "beta", text: "x", messageID: "bad id!") }
    }

    // MARK: failures are reported

    func testSendToDeadPeerIsTransport() throws {
        let doomed = try Peer(nodeID: "doomed", bindEndpoint: "127.0.0.1:0", authToken: TestSupport.token)
        let ep = try doomed.endpoint
        try doomed.close()
        assertPolycallError(.transport) { try alpha.send(to: ep, text: "into the void", timeoutMs: 2000) }
        assertPolycallError(.transport) { try alpha.send(to: "127.0.0.1:1", text: "x", timeoutMs: 1000) }
    }

    func testSendToUnregisteredIDIsNotFound() {
        assertPolycallError(.notFound) { try alpha.send(to: "unknown-peer", text: "x", timeoutMs: 1000) }
    }

    func testAuthFailures() throws {
        let noToken = try Peer(nodeID: "carol", bindEndpoint: nil)
        defer { try? noToken.close() }
        assertPolycallError(.auth, "no token") { try noToken.send(to: betaEP, text: "x", timeoutMs: 2000) }
        let wrong = try Peer(nodeID: "mallory", bindEndpoint: nil, authToken: "not-the-token")
        defer { try? wrong.close() }
        assertPolycallError(.auth, "wrong token") { try wrong.send(to: betaEP, text: "x", timeoutMs: 2000) }
        assertPolycallError(.timeout, "rejected messages are not queued") { try beta.recv(timeoutMs: 200) }
    }

    // MARK: concurrency

    func testBackpressureInboxFullIsBusy() throws {
        var accepted = 0
        var busy: PolycallError?
        for i in 0..<300 {
            do {
                try alpha.send(to: "beta", text: "f", messageID: "flood-\(i)", timeoutMs: 2000)
                accepted += 1
            } catch let error as PolycallError {
                busy = error
                break
            }
        }
        XCTAssertEqual(accepted, 256, "the inbox holds 256 messages")
        XCTAssertEqual(busy?.code, .busy, "\(String(describing: busy))")
        for _ in 0..<accepted { _ = try beta.recv(timeoutMs: 2000) }
        try alpha.send(to: "beta", text: "after", messageID: "after-drain")
        try expectMessage(beta, from: "alpha", id: "after-drain", Array("after".utf8))
    }

    func testConcurrentSenders() throws {
        // 8 x 30 = 240 messages: below the 256-message inbox, so every send must succeed
        let threads = 8, perThread = 30
        let failures = Locked<[String]>([])
        let sender: Peer = alpha
        DispatchQueue.concurrentPerform(iterations: threads) { t in
            for i in 0..<perThread {
                do {
                    try sender.send(to: "beta", text: "payload \(t)/\(i)", messageID: "t\(t)-m\(i)")
                } catch {
                    failures.mutate { $0.append("t\(t)-m\(i): \(error)") }
                }
            }
        }
        XCTAssertEqual(failures.value, [])
        var seen: [String: String] = [:]
        for _ in 0..<(threads * perThread) {
            let m = try beta.recv(timeoutMs: 5000)
            XCTAssertEqual(m.sender, "alpha")
            seen[m.messageID] = m.text
        }
        XCTAssertEqual(seen.count, threads * perThread)
        for t in 0..<threads { for i in 0..<perThread {
            XCTAssertEqual(seen["t\(t)-m\(i)"], "payload \(t)/\(i)")
        } }
        assertPolycallError(.timeout) { try beta.recv(timeoutMs: 200) }
    }
}
