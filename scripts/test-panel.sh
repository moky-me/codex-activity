#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product CodexActivity
binaries=$(swift build -c release --show-bin-path)
mkdir -p .build/panel-tests
sources=()
for file in Sources/ActivityPanel/*.swift; do
    if [[ "$file" != */main.swift ]]; then sources+=("$file"); fi
done
swiftc -swift-version 5 -parse-as-library -I "$binaries/Modules" -I Sources/CSQLite \
    "${sources[@]}" Sources/ActivityLauncher/Launcher.swift Tests/PanelRegressionTests.swift "$binaries/ActivityCore.build/"*.o \
    "$binaries/ActivityPanelStyle.build/"*.o \
    -o .build/panel-tests/regressions
.build/panel-tests/regressions
