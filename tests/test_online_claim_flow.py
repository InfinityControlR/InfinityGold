"""Executable regression tests for online reward claiming."""

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


ONLINE_HELPERS = core_slice(
    "    local onlineClaimTelemetry = {",
    "    local function isProtectedAlchemyMaterial",
)


class OnlineClaimFlowTests(unittest.TestCase):
    def test_only_claimable_ids_are_invoked_individually(self):
        fixture = f"""
local player = {{ marker = "local-player" }}
local cfg = {{ AutoClaimOnline = true }}
local sessionAlive = true
local onlineBox = {{ elapsed = 900, claimed = {{}} }}
local playerDataAvailable = false
local eligibilityCalls = 0
local waits = {{}}
local calls = {{}}
local task = {{
    wait = function(seconds) table.insert(waits, seconds) end,
}}

local awards = {{
    {{ id = 3, ready = true }},
    {{ id = 7, ready = false }},
    {{ id = "12", ready = true }},
    {{ id = 0, ready = true }},
    {{ id = 9, throws = true }},
    "malformed",
}}
local playerData = {{
    GetPlrDataByKey = function(actualPlayer, key)
        assert(actualPlayer == player, "OnlineBox lookup received the wrong player")
        assert(key == "OnlineBox", "online claims read the wrong player-data key")
        return onlineBox
    end,
}}
local cfgFind = {{
    GetOnlineAwardList = function()
        return awards
    end,
    IsOnlineTierClaimable = function(actualBox, award)
        assert(actualBox == onlineBox, "eligibility received the wrong OnlineBox")
        eligibilityCalls += 1
        if award.throws then error("temporary eligibility failure") end
        return award.ready
    end,
}}
local function resolveRuntimeModule(name)
    if name == "PlayerData" then
        return playerDataAvailable and playerData or nil
    end
    if name == "CfgFind" then return cfgFind end
    error("unexpected module " .. tostring(name))
end
local function invokeAction(action, awardId)
    assert(action == "CLAIM_ONLINE_AWARD", "wrong online claim action")
    table.insert(calls, awardId)
    if awardId == 3 then return false, nil, "warming up" end
    return true, {{ accepted = awardId }}
end

{ONLINE_HELPERS}

local missing, missingError = claimableOnlineAwardIds()
assert(missing == nil and missingError == "PlayerData unavailable",
    "an unavailable PlayerData module was treated as a valid empty list")
playerDataAvailable = true

local ids, scanError = claimableOnlineAwardIds()
assert(scanError == nil, "claimability scan failed: " .. tostring(scanError))
assert(#ids == 2 and ids[1] == 3 and ids[2] == 12,
    "claimability scan returned wrong ids")
assert(eligibilityCalls == 5, "malformed/error rows were not skipped safely")

eligibilityCalls = 0
local claimed, claimError = claimOnlineAwards()
assert(claimed == 1, "successful online reward count was wrong")
assert(claimError == "warming up", "a failed reward invocation was hidden")
assert(#calls == 2 and calls[1] == 3 and calls[2] == 12,
    "claiming stopped early or changed reward order")
assert(#waits == 2 and waits[1] == 0.35 and waits[2] == 0.35,
    "online rewards were not spaced at the original cadence")
assert(onlineClaimTelemetry.attempts == 2 and onlineClaimTelemetry.claimed == 1,
    "online claim telemetry did not match transport outcomes")

local callsBeforeDisable = #calls
local waitsBeforeDisable = #waits
cfg.AutoClaimOnline = false
claimed = claimOnlineAwards()
assert(claimed == 0 and #calls == callsBeforeDisable and #waits == waitsBeforeDisable,
    "disabling Auto Claim Online did not stop the active drain")
print("online_claim_flow_smoke=ok")
"""
        completed = run_luau(fixture)
        self.assertEqual(
            completed.returncode,
            0,
            f"online claim smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("online_claim_flow_smoke=ok", completed.stdout)

    def test_worker_uses_invoke_helper_and_original_cadence(self):
        source = (REPO_ROOT / "games" / "magicloot.lua").read_text(encoding="utf-8")
        worker = core_slice(
            "    task.spawn(function() -- online claims",
            "    task.spawn(function() -- potions",
        )
        helper = core_slice(
            "    local function claimOnlineAwards()",
            "    local function isProtectedAlchemyMaterial",
        )
        self.assertIn("claimOnlineAwards()", worker)
        self.assertIn("task.wait(2)", worker)
        self.assertNotIn('sendAction("CLAIM_ONLINE_AWARD")', source)
        self.assertIn('invokeAction("CLAIM_ONLINE_AWARD", awardId)', helper)
        self.assertIn("task.wait(0.35)", helper)


if __name__ == "__main__":
    unittest.main()
