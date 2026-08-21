"""Static safety checks for the passive Event Claim state inspector."""

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "diagnostics" / "event_claim_state_inspector.lua"


class EventClaimStateInspectorTests(unittest.TestCase):
    def setUp(self):
        self.source = SOURCE.read_text(encoding="utf-8")

    def test_inspector_is_bounded_and_passive(self):
        self.assertIn("MAX_GC_OBJECTS = 20000", self.source)
        self.assertIn("MAX_MATCHES = 80", self.source)
        self.assertIn("MAX_REPORT_CHARACTERS = 60000", self.source)
        self.assertIn("getloadedmodules", self.source)
        self.assertIn("loadedModules[utilsScript]", self.source)
        self.assertNotIn("InvokeServer", self.source)
        self.assertNotIn("FireServer", self.source)
        self.assertNotIn("loadstring", self.source)
        self.assertNotIn("GetPlrDataByKey", self.source)

    def test_inspector_targets_dynamic_event_vocabulary(self):
        for token in ("活动", "任务", "限时", "每日", "event", "quest", "claim"):
            self.assertIn(f'"{token}"', self.source)


if __name__ == "__main__":
    unittest.main()
