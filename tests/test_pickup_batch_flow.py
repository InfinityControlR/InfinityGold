"""Executable checks for fast, priority-preserving loot collection."""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from tools.ensure_luau import run_binary as luau_runner  # noqa: E402


def core_slice(start: str, end: str) -> str:
    source = (REPO_ROOT / "games" / "magicloot.lua").read_text(encoding="utf-8")
    left = source.index(start)
    right = source.index(end, left)
    return source[left:right]


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


class PickupBatchFlowTests(unittest.TestCase):
    def test_every_allowed_drop_is_activated_in_priority_order(self):
        helper = core_slice(
            "    local function activateSortedDrops",
            "    local function collectDrops()",
        )
        fixture = f"""
local cfg = {{ PickupFilterItems = true }}
local Common = {{}}
function Common.gateDrop(entry, options)
    assert(options.minValue == 10)
    assert(options.filterItems == true)
    assert(options.itemIds[77] == true)
    return entry.allowed
end

local activated = {{}}
local function pickupPrompt(primaryPart)
    return primaryPart.prompt
end
local function activatePrompt(prompt)
    table.insert(activated, prompt.id)
    return prompt.succeeds ~= false
end

{helper}

-- collectDrops supplies Common.sortDrops output here: event first, then gold
-- descending.  A filtered entry must not prevent later valid drops.
local sorted = {{
    {{ allowed = true, primaryPart = {{ prompt = {{ id = "event" }} }} }},
    {{ allowed = true, primaryPart = {{ prompt = {{ id = "gold-100" }} }} }},
    {{ allowed = false, primaryPart = {{ prompt = {{ id = "filtered" }} }} }},
    {{ allowed = true, primaryPart = {{ prompt = {{ id = "failed", succeeds = false }} }} }},
    {{ allowed = true, primaryPart = {{ prompt = {{ id = "gold-20" }} }} }},
}}
local count = activateSortedDrops(sorted, 10, {{ [77] = true }})
assert(count == 3, "the scan stopped before activating every valid drop")
assert(table.concat(activated, ",") == "event,gold-100,failed,gold-20",
    "pickup priority/order changed: " .. table.concat(activated, ","))
print("pickup_batch_smoke=ok")
"""
        completed = run_luau(fixture)
        self.assertEqual(
            completed.returncode,
            0,
            f"pickup batch smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("pickup_batch_smoke=ok", completed.stdout)

    def test_scan_sorts_before_batch_and_uses_original_cadence(self):
        source = (REPO_ROOT / "games" / "magicloot.lua").read_text(encoding="utf-8")
        collect = core_slice("    local function collectDrops()", "    -- Progress workers")
        self.assertLess(
            collect.index("Common.sortDrops(candidates)"),
            collect.index("activateSortedDrops(sorted, minValue, selectedItemIds)"),
        )
        batch = core_slice(
            "    local function activateSortedDrops",
            "    local function collectDrops()",
        )
        self.assertNotIn("task.wait", batch)
        self.assertNotIn("return\n", batch.split("return activatedCount")[0])
        worker = collect[collect.index("task.spawn(function()") :]
        self.assertIn("task.wait(0.4)", worker)
        self.assertNotIn("task.wait(0.5)", worker)


if __name__ == "__main__":
    unittest.main()
