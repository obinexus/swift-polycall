// polycall-swift -- small command-line example of the swift-polycall API.
//
//   polycall-swift version
//   polycall-swift run-config <path> [--lenient]
//   polycall-swift describe <path>
//   polycall-swift call <endpoint> <service> <operation> [input-json] [timeout-ms]
//   polycall-swift selftest [iterations]
//
// Exit status: 0 success, 1 Polycall error (status, name and detail on
// stderr), 2 usage error.
import Foundation
import Polycall

func fail(_ error: PolycallError) -> Never {
    FileHandle.standardError.write(Data("polycall-swift: \(error)\n".utf8))
    exit(1)
}

func usage() -> Never {
    FileHandle.standardError.write(Data("""
        usage: polycall-swift version
               polycall-swift run-config <path> [--lenient]
               polycall-swift describe <path>
               polycall-swift call <endpoint> <service> <operation> [input-json] [timeout-ms]
               polycall-swift selftest [iterations]

        """.utf8))
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }

do {
    switch command {
    case "version":
        try Polycall.checkABI()
        print("libpolycall \(Polycall.version) (binding ABI \(Polycall.abiVersion)) from \(Polycall.libraryPath ?? "?")")
    case "run-config":
        guard args.count >= 2 else { usage() }
        let strict = !args.dropFirst(2).contains("--lenient")
        try Polycall.runConfig(args[1], strict: strict)
        print("\(args[1]): valid (\(strict ? "strict" : "lenient"))")
    case "describe":
        guard args.count == 2 else { usage() }
        print(try Polycall.describe(args[1]))
    case "selftest":
        // Exercise the whole peer lifecycle N times in one process (used by the
        // leak check under AddressSanitizer/LeakSanitizer).
        let iterations = args.count >= 2 ? Int(args[1]) ?? 50 : 50
        for i in 0..<iterations {
            let a = try Peer(nodeID: "self-a", bindEndpoint: "127.0.0.1:0", authToken: "selftest")
            let b = try Peer(nodeID: "self-b", bindEndpoint: "127.0.0.1:0", authToken: "selftest")
            try a.register("self-b", endpoint: try b.endpoint)
            try a.ping("self-b")
            let payload = (0..<4096).map { UInt8(truncatingIfNeeded: $0 &+ i) }
            try a.send(to: "self-b", payload: payload, messageID: "m-\(i)")
            let m = try b.recv(timeoutMs: 3000)
            guard m.payload == payload, m.sender == "self-a" else {
                throw PolycallError(status: -6, name: "selftest", detail: "payload mismatch at \(i)")
            }
            _ = try a.list()
            _ = try b.health()
            _ = try? b.recv(timeoutMs: 0)
            _ = try? b.recv(timeoutMs: 10, capacity: 1)
            _ = try? a.send(to: "127.0.0.1:1", text: "x", timeoutMs: 200)
            _ = try? Polycall.runConfig("/nonexistent/selftest-polycallrc")
            try a.close()
            _ = try? a.close()
            // b is released by deinit (never closed explicitly)
        }
        print("selftest: \(iterations) iterations OK")
    case "call":
        guard args.count >= 4 else { usage() }
        let input = args.count >= 5 ? args[4] : nil
        let timeout = args.count >= 6 ? UInt32(args[5]) ?? 5000 : 5000
        print(try Polycall.call(endpoint: args[1], service: args[2], operation: args[3],
                                input: input, timeoutMs: timeout))
    default:
        usage()
    }
} catch let error as PolycallError {
    fail(error)
} catch {
    FileHandle.standardError.write(Data("polycall-swift: \(error)\n".utf8))
    exit(1)
}
