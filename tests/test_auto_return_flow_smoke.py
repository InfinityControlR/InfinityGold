"""Executable smoke tests for the full-bag return path.

The original game derives the capacity from GetData.GetItemCountByID(player,
5), not from a guessed ``LimitBagMax`` value.  These tests execute the shipped
helper bodies under Luau so a future string-only rewrite cannot silently turn
Auto Return into a permanent no-op again.
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


PLAYER_NUMBER = helper_source(
    "    local function playerNumber(name)",
    "    local getData = nil",
)
GET_DATA = helper_source(
    "    local function resolveGetData()",
    "    local function playerBag()",
)
BAG_HELPERS = helper_source(
    "    local BAG_CAPACITY_ITEM_ID = 5",
    "    -- Stages",
)
RETURN_HELPERS = helper_source(
    "    local MAX_RETURN_ATTEMPTS = 15",
    "    -- Movement worker",
)


class AutoReturnFlowSmokeTests(unittest.TestCase):
    def test_capacity_uses_original_item_count_contract_and_retries_getdata(self):
        fixture = f"""
local values = {{
    LimitBagUsed = {{ Value = 4 }},
}}
local player = {{}}
function player:FindFirstChild(name)
    return values[name]
end

local currentData = nil
local resolveCalls = 0
local capacity = 4
local getItemCalls = 0
local data = {{
    GetItemCountByID = function(actualPlayer, itemId)
        assert(actualPlayer == player, "capacity lookup did not receive LocalPlayer")
        assert(itemId == 5, "capacity lookup used the wrong item id")
        getItemCalls += 1
        return capacity
    end,
}}
local function resolveRuntimeModule(name)
    assert(name == "GetData", "unexpected runtime module " .. tostring(name))
    resolveCalls += 1
    return currentData
end

{PLAYER_NUMBER}
local getData = nil
{GET_DATA}
{BAG_HELPERS}

assert(resolveGetData() == nil, "early GetData probe should be unavailable")
currentData = data
assert(resolveGetData() == data, "an early nil result was cached permanently")
assert(resolveCalls == 2, "GetData was not retried exactly once")

local full, known, used, limit, source = bagFull()
assert(full == true and known == true, "a 4/4 bag was not full")
assert(used == 4 and limit == 4, "wrong bag snapshot")
assert(source == "GetItemCountByID(5)", "wrong capacity source")
assert(getItemCalls == 1, "capacity lookup call count was wrong")

values.LimitBagUsed.Value = 3.9
full, known, used = bagFull()
assert(full == false and known == true, "a 3/4 bag was reported full")
assert(used == 3, "LimitBagUsed was not floored like the original client")

capacity = 0
values.LimitBagMax = {{ Value = 6 }}
full, known, used, limit, source = bagFull()
assert(full == false and known == true and limit == 6, "direct fallback failed")
assert(source == "LimitBagMax", "fallback source was not reported")

values.LimitBagMax = nil
full, known, used, limit, source = bagFull()
assert(full == false and known == false and limit == nil, "unknown capacity was guessed")
assert(source == "unavailable", "unknown source was not explicit")
print("auto_return_capacity_smoke=ok")
"""
        completed = run_luau(fixture)
        self.assertEqual(
            completed.returncode,
            0,
            f"capacity smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("auto_return_capacity_smoke=ok", completed.stdout)

    def test_return_episode_retries_safely_and_sends_exact_action(self):
        fixture = f"""
local now = 10
local os = {{ clock = function() return now end }}
local cfg = {{ ReturnDelay = 0, AutoReturnFull = true, AutoFarm = false }}
local challenge = 7
local attempts = 0
local actions = {{}}
local broomArms = 0
local loco = {{}}
function loco:OnAutoReturnFull()
    broomArms += 1
end
local notifications = {{}}

local function playerNumber(name)
    assert(name == "InDungeonChallenge", "unexpected player value")
    return challenge
end
local function notify(message)
    table.insert(notifications, message)
end
local function sendAction(action)
    table.insert(actions, action)
    attempts += 1
    if attempts == 1 then return false, "network warming up" end
    return true
end

{RETURN_HELPERS}

startReturnEpisode("bag")
assert(returnEpisode.active == true, "episode did not start")
updateReturnEpisode(true)
assert(#actions == 1 and actions[1] == "DUNGEON_RETURN_TOWN", "wrong return action")
assert(returnEpisode.fired == false, "failed request was marked sent")
assert(returnEpisode.lastError == "network warming up", "failure was hidden")
assert(broomArms == 1, "broom was not armed immediately before the first request")

now = 11
updateReturnEpisode(true)
assert(#actions == 1, "failed request retried faster than the 2 second cooldown")
now = 12
updateReturnEpisode(true)
assert(#actions == 2 and returnEpisode.fired == true, "return request did not retry")
now = 13
updateReturnEpisode(true)
assert(#actions == 2, "successful request retried faster than the cooldown")
now = 14
updateReturnEpisode(true)
assert(#actions == 3, "request was not repeated while still inside the dungeon")
assert(broomArms == 1, "broom was armed more than once in one episode")

challenge = 0
now = 14.25
updateReturnEpisode(true)
assert(returnEpisode.active == false, "base arrival did not settle the episode")

challenge = 7
now = 20
updateReturnEpisode(true)
assert(returnEpisode.active == true, "a new full-bag episode did not re-arm")
cfg.AutoReturnFull = false
updateReturnEpisode(true)
assert(returnEpisode.active == false, "disabling Auto Return did not cancel")
cfg.AutoReturnFull = true
updateReturnEpisode(false)
assert(returnEpisode.active == false, "an emptied bag did not cancel")
challenge = nil
updateReturnEpisode(true)
assert(returnEpisode.active == false, "unknown challenge state was treated as a dungeon")

challenge = 7
cfg.ReturnDelay = 3
now = 30
local beforeDelayCalls = #actions
local beforeDelayArms = broomArms
updateReturnEpisode(true)
assert(returnEpisode.active == true, "delayed episode did not arm")
assert(#actions == beforeDelayCalls, "ReturnDelay was ignored at episode start")
assert(broomArms == beforeDelayArms, "broom armed before ReturnDelay elapsed")
now = 32.9
updateReturnEpisode(true)
assert(#actions == beforeDelayCalls, "return fired before ReturnDelay elapsed")
now = 33
updateReturnEpisode(true)
assert(#actions == beforeDelayCalls + 1, "return did not fire after ReturnDelay")
assert(broomArms == beforeDelayArms + 1, "broom did not arm with the first request")

for attempt = 2, MAX_RETURN_ATTEMPTS do
    now = 33 + (attempt - 1) * 2
    updateReturnEpisode(true)
end
assert(#actions == beforeDelayCalls + MAX_RETURN_ATTEMPTS,
    "bounded return did not make the expected attempts")
now += 2
updateReturnEpisode(true)
assert(returnEpisode.active == false and returnEpisode.blocked == true,
    "unconfirmed return did not enter its safe paused state")
local callsAtPause = #actions
now += 2
updateReturnEpisode(true)
assert(#actions == callsAtPause, "paused return continued sending")
updateReturnEpisode(false)
assert(returnEpisode.blocked == false, "a real gate change did not re-arm return")
print("auto_return_episode_smoke=ok")
"""
        completed = run_luau(fixture)
        self.assertEqual(
            completed.returncode,
            0,
            f"return episode smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("auto_return_episode_smoke=ok", completed.stdout)


if __name__ == "__main__":
    unittest.main()
