import CPolycall

/// Binding ABI v1 status codes (`POLYCALL_OK`, `POLYCALL_E_*` in polycall.h).
public enum PolycallStatus: Int32, Sendable, CaseIterable {
    case ok = 0
    case invalidArgument = -1
    case noMemory = -2
    case invalidHandle = -3
    case timeout = -4
    case transport = -5
    case protocolError = -6
    case notFound = -7
    case auth = -8
    case remote = -9
    case tooLarge = -10
    case busy = -11
    case cancelled = -12
    case config = -13
    case addressInUse = -14
    case unsupported = -15
    case permission = -16
    case closed = -17
    case internalError = -18
}

/// The error every swift-polycall API throws.
///
/// It carries exactly what the core reported for the failing call:
/// - `status`: the negative `POLYCALL_E_*` code,
/// - `name`: `polycall_strerror(status)` (e.g. `"POLYCALL_E_TIMEOUT: deadline exceeded"`),
/// - `detail`: `polycall_last_error()` read on the same thread right after the call,
/// - `output`: for `Polycall.call`, the remote error object JSON when the core supplied one,
/// - `requiredSize`: for `POLYCALL_E_TOO_LARGE`, the buffer size the core asked for.
public struct PolycallError: Error, Sendable, Equatable, CustomStringConvertible {
    public let status: Int32
    public let name: String
    public let detail: String
    public let output: String?
    public let requiredSize: Int?

    public init(status: Int32, name: String, detail: String, output: String? = nil, requiredSize: Int? = nil) {
        self.status = status
        self.name = name
        self.detail = detail
        self.output = output
        self.requiredSize = requiredSize
    }

    /// The typed status, or `nil` for a code this binding does not know.
    public var code: PolycallStatus? { PolycallStatus(rawValue: status) }

    public var description: String {
        var text = "\(name) [\(status)]"
        if !detail.isEmpty { text += ": \(detail)" }
        if let output, !output.isEmpty { text += " -- \(output)" }
        return text
    }

    /// Build the error for a failed core call. Must run on the thread that made
    /// the call, before any other Polycall call, because the detail is per thread.
    static func capture(_ status: Int32, output: String? = nil, requiredSize: Int? = nil) -> PolycallError {
        PolycallError(status: status, name: Polycall.statusName(status),
                      detail: Polycall.lastErrorDetail(), output: output, requiredSize: requiredSize)
    }

    /// An error raised by the binding itself (argument the C ABI cannot carry,
    /// ABI mismatch, ...), named with the core's own status vocabulary.
    static func binding(_ code: PolycallStatus, _ detail: String) -> PolycallError {
        PolycallError(status: code.rawValue, name: Polycall.statusName(code.rawValue), detail: detail)
    }
}

@inline(__always)
func check(_ status: Int32) throws {
    if status != POLYCALL_OK { throw PolycallError.capture(status) }
}
