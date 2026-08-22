-- InfinityGold passive world-event cycle inspector.
-- Observes one countdown -> event -> forced return cycle. It never sends a
-- remote, invokes a callback, moves the character or synthesizes input.

if not game:IsLoaded() then game.Loaded:Wait() end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local CoreGui = game:GetService("CoreGui")

local player = Players.LocalPlayer
if player == nil then return end

local MAX_EVENTS = 700
local MAX_REPORT_CHARACTERS = 180000
local MAX_SCALARS = 900
local MAX_UI_TEXTS = 700
local MAX_PARTS = 3000
local MAX_TABLE_MATCHES = 60
local MAX_DIFF_RECORDS = 100
local CHECKPOINT_SECONDS = 15
local CHECKPOINT_FILE = "InfinityGold_world_event_capture.txt"
local POLL_SECONDS = 1

local alive = true
local startedAt = os.clock()
local events = {}
local connections = {}
local scalarState = {}
local uiState = {}
local monsterState = {}
local partState = {}
local remoteRate = {}
local lastRootPosition = nil
local baselineSummary = "pending"
local lastCheckpointStatus = "checkpoint pending"

local strongTokens = {
    "dragon", "event", "countdown",
    "龙", "活動", "活动", "事件", "倒计时",
}

local function clean(value, limit)
    local text = tostring(value)
    text = string.gsub(text, "[%c]", " ")
    limit = limit or 180
    return #text > limit and (string.sub(text, 1, limit) .. "...") or text
end

local function path(instance)
    local ok, value = pcall(function() return instance:GetFullName() end)
    return ok and clean(value, 260) or clean(instance, 260)
end

local function positionText(value)
    return string.format("(%.1f, %.1f, %.1f)", value.X, value.Y, value.Z)
end

local function matchesStrong(value)
    if type(value) ~= "string" then return false end
    local lower = string.lower(value)
    for _, token in ipairs(strongTokens) do
        if string.find(lower, string.lower(token), 1, true) then return true end
    end
    return false
end

local function add(kind, detail)
    table.insert(events, {
        at = os.clock() - startedAt,
        kind = clean(kind, 40),
        detail = clean(detail, 360),
    })
    while #events > MAX_EVENTS do table.remove(events, 1) end
end

local function connect(signal, callback)
    local ok, connection = pcall(function() return signal:Connect(callback) end)
    if ok and connection ~= nil then table.insert(connections, connection) end
end

local function attributesText(instance)
    local rows = {}
    local ok, attributes = pcall(function() return instance:GetAttributes() end)
    if ok and type(attributes) == "table" then
        for key, value in pairs(attributes) do
            table.insert(rows, clean(key, 50) .. "=" .. clean(value, 80))
            if #rows >= 14 then break end
        end
    end
    table.sort(rows)
    return table.concat(rows, ",")
end

local function tagsText(instance)
    local ok, tags = pcall(CollectionService.GetTags, CollectionService, instance)
    if not ok or type(tags) ~= "table" then return "" end
    table.sort(tags)
    return table.concat(tags, ",")
end

local function scalarSnapshot()
    local result = {}
    local count = 0
    for _, descendant in ipairs(player:GetDescendants()) do
        if descendant:IsA("ValueBase") then
            count += 1
            if count > MAX_SCALARS then break end
            local ok, value = pcall(function() return descendant.Value end)
            if ok then result[path(descendant)] = clean(value, 160) end
        end
    end
    return result
end

local function relevantUiText(text)
    if matchesStrong(text) then return true end
    return string.match(text, "%d+:%d+") ~= nil
        or string.match(text, "%d+%s*[smh]") ~= nil
end

local function uiSnapshot()
    local result = {}
    local gui = player:FindFirstChildOfClass("PlayerGui")
    if gui == nil then return result end
    local count = 0
    for _, descendant in ipairs(gui:GetDescendants()) do
        if descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
            local ok, text = pcall(function() return descendant.Text end)
            if ok and type(text) == "string" and relevantUiText(text) then
                count += 1
                if count > MAX_UI_TEXTS then break end
                result[path(descendant)] = clean(text, 240)
            end
        end
    end
    return result
end

local function modelAnchor(model)
    return model.PrimaryPart
        or model:FindFirstChild("HumanoidRootPart")
        or model:FindFirstChildWhichIsA("BasePart", true)
end

local function monsterSnapshot()
    local result = {}
    for _, descendant in ipairs(workspace:GetDescendants()) do
        if descendant:IsA("Model")
            and descendant ~= player.Character
            and descendant:FindFirstChildOfClass("Humanoid") ~= nil
        then
            local anchor = modelAnchor(descendant)
            local position = anchor and positionText(anchor.Position) or "?"
            result[path(descendant)] = table.concat({
                "name=" .. clean(descendant.Name, 100),
                "pos=" .. position,
                "attrs=" .. attributesText(descendant),
                "tags=" .. tagsText(descendant),
            }, " | ")
        end
    end
    return result
end

local function partSnapshot()
    local result = {}
    local count = 0
    local character = player.Character
    for _, descendant in ipairs(workspace:GetDescendants()) do
        if descendant:IsA("BasePart")
            and (character == nil or not descendant:IsDescendantOf(character))
        then
            count += 1
            if count > MAX_PARTS then break end
            result[path(descendant)] = string.format(
                "T=%.2f C=%s Q=%s",
                descendant.Transparency,
                tostring(descendant.CanCollide),
                tostring(descendant.CanTouch)
            )
        end
    end
    return result
end

local function diffState(kind, previous, current)
    local emitted = 0
    local omitted = 0
    local function emit(suffix, detail)
        if emitted < MAX_DIFF_RECORDS then
            emitted += 1
            add(kind .. suffix, detail)
        else
            omitted += 1
        end
    end
    for key, value in pairs(current) do
        local old = previous[key]
        if old == nil then
            emit("+", key .. " | " .. value)
        elseif old ~= value then
            emit("~", key .. " | " .. old .. " -> " .. value)
        end
    end
    for key, value in pairs(previous) do
        if current[key] == nil then emit("-", key .. " | " .. value) end
    end
    if omitted > 0 then add(kind .. "!", tostring(omitted) .. " additional changes summarized") end
end

local function remoteValue(value, depth)
    depth = depth or 0
    if depth >= 2 then return "<" .. type(value) .. ">" end
    if typeof(value) == "Instance" then return "<" .. value.ClassName .. "> " .. path(value) end
    if typeof(value) == "Vector3" then return positionText(value) end
    if type(value) ~= "table" then return clean(value, 140) end
    local rows = {}
    for key, item in pairs(value) do
        table.insert(rows, clean(key, 60) .. "=" .. remoteValue(item, depth + 1))
        if #rows >= 12 then break end
    end
    table.sort(rows)
    return "{" .. table.concat(rows, ",") .. "}"
end

local function observeRemote(remote)
    if not remote:IsA("RemoteEvent") then return end
    connect(remote.OnClientEvent, function(...)
        local packed = table.pack(...)
        local action = packed.n > 0 and remoteValue(packed[1]) or "<empty>"
        local key = remote.Name .. "|" .. action
        local now = os.clock()
        if not matchesStrong(action) and now - (remoteRate[key] or 0) < 2 then return end
        remoteRate[key] = now
        local args = {}
        for index = 1, math.min(packed.n, 8) do
            table.insert(args, tostring(index) .. "=" .. remoteValue(packed[index]))
        end
        add("remote<", path(remote) .. " | " .. table.concat(args, " | "))
    end)
end

for _, descendant in ipairs(ReplicatedStorage:GetDescendants()) do observeRemote(descendant) end
connect(ReplicatedStorage.DescendantAdded, observeRemote)

scalarState = scalarSnapshot()
uiState = uiSnapshot()
monsterState = monsterSnapshot()
partState = partSnapshot()
baselineSummary = string.format(
    "scalars=%d ui=%d monsters=%d parts=%d",
    (function() local n=0 for _ in pairs(scalarState) do n+=1 end return n end)(),
    (function() local n=0 for _ in pairs(uiState) do n+=1 end return n end)(),
    (function() local n=0 for _ in pairs(monsterState) do n+=1 end return n end)(),
    (function() local n=0 for _ in pairs(partState) do n+=1 end return n end)()
)
add("baseline", baselineSummary)

local function loadedTableMatches()
    local rows = {}
    if type(getgc) ~= "function" then return rows end
    local ok, objects = pcall(getgc, true)
    if not ok or type(objects) ~= "table" then return rows end
    for index, object in ipairs(objects) do
        if type(object) == "table" then
            local hits = {}
            for key, value in pairs(object) do
                if matchesStrong(tostring(key)) or matchesStrong(tostring(value)) then
                    table.insert(hits, clean(key, 70) .. "=" .. clean(value, 120))
                end
                if #hits >= 10 then break end
            end
            if #hits > 0 then
                table.insert(rows, "gc=" .. tostring(index) .. " {" .. table.concat(hits, ",") .. "}")
                if #rows >= MAX_TABLE_MATCHES then break end
            end
        end
    end
    return rows
end

local function currentStateLines()
    local rows = { "Baseline: " .. baselineSummary, "Current relevant state:" }
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    table.insert(rows, "player=" .. (root and positionText(root.Position) or "?"))
    for key, value in pairs(uiState) do
        table.insert(rows, "ui " .. key .. " | " .. value)
    end
    for key, value in pairs(monsterState) do
        table.insert(rows, "monster " .. key .. " | " .. value)
    end
    for key, value in pairs(scalarState) do
        if matchesStrong(key)
            or string.find(key, "InDungeonChallenge", 1, true)
        then
            table.insert(rows, "scalar " .. key .. " | " .. value)
        end
    end
    return rows
end

local function report(includeLoadedTables)
    local lines = {
        "INFINITYGOLD PASSIVE WORLD EVENT CYCLE INSPECTOR",
        "mode=READ ONLY | no remotes sent | no movement | no synthetic input",
        string.format("elapsed=%.1fs events=%d", os.clock() - startedAt, #events),
        "",
    }
    for _, row in ipairs(currentStateLines()) do table.insert(lines, row) end
    table.insert(lines, "")
    table.insert(lines, "Timeline:")
    for _, event in ipairs(events) do
        table.insert(lines, string.format("+%.2fs [%s] %s", event.at, event.kind, event.detail))
    end
    if includeLoadedTables ~= false then
        table.insert(lines, "")
        table.insert(lines, "Matching loaded tables at copy time:")
        for _, row in ipairs(loadedTableMatches()) do table.insert(lines, row) end
    end
    local text = table.concat(lines, "\n")
    if #text > MAX_REPORT_CHARACTERS then
        local preserved = { lines[1], lines[2], lines[3], "" }
        for _, row in ipairs(currentStateLines()) do table.insert(preserved, row) end
        table.insert(preserved, "")
        table.insert(preserved, "<earlier timeline truncated; newest data preserved>")
        local header = table.concat(preserved, "\n") .. "\n"
        text = header .. string.sub(
            text,
            math.max(1, #text - (MAX_REPORT_CHARACTERS - #header - 1))
        )
    end
    return text
end

local function checkpoint(includeLoadedTables)
    if type(writefile) ~= "function" then
        lastCheckpointStatus = "writefile unavailable; clipboard still active"
        return false
    end
    local ok, err = pcall(writefile, CHECKPOINT_FILE, report(includeLoadedTables))
    lastCheckpointStatus = ok
        and ("saved " .. CHECKPOINT_FILE)
        or ("checkpoint failed: " .. clean(err, 120))
    return ok
end

local old = CoreGui:FindFirstChild("InfinityGoldWorldEventInspector")
if old ~= nil then old:Destroy() end
local gui = Instance.new("ScreenGui")
gui.Name = "InfinityGoldWorldEventInspector"
gui.ResetOnSpawn = false
gui.DisplayOrder = 1000001
gui.Parent = CoreGui

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(390, 92)
frame.Position = UDim2.new(0.5, -195, 0, 70)
frame.BackgroundColor3 = Color3.fromRGB(14, 16, 20)
frame.Parent = gui
local frameCorner = Instance.new("UICorner")
frameCorner.CornerRadius = UDim.new(0, 9)
frameCorner.Parent = frame

local status = Instance.new("TextLabel")
status.BackgroundTransparency = 1
status.Position = UDim2.fromOffset(12, 8)
status.Size = UDim2.new(1, -24, 0, 42)
status.Font = Enum.Font.Gotham
status.TextColor3 = Color3.fromRGB(235, 198, 82)
status.TextSize = 12
status.TextWrapped = true
status.Text = "World Event Inspector running..."
status.Parent = frame

local copy = Instance.new("TextButton")
copy.Position = UDim2.fromOffset(12, 56)
copy.Size = UDim2.fromOffset(174, 26)
copy.Text = "Copy report"
copy.Font = Enum.Font.GothamSemibold
copy.TextSize = 12
copy.Parent = frame

local close = Instance.new("TextButton")
close.Position = UDim2.fromOffset(204, 56)
close.Size = UDim2.fromOffset(174, 26)
close.Text = "Close"
close.Font = Enum.Font.GothamSemibold
close.TextSize = 12
close.Parent = frame

connect(copy.Activated, function()
    local text = report(true)
    local copied = false
    for _, name in ipairs({ "setclipboard", "toclipboard" }) do
        local writer = nil
        pcall(function() writer = getfenv and getfenv()[name] or _G[name] end)
        if type(writer) == "function" then copied = pcall(writer, text) end
        if copied then break end
    end
    checkpoint(true)
    print(text)
    copy.Text = copied and "Copied" or "Printed to console"
end)

local function shutdown()
    if not alive then return end
    checkpoint(false)
    alive = false
    for _, connection in ipairs(connections) do pcall(function() connection:Disconnect() end) end
    table.clear(connections)
    if gui.Parent ~= nil then gui:Destroy() end
end
connect(close.Activated, shutdown)

task.spawn(function()
    local nextCheckpointAt = os.clock() + CHECKPOINT_SECONDS
    while alive do
        local scalars = scalarSnapshot()
        local ui = uiSnapshot()
        local monsters = monsterSnapshot()
        local parts = partSnapshot()
        diffState("scalar", scalarState, scalars)
        diffState("ui", uiState, ui)
        diffState("monster", monsterState, monsters)
        diffState("part", partState, parts)
        scalarState, uiState, monsterState, partState = scalars, ui, monsters, parts

        local character = player.Character
        local root = character and character:FindFirstChild("HumanoidRootPart")
        if root ~= nil then
            if lastRootPosition == nil or (root.Position - lastRootPosition).Magnitude >= 25 then
                add("player-pos", positionText(root.Position))
                lastRootPosition = root.Position
            end
        end
        if os.clock() >= nextCheckpointAt then
            checkpoint(false)
            nextCheckpointAt = os.clock() + CHECKPOINT_SECONDS
        end
        status.Text = string.format(
            "World Event Inspector • %.0fs • %d records\n%s",
            os.clock() - startedAt,
            #events,
            lastCheckpointStatus
        )
        task.wait(POLL_SECONDS)
    end
end)
