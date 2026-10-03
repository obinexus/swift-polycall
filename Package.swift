// swift-tools-version:6.0
//
// swift-polycall -- Swift binding for the Polycall C library (binding ABI v1).
//
// The C surface is reached through a SwiftPM system-library target whose
// module map imports <polycall.h>. Compiler and linker flags come from
// `pkg-config polycall` (installed by the core as lib/pkgconfig/polycall.pc),
// so no path is hard-coded here. Set PKG_CONFIG_PATH when the core is
// installed outside the default search path, e.g.
//
//   PKG_CONFIG_PATH=/opt/polycall/lib/pkgconfig swift build
//
import PackageDescription

let package = Package(
    name: "swift-polycall",
    products: [
        .library(name: "Polycall", targets: ["Polycall"]),
        .executable(name: "polycall-swift", targets: ["polycall-swift"]),
    ],
    targets: [
        .systemLibrary(
            name: "CPolycall",
            path: "src/CPolycall",
            pkgConfig: "polycall",
            providers: [.apt(["libpolycall-dev"])]
        ),
        .target(
            name: "Polycall",
            dependencies: ["CPolycall"],
            path: "src/Polycall"
        ),
        .executableTarget(
            name: "polycall-swift",
            dependencies: ["Polycall"],
            path: "examples/polycall-swift"
        ),
        .testTarget(
            name: "PolycallTests",
            dependencies: ["Polycall"],
            path: "tests/PolycallTests"
        ),
    ]
)
