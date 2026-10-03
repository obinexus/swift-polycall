#!/bin/sh
# swift-polycall test matrix against the REAL installed Polycall core (Linux).
#
# Prerequisites: a Swift 6 toolchain and the core installed so that
#   pkg-config --cflags --libs polycall   works (set PKG_CONFIG_PATH),
#   libpolycall.so.1 is resolvable          (set LD_LIBRARY_PATH or ldconfig),
#   the `polycall` CLI is on PATH           (daemon + C peer interop tests).
# In the QA image: sh /qa/build-linux-core.sh, then
#   PATH=/opt/polycall/bin:$PATH LD_LIBRARY_PATH=/opt/polycall/lib \
#   PKG_CONFIG_PATH=/opt/polycall/lib/pkgconfig sh tests/run-real-core.sh
#
# A missing prerequisite is reported as SKIP with exit status 77 -- never as
# success. Set SANITIZE=address or SANITIZE=thread to run the XCTest suite
# under that sanitizer.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRATCH=${SWIFT_SCRATCH:-$ROOT/.build}
cd "$ROOT" || exit 1

skip() { echo "SKIP: $1"; exit 77; }
command -v swift >/dev/null 2>&1 || skip "swift toolchain not found"
pkg-config --exists polycall 2>/dev/null || skip "pkg-config cannot find polycall (install the core, set PKG_CONFIG_PATH)"
command -v polycall >/dev/null 2>&1 || skip "polycall CLI not on PATH (needed for daemon and C-peer interop tests)"

echo "== toolchain: $(swift --version 2>&1 | head -1)"
echo "== core: $(polycall --version) via pkg-config $(pkg-config --modversion polycall): $(pkg-config --cflags --libs polycall)"
FAIL=0
run() { echo "== $*"; "$@" || { echo "FAILED: $*"; FAIL=1; }; }

run swift build --scratch-path "$SCRATCH" -Xswiftc -warnings-as-errors
if [ -n "${SANITIZE:-}" ]; then
  run swift test --scratch-path "$SCRATCH-$SANITIZE" --disable-swift-testing --sanitize="$SANITIZE"
else
  run swift test --scratch-path "$SCRATCH" --disable-swift-testing
fi
POLYCALL_LIBDIR=${POLYCALL_LIBDIR:-$(pkg-config --variable=libdir polycall)}
export POLYCALL_LIBDIR
run sh tests/loader-errors.sh "$SCRATCH/debug/polycall-swift"
run "$SCRATCH/debug/polycall-swift" run-config swift-polycallrc
run sh tests/consumer-package.sh "$ROOT" ${CONSUMER_REVISION:+"$CONSUMER_REVISION"}

[ "$FAIL" -eq 0 ] && echo "== swift-polycall real-core matrix: PASS" || echo "== swift-polycall real-core matrix: FAIL"
exit "$FAIL"
