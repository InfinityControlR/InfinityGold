"""Executable regressions for automatic Alchemy creation and pickup."""

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


ALCHEMY_HELPERS = core_slice(
    "    local carriedAlchemyTravel =",
    "    -- Attack -----------------------------------------------------------------",
)
ALCHEMY_INVOKE_HELPER = core_slice(
    "    local function invokeAlchemyAction",
    "    local function refreshAlchemyUi",
)
RETURN_PENDING_HELPER = core_slice(
    "    alchemyReturnPending = function()",
    "    local function resetReturnEpisode()",
)


class AlchemyFlowTests(unittest.TestCase):
    def test_return_hold_treats_loading_challenge_as_pending(self):
        fixture = f"""
local fakeClock = 5
local os = {{ clock = function() return fakeClock end }}
local challenge = nil
local returnEpisode = {{ active = false }}
local returnTravelHoldUntil = 10
local alchemyInvokeLease = {{ returnHoldUntil = 10 }}
local cfg = {{ AutoReturnFull = true }}
local function playerNumber(name)
    assert(name == "InDungeonChallenge", "wrong return state key")
    return challenge
end
local function bagFull() return true end
local alchemyReturnPending

{RETURN_PENDING_HELPER}

assert(alchemyReturnPending() == true,
    "nil challenge escaped the active return travel hold")
challenge = 0
assert(alchemyReturnPending() == false,
    "known base state did not release the return hold")
assert(alchemyInvokeLease.returnHoldUntil == nil,
    "known base state did not clear the shared return hold")
challenge = nil
alchemyInvokeLease.returnHoldUntil = 20
assert(alchemyReturnPending() == true,
    "a return hold published by the previous session was not adopted")
challenge = 0
assert(alchemyReturnPending() == false,
    "adopted return hold did not release at a known base state")
challenge = 1
assert(alchemyReturnPending() == true,
    "known dungeon state did not preserve the return hold")
fakeClock = 11
challenge = nil
assert(alchemyReturnPending() == false,
    "expired hold treated an unrelated nil state as an active return")
challenge = 1
returnEpisode.blocked = true
assert(alchemyReturnPending() == false,
    "exhausted Auto Return blocked Alchemy forever")
returnEpisode.blocked = false
returnEpisode.active = true
assert(alchemyReturnPending() == true,
    "active return episode was not authoritative")
print("alchemy_return_hold_smoke=ok")
"""
        completed = run_luau(fixture)
        self.assertEqual(
            completed.returncode,
            0,
            f"Alchemy return hold smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("alchemy_return_hold_smoke=ok", completed.stdout)

    def test_invoke_timeout_keeps_a_cross_reload_single_flight_lease(self):
        fixture = f"""
local sessionAlive = true
local alchemyInvokeLease = {{ pending = false, generation = 0 }}
local waits = 0
local closeOnWait = false
local completeDuringClosedWait = false
local queued = {{}}
local runImmediately = false
local calls = 0
local task = {{
    wait = function(seconds)
        assert(seconds == 0.25, "unexpected Alchemy poll cadence")
        waits += 1
        if closeOnWait then
            closeOnWait = false
            sessionAlive = false
        end
        if completeDuringClosedWait then
            completeDuringClosedWait = false
            sessionAlive = false
            queued[#queued]()
        end
    end,
    spawn = function(callback)
        if runImmediately then callback() else table.insert(queued, callback) end
    end,
}}
local function invokeAction(action, payload)
    calls += 1
    assert(action == "ALCHEMY_CRAFT_RECIPE", "wrong deferred action")
    assert(payload.recipeId == 4, "wrong deferred recipe")
    return true, {{ accepted = true }}, nil
end

{ALCHEMY_INVOKE_HELPER}

local sent, _, err = invokeAlchemyAction(
    "ALCHEMY_CRAFT_RECIPE",
    {{ recipeId = 4 }}
)
assert(sent == false and string.find(err, "timed out", 1, true) ~= nil,
    "a pending RemoteFunction was not bounded")
assert(waits == 16 and alchemyInvokeLease.pending == true and calls == 0,
    "timeout released or executed the pending lease incorrectly")

local duplicate, _, duplicateError = invokeAlchemyAction(
    "ALCHEMY_CRAFT_RECIPE",
    {{ recipeId = 4 }}
)
assert(duplicate == false
    and string.find(duplicateError, "previous Alchemy request", 1, true) ~= nil,
    "a reload/session could duplicate the unresolved request")

-- Model stale-lease recovery/new session ownership before the original
-- callback returns. The old generation must never clear the newer request.
alchemyInvokeLease.generation += 1
alchemyInvokeLease.pending = false
alchemyInvokeLease.startedAt = nil
local secondSent, _, secondError = invokeAlchemyAction(
    "ALCHEMY_CRAFT_RECIPE",
    {{ recipeId = 4 }}
)
assert(secondSent == false and string.find(secondError, "timed out", 1, true) ~= nil
    and #queued == 2 and alchemyInvokeLease.pending == true,
    "replacement session did not acquire its own bounded lease")
queued[1]()
assert(calls == 1 and alchemyInvokeLease.pending == true,
    "late callback from the old session cleared the newer lease")
queued[2]()
assert(calls == 2 and alchemyInvokeLease.pending == false,
    "current late completion did not release its own lease")
runImmediately = true
local retried, response, retryError = invokeAlchemyAction(
    "ALCHEMY_CRAFT_RECIPE",
    {{ recipeId = 4 }}
)
assert(retried == true and response.accepted == true and retryError == nil,
    "Alchemy did not recover after the late request completed")

-- A reload can detach the caller before the four-second timeout. The eventual
-- result still belongs to the shared lease and must reach the new session.
runImmediately = false
queued = {{}}
sessionAlive = true
closeOnWait = true
local closed, _, closedError, closedPending = invokeAlchemyAction(
    "ALCHEMY_CRAFT_RECIPE",
    {{ recipeId = 4 }},
    {{ key = "Best craftable|4,1", candidateIds = {{ 4, 1 }}, cursor = 1 }}
)
assert(closed == false and closedPending == true
    and string.find(closedError, "session closed", 1, true) ~= nil,
    "reload did not detach the in-flight Alchemy request")
sessionAlive = true
queued[1]()
assert(alchemyInvokeLease.pending == false
    and type(alchemyInvokeLease.completed) == "table"
    and type(alchemyInvokeLease.completed.recovery) == "table",
    "late completion was discarded during reload handoff")

-- Exercise the opposite scheduling order: unload happens while the poller is
-- asleep and the RemoteFunction callback finishes before that poller wakes.
alchemyInvokeLease.completed = nil
queued = {{}}
sessionAlive = true
completeDuringClosedWait = true
local raced, racedResponse = invokeAlchemyAction(
    "ALCHEMY_CRAFT_RECIPE",
    {{ recipeId = 4 }},
    {{ key = "Best craftable|4,1", candidateIds = {{ 4, 1 }}, cursor = 1 }}
)
assert(raced == true and racedResponse.accepted == true,
    "callback-before-poller fixture did not complete the request")
assert(type(alchemyInvokeLease.completed) == "table"
    and type(alchemyInvokeLease.completed.recovery) == "table",
    "callback-before-poller race lost the cross-reload completion")
print("alchemy_invoke_lease_smoke=ok")
"""
        completed = run_luau(fixture)
        self.assertEqual(
            completed.returncode,
            0,
            f"Alchemy invoke lease smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("alchemy_invoke_lease_smoke=ok", completed.stdout)

    def test_nested_alchemy_selects_best_and_picks_up_with_invoke(self):
        fixture = f"""
local player = {{ marker = "local-player" }}
local cfg = {{
    AutoBrew = true,
    AutoPickupPotion = true,
    BrewRecipe = "Best craftable",
    FarmMode = "Walking",
}}
local sessionAlive = true
local fakeClock = 0
local os = {{ clock = function() return fakeClock end }}
local alchemyInvokeLease = {{ pending = false, generation = 0 }}
local waits = {{}}
local calls = {{}}
local pauseCalls = 0
local resumeCalls = 0
local refreshCalls = 0
local waitHook = function(_seconds) end
local travelHook = function() end
local delayed = {{}}
local spawnHook = function(callback) callback() end
local task = {{
    wait = function(seconds)
        table.insert(waits, seconds)
        if seconds == 0.2 then travelHook() end
        waitHook(seconds)
    end,
    delay = function(seconds, callback)
        table.insert(delayed, {{ seconds = seconds, callback = callback }})
    end,
    spawn = function(callback) spawnHook(callback) end,
}}
local Vector3 = {{ new = function(x, y, z) return {{ x = x, y = y, z = z }} end }}

local function makeCFrame(name)
    return setmetatable({{ _kind = "CFrame", name = name }}, {{
        __add = function(left, _right) return makeCFrame(left.name .. "+offset") end,
    }})
end
local function typeof(value)
    if type(value) == "table" and value._kind ~= nil then return value._kind end
    return type(value)
end

local home = makeCFrame("home")
local root = {{ CFrame = home, Parent = {{}} }}
local function characterParts()
    return {{ root = root, humanoid = {{ Health = 100 }}, character = {{}} }}
end

local inProgress = false
local progressNilReads = 0
local readyForPickup = false
local readyNilReads = 0
local recipeListReads = 0
local potionConfReads = 0
local potionFindCalls = 0
local translationCalls = 0
local recipesReady = false
local translationsReady = false
local remoteMode = "accept"
local pendingAction = nil
local confirmationTicks = 0
local recipes = {{
    {{ recipeId = 1, PID = 101, Rebirth = 0, craftable = true, ZhName = "药水一" }},
    {{ recipeId = 4, PID = 104, Rebirth = 1, craftable = true, ZhName = "药水四" }},
    {{ recipeId = 7, PID = 107, Rebirth = 9, craftable = false, ZhName = "药水七" }},
}}
local alchemy = {{
    CanUseAlchemy = function(actualPlayer)
        assert(actualPlayer == player, "CanUseAlchemy received the wrong player")
        return true
    end,
    IsBrewInProgress = function(actualPlayer)
        assert(actualPlayer == player, "progress check received the wrong player")
        if progressNilReads > 0 then
            progressNilReads -= 1
            return nil
        end
        return inProgress
    end,
    IsBrewReadyForPickup = function(actualPlayer)
        assert(actualPlayer == player, "pickup check received the wrong player")
        if readyNilReads > 0 then
            readyNilReads -= 1
            return nil
        end
        return readyForPickup
    end,
    CanMeetRecipeRebirth = function(actualPlayer, raw)
        assert(actualPlayer == player, "rebirth check received the wrong player")
        return raw.Rebirth <= 2
    end,
    CanCraftRecipe = function(actualPlayer, raw)
        assert(actualPlayer == player, "craft check received the wrong player")
        return raw.craftable
    end,
    GetRecipeList = function()
        recipeListReads += 1
        if not recipesReady then error("recipe data still loading") end
        return recipes
    end,
    ResolveBrewActorCFrame = function() return makeCFrame("actor") end,
    ResolveFinishSpawnCFrame = function() return makeCFrame("finish") end,
}}
local function resolveGetData() return {{ Alchemy = alchemy }} end
local function resolveRuntimeModule(name)
    if name == "CfgFind" then
        return {{
            GetCfgByName = function(configName)
                assert(configName == "potionConf", "wrong Alchemy config " .. tostring(configName))
                potionConfReads += 1
                return {{ {{ potionId = 999, Name = "Potion item, not recipe" }} }}
            end,
            FindCfgByID = function(potionId, configType)
                assert(configType == 9, "wrong potion config type " .. tostring(configType))
                potionFindCalls += 1
                return {{ ZhName = "药水键" .. tostring(potionId) }}
            end,
        }}
    end
    if name == "TranslationHelper" then
        return {{
            TranslateByKey = function(key)
                translationCalls += 1
                if not translationsReady then return key end
                return "Localized " .. tostring(key)
            end,
        }}
    end
    error("unexpected runtime module " .. tostring(name))
end
local function invokeAction(action, payload)
    table.insert(calls, {{ action = action, payload = payload, root = root.CFrame }})
    if remoteMode == "accept"
        or (remoteMode == "accept-one" and payload ~= nil and payload.recipeId == 1)
    then
        pendingAction = action
        confirmationTicks = 0
    elseif remoteMode == "reject" then
        return true, {{ success = false, error = "fixture rejection" }}, nil
    end
    return true, {{ accepted = true }}, nil
end
local function fireBindableAction(action, gameName, empty, visible, animate)
    assert(action == "SHOW_LOCAL_UI", "wrong Alchemy bindable action")
    assert(gameName == "PotionBrewingGame" and empty == nil,
        "wrong PotionBrewingGame bindable arguments")
    assert(visible == false and animate == false, "wrong UI refresh flags")
    refreshCalls += 1
    return true
end

waitHook = function(seconds)
    if seconds ~= 0.25 or pendingAction == nil then return end
    confirmationTicks += 1
    if confirmationTicks < 2 then return end
    if pendingAction == "ALCHEMY_CRAFT_RECIPE" then
        inProgress = true
    elseif pendingAction == "ALCHEMY_PICKUP_FINISH_POTION" then
        readyForPickup = false
    end
    pendingAction = nil
end

{ALCHEMY_HELPERS}

pauseAlchemyMovement = function() pauseCalls += 1 end
resumeAlchemyMovement = function() resumeCalls += 1 end

local loadingValues = alchemyDropdownValues()
assert(#loadingValues == 1 and loadingValues[1] == "Best craftable",
    "loading recipe data should remain retryable")
recipesReady = true
local fallbackValues = alchemyDropdownValues()
assert(fallbackValues[2] == "#1 Recipe 1"
    and fallbackValues[3] == "#4 Recipe 4"
    and fallbackValues[4] == "#7 Recipe 7",
    "untranslated Chinese keys leaked into the dropdown")
translationsReady = true
local recipeValues = alchemyDropdownValues()
assert(#recipeValues == 4, "recipe dropdown did not discover GetRecipeList rows")
assert(recipeValues[1] == "Best craftable"
    and recipeValues[2] == "#1 Localized 药水键101"
    and recipeValues[3] == "#4 Localized 药水键104"
    and recipeValues[4] == "#7 Localized 药水键107",
    "recipe dropdown did not use the game's translator")

local legacyRecipe = selectAlchemyRecipe(alchemy, "#4 old-language label")
assert(legacyRecipe ~= nil and legacyRecipe.id == 4,
    "a saved recipe label was not preserved by numeric id")

local sent, craftError = runAlchemyCycle()
assert(sent == true and craftError == nil,
    "craft cycle failed: " .. tostring(craftError) .. " / " .. tostring(alchemyTelemetry.status))
assert(#calls == 1 and calls[1].action == "ALCHEMY_CRAFT_RECIPE",
    "craft used the wrong transport/action")
assert(calls[1].payload.recipeId == 4,
    "Best craftable did not choose the highest eligible recipe")
assert(recipeListReads == 5, "Alchemy.GetRecipeList was not retried by UI and worker")
assert(potionConfReads == 0, "potionConf incorrectly replaced the recipe list")
assert(potionFindCalls == 12 and translationCalls == 15,
    "recipe display metadata was not localized independently of craft data: "
        .. tostring(potionFindCalls) .. "/" .. tostring(translationCalls))
assert(calls[1].root.name == "actor+offset", "craft request was not sent at the actor")
assert(root.CFrame == home, "craft did not restore the player's position")
assert(waits[1] == 0.2 and waits[2] == 0.4, "craft cadence changed")
assert(alchemyBusy == false, "craft left the movement lock active")
assert(pauseCalls == 1, "Walking was not paused synchronously before craft")
assert(refreshCalls == 1, "craft did not refresh PotionBrewingGame")
assert(alchemyTelemetry.canUse == true
    and alchemyTelemetry.ready == false
    and alchemyTelemetry.inProgress == true
    and alchemyTelemetry.confirmed == true,
    "Alchemy gate diagnostics lost true/false states")
assert(alchemyTelemetry.checkTotal == 3
    and alchemyTelemetry.rebirthPassed == 2
    and alchemyTelemetry.materialChecks == 2
    and alchemyTelemetry.craftable == 2
    and alchemyTelemetry.predicateErrors == 0
    and alchemyTelemetry.chosenId == 4,
    "Best craftable diagnostics do not explain recipe selection")

inProgress = true
runAlchemyCycle()
assert(#calls == 1, "a second brew was sent while one was in progress")

cfg.AutoBrew = false
cfg.AutoPickupPotion = true
inProgress = false
readyForPickup = true
waits = {{}}
sent = runAlchemyCycle()
assert(sent == true, "ready brewed potion was not picked up")
assert(#calls == 2 and calls[2].action == "ALCHEMY_PICKUP_FINISH_POTION",
    "pickup did not use the verified InvokeServer action")
assert(calls[2].payload == nil, "pickup unexpectedly sent a payload")
assert(calls[2].root.name == "finish+offset", "pickup request was not sent at finish")
assert(root.CFrame == home, "pickup did not restore the player's position")
assert(waits[1] == 0.2 and waits[2] == 0.5, "pickup cadence changed")
assert(pauseCalls == 2, "Walking was not paused synchronously before pickup")
assert(refreshCalls == 2, "pickup did not refresh PotionBrewingGame")

cfg.AutoBrew = true
cfg.AutoPickupPotion = false
inProgress = false
readyForPickup = true
local callsBeforeReadyBlock = #calls
sent, craftError = runAlchemyCycle()
assert(sent == false and craftError == "enable Auto Pickup Brewed Potion",
    "a pre-existing ready potion did not block a new craft")
assert(#calls == callsBeforeReadyBlock,
    "a ready potion was mistaken for confirmation of a new brew")
readyForPickup = false

fakeClock = 1
remoteMode = "unconfirmed"
readyForPickup = true
readyNilReads = 1
cfg.BrewRecipe = "#4 baseline-unknown"
root.CFrame = home
local callsBeforeUnknownBaseline = #calls
sent, craftError = runAlchemyCycle()
assert(sent == false and craftError == "a brewed potion must be picked up first",
    "unknown->ready was not rejected by the actor recheck")
assert(#calls == callsBeforeUnknownBaseline and alchemyTelemetry.confirmed == false,
    "unknown baseline emitted or confirmed a new brew")
readyForPickup = false
cfg.BrewRecipe = "Best craftable"

fakeClock = 2
remoteMode = "unconfirmed"
progressNilReads = 1
local callsBeforeUnknownProgress = #calls
sent, craftError = runAlchemyCycle()
assert(sent == false
    and string.find(craftError, "returned nil", 1, true) ~= nil,
    "unknown brewing state did not stop a duplicate request")
assert(#calls == callsBeforeUnknownProgress,
    "a craft was sent while IsBrewInProgress was unknown")

fakeClock = 2.5
readyForPickup = false
travelHook = function()
    readyForPickup = true
    travelHook = function() end
end
local callsBeforeTravelRace = #calls
sent, craftError = runAlchemyCycle()
assert(sent == false and craftError == "a brewed potion must be picked up first",
    "ready state was not revalidated at the actor")
assert(#calls == callsBeforeTravelRace,
    "craft remote was sent after a potion became ready during travel")
readyForPickup = false

local validBrewResolver = alchemy.ResolveBrewActorCFrame
alchemy.ResolveBrewActorCFrame = function() return nil end
local callsBeforeTravelFailure = #calls
sent, craftError = runAlchemyCycle()
assert(sent == false and string.find(craftError, "returned nil", 1, true) ~= nil,
    "missing actor CFrame was not exposed")
assert(#calls == callsBeforeTravelFailure,
    "craft remote was sent even though travel to the actor failed")
assert(alchemyTelemetry.status == "brew actor unavailable"
    and alchemyTelemetry.travel == "failed",
    "travel failure telemetry is misleading")

alchemy.ResolveBrewActorCFrame = validBrewResolver
remoteMode = "unconfirmed"
fakeClock = 5
root.CFrame = home
waits = {{}}
sent, craftError = runAlchemyCycle()
assert(sent == false and craftError == "brew was not confirmed by game state",
    "transport without a brewing transition was reported as success")
assert(alchemyTelemetry.confirmed == false
    and alchemyTelemetry.status == "brew unconfirmed",
    "unconfirmed craft diagnostics are misleading")
assert(root.CFrame == home,
    "unconfirmed craft did not restore the original farm position after polling")
assert(waits[1] == 0.2 and waits[2] == 0.4 and waits[3] == 0.25,
    "confirmation polling did not keep the player at the actor")
assert(alchemyBusy == false, "unconfirmed craft left movement locked")

fakeClock = 10
remoteMode = "accept-one"
root.CFrame = home
sent, craftError = runAlchemyCycle()
assert(sent == true and craftError == nil,
    "Best craftable did not advance after an unconfirmed server candidate")
assert(calls[#calls].payload.recipeId == 1,
    "Best craftable did not rotate to the next server-validated candidate")

fakeClock = 20
remoteMode = "accept"
inProgress = false
recipes[1].craftable = false
cfg.BrewRecipe = "#1 explicitly selected"
root.CFrame = home
sent, craftError = runAlchemyCycle()
assert(sent == true and craftError == nil,
    "an explicitly selected recipe was blocked by stale local predicates")
assert(calls[#calls].payload.recipeId == 1,
    "explicit recipe server validation used the wrong id")

fakeClock = 30
remoteMode = "reject"
inProgress = false
cfg.BrewRecipe = "#4 explicit rejection"
root.CFrame = home
sent, craftError = runAlchemyCycle()
assert(sent == false and string.find(craftError, "fixture rejection", 1, true) ~= nil,
    "structured server rejection was reported as success")
assert(root.CFrame == home and alchemyTelemetry.confirmed == false,
    "rejected craft did not cleanly restore its transaction")

fakeClock = 40
remoteMode = "accept"
inProgress = false
readyForPickup = false
recipes[1].craftable = true
cfg.BrewRecipe = "Best craftable"
resetAlchemyRecovery()
alchemyInvokeLease.completed = {{
    action = "ALCHEMY_CRAFT_RECIPE",
    payload = {{ recipeId = 4 }},
    sent = true,
    response = {{ success = false, error = "late fixture rejection" }},
    recovery = {{
        key = "Best craftable|4,1",
        candidateIds = {{ 4, 1 }},
        cursor = 1,
    }},
}}
local callsBeforeLateRejection = #calls
sent, craftError = runAlchemyCycle()
assert(sent == false and string.find(craftError, "late fixture rejection", 1, true) ~= nil,
    "late structured rejection was lost after timeout")
assert(#calls == callsBeforeLateRejection,
    "late completion triggered a duplicate recipe request")

fakeClock = 44
remoteMode = "accept-one"
sent, craftError = runAlchemyCycle()
assert(sent == true and craftError == nil and calls[#calls].payload.recipeId == 1,
    "late rejection after reload did not preserve Best candidate rotation")

fakeClock = 100
remoteMode = "accept"
inProgress = false
readyForPickup = false
cfg.BrewRecipe = "#4 stale lease recovery"
alchemyInvokeLease.pending = true
alchemyInvokeLease.startedAt = 1
local callsBeforeStaleLease = #calls
alchemyBroomPending = function() return true end
sent, craftError = runAlchemyCycle()
assert(sent == false and alchemyTelemetry.status == "waiting for Broom travel"
    and #calls == callsBeforeStaleLease
    and alchemyInvokeLease.pending == false,
    "Broom gate prevented an abandoned lease from being retired")
alchemyBroomPending = function() return false end
fakeClock = 101
sent, craftError = runAlchemyCycle()
assert(sent == true and craftError == nil
    and #calls == callsBeforeStaleLease + 1,
    "Alchemy did not resume after stale-lease recovery and Broom release")

fakeClock = 200
inProgress = false
readyForPickup = false
cfg.BrewRecipe = "#4 timeout hold"
root.CFrame = home
delayed = {{}}
local pendingInvokeCallback = nil
spawnHook = function(callback) pendingInvokeCallback = callback end
local resumesBeforeTimeout = resumeCalls
sent, craftError = runAlchemyCycle()
assert(sent == false and string.find(craftError, "timed out", 1, true) ~= nil,
    "full Alchemy cycle did not expose its bounded timeout")
assert(root.CFrame.name == "actor+offset"
    and alchemyBusy == true
    and alchemyInvokeLease.pending == true,
    "timeout abandoned the actor or physical lock before the watchdog")
assert(#delayed == 1 and delayed[1].seconds == 10,
    "Alchemy travel watchdog was not scheduled for the bounded hold")
delayed[1].callback()
assert(root.CFrame == home and alchemyBusy == false
    and resumeCalls == resumesBeforeTimeout + 1,
    "watchdog did not restore the farm and release movement")
assert(alchemyInvokeLease.pending == true,
    "watchdog incorrectly released the unresolved network lease")
pendingInvokeCallback()
assert(alchemyInvokeLease.pending == false
    and type(alchemyInvokeLease.completed) == "table",
    "late callback did not complete the shared lease safely")
print("alchemy_flow_smoke=ok")
"""
        completed = run_luau(fixture)
        self.assertEqual(
            completed.returncode,
            0,
            f"alchemy flow smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("alchemy_flow_smoke=ok", completed.stdout)

    def test_worker_and_ui_preserve_verified_contract(self):
        source = (REPO_ROOT / "games" / "magicloot.lua").read_text(encoding="utf-8")
        worker = core_slice(
            "    task.spawn(function() -- alchemy",
            "    task.spawn(function() -- gear",
        )
        self.assertIn("pcall(runAlchemyCycle)", worker)
        self.assertIn("configReady and", worker)
        self.assertIn("task.wait(2)", worker)
        self.assertNotIn('cfg.FarmMode ~= "Walking"', source)
        self.assertNotIn('cfg.FarmMode ~= "Running"', source)
        self.assertNotIn('sendAction("ALCHEMY_PICKUP_FINISH_POTION")', source)
        self.assertIn('"ALCHEMY_PICKUP_FINISH_POTION"', ALCHEMY_HELPERS)
        self.assertIn('"ALCHEMY_CRAFT_RECIPE"', ALCHEMY_HELPERS)
        self.assertIn("local function invokeAlchemyAction", ALCHEMY_HELPERS)
        self.assertIn("pcall(invokeAction, action, payload)", ALCHEMY_HELPERS)
        self.assertIn("waitForAlchemyConfirmation", ALCHEMY_HELPERS)
        self.assertIn("if not sessionAlive then", ALCHEMY_HELPERS)
        self.assertIn("alchemyInvokeLease.pending", ALCHEMY_HELPERS)
        self.assertIn("ALCHEMY_STALE_LEASE_SECONDS", ALCHEMY_HELPERS)
        self.assertIn('pcall(previousUnload, "reload")', source)
        self.assertIn('reason == "reload"', source)
        self.assertIn("alchemyInvokeLease.returnHoldUntil", source)
        self.assertIn("returnTravelPending = function()", source)
        self.assertIn("alchemyInvokeLease.travel == staleAlchemyTravel", source)
        self.assertIn("scheduleAlchemyTravelWatchdog(travel, 10)", ALCHEMY_HELPERS)
        self.assertIn("if travel == nil then", ALCHEMY_HELPERS)
        self.assertIn('BrewRecipe = "Best craftable"', source)
        self.assertIn("AutoPickupPotion = true", source)
        self.assertIn('group:AddDropdown("BrewRecipe"', source)
        self.assertIn("pcall(alchemy.GetRecipeList)", ALCHEMY_HELPERS)
        self.assertIn("pcall(cfgFind.FindCfgByID, potionId, 9)", ALCHEMY_HELPERS)
        self.assertIn("pcall(helper.TranslateByKey, key)", ALCHEMY_HELPERS)
        self.assertIn('string.match(selection, "^#(%d+)")', ALCHEMY_HELPERS)
        self.assertNotIn('GetCfgByName, "potionConf"', ALCHEMY_HELPERS)
        recipe_ui = core_slice(
            '        local recipeValues = alchemyDropdownValues()',
            '        group:AddToggle("AutoDrinkPotion"',
        )
        self.assertNotIn("if #recipeValues == 1 then", recipe_ui)
        self.assertNotIn("fingerprint = refreshedFingerprint\n                    break", recipe_ui)
        self.assertIn('table.concat(recipeValues, "\\30")', recipe_ui)
        self.assertLess(
            source.index("pauseAlchemyMovement()", source.index("local function beginAlchemyTravel")),
            source.index("root.CFrame = destination", source.index("local function beginAlchemyTravel")),
        )
        movement_start = source.index("    local function updateMovement()")
        busy_start = source.index(
            '        if alchemyBusy or type(alchemyInvokeLease.travel) == "table" then',
            movement_start,
        )
        busy_gate = source[
            busy_start : source.index("        local full = bagFull()", busy_start)
        ]
        self.assertIn("pauseAlchemyMovement()", busy_gate)
        self.assertIn("alchemyInvokeLease.travel", busy_gate)
        self.assertNotIn("alchemyInvokeLease.pending", busy_gate)
        self.assertNotIn("stopMovementModes()", busy_gate)
        locomotion = (REPO_ROOT / "games" / "magicloot_locomotion.lua").read_text(
            encoding="utf-8"
        )
        self.assertIn("if broom.suspended then", locomotion)
        self.assertIn("function api:SetBroomSuspended(suspended)", locomotion)
        self.assertIn("loco:SetBroomSuspended(true)", source)
        self.assertIn("loco:SetBroomSuspended(false)", source)
        pause = locomotion[
            locomotion.index("    function api:PauseWalking()") : locomotion.index(
                "    function api:Stop()", locomotion.index("    function api:PauseWalking()")
            )
        ]
        self.assertIn("stopMovement()", pause)
        self.assertNotIn("resetAll()", pause)


if __name__ == "__main__":
    unittest.main()
