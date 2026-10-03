import XCTest
@testable import Polycall

/// Library / version / error-vocabulary checks against the real libpolycall.
final class LibraryTests: XCTestCase {
    func testABIVersionIsOneAndCheckPasses() throws {
        XCTAssertEqual(Polycall.abiVersion, 1)
        XCTAssertEqual(Polycall.requiredABIVersion, 1)
        try Polycall.checkABI()
    }

    func testLibraryVersionString() {
        let version = Polycall.version
        XCTAssertEqual(version, "1.1.0", "core 58bae1b reports 1.1.0")
        XCTAssertFalse(version.isEmpty)
    }

    func testLibraryPathNamesLibpolycall() throws {
        let path = try XCTUnwrap(Polycall.libraryPath)
        XCTAssertTrue(path.contains("libpolycall"), path)
    }

    func testStatusNamesForEveryCode() {
        for status in PolycallStatus.allCases {
            let name = Polycall.statusName(status.rawValue)
            XCTAssertTrue(name.hasPrefix("POLYCALL_"), "\(status): \(name)")
        }
        XCTAssertTrue(Polycall.statusName(-12).hasPrefix("POLYCALL_E_CANCELLED"))
        XCTAssertTrue(Polycall.statusName(-999).contains("UNKNOWN"))
        XCTAssertNil(PolycallStatus(rawValue: -999))
    }

    func testErrorCarriesStatusNameAndDetail() throws {
        let error = assertPolycallError(.notFound) {
            try Polycall.runConfig("/nonexistent-dir/swift-polycallrc")
        }
        let e = try XCTUnwrap(error)
        XCTAssertEqual(e.status, -7)
        XCTAssertTrue(e.name.hasPrefix("POLYCALL_E_NOT_FOUND"), e.name)
        XCTAssertFalse(e.detail.isEmpty, "detail comes from polycall_last_error")
        XCTAssertTrue(e.description.contains("POLYCALL_E_NOT_FOUND"))
        XCTAssertTrue(e.description.contains(e.detail))
    }

    func testLastErrorIsPerThreadAndClearedBySuccess() throws {
        _ = try? Polycall.runConfig("/nonexistent-dir/swift-polycallrc")
        XCTAssertFalse(Polycall.lastErrorDetail().isEmpty)
        // another thread has its own, untouched detail
        let other = Locked<String>("unset")
        let done = DispatchSemaphore(value: 0)
        Thread { other.mutate { $0 = Polycall.lastErrorDetail() }; done.signal() }.start()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(other.value, "")
        // a later successful call on this thread clears it
        XCTAssertEqual(Polycall.abiVersion, 1)
        let dir = TestSupport.tempDir("lasterr")
        let rc = dir.appendingPathComponent("ok-polycallrc")
        try TestSupport.write("log_level=info\n", to: rc)
        try Polycall.runConfig(rc.path)
        XCTAssertEqual(Polycall.lastErrorDetail(), "")
    }

    func testNulInStringArgumentIsRefusedNotTruncated() {
        let error = assertPolycallError(.invalidArgument) {
            try Polycall.runConfig("swift-polycallrc\u{0}ignored")
        }
        XCTAssertTrue(error?.detail.contains("NUL") ?? false)
    }
}
