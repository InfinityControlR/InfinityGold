"""Static safety contract for the one-shot Event claim runtime test."""

import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT = REPO_ROOT / "diagnostics" / "event_claim_remote_test.lua"


class EventClaimRemoteTestTests(unittest.TestCase):
    def test_exact_dynamic_remote_contract_without_local_ui(self):
        source = SCRIPT.read_text(encoding="utf-8")

        self.assertIn('rawget(object, "canClaim")', source)
        self.assertIn('rawget(object, "claimed")', source)
        self.assertIn("candidatesByTag[onlyTag] = true", source)
        self.assertIn('rawget(object, "Accepted")', source)
        self.assertIn('rawget(object, "Progress")', source)
        self.assertIn('rawget(object, "Completed")', source)
        self.assertIn('remoteEvent:FireServer("活动界面已打开")', source)
        self.assertIn(':InvokeServer("活动任务提交", tag)', source)
        self.assertIn('networkRemote("RemoteFunction", "NetWorkRemoteFunction")', source)
        self.assertIn("xpcall(run", source)
        self.assertIn("toclipboard", source)
        self.assertNotIn("SHOW_LOCAL_UI", source)
        self.assertNotIn("FireBindable", source)
        self.assertNotIn("ScreenGui", source)
        self.assertNotIn("AddToggle", source)
        self.assertNotIn("活动在线3分钟", source)
        self.assertNotIn("每日击杀指定怪物", source)


if __name__ == "__main__":
    unittest.main()
