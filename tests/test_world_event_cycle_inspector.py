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
            "MAX_EVENTS = 500",
            "MAX_REPORT_CHARACTERS = 60000",
            "MAX_SCALARS = 900",
            "MAX_UI_TEXTS = 700",
            "MAX_PARTS = 3000",
            "MAX_TABLE_MATCHES = 60",
            "while #events > MAX_EVENTS",
            "remote.OnClientEvent",
            "ReplicatedStorage.DescendantAdded",
            "scalarSnapshot()",
            "uiSnapshot()",
            "monsterSnapshot()",
            "partSnapshot()",
            "loadedTableMatches()",
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
