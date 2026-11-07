#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-}" in
    "") universal=false ;;
    --universal) universal=true ;;
    *) printf 'Usage: %s [--universal]\n' "$0" >&2; exit 2 ;;
esac

panel_id=io.github.moky-me.CodexActivity
helper_id="$panel_id.Launcher"
build_dir="$PWD/build"
output="$build_dir/Codex Activity Community.app"
mkdir -p "$build_dir"
stage=$(mktemp -d "${TMPDIR:-/tmp}/codex-activity-build.XXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/Codex Activity Community.app"
helper="$app/Contents/Library/LoginItems/ActivityLauncher.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$helper/Contents/MacOS"

build_binaries() {
    local options=("$@")
    swift build -c release "${options[@]}" --product CodexActivity >&2
    swift build -c release "${options[@]}" --product ActivityLauncher >&2
    swift build -c release "${options[@]}" --show-bin-path
}

if "$universal"; then
    arm=$(build_binaries --triple arm64-apple-macosx14.0)
    intel=$(build_binaries --triple x86_64-apple-macosx14.0)
    lipo -create "$arm/CodexActivity" "$intel/CodexActivity" -output "$app/Contents/MacOS/CodexActivity"
    lipo -create "$arm/ActivityLauncher" "$intel/ActivityLauncher" -output "$helper/Contents/MacOS/ActivityLauncher"
else
    binaries=$(build_binaries --triple "$(uname -m)-apple-macosx14.0")
    cp "$binaries/CodexActivity" "$app/Contents/MacOS/CodexActivity"
    cp "$binaries/ActivityLauncher" "$helper/Contents/MacOS/ActivityLauncher"
fi

python3 - "$app" "$helper" "$panel_id" "$helper_id" <<'PY'
import json
import pathlib
import plistlib
import re
import sys

metadata = json.loads(pathlib.Path("version.json").read_text())
version, build = metadata["version"], metadata["build"]
if not isinstance(version, str) or not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
    raise SystemExit("version.json: version must be MAJOR.MINOR.PATCH")
if type(build) is not int or build < 1:
    raise SystemExit("version.json: build must be a positive integer")

app, helper, panel_id, helper_id = sys.argv[1:]
for path, identifier, name, executable in (
    (app, panel_id, "Codex Activity Community", "CodexActivity"),
    (helper, helper_id, "Codex Activity Community Launcher", "ActivityLauncher"),
):
    info = dict(
        CFBundleIdentifier=identifier, CFBundleName=name, CFBundleDisplayName=name,
        CFBundleExecutable=executable, CFBundlePackageType="APPL", CFBundleVersion=str(build),
        CFBundleShortVersionString=version, LSMinimumSystemVersion="14.0", LSUIElement=True,
        NSHighResolutionCapable=True, NSPrincipalClass="NSApplication",
    )
    if path == app:
        info["CFBundleIconFile"] = "Activity"
    (pathlib.Path(path) / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
PY

swift scripts/icon.swift "$stage"
iconutil -c icns "$stage/Activity.iconset" -o "$app/Contents/Resources/Activity.icns"
# File Provider can attach FinderInfo. Only this packaging metadata is removed.
xattr -dr com.apple.FinderInfo "$app" 2>/dev/null || true
codesign --force --sign - --identifier "$helper_id" -r="designated => identifier \"$helper_id\"" "$helper"
codesign --force --sign - --identifier "$panel_id" -r="designated => identifier \"$panel_id\"" "$app"
codesign --verify --deep --strict "$app"
# Replace the generated bundle as a unit. Keep the previous output if publication fails.
previous="$stage/previous.app"
if [[ -e "$output" ]]; then mv "$output" "$previous"; fi
if ! mv "$app" "$output" || ! codesign --verify --deep --strict "$output"; then
    if [[ -e "$output" ]]; then mv "$output" "$stage/rejected.app"; fi
    if [[ -e "$previous" ]]; then mv "$previous" "$output"; fi
    exit 1
fi
printf 'Built: %s\n' "$output"
