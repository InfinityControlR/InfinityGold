"""Execute the shipped Broom startup/retry state machine under Luau."""

from __future__ import annotations

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "games" / "magicloot_locomotion.lua"


def luau_binary() -> Path | None:
    names = ("luau.exe", "luau")
    candidates = (
        ROOT / ".tools" / "luau",
    )
    for directory in candidates:
        for name in names:
            candidate = directory / name
            if candidate.is_file():
                return candidate
    found = shutil.which("luau")
    return Path(found) if found else None


def broom_source() -> str:
    source = MODULE.read_text(encoding="utf-8")
    state_left = source.index("    local broomStages =")
    state_right = source.index("    local function startBroomWorker()", state_left)
    api_left = source.index("    function api:OnConfigLoaded()", state_right)
    api_right = source.index("    function api:GetBroomStatus()", api_left)
    state = source[state_left:state_right].replace("os.clock()", "clockNow()")
    return state + "\nlocal api = {}\n" + source[api_left:api_right]


class BroomStartupFlowTests(unittest.TestCase):
    def test_config_priority_retry_confirmation_and_rearm(self) -> None:
        runner = luau_binary()
        if runner is None:
            self.skipTest("Luau runner is unavailable")

        fixture = f'''\
local now = 0
local enabled = true
local selected = "28"
local challenge = 0
local calls = {{}}
local enteredStages = {{}}
local priorityAllowed = false

local function clockNow()
    return now
end

local context = {{}}
function context.option(name, fallback)
    if name == "BroomStage" then return selected end
    if name == "BroomReturnDelay" then return 5 end
    return fallback
end
function context.toggle(name)
    return name == "AutoBroom" and enabled
end
function context.broomGate()
    return priorityAllowed, "broom waiting for alchemy"
end
function context.notify() end
function context.onBroomStageEntered(stage)
    table.insert(enteredStages, {{ stage = stage, at = now }})
end

local challengeValue = {{ Value = challenge }}
local player = {{}}
function player:FindFirstChild(name)
    if name ~= "InDungeonChallenge" then return nil end
    challengeValue.Value = challenge
    return challengeValue
end
local players = {{ LocalPlayer = player }}

local requestRemote = {{}}
function requestRemote:IsA(className)
    return className == "RemoteEvent"
end
function requestRemote:IsDescendantOf(parent)
    return parent ~= nil
end
function requestRemote:FireServer(action, stage)
    table.insert(calls, {{ action = action, stage = stage, at = now }})
end

local eventFolder = {{}}
function eventFolder:FindFirstChild(name)
    if name == "NetWorkRemoteEvent" then return requestRemote end
    return nil
end
local msg = {{}}
function msg:FindFirstChild(name)
    if name == "RemoteEvent" then return eventFolder end
    return nil
end
local replicatedStorage = {{}}
function replicatedStorage:FindFirstChild(name)
    if name == "Msg" then return msg end
    return nil
end

{broom_source()}

assert(broomStage("28") == 28)
assert(broomStage("32") == nil)

-- No network activity is allowed before the old core finishes restoring all
-- controls from SaveManager.
updateBroom()
assert(#calls == 0 and broom.status == "broom waiting for config")

-- A saved Auto Broom value creates an activation edge only after config load.
-- Its one-second delay must not start until Alchemy/Sell release the gate.
assert(api:OnConfigLoaded())
updateBroom()
assert(broom.armed and #calls == 0)
now = 0.99
updateBroom()
assert(#calls == 0)
now = 1
updateBroom()
assert(#calls == 0 and broom.status == "broom waiting for alchemy",
    "Broom ignored the Alchemy/Sell priority gate")
priorityAllowed = true
updateBroom()
assert(#calls == 0 and broom.delayStarted and broom.readyAt == 2,
    "initial delay was consumed while the priority gate was closed")
now = 1.99
updateBroom()
assert(#calls == 0)
now = 2
updateBroom()
assert(#calls == 1 and calls[1].action == "关卡跳关请求" and calls[1].stage == 28)

-- A request with no room confirmation remains armed and retries after five
-- seconds, never earlier.
now = 6.99
updateBroom()
assert(#calls == 1)
now = 7
updateBroom()
assert(#calls == 2 and broom.requestAttempts == 2)
assert(#enteredStages == 0, "Broom announced entry before room confirmation")

-- Entering the first room confirms the trip and cancels the pending retry.
challenge = 1
now = 10
updateBroom()
assert(#calls == 2 and broom.armed == false)
assert(#enteredStages == 1 and enteredStages[1].stage == 28
    and enteredStages[1].at == 10,
    "confirmed Broom did not hand the selected stage to Farm")
now = 50
updateBroom()
assert(#calls == 2 and #enteredStages == 1,
    "confirmed Broom entry was emitted more than once")

-- Loading the same enabled config while already in a room must not request a
-- duplicate journey.
now = 51
assert(api:OnConfigLoaded())
updateBroom()
assert(#calls == 2 and broom.armed == false)

-- Loading that same enabled config at base creates a fresh edge. Three
-- unconfirmed requests end one retry cycle, never the whole AutoBroom session.
challenge = 0
now = 60
assert(api:OnConfigLoaded())
updateBroom()
assert(broom.armed and #calls == 2)
now = 61
updateBroom()
now = 66
updateBroom()
now = 71
updateBroom()
assert(#calls == 5 and broom.armed == true and broom.requestAttempts == 0)
now = 75.99
updateBroom()
assert(#calls == 5)
now = 76
updateBroom()
assert(#calls == 6 and broom.requestAttempts == 1,
    "Broom did not automatically start a new retry cycle")

-- A transient nil during AutoReturn must not leave waitingForBase latched.
challenge = nil
assert(api:OnAutoReturnFull())
broom.lastChallenge = nil
challenge = 0
priorityAllowed = false
now = 80
updateBroom()
assert(broom.waitingForBase == false and broom.armed == true
    and broom.delayStarted == false and broom.readyAt == 0
    and broom.status == "broom waiting for alchemy",
    "missed >0 -> 0 replication transition stranded Broom")
priorityAllowed = true
updateBroom()
assert(#calls == 6 and broom.delayStarted and broom.readyAt == 85,
    "return delay did not start after the economy gate opened")
now = 84.99
updateBroom()
assert(#calls == 6)
now = 85
updateBroom()
assert(#calls == 7 and calls[7].at == 85,
    "Alchemy/Sell time consumed the configured Broom Return Delay")

-- The retry counter is cycle-local and resets after the third send. Entry
-- confirmation must still hand the Broom stage to Farm through the independent
-- requested-stage latch, otherwise Running/Walking consume Enter Delay.
now = 90
updateBroom()
now = 95
updateBroom()
assert(#calls == 9 and broom.requestAttempts == 0
    and broom.requestedStage == 28,
    "third Broom send discarded the pending stage latch")
challenge = 1
now = 95.1
updateBroom()
assert(#enteredStages == 2 and enteredStages[2].stage == 28
    and enteredStages[2].at == 95.1,
    "entry after retry-counter reset did not bypass Enter Delay")
assert(broom.requestedStage == nil and broom.armed == false,
    "confirmed Broom entry did not consume its pending stage latch")

print("broom_startup_flow=ok")
'''

        with tempfile.NamedTemporaryFile(
            "w", suffix=".luau", delete=False, encoding="utf-8", newline="\n"
        ) as handle:
            handle.write(fixture)
            path = Path(handle.name)
        try:
            completed = subprocess.run(
                [str(runner), str(path)],
                capture_output=True,
                text=True,
                timeout=30,
            )
        finally:
            path.unlink(missing_ok=True)

        self.assertEqual(
            completed.returncode,
            0,
            f"Broom startup flow failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("broom_startup_flow=ok", completed.stdout)


if __name__ == "__main__":
    unittest.main()
