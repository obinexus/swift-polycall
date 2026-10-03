# Swift adapter

- `CPolycall/` — SwiftPM system-library target. Its module map imports the
  core's installed `<polycall.h>` and links `polycall`; flags come from
  `pkg-config polycall`. No declarations are copied or generated.
- `Polycall/` — the Swift API. Each method calls exactly one C function of the
  binding ABI v1 (or two, when a too-small output buffer must be resized) and
  converts its status into `PolycallError` (status, `polycall_strerror` name,
  `polycall_last_error` detail).

The documented entry point is unchanged:

    try Polycall.runConfig("swift-polycallrc")   // polycall_ffi_run_config(path, 1)

Do not parse config or duplicate any core logic here.
