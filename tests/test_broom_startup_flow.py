"""Execute the shipped Broom startup/retry state machine under Luau."""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from tools.ensure_luau import run_binary as luau_runner  # noqa: E402


def broom_state_source() -> str:
    source = (REPO_ROOT / "games" / "magicloot_locomotion.lua").read_text(
        encoding="utf-8"
    )
    left = source.index("    local broomStages =")
    right = source.index("    local function startBroomWorker()", left)
    # The production code intentionally uses os.clock.  A deterministic clock
    # lets this smoke exercise the exact state machine without sleeping.
    return source[left:right].replace("os.clock()", "clockNow()")


class BroomStartupFlowTests(unittest.TestCase):
    def test_alchemy_suspension_api_round_trips(self):
        source = (REPO_ROOT / "games" / "magicloot_locomotion.lua").read_text(
            encoding="utf-8"
        )
        self.assertIn("broom.giveUpAt = os.clock() + BROOM_ARM_TIMEOUT", source)
        left = source.index("    function api:SetBroomSuspended(suspended)")
        right = source.index("    function api:GetBroomStatus()", left)
        method = source[left:right]
        fixture = f'''\
local broom = {{ alive = true, suspended = false, status = "idle" }}
local api = {{}}
{method}
assert(api:SetBroomSuspended(true) == true
    and broom.suspended == true
    and broom.status == "broom paused for Alchemy",
    "SetBroomSuspended(true) did not pause Broom")
assert(api:SetBroomSuspended(false) == true
    and broom.suspended == false
    and broom.status == "broom resumed after Alchemy",
    "SetBroomSuspended(false) did not resume Broom")
broom.alive = false
assert(api:SetBroomSuspended(true) == false and broom.suspended == false,
    "dead Broom accepted a new suspension")
print("broom_alchemy_suspension_api=ok")
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
            f"Broom suspension API smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("broom_alchemy_suspension_api=ok", completed.stdout)

    def test_saved_config_retries_until_room_entry_then_stops(self):
        section = broom_state_source()
        fixture = f'''\
local now = 0
local enabled = true
local selected = "28"
local challenge = 0
local challengeAvailable = true
local returnBlocked = false
local returnArrival = 0
local acknowledgedReturn = 0
local remoteAvailable = true
local failuresRemaining = 0
local alwaysFail = false
local calls = {{}}

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
function context.notify() end
function context.returnTravelPending() return returnBlocked end
function context.returnArrivalToken()
    if returnArrival > acknowledgedReturn then return returnArrival end
    return nil
end
function context.acknowledgeReturnArrival(token)
    acknowledgedReturn = math.max(acknowledgedReturn, token)
end

local challengeValue = {{ Value = challenge }}
local player = {{}}
function player:FindFirstChild(name)
    if name ~= "InDungeonChallenge" then return nil end
    if not challengeAvailable then return nil end
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
    if alwaysFail or failuresRemaining > 0 then
        failuresRemaining = math.max(0, failuresRemaining - 1)
        error("network warming up")
    end
end

local eventFolder = {{}}
function eventFolder:FindFirstChild(name)
    if name == "NetWorkRemoteEvent" and remoteAvailable then return requestRemote end
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

{section}

assert(broomStage("28") == 28, "new Broom stage 28 was rejected")
assert(broomStage("32") == nil, "farm ceiling 32 leaked into the Broom catalog")

-- The worker must remain completely passive until the core finishes loading
-- all saved controls.
updateBroom()
assert(#calls == 0 and broom.status == "broom waiting for config",
    "Broom acted before config restoration completed")

-- Saved AutoBroom=true creates a fresh activation, but with a short bootstrap
-- grace period so a reload cannot fire during partial initialization.
broom.configReady = true
updateBroom()
assert(broom.armed == true and #calls == 0, "saved AutoBroom did not arm safely")
now = 0.99
updateBroom()
assert(#calls == 0, "initial grace period was ignored")
now = 1
broom.suspended = true
updateBroom()
assert(#calls == 0 and broom.armed == true,
    "Alchemy suspension did not hold the armed Broom request")
broom.suspended = false
updateBroom()
assert(#calls == 1 and calls[1].action == "关卡跳关请求" and calls[1].stage == 28,
    "initial stage request was not emitted")
assert(broom.armed == true and broom.requestAttempts == 1,
    "request was consumed before dungeon confirmation")

-- A locally successful FireServer is not proof that the server started the
-- trip.  Stay armed and retry only after the confirmation timeout.
now = 5.99
updateBroom()
assert(#calls == 1, "Broom retried before its confirmation timeout")
now = 6
updateBroom()
assert(#calls == 2 and broom.requestAttempts == 2,
    "ignored startup request was not retried")

-- Passing room 1 flips InDungeonChallenge positive.  This acknowledgement
-- must cancel the pending retry before another remote can be sent.
challenge = 1
now = 10.99
updateBroom()
assert(#calls == 2 and broom.armed == false,
    "room entry did not cancel the pending Broom retry")
now = 40
updateBroom()
assert(#calls == 2, "Broom sent a duplicate request after room entry")

-- A thrown FireServer call also remains retryable instead of consuming the
-- activation forever.
enabled = false
challenge = 0
updateBroom()
enabled = true
failuresRemaining = 1
now = 50
updateBroom()
now = 51
updateBroom()
assert(#calls == 3 and broom.armed == true and broom.requestAttempts == 1,
    "failed initial request was not kept pending")
now = 56
updateBroom()
assert(#calls == 4 and broom.requestAttempts == 2,
    "failed initial request did not retry")
challenge = 1
now = 56.1
updateBroom()
assert(broom.armed == false, "successful retry was not acknowledged")

-- A request that cannot be confirmed is bounded; it must never spam forever.
enabled = false
challenge = 0
updateBroom()
enabled = true
alwaysFail = false
now = 70
updateBroom()
now = 71
updateBroom()
now = 76
updateBroom()
now = 81
updateBroom()
local afterMaximum = #calls
assert(broom.armed == true and broom.finalConfirmationPending == true,
    "Broom discarded its final confirmation window")
now = 85.99
updateBroom()
assert(broom.armed == true and #calls == afterMaximum,
    "Broom resent or discarded the final request too early")
now = 86
updateBroom()
assert(broom.armed == false and broom.requestAttempts == 0,
    "Broom did not stop after the final confirmation timeout")
now = 120
updateBroom()
assert(#calls == afterMaximum, "Broom kept retrying after its bounded maximum")

-- If the remote appears only after the game already reports a dungeon, the
-- pending activation is cancelled before remote lookup/send.
enabled = false
alwaysFail = false
challenge = 0
updateBroom()
enabled = true
remoteAvailable = false
now = 130
updateBroom()
now = 131
updateBroom()
local beforeLateRemote = #calls
challenge = 1
remoteAvailable = true
now = 132
updateBroom()
assert(#calls == beforeLateRemote and broom.armed == false,
    "pending startup request fired after dungeon entry")

-- Missing replicated state/remotes must not leave every other feature blocked
-- forever. The armed episode gets one bounded availability window.
enabled = false
challenge = 0
remoteAvailable = false
now = 150
updateBroom()
enabled = true
updateBroom()
now = 151
updateBroom()
assert(broom.armed == true, "missing remote did not remain briefly retryable")
now = 181
updateBroom()
assert(broom.armed == false,
    "unavailable Broom state did not release its bounded armed episode")

-- A shared DUNGEON_RETURN_TOWN hold survives reload and must win over a fresh
-- AutoBroom activation until the return state becomes safe.
enabled = false
challengeAvailable = true
challenge = 0
remoteAvailable = true
now = 185
updateBroom()
enabled = true
returnBlocked = true
now = 186
updateBroom()
assert(broom.armed == false and broom.status == "broom waiting for inventory return travel",
    "Broom ignored the shared return-travel exclusion")
returnBlocked = false
now = 187
updateBroom()
assert(broom.armed == true
    and broom.reason == "inventory return"
    and broom.readyAt == 192,
    "Broom reload lost BroomReturnDelay after the shared return hold cleared")
enabled = false
updateBroom()

-- If the return finishes during config bootstrap, Broom may never observe a
-- blocked tick. The persisted arrival token still has to select the inventory
-- delay on that very first base tick, then be consumed exactly once.
returnArrival = 1
enabled = true
returnBlocked = false
challenge = 0
now = 200
updateBroom()
assert(broom.armed == true
    and broom.reason == "inventory return"
    and broom.readyAt == 205
    and acknowledgedReturn == 1,
    "first post-reload base tick ignored the persisted return episode")
enabled = false
updateBroom()

-- Auto Return can arm Broom before the challenge value temporarily disappears.
-- Waiting for the >0 -> 0 transition is bounded independently of `armed` so a
-- lost return can never block Alchemy forever.
remoteAvailable = true
challengeAvailable = false
enabled = true
broom.enabled = true
broom.stage = 28
broom.waitingForBase = true
broom.returnEpisode = true
broom.armed = false
broom.giveUpAt = 220
now = 219.9
updateBroom()
assert(broom.waitingForBase == true,
    "Broom abandoned the return transition before its deadline")
now = 220
updateBroom()
assert(broom.waitingForBase == false
    and broom.returnEpisode == false
    and broom.giveUpAt == 0,
    "unobservable return transition blocked Broom/Alchemy forever")

print("broom_startup_retry_smoke=ok")
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
            f"Broom startup smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("broom_startup_retry_smoke=ok", completed.stdout)


if __name__ == "__main__":
    unittest.main()
