local vectorMeta = {}
vectorMeta.__index = function(value, key)
    if key == "Magnitude" then
        return math.sqrt(value.X * value.X + value.Y * value.Y + value.Z * value.Z)
    end
    if key == "Unit" then
        local magnitude = vectorMeta.__index(value, "Magnitude")
        if magnitude == 0 then
            return setmetatable({ X = 0, Y = 0, Z = 0 }, vectorMeta)
        end
        return setmetatable({
            X = value.X / magnitude,
            Y = value.Y / magnitude,
            Z = value.Z / magnitude,
        }, vectorMeta)
    end
    return nil
end
vectorMeta.__add = function(left, right)
    return setmetatable({
        X = left.X + right.X,
        Y = left.Y + right.Y,
        Z = left.Z + right.Z,
    }, vectorMeta)
end
vectorMeta.__sub = function(left, right)
    return setmetatable({
        X = left.X - right.X,
        Y = left.Y - right.Y,
        Z = left.Z - right.Z,
    }, vectorMeta)
end
vectorMeta.__mul = function(left, right)
    if type(left) == "number" then left, right = right, left end
    return setmetatable({
        X = left.X * right,
        Y = left.Y * right,
        Z = left.Z * right,
    }, vectorMeta)
end

Vector3 = {}
function Vector3.new(x, y, z)
    return setmetatable({ X = x, Y = y, Z = z }, vectorMeta)
end

local nativeTypeof = typeof or type
typeof = function(value)
    if getmetatable(value) == vectorMeta then return "Vector3" end
    return nativeTypeof(value)
end

Enum = {
    Material = { Air = "Air" },
    HumanoidStateType = { Dead = "Dead", Jumping = "Jumping" },
    RenderPriority = { Character = { Value = 100 } },
}

task = {
    spawn = function() end,
    wait = function() end,
}

local renderCallback = nil
local runService = {}
function runService:BindToRenderStep(_, _, callback)
    renderCallback = callback
end
function runService:UnbindFromRenderStep()
    renderCallback = nil
end

local players = { LocalPlayer = {} }
local replicatedStorage = {}
game = {}
function game:GetService(name)
    if name == "RunService" then return runService end
    if name == "Players" then return players end
    if name == "ReplicatedStorage" then return replicatedStorage end
    error("unexpected service " .. tostring(name))
end

local center = Vector3.new(0, 3, 0)
local stagePart = {
    Position = Vector3.new(0, 0, 0),
    Size = Vector3.new(100, 2, 100),
}
function stagePart:IsA(className)
    return className == "BasePart"
end
stagePart.CFrame = {}
function stagePart.CFrame:PointToObjectSpace(point)
    return point - stagePart.Position
end
function stagePart.CFrame:VectorToWorldSpace(offset)
    return offset
end

local character = {}
local humanoid = {
    Health = 100,
    FloorMaterial = "Ground",
    Jump = false,
    lastMove = nil,
    lastState = nil,
}
humanoid.Parent = character
function humanoid:Move(direction)
    self.lastMove = direction
end
function humanoid:ChangeState(nextState)
    self.lastState = nextState
end
function character:FindFirstChildOfClass(className)
    if className == "Humanoid" then return humanoid end
    return nil
end

local root = {
    Parent = character,
    Position = Vector3.new(-60, 3, 0),
}
local runningDistance = 12
local enterDelay = 30
local context = {}
function context.option(name, fallback)
    if name == "RunningDistance" then return runningDistance end
    if name == "EnterDelay" then return enterDelay end
    return fallback
end
function context.stagePart()
    return stagePart
end

local Locomotion = require("../games/magicloot_locomotion")
local controller = Locomotion.create(context)

assert(table.concat(controller:GetModes(), ",") == "Walking,Running")
assert(controller:Supports("Walking"))
assert(controller:Supports("Running"))

controller:Prepare("Running", 2, stagePart)
local delayed = controller:Update("Running", 2, stagePart, root, center)
assert(string.find(delayed, "entering stage 2", 1, true) ~= nil)
assert(renderCallback == nil, "normal route ignored its configured Enter Delay")
local approaching = controller:Update("Running", 2, stagePart, root, center, true)
assert(string.find(approaching, "running", 1, true) ~= nil)
assert(renderCallback ~= nil)
assert(humanoid.Jump == false)

-- Crossing the footprint starts the orbit even while far from the centre.
-- Simulate the normal controller clearing Jump first: our later render step
-- must restore both the Jump property and the Jumping state request.
root.Position = Vector3.new(-49, 3, 0)
local orbiting = controller:Update("Running", 2, stagePart, root, center, true)
assert(string.find(orbiting, "running 12.0 studs from center", 1, true) ~= nil)
humanoid.Jump = false
renderCallback()
assert(humanoid.lastMove ~= nil and math.abs(humanoid.lastMove.Z) > 0.01)
assert(humanoid.Jump == true)
assert(humanoid.lastState == Enum.HumanoidStateType.Jumping)

-- The render callback is frequent, but jumping remains rate-limited.
humanoid.Jump = false
renderCallback()
assert(humanoid.Jump == false)

-- The radius option is read live without preparing the route again.
runningDistance = 20
local resized = controller:Update("Running", 2, stagePart, root, center, true)
assert(string.find(resized, "running 20.0 studs from center", 1, true) ~= nil)

-- Walking retains Magic's center-destination contract and never jumps when it
-- has reached that destination.
humanoid.Jump = false
humanoid.lastState = nil
root.Position = center
controller:Prepare("Walking", 2, stagePart)
local arrived = controller:Update("Walking", 2, stagePart, root, center, true)
assert(string.find(arrived, "walking arrived", 1, true) ~= nil)
assert(humanoid.Jump == false)
assert(humanoid.lastState == nil)

-- World Event reuses the same render-step/native Running controller around a
-- moving dragon target, without a stage part or teleport.
controller:StopWalking()
root.Position = Vector3.new(-20, 3, 0)
humanoid.Jump = false
humanoid.lastMove = nil
local eventRunning = controller:UpdateEventRunning(root, center)
assert(string.find(eventRunning, "event running 20.0 studs from dragon", 1, true) ~= nil)
assert(renderCallback ~= nil)
renderCallback()
assert(humanoid.lastMove ~= nil and humanoid.lastMove.Magnitude > 0.01)
assert(humanoid.Jump == true)

local movedDragon = Vector3.new(10, 3, 0)
eventRunning = controller:UpdateEventRunning(root, movedDragon)
assert(string.find(eventRunning, "event running 20.0 studs from dragon", 1, true) ~= nil)
controller:StopWalking()
assert(renderCallback == nil)

print("running_orbit_smoke=ok")
