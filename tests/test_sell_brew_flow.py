"""Executable regressions for base-only AutoSell and brew-before-sell order."""

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


SELL_COORDINATION = core_slice(
    "    local function autoSellBaseGate()",
    "    -- Attack -----------------------------------------------------------------",
)
ALCHEMY_WORKER = core_slice(
    "    task.spawn(function() -- alchemy",
    "    task.spawn(function() -- gear",
)


class SellBrewFlowTests(unittest.TestCase):
    def test_pending_auto_sell_does_not_freeze_fast_alchemy_polling(self):
        fixture = f"""
local sessionAlive = true
local configReady = true
local cfg = {{
    AutoBrew = true,
    AutoPickupPotion = false,
    AutoSell = true,
}}
local alchemyTelemetry = {{ confirmedAction = nil }}
local sellTelemetry = {{ status = "waiting", lastError = nil }}
local fakeClock = 0
local os = {{ clock = function() return fakeClock end }}
local alchemyRuns = 0
local sellActions = {{}}
local firstQueuedSell = nil
local secondQueuedSell = nil
local spawnCalls = 0
local function playerNumber(_name)
    if fakeClock == 1.5 then return nil end
    return 0
end
local function observeAlchemyLocation(_challenge) end
local function resetAlchemyRecovery() end
local function runAlchemyCycle()
    alchemyRuns += 1
    alchemyTelemetry.confirmedAction = alchemyRuns == 3 and "brew" or nil
end
local function runAutoSellCycle(confirmedAction)
    table.insert(sellActions, confirmedAction or "ordinary")
end
local task = {{}}
task.spawn = function(callback)
    spawnCalls += 1
    if spawnCalls == 1 then
        callback()
    elseif spawnCalls == 2 then
        assert(firstQueuedSell == nil)
        firstQueuedSell = callback
    elseif spawnCalls == 3 then
        assert(secondQueuedSell == nil)
        secondQueuedSell = callback
    else
        error("duplicate AutoSell task escaped single flight")
    end
end
task.wait = function(seconds)
    assert(seconds == 0.5)
    fakeClock += seconds
    if fakeClock == 1.5 then
        assert(type(firstQueuedSell) == "function")
        firstQueuedSell()
        firstQueuedSell = nil
    end
    if fakeClock >= 2.5 then sessionAlive = false end
end

{ALCHEMY_WORKER}

assert(alchemyRuns == 5,
    "a pending SELL_MATERIAL task froze subsequent Alchemy polling")
assert(spawnCalls == 3
    and #sellActions == 1
    and sellActions[1] == "ordinary"
    and type(secondQueuedSell) == "function",
    "AutoSell did not remain a single detached request")
secondQueuedSell()
assert(#sellActions == 2 and sellActions[2] == "brew",
    "a craft confirmation was lost while the previous sell was pending")
print("pending_auto_sell_smoke=ok")
"""
        completed = run_luau(fixture)
        self.assertEqual(
            completed.returncode,
            0,
            f"pending AutoSell smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("pending_auto_sell_smoke=ok", completed.stdout)

    def test_worker_tracks_stage_inventory_while_alchemy_is_disabled(self):
        fixture = f"""
local sessionAlive = true
local configReady = true
local cfg = {{
    AutoBrew = false,
    AutoPickupPotion = false,
    AutoSell = false,
}}
local alchemyTelemetry = {{ confirmedAction = nil }}
local fakeClock = 0
local os = {{ clock = function() return fakeClock end }}
local inventoryEpoch = 0
local stageActive = false
local recoveryResets = 0
local function playerNumber(_name)
    if fakeClock >= 0.5 and fakeClock < 1.5 then return 4 end
    return 0
end
local function observeAlchemyLocation(challenge)
    if challenge > 0 then
        if not stageActive then
            inventoryEpoch += 1
            stageActive = true
        end
    else
        stageActive = false
    end
end
local function resetAlchemyRecovery() recoveryResets += 1 end
local function runAlchemyCycle()
    error("disabled Alchemy unexpectedly ran")
end
local function runAutoSellCycle(_confirmedAction) end
local task = {{}}
task.spawn = function(callback) callback() end
task.wait = function(seconds)
    assert(seconds == 0.5)
    fakeClock += seconds
    if fakeClock >= 2 then sessionAlive = false end
end

{ALCHEMY_WORKER}

assert(inventoryEpoch == 1 and recoveryResets == 2,
    "disabled Alchemy missed or duplicated the dungeon inventory epoch")
print("disabled_alchemy_inventory_epoch_smoke=ok")
"""
        completed = run_luau(fixture)
        self.assertEqual(
            completed.returncode,
            0,
            f"disabled Alchemy epoch smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("disabled_alchemy_inventory_epoch_smoke=ok", completed.stdout)

    def test_fast_alchemy_poll_preserves_two_second_auto_sell_cadence(self):
        fixture = f"""
local sessionAlive = true
local configReady = true
local cfg = {{
    AutoBrew = true,
    AutoPickupPotion = false,
    AutoSell = true,
}}
local alchemyTelemetry = {{ confirmedAction = nil }}
local fakeClock = 0
local os = {{ clock = function() return fakeClock end }}
local alchemyRuns = 0
local sellTimes = {{}}
local locationObservations = 0
local function playerNumber(name)
    assert(name == "InDungeonChallenge")
    return 0
end
local function observeAlchemyLocation(challenge)
    assert(challenge == 0)
    locationObservations += 1
end
local function resetAlchemyRecovery()
    error("base observation unexpectedly reset Alchemy recovery")
end
local function runAlchemyCycle()
    alchemyRuns += 1
    alchemyTelemetry.confirmedAction = nil
end
local function runAutoSellCycle(_confirmedAction)
    table.insert(sellTimes, fakeClock)
end
local task = {{}}
task.spawn = function(callback) callback() end
task.wait = function(seconds)
    assert(seconds == 0.5, "Alchemy worker lost its fast poll cadence")
    fakeClock += seconds
    if fakeClock >= 2.5 then sessionAlive = false end
end

{ALCHEMY_WORKER}

assert(alchemyRuns == 5,
    "Alchemy was not checked immediately and every half second")
assert(locationObservations == 5,
    "inventory epoch was not observed on every worker tick")
assert(#sellTimes == 2 and sellTimes[1] == 0 and sellTimes[2] == 2,
    "fast Alchemy polling accelerated AutoSell below two seconds")
print("fast_alchemy_worker_smoke=ok")
"""
        completed = run_luau(fixture)
        self.assertEqual(
            completed.returncode,
            0,
            f"fast Alchemy worker smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("fast_alchemy_worker_smoke=ok", completed.stdout)

    def test_auto_sell_is_base_only_and_waits_for_a_confirmed_brew(self):
        fixture = f"""
local configReady = false
local sessionAlive = true
local cfg = {{ AutoSell = true, AutoBrew = false }}
local challenge = 0
local alchemyAvailable = true
local inProgress = false
local progressError = nil
local progressReadHook = function() end
local sellMode = "success"
local scanHook = function() end
local scans = 0
local sales = 0
local alchemy = {{}}
local sellTelemetry = {{
    status = "waiting",
    challenge = nil,
    brewInProgress = nil,
    authorization = nil,
    attempts = 0,
    requests = 0,
    requestedItems = 0,
    lastCount = 0,
    lastError = nil,
}}

local function playerNumber(name)
    assert(name == "InDungeonChallenge", "AutoSell read the wrong player state")
    return challenge
end
local function resolveAlchemy()
    if not alchemyAvailable then return nil, "Alchemy unavailable" end
    return alchemy
end
local function alchemyState(actualAlchemy, methodName)
    assert(actualAlchemy == alchemy, "AutoSell used the wrong Alchemy module")
    assert(methodName == "IsBrewInProgress", "AutoSell used the wrong brew gate")
    if progressError ~= nil then return nil, progressError end
    progressReadHook()
    return inProgress
end
local function sellAllMaterials(beforeSend)
    scans += 1
    scanHook()
    if type(beforeSend) == "function" then
        local allowed, guardError = beforeSend()
        if not allowed then return false, 0, guardError end
    end
    if sellMode == "empty" then return false, 0, "nothing to sell" end
    if sellMode == "failure" then return false, 2, "fixture failure" end
    sales += 1
    return true, 3
end

{SELL_COORDINATION}

local sold = runAutoSellCycle(nil)
assert(sold == false and scans == 0 and sellTelemetry.status == "waiting for config",
    "AutoSell ran before config restoration finished")

configReady = true
cfg.AutoSell = false
sold = runAutoSellCycle("brew")
assert(sold == false and scans == 0 and sellTelemetry.status == "disabled",
    "a craft confirmation bypassed the AutoSell toggle")
cfg.AutoSell = true

challenge = nil
sold = runAutoSellCycle("brew")
assert(sold == false and scans == 0
    and sellTelemetry.status == "waiting for dungeon state",
    "unknown dungeon state was guessed to be base")
challenge = 4
sold = runAutoSellCycle("brew")
assert(sold == false and scans == 0 and sellTelemetry.status == "waiting for base",
    "AutoSell scanned or sold inside a stage")

challenge = 0
cfg.AutoBrew = false
sold = runAutoSellCycle(nil)
assert(sold == true and scans == 1 and sales == 1,
    "base AutoSell was blocked while AutoBrew was disabled")

cfg.AutoBrew = true
alchemyAvailable = false
sold = runAutoSellCycle(nil)
assert(sold == false and scans == 1 and sellTelemetry.status == "waiting for Alchemy",
    "missing Alchemy failed open and sold recipe materials")
alchemyAvailable = true

progressError = "state loading"
sold = runAutoSellCycle(nil)
assert(sold == false and scans == 1
    and sellTelemetry.status == "waiting for brew state",
    "unknown brew state failed open")
progressError = nil
inProgress = false
sold = runAutoSellCycle(nil)
assert(sold == false and scans == 1
    and sellTelemetry.status == "waiting for confirmed brew",
    "AutoSell ran before a potion started")

inProgress = true
sold = runAutoSellCycle(nil)
assert(sold == true and scans == 2 and sales == 2,
    "an already brewing potion did not unlock AutoSell")

-- A newly confirmed craft may have moved directly to ready without a visible
-- in-progress sample. Its typed, current-cycle permission is still valid once.
inProgress = false
sold = runAutoSellCycle("brew")
assert(sold == true and scans == 3 and sales == 3,
    "a newly confirmed instant craft did not unlock AutoSell")
inProgress = false
sold = runAutoSellCycle("pickup")
assert(sold == false and scans == 3
    and sellTelemetry.status == "waiting for next brew",
    "a pickup confirmation was confused with a new craft")
inProgress = true
sold = runAutoSellCycle("pickup")
assert(sold == true and scans == 4 and sales == 4,
    "an actually brewing potion was blocked after pickup")
inProgress = false
sold = runAutoSellCycle(nil)
assert(sold == false and scans == 4,
    "the current-cycle craft permission leaked into a later cycle")

challenge = 2
sold = runAutoSellCycle("brew")
assert(sold == false and scans == 4,
    "a craft confirmation bypassed the final base gate")

-- Revalidate after a potentially yielding inventory scan and before SELL.
challenge = 0
cfg.AutoBrew = false
scanHook = function()
    challenge = 2
    scanHook = function() end
end
sold = runAutoSellCycle(nil)
assert(sold == false and scans == 5 and sales == 4
    and sellTelemetry.status == "waiting for base",
    "AutoSell invoked after Broom left base during the bag scan")

challenge = 0
scanHook = function()
    cfg.AutoBrew = true
    scanHook = function() end
end
sold = runAutoSellCycle(nil)
assert(sold == false and scans == 6 and sales == 4
    and sellTelemetry.status == "waiting for confirmed brew",
    "enabling AutoBrew during the scan sold ahead of a potion")

cfg.AutoBrew = false
scanHook = function()
    cfg.AutoSell = false
    scanHook = function() end
end
sold = runAutoSellCycle(nil)
assert(sold == false and scans == 7 and sales == 4
    and sellTelemetry.status == "disabled",
    "disabling AutoSell during the scan did not cancel its remote")

cfg.AutoSell = true
scanHook = function()
    sessionAlive = false
    scanHook = function() end
end
sold = runAutoSellCycle(nil)
assert(sold == false and scans == 8 and sales == 4
    and sellTelemetry.status == "session closed",
    "an old reloaded session sent SELL after unload")
sessionAlive = true

configReady = true
scanHook = function()
    configReady = false
    scanHook = function() end
end
sold = runAutoSellCycle(nil)
assert(sold == false and scans == 9 and sales == 4
    and sellTelemetry.status == "waiting for config",
    "config reload during the scan did not cancel its remote")
configReady = true

challenge = -1
cfg.AutoBrew = false
sellMode = "empty"
sold = runAutoSellCycle(nil)
assert(sold == false and scans == 10 and sellTelemetry.status == "nothing to sell"
    and sellTelemetry.lastError == nil,
    "empty base inventory was reported as a sell failure")
sellMode = "failure"
sold = runAutoSellCycle(nil)
assert(sold == false and scans == 11 and sellTelemetry.status == "sell failed"
    and sellTelemetry.lastError == "fixture failure",
    "sell transport failure was hidden")

assert(sellTelemetry.requests == 4 and sellTelemetry.requestedItems == 12,
    "sell telemetry counted scans instead of successful requests")

-- A detached scan can overlap pickup. The initial in-progress sample must be
-- revalidated immediately before SELL instead of becoming a stale grant.
sellMode = "success"
cfg.AutoBrew = true
inProgress = true
local scansBeforeStaleGrant = scans
local salesBeforeStaleGrant = sales
scanHook = function()
    inProgress = false
    scanHook = function() end
end
sold = runAutoSellCycle(nil)
assert(sold == false
    and scans == scansBeforeStaleGrant + 1
    and sales == salesBeforeStaleGrant
    and sellTelemetry.status == "waiting for confirmed brew",
    "a stale in-progress sample sold after pickup and before the next brew")

challenge = 0
inProgress = true
local progressReadsBeforeFinalGate = 0
progressReadHook = function()
    progressReadsBeforeFinalGate += 1
    if progressReadsBeforeFinalGate == 2 then challenge = 3 end
end
local scansBeforeFinalYieldGate = scans
local salesBeforeFinalYieldGate = sales
sold = runAutoSellCycle(nil)
assert(sold == false
    and scans == scansBeforeFinalYieldGate + 1
    and sales == salesBeforeFinalYieldGate
    and sellTelemetry.status == "waiting for base",
    "AutoSell left base while revalidating brew state and still sent SELL")
progressReadHook = function() end
print("sell_brew_flow_smoke=ok")
"""
        completed = run_luau(fixture)
        self.assertEqual(
            completed.returncode,
            0,
            f"sell/brew smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("sell_brew_flow_smoke=ok", completed.stdout)

    def test_one_worker_runs_alchemy_before_automatic_selling(self):
        source = (REPO_ROOT / "games" / "magicloot.lua").read_text(encoding="utf-8")
        worker = core_slice(
            "    task.spawn(function() -- alchemy",
            "    task.spawn(function() -- gear",
        )
        self.assertNotIn("task.spawn(function() -- sell", source)
        self.assertIn("if configReady then", worker)
        loop = worker[worker.index("        while sessionAlive do") :]
        self.assertLess(loop.index("runAlchemyCycle"), loop.index("startAutoSellCycle"))
        self.assertIn("runAutoSellCycle,\n                    confirmedAction", worker)
        self.assertIn("confirmedActionThisCycle = alchemyTelemetry.confirmedAction", worker)
        self.assertNotIn('alchemyTelemetry.confirmedAction == "brew"', worker)
        self.assertIn("task.wait(0.5)", worker)
        self.assertIn("os.clock() + 2", worker)

        helper = SELL_COORDINATION
        self.assertIn('playerNumber("InDungeonChallenge")', helper)
        self.assertIn('alchemyState(\n                alchemy,\n                "IsBrewInProgress"', helper)
        self.assertIn('confirmedActionThisCycle ~= "brew"', helper)
        self.assertNotIn("sellAllMaterials()", source[source.index("-- online claims") : source.index("-- potions")])

        sell_builder = core_slice(
            "    local function sellAllMaterials(beforeSend)",
            "    local function playerGold()",
        )
        self.assertIn(
            '"SELL_MATERIAL",\n            { onlyIDList = onlyIds },\n            beforeSend',
            sell_builder,
        )


if __name__ == "__main__":
    unittest.main()
