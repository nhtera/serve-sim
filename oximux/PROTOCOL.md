# oximux-sim-helper stdio protocol, version 2

This is the contract between `oximux-sim-helper` (this fork) and OxiMux (`crates/simulator/src/protocol.rs`). Both sides must change together.
- The helper announces `proto` in its first message, and OxiMux refuses a version it doesn't speak.
- Any change an older peer would misread bumps `protocolVersion` (in `Protocol.swift`) and ships as a new `helper-v*` release.

Transport is the helper's own stdin and stdout, nothing else. **The helper opens no sockets.** Upstream code's `print` output is moved to stderr, which is a free-form log and not part of the protocol.

## Invocation
```
oximux-sim-helper --udid <UDID> [--scale 0.05-1] [--fps 1-60] [--quality 0.1-1] [--orientation 1-4] [--format jpeg|avcc]
oximux-sim-helper --conformance
oximux-sim-helper --version        # prints "oximux-sim-helper <version>" (plain text) and exits
```
- **Defaults:** `--scale 1`, `--fps 30`, `--quality 0.7`, `--orientation 1`, `--format jpeg`.
- **Out-of-range values:** `--scale` is **clamped** into range, so a tiny scale never silently becomes full resolution. Other out-of-range values fall back to their default.
- **Exit codes:** `0` on stdin EOF, `3` after a `fatal` event.

## Outbound: helper → OxiMux (stdout)
Every message is `[u8 kind][u32 LE length][payload]`, and `length` never exceeds 16 MiB.
- OxiMux treats a larger prefix as a corrupt stream.
- A reply that would exceed the cap is sent as `ok: false`, with an error naming its size. A full-resolution PNG screenshot of a large iPad can do this; fall back to `simctl io screenshot`.
- An oversized frame is dropped.

| kind | payload |
|---|---|
| 1 `frame` | `[u32 LE width][u32 LE height][JPEG bytes]`. The frame is already scaled by `scale` and **rotated for display** by the current orientation. |
| 2 `event` | A UTF-8 JSON object with a string field `event`. |
| 3 `video` | `[u32 LE width][u32 LE height][u8 tag][payload]`, sent instead of `frame` in `avcc` format. Width and height are the display size, scaled and **rotated** like a frame's. Tag 1: the avcC record (SPS/PPS), sent before **every** key frame. Tag 2: a key frame (IDR). Tag 3: a delta frame. Pictures are AVCC: NAL units with 4-byte big-endian lengths. |

**Formats.** `jpeg` sends `frame`s; `avcc` sends `video` (H.264, VideoToolbox, no B-frames). A new format, a `configure`, `resume` or orientation change makes the next picture a key frame. If H.264 encoding keeps failing (3 pictures in a row), the helper falls back to `jpeg` and says so with a `format` event, so a client must paint either kind at any time. Unchanged screens send nothing, except that in `avcc` the first unchanged picture after a delta is sent once more as a key frame, which sharpens what motion left soft. *(Version 2 added `video`, `--format` and `configure.format`.)*

Events:

| event | fields | when |
|---|---|---|
| `hello` | `proto` (int), `version` (string), `xcode` (developer dir) | **Always the first message.** |
| `ready` | `udid`, `pid`, `orientation` | Capture is running. It is sent **before** any `size` or frame. |
| `size` | `width`, `height` | Framebuffer size in pixels. It is always **portrait** and unscaled. Sent before the first frame and whenever it changes. |
| `orientation` | `value` (1–4) | A commanded orientation has taken effect. The ordering is strict: every frame after this event is rotated for the new orientation, and no frame before it is. |
| `response` | `id`, `ok: true`, `result` (JSON) | Success reply to a command that carried an `id`. |
| `response` | `id`, `ok: false`, `error` (string) | Failure reply to a command that carried an `id`. |
| `format` | `value` (`jpeg`), `message` | The helper changed the stream format on its own: H.264 kept failing. |
| `error` | `message` | A non-fatal problem with no `id` to answer: a malformed body, a rejected command sent without an id, or a full queue. |
| `fatal` | `reason`, `message` | The helper exits with code 3 right after. `reason` is one of `bad_args`, `framework_load_failed`, `device_not_found`, `device_not_booted`, `capture_failed`. |
| `parsed` | `command` (canonical JSON) and optional `id`, **or** `error` | `--conformance` only. |
| `conformance_ready` | none | `--conformance` only: the fixed opening sequence has finished. |

**Orientation.** Numbering follows UIKit's `UIDeviceOrientation`:
- 1: portrait
- 2: portrait upside down
- 3: landscape, device turned counter-clockwise
- 4: landscape, device turned clockwise

The framebuffer itself never rotates. Frames are rotated by the **device** orientation, as Simulator.app does, so a portrait-only app shows sideways on a rotated device. Measured on Xcode 26.3: 3 rotates the buffer 90° counter-clockwise, 4 rotates it 90° clockwise, and 2 rotates it 180°.

## Inbound: OxiMux → helper (stdin)
Every message is `[u32 LE length][UTF-8 JSON object]`, with 1 ≤ `length` ≤ 1 MiB. A zero or oversized length, or EOF, makes the helper exit immediately with code 0. A body that isn't a JSON object gets an `error` event, and the helper keeps reading.

Every command is `{"cmd": "<name>", "id"?: int, …}`. A command that returns data replies with `response` for its `id`. A rejected command replies `ok: false` if it had an `id`; otherwise the helper emits an `error` event.

| cmd | fields | reply |
|---|---|---|
| `ping` | none | `{"pong": true}` |
| `touch` | `phase`: `begin`\|`move`\|`end`; `x`, `y` in 0–1 **portrait-normalized**; `edge` (optional int, default 0) | none |
| `multitouch` | `phase`, `x1`, `y1`, `x2`, `y2` (portrait-normalized) | none |
| `scroll` | `dx`, `dy` (finite); optional anchor `x`, `y` (portrait-normalized) | none |
| `key` | `phase`: `down`\|`up`; `usage` (HID usage, keyboard page) | none |
| `button` | `name`: `home`\|`lock`\|`siri`\|`side_button`\|`app_switcher`\|`swipe_home` | none |
| `configure` | optional `scale` (0 < s ≤ 1), `fps` (1–60), `orientation` (1–4), `format` (`jpeg`\|`avcc`) | `{"ok": true}`. With `orientation`, an `orientation` event comes first. |
| `pause` / `resume` | none | none. `resume` forces one fresh frame. |
| `screenshot` | none | `{"png_base64": "…"}`: full resolution, rotated like the stream |
| `ax_describe` | none | The accessibility tree, as an array of nodes. Frames are in **logical display points** of the current orientation. |
| `ax_frontmost` | none | `{"bundleId": "…", "pid": n}` |
| `memory_warning` | none | `{"ok": true}` |

**Validation.** Coordinates are clamped to 0–1, non-finite numbers become 0, and integer codes are clamped into u32. JSON booleans are not numbers. For `configure`, an out-of-range `scale` or `fps` is **ignored**, while an out-of-range `orientation` or an unknown `format` is **rejected**. An unknown `cmd`, `phase` or button is rejected.

**Ordering.** Input commands run in arrival order on a single queue, which holds at most 512 commands; beyond that, commands are dropped with an error. `screenshot`, `ax_describe` and `ax_frontmost` run detached and reply by id, so they never delay input. At most 8 can be in flight; beyond that a request fails immediately with a retry message. Only input commands wait for the HID client to finish setting up: touch, multitouch, scroll, key, button, `configure` with `orientation`, and `memory_warning`, which needs the device that HID setup resolves.

## Conformance mode
`--conformance` needs no simulator or Xcode. It writes this fixed sequence:
1. `hello` with `xcode: "conformance"`
2. a 3×2 frame whose payload is `FF D8 FF D9`
3. a 3×2 `video` message, tag 1, payload `01 64 00 1F`
4. `ready`
5. `size` 1206×2622
6. `orientation` 4
7. `response` id 1, ok, `{"pong": true}`
8. `response` id 2, ok, with a raw array result
9. `response` id 3, failed
10. `error`
11. `format` `jpeg`
12. `fatal` (`framework_load_failed`)
13. `conformance_ready`

After that it echoes each command as `parsed`, with the canonical form the helper understood (clamped values, absent optionals omitted). OxiMux's tests drive the **shipped** binary this way.
