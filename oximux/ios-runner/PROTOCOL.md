# OxiMux iPhone runner — protocol `oximux-runner/1`

An XCUITest bundle that serves commands on the iPhone's **loopback** while it runs, so OxiMux can touch, type into and read a real iPhone. OxiMux reaches it from the Mac through usbmux (the USB connection's port forwarding). Nothing off the phone can connect: the listener is bound to `127.0.0.1`.

## Building and starting it (what OxiMux does)
The project carries no team and no real bundle ids. OxiMux builds it on the user's Mac, signed with the user's team:
```sh
xcodebuild build-for-testing -project OximuxRunner.xcodeproj -scheme OximuxRunner \
  -destination id=<phone udid> -derivedDataPath <dir> \
  DEVELOPMENT_TEAM=<team> OXIMUX_BUNDLE_PREFIX=dev.oximux.runner.t<team> -allowProvisioningUpdates
TEST_RUNNER_OXIMUX_TOKEN=<token> xcodebuild test-without-building -project OximuxRunner.xcodeproj \
  -scheme OximuxRunner -destination id=<phone udid> -derivedDataPath <dir>
```
- `OXIMUX_BUNDLE_PREFIX` names the host app; the test bundle is `<prefix>.uitests`.
- The token is fresh per launch, at least 32 characters. xcodebuild hands `TEST_RUNNER_OXIMUX_TOKEN` to the runner as `OXIMUX_TOKEN`. The runner never logs it.
- When it is listening, the runner prints one line: `OXIMUX_RUNNER_LISTENING port=<n>`. A listener failure prints `OXIMUX_RUNNER_FAILED …` and ends the run.
- It parks for at most 24 hours, then ends. `shutdown` ends it sooner.
- It starts by pressing Home, off its own blank screen.

## Transport
- One HTTP/1.1 `POST /` per command, `Content-Length` framed, answered with `Connection: close`.
- Every request carries `Authorization: Bearer <token>`, compared in constant time. Without it, or with another: **401, no body** — checked before anything else about the request.
- Other refusals, all without a body: 405 (not `POST`), 404 (not `/`), 400 (an unreadable head or no `Content-Length`), 413 (a body over 2 MB), 503 (a fifth connection while four are open).
- Otherwise **200**, with a JSON envelope:
  - `{"ok": true, "data": {…}}`, plus `"reactivated": true` when the command first had to bring its app to the front;
  - `{"ok": false, "error": {"code": "…", "message": "…", "hint": "…"}}` (`hint` optional).

## Commands
A JSON object: `command`, an optional `commandId` (1–128 characters), and the command's fields.

`app` is a bundle id; it defaults to `com.apple.springboard` (the home screen and system dialogs). Coordinates are **points from the app's top-left**, as XCTest addresses them, whichever way the phone is turned.

| command | fields | data |
|---|---|---|
| `status` | `statusCommandId`? | `protocol`, `version`; with `statusCommandId`, `reply`: the reply that command got (or `null` when unknown) |
| `viewport` | `app`? | `x`, `y`, `width`, `height` (the app's frame), `orientation` (`UIDeviceOrientation`) |
| `snapshot` | `app`? | `nodes`: the accessibility tree flattened depth first — `role`, `label`?, `identifier`?, `value`?, `frame` `[x, y, w, h]`, `enabled`, `depth` — at most 2000; `truncated` |
| `screenshot` | — | `pngBase64`: the whole screen |
| `tap` | `app`?, `x`, `y`, `taps`? (1–3) | — |
| `longPress` | `app`?, `x`, `y`, `durationMs`? (default 800) | — |
| `drag` | `app`?, `from` `{x, y}`, `to` `{x, y}`, `durationMs`?, `holdMs`?, `settle`? (ms) | — (one gesture; speed clamped to 60–5000 pt/s) |
| `type` | `app`?, `text` (1–4000 characters) | — (into whatever has the keyboard focus) |
| `keyboardReturn` | `app`? | — |
| `keyboardDelete` | `app`?, `count`? (1–500) | — |
| `button` | `name`: `home`, `volumeUp`, `volumeDown`, `action` | — (`UNSUPPORTED` where there is no such button, e.g. volume on a simulator) |
| `shutdown` | — | — (the run ends) |

- **Reading never brings an app to the front**: `viewport` and `snapshot` of an app that is not in front answer `APP_BACKGROUNDED`. A gesture does bring it back, and says so (`reactivated`). An app just opened gets a second to come forward before either.
- **Send-once.** The mutating commands (`tap`, `longPress`, `drag`, `type`, `keyboardReturn`, `keyboardDelete`, `button`) are answered once per `commandId`: the same id again returns the first reply without acting (the reply was lost, not the gesture). `status{statusCommandId}` reads it. The runner keeps the last 256.
- **One at a time.** XCTest is driven from one thread: a command arriving while another runs is `RUNNER_BUSY`; one that overruns its deadline (30 s plus its own length) is `RUNNER_WEDGED`, and the runner stays busy until it does end.

## Error codes
`BAD_REQUEST`, `UNKNOWN_COMMAND`, `APP_BACKGROUNDED`, `RUNNER_BUSY`, `RUNNER_WEDGED`, `UNSUPPORTED`, `XCTEST_FAILED` (XCTest's complaint, first line only — e.g. no keyboard focus, with the hint to tap the field first). A failure XCTest records during a command is that command's error: it never ends the run.

## Source layout
- `project.yml` — the xcodegen spec; `OximuxRunner.xcodeproj` is generated from it and committed (`xcodegen generate`).
- `OximuxRunner/` — the host app (a black screen).
- `OximuxRunnerUITests/` — the runner. `Protocol`, `HTTPParsing`, `Journal` and `HTTPServer` are pure Foundation/Network and also build into the package's `OximuxRunnerCore`, tested on macOS by `oximux/Tests/RunnerProtocolTests`.
