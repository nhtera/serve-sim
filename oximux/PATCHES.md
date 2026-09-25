# OxiMux patches to upstream files

Everything else on the `oximux` branch is **additive**, meaning it only adds files:
- `Package.swift`
- `oximux/`
- `.github/workflows/oximux-helper.yml`

These are the only commits that touch upstream files. Keep each one small and in its own commit, and re-check each after a rebase. CI fails if `git diff <upstream-base> -- packages/` touches a file that isn't listed here.

Upstream base: see `oximux/upstream-base`.

| # | Files | Why | Upstream PR |
|---|---|---|---|
| 1 | `packages/serve-sim/Sources/SimNative/FrameCapture.swift` | Rate-limit and pause **before** the full-frame Photocopier copy. Upstream copies on every simulator frame callback, up to 60 Hz, however slowly the consumer encodes. Adds `setCaptureRate(maxFPS:paused:)`. At 30 fps and half resolution this cut helper CPU from about 30% to about 24%, and to about 0.2% while paused. | not yet |
| 2 | `packages/serve-sim/Sources/SimNative/HIDInjector.swift`, `packages/serve-sim/Sources/SimNative/Xcode.swift` | Spawned `xcrun` / `xcode-select` get `/dev/null` as stdin, so they can't read the host's command pipe. | not yet |

When upstream merges an equivalent change, drop the patch commit during the next rebase and remove its row.
