"""Static safety invariants for the standalone passive click inspector."""

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
INSPECTOR = REPO_ROOT / "diagnostics" / "click_action_inspector.lua"


class ClickActionInspectorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = INSPECTOR.read_text(encoding="utf-8")

    def test_is_standalone_and_passive(self):
        self.assertTrue(INSPECTOR.is_file())
        for banned in (
            "VirtualInputManager",
            "SendMouseButtonEvent",
            "mouse1click",
            "firesignal",
            "fireproximityprompt",
        ):
            self.assertNotIn(banned, self.source)
        self.assertIsNone(re.search(r":\s*(?:FireServer|InvokeServer)\s*\(", self.source))

    def test_records_only_real_left_button_uis_phases(self):
        self.assertIn("UserInputService.InputBegan", self.source)
        self.assertIn("UserInputService.InputEnded", self.source)
        self.assertIn("Enum.UserInputType.MouseButton1", self.source)
        self.assertIn("beginRealLeftClick(input, processed)", self.source)
        self.assertIn("endRealLeftClick(input, processed)", self.source)
        self.assertIn("InputBegan t=", self.source)
        self.assertIn("InputEnded t=", self.source)
        self.assertNotIn("Enum.UserInputType.Touch", self.source)

    def test_own_popup_clicks_are_excluded(self):
        self.assertIn("if pointInside(window, position) then return end", self.source)
        self.assertIn("isOwnInstance(instance)", self.source)

    def test_namecall_hook_is_a_pure_bounded_producer(self):
        producer = self.source.split("-- HOOK_PRODUCER_BEGIN", 1)[1].split(
            "-- HOOK_PRODUCER_END", 1
        )[0]
        self.assertIn("pendingRemoteCount >= CONFIG.MaxPendingRemotes", producer)
        self.assertIn("pendingRemoteQueue[pendingRemoteTail]", producer)
        for banned in (
            "Instance.new",
            "safeFullName",
            "safeClassName",
            "scheduleRender",
            "task.",
            ".Parent",
            ".ClassName",
        ):
            self.assertNotIn(banned, producer)

        self.assertIn("table.pack(...)", self.source)
        self.assertIn("local methodOk, method = pcall(namecallMethod)", self.source)
        self.assertIn("if methodOk and (method ==", self.source)
        self.assertIn("RunService.Heartbeat", self.source)
        self.assertIn("pcall(processRemoteCapture, capture)", self.source)

        handler = self.source.split("-- HOOK_HANDLER_BEGIN", 1)[1].split(
            "-- HOOK_HANDLER_END", 1
        )[0]
        self.assertEqual(handler.count("pcall"), 1)
        self.assertIn("pcall(namecallMethod)", handler)
        self.assertIn("return originalNamecall(self, ...)", handler)
        for banned in (
            "Instance.new",
            "safeFullName",
            "safeClassName",
            "formatRemote",
            "scheduleRender",
            "task.",
            ".Parent",
            ".ClassName",
        ):
            self.assertNotIn(banned, handler)

    def test_correlates_only_observed_remote_calls(self):
        self.assertIn('method == "FireServer" or method == "InvokeServer"', self.source)
        self.assertIn("CorrelationBeforeSeconds", self.source)
        self.assertIn("CorrelationAfterSeconds", self.source)
        self.assertIn("correlateRemotes(click", self.source)
        self.assertIn('string.find(lowerName, "玩家瞄准采样", 1, true)', self.source)
        self.assertIn('type(capture.arguments[1]) == "string"', self.source)
        self.assertIn("action = cleanText(capture.arguments[1]", self.source)
        self.assertIn('remote.action .. " " .. remote.name', self.source)
        self.assertIn("remote.distanceFromClick", self.source)
        self.assertIn("table.sort(relevant", self.source)
        self.assertIn("for _, remote in ipairs(relevant)", self.source)
        self.assertIn("aim samples collapsed", self.source)

        begin = self.source.split("local function beginRealLeftClick", 1)[1].split(
            "local function endRealLeftClick", 1
        )[0]
        self.assertLess(begin.index("local beganAt = os.clock()"), begin.index("captureNumericSnapshot()"))
        self.assertIn("beganAt = beganAt", begin)

    def test_numeric_effect_snapshot_is_bounded_and_read_only(self):
        self.assertIn('safeIsA(instance, "NumberValue")', self.source)
        self.assertIn('safeIsA(instance, "IntValue")', self.source)
        self.assertIn("instance:GetAttributes()", self.source)
        self.assertIn('queueRoot(LocalPlayer, "LocalPlayer")', self.source)
        self.assertIn('queueRoot(LocalPlayer.Character, "Character")', self.source)
        self.assertIn("MaxScanInstances", self.source)
        self.assertIn("MaxNumericSignals", self.source)
        self.assertIn("compareNumericSnapshots", self.source)
        self.assertIn("numericSnapshotSummary", self.source)
        self.assertIn("snapshot truncated; zero deltas is not proof", self.source)

    def test_skill_exports_and_uis_callbacks_are_inspected_not_called(self):
        for segment in (
            'FindFirstChild("Manager")',
            'FindFirstChild("PlayerSkillClientManager")',
            'FindFirstChild("PlayerSkillInput")',
            "functionMetadata(value)",
            "getconnections",
            "debug.info",
            "connection.Function or connection.fn",
        ):
            self.assertIn(segment, self.source)
        self.assertNotRegex(self.source, r"connection\.(?:Function|fn)\s*\(")

    def test_utils_system_callable_registry_is_probed_read_only(self):
        for marker in (
            'ReplicatedFirst:FindFirstChild("UtilsSystem", true)',
            'ReplicatedStorage:FindFirstChild("UtilsSystem", true)',
            "type(require(UtilsSystem)):",
            "type(getmetatable(registry).__call):",
            '{ "NetMsg", "NetWork" }',
            '"  registry(%q): ok=%s type=%s result=%s"',
            'return registry(key)',
            "ok (read-only registry probe)",
        ):
            self.assertIn(marker, self.source)
        self.assertIn("No returned function, callback", self.source)

    def test_module_inspection_never_initializes_an_unloaded_module(self):
        self.assertIn("getloadedmodules", self.source)
        self.assertIn("moduleWasAlreadyLoaded(moduleScript)", self.source)
        self.assertIn("skipped to remain passive", self.source)
        self.assertIn("readLoadedModuleAtIdentityTwo", self.source)
        self.assertNotIn("requireAtIdentityTwo", self.source)
        self.assertIn("cached modules only", self.source)

    def test_popup_has_required_controls_and_dragging(self):
        for marker in (
            'copyButton.Text = "Copiar"',
            'minimizeButton.Name = "Minimize"',
            'closeButton.Text = "X"',
            "header.InputBegan",
            "setWindowTopLeft",
        ):
            self.assertIn(marker, self.source)

    def test_cleanup_is_idempotent_and_preserves_newer_hooks(self):
        self.assertIn("if closed then return end", self.source)
        self.assertIn("hookActive = false", self.source)
        self.assertIn("ownsCurrentNamecallHook()", self.source)
        self.assertIn('hookInstaller, game, "__namecall", originalNamecall', self.source)
        self.assertIn('"dormant; newer/unknown hook preserved"', self.source)
        self.assertIn("connection:Disconnect()", self.source)
        self.assertIn("rootGui:Destroy()", self.source)

    def test_all_growth_has_explicit_limits(self):
        for marker in (
            "MaxClicks",
            "MaxPendingClicks",
            "MaxPendingRemotes",
            "MaxRemoteHistory",
            "MaxRemotesPerClick",
            "MaxArguments",
            "MaxArgumentDepth",
            "MaxReportCharacters",
            "MaxExports",
            "MaxLoadedModulesScan",
            "MaxConnectionsTotal",
        ):
            self.assertIn(marker, self.source)


if __name__ == "__main__":
    unittest.main()
