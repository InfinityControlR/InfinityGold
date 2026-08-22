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
local MAX_TABLE_SNAPSHOTS = 6
local MAX_DIFF_RECORDS = 100
local MAX_STRUCTURE_EVENTS_PER_SECOND = 160
local MAX_VALUE_EVENTS_PER_SECOND = 120
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
local tableSnapshots = {}
local observedValues = setmetatable({}, { __mode = "k" })
local lastRootPosition = nil
local baselineSummary = "pending"
local lastCheckpointStatus = "clipboard ready; file backup pending"
local structureWindowAt = os.clock()
local structureEmitted = 0
local structureOmitted = 0
local valueWindowAt = os.clock()
local valueEmitted = 0
local valueOmitted = 0
local requestTableSnapshot = function(_) end

local strongTokens = {
    "dragon", "event", "countdown", "activity", "boss", "egg", "raid",
    "龙", "巨龙", "龙蛋", "蛋", "首领", "限时", "宠物",
    "活動", "活动", "事件", "倒计时",
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
    local contexts = {}
    local contextSeen = setmetatable({}, { __mode = "k" })
    local count = 0
    for _, descendant in ipairs(gui:GetDescendants()) do
        if descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
            local ok, text = pcall(function() return descendant.Text end)
            if ok and type(text) == "string" and relevantUiText(text) then
                local context = descendant.Parent
                if context ~= nil and context.Parent ~= nil then context = context.Parent end
                if context ~= nil and not contextSeen[context] then
                    contextSeen[context] = true
                    table.insert(contexts, context)
                end
            end
        end
    end
    -- A timer alone is ambiguous. Preserve every neighbouring caption in the
    -- same small panel so the event name/type survives in the report too.
    for _, context in ipairs(contexts) do
        for _, descendant in ipairs(context:GetDescendants()) do
            if descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
                local ok, text = pcall(function() return descendant.Text end)
                if ok and type(text) == "string" and text ~= "" then
                    local key = path(descendant)
                    if result[key] == nil then
                        count += 1
                        if count > MAX_UI_TEXTS then return result end
                        result[key] = clean(text, 240)
                    end
                end
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

local function instanceDescription(instance)
    local rows = {
        "class=" .. instance.ClassName,
        "path=" .. path(instance),
    }
    if instance:IsA("BasePart") then
        table.insert(rows, "pos=" .. positionText(instance.Position))
        table.insert(rows, "size=" .. positionText(instance.Size))
        table.insert(rows, string.format(
            "T=%.2f C=%s Q=%s",
            instance.Transparency,
            tostring(instance.CanCollide),
            tostring(instance.CanTouch)
        ))
    elseif instance:IsA("Model") then
        local anchor = modelAnchor(instance)
        table.insert(rows, "pos=" .. (anchor and positionText(anchor.Position) or "?"))
        local humanoid = instance:FindFirstChildOfClass("Humanoid")
        if humanoid ~= nil then
            table.insert(rows, string.format("hp=%.1f/%.1f", humanoid.Health, humanoid.MaxHealth))
        end
    elseif instance:IsA("ValueBase") then
        local ok, value = pcall(function() return instance.Value end)
        if ok then table.insert(rows, "value=" .. clean(value, 120)) end
    end
    local attributes = attributesText(instance)
    if attributes ~= "" then table.insert(rows, "attrs=" .. attributes) end
    local tags = tagsText(instance)
    if tags ~= "" then table.insert(rows, "tags=" .. tags) end
    return table.concat(rows, " | ")
end

local function flushBurstSummaries(now)
    now = now or os.clock()
    if now - structureWindowAt >= 1 then
        if structureOmitted > 0 then
            add("workspace!", tostring(structureOmitted) .. " additional changes summarized")
        end
        structureWindowAt, structureEmitted, structureOmitted = now, 0, 0
    end
    if now - valueWindowAt >= 1 then
        if valueOmitted > 0 then
            add("value!", tostring(valueOmitted) .. " additional changes summarized")
        end
        valueWindowAt, valueEmitted, valueOmitted = now, 0, 0
    end
end

local function recordStructure(kind, instance)
    flushBurstSummaries()
    if structureEmitted >= MAX_STRUCTURE_EVENTS_PER_SECOND then
        structureOmitted += 1
        return
    end
    structureEmitted += 1
    add(kind, instanceDescription(instance))
end

local function observeValue(instance)
    if not instance:IsA("ValueBase") or observedValues[instance] then return end
    observedValues[instance] = true
    connect(instance.Changed, function(value)
        flushBurstSummaries()
        if valueEmitted >= MAX_VALUE_EVENTS_PER_SECOND then
            valueOmitted += 1
            return
        end
        valueEmitted += 1
        add("value~", path(instance) .. " = " .. clean(value, 160))
    end)
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
            local humanoid = descendant:FindFirstChildOfClass("Humanoid")
            result[path(descendant)] = table.concat({
                "name=" .. clean(descendant.Name, 100),
                "pos=" .. position,
                humanoid and string.format("hp=%.1f/%.1f", humanoid.Health, humanoid.MaxHealth)
                    or "hp=?",
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
    local changed = 0
    local function emit(suffix, detail)
        changed += 1
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
    return changed
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
        if matchesStrong(action) then requestTableSnapshot("event remote") end
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

local lastTableSnapshotAt = -math.huge
local tableSnapshotPending = false
local function captureLoadedTableSnapshot(reason)
    local rows = loadedTableMatches()
    table.insert(tableSnapshots, {
        at = os.clock() - startedAt,
        reason = clean(reason, 80),
        rows = rows,
    })
    while #tableSnapshots > MAX_TABLE_SNAPSHOTS do table.remove(tableSnapshots, 1) end
end

requestTableSnapshot = function(reason)
    local now = os.clock()
    if tableSnapshotPending or now - lastTableSnapshotAt < 8 then return end
    tableSnapshotPending = true
    lastTableSnapshotAt = now
    task.defer(function()
        tableSnapshotPending = false
        if alive then captureLoadedTableSnapshot(reason) end
    end)
end

for _, root in ipairs({ player, ReplicatedStorage, workspace }) do
    for _, descendant in ipairs(root:GetDescendants()) do observeValue(descendant) end
end
connect(player.DescendantAdded, observeValue)
connect(ReplicatedStorage.DescendantAdded, observeValue)
connect(workspace.DescendantAdded, function(instance)
    observeValue(instance)
    local character = player.Character
    if (instance:IsA("Model") or instance:IsA("BasePart"))
        and (character == nil or not instance:IsDescendantOf(character))
    then
        recordStructure("workspace+", instance)
        requestTableSnapshot("workspace addition")
    end
end)
connect(workspace.DescendantRemoving, function(instance)
    local character = player.Character
    if (instance:IsA("Model") or instance:IsA("BasePart"))
        and (character == nil or not instance:IsDescendantOf(character))
    then
        recordStructure("workspace-", instance)
    end
end)
requestTableSnapshot("startup")

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
    table.insert(lines, "")
    table.insert(lines, "Loaded-table snapshots captured during the cycle:")
    for _, snapshot in ipairs(tableSnapshots) do
        table.insert(lines, string.format(
            "+%.2fs reason=%s matches=%d",
            snapshot.at,
            snapshot.reason,
            #snapshot.rows
        ))
        for _, row in ipairs(snapshot.rows) do table.insert(lines, row) end
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
        lastCheckpointStatus = "clipboard ready; optional file backup unavailable"
        return false
    end
    local ok, err = pcall(writefile, CHECKPOINT_FILE, report(includeLoadedTables))
    lastCheckpointStatus = ok
        and ("clipboard ready; backup saved " .. CHECKPOINT_FILE)
        or ("clipboard ready; backup failed: " .. clean(err, 90))
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
        local scalarChanges = diffState("scalar", scalarState, scalars)
        local uiChanges = diffState("ui", uiState, ui)
        local monsterChanges = diffState("monster", monsterState, monsters)
        local partChanges = diffState("part", partState, parts)
        scalarState, uiState, monsterState, partState = scalars, ui, monsters, parts
        if partChanges >= 3
            or (uiChanges > 0 and (monsterChanges > 0 or scalarChanges > 0))
        then
            requestTableSnapshot("replicated event-state change")
        end

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
        flushBurstSummaries()
        status.Text = string.format(
            "World Event Inspector • %.0fs • %d records\n%s",
            os.clock() - startedAt,
            #events,
            lastCheckpointStatus
        )
        task.wait(POLL_SECONDS)
    end
end)
