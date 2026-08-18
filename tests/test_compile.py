"""Compile every shipped Lua source with the official Luau compiler."""

import subprocess
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from tools.ensure_luau import compile_binary as luau_compile  # noqa: E402

SOURCES = [
    "loader.lua",
    "tools/loader.template.lua",
    "ui/InfinityUI.lua",
    "games/magicloot_common.lua",
    "games/magicloot_locomotion.lua",
    "games/magicloot.lua",
]


class CompileTests(unittest.TestCase):
    def test_shipped_sources_compile(self):
        compiler = luau_compile()
        for relative in SOURCES:
            source = REPO_ROOT / relative
            self.assertTrue(source.is_file(), f"missing {relative}")
            completed = subprocess.run(
                [str(compiler), "--binary", str(source)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
            )
            self.assertEqual(
                completed.returncode,
                0,
                f"{relative} failed to compile:\n{completed.stderr}",
            )

    def test_core_under_chunk_limit(self):
        for relative in ("games/magicloot.lua", "games/magicloot_locomotion.lua"):
            size = (REPO_ROOT / relative).stat().st_size
            self.assertLess(
                size,
                262144,
                f"{relative} is {size} bytes; keep it under the 262144 chunk limit",
            )


if __name__ == "__main__":
    unittest.main()
