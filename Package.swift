// swift-tools-version:6.1
//
// OxiMux fork addition — NOT part of upstream serve-sim.
//
// Builds `oximux-sim-helper`: a stdio-only child process that streams and
// drives one iOS Simulator for the OxiMux desktop app. It reuses upstream's
// native Swift (packages/serve-sim/Sources/SimNative + SimNativeSupport)
// without the Node binding (`sim-module.swift`, the only NodeAPI file). It
// opens no sockets: JPEG or H.264 goes out on stdout, JSON commands come in on
// stdin, and it exits on stdin EOF. See oximux/README.md.
//
// This manifest lives at the repo root because SwiftPM rejects a target path
// outside the package root, and upstream has no root manifest — so it is a
// purely additive file that never conflicts on rebase. Upstream's own
// package (packages/serve-sim/Package.swift) is untouched.
//
// Upstream sources and ours share ONE module (via the committed symlink
// oximux/Sources/oximux-sim-helper/Upstream) so upstream types stay
// `internal` and unpatched. Swift 6.1+ is required (upstream uses 6.1
// syntax); Swift 5 language mode matches upstream.

import PackageDescription

let package = Package(
    name: "oximux-sim-helper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "oximux-sim-helper", targets: ["oximux-sim-helper"]),
    ],
    targets: [
        .target(
            name: "SimNativeSupport",
            path: "packages/serve-sim/Sources/SimNativeSupport"
        ),
        .executableTarget(
            name: "oximux-sim-helper",
            dependencies: ["SimNativeSupport"],
            // `Upstream` is a committed symlink to upstream's
            // packages/serve-sim/Sources/SimNative, so the target has a
            // narrow root of its own instead of scanning the whole repo.
            path: "oximux/Sources/oximux-sim-helper",
            exclude: [
                "Upstream/sim-module.swift",
                "Upstream/build.sh",
            ]
        ),
        .testTarget(
            name: "HelperTests",
            dependencies: ["oximux-sim-helper"],
            path: "oximux/Tests/HelperTests"
        ),
        .testTarget(
            name: "SimNativeSupportTests",
            dependencies: ["SimNativeSupport"],
            path: "packages/serve-sim/Tests/SimNativeSupportTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
