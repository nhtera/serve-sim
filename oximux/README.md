# oximux-sim-helper (OxiMux fork addition)

This branch (`oximux`) of the `nhtera/serve-sim` fork builds **`oximux-sim-helper`**. It is the child process the [OxiMux](https://github.com/nhtera/OxiMux) desktop app uses to stream and drive one iOS Simulator. It reuses upstream serve-sim's native Swift (Apache-2.0, © Evan Bacon), minus the Node binding.

## Contract
The full wire spec is **[`PROTOCOL.md`](PROTOCOL.md)**: protocol version 2, announced in the first `hello` event.
- **stdio only.** It opens no sockets. Framed JPEG frames or H.264 pictures and JSON events go out on stdout; framed JSON commands come in on stdin.
- **Frames** are rotated for display by the device orientation. Touches are in portrait-normalized coordinates.
- **Lifetime:** it exits on stdin EOF and never outlives its parent.
- **Conformance:** `--conformance` needs no simulator. It lets OxiMux test its protocol code against the shipped binary.
- **Signing:** hardened runtime, no entitlements. OxiMux re-signs the binary inside its own notarized app bundle.

## Layout
- `/Package.swift`: root manifest. It is an added file; upstream has no root manifest. It builds one module from `oximux/Sources/oximux-sim-helper`.
  - `Upstream` in that folder is a **committed symlink** to `packages/serve-sim/Sources/SimNative`.
  - `sim-module.swift` and `build.sh` are excluded.
- `oximux/Sources/oximux-sim-helper/`: our code (`main`, `Protocol`, `Commands`, `FrameStream`, `Wire`, `Conformance`, `Version`).
- `oximux/Tests/HelperTests/`: golden framing and command-parser tests.
- `oximux/PATCHES.md`: the only changes to upstream files.

## Build and test (Swift ≥ 6.1, Xcode 26 recommended)
```sh
swift build -c release --arch arm64
swift test
.build/arm64-apple-macosx/release/oximux-sim-helper --version
```

## Release
1. Bump `helperVersion` in `oximux/Sources/oximux-sim-helper/Version.swift`.
2. Push the tag `helper-v<version>`. The `oximux-helper` workflow then:
   - tests the build
   - builds the arm64 binary
   - checks that it has no `@rpath` Swift runtime and no entitlements
   - publishes `oximux-sim-helper-<version>-macos-arm64.tar.gz` with its `.sha256` and a build-provenance attestation
3. In OxiMux, bump the version and sha256 pinned in `scripts/fetch-sim-helper.sh`.

## Rebasing on upstream
```sh
git fetch upstream            # remote added with --no-tags
git rebase upstream/main oximux
git rev-parse upstream/main > oximux/upstream-base
swift test
```
Only the commits listed in `PATCHES.md` can conflict.
