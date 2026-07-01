# Swift adapter (scaffold)

Implement the Swift adapter here. It must call across the FFI boundary only:

    status = polycall_ffi_run_config("swift-polycallrc", /*run=*/1)

Return/raise a Swift-native error when `status` is non-zero. Do not parse
config or duplicate any core logic. See ../../../docs/adapter-pattern.md.
