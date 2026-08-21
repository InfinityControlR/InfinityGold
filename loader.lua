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

-- Always-visible status banner (PlayerGui): toasts can be blocked by the
-- game or the executor, the console is easy to miss on mobile. This label
-- shows every load step directly on screen.
local bannerGui

local function screenBanner(text)
    pcall(function()
        local localPlayer = game:GetService('Players').LocalPlayer
        if localPlayer == nil then return end
        local playerGui = localPlayer:FindFirstChildOfClass('PlayerGui')
        if playerGui == nil then return end
        if bannerGui == nil or bannerGui.Parent == nil then
            bannerGui = Instance.new('ScreenGui')
            bannerGui.Name = 'InfinityGoldStatus'
            bannerGui.ResetOnSpawn = false
            bannerGui.DisplayOrder = 1000000
            bannerGui.IgnoreGuiInset = true
            bannerGui.Parent = playerGui

            local label = Instance.new('TextLabel')
            label.Name = 'Status'
            label.AnchorPoint = Vector2.new(0.5, 1)
            label.Position = UDim2.new(0.5, 0, 1, -24)
            label.Size = UDim2.new(0.92, 0, 0, 30)
            label.BackgroundColor3 = Color3.fromRGB(13, 13, 18)
            label.BackgroundTransparency = 0.15
            label.TextColor3 = Color3.fromRGB(245, 197, 66)
            label.Font = Enum.Font.GothamBold
            label.TextSize = 13
            label.TextScaled = false
            label.TextWrapped = true
            label.Parent = bannerGui

            local rounding = Instance.new('UICorner')
            rounding.CornerRadius = UDim.new(0, 8)
            rounding.Parent = label
        end
        bannerGui.Status.Text = '[InfinityGold] ' .. tostring(text)
    end)
end

local function visibleNotify(content)
    screenBanner(content)
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

-- Every module (including the core) is pinned to an immutable commit SHA:
-- SHA URLs can never be served stale by the raw CDN, which caches /main/
-- URLs for minutes and sometimes ignores cache-busting query strings.
-- Only this loader itself is served from main.
local UI = 'https://raw.githubusercontent.com/InfinityControlR/InfinityGold/0c1f5c7af5a43e06b1772d23edfe605360eef833/ui/InfinityUI.lua'
local COMMON = 'https://raw.githubusercontent.com/InfinityControlR/InfinityGold/0c1f5c7af5a43e06b1772d23edfe605360eef833/games/magicloot_common.lua'
local LOCOMOTION = 'https://raw.githubusercontent.com/InfinityControlR/InfinityGold/0c1f5c7af5a43e06b1772d23edfe605360eef833/games/magicloot_locomotion.lua'
local CORE = 'https://raw.githubusercontent.com/InfinityControlR/InfinityGold/0c1f5c7af5a43e06b1772d23edfe605360eef833/games/magicloot.lua'

-- Belt and braces: a fresh cache key per run for the pinned URLs too.
local CACHE_BUST = '?t=' .. tostring(os.time())

local function busted(url)
    return url .. CACHE_BUST
end

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
screenBanner('downloading modules...')

local function fetchModule(name, url)
    screenBanner('downloading ' .. string.lower(name) .. '...')
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
    visibleNotify(name .. ' failed: ' .. tostring(result))
    return nil
end

local function fetchChunk(name, url)
    local ok, result = pcall(function()
        local source = game:HttpGet(busted(url))
        local chunk, compileError = loadstring(source)
        if type(chunk) ~= 'function' then
            error(tostring(compileError or 'chunk compile failed'))
        end
        local exported = chunk()
        if type(exported) ~= 'function' then
            error(name .. ' did not return an entry function')
        end
        return exported
    end)
    if ok then
        return result
    end
    warn('[InfinityGold] ' .. name .. ' failed: ' .. tostring(result) .. ' @ ' .. url)
    visibleNotify(name .. ' failed: ' .. tostring(result))
    return nil
end

local Library = fetchModule('Interface library', busted(UI))
if type(Library) ~= 'table' or type(Library.CreateWindow) ~= 'function' then
    visibleNotify('Interface library unavailable - aborting (check console)')
    return
end

screenBanner('interface library ok')

local function notifyLoad(content)
    pcall(function()
        Library:Notify({ Title = 'InfinityGold', Content = content, Duration = 6 })
    end)
    visibleNotify(content)
end

local Common = fetchModule('Shared helpers', busted(COMMON))
if type(Common) ~= 'table' then
    Common = nil
end

local factory = fetchModule('Locomotion module', busted(LOCOMOTION))
if type(factory) ~= 'table' or type(factory.create) ~= 'function' then
    factory = nil
end

local coreChunk = fetchChunk('Core script', CORE)
if type(coreChunk) ~= 'function' then
    notifyLoad('Core script unavailable - aborting (check console)')
    return
end

screenBanner('starting core...')

local runOk, result = pcall(coreChunk, factory, Library, Common)
if not runOk then
    notifyLoad('Core error: ' .. tostring(result))
    warn('[InfinityGold] core runtime error: ' .. tostring(result))
    return
end

-- Final report and floating toggle built in the LOADER context: this is the
-- channel proven to render on every executor tested, so the diagnosis and
-- the open/close button do not depend on the core's own gui health.
local windowFrame = type(result) == 'table' and result.windowFrame or nil
local windowGui = type(result) == 'table' and result.windowGui or nil

do
    local summary = { 'loaded' }
    if windowGui ~= nil then
        if windowGui.Parent == nil then
            pcall(function()
                local localPlayer = game:GetService('Players').LocalPlayer
                local target = localPlayer and localPlayer:FindFirstChildOfClass('PlayerGui')
                if target ~= nil then windowGui.Parent = target end
            end)
        end
        pcall(function()
            local parent = windowGui.Parent
            table.insert(summary, 'gui: ' .. tostring(parent and parent.ClassName or 'unparented'))
            table.insert(summary, string.format(
                '%dx%d',
                math.floor(windowGui.AbsoluteSize.X),
                math.floor(windowGui.AbsoluteSize.Y)
            ))
            table.insert(summary, #windowGui:GetChildren() .. ' children')
        end)
    else
        table.insert(summary, 'no window reference from core')
    end
    screenBanner(table.concat(summary, ' | ') .. ' | tap the gold IG button')
end

-- The core owns the single floating toggle and its unload lifecycle. Older
-- loader builds created a second button; remove that exact legacy GUI once.
pcall(function()
    local localPlayer = game:GetService('Players').LocalPlayer
    local playerGui = localPlayer and localPlayer:FindFirstChildOfClass('PlayerGui')
    local legacy = playerGui and playerGui:FindFirstChild('InfinityGoldLoaderToggle')
    if legacy ~= nil then legacy:Destroy() end
end)

task.delay(15, function()
    if bannerGui ~= nil then
        pcall(function() bannerGui:Destroy() end)
        bannerGui = nil
    end
end)
