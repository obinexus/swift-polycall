# Swift tests

All tests run against the REAL installed Polycall core; there is no mock.

| File | What it checks |
| --- | --- |
| `PolycallTests/LibraryTests.swift` | ABI version 1, library version, library path, `polycall_strerror` names, per-thread `polycall_last_error`, NUL refusal |
| `PolycallTests/ConfigTests.swift` | `runConfig` valid / missing / empty / invalid / unknown key (lenient vs strict) / TLS unsupported / non-ASCII path; `describe` |
| `PolycallTests/CallTests.swift` | `call` against a `polycall daemon` (private state dir, ephemeral port): success, null input, unknown operation, remote error, deadline, invalid JSON, no runtime, timeout bounds 0/1/600000/600001, too-small output, concurrent calls |
| `PolycallTests/PeerTests.swift` | open validation, endpoints, address in use, double close / use after close / invalid handles, registry ownership, ping + identity, health, payloads both directions (empty, UTF-8, binary with NUL, 1 MiB, 1 MiB + 1), too-small buffer keeps the message, timeouts, duplicate id once, dead peer, unregistered id, auth failures, backpressure, concurrent senders |
| `PolycallTests/ConcurrencyTests.swift` | cancel / close wake a blocked receive (thread and async), task cancellation, async timeout, more async receives than cooperative-pool threads, concurrent async senders/receivers |
| `PolycallTests/InteropTests.swift` | Swift peer <-> C CLI peer (`polycall peer serve` / `send` / `recv`) in both directions with exact bytes, sender and id; wrong-token CLI sender rejected; 12 concurrent CLI senders |
| `loader-errors.sh` | example executable against no library, a 1.0 library without ABI v1 symbols, and a library reporting ABI 2 (fixtures in `fixtures/`) |
| `consumer-package.sh` | clean consumer SwiftPM package depending on swift-polycall (path or git revision): resolve, build, run |

Run everything with `sh tests/run-real-core.sh` (see the README for the
environment). Tests that need the `polycall` CLI throw `XCTSkip` when it is
absent, so they show up as skipped, never as passed.
