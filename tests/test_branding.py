"""Branding guards: the shipped sources must be original InfinityGold work.

Blocks any accidental reintroduction of third-party names, original upstream
repositories or foreign UI libraries in the shipped Lua sources.
"""

import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

SOURCES = [
    "ui/InfinityUI.lua",
    "games/magicloot_common.lua",
    "games/magicloot_locomotion.lua",
    "games/magicloot.lua",
    "loader.lua",
]

BANNED_FRAGMENTS = [
    "Ouroboros",
    "ourob",
    "joustingmatch",
    "Obsidian",
    "InfinityControlR/Magic",
    "MagicLootWalkingControl",
]


class BrandingTests(unittest.TestCase):
    def test_sources_exist(self):
        for relative in SOURCES:
            if relative == "loader.lua" and not (REPO_ROOT / relative).is_file():
                continue  # loader lands in the second publish commit
            self.assertTrue((REPO_ROOT / relative).is_file(), f"missing {relative}")

    def test_no_third_party_fragments(self):
        for relative in SOURCES:
            path = REPO_ROOT / relative
            if not path.is_file():
                continue
            text = path.read_text(encoding="utf-8")
            for fragment in BANNED_FRAGMENTS:
                self.assertNotIn(
                    fragment,
                    text,
                    f"{relative} references third-party fragment {fragment!r}",
                )

    def test_brand_markers_present(self):
        expectations = {
            "ui/InfinityUI.lua": "INFINITYGOLD",
            "games/magicloot.lua": "InfinityGold",
            "games/magicloot_locomotion.lua": "InfinityGold",
            "games/magicloot_common.lua": "InfinityGold",
        }
        for relative, marker in expectations.items():
            text = (REPO_ROOT / relative).read_text(encoding="utf-8")
            self.assertIn(marker, text, f"{relative} lost its {marker} branding")


if __name__ == "__main__":
    unittest.main()
