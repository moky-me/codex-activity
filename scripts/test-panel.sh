#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product CodexActivity
binaries=$(swift build -c release --show-bin-path)
mkdir -p .build/panel-tests
python3 - <<'PY'
from pathlib import Path
s=Path('Sources/ActivityPanel/main.swift').read_text()
Path('.build/panel-tests/AppDelegate.swift').write_text(s.split('\nlet app=NSApplication.shared')[0])
PY
swiftc -swift-version 5 -parse-as-library -I "$binaries/Modules" -I Sources/CSQLite \
  .build/panel-tests/AppDelegate.swift Sources/ActivityPanel/PanelModel.swift \
  Sources/ActivityPanel/PanelViews.swift Sources/ActivityPanel/PanelStyle.swift \
  Tests/PanelRegressionTests.swift "$binaries/ActivityCore.build/"*.o \
  -o .build/panel-tests/regressions
.build/panel-tests/regressions
