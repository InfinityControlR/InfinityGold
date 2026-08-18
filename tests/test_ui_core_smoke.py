"""Offline construction smoke test for the dashboard and core script.

The plain Luau CLI isolates the global environment per required module, so
this test concatenates the Roblox API stubs (tests/ui_core_smoke.luau) with
the real module sources into a single chunk and executes it. Any
construction-time error in InfinityUI or the core script surfaces with a
full stack trace instead of failing silently inside Roblox.
"""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from tools.ensure_luau import run_binary as luau_runner  # noqa: E402

HARNESS = REPO_ROOT / "tests" / "ui_core_smoke.luau"
MARKER = "-- @@INJECT_MODULES@@"

MODULES = [
    ("Library", "ui/InfinityUI.lua"),
    ("Common", "games/magicloot_common.lua"),
    ("LocomotionFactory", "games/magicloot_locomotion.lua"),
    ("core", "games/magicloot.lua"),
]


def build_chunk() -> str:
    harness = HARNESS.read_text(encoding="utf-8")
    if MARKER not in harness:
        raise RuntimeError("ui_core_smoke.luau is missing the injection marker")
    injections = []
    for name, relative in MODULES:
        source = (REPO_ROOT / relative).read_text(encoding="utf-8")
        injections.append(f"local {name} = (function()\n{source}\nend)()")
    return harness.replace(MARKER, "\n".join(injections))


class UiCoreSmokeTests(unittest.TestCase):
    def test_dashboard_and_core_construct(self):
        runner = luau_runner()
        with tempfile.NamedTemporaryFile(
            "w", suffix=".luau", delete=False, encoding="utf-8", newline="\n"
        ) as handle:
            handle.write(build_chunk())
            path = handle.name
        try:
            completed = subprocess.run(
                [str(runner), path],
                capture_output=True,
                text=True,
                timeout=60,
            )
        finally:
            Path(path).unlink(missing_ok=True)
        self.assertEqual(
            completed.returncode,
            0,
            f"construction smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("ui_core_smoke: all checks passed", completed.stdout)


if __name__ == "__main__":
    unittest.main()
