-- InfinityGold - passive Event Claim state inspector.
--
-- Run after opening the game's Event panel manually once. This script never
-- opens UI, executes callbacks, calls exported functions, or sends remotes. It
-- only inspects already-loaded Lua tables for event/quest configuration and
-- copies a bounded report.

local ReplicatedFirst = game:GetService("ReplicatedFirst")

local MAX_GC_OBJECTS = 50000
local MAX_MATCHES = 100
local MAX_TABLE_ITEMS = 48
local MAX_DEPTH = 4
local MAX_REPORT_CHARACTERS = 60000

local tokens = {
    "活动",
    "任务",
    "限时",
    "每日",
    "限时击杀任意怪",
    "活动在线3分钟",
    "每日击杀指定怪物",
}

local function clean(value, limit)
    local text = tostring(value)
    text = string.gsub(text, "[%c]", " ")
    limit = limit or 240
    if #text > limit then return string.sub(text, 1, limit) .. "..." end
    return text
end

local function matches(value)
    if type(value) ~= "string" then return false end
    local lower = string.lower(value)
    for _, token in ipairs(tokens) do
        if string.find(lower, string.lower(token), 1, true) then return true end
    end
    return false
end

local function shallowMatch(value)
    if type(value) ~= "table" then return false end
    local checked = 0
    for key, item in pairs(value) do
        checked += 1
        if matches(key) or matches(item) then return true end
        if type(item) == "table" then
            local nested = 0
            for nestedKey, nestedValue in pairs(item) do
                nested += 1
                if matches(nestedKey) or matches(nestedValue) then return true end
                if nested >= 32 then break end
            end
        end
        if checked >= 96 then break end
    end
    return false
end

local function describe(value, depth, seen)
    local valueType = type(value)
    if valueType == "string" then return string.format("%q", clean(value)) end
    if valueType == "number" or valueType == "boolean" or valueType == "nil" then
        return tostring(value)
    end
    if valueType == "function" then
        local name = ""
        pcall(function()
            if type(debug) == "table" and type(debug.info) == "function" then
                name = clean(debug.info(value, "n") or "", 120)
            end
        end)
        return name ~= "" and ("<function " .. name .. ">") or "<function>"
    end
    if valueType ~= "table" then return "<" .. clean(typeof(value), 80) .. ">" end
    if depth <= 0 then return "{...}" end
    if seen[value] then return "<cycle>" end
    seen[value] = true
    local keys = {}
    for key in pairs(value) do table.insert(keys, key) end
    table.sort(keys, function(left, right) return tostring(left) < tostring(right) end)
    local parts = {}
    for index, key in ipairs(keys) do
        if index > MAX_TABLE_ITEMS then
            table.insert(parts, "...=" .. tostring(#keys - MAX_TABLE_ITEMS) .. " more")
            break
        end
        table.insert(parts, "[" .. describe(key, 1, seen) .. "]="
            .. describe(value[key], depth - 1, seen))
    end
    seen[value] = nil
    return "{" .. table.concat(parts, ",") .. "}"
end

local lines = {
    "INFINITYGOLD PASSIVE EVENT CLAIM STATE INSPECTOR",
    "mode=READ ONLY | loaded tables only | no callbacks | no remotes | no UI opening",
    "",
}

local loadedModules = {}
local loadedReader = nil
pcall(function()
    if type(getloadedmodules) == "function" then loadedReader = getloadedmodules end
end)
if loadedReader ~= nil then
    local ok, modules = pcall(loadedReader)
    if ok and type(modules) == "table" then
        for _, moduleScript in ipairs(modules) do loadedModules[moduleScript] = true end
    end
end

local utilsScript = ReplicatedFirst:FindFirstChild("AllSideCode")
utilsScript = utilsScript and utilsScript:FindFirstChild("UtilsSystem") or nil
if utilsScript ~= nil and loadedModules[utilsScript] then
    local ok, registry = pcall(require, utilsScript)
    if ok and type(registry) == "table" then
        table.insert(lines, "UtilsSystem direct exports:")
        local keys = {}
        for key in pairs(registry) do table.insert(keys, key) end
        table.sort(keys, function(left, right) return tostring(left) < tostring(right) end)
        for index, key in ipairs(keys) do
            if index > 300 then
                table.insert(lines, "  <export limit reached>")
                break
            end
            table.insert(lines, "  " .. clean(key, 160) .. " -> " .. type(registry[key]))
        end
        table.insert(lines, "")
    else
        table.insert(lines, "UtilsSystem loaded read failed: " .. clean(registry))
    end
else
    table.insert(lines, "UtilsSystem is not already loaded; skipped")
end

local gcReader = nil
pcall(function()
    if type(getgc) == "function" then gcReader = getgc end
end)
if gcReader == nil then
    table.insert(lines, "getgc unavailable; no event tables inspected")
else
    local ok, objects = pcall(gcReader, true)
    if not ok or type(objects) ~= "table" then
        table.insert(lines, "getgc failed: " .. clean(objects))
    else
        local scanned = 0
        local matched = 0
        table.insert(lines, "Matching loaded Lua tables:")
        for index, object in ipairs(objects) do
            if index > MAX_GC_OBJECTS or matched >= MAX_MATCHES then break end
            scanned += 1
            if type(object) == "table" and shallowMatch(object) then
                matched += 1
                table.insert(lines, string.format(
                    "TABLE #%d gc=%d %s",
                    matched,
                    index,
                    describe(object, MAX_DEPTH, {})
                ))
            end
        end
        table.insert(lines, string.format(
            "scanned=%d matches=%d%s",
            scanned,
            matched,
            matched >= MAX_MATCHES and " (match limit reached)" or ""
        ))
    end
end

local report = table.concat(lines, "\n")
if #report > MAX_REPORT_CHARACTERS then
    report = string.sub(report, 1, MAX_REPORT_CHARACTERS)
        .. "\n<report truncated at " .. tostring(MAX_REPORT_CHARACTERS) .. " characters>"
end
print(report)
local copied = false
for _, name in ipairs({ "setclipboard", "toclipboard" }) do
    local writer = nil
    pcall(function() writer = getfenv and getfenv()[name] or _G[name] end)
    if type(writer) == "function" then
        copied = pcall(writer, report)
        if copied then break end
    end
end
warn("InfinityGold Event inspector complete; copied=" .. tostring(copied))
