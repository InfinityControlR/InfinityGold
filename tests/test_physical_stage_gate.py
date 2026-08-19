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

    def test_stopping_running_cancels_the_existing_moveto(self):
        helper = core_slice(
            "    local function stopMovementModes()",
            "    -- Return episode",
        )
        fixture = f"""
local stopWalkingCalls = 0
local moveToCalls = 0
local moveCalls = 0
local rootPosition = {{ X = 10, Y = 3, Z = 20 }}
local root = {{ Position = rootPosition }}
local humanoid = {{}}
function humanoid:MoveTo(position)
    assert(position == rootPosition, "MoveTo was not cancelled at the current root")
    moveToCalls += 1
end
function humanoid:Move(direction, relative)
    assert(direction.X == 0 and direction.Y == 0 and direction.Z == 0)
    assert(relative == false)
    moveCalls += 1
end
local Vector3 = {{
    new = function(x, y, z) return {{ X = x, Y = y, Z = z }} end,
}}
local loco = {{
    StopWalking = function()
        stopWalkingCalls += 1
    end,
}}
local running = {{
    -- updateRunning can mark arrival before Roblox has fully discarded the
    -- last MoveTo.  The stored handles must still cancel that residual order.
    active = false,
    arrived = true,
    humanoid = humanoid,
    root = root,
    lastPosition = rootPosition,
    lastProgress = 12,
    retryUntil = 99,
}}

{helper}

stopMovementModes()
assert(stopWalkingCalls == 1)
assert(moveToCalls == 1 and moveCalls == 1, "residual MoveTo was not cancelled")
assert(running.active == false and running.arrived == false)
assert(running.humanoid == nil and running.root == nil)
assert(running.lastPosition == nil and running.lastProgress == 0)
assert(running.retryUntil == 0)

stopMovementModes()
assert(stopWalkingCalls == 2)
assert(moveToCalls == 1 and moveCalls == 1, "cleared Running was cancelled twice")
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
        self.assertLess(gate, movement.index('loco:Update("Walking"'))
        self.assertLess(gate, movement.index("updateRunning(stage"))
        self.assertIn("stageEntryWaiting", source)
        self.assertIn('setMovementStatus("stage " .. stage .. " waiting for dungeon entry")', movement)


if __name__ == "__main__":
    unittest.main()
