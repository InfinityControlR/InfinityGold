"""Executable regression checks for Walking/Running stage-entry gating.

Stage geometry remains loaded while the player is at base.  Physical farm
modes must therefore use InDungeonChallenge as their entry gate instead of
treating a cached stage part as proof that the player is already there.
"""

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


class PhysicalStageGateTests(unittest.TestCase):
    def test_physical_modes_wait_at_base_for_non_first_stage(self):
        helper = core_slice(
            "    local function shouldWaitForPhysicalStage",
            "    local function blocksAttack",
        )
        fixture = f"""
{helper}

assert(shouldWaitForPhysicalStage("Walking", 4, 0) == true)
assert(shouldWaitForPhysicalStage("Running", 4, nil) == true)
assert(shouldWaitForPhysicalStage("Running", "4", "0") == true)
assert(shouldWaitForPhysicalStage("Walking", 4, 1) == false)
assert(shouldWaitForPhysicalStage("Running", 4, 7) == false)
assert(shouldWaitForPhysicalStage("Running", 1, 0) == false)
assert(shouldWaitForPhysicalStage("Walking", 1, nil) == false)
assert(shouldWaitForPhysicalStage("Ground", 4, 0) == false)
assert(shouldWaitForPhysicalStage("Above", 4, nil) == false)
print("physical_stage_gate_smoke=ok")
"""
        completed = run_luau(fixture)
        self.assertEqual(
            completed.returncode,
            0,
            f"stage gate smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("physical_stage_gate_smoke=ok", completed.stdout)

    def test_stopping_physical_mode_delegates_to_locomotion_module(self):
        helper = core_slice(
            "    local function stopMovementModes()",
            "    -- Return episode",
        )
        fixture = f"""
local stopWalkingCalls = 0
local loco = {{
    StopWalking = function()
        stopWalkingCalls += 1
    end,
}}

{helper}

stopMovementModes()
assert(stopWalkingCalls == 1)
stopMovementModes()
assert(stopWalkingCalls == 2)
print("running_stop_smoke=ok")
"""
        completed = run_luau(fixture)
        self.assertEqual(
            completed.returncode,
            0,
            f"running stop smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("running_stop_smoke=ok", completed.stdout)

    def test_gate_precedes_stage_geometry_and_both_physical_dispatches(self):
        source = (REPO_ROOT / "games" / "magicloot.lua").read_text(encoding="utf-8")
        movement = core_slice("    local function updateMovement()", "    -- Combat")
        gate = movement.index("if shouldWaitForPhysicalStage(mode, stage, challenge) then")
        self.assertLess(gate, movement.index("local stagePartInstance = stagePart(stage)"))
        self.assertLess(gate, movement.index("return loco:Update("))
        self.assertIn('setMovementStatus("stage " .. stage .. " waiting for dungeon entry")', movement)

    def test_waiting_at_base_does_not_block_background_autoclick(self):
        helper = core_slice(
            "    local function blocksPhysicalTransit()",
            "    local function stopMovementModes()",
        )
        fixture = f"""
local cfg = {{
    AutoFarm = true,
    AutoFarmSpecific = false,
    FarmMode = "Running",
}}
local locomotionBlocked = false
local loco = {{ BlocksAttack = function() return locomotionBlocked end }}
local stageEntryWaiting = true

{helper}

-- This is the base-wait state: physical movement is stopped, but power clicks
-- must remain available in the background. AutoAttack keeps the broader gate.
assert(blocksPhysicalTransit() == false, "base waiting incorrectly blocked AutoClick")
assert(blocksAttack() == true, "base waiting did not block AutoAttack")

locomotionBlocked = true
assert(blocksPhysicalTransit() == true, "active Running did not block AutoClick")
assert(blocksAttack() == true, "active Running did not block AutoAttack")
locomotionBlocked = false
stageEntryWaiting = false
assert(blocksPhysicalTransit() == false, "arrived Running kept AutoClick blocked")
assert(blocksAttack() == false, "arrived Running kept AutoAttack blocked")

cfg.FarmMode = "Walking"
loco.BlocksAttack = function() return true end
assert(blocksPhysicalTransit() == true, "Walking entry gate was bypassed")
assert(blocksAttack() == true, "Walking did not block AutoAttack")
loco.BlocksAttack = function() return false end
assert(blocksPhysicalTransit() == false, "entered Walking stage kept AutoClick blocked")
assert(blocksAttack() == false, "entered Walking stage kept AutoAttack blocked")
print("base_autoclick_gate_smoke=ok")
"""
        completed = run_luau(fixture)
        self.assertEqual(
            completed.returncode,
            0,
            f"base AutoClick smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("base_autoclick_gate_smoke=ok", completed.stdout)

        source = (REPO_ROOT / "games" / "magicloot.lua").read_text(encoding="utf-8")
        combat = core_slice("    -- Combat workers", "    -- Pickup worker")
        autoattack = combat[: combat.index("task.wait(0.2)")]
        autoclick = combat[combat.index("task.wait(0.2)") :]
        self.assertIn("not blocksAttack()", autoattack)
        self.assertIn("not blocksPhysicalTransit()", autoclick)
        self.assertNotIn("not blocksAttack()", autoclick)


if __name__ == "__main__":
    unittest.main()
