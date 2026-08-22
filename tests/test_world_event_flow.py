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
            'player:FindFirstChild("事件通知")',
            'notices:FindFirstChild("Mysterious Event")',
            "Vector3.new(-452.6, 10.2, -137.2)",
            'candidate:FindFirstChild("InEventCombat")',
            'model:GetAttribute("EventBattleEnemy") ~= true',
            'model:GetAttribute("SpecialEnemyConfigId") ~= nil',
            'model:GetAttribute("SpecialEnemyStageId") ~= nil',
            'facility == "DragonNest"',
            'weather == "FireDragon" or weather == "DarkDragon"',
            "parts.humanoid:MoveTo(target)",
            "parts.humanoid:MoveTo(parts.root.Position)",
            'resetBasePriority("world event finished")',
        ):
            self.assertIn(marker, CORE)

        self.assertNotIn('model.Name == "FireDragon"', controller)
        self.assertNotIn('model.Name == "DarkDragon"', controller)
        self.assertNotIn("DUNGEON_RETURN_TOWN", controller)
        self.assertNotIn("root.CFrame =", controller)
        self.assertNotIn("eventDuration", controller)
        self.assertNotIn("eventEndsAt", controller)

    def test_cached_countdown_signals_never_own_objectives(self):
        availability = core_slice(
            "    function worldEvent:CurrentId()",
            "    local basePriority = {",
        )
        fixture = f"""
local currentId = 3
local combat = 0
local invitation = 0
local countdown = 750
local challenge = 0
local weatherConfig = false
local fakeClock = 0
local os = {{ clock = function() return fakeClock end }}
local function getgc()
    if weatherConfig then
        return {{{{ Facility = "DragonNest", Weather = "DarkDragon" }}}}
    end
    return {{{{ Facility = "SpecialEnemy", Weather = "Dark" }}}}
end
local cfg = {{ AutoWorldEvent = true }}
local Common = {{}}
function Common.dragonWorldEventId(value)
    value = tonumber(value)
    return (value == 3 or value == 4) and value or nil
end
local invitationValue = {{ Value = 0 }}
local notices = {{}}
function notices:FindFirstChild(name)
    assert(name == "Mysterious Event")
    invitationValue.Value = invitation
    return invitationValue
end
local player = {{}}
function player:FindFirstChild(name)
    assert(name == "事件通知")
    return notices
end
local timer = {{ Text = "12:30" }}
local weather = {{ FindFirstChild = function(_, name)
    assert(name == "Time")
    timer.Text = string.format("%02d:%02d", math.floor(countdown / 60), countdown % 60)
    return timer
end }}
local playerGui = {{ FindFirstChild = function(_, name, recursive)
    assert(name == "Buff_EventWeather" and recursive == true)
    return weather
end }}
function player:FindFirstChildOfClass(name)
    assert(name == "PlayerGui")
    return playerGui
end
local function playerNumber(name)
    if name == "curEventId" then return currentId end
    if name == "InEventCombat" then return combat end
    if name == "InDungeonChallenge" then return challenge end
    error("unexpected player value " .. tostring(name))
end
local worldEvent = {{
    phase = "idle",
    completedEventId = nil,
    weatherScanAt = 0,
    weatherActive = false,
}}

{availability}

local dragonTarget = false
local specialEvent = false
local bossActive = false
local participantActive = false
function worldEvent:FindTarget()
    return dragonTarget and {{}} or nil
end
function worldEvent:HasSpecialEnemyEvent()
    return specialEvent
end
function worldEvent:DragonBossUiActive()
    return bossActive
end
function worldEvent:ActiveParticipantPosition()
    return participantActive and {{ X = -452, Y = 10, Z = -140 }} or nil
end

assert(worldEvent:CurrentId() == 3)
assert(worldEvent:AvailableId() == nil)
assert(worldEvent:OwnsObjective() == false,
    "dragon ID during countdown paused normal objectives")

weatherConfig = true
fakeClock = 2
assert(worldEvent:DragonWeatherActive() == true)
assert(worldEvent:AvailableId() == nil)
assert(worldEvent:OwnsObjective() == false,
    "cached DragonNest config paused a 27-minute countdown")

countdown = 10
fakeClock = 4
assert(worldEvent:ShouldPrewait() == false)
assert(worldEvent:OwnsObjective() == false,
    "last ten seconds speculatively reserved an unknown event")

challenge = 28
assert(worldEvent:ShouldPrewait() == false)
assert(worldEvent:OwnsObjective() == false,
    "last ten seconds interrupted an active farm run")

challenge = 0
specialEvent = true
weatherConfig = false
fakeClock = 6
assert(worldEvent:ShouldPrewait() == false)
assert(worldEvent:OwnsObjective() == false,
    "SpecialEnemy event reserved the final ten seconds at base")

invitation = 1
assert(worldEvent:AvailableId() == nil,
    "shared Mysterious Event flag was mistaken for a dragon")
assert(worldEvent:OwnsObjective() == false,
    "non-dragon SpecialEnemy event interrupted active farming")

challenge = 0
assert(worldEvent:OwnsObjective() == false,
    "non-dragon SpecialEnemy event held the player at base")

specialEvent = false
weatherConfig = true
fakeClock = 8
dragonTarget = false
assert(worldEvent:DragonWeatherActive() == true)
assert(worldEvent:AvailableId() == nil,
    "cached config plus stale notice authorized movement")
assert(worldEvent:OwnsObjective() == false,
    "cached DragonNest state took over at base")

bossActive = true
assert(worldEvent:AvailableId() == 3)
assert(worldEvent:OwnsObjective() == true,
    "visible dragon Boss UI did not authorize takeover")
bossActive = false

participantActive = true
assert(worldEvent:AvailableId() == 3)
assert(worldEvent:OwnsObjective() == true,
    "active event participant did not authorize takeover")
participantActive = false

dragonTarget = true
assert(worldEvent:AvailableId() == 3)
assert(worldEvent:OwnsObjective() == true,
    "captured EventBattleEnemy did not authorize takeover at base")

challenge = 28
assert(worldEvent:OwnsObjective() == false,
    "dragon target forced an active farm run to return")

invitation = 0
dragonTarget = false
combat = 1
assert(worldEvent:OwnsObjective() == true,
    "confirmed InEventCombat did not retain event ownership")
print("world_event_countdown_gate_smoke=ok")
"""
        completed = run_luau(fixture)
        self.assertEqual(
            completed.returncode,
            0,
            f"World Event countdown smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("world_event_countdown_gate_smoke=ok", completed.stdout)
        self.assertIn("function worldEvent:ShouldPrewait()", CORE)
        self.assertIn("joining on the first live boss/participant signal", CORE)

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
local worldEvent = {{
    phase = "seeking",
    entryTarget = nil,
    fallbackEntry = Vector3.new(-452.6, 10.2, -137.2),
}}
function worldEvent:Sync() end
function worldEvent:OwnsObjective() return challenge <= 0 end

{movement}

assert(worldEvent:UpdateMovement() == true)
assert(humanoid.moveTo == worldEvent.fallbackEntry)
assert(stopped == 1)

worldEvent.phase = "combat"
humanoid.moveTo = nil
assert(worldEvent:UpdateMovement() == true)
assert(humanoid.moveTo == root.Position)
assert(humanoid.move == Vector3.zero)
assert(string.find(movementStatus, "attacking until server return", 1, true))

worldEvent.phase = "prewait"
humanoid.moveTo = nil
assert(worldEvent:UpdateMovement() == true)
assert(humanoid.moveTo == root.Position)
assert(string.find(movementStatus, "waiting for start", 1, true))

worldEvent.phase = "seeking"
challenge = 28
humanoid.moveTo = nil
assert(worldEvent:UpdateMovement() == false)
assert(humanoid.moveTo == nil)
print("world_event_movement_smoke=ok")
"""
        completed = run_luau(fixture)
        self.assertEqual(
            completed.returncode,
            0,
            f"World Event movement smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("world_event_movement_smoke=ok", completed.stdout)

    def test_event_attack_falls_back_when_target_value_is_unavailable(self):
        attack_helper = core_slice(
            "    local function attackTarget(target, allowUntargeted)",
            "    -- Auto Click combines",
        )
        fixture = f"""
local calls = 0
local attack = {{ slotIndex = 7, status = "ready" }}
local input = {{ simulateSlotPressRelease = function(slot, pressed)
    assert(slot == 7 and pressed == true)
    calls += 1
end }}
local function resolveAttack() return input end
local function setNowTarget() return false end
local target = {{}}

{attack_helper}

local ok, err = attackTarget(target, false)
assert(ok == false and err == "NowTargetCurrent unavailable")
assert(calls == 0)
ok, err = attackTarget(target, true)
assert(ok == true and err == nil)
assert(calls == 1,
    "event attack did not fall back to untargeted skill simulation")
print("world_event_attack_fallback_smoke=ok")
"""
        completed = run_luau(fixture)
        self.assertEqual(
            completed.returncode,
            0,
            f"World Event attack fallback failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("world_event_attack_fallback_smoke=ok", completed.stdout)

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
        self.assertIn(
            '"World Event: %s • id %s • timer %s • config %s • notice %d • boss %s • participant %s • dragon %s • special %s • combat %d"',
            CORE,
        )


if __name__ == "__main__":
    unittest.main()
