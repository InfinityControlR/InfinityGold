"""Luau CLI smoke suite: run the pure helper checks with the luau runner."""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from tools.ensure_luau import run_binary as luau_runner  # noqa: E402

SMOKE = REPO_ROOT / "tests" / "pickup_sort_smoke.luau"
WAND_SMOKE = REPO_ROOT / "tests" / "wand_selected_smoke.luau"


class SmokeTests(unittest.TestCase):
    def test_pickup_sort_smoke(self):
        self.assertTrue(SMOKE.is_file(), "missing tests/pickup_sort_smoke.luau")
        runner = luau_runner()
        completed = subprocess.run(
            [str(runner), str(SMOKE)],
            capture_output=True,
            text=True,
            cwd=str(REPO_ROOT),
        )
        self.assertEqual(
            completed.returncode,
            0,
            f"smoke suite failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("all pickup_sort_smoke checks passed", completed.stdout)

    def test_selected_wand_smoke(self):
        self.assertTrue(WAND_SMOKE.is_file(), "missing selected Wand smoke")
        smoke = WAND_SMOKE.read_text(encoding="utf-8")
        module = (REPO_ROOT / "games" / "magicloot_locomotion.lua").read_text(
            encoding="utf-8"
        )
        require_line = 'local Locomotion = require("../games/magicloot_locomotion")'
        module_body = module.rstrip()[: -len("return Module")]
        fixture = smoke.replace(
            require_line,
            module_body + "\nlocal Locomotion = Module",
        )
        runner = luau_runner()
        with tempfile.NamedTemporaryFile(
            "w", suffix=".luau", delete=False, encoding="utf-8", newline="\n"
        ) as handle:
            handle.write(fixture)
            path = Path(handle.name)
        try:
            completed = subprocess.run(
                [str(runner), str(path)],
                capture_output=True,
                text=True,
                cwd=str(REPO_ROOT),
            )
        finally:
            path.unlink(missing_ok=True)
        self.assertEqual(
            completed.returncode,
            0,
            f"selected Wand smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("wand_selected_smoke=ok", completed.stdout)


if __name__ == "__main__":
    unittest.main()
