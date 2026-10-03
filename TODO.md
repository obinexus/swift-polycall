# TODO — swift-polycall (Swift)

Status: binding ABI v1 adapter over the real Polycall core
(`polycall >= 1.1.0`, `libpolycall.so.1`), tested on Linux x86_64.

- [x] Folder structure, manifest, and `swift-polycallrc` (shared schema)
- [x] SwiftPM system-library target over the installed `<polycall.h>` (pkg-config)
- [x] Thin adapter in `src/Polycall`: ABI check, `runConfig(path)` /
      `runConfig(path, strict:)`, `describe`, `call`, `Peer`, `PolycallError`
- [x] Runnable example (`examples/polycall-swift`)
- [x] XCTest suite against the real library, loader checks, consumer package
- [ ] Build and test on macOS (`libpolycall.1.dylib`) — needs a macOS host
- [ ] Build and test on Windows (Swift for Windows + `polycall.dll`)

Do not add config parsing or runtime logic here — adapt the core only.
