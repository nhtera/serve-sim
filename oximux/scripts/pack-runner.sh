#!/usr/bin/env bash
#
# Pack the iPhone runner's sources into a reproducible tarball:
#   oximux/scripts/pack-runner.sh <version> [<out dir>]
#   → <out dir>/oximux-ios-runner-src-<version>.tar.gz
#
# Byte for byte the same on any machine, so its sha256 can be pinned and
# re-checked: only committed files under oximux/ios-runner (plus LICENSE),
# sorted, with zeroed times, owners and modes reduced to 0644/0755, in a
# gzip stream without a name or a timestamp. Python's tarfile does this, so
# no GNU tar is needed.
set -euo pipefail
cd "$(dirname "$0")/../.."

version="${1:?usage: pack-runner.sh <version> [<out dir>]}"
# Committed files, as committed: the contents come from the worktree.
if ! git diff --quiet HEAD -- oximux/ios-runner LICENSE; then
    echo "error: oximux/ios-runner has uncommitted changes; commit them first" >&2
    exit 1
fi
out="${2:-.}"
name="oximux-ios-runner-src-${version}"
mkdir -p "$out"

{ git ls-files -- oximux/ios-runner; echo LICENSE; } | python3 -c '
import gzip, io, os, sys, tarfile
name, archive = sys.argv[1], sys.argv[2]
files = sorted(line.strip() for line in sys.stdin if line.strip())
raw = io.BytesIO()
with tarfile.open(fileobj=raw, mode="w", format=tarfile.PAX_FORMAT) as tar:
    for path in files:
        # The project at the top: <name>/OximuxRunner.xcodeproj, …
        relative = path.removeprefix("oximux/ios-runner/")
        info = tar.gettarinfo(path, arcname=name + "/" + relative)
        info.mtime = 0
        info.uid = info.gid = 0
        info.uname = info.gname = ""
        info.pax_headers = {}
        if info.isfile():
            info.mode = 0o755 if os.access(path, os.X_OK) else 0o644
            with open(path, "rb") as f:
                tar.addfile(info, f)
        else:
            raise SystemExit(f"not a plain file: {path}")
with open(archive, "wb") as f, gzip.GzipFile(filename="", mode="wb", fileobj=f, mtime=0, compresslevel=9) as gz:
    gz.write(raw.getvalue())
' "$name" "$out/$name.tar.gz"

(cd "$out" && shasum -a 256 "$name.tar.gz" | tee "$name.tar.gz.sha256")
