"""Executable regression checks for Magic-compatible physical stage entry."""

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
    def test_broom_entry_bypasses_teleport_enter_delay_continuously(self):
        helper = core_slice(
            "    local enterDelay = {",
            "    local function nearestMonsterPosition",
        )
        fixture = f"""
local fakeClock = 0
local os = {{ clock = function() return fakeClock end }}
local cfg = {{ EnterDelay = 30 }}
local movementStatus = "idle"
local function setMovementStatus(text) movementStatus = text end

{helper}

assert(applyEnterDelay(28, false) == false,
    "normal route did not preserve Enter Delay")
assert(string.find(movementStatus, "entering stage 28", 1, true) ~= nil)
assert(applyEnterDelay(28, true) == true,
    "confirmed Broom route did not bypass Enter Delay")
fakeClock = 10
assert(applyEnterDelay(28, true) == true,
    "Broom route reapplied a pause instead of staying continuous")
print("broom_teleport_fast_start_smoke=ok")
"""
        completed = run_luau(fixture)
        self.assertEqual(
            completed.returncode,
            0,
            f"Broom teleport fast-start smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("broom_teleport_fast_start_smoke=ok", completed.stdout)

    def test_physical_modes_dispatch_without_waiting_for_dungeon_state(self):
        movement = core_slice("    local function updateMovement()", "    -- Combat")
        self.assertNotIn("shouldWaitForPhysicalStage", movement)
        self.assertNotIn("waiting for dungeon entry", movement)
        self.assertNotIn('playerNumber("InDungeonChallenge")', movement)
        self.assertLess(
            movement.index("local stagePartInstance = stagePart(stage)"),
            movement.index("return loco:Update("),
        )
        self.assertIn("Common.broomFarmStageTarget(", movement)
        self.assertIn("if releaseBroomRoute then", movement)
        self.assertIn("broomFarmRoute.stage = nil", movement)
        self.assertIn("broomFarmRoute.bypassEnterDelay = false", movement)
        self.assertLess(
            movement.index("if releaseBroomRoute then"),
            movement.index("local stagePartInstance = stagePart(stage)"),
        )
        self.assertIn("bypassEnterDelay", movement)
        self.assertIn("groundPoint(stagePartInstance),\n                    bypassEnterDelay", movement)
        self.assertEqual(
            movement.count("applyEnterDelay(stage, bypassEnterDelay)"),
            3,
        )
        bridge = core_slice("    -- Locomotion bridge", "    local lastFarmMode")
        self.assertIn("onBroomStageEntered = function(stage)", bridge)

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

    def test_locomotion_itself_owns_the_attack_block(self):
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
{helper}

assert(blocksPhysicalTransit() == false)
assert(blocksAttack() == false)

locomotionBlocked = true
assert(blocksPhysicalTransit() == true)
assert(blocksAttack() == true)
locomotionBlocked = false
assert(blocksPhysicalTransit() == false)
assert(blocksAttack() == false)

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
