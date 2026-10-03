import CPolycall
import Foundation

/// Library-level entry points of the Polycall binding ABI v1.
///
/// Every call goes straight to the C function of the same name in
/// `libpolycall` (linked through `pkg-config polycall`). Nothing here parses
/// configuration or talks to the network itself.
public enum Polycall {
    /// The binding ABI this package was written for (`POLYCALL_FFI_ABI_VERSION`).
    public static let requiredABIVersion: Int32 = 1
    /// `POLYCALL_PEER_MAX_PAYLOAD`: largest payload `Peer.send` accepts (1 MiB).
    public static let maxPayload = 1 << 20
    /// `POLYCALL_CALL_MAX_OUTPUT`: largest output `call` can return (1 MiB).
    public static let maxCallOutput = 1 << 20
    /// `POLYCALL_PEER_ID_MAX` / `POLYCALL_MESSAGE_ID_MAX` (buffer sizes incl. NUL).
    public static let peerIDBufferSize = 64
    public static let messageIDBufferSize = 64
    /// `POLYCALL_ENDPOINT_MAX` ("host:port" incl. NUL).
    public static let endpointBufferSize = 128
    /// `UINT32_MAX`: wait until a message, `cancel()` or `close()`.
    public static let waitForever: UInt32 = .max

    // MARK: library / version

    /// `polycall_ffi_abi_version()` of the loaded library (unchecked).
    public static var abiVersion: Int32 { polycall_ffi_abi_version() }

    /// `polycall_ffi_version()`, e.g. "1.1.0".
    public static var version: String {
        var cap: Int32 = 64
        var buf = [CChar](repeating: 0, count: Int(cap))
        let n = polycall_ffi_version(&buf, cap)
        if n >= cap {
            cap = n + 1
            buf = [CChar](repeating: 0, count: Int(cap))
            _ = polycall_ffi_version(&buf, cap)
        }
        return decodeCString(buf)
    }

    /// File the dynamic loader resolved libpolycall from, when the platform can tell.
    public static var libraryPath: String? {
        let fn: @convention(c) () -> Int32 = polycall_ffi_abi_version
        let address = UInt(bitPattern: unsafeBitCast(fn, to: UnsafeRawPointer.self))
        #if os(Linux)
        // Glibc hides dladdr() behind _GNU_SOURCE, so find the mapping that
        // contains the function in /proc/self/maps instead.
        // (procfs reports size 0: read to EOF, String(contentsOfFile:) truncates)
        guard let handle = FileHandle(forReadingAtPath: "/proc/self/maps") else { return nil }
        defer { try? handle.close() }
        let maps = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        for line in maps.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 6 else { continue }
            let range = fields[0].split(separator: "-")
            guard range.count == 2, let lo = UInt(range[0], radix: 16), let hi = UInt(range[1], radix: 16),
                  address >= lo, address < hi else { continue }
            return fields[5...].joined(separator: " ")
        }
        return nil
        #elseif canImport(Darwin)
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0,
              let name = info.dli_fname else { return nil }
        return String(cString: name)
        #else
        _ = address
        return nil
        #endif
    }

    private static let abiCheck: Result<Int32, PolycallError> = {
        let found = polycall_ffi_abi_version()
        if found == requiredABIVersion { return .success(found) }
        let where_ = libraryPath ?? "libpolycall"
        // The name is fixed here: an incompatible library's own strerror is not trusted.
        return .failure(PolycallError(
            status: PolycallStatus.unsupported.rawValue,
            name: "POLYCALL_E_UNSUPPORTED: binding ABI mismatch",
            detail: "\(where_) implements binding ABI \(found) (library version \(version)); "
                + "swift-polycall requires binding ABI \(requiredABIVersion)"))
    }()

    /// Throws unless the loaded library implements binding ABI v1. Every other
    /// API in this package performs this check before calling the core.
    public static func checkABI() throws {
        _ = try abiCheck.get()
    }

    /// `polycall_strerror(status)`: static name of any status code.
    public static func statusName(_ status: Int32) -> String {
        String(cString: polycall_strerror(status))
    }

    /// `polycall_last_error()`: this thread's detail for its most recent failure.
    public static func lastErrorDetail() -> String {
        var cap = 512
        var buf = [CChar](repeating: 0, count: cap)
        let n = Int(polycall_last_error(&buf, cap))
        if n >= cap {
            cap = n + 1
            buf = [CChar](repeating: 0, count: cap)
            _ = polycall_last_error(&buf, cap)
        }
        return decodeCString(buf)
    }

    // MARK: configuration

    /// The documented entry point: `polycall_ffi_run_config(path, 1)`, i.e.
    /// validate `path` for running with this build (strict).
    public static func runConfig(_ path: String) throws {
        try runConfig(path, strict: true)
    }

    /// `polycall_ffi_run_config(path, strict ? 1 : 0)`. Lenient mode reports
    /// unknown keys as warnings; strict mode rejects them and rejects settings
    /// this build cannot honour (`tls_enabled=true` -> `.unsupported`).
    public static func runConfig(_ path: String, strict: Bool) throws {
        try check(runConfigStatus(path, strict: strict))
    }

    /// Raw status of `polycall_ffi_run_config` (0 or a negative `POLYCALL_E_*`).
    /// The detail of a failure is in `lastErrorDetail()` on the same thread.
    public static func runConfigStatus(_ path: String, strict: Bool = true) throws -> Int32 {
        try checkABI()
        return try withCStringArgument(path, "config path") {
            polycall_ffi_run_config($0, strict ? 1 : 0)
        }
    }

    /// `polycall_ffi_describe(path)`: JSON description of a configuration file
    /// (layer, servers, peers, key/values; secrets are never resolved).
    public static func describe(_ path: String) throws -> String {
        try checkABI()
        return try withCStringArgument(path, "config path") { cpath -> String in
            var cap = 4096
            for _ in 0..<4 {
                var buf = [CChar](repeating: 0, count: cap)
                let n = polycall_ffi_describe(cpath, &buf, Int32(cap))
                if n < 0 { throw PolycallError.capture(n) }
                if Int(n) < cap { return decodeCString(buf) }
                cap = Int(n) + 1
            }
            throw PolycallError.binding(.internalError, "describe output kept growing")
        }
    }

    // MARK: RPC

    /// One `polycall_rpc` v1 round trip (`polycall_call`) to a running runtime
    /// or daemon. Executes once and is never retried. Returns the operation's
    /// output JSON. On failure the thrown `PolycallError.output` holds the
    /// remote error object (`{"code":..,"message":..}`) when the core supplied one.
    ///
    /// - Parameters:
    ///   - input: input JSON (`nil` sends `null`); invalid JSON -> `.invalidArgument`.
    ///   - timeoutMs: 1...600000.
    ///   - outputCapacity: output buffer size; a too-small buffer discards a result
    ///     that already ran (`.tooLarge`, `requiredSize` = bytes needed).
    public static func call(endpoint: String, service: String, operation: String,
                            input: String? = nil, timeoutMs: UInt32 = 5000,
                            outputCapacity: Int = maxCallOutput + 1) throws -> String {
        try checkABI()
        guard outputCapacity >= 0 else {
            throw PolycallError.binding(.invalidArgument, "outputCapacity must not be negative")
        }
        var out = [CChar](repeating: 0, count: max(outputCapacity, 1))
        var outLen = 0
        let status: Int32 = try withCStringArgument(endpoint, "endpoint") { ep in
            try withCStringArgument(service, "service") { sv in
                try withCStringArgument(operation, "operation") { op in
                    try withOptionalCStringArgument(input, "input JSON") { inp in
                        out.withUnsafeMutableBufferPointer { buf in
                            polycall_call(ep, sv, op, inp, timeoutMs,
                                          outputCapacity == 0 ? nil : buf.baseAddress,
                                          outputCapacity, &outLen)
                        }
                    }
                }
            }
        }
        if status == POLYCALL_OK {
            return decodeCString(out)
        }
        let errorObject: String? = (outputCapacity > 0 && out[0] != 0) ? decodeCString(out) : nil
        throw PolycallError.capture(status, output: errorObject,
                                    requiredSize: status == POLYCALL_E_TOO_LARGE ? outLen : nil)
    }
}

// MARK: - argument marshalling

/// Pass `value` as a NUL-terminated UTF-8 string. A Swift string containing a
/// NUL byte cannot cross the C ABI unchanged, so it is refused instead of
/// being silently truncated.
@inline(__always)
func withCStringArgument<R>(_ value: String, _ what: String,
                            _ body: (UnsafePointer<CChar>) throws -> R) throws -> R {
    if value.utf8.contains(0) {
        throw PolycallError.binding(.invalidArgument, "\(what) contains a NUL byte")
    }
    return try value.withCString(body)
}

@inline(__always)
func withOptionalCStringArgument<R>(_ value: String?, _ what: String,
                                    _ body: (UnsafePointer<CChar>?) throws -> R) throws -> R {
    guard let value else { return try body(nil) }
    return try withCStringArgument(value, what) { try body($0) }
}

/// Fetch a text output that follows the ABI's snprintf rules with an
/// `out_len` (list, health): grow the buffer when the core reports
/// `POLYCALL_E_TOO_LARGE` with the size it needs.
func fetchText(_ fill: (UnsafeMutablePointer<CChar>, Int, UnsafeMutablePointer<Int>) -> Int32) throws -> String {
    var cap = 4096
    for _ in 0..<6 {
        var buf = [CChar](repeating: 0, count: cap)
        var needed = 0
        let status = buf.withUnsafeMutableBufferPointer { fill($0.baseAddress!, cap, &needed) }
        if status == POLYCALL_OK { return decodeCString(buf) }
        if status != POLYCALL_E_TOO_LARGE { throw PolycallError.capture(status) }
        cap = max(cap * 2, needed + 1)
    }
    throw PolycallError.binding(.internalError, "output kept growing")
}

/// Decode a NUL-terminated UTF-8 buffer filled by the core (invalid UTF-8 is
/// repaired with U+FFFD rather than dropped).
@inline(__always)
func decodeCString(_ buffer: [CChar]) -> String {
    let end = buffer.firstIndex(of: 0) ?? buffer.count
    return String(decoding: buffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
}
