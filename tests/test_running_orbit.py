"""Execute the Magic-compatible Running contract under standalone Luau."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from tools.ensure_luau import run_binary as luau_runner  # noqa: E402

SMOKE = REPO_ROOT / "tests" / "running_orbit_smoke.luau"
MODULE = REPO_ROOT / "games" / "magicloot_locomotion.lua"


class RunningOrbitSmokeTests(unittest.TestCase):
    def test_running_orbits_on_entry_and_reads_distance_live(self) -> None:
        smoke = SMOKE.read_text(encoding="utf-8")
        source = MODULE.read_text(encoding="utf-8")
        require_line = (
            'local Locomotion = require("../games/magicloot_locomotion")'
        )
        self.assertEqual(smoke.count(require_line), 1)
        self.assertTrue(source.rstrip().endswith("return Module"))
        module_body = source.rstrip()[: -len("return Module")]
        fixture = smoke.replace(
            require_line,
            module_body + "\nlocal Locomotion = Module",
        )

        with tempfile.NamedTemporaryFile(
            "w", suffix=".luau", delete=False, encoding="utf-8", newline="\n"
        ) as handle:
            handle.write(fixture)
            path = Path(handle.name)
        try:
            completed = subprocess.run(
                [str(luau_runner()), str(path)],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                timeout=30,
            )
        finally:
            path.unlink(missing_ok=True)
        self.assertEqual(
            completed.returncode,
            0,
            f"Running orbit smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("running_orbit_smoke=ok", completed.stdout)


if __name__ == "__main__":
    unittest.main()
