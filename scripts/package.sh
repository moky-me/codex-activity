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
codesign --verify --deep --strict --all-architectures "$unpacked"
lipo -verify_arch arm64 x86_64 "$unpacked/Contents/MacOS/CodexActivity"
lipo -verify_arch arm64 x86_64 "$unpacked/Contents/Library/LoginItems/ActivityLauncher.app/Contents/MacOS/ActivityLauncher"

(
    cd "$stage"
    shasum -a 256 "$archive" > SHA256SUMS.txt
    shasum -a 256 -c SHA256SUMS.txt
)
mv "$stage/$archive" "$stage/SHA256SUMS.txt" "$out/"
printf 'Archive: %s/%s\n' "$out" "$archive"
