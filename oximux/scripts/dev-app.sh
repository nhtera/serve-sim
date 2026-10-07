#!/usr/bin/env bash
#
# Build `OxiMux Device Capture.app` for local use, the way OxiMux's bundle
# will hold it: hardened runtime, the camera entitlement alone, ad-hoc
# signed, and registered with LaunchServices (macOS grants the camera only to
# a bundle it has seen).
#
#   oximux/scripts/dev-app.sh [<out dir>]     (default: .build/dev-app)
#
# Then point OxiMux at it:
#   OXIMUX_DEVICE_CAPTURE="<out dir>/OxiMux Device Capture.app/Contents/MacOS/oximux-device-capture"
set -euo pipefail
cd "$(dirname "$0")/../.."

out="${1:-.build/dev-app}"
swift build -c release --arch arm64 --product oximux-device-capture
app="$out/OxiMux Device Capture.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
install -m 0755 .build/arm64-apple-macosx/release/oximux-device-capture "$app/Contents/MacOS/"
cp oximux/device-capture/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - --options runtime --entitlements oximux/entitlements/device-capture.entitlements "$app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
echo "OXIMUX_DEVICE_CAPTURE=\"$(cd "$out" && pwd)/OxiMux Device Capture.app/Contents/MacOS/oximux-device-capture\""
