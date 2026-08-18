-- InfinityGold loader.
--
-- Downloads the pinned interface library, shared helpers and locomotion
-- module first, then the core script from main. A failure in any pinned
-- module degrades gracefully: InfinityGold only aborts when the interface
-- library itself cannot be loaded.

if not game:IsLoaded() then
    game.Loaded:Wait()
end

if identifyexecutor then
    local execName = tostring(identifyexecutor()):lower()
    if execName:find("solara") or execName:find("xeno") then
        game:GetService("Players").LocalPlayer:Kick(
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
    return
end

task.wait(math.random())

local function fetchModule(url)
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
    warn('[InfinityGold] module failed to load: ' .. tostring(url) .. ' -> ' .. tostring(result))
    return nil
end

local Library = fetchModule(UI)
if type(Library) ~= 'table' or type(Library.CreateWindow) ~= 'function' then
    warn('[InfinityGold] interface library unavailable; aborting')
    return
end

local Common = fetchModule(COMMON)
if type(Common) ~= 'table' then
    Common = nil
end

local factory = fetchModule(LOCOMOTION)
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
    pcall(function()
        Library:Notify({
            Title = 'InfinityGold',
            Content = 'core script failed to load',
            Duration = 6,
        })
    end)
    warn('[InfinityGold] core script failed: ' .. tostring(coreChunk))
    return
end

coreChunk(factory, Library, Common)
