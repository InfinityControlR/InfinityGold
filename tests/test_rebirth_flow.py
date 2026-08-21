"""Executable regression for Magic's rebirth level requirement."""

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


class RebirthFlowTests(unittest.TestCase):
    def test_level_requirement_precedes_payload_free_rebirth(self):
        helper = core_slice(
            "    local function playerLevel()",
            "    task.spawn(function() -- rebirth",
        )
        fixture = f"""
local cfg = {{ AutoRebirth = true, RebirthLimit = 41 }}
local rebirths = 0
local levelValue = {{ Value = 4 }}
local leaderstats = {{}}
function leaderstats:FindFirstChild(name)
    assert(name == "Level")
    return levelValue
end
local player = {{}}
function player:FindFirstChild(name)
    assert(name == "leaderstats")
    return leaderstats
end
local rebirthConfig = {{ ["1"] = {{ LvNeed = 5 }} }}
local function configByName(name)
    assert(name == "rebirthConf")
    return rebirthConfig
end
local function playerNumber(name)
    assert(name == "Rebirths")
    return rebirths
end
local calls = 0
local function invokeAction(action, payload)
    assert(action == "PLAYER_REBIRTH")
    assert(payload == nil)
    calls += 1
    return true
end

{helper}

assert(nextRebirthLevelRequirement() == 5)
assert(runRebirthCycle() == false and calls == 0,
    "rebirth ignored the next LvNeed requirement")
levelValue.Value = 5
assert(runRebirthCycle() == true and calls == 1,
    "eligible rebirth did not use the payload-free action")
cfg.RebirthLimit = 0
assert(runRebirthCycle() == false and calls == 1,
    "rebirth limit was ignored")
cfg.RebirthLimit = 41
rebirthConfig = {{}}
assert(runRebirthCycle() == false and calls == 1,
    "missing rebirthConf was guessed")
print("rebirth_level_gate_smoke=ok")
"""
        with tempfile.NamedTemporaryFile(
            "w", suffix=".luau", delete=False, encoding="utf-8", newline="\n"
        ) as handle:
            handle.write(fixture)
            path = Path(handle.name)
        try:
            completed = subprocess.run(
                [str(luau_runner()), str(path)],
                capture_output=True,
                text=True,
                timeout=30,
            )
        finally:
            path.unlink(missing_ok=True)
        self.assertEqual(
            completed.returncode,
            0,
            f"rebirth smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("rebirth_level_gate_smoke=ok", completed.stdout)


if __name__ == "__main__":
    unittest.main()
