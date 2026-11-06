#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build.sh --universal
version=$(python3 -c 'import json; print(json.load(open("version.json"))["version"])')
archive="Codex-Activity-Community-${version}-universal.zip"
app="Codex Activity Community.app"
out="$PWD/build/release"
stage=$(mktemp -d "$PWD/build/.release.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir -p "$out" "$stage/unpacked"

ditto -c -k --norsrc --keepParent "build/$app" "$stage/$archive"
ditto -x -k "$stage/$archive" "$stage/unpacked"
unpacked="$stage/unpacked/$app"
python3 - "$unpacked" <<'CHECK_BUNDLE'
from pathlib import Path
import sys

app = Path(sys.argv[1])
helper = "Contents/Library/LoginItems/ActivityLauncher.app/Contents"
allowed = {
    "Contents/Info.plist",
    "Contents/MacOS/CodexActivity",
    "Contents/Resources/Activity.icns",
    "Contents/_CodeSignature/CodeResources",
    f"{helper}/Info.plist",
    f"{helper}/MacOS/ActivityLauncher",
    f"{helper}/_CodeSignature/CodeResources",
}
paths = list(app.rglob("*"))
if any(path.is_symlink() for path in paths):
    raise SystemExit("Community bundle must not contain symbolic links")
if {path.relative_to(app).as_posix() for path in paths if not path.is_dir()} != allowed:
    raise SystemExit("Unexpected file set in Community bundle")
CHECK_BUNDLE
codesign --verify --deep --strict --all-architectures "$unpacked"
lipo "$unpacked/Contents/MacOS/CodexActivity" -verify_arch arm64 x86_64
lipo "$unpacked/Contents/Library/LoginItems/ActivityLauncher.app/Contents/MacOS/ActivityLauncher" -verify_arch arm64 x86_64

(
    cd "$stage"
    shasum -a 256 "$archive" > SHA256SUMS.txt
    shasum -a 256 -c SHA256SUMS.txt
)
mv "$stage/$archive" "$stage/SHA256SUMS.txt" "$out/"
printf 'Archive: %s/%s\n' "$out" "$archive"
