"""Executable regressions for the strict Alchemy -> Sell -> Broom pipeline."""

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


BASE_PRIORITY = core_slice(
    "    local basePriority = {",
    "    local alchemyRecovery = {",
)
AUTO_SELL_OPTIONS = core_slice(
    "    local function autoSellEnabled()",
    "    local function sellAllMaterials(",
)
ALCHEMY_OUTCOME = core_slice(
    "    local function alchemyPriorityOutcome()",
    "    local function autoSellBaseGate()",
)
SELL_COORDINATION = AUTO_SELL_OPTIONS + core_slice(
    "    local function autoSellBaseGate()",
    "    -- Attack -----------------------------------------------------------------",
)
ALCHEMY_WORKER = AUTO_SELL_OPTIONS + BASE_PRIORITY + core_slice(
    "    task.spawn(function() -- alchemy",
    "    task.spawn(function() -- gear",
)


class SellBrewFlowTests(unittest.TestCase):
    def test_idle_base_watches_only_confirmed_brew_until_ready(self):
        fixture = f"""
local sessionAlive = true
local configReady = true
local cfg = {{
    AutoBrew = true,
    AutoPickupPotion = true,
    BrewRecipe = "Best craftable",
    AutoSell = false,
    AutoSellSpecific = false,
    SellItems = {{}},
    AutoBroom = false,
    AutoFarm = false,
    AutoFarmSpecific = false,
}}
local fakeClock = 0
local os = {{ clock = function() return fakeClock end }}
local alchemyTelemetry = {{
    confirmedAction = nil,
    inProgress = false,
    ready = false,
    status = "waiting",
}}
local sellTelemetry = {{ status = "waiting", lastError = nil }}
local alchemy = {{}}
local readyChecks = 0
local alchemyRuns = 0
local rearmedAt = nil

local function playerNumber(name)
    assert(name == "InDungeonChallenge")
    return 0
end
local function observeAlchemyLocation(_challenge) end
local function alchemyInventoryTransferPending() return false end
local function resetAlchemyRecovery() end
local function clearAlchemyStageCandidate() end
local function resolveAlchemy() return alchemy end
local function alchemyState(actual, method)
    assert(actual == alchemy and method == "IsBrewReadyForPickup")
    readyChecks += 1
    return readyChecks >= 3
end
local function runAlchemyCycle()
    alchemyRuns += 1
    if alchemyRuns == 1 then
        alchemyTelemetry.confirmedAction = "brew"
        alchemyTelemetry.inProgress = true
        alchemyTelemetry.ready = false
        alchemyTelemetry.status = "brew confirmed"
        return true
    end
    rearmedAt = fakeClock
    sessionAlive = false
    return false
end
local function alchemyPriorityOutcome()
    return alchemyTelemetry.confirmedAction
end
local function runAutoSellCycle()
    error("disabled AutoSell was invoked")
end

local task = {{}}
task.spawn = function(callback) callback() end
task.wait = function(seconds)
    fakeClock += seconds
    assert(fakeClock < 10, "idle readiness watcher did not terminate")
end

{ALCHEMY_WORKER}

assert(alchemyRuns == 2 and readyChecks == 3,
    "idle brew was not watched and rearmed exactly once")
assert(rearmedAt >= 2.5 and rearmedAt < 3,
    "readiness polling cadence was not approximately one second")
print("idle_brew_ready_watch_smoke=ok")
"""
        completed = run_luau(fixture)
        self.assertEqual(
            completed.returncode,
            0,
            f"idle brew watch smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("idle_brew_ready_watch_smoke=ok", completed.stdout)

        exhausted_fixture = f"""
local sessionAlive = true
local configReady = true
local cfg = {{
    AutoBrew = true,
    AutoPickupPotion = true,
    BrewRecipe = "Best craftable",
    AutoSell = false,
    AutoSellSpecific = false,
    SellItems = {{}},
    AutoBroom = false,
    AutoFarm = false,
    AutoFarmSpecific = false,
}}
local fakeClock = 0
local os = {{ clock = function() return fakeClock end }}
local alchemyTelemetry = {{
    confirmedAction = nil,
    inProgress = false,
    ready = false,
    status = "no recipe candidate",
}}
local sellTelemetry = {{ status = "waiting", lastError = nil }}
local alchemyRuns = 0
local readyChecks = 0
local function playerNumber(_name) return 0 end
local function observeAlchemyLocation(_challenge) end
local function alchemyInventoryTransferPending() return false end
local function resetAlchemyRecovery() end
local function clearAlchemyStageCandidate() end
local function resolveAlchemy() readyChecks += 1 return {{}} end
local function alchemyState() readyChecks += 1 return false end
local function runAlchemyCycle()
    alchemyRuns += 1
    alchemyTelemetry.confirmedAction = nil
    alchemyTelemetry.inProgress = false
    alchemyTelemetry.ready = false
    alchemyTelemetry.status = "no recipe candidate"
    return false
end
local function alchemyPriorityOutcome() return "alchemy-empty" end
local function runAutoSellCycle() error("disabled AutoSell was invoked") end
local task = {{}}
task.spawn = function(callback) callback() end
task.wait = function(seconds)
    fakeClock += seconds
    if fakeClock >= 2 then sessionAlive = false end
end

{ALCHEMY_WORKER}

assert(alchemyRuns == 1 and readyChecks == 0,
    "exhausted materials kept the idle watcher active")
print("idle_brew_exhausted_smoke=ok")
"""
        completed = run_luau(exhausted_fixture)
        self.assertEqual(
            completed.returncode,
            0,
            f"idle exhausted smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("idle_brew_exhausted_smoke=ok", completed.stdout)

    def test_broom_and_farm_have_separate_sequential_gates(self):
        fixture = f"""
local cfg = {{ AutoBroom = true }}
local configReady = true
local challenge = 0
local function playerNumber(name)
    assert(name == "InDungeonChallenge")
    return challenge
end

{BASE_PRIORITY}

broomFarmRoute.stage = 28
broomFarmRoute.bypassEnterDelay = true
assert(broomEconomyGate() == false and farmObjectiveGate() == false,
    "Alchemy did not block Broom and Farm")
assert(broomFarmRoute.stage == nil and broomFarmRoute.bypassEnterDelay == false,
    "returning to base did not clear the prior Broom Farm route")
setBasePriorityPhase("sell", "test")
assert(broomEconomyGate() == false and farmObjectiveGate() == false,
    "Sell did not block Broom and Farm")
setBasePriorityPhase("broom", "test")
assert(broomEconomyGate() == true,
    "settled Sell did not release Broom")
assert(farmObjectiveGate() == false,
    "Farm started alongside an enabled Broom")
cfg.AutoBroom = false
assert(farmObjectiveGate() == true,
    "disabled Broom did not release Farm")
cfg.AutoBroom = true
challenge = 28
assert(farmObjectiveGate() == true,
    "confirmed Broom stage did not release Farm")
print("sequential_objective_gates_smoke=ok")
"""
        completed = run_luau(fixture)
        self.assertEqual(
            completed.returncode,
            0,
            f"sequential gate smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("sequential_objective_gates_smoke=ok", completed.stdout)

    def test_valid_zero_craftable_round_releases_sell_and_broom(self):
        fixture = f"""
local sessionAlive = true
local configReady = true
local cfg = {{
    AutoBrew = true,
    AutoPickupPotion = true,
    BrewRecipe = "Best craftable",
    AutoSell = true,
    AutoSellSpecific = false,
    SellItems = {{}},
}}
local fakeClock = 0
local os = {{ clock = function() return fakeClock end }}
local alchemyTelemetry = {{
    confirmedAction = nil,
    inProgress = false,
    status = "no recipe candidate",
    checkTotal = 4,
    craftable = 0,
    predicateErrors = 0,
    ready = false,
}}
local sellTelemetry = {{ status = "waiting", lastError = nil }}
local events = {{}}

local function playerNumber(name)
    assert(name == "InDungeonChallenge")
    return 0
end
local function observeAlchemyLocation(_challenge) end
local function alchemyInventoryTransferPending() return false end
local function resetAlchemyRecovery() end
local function clearAlchemyStageCandidate() end
local function runAlchemyCycle()
    table.insert(events, "alchemy-empty")
    return false, "no recipe can be crafted"
end
local function runAutoSellCycle(authorization)
    assert(authorization == "alchemy-empty",
        "zero-material round lost its typed authorization")
    table.insert(events, "sell-empty")
    sessionAlive = false
    return false, 0, "nothing to sell"
end

local task = {{}}
task.spawn = function(callback) callback() end
task.wait = function(seconds) fakeClock += seconds end

{ALCHEMY_OUTCOME}
{ALCHEMY_WORKER}

assert(table.concat(events, ",") == "alchemy-empty,sell-empty",
    "empty round did not preserve Alchemy -> Sell order")
assert(basePriority.phase == "broom",
    "valid zero-craftable round left Broom blocked")
print("empty_round_priority_smoke=ok")
"""
        completed = run_luau(fixture)
        self.assertEqual(
            completed.returncode,
            0,
            f"empty-round priority smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("empty_round_priority_smoke=ok", completed.stdout)

    def test_worker_enforces_alchemy_then_confirmed_sell_then_broom(self):
        fixture = f"""
local sessionAlive = true
local configReady = true
local cfg = {{
    AutoBrew = true,
    AutoPickupPotion = true,
    BrewRecipe = "Best craftable",
    AutoSell = true,
    AutoSellSpecific = false,
    SellItems = {{}},
}}
local fakeClock = 0
local os = {{ clock = function() return fakeClock end }}
local alchemyTelemetry = {{ confirmedAction = nil, status = "working" }}
local sellTelemetry = {{ status = "waiting", lastError = nil }}
local events = {{}}
local alchemyRuns = 0
local sellRuns = 0

local function playerNumber(name)
    assert(name == "InDungeonChallenge")
    return 0
end
local function observeAlchemyLocation(_challenge) end
local function alchemyInventoryTransferPending() return false end
local function resetAlchemyRecovery() end
local function clearAlchemyStageCandidate() end

local function runAlchemyCycle()
    alchemyRuns += 1
    table.insert(events, "alchemy-" .. tostring(alchemyRuns))
    if alchemyRuns < 3 then
        alchemyTelemetry.status = "waiting for Alchemy"
        alchemyTelemetry.confirmedAction = nil
        return false
    end
    alchemyTelemetry.status = "brew confirmed"
    alchemyTelemetry.confirmedAction = "brew"
    return true
end
local function alchemyPriorityOutcome()
    return alchemyTelemetry.confirmedAction
end
local function runAutoSellCycle(authorization)
    assert(authorization == "brew")
    sellRuns += 1
    table.insert(events, sellRuns == 1 and "sell-request" or "sell-empty")
    if sellRuns == 1 then return true, 2, nil end
    sessionAlive = false
    return false, 0, "nothing to sell"
end

local task = {{}}
task.spawn = function(callback) callback() end
task.wait = function(seconds)
    fakeClock += seconds
end

{ALCHEMY_WORKER}

assert(table.concat(events, ",")
    == "alchemy-1,alchemy-2,alchemy-3,sell-request,sell-empty",
    "priority order changed: " .. table.concat(events, ","))
assert(basePriority.phase == "broom")
assert(sellRuns == 2,
    "Broom was released on transport success instead of an empty rescan")
print("strict_base_priority_smoke=ok")
"""
        completed = run_luau(fixture)
        self.assertEqual(
            completed.returncode,
            0,
            f"strict priority smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("strict_base_priority_smoke=ok", completed.stdout)

    def test_alchemy_terminal_outcomes_are_explicit_and_fail_closed(self):
        fixture = f"""
local cfg = {{ AutoBrew = true, AutoPickupPotion = true }}
local transferPending = false
local function alchemyInventoryTransferPending() return transferPending end
local alchemyTelemetry = {{
    confirmedAction = nil,
    inProgress = false,
    status = "no recipe candidate",
    checkTotal = 4,
    craftable = 0,
    predicateErrors = 0,
    ready = false,
}}

{ALCHEMY_OUTCOME}

assert(alchemyPriorityOutcome() == "alchemy-empty",
    "a verified empty recipe catalog did not release Alchemy")
alchemyTelemetry.predicateErrors = 1
assert(alchemyPriorityOutcome() == nil,
    "predicate errors failed open into Sell")
alchemyTelemetry.predicateErrors = 0
alchemyTelemetry.status = "brewing (one potion at a time)"
alchemyTelemetry.inProgress = true
assert(alchemyPriorityOutcome() == "brew")
alchemyTelemetry.confirmedAction = "pickup"
alchemyTelemetry.inProgress = false
alchemyTelemetry.status = "pickup confirmed"
assert(alchemyPriorityOutcome() == nil,
    "a pickup released Alchemy before checking for another recipe")
alchemyTelemetry.status = "no recipe candidate"
assert(alchemyPriorityOutcome() == "alchemy-empty",
    "a pickup plus verified empty recipe result did not release Alchemy")
cfg.AutoBrew = false
alchemyTelemetry.status = "pickup confirmed"
assert(alchemyPriorityOutcome() == "pickup",
    "pickup-only mode did not release Alchemy")
cfg.AutoBrew = true
alchemyTelemetry.confirmedAction = nil
alchemyTelemetry.inProgress = false
alchemyTelemetry.status = "potion ready for pickup"
cfg.AutoPickupPotion = false
assert(alchemyPriorityOutcome() == "potion-ready")
cfg.AutoBrew = false
cfg.AutoPickupPotion = true
alchemyTelemetry.status = "waiting for brewed potion"
alchemyTelemetry.ready = false
assert(alchemyPriorityOutcome() == "alchemy-empty")
cfg.AutoPickupPotion = false
assert(alchemyPriorityOutcome() == "alchemy-disabled")
print("alchemy_terminal_outcomes_smoke=ok")
"""
        completed = run_luau(fixture)
        self.assertEqual(
            completed.returncode,
            0,
            f"Alchemy outcome smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("alchemy_terminal_outcomes_smoke=ok", completed.stdout)

    def test_sell_accepts_only_a_terminal_alchemy_authorization(self):
        fixture = f"""
local configReady = true
local sessionAlive = true
local cfg = {{ AutoSell = true, AutoSellSpecific = false, AutoBrew = true }}
local challenge = 0
local inProgress = false
local scans = 0
local sales = 0
local alchemy = {{}}
local sellTelemetry = {{
    status = "waiting", attempts = 0, requests = 0,
    requestedItems = 0, lastCount = 0,
}}
local function playerNumber(name)
    assert(name == "InDungeonChallenge")
    return challenge
end
local function resolveAlchemy() return alchemy end
local function alchemyState(actual, method)
    assert(actual == alchemy and method == "IsBrewInProgress")
    return inProgress
end
local function sellAllMaterials(_selected, beforeSend)
    scans += 1
    local allowed, err = beforeSend()
    if not allowed then return false, 0, err end
    sales += 1
    return true, 2
end

{SELL_COORDINATION}

assert(runAutoSellCycle(nil) == false and scans == 0,
    "Sell ran before Alchemy settled")
assert(runAutoSellCycle("alchemy-empty") == true and scans == 1,
    "verified empty Alchemy did not authorize Sell")
assert(runAutoSellCycle("potion-ready") == true and scans == 2,
    "a completed potion did not authorize Sell")
assert(runAutoSellCycle("pickup") == true and scans == 3,
    "confirmed pickup did not authorize the following Sell phase")
inProgress = true
assert(runAutoSellCycle(nil) == true and scans == 4,
    "authoritative in-progress state did not authorize Sell")
challenge = 4
assert(runAutoSellCycle("brew") == false and scans == 4,
    "Sell escaped the base gate")
assert(sales == 4)
print("terminal_sell_authorization_smoke=ok")
"""
        completed = run_luau(fixture)
        self.assertEqual(
            completed.returncode,
            0,
            f"Sell authorization smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("terminal_sell_authorization_smoke=ok", completed.stdout)

    def test_core_and_locomotion_share_one_priority_gate(self):
        core = (REPO_ROOT / "games" / "magicloot.lua").read_text(encoding="utf-8")
        locomotion = (
            REPO_ROOT / "games" / "magicloot_locomotion.lua"
        ).read_text(encoding="utf-8")
        worker = core_slice(
            "    task.spawn(function() -- alchemy",
            "    task.spawn(function() -- gear",
        )
        loop = worker[worker.index("        while sessionAlive do") :]
        self.assertLess(loop.index("runAlchemyCycle"), loop.index("startAutoSellCycle"))
        self.assertIn('setBasePriorityPhase("sell"', worker)
        self.assertIn('setBasePriorityPhase("broom"', worker)
        self.assertIn('err == "nothing to sell"', worker)
        self.assertIn("broomGate = broomEconomyGate", core)
        self.assertIn("local function broomPriorityGate()", locomotion)
        self.assertIn("local priorityAllowed, priorityStatus", locomotion)
        movement = core_slice("    local function updateMovement()", "    -- Combat")
        self.assertLess(
            movement.index("farmObjectiveGate()"),
            movement.index("Common.farmStageTarget"),
        )
        self.assertIn("enterDelay.stage = nil", movement)
        train_worker = core_slice(
            "    task.spawn(function() -- train",
            "    task.spawn(function() -- alchemy",
        )
        self.assertIn("local trainPriorityAllowed = farmObjectiveGate()", train_worker)
        self.assertIn("cfg.AutoTrain and trainPriorityAllowed", train_worker)
        broom_update = locomotion[
            locomotion.index("    local function updateBroom()") :
            locomotion.index("    local function startBroomWorker()")
        ]
        self.assertLess(
            broom_update.index("broomPriorityGate()"),
            broom_update.index("scheduleBroomDelay(now, broom.delayDuration)"),
        )
        self.assertIn("deferBroomDelay()", broom_update)
        self.assertNotIn("queuedCraftSellAuthorization", core)


if __name__ == "__main__":
    unittest.main()
