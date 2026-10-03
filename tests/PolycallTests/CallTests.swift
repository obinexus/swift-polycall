import XCTest
@testable import Polycall

/// `polycall_call` against a real `polycall daemon` (private state dir, ephemeral port).
final class CallTests: XCTestCase {
    nonisolated(unsafe) static var daemon: DaemonFixture?
    nonisolated(unsafe) static var setupError: Error?

    override class func setUp() {
        super.setUp()
        do { daemon = try DaemonFixture() } catch { setupError = error }
    }

    override class func tearDown() {
        daemon?.stop()
        daemon = nil
        super.tearDown()
    }

    func endpoint() throws -> String {
        if let error = Self.setupError, error is XCTSkip { throw error }
        if let error = Self.setupError { XCTFail("daemon did not start: \(error)"); throw error }
        return try XCTUnwrap(Self.daemon?.endpoint)
    }

    func testEchoSuccess() throws {
        let out = try Polycall.call(endpoint: endpoint(), service: "debug", operation: "echo",
                                    input: #"{"a":1,"s":"héllo"}"#)
        let json = try XCTUnwrap(TestSupport.jsonObject(out), out)
        let echo = try XCTUnwrap(json["echo"] as? [String: Any])
        XCTAssertEqual(echo["a"] as? Int, 1)
        XCTAssertEqual(echo["s"] as? String, "h\u{e9}llo")
    }

    func testNilInputIsSentAsNull() throws {
        let out = try Polycall.call(endpoint: endpoint(), service: "debug", operation: "echo")
        XCTAssertEqual(out.replacingOccurrences(of: " ", with: ""), #"{"echo":null}"#)
    }

    func testInventoryGet() throws {
        let out = try Polycall.call(endpoint: endpoint(), service: "inventory", operation: "get",
                                    input: #"{"item_id":"widget-a"}"#)
        let json = try XCTUnwrap(TestSupport.jsonObject(out), out)
        XCTAssertEqual(json["quantity"] as? Int, 42)
        XCTAssertEqual(json["in_stock"] as? Bool, true)
    }

    func testUnknownOperationIsNotFoundWithErrorObject() throws {
        let error = assertPolycallError(.notFound) {
            try Polycall.call(endpoint: endpoint(), service: "debug", operation: "nope")
        }
        let output = try XCTUnwrap(error?.output)
        XCTAssertTrue(output.contains("operation.unknown"), output)
    }

    func testRemoteOperationErrorCarriesErrorObject() throws {
        do {
            _ = try Polycall.call(endpoint: endpoint(), service: "inventory", operation: "get",
                                  input: #"{"item_id":"nope"}"#)
            XCTFail("unknown item must fail")
        } catch let error as PolycallError {
            XCTAssertTrue([PolycallStatus.remote, .notFound].contains(error.code), "\(error)")
            XCTAssertTrue(error.output?.contains("item.unknown") ?? false, "\(error)")
        }
    }

    func testDeadlineExceeded() throws {
        let start = Date()
        assertPolycallError(.timeout) {
            try Polycall.call(endpoint: endpoint(), service: "debug", operation: "sleep",
                              input: #"{"ms":3000}"#, timeoutMs: 300)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.5)
    }

    func testInvalidInputJSONIsRejectedBeforeSending() throws {
        assertPolycallError(.invalidArgument) {
            try Polycall.call(endpoint: endpoint(), service: "debug", operation: "echo", input: "{not json")
        }
    }

    func testNoRuntimeIsTransportError() {
        assertPolycallError(.transport) {
            try Polycall.call(endpoint: "127.0.0.1:1", service: "debug", operation: "echo", timeoutMs: 2000)
        }
    }

    func testTimeoutBoundaries() throws {
        let ep = try endpoint()
        assertPolycallError(.invalidArgument, "timeout 0") {
            try Polycall.call(endpoint: ep, service: "debug", operation: "echo", timeoutMs: 0)
        }
        assertPolycallError(.invalidArgument, "timeout 600001") {
            try Polycall.call(endpoint: ep, service: "debug", operation: "echo", timeoutMs: 600_001)
        }
        XCTAssertNoThrow(try Polycall.call(endpoint: ep, service: "debug", operation: "echo", timeoutMs: 1))
        XCTAssertNoThrow(try Polycall.call(endpoint: ep, service: "debug", operation: "echo", timeoutMs: 600_000))
    }

    func testTooSmallOutputBufferReportsRequiredSize() throws {
        let error = assertPolycallError(.tooLarge) {
            try Polycall.call(endpoint: endpoint(), service: "debug", operation: "echo",
                              input: #"{"k":"0123456789"}"#, outputCapacity: 4)
        }
        let needed = try XCTUnwrap(error?.requiredSize)
        XCTAssertGreaterThan(needed, 4)
        let out = try Polycall.call(endpoint: endpoint(), service: "debug", operation: "echo",
                                    input: #"{"k":"0123456789"}"#, outputCapacity: needed + 1)
        XCTAssertEqual(out.utf8.count, needed)
    }

    func testInvalidEndpoint() {
        assertPolycallError(.invalidArgument) {
            try Polycall.call(endpoint: "no-port", service: "debug", operation: "echo")
        }
    }

    func testConcurrentCalls() throws {
        let ep = try endpoint()
        let failures = Locked<[String]>([])
        DispatchQueue.concurrentPerform(iterations: 16) { i in
            do {
                let out = try Polycall.call(endpoint: ep, service: "debug", operation: "echo",
                                            input: "{\"n\":\(i)}")
                if out.replacingOccurrences(of: " ", with: "") != "{\"echo\":{\"n\":\(i)}}" {
                    failures.mutate { $0.append("call \(i): \(out)") }
                }
            } catch {
                failures.mutate { $0.append("call \(i): \(error)") }
            }
        }
        XCTAssertEqual(failures.value, [])
    }
}
