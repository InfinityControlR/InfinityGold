"""Execute visible catalog-label normalization for translated dropdowns."""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from tools.ensure_luau import run_binary as luau_runner  # noqa: E402


def source_slice(relative: str, start: str, end: str) -> str:
    source = (REPO_ROOT / relative).read_text(encoding="utf-8")
    left = source.index(start)
    right = source.index(end, left)
    return source[left:right]


DISPLAY_HELPER = source_slice(
    "games/magicloot_common.lua",
    "function Common.catalogDisplayName",
    "-- Local-space offset for Running",
)
TRANSLATED_CONFIG_NAME = source_slice(
    "games/magicloot.lua",
    "    local function translatedConfigName",
    "    local function catalogByName",
)


def run_luau(source: str) -> subprocess.CompletedProcess:
    with tempfile.NamedTemporaryFile(
        "w", suffix=".luau", delete=False, encoding="utf-8", newline="\n"
    ) as handle:
        handle.write(source)
        path = Path(handle.name)
    try:
        return subprocess.run(
            [str(luau_runner()), str(path)],
            capture_output=True,
            text=True,
            timeout=30,
        )
    finally:
        path.unlink(missing_ok=True)


class CatalogLabelTests(unittest.TestCase):
    def test_training_ground_never_shows_legacy_or_cjk_labels(self):
        fixture = f"""
local Common = {{}}
{DISPLAY_HELPER}

local translations = {{}}
local translationHelper = {{
    TranslateByKey = function(key)
        return translations[key] or key
    end,
}}
local function resolveRuntimeModule(name)
    assert(name == "TranslationHelper")
    return translationHelper
end

{TRANSLATED_CONFIG_NAME}

local function visible(raw, id, prefix)
    local name = translatedConfigName(raw, id, prefix)
    return Common.catalogDisplayName(name, prefix, id)
end

local chinese = "训练场"
local fallback = visible({{ ZhName = chinese }}, 12, "Training ground")
assert(fallback == "Training ground 12", "CJK echo remained visible: " .. fallback)

translations[chinese] = "Crystal Training Ground"
local translated = visible({{ ZhName = chinese }}, 12, "Training ground")
assert(translated == "Crystal Training Ground", "valid translation was discarded")

translations[chinese] = chinese
local direct = visible(
    {{ Name = "Stone Training Ground" }},
    13,
    "Training ground"
)
assert(direct == "Stone Training Ground", "English direct name was discarded")

local legacy = visible({{ Name = "#14 Ember Ground" }}, 14, "Training ground")
assert(legacy == "Ember Ground", "legacy #ID remained visible: " .. legacy)
print("catalog_labels_smoke=ok")
"""
        completed = run_luau(fixture)
        self.assertEqual(
            completed.returncode,
            0,
            f"catalog label smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("catalog_labels_smoke=ok", completed.stdout)


if __name__ == "__main__":
    unittest.main()
