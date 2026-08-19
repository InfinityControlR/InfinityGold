-- Offline geometry checks for Walking's final farm point.
-- Run with: luau tests/walking_geometry_smoke.luau

local Locomotion = require("../games/magicloot_locomotion")
local failures = {}

local function close(left, right)
    return left ~= nil and math.abs(left - right) < 0.0001
end

local function check(name, condition)
    if condition then
        print("ok   " .. name)
    else
        table.insert(failures, name)
        print("FAIL " .. name)
    end
end

local stageOneX, stageOneZ = Locomotion._entryDirection2D(1, 0, 0, 0, 100)
check("entry direction: stage 1 faces away from stage 2", close(stageOneX, 0)
    and close(stageOneZ, -1))

local laterX, laterZ = Locomotion._entryDirection2D(4, 100, 0, 0, 0)
check("entry direction: later stage faces its predecessor", close(laterX, -1)
    and close(laterZ, 0))

local missingX, missingZ = Locomotion._entryDirection2D(4, 100, 0, 100, 0)
check("entry direction: coincident centers fall back", missingX == nil
    and missingZ == nil)

-- A 100x40 footprint reaches its X edge after 50 studs and its Z edge
-- after 20. Walking must stop halfway to whichever edge the ray hits first.
check("halfway: X edge", close(
    Locomotion._halfwayFootprintDistance(100, 40, 1, 0),
    25
))
check("halfway: Z edge", close(
    Locomotion._halfwayFootprintDistance(100, 40, 0, -1),
    10
))

local diagonal = math.sqrt(0.5)
check("halfway: diagonal uses first rectangular edge", close(
    Locomotion._halfwayFootprintDistance(100, 40, diagonal, diagonal),
    10 / diagonal
))
-- A +X world entry transformed by a 90-degree yaw becomes +Z in local space.
-- For a local Z size of 80 the target must therefore sit 20 studs from center.
check("halfway: rotated footprint uses local axes", close(
    Locomotion._halfwayFootprintDistance(40, 80, 0, 1),
    20
))
check("halfway: zero direction falls back", Locomotion._halfwayFootprintDistance(
    100,
    40,
    0,
    0
) == nil)
check("halfway: invalid footprint falls back", Locomotion._halfwayFootprintDistance(
    0,
    40,
    1,
    0
) == nil)

if #failures > 0 then
    error("walking geometry failures: " .. table.concat(failures, ", "))
end

print("all walking_geometry_smoke checks passed")
