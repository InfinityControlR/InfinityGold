"""Execute Magic-compatible Training Ground selection semantics."""

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


SELECTION_HELPER = core_slice(
    "    local function selectedTrainGroundId()",
    "    local function trainGroundPart(trainId)",
)
TRAIN_WORKER = core_slice(
    "    task.spawn(function() -- train",
    "    task.spawn(function() -- index claims",
)


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


class TrainingSelectionFlowTests(unittest.TestCase):
    def test_explicit_bypasses_stale_predicate_and_best_matches_magic_order(self):
        fixture = f"""
local cfg = {{ TrainGround = "#12 Training ground" }}
local enterable = {{ [3] = false, [7] = true, [12] = true }}
local predicateCalls = {{}}
local function canEnterTrainGround(id)
    table.insert(predicateCalls, id)
    return enterable[id] == true
end
local function catalogByName(name)
    assert(name == "trainConf")
    return {{
        {{ id = 12 }},
        {{ id = 3 }},
        {{ id = 7 }},
    }}
end

{SELECTION_HELPER}

local explicit = selectedTrainGroundId()
assert(explicit == 12, "explicit ground was vetoed by CanEnterTrainGround")
assert(#predicateCalls == 0, "explicit ground unexpectedly called the Best predicate")

cfg.TrainGround = "Best available"
local best = selectedTrainGroundId()
assert(best == 7, "Best did not use Magic's ascending first-enterable order")
assert(#predicateCalls == 2 and predicateCalls[1] == 3 and predicateCalls[2] == 7,
    "Best predicate order changed")
print("training_selection_flow_smoke=ok")
"""
        completed = run_luau(fixture)
        self.assertEqual(
            completed.returncode,
            0,
            f"Training selection smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("training_selection_flow_smoke=ok", completed.stdout)

    def test_worker_moves_updates_zone_and_clicks(self):
        fixture = f"""
local function vector(x, y, z)
    return setmetatable({{ X = x, Y = y, Z = z }}, {{
        __add = function(left, right)
            return vector(left.X + right.X, left.Y + right.Y, left.Z + right.Z)
        end,
    }})
end
local Vector3 = {{ new = vector }}
local CFrame = {{ new = function(position) return {{ Position = position }} end }}
local sessionAlive = true
local cfg = {{ AutoTrain = true }}
local ground = {{ Position = vector(10, 2, 30), Size = {{ Y = 4 }} }}
local root = {{ Position = vector(0, 0, 0), CFrame = nil }}
local zoneCalls = 0
local clickCalls = 0
local waits = 0

local function farmObjectiveGate() return true end
local function selectedTrainGroundId() return 12 end
local function trainGroundPart(id) assert(id == 12) return ground end
local function characterParts() return {{ root = root }} end
local function isOverFootprint() return false end
local function playerNumber(name) assert(name == "TrainGroundId") return 0 end
local function sendAction(action, payload)
    assert(action == "TRAIN_ZONE_UPDATE" and payload.trainId == 12)
    zoneCalls += 1
    return true
end
local function invokeAction(action, payload)
    assert(action == "TRAIN_MANUAL_CLICK" and type(payload) == "table"
        and next(payload) == nil)
    clickCalls += 1
    return true
end
local task = {{}}
task.spawn = function(callback) callback() end
task.wait = function()
    waits += 1
    if waits >= 3 then sessionAlive = false end
end

{TRAIN_WORKER}

assert(root.CFrame ~= nil
    and root.CFrame.Position.X == 10
    and root.CFrame.Position.Y == 7
    and root.CFrame.Position.Z == 30,
    "Training worker did not move above the selected ground")
assert(zoneCalls == 1, "Training worker did not update its zone")
assert(clickCalls == 1, "Training worker did not invoke manual training")
print("training_worker_flow_smoke=ok")
"""
        completed = run_luau(fixture)
        self.assertEqual(
            completed.returncode,
            0,
            f"Training worker smoke failed:\n{completed.stdout}\n{completed.stderr}",
        )
        self.assertIn("training_worker_flow_smoke=ok", completed.stdout)


if __name__ == "__main__":
    unittest.main()
