"""Behavioural invariants for the locomotion module and the core script.

These checks encode the project rules that must never regress:

  * Walking never teleports, never changes speed, drives humanoid:Move from a
    render-step binding, and is the only place allowed to request a reset.
  * Broom uses exactly the observed two-step remote flow with single-flight
    protection.
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

    def test_broom_two_step_remote_flow(self):
        self.assertIn('FireServer("关卡跳关请求", stage)', self.source)
        self.assertIn('InvokeServer("上下扫帚")', self.source)

    def test_broom_single_flight_protection(self):
        for marker in (
            "transactionActive",
            "epoch",
            "invalidateBroomTransaction",
            "transactionStillCurrent",
        ):
            self.assertIn(marker, self.source)

    def test_broom_base_detection_uses_challenge_value(self):
        self.assertIn("InDungeonChallenge", self.source)
        self.assertIn("tonumber(value.Value)", self.source)
        self.assertNotIn("CharacterAdded", self.source)
        self.assertNotIn("Humanoid.Died", self.source)


class CoreInvariantTests(unittest.TestCase):
    def setUp(self):
        self.source = read("games/magicloot.lua")

    def test_combat_cadence(self):
        self.assertIn("task.wait(0.2)", self.source)

    def test_click_cadence_formula(self):
        self.assertIn("1 / math.max(1, tonumber(cfg.ClickRate) or 10)", self.source)

    def test_pickup_wait_after_activation(self):
        self.assertIn("task.wait(0.4)", self.source)

    def test_sell_cadence(self):
        self.assertIn('local ReplicatedFirst = game:GetService("ReplicatedFirst")', self.source)
        self.assertIn("local utils = requireUtilsSystem(ReplicatedFirst)", self.source)
        self.assertIn("if utils ~= nil then net.clientUtils = utils end", self.source)
        self.assertIn('playerData.GetPlrDataByKey, player, "Bag"', self.source)
        self.assertIn("Common.sellOnlyIds", self.source)
        self.assertIn('invokeAction("SELL_MATERIAL", { onlyIDList = onlyIds })', self.source)
        self.assertNotIn('sendAction("SELL_MATERIAL", { onlyIDList = {} })', self.source)
        self.assertIn("task.wait(2)", self.source)

    def test_train_zone_update_payload(self):
        self.assertIn(
            'sendAction("TRAIN_ZONE_UPDATE", { trainId = trainId })', self.source
        )

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

    def test_walking_reset_only_in_locomotion(self):
        self.assertNotIn("Enum.HumanoidStateType.Dead", self.source)

    def test_stage_resolution_paths(self):
        self.assertIn('"场景"', self.source)
        self.assertIn('"战斗区域"', self.source)

    def test_drop_schema_supports_itemid(self):
        self.assertIn('model.Name == "DropItem"', self.source)
        self.assertIn('model:GetAttribute("ItemId")', self.source)
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

    def test_pickup_rarity_accepts_multiselect_map(self):
        self.assertIn('value == true', self.source)
        self.assertIn('type(key) == "number" and value or key', self.source)

    def test_walking_mode_dispatch(self):
        self.assertIn('cfg.FarmMode == "Walking"', self.source)
        self.assertIn('loco:Update("Walking"', self.source)

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
