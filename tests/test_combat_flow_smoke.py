"""Execute the real combat helpers against a small Luau runtime fixture.

Unlike the string invariants, these tests exercise the helper bodies copied
directly from games/magicloot.lua. They catch path/order/branch regressions
without needing a Roblox client.
"""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from tools.ensure_luau import run_binary as luau_runner  # noqa: E402


def helper_source(start: str, end: str) -> str:
    source = (REPO_ROOT / "games" / "magicloot.lua").read_text(encoding="utf-8")
    left = source.index(start)
    right = source.index(end, left)
    return source[left:right]


def run_luau(source: str) -> subprocess.CompletedProcess:
    with tempfile.NamedTemporaryFile(
        "w", suffix=".luau", delete=False, encoding="utf-8", newline="\n"
    ) as handle:
        handle.write(source)
        path = Path(handle.name)
    try:
        return subprocess.run(
            [str(luau_runner()), str(path)],
            capture_output=True,
            text=True,
            timeout=30,
        )
    finally:
        path.unlink(missing_ok=True)


class CombatFlowSmokeTests(unittest.TestCase):
    def test_attack_modules_resolve_through_manager(self):
        helper = helper_source(
            "    local function resolveAttack()",
            "    local function setNowTarget",
        )
        source = f"""
local lookups = {{}}
local inputPayload = {{ simulateSlotPressRelease = function() end }}
local configPayload = {{ NORMAL_ATTACK_SLOT_INDEX = 7 }}

local function module(payload)
    return {{ payload = payload }}
end

local skillManager
skillManager = {{
    WaitForChild = function(_, name)
        table.insert(lookups, name)
        if name == "PlayerSkillInput" then return module(inputPayload) end
        if name == "SkillSlotConfig" then return module(configPayload) end
        return nil
    end,
}}
local managerFolder = {{
    WaitForChild = function(_, name)
        table.insert(lookups, name)
        if name == "PlayerSkillClientManager" then return skillManager end
        return nil
    end,
}}
local playerScripts = {{
    WaitForChild = function(_, name)
        table.insert(lookups, name)
        if name == "Manager" then return managerFolder end
        return nil
    end,
}}
local player = {{
    WaitForChild = function(_, name)
        table.insert(lookups, name)
        if name == "PlayerScripts" then return playerScripts end
        return nil
    end,
}}
local attack = {{ skillInput = nil, slotIndex = nil, status = "resolving" }}
local function withElevatedIdentity(callback) return pcall(callback) end
local function require(value) return value.payload end

{helper}

local resolved = resolveAttack()
assert(resolved == inputPayload, "input module was not resolved")
assert(attack.slotIndex == 7, "normal attack slot was not resolved")
assert(
    table.concat(lookups, "/")
        == "PlayerScripts/Manager/PlayerSkillClientManager/PlayerSkillInput/SkillSlotConfig",
    "wrong skill module path: " .. table.concat(lookups, "/")
)
print("attack_resolver_smoke=ok")
"""
        completed = run_luau(source)
        self.assertEqual(
            completed.returncode,
            0,
            f"resolver smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("attack_resolver_smoke=ok", completed.stdout)

    def test_autoclick_splits_dungeon_and_training_delivery(self):
        helper = helper_source(
            "    local function performAutoClick()",
            "    -- Locomotion bridge",
        )
        source = f"""
local cfg = {{ AttackRange = 120 }}
local trainId = 0
local target = {{ Name = "Monster" }}
local attackCalls = 0
local invokeCalls = 0
local function characterParts() return {{}} end
local function playerNumber(name)
    assert(name == "TrainGroundId")
    return trainId
end
local function findAttackTarget(range)
    assert(range == 120)
    return target
end
local function attackTarget(value)
    assert(value == target)
    attackCalls += 1
    return true
end
local function invokeAction(action, payload)
    assert(action == "TRAIN_MANUAL_CLICK")
    assert(type(payload) == "table")
    invokeCalls += 1
    return true, true, nil
end

{helper}

local ok, delivery = performAutoClick()
assert(ok and delivery == "normal attack")
assert(attackCalls == 1 and invokeCalls == 0, "dungeon click used wrong route")

target = nil
ok, delivery = performAutoClick()
assert(ok and delivery == "normal attack")
assert(attackCalls == 2 and invokeCalls == 0, "targetless click was suppressed")

trainId = 3
ok, delivery = performAutoClick()
assert(ok and delivery == "training remote")
assert(attackCalls == 2 and invokeCalls == 1, "training click used wrong route")
print("autoclick_split_smoke=ok")
"""
        completed = run_luau(source)
        self.assertEqual(
            completed.returncode,
            0,
            f"autoclick smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("autoclick_split_smoke=ok", completed.stdout)


if __name__ == "__main__":
    unittest.main()
