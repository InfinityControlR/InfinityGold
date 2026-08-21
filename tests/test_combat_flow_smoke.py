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
local managerReady = false

local function module(payload)
    return {{ payload = payload }}
end

local skillManager
skillManager = {{
    FindFirstChild = function(_, name)
        table.insert(lookups, name)
        if name == "PlayerSkillInput" then return module(inputPayload) end
        if name == "SkillSlotConfig" then return module(configPayload) end
        return nil
    end,
}}
local managerFolder = {{
    FindFirstChild = function(_, name)
        table.insert(lookups, name)
        if name == "PlayerSkillClientManager" then return skillManager end
        return nil
    end,
}}
local playerScripts = {{
    FindFirstChild = function(_, name)
        table.insert(lookups, name)
        if name == "Manager" and managerReady then return managerFolder end
        return nil
    end,
}}
local player = {{
    FindFirstChild = function(_, name)
        table.insert(lookups, name)
        if name == "PlayerScripts" then return playerScripts end
        return nil
    end,
}}
local attack = {{ skillInput = nil, slotIndex = nil, status = "resolving" }}
local function withElevatedIdentity(callback) return pcall(callback) end
local function require(value) return value.payload end

{helper}

local missing = resolveAttack()
assert(missing == nil and attack.status == "Manager not found",
    "missing Manager did not fail the current tick immediately")
managerReady = true
local resolved = resolveAttack()
assert(resolved == inputPayload, "input module was not resolved")
assert(attack.slotIndex == 7, "normal attack slot was not resolved")
assert(
    table.concat(lookups, "/")
        == "PlayerScripts/Manager/PlayerScripts/Manager/PlayerSkillClientManager/PlayerSkillInput/SkillSlotConfig",
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

    def test_autoclick_sends_power_and_attack_in_every_context(self):
        helper = helper_source(
            "    local powerClick = {",
            "    -- Locomotion bridge",
        )
        source = f"""
local cfg = {{ AttackRange = 120 }}
local target = {{ Name = "Monster" }}
local attackCalls = 0
local invokeCalls = 0
local callLog = {{}}
local attackSucceeds = true
local invokeSucceeds = true
local pendingSpawn = nil
local spawnImmediately = true
local combatStats = {{
    powerRequestsOk = 0,
    powerRequestsFailed = 0,
    lastPowerError = "none",
}}
local task = {{
    spawn = function(callback)
        if spawnImmediately then
            callback()
        else
            assert(pendingSpawn == nil, "spawned overlapping power requests")
            pendingSpawn = callback
        end
    end,
}}
local function characterParts() return {{}} end
local function findAttackTarget(range)
    assert(range == 120)
    return target
end
local function attackTarget(value)
    assert(value == target)
    table.insert(callLog, "attack")
    attackCalls += 1
    return attackSucceeds, attackSucceeds and nil or "skill unavailable"
end
local function invokeAction(action, payload)
    assert(action == "TRAIN_MANUAL_CLICK")
    assert(type(payload) == "table")
    assert(next(payload) == nil, "power-click payload must stay empty")
    table.insert(callLog, "power")
    invokeCalls += 1
    return invokeSucceeds, nil, invokeSucceeds and nil or "remote unavailable"
end

{helper}

local ok, delivery = performAutoClick()
assert(ok and delivery == "power request queued + normal attack")
assert(attackCalls == 1 and invokeCalls == 1, "click did not send both routes")
assert(callLog[1] == "power" and callLog[2] == "attack",
    "the first power request was not dispatched before attack resolution")
assert(combatStats.powerRequestsOk == 1 and combatStats.powerRequestsFailed == 0)

target = nil
ok, delivery = performAutoClick()
assert(ok and delivery == "power request queued + normal attack")
assert(attackCalls == 2 and invokeCalls == 2, "targetless click lost a route")

target = {{ Name = "Monster" }}
attackSucceeds = false
ok, delivery = performAutoClick()
assert(ok and string.find(delivery, "power request queued; attack failed", 1, true))
assert(attackCalls == 3 and invokeCalls == 3, "attack failure skipped power")

attackSucceeds = true
invokeSucceeds = false
ok, delivery = performAutoClick()
assert(ok and delivery == "power request queued + normal attack")
assert(attackCalls == 4 and invokeCalls == 4, "power failure skipped attack")
assert(combatStats.powerRequestsFailed == 1, "async power failure was not reported")

invokeSucceeds = true
spawnImmediately = false
ok, delivery = performAutoClick()
assert(ok and delivery == "power request queued + normal attack")
assert(pendingSpawn ~= nil and invokeCalls == 4, "deferred request ran early")
ok, delivery = performAutoClick()
assert(ok and delivery == "power request pending + normal attack")
assert(invokeCalls == 4, "a second power request overlapped the first")
local resume = pendingSpawn
pendingSpawn = nil
resume()
assert(invokeCalls == 5 and combatStats.powerRequestsOk == 4,
    "deferred power request did not complete")
print("autoclick_dual_route_smoke=ok")
"""
        completed = run_luau(source)
        self.assertEqual(
            completed.returncode,
            0,
            f"autoclick smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("autoclick_dual_route_smoke=ok", completed.stdout)


if __name__ == "__main__":
    unittest.main()
