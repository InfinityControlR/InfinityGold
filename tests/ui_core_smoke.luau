-- Offline construction harness: runs InfinityUI and the core script against a
-- minimal Roblox API simulation under the plain Luau CLI.
--
-- Catching construction-time errors here means the dashboard cannot ship a
-- silent "nothing opens" failure. Run from the repository root:
--   luau tests/ui_core_smoke.luau

local failures = {}

local function fail(message)
    table.insert(failures, tostring(message))
    print("FAIL " .. tostring(message))
end

-- Signals -----------------------------------------------------------------

local function makeSignal()
    local handlers = {}
    local signal = {}
    function signal:Connect(handler)
        table.insert(handlers, handler)
        return { Disconnect = function() end }
    end
    function signal:Fire(...)
        for _, handler in ipairs(handlers) do
            handler(...)
        end
    end
    return signal
end

-- Instances ---------------------------------------------------------------

local SIGNAL_NAMES = {
    InputBegan = true,
    InputChanged = true,
    InputEnded = true,
    MouseButton1Click = true,
    MouseButton1Down = true,
    FocusLost = true,
    Idled = true,
    Changed = true,
}

local InstanceMT
local InstanceMethods = {}

local function newInstance(className, name)
    local self = setmetatable({
        __children = {},
        ClassName = className,
        Name = name or className,
        AbsoluteSize = Vector2.new(1024, 640),
        AbsolutePosition = Vector2.new(0, 0),
    }, InstanceMT)
    return self
end

function InstanceMethods:GetChildren()
    local copy = {}
    for index, child in ipairs(self.__children) do
        copy[index] = child
    end
    return copy
end

function InstanceMethods:IsA(className)
    return self.ClassName == className
end

function InstanceMethods:FindFirstChild(name)
    for _, child in ipairs(self.__children) do
        if child.Name == name then
            return child
        end
    end
    return nil
end

function InstanceMethods:FindFirstChildOfClass(className)
    for _, child in ipairs(self.__children) do
        if child.ClassName == className then
            return child
        end
    end
    return nil
end

function InstanceMethods:WaitForChild(name)
    return InstanceMethods.FindFirstChild(self, name)
end

function InstanceMethods:IsDescendantOf()
    return false
end

function InstanceMethods:Destroy()
    local parent = rawget(self, "Parent")
    if parent ~= nil then
        for index, child in ipairs(parent.__children) do
            if child == self then
                table.remove(parent.__children, index)
                break
            end
        end
    end
    rawset(self, "Parent", nil)
end

function InstanceMethods:GetPropertyChangedSignal()
    return makeSignal()
end

InstanceMT = {
    __index = function(self, key)
        local method = InstanceMethods[key]
        if method ~= nil then
            return method
        end
        if SIGNAL_NAMES[key] then
            local signal = makeSignal()
            rawset(self, key, signal)
            return signal
        end
        local raw = rawget(self, key)
        if raw ~= nil then
            return raw
        end
        if type(key) == "string" then
            for _, child in ipairs(self.__children) do
                if child.Name == key then
                    return child
                end
            end
        end
        return nil
    end,
    __newindex = function(self, key, value)
        if key == "Parent" then
            local old = rawget(self, "Parent")
            if old ~= nil then
                for index, child in ipairs(old.__children) do
                    if child == self then
                        table.remove(old.__children, index)
                        break
                    end
                end
            end
            if value ~= nil then
                table.insert(value.__children, self)
            end
            rawset(self, "Parent", value)
            return
        end
        if key == "Size" and type(value) == "table" and value.X and value.Y then
            -- Cheap layout approximation: a pixel Size maps to AbsoluteSize.
            if value.X.Scale == 0 and value.Y.Scale == 0 then
                rawset(self, "AbsoluteSize", Vector2.new(value.X.Offset, value.Y.Offset))
            end
        end
        rawset(self, key, value)
    end,
}

Instance = { new = function(first, second)
    -- supports both Instance.new("X") and Instance:new("X") call styles
    return newInstance(second or first)
end }

-- Datatypes ---------------------------------------------------------------

local function arithmeticMetatable(zero)
    return {
        __add = function() return zero end,
        __sub = function() return zero end,
        __mul = function() return zero end,
    }
end

local EnumTokenMT = arithmeticMetatable(0)
local function makeEnumCategory()
    return setmetatable({}, {
        __index = function(category, key)
            local token = setmetatable({ Value = 0 }, EnumTokenMT)
            rawset(category, key, token)
            return token
        end,
    })
end

Enum = setmetatable({}, {
    __index = function(_, key)
        local category = makeEnumCategory()
        rawset(Enum, key, category)
        return category
    end,
})

local Vector3MT
Vector3 = {
    new = function(x, y, z)
        return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, Vector3MT)
    end,
    zero = nil,
}
Vector3MT = {
    __index = function(vector, key)
        if key == "Magnitude" then
            return math.sqrt(vector.X ^ 2 + vector.Y ^ 2 + vector.Z ^ 2)
        elseif key == "Unit" then
            local magnitude = math.sqrt(vector.X ^ 2 + vector.Y ^ 2 + vector.Z ^ 2)
            if magnitude == 0 then return Vector3.new(0, 0, 0) end
            return Vector3.new(vector.X / magnitude, vector.Y / magnitude, vector.Z / magnitude)
        end
        return nil
    end,
    __add = function(a, b) return Vector3.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end,
    __sub = function(a, b) return Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end,
    __mul = function(a, b)
        if type(b) == "number" then return Vector3.new(a.X * b, a.Y * b, a.Z * b) end
        return Vector3.new(0, 0, 0)
    end,
}
Vector3.zero = Vector3.new(0, 0, 0)

Vector2 = { new = function(x, y) return { X = x or 0, Y = y or 0 } end }

UDim = { new = function(scale, offset) return { Scale = scale or 0, Offset = offset or 0 } end }

local UDim2MT
UDim2 = {
    new = function(xs, xo, ys, yo)
        return setmetatable({ X = { Scale = xs or 0, Offset = xo or 0 }, Y = { Scale = ys or 0, Offset = yo or 0 } }, UDim2MT)
    end,
}
UDim2MT = {
    __add = function(a, b)
        return UDim2.new(a.X.Scale + b.X.Scale, a.X.Offset + b.X.Offset, a.Y.Scale + b.Y.Scale, a.Y.Offset + b.Y.Offset)
    end,
    __sub = function(a, b)
        return UDim2.new(a.X.Scale - b.X.Scale, a.X.Offset - b.X.Offset, a.Y.Scale - b.Y.Scale, a.Y.Offset - b.Y.Offset)
    end,
}

Color3 = {
    fromRGB = function(r, g, b) return { R = r, G = g, B = b } end,
    new = function(r, g, b) return { R = r, G = g, B = b } end,
}
ColorSequenceKeypoint = { new = function(time, value) return { Time = time, Value = value } end }
ColorSequence = { new = function(keypoints) return { Keypoints = keypoints } end }
TweenInfo = { new = function() return {} end }

CFrame = {
    new = function(...)
        return { Position = Vector3.new(0, 0, 0) }
    end,
    lookAt = function(...)
        return { Position = Vector3.new(0, 0, 0) }
    end,
}

-- Task scheduler ----------------------------------------------------------

local threads = {}
local delayed = {}
local clockRound = 0

task = {}

function task.spawn(fn, ...)
    local co = coroutine.create(fn)
    local ok, err = coroutine.resume(co, ...)
    if not ok then
        fail("task.spawn error: " .. tostring(debug.traceback(co, err)))
    end
    if coroutine.status(co) ~= "dead" then
        table.insert(threads, co)
    end
end

function task.wait()
    return coroutine.yield()
end

function task.delay(duration, fn, ...)
    local co = coroutine.create(fn)
    table.insert(delayed, {
        thread = co,
        readyRound = clockRound + math.max(1, math.ceil(tonumber(duration) or 0)),
    })
end

function task.defer(fn, ...)
    task.spawn(fn, ...)
end

local function pump(rounds)
    for _ = 1, rounds do
        clockRound = clockRound + 1
        for index = #delayed, 1, -1 do
            local entry = delayed[index]
            if entry.readyRound <= clockRound then
                table.remove(delayed, index)
                local ok, err = coroutine.resume(entry.thread)
                if not ok then
                    fail("delayed error: " .. tostring(debug.traceback(entry.thread, err)))
                elseif coroutine.status(entry.thread) ~= "dead" then
                    table.insert(threads, entry.thread)
                end
            end
        end
        for _, co in ipairs(threads) do
            if coroutine.status(co) ~= "dead" then
                local ok, err = coroutine.resume(co)
                if not ok then
                    fail("worker error: " .. tostring(debug.traceback(co, err)))
                end
            end
        end
    end
end

-- Services ----------------------------------------------------------------

local function makeService(className)
    return newInstance(className)
end

local services = {}
local function service(name)
    if services[name] == nil then
        services[name] = makeService(name)
    end
    return services[name]
end

local player = makeService("Player")
player.Name = "LocalPlayer"

local playerGui = makeService("PlayerGui")
playerGui.Name = "PlayerGui"
playerGui.Parent = player

local Players = service("Players")
rawset(Players, "LocalPlayer", player)

game = setmetatable({
    PlaceId = 133188236593503,
    CreatorId = 118455659,
    JobId = "job-id",
    IsLoaded = true,
    Loaded = makeSignal(),
    GetService = function(_, name)
        return service(name)
    end,
    HttpGet = function(_, _url)
        return ""
    end,
}, {
    __index = function(_, key)
        if key == "PlaceId" or key == "CreatorId" or key == "JobId" then
            return nil
        end
        return nil
    end,
})

workspace = service("Workspace")

TweenService = nil -- accessed through game:GetService

-- Patch TweenService with a playable object
do
    local tweenService = service("TweenService")
    rawset(tweenService, "Create", function(_, instance, _info, _props)
        return { Play = function() end }
    end)
end

warn = function(...) print("[warn]", ...) end

-- Harness -----------------------------------------------------------------
-- The module sources are injected here by tests/test_ui_core_smoke.py: the
-- plain Luau CLI isolates globals per required module, so the harness runs
-- everything inside a single chunk instead of using require.
-- @@INJECT_MODULES@@

local notifications = {}
do
    local originalNotify = Library.Notify
    function Library:Notify(options)
        table.insert(notifications, options)
        return originalNotify(self, options)
    end
end

local ok, err = xpcall(function()
    core(LocomotionFactory, Library, Common)
end, debug.traceback)

if not ok then
    fail("core construction error: " .. tostring(err))
end

pump(10)

if #Library._windows ~= 1 then
    fail("expected exactly one window, got " .. tostring(#Library._windows))
end

if #Library._windows == 1 then
    local window = Library._windows[1]
    if window.Frame == nil or window.Frame.Parent == nil then
        fail("window frame was never parented to a screen gui")
    end
end

if #notifications == 0 then
    fail("core never issued its loaded notification")
end

-- The render-verification block must have run and reported through the
-- banner channel (the only channel proven visible on every executor).
do
    local playerGui = player:FindFirstChildOfClass("PlayerGui")
    local statusGui = playerGui and playerGui:FindFirstChild("InfinityGoldStatus")
    local statusText = statusGui and statusGui:FindFirstChild("Status")
    if statusText == nil or not statusText.Text:find("dashboard", 1, true) then
        fail("render verification never reported through the banner")
    else
        print("banner: " .. statusText.Text)
    end
    local windowGui = Library._windows[1] and Library._windows[1].Gui
    if windowGui == nil or windowGui:FindFirstChild("IGProbe") == nil then
        fail("IG probe badge was not created in the window gui")
    end
    local toggleGui = playerGui and playerGui:FindFirstChild("InfinityGoldToggle")
    if toggleGui == nil or toggleGui:FindFirstChild("IG") == nil then
        fail("floating IG toggle button was not created")
    end
end

-- Floating button interaction: a tap toggles the dashboard, a drag moves the
-- button without toggling.
do
    local playerGui = player:FindFirstChildOfClass("PlayerGui")
    local toggleGui = playerGui and playerGui:FindFirstChild("InfinityGoldToggle")
    local button = toggleGui and toggleGui:FindFirstChild("IG")
    if button == nil then
        fail("cannot simulate the floating toggle: button missing")
    else
        local inputService = service("UserInputService")
        local touch = Enum.UserInputType.Touch

        -- Roblox frames start visible; make the stub match before tapping.
        Library._windows[1].Frame.Visible = true

        -- Tap: press and release in place -> toggles (hides) the dashboard.
        button.InputBegan:Fire({ UserInputType = touch, Position = Vector3.new(300, 300, 0) })
        inputService.InputEnded:Fire({ UserInputType = touch, Position = Vector3.new(300, 300, 0) })

        local statusGui = playerGui:FindFirstChild("InfinityGoldStatus")
        local statusText = statusGui and statusGui:FindFirstChild("Status")
        if statusText == nil or not statusText.Text:find("dashboard hidden", 1, true) then
            fail("tap on the IG button did not hide the dashboard")
        end

        -- Drag: move beyond the tap threshold -> repositions without toggling.
        button.InputBegan:Fire({ UserInputType = touch, Position = Vector3.new(300, 300, 0) })
        inputService.InputChanged:Fire({ UserInputType = touch, Position = Vector3.new(345, 331, 0) })
        inputService.InputEnded:Fire({ UserInputType = touch, Position = Vector3.new(345, 331, 0) })

        if button.Position.X.Offset ~= 45 or button.Position.Y.Offset ~= 31 then
            fail(string.format(
                "drag did not move the button: offset %d,%d",
                button.Position.X.Offset,
                button.Position.Y.Offset
            ))
        end
        statusGui = playerGui:FindFirstChild("InfinityGoldStatus")
        statusText = statusGui and statusGui:FindFirstChild("Status")
        if statusText == nil or not statusText.Text:find("dashboard hidden", 1, true) then
            fail("drag unexpectedly toggled the dashboard")
        end
    end
end

-- Dropdown interaction: header toggles open/closed, the list height is
-- capped, choosing an option closes it, and a tap outside closes it too.
do
    local function findDescendant(root, name)
        for _, child in ipairs(root:GetChildren()) do
            if child.Name == name then return child end
            local found = findDescendant(child, name)
            if found then return found end
        end
        return nil
    end

    local windowFrame = Library._windows[1] and Library._windows[1].Frame
    local dropdown = windowFrame and findDescendant(windowFrame, "Dropdown")
    if dropdown == nil then
        fail("cannot simulate a dropdown: none found in the window")
    else
        local header = dropdown:FindFirstChild("Button")
        local list = dropdown:FindFirstChild("List")
        if header == nil or list == nil then
            fail("dropdown is missing its header or list")
        else
            -- Open via the header: the 27-stage list must cap at 5 rows.
            header.MouseButton1Click:Fire()
            if list.Visible ~= true then
                fail("clicking the dropdown header did not open it")
            end
            if list.Size.Y.Offset ~= 138 then
                fail(string.format(
                    "list height not capped to 5 rows: %d",
                    list.Size.Y.Offset
                ))
            end

            -- Choosing an option closes a single-select dropdown.
            local option = list:FindFirstChildOfClass("TextButton")
            if option ~= nil then
                option.MouseButton1Click:Fire()
                if list.Visible ~= false then
                    fail("choosing an option did not close the dropdown")
                end
            end

            -- Reopen, then a tap far outside must close it.
            header.MouseButton1Click:Fire()
            if list.Visible ~= true then
                fail("dropdown did not reopen")
            end
            service("UserInputService").InputBegan:Fire({
                UserInputType = Enum.UserInputType.Touch,
                Position = Vector3.new(5000, 5000, 0),
            })
            if list.Visible ~= false then
                fail("tap outside did not close the dropdown")
            end
        end
    end
end

if #failures > 0 then
    print(string.format("ui_core_smoke: %d failure(s)", #failures))
    error("ui_core_smoke failed")
end

print("ui_core_smoke: all checks passed")
