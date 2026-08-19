-- InfinityGold - passive click/action inspector
--
-- This standalone diagnostic observes real left-button UserInputService
-- InputBegan/InputEnded events, nearby outgoing remotes, and replicated numeric
-- changes. It never synthesizes input, invokes exported/UIS callbacks, loads an
-- uninitialized module, or sends a remote. The only callable registry probes
-- are read-only lookups for NetMsg/NetWork. Close the popup to disconnect every
-- signal and put its hook to sleep.

local Players = game:GetService("Players")
local CoreGui = game:GetService("CoreGui")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
if LocalPlayer == nil then
    warn("InfinityGold Click Inspector: LocalPlayer is unavailable")
    return
end

local PlayerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    or LocalPlayer:WaitForChild("PlayerGui", 10)
if PlayerGui == nil then
    warn("InfinityGold Click Inspector: PlayerGui is unavailable")
    return
end

local CONFIG = {
    MaxClicks = 18,
    MaxPendingClicks = 6,
    MaxPendingRemotes = 96,
    MaxRemoteHistory = 96,
    MaxRemotesPerHeartbeat = 32,
    MaxRemotesPerClick = 12,
    MaxArguments = 12,
    MaxArgumentDepth = 2,
    MaxArgumentNodes = 80,
    MaxTableItems = 12,
    MaxStringLength = 240,
    MaxArgumentCharacters = 1800,
    MaxReportCharacters = 50000,
    MaxScanInstances = 1600,
    MaxNumericSignals = 320,
    MaxDeltasPerClick = 40,
    MaxExports = 64,
    MaxLoadedModulesScan = 4000,
    MaxConnectionsPerSignal = 32,
    MaxConnectionsTotal = 80,
    CorrelationBeforeSeconds = 0.15,
    CorrelationAfterSeconds = 0.85,
    NumericSettleSeconds = 0.75,
    RenderIntervalSeconds = 0.12,
}

local GLOBAL_KEY = "__INFINITYGOLD_CLICK_ACTION_INSPECTOR_CLEANUP"
local globalEnvironment = nil
pcall(function()
    if type(getgenv) == "function" then
        globalEnvironment = getgenv()
    end
end)
if type(globalEnvironment) ~= "table" then
    globalEnvironment = _G
end
local previousCleanup = globalEnvironment[GLOBAL_KEY]
if type(previousCleanup) == "function" then
    pcall(previousCleanup)
end

-- Popup ---------------------------------------------------------------------

local rootGui = Instance.new("ScreenGui")
rootGui.Name = "InfinityGoldClickActionInspector_" .. tostring(math.random(100000, 999999))
rootGui.ResetOnSpawn = false
rootGui.IgnoreGuiInset = false
rootGui.DisplayOrder = 2147483000
rootGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local function parentPopup()
    local hui = nil
    pcall(function()
        if type(gethui) == "function" then
            hui = gethui()
        end
    end)
    if typeof(hui) == "Instance" then
        local ok = pcall(function()
            rootGui.Parent = hui
        end)
        if ok then return end
    end
    local coreOk = pcall(function()
        rootGui.Parent = CoreGui
    end)
    if not coreOk then
        rootGui.Parent = PlayerGui
    end
end
parentPopup()

local expandedSize = UDim2.fromOffset(590, 430)
local minimizedSize = UDim2.fromOffset(330, 50)

local window = Instance.new("Frame")
window.Name = "Window"
window.AnchorPoint = Vector2.new(1, 0)
window.Position = UDim2.new(1, -14, 0, 72)
window.Size = expandedSize
window.BackgroundColor3 = Color3.fromRGB(17, 20, 28)
window.BorderSizePixel = 0
window.ClipsDescendants = true
window.Parent = rootGui

local windowCorner = Instance.new("UICorner")
windowCorner.CornerRadius = UDim.new(0, 9)
windowCorner.Parent = window

local windowStroke = Instance.new("UIStroke")
windowStroke.Color = Color3.fromRGB(69, 82, 112)
windowStroke.Thickness = 1
windowStroke.Transparency = 0.1
windowStroke.Parent = window

local header = Instance.new("Frame")
header.Name = "Header"
header.Size = UDim2.new(1, 0, 0, 50)
header.BackgroundColor3 = Color3.fromRGB(25, 30, 42)
header.BorderSizePixel = 0
header.Active = true
header.Parent = window

local title = Instance.new("TextLabel")
title.Name = "Title"
title.Position = UDim2.fromOffset(12, 5)
title.Size = UDim2.new(1, -240, 0, 20)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.Text = "InfinityGold - Click Inspector"
title.TextColor3 = Color3.fromRGB(235, 240, 250)
title.TextSize = 14
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = header

local subtitle = Instance.new("TextLabel")
subtitle.Name = "Subtitle"
subtitle.Position = UDim2.fromOffset(12, 26)
subtitle.Size = UDim2.new(1, -240, 0, 16)
subtitle.BackgroundTransparency = 1
subtitle.Font = Enum.Font.Gotham
subtitle.Text = "Pasivo: clic real, remotos cercanos y deltas numericos"
subtitle.TextColor3 = Color3.fromRGB(150, 160, 181)
subtitle.TextSize = 10
subtitle.TextXAlignment = Enum.TextXAlignment.Left
subtitle.Parent = header

local copyButton = Instance.new("TextButton")
copyButton.Name = "Copy"
copyButton.AnchorPoint = Vector2.new(1, 0.5)
copyButton.Position = UDim2.new(1, -88, 0.5, 0)
copyButton.Size = UDim2.fromOffset(78, 30)
copyButton.BackgroundColor3 = Color3.fromRGB(37, 83, 112)
copyButton.BorderSizePixel = 0
copyButton.Font = Enum.Font.GothamSemibold
copyButton.Text = "Copiar"
copyButton.TextColor3 = Color3.fromRGB(213, 239, 255)
copyButton.TextSize = 11
copyButton.Parent = header

local copyCorner = Instance.new("UICorner")
copyCorner.CornerRadius = UDim.new(0, 7)
copyCorner.Parent = copyButton

local minimizeButton = Instance.new("TextButton")
minimizeButton.Name = "Minimize"
minimizeButton.AnchorPoint = Vector2.new(1, 0.5)
minimizeButton.Position = UDim2.new(1, -48, 0.5, 0)
minimizeButton.Size = UDim2.fromOffset(30, 30)
minimizeButton.BackgroundColor3 = Color3.fromRGB(47, 56, 76)
minimizeButton.BorderSizePixel = 0
minimizeButton.Font = Enum.Font.GothamBold
minimizeButton.Text = "-"
minimizeButton.TextColor3 = Color3.fromRGB(215, 223, 242)
minimizeButton.TextSize = 15
minimizeButton.Parent = header

local minimizeCorner = Instance.new("UICorner")
minimizeCorner.CornerRadius = UDim.new(0, 7)
minimizeCorner.Parent = minimizeButton

local closeButton = Instance.new("TextButton")
closeButton.Name = "Close"
closeButton.AnchorPoint = Vector2.new(1, 0.5)
closeButton.Position = UDim2.new(1, -10, 0.5, 0)
closeButton.Size = UDim2.fromOffset(30, 30)
closeButton.BackgroundColor3 = Color3.fromRGB(83, 39, 48)
closeButton.BorderSizePixel = 0
closeButton.Font = Enum.Font.GothamBold
closeButton.Text = "X"
closeButton.TextColor3 = Color3.fromRGB(255, 198, 205)
closeButton.TextSize = 13
closeButton.Parent = header

local closeCorner = Instance.new("UICorner")
closeCorner.CornerRadius = UDim.new(0, 7)
closeCorner.Parent = closeButton

local statusLabel = Instance.new("TextLabel")
statusLabel.Name = "Status"
statusLabel.Position = UDim2.fromOffset(10, 55)
statusLabel.Size = UDim2.new(1, -20, 0, 20)
statusLabel.BackgroundTransparency = 1
statusLabel.Font = Enum.Font.GothamSemibold
statusLabel.Text = "Preparando diagnostico..."
statusLabel.TextColor3 = Color3.fromRGB(181, 202, 227)
statusLabel.TextSize = 10
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.TextTruncate = Enum.TextTruncate.AtEnd
statusLabel.Parent = window

local reportScroll = Instance.new("ScrollingFrame")
reportScroll.Name = "Report"
reportScroll.Position = UDim2.fromOffset(8, 78)
reportScroll.Size = UDim2.new(1, -16, 1, -86)
reportScroll.BackgroundColor3 = Color3.fromRGB(10, 12, 18)
reportScroll.BorderSizePixel = 0
reportScroll.ScrollBarThickness = 6
reportScroll.ScrollingDirection = Enum.ScrollingDirection.XY
reportScroll.CanvasSize = UDim2.fromOffset(0, 0)
reportScroll.Parent = window

local reportCorner = Instance.new("UICorner")
reportCorner.CornerRadius = UDim.new(0, 7)
reportCorner.Parent = reportScroll

local reportText = Instance.new("TextLabel")
reportText.Name = "Text"
reportText.Position = UDim2.fromOffset(8, 7)
reportText.Size = UDim2.fromOffset(540, 100)
reportText.BackgroundTransparency = 1
reportText.Font = Enum.Font.Code
reportText.Text = ""
reportText.TextColor3 = Color3.fromRGB(211, 217, 230)
reportText.TextSize = 12
reportText.TextXAlignment = Enum.TextXAlignment.Left
reportText.TextYAlignment = Enum.TextYAlignment.Top
reportText.TextWrapped = false
reportText.RichText = false
reportText.Parent = reportScroll

-- State and safe readers -----------------------------------------------------

local alive = true
local closed = false
local minimized = false
local startedAt = os.clock()
local readErrors = 0
local droppedRemoteCaptures = 0
local droppedClicks = 0
local clickSequence = 0
local clicks = {}
local pendingClicks = {}
local activeClick = nil
local remoteHistory = {}
local latestReport = ""
local renderScheduled = true
local lastRenderAt = 0
local globalConnections = {}

local pendingRemoteQueue = {}
local pendingRemoteHead = 1
local pendingRemoteTail = 0
local pendingRemoteCount = 0

local hookInstalled = false
local hookActive = false
local hookFunction = nil
local originalNamecall = nil
local hookInstaller = nil
local hookRestoreStatus = "not installed"

local function cleanText(value, limit)
    local text = value == nil and "" or tostring(value)
    text = text:gsub("[%c]", " ")
    local maximum = limit or CONFIG.MaxStringLength
    if #text > maximum then
        return text:sub(1, maximum) .. "..."
    end
    return text
end

local function safeFullName(instance)
    local ok, value = pcall(function()
        return instance:GetFullName()
    end)
    if ok then return cleanText(value, 600) end
    readErrors = readErrors + 1
    return "<path unavailable>"
end

local function safeClassName(instance)
    local ok, value = pcall(function()
        return instance.ClassName
    end)
    if ok then return cleanText(value, 80) end
    readErrors = readErrors + 1
    return "<class unavailable>"
end

local function safeIsA(instance, className)
    local ok, value = pcall(function()
        return instance:IsA(className)
    end)
    return ok and value == true
end

local function isOwnInstance(instance)
    if instance == rootGui then return true end
    local ok, value = pcall(function()
        return instance:IsDescendantOf(rootGui)
    end)
    return ok and value == true
end

local function pointInside(guiObject, position)
    if guiObject == nil or not guiObject.Visible then return false end
    local topLeft = guiObject.AbsolutePosition
    local size = guiObject.AbsoluteSize
    return position.X >= topLeft.X and position.X <= topLeft.X + size.X
        and position.Y >= topLeft.Y and position.Y <= topLeft.Y + size.Y
end

local function inputPosition(input)
    local ok, position = pcall(function()
        return input.Position
    end)
    if ok and position ~= nil then
        return Vector2.new(position.X, position.Y)
    end
    readErrors = readErrors + 1
    return Vector2.zero
end

local function formatPosition(position)
    return string.format("(%d,%d)", math.floor(position.X + 0.5), math.floor(position.Y + 0.5))
end

local function setWindowTopLeft(topLeft)
    local camera = workspace.CurrentCamera
    if camera == nil then return end
    local viewport = camera.ViewportSize
    local size = window.AbsoluteSize
    local x = math.clamp(topLeft.X, 0, math.max(0, viewport.X - size.X))
    local y = math.clamp(topLeft.Y, 0, math.max(0, viewport.Y - size.Y))
    window.AnchorPoint = Vector2.zero
    window.Position = UDim2.fromOffset(x, y)
end

local function connect(signal, callback)
    local ok, connection = pcall(function()
        return signal:Connect(callback)
    end)
    if ok and connection ~= nil then
        table.insert(globalConnections, connection)
        return connection
    end
    readErrors = readErrors + 1
    return nil
end

local function scheduleRender()
    if alive and not closed and not minimized then
        renderScheduled = true
    end
end

-- Read-only function/module inspection --------------------------------------

local debugInfo = nil
pcall(function()
    if type(debug) == "table" and type(debug.info) == "function" then
        debugInfo = debug.info
    end
end)

local function functionMetadata(callback)
    if type(callback) ~= "function" then
        return "type=" .. cleanText(typeof(callback), 40)
    end
    if debugInfo == nil then
        return "function | arity=? | source=? (debug.info unavailable)"
    end

    local arity = "?"
    local vararg = "?"
    local arityOk, parameterCount, isVararg = pcall(debugInfo, callback, "a")
    if arityOk then
        arity = tostring(parameterCount)
        vararg = tostring(isVararg == true)
    end

    local source = "?"
    local sourceOk, sourceValue = pcall(debugInfo, callback, "s")
    if sourceOk then source = cleanText(sourceValue, 260) end

    local name = ""
    local nameOk, nameValue = pcall(debugInfo, callback, "n")
    if nameOk and nameValue ~= nil and tostring(nameValue) ~= "" then
        name = " | name=" .. cleanText(nameValue, 100)
    end
    return string.format(
        "function | arity=%s | vararg=%s | source=%s%s",
        arity,
        vararg,
        source,
        name
    )
end

local loadedModuleSet = nil
local loadedModulesStatus = "not inspected"
local loadedModulesResolved = false

local function resolveLoadedModuleSet()
    if loadedModulesResolved then return loadedModuleSet end
    loadedModulesResolved = true
    local reader = nil
    pcall(function()
        if type(getloadedmodules) == "function" then reader = getloadedmodules end
    end)
    if reader == nil then
        loadedModulesStatus = "getloadedmodules unavailable"
        return nil
    end
    local ok, modules = pcall(reader)
    if not ok or type(modules) ~= "table" then
        loadedModulesStatus = "getloadedmodules failed"
        return nil
    end
    local found = {}
    local scanned = 0
    for _, moduleScript in ipairs(modules) do
        if scanned >= CONFIG.MaxLoadedModulesScan then
            loadedModulesStatus = "loaded-module scan truncated"
            break
        end
        scanned = scanned + 1
        if typeof(moduleScript) == "Instance" then found[moduleScript] = true end
    end
    if loadedModulesStatus == "not inspected" then
        loadedModulesStatus = string.format("ok (%d scanned)", scanned)
    end
    loadedModuleSet = found
    return loadedModuleSet
end

local function moduleWasAlreadyLoaded(moduleScript)
    local loaded = resolveLoadedModuleSet()
    if loaded == nil then return false, loadedModulesStatus end
    if loaded[moduleScript] == true then return true, loadedModulesStatus end
    if loadedModulesStatus == "loaded-module scan truncated" then
        return false, loadedModulesStatus
    end
    return false, "module not already loaded"
end

local skillInspection = {
    status = "not inspected",
    path = "PlayerScripts/Manager/PlayerSkillClientManager/PlayerSkillInput",
    exports = {},
    truncated = false,
}

local function readLoadedModuleAtIdentityTwo(moduleScript)
    local wasLoaded, loadedStatus = moduleWasAlreadyLoaded(moduleScript)
    if not wasLoaded then
        return false, "skipped to remain passive: " .. loadedStatus
    end
    local identityGetter = nil
    local identitySetter = nil
    pcall(function()
        if type(getthreadidentity) == "function" then identityGetter = getthreadidentity end
        if type(setthreadidentity) == "function" then identitySetter = setthreadidentity end
    end)

    local originalIdentity = nil
    local changedIdentity = false
    if identityGetter ~= nil and identitySetter ~= nil then
        local identityOk, identity = pcall(identityGetter)
        if identityOk and type(identity) == "number" then
            originalIdentity = identity
            changedIdentity = pcall(identitySetter, 2)
        end
    end

    -- getloadedmodules proved this exact ModuleScript was initialized already,
    -- so require returns its cached export table. No export is invoked here.
    local ok, result = pcall(require, moduleScript)
    if changedIdentity then
        pcall(identitySetter, originalIdentity)
    end
    return ok, result
end

local function inspectSkillInput()
    local playerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
    local manager = playerScripts and playerScripts:FindFirstChild("Manager")
    local skillManager = manager and manager:FindFirstChild("PlayerSkillClientManager")
    local moduleScript = skillManager and skillManager:FindFirstChild("PlayerSkillInput")
    if moduleScript == nil or not safeIsA(moduleScript, "ModuleScript") then
        skillInspection.status = "module not found"
        return
    end

    skillInspection.path = safeFullName(moduleScript)
    local ok, exports = readLoadedModuleAtIdentityTwo(moduleScript)
    if not ok then
        local reason = cleanText(exports, 180)
        skillInspection.status = string.find(reason, "skipped to remain passive", 1, true)
            and reason
            or ("cached require failed: " .. reason)
        return
    end
    if type(exports) ~= "table" then
        skillInspection.status = "cached require returned " .. cleanText(typeof(exports), 60)
        return
    end

    local rows = {}
    local iterationOk = pcall(function()
        local cursor = nil
        while true do
            local key, value = next(exports, cursor)
            if key == nil then break end
            cursor = key
            if #rows >= CONFIG.MaxExports then
                skillInspection.truncated = true
                break
            end
            table.insert(rows, {
                key = cleanText(key, 140),
                metadata = functionMetadata(value),
            })
        end
    end)
    if not iterationOk then
        readErrors = readErrors + 1
        skillInspection.status = "export enumeration failed"
        return
    end
    table.sort(rows, function(left, right)
        return left.key < right.key
    end)
    skillInspection.exports = rows
    skillInspection.status = string.format("ok (%d exports)", #rows)
end

local utilsInspection = {
    status = "not inspected",
    path = "<not found>",
    requireType = "?",
    metatableType = "?",
    callType = "?",
    directNetMsgType = "?",
    directNetWorkType = "?",
    lookups = {},
}

local function describeRegistryResult(value)
    local valueType = typeof(value)
    if valueType == "Instance" then
        return string.format("[%s] %s", safeClassName(value), safeFullName(value))
    end
    if valueType ~= "table" then
        return cleanText(value, 180)
    end

    local keys = {}
    local truncated = false
    local iterationOk = pcall(function()
        local cursor = nil
        while true do
            local key, item = next(value, cursor)
            if key == nil then break end
            cursor = key
            if #keys >= 12 then
                truncated = true
                break
            end
            table.insert(keys, cleanText(key, 80) .. ":" .. cleanText(typeof(item), 40))
        end
    end)
    if not iterationOk then return "table <enumeration failed>" end
    table.sort(keys)
    return "table {" .. table.concat(keys, ", ") .. (truncated and ", ...}" or "}")
end

local function inspectUtilsSystem()
    local moduleScript = ReplicatedFirst:FindFirstChild("UtilsSystem", true)
    if moduleScript == nil then
        moduleScript = ReplicatedStorage:FindFirstChild("UtilsSystem", true)
    end
    if moduleScript == nil or not safeIsA(moduleScript, "ModuleScript") then
        utilsInspection.status = "UtilsSystem module not found"
        return
    end

    utilsInspection.path = safeFullName(moduleScript)
    local requireOk, registry = readLoadedModuleAtIdentityTwo(moduleScript)
    utilsInspection.requireType = requireOk and typeof(registry) or "not called/failed"
    if not requireOk then
        local reason = cleanText(registry, 180)
        utilsInspection.status = string.find(reason, "skipped to remain passive", 1, true)
            and reason
            or ("cached require failed: " .. reason)
        return
    end

    local metatableOk, metatable = pcall(getmetatable, registry)
    if metatableOk then
        utilsInspection.metatableType = typeof(metatable)
        if type(metatable) == "table" then
            local callOk, callValue = pcall(function()
                return metatable.__call
            end)
            utilsInspection.callType = callOk and typeof(callValue) or "read failed"
        else
            utilsInspection.callType = "none"
        end
    else
        utilsInspection.metatableType = "read failed"
        utilsInspection.callType = "unknown"
    end

    if type(registry) == "table" then
        local netMsgOk, netMsg = pcall(function() return registry.NetMsg end)
        local netWorkOk, netWork = pcall(function() return registry.NetWork end)
        utilsInspection.directNetMsgType = netMsgOk and typeof(netMsg) or "read failed"
        utilsInspection.directNetWorkType = netWorkOk and typeof(netWork) or "read failed"
    end

    local callable = type(registry) == "function"
        or (type(registry) == "table" and utilsInspection.callType == "function")
    for _, key in ipairs({ "NetMsg", "NetWork" }) do
        local row = { key = key, ok = false, valueType = "not called", result = "registry not callable" }
        if callable then
            -- These are registry lookups only. No returned function, callback,
            -- action, RemoteEvent, or RemoteFunction is invoked.
            local lookupOk, value = pcall(function()
                return registry(key)
            end)
            row.ok = lookupOk
            row.valueType = lookupOk and typeof(value) or "error"
            row.result = lookupOk and describeRegistryResult(value) or cleanText(value, 180)
        end
        table.insert(utilsInspection.lookups, row)
    end
    utilsInspection.status = "ok (read-only registry probe)"
end

local uisInspection = {
    status = "not inspected",
    rows = {},
    truncated = false,
}

local function inspectUISConnections()
    local connectionReader = nil
    pcall(function()
        if type(getconnections) == "function" then
            connectionReader = getconnections
        end
    end)
    if connectionReader == nil then
        uisInspection.status = "getconnections unavailable"
        return
    end

    local signalRows = {
        { name = "InputBegan", signal = UserInputService.InputBegan },
        { name = "InputEnded", signal = UserInputService.InputEnded },
        { name = "InputChanged", signal = UserInputService.InputChanged },
    }
    local total = 0
    for _, signalRow in ipairs(signalRows) do
        local ok, connections = pcall(connectionReader, signalRow.signal)
        if ok and type(connections) == "table" then
            local perSignal = 0
            for index, connection in ipairs(connections) do
                if perSignal >= CONFIG.MaxConnectionsPerSignal
                    or total >= CONFIG.MaxConnectionsTotal then
                    uisInspection.truncated = true
                    break
                end
                local callback = nil
                pcall(function()
                    callback = connection.Function or connection.fn
                end)
                table.insert(uisInspection.rows, {
                    signal = signalRow.name,
                    index = index,
                    metadata = functionMetadata(callback),
                })
                perSignal = perSignal + 1
                total = total + 1
            end
        else
            table.insert(uisInspection.rows, {
                signal = signalRow.name,
                index = 0,
                metadata = "connection read failed",
            })
            readErrors = readErrors + 1
        end
        if total >= CONFIG.MaxConnectionsTotal then break end
    end
    uisInspection.status = string.format("ok (%d connections)", total)
end

-- Numeric snapshot/delta -----------------------------------------------------

local function finiteNumber(value)
    return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end

local function captureNumericSnapshot()
    local snapshot = {
        values = {},
        labels = {},
        scanned = 0,
        captured = 0,
        truncated = false,
    }
    local queue = {}
    local queued = {}

    local function queueRoot(root, scope)
        if root ~= nil and not queued[root] then
            queued[root] = true
            table.insert(queue, { instance = root, scope = scope })
        end
    end

    queueRoot(LocalPlayer, "LocalPlayer")
    queueRoot(LocalPlayer.Character, "Character")
    local head = 1
    while head <= #queue and snapshot.scanned < CONFIG.MaxScanInstances
        and snapshot.captured < CONFIG.MaxNumericSignals do
        local entry = queue[head]
        head = head + 1
        local instance = entry.instance
        if not isOwnInstance(instance) then
            snapshot.scanned = snapshot.scanned + 1
            local path = entry.scope .. "/" .. safeFullName(instance)

            if safeIsA(instance, "NumberValue") or safeIsA(instance, "IntValue") then
                local valueOk, value = pcall(function()
                    return instance.Value
                end)
                if valueOk and finiteNumber(value) then
                    local key = "Value|" .. path
                    snapshot.values[key] = value
                    snapshot.labels[key] = path .. ".Value"
                    snapshot.captured = snapshot.captured + 1
                elseif not valueOk then
                    readErrors = readErrors + 1
                end
            end

            if snapshot.captured < CONFIG.MaxNumericSignals then
                local attributesOk, attributes = pcall(function()
                    return instance:GetAttributes()
                end)
                if attributesOk and type(attributes) == "table" then
                    local names = {}
                    for name, value in pairs(attributes) do
                        if finiteNumber(value) then table.insert(names, tostring(name)) end
                    end
                    table.sort(names)
                    for _, name in ipairs(names) do
                        if snapshot.captured >= CONFIG.MaxNumericSignals then
                            snapshot.truncated = true
                            break
                        end
                        local value = attributes[name]
                        if finiteNumber(value) then
                            local key = "Attribute|" .. path .. "@" .. cleanText(name, 120)
                            snapshot.values[key] = value
                            snapshot.labels[key] = path .. "[" .. cleanText(name, 120) .. "]"
                            snapshot.captured = snapshot.captured + 1
                        end
                    end
                elseif not attributesOk then
                    readErrors = readErrors + 1
                end
            end

            local childrenOk, children = pcall(function()
                return instance:GetChildren()
            end)
            if childrenOk and type(children) == "table" then
                for _, child in ipairs(children) do
                    if #queue - head + 1 >= CONFIG.MaxScanInstances then
                        snapshot.truncated = true
                        break
                    end
                    if not queued[child] and not isOwnInstance(child) then
                        queued[child] = true
                        table.insert(queue, { instance = child, scope = entry.scope })
                    end
                end
            elseif not childrenOk then
                readErrors = readErrors + 1
            end
        end
    end
    if head <= #queue or snapshot.scanned >= CONFIG.MaxScanInstances
        or snapshot.captured >= CONFIG.MaxNumericSignals then
        snapshot.truncated = true
    end
    return snapshot
end

local function compareNumericSnapshots(before, after)
    local deltas = {}
    local visited = {}
    for key, beforeValue in pairs(before.values) do
        visited[key] = true
        local afterValue = after.values[key]
        if afterValue == nil then
            table.insert(deltas, {
                label = before.labels[key] or key,
                before = beforeValue,
                after = nil,
                delta = nil,
                magnitude = math.huge,
            })
        elseif afterValue ~= beforeValue then
            table.insert(deltas, {
                label = after.labels[key] or before.labels[key] or key,
                before = beforeValue,
                after = afterValue,
                delta = afterValue - beforeValue,
                magnitude = math.abs(afterValue - beforeValue),
            })
        end
    end
    for key, afterValue in pairs(after.values) do
        if not visited[key] then
            table.insert(deltas, {
                label = after.labels[key] or key,
                before = nil,
                after = afterValue,
                delta = nil,
                magnitude = math.huge,
            })
        end
    end
    table.sort(deltas, function(left, right)
        if left.magnitude == right.magnitude then
            return left.label < right.label
        end
        return left.magnitude > right.magnitude
    end)
    local truncated = #deltas > CONFIG.MaxDeltasPerClick
    while #deltas > CONFIG.MaxDeltasPerClick do
        table.remove(deltas)
    end
    return deltas, truncated
end

local function numericSnapshotSummary(snapshot)
    return {
        scanned = snapshot.scanned,
        captured = snapshot.captured,
        truncated = snapshot.truncated == true,
    }
end

-- Remote capture. The __namecall hook is deliberately a pure producer. ------

local function formatRemoteValue(value, depth, state)
    if state.nodes >= CONFIG.MaxArgumentNodes then return "<node-limit>" end
    state.nodes = state.nodes + 1
    local valueType = typeof(value)
    if value == nil then return "nil" end
    if valueType == "string" then return string.format("%q", cleanText(value, CONFIG.MaxStringLength)) end
    if valueType == "number" or valueType == "boolean" then return tostring(value) end
    if valueType == "Instance" then
        return string.format("[%s] %s", safeClassName(value), safeFullName(value))
    end
    if valueType == "table" then
        if depth >= CONFIG.MaxArgumentDepth then return "{...}" end
        if state.seen[value] then return "<cycle>" end
        state.seen[value] = true
        local pieces = {}
        local cursor = nil
        for _ = 1, CONFIG.MaxTableItems do
            local nextOk, key, item = pcall(next, value, cursor)
            if not nextOk then
                table.insert(pieces, "<table-read-failed>")
                readErrors = readErrors + 1
                break
            end
            if key == nil then break end
            cursor = key
            table.insert(
                pieces,
                formatRemoteValue(key, depth + 1, state)
                    .. "=" .. formatRemoteValue(item, depth + 1, state)
            )
            if state.nodes >= CONFIG.MaxArgumentNodes then break end
        end
        state.seen[value] = nil
        return "{" .. table.concat(pieces, ", ") .. "}"
    end
    local ok, text = pcall(tostring, value)
    return ok and ("<" .. valueType .. "> " .. cleanText(text, 160)) or ("<" .. valueType .. ">")
end

local function formatRemoteArguments(packed)
    local state = { nodes = 0, seen = {} }
    local pieces = {}
    local count = math.min(tonumber(packed.n) or 0, CONFIG.MaxArguments)
    for index = 1, count do
        table.insert(pieces, string.format(
            "%d=%s",
            index,
            formatRemoteValue(packed[index], 0, state)
        ))
    end
    if (tonumber(packed.n) or 0) > CONFIG.MaxArguments then
        table.insert(pieces, "<argument-limit>")
    end
    return cleanText(table.concat(pieces, ", "), CONFIG.MaxArgumentCharacters)
end

-- HOOK_PRODUCER_BEGIN: primitive queue writes only.
local function produceRemoteCapture(method, remote, arguments, capturedAt)
    if not hookActive then return end
    if pendingRemoteCount >= CONFIG.MaxPendingRemotes then
        droppedRemoteCaptures = droppedRemoteCaptures + 1
        return
    end
    pendingRemoteTail = pendingRemoteTail + 1
    pendingRemoteQueue[pendingRemoteTail] = {
        method = method,
        remote = remote,
        arguments = arguments,
        clock = capturedAt,
    }
    pendingRemoteCount = pendingRemoteCount + 1
end
-- HOOK_PRODUCER_END

local function dequeueRemoteCapture()
    if pendingRemoteCount <= 0 then return nil end
    local capture = pendingRemoteQueue[pendingRemoteHead]
    pendingRemoteQueue[pendingRemoteHead] = nil
    pendingRemoteHead = pendingRemoteHead + 1
    pendingRemoteCount = pendingRemoteCount - 1
    if pendingRemoteCount == 0 then
        pendingRemoteHead = 1
        pendingRemoteTail = 0
    end
    return capture
end

local function processRemoteCapture(capture)
    if capture == nil or not hookActive then return end
    local remote = capture.remote
    if typeof(remote) ~= "Instance" then return end
    local className = safeClassName(remote)
    local valid = (capture.method == "FireServer"
        and (className == "RemoteEvent" or className == "UnreliableRemoteEvent"))
        or (capture.method == "InvokeServer" and className == "RemoteFunction")
    if not valid then return end

    local remoteName = "<name unavailable>"
    local nameOk, nameValue = pcall(function() return remote.Name end)
    if nameOk then
        remoteName = cleanText(nameValue, 160)
    else
        readErrors = readErrors + 1
    end
    local action = ""
    if (tonumber(capture.arguments.n) or 0) >= 1
        and type(capture.arguments[1]) == "string" then
        action = cleanText(capture.arguments[1], 240)
    end
    table.insert(remoteHistory, {
        clock = capture.clock,
        method = capture.method,
        className = className,
        name = remoteName,
        action = action,
        path = safeFullName(remote),
        arguments = formatRemoteArguments(capture.arguments),
    })
    while #remoteHistory > CONFIG.MaxRemoteHistory do
        table.remove(remoteHistory, 1)
    end
end

local function installRemoteObserver()
    local namecallMethod = nil
    pcall(function()
        if type(getnamecallmethod) == "function" then namecallMethod = getnamecallmethod end
        if type(hookmetamethod) == "function" then hookInstaller = hookmetamethod end
    end)
    if namecallMethod == nil or hookInstaller == nil then
        hookRestoreStatus = "executor hook APIs unavailable"
        return false
    end

    -- HOOK_HANDLER_BEGIN: fail-open classification and primitive enqueue only.
    local rawHandler = function(self, ...)
        if hookActive then
            -- Some executors expose getnamecallmethod but reject it in a
            -- restricted hook capability. Classification must fail open: an
            -- inspection error can never prevent the original remote call.
            local methodOk, method = pcall(namecallMethod)
            if methodOk and (method == "FireServer" or method == "InvokeServer") then
                produceRemoteCapture(method, self, table.pack(...), os.clock())
            end
        end
        return originalNamecall(self, ...)
    end
    -- HOOK_HANDLER_END

    local closureFactory = nil
    pcall(function()
        if type(newcclosure) == "function" then closureFactory = newcclosure end
    end)
    hookFunction = closureFactory and closureFactory(rawHandler) or rawHandler
    local ok, previous = pcall(hookInstaller, game, "__namecall", hookFunction)
    if not ok or type(previous) ~= "function" then
        hookFunction = nil
        hookRestoreStatus = "hook installation failed"
        return false
    end
    originalNamecall = previous
    hookInstalled = true
    hookActive = true
    hookRestoreStatus = "active"
    return true
end

-- Click lifecycle ------------------------------------------------------------

local function appendClick(click)
    table.insert(clicks, click)
    while #clicks > CONFIG.MaxClicks do
        table.remove(clicks, 1)
        droppedClicks = droppedClicks + 1
    end
end

local function correlateRemotes(click, cutoff)
    local candidates = {}
    local lower = click.beganAt - CONFIG.CorrelationBeforeSeconds
    local upper = cutoff + CONFIG.CorrelationAfterSeconds
    for _, remote in ipairs(remoteHistory) do
        if remote.clock >= lower and remote.clock <= upper then
            table.insert(candidates, {
                clock = remote.clock,
                method = remote.method,
                className = remote.className,
                name = remote.name,
                action = remote.action,
                path = remote.path,
                arguments = remote.arguments,
                distanceFromClick = math.abs(remote.clock - click.beganAt),
            })
        end
    end

    local relevant = {}
    local aimSamples = {}
    for _, remote in ipairs(candidates) do
        local lowerName = string.lower(
            remote.action .. " " .. remote.name .. " " .. remote.path
        )
        local isAimSample = string.find(lowerName, "玩家瞄准采样", 1, true) ~= nil
            or (string.find(lowerName, "aim", 1, true) ~= nil
                and string.find(lowerName, "sampl", 1, true) ~= nil)
        if isAimSample then
            local key = remote.method .. "|" .. remote.path
            local existing = aimSamples[key]
            if existing == nil or remote.distanceFromClick < existing.distanceFromClick then
                local count = existing and existing.repeatCount or 0
                remote.repeatCount = count + 1
                aimSamples[key] = remote
            else
                existing.repeatCount = (existing.repeatCount or 1) + 1
            end
        else
            table.insert(relevant, remote)
        end
    end
    table.sort(relevant, function(left, right)
        return left.distanceFromClick < right.distanceFromClick
    end)

    local matches = {}
    for _, remote in ipairs(relevant) do
        table.insert(matches, remote)
        if #matches >= CONFIG.MaxRemotesPerClick then return matches end
    end

    local collapsedAimSamples = {}
    for _, remote in pairs(aimSamples) do
        table.insert(collapsedAimSamples, remote)
    end
    table.sort(collapsedAimSamples, function(left, right)
        return left.distanceFromClick < right.distanceFromClick
    end)
    for _, remote in ipairs(collapsedAimSamples) do
        table.insert(matches, remote)
        if #matches >= CONFIG.MaxRemotesPerClick then break end
    end
    return matches
end

local function finalizeClick(click)
    if click.finalized or not alive then return end
    click.finalized = true
    click.after = captureNumericSnapshot()
    click.afterSummary = numericSnapshotSummary(click.after)
    click.deltas, click.deltasTruncated = compareNumericSnapshots(click.before, click.after)
    click.remotes = correlateRemotes(click, click.endedAt or click.beganAt)
    click.before = nil
    click.after = nil
    scheduleRender()
end

local function queueClickForFinalization(click)
    if #pendingClicks >= CONFIG.MaxPendingClicks then
        local oldest = table.remove(pendingClicks, 1)
        finalizeClick(oldest)
    end
    table.insert(pendingClicks, click)
end

local function beginRealLeftClick(input, processed)
    -- Timestamp the UIS callback before any potentially expensive snapshot so
    -- synchronous remotes remain inside the correlation window.
    local beganAt = os.clock()
    local position = inputPosition(input)
    if pointInside(window, position) then return end

    if activeClick ~= nil and not activeClick.finalized then
        activeClick.interrupted = true
        activeClick.endedAt = os.clock()
        activeClick.endPosition = position
        queueClickForFinalization(activeClick)
    end

    clickSequence = clickSequence + 1
    local before = captureNumericSnapshot()
    local click = {
        id = clickSequence,
        beganAt = beganAt,
        beginProcessed = processed == true,
        beginPosition = position,
        before = before,
        beforeSummary = numericSnapshotSummary(before),
        finalized = false,
        remotes = {},
        deltas = {},
    }
    activeClick = click
    appendClick(click)
    scheduleRender()
end

local function endRealLeftClick(input, processed)
    if activeClick == nil then return end
    local click = activeClick
    activeClick = nil
    click.endedAt = os.clock()
    click.endProcessed = processed == true
    click.endPosition = inputPosition(input)
    click.finalizeAt = click.endedAt
        + math.max(CONFIG.NumericSettleSeconds, CONFIG.CorrelationAfterSeconds)
    queueClickForFinalization(click)
    scheduleRender()
end

local function pumpPendingClicks(now)
    local index = 1
    while index <= #pendingClicks do
        local click = pendingClicks[index]
        if now >= (click.finalizeAt or now) then
            table.remove(pendingClicks, index)
            finalizeClick(click)
        else
            index = index + 1
        end
    end
end

-- Report --------------------------------------------------------------------

local function renderReport()
    if not alive or closed or minimized then return end
    local lines = {}
    local characters = 0
    local reportFull = false
    local longest = 0

    local function addLine(text)
        if reportFull then return end
        text = cleanText(text, 1800)
        if characters + #text + 1 > CONFIG.MaxReportCharacters then
            reportFull = true
            table.insert(lines, "<report character limit reached>")
            return
        end
        table.insert(lines, text)
        characters = characters + #text + 1
        longest = math.max(longest, #text)
    end

    addLine("INFINITYGOLD PASSIVE CLICK/ACTION INSPECTOR")
    addLine(string.format(
        "elapsed=%.1fs | clicks=%d | pending-clicks=%d | remote-queue=%d | dropped-remotes=%d | read-errors=%d",
        os.clock() - startedAt,
        #clicks,
        #pendingClicks,
        pendingRemoteCount,
        droppedRemoteCaptures,
        readErrors
    ))
    addLine("mode=READ ONLY | no input injection | no exported/UIS callback execution | no remote sending")
    addLine("module inspection: cached modules only | callable registry: NetMsg/NetWork lookups only")
    addLine("remote observer: " .. hookRestoreStatus)
    addLine("")

    addLine("PlayerSkillInput exports (inspection only):")
    addLine("  path: " .. skillInspection.path)
    addLine("  status: " .. skillInspection.status)
    for _, row in ipairs(skillInspection.exports) do
        addLine("  " .. row.key .. " -> " .. row.metadata)
    end
    if skillInspection.truncated then addLine("  <export limit reached>") end
    addLine("")

    addLine("UtilsSystem registry resolver (read-only lookups):")
    addLine("  path: " .. utilsInspection.path)
    addLine("  status: " .. utilsInspection.status)
    addLine("  type(require(UtilsSystem)): " .. utilsInspection.requireType)
    addLine("  type(getmetatable(registry)): " .. utilsInspection.metatableType)
    addLine("  type(getmetatable(registry).__call): " .. utilsInspection.callType)
    addLine("  direct registry.NetMsg type: " .. utilsInspection.directNetMsgType)
    addLine("  direct registry.NetWork type: " .. utilsInspection.directNetWorkType)
    for _, row in ipairs(utilsInspection.lookups) do
        addLine(string.format(
            "  registry(%q): ok=%s type=%s result=%s",
            row.key,
            tostring(row.ok),
            row.valueType,
            row.result
        ))
    end
    addLine("")

    addLine("Existing UserInputService connections (inspection only):")
    addLine("  status: " .. uisInspection.status)
    for _, row in ipairs(uisInspection.rows) do
        addLine(string.format("  %s #%d -> %s", row.signal, row.index, row.metadata))
    end
    if uisInspection.truncated then addLine("  <connection limit reached>") end
    addLine("")

    addLine("Real left-click observations (newest first):")
    if #clicks == 0 then
        addLine("  No external MouseButton1 InputBegan event observed yet.")
    end
    for index = #clicks, 1, -1 do
        local click = clicks[index]
        addLine(string.format(
            "CLICK #%d | InputBegan t=%.3f processed=%s position=%s",
            click.id,
            click.beganAt - startedAt,
            tostring(click.beginProcessed),
            formatPosition(click.beginPosition)
        ))
        if click.endedAt ~= nil then
            addLine(string.format(
                "  InputEnded t=%.3f processed=%s position=%s held=%.3fs%s",
                click.endedAt - startedAt,
                tostring(click.endProcessed),
                formatPosition(click.endPosition),
                click.endedAt - click.beganAt,
                click.interrupted and " interrupted=true" or ""
            ))
        else
            addLine("  InputEnded: pending")
        end
        if not click.finalized then
            addLine(string.format(
                "  numeric snapshot before: scanned=%d captured=%d truncated=%s",
                click.beforeSummary.scanned,
                click.beforeSummary.captured,
                tostring(click.beforeSummary.truncated)
            ))
            addLine("  effect snapshot: waiting for release/settle window")
        else
            addLine(string.format(
                "  nearby FireServer/InvokeServer calls: %d",
                #click.remotes
            ))
            for _, remote in ipairs(click.remotes) do
                addLine(string.format(
                    "    %+0.3fs %s [%s] %s%s%s",
                    remote.clock - click.beganAt,
                    remote.method,
                    remote.className,
                    remote.path,
                    remote.action ~= "" and (" action=" .. string.format("%q", remote.action)) or "",
                    (remote.repeatCount or 1) > 1
                        and string.format(" (x%d aim samples collapsed)", remote.repeatCount)
                        or ""
                ))
                addLine("      args: " .. remote.arguments)
            end
            addLine(string.format(
                "  numeric snapshots: before scanned=%d captured=%d truncated=%s"
                    .. " | after scanned=%d captured=%d truncated=%s",
                click.beforeSummary.scanned,
                click.beforeSummary.captured,
                tostring(click.beforeSummary.truncated),
                click.afterSummary.scanned,
                click.afterSummary.captured,
                tostring(click.afterSummary.truncated)
            ))
            addLine(string.format("  numeric deltas: %d", #click.deltas))
            for _, delta in ipairs(click.deltas) do
                if delta.before == nil then
                    addLine(string.format("    %s | added=%s", delta.label, tostring(delta.after)))
                elseif delta.after == nil then
                    addLine(string.format("    %s | removed (was %s)", delta.label, tostring(delta.before)))
                else
                    addLine(string.format(
                        "    %s | %s -> %s | delta=%+g",
                        delta.label,
                        tostring(delta.before),
                        tostring(delta.after),
                        delta.delta
                    ))
                end
            end
            if click.deltasTruncated then addLine("    <delta limit reached>") end
            if click.beforeSummary.truncated or click.afterSummary.truncated then
                addLine("    WARNING: snapshot truncated; zero deltas is not proof of no change")
            end
        end
        addLine("")
    end

    latestReport = table.concat(lines, "\n")
    reportText.Text = latestReport
    local contentWidth = math.max(reportScroll.AbsoluteSize.X - 20, math.min(12000, longest * 7.3 + 20))
    local contentHeight = math.max(reportScroll.AbsoluteSize.Y - 20, #lines * 15 + 20)
    reportText.Size = UDim2.fromOffset(contentWidth, contentHeight)
    reportScroll.CanvasSize = UDim2.fromOffset(contentWidth + 16, contentHeight + 14)
    statusLabel.Text = string.format(
        "Clics %d | Hook %s | Cola %d | Perdidos %d | Errores %d",
        #clicks,
        hookInstalled and (hookActive and "activo" or "dormido") or "no disponible",
        pendingRemoteCount,
        droppedRemoteCaptures + droppedClicks,
        readErrors
    )
end

-- Cleanup and controls -------------------------------------------------------

local function getClipboardWriter()
    local writer = nil
    pcall(function()
        if type(setclipboard) == "function" then
            writer = setclipboard
        elseif type(toclipboard) == "function" then
            writer = toclipboard
        end
    end)
    return writer
end

local function ownsCurrentNamecallHook()
    local rawMetatableReader = nil
    pcall(function()
        if type(getrawmetatable) == "function" then
            rawMetatableReader = getrawmetatable
        end
    end)
    if rawMetatableReader == nil or hookFunction == nil then return false end
    local ok, current = pcall(function()
        return rawMetatableReader(game).__namecall
    end)
    return ok and current == hookFunction
end

local function clearQueues()
    pendingRemoteQueue = {}
    pendingRemoteHead = 1
    pendingRemoteTail = 0
    pendingRemoteCount = 0
    pendingClicks = {}
    remoteHistory = {}
    clicks = {}
    activeClick = nil
end

local closeInspector
closeInspector = function()
    if closed then return end
    closed = true
    alive = false

    -- Sleeping first guarantees that an un-restorable stacked hook becomes a
    -- harmless pass-through instead of observing after the popup is closed.
    hookActive = false
    for _, connection in ipairs(globalConnections) do
        pcall(function()
            connection:Disconnect()
        end)
    end
    globalConnections = {}

    if hookInstalled and hookInstaller ~= nil and originalNamecall ~= nil
        and ownsCurrentNamecallHook() then
        local restored = pcall(hookInstaller, game, "__namecall", originalNamecall)
        hookRestoreStatus = restored and "restored" or "dormant; restore failed"
    elseif hookInstalled then
        hookRestoreStatus = "dormant; newer/unknown hook preserved"
    end
    hookInstalled = false
    clearQueues()

    if globalEnvironment[GLOBAL_KEY] == closeInspector then
        globalEnvironment[GLOBAL_KEY] = nil
    end
    pcall(function()
        rootGui:Destroy()
    end)
end

globalEnvironment[GLOBAL_KEY] = closeInspector

connect(closeButton.Activated, closeInspector)

connect(minimizeButton.Activated, function()
    local topLeft = window.AbsolutePosition
    minimized = not minimized
    if minimized then
        window.Size = minimizedSize
        title.Size = UDim2.new(1, -90, 0, 20)
        subtitle.Visible = false
        copyButton.Visible = false
        statusLabel.Visible = false
        reportScroll.Visible = false
        minimizeButton.Text = "+"
    else
        window.Size = expandedSize
        title.Size = UDim2.new(1, -240, 0, 20)
        subtitle.Visible = true
        copyButton.Visible = true
        statusLabel.Visible = true
        reportScroll.Visible = true
        minimizeButton.Text = "-"
        scheduleRender()
    end
    task.defer(function()
        if alive and not closed then setWindowTopLeft(topLeft) end
    end)
end)

connect(copyButton.Activated, function()
    local writer = getClipboardWriter()
    local copied = writer ~= nil and pcall(writer, latestReport)
    copyButton.Text = copied and "Copiado" or "Sin soporte"
    copyButton.BackgroundColor3 = copied
        and Color3.fromRGB(34, 91, 62)
        or Color3.fromRGB(88, 43, 52)
    task.delay(1.3, function()
        if alive and not closed then
            copyButton.Text = "Copiar"
            copyButton.BackgroundColor3 = Color3.fromRGB(37, 83, 112)
        end
    end)
end)

local dragging = false
local dragStart = nil
local dragOrigin = nil

connect(header.InputBegan, function(input)
    if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
    local position = inputPosition(input)
    if pointInside(copyButton, position)
        or pointInside(minimizeButton, position)
        or pointInside(closeButton, position) then
        return
    end
    dragging = true
    dragStart = position
    dragOrigin = window.AbsolutePosition
end)

-- Capture the game's pre-existing handlers before connecting this inspector's
-- own UIS observers, so the report does not mostly describe itself.
inspectSkillInput()
inspectUtilsSystem()
inspectUISConnections()

connect(UserInputService.InputBegan, function(input, processed)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        beginRealLeftClick(input, processed)
    end
end)

connect(UserInputService.InputEnded, function(input, processed)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        endRealLeftClick(input, processed)
        dragging = false
        dragStart = nil
        dragOrigin = nil
    end
end)

connect(UserInputService.InputChanged, function(input)
    if not dragging or dragStart == nil or dragOrigin == nil then return end
    if input.UserInputType == Enum.UserInputType.MouseMovement then
        local position = inputPosition(input)
        setWindowTopLeft(dragOrigin + (position - dragStart))
    end
end)

-- The hook may inherit a restricted executor capability context. It only
-- produces queue records; this Heartbeat consumer performs every Instance/UI
-- read, argument snapshot, correlation, and render on the script's main context.
connect(RunService.Heartbeat, function()
    local drained = math.min(pendingRemoteCount, CONFIG.MaxRemotesPerHeartbeat)
    for _ = 1, drained do
        local capture = dequeueRemoteCapture()
        local ok = pcall(processRemoteCapture, capture)
        if not ok then readErrors = readErrors + 1 end
    end

    local now = os.clock()
    pumpPendingClicks(now)
    if renderScheduled and not minimized
        and now - lastRenderAt >= CONFIG.RenderIntervalSeconds then
        lastRenderAt = now
        renderScheduled = false
        local ok = pcall(renderReport)
        if not ok then readErrors = readErrors + 1 end
    end
end)

installRemoteObserver()
scheduleRender()
