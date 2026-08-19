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
    "    local alchemyBusy = false",
    "    -- Attack -----------------------------------------------------------------",
)


class AlchemyFlowTests(unittest.TestCase):
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
local waits = {{}}
local calls = {{}}
local pauseCalls = 0
local refreshCalls = 0
local task = {{
    wait = function(seconds) table.insert(waits, seconds) end,
    delay = function(_seconds, _callback) end,
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
local readyForPickup = false
local recipeListReads = 0
local potionConfReads = 0
local potionFindCalls = 0
local translationCalls = 0
local recipesReady = false
local translationsReady = false
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
        return inProgress
    end,
    IsBrewReadyForPickup = function(actualPlayer)
        assert(actualPlayer == player, "pickup check received the wrong player")
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

{ALCHEMY_HELPERS}

pauseAlchemyMovement = function() pauseCalls += 1 end

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
assert(sent == true and craftError == nil, "craft cycle failed")
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
    and alchemyTelemetry.inProgress == false,
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
        self.assertIn("task.wait(2)", worker)
        self.assertNotIn('cfg.FarmMode ~= "Walking"', source)
        self.assertNotIn('cfg.FarmMode ~= "Running"', source)
        self.assertNotIn('sendAction("ALCHEMY_PICKUP_FINISH_POTION")', source)
        self.assertIn('"ALCHEMY_PICKUP_FINISH_POTION"', ALCHEMY_HELPERS)
        self.assertIn('"ALCHEMY_CRAFT_RECIPE"', ALCHEMY_HELPERS)
        self.assertIn("pcall(\n                    invokeAction", ALCHEMY_HELPERS)
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
        busy_gate = source[
            source.index("        if alchemyBusy then") : source.index(
                "        local full = bagFull()", source.index("        if alchemyBusy then")
            )
        ]
        self.assertIn("pauseAlchemyMovement()", busy_gate)
        self.assertNotIn("stopMovementModes()", busy_gate)
        locomotion = (REPO_ROOT / "games" / "magicloot_locomotion.lua").read_text(
            encoding="utf-8"
        )
        pause = locomotion[
            locomotion.index("    function api:PauseWalking()") : locomotion.index(
                "    function api:Stop()", locomotion.index("    function api:PauseWalking()")
            )
        ]
        self.assertIn("stopMovement()", pause)
        self.assertNotIn("resetAll()", pause)


if __name__ == "__main__":
    unittest.main()
