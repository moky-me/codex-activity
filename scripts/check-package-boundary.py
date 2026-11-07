"""Check the SwiftPM graph before building a Community package."""

import json
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parent.parent
PUBLIC_PRODUCTS = {
    "CodexActivity": ["ActivityPanel"],
    "ActivityLauncher": ["ActivityLauncher"],
    "ActivityDiagnostics": ["ActivityDiagnostics"],
    "ActivityCoreTests": ["ActivityCoreTests"],
}
PUBLIC_TARGETS = {
    "CSQLite": ("system", "Sources/CSQLite", []),
    "ActivityCore": ("regular", "Sources/ActivityCore", ["CSQLite"]),
    "ActivityPanelStyle": ("regular", "Sources/ActivityPanelStyle", ["ActivityCore"]),
    "ActivityPanel": ("executable", "Sources/ActivityPanel", ["ActivityCore", "ActivityPanelStyle"]),
    "ActivityLauncher": ("executable", "Sources/ActivityLauncher", ["ActivityCore"]),
    "ActivityDiagnostics": ("executable", "Sources/ActivityDiagnostics", ["ActivityCore"]),
    "ActivityCoreTests": ("executable", "Tests/ActivityCoreTests", ["ActivityCore"]),
}
INTEGRATION_IMPORT = re.compile(r"\bimport[ \t]+(?:\w+[ \t]+)?(?:Telegram|TDLib)\w*\b", re.IGNORECASE)


def target_entry(target):
    name = target["name"]
    dependencies = []
    for dependency in target["dependencies"]:
        local_edge = dependency.get("target", dependency.get("byName"))
        if local_edge is None or local_edge[1:] != [None]:
            raise SystemExit(f"Community target {name} must use unconditional local target dependencies")
        dependencies.append(local_edge[0])
    return target["type"], target.get("path") or f"Sources/{name}", sorted(dependencies)


def main():
    manifest = json.loads(subprocess.check_output(["swift", "package", "dump-package"], cwd=ROOT))
    if manifest["dependencies"]:
        raise SystemExit("Community must not depend on another Swift package")
    if {item["name"]: item["targets"] for item in manifest["products"]} != PUBLIC_PRODUCTS:
        raise SystemExit("Unexpected products in the Community Swift package")
    if {item["name"]: target_entry(item) for item in manifest["targets"]} != PUBLIC_TARGETS:
        raise SystemExit("Unexpected targets, paths or dependency edges in the Community Swift package")
    for directory in (ROOT / "Sources", ROOT / "Tests"):
        for source in directory.rglob("*.swift"):
            if INTEGRATION_IMPORT.search(source.read_text(encoding="utf-8")):
                raise SystemExit(f"Telegram or TDLib import in {source.relative_to(ROOT)}")
    print("Community Swift package boundary verified")


if __name__ == "__main__":
    main()
