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


class SellBrewFlowTests(unittest.TestCase):
    def test_auto_sell_is_base_only_and_waits_for_a_confirmed_brew(self):
        fixture = f"""
local configReady = false
local sessionAlive = true
local cfg = {{ AutoSell = true, AutoBrew = false }}
local challenge = 0
local alchemyAvailable = true
local inProgress = false
local progressError = nil
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
        self.assertLess(worker.index("runAlchemyCycle"), worker.index("runAutoSellCycle"))
        self.assertIn("confirmedActionThisCycle = alchemyTelemetry.confirmedAction", worker)
        self.assertNotIn('alchemyTelemetry.confirmedAction == "brew"', worker)
        self.assertIn("task.wait(2)", worker)

        helper = SELL_COORDINATION
        self.assertIn('playerNumber("InDungeonChallenge")', helper)
        self.assertIn('alchemyState(\n                alchemy,\n                "IsBrewInProgress"', helper)
        self.assertIn('confirmedActionThisCycle ~= "brew"', helper)
        self.assertNotIn("sellAllMaterials()", source[source.index("-- online claims") : source.index("-- potions")])

        sell_builder = core_slice(
            "    local function sellAllMaterials(beforeSend)",
            "    local function playerGold()",
        )
        self.assertLess(
            sell_builder.index("beforeSend()"),
            sell_builder.index('invokeAction("SELL_MATERIAL"'),
        )


if __name__ == "__main__":
    unittest.main()
