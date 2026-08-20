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
    "    local alchemyReturnPending = function() return false end",
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
ALCHEMY_LEGACY_MIGRATION = core_slice(
    "    -- Migrate a request handed off by the previous physical-Alchemy build.",
    "    -- Common helpers:",
)


class AlchemyFlowTests(unittest.TestCase):
    def test_legacy_physical_lease_is_cleaned_without_overwriting_new_travel(self):
        fixture = f"""
local vectorMt = {{
    __sub = function(left, right)
        return {{ Magnitude = math.abs(left.value - right.value) }}
    end,
}}
local function vector(value)
    return setmetatable({{ value = value }}, vectorMt)
end

local home = {{ name = "old farm home" }}
local actor = {{ Position = vector(0) }}
local root = {{ Parent = {{}}, Position = vector(1), CFrame = {{ name = "actor" }} }}
local alchemyInvokeLease = {{
    pending = true,
    generation = 7,
    returnHoldUntil = 42,
    returnEpisodeToken = 3,
    travel = {{ root = root, home = home, destination = actor }},
    holdUntil = 99,
}}
do
{ALCHEMY_LEGACY_MIGRATION}
end
assert(root.CFrame == home, "nearby legacy actor trip was not restored once")
assert(alchemyInvokeLease.travel == nil and alchemyInvokeLease.holdUntil == nil,
    "legacy physical lease was not cleared")
assert(alchemyInvokeLease.pending == true
    and alchemyInvokeLease.generation == 7
    and alchemyInvokeLease.returnHoldUntil == 42
    and alchemyInvokeLease.returnEpisodeToken == 3,
    "legacy cleanup damaged the logical network/return lease")

local newerPosition = {{ name = "Broom destination" }}
root.Position = vector(100)
root.CFrame = newerPosition
alchemyInvokeLease.travel = {{ root = root, home = home, destination = actor }}
alchemyInvokeLease.holdUntil = 120
do
{ALCHEMY_LEGACY_MIGRATION}
end
assert(root.CFrame == newerPosition,
    "legacy cleanup overwrote a newer Broom/respawn position")
assert(alchemyInvokeLease.travel == nil and alchemyInvokeLease.holdUntil == nil,
    "far legacy physical lease was not retired")
print("alchemy_legacy_migration_smoke=ok")
"""
        completed = run_luau(fixture)
        self.assertEqual(
            completed.returncode,
            0,
            f"Alchemy legacy migration smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("alchemy_legacy_migration_smoke=ok", completed.stdout)

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
local configReady = true
local cfg = {{ AutoBrew = true, AutoPickupPotion = true }}
local challenge = 0
local function playerNumber(name)
    assert(name == "InDungeonChallenge", "wrong deferred Alchemy gate")
    return challenge
end
local alchemyInvokeLease = {{
    pending = false,
    generation = 0,
    inventoryEpoch = 0,
    inventoryStageActive = false,
}}
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
local function invokeAction(action, payload, beforeInvoke)
    if type(beforeInvoke) == "function" then
        local allowed, guardError = beforeInvoke()
        if allowed ~= true then return false, nil, guardError, false end
    end
    calls += 1
    assert(action == "ALCHEMY_CRAFT_RECIPE", "wrong deferred action")
    assert(payload.recipeId == 4, "wrong deferred recipe")
    return true, {{ accepted = true }}, nil, true
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
    {{ key = "priority-v2|Best craftable|4,1", candidateIds = {{ 4, 1 }}, cursor = 1 }}
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
    {{ key = "priority-v2|Best craftable|4,1", candidateIds = {{ 4, 1 }}, cursor = 1 }}
)
assert(raced == false and racedResponse == nil,
    "a callback that had not started before unload still sent its request")
assert(type(alchemyInvokeLease.completed) == "table"
    and type(alchemyInvokeLease.completed.recovery) == "table"
    and alchemyInvokeLease.completed.sent == false,
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
local challenge = 0
local challengeReadHook = function() end
local function playerNumber(name)
    assert(name == "InDungeonChallenge", "wrong Alchemy location state")
    challengeReadHook()
    return challenge
end
local cfg = {{
    AutoBrew = true,
    AutoPickupPotion = true,
    BrewRecipe = "Best craftable",
    FarmMode = "Walking",
}}
local sessionAlive = true
local configReady = true
local fakeClock = 0
local os = {{ clock = function() return fakeClock end }}
local alchemyInvokeLease = {{
    pending = false,
    generation = 0,
    inventoryEpoch = 0,
    inventoryStageActive = false,
}}
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
local rootCFrame = home
local cframeWrites = 0
local root = setmetatable({{ Parent = {{}} }}, {{
    __index = function(_, key)
        if key == "CFrame" then return rootCFrame end
        return nil
    end,
    __newindex = function(self, key, value)
        if key == "CFrame" then
            cframeWrites += 1
            rootCFrame = value
            return
        end
        rawset(self, key, value)
    end,
}})
local function characterParts()
    error("remote Alchemy must not inspect or reserve the character")
end

local inProgress = false
local progressNilReads = 0
local readyForPickup = false
local readyNilReads = 0
local readyReadHook = function() end
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
    {{ recipeId = 4, PID = 104, Rebirth = 1, craftable = false, ZhName = "药水四" }},
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
        readyReadHook()
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
    ResolveBrewActorCFrame = function()
        error("remote brew must not resolve or visit the Alchemy actor")
    end,
    ResolveFinishSpawnCFrame = function()
        error("remote pickup must not resolve or visit the Alchemy actor")
    end,
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
local function invokeAction(action, payload, beforeInvoke)
    if type(beforeInvoke) == "function" then
        local allowed, guardError = beforeInvoke()
        if allowed ~= true then return false, nil, guardError, false end
    end
    if remoteMode == "unavailable" then
        return false, nil, "NetWork unavailable", false
    end
    table.insert(calls, {{ action = action, payload = payload, root = root.CFrame }})
    if remoteMode == "accept"
        or (remoteMode == "accept-one" and payload ~= nil and payload.recipeId == 1)
    then
        pendingAction = action
        confirmationTicks = 0
    elseif remoteMode == "reject" then
        return true, {{ success = false, error = "fixture rejection" }}, nil, true
    end
    return true, {{ accepted = true }}, nil, true
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

local callsBeforeStageGate = #calls
challenge = nil
local blocked, blockedError = runAlchemyCycle()
assert(blocked == false and blockedError == nil
    and alchemyTelemetry.status == "waiting for dungeon state"
    and #calls == callsBeforeStageGate,
    "Alchemy guessed base while dungeon state was unknown")
challenge = 4
alchemyRecovery.key = "stale-before-stage"
alchemyRecovery.candidateIds = {{ 4, 1 }}
alchemyRecovery.cursor = 2
alchemyRecovery.nextAttemptAt = 999
blocked, blockedError = runAlchemyCycle()
assert(blocked == false and blockedError == nil
    and alchemyTelemetry.status == "waiting for base"
    and #calls == callsBeforeStageGate,
    "Alchemy ran while the player was inside a stage")
assert(alchemyRecovery.key == nil and #alchemyRecovery.candidateIds == 0,
    "a dungeon trip preserved a stale recipe priority for the next base return")
challenge = 0

local writesBeforeCraft = cframeWrites
local sent, craftError = runAlchemyCycle()
assert(sent == true and craftError == nil,
    "craft cycle failed: " .. tostring(craftError) .. " / " .. tostring(alchemyTelemetry.status))
assert(alchemyTelemetry.confirmedAction == "brew",
    "confirmed craft did not expose a typed brew outcome")
assert(#calls == 1 and calls[1].action == "ALCHEMY_CRAFT_RECIPE",
    "craft used the wrong transport/action")
assert(calls[1].payload.recipeId == 1,
    "Best craftable did not immediately select the locally available recipe")
assert(recipeListReads == 5, "Alchemy.GetRecipeList was not retried by UI and worker")
assert(potionConfReads == 0, "potionConf incorrectly replaced the recipe list")
assert(potionFindCalls == 12 and translationCalls == 15,
    "recipe display metadata was not localized independently of craft data: "
        .. tostring(potionFindCalls) .. "/" .. tostring(translationCalls))
assert(calls[1].root == home, "remote craft moved the player")
assert(root.CFrame == home, "remote craft changed the player's position")
assert(cframeWrites == writesBeforeCraft,
    "remote craft wrote Root.CFrame before restoring it")
assert(waits[1] == 0.4 and waits[2] == 0.25, "remote craft cadence changed")
assert(pauseCalls == 0 and resumeCalls == 0,
    "remote craft paused or resumed character movement")
assert(refreshCalls == 1, "craft did not refresh PotionBrewingGame")
assert(alchemyTelemetry.canUse == true
    and alchemyTelemetry.ready == false
    and alchemyTelemetry.inProgress == true
    and alchemyTelemetry.confirmed == true,
    "Alchemy gate diagnostics lost true/false states")
assert(alchemyTelemetry.checkTotal == 3
    and alchemyTelemetry.rebirthPassed == 2
    and alchemyTelemetry.materialChecks == 2
    and alchemyTelemetry.craftable == 1
    and alchemyTelemetry.predicateErrors == 0
    and alchemyTelemetry.chosenId == 1,
    "Best craftable diagnostics do not explain recipe selection")

inProgress = true
runAlchemyCycle()
assert(#calls == 1, "a second brew was sent while one was in progress")

cfg.AutoBrew = false
cfg.AutoPickupPotion = true
inProgress = false
readyForPickup = true
waits = {{}}
local writesBeforePickup = cframeWrites

local pickupChallengeReads = 0
challengeReadHook = function()
    pickupChallengeReads += 1
    if pickupChallengeReads == 2 then challenge = 4 end
end
local callsBeforePickupBaseGate = #calls
sent, craftError = runAlchemyCycle()
assert(sent == false
    and string.find(craftError, "left base", 1, true) ~= nil
    and #calls == callsBeforePickupBaseGate,
    "pickup emitted a remote after the final base recheck failed")
challengeReadHook = function() end
challenge = 0

sent = runAlchemyCycle()
assert(sent == true, "ready brewed potion was not picked up")
assert(alchemyTelemetry.confirmedAction == "pickup",
    "confirmed pickup was confused with a craft outcome")
assert(#calls == 2 and calls[2].action == "ALCHEMY_PICKUP_FINISH_POTION",
    "pickup did not use the verified InvokeServer action")
assert(calls[2].payload == nil, "pickup unexpectedly sent a payload")
assert(calls[2].root == home, "remote pickup moved the player")
assert(root.CFrame == home, "remote pickup changed the player's position")
assert(cframeWrites == writesBeforePickup,
    "remote pickup wrote Root.CFrame before restoring it")
assert(waits[1] == 0.5 and waits[2] == 0.25, "remote pickup cadence changed")
assert(pauseCalls == 0 and resumeCalls == 0,
    "remote pickup paused or resumed character movement")
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
    "unknown->ready was not rejected by the final remote recheck")
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
local readyReads = 0
readyReadHook = function()
    readyReads += 1
    if readyReads == 2 then readyForPickup = true end
end
local callsBeforeTravelRace = #calls
sent, craftError = runAlchemyCycle()
assert(sent == false and craftError == "a brewed potion must be picked up first",
    "ready state was not revalidated immediately before remote craft")
assert(#calls == callsBeforeTravelRace,
    "craft remote was sent after a potion became ready during selection")
readyReadHook = function() end
readyForPickup = false

fakeClock = 2.75
remoteMode = "accept"
cfg.BrewRecipe = "#1 final base gate"
resetAlchemyRecovery()
local challengeReads = 0
challengeReadHook = function()
    challengeReads += 1
    if challengeReads == 2 then challenge = 4 end
end
local callsBeforeFinalBaseGate = #calls
sent, craftError = runAlchemyCycle()
assert(sent == false
    and string.find(craftError, "left base", 1, true) ~= nil,
    "Alchemy did not cancel after Broom left base during recipe selection")
assert(#calls == callsBeforeFinalBaseGate,
    "Alchemy emitted a remote after the final base recheck failed")
challengeReadHook = function() end
challenge = 0
cfg.BrewRecipe = "Best craftable"
resetAlchemyRecovery()

fakeClock = 2.8
cfg.BrewRecipe = "#1 config reload gate"
local callsBeforeConfigGate = #calls
spawnHook = function(callback)
    configReady = false
    callback()
end
sent, craftError = runAlchemyCycle()
assert(sent == false
    and string.find(craftError, "config reloading", 1, true) ~= nil
    and #calls == callsBeforeConfigGate,
    "Alchemy emitted a remote while configuration was reloading")
configReady = true
spawnHook = function(callback) callback() end
cfg.BrewRecipe = "Best craftable"
resetAlchemyRecovery()

fakeClock = 2.9
remoteMode = "unavailable"
cfg.BrewRecipe = "#1 network warmup"
local callsBeforeNetworkWarmup = #calls
local attemptsBeforeNetworkWarmup = alchemyTelemetry.craftAttempts
sent, craftError = runAlchemyCycle()
assert(sent == false and craftError == "NetWork unavailable"
    and #calls == callsBeforeNetworkWarmup
    and alchemyTelemetry.craftAttempts == attemptsBeforeNetworkWarmup
    and alchemyRecovery.key == nil
    and alchemyRecovery.nextAttemptAt == 0,
    "network preparation failure skipped or cooled down the best recipe")
remoteMode = "accept"
sent, craftError = runAlchemyCycle()
assert(sent == true and craftError == nil and calls[#calls].payload.recipeId == 1,
    "recipe was not retried immediately when NetWork became available")
inProgress = false
cfg.BrewRecipe = "Best craftable"
resetAlchemyRecovery()

local validBrewResolver = alchemy.ResolveBrewActorCFrame
alchemy.ResolveBrewActorCFrame = nil
local callsBeforeTravelFailure = #calls
fakeClock = 3
remoteMode = "accept"
sent, craftError = runAlchemyCycle()
assert(sent == true and craftError == nil,
    "remote craft incorrectly required ResolveBrewActorCFrame")
assert(#calls == callsBeforeTravelFailure + 1 and root.CFrame == home,
    "remote craft did not stay independent of the actor resolver")
assert(alchemyTelemetry.travel == "remote",
    "remote Alchemy telemetry still reports a physical trip")

alchemy.ResolveBrewActorCFrame = validBrewResolver
remoteMode = "unconfirmed"
fakeClock = 5
inProgress = false
root.CFrame = home
waits = {{}}
sent, craftError = runAlchemyCycle()
assert(sent == false and craftError == "brew was not confirmed by game state",
    "transport without a brewing transition was reported as success")
assert(alchemyTelemetry.confirmed == false
    and alchemyTelemetry.status == "brew unconfirmed",
    "unconfirmed craft diagnostics are misleading")
assert(root.CFrame == home,
    "unconfirmed remote craft moved the original farm position")
assert(waits[1] == 0.4 and waits[2] == 0.25,
    "remote confirmation polling cadence changed")

fakeClock = 10
remoteMode = "accept"
root.CFrame = home
sent, craftError = runAlchemyCycle()
assert(sent == true and craftError == nil,
    "Best craftable did not advance after an unconfirmed server candidate")
assert(calls[#calls].payload.recipeId == 4,
    "Best craftable did not rotate to the next server-validated candidate")

-- This is the live regression: away from the UI both material predicates can
-- say false, while the same explicit recipe is accepted by the server. Best
-- must still emit the highest rebirth-eligible candidate instead of no-oping.
fakeClock = 15
inProgress = false
recipes[1].craftable = false
recipes[2].craftable = false
cfg.BrewRecipe = "Best craftable"
resetAlchemyRecovery()
local callsBeforeStaleMaterials = #calls
sent, craftError = runAlchemyCycle()
assert(sent == true and craftError == nil,
    "Best craftable trusted stale material predicates")
assert(#calls == callsBeforeStaleMaterials + 1
    and calls[#calls].payload.recipeId == 4
    and alchemyTelemetry.craftable == 0,
    "Best did not server-validate the highest rebirth-eligible recipe")
recipes[1].craftable = true
recipes[2].craftable = true

fakeClock = 16
resetAlchemyRecovery()
recipes[2].craftable = false
local firstStableCandidate = selectAlchemyRecipe(alchemy, "Best craftable")
assert(firstStableCandidate.id == 1,
    "positive material hint was not prioritized ahead of stale fallbacks")
finishAlchemyRecipeAttempt(false)
recipes[2].craftable = true
fakeClock = 19.9
local coolingCandidate, coolingError, coolingState = selectAlchemyRecipe(
    alchemy,
    "Best craftable"
)
assert(coolingCandidate == nil and coolingState == "cooldown",
    "changing material hints bypassed the active recovery cooldown")
fakeClock = 20
local secondStableCandidate = selectAlchemyRecipe(alchemy, "Best craftable")
assert(secondStableCandidate.id == 4,
    "changing material hints reset Best instead of preserving its frozen order")
resetAlchemyRecovery()

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
local callsBeforeExplicitRejection = #calls
sent, craftError = runAlchemyCycle()
assert(sent == false and string.find(craftError, "fixture rejection", 1, true) ~= nil,
    "structured server rejection was reported as success")
assert(#calls == callsBeforeExplicitRejection + 1
    and calls[#calls].payload.recipeId == 4,
    "one rejected cycle emitted zero or multiple recipe requests")
assert(root.CFrame == home and alchemyTelemetry.confirmed == false,
    "rejected craft did not cleanly restore its transaction")

fakeClock = 35
cfg.BrewRecipe = "Best craftable"
recipes[1].Rebirth = 9
recipes[2].Rebirth = 9
resetAlchemyRecovery()
local callsBeforeRebirthGate = #calls
sent, craftError = runAlchemyCycle()
assert(sent == false and craftError == "no rebirth-eligible recipe"
    and #calls == callsBeforeRebirthGate,
    "Best sent a server probe when every recipe was rebirth-locked")
recipes[1].Rebirth = 0
recipes[2].Rebirth = 1

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
        key = "priority-v2|Best craftable|4,1",
        candidateIds = {{ 4, 1 }},
        cursor = 1,
        inventoryEpoch = alchemyInvokeLease.inventoryEpoch,
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

-- A dungeon trip can change the inventory while a timed-out craft is still
-- resolving. Its old rejection must not resurrect the pre-trip priority.
fakeClock = 50
inProgress = false
readyForPickup = false
remoteMode = "accept"
resetAlchemyRecovery()
local oldInventoryEpoch = alchemyInvokeLease.inventoryEpoch
alchemyInvokeLease.completed = {{
    action = "ALCHEMY_CRAFT_RECIPE",
    payload = {{ recipeId = 4 }},
    sent = true,
    response = {{ success = false, error = "stale pre-trip rejection" }},
    recovery = {{
        key = "priority-v2|Best craftable|4,1",
        candidateIds = {{ 4, 1 }},
        cursor = 1,
        inventoryEpoch = oldInventoryEpoch,
    }},
}}
challenge = 4
local callsBeforeTripCompletion = #calls
runAlchemyCycle()
challenge = 0
sent, craftError = runAlchemyCycle()
assert(sent == false
    and string.find(craftError, "stale pre-trip rejection", 1, true) ~= nil
    and alchemyRecovery.key == nil,
    "late rejection restored a recipe order from before the dungeon trip")
assert(#calls == callsBeforeTripCompletion,
    "late rejection emitted a request while reconciling changed inventory")
sent, craftError = runAlchemyCycle()
assert(sent == true and craftError == nil and calls[#calls].payload.recipeId == 4,
    "returning to base did not freshly rank the newly available best recipe")

fakeClock = 55
inProgress = false
resetAlchemyRecovery()
alchemyInvokeLease.completed = {{
    action = "ALCHEMY_CRAFT_RECIPE",
    payload = {{ recipeId = 4 }},
    sent = true,
    response = {{ success = false, error = "legacy rejection without epoch" }},
    recovery = {{
        key = "priority-v2|Best craftable|4,1",
        candidateIds = {{ 4, 1 }},
        cursor = 1,
    }},
}}
sent, craftError = runAlchemyCycle()
assert(sent == false
    and string.find(craftError, "legacy rejection without epoch", 1, true) ~= nil
    and alchemyRecovery.key == nil,
    "legacy snapshot without an epoch was trusted after a dungeon trip")

-- A detached callback can be cancelled by reload before it ever reaches the
-- remote. Reconciliation must retry the same best candidate without rotating
-- or imposing a server-rejection cooldown.
fakeClock = 60
inProgress = false
readyForPickup = false
resetAlchemyRecovery()
alchemyInvokeLease.completed = {{
    action = "ALCHEMY_CRAFT_RECIPE",
    payload = {{ recipeId = 4 }},
    sent = false,
    err = "alchemy session closed before request",
    recovery = {{
        key = "priority-v2|Best craftable|4,1",
        candidateIds = {{ 4, 1 }},
        cursor = 1,
        inventoryEpoch = alchemyInvokeLease.inventoryEpoch,
    }},
}}
local callsBeforeCancelledCompletion = #calls
sent, craftError = runAlchemyCycle()
assert(sent == false
    and craftError == "alchemy session closed before request"
    and alchemyRecovery.key == nil
    and alchemyRecovery.nextAttemptAt == 0,
    "a request cancelled before send skipped or cooled down a recipe")
assert(#calls == callsBeforeCancelledCompletion,
    "cancelled late completion unexpectedly emitted a remote")
sent, craftError = runAlchemyCycle()
assert(sent == true and craftError == nil and calls[#calls].payload.recipeId == 4,
    "cancelled-before-send reconciliation did not retry the same best recipe")

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
assert(sent == true and craftError == nil
    and #calls == callsBeforeStaleLease + 1
    and alchemyInvokeLease.pending == false,
    "remote Alchemy was blocked by Broom after stale-lease recovery")
alchemyBroomPending = function() return false end

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
assert(root.CFrame == home and alchemyInvokeLease.pending == true,
    "remote timeout moved or physically locked the character")
assert(#delayed == 0 and resumeCalls == resumesBeforeTimeout,
    "remote timeout scheduled a physical travel watchdog")
assert(alchemyInvokeLease.pending == true,
    "remote timeout incorrectly released the unresolved network lease")
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
        self.assertIn("if configReady then", worker)
        self.assertIn("task.wait(0.5)", worker)
        self.assertIn("nextAutoSellAt", worker)
        self.assertIn("os.clock() + 2", worker)
        self.assertNotIn('cfg.FarmMode ~= "Walking"', source)
        self.assertNotIn('cfg.FarmMode ~= "Running"', source)
        self.assertNotIn('sendAction("ALCHEMY_PICKUP_FINISH_POTION")', source)
        self.assertIn('"ALCHEMY_PICKUP_FINISH_POTION"', ALCHEMY_HELPERS)
        self.assertIn('"ALCHEMY_CRAFT_RECIPE"', ALCHEMY_HELPERS)
        self.assertIn("local function invokeAlchemyAction", ALCHEMY_HELPERS)
        self.assertIn(
            "callOk, sent, response, err, didInvoke = pcall(",
            ALCHEMY_HELPERS,
        )
        self.assertIn("outcome.didInvoke = didInvoke == true", ALCHEMY_HELPERS)
        self.assertIn(
            "alchemyRequestDidNotStart(err, didInvoke)",
            ALCHEMY_HELPERS,
        )
        self.assertIn("invokeAction,\n                action,", ALCHEMY_HELPERS)
        self.assertIn("payload,\n                beforeInvoke", ALCHEMY_HELPERS)
        self.assertIn("waitForAlchemyConfirmation", ALCHEMY_HELPERS)
        self.assertIn("if not sessionAlive then", ALCHEMY_HELPERS)
        self.assertIn("alchemyInvokeLease.pending", ALCHEMY_HELPERS)
        self.assertIn("ALCHEMY_STALE_LEASE_SECONDS", ALCHEMY_HELPERS)
        self.assertIn('pcall(previousUnload, "reload")', source)
        self.assertIn("alchemyInvokeLease.returnHoldUntil", source)
        self.assertIn("returnTravelPending = function()", source)
        self.assertIn('BrewRecipe = "Best craftable"', source)
        self.assertIn("AutoPickupPotion = true", source)
        self.assertIn('group:AddDropdown("BrewRecipe"', source)
        self.assertIn("pcall(alchemy.GetRecipeList)", ALCHEMY_HELPERS)
        self.assertIn("pcall(cfgFind.FindCfgByID, potionId, 9)", ALCHEMY_HELPERS)
        self.assertIn("pcall(helper.TranslateByKey, key)", ALCHEMY_HELPERS)
        self.assertIn('string.match(selection, "^#(%d+)")', ALCHEMY_HELPERS)
        self.assertIn('if reason ~= "rebirth" then', ALCHEMY_HELPERS)
        self.assertIn("craftable and prioritizedIds or fallbackIds", ALCHEMY_HELPERS)
        self.assertIn('local recoveryKey = "priority-v2|"', ALCHEMY_HELPERS)
        self.assertNotIn('GetCfgByName, "potionConf"', ALCHEMY_HELPERS)
        recipe_ui = core_slice(
            '        local recipeValues = alchemyDropdownValues()',
            '        group:AddToggle("AutoDrinkPotion"',
        )
        self.assertNotIn("if #recipeValues == 1 then", recipe_ui)
        self.assertNotIn("fingerprint = refreshedFingerprint\n                    break", recipe_ui)
        self.assertIn('table.concat(recipeValues, "\\30")', recipe_ui)
        cycle = core_slice(
            "    local function runAlchemyCycle()",
            "    -- Attack -----------------------------------------------------------------",
        )
        self.assertIn('alchemyTelemetry.travel = "remote"', cycle)
        self.assertIn('playerNumber("InDungeonChallenge")', cycle)
        self.assertIn('alchemyTelemetry.status = "waiting for base"', cycle)
        self.assertNotIn("beginAlchemyTravel", cycle)
        self.assertNotIn("reaffirmAlchemyTravel", cycle)
        self.assertNotIn("finishAlchemyTravel", cycle)
        self.assertNotIn("ResolveBrewActorCFrame", cycle)
        self.assertNotIn("ResolveFinishSpawnCFrame", cycle)
        self.assertNotIn("root.CFrame", cycle)
        self.assertNotIn("alchemyBroomPending()", cycle)
        self.assertNotIn("alchemyReturnPending()", cycle)
        locomotion = (REPO_ROOT / "games" / "magicloot_locomotion.lua").read_text(
            encoding="utf-8"
        )
        self.assertIn("if broom.suspended then", locomotion)
        self.assertIn("function api:SetBroomSuspended(suspended)", locomotion)
        pause = locomotion[
            locomotion.index("    function api:PauseWalking()") : locomotion.index(
                "    function api:Stop()", locomotion.index("    function api:PauseWalking()")
            )
        ]
        self.assertIn("stopMovement()", pause)
        self.assertNotIn("resetAll()", pause)


if __name__ == "__main__":
    unittest.main()
