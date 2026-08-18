"""Luau CLI smoke suite: run the pure helper checks with the luau runner."""

import subprocess
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from tools.ensure_luau import run_binary as luau_runner  # noqa: E402

SMOKE = REPO_ROOT / "tests" / "pickup_sort_smoke.luau"


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


if __name__ == "__main__":
    unittest.main()
