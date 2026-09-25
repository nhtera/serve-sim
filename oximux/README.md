# oximux-sim-helper (OxiMux fork addition)

This branch (`oximux`) of the `nhtera/serve-sim` fork builds **`oximux-sim-helper`**. It is the child process the [OxiMux](https://github.com/nhtera/OxiMux) desktop app uses to stream and drive one iOS Simulator. It reuses upstream serve-sim's native Swift (Apache-2.0, © Evan Bacon), minus the Node binding.

## Contract
- **stdio only.** It opens no sockets.
- **Output (stdout):** `[u8 kind][u32 LE len][payload]`.
  - kind 1 is a frame: `[u32 LE w][u32 LE h][JPEG]`
  - kind 2 is a JSON event: `ready`, `size`, `response`, `error`
- **Input (stdin):** `[u32 LE len][JSON command]`, at most 1 MiB each.
- **Lifetime:** it exits on stdin EOF, and never outlives its parent.
- **Stray output:** upstream code's `print` output is moved to stderr, so it can't corrupt the frame stream.
- **Signing:** hardened runtime, no entitlements. OxiMux re-signs the binary inside its own notarized app bundle. The raw release binary is not meant for standalone use.

## Layout
- `/Package.swift`: root manifest. It is an added file; upstream has no root manifest. It builds one module from `oximux/Sources/oximux-sim-helper`.
  - `Upstream` in that folder is a **committed symlink** to `packages/serve-sim/Sources/SimNative`.
  - `sim-module.swift` and `build.sh` are excluded.
- `oximux/Sources/oximux-sim-helper/`: our code (`main`, `Commands`, `FrameStream`, `Wire`, `Version`).
- `oximux/Tests/HelperTests/`: golden framing tests.
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
