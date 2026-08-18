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
        self.assertIn('playerData.GetPlrDataByKey, player, "Bag"', self.source)
        self.assertIn("Common.sellOnlyIds", self.source)
        self.assertIn('sendAction("SELL_MATERIAL", { onlyIDList = onlyIds })', self.source)
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


if __name__ == "__main__":
    unittest.main()
