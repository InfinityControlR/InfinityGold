-- InfinityGold loader.
--
-- Downloads the pinned interface library, shared helpers and locomotion
-- module first, then the core script from main. A failure in any pinned
-- module degrades gracefully: InfinityGold only aborts when the interface
-- library itself cannot be loaded.
--
-- Every failure path raises a visible notification (Roblox toast through
-- StarterGui, plus the dashboard library once available) so a load problem
-- can never look like "nothing happened".

if not game:IsLoaded() then
    game.Loaded:Wait()
end

local function visibleNotify(content)
    pcall(function()
        game:GetService('StarterGui'):SetCore('SendNotification', {
            Title = 'InfinityGold',
            Text = content,
            Duration = 8,
        })
    end)
end

if identifyexecutor then
    local execName = tostring(identifyexecutor()):lower()
    if execName:find('solara') or execName:find('xeno') then
        game:GetService('Players').LocalPlayer:Kick(
            "EXECUTOR NOT SUPPORTED[PLEASE DON'T GET MAD THIS IS SOLARA/XENO'S FAULT]"
        )
        return
    end
end

local BASE = 'https://raw.githubusercontent.com/InfinityControlR/InfinityGold/main/'
local UI = 'https://raw.githubusercontent.com/InfinityControlR/InfinityGold/64873a6115a472936d9000bbf69d33f53f39b762/ui/InfinityUI.lua'
local COMMON = 'https://raw.githubusercontent.com/InfinityControlR/InfinityGold/64873a6115a472936d9000bbf69d33f53f39b762/games/magicloot_common.lua'
local LOCOMOTION = 'https://raw.githubusercontent.com/InfinityControlR/InfinityGold/64873a6115a472936d9000bbf69d33f53f39b762/games/magicloot_locomotion.lua'

local PLACE_IDS = {
    [133188236593503] = true,
}
local CREATOR_IDS = {
    [118455659] = true,
}

if not (PLACE_IDS[game.PlaceId] or CREATOR_IDS[game.CreatorId]) then
    visibleNotify('Unsupported game (PlaceId ' .. tostring(game.PlaceId) .. ') - nothing loaded')
    return
end

task.wait(math.random())

local function fetchModule(name, url)
    local ok, result = pcall(function()
        local source = game:HttpGet(url)
        local chunk, compileError = loadstring(source)
        if type(chunk) ~= 'function' then
            error(tostring(compileError or 'module compile failed'))
        end
        return chunk()
    end)
    if ok then
        return result
    end
    warn('[InfinityGold] ' .. name .. ' failed: ' .. tostring(result) .. ' @ ' .. url)
    visibleNotify(name .. ' failed to load (check console)')
    return nil
end

local Library = fetchModule('Interface library', UI)
if type(Library) ~= 'table' or type(Library.CreateWindow) ~= 'function' then
    visibleNotify('Interface library unavailable - aborting (check console)')
    return
end

local function notifyLoad(content)
    pcall(function()
        Library:Notify({ Title = 'InfinityGold', Content = content, Duration = 6 })
    end)
    visibleNotify(content)
end

local Common = fetchModule('Shared helpers', COMMON)
if type(Common) ~= 'table' then
    Common = nil
end

local factory = fetchModule('Locomotion module', LOCOMOTION)
if type(factory) ~= 'table' or type(factory.create) ~= 'function' then
    factory = nil
end

local coreOk, coreChunk = pcall(function()
    local source = game:HttpGet(BASE .. 'games/magicloot.lua')
    local chunk, compileError = loadstring(source)
    if type(chunk) ~= 'function' then
        error(tostring(compileError or 'core compile failed'))
    end
    return chunk
end)

if not coreOk or type(coreChunk) ~= 'function' then
    notifyLoad('Core script failed to download/compile (check console)')
    warn('[InfinityGold] core script failed: ' .. tostring(coreChunk))
    return
end

local runOk, runError = pcall(coreChunk, factory, Library, Common)
if not runOk then
    notifyLoad('Core error: ' .. tostring(runError))
    warn('[InfinityGold] core runtime error: ' .. tostring(runError))
    return
end
