import CPolycall
import Foundation

/// One message taken from a peer node's inbox.
public struct PeerMessage: Sendable, Equatable {
    /// Node id of the sender (as asserted by the sender).
    public let sender: String
    /// Message id (the sender's id, or one the core generated).
    public let messageID: String
    /// Exact payload bytes (binary-safe, may contain NULs).
    public let payload: [UInt8]

    public init(sender: String, messageID: String, payload: [UInt8]) {
        self.sender = sender
        self.messageID = messageID
        self.payload = payload
    }

    /// The payload decoded as UTF-8, or `nil` when it is not valid UTF-8.
    public var text: String? { String(validating: payload, as: UTF8.self) }
}

/// A Polycall peer node (`polycall_peer_*`, protocol polycall-peer/1).
///
/// The node's registry and inbox belong to this node only. All methods are
/// thread-safe (the core validates the integer handle on every call), so one
/// `Peer` may be shared between threads and tasks.
///
/// Lifetime: `close()` stops the listener, wakes blocked receives with
/// `.closed` and releases the handle. Calling `close()` again, or any method
/// after it, throws the core's `.invalidHandle`. A `Peer` that was never
/// closed explicitly is closed exactly once when it is deinitialised.
public final class Peer: @unchecked Sendable {
    /// The core's handle (`polycall_peer_t`, > 0).
    public let handle: Int32

    private let lock = NSLock()
    private var closedByOwner = false
    private var cancelEpoch: UInt64 = 0

    /// `polycall_peer_open`.
    /// - Parameters:
    ///   - nodeID: 1-63 bytes of `[A-Za-z0-9._-]`.
    ///   - bindEndpoint: `"host:port"` to listen on (`"127.0.0.1:0"` = ephemeral
    ///     port), or `nil` for a send-only node.
    ///   - authToken: shared secret (`nil`/empty = no authentication). A
    ///     non-loopback bind without a token is refused (`.config`).
    public init(nodeID: String, bindEndpoint: String? = "127.0.0.1:0", authToken: String? = nil) throws {
        try Polycall.checkABI()
        var h: Int32 = 0
        let status = try withCStringArgument(nodeID, "node id") { id in
            try withOptionalCStringArgument(bindEndpoint, "bind endpoint") { ep in
                try withOptionalCStringArgument(authToken, "auth token") { tok in
                    polycall_peer_open(id, ep, tok, &h)
                }
            }
        }
        try check(status)
        handle = h
    }

    /// Wrap a raw handle value WITHOUT owning it (never closed on deinit).
    /// Internal: used by the tests of the core's handle validation.
    init(unownedHandle: Int32) {
        handle = unownedHandle
        closedByOwner = true
    }

    deinit {
        if !closedByOwner {
            _ = polycall_peer_close(handle)
        }
    }

    /// `polycall_peer_close`. A second call throws `.invalidHandle` (the core's
    /// defined double-close result); the handle is released only once.
    public func close() throws {
        lock.lock()
        closedByOwner = true
        lock.unlock()
        try check(polycall_peer_close(handle))
    }

    /// Whether `close()` has been called on this object.
    public var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closedByOwner
    }

    /// `polycall_peer_endpoint`: bound `"host:port"` (`""` for a send-only node).
    public var endpoint: String {
        get throws {
            var buf = [CChar](repeating: 0, count: Polycall.endpointBufferSize)
            try check(polycall_peer_endpoint(handle, &buf, Polycall.endpointBufferSize))
            return decodeCString(buf)
        }
    }

    /// `polycall_peer_node_id`.
    public var nodeID: String {
        get throws {
            var buf = [CChar](repeating: 0, count: Polycall.peerIDBufferSize)
            try check(polycall_peer_node_id(handle, &buf, Polycall.peerIDBufferSize))
            return decodeCString(buf)
        }
    }

    /// `polycall_peer_register`: add or replace `peerID -> endpoint` in THIS node's registry.
    public func register(_ peerID: String, endpoint: String) throws {
        let status = try withCStringArgument(peerID, "peer id") { id in
            try withCStringArgument(endpoint, "endpoint") { ep in
                polycall_peer_register(handle, id, ep)
            }
        }
        try check(status)
    }

    /// `polycall_peer_unregister` (`.notFound` when `peerID` is not registered).
    public func unregister(_ peerID: String) throws {
        let status = try withCStringArgument(peerID, "peer id") { polycall_peer_unregister(handle, $0) }
        try check(status)
    }

    /// `polycall_peer_list`: this node's registry as the core's JSON object text.
    public func listJSON() throws -> String {
        try fetchText { buf, cap, needed in polycall_peer_list(handle, buf, cap, needed) }
    }

    /// This node's registry as a dictionary `peer id -> "host:port"`.
    public func list() throws -> [String: String] {
        let json = try listJSON()
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let registry = object as? [String: String] else {
            throw PolycallError.binding(.protocolError, "unexpected registry JSON: \(json)")
        }
        return registry
    }

    /// `polycall_peer_ping`: GET /health of `peer` (registered id or `"host:port"`).
    public func ping(_ peer: String, timeoutMs: UInt32 = 2000) throws {
        let status = try withCStringArgument(peer, "peer") { polycall_peer_ping(handle, $0, timeoutMs) }
        try check(status)
    }

    /// `polycall_peer_send`: exactly one delivery attempt of `payload` (at most
    /// 1 MiB; more -> `.tooLarge` before any I/O). Success means the receiver
    /// stored the message and acknowledged it under the expected id. On
    /// `.timeout` the outcome is unknown: retry with the SAME `messageID`.
    /// `messageID` nil lets the core generate one.
    public func send(to peer: String, payload: [UInt8], messageID: String? = nil,
                     timeoutMs: UInt32 = 5000) throws {
        let status = try withCStringArgument(peer, "peer") { p in
            try withOptionalCStringArgument(messageID, "message id") { mid in
                payload.withUnsafeBytes { bytes in
                    polycall_peer_send(handle, p, bytes.baseAddress, bytes.count, mid, timeoutMs)
                }
            }
        }
        try check(status)
    }

    /// Send the UTF-8 bytes of `text`.
    public func send(to peer: String, text: String, messageID: String? = nil,
                     timeoutMs: UInt32 = 5000) throws {
        try send(to: peer, payload: Array(text.utf8), messageID: messageID, timeoutMs: timeoutMs)
    }

    /// Send the bytes of `data`.
    public func send(to peer: String, data: Data, messageID: String? = nil,
                     timeoutMs: UInt32 = 5000) throws {
        try send(to: peer, payload: [UInt8](data), messageID: messageID, timeoutMs: timeoutMs)
    }

    /// `polycall_peer_recv`, blocking the calling thread.
    ///
    /// `timeoutMs` 0 polls, `Polycall.waitForever` waits until a message,
    /// `cancel()` (`.cancelled`) or `close()` (`.closed`). If `capacity` is
    /// smaller than the next payload the core throws `.tooLarge` with
    /// `requiredSize` set and the message stays queued.
    ///
    /// From Swift concurrency use `receive(timeoutMs:)` instead: it blocks a
    /// dedicated thread, never a cooperative-pool thread.
    public func recv(timeoutMs: UInt32 = Polycall.waitForever,
                     capacity: Int = Polycall.maxPayload) throws -> PeerMessage {
        guard capacity >= 0 else {
            throw PolycallError.binding(.invalidArgument, "capacity must not be negative")
        }
        var sender = [CChar](repeating: 0, count: Polycall.peerIDBufferSize)
        var messageID = [CChar](repeating: 0, count: Polycall.messageIDBufferSize)
        var length = 0
        var status: Int32 = POLYCALL_OK
        let payload = [UInt8](unsafeUninitializedCapacity: capacity) { buf, initialized in
            status = polycall_peer_recv(handle, timeoutMs,
                                        &sender, Polycall.peerIDBufferSize, &messageID, Polycall.messageIDBufferSize,
                                        capacity == 0 ? nil : buf.baseAddress, capacity, &length)
            initialized = status == POLYCALL_OK ? min(length, capacity) : 0
        }
        if status != POLYCALL_OK {
            throw PolycallError.capture(status, requiredSize: status == POLYCALL_E_TOO_LARGE ? length : nil)
        }
        return PeerMessage(sender: decodeCString(sender), messageID: decodeCString(messageID),
                           payload: payload)
    }

    /// Receive without blocking the Swift concurrency cooperative pool.
    ///
    /// The wait runs on a dedicated thread. It ends with a message, a timeout
    /// (`.timeout`), `cancel()` (`.cancelled`), `close()` (`.closed`) or
    /// cancellation of the calling task (`.cancelled`). Task cancellation calls
    /// `polycall_peer_cancel`, which -- as the core defines -- wakes every
    /// receive blocked on this node at that moment.
    public func receive(timeoutMs: UInt32 = Polycall.waitForever,
                        capacity: Int = Polycall.maxPayload) async throws -> PeerMessage {
        let waiter = ReceiveWaiter(epoch: currentCancelEpoch())
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PeerMessage, Error>) in
                let thread = Thread { [self] in
                    continuation.resume(with: Result {
                        try self.waitForMessage(timeoutMs: timeoutMs, capacity: capacity, waiter: waiter)
                    })
                }
                thread.name = "polycall-peer-recv"
                thread.start()
            }
        } onCancel: {
            waiter.cancel()
            _ = polycall_peer_cancel(handle)
        }
    }

    /// `polycall_peer_cancel`: wake every receive currently blocked on this node
    /// with `.cancelled` (later receives wait normally).
    public func cancel() throws {
        lock.lock()
        cancelEpoch &+= 1
        lock.unlock()
        try check(polycall_peer_cancel(handle))
    }

    /// `polycall_peer_health`: this node's health JSON.
    public func health() throws -> String {
        try fetchText { buf, cap, needed in polycall_peer_health(handle, buf, cap, needed) }
    }

    // MARK: private

    private func currentCancelEpoch() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return cancelEpoch
    }

    /// Blocking wait used by `receive`. It waits in bounded slices so that a
    /// task cancellation or `cancel()` that lands between two core calls is
    /// still observed; a cancel during a slice wakes it immediately.
    private func waitForMessage(timeoutMs: UInt32, capacity: Int, waiter: ReceiveWaiter) throws -> PeerMessage {
        let slice: UInt32 = 200
        let start = DispatchTime.now().uptimeNanoseconds
        while true {
            if waiter.isCancelled || currentCancelEpoch() != waiter.epoch {
                throw PolycallError.binding(.cancelled, "receive cancelled")
            }
            var wait = slice
            if timeoutMs != Polycall.waitForever {
                let elapsed = (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                let remaining = elapsed >= UInt64(timeoutMs) ? 0 : UInt64(timeoutMs) - elapsed
                wait = UInt32(min(UInt64(slice), remaining))
            }
            do {
                return try recv(timeoutMs: wait, capacity: capacity)
            } catch let error as PolycallError where error.code == .timeout {
                if timeoutMs != Polycall.waitForever {
                    let elapsed = (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                    if elapsed >= UInt64(timeoutMs) { throw error }
                }
            } catch let error as PolycallError where error.code == .invalidHandle && isClosed {
                // closed between two slices: report it as the core does for a
                // receive that was blocked when the node closed
                throw PolycallError.binding(.closed, "peer closed while receiving (\(error.detail))")
            }
        }
    }
}

/// Cancellation state shared between a `receive` call and its waiting thread.
private final class ReceiveWaiter: @unchecked Sendable {
    let epoch: UInt64
    private let lock = NSLock()
    private var cancelled = false

    init(epoch: UInt64) { self.epoch = epoch }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}
