"""Exercise dynamic, UI-free Event quest discovery and claiming."""

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


EVENT_HELPERS = core_slice(
    "    local eventClaims = {}",
    "    local indexViewModule = nil",
)


class EventClaimFlowTests(unittest.TestCase):
    def test_dynamic_claimability_and_raw_remote_contract(self):
        fixture = f"""
local cfg = {{ AutoClaimEvent = true }}
local sessionAlive = true
local waits = {{}}
local refreshCalls = {{}}
local claimCalls = {{}}
local task = {{
    wait = function(seconds) table.insert(waits, seconds) end,
}}

local objects = {{
    {{
        Accepted = {{ "future-event-quest", "incomplete-event-quest", "claimed-event-quest" }},
        Completed = {{ ["claimed-event-quest"] = 1 }},
        Progress = {{
            ["future-event-quest"] = 25,
            ["incomplete-event-quest"] = 4,
            ["claimed-event-quest"] = 99,
        }},
    }},
    {{ ResetType = 3, onlyTag = "future-event-quest", need = {{ 25 }} }},
    {{ ResetType = 3, onlyTag = "incomplete-event-quest", need = {{ 10 }} }},
    {{ ResetType = 3, onlyTag = "claimed-event-quest", need = {{ 10 }} }},
    {{
        ResetType = 3,
        onlyTag = "future-event-quest",
        need = 25,
        progress = 25,
        claimed = false,
        canClaim = true,
    }},
    {{
        ResetType = 3,
        onlyTag = "incomplete-event-quest",
        need = 10,
        progress = 4,
        claimed = false,
        canClaim = false,
    }},
    {{
        Accepted = {{ "fallback-future-quest" }},
        Completed = {{}},
        Progress = {{ ["fallback-future-quest"] = 7 }},
    }},
    {{ ResetType = 4, onlyTag = "fallback-future-quest", need = {{ 7 }} }},
    {{
        ResetType = 4,
        onlyTag = "derived-only-future-quest",
        need = 1,
        progress = 1,
        claimed = false,
        canClaim = true,
    }},
    {{ Accepted = "malformed", Progress = {{}}, Completed = {{}} }},
}}

local function getgc(includeTables)
    assert(includeTables == true, "Event scan did not request loaded tables")
    return objects
end

local function sendLiteralAction(action, payload)
    assert(action == "活动界面已打开", "wrong Event refresh action")
    assert(payload == nil, "Event refresh unexpectedly opened/passed UI state")
    table.insert(refreshCalls, action)
    return true
end

local function invokeLiteralAction(action, tag)
    assert(action == "活动任务提交", "wrong Event claim action")
    table.insert(claimCalls, tag)
    if tag == "fallback-future-quest" then
        return false, nil, "server warming up"
    end
    return true, {{ accepted = tag }}
end

{EVENT_HELPERS}

local sources = eventClaims.sourcesFrom(objects)
local tags = eventClaims.claimableFrom(sources)
assert(#tags == 3, "dynamic scan returned the wrong number of quests")
assert(tags[1] == "derived-only-future-quest"
    and tags[2] == "fallback-future-quest"
    and tags[3] == "future-event-quest",
    "dynamic scan changed or hard-coded the quest catalog")

local claimed, claimError = eventClaims.claim()
assert(claimed == 2, "successful Event claim count was wrong")
assert(claimError == "server warming up", "Event claim failure was hidden")
assert(#refreshCalls == 1, "Event state was not refreshed remotely once")
assert(#claimCalls == 3
    and claimCalls[1] == "derived-only-future-quest"
    and claimCalls[2] == "fallback-future-quest"
    and claimCalls[3] == "future-event-quest",
    "claim drain did not preserve every dynamic quest tag")
assert(#waits == 4 and waits[1] == 0.1
    and waits[2] == 0.25 and waits[3] == 0.25 and waits[4] == 0.25,
    "Event refresh/claim cadence changed")
assert(eventClaims.telemetry.stateGroups == 2
    and eventClaims.telemetry.attempts == 3
    and eventClaims.telemetry.claimed == 2,
    "Event claim telemetry did not match the scan")

cfg.AutoClaimEvent = false
local refreshesBeforeDisable = #refreshCalls
local claimsBeforeDisable = #claimCalls
claimed = eventClaims.claim()
assert(claimed == 0
    and #refreshCalls == refreshesBeforeDisable
    and #claimCalls == claimsBeforeDisable,
    "disabling Auto Claim Event did not stop the worker")
print("event_claim_flow_smoke=ok")
"""
        completed = run_luau(fixture)
        self.assertEqual(
            completed.returncode,
            0,
            f"Event claim smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("event_claim_flow_smoke=ok", completed.stdout)

    def test_worker_toggle_and_no_local_ui_path(self):
        source = (REPO_ROOT / "games" / "magicloot.lua").read_text(encoding="utf-8")
        helper = core_slice(
            "    local eventClaims = {}",
            "    local indexViewModule = nil",
        )
        worker = core_slice(
            "    task.spawn(function() -- event claims",
            "    task.spawn(function() -- potions",
        )
        rewards = core_slice(
            "    -- Rewards tab",
            "    -- Gear tab",
        )

        self.assertIn('AutoClaimEvent = false', source)
        self.assertIn('AddToggle("AutoClaimEvent"', rewards)
        self.assertIn("eventClaims.claim()", worker)
        self.assertIn("task.wait(2)", worker)
        self.assertIn('sendLiteralAction(refreshAction)', helper)
        self.assertIn(
            'invokeLiteralAction(submitAction, tag)', helper
        )
        self.assertIn('rawget(object, "onlyTag")', helper)
        self.assertIn('rawget(object, "canClaim")', helper)
        self.assertIn('rawget(object, "Accepted")', helper)
        self.assertIn('rawget(object, "Progress")', helper)
        self.assertIn('rawget(object, "Completed")', helper)
        self.assertIn('direct:FireServer(action)', source)
        self.assertIn('direct:InvokeServer(action, payload)', source)
        self.assertNotIn("SHOW_LOCAL_UI", helper)
        self.assertNotIn("FireBindable", helper)
        self.assertNotIn("ScreenGui", helper)
        self.assertNotIn("活动在线3分钟", source)
        self.assertNotIn("每日击杀指定怪物", source)


if __name__ == "__main__":
    unittest.main()
