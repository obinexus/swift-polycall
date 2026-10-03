import Foundation
import XCTest
@testable import Polycall

/// Small lock-protected box for values shared between threads in tests.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
    func mutate(_ body: (inout Value) -> Void) {
        lock.lock(); body(&stored); lock.unlock()
    }
}

/// Helpers that drive the real `polycall` CLI (daemon, peer serve, peer send/recv).
enum TestSupport {
    /// A random shared token for this test process (never a real secret).
    static let token: String = "swift-qa-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")

    /// Path of the `polycall` CLI: $POLYCALL_CLI, else the first `polycall` on PATH.
    static func cliPath() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let explicit = env["POLYCALL_CLI"], FileManager.default.isExecutableFile(atPath: explicit) {
            return explicit
        }
        for dir in (env["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(dir)/polycall"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// The CLI, or an XCTSkip (reported as skipped, never as passed).
    static func requireCLI() throws -> String {
        guard let cli = cliPath() else {
            throw XCTSkip("polycall CLI not found (set POLYCALL_CLI or PATH); this check needs the real CLI")
        }
        return cli
    }

    static func tempDir(_ tag: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-polycall-\(tag)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func environment(_ extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["POLYCALL_DEV_TOKEN"] = token
        env["POLYCALL_TELEMETRY"] = "off"
        for (k, v) in extra { env[k] = v }
        return env
    }

    struct Output {
        let status: Int32
        let stdout: Data
        let stderr: String
        var text: String { String(decoding: stdout, as: UTF8.self) }
    }

    /// Run a command to completion and capture its output.
    static func run(_ executable: String, _ arguments: [String],
                    environment env: [String: String]? = nil) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = env ?? environment()
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, stdout: stdout,
                      stderr: String(decoding: stderr, as: UTF8.self))
    }

    /// Start a long-running command (output to a log file).
    static func start(_ executable: String, _ arguments: [String], log: URL) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment()
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        return process
    }

    /// Wait for a non-empty file and return its trimmed text.
    static func waitForFile(_ url: URL, timeout: TimeInterval = 10) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            usleep(50_000)
        }
        throw PolycallError.binding(.timeout, "test harness: timed out waiting for \(url.path)")
    }

    static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    static func jsonObject(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}

/// A `polycall daemon` with a private state directory on an ephemeral port.
final class DaemonFixture: @unchecked Sendable {
    let cli: String
    let dir: URL
    let endpoint: String

    init() throws {
        cli = try TestSupport.requireCLI()
        dir = TestSupport.tempDir("daemon")
        try TestSupport.write("log_level=info\n", to: dir.appendingPathComponent("Polycallfile"))
        let result = try TestSupport.run(cli, [
            "daemon", "start", "--endpoint", "127.0.0.1:0",
            "--state-dir", dir.appendingPathComponent("state").path,
            dir.appendingPathComponent("Polycallfile").path,
        ])
        guard result.status == 0 else {
            throw PolycallError.binding(.transport, "daemon start failed (\(result.status)): \(result.text) \(result.stderr)")
        }
        let state = try String(contentsOf: dir.appendingPathComponent("state/daemon.json"), encoding: .utf8)
        guard let json = TestSupport.jsonObject(state), let ep = json["endpoint"] as? String else {
            throw PolycallError.binding(.protocolError, "daemon.json has no endpoint: \(state)")
        }
        endpoint = ep
    }

    func stop() {
        _ = try? TestSupport.run(cli, [
            "daemon", "stop", "--state-dir", dir.appendingPathComponent("state").path,
            dir.appendingPathComponent("Polycallfile").path,
        ])
        try? FileManager.default.removeItem(at: dir)
    }
}

/// Assert that `body` throws a `PolycallError` with status `code`; returns it.
@discardableResult
func assertPolycallError<T>(_ code: PolycallStatus, _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line,
                            _ body: () throws -> T) -> PolycallError? {
    do {
        _ = try body()
        XCTFail("expected \(code) but the call succeeded. \(message)", file: file, line: line)
        return nil
    } catch let error as PolycallError {
        XCTAssertEqual(error.code, code, "\(message) -- got \(error)", file: file, line: line)
        XCTAssertEqual(error.status, code.rawValue, file: file, line: line)
        XCTAssertEqual(error.name, Polycall.statusName(code.rawValue), file: file, line: line)
        return error
    } catch {
        XCTFail("expected PolycallError(\(code)), got \(error). \(message)", file: file, line: line)
        return nil
    }
}
