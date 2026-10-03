import XCTest
@testable import Polycall

/// Blocking receive, cancellation and close, from threads and Swift concurrency.
final class ConcurrencyTests: XCTestCase {
    func openPair() throws -> (Peer, Peer, String) {
        let a = try Peer(nodeID: "conc-a", bindEndpoint: "127.0.0.1:0", authToken: TestSupport.token)
        let b = try Peer(nodeID: "conc-b", bindEndpoint: "127.0.0.1:0", authToken: TestSupport.token)
        return (a, b, try b.endpoint)
    }

    /// Run a blocking `recv` on a plain thread; returns (semaphore, result box).
    func blockedReceive(_ peer: Peer) -> (DispatchSemaphore, Locked<Result<PeerMessage, Error>?>) {
        let done = DispatchSemaphore(value: 0)
        let result = Locked<Result<PeerMessage, Error>?>(nil)
        Thread {
            let r = Result { try peer.recv(timeoutMs: Polycall.waitForever) }
            result.mutate { $0 = r }
            done.signal()
        }.start()
        return (done, result)
    }

    func statusOf(_ result: Result<PeerMessage, Error>?) -> PolycallStatus? {
        guard case .failure(let error)? = result else { return nil }
        return (error as? PolycallError)?.code
    }

    func testCancelWakesBlockedThreadReceive() throws {
        let (a, b, _) = try openPair()
        defer { try? a.close(); try? b.close() }
        let (done, result) = blockedReceive(b)
        usleep(300_000)
        XCTAssertEqual(done.wait(timeout: .now()), .timedOut, "receive is blocked")
        try b.cancel()
        XCTAssertEqual(done.wait(timeout: .now() + 3), .success, "cancel woke the receive")
        XCTAssertEqual(statusOf(result.value), .cancelled)
        assertPolycallError(.timeout, "later receives wait normally") { try b.recv(timeoutMs: 100) }
    }

    func testCloseWakesBlockedThreadReceive() throws {
        let (a, b, _) = try openPair()
        defer { try? a.close() }
        let (done, result) = blockedReceive(b)
        usleep(300_000)
        let start = Date()
        try b.close()
        XCTAssertEqual(done.wait(timeout: .now() + 3), .success, "close woke the receive")
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertEqual(statusOf(result.value), .closed)
    }

    func testBlockedReceiveGetsMessageFromAnotherThread() throws {
        let (a, b, bEP) = try openPair()
        defer { try? a.close(); try? b.close() }
        let (done, result) = blockedReceive(b)
        usleep(200_000)
        try a.send(to: bEP, text: "wake up", messageID: "wake-1")
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        let message = try XCTUnwrap(result.value).get()
        XCTAssertEqual(message.messageID, "wake-1")
        XCTAssertEqual(message.sender, "conc-a")
    }

    func testAsyncReceiveTaskCancellation() async throws {
        let (a, b, _) = try openPair()
        defer { try? a.close(); try? b.close() }
        let task = Task { try await b.receive() }
        try await Task.sleep(nanoseconds: 300_000_000)
        let start = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let error as PolycallError {
            XCTAssertEqual(error.code, .cancelled, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testAsyncReceivePeerCancelAndClose() async throws {
        let (a, b, _) = try openPair()
        defer { try? a.close() }
        let first = Task { try await b.receive() }
        try await Task.sleep(nanoseconds: 300_000_000)
        try b.cancel()
        do { _ = try await first.value; XCTFail("expected .cancelled") }
        catch let error as PolycallError { XCTAssertEqual(error.code, .cancelled, "\(error)") }

        let second = Task { try await b.receive() }
        try await Task.sleep(nanoseconds: 300_000_000)
        try b.close()
        do { _ = try await second.value; XCTFail("expected .closed") }
        catch let error as PolycallError { XCTAssertEqual(error.code, .closed, "\(error)") }
    }

    func testAsyncReceiveTimeout() async throws {
        let (a, b, _) = try openPair()
        defer { try? a.close(); try? b.close() }
        let start = Date()
        do { _ = try await b.receive(timeoutMs: 450); XCTFail("expected timeout") }
        catch let error as PolycallError { XCTAssertEqual(error.code, .timeout, "\(error)") }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, 0.4)
        XCTAssertLessThan(elapsed, 3)
    }

    /// More concurrent async receives than the cooperative pool has threads:
    /// if `receive` blocked pool threads, the sender task below could never run.
    func testAsyncReceivesDoNotStarveCooperativePool() throws {
        let (a, b, bEP) = try openPair()
        defer { try? a.close(); try? b.close() }
        let count = ProcessInfo.processInfo.activeProcessorCount * 2 + 4
        let received = expectation(description: "\(count) receives completed")
        received.expectedFulfillmentCount = count
        let ids = Locked<[String]>([])
        for _ in 0..<count {
            Task.detached {
                do {
                    let m = try await b.receive(timeoutMs: 60_000)
                    ids.mutate { $0.append(m.messageID) }
                } catch {
                    XCTFail("receive failed: \(error)")
                }
                received.fulfill()
            }
        }
        let sent = expectation(description: "sender task ran on the cooperative pool")
        Task.detached {
            try? await Task.sleep(nanoseconds: 500_000_000)
            do {
                for i in 0..<count { try a.send(to: bEP, text: "m\(i)", messageID: "pool-\(i)") }
            } catch {
                XCTFail("send failed: \(error)")
            }
            sent.fulfill()
        }
        wait(for: [sent], timeout: 30)
        wait(for: [received], timeout: 30)
        XCTAssertEqual(Set(ids.value), Set((0..<count).map { "pool-\($0)" }))
    }

    func testConcurrentAsyncSendersAndReceivers() async throws {
        let (a, b, bEP) = try openPair()
        defer { try? a.close(); try? b.close() }
        let total = 64
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<total {
                group.addTask { try a.send(to: bEP, text: "g\(i)", messageID: "g-\(i)") }
            }
            try await group.waitForAll()
        }
        let messages = try await withThrowingTaskGroup(of: PeerMessage.self) { group in
            for _ in 0..<total { group.addTask { try await b.receive(timeoutMs: 10_000) } }
            var all: [PeerMessage] = []
            for try await m in group { all.append(m) }
            return all
        }
        XCTAssertEqual(Set(messages.map(\.messageID)), Set((0..<total).map { "g-\($0)" }))
        XCTAssertTrue(messages.allSatisfy { $0.text == "g" + $0.messageID.dropFirst(2) })
    }
}
