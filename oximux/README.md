# oximux-sim-helper (OxiMux fork addition)

This branch (`oximux`) of the `nhtera/serve-sim` fork builds **`oximux-sim-helper`**. It is the child process the [OxiMux](https://github.com/nhtera/OxiMux) desktop app uses to stream and drive one iOS Simulator. It reuses upstream serve-sim's native Swift (Apache-2.0, © Evan Bacon), minus the Node binding.

## Contract
The full wire spec is **[`PROTOCOL.md`](PROTOCOL.md)**: protocol version 2, announced in the first `hello` event.
- **stdio only.** It opens no sockets. Framed JPEG frames or H.264 pictures and JSON events go out on stdout; framed JSON commands come in on stdin.
- **Frames** are rotated for display by the device orientation. Touches are in portrait-normalized coordinates.
- **Lifetime:** it exits on stdin EOF and never outlives its parent.
- **Conformance:** `--conformance` needs no simulator. It lets OxiMux test its protocol code against the shipped binary.
- **Signing:** hardened runtime, no entitlements. OxiMux re-signs the binary inside its own notarized app bundle.

## Device capture (`oximux-device-capture`)
A second executable for a **USB iPhone's screen** (view-only), in the same protocol: see `PROTOCOL.md`, "Device capture helper". It shares `Wire.swift`, `Protocol.swift`, `Version.swift` and `H264Output.swift` with the sim helper, and upstream's `H264Encoder.swift` and `StreamFormat.swift`, through committed symlinks in `oximux/Sources/oximux-device-capture/`; the sim helper's sources are untouched. Released as an unsigned app-bundle skeleton (`OxiMux Device Capture.app` with `oximux/device-capture/Info.plist`) plus `oximux/entitlements/device-capture.entitlements`: OxiMux signs it with that camera entitlement alone.

## Layout
- `/Package.swift`: root manifest. It is an added file; upstream has no root manifest. It builds two executables: `oximux-sim-helper` from `oximux/Sources/oximux-sim-helper`, and `oximux-device-capture` from `oximux/Sources/oximux-device-capture` (its shared files are symlinks).
  - `Upstream` in that folder is a **committed symlink** to `packages/serve-sim/Sources/SimNative`.
  - `sim-module.swift` and `build.sh` are excluded.
- `oximux/Sources/oximux-sim-helper/`: our code (`main`, `Protocol`, `Commands`, `FrameStream`, `Wire`, `Conformance`, `Version`).
- `oximux/Tests/HelperTests/`: golden framing and command-parser tests.
- `oximux/Sources/oximux-device-capture/`: the capture helper (`main`, `Options`, `DeviceStream`, `Still`, `Recorder`, `DeviceCommands`, `Shutdown`); `oximux/device-capture/Info.plist` and `oximux/entitlements/device-capture.entitlements` make its app bundle.
- `oximux/Tests/DeviceCaptureTests/`: arguments, record paths, still-screen gating, recording from synthetic frames.
- `oximux/ios-runner/`: the iPhone **control runner**, an XCUITest bundle serving commands on the phone's loopback (protocol `oximux-runner/1`, see its `PROTOCOL.md`). Released as **sources** (`oximux-ios-runner-src-<v>.tar.gz`, reproducible: `oximux/scripts/pack-runner.sh`) by the `oximux-ios-runner` workflow on a `ios-runner-v<v>` tag; OxiMux builds and signs it on the user's Mac. Its pure protocol files build into `OximuxRunnerCore`, tested by `oximux/Tests/RunnerProtocolTests/`.
- `oximux/PATCHES.md`: the only changes to upstream files.

## Build and test (Swift ≥ 6.1, Xcode 26 recommended)
```sh
swift build -c release --arch arm64
swift test
.build/arm64-apple-macosx/release/oximux-sim-helper --version
```

## Release
1. Bump `helperVersion` in `oximux/Sources/oximux-sim-helper/Version.swift`, and both versions in `oximux/device-capture/Info.plist` to match (every build checks).
2. Push the tag `helper-v<version>`. The `oximux-helper` workflow then:
   - tests the build
   - builds both arm64 binaries
   - checks that neither has an `@rpath` Swift runtime or entitlements, and that the capture app's entitlement file names the camera alone
   - publishes `oximux-sim-helper-<version>-macos-arm64.tar.gz` and `oximux-device-capture-<version>-macos-arm64.tar.gz` (the unsigned `OxiMux Device Capture.app` and its entitlement file), each with its `.sha256` and a build-provenance attestation
3. In OxiMux, bump the versions and sha256s pinned in `scripts/fetch-sim-helper.sh`.

## Rebasing on upstream
```sh
git fetch upstream            # remote added with --no-tags
git rebase upstream/main oximux
git rev-parse upstream/main > oximux/upstream-base
swift test
```
Only the commits listed in `PATCHES.md` can conflict.
