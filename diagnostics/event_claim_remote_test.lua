-- InfinityGold one-shot Event claim transport test.
-- This script performs no clicks and creates no interface. It submits every
-- currently loaded Event row whose own live state says canClaim=true.

if not game:IsLoaded() then game.Loaded:Wait() end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local lines = {
    "INFINITYGOLD EVENT CLAIM REMOTE TEST",
    "mode=ONE SHOT | no clicks | no UI opening",
}

local function clipboardWriter()
    for _, name in ipairs({ "setclipboard", "toclipboard" }) do
        local writer = nil
        pcall(function()
            local environment = getfenv and getfenv() or _G
            writer = environment and environment[name] or nil
        end)
        if type(writer) == "function" then return writer end
    end
    return nil
end

local function finish(message)
    table.insert(lines, message)
    local report = table.concat(lines, "\n")
    local writer = clipboardWriter()
    local copied = writer ~= nil and pcall(writer, report)
    pcall(function()
        if type(getgenv) == "function" then
            getgenv().__INFINITYGOLD_EVENT_CLAIM_TEST_REPORT = report
        end
    end)
    print(report)
    warn(report)
    return copied
end

local function eventQuestNeed(value)
    local valueType = type(value)
    if valueType == "number" or valueType == "string" then
        return tonumber(value)
    end
    if valueType ~= "table" then return nil end
    for _, item in pairs(value) do
        local itemType = type(item)
        if itemType == "number" or itemType == "string" then
            local number = tonumber(item)
            if number ~= nil then return number end
        end
    end
    return nil
end

local function networkRemote(folderName, remoteName)
    local msg = ReplicatedStorage:FindFirstChild("Msg")
        or ReplicatedStorage:WaitForChild("Msg", 5)
    local folder = msg and (msg:FindFirstChild(folderName)
        or msg:WaitForChild(folderName, 5)) or nil
    return folder and (folder:FindFirstChild(remoteName)
        or folder:WaitForChild(remoteName, 5)) or nil
end

local function run()
    local remoteEvent = networkRemote("RemoteEvent", "NetWorkRemoteEvent")
    if remoteEvent ~= nil and remoteEvent:IsA("RemoteEvent") then
        local refreshed, refreshError = pcall(function()
            remoteEvent:FireServer("活动界面已打开")
        end)
        table.insert(lines, refreshed
            and "remote refresh=sent"
            or ("remote refresh=error " .. tostring(refreshError)))
        task.wait(0.2)
    else
        table.insert(lines, "remote refresh=unavailable; scanning loaded state")
    end

    if type(getgc) ~= "function" then
        finish("ERROR getgc unavailable")
        return
    end

    local okGc, objects = pcall(getgc, true)
    if not okGc or type(objects) ~= "table" then
        finish("ERROR loaded-table scan failed")
        return
    end

    local candidatesByTag = {}
    local requirements = {}
    local stateByTag = {}
    for _, object in ipairs(objects) do
        if type(object) == "table" then
            local onlyTag = rawget(object, "onlyTag")
            local canClaim = rawget(object, "canClaim")
            local claimed = rawget(object, "claimed")
            if type(onlyTag) == "string"
                and onlyTag ~= ""
                and canClaim == true
                and claimed ~= true
            then
                candidatesByTag[onlyTag] = true
            end

            local cfg = rawget(object, "cfg")
            local row = type(cfg) == "table" and cfg or object
            local rowTag = rawget(row, "onlyTag")
            local need = eventQuestNeed(rawget(row, "need"))
            if type(rowTag) == "string"
                and rowTag ~= ""
                and rawget(row, "ResetType") ~= nil
                and need ~= nil
            then
                requirements[rowTag] = need
            end

            local accepted = rawget(object, "Accepted")
            local progress = rawget(object, "Progress")
            local completed = rawget(object, "Completed")
            if type(accepted) == "table"
                and type(progress) == "table"
                and type(completed) == "table"
            then
                for key, value in pairs(accepted) do
                    local tag = type(value) == "string" and value
                        or (type(key) == "string" and value and key or nil)
                    if type(tag) == "string" and tag ~= "" then
                        stateByTag[tag] = object
                    end
                end
            end
        end
    end

    for tag, state in pairs(stateByTag) do
        local completed = rawget(state, "Completed")
        local progress = rawget(state, "Progress")
        local claimed = type(completed) == "table" and rawget(completed, tag) or nil
        local current = type(progress) == "table" and tonumber(rawget(progress, tag)) or nil
        local need = tonumber(requirements[tag])
        if (claimed == nil or claimed == false or claimed == 0)
            and current ~= nil
            and need ~= nil
            and current >= need
        then
            candidatesByTag[tag] = true
        end
    end

    local candidates = {}
    for tag in pairs(candidatesByTag) do table.insert(candidates, tag) end
    table.sort(candidates)

    if #candidates == 0 then
        finish("NO CLAIMABLE EVENT QUEST FOUND")
        return
    end

    local remoteFunction = networkRemote("RemoteFunction", "NetWorkRemoteFunction")
    if remoteFunction == nil or not remoteFunction:IsA("RemoteFunction") then
        finish("ERROR NetWorkRemoteFunction unavailable")
        return
    end

    table.insert(lines, "candidates=" .. tostring(#candidates))
    for _, tag in ipairs(candidates) do
        local invoked, result = pcall(function()
            return remoteFunction:InvokeServer("活动任务提交", tag)
        end)
        if invoked then
            table.insert(lines, "SUBMITTED " .. tag .. " | result=" .. tostring(result))
        else
            table.insert(lines, "ERROR " .. tag .. " | " .. tostring(result))
        end
    end

    finish("DONE")
end

local ran, runError = xpcall(run, function(value)
    local trace = debug and debug.traceback
    return type(trace) == "function" and trace(tostring(value), 2) or tostring(value)
end)
if not ran then finish("UNCAUGHT ERROR " .. tostring(runError)) end
