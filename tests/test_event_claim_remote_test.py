"""Static safety contract for the one-shot Event claim runtime test."""

import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT = REPO_ROOT / "diagnostics" / "event_claim_remote_test.lua"


class EventClaimRemoteTestTests(unittest.TestCase):
    def test_exact_dynamic_remote_contract_without_local_ui(self):
        source = SCRIPT.read_text(encoding="utf-8")

        self.assertIn("object.canClaim == true", source)
        self.assertIn("object.claimed ~= true", source)
        self.assertIn("candidatesByTag[object.onlyTag] = true", source)
        self.assertIn(':InvokeServer("活动任务提交", tag)', source)
        self.assertIn('WaitForChild("NetWorkRemoteFunction", 5)', source)
        self.assertNotIn("FireServer", source)
        self.assertNotIn("SHOW_LOCAL_UI", source)
        self.assertNotIn("FireBindable", source)
        self.assertNotIn("ScreenGui", source)
        self.assertNotIn("AddToggle", source)
        self.assertNotIn("活动在线3分钟", source)
        self.assertNotIn("每日击杀指定怪物", source)


if __name__ == "__main__":
    unittest.main()
