#!/bin/sh
# Packaging check: a clean consumer SwiftPM package that depends on
# swift-polycall, resolves it, builds, and runs against the real core.
#
# Usage: tests/consumer-package.sh <swift-polycall git URL or path> [revision]
#   With a revision the dependency is fetched from git at exactly that commit
#   (what a user gets); without one it is a local path dependency.
set -u
SRC=${1:?usage: tests/consumer-package.sh <git url or path> [revision]}
REV=${2:-}
IDENT=$(basename "$SRC" .git)   # SwiftPM package identity = last path component
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/consumer/Sources/consumer"
if [ -n "$REV" ]; then
  case "$SRC" in *://*) URL=$SRC ;; *) URL="file://$SRC" ;; esac
  DEP=".package(url: \"$URL\", revision: \"$REV\")"
else
  DEP=".package(path: \"$SRC\")"
fi
cat >"$T/consumer/Package.swift" <<EOF
// swift-tools-version:6.0
import PackageDescription
let package = Package(
    name: "consumer",
    dependencies: [$DEP],
    targets: [
        .executableTarget(name: "consumer",
                          dependencies: [.product(name: "Polycall", package: "$IDENT")]),
    ]
)
EOF
cat >"$T/consumer/Sources/consumer/main.swift" <<'EOF'
import Polycall

try Polycall.checkABI()
print("consumer: libpolycall \(Polycall.version), binding ABI \(Polycall.abiVersion)")
let a = try Peer(nodeID: "consumer-a", authToken: "consumer-token")
let b = try Peer(nodeID: "consumer-b", authToken: "consumer-token")
try a.send(to: try b.endpoint, text: "hello from a consumer package", messageID: "consumer-1")
let m = try b.recv(timeoutMs: 3000)
precondition(m.sender == "consumer-a" && m.messageID == "consumer-1"
             && m.text == "hello from a consumer package", "unexpected message \(m)")
try a.close()
try b.close()
do {
    try b.close()
    fatalError("double close must throw")
} catch let error as PolycallError where error.code == .invalidHandle {
    print("consumer: double close -> \(error.name)")
}
print("consumer: OK")
EOF
cd "$T/consumer" || exit 1
swift package resolve || exit 1
swift package describe | sed -n '1,12p'
swift build || exit 1
swift run consumer
