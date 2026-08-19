"""Execute InfinityGold's shipped Broom request helper under Luau.

The proven Magic fix sends only ``关卡跳关请求``.  Calling ``上下扫帚`` after
that request toggles/equips the broom instead of performing a cleaner direct
stage transition, so this regression test exercises the real helper body and
keeps that second action out of the flow.
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
    source = (REPO_ROOT / "games" / "magicloot_locomotion.lua").read_text(
        encoding="utf-8"
    )
    left = source.index(start)
    right = source.index(end, left)
    return source[left:right]


BROOM_REQUEST = helper_source(
    "    local function invalidateBroomTransaction()",
    "    local function disarmBroom()",
)


class BroomRequestFlowTests(unittest.TestCase):
    def test_stage_request_is_single_step_and_releases_its_lock(self):
        fixture = f'''\
local broom = {{
    epoch = 0,
    transactionActive = false,
    lastAttemptAt = -math.huge,
}}
local calls = {{}}
local requestRemote = {{}}
function requestRemote:FireServer(action, stage)
    table.insert(calls, {{ action = action, stage = stage }})
end

{BROOM_REQUEST}

local ok, detail = requestBroomStage(requestRemote, 13, 42)
assert(ok == true and detail == "stage request", "stage request did not succeed")
assert(#calls == 1, "one activation emitted more than one request")
assert(calls[1].action == "关卡跳关请求" and calls[1].stage == 13,
    "wrong stage request payload")
assert(broom.transactionActive == false, "single-flight lock was not released")
assert(broom.lastAttemptAt == 42, "attempt timestamp was not recorded")

broom.transactionActive = true
ok, detail = requestBroomStage(requestRemote, 18, 43)
assert(ok == false and detail == "transaction already active",
    "an overlapping request was not rejected")
assert(#calls == 1, "overlapping activation sent another request")
broom.transactionActive = false

local staleRemote = {{}}
function staleRemote:FireServer(action, stage)
    table.insert(calls, {{ action = action, stage = stage }})
    invalidateBroomTransaction()
end
ok, detail = requestBroomStage(staleRemote, 23, 44)
assert(ok == false and detail == "stage request sent; result superseded by newer state",
    "a superseded request was reported as current")
assert(broom.transactionActive == false, "superseded request retained its lock")

local failingRemote = {{}}
function failingRemote:FireServer()
    error("network failure")
end
ok, detail = requestBroomStage(failingRemote, 4, 45)
assert(ok == false and string.find(detail, "request failed", 1, true) ~= nil,
    "network failure was hidden")
assert(broom.transactionActive == false, "failed request retained its lock")

print("broom_stage_request_smoke=ok")
'''
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
            f"Broom request smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("broom_stage_request_smoke=ok", completed.stdout)


if __name__ == "__main__":
    unittest.main()
