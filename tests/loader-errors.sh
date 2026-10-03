#!/bin/sh
# Loader behaviour of the link-time Swift binding (Linux).
#
# swift-polycall links libpolycall through pkg-config, so the OS dynamic loader
# resolves the library (and, at startup or first call, its symbols) and
# Polycall.checkABI() rejects an incompatible ABI. This runs the binding's
# example executable against:
#   1. no libpolycall at all,
#   2. a 1.0-era libpolycall.so.1 without the binding ABI v1 symbols,
#   3. a libpolycall.so.1 that reports binding ABI 2,
# and requires a clear message and an ordinary exit status (never a signal).
#
# Usage: tests/loader-errors.sh <path to polycall-swift executable>
set -u
BIN=${1:?usage: tests/loader-errors.sh <polycall-swift executable>}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CC=${CC:-cc}
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/none" "$T/old" "$T/abi2"
"$CC" -shared -fPIC -Wl,-soname,libpolycall.so.1 -o "$T/old/libpolycall.so.1" "$ROOT/tests/fixtures/fake_polycall_v10.c" || exit 1
"$CC" -shared -fPIC -Wl,-soname,libpolycall.so.1 -o "$T/abi2/libpolycall.so.1" "$ROOT/tests/fixtures/fake_polycall_abi2.c" || exit 1

# expect LABEL LIBDIR WANT_RC PATTERN
expect() {
  LD_LIBRARY_PATH="$2" "$BIN" version >"$T/out" 2>"$T/err"
  rc=$?
  msg=$(tr '\n' ' ' <"$T/err")
  if [ "$rc" -ge 128 ]; then
    bad "$1: crashed with signal $((rc-128)): $msg"
  elif [ "$rc" -ne "$3" ]; then
    bad "$1: exit $rc (want $3): $msg"
  elif ! grep -q -- "$4" "$T/err"; then
    bad "$1: message lacks '$4': $msg"
  else
    ok "$1 -> exit $rc: $msg"
  fi
}

# sanity: the real library works with the same executable
if [ -n "${POLYCALL_LIBDIR:-}" ]; then
  LD_LIBRARY_PATH="$POLYCALL_LIBDIR" "$BIN" version >"$T/out" 2>&1 && ok "real libpolycall: $(cat "$T/out")" \
    || bad "real libpolycall: $(cat "$T/out")"
fi
expect "missing libpolycall" "$T/none" 127 "libpolycall.so.1: cannot open shared object file"
expect "1.0 library without ABI v1 symbols" "$T/old" 127 "undefined symbol: polycall_"
expect "library reporting binding ABI 2" "$T/abi2" 1 "implements binding ABI 2"
grep -q "POLYCALL_E_UNSUPPORTED" "$T/err" && grep -q "requires binding ABI 1" "$T/err" \
  && grep -q "$T/abi2/libpolycall.so.1" "$T/err" \
  && ok "ABI mismatch error is POLYCALL_E_UNSUPPORTED and names the library file and the required ABI" \
  || bad "ABI mismatch error should be POLYCALL_E_UNSUPPORTED naming $T/abi2/libpolycall.so.1 and ABI 1: $(cat "$T/err")"

echo "--- loader-errors: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
