# swift-polycall

**Swift** binding for [Polycall](https://github.com/obinexus/polycall) — the
binding ABI v1 surface of the Polycall C library (`polycall.h`,
`libpolycall.so.1`), wrapped in idiomatic Swift.

This binding is a *thin adapter*: it contains no runtime or configuration
logic. Every call goes straight to the C function of the same name through a
SwiftPM system-library target whose module map imports the core's installed
`<polycall.h>`; compiler and linker flags come from `pkg-config polycall`.

## Requirements

- Swift 6.0 or newer (SwiftPM, `swift-tools-version:6.0`).
- The Polycall core **1.1.0 or newer (binding ABI 1)** installed with its
  pkg-config file — the Debian package `libpolycall-dev`, the Arch package
  `polycall`, or a CMake install (`cmake --install`), which writes
  `<prefix>/lib/pkgconfig/polycall.pc`.

Tested platform: **Linux x86_64** (Swift 6.0.3 on Ubuntu 24.04, see
`tests/run-real-core.sh`). macOS and Windows are not claimed: nothing here is
platform-specific beyond the link through pkg-config, but neither has been
built or tested.

## Use it

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/obinexus/swift-polycall", branch: "main"),
],
targets: [
    .executableTarget(name: "app", dependencies: [
        .product(name: "Polycall", package: "swift-polycall"),
    ]),
]
```

When the core lives outside the default pkg-config search path:

```bash
PKG_CONFIG_PATH=/opt/polycall/lib/pkgconfig swift build
LD_LIBRARY_PATH=/opt/polycall/lib swift run app     # if libpolycall.so.1 is not in the loader path
```

## API

```swift
import Polycall

// library / ABI
try Polycall.checkABI()                 // throws unless polycall_ffi_abi_version() == 1
Polycall.version                        // "1.1.0"
Polycall.abiVersion                     // 1

// configuration -- the documented entry point is strict (polycall_ffi_run_config(path, 1))
try Polycall.runConfig("swift-polycallrc")
try Polycall.runConfig("swift-polycallrc", strict: false)   // unknown keys are warnings
let json = try Polycall.describe("Polycallfile")

// RPC: one polycall_rpc v1 round trip to `polycall daemon start` / `polycall start`
let out = try Polycall.call(endpoint: "127.0.0.1:8084", service: "inventory",
                            operation: "get", input: #"{"item_id":"widget-a"}"#,
                            timeoutMs: 2000)

// peer nodes (polycall-peer/1, no broker)
let alpha = try Peer(nodeID: "alpha", bindEndpoint: "127.0.0.1:0", authToken: token)
let beta  = try Peer(nodeID: "beta",  bindEndpoint: "127.0.0.1:0", authToken: token)
try alpha.register("beta", endpoint: try beta.endpoint)
try alpha.ping("beta")
try alpha.send(to: "beta", payload: [0x00, 0xff], messageID: "m-1")
let message = try beta.recv(timeoutMs: 2000)          // blocks this thread
let next = try await beta.receive(timeoutMs: 2000)    // async, never blocks the cooperative pool
try beta.cancel()                                     // wakes blocked receives (.cancelled)
try beta.close()                                      // wakes them with .closed; a 2nd close throws .invalidHandle
```

`Peer` also has `nodeID`, `unregister(_:)`, `list()` / `listJSON()`,
`health()` and `send(to:text:)` / `send(to:data:)`.

### Errors

Every failure throws `PolycallError`:

| property | meaning |
| --- | --- |
| `status` | the negative `POLYCALL_E_*` code (`code` gives it as `PolycallStatus`) |
| `name` | `polycall_strerror(status)`, e.g. `POLYCALL_E_TIMEOUT: deadline exceeded` |
| `detail` | `polycall_last_error()` read on the failing thread right after the call |
| `output` | for `call`: the remote error object `{"code":..,"message":..}` when present |
| `requiredSize` | for `.tooLarge`: the buffer size the core asked for |

A Swift string that contains a NUL byte cannot cross the C ABI unchanged and is
refused with `.invalidArgument` instead of being truncated.

### Loading

The library is linked at build time through pkg-config (no hard-coded paths),
so the operating system's dynamic loader finds `libpolycall.so.1`:

- library missing → the loader refuses to start the program
  (`error while loading shared libraries: libpolycall.so.1 ...`, exit 127);
- a 1.0 library without the ABI v1 symbols → the loader reports
  `undefined symbol: polycall_ffi_abi_version` (exit 127);
- a library reporting another binding ABI → every API throws
  `PolycallError` (`POLYCALL_E_UNSUPPORTED: binding ABI mismatch`) naming the
  library file and both ABI numbers.

`tests/loader-errors.sh` checks all three. Nothing returned by the library is
ever freed by the binding (the ABI returns nothing to free); a `Peer` releases
its handle exactly once (`close()`, or `deinit` if it was never closed).

### Concurrency

All C functions are thread-safe, and `Peer` is `Sendable`. `recv` blocks the
calling thread; from Swift concurrency use `receive`, which waits on a
dedicated thread so many concurrent receives never starve the cooperative
pool. Cancelling the task calls `polycall_peer_cancel`, which — as the core
defines it — wakes **every** receive blocked on that node at that moment.

## Config

Read-only config: [`swift-polycallrc`](swift-polycallrc) — the standard
`*-polycallrc` convention, validated by the core with exactly the grammar of
`polycall config validate` (`polycall_ffi_run_config`). No per-language
parser exists.

## Example

```bash
swift run polycall-swift version
swift run polycall-swift run-config swift-polycallrc
swift run polycall-swift call 127.0.0.1:8084 debug echo '{"hello":"world"}'
```

## Tests

```bash
PATH=/opt/polycall/bin:$PATH LD_LIBRARY_PATH=/opt/polycall/lib \
PKG_CONFIG_PATH=/opt/polycall/lib/pkgconfig sh tests/run-real-core.sh
```

builds with warnings as errors, runs the XCTest suite against the real
library (configuration, `call` against a `polycall daemon`, two peers in both
directions, payload limits, cancellation/close, concurrency, interop with the
C CLI `polycall peer serve/send/recv`), the loader checks and a clean
consumer package. A missing toolchain, core or CLI is reported as `SKIP`
(exit 77), never as success. `SANITIZE=address` or `SANITIZE=thread` runs the
suite under ASan / TSan. See [tests/TESTS.md](tests/TESTS.md).

## License

MIT — see [LICENSE](LICENSE).
