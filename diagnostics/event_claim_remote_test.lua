-- InfinityGold one-shot Event claim transport test.
-- This script performs no clicks and creates no interface. It submits every
-- currently loaded Event row whose own live state says canClaim=true.

if not game:IsLoaded() then game.Loaded:Wait() end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local lines = {
    "INFINITYGOLD EVENT CLAIM REMOTE TEST",
    "mode=ONE SHOT | no clicks | no UI opening",
}

local function finish(message)
    table.insert(lines, message)
    local report = table.concat(lines, "\n")
    if type(setclipboard) == "function" then
        pcall(setclipboard, report)
    end
    warn(report)
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
for _, object in ipairs(objects) do
    if type(object) == "table"
        and type(object.onlyTag) == "string"
        and object.onlyTag ~= ""
        and object.canClaim == true
        and object.claimed ~= true
    then
        candidatesByTag[object.onlyTag] = true
    end
end

local candidates = {}
for tag in pairs(candidatesByTag) do table.insert(candidates, tag) end
table.sort(candidates)

if #candidates == 0 then
    finish("NO CLAIMABLE EVENT QUEST FOUND")
    return
end

local msg = ReplicatedStorage:WaitForChild("Msg", 5)
local remoteFolder = msg and msg:WaitForChild("RemoteFunction", 5) or nil
local remoteFunction = remoteFolder
    and remoteFolder:WaitForChild("NetWorkRemoteFunction", 5) or nil
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
