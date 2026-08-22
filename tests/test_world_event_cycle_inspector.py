"""Static safety/bounds contract for the passive world-event inspector."""

import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SOURCE = (
    REPO_ROOT / "diagnostics" / "world_event_cycle_inspector.lua"
).read_text(encoding="utf-8")


class WorldEventCycleInspectorTests(unittest.TestCase):
    def test_is_passive_bounded_and_captures_required_surfaces(self):
        for marker in (
            "MAX_EVENTS = 700",
            "MAX_REPORT_CHARACTERS = 180000",
            "MAX_SCALARS = 900",
            "MAX_UI_TEXTS = 700",
            "MAX_PARTS = 3000",
            "MAX_TABLE_MATCHES = 60",
            "MAX_TABLE_SNAPSHOTS = 6",
            "MAX_DIFF_RECORDS = 100",
            "MAX_STRUCTURE_EVENTS_PER_SECOND = 160",
            "MAX_VALUE_EVENTS_PER_SECOND = 120",
            "CHECKPOINT_SECONDS = 15",
            'CHECKPOINT_FILE = "InfinityGold_world_event_capture.txt"',
            "while #events > MAX_EVENTS",
            "remote.OnClientEvent",
            "ReplicatedStorage.DescendantAdded",
            "workspace.DescendantAdded",
            "workspace.DescendantRemoving",
            "scalarSnapshot()",
            "uiSnapshot()",
            "context:GetDescendants()",
            "monsterSnapshot()",
            "partSnapshot()",
            "instanceDescription(instance)",
            "observeValue(instance)",
            "loadedTableMatches()",
            "captureLoadedTableSnapshot(reason)",
            "Loaded-table snapshots captured during the cycle:",
            "for _, row in ipairs(currentStateLines()) do table.insert(preserved, row) end",
            "earlier timeline truncated; newest data preserved",
            "checkpoint(false)",
            "pcall(writefile, CHECKPOINT_FILE",
            "connection:Disconnect()",
            'copy.Text = copied and "Copied"',
        ):
            self.assertIn(marker, SOURCE)

        for forbidden in (
            "FireServer",
            "InvokeServer",
            "FireBindable",
            "fireproximityprompt",
            "firesignal",
            "VirtualInputManager",
            "mouse1click",
            "loadstring",
            "HttpGet",
            "root.CFrame =",
        ):
            self.assertNotIn(forbidden, SOURCE)


if __name__ == "__main__":
    unittest.main()
