"""Runtime-state and integration regression tests for Auto World Event."""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from tools.ensure_luau import run_binary as luau_runner  # noqa: E402

CORE = (REPO_ROOT / "games" / "magicloot.lua").read_text(encoding="utf-8")
COMMON = (REPO_ROOT / "games" / "magicloot_common.lua").read_text(
    encoding="utf-8"
)
SMOKE = REPO_ROOT / "tests" / "world_event_flow_smoke.luau"


def core_slice(start: str, end: str) -> str:
    left = CORE.index(start)
    right = CORE.index(end, left)
    return CORE[left:right]


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


class WorldEventFlowTests(unittest.TestCase):
    def test_pure_transition_uses_server_combat_and_prevents_reentry(self):
        completed = subprocess.run(
            [str(luau_runner()), str(SMOKE)],
            capture_output=True,
            text=True,
            cwd=str(REPO_ROOT),
            timeout=30,
        )
        self.assertEqual(
            completed.returncode,
            0,
            f"World Event smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("world_event_flow_smoke=ok", completed.stdout)
        self.assertIn("function Common.dragonWorldEventId(value)", COMMON)
        self.assertIn("function Common.worldEventTransition(", COMMON)

    def test_capture_contract_is_generic_and_physically_enters_once(self):
        controller = core_slice("    local worldEvent = {", "    -- Return episode")
        for marker in (
            "AutoWorldEvent = false",
            'playerNumber("curEventId")',
            'playerNumber("InEventCombat")',
            "Vector3.new(-452.6, 10.2, -137.2)",
            'candidate:FindFirstChild("InEventCombat")',
            'model:GetAttribute("EventBattleEnemy") ~= true',
            'sendAction("DUNGEON_RETURN_TOWN")',
            "parts.humanoid:MoveTo(target)",
            "parts.humanoid:MoveTo(parts.root.Position)",
            'resetBasePriority("world event finished")',
        ):
            self.assertIn(marker, CORE)

        self.assertNotIn("FireDragon", controller)
        self.assertNotIn("DarkDragon", controller)
        self.assertNotIn("root.CFrame =", controller)
        self.assertNotIn("eventDuration", controller)
        self.assertNotIn("eventEndsAt", controller)

    def test_movement_walks_holds_and_returns_without_teleporting(self):
        movement = core_slice(
            "    function worldEvent:EntryPosition()",
            "    local function updateMovement()",
        )
        fixture = f"""
local Vector3 = {{ zero = {{ X = 0, Y = 0, Z = 0 }} }}
function Vector3.new(x, y, z) return {{ X = x, Y = y, Z = z }} end

local player = {{}}
local Players = {{ GetPlayers = function() return {{ player }} end }}
local workspace = {{ FindFirstChild = function() return nil end }}
local fakeClock = 2
local os = {{ clock = function() return fakeClock end }}
local challenge = 0
local sentActions = {{}}
local stopped = 0
local movementStatus = "idle"
local root = {{ Position = Vector3.new(1, 2, 3) }}
local humanoid = {{ moveTo = nil, move = nil }}
function humanoid:MoveTo(target) self.moveTo = target end
function humanoid:Move(direction) self.move = direction end

local function characterParts()
    return {{ root = root, humanoid = humanoid }}
end
local function stopMovementModes() stopped += 1 end
local function setMovementStatus(value) movementStatus = value end
local function playerNumber(name)
    assert(name == "InDungeonChallenge")
    return challenge
end
local function sendAction(name)
    table.insert(sentActions, name)
    return true
end

local worldEvent = {{
    phase = "seeking",
    entryTarget = nil,
    fallbackEntry = Vector3.new(-452.6, 10.2, -137.2),
    lastReturnAt = 0,
}}
function worldEvent:Sync() end
function worldEvent:OwnsObjective() return true end

{movement}

assert(worldEvent:UpdateMovement() == true)
assert(humanoid.moveTo == worldEvent.fallbackEntry)
assert(#sentActions == 0 and stopped == 1)

worldEvent.phase = "combat"
humanoid.moveTo = nil
assert(worldEvent:UpdateMovement() == true)
assert(humanoid.moveTo == root.Position)
assert(humanoid.move == Vector3.zero)
assert(string.find(movementStatus, "attacking until server return", 1, true))

worldEvent.phase = "seeking"
challenge = 28
humanoid.moveTo = nil
assert(worldEvent:UpdateMovement() == true)
assert(humanoid.moveTo == nil)
assert(#sentActions == 1 and sentActions[1] == "DUNGEON_RETURN_TOWN")
print("world_event_movement_smoke=ok")
"""
        completed = run_luau(fixture)
        self.assertEqual(
            completed.returncode,
            0,
            f"World Event movement smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("world_event_movement_smoke=ok", completed.stdout)

    def test_world_event_preempts_every_objective_without_changing_toggles(self):
        movement = core_slice("    local function updateMovement()", "    -- Combat")
        self.assertLess(
            movement.index("worldEvent:UpdateMovement()"),
            movement.index("local full = bagFull()"),
        )

        gates = core_slice("    local function broomEconomyGate()", "    local alchemyRecovery")
        self.assertEqual(gates.count("worldEvent:OwnsObjective()"), 2)
        self.assertIn("broom waiting for World Event", gates)
        self.assertIn("objective waiting for World Event", gates)

        alchemy_worker = core_slice("    task.spawn(function() -- alchemy", "    task.spawn(function() -- gear")
        self.assertIn("elseif worldEvent:OwnsObjective() then", alchemy_worker)
        self.assertIn("and not worldEvent:OwnsObjective()", alchemy_worker)

        combat = core_slice("    -- Combat workers", "    -- Pickup worker")
        self.assertIn("local eventCombat = cfg.AutoWorldEvent == true", combat)
        self.assertIn("eventCombat and worldEvent:FindTarget()", combat)
        self.assertIn("eventCombat or normalCombat", combat)

        pickup = core_slice("    -- Pickup worker", "    -- Progress workers")
        self.assertIn("if cfg.AutoPickup or eventCombat then", pickup)

        # The feature pauses existing choices; it never turns them off.
        event_toggle = core_slice(
            '        group:AddToggle("AutoWorldEvent"',
            "        local stageValues = {}",
        )
        for name in ("AutoFarm", "AutoFarmSpecific", "AutoTrain", "AutoBroom"):
            self.assertNotIn(f'setRegisteredToggle("{name}"', event_toggle)

    def test_ui_exposes_event_state(self):
        self.assertIn('group:AddToggle("AutoWorldEvent"', CORE)
        self.assertIn('Text = "Auto World Event"', CORE)
        self.assertIn('"World Event: %s • id %s • combat %d"', CORE)


if __name__ == "__main__":
    unittest.main()
