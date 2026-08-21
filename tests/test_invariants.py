"""Behavioural invariants for the locomotion module and the core script.

These checks encode the project rules that must never regress:

  * Walking and Running never teleport or change speed, drive humanoid:Move
    from a render-step binding, and are the only place allowed to reset.
  * Broom sends only the selected-stage request and never toggles/equips it.
  * The core keeps the documented worker cadences and the shared attack block.
"""

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def read(relative):
    return (REPO_ROOT / relative).read_text(encoding="utf-8")


class LocomotionInvariantTests(unittest.TestCase):
    def setUp(self):
        self.source = read("games/magicloot_locomotion.lua")

    def test_walking_uses_render_step_binding(self):
        self.assertIn("BindToRenderStep", self.source)
        self.assertIn("Enum.RenderPriority.Character.Value + 1", self.source)

    def test_walking_drives_humanoid_move(self):
        self.assertIn("humanoid:Move(currentPlanar.Unit, false)", self.source)

    def test_walking_never_teleports_or_changes_speed(self):
        for banned in (
            "WalkSpeed",
            "JumpPower",
            "JumpHeight",
            "TweenService",
            "MoveTo(",
            ".CFrame =",
            "CFrame.new(",
            "CFrame.lookAt(",
        ):
            self.assertNotIn(banned, self.source, f"locomotion must not use {banned}")

    def test_walking_detects_footprint_in_object_space(self):
        self.assertIn("PointToObjectSpace", self.source)

    def test_walking_finishes_at_the_magic_stage_center(self):
        self.assertNotIn("resolveWalkingDestination", self.source)
        self.assertNotIn("_halfwayFootprintDistance", self.source)
        self.assertIn("local function chooseInitialDestination", self.source)
        self.assertIn("state.finalDestination = destination", self.source)
        self.assertIn("state.destination = destination", self.source)

    def test_running_orbits_the_stage_center_with_live_radius(self):
        core = read("games/magicloot.lua")
        self.assertIn("RunningDistance = 12", core)
        self.assertIn("local RUNNING_ORBIT_STEP = math.rad(45)", self.source)
        self.assertIn("local RUNNING_JUMP_INTERVAL = 0.9", self.source)
        self.assertIn("local function runningOrbitPoint", self.source)
        self.assertIn("local function startRunningOrbit", self.source)
        self.assertIn("local function updateRunningOrbit", self.source)
        self.assertIn("state.orbitAngle = state.orbitAngle + RUNNING_ORBIT_STEP", self.source)
        self.assertIn('context.option,\n            "RunningDistance"', self.source)
        self.assertIn('return { "Walking", "Running" }', self.source)
        self.assertIn('return mode == "Walking" or mode == "Running"', self.source)
        self.assertIn('state.mode == "Running" and state.enteredStage', self.source)
        self.assertIn("jumpWhileRunning(humanoid, os.clock())", self.source)
        self.assertIn("humanoid:ChangeState(Enum.HumanoidStateType.Jumping)", self.source)
        self.assertIn('group:AddSlider("RunningDistance"', core)
        self.assertNotIn("local function updateRunning", core)
        self.assertNotIn("humanoid:MoveTo(movementTarget)", core)
        self.assertNotIn('CreateSection("Running points")', core)
        movement_start = core.index("    local function updateMovement()")
        movement = core[
            movement_start : core.index("    -- Combat", movement_start)
        ]
        self.assertIn('if mode == "Walking" or mode == "Running" then', movement)
        self.assertIn("return loco:Update(\n                    mode,", movement)

    def test_reset_flow_is_gated_and_bounded(self):
        self.assertIn("Enum.HumanoidStateType.Dead", self.source)
        self.assertIn("state.resetUsedStage", self.source)
        self.assertIn("state.blockedStage", self.source)
        self.assertIn("settleUntil", self.source)

    def test_enter_delay_is_rearmed_per_route(self):
        self.assertIn("routeChangedAt", self.source)
        self.assertIn("readEnterDelay", self.source)

    def test_stage_entry_releases_attacks(self):
        self.assertIn("enteredStage", self.source)
        self.assertIn("function api:BlocksAttack()", self.source)

    def test_broom_stage_only_remote_flow(self):
        self.assertIn('FireServer("关卡跳关请求", stage)', self.source)
        self.assertNotIn('InvokeServer("上下扫帚")', self.source)
        self.assertNotIn("NetWorkRemoteFunction", self.source)
        request_start = self.source.index("    local function requestBroomStage(")
        request_end = self.source.index("    local function disarmBroom()", request_start)
        request = self.source[request_start:request_end]
        self.assertNotIn("task.wait(0.25)", request)
        self.assertIn('return true, "stage request"', request)

    def test_broom_catalog_adds_stage_28_but_not_the_farm_ceiling(self):
        self.assertIn("local broomStages = { 4, 8, 13, 18, 23, 28 }", self.source)
        self.assertIn("[28] = true", self.source)
        self.assertIn('Values = { "4", "8", "13", "18", "23", "28" }', self.source)
        self.assertNotIn("[32] = true", self.source)

    def test_broom_single_flight_protection(self):
        for marker in (
            "transactionActive",
            "epoch",
            "invalidateBroomTransaction",
        ):
            self.assertIn(marker, self.source)

    def test_broom_base_detection_uses_challenge_value(self):
        self.assertIn("InDungeonChallenge", self.source)
        self.assertIn("tonumber(value.Value)", self.source)
        self.assertNotIn("CharacterAdded", self.source)
        self.assertNotIn("Humanoid.Died", self.source)

    def test_broom_startup_waits_for_config_and_room_confirmation(self):
        for marker in (
            "configReady",
            "function api:OnConfigLoaded()",
            "local BROOM_INITIAL_DELAY = 1",
            "local BROOM_CONFIRM_TIMEOUT = 5",
            "local MAX_BROOM_REQUEST_ATTEMPTS = 3",
            "broom.requestAttempts = broom.requestAttempts + 1",
            'broom.status = "broom waiting for InDungeonChallenge"',
        ):
            self.assertIn(marker, self.source)
        challenge_guard = self.source.index("        if challenge > 0 then")
        request_lookup = self.source.index(
            "        local requestRemote, locateError = locateBroomRequestRemote()"
        )
        self.assertLess(challenge_guard, request_lookup)
        self.assertIn("local function broomPriorityGate()", self.source)
        self.assertIn("local priorityAllowed, priorityStatus", self.source)
        self.assertIn("broom.armed = true", self.source)
        self.assertIn("retry cycle in %.0fs", self.source)


class CoreInvariantTests(unittest.TestCase):
    def setUp(self):
        self.source = read("games/magicloot.lua")

    def test_combat_cadence(self):
        self.assertIn("task.wait(0.2)", self.source)

    def test_farm_stage_ceiling_is_32(self):
        self.assertIn("local MAX_FARM_STAGE = 32", self.source)
        self.assertIn("for stage = 1, MAX_FARM_STAGE do", self.source)

    def test_click_cadence_formula(self):
        self.assertIn("1 / math.max(1, tonumber(cfg.ClickRate) or 10)", self.source)

    def test_pickup_batches_every_scan_at_original_cadence(self):
        pickup = self.source[
            self.source.index("    -- Pickup worker") :
            self.source.index("    -- Progress workers")
        ]
        self.assertIn(
            "activateSortedDrops(sorted, minValue, selectedItemIds)", pickup
        )
        self.assertIn("task.wait(0.4)", pickup)
        self.assertNotIn("task.wait(0.5)", pickup)

    def test_sell_cadence(self):
        self.assertIn('local ReplicatedFirst = game:GetService("ReplicatedFirst")', self.source)
        self.assertIn("local utils = requireUtilsSystem(ReplicatedFirst)", self.source)
        self.assertIn("if utils ~= nil then net.clientUtils = utils end", self.source)
        self.assertIn('playerData.GetPlrDataByKey, player, "Bag"', self.source)
        self.assertIn("Common.sellOnlyIds", self.source)
        self.assertIn('"SELL_MATERIAL",\n            { onlyIDList = onlyIds },', self.source)
        self.assertNotIn('sendAction("SELL_MATERIAL", { onlyIDList = {} })', self.source)
        self.assertIn("task.wait(2)", self.source)

    def test_train_zone_update_payload(self):
        self.assertIn(
            'sendAction("TRAIN_ZONE_UPDATE", { trainId = trainId })', self.source
        )

    def test_magic_progress_remote_contracts(self):
        self.assertIn('RebirthLimit = 41', self.source)
        self.assertIn('Default = 41, Min = 1, Max = 41', self.source)
        self.assertIn('invokeAction("PLAYER_REBIRTH")', self.source)
        self.assertNotIn('sendAction("PLAYER_REBIRTH")', self.source)
        self.assertIn('configByName("rebirthConf")', self.source)
        self.assertIn("row.LvNeed", self.source)
        self.assertIn("playerLevel() < levelRequirement", self.source)
        self.assertIn('indexView.buildAllTabSnapshots,', self.source)
        self.assertIn('invokeAction("INDEX_CLAIM_REWARD", {', self.source)
        self.assertIn('tag = tag,', self.source)
        self.assertIn('progress = snapshot.targetProgress,', self.source)
        self.assertNotIn('sendAction("INDEX_CLAIM_REWARD")', self.source)

    def test_magic_train_selection_and_click_contract(self):
        self.assertIn('TrainGround = "Best available"', self.source)
        self.assertIn('train.CanEnterTrainGround,\n            player,\n            trainId', self.source)
        self.assertIn('candidate.FindZonePartByTrainId,', self.source)
        self.assertIn('invokeAction("TRAIN_MANUAL_CLICK", {})', self.source)
        self.assertIn('AddDropdown("TrainGround"', self.source)
        self.assertIn('setRegisteredToggle("AutoFarm", false)', self.source)
        self.assertIn('setRegisteredToggle("AutoFarmSpecific", false)', self.source)
        self.assertIn('setRegisteredToggle("AutoTrain", false)', self.source)

    def test_magic_potion_contract_uses_selected_inventory_only_id(self):
        self.assertIn('Common.parseIdSelection(cfg.DrinkPotions)', self.source)
        self.assertIn('Common.selectedOnlyIds(bag, selectedIds)', self.source)
        self.assertIn(
            'invokeAction("DRINK_POTION", { onlyID = onlyId })', self.source
        )
        self.assertNotIn('sendAction("DRINK_POTION")', self.source)
        self.assertIn('AddDropdown("DrinkPotions"', self.source)

    def test_magic_gear_contract_uses_equip_id_and_item_type(self):
        self.assertIn('itemType = 9,', self.source)
        self.assertIn('itemType = 13,', self.source)
        self.assertIn('invokeAction("EQUIP_SHOP_BUY", {', self.source)
        self.assertIn('invokeAction("EQUIP_SHOP_EQUIP", {', self.source)
        self.assertIn('equipID = entry.id,', self.source)
        self.assertIn('itemType = kind.itemType,', self.source)
        self.assertNotIn('sendAction("EQUIP_SHOP_BUY"', self.source)
        self.assertNotIn('sendAction("EQUIP_SHOP_EQUIP"', self.source)
        self.assertIn('wand:AddToggle("AutoBuyWand"', self.source)
        self.assertIn('wand:AddToggle("AutoEquipWand"', self.source)
        self.assertIn('armor:AddToggle("AutoBuyArmor"', self.source)
        self.assertIn('armor:AddToggle("AutoEquipArmor"', self.source)

    def test_magic_selective_sell_contract(self):
        self.assertIn('AutoSellSpecific = false', self.source)
        self.assertIn('SellItems = {}', self.source)
        self.assertIn('Common.parseIdSelection(cfg.SellItems)', self.source)
        self.assertIn('sellAllMaterials(automaticSellSelection(), function()', self.source)
        self.assertIn('AddDropdown("SellItems"', self.source)
        self.assertIn('setRegisteredToggle("AutoSellSpecific", false)', self.source)
        self.assertIn('setRegisteredToggle("AutoSell", false)', self.source)

    def test_catalog_dropdowns_refresh_late_data_and_preserve_ids(self):
        self.assertIn('local function refreshCatalogDropdown(', self.source)
        self.assertIn('local selectedIds = Common.parseIdSelection(previous)', self.source)
        self.assertIn('element:SetValues(refreshed)', self.source)
        self.assertIn('resolveRuntimeModule("CfgFind", true)', self.source)
        self.assertIn('resolveGetData(true)', self.source)
        self.assertIn('local count = #Common.catalogEntries(result)', self.source)
        self.assertGreaterEqual(self.source.count('for _, raw in pairs(rawRecipes) do'), 2)
        self.assertIn('refreshCatalogDropdown(\n            sellItemsDropdown,', self.source)
        self.assertIn('refreshCatalogDropdown(\n            pickupItemsDropdown,', self.source)
        self.assertIn('refreshCatalogDropdown(\n            trainGroundDropdown,', self.source)
        self.assertIn('refreshCatalogDropdown(\n            recipeDropdown,', self.source)
        self.assertIn('refreshCatalogDropdown(\n            potionDropdown,', self.source)

    def test_legacy_unlimited_rebirth_setting_migrates_to_magic_limit(self):
        self.assertIn('decoded.RebirthLimit = 41', self.source)

    def test_magic_anti_afk_control_can_disable_and_restore_connections(self):
        self.assertIn('AntiAfk = true', self.source)
        self.assertIn('local function setAntiAfk(enabled)', self.source)
        self.assertIn('connection:Disable()', self.source)
        self.assertIn('connection:Enable()', self.source)
        self.assertIn('group:AddToggle("AntiAfk"', self.source)

    def test_magic_ground_volume_and_orbit_delay(self):
        footprint = self.source[
            self.source.index('    local function isOverFootprint') :
            self.source.index('    -- Character', self.source.index('    local function isOverFootprint'))
        ]
        self.assertIn('math.abs(localPoint.Y) <= part.Size.Y * 0.5', footprint)
        orbit = self.source[
            self.source.index('        if mode == "Orbit" then') :
            self.source.index('        setMovementStatus("unknown farm mode', self.source.index('        if mode == "Orbit" then'))
        ]
        self.assertIn('if not applyEnterDelay(stage) then return end', orbit)

    def test_shared_attack_block(self):
        self.assertIn("local function blocksAttack()", self.source)
        self.assertIn("loco:BlocksAttack()", self.source)

    def test_remote_action_names(self):
        for action in (
            "TRAIN_MANUAL_CLICK",
            "TRAIN_ZONE_UPDATE",
            "SELL_MATERIAL",
            "PLAYER_REBIRTH",
            "INDEX_CLAIM_REWARD",
            "CLAIM_ONLINE_AWARD",
            "DUNGEON_RETURN_TOWN",
            "DROP_PICKUP",
            "ALCHEMY_CRAFT_RECIPE",
            "ALCHEMY_PICKUP_FINISH_POTION",
            "DRINK_POTION",
            "EQUIP_SHOP_BUY",
            "EQUIP_SHOP_EQUIP",
        ):
            self.assertIn(action, self.source)

    def test_broom_flow_not_duplicated_in_core(self):
        self.assertNotIn("关卡跳关请求", self.source)
        self.assertNotIn("上下扫帚", self.source)

    def test_movement_worker_cadences(self):
        self.assertIn('cfg.FarmMode == "Orbit" and 0.05 or 0.25', self.source)

    def test_return_flow_uses_challenge_transitions(self):
        self.assertIn("playerNumber(\"InDungeonChallenge\")", self.source)

    def test_return_check_runs_independently_of_auto_farm(self):
        movement = self.source[
            self.source.index("    local function updateMovement()") :
            self.source.index("    -- Combat", self.source.index("    local function updateMovement()"))
        ]
        self.assertLess(
            movement.index("local full = bagFull()"),
            movement.index("if not (cfg.AutoFarm or cfg.AutoFarmSpecific) then"),
        )

    def test_return_capacity_uses_original_game_contract(self):
        self.assertIn("local BAG_CAPACITY_ITEM_ID = 5", self.source)
        self.assertIn("data.GetItemCountByID,", self.source)
        self.assertIn("player,\n                BAG_CAPACITY_ITEM_ID", self.source)
        self.assertNotIn("local getDataResolved", self.source)

    def test_return_has_live_bag_diagnostics(self):
        self.assertIn('group:AddLabel("Bag check: waiting...")', self.source)
        self.assertIn('"Bag: %s / %s • %s\\nAuto return: %s"', self.source)

    def test_return_keeps_retrying_until_replicated_confirmation(self):
        self.assertNotIn("MAX_RETURN_ATTEMPTS", self.source)
        self.assertNotIn("returnEpisode.blocked", self.source)
        self.assertIn("now - returnEpisode.lastAttemptAt >= 2", self.source)

    def test_pickup_prepares_the_prompt_like_magic(self):
        self.assertIn("prompt.HoldDuration = 0", self.source)
        self.assertIn("prompt.MaxActivationDistance = math.max(", self.source)
        self.assertIn("activatePrompt(prompt, cfg.PickupRange)", self.source)

    def test_selected_wand_is_stage_only_and_uses_stable_ids(self):
        locomotion = read("games/magicloot_locomotion.lua")
        self.assertIn('group:AddToggle("AutoEquipSelectedWand"', locomotion)
        self.assertIn('group:AddDropdown("SelectedWand"', locomotion)
        self.assertIn('if challenge == nil or challenge <= 0 then return end', locomotion)
        self.assertIn('pcall(bridge[4], "EQUIP_SHOP_EQUIP", {', locomotion)
        self.assertIn('loco:Install(wand, "Wand", selectedBridge)', self.source)

    def test_walking_reset_only_in_locomotion(self):
        self.assertNotIn("Enum.HumanoidStateType.Dead", self.source)

    def test_stage_resolution_paths(self):
        self.assertIn('"场景"', self.source)
        self.assertIn('"战斗区域"', self.source)

    def test_drop_schema_supports_itemid(self):
        self.assertIn('model.Name == "DropItem"', self.source)
        self.assertIn('model:GetAttribute("ItemId")', self.source)
        self.assertIn('itemId = itemId,', self.source)
        self.assertIn('model:GetAttribute("DropLanded")', self.source)
        self.assertIn('model:GetAttribute("GoldValue")', self.source)
        self.assertIn("container:GetDescendants()", self.source)
        self.assertNotIn('tierFolder:IsA("Model")', self.source)

    def test_pickup_activates_the_real_prompt_signal_or_exact_drop_id(self):
        self.assertIn("fireproximityprompt, prompt, 0", self.source)
        self.assertIn("firesignal, prompt.Triggered, player", self.source)
        self.assertIn('sendAction("DROP_PICKUP", dropId)', self.source)
        self.assertNotIn('sendAction("DROP_PICKUP", primaryPart)', self.source)
        self.assertIn('model:GetAttribute("Xyd")', self.source)

    def test_pickup_filters_by_dynamic_material_ids(self):
        loot_start = self.source.index('window:CreateTab({ Name = "Loot"')
        loot_end = self.source.index('-- Progress tab', loot_start)
        loot_ui = self.source[loot_start:loot_end]
        self.assertIn('group:AddToggle("PickupFilterItems"', loot_ui)
        self.assertIn('group:AddDropdown("PickupItems"', loot_ui)
        self.assertIn(
            'catalogDropdownValues("materialConf", "Material")', loot_ui
        )
        self.assertIn('MaxVisible = 5', loot_ui)
        self.assertNotIn("PickupFilterRarity", loot_ui)
        self.assertNotIn("PickupTiers", loot_ui)

        pickup = self.source[
            self.source.index("    -- Pickup worker") :
            self.source.index("    -- Progress workers")
        ]
        self.assertIn('Common.parseIdSelection(cfg.PickupItems)', pickup)
        self.assertIn('filterItems = cfg.PickupFilterItems == true', pickup)
        self.assertIn('itemIds = selectedItemIds', pickup)

    def test_zero_value_event_drops_bypass_value_and_item_filters(self):
        self.assertIn('entry.isEvent = Common.isEventDrop(entry.rawGold)', self.source)
        common = read("games/magicloot_common.lua")
        event_gate = common.split("function Common.gateDrop", 1)[1].split(
            "function Common.farmStageTarget", 1
        )[0]
        self.assertLess(
            event_gate.index("if entry.isEvent == true then"),
            event_gate.index("local minValue ="),
        )
        self.assertIn("if options.filterItems == true then", event_gate)

    def test_pickup_minimum_value_is_an_unbounded_numeric_input(self):
        loot_start = self.source.index('window:CreateTab({ Name = "Loot"')
        loot_end = self.source.index('-- Progress tab', loot_start)
        loot_ui = self.source[loot_start:loot_end]
        self.assertIn('group:AddInput("PickupMinValue"', loot_ui)
        self.assertNotIn('group:AddSlider("PickupMinValue"', loot_ui)
        self.assertNotIn("Max = 100000", loot_ui)
        self.assertIn('group:AddLabel("Minimum gold value (no limit)")', loot_ui)
        self.assertIn("Parser = parsePickupMinimumValue", loot_ui)

        parser = self.source.split(
            "    local function parsePickupMinimumValue(value)", 1
        )[1].split("    local configReady", 1)[0]
        self.assertIn("local numeric = tonumber(value)", parser)
        self.assertIn("numeric == math.huge", parser)
        self.assertIn("return math.max(0, math.floor(numeric))", parser)

    def test_physical_modes_dispatch_through_locomotion_module(self):
        self.assertIn('cfg.FarmMode == "Walking" or cfg.FarmMode == "Running"', self.source)
        self.assertIn('if mode == "Walking" or mode == "Running" then', self.source)
        self.assertIn("return loco:Update(\n                    mode,", self.source)

    def test_no_loadstring_in_core(self):
        self.assertNotIn("loadstring", self.source)

    def test_unload_destroys_all_owned_gui(self):
        self.assertIn("window.OnClose = unloadSession", self.source)
        self.assertIn("Callback = unloadSession", self.source)
        self.assertIn("__INFINITYGOLD_UNLOAD", self.source)
        self.assertIn("previousUnload", self.source)
        self.assertIn('"InfinityGoldToggle"', self.source)
        self.assertIn('"InfinityGoldLoaderToggle"', self.source)
        self.assertIn("sessionAlive = false", self.source)

    def test_config_persists_and_auto_loads(self):
        self.assertIn('local fallbackConfigPath = BRAND .. "_config.json"', self.source)
        self.assertIn("pcall(writefile, fallbackConfigPath, text)", self.source)
        self.assertIn("for _, path in ipairs({ configPath, fallbackConfigPath })", self.source)
        self.assertIn("cfg[name] = value", self.source)
        self.assertIn('notify("Config auto-loaded", 3)', self.source)
        self.assertIn("local loaded = loadConfig()", self.source)
        self.assertGreaterEqual(self.source.count("loco:OnConfigLoaded()"), 2)


class CommonInvariantTests(unittest.TestCase):
    def setUp(self):
        self.source = read("games/magicloot_common.lua")

    def test_common_has_no_roblox_globals(self):
        for banned in ("game:", "Instance.new", "workspace", "Vector3"):
            self.assertNotIn(banned, self.source)

    def test_sell_builder_uses_unique_ids_and_protects_materials(self):
        self.assertIn("function Common.sellOnlyIds", self.source)
        self.assertIn("tonumber(item.onlyID)", self.source)
        self.assertIn("tonumber(item.tp) == 2", self.source)
        self.assertIn("not protected", self.source)


class UiLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.source = read("ui/InfinityUI.lua")

    def test_close_delegates_to_core_unload(self):
        self.assertIn('type(window.OnClose) == "function"', self.source)
        self.assertIn("pcall(window.OnClose)", self.source)

    def test_global_input_connections_are_disconnected(self):
        self.assertIn("local function connectGlobal", self.source)
        self.assertIn("Library._connections = {}", self.source)
        self.assertNotIn("UserInputService.InputChanged:Connect", self.source)
        self.assertNotIn("UserInputService.InputEnded:Connect", self.source)
        self.assertNotIn("UserInputService.InputBegan:Connect", self.source)

    def test_minimize_hides_the_window_completely(self):
        self.assertNotIn("collapsed", self.source)
        self.assertNotIn("refreshCollapsed", self.source)
        self.assertIn("visible = false", self.source)
        self.assertIn("main.Visible = false", self.source)

    def test_dynamic_text_properties_reach_labels(self):
        helper = self.source.split("local function label", 1)[1].split(
            "local function resolveParent", 1
        )[0]
        for property_name in (
            "AnchorPoint",
            "AutomaticSize",
            "LayoutOrder",
            "TextTruncate",
            "TextWrapped",
        ):
            self.assertIn(
                f"textLabel.{property_name} = options.{property_name}",
                helper,
            )

    def test_multiline_content_participates_in_vertical_layout(self):
        self.assertIn('local paragraphLayout = Instance.new("UIListLayout")', self.source)
        self.assertIn("AutomaticSize = Enum.AutomaticSize.Y", self.source)
        self.assertIn("TextYAlignment = Enum.TextYAlignment.Top", self.source)


class FloatingButtonTests(unittest.TestCase):
    def setUp(self):
        self.source = read("games/magicloot.lua")

    def test_floating_button_position_survives_recreation(self):
        self.assertIn("local floatingPosition", self.source)
        self.assertIn("button.Position = floatingPosition", self.source)
        self.assertIn("floatingPosition = button.Position", self.source)

    def test_floating_button_tap_vs_drag(self):
        self.assertIn("local dragMoved = false", self.source)
        self.assertIn("delta.Magnitude < 6", self.source)
        self.assertIn("if dragMoved then", self.source)

    def test_floating_button_drag_is_clamped_to_viewport(self):
        self.assertIn("math.clamp(buttonOrigin.X + delta.X", self.source)
        self.assertIn("math.clamp(buttonOrigin.Y + delta.Y", self.source)

    def test_floating_button_anchor_matches_drag_math(self):
        # AbsolutePosition is the top-left corner; the button must be
        # top-left anchored or the first drag move jumps by its own size.
        self.assertIn("button.AnchorPoint = Vector2.new(0, 0)", self.source)
        self.assertIn("local floatingPosition = UDim2.new(1, -70, 1, -70)", self.source)
        self.assertNotIn("button.AnchorPoint = Vector2.new(1, 1)", self.source)


class DropdownTests(unittest.TestCase):
    def setUp(self):
        self.source = read("ui/InfinityUI.lua")

    def test_header_click_toggles_the_list(self):
        self.assertIn("local function setOpen(open)", self.source)
        self.assertIn("setOpen(not listFrame.Visible)", self.source)

    def test_tap_outside_closes_the_list(self):
        self.assertIn("connectGlobal(UserInputService.InputBegan", self.source)
        self.assertIn("setOpen(false)", self.source)

    def test_list_is_capped_and_scrollable(self):
        self.assertIn('local listFrame = Instance.new("ScrollingFrame")', self.source)
        self.assertIn("MaxVisible", self.source)
        self.assertIn("math.min(#values, maxVisible)", self.source)
        self.assertIn("ScrollBarThickness", self.source)
        self.assertIn("AutomaticCanvasSize", self.source)

    def test_open_list_reserves_layout_space(self):
        self.assertIn("local function listHeight()", self.source)
        self.assertIn("open and (54 + listHeight()) or 48", self.source)

    def test_set_values_rebuilds_visible_options(self):
        set_values = self.source.split("function element.SetValues", 1)[1].split(
            "function element.Get", 1
        )[0]
        self.assertIn("rebuildList()", set_values)

    def test_dropdown_separates_stable_value_from_visible_name(self):
        self.assertIn('rawValue = entry.Value or entry.value', self.source)
        self.assertIn('rawLabel = entry.Text or entry.text', self.source)
        self.assertIn('valueLabels[value] = display', self.source)
        self.assertIn('Text = valueLabels[entry] or entry', self.source)
        self.assertIn('table.insert(chosen, entry)', self.source)
        self.assertIn('string.match(candidate, "^#?(%d+)%s+")', self.source)

    def test_arrow_sits_inside_the_header(self):
        self.assertIn("Position = UDim2.new(1, -10, 0.5, 0)", self.source)
        self.assertIn("AnchorPoint = Vector2.new(1, 0.5)", self.source)
        self.assertNotIn("Position = UDim2.new(1, -8, 0, 0)", self.source)


class CombatDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.source = read("games/magicloot.lua")

    def test_autoclick_always_sends_confirmed_power_click_and_attack(self):
        section = self.source.split("local powerClick = {", 1)[1].split(
            "-- Locomotion bridge", 1
        )[0]
        self.assertIn("pcall(\n                invokeAction,", section)
        self.assertIn('"TRAIN_MANUAL_CLICK"', section)
        self.assertIn("local function queuePowerClick()", section)
        self.assertIn("if powerClick.inFlight then", section)
        self.assertIn("local target = findAttackTarget", section)
        self.assertIn("local attackOk, attackErr = attackTarget(target)", section)
        self.assertNotIn('playerNumber("TrainGroundId")', section)
        perform = section.split("local function performAutoClick()", 1)[1]
        self.assertLess(
            perform.index("local powerAccepted, powerDelivery = queuePowerClick()"),
            perform.index("local attackOk, attackErr = attackTarget(target)"),
        )

    def test_clicks_never_inject_real_input(self):
        # Background clicks only: the mouse and the dashboard must stay
        # usable while Auto Click runs.
        for banned in ("VirtualInputManager", "SendMouseButtonEvent", "mouse1click"):
            self.assertNotIn(banned, self.source)

        attack_section = self.source.split("-- Attack", 1)[1].split(
            "-- Locomotion bridge", 1
        )[0]
        for banned in ("getconnections", "firesignal", "TouchTap"):
            self.assertNotIn(banned, attack_section)

    def test_autoclick_reports_its_real_delivery(self):
        self.assertIn('return true, "power request pending"', self.source)
        self.assertIn('return true, "power request queued"', self.source)
        self.assertIn("combatStats.powerRequestsOk", self.source)
        self.assertIn("combatStats.powerRequestsFailed", self.source)
        self.assertIn("combatStats.lastPowerError", self.source)
        self.assertIn("combatStats.clickDelivery = delivery", self.source)

    def test_netmsg_descriptors_are_forwarded_without_instance_assumptions(self):
        remote_for = self.source.split("local function remoteFor(action)", 1)[1].split(
            "local function sendAction", 1
        )[0]
        self.assertIn("remote ~= nil", remote_for)
        self.assertNotIn('typeof(remote) == "Instance"', remote_for)

    def test_network_retries_a_half_resolved_message_registry(self):
        resolve_net = self.source.split("local function resolveNet()", 1)[1].split(
            "local function remoteFor", 1
        )[0]
        self.assertIn(
            "if net.network ~= nil and net.messages ~= nil then", resolve_net
        )
        self.assertIn(
            'local network = net.network or readUtilsEntry(utils, "NetWork")',
            resolve_net,
        )

    def test_autoattack_never_falls_back_to_training(self):
        worker = self.source.split("-- Combat workers", 1)[1].split(
            "-- Pickup worker", 1
        )[0]
        autoattack = worker.split("task.spawn(function()", 2)[1]
        self.assertIn("attackTarget(target)", autoattack)
        self.assertNotIn("TRAIN_MANUAL_CLICK", autoattack)
        self.assertNotIn("performAutoClick", autoattack)
        self.assertIn("local farming = cfg.AutoFarm or cfg.AutoFarmSpecific", autoattack)

    def test_skill_resolution_reports_the_failing_step(self):
        for marker in (
            '"PlayerScripts not found"',
            '"Manager not found"',
            '"PlayerSkillClientManager not found"',
            '"PlayerSkillInput not found"',
            '"SkillSlotConfig not found"',
            '"simulateSlotPressRelease missing"',
        ):
            self.assertIn(marker, self.source)

    def test_skill_resolution_uses_original_nested_manager_path(self):
        manager = 'playerScripts:WaitForChild("Manager", 8)'
        skill = 'managerFolder:WaitForChild("PlayerSkillClientManager", 8)'
        self.assertIn(manager, self.source)
        self.assertIn(skill, self.source)
        self.assertLess(self.source.index(manager), self.source.index(skill))
        self.assertNotIn(
            'playerScripts:WaitForChild("PlayerSkillClientManager", 8)',
            self.source,
        )
        self.assertIn("pcall(setIdentity, 2)", self.source)
        self.assertNotIn("math.max(original, 2)", self.source)

    def test_target_and_skill_call_match_original_contract(self):
        self.assertIn(
            "if humanoid ~= nil and humanoid.Health <= 0 then return false end",
            self.source,
        )
        self.assertIn("if target ~= nil and not setNowTarget(target) then", self.source)
        self.assertIn('return false, "NowTargetCurrent unavailable"', self.source)
        self.assertIn(
            "pcall(\n            input.simulateSlotPressRelease,",
            self.source,
        )
        self.assertIn('character unavailable', self.source)

    def test_netmsg_fallbacks(self):
        self.assertIn("network.NetMsg", self.source)
        self.assertIn('readUtilsEntry(utils, "NetMsg")', self.source)
        self.assertIn('readUtilsEntry(utils, "Net")', self.source)
        self.assertIn("net.lastMissedAction", self.source)

    def test_utils_registry_and_network_static_call_contract(self):
        self.assertIn('return utils(name)', self.source)
        self.assertIn('readUtilsEntry(utils, "NetWork")', self.source)
        self.assertIn("pcall(fireServer, remote, payload)", self.source)
        self.assertIn("pcall(invokeServer, remote, payload)", self.source)
        self.assertNotIn("network:FireServer", self.source)
        self.assertNotIn("network:InvokeServer", self.source)

    def test_combat_telemetry_exists(self):
        for marker in (
            "local combatStats",
            "attacksOk",
            "clicksOk",
            "lastClickError",
        ):
            self.assertIn(marker, self.source)

    def test_combat_tab_has_probe_buttons(self):
        self.assertIn("Send test click now", self.source)
        self.assertIn("Probe skill modules", self.source)
        self.assertIn("Max = 20", self.source)


if __name__ == "__main__":
    unittest.main()
