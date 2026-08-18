"""Loader pin validation.

Rules:
  * InfinityUI, magicloot_common and magicloot_locomotion must be pinned to a
    full 40-character commit SHA (never /main/ or an abbreviated SHA).
  * The core script is served from main (the two-commit publish flow).
  * tests/fixtures/expected_pins.json must list the same SHAs so the pins are
    reviewed deliberately on every pin change.
  * With INFINITYGOLD_VERIFY_REMOTE=1 the pinned URLs are fetched and compared
    byte-by-byte against the local files (used after publishing).
"""

import json
import os
import re
import unittest
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
LOADER = REPO_ROOT / "loader.lua"
FIXTURE = REPO_ROOT / "tests" / "fixtures" / "expected_pins.json"

PINNED_FILES = {
    "UI": "ui/InfinityUI.lua",
    "COMMON": "games/magicloot_common.lua",
    "LOCOMOTION": "games/magicloot_locomotion.lua",
}

SHA_PATTERN = re.compile(
    r"raw\.githubusercontent\.com/InfinityControlR/InfinityGold/([0-9a-f]{40})/"
)


class LoaderPinTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not LOADER.is_file():
            raise unittest.SkipTest("loader.lua not published yet (commit 2)")
        cls.text = LOADER.read_text(encoding="utf-8")

    def extract_url(self, name):
        match = re.search(rf"local {name} = '([^']+)'", self.text)
        self.assertIsNotNone(match, f"loader does not define {name}")
        return match.group(1)

    def test_pinned_modules_use_full_shas(self):
        seen = {}
        for name in PINNED_FILES:
            url = self.extract_url(name)
            self.assertNotIn("/main/", url, f"{name} must be pinned to a commit")
            match = SHA_PATTERN.search(url)
            self.assertIsNotNone(
                match, f"{name} URL is not pinned with a full 40-char SHA"
            )
            seen[name] = match.group(1)
        fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))
        for name, sha in seen.items():
            self.assertEqual(
                fixture.get(name),
                sha,
                f"{name} pin does not match tests/fixtures/expected_pins.json",
            )

    def test_core_served_from_main(self):
        match = re.search(r"local BASE = '([^']+)'", self.text)
        self.assertIsNotNone(match, "loader does not define BASE")
        self.assertIn(
            "InfinityControlR/InfinityGold/main/", match.group(1)
        )
        self.assertNotIn("REPLACE_WITH", self.text)

    def test_remote_pins_match_published_files(self):
        if os.environ.get("INFINITYGOLD_VERIFY_REMOTE") != "1":
            raise unittest.SkipTest(
                "set INFINITYGOLD_VERIFY_REMOTE=1 after publishing to verify remote bytes"
            )
        fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))
        for name, relative in PINNED_FILES.items():
            sha = fixture[name]
            url = (
                f"https://raw.githubusercontent.com/InfinityControlR/InfinityGold/"
                f"{sha}/{relative}"
            )
            with urllib.request.urlopen(url, timeout=30) as response:
                remote = response.read()
            local = (REPO_ROOT / relative).read_bytes()
            self.assertEqual(
                remote,
                local,
                f"remote {relative}@{sha} differs from the local file",
            )


if __name__ == "__main__":
    unittest.main()
