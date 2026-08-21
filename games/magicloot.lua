-- InfinityGold for Magic Loot — original automation suite.
--
-- Entry point: the loader calls this chunk with
--   (locomotionFactory, Library, Common)
-- locomotionFactory may be nil (module failed to load); InfinityGold keeps
-- working without the external Walking/Broom extension in that case.
--
-- Design rules honoured here:
--   * Walking never teleports and never touches WalkSpeed/JumpPower.
--   * Only the external Walking module may request a character reset.
--   * Every game-integration surface is fail-open: a missing remote or
--     module disables its feature with a status message instead of erroring.

local BRAND = "InfinityGold"
local MAX_FARM_STAGE = 32
local MAX_PICKUP_TIER = 10
local PLACE_ID = 133188236593503
local CREATOR_ID = 118455659
local DISCORD_INVITE = "" -- set to an invite URL to show the invite button

return function(locomotionFactory, Library, Common)
    local bannerGui

    local function banner(content)
        pcall(function()
            if player == nil then return end
            local playerGui = player:FindFirstChildOfClass("PlayerGui")
            if playerGui == nil then return end
            if bannerGui == nil or bannerGui.Parent == nil then
                bannerGui = Instance.new("ScreenGui")
                bannerGui.Name = "InfinityGoldStatus"
                bannerGui.ResetOnSpawn = false
                bannerGui.DisplayOrder = 1000000
                bannerGui.IgnoreGuiInset = true
                bannerGui.Parent = playerGui

                local label = Instance.new("TextLabel")
                label.Name = "Status"
                label.AnchorPoint = Vector2.new(0.5, 1)
                label.Position = UDim2.new(0.5, 0, 1, -24)
                label.Size = UDim2.new(0.92, 0, 0, 30)
                label.BackgroundColor3 = Color3.fromRGB(13, 13, 18)
                label.BackgroundTransparency = 0.15
                label.TextColor3 = Color3.fromRGB(245, 197, 66)
                label.Font = Enum.Font.GothamBold
                label.TextSize = 13
                label.TextWrapped = true
                label.Parent = bannerGui

                local rounding = Instance.new("UICorner")
                rounding.CornerRadius = UDim.new(0, 8)
                rounding.Parent = label
            end
            bannerGui.Status.Text = "[InfinityGold] " .. tostring(content)
        end)
    end

    local function earlyNotify(content)
        banner(content)
        pcall(function()
            Library:Notify({
                Title = BRAND,
                Content = content,
                Duration = 6,
            })
        end)
        pcall(function()
            game:GetService("StarterGui"):SetCore("SendNotification", {
                Title = BRAND,
                Text = content,
                Duration = 6,
            })
        end)
    end

    if game.PlaceId ~= PLACE_ID and game.CreatorId ~= CREATOR_ID then
        earlyNotify("Unsupported game (PlaceId " .. tostring(game.PlaceId) .. ")")
        return
    end

    if type(Library) ~= "table" or type(Library.CreateWindow) ~= "function" then
        warn("[" .. BRAND .. "] interface library unavailable")
        return
    end

    local Players = game:GetService("Players")
    local ReplicatedFirst = game:GetService("ReplicatedFirst")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local RunService = game:GetService("RunService")
    local TeleportService = game:GetService("TeleportService")
    local HttpService = game:GetService("HttpService")
    local UserInputService = game:GetService("UserInputService")

    local player = Players.LocalPlayer
    if player == nil then
        Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
        player = Players.LocalPlayer
    end

    local sessionEnvironment = nil
    pcall(function()
        if type(getgenv) == "function" then
            sessionEnvironment = getgenv()
            local previousUnload = sessionEnvironment.__INFINITYGOLD_UNLOAD
            if type(previousUnload) == "function" then pcall(previousUnload, "reload") end
        end
    end)
    pcall(function()
        local playerGui = player:FindFirstChildOfClass("PlayerGui")
        if playerGui == nil then return end
        for _, name in ipairs({
            "InfinityGoldToggle",
            "InfinityGoldLoaderToggle",
            "InfinityGoldEmergency",
        }) do
            for _, child in ipairs(playerGui:GetChildren()) do
                if child.Name == name then child:Destroy() end
            end
        end
    end)

    local sessionAlive = true
    local unloaded = false
    local floatingGui
    local emergencyGui
    local unloadSession
    local startedAt = os.clock()
    local executorName = type(identifyexecutor) == "function"
        and tostring(identifyexecutor())
        or "unknown"
    local alchemyInvokeLease = { pending = false, generation = 0, startedAt = nil }
    if sessionEnvironment ~= nil then
        local existingLease = sessionEnvironment.__INFINITYGOLD_ALCHEMY_INVOKE
        if type(existingLease) == "table" then
            alchemyInvokeLease = existingLease
            alchemyInvokeLease.pending = existingLease.pending == true
            alchemyInvokeLease.generation = tonumber(existingLease.generation) or 0
            alchemyInvokeLease.startedAt = tonumber(existingLease.startedAt)
            alchemyInvokeLease.inventoryEpoch = math.max(
                0,
                math.floor(tonumber(existingLease.inventoryEpoch) or 0)
            )
            alchemyInvokeLease.inventoryStageActive =
                existingLease.inventoryStageActive == true
            if alchemyInvokeLease.pending and alchemyInvokeLease.startedAt == nil then
                alchemyInvokeLease.startedAt = os.clock()
            end
        else
            alchemyInvokeLease.inventoryEpoch = 0
            alchemyInvokeLease.inventoryStageActive = false
            sessionEnvironment.__INFINITYGOLD_ALCHEMY_INVOKE = alchemyInvokeLease
        end
    end
    alchemyInvokeLease.inventoryEpoch = math.max(
        0,
        math.floor(tonumber(alchemyInvokeLease.inventoryEpoch) or 0)
    )
    alchemyInvokeLease.inventoryStageActive =
        alchemyInvokeLease.inventoryStageActive == true
    -- Migrate a request handed off by the previous physical-Alchemy build.
    -- Restore only while the same root is still beside that old destination;
    -- never overwrite a newer Broom/respawn position. New Alchemy requests are
    -- remote and never publish a physical travel lease.
    local inheritedAlchemyTravel = type(alchemyInvokeLease.travel) == "table"
        and alchemyInvokeLease.travel
        or nil
    if inheritedAlchemyTravel ~= nil then
        pcall(function()
            local root = inheritedAlchemyTravel.root
            local destination = inheritedAlchemyTravel.destination
            if root ~= nil
                and root.Parent ~= nil
                and inheritedAlchemyTravel.home ~= nil
                and destination ~= nil
                and (root.Position - destination.Position).Magnitude <= 12
            then
                root.CFrame = inheritedAlchemyTravel.home
            end
        end)
    end
    alchemyInvokeLease.travel = nil
    alchemyInvokeLease.holdUntil = nil

    -- Common helpers: loader-supplied module with a minimal local fallback so
    -- a missing download only degrades sorting, never the whole script.
    if type(Common) ~= "table" then
        Common = {
            isEventDrop = function(gold)
                return type(gold) == "number" and gold == 0
            end,
            sortDrops = function(entries)
                local copy = {}
                for index = 1, #entries do copy[index] = entries[index] end
                table.sort(copy, function(left, right)
                    return (left.gold or 0) > (right.gold or 0)
                end)
                return copy
            end,
            gateDrop = function(entry)
                return entry.hasPrimaryPart and entry.landed and entry.inRange
            end,
            farmStageTarget = function(cleared, selected, specific)
                if specific then return math.floor(tonumber(selected) or 1) end
                return math.max((tonumber(cleared) or 0) + 1, math.floor(tonumber(selected) or 1))
            end,
            parseTierSelection = function(values)
                local tiers = {}
                if type(values) == "table" then
                    for key, value in pairs(values) do
                        local selected = type(key) == "number" or value == true
                        local number = tonumber(type(key) == "number" and value or key)
                        if selected and number ~= nil then tiers[math.floor(number)] = true end
                    end
                end
                return tiers
            end,
        }
    end

    local function notify(content, duration)
        pcall(function()
            Library:Notify({
                Title = BRAND,
                Content = tostring(content),
                Duration = duration or 4,
            })
        end)
    end

    notify("starting • building dashboard...", 3)

    -- Options ----------------------------------------------------------------

    local cfg = {
        -- Farm
        AutoFarm = false,
        AutoFarmSpecific = false,
        FarmStage = 1,
        FarmMode = "Ground",
        FarmHeight = 20,
        OrbitRadius = 25,
        OrbitSpeed = 1.5,
        RunningDistance = 12,
        EnterDelay = 0,
        AttackRange = 120,
        AutoReturnFull = true,
        ReturnDelay = 0,
        -- Combat
        AutoAttack = true,
        AutoClick = false,
        ClickRate = 10,
        -- Loot
        AutoPickup = false,
        PickupRange = 150,
        PickupMinValue = 0,
        PickupFilterRarity = false,
        PickupTiers = {},
        AutoSell = false,
        AutoSellSpecific = false,
        SellItems = {},
        -- Progress
        AutoRebirth = false,
        RebirthLimit = 41,
        AutoTrain = false,
        TrainGround = "Best available",
        -- Broom (installed by the locomotion module)
        AutoBroom = false,
        BroomStage = "4",
        BroomReturnDelay = 5,
        -- Alchemy
        AutoBrew = false,
        BrewRecipe = "Best craftable",
        AutoDrinkPotion = false,
        DrinkPotions = {},
        AutoPickupPotion = true,
        -- Rewards
        AutoClaimIndex = false,
        AutoClaimOnline = false,
        -- Gear
        AutoBuyBest = false,
        AutoEquipBest = false,
        AutoBuyWand = false,
        AutoEquipWand = false,
        AutoBuyArmor = false,
        AutoEquipArmor = false,
        -- Utility
        AntiAfk = true,
    }

    local function parsePickupMinimumValue(value)
        local numeric = tonumber(value)
        if numeric == nil
            or numeric ~= numeric
            or numeric == math.huge
            or numeric == -math.huge
        then
            return nil
        end
        return math.max(0, math.floor(numeric))
    end

    local configReady = false

    local registry = {}

    local function bind(name, element)
        registry[name] = element
        return element
    end

    -- Game network -----------------------------------------------------------

    local net = {
        utils = nil,
        clientUtils = nil,
        network = nil,
        messages = nil,
        status = "resolving",
    }

    local function isUtilsRegistry(value)
        local valueType = type(value)
        return valueType == "function"
            or valueType == "table"
            or valueType == "userdata"
    end

    local function requireUtilsSystem(container)
        local function load()
            local allSide = container:WaitForChild("AllSideCode", 8)
            if allSide == nil then return nil end
            local module = allSide:WaitForChild("UtilsSystem", 8)
            if module == nil then return nil end
            return require(module)
        end

        local ok, utils = pcall(load)
        if (not ok or not isUtilsRegistry(utils))
            and type(getthreadidentity) == "function"
            and type(setthreadidentity) == "function"
        then
            local elevatedOk, elevatedUtils = pcall(function()
                local identity = getthreadidentity()
                setthreadidentity(2)
                local loadOk, result = pcall(load)
                setthreadidentity(identity)
                if not loadOk then error(result) end
                return result
            end)
            if elevatedOk then
                ok, utils = true, elevatedUtils
            end
        end
        if ok and isUtilsRegistry(utils) then return utils end
        return nil
    end

    local function readUtilsEntry(utils, name)
        if not isUtilsRegistry(utils) then return nil end

        local function readEntry()
            local utilsType = type(utils)
            if utilsType == "function" then
                return utils(name)
            end

            local direct = utils[name]
            if direct ~= nil then return direct end

            -- Some builds expose a callable table/userdata rather than a
            -- plain lookup table.  Calling it matches UtilsSystem's original
            -- registry contract while retaining compatibility with tables.
            if utilsType == "userdata" then
                return utils(name)
            end
            local metatable = getmetatable(utils)
            if type(metatable) == "table" and type(metatable.__call) == "function" then
                return utils(name)
            end
            return nil
        end

        local ok, candidate = pcall(readEntry)
        if (not ok or candidate == nil)
            and type(getthreadidentity) == "function"
            and type(setthreadidentity) == "function"
        then
            local elevatedOk, elevatedCandidate = pcall(function()
                local identity = getthreadidentity()
                setthreadidentity(2)
                local readOk, result = pcall(readEntry)
                setthreadidentity(identity)
                if not readOk then error(result) end
                return result
            end)
            if elevatedOk then
                ok, candidate = true, elevatedCandidate
            end
        end
        if ok then return candidate end
        return nil
    end

    local function resolveClientUtils()
        if net.clientUtils ~= nil then return net.clientUtils end
        -- The original Magic Loot runtime exposes PlayerData/GetData here.
        local utils = requireUtilsSystem(ReplicatedFirst)
        if utils ~= nil then net.clientUtils = utils end
        return net.clientUtils
    end

    local function resolveNet()
        if net.network ~= nil and net.messages ~= nil then
            return net.network
        end
        -- NetWork can appear a little before NetMsg while the client is
        -- loading. Keep retrying the message registry instead of caching a
        -- permanent half-resolved state.
        local utils = net.utils or resolveClientUtils()
        local network = net.network or readUtilsEntry(utils, "NetWork")
        if network == nil then
            -- Keep a compatibility fallback for game builds that mirror only
            -- the networking facade into ReplicatedStorage.
            utils = requireUtilsSystem(ReplicatedStorage)
            network = readUtilsEntry(utils, "NetWork")
        end
        if not isUtilsRegistry(utils) then
            net.status = "UtilsSystem unavailable"
            return nil
        end
        if type(network) ~= "table" and type(network) ~= "userdata" then
            net.status = "NetWork unavailable"
            return nil
        end
        net.utils = utils
        net.network = network
        -- The action->remote map may live on the facade itself depending on
        -- the game build; try the known shapes before giving up.
        local messages = readUtilsEntry(utils, "NetMsg")
        if messages == nil then
            local embeddedOk, embedded = pcall(function()
                return network.NetMsg
            end)
            if embeddedOk then messages = embedded end
        end
        if messages == nil then
            messages = readUtilsEntry(utils, "Net")
        end
        net.messages = messages
        net.status = messages ~= nil and "ready" or "NetMsg unavailable"
        return network
    end

    local function remoteFor(action)
        local network = resolveNet()
        if network == nil or net.messages == nil then
            net.lastMissedAction = action
            return nil
        end
        local ok, remote = pcall(function()
            return net.messages[action]
        end)
        -- NetMsg entries are opaque descriptors consumed by the NetWork
        -- facade. The observed live network call ultimately receives the
        -- string "训练点屏"; NetMsg itself may expose strings, Instances or
        -- tables depending on the build.
        -- The original client only rejects a missing entry and forwards the
        -- descriptor unchanged.
        if ok and remote ~= nil then
            return remote
        end
        net.lastMissedAction = action
        return nil
    end

    local function sendAction(action, payload)
        local network = resolveNet()
        if network == nil then return false, net.status end
        local remote = remoteFor(action)
        if remote == nil then return false, action .. " remote unavailable" end
        local methodOk, fireServer = pcall(function()
            return network.FireServer
        end)
        if not methodOk or type(fireServer) ~= "function" then
            return false, "NetWork.FireServer unavailable"
        end
        local ok, err
        if payload == nil then
            ok, err = pcall(fireServer, remote)
        else
            ok, err = pcall(fireServer, remote, payload)
        end
        if not ok then return false, tostring(err) end
        return true
    end

    local function invokeAction(action, payload, beforeInvoke)
        local network = resolveNet()
        if network == nil then return false, nil, net.status, false end
        local remote = remoteFor(action)
        if remote == nil then
            return false, nil, action .. " remote unavailable", false
        end
        local methodOk, invokeServer = pcall(function()
            return network.InvokeServer
        end)
        if not methodOk or type(invokeServer) ~= "function" then
            return false, nil, "NetWork.InvokeServer unavailable", false
        end
        if type(beforeInvoke) == "function" then
            local guardOk, allowed, guardError = pcall(beforeInvoke)
            if not guardOk then return false, nil, tostring(allowed), false end
            if allowed ~= true then
                return false, nil, guardError or "request cancelled", false
            end
        end
        local ok, result
        if payload == nil then
            ok, result = pcall(invokeServer, remote)
        else
            ok, result = pcall(invokeServer, remote, payload)
        end
        if not ok then return false, nil, tostring(result), true end
        return true, result, nil, true
    end

    local function fireBindableAction(action, ...)
        local network = resolveNet()
        if network == nil then return false, net.status end
        local remote = remoteFor(action)
        if remote == nil then return false, action .. " bindable unavailable" end
        local methodOk, fireBindable = pcall(function()
            return network.FireBindable
        end)
        if not methodOk or type(fireBindable) ~= "function" then
            return false, "NetWork.FireBindable unavailable"
        end
        local ok, err = pcall(fireBindable, remote, ...)
        if not ok then return false, tostring(err) end
        return true
    end

    -- Player data ------------------------------------------------------------

    local function playerNumber(name)
        local value = player:FindFirstChild(name)
        if value == nil then return nil end
        local ok, number = pcall(function() return tonumber(value.Value) end)
        if ok then return number end
        return nil
    end

    local getData = nil

    local runtimeModules = {}

    local function resolveRuntimeModule(name, refresh)
        if not refresh and runtimeModules[name] ~= nil then
            return runtimeModules[name]
        end
        local utils = resolveClientUtils()
        if utils == nil then return runtimeModules[name] end

        local candidate = readUtilsEntry(utils, name)
        if candidate == nil then return runtimeModules[name] end

        if typeof(candidate) == "Instance" then
            local ok
            ok, candidate = pcall(require, candidate)
            if not ok then return runtimeModules[name] end
        end
        if type(candidate) ~= "table" then return runtimeModules[name] end

        runtimeModules[name] = candidate
        return candidate
    end

    local function resolveGetData(refresh)
        -- UtilsSystem is populated asynchronously on some clients. Cache only
        -- a successful resolution so an early probe cannot disable every
        -- GetData-backed feature for the rest of the session. Catalog scans may
        -- explicitly refresh this reference when a game patch swaps the facade.
        if getData ~= nil and not refresh then return getData end
        getData = resolveRuntimeModule("GetData", refresh) or getData
        return getData
    end

    local function playerBag()
        local playerData = resolveRuntimeModule("PlayerData")
        if playerData == nil then
            return nil, "PlayerData unavailable"
        end
        if type(playerData.GetPlrDataByKey) ~= "function" then
            return nil, "GetPlrDataByKey unavailable"
        end
        local ok, bag = pcall(playerData.GetPlrDataByKey, player, "Bag")
        if ok and type(bag) == "table" then return bag end
        if not ok then return nil, "inventory read failed: " .. tostring(bag) end
        return nil, "Bag data unavailable"
    end

    local function configByName(name)
        -- Query both live facades on every catalog scan. A patch can replace a
        -- registry entry or populate one facade before the other; selecting the
        -- richest normalized result prevents a stale/empty table from hiding
        -- newly released items.
        local best = nil
        local bestCount = -1
        local function consider(result)
            if type(result) ~= "table" then return end
            local count = #Common.catalogEntries(result)
            if count > bestCount then
                best = result
                bestCount = count
            end
        end

        local cfgFind = resolveRuntimeModule("CfgFind", true)
        if cfgFind ~= nil and type(cfgFind.GetCfgByName) == "function" then
            local ok, result = pcall(cfgFind.GetCfgByName, name)
            if ok then consider(result) end
        end

        local data = resolveGetData(true)
        if data ~= nil and type(data.GetCfgByName) == "function" then
            local ok, result = pcall(data.GetCfgByName, name)
            if ok then consider(result) end
        end
        return best
    end

    local function translatedConfigName(raw, id, fallbackPrefix)
        local name = type(raw) == "table"
            and (raw.ZhName or raw.name)
            or nil
        if name ~= nil then
            local translation = resolveRuntimeModule("TranslationHelper")
            if translation ~= nil
                and type(translation.TranslateByKey) == "function"
            then
                local ok, value = pcall(translation.TranslateByKey, name)
                if ok and type(value) == "string" and value ~= "" then
                    name = value
                end
            end
        end
        if type(name) ~= "string" or name == "" then
            name = tostring(fallbackPrefix or "Item") .. " " .. tostring(id)
        end
        return "#" .. tostring(id) .. " " .. name
    end

    local function catalogByName(name, itemType)
        return Common.catalogEntries(configByName(name), itemType)
    end

    local function catalogDropdownValues(name, fallbackPrefix, firstValue)
        local values = {}
        if firstValue ~= nil then table.insert(values, firstValue) end
        for _, entry in ipairs(catalogByName(name)) do
            table.insert(values, translatedConfigName(
                entry.raw,
                entry.id,
                fallbackPrefix
            ))
        end
        return values
    end

    local onlineClaimTelemetry = {
        available = 0,
        attempts = 0,
        claimed = 0,
        lastError = nil,
        status = "waiting",
    }

    local function claimableOnlineAwardIds()
        local playerData = resolveRuntimeModule("PlayerData")
        if playerData == nil or type(playerData.GetPlrDataByKey) ~= "function" then
            return nil, "PlayerData unavailable"
        end

        local onlineOk, onlineBox = pcall(
            playerData.GetPlrDataByKey,
            player,
            "OnlineBox"
        )
        if not onlineOk then
            return nil, "OnlineBox read failed: " .. tostring(onlineBox)
        end
        if type(onlineBox) ~= "table" then
            return nil, "OnlineBox unavailable"
        end

        local cfgFind = resolveRuntimeModule("CfgFind")
        if cfgFind == nil
            or type(cfgFind.GetOnlineAwardList) ~= "function"
            or type(cfgFind.IsOnlineTierClaimable) ~= "function"
        then
            return nil, "online reward config unavailable"
        end

        local listOk, awardList = pcall(cfgFind.GetOnlineAwardList)
        if not listOk or type(awardList) ~= "table" then
            return nil, "online reward list unavailable"
        end

        local ids = {}
        for _, award in ipairs(awardList) do
            if type(award) == "table" then
                local claimOk, claimable = pcall(
                    cfgFind.IsOnlineTierClaimable,
                    onlineBox,
                    award
                )
                local id = math.floor(tonumber(award.id) or 0)
                if claimOk and claimable and id > 0 then
                    table.insert(ids, id)
                end
            end
        end
        return ids
    end

    local function claimOnlineAwards()
        local ids, scanError = claimableOnlineAwardIds()
        if ids == nil then
            onlineClaimTelemetry.available = 0
            onlineClaimTelemetry.lastError = scanError
            onlineClaimTelemetry.status = scanError or "waiting"
            return 0, scanError
        end

        onlineClaimTelemetry.available = #ids
        onlineClaimTelemetry.lastError = nil
        onlineClaimTelemetry.status = #ids > 0 and "claiming" or "waiting"

        local claimed = 0
        for _, awardId in ipairs(ids) do
            if not sessionAlive or not cfg.AutoClaimOnline then break end
            onlineClaimTelemetry.attempts = onlineClaimTelemetry.attempts + 1
            local ok, _, err = invokeAction("CLAIM_ONLINE_AWARD", awardId)
            if ok then
                claimed = claimed + 1
                onlineClaimTelemetry.claimed = onlineClaimTelemetry.claimed + 1
            else
                onlineClaimTelemetry.lastError = err
            end
            task.wait(0.35)
        end

        onlineClaimTelemetry.status = claimed > 0 and "claimed" or "waiting"
        return claimed, onlineClaimTelemetry.lastError
    end

    local indexViewModule = nil

    local function resolveIndexView()
        if indexViewModule ~= nil then return indexViewModule end
        local ok, moduleScript = pcall(function()
            return ReplicatedStorage
                :WaitForChild("ClientSideCode")
                :WaitForChild("GuiScripts")
                :WaitForChild("ModuleScript")
                :WaitForChild("Index")
                :WaitForChild("IndexView")
        end)
        if not ok or moduleScript == nil then return nil end

        local previousIdentity = nil
        if type(getthreadidentity) == "function" then
            pcall(function() previousIdentity = getthreadidentity() end)
        end
        if type(setthreadidentity) == "function" then
            pcall(setthreadidentity, 2)
        end
        local requireOk, result = pcall(require, moduleScript)
        if previousIdentity ~= nil and type(setthreadidentity) == "function" then
            pcall(setthreadidentity, previousIdentity)
        end
        if requireOk and type(result) == "table" then
            indexViewModule = result
            return result
        end
        return nil
    end

    local function claimIndexRewards()
        local indexData = resolveRuntimeModule("Index")
        local indexView = resolveIndexView()
        if indexData == nil
            or indexView == nil
            or type(indexView.buildAllTabSnapshots) ~= "function"
        then
            return 0, "IndexView snapshot API unavailable"
        end

        local ok, snapshots = pcall(
            indexView.buildAllTabSnapshots,
            indexData
        )
        if not ok or type(snapshots) ~= "table" then
            return 0, "index snapshot failed"
        end

        local claimed = 0
        for tag, snapshot in pairs(snapshots) do
            if not sessionAlive or not cfg.AutoClaimIndex then break end
            if type(snapshot) == "table"
                and snapshot.canClaim == true
                and snapshot.targetProgress ~= nil
            then
                local sent = invokeAction("INDEX_CLAIM_REWARD", {
                    tag = tag,
                    progress = snapshot.targetProgress,
                })
                if sent then claimed += 1 end
                task.wait(0.3)
            end
        end
        return claimed
    end

    local function isProtectedAlchemyMaterial(itemId)
        local data = resolveGetData()
        if data == nil
            or type(data.Alchemy) ~= "table"
            or type(data.Alchemy.IsMarkedRecipeMaterial) ~= "function"
        then
            return false
        end
        local ok, marked = pcall(data.Alchemy.IsMarkedRecipeMaterial, player, itemId)
        return ok and marked == true
    end

    local sellTelemetry = {
        status = "waiting",
        challenge = nil,
        brewInProgress = nil,
        authorization = nil,
        attempts = 0,
        requests = 0,
        requestedItems = 0,
        lastCount = 0,
        lastError = nil,
    }

    local function autoSellEnabled()
        return cfg.AutoSell == true or cfg.AutoSellSpecific == true
    end

    local function automaticSellSelection()
        if cfg.AutoSell == true then return nil end
        return Common.parseIdSelection(cfg.SellItems)
    end

    local function sellAllMaterials(selectedIds, beforeSend)
        local bag, bagError = playerBag()
        if bag == nil then return false, 0, bagError or "inventory unavailable" end
        local ok, onlyIds = pcall(
            Common.sellOnlyIds,
            bag,
            selectedIds,
            isProtectedAlchemyMaterial
        )
        if not ok or type(onlyIds) ~= "table" then
            return false, 0, "inventory scan failed"
        end
        if #onlyIds == 0 then return false, 0, "nothing to sell" end

        -- invokeAction runs this optional guard only after resolving NetWork
        -- and NetMsg, immediately adjacent to InvokeServer. Sell All Now omits
        -- it intentionally and remains a manual override.
        local sent, _, err = invokeAction(
            "SELL_MATERIAL",
            { onlyIDList = onlyIds },
            beforeSend
        )
        return sent, #onlyIds, err
    end

    local function playerGold()
        local direct = playerNumber("Gold")
        if direct ~= nil then return direct end
        local data = resolveGetData()
        if data ~= nil and type(data.GetPlrDataByKey) == "function" then
            local ok, value = pcall(data.GetPlrDataByKey, "Gold")
            if ok then return tonumber(value) end
        end
        return nil
    end

    -- The original Magic Loot client does not expose the bag limit through a
    -- guessed LimitBagMax value. It asks GetData for item/count id 5 and then
    -- compares that result with LocalPlayer.LimitBagUsed.
    local BAG_CAPACITY_ITEM_ID = 5
    local bagCapacityNames = { "LimitBagMax", "LimitBagCapacity", "LimitBagCount" }
    local bagTelemetry = {
        used = nil,
        capacity = nil,
        source = "waiting",
        known = false,
        full = false,
        checkedAt = 0,
    }

    local function bagCapacity()
        local data = resolveGetData()
        if data ~= nil and type(data.GetItemCountByID) == "function" then
            local ok, value = pcall(
                data.GetItemCountByID,
                player,
                BAG_CAPACITY_ITEM_ID
            )
            value = ok and tonumber(value) or nil
            if value ~= nil and value > 0 then
                return value, "GetItemCountByID(5)"
            end
        end

        -- Compatibility fallbacks for builds that mirror the limit directly
        -- on the player. They are deliberately secondary to the proven game
        -- contract above.
        for _, name in ipairs(bagCapacityNames) do
            local value = playerNumber(name)
            if value ~= nil and value > 0 then return value, name end
        end
        if data ~= nil and type(data.GetPlrDataByKey) == "function" then
            for _, key in ipairs({ "LimitBagMax", "LimitBagCapacity" }) do
                local ok, value = pcall(data.GetPlrDataByKey, player, key)
                if ok and tonumber(value) ~= nil and tonumber(value) > 0 then
                    return tonumber(value), "GetPlrDataByKey(" .. key .. ")"
                end
            end
        end
        return nil, "unavailable"
    end

    local function bagFull()
        local used = playerNumber("LimitBagUsed")
        if used ~= nil then used = math.floor(used) end
        local capacity, source = bagCapacity()
        bagTelemetry.used = used
        bagTelemetry.capacity = capacity
        bagTelemetry.source = source
        bagTelemetry.known = used ~= nil and capacity ~= nil and capacity > 0
        bagTelemetry.full = bagTelemetry.known and used >= capacity or false
        bagTelemetry.checkedAt = os.clock()
        if used == nil or capacity == nil or capacity <= 0 then
            return false, false, used, capacity, source
        end
        return used >= capacity, true, used, capacity, source
    end

    -- Stages -----------------------------------------------------------------

    local stagePartCache = {}

    local function stageModel(stage)
        local scenes = workspace:FindFirstChild("场景")
        if scenes == nil then return nil end
        return scenes:FindFirstChild(tostring(stage))
    end

    local function stagePart(stage)
        local cached = stagePartCache[stage]
        if cached ~= nil and cached.Parent ~= nil then
            return cached
        end
        stagePartCache[stage] = nil
        local model = stageModel(stage)
        if model == nil then return nil end
        local ok, part = pcall(function()
            return model:FindFirstChild("战斗区域", true)
        end)
        if ok and part ~= nil and part:IsA("BasePart") then
            stagePartCache[stage] = part
            return part
        end
        return nil
    end

    local function groundPoint(part)
        return part.Position
            - Vector3.new(0, part.Size.Y * 0.5, 0)
            + Vector3.new(0, 3, 0)
    end

    local function isOverFootprint(part, point)
        local localPoint = part.CFrame:PointToObjectSpace(point)
        return math.abs(localPoint.X) <= part.Size.X * 0.5
            and math.abs(localPoint.Y) <= part.Size.Y * 0.5
            and math.abs(localPoint.Z) <= part.Size.Z * 0.5
    end

    -- Character --------------------------------------------------------------

    local function characterParts()
        local character = player.Character
        if character == nil then return nil end
        local root = character:FindFirstChild("HumanoidRootPart")
        local humanoid = character:FindFirstChildOfClass("Humanoid")
        if root == nil or humanoid == nil or humanoid.Health <= 0 then
            return nil
        end
        return { character = character, root = root, humanoid = humanoid }
    end

    -- Alchemy ---------------------------------------------------------------

    local alchemyReturnPending = function() return false end
    local alchemyTelemetry = {
        status = "waiting",
        recipes = 0,
        selected = nil,
        craftAttempts = 0,
        pickupAttempts = 0,
        lastError = nil,
        canUse = nil,
        inProgress = nil,
        ready = nil,
        checkTotal = 0,
        rebirthPassed = 0,
        materialChecks = 0,
        craftable = 0,
        predicateErrors = 0,
        chosenId = nil,
        remoteResult = nil,
        travel = "idle",
        confirmed = false,
        confirmedAction = nil,
        stageCandidateId = nil,
        temporaryBagUsed = nil,
        transferStatus = "idle",
    }
    local alchemyRecovery = {
        key = nil,
        candidateIds = {},
        cursor = 1,
        nextAttemptAt = 0,
    }
    local alchemyPickupNextAttemptAt = 0
    local alchemyBaseSyncUntil = 0
    local ALCHEMY_BASE_SYNC_SECONDS = 0.35
    local ALCHEMY_STAGE_RESCAN_SECONDS = 0.8
    local ALCHEMY_STAGE_RESCAN_INTERVAL = 0.1
    local ALCHEMY_STAGE_IDLE_SCAN_INTERVAL = 0.5
    local ALCHEMY_TRANSFER_SETTLE_SECONDS = 0.2
    local ALCHEMY_TRANSFER_TIMEOUT_SECONDS = 3
    local alchemyBagFingerprint = function()
        return nil, "Bag fingerprint unavailable"
    end
    local inheritedTransfer = type(alchemyInvokeLease.inventoryTransfer) == "table"
        and alchemyInvokeLease.inventoryTransfer
        or nil
    local alchemyInventoryTransfer = {
        epoch = inheritedTransfer ~= nil
            and math.floor(tonumber(inheritedTransfer.epoch) or -1)
            or -1,
        baselineFingerprint = inheritedTransfer ~= nil
            and inheritedTransfer.baselineFingerprint
            or nil,
        lastFingerprint = inheritedTransfer ~= nil
            and inheritedTransfer.lastFingerprint
            or nil,
        pending = inheritedTransfer ~= nil and inheritedTransfer.pending == true,
        changed = inheritedTransfer ~= nil and inheritedTransfer.changed == true,
        permanentChanged = inheritedTransfer ~= nil
            and inheritedTransfer.permanentChanged == true,
        refreshed = inheritedTransfer ~= nil and inheritedTransfer.refreshed == true,
        stableSince = inheritedTransfer ~= nil
            and tonumber(inheritedTransfer.stableSince) or 0,
        deadline = inheritedTransfer ~= nil
            and tonumber(inheritedTransfer.deadline) or 0,
    }
    local inheritedStageCandidate = type(alchemyInvokeLease.stageCandidate) == "table"
        and alchemyInvokeLease.stageCandidate
        or nil
    local inheritedStageEpoch = inheritedStageCandidate ~= nil
        and math.floor(tonumber(inheritedStageCandidate.epoch) or -1)
        or -1
    local inheritedStageRecipeId = inheritedStageCandidate ~= nil
        and math.floor(tonumber(inheritedStageCandidate.recipeId) or 0)
        or 0
    local inheritedStageFingerprint = inheritedStageCandidate ~= nil
        and inheritedStageCandidate.bagFingerprint
        or nil
    local inheritedStageFresh = inheritedStageEpoch == alchemyInvokeLease.inventoryEpoch
        and inheritedStageRecipeId > 0
        and type(inheritedStageFingerprint) == "string"
    local alchemyStageCandidate = {
        epoch = inheritedStageFresh and inheritedStageEpoch or -1,
        recipeId = inheritedStageFresh and inheritedStageRecipeId or nil,
        bagFingerprint = inheritedStageFresh and inheritedStageFingerprint or nil,
        candidateFresh = inheritedStageFresh,
        nextScanAt = 0,
        rescanUntil = 0,
    }
    if inheritedStageFresh then
        alchemyTelemetry.stageCandidateId = inheritedStageRecipeId
    else
        alchemyInvokeLease.stageCandidate = nil
    end

    local function resetAlchemyRecovery()
        alchemyRecovery.key = nil
        alchemyRecovery.candidateIds = {}
        alchemyRecovery.cursor = 1
        alchemyRecovery.nextAttemptAt = 0
    end

    local function clearAlchemyStageCandidate(epoch)
        alchemyStageCandidate.epoch = tonumber(epoch) or -1
        alchemyStageCandidate.recipeId = nil
        alchemyStageCandidate.bagFingerprint = nil
        alchemyStageCandidate.candidateFresh = false
        alchemyStageCandidate.nextScanAt = 0
        alchemyStageCandidate.rescanUntil = 0
        alchemyTelemetry.stageCandidateId = nil
        alchemyInvokeLease.stageCandidate = nil
    end

    local function publishAlchemyStageCandidate()
        if not alchemyStageCandidate.candidateFresh
            or alchemyStageCandidate.recipeId == nil
            or type(alchemyStageCandidate.bagFingerprint) ~= "string"
        then
            alchemyInvokeLease.stageCandidate = nil
            return
        end
        alchemyInvokeLease.stageCandidate = {
            epoch = alchemyStageCandidate.epoch,
            recipeId = alchemyStageCandidate.recipeId,
            bagFingerprint = alchemyStageCandidate.bagFingerprint,
        }
    end

    local function publishAlchemyInventoryTransfer()
        if alchemyInventoryTransfer.epoch < 0 then
            alchemyInvokeLease.inventoryTransfer = nil
            return
        end
        alchemyInvokeLease.inventoryTransfer = {
            epoch = alchemyInventoryTransfer.epoch,
            baselineFingerprint = alchemyInventoryTransfer.baselineFingerprint,
            lastFingerprint = alchemyInventoryTransfer.lastFingerprint,
            pending = alchemyInventoryTransfer.pending,
            changed = alchemyInventoryTransfer.changed,
            permanentChanged = alchemyInventoryTransfer.permanentChanged,
            refreshed = alchemyInventoryTransfer.refreshed,
            stableSince = alchemyInventoryTransfer.stableSince,
            deadline = alchemyInventoryTransfer.deadline,
        }
    end

    local function finishAlchemyInventoryTransfer(status)
        alchemyInventoryTransfer.pending = false
        alchemyInventoryTransfer.deadline = 0
        alchemyTelemetry.transferStatus = status
        publishAlchemyInventoryTransfer()
    end

    local function alchemyInventoryTransferPending()
        return alchemyInventoryTransfer.pending == true
    end

    local function observeAlchemyLocation(challenge)
        local now = os.clock()
        if challenge > 0 then
            if not alchemyInvokeLease.inventoryStageActive then
                alchemyInvokeLease.inventoryEpoch += 1
                alchemyInvokeLease.inventoryStageActive = true
                clearAlchemyStageCandidate(alchemyInvokeLease.inventoryEpoch)
                local fingerprint = alchemyBagFingerprint()
                alchemyInventoryTransfer.epoch = alchemyInvokeLease.inventoryEpoch
                alchemyInventoryTransfer.baselineFingerprint = fingerprint
                alchemyInventoryTransfer.lastFingerprint = fingerprint
                alchemyInventoryTransfer.pending = false
                alchemyInventoryTransfer.changed = false
                alchemyInventoryTransfer.permanentChanged = false
                alchemyInventoryTransfer.refreshed = false
                alchemyInventoryTransfer.stableSince = now
                alchemyInventoryTransfer.deadline = 0
                alchemyTelemetry.transferStatus = "temporary bag collecting"
                publishAlchemyInventoryTransfer()
            end
            alchemyTelemetry.temporaryBagUsed = playerNumber("LimitBagUsed")
            return
        end
        if alchemyInvokeLease.inventoryStageActive then
            -- Dungeon drops live in the small temporary LimitBag. Only after
            -- returning do they move into PlayerData.Bag (the visible 999-slot
            -- inventory used by CanCraftRecipe). Reserve this base window until
            -- the permanent material fingerprint changes and settles.
            local fingerprint = alchemyBagFingerprint()
            local temporaryUsed = playerNumber("LimitBagUsed")
            alchemyTelemetry.temporaryBagUsed = temporaryUsed
            alchemyInventoryTransfer.epoch = alchemyInvokeLease.inventoryEpoch
            alchemyInventoryTransfer.lastFingerprint = fingerprint
            alchemyInventoryTransfer.permanentChanged = fingerprint ~= nil
                and alchemyInventoryTransfer.baselineFingerprint ~= nil
                and fingerprint ~= alchemyInventoryTransfer.baselineFingerprint
            alchemyInventoryTransfer.changed = alchemyInventoryTransfer.permanentChanged
            if temporaryUsed ~= nil and temporaryUsed <= 0 then
                -- The temporary bag clearing is the game's direct handoff
                -- signal. Start the local Best scan in this same base tick;
                -- if PlayerData lags, subsequent 0.1 s polls re-evaluate it.
                alchemyInventoryTransfer.changed = true
            end
            alchemyInventoryTransfer.stableSince = now
            alchemyInventoryTransfer.deadline = now
                + ALCHEMY_TRANSFER_TIMEOUT_SECONDS
            alchemyInventoryTransfer.pending = configReady
                and (cfg.AutoBrew or autoSellEnabled())
            alchemyInventoryTransfer.refreshed = false
            alchemyTelemetry.transferStatus = alchemyInventoryTransfer.pending
                and "waiting for temporary bag transfer"
                or "transfer wait not required"
            alchemyBaseSyncUntil = math.max(
                alchemyBaseSyncUntil,
                now + ALCHEMY_BASE_SYNC_SECONDS
            )
            publishAlchemyInventoryTransfer()
        end
        alchemyInvokeLease.inventoryStageActive = false

        if not alchemyInventoryTransfer.pending then return end
        if not configReady or (not cfg.AutoBrew and not autoSellEnabled()) then
            finishAlchemyInventoryTransfer("transfer wait cancelled")
            return
        end
        local fingerprint, fingerprintError = alchemyBagFingerprint()
        if fingerprint ~= nil then
            if fingerprint ~= alchemyInventoryTransfer.lastFingerprint then
                alchemyInventoryTransfer.lastFingerprint = fingerprint
                alchemyInventoryTransfer.stableSince = now
                alchemyInventoryTransfer.changed = true
                alchemyInventoryTransfer.permanentChanged = true
                resetAlchemyRecovery()
                clearAlchemyStageCandidate(alchemyInvokeLease.inventoryEpoch)
            end
            local stable = alchemyInventoryTransfer.permanentChanged
                and now - alchemyInventoryTransfer.stableSince
                    >= ALCHEMY_TRANSFER_SETTLE_SECONDS
            if stable then
                alchemyBaseSyncUntil = 0
                finishAlchemyInventoryTransfer("permanent bag synchronized")
                return
            end
        else
            alchemyTelemetry.lastError = fingerprintError
        end
        if now >= alchemyInventoryTransfer.deadline then
            -- Never strand Broom/farming at base if the transfer exposes no
            -- tp=2 delta (for example a trip that collected no ingredients).
            finishAlchemyInventoryTransfer("transfer wait timed out")
            return
        end
        alchemyTelemetry.transferStatus = "waiting for temporary bag transfer"
        publishAlchemyInventoryTransfer()
    end

    local function resolveAlchemy()
        local data = resolveGetData()
        local alchemy = data and data.Alchemy
        if type(alchemy) ~= "table" then
            return nil, "GetData.Alchemy unavailable"
        end
        return alchemy
    end

    local function rawAlchemyRecipes(alchemy)
        -- GetRecipeList is the Alchemy-owned recipe source used by the game.
        -- potionConf contains potion item definitions, not the raw recipe
        -- objects expected by CanCraftRecipe/CanMeetRecipeRebirth.
        if type(alchemy.GetRecipeList) ~= "function" then
            return nil, "Alchemy.GetRecipeList unavailable"
        end
        local ok, recipes = pcall(alchemy.GetRecipeList)
        if not ok then return nil, "recipe list failed: " .. tostring(recipes) end
        if type(recipes) ~= "table" then
            return nil, "Alchemy.GetRecipeList returned " .. type(recipes)
        end
        return recipes
    end

    local function isAsciiText(value)
        if type(value) ~= "string" then return false end
        for index = 1, #value do
            if string.byte(value, index) > 127 then return false end
        end
        return true
    end

    local function translatedAlchemyRecipeName(raw, id, potionId)
        local translationKey = nil
        local cfgFind = resolveRuntimeModule("CfgFind")
        if potionId > 0
            and cfgFind ~= nil
            and type(cfgFind.FindCfgByID) == "function"
        then
            -- 9 is the game's potion config type. The recipe list itself still
            -- comes exclusively from Alchemy.GetRecipeList().
            local cfgOk, potion = pcall(cfgFind.FindCfgByID, potionId, 9)
            if cfgOk and type(potion) == "table" then
                translationKey = potion.ZhName
            end
        end

        local function translate(key)
            if type(key) ~= "string" or key == "" then return nil end
            local helper = resolveRuntimeModule("TranslationHelper")
            if helper ~= nil and type(helper.TranslateByKey) == "function" then
                local ok, translated = pcall(helper.TranslateByKey, key)
                if ok and type(translated) == "string" and translated ~= "" then
                    -- A not-yet-ready translator often echoes the Chinese key.
                    -- Keep the neutral fallback until it can provide the same
                    -- localized name shown by the game.
                    if translated ~= key or isAsciiText(translated) then
                        return translated
                    end
                end
            end
            if isAsciiText(key) then return key end
            return nil
        end

        local translated = translate(translationKey)
        if translated ~= nil then return translated end

        local directName = raw.Name or raw.name
        if type(directName) == "string" and directName ~= "" and isAsciiText(directName) then
            return directName
        end
        translated = translate(raw.ZhName)
        return translated or ("Recipe " .. tostring(id))
    end

    local function alchemyRecipeCatalog(alchemy)
        local rawRecipes, err = rawAlchemyRecipes(alchemy)
        if rawRecipes == nil then return nil, err end

        local catalog = {}
        for _, raw in pairs(rawRecipes) do
            if type(raw) == "table" then
                local id = math.floor(tonumber(raw.recipeId) or 0)
                if id > 0 then
                    local potionId = math.floor(tonumber(raw.PID) or 0)
                    local name = translatedAlchemyRecipeName(raw, id, potionId)
                    table.insert(catalog, {
                        id = id,
                        potionId = potionId,
                        rebirth = math.floor(tonumber(raw.Rebirth) or 0),
                        label = string.format("#%d %s", id, name),
                        recipe = raw,
                    })
                end
            end
        end
        table.sort(catalog, function(a, b) return a.id < b.id end)
        alchemyTelemetry.recipes = #catalog
        if #catalog == 0 then return nil, "no alchemy recipes found" end
        return catalog
    end

    local function isAlchemyRecipeCraftable(alchemy, recipe)
        if type(alchemy.CanCraftRecipe) ~= "function" then
            return false, "alchemy recipe checks unavailable", "api"
        end
        local rebirthOk, meetsRebirth = false, nil
        if type(alchemy.CanMeetRecipeRebirth) == "function" then
            rebirthOk, meetsRebirth = pcall(
                alchemy.CanMeetRecipeRebirth,
                player,
                recipe.recipe
            )
        end
        -- Always ask the material predicate. In live builds the rebirth facade
        -- can be stale even though the manually selected recipe is accepted by
        -- the server; short-circuiting here made Best silently do nothing.
        local craftOk, canCraft = pcall(alchemy.CanCraftRecipe, player, recipe.recipe)
        if not craftOk then return false, tostring(canCraft), "materials-error" end
        if not canCraft then
            if not rebirthOk then
                return false, tostring(meetsRebirth), "materials-rebirth-error"
            end
            return false, nil, meetsRebirth and "materials" or "materials-rebirth"
        end
        if not rebirthOk then
            return true, tostring(meetsRebirth), "craftable-rebirth-error"
        end
        if not meetsRebirth then
            return true, nil, "craftable-rebirth-advisory"
        end
        return true, nil, "craftable"
    end

    alchemyBagFingerprint = function()
        local bag, bagError = playerBag()
        if bag == nil then return nil, bagError end
        local rows = {}
        for key, item in pairs(bag) do
            -- Alchemy ingredients are the Bag's tp=2 material entries. A
            -- finished-potion pickup can add a potion/equipment row while the
            -- ingredients are unchanged; including those rows would discard
            -- the recipe proven during the stage immediately before brewing.
            if type(item) == "table" and tonumber(item.tp) == 2 then
                local id = math.floor(tonumber(item.id) or 0)
                local onlyId = tostring(item.onlyID or key)
                local amount = tonumber(
                    item.count
                    or item.Count
                    or item.amount
                    or item.Amount
                    or item.num
                    or item.Num
                    or item.stack
                    or item.Stack
                ) or 1
                table.insert(rows, table.concat({
                    tostring(id),
                    onlyId,
                    tostring(amount),
                    tostring(item.tp or ""),
                    tostring(item.lock or ""),
                }, ":"))
            end
        end
        table.sort(rows)
        return table.concat(rows, "|")
    end

    local function bestAlchemyRecipeIdFromLocalState(alchemy)
        local rawRecipes, recipeError = rawAlchemyRecipes(alchemy)
        if rawRecipes == nil then return nil, recipeError end
        local bestId = nil
        local advisoryId = nil
        for _, raw in pairs(rawRecipes) do
            if type(raw) == "table" then
                local id = math.floor(tonumber(raw.recipeId) or 0)
                if id > 0 then
                    local craftable, _, reason = isAlchemyRecipeCraftable(alchemy, {
                        id = id,
                        recipe = raw,
                    })
                    if craftable then
                        if reason == "craftable" then
                            if bestId == nil or id > bestId then bestId = id end
                        elseif advisoryId == nil or id > advisoryId then
                            advisoryId = id
                        end
                    end
                end
            end
        end
        return bestId or advisoryId
    end

    local function updateStageAlchemyCandidate(alchemy)
        local epoch = alchemyInvokeLease.inventoryEpoch
        if alchemyStageCandidate.epoch ~= epoch then
            clearAlchemyStageCandidate(epoch)
        end

        local now = os.clock()
        local fingerprint = alchemyBagFingerprint()
        if fingerprint ~= nil
            and fingerprint ~= alchemyStageCandidate.bagFingerprint
        then
            -- A pickup changes Bag before every dependent local cache is
            -- guaranteed to update. Invalidate the old answer, then rescan for
            -- a short window even if Bag itself stops changing.
            alchemyStageCandidate.bagFingerprint = fingerprint
            alchemyStageCandidate.candidateFresh = false
            alchemyTelemetry.stageCandidateId = nil
            publishAlchemyStageCandidate()
            alchemyStageCandidate.nextScanAt = now + ALCHEMY_STAGE_RESCAN_INTERVAL
            alchemyStageCandidate.rescanUntil = now + ALCHEMY_STAGE_RESCAN_SECONDS
            return nil
        end
        if now < alchemyStageCandidate.nextScanAt then
            return alchemyStageCandidate.candidateFresh
                and alchemyStageCandidate.recipeId
                or nil
        end

        local bestId = bestAlchemyRecipeIdFromLocalState(alchemy)
        if bestId ~= nil then
            if not alchemyStageCandidate.candidateFresh
                or alchemyStageCandidate.recipeId == nil
                or bestId > alchemyStageCandidate.recipeId
            then
                alchemyStageCandidate.recipeId = bestId
            end
            -- A transient false from the same unchanged Bag must not erase a
            -- recipe already proven true. Only an epoch/fingerprint/config
            -- change invalidates that evidence.
            alchemyStageCandidate.candidateFresh = true
            alchemyTelemetry.stageCandidateId = alchemyStageCandidate.recipeId
            publishAlchemyStageCandidate()
        end
        alchemyStageCandidate.nextScanAt = now + (
            now < alchemyStageCandidate.rescanUntil
                and ALCHEMY_STAGE_RESCAN_INTERVAL
                or ALCHEMY_STAGE_IDLE_SCAN_INTERVAL
        )
        return alchemyStageCandidate.candidateFresh
            and alchemyStageCandidate.recipeId
            or nil
    end

    local function cachedStageAlchemyRecipeId(alchemy)
        if cfg.BrewRecipe ~= "Best craftable" then return nil end
        if alchemyStageCandidate.epoch ~= alchemyInvokeLease.inventoryEpoch
            or not alchemyStageCandidate.candidateFresh
        then
            return nil
        end
        local currentFingerprint = alchemyBagFingerprint()
        if currentFingerprint == nil
            or currentFingerprint ~= alchemyStageCandidate.bagFingerprint
        then
            -- A last pickup can land between the final stage poll and the
            -- challenge transition. Never apply an older recipe to a newer
            -- Bag; let the normal base rescan handle that snapshot instead.
            alchemyStageCandidate.candidateFresh = false
            alchemyTelemetry.stageCandidateId = nil
            publishAlchemyStageCandidate()
            return nil
        end
        local currentBestId = bestAlchemyRecipeIdFromLocalState(alchemy)
        if currentBestId ~= nil
            and (alchemyStageCandidate.recipeId == nil
                or currentBestId > alchemyStageCandidate.recipeId)
        then
            -- Upgrade from fresh evidence, but never let a stale false at base
            -- erase the recipe already proven while collecting.
            alchemyStageCandidate.recipeId = currentBestId
            alchemyTelemetry.stageCandidateId = currentBestId
            publishAlchemyStageCandidate()
        end
        return alchemyStageCandidate.recipeId
    end

    local function noteAlchemyRecipeCheck(reason)
        if reason == "craftable" or reason == "materials" then
            alchemyTelemetry.rebirthPassed += 1
        end
        if reason ~= "api" then alchemyTelemetry.materialChecks += 1 end
        if reason == "craftable"
            or reason == "craftable-rebirth-advisory"
            or reason == "craftable-rebirth-error"
        then
            alchemyTelemetry.craftable += 1
        end
        if reason == "craftable-rebirth-error"
            or reason == "materials-rebirth-error"
            or reason == "materials-error"
            or reason == "api"
        then
            alchemyTelemetry.predicateErrors += 1
        end
    end

    local function selectAlchemyRecipe(alchemy, selection, stagedRecipeId)
        selection = tostring(selection or "Best craftable")
        local recoveryPrefix = "magic-best-v1|" .. selection .. "|"

        local catalog, err = alchemyRecipeCatalog(alchemy)
        if catalog == nil then return nil, err end

        alchemyTelemetry.checkTotal = #catalog
        alchemyTelemetry.rebirthPassed = 0
        alchemyTelemetry.materialChecks = 0
        alchemyTelemetry.craftable = 0
        alchemyTelemetry.predicateErrors = 0
        alchemyTelemetry.chosenId = nil
        local candidateById = {}
        local membershipIds = {}
        local prioritizedIds = {}
        if selection == "Best craftable" then
            -- Match Magic's original selector exactly: scan the ascending
            -- catalog, remember the last recipe whose two local predicates are
            -- true, and send only that id. Do not freeze an early false snapshot
            -- or walk server candidates; those retries were the source of the
            -- multi-minute delay after returning from a dungeon.
            local best = nil
            local advisoryBest = nil
            stagedRecipeId = math.floor(tonumber(stagedRecipeId) or 0)
            if stagedRecipeId > 0 then
                for _, recipe in ipairs(catalog) do
                    if recipe.id == stagedRecipeId then
                        best = recipe
                        break
                    end
                end
            end
            if best == nil then
                for _, recipe in ipairs(catalog) do
                    local craftable, _, reason = isAlchemyRecipeCraftable(
                        alchemy,
                        recipe
                    )
                    noteAlchemyRecipeCheck(reason)
                    if craftable then
                        if reason == "craftable" then
                            best = recipe
                        else
                            advisoryBest = recipe
                        end
                    end
                end
            end
            best = best or advisoryBest
            if best ~= nil then
                candidateById[best.id] = best
                table.insert(membershipIds, best.id)
                table.insert(prioritizedIds, best.id)
            end
        else
            local selectedId = math.floor(tonumber(selection) or 0)
            if selectedId <= 0 then
                selectedId = math.floor(tonumber(string.match(selection, "^#(%d+)")) or 0)
            end
            for _, recipe in ipairs(catalog) do
                if selection == recipe.label or selectedId == recipe.id then
                    local _, _, reason = isAlchemyRecipeCraftable(alchemy, recipe)
                    noteAlchemyRecipeCheck(reason)
                    candidateById[recipe.id] = recipe
                    table.insert(membershipIds, recipe.id)
                    table.insert(prioritizedIds, recipe.id)
                    break
                end
            end
        end

        if #membershipIds == 0 then
            if selection == "Best craftable" then resetAlchemyRecovery() end
            return nil, selection == "Best craftable"
                and "waiting for the game to report a craftable recipe"
                or "selected recipe is unavailable"
        end

        -- A changed local Best is new inventory evidence. Give it a fresh
        -- request immediately instead of preserving the cooldown/order of a
        -- different recipe selected from an older Bag snapshot.
        local recoveryKey = recoveryPrefix .. table.concat(membershipIds, ",")
        if alchemyRecovery.key ~= recoveryKey then
            alchemyRecovery.key = recoveryKey
            alchemyRecovery.candidateIds = {}
            for _, id in ipairs(prioritizedIds) do
                table.insert(alchemyRecovery.candidateIds, id)
            end
            alchemyRecovery.cursor = 1
            alchemyRecovery.nextAttemptAt = 0
        end
        if os.clock() < alchemyRecovery.nextAttemptAt then
            return nil, "waiting before the next server-validated recipe", "cooldown"
        end

        if alchemyRecovery.cursor > #alchemyRecovery.candidateIds then
            alchemyRecovery.cursor = 1
        end
        local candidateId = alchemyRecovery.candidateIds[alchemyRecovery.cursor]
        local candidate = candidateById[candidateId]
        if candidate == nil then
            resetAlchemyRecovery()
            return nil, "recipe candidate changed; retrying"
        end
        alchemyTelemetry.chosenId = candidate.id
        return candidate
    end

    local function finishAlchemyRecipeAttempt(confirmed)
        if confirmed then
            -- Materials changed after a successful craft. Rebuild local
            -- priorities before choosing the next potion.
            resetAlchemyRecovery()
            if alchemyInventoryTransferPending() then
                finishAlchemyInventoryTransfer("brew started after bag transfer")
            end
            return
        end
        local count = #alchemyRecovery.candidateIds
        local delay = cfg.BrewRecipe == "Best craftable" and 2 or 8
        if count > 1 then
            local nextCursor = (alchemyRecovery.cursor % count) + 1
            alchemyRecovery.cursor = nextCursor
            delay = nextCursor == 1 and 15 or 4
        end
        -- Keep a conservative delay after every rejected or ambiguous request.
        -- Explicit recipes retry the same id; Best advances one candidate and
        -- applies a longer delay when a full round wraps.
        alchemyRecovery.nextAttemptAt = os.clock() + delay
    end

    local function alchemyDropdownValues()
        local values = { "Best craftable" }
        local alchemy = resolveAlchemy()
        if alchemy == nil then return values end
        local catalog = alchemyRecipeCatalog(alchemy)
        if catalog == nil then return values end
        for _, recipe in ipairs(catalog) do
            table.insert(values, recipe.label)
        end
        return values
    end

    local function alchemyState(alchemy, methodName)
        local method = alchemy[methodName]
        if type(method) ~= "function" then
            return nil, methodName .. " unavailable"
        end
        local ok, value = pcall(method, player)
        if not ok then return nil, tostring(value) end
        if value == nil then return nil, methodName .. " returned nil" end
        return not not value
    end

    local function waitForAlchemyConfirmation(alchemy, kind, initialReady)
        -- A successful pcall is merely transport, not proof that the server
        -- accepted the remote action. Confirm it from replicated game state.
        for attempt = 1, 10 do
            if not sessionAlive then return false, "alchemy session closed" end
            if kind == "brew" and not cfg.AutoBrew then
                return false, "brew cancelled"
            end
            if kind == "pickup" and not cfg.AutoPickupPotion then
                return false, "pickup cancelled"
            end
            if kind == "brew" then
                local brewing = alchemyState(alchemy, "IsBrewInProgress")
                if brewing ~= nil then alchemyTelemetry.inProgress = brewing end
                if brewing == true then return true, "brewing" end
                local ready = alchemyState(alchemy, "IsBrewReadyForPickup")
                if ready ~= nil then alchemyTelemetry.ready = ready end
                if initialReady == false and ready == true then return true, "ready" end
            else
                local ready = alchemyState(alchemy, "IsBrewReadyForPickup")
                if ready ~= nil then alchemyTelemetry.ready = ready end
                if initialReady == true and ready == false then return true, "picked up" end
            end
            if attempt < 10 then task.wait(0.25) end
        end
        return false, kind .. " was not confirmed by game state"
    end

    local function alchemyResponseRejected(response)
        if response == false then return true, "server returned false" end
        if type(response) ~= "table" then return false end
        for _, key in ipairs({ "success", "Success", "ok", "accepted", "result" }) do
            if response[key] == false then
                local detail = response.error or response.Error or response.message
                return true, detail ~= nil and tostring(detail) or (key .. " was false")
            end
        end
        return false
    end

    local function alchemyRequestDidNotStart(err, didInvoke)
        return didInvoke == false
            or err == "alchemy session closed before request"
            or err == "Alchemy config reloading before request"
            or err == "brew cancelled before request"
            or err == "pickup cancelled before request"
            or err == "dungeon state unknown before Alchemy request"
            or err == "left base before Alchemy request"
            or err == "Bag changed before Alchemy request"
    end

    local ALCHEMY_STALE_LEASE_SECONDS = 30

    local function alchemyLeaseBlocksCycle(alchemy)
        if not alchemyInvokeLease.pending then return false end
        local startedAt = tonumber(alchemyInvokeLease.startedAt)
        if startedAt == nil
            or os.clock() - startedAt < ALCHEMY_STALE_LEASE_SECONDS
        then
            return true
        end

        -- A dead executor coroutine must not disable Alchemy forever across
        -- reloads. Only retire a stale lease after both authoritative game
        -- states are readable; the normal gates below still prevent a second
        -- request if the old one actually started/finished a potion.
        local brewing = alchemyState(alchemy, "IsBrewInProgress")
        local ready = alchemyState(alchemy, "IsBrewReadyForPickup")
        if brewing == nil or ready == nil then return true end
        alchemyInvokeLease.generation += 1
        alchemyInvokeLease.pending = false
        alchemyInvokeLease.startedAt = nil
        return false
    end

    local function invokeAlchemyAction(action, payload, recoverySnapshot)
        if alchemyInvokeLease.pending then
            return false, nil, "a previous Alchemy request is still pending", true, false
        end
        alchemyInvokeLease.generation += 1
        local token = alchemyInvokeLease.generation
        alchemyInvokeLease.pending = true
        alchemyInvokeLease.startedAt = os.clock()
        local outcome = {
            done = false,
            timedOut = false,
            action = action,
            payload = payload,
            recovery = recoverySnapshot,
        }
        local spawned, spawnError = pcall(task.spawn, function()
            local function beforeInvoke()
                if action == "ALCHEMY_CRAFT_RECIPE"
                    and type(recoverySnapshot) == "table"
                    and (recoverySnapshot.staged == true
                        or type(recoverySnapshot.transferBagFingerprint) == "string")
                then
                    -- PlayerData is the only opaque getter in this commit
                    -- guard and may yield. Read it first; every gate below is
                    -- a local flag or a non-yielding Value read, so neither the
                    -- material snapshot nor the base decision can become stale
                    -- inside our code before InvokeServer.
                    local finalFingerprint = alchemyBagFingerprint()
                    local expectedFingerprint = recoverySnapshot.staged == true
                        and recoverySnapshot.stageBagFingerprint
                        or recoverySnapshot.transferBagFingerprint
                    if finalFingerprint == nil
                        or finalFingerprint ~= expectedFingerprint
                    then
                        return false, "Bag changed before Alchemy request"
                    end
                end
                if not sessionAlive then
                    return false, "alchemy session closed before request"
                end
                if not configReady then
                    return false, "Alchemy config reloading before request"
                end
                if action == "ALCHEMY_CRAFT_RECIPE" and not cfg.AutoBrew then
                    return false, "brew cancelled before request"
                end
                if action == "ALCHEMY_PICKUP_FINISH_POTION"
                    and not cfg.AutoPickupPotion
                then
                    return false, "pickup cancelled before request"
                end
                local challenge = playerNumber("InDungeonChallenge")
                if challenge == nil then
                    return false, "dungeon state unknown before Alchemy request"
                end
                if challenge > 0 then
                    return false, "left base before Alchemy request"
                end
                return true
            end
            local callOk, sent, response, err, didInvoke = pcall(
                invokeAction,
                action,
                payload,
                beforeInvoke
            )
            if not callOk then
                err = tostring(sent)
                sent = false
                response = nil
                didInvoke = false
            end
            outcome.sent = sent == true
            outcome.response = response
            outcome.err = err
            outcome.didInvoke = didInvoke == true
            outcome.done = true
            if alchemyInvokeLease.generation == token then
                alchemyInvokeLease.pending = false
                alchemyInvokeLease.startedAt = nil
                if outcome.timedOut or not sessionAlive then
                    alchemyInvokeLease.completed = {
                        action = action,
                        payload = payload,
                        sent = outcome.sent,
                        response = response,
                        err = err,
                        didInvoke = outcome.didInvoke,
                        recovery = outcome.recovery,
                        completedAt = os.clock(),
                    }
                end
            end
        end)
        if not spawned then
            if alchemyInvokeLease.generation == token then
                alchemyInvokeLease.pending = false
                alchemyInvokeLease.startedAt = nil
            end
            return false,
                nil,
                "could not start Alchemy request: " .. tostring(spawnError),
                false,
                false
        end

        for _ = 1, 16 do
            if outcome.done then
                return outcome.sent,
                    outcome.response,
                    outcome.err,
                    false,
                    outcome.didInvoke
            end
            if not sessionAlive then
                -- Detach this caller but keep the shared lease. The old request
                -- may still finish after a reload, and its result must be
                -- reconciled by the next session instead of being discarded.
                outcome.timedOut = true
                return false,
                    nil,
                    "alchemy session closed while request was pending",
                    true,
                    outcome.didInvoke
            end
            task.wait(0.25)
        end
        if outcome.done then
            return outcome.sent,
                outcome.response,
                outcome.err,
                false,
                outcome.didInvoke
        end
        -- The lease deliberately remains pending. A late completion clears it;
        -- until then neither this session nor a reload can duplicate the call.
        outcome.timedOut = true
        return false,
            nil,
            "Alchemy request timed out; waiting for late completion",
            true,
            outcome.didInvoke
    end

    local function reconcileLateAlchemyCompletion(alchemy)
        local completed = alchemyInvokeLease.completed
        if type(completed) ~= "table" then return false end
        alchemyInvokeLease.completed = nil
        local recovery = completed.recovery
        local snapshotEpoch = type(recovery) == "table"
            and tonumber(recovery.inventoryEpoch)
            or nil
        local inventoryUnchanged = snapshotEpoch ~= nil
            and snapshotEpoch == alchemyInvokeLease.inventoryEpoch
            or snapshotEpoch == nil
                and alchemyInvokeLease.inventoryEpoch == 0
        if alchemyRequestDidNotStart(completed.err, completed.didInvoke) then
            if completed.action == "ALCHEMY_CRAFT_RECIPE" then
                resetAlchemyRecovery()
                if completed.err == "Bag changed before Alchemy request"
                    and inventoryUnchanged
                then
                    clearAlchemyStageCandidate(alchemyInvokeLease.inventoryEpoch)
                end
            elseif completed.action == "ALCHEMY_PICKUP_FINISH_POTION" then
                alchemyPickupNextAttemptAt = 0
            end
            alchemyTelemetry.confirmed = false
            alchemyTelemetry.remoteResult = completed.response
            alchemyTelemetry.status = "late Alchemy request cancelled before send"
            alchemyTelemetry.lastError = completed.err
            return true, false, completed.err
        end
        local rejected, rejection = alchemyResponseRejected(completed.response)
        local accepted = completed.sent == true and not rejected
        local errorText = completed.err
            or (rejected and tostring(rejection))
            or "late request was not confirmed"

        if completed.action == "ALCHEMY_CRAFT_RECIPE" then
            if rejected
                and inventoryUnchanged
                and type(recovery) == "table"
                and recovery.staged == true
            then
                clearAlchemyStageCandidate(alchemyInvokeLease.inventoryEpoch)
            end
            if type(recovery) == "table" and inventoryUnchanged then
                alchemyRecovery.key = recovery.key
                alchemyRecovery.candidateIds = type(recovery.candidateIds) == "table"
                    and recovery.candidateIds
                    or {}
                alchemyRecovery.cursor = math.max(1, tonumber(recovery.cursor) or 1)
                alchemyRecovery.nextAttemptAt = 0
            end
            local brewing = alchemyState(alchemy, "IsBrewInProgress")
            local ready = alchemyState(alchemy, "IsBrewReadyForPickup")
            local confirmed = accepted and (brewing == true or ready == true)
            if confirmed then
                finishAlchemyRecipeAttempt(true)
                if inventoryUnchanged then
                    clearAlchemyStageCandidate(alchemyInvokeLease.inventoryEpoch)
                end
            elseif inventoryUnchanged then
                finishAlchemyRecipeAttempt(false)
            else
                -- A stage trip changed the bag while this request was in
                -- flight. Never resurrect the old frozen priority/cursor;
                -- rank the current inventory afresh on the next fast tick.
                resetAlchemyRecovery()
            end
            alchemyTelemetry.confirmed = confirmed
            alchemyTelemetry.inProgress = brewing
            alchemyTelemetry.ready = ready
            alchemyTelemetry.remoteResult = completed.response
            alchemyTelemetry.status = confirmed
                and "late brew confirmed"
                or "late brew unconfirmed"
            alchemyTelemetry.lastError = confirmed and nil or errorText
            if confirmed then alchemyTelemetry.confirmedAction = "brew" end
            return true, confirmed, alchemyTelemetry.lastError
        end

        if completed.action == "ALCHEMY_PICKUP_FINISH_POTION" then
            local ready = alchemyState(alchemy, "IsBrewReadyForPickup")
            local confirmed = accepted and ready == false
            alchemyTelemetry.confirmed = confirmed
            alchemyTelemetry.ready = ready
            alchemyTelemetry.remoteResult = completed.response
            alchemyTelemetry.status = confirmed
                and "late pickup confirmed"
                or "late pickup unconfirmed"
            alchemyTelemetry.lastError = confirmed and nil or errorText
            alchemyPickupNextAttemptAt = confirmed and 0 or (os.clock() + 8)
            if confirmed then
                alchemyTelemetry.confirmedAction = "pickup"
                resetAlchemyRecovery()
            end
            return true, confirmed, alchemyTelemetry.lastError
        end
        return false
    end

    local function refreshAlchemyUi()
        -- This is the original local PotionBrewingGame refresh. It is strictly
        -- fail-open: a missing bindable never changes the network result.
        fireBindableAction(
            "SHOW_LOCAL_UI",
            "PotionBrewingGame",
            nil,
            false,
            false
        )
    end

    local function runAlchemyCycle()
        alchemyTelemetry.confirmed = false
        alchemyTelemetry.confirmedAction = nil
        if not cfg.AutoBrew and not cfg.AutoPickupPotion then
            resetAlchemyRecovery()
            clearAlchemyStageCandidate(alchemyInvokeLease.inventoryEpoch)
            alchemyTelemetry.status = "disabled"
            return false
        end
        if not cfg.AutoBrew or cfg.BrewRecipe ~= "Best craftable" then
            clearAlchemyStageCandidate(alchemyInvokeLease.inventoryEpoch)
        end
        local challenge = playerNumber("InDungeonChallenge")
        if challenge == nil then
            alchemyTelemetry.status = "waiting for dungeon state"
            alchemyTelemetry.lastError = nil
            return false
        end
        observeAlchemyLocation(challenge)
        if challenge > 0 then
            -- PlayerData.Bag is the permanent inventory, not the stage's
            -- temporary LimitBag. This passive scan can reuse older permanent
            -- materials but never treats it as proof that new drops transferred;
            -- the two-bag fingerprint handoff below revalidates it at base.
            resetAlchemyRecovery()
            local stagedId = nil
            local stageError = nil
            if cfg.AutoBrew and cfg.BrewRecipe == "Best craftable" then
                local stageAlchemy
                stageAlchemy, stageError = resolveAlchemy()
                if stageAlchemy ~= nil then
                    stagedId = updateStageAlchemyCandidate(stageAlchemy)
                end
            end
            alchemyTelemetry.status = stagedId ~= nil
                and ("temporary bag collecting; existing recipe #"
                    .. tostring(stagedId))
                or "collecting in temporary bag"
            alchemyTelemetry.lastError = stageError
            return false
        end
        local alchemy, resolveError = resolveAlchemy()
        if alchemy == nil then
            alchemyTelemetry.status = "waiting for game data"
            alchemyTelemetry.lastError = resolveError
            return false, resolveError
        end
        if alchemyLeaseBlocksCycle(alchemy) then
            alchemyTelemetry.status = "waiting for previous Alchemy request"
            alchemyTelemetry.lastError = "a prior request is still pending"
            return false, alchemyTelemetry.lastError
        end
        local reconciled, reconciledOk, reconciledError = reconcileLateAlchemyCompletion(
            alchemy
        )
        if reconciled then return reconciledOk, reconciledError end
        -- Alchemy actions are server requests and do not move the character.
        -- They can therefore run while Walking, Running, Broom or Auto Return
        -- are active; only the shared network lease serializes them.
        if type(alchemy.CanUseAlchemy) == "function" then
            local canUseOk, canUse = pcall(alchemy.CanUseAlchemy, player)
            if canUseOk then
                alchemyTelemetry.canUse = not not canUse
            else
                alchemyTelemetry.canUse = nil
            end
        else
            alchemyTelemetry.canUse = nil
        end

        local readyBefore = nil
        local readyError = nil
        if type(alchemy.IsBrewReadyForPickup) == "function" then
            local readyOk, ready = pcall(alchemy.IsBrewReadyForPickup, player)
            if readyOk and ready ~= nil then
                readyBefore = not not ready
                alchemyTelemetry.ready = readyBefore
            elseif readyOk then
                readyError = "IsBrewReadyForPickup returned nil"
                alchemyTelemetry.ready = nil
            else
                readyError = tostring(ready)
                alchemyTelemetry.ready = nil
            end
        elseif cfg.AutoPickupPotion then
            readyError = "IsBrewReadyForPickup unavailable"
        end

        if cfg.AutoPickupPotion then
            if readyError ~= nil then
                alchemyTelemetry.status = "waiting for pickup API"
                alchemyTelemetry.lastError = readyError
                return false, alchemyTelemetry.lastError
            end
            if readyBefore == true then
                if os.clock() < alchemyPickupNextAttemptAt then
                    alchemyTelemetry.status = "pickup retry cooldown"
                    alchemyTelemetry.lastError = "waiting before retrying pickup"
                    return false, alchemyTelemetry.lastError
                end
                local readyNow, readyNowError = alchemyState(
                    alchemy,
                    "IsBrewReadyForPickup"
                )
                if readyNow ~= nil then alchemyTelemetry.ready = readyNow end
                if readyNow ~= true then
                    alchemyTelemetry.status = "pickup state changed"
                    alchemyTelemetry.lastError = readyNowError
                        or "potion is no longer ready"
                    return false, alchemyTelemetry.lastError
                end
                readyBefore = readyNow
                if not sessionAlive or not cfg.AutoPickupPotion then
                    alchemyTelemetry.status = "pickup cancelled"
                    return false, "pickup cancelled"
                end
                alchemyTelemetry.pickupAttempts += 1
                alchemyTelemetry.travel = "remote"
                local sent, response, err, requestPending, didInvoke =
                    invokeAlchemyAction(
                        "ALCHEMY_PICKUP_FINISH_POTION"
                    )
                if requestPending then
                    alchemyTelemetry.remoteResult = nil
                    alchemyTelemetry.status = "pickup request still pending"
                    alchemyTelemetry.lastError = err
                    return false, err
                end
                if not sent and alchemyRequestDidNotStart(err, didInvoke) then
                    alchemyTelemetry.pickupAttempts = math.max(
                        0,
                        alchemyTelemetry.pickupAttempts - 1
                    )
                    alchemyPickupNextAttemptAt = 0
                    alchemyTelemetry.status = err
                    alchemyTelemetry.lastError = nil
                    return false, err
                end
                local rejected, rejection = alchemyResponseRejected(response)
                if sent and rejected then
                    sent = false
                    err = "server rejected pickup: " .. tostring(rejection)
                end
                alchemyTelemetry.remoteResult = response
                refreshAlchemyUi()
                task.wait(0.5)
                local confirmed, confirmation = false, err
                if sent then
                    confirmed, confirmation = waitForAlchemyConfirmation(
                        alchemy,
                        "pickup",
                        readyBefore
                    )
                end
                alchemyTelemetry.confirmed = confirmed
                if confirmed then
                    alchemyPickupNextAttemptAt = 0
                    resetAlchemyRecovery()
                else
                    alchemyPickupNextAttemptAt = os.clock() + 8
                end
                if confirmed then
                    alchemyTelemetry.confirmedAction = "pickup"
                    alchemyTelemetry.lastError = nil
                    alchemyTelemetry.status = "pickup confirmed"
                else
                    alchemyTelemetry.lastError = confirmation
                    alchemyTelemetry.status = "pickup unconfirmed"
                end
                if not confirmed then return false, confirmation end
                -- The station has one brewing slot. Once pickup frees it, start
                -- the next requested brew in this same base window instead of
                -- sleeping for another worker cycle (which can lose to Broom's
                -- one-second return delay).
                observeAlchemyLocation(challenge)
                readyBefore = false
                if not cfg.AutoBrew then return true end
            end
            alchemyPickupNextAttemptAt = 0
        elseif readyBefore == true then
            alchemyTelemetry.status = "potion ready for pickup"
            alchemyTelemetry.lastError = "enable Auto Pickup Brewed Potion"
            return false, alchemyTelemetry.lastError
        end

        if not cfg.AutoBrew then
            resetAlchemyRecovery()
            alchemyTelemetry.status = "waiting for brewed potion"
            return false
        end
        if type(alchemy.IsBrewInProgress) ~= "function" then
            alchemyTelemetry.status = "waiting for brew API"
            alchemyTelemetry.lastError = "IsBrewInProgress unavailable"
            return false, alchemyTelemetry.lastError
        end

        local inProgress, progressError = alchemyState(alchemy, "IsBrewInProgress")
        alchemyTelemetry.inProgress = inProgress
        if inProgress == nil then
            alchemyTelemetry.status = "brew check failed"
            alchemyTelemetry.lastError = progressError
            return false, alchemyTelemetry.lastError
        end
        if inProgress then
            finishAlchemyRecipeAttempt(true)
            alchemyTelemetry.status = "brewing (one potion at a time)"
            alchemyTelemetry.lastError = nil
            return false
        end

        if alchemyInventoryTransferPending()
            and not alchemyInventoryTransfer.changed
        then
            alchemyTelemetry.status = "waiting for temporary bag transfer"
            alchemyTelemetry.lastError = nil
            return false
        end

        local stagedRecipeId = cachedStageAlchemyRecipeId(alchemy)
        if stagedRecipeId == nil
            and not alchemyInventoryTransfer.changed
            and os.clock() < alchemyBaseSyncUntil
        then
            alchemyTelemetry.status = "syncing dungeon materials"
            alchemyTelemetry.lastError = nil
            return false
        end

        if alchemyInventoryTransfer.changed
            and not alchemyInventoryTransfer.refreshed
        then
            -- Ask the same local PotionBrewingGame facade used by Magic to
            -- refresh after the permanent Bag receives the temporary drops.
            -- This never moves the character and sends no server action.
            refreshAlchemyUi()
            alchemyInventoryTransfer.refreshed = true
            publishAlchemyInventoryTransfer()
        end

        local recipe, recipeError, selectionState = selectAlchemyRecipe(
            alchemy,
            cfg.BrewRecipe,
            stagedRecipeId
        )
        if recipe == nil then
            alchemyTelemetry.status = selectionState == "cooldown"
                and "brew retry cooldown"
                or "no recipe candidate"
            alchemyTelemetry.lastError = recipeError
            return false, recipeError
        end

        alchemyTelemetry.selected = recipe.label
        local progressBeforeSend, progressBeforeSendError = alchemyState(
            alchemy,
            "IsBrewInProgress"
        )
        if progressBeforeSend ~= nil then
            alchemyTelemetry.inProgress = progressBeforeSend
        end
        if progressBeforeSend ~= false then
            alchemyTelemetry.status = progressBeforeSend == true
                and "brewing"
                or "brew state changed"
            alchemyTelemetry.lastError = progressBeforeSendError
            return false, progressBeforeSendError
        end
        local readyBeforeSend, readyBeforeSendError = alchemyState(
            alchemy,
            "IsBrewReadyForPickup"
        )
        if readyBeforeSend ~= nil then alchemyTelemetry.ready = readyBeforeSend end
        if readyBeforeSend ~= false then
            alchemyTelemetry.status = readyBeforeSend == true
                and "potion ready for pickup"
                or "brew readiness changed"
            alchemyTelemetry.lastError = readyBeforeSendError
                or "a brewed potion must be picked up first"
            return false, alchemyTelemetry.lastError
        end
        readyBefore = readyBeforeSend
        if not sessionAlive or not cfg.AutoBrew then
            alchemyTelemetry.status = "brew cancelled"
            return false, "brew cancelled"
        end
        alchemyTelemetry.craftAttempts += 1
        alchemyTelemetry.travel = "remote"
        local recoverySnapshot = {
            key = alchemyRecovery.key,
            candidateIds = table.clone(alchemyRecovery.candidateIds),
            cursor = alchemyRecovery.cursor,
            inventoryEpoch = alchemyInvokeLease.inventoryEpoch,
            staged = stagedRecipeId ~= nil,
            stageRecipeId = stagedRecipeId,
            stageBagFingerprint = stagedRecipeId ~= nil
                and alchemyStageCandidate.bagFingerprint
                or nil,
            transferBagFingerprint = alchemyInventoryTransfer.pending
                and alchemyInventoryTransfer.changed
                and alchemyInventoryTransfer.lastFingerprint
                or nil,
        }
        local sent, response, err, requestPending, didInvoke = invokeAlchemyAction(
            "ALCHEMY_CRAFT_RECIPE",
            { recipeId = recipe.id },
            recoverySnapshot
        )
        if requestPending then
            alchemyTelemetry.remoteResult = nil
            alchemyTelemetry.status = "brew request still pending"
            alchemyTelemetry.lastError = err
            return false, err
        end
        if not sent and alchemyRequestDidNotStart(err, didInvoke) then
            alchemyTelemetry.craftAttempts = math.max(
                0,
                alchemyTelemetry.craftAttempts - 1
            )
            resetAlchemyRecovery()
            if err == "Bag changed before Alchemy request" then
                clearAlchemyStageCandidate(alchemyInvokeLease.inventoryEpoch)
            end
            alchemyTelemetry.status = err
            alchemyTelemetry.lastError = nil
            return false, err
        end
        local rejected, rejection = alchemyResponseRejected(response)
        if sent and rejected then
            sent = false
            err = "server rejected recipe #" .. tostring(recipe.id)
                .. ": " .. tostring(rejection)
            alchemyTelemetry.remoteResult = response
            if stagedRecipeId ~= nil then
                clearAlchemyStageCandidate(alchemyInvokeLease.inventoryEpoch)
            end
        end
        alchemyTelemetry.remoteResult = response
        task.wait(0.4)
        refreshAlchemyUi()
        local confirmed, confirmation = false, err
        if sent then
            confirmed, confirmation = waitForAlchemyConfirmation(
                alchemy,
                "brew",
                readyBefore
            )
        end
        alchemyTelemetry.confirmed = confirmed
        finishAlchemyRecipeAttempt(confirmed)
        if confirmed then
            clearAlchemyStageCandidate(alchemyInvokeLease.inventoryEpoch)
            alchemyTelemetry.confirmedAction = "brew"
            alchemyTelemetry.lastError = nil
            alchemyTelemetry.status = "brew confirmed"
        else
            alchemyTelemetry.lastError = confirmation
            alchemyTelemetry.status = "brew unconfirmed"
        end
        if confirmed then return true end
        return false, confirmation
    end

    local function autoSellBaseGate()
        if not sessionAlive then return false, "session closed", nil end
        if not configReady then return false, "waiting for config", nil end
        if not autoSellEnabled() then return false, "disabled", nil end
        local challenge = playerNumber("InDungeonChallenge")
        if challenge == nil then
            return false, "waiting for dungeon state", nil
        end
        if challenge > 0 then return false, "waiting for base", challenge end
        return true, nil, challenge
    end

    local function runAutoSellCycle(confirmedActionThisCycle)
        local baseAllowed, baseStatus, challenge = autoSellBaseGate()
        sellTelemetry.challenge = challenge
        if not baseAllowed then
            sellTelemetry.status = baseStatus
            sellTelemetry.lastError = nil
            return false, 0
        end

        sellTelemetry.brewInProgress = nil
        sellTelemetry.authorization = cfg.AutoBrew and nil or "Auto Brew off"
        if cfg.AutoBrew and confirmedActionThisCycle ~= "brew" then
            local alchemy, resolveError = resolveAlchemy()
            if alchemy == nil then
                sellTelemetry.status = "waiting for Alchemy"
                sellTelemetry.lastError = resolveError
                return false, 0, resolveError
            end
            local inProgress, progressError = alchemyState(
                alchemy,
                "IsBrewInProgress"
            )
            sellTelemetry.brewInProgress = inProgress
            if inProgress ~= true then
                sellTelemetry.status = inProgress == false
                    and (confirmedActionThisCycle == "pickup"
                        and "waiting for next brew"
                        or "waiting for confirmed brew")
                    or "waiting for brew state"
                sellTelemetry.lastError = progressError
                return false, 0, progressError
            end
            sellTelemetry.authorization = "already brewing"
        elseif cfg.AutoBrew then
            -- A craft can complete so quickly that replicated state moves
            -- directly from idle to ready. A typed confirmation from THIS
            -- worker tick still proves its ingredients were consumed. Pickup
            -- confirmations never set this permission.
            sellTelemetry.authorization = "craft confirmed"
        end

        sellTelemetry.attempts += 1
        sellTelemetry.status = "selling"
        local sold, count, err = sellAllMaterials(automaticSellSelection(), function()
            local brewStateValidated = confirmedActionThisCycle == "brew"
            if cfg.AutoBrew and confirmedActionThisCycle ~= "brew" then
                -- A detached sell scan can overlap pickup/the next brew.
                -- Re-read the authoritative state immediately before SELL so
                -- a stale "already brewing" grant cannot sell ingredients in
                -- the gap after pickup and before a new craft starts.
                local currentAlchemy = resolveAlchemy()
                if currentAlchemy == nil then return false, "waiting for Alchemy" end
                local currentProgress = alchemyState(
                    currentAlchemy,
                    "IsBrewInProgress"
                )
                if currentProgress ~= true then
                    return false, "waiting for confirmed brew"
                end
                brewStateValidated = true
            end

            -- Keep the base/config/toggle read last: the Alchemy state helpers
            -- above may yield while Broom, reload or the user changes state.
            local stillAtBase, finalStatus, finalChallenge = autoSellBaseGate()
            sellTelemetry.challenge = finalChallenge
            if not stillAtBase then return false, finalStatus end
            -- If AutoBrew switched on while the final gate yielded, the prior
            -- AutoBrew-off decision is no longer a safe sell authorization.
            if cfg.AutoBrew and not brewStateValidated then
                return false, "waiting for confirmed brew"
            end
            return true
        end)
        sellTelemetry.lastCount = count or 0
        sellTelemetry.lastError = err
        if sold then
            sellTelemetry.requests += 1
            sellTelemetry.requestedItems += count or 0
            sellTelemetry.status = "sell request sent"
        elseif err == "nothing to sell" then
            sellTelemetry.status = "nothing to sell"
            sellTelemetry.lastError = nil
        elseif err == "waiting for config"
            or err == "session closed"
            or err == "disabled"
            or err == "waiting for dungeon state"
            or err == "waiting for base"
            or err == "waiting for confirmed brew"
        then
            sellTelemetry.status = err
            sellTelemetry.lastError = nil
        else
            sellTelemetry.status = "sell failed"
        end
        return sold, count or 0, err
    end

    -- Attack -----------------------------------------------------------------

    local attack = {
        skillInput = nil,
        slotIndex = nil,
        status = "resolving",
    }

    -- Live combat telemetry: the Combat tab renders these so a silent
    -- fail-open (missing skill module, missing remote) is always visible.
    local combatStats = {
        attacksOk = 0,
        attacksFailed = 0,
        clicksOk = 0,
        clicksFailed = 0,
        lastAttackError = "none",
        lastClickError = "none",
        clickDelivery = "none",
        powerRequestsOk = 0,
        powerRequestsFailed = 0,
        lastPowerError = "none",
    }

    local function withElevatedIdentity(callback)
        local getIdentity = getthreadidentity
        local setIdentity = setthreadidentity
        if type(getIdentity) == "function" and type(setIdentity) == "function" then
            local ok, original = pcall(getIdentity)
            if ok and type(original) == "number" then
                -- The original resolver requires identity 2 specifically;
                -- retaining a higher executor identity can make ModuleScripts
                -- reject require() even though the path is correct.
                pcall(setIdentity, 2)
                local resultOk, result = pcall(callback)
                pcall(setIdentity, original)
                return resultOk, result
            end
        end
        return pcall(callback)
    end

    local function resolveAttack()
        if attack.skillInput ~= nil then
            return attack.skillInput
        end
        local ok, result = withElevatedIdentity(function()
            local playerScripts = player:WaitForChild("PlayerScripts", 8)
            if playerScripts == nil then return { error = "PlayerScripts not found" } end
            local managerFolder = playerScripts:WaitForChild("Manager", 8)
            if managerFolder == nil then return { error = "Manager not found" } end
            local skillManager = managerFolder:WaitForChild("PlayerSkillClientManager", 8)
            if skillManager == nil then return { error = "PlayerSkillClientManager not found" } end
            local inputModule = skillManager:WaitForChild("PlayerSkillInput", 8)
            if inputModule == nil then return { error = "PlayerSkillInput not found" } end
            local configModule = skillManager:WaitForChild("SkillSlotConfig", 8)
            if configModule == nil then return { error = "SkillSlotConfig not found" } end
            local inputOk, inputTable = pcall(require, inputModule)
            if not inputOk or type(inputTable) ~= "table" then
                return { error = "PlayerSkillInput require failed" }
            end
            local configOk, configTable = pcall(require, configModule)
            if not configOk or type(configTable) ~= "table" then
                return { error = "SkillSlotConfig require failed" }
            end
            if type(inputTable.simulateSlotPressRelease) ~= "function" then
                return { error = "simulateSlotPressRelease missing" }
            end
            if configTable.NORMAL_ATTACK_SLOT_INDEX == nil then
                return { error = "NORMAL_ATTACK_SLOT_INDEX missing" }
            end
            return {
                input = inputTable,
                slot = configTable.NORMAL_ATTACK_SLOT_INDEX,
            }
        end)
        if ok and type(result) == "table" and result.error == nil then
            attack.skillInput = result.input
            attack.slotIndex = result.slot
            attack.status = "ready"
            return attack.skillInput
        end
        attack.status = (ok and type(result) == "table" and result.error)
            or "skill modules unavailable"
        return nil
    end

    local function setNowTarget(target)
        local value = player:FindFirstChild("NowTargetCurrent")
        if value == nil then return false end
        local ok = pcall(function() value.Value = target end)
        return ok
    end

    local function findAttackTarget(range)
        local parts = characterParts()
        if parts == nil then return nil end
        local best = nil
        local bestDistance = nil
        for _, folderName in ipairs({ "Monster", "LocalMonster" }) do
            local folder = workspace:FindFirstChild(folderName)
            if folder ~= nil then
                for _, model in ipairs(folder:GetChildren()) do
                    local ok, usable = pcall(function()
                        if not model:IsA("Model") then return false end
                        local humanoid = model:FindFirstChildOfClass("Humanoid")
                        if humanoid ~= nil and humanoid.Health <= 0 then return false end
                        local anchor = model.PrimaryPart
                            or model:FindFirstChild("HumanoidRootPart")
                        if anchor == nil then return false end
                        return true
                    end)
                    if ok and usable then
                        local anchor = model.PrimaryPart
                            or model:FindFirstChild("HumanoidRootPart")
                        local distance = (anchor.Position - parts.root.Position).Magnitude
                        if distance < range and (bestDistance == nil or distance < bestDistance) then
                            best = model
                            bestDistance = distance
                        end
                    end
                end
            end
        end
        return best
    end

    local function attackTarget(target)
        local input = resolveAttack()
        if input == nil then return false, attack.status end
        if target ~= nil and not setNowTarget(target) then
            return false, "NowTargetCurrent unavailable"
        end
        -- Match the game/original call context: only module resolution needs
        -- identity 2; the actual input simulation runs at the caller identity.
        local ok = pcall(
            input.simulateSlotPressRelease,
            attack.slotIndex,
            true
        )
        if not ok then return false, "simulateSlotPressRelease failed" end
        return true
    end

    -- Auto Click combines the power route confirmed from real world clicks
    -- with the existing normal-attack route. The server calculates the
    -- awarded power from the player's current weapon/rebirth state; no gain
    -- is hard-coded here. Neither route injects mouse input or moves the
    -- real cursor.
    --
    -- InvokeServer is yielding and cannot be cancelled safely. Keep exactly
    -- one power request in flight so a slow response never freezes combat or
    -- creates an unbounded pile of remote calls.
    local powerClick = {
        inFlight = false,
    }

    local function queuePowerClick()
        if powerClick.inFlight then
            return true, "power request pending"
        end

        powerClick.inFlight = true
        local spawnOk, spawnError = pcall(task.spawn, function()
            local callOk, sent, _, sendError = pcall(
                invokeAction,
                "TRAIN_MANUAL_CLICK",
                {}
            )
            powerClick.inFlight = false
            if callOk and sent then
                combatStats.powerRequestsOk = combatStats.powerRequestsOk + 1
                combatStats.lastPowerError = "none"
            else
                combatStats.powerRequestsFailed = combatStats.powerRequestsFailed + 1
                combatStats.lastPowerError = tostring(
                    callOk and sendError or sent or "power request failed"
                )
            end
        end)
        if not spawnOk then
            powerClick.inFlight = false
            combatStats.powerRequestsFailed = combatStats.powerRequestsFailed + 1
            combatStats.lastPowerError = tostring(spawnError)
            return false, "power queue failed: " .. tostring(spawnError)
        end
        return true, "power request queued"
    end

    local function performAutoClick()
        if characterParts() == nil then return false, "character unavailable" end

        local powerAccepted, powerDelivery = queuePowerClick()
        local target = findAttackTarget(tonumber(cfg.AttackRange) or 120)
        local attackOk, attackErr = attackTarget(target)

        if powerAccepted and attackOk then
            return true, powerDelivery .. " + normal attack"
        end
        if not powerAccepted and not attackOk then
            return false, tostring(powerDelivery)
                .. "; attack failed: " .. tostring(attackErr)
        end
        if not powerAccepted then
            return false, tostring(powerDelivery)
                .. "; normal attack sent"
        end
        -- Power is Auto Click's primary effect. A missing attack module is
        -- reported in diagnostics but must not turn a successful power click
        -- into a failed click.
        return true, powerDelivery .. "; attack failed: " .. tostring(attackErr)
    end

    -- Locomotion bridge --------------------------------------------------------

    local loco = nil
    if type(locomotionFactory) == "table"
        and type(locomotionFactory.create) == "function"
    then
        local ok, module = pcall(locomotionFactory.create, {
            option = function(name, fallback)
                if cfg[name] ~= nil then return cfg[name] end
                return fallback
            end,
            toggle = function(name)
                return cfg[name] == true
            end,
            notify = function(text)
                notify(text)
            end,
            stagePart = function(stage)
                return stagePart(stage)
            end,
            alive = function()
                return sessionAlive
            end,
            returnTravelPending = function()
                return alchemyReturnPending()
            end,
            returnArrivalToken = function()
                local challenge = playerNumber("InDungeonChallenge")
                if challenge == nil or challenge > 0 then return nil end
                local token = math.floor(
                    tonumber(alchemyInvokeLease.returnEpisodeToken) or 0
                )
                local consumed = math.floor(
                    tonumber(alchemyInvokeLease.returnConsumedToken) or 0
                )
                if token > consumed then return token end
                return nil
            end,
            acknowledgeReturnArrival = function(token)
                token = math.floor(tonumber(token) or 0)
                if token <= 0 then return false end
                local consumed = math.floor(
                    tonumber(alchemyInvokeLease.returnConsumedToken) or 0
                )
                if token > consumed then
                    alchemyInvokeLease.returnConsumedToken = token
                end
                return true
            end,
        })
        if ok and type(module) == "table" then
            loco = module
        end
    end

    local lastFarmMode = nil

    local DEFAULT_RUNNING_DISTANCE = 12
    local MIN_RUNNING_DISTANCE = 4
    local MAX_RUNNING_DISTANCE = 50
    local RUNNING_ORBIT_STEP = math.rad(45)

    local running = {
        targets = {},
        lastEmit = -math.huge,
        lastJump = -math.huge,
        lastPosition = nil,
        lastProgress = 0,
        retryUntil = 0,
        arrived = false,
        active = false,
        humanoid = nil,
        root = nil,
        stage = nil,
        orbitAngle = 0,
        orbitRadius = DEFAULT_RUNNING_DISTANCE,
        orbitCenter = nil,
        orbitDestination = nil,
    }

    local function shouldWaitForPhysicalStage(mode, stage, challenge)
        local physical = mode == "Walking" or mode == "Running"
        local challengeNumber = tonumber(challenge)
        return physical
            and (tonumber(stage) or 1) > 1
            and (challengeNumber == nil or challengeNumber <= 0)
    end

    local stageEntryWaiting = false

    local function blocksPhysicalTransit()
        if loco ~= nil and cfg.FarmMode == "Walking" then
            local ok, blocked = pcall(function() return loco:BlocksAttack() end)
            if ok and blocked then return true end
        end
        if cfg.FarmMode == "Running" and running.active and not running.arrived then
            return true
        end
        return false
    end

    local function blocksAttack()
        if stageEntryWaiting
            and (cfg.AutoFarm or cfg.AutoFarmSpecific)
            and (cfg.FarmMode == "Walking" or cfg.FarmMode == "Running")
        then
            return true
        end
        return blocksPhysicalTransit()
    end

    local function stopMovementModes()
        if loco ~= nil then
            pcall(function() loco:StopWalking() end)
        end
        local humanoid = running.humanoid
        local root = running.root
        running.active = false
        running.arrived = false
        running.humanoid = nil
        running.root = nil
        running.lastPosition = nil
        running.lastProgress = 0
        running.retryUntil = 0
        running.lastEmit = -math.huge
        running.lastJump = -math.huge
        running.stage = nil
        running.orbitCenter = nil
        running.orbitDestination = nil
        if humanoid ~= nil and root ~= nil then
            pcall(function() humanoid:MoveTo(root.Position) end)
            pcall(function() humanoid:Move(Vector3.new(0, 0, 0), false) end)
        end
    end

    -- Return episode (inventory full) ------------------------------------------

    local MAX_RETURN_ATTEMPTS = 15
    local returnEpisode = {
        active = false,
        requestedAt = 0,
        fired = false,
        lastChallenge = nil,
        lastAttemptAt = 0,
        lastError = nil,
        attempts = 0,
        blocked = false,
        broomArmed = false,
    }
    local returnTravelHoldUntil = tonumber(alchemyInvokeLease.returnHoldUntil) or 0

    alchemyReturnPending = function()
        local sharedHold = tonumber(alchemyInvokeLease.returnHoldUntil) or 0
        if sharedHold > returnTravelHoldUntil then
            returnTravelHoldUntil = sharedHold
        end
        if returnEpisode.active then return true end
        local challenge = playerNumber("InDungeonChallenge")
        local now = os.clock()
        if challenge ~= nil and challenge <= 0
            and (alchemyInventoryTransferPending()
                or (alchemyInvokeLease.inventoryStageActive
                    and configReady
                    and (cfg.AutoBrew or autoSellEnabled())))
        then
            -- Auto Return has reached base, but the temporary LimitBag has not
            -- yet been observed in the permanent Bag. This is a short base
            -- reservation, not a movement suspension: Broom is released as
            -- soon as the transfer is visible or its bounded timeout expires.
            return true
        end
        if now < returnTravelHoldUntil then
            -- During a server teleport nil is an unknown/loading state, not a
            -- confirmation that base has been reached.
            if challenge == nil or challenge > 0 then return true end
        end
        if returnTravelHoldUntil > 0 then
            returnTravelHoldUntil = 0
            alchemyInvokeLease.returnHoldUntil = nil
        end
        if challenge == nil or challenge <= 0 then return false end
        -- Auto Return deliberately stops after its bounded request count. Once
        -- the last travel hold has expired, that terminal state must release
        -- Broom/re-entry coordination instead of becoming an invisible return.
        if returnEpisode.blocked then return false end
        if not cfg.AutoReturnFull then return false end
        local full = bagFull()
        return full == true
    end

    local function resetReturnEpisode()
        returnEpisode.active = false
        returnEpisode.requestedAt = 0
        returnEpisode.fired = false
        returnEpisode.lastChallenge = nil
        returnEpisode.lastAttemptAt = 0
        returnEpisode.lastError = nil
        returnEpisode.attempts = 0
        returnEpisode.blocked = false
        returnEpisode.broomArmed = false
    end

    local function startReturnEpisode(reason)
        if returnEpisode.active then return end
        returnEpisode.active = true
        returnEpisode.requestedAt = os.clock()
        returnEpisode.fired = false
        returnEpisode.lastAttemptAt = 0
        returnEpisode.lastError = nil
        returnEpisode.attempts = 0
        returnEpisode.blocked = false
        returnEpisode.broomArmed = false
        notify("Inventory full; returning to base (" .. tostring(reason) .. ")")
    end

    local function updateReturnEpisode(full)
        local now = os.clock()
        local challenge = playerNumber("InDungeonChallenge")

        -- Auto Return is its own feature, not an Auto Farm sub-mode. Cancel
        -- immediately when its real gates no longer hold and re-arm cleanly on
        -- the next full-bag dungeon episode.
        if not cfg.AutoReturnFull
            or not full
            or challenge == nil
            or challenge <= 0
        then
            resetReturnEpisode()
            return
        end
        returnEpisode.lastChallenge = challenge

        if returnEpisode.blocked then return end

        if not returnEpisode.active then
            startReturnEpisode("bag")
        end

        if now - returnEpisode.requestedAt
            < math.max(0, tonumber(cfg.ReturnDelay) or 0)
        then
            return
        end
        -- FireServer confirms only that the local facade accepted the call,
        -- not that the server returned us. Match the original worker and retry
        -- at most once every two seconds until InDungeonChallenge reaches 0.
        -- A bounded latch prevents an unavailable server route from freezing
        -- movement and sending forever; changing any real gate re-arms it.
        if now - returnEpisode.lastAttemptAt >= 2 then
            if returnEpisode.attempts >= MAX_RETURN_ATTEMPTS then
                returnEpisode.active = false
                returnEpisode.blocked = true
                returnEpisode.lastError = "return not confirmed after "
                    .. tostring(MAX_RETURN_ATTEMPTS) .. " requests"
                notify("Auto return paused: " .. returnEpisode.lastError)
                return
            end
            if not returnEpisode.broomArmed and loco ~= nil then
                local armedOk, armed = pcall(function()
                    return loco:OnAutoReturnFull()
                end)
                returnEpisode.broomArmed = armedOk and armed ~= false
            end
            returnEpisode.lastAttemptAt = now
            returnEpisode.attempts = returnEpisode.attempts + 1
            local ok, err = sendAction("DUNGEON_RETURN_TOWN")
            if ok then
                if not returnEpisode.fired then
                    alchemyInvokeLease.returnEpisodeToken = math.floor(
                        tonumber(alchemyInvokeLease.returnEpisodeToken) or 0
                    ) + 1
                end
                returnEpisode.fired = true
                returnTravelHoldUntil = math.max(returnTravelHoldUntil, now + 10)
                alchemyInvokeLease.returnHoldUntil = returnTravelHoldUntil
                returnEpisode.lastError = nil
            else
                returnEpisode.lastError = err or "return request failed"
            end
        end
    end

    -- Movement worker -----------------------------------------------------------

    local movementStatus = "idle"
    local dashboard = {}

    local function setMovementStatus(text)
        movementStatus = tostring(text)
        pcall(function() dashboard.window:SetStatus(BRAND .. " • " .. movementStatus) end)
    end

    local enterDelay = {
        stage = nil,
        until_ = 0,
    }

    local function applyEnterDelay(stage)
        if enterDelay.stage ~= stage then
            enterDelay.stage = stage
            enterDelay.until_ = os.clock() + math.max(0, tonumber(cfg.EnterDelay) or 0)
        end
        if os.clock() < enterDelay.until_ then
            setMovementStatus(string.format(
                "entering stage %d in %.1fs",
                stage,
                enterDelay.until_ - os.clock()
            ))
            return false
        end
        return true
    end

    local function nearestMonsterPosition(range, fallback)
        local target = findAttackTarget(range)
        if target ~= nil then
            local anchor = target.PrimaryPart or target:FindFirstChild("HumanoidRootPart")
            if anchor ~= nil then
                return anchor.Position
            end
        end
        return fallback
    end

    local function isOverHorizontalFootprint(part, point)
        local localPoint = part.CFrame:PointToObjectSpace(point)
        return math.abs(localPoint.X) <= part.Size.X * 0.5
            and math.abs(localPoint.Z) <= part.Size.Z * 0.5
    end

    local function runningOrbitPoint(stagePartInstance, center, angle, radius)
        local offsetX, offsetZ = Common.runningOrbitOffset(angle, radius)
        local worldOffset = stagePartInstance.CFrame:VectorToWorldSpace(
            Vector3.new(offsetX, 0, offsetZ)
        )
        return center + Vector3.new(worldOffset.X, 0, worldOffset.Z)
    end

    local function resetRunningOrbit(stage)
        running.stage = stage
        running.orbitAngle = 0
        running.orbitRadius = math.clamp(
            tonumber(cfg.RunningDistance) or DEFAULT_RUNNING_DISTANCE,
            MIN_RUNNING_DISTANCE,
            MAX_RUNNING_DISTANCE
        )
        running.orbitCenter = nil
        running.orbitDestination = nil
        running.arrived = false
        running.lastEmit = -math.huge
        running.lastJump = -math.huge
    end

    local function updateRunningOrbit(stagePartInstance, root, center)
        local changed = false
        local radius = math.clamp(
            tonumber(cfg.RunningDistance) or DEFAULT_RUNNING_DISTANCE,
            MIN_RUNNING_DISTANCE,
            MAX_RUNNING_DISTANCE
        )
        local centerChanged = running.orbitCenter == nil
            or (running.orbitCenter - center).Magnitude > 0.05

        if running.orbitDestination == nil then
            local localRoot = stagePartInstance.CFrame:PointToObjectSpace(root.Position)
            local planarMagnitude = Vector3.new(localRoot.X, 0, localRoot.Z).Magnitude
            local entryAngle = planarMagnitude >= 1
                and math.atan2(localRoot.Z, localRoot.X)
                or 0
            running.orbitAngle = entryAngle + RUNNING_ORBIT_STEP
            changed = true
        elseif math.abs(radius - running.orbitRadius) > 0.05 or centerChanged then
            changed = true
        end

        running.orbitRadius = radius
        running.orbitCenter = center
        if changed then
            running.orbitDestination = runningOrbitPoint(
                stagePartInstance,
                center,
                running.orbitAngle,
                radius
            )
        end

        local delta = running.orbitDestination - root.Position
        local distance = Vector3.new(delta.X, 0, delta.Z).Magnitude
        if distance <= 4 then
            running.orbitAngle += RUNNING_ORBIT_STEP
            running.orbitDestination = runningOrbitPoint(
                stagePartInstance,
                center,
                running.orbitAngle,
                radius
            )
            changed = true
            delta = running.orbitDestination - root.Position
            distance = Vector3.new(delta.X, 0, delta.Z).Magnitude
        end
        return running.orbitDestination, distance, changed
    end

    local function updateRunning(stage, stagePartInstance, parts, destination)
        local now = os.clock()
        local humanoid = parts.humanoid
        local root = parts.root

        if running.stage ~= stage then
            resetRunningOrbit(stage)
        end

        local center = running.targets[stage] or destination
        if not running.arrived
            and isOverHorizontalFootprint(stagePartInstance, root.Position)
        then
            running.arrived = true
        end

        running.active = true
        running.humanoid = humanoid
        running.root = root

        local movementTarget = center
        local targetChanged = false
        local distanceFromCenter = nil
        if running.arrived then
            local waypointDistance
            movementTarget, waypointDistance, targetChanged = updateRunningOrbit(
                stagePartInstance,
                root,
                center
            )
            local centerDelta = center - root.Position
            distanceFromCenter = Vector3.new(
                centerDelta.X,
                0,
                centerDelta.Z
            ).Magnitude
        end

        local delta = movementTarget - root.Position
        local planar = Vector3.new(delta.X, 0, delta.Z)

        if now >= running.retryUntil then
            if targetChanged or now - running.lastEmit >= 3.5 then
                pcall(function() humanoid:MoveTo(movementTarget) end)
                running.lastEmit = now
            end
            if running.arrived
                and now - running.lastJump >= 0.9
                and humanoid.FloorMaterial ~= Enum.Material.Air
            then
                pcall(function() humanoid.Jump = true end)
                running.lastJump = now
            end
            local moved = running.lastPosition ~= nil
                and (root.Position - running.lastPosition).Magnitude >= 1
            if moved then
                running.lastPosition = root.Position
                running.lastProgress = now
            elseif running.lastPosition ~= nil and now - running.lastProgress >= 6 then
                running.retryUntil = now + 5
                running.lastProgress = now
            elseif running.lastPosition == nil then
                running.lastPosition = root.Position
                running.lastProgress = now
            end
        end

        if running.arrived then
            return string.format(
                "stage %d running %.1f studs from center; waypoint %.1f studs",
                stage,
                distanceFromCenter or 0,
                planar.Magnitude
            )
        end
        return string.format("stage %d running entry %.1f studs", stage, planar.Magnitude)
    end

    local function updateMovement()
        if cfg.FarmMode ~= lastFarmMode then
            if lastFarmMode == "Walking" or lastFarmMode == "Running" then
                stopMovementModes()
            end
            stageEntryWaiting = false
            lastFarmMode = cfg.FarmMode
            enterDelay.stage = nil
            running.lastPosition = nil
            running.lastProgress = os.clock()
            running.arrived = false
            running.stage = nil
            running.orbitCenter = nil
            running.orbitDestination = nil
        end

        local full = bagFull()
        updateReturnEpisode(full)

        if returnEpisode.active then
            stageEntryWaiting = (cfg.AutoFarm or cfg.AutoFarmSpecific)
                and (cfg.FarmMode == "Walking" or cfg.FarmMode == "Running")
            stopMovementModes()
            setMovementStatus("inventory full; returning to base")
            return
        end

        if not (cfg.AutoFarm or cfg.AutoFarmSpecific) then
            stageEntryWaiting = false
            if movementStatus ~= "idle" then
                stopMovementModes()
                setMovementStatus("idle")
            end
            return
        end

        local cleared = playerNumber("DungeonRunMaxClear") or 0
        local stage = Common.farmStageTarget(
            cleared,
            cfg.FarmStage,
            cfg.AutoFarmSpecific == true,
            MAX_FARM_STAGE
        )

        local mode = cfg.FarmMode
        local challenge = playerNumber("InDungeonChallenge")
        if shouldWaitForPhysicalStage(mode, stage, challenge) then
            stageEntryWaiting = true
            stopMovementModes()
            setMovementStatus("stage " .. stage .. " waiting for dungeon entry")
            return
        end
        stageEntryWaiting = false

        local stagePartInstance = stagePart(stage)
        if stagePartInstance == nil then
            stopMovementModes()
            setMovementStatus("stage " .. stage .. " not loaded")
            return
        end

        local parts = characterParts()
        if parts == nil then
            if cfg.FarmMode == "Walking" then
                stopMovementModes()
            end
            setMovementStatus("waiting for character")
            return
        end

        if mode == "Walking" then
            if loco == nil then
                setMovementStatus("Walking module unavailable")
                return
            end
            local ok, status = pcall(function()
                return loco:Update("Walking", stage, stagePartInstance, parts.root, groundPoint(stagePartInstance))
            end)
            if ok then
                setMovementStatus(status or "walking")
            else
                setMovementStatus("walking error: " .. tostring(status))
            end
            return
        end

        if mode == "Running" then
            if not applyEnterDelay(stage) then
                stopMovementModes()
                return
            end
            local status = updateRunning(stage, stagePartInstance, parts, groundPoint(stagePartInstance))
            setMovementStatus(status)
            return
        end

        -- Teleport-based modes below this point.
        if mode == "Ground" then
            if not applyEnterDelay(stage) then return end
            if isOverFootprint(stagePartInstance, parts.root.Position) then
                setMovementStatus("stage " .. stage .. " farming")
                return
            end
            parts.root.CFrame = CFrame.new(groundPoint(stagePartInstance))
            setMovementStatus("stage " .. stage .. " farming")
            return
        end

        if mode == "Above" then
            if not applyEnterDelay(stage) then return end
            local center = nearestMonsterPosition(tonumber(cfg.AttackRange) or 120, groundPoint(stagePartInstance))
            parts.root.CFrame = CFrame.new(center + Vector3.new(0, tonumber(cfg.FarmHeight) or 20, 0))
            setMovementStatus("stage " .. stage .. " farming above")
            return
        end

        if mode == "Orbit" then
            if not applyEnterDelay(stage) then return end
            local center = nearestMonsterPosition(tonumber(cfg.AttackRange) or 120, groundPoint(stagePartInstance))
            local height = tonumber(cfg.FarmHeight) or 20
            local radius = tonumber(cfg.OrbitRadius) or 25
            local speed = tonumber(cfg.OrbitSpeed) or 1.5
            local angle = os.clock() * speed
            local position = center
                + Vector3.new(math.cos(angle) * radius, height, math.sin(angle) * radius)
            local lookAt = Vector3.new(center.X, position.Y, center.Z)
            parts.root.CFrame = CFrame.lookAt(position, lookAt)
            setMovementStatus("stage " .. stage .. " orbiting")
            return
        end

        setMovementStatus("unknown farm mode " .. tostring(mode))
    end

    -- Combat workers -------------------------------------------------------------

    task.spawn(function()
        while sessionAlive do
            local farming = cfg.AutoFarm or cfg.AutoFarmSpecific
            if farming and cfg.AutoAttack and not blocksAttack() then
                local target = findAttackTarget(tonumber(cfg.AttackRange) or 120)
                if target ~= nil then
                    local ok, err = attackTarget(target)
                    if ok then
                        combatStats.attacksOk = combatStats.attacksOk + 1
                        combatStats.lastAttackError = "none"
                    else
                        combatStats.attacksFailed = combatStats.attacksFailed + 1
                        combatStats.lastAttackError = tostring(err or "attack failed")
                    end
                end
            end
            task.wait(0.2)
        end
    end)

    task.spawn(function()
        while sessionAlive do
            if cfg.AutoClick and not blocksPhysicalTransit() then
                local clicked, delivery = performAutoClick()
                if clicked then
                    combatStats.clicksOk = combatStats.clicksOk + 1
                    combatStats.lastClickError = "none"
                    combatStats.clickDelivery = delivery
                else
                    combatStats.clicksFailed = combatStats.clicksFailed + 1
                    combatStats.lastClickError = tostring(delivery)
                    combatStats.clickDelivery = "none"
                end
            end
            task.wait(1 / math.max(1, tonumber(cfg.ClickRate) or 10))
        end
    end)

    -- Pickup worker -----------------------------------------------------------------

    local dropsClient = workspace:FindFirstChild("DropsClient")

    local function resolveDropsClient()
        if dropsClient ~= nil and dropsClient.Parent ~= nil then
            return dropsClient
        end
        dropsClient = workspace:FindFirstChild("DropsClient")
        return dropsClient
    end

    local function pickupPrompt(primaryPart)
        if primaryPart == nil then return nil end
        local prompt = primaryPart:FindFirstChild("PickupPrompt")
        if prompt ~= nil and prompt:IsA("ProximityPrompt") then
            return prompt
        end
        return nil
    end

    local function promptDropId(prompt)
        if type(getconnections) ~= "function" or type(getupvalue) ~= "function" then
            return nil
        end
        local ok, connections = pcall(getconnections, prompt.Triggered)
        if not ok or type(connections) ~= "table" then return nil end
        for _, connection in ipairs(connections) do
            local callbackOk, callback = pcall(function()
                return connection.Function or connection.fn
            end)
            if callbackOk and type(callback) == "function" then
                for index = 1, 8 do
                    local readOk, value = pcall(getupvalue, callback, index)
                    if readOk and type(value) == "string" and value ~= "" then
                        return value
                    end
                end
            end
        end
        return nil
    end

    local function activatePrompt(prompt)
        if type(fireproximityprompt) == "function" then
            local ok = pcall(fireproximityprompt, prompt, 0)
            if ok then return true end
        end
        if type(firesignal) == "function" then
            local ok = pcall(firesignal, prompt.Triggered, player)
            if ok then return true end
        end
        local dropId = promptDropId(prompt)
        if dropId ~= nil then
            return sendAction("DROP_PICKUP", dropId)
        end
        return false
    end

    local pickupCount = 0
    local dropsNearby = 0

    local function activateSortedDrops(sorted, minValue, tierSet)
        local activatedCount = 0
        for _, entry in ipairs(sorted) do
            if Common.gateDrop(entry, {
                minValue = minValue,
                filterRarity = cfg.PickupFilterRarity == true,
                tiers = tierSet,
            }) then
                local prompt = pickupPrompt(entry.primaryPart)
                if prompt ~= nil and activatePrompt(prompt) then
                    activatedCount = activatedCount + 1
                end
            end
        end
        return activatedCount
    end

    local function collectDrops()
        local container = resolveDropsClient()
        if container == nil then return end
        local parts = characterParts()
        if parts == nil then return end

        local range = tonumber(cfg.PickupRange) or 150
        local minValue = tonumber(cfg.PickupMinValue) or 0
        local tierSet = Common.parseTierSelection(cfg.PickupTiers)

        local candidates = {}
        local order = 0
        for _, model in ipairs(container:GetDescendants()) do
            local ok, entry = pcall(function()
                if not model:IsA("Model") then return nil end
                local legacy = model.Name == "DropItem"
                local itemId = tonumber(model:GetAttribute("ItemId"))
                if not legacy and itemId == nil then return nil end
                local primaryPart = model.PrimaryPart
                if primaryPart == nil then return nil end
                local rawGold = model:GetAttribute("GoldValue")
                local gold = math.floor(tonumber(rawGold) or 0)
                local landed = model:GetAttribute("DropLanded") == true
                local tier = tonumber(model:GetAttribute("Xyd"))
                    or tonumber(model.Parent and model.Parent.Name)
                    or nil
                local distance = (primaryPart.Position - parts.root.Position).Magnitude
                return {
                    model = model,
                    primaryPart = primaryPart,
                    rawGold = rawGold,
                    gold = gold,
                    tier = tier,
                    landed = landed,
                    distance = distance,
                    order = order,
                }
            end)
            if ok and entry ~= nil then
                order = order + 1
                entry.order = order
                entry.hasPrimaryPart = entry.primaryPart ~= nil
                entry.inRange = entry.distance <= range
                entry.isEvent = Common.isEventDrop(entry.rawGold)
                table.insert(candidates, entry)
            end
        end

        dropsNearby = 0
        for _, entry in ipairs(candidates) do
            if entry.inRange then dropsNearby = dropsNearby + 1 end
        end

        local sorted = Common.sortDrops(candidates)
        pickupCount = pickupCount + activateSortedDrops(sorted, minValue, tierSet)
    end

    task.spawn(function()
        while sessionAlive do
            if cfg.AutoPickup then
                local ok, err = pcall(collectDrops)
                if not ok then
                    -- transient scan failure; retry on the next tick
                end
            end
            task.wait(0.4)
        end
    end)

    -- Progress workers -----------------------------------------------------------------

    local function canEnterTrainGround(trainId)
        local data = resolveGetData()
        local train = data and data.Train
        if type(train) ~= "table"
            or type(train.CanEnterTrainGround) ~= "function"
        then
            return false
        end
        local ok, result = pcall(
            train.CanEnterTrainGround,
            player,
            trainId
        )
        if not ok then return false end
        if type(result) == "table" then return result.ok == true end
        return result == true
    end

    local function selectedTrainGroundId()
        local selected = tostring(cfg.TrainGround or "Best available")
        local explicit = tonumber(selected)
            or tonumber(string.match(selected, "^#?(%d+)"))
        if explicit ~= nil then
            explicit = math.floor(explicit)
            return canEnterTrainGround(explicit) and explicit or nil
        end

        local ids = {}
        for _, entry in ipairs(catalogByName("trainConf")) do
            table.insert(ids, entry.id)
        end
        table.sort(ids, function(left, right) return left > right end)
        for _, trainId in ipairs(ids) do
            if canEnterTrainGround(trainId) then return trainId end
        end
        return nil
    end

    local function trainGroundPart(trainId)
        local data = resolveGetData()
        local candidates = {}
        for _, candidate in pairs({
            data and data.Train,
            resolveRuntimeModule("Train"),
            resolveRuntimeModule("CfgFind"),
        }) do
            if candidate ~= nil then table.insert(candidates, candidate) end
        end
        for _, candidate in ipairs(candidates) do
            if type(candidate) == "table"
                and type(candidate.FindZonePartByTrainId) == "function"
            then
                local ok, part = pcall(
                    candidate.FindZonePartByTrainId,
                    trainId
                )
                if (not ok or part == nil) and data ~= nil then
                    ok, part = pcall(
                        candidate.FindZonePartByTrainId,
                        player,
                        trainId
                    )
                end
                if ok and typeof(part) == "Instance" then
                    if part:IsA("BasePart") then return part end
                    local nested = part:FindFirstChildWhichIsA("BasePart", true)
                    if nested ~= nil then return nested end
                end
            end
        end
        return nil
    end

    local potionDrinkCooldown = {}

    local function drinkSelectedPotions()
        local selectedIds = Common.parseIdSelection(cfg.DrinkPotions)
        if next(selectedIds) == nil then return 0, "no potions selected" end
        local bag, bagError = playerBag()
        if bag == nil then return 0, bagError end
        local onlyIds = Common.selectedOnlyIds(bag, selectedIds)
        local sentCount = 0
        for _, onlyId in ipairs(onlyIds) do
            if not sessionAlive or not cfg.AutoDrinkPotion then break end
            local now = os.clock()
            if now - (potionDrinkCooldown[onlyId] or 0) >= 1.5 then
                potionDrinkCooldown[onlyId] = now
                local sent = invokeAction("DRINK_POTION", { onlyID = onlyId })
                if sent then sentCount += 1 end
                task.wait(0.6)
            end
        end
        return sentCount
    end

    local gearKinds = {
        {
            config = "weaponConf",
            itemType = 9,
            equippedKey = "Weapon",
            buyToggle = "AutoBuyWand",
            equipToggle = "AutoEquipWand",
        },
        {
            config = "armorConf",
            itemType = 13,
            equippedKey = "Armor",
            buyToggle = "AutoBuyArmor",
            equipToggle = "AutoEquipArmor",
        },
    }

    local function runGearKind(kind)
        local entries = catalogByName(kind.config, kind.itemType)
        if #entries == 0 then return false end
        local bag = playerBag()
        if type(bag) ~= "table" then return false end
        local owned = Common.ownedItemIds(bag, kind.itemType)
        local gold = playerGold() or 0
        local buyEnabled = cfg.AutoBuyBest or cfg[kind.buyToggle]
        local equipEnabled = cfg.AutoEquipBest or cfg[kind.equipToggle]

        if buyEnabled then
            for _, entry in ipairs(entries) do
                if entry.price > 0
                    and entry.price <= gold
                    and owned[entry.id] ~= true
                then
                    invokeAction("EQUIP_SHOP_BUY", {
                        equipID = entry.id,
                        itemType = kind.itemType,
                    })
                    task.wait(0.4)
                    break
                end
            end
        end

        if equipEnabled then
            bag = playerBag()
            owned = Common.ownedItemIds(bag, kind.itemType)
            local current = math.floor(
                tonumber(playerNumber(kind.equippedKey)) or 0
            )
            for _, entry in ipairs(entries) do
                if owned[entry.id] == true then
                    if current ~= entry.id then
                        invokeAction("EQUIP_SHOP_EQUIP", {
                            equipID = entry.id,
                            itemType = kind.itemType,
                        })
                        task.wait(0.4)
                    end
                    break
                end
            end
        end
        return true
    end

    task.spawn(function() -- rebirth
        while sessionAlive do
            if cfg.AutoRebirth then
                local rebirths = playerNumber("Rebirths") or 0
                local limit = math.floor(tonumber(cfg.RebirthLimit) or 41)
                if rebirths < limit then
                    invokeAction("PLAYER_REBIRTH")
                end
            end
            task.wait(3)
        end
    end)

    task.spawn(function() -- train
        while sessionAlive do
            if cfg.AutoTrain then
                local trainId = selectedTrainGroundId()
                if trainId ~= nil and trainId > 0 then
                    local ground = trainGroundPart(trainId)
                    local parts = characterParts()
                    if ground ~= nil and parts ~= nil
                        and not isOverFootprint(ground, parts.root.Position)
                    then
                        parts.root.CFrame = CFrame.new(
                            ground.Position
                                + Vector3.new(0, ground.Size.Y * 0.5 + 3, 0)
                        )
                        task.wait(0.3)
                    end
                    if playerNumber("TrainGroundId") ~= trainId then
                        sendAction("TRAIN_ZONE_UPDATE", { trainId = trainId })
                        task.wait(0.2)
                    end
                    invokeAction("TRAIN_MANUAL_CLICK", {})
                end
            end
            task.wait(0.2)
        end
    end)

    task.spawn(function() -- index claims
        while sessionAlive do
            if cfg.AutoClaimIndex then
                claimIndexRewards()
            end
            task.wait(4)
        end
    end)

    task.spawn(function() -- online claims
        while sessionAlive do
            if cfg.AutoClaimOnline then
                claimOnlineAwards()
            end
            task.wait(2)
        end
    end)

    task.spawn(function() -- potions
        while sessionAlive do
            if cfg.AutoDrinkPotion then
                drinkSelectedPotions()
            end
            task.wait(1)
        end
    end)

    task.spawn(function() -- alchemy
        local nextAutoSellAt = 0
        local autoSellCyclePending = false
        local autoSellCycleGeneration = 0
        local queuedCraftSellAuthorization = false
        local queuedCraftSellGeneration = 0
        local function clearQueuedCraftSellAuthorization()
            if queuedCraftSellAuthorization then
                queuedCraftSellGeneration += 1
            end
            queuedCraftSellAuthorization = false
        end
        local function startAutoSellCycle(confirmedAction, authorizationGeneration)
            if autoSellCyclePending then return false end
            autoSellCyclePending = true
            autoSellCycleGeneration += 1
            local token = autoSellCycleGeneration
            local started, spawnError = pcall(task.spawn, function()
                local ok, sold, _, err = pcall(
                    runAutoSellCycle,
                    confirmedAction
                )
                if autoSellCycleGeneration ~= token then return end
                autoSellCyclePending = false
                if not ok and sessionAlive then
                    sellTelemetry.status = "sell error"
                    sellTelemetry.lastError = tostring(sold)
                elseif confirmedAction == "brew"
                    and authorizationGeneration == queuedCraftSellGeneration
                    and (sold == true or err == "nothing to sell")
                then
                    queuedCraftSellAuthorization = false
                end

                if queuedCraftSellAuthorization
                    and (confirmedAction ~= "brew"
                        or authorizationGeneration ~= queuedCraftSellGeneration)
                then
                    -- A newer craft was confirmed while this request ran.
                    nextAutoSellAt = 0
                else
                    nextAutoSellAt = configReady and autoSellEnabled()
                        and (os.clock() + 2)
                        or 0
                end
            end)
            if not started and autoSellCycleGeneration == token then
                autoSellCyclePending = false
                sellTelemetry.status = "sell error"
                sellTelemetry.lastError = tostring(spawnError)
                nextAutoSellAt = os.clock() + 2
            end
            return started
        end
        while sessionAlive do
            local confirmedActionThisCycle = nil
            -- Keep the inventory epoch current even while both Alchemy
            -- toggles are off. A late request must never resurrect a frozen
            -- pre-dungeon recipe order after the player collects new items.
            local observedChallenge = playerNumber("InDungeonChallenge")
            if observedChallenge ~= nil then
                observeAlchemyLocation(observedChallenge)
                if observedChallenge > 0 then
                    resetAlchemyRecovery()
                    clearQueuedCraftSellAuthorization()
                end
            end
            if configReady and not cfg.AutoBrew then
                clearAlchemyStageCandidate()
            end
            if configReady then
                if cfg.AutoBrew or cfg.AutoPickupPotion then
                    local ok, err = pcall(runAlchemyCycle)
                    if not ok then
                        alchemyTelemetry.status = "alchemy error"
                        alchemyTelemetry.lastError = tostring(err)
                    else
                        confirmedActionThisCycle = alchemyTelemetry.confirmedAction
                    end
                end
            end

            if confirmedActionThisCycle == "brew"
                and configReady
                and autoSellEnabled()
            then
                -- A sell request from the previous tick may still be in
                -- flight. Preserve this one-shot ordering permission until a
                -- new sell task actually accepts it; never confuse pickup.
                queuedCraftSellAuthorization = true
                queuedCraftSellGeneration += 1
                if not autoSellCyclePending then nextAutoSellAt = 0 end
            elseif not configReady or not autoSellEnabled() then
                clearQueuedCraftSellAuthorization()
            end

            -- Poll Alchemy quickly so enabling it or reaching base starts a
            -- locally selected recipe within half a second. Automatic selling
            -- keeps its two-second cadence, except that a newly confirmed brew
            -- authorizes the ordered sale immediately in this same cycle.
            local now = os.clock()
            local queuedAuthorizationReady = queuedCraftSellAuthorization
                and observedChallenge ~= nil
                and observedChallenge <= 0
                and now >= nextAutoSellAt
            local sellAuthorization = queuedAuthorizationReady
                and "brew"
                or (not queuedCraftSellAuthorization and confirmedActionThisCycle)
            local shouldCheckSell = queuedCraftSellAuthorization
                and queuedAuthorizationReady
                or not queuedCraftSellAuthorization
                    and now >= nextAutoSellAt
            if not configReady then
                sellTelemetry.status = "waiting for config"
                sellTelemetry.lastError = nil
                nextAutoSellAt = 0
            elseif not autoSellEnabled() then
                -- Do not spawn a detached no-op sell task on every fast
                -- Alchemy stage poll merely to publish the disabled status.
                sellTelemetry.status = "disabled"
                sellTelemetry.lastError = nil
                nextAutoSellAt = 0
            elseif shouldCheckSell then
                startAutoSellCycle(
                    sellAuthorization,
                    queuedCraftSellGeneration
                )
            end
            -- While Auto Brew is farming, watch both sides of the two-bag
            -- handoff quickly. The stage owns the small LimitBag; base owns the
            -- permanent Bag used by CanCraftRecipe. Broom waits through this
            -- bounded handoff, but character movement is never suspended.
            if configReady
                and cfg.AutoBrew
                and observedChallenge ~= nil
                and (observedChallenge > 0
                    or alchemyInventoryTransferPending()
                    or alchemyTelemetry.status == "syncing dungeon materials")
            then
                task.wait(0.1)
            else
                task.wait(0.5)
            end
        end
    end)

    task.spawn(function() -- gear
        while sessionAlive do
            local enabled = cfg.AutoBuyBest
                or cfg.AutoEquipBest
                or cfg.AutoBuyWand
                or cfg.AutoEquipWand
                or cfg.AutoBuyArmor
                or cfg.AutoEquipArmor
            if enabled then
                for _, kind in ipairs(gearKinds) do runGearKind(kind) end
            end

            task.wait(2)
        end
    end)

    -- Anti-AFK -----------------------------------------------------------------------

    local idleConnections = {}
    local function setAntiAfk(enabled)
        for _, connection in ipairs(idleConnections) do
            pcall(function()
                if enabled then
                    connection:Disable()
                elseif type(connection.Enable) == "function" then
                    connection:Enable()
                end
            end)
        end
    end
    pcall(function()
        if type(getconnections) == "function" then
            idleConnections = getconnections(player.Idled)
        end
    end)
    setAntiAfk(cfg.AntiAfk)

    -- Dashboard -----------------------------------------------------------------------

    local window = Library:CreateWindow({
        Title = BRAND,
        SubTitle = "Magic Loot suite • " .. Library.Version,
    })
    dashboard.window = window

    unloadSession = function(reason)
        if unloaded then return end
        unloaded = true
        sessionAlive = false
        configReady = false
        resetAlchemyRecovery()
        if loco ~= nil then
            pcall(function() loco:Stop() end)
        end
        for _, gui in pairs({ floatingGui, emergencyGui, bannerGui }) do
            if gui ~= nil then pcall(function() gui:Destroy() end) end
        end
        local playerGui = player:FindFirstChildOfClass("PlayerGui")
        if playerGui ~= nil then
            for _, name in ipairs({
                "InfinityGoldToggle",
                "InfinityGoldLoaderToggle",
                "InfinityGoldEmergency",
                "InfinityGoldStatus",
            }) do
                for _, child in ipairs(playerGui:GetChildren()) do
                    if child.Name == name then
                        pcall(function() child:Destroy() end)
                    end
                end
            end
        end
        if sessionEnvironment ~= nil
            and sessionEnvironment.__INFINITYGOLD_UNLOAD == unloadSession
        then
            sessionEnvironment.__INFINITYGOLD_UNLOAD = nil
        end
        pcall(function() Library:Destroy() end)
    end
    window.OnClose = unloadSession
    if sessionEnvironment ~= nil then
        sessionEnvironment.__INFINITYGOLD_UNLOAD = unloadSession
    end

    local function bindGroup(section)
        return {
            AddToggle = function(_, name, options)
                options = options or {}
                local element = section:AddToggle({
                    Text = options.Text or name,
                    Default = cfg[name] == true,
                    Callback = function(value)
                        cfg[name] = value
                        if type(options.Callback) == "function" then
                            options.Callback(value)
                        end
                    end,
                })
                return bind(name, element)
            end,
            AddDropdown = function(_, name, options)
                options = options or {}
                local element = section:AddDropdown({
                    Text = options.Text or name,
                    Values = options.Values or {},
                    Default = options.Default,
                    Multi = options.Multi,
                    MaxVisible = options.MaxVisible,
                    Callback = function(value) cfg[name] = value end,
                })
                return bind(name, element)
            end,
            AddSlider = function(_, name, options)
                options = options or {}
                local element = section:AddSlider({
                    Text = options.Text or name,
                    Default = options.Default or cfg[name],
                    Min = options.Min or 0,
                    Max = options.Max or 100,
                    Rounding = options.Rounding or 0,
                    Suffix = options.Suffix,
                    Callback = function(value) cfg[name] = value end,
                })
                return bind(name, element)
            end,
            AddButton = function(_, options)
                return section:AddButton(options)
            end,
            AddInput = function(_, name, options)
                options = options or {}
                local element
                element = section:AddInput({
                    Text = options.Text,
                    Default = options.Default ~= nil and options.Default or cfg[name],
                    Placeholder = options.Placeholder,
                    Callback = function(value)
                        local parsed = value
                        if type(options.Parser) == "function" then
                            local ok, result = pcall(options.Parser, value)
                            if not ok or result == nil then
                                if element ~= nil then element:Set(cfg[name]) end
                                return
                            end
                            parsed = result
                        end
                        cfg[name] = parsed
                        if type(options.Parser) == "function" and element ~= nil then
                            element:Set(parsed)
                        end
                    end,
                })
                return bind(name, element)
            end,
            AddLabel = function(_, text)
                return section:AddLabel(text)
            end,
        }
    end

    local function setRegisteredToggle(name, value)
        cfg[name] = value == true
        local element = registry[name]
        if element ~= nil then
            pcall(function() element:Set(value == true) end)
        end
    end

    local function catalogLabelId(value)
        return tonumber(value)
            or tonumber(string.match(tostring(value or ""), "^#(%d+)"))
    end

    local function sameArray(left, right)
        if type(left) ~= "table" or #left ~= #right then return false end
        for index, value in ipairs(right) do
            if tostring(left[index]) ~= tostring(value) then return false end
        end
        return true
    end

    -- Config modules can appear after the hub UI. Keep every catalog-backed
    -- dropdown live and preserve saved selections by stable numeric ID when a
    -- translated label changes or the catalog arrives late.
    local function refreshCatalogDropdown(
        element,
        configName,
        initialValues,
        valuesBuilder,
        multi,
        fallback
    )
        task.spawn(function()
            local fingerprint = table.concat(initialValues or {}, "\30")
            while sessionAlive do
                task.wait(2)
                local refreshed = valuesBuilder()
                local minimumCount = fallback ~= nil and 1 or 0
                if #refreshed > minimumCount then
                    local refreshedFingerprint = table.concat(refreshed, "\30")
                    local previous = cfg[configName]
                    local desired

                    if multi then
                        local selectedIds = Common.parseIdSelection(previous)
                        desired = {}
                        for _, label in ipairs(refreshed) do
                            local id = catalogLabelId(label)
                            if id ~= nil and selectedIds[math.floor(id)] == true then
                                table.insert(desired, label)
                            end
                        end
                    else
                        local previousText = tostring(previous or fallback or "")
                        local previousId = catalogLabelId(previousText)
                        desired = fallback
                        for _, label in ipairs(refreshed) do
                            if label == previousText
                                or (previousId ~= nil
                                    and catalogLabelId(label) == previousId)
                            then
                                desired = label
                                break
                            end
                        end
                    end

                    local selectionChanged = multi
                        and not sameArray(previous, desired)
                        or (not multi and tostring(previous or "") ~= tostring(desired or ""))
                    if refreshedFingerprint ~= fingerprint or selectionChanged then
                        pcall(function()
                            if refreshedFingerprint ~= fingerprint then
                                element:SetValues(refreshed)
                            end
                            element:Set(desired)
                        end)
                        cfg[configName] = desired
                        fingerprint = refreshedFingerprint
                    end
                end
            end
        end)
    end

    -- Farm tab
    do
        local tab = window:CreateTab({ Name = "Farm", Icon = ">" })
        local group = bindGroup(tab:CreateSection("Auto Farm"))
        group:AddToggle("AutoFarm", {
            Text = "Auto Farm",
            Default = false,
            Callback = function(value)
                if value then
                    setRegisteredToggle("AutoFarmSpecific", false)
                    setRegisteredToggle("AutoTrain", false)
                end
            end,
        })
        group:AddToggle("AutoFarmSpecific", {
            Text = "Farm specific stage only",
            Default = false,
            Callback = function(value)
                if value then
                    setRegisteredToggle("AutoFarm", false)
                    setRegisteredToggle("AutoTrain", false)
                end
            end,
        })
        local stageValues = {}
        for stage = 1, MAX_FARM_STAGE do
            table.insert(stageValues, tostring(stage))
        end
        group:AddDropdown("FarmStage", {
            Text = "Stage",
            Values = stageValues,
            Default = "1",
            Multi = false,
        })
        group:AddDropdown("FarmMode", {
            Text = "Mode",
            Values = { "Ground", "Above", "Orbit", "Running", "Walking" },
            Default = "Ground",
            Multi = false,
        })
        group:AddSlider("FarmHeight", {
            Text = "Height",
            Default = 20, Min = 5, Max = 80, Rounding = 0,
        })
        group:AddSlider("OrbitRadius", {
            Text = "Orbit radius",
            Default = 25, Min = 5, Max = 80, Rounding = 0,
        })
        group:AddSlider("OrbitSpeed", {
            Text = "Orbit speed",
            Default = 1.5, Min = 0.2, Max = 6, Rounding = 1,
        })
        group:AddSlider("RunningDistance", {
            Text = "Running distance from center",
            Default = DEFAULT_RUNNING_DISTANCE,
            Min = MIN_RUNNING_DISTANCE,
            Max = MAX_RUNNING_DISTANCE,
            Rounding = 0,
        })
        group:AddSlider("EnterDelay", {
            Text = "Enter delay (s)",
            Default = 0, Min = 0, Max = 30, Rounding = 1,
        })
        group:AddSlider("AttackRange", {
            Text = "Attack range",
            Default = 120, Min = 20, Max = 400, Rounding = 0,
        })
        group:AddToggle("AutoReturnFull", {
            Text = "Auto return when bag full",
            Default = true,
        })
        group:AddSlider("ReturnDelay", {
            Text = "Return delay (s)",
            Default = 0, Min = 0, Max = 30, Rounding = 0,
        })
        local returnDiagnostics = group:AddLabel("Bag check: waiting...")
        task.spawn(function()
            while sessionAlive do
                pcall(function()
                    bagFull()
                    local usedText = bagTelemetry.used ~= nil
                        and tostring(math.floor(bagTelemetry.used)) or "?"
                    local capacityText = bagTelemetry.capacity ~= nil
                        and tostring(math.floor(bagTelemetry.capacity)) or "?"
                    local state
                    if not cfg.AutoReturnFull then
                        state = "disabled"
                    elseif returnEpisode.blocked then
                        state = "paused after " .. tostring(returnEpisode.attempts)
                            .. " requests"
                    elseif returnEpisode.active then
                        state = returnEpisode.fired
                            and ("request sent x" .. tostring(returnEpisode.attempts)
                                .. "; waiting for base")
                            or "return pending"
                    elseif bagTelemetry.known then
                        state = bagTelemetry.full
                            and "bag full; waiting for dungeon"
                            or "armed"
                    else
                        state = "capacity unavailable"
                    end
                    if returnEpisode.lastError ~= nil then
                        state = state .. "; " .. tostring(returnEpisode.lastError)
                    end
                    returnDiagnostics:Set(string.format(
                        "Bag: %s / %s • %s\nAuto return: %s",
                        usedText,
                        capacityText,
                        tostring(bagTelemetry.source),
                        state
                    ))
                end)
                task.wait(1)
            end
        end)

        local runningGroup = bindGroup(tab:CreateSection("Running points"))
        runningGroup:AddButton({
            Text = "Capture current position (current stage)",
            Callback = function()
                local parts = characterParts()
                if parts == nil then
                    notify("No character available to capture")
                    return
                end
                local cleared = playerNumber("DungeonRunMaxClear") or 0
                local stage = Common.farmStageTarget(
                    cleared, cfg.FarmStage, cfg.AutoFarmSpecific == true, MAX_FARM_STAGE
                )
                running.targets[stage] = parts.root.Position
                notify("Running point captured for stage " .. stage)
            end,
        })
        runningGroup:AddButton({
            Text = "Clear running points",
            Callback = function()
                running.targets = {}
                notify("Running points cleared")
            end,
        })
    end

    -- Combat tab
    do
        local tab = window:CreateTab({ Name = "Combat", Icon = "!" })
        local group = bindGroup(tab:CreateSection("Automation"))
        group:AddToggle("AutoAttack", { Text = "Auto Attack", Default = true })
        group:AddToggle("AutoClick", { Text = "Auto Click", Default = false })
        group:AddSlider("ClickRate", {
            Text = "Click rate",
            Default = 10, Min = 1, Max = 20, Rounding = 0,
        })
        group:AddButton({
            Text = "Send test click now",
            Callback = function()
                local clicked, delivery = performAutoClick()
                local message = clicked
                    and ("test click sent via " .. tostring(delivery))
                    or ("test click failed: " .. tostring(delivery))
                notify(message)
                banner(message)
            end,
        })
        group:AddButton({
            Text = "Probe skill modules",
            Callback = function()
                task.spawn(function()
                    attack.skillInput = nil
                    resolveAttack()
                    local message = "skill: " .. tostring(attack.status)
                    notify(message)
                    banner(message)
                end)
            end,
        })

        local diagnostics = tab:CreateSection("Diagnostics"):AddLabel("probing...")
        task.spawn(function()
            while sessionAlive do
                pcall(function()
                    local monsters = 0
                    for _, folderName in ipairs({ "Monster", "LocalMonster" }) do
                        local folder = workspace:FindFirstChild(folderName)
                        if folder ~= nil then
                            monsters = monsters + #folder:GetChildren()
                        end
                    end
                    diagnostics:Set(string.format(
                        "skill: %s\nclick delivery: %s\nnet: %s\n"
                            .. "click remote: %s\nlast missed action: %s\n"
                            .. "NowTargetCurrent: %s\nmonsters nearby containers: %d\n"
                            .. "attacks: %d ok / %d fail\nclicks: %d ok / %d fail\n"
                            .. "power requests: %d ok / %d fail / %s\n"
                            .. "last attack error: %s\nlast click error: %s\n"
                            .. "last power error: %s",
                        tostring(attack.status),
                        tostring(combatStats.clickDelivery),
                        tostring(net.status),
                        remoteFor("TRAIN_MANUAL_CLICK") ~= nil and "found" or "missing",
                        tostring(net.lastMissedAction or "-"),
                        player:FindFirstChild("NowTargetCurrent") ~= nil and "yes" or "no",
                        monsters,
                        combatStats.attacksOk, combatStats.attacksFailed,
                        combatStats.clicksOk, combatStats.clicksFailed,
                        combatStats.powerRequestsOk, combatStats.powerRequestsFailed,
                        powerClick.inFlight and "pending" or "idle",
                        tostring(combatStats.lastAttackError),
                        tostring(combatStats.lastClickError),
                        tostring(combatStats.lastPowerError)
                    ))
                end)
                task.wait(1)
            end
        end)

        tab:CreateSection("Notes"):AddParagraph({
            Title = "How clicking works",
            Text = "Auto Click continuously sends the confirmed power-click "
                .. "request (one at a time) and releases the normal attack "
                .. "skill, without moving the real mouse. Auto Attack "
                .. "pauses while Walking or Running has not entered the "
                .. "stage yet.",
        })
    end

    -- Loot tab
    do
        local tab = window:CreateTab({ Name = "Loot", Icon = "#" })
        local group = bindGroup(tab:CreateSection("Auto Pickup"))
        group:AddToggle("AutoPickup", { Text = "Auto Pickup", Default = false })
        group:AddSlider("PickupRange", {
            Text = "Pickup range",
            Default = 150, Min = 10, Max = 400, Rounding = 0,
        })
        group:AddLabel("Minimum gold value (no limit)")
        group:AddInput("PickupMinValue", {
            Default = 0,
            Placeholder = "Type a whole number, for example 1000000000000",
            Parser = parsePickupMinimumValue,
        })
        group:AddToggle("PickupFilterRarity", {
            Text = "Filter by rarity",
            Default = false,
        })
        local tierValues = {}
        for tier = 1, MAX_PICKUP_TIER do
            table.insert(tierValues, tostring(tier))
        end
        group:AddDropdown("PickupTiers", {
            Text = "Rarities",
            Values = tierValues,
            Default = {},
            Multi = true,
            MaxVisible = 5,
        })
        tab:CreateSection("Notes"):AddParagraph({
            Title = "Event drops",
            Text = "Drops worth exactly 0 gold are treated as event drops: "
                .. "they ignore the minimum value and rarity filter and are "
                .. "collected first. Range and landing checks always apply.",
        })

        local sellSection = tab:CreateSection("Selling")
        local sellGroup = bindGroup(sellSection)
        sellGroup:AddToggle("AutoSell", {
            Text = "Auto Sell (all)",
            Default = false,
            Callback = function(value)
                if value then setRegisteredToggle("AutoSellSpecific", false) end
            end,
        })
        sellGroup:AddToggle("AutoSellSpecific", {
            Text = "Auto Sell Specific Items",
            Default = false,
            Callback = function(value)
                if value then setRegisteredToggle("AutoSell", false) end
            end,
        })
        local sellItemValues = catalogDropdownValues("materialConf", "Material")
        local sellItemsDropdown = sellGroup:AddDropdown("SellItems", {
            Text = "Items",
            Values = sellItemValues,
            Default = {},
            Multi = true,
        })
        refreshCatalogDropdown(
            sellItemsDropdown,
            "SellItems",
            sellItemValues,
            function() return catalogDropdownValues("materialConf", "Material") end,
            true
        )
        sellGroup:AddButton({
            Text = "Sell All Now",
            Callback = function()
                local sold, count, err = sellAllMaterials(nil)
                if sold then
                    notify("Sell request sent for " .. tostring(count) .. " items")
                else
                    notify(err or "Nothing to sell")
                end
            end,
        })
        sellSection:AddParagraph({
            Title = "Automatic order",
            Text = "Auto Sell runs only at base. With Auto Brew enabled it waits "
                .. "until a potion is already brewing, or until a new craft is "
                .. "confirmed. Sell All Now remains a manual override.",
        })

        local stats = tab:CreateSection("Session"):AddLabel("drops: 0 • picked: 0")
        task.spawn(function()
            while sessionAlive do
                pcall(function()
                    stats:Set(string.format(
                        "drops nearby: %d • picked this session: %d\n"
                            .. "auto sell: %s • requested items: %d",
                        dropsNearby,
                        pickupCount,
                        sellTelemetry.status,
                        sellTelemetry.requestedItems
                    ))
                end)
                task.wait(1)
            end
        end)
    end

    -- Progress tab
    do
        local tab = window:CreateTab({ Name = "Progress", Icon = "%" })
        local group = bindGroup(tab:CreateSection("Advancement"))
        group:AddToggle("AutoRebirth", { Text = "Auto Rebirth", Default = false })
        group:AddSlider("RebirthLimit", {
            Text = "Stop at rebirths",
            Default = 41, Min = 1, Max = 41, Rounding = 0,
        })
        group:AddToggle("AutoTrain", {
            Text = "Auto Train",
            Default = false,
            Callback = function(value)
                if value then
                    setRegisteredToggle("AutoFarm", false)
                    setRegisteredToggle("AutoFarmSpecific", false)
                end
            end,
        })
        local trainGroundValues = catalogDropdownValues(
            "trainConf",
            "Training ground",
            "Best available"
        )
        local trainGroundDropdown = group:AddDropdown("TrainGround", {
            Text = "Training ground",
            Values = trainGroundValues,
            Default = "Best available",
            Multi = false,
        })
        refreshCatalogDropdown(
            trainGroundDropdown,
            "TrainGround",
            trainGroundValues,
            function()
                return catalogDropdownValues(
                    "trainConf",
                    "Training ground",
                    "Best available"
                )
            end,
            false,
            "Best available"
        )

        if loco ~= nil then
            local broomGroup = bindGroup(tab:CreateSection("Broom"))
            local ok = pcall(function() loco:Install(broomGroup) end)
            if not ok then
                broomGroup:AddLabel("Broom controls unavailable")
            end
        else
            tab:CreateSection("Broom"):AddLabel("Walking/Broom module not loaded")
        end
    end

    -- Alchemy tab
    do
        local tab = window:CreateTab({ Name = "Alchemy", Icon = "@" })
        local group = bindGroup(tab:CreateSection("Automation"))
        group:AddToggle("AutoBrew", { Text = "Auto Brew", Default = false })
        local recipeValues = alchemyDropdownValues()
        local recipeDropdown = group:AddDropdown("BrewRecipe", {
            Text = "Recipe",
            Values = recipeValues,
            Default = "Best craftable",
            Multi = false,
        })
        task.spawn(function()
            local fingerprint = table.concat(recipeValues, "\30")
            while sessionAlive do
                task.wait(2)
                local refreshed = alchemyDropdownValues()
                local refreshedFingerprint = table.concat(refreshed, "\30")
                local previous = tostring(cfg.BrewRecipe or "Best craftable")
                local desired = previous
                local desiredId = math.floor(
                    tonumber(desired)
                        or tonumber(string.match(desired, "^#(%d+)"))
                        or 0
                )
                local found = false
                if #refreshed > 1 then
                    for _, value in ipairs(refreshed) do
                        if value == desired then
                            found = true
                            break
                        end
                        if desiredId > 0
                            and tonumber(string.match(value, "^#(%d+)")) == desiredId
                        then
                            desired = value
                            found = true
                            break
                        end
                    end
                end
                if #refreshed > 1 and not found and desiredId <= 0 then
                    desired = "Best craftable"
                end

                if #refreshed > 1
                    and (refreshedFingerprint ~= fingerprint or desired ~= previous)
                then
                    pcall(function()
                        if refreshedFingerprint ~= fingerprint then
                            recipeDropdown:SetValues(refreshed)
                        end
                        recipeDropdown:Set(desired)
                    end)
                    cfg.BrewRecipe = desired
                    fingerprint = refreshedFingerprint
                end
            end
        end)
        group:AddToggle("AutoDrinkPotion", { Text = "Auto Drink Potion", Default = false })
        local potionValues = catalogDropdownValues("potionConf", "Potion")
        local potionDropdown = group:AddDropdown("DrinkPotions", {
            Text = "Potions",
            Values = potionValues,
            Default = {},
            Multi = true,
        })
        refreshCatalogDropdown(
            potionDropdown,
            "DrinkPotions",
            potionValues,
            function() return catalogDropdownValues("potionConf", "Potion") end,
            true
        )
        group:AddToggle("AutoPickupPotion", { Text = "Auto Pickup Brewed Potion", Default = true })
        local alchemyStatus = group:AddLabel("Alchemy: waiting...")
        task.spawn(function()
            while sessionAlive do
                pcall(function()
                    local selected = alchemyTelemetry.selected
                        and (" • " .. alchemyTelemetry.selected)
                        or ""
                    local lastError = alchemyTelemetry.lastError
                        and (" • " .. tostring(alchemyTelemetry.lastError))
                        or ""
                    local function flag(value)
                        if value == nil then return "?" end
                        return value and "yes" or "no"
                    end
                    local chosen = alchemyTelemetry.chosenId ~= nil
                        and ("#" .. tostring(alchemyTelemetry.chosenId))
                        or "-"
                    local remoteResult = alchemyTelemetry.remoteResult
                    if remoteResult == nil then
                        remoteResult = "-"
                    elseif type(remoteResult) ~= "string"
                        and type(remoteResult) ~= "number"
                        and type(remoteResult) ~= "boolean"
                    then
                        remoteResult = type(remoteResult)
                    end
                    local temporaryUsed = alchemyTelemetry.temporaryBagUsed ~= nil
                        and tostring(math.floor(alchemyTelemetry.temporaryBagUsed))
                        or "?"
                    alchemyStatus:Set(string.format(
                        "Alchemy: %s • recipes: %d • craft: %d • pickup: %d%s%s\n"
                            .. "Inventory: temporary %s • transfer %s\n"
                            .. "Checks: use %s • brewing %s • ready %s • "
                            .. "rebirth %d/%d • materials %d • craftable %d • "
                            .. "errors %d • chosen %s • remote %s • travel %s • confirmed %s",
                        alchemyTelemetry.status,
                        alchemyTelemetry.recipes,
                        alchemyTelemetry.craftAttempts,
                        alchemyTelemetry.pickupAttempts,
                        selected,
                        lastError,
                        temporaryUsed,
                        tostring(alchemyTelemetry.transferStatus),
                        flag(alchemyTelemetry.canUse),
                        flag(alchemyTelemetry.inProgress),
                        flag(alchemyTelemetry.ready),
                        alchemyTelemetry.rebirthPassed,
                        alchemyTelemetry.checkTotal,
                        alchemyTelemetry.materialChecks,
                        alchemyTelemetry.craftable,
                        alchemyTelemetry.predicateErrors,
                        chosen,
                        tostring(remoteResult),
                        tostring(alchemyTelemetry.travel),
                        flag(alchemyTelemetry.confirmed)
                    ))
                end)
                task.wait(1)
            end
        end)
        tab:CreateSection("Notes"):AddParagraph({
            Title = "Automatic brewing",
            Text = "Alchemy runs remotely only while the player is at base. "
                .. "Dungeon drops first live in the small temporary bag. On return, "
                .. "Best waits only until those materials appear in the permanent "
                .. "999-slot Bag, then sends the highest material-positive recipe in "
                .. "that first base cycle. It never probes guessed recipe IDs one by "
                .. "one. The bounded transfer gate releases Broom even when no material "
                .. "change appears. Pickup can chain the next brew immediately; neither "
                .. "action moves the character. Only one potion can brew at a time.",
        })
    end

    -- Rewards tab
    do
        local tab = window:CreateTab({ Name = "Rewards", Icon = "*" })
        local group = bindGroup(tab:CreateSection("Claims"))
        group:AddToggle("AutoClaimIndex", { Text = "Auto Claim Index", Default = false })
        group:AddToggle("AutoClaimOnline", { Text = "Auto Claim Online", Default = false })
    end

    -- Gear tab
    do
        local tab = window:CreateTab({ Name = "Gear", Icon = "+" })
        local wand = bindGroup(tab:CreateSection("Wand"))
        wand:AddToggle("AutoBuyWand", {
            Text = "Auto Buy Best Affordable Wand",
            Default = false,
        })
        wand:AddToggle("AutoEquipWand", {
            Text = "Auto Equip Best Owned Wand",
            Default = false,
        })
        local armor = bindGroup(tab:CreateSection("Armor"))
        armor:AddToggle("AutoBuyArmor", {
            Text = "Auto Buy Best Affordable Armor",
            Default = false,
        })
        armor:AddToggle("AutoEquipArmor", {
            Text = "Auto Equip Best Owned Armor",
            Default = false,
        })
        tab:CreateSection("Notes"):AddParagraph({
            Title = "Fail-open",
            Text = "Gear automation reads the game's shop configs; if they "
                .. "are unavailable nothing is bought.",
        })
    end

    -- Info tab
    do
        local tab = window:CreateTab({ Name = "Info", Icon = "i" })
        local group = bindGroup(tab:CreateSection("Session"))
        group:AddToggle("AntiAfk", {
            Text = "Anti AFK",
            Default = true,
            Callback = setAntiAfk,
        })
        local info = tab:CreateSection("Game"):AddLabel("loading...")
        task.spawn(function()
            while sessionAlive do
                pcall(function()
                    info:Set(string.format(
                        "place: %d\njob: %s\nexecutor: %s\nuptime: %d s",
                        game.PlaceId,
                        tostring(game.JobId),
                        executorName,
                        math.floor(os.clock() - startedAt)
                    ))
                end)
                task.wait(1)
            end
        end)

        if DISCORD_INVITE ~= "" then
            group:AddButton({
                Text = "Copy invite",
                Callback = function()
                    if setclipboard then
                        pcall(setclipboard, DISCORD_INVITE)
                        notify("Invite copied")
                    end
                end,
            })
        end

        group:AddButton({
            Text = "Rejoin server",
            Callback = function()
                pcall(function()
                    TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId)
                end)
            end,
        })

        local configPath = BRAND .. "/config.json"
        local fallbackConfigPath = BRAND .. "_config.json"

        local function configPayload()
            local payload = {}
            for name in pairs(registry) do
                payload[name] = cfg[name]
            end
            return payload
        end

        local function writeConfig(text)
            if type(writefile) ~= "function" then
                return false, "writefile unavailable"
            end

            local folderReady = false
            if type(isfolder) == "function" then
                local ok, exists = pcall(isfolder, BRAND)
                folderReady = ok and exists == true
            end
            if not folderReady and type(makefolder) == "function" then
                pcall(makefolder, BRAND)
                if type(isfolder) == "function" then
                    local ok, exists = pcall(isfolder, BRAND)
                    folderReady = ok and exists == true
                else
                    folderReady = true
                end
            end

            if folderReady then
                local ok = pcall(writefile, configPath, text)
                if ok then return true, configPath end
            end
            local ok, err = pcall(writefile, fallbackConfigPath, text)
            if ok then return true, fallbackConfigPath end
            return false, tostring(err)
        end

        local function readConfig()
            if type(readfile) ~= "function" then
                return nil, "readfile unavailable"
            end
            for _, path in ipairs({ configPath, fallbackConfigPath }) do
                local ok, text = pcall(readfile, path)
                if ok and type(text) == "string" and text ~= "" then
                    return text, path
                end
            end
            return nil, "no saved config"
        end

        local function saveConfig()
            local ok, encoded = pcall(HttpService.JSONEncode, HttpService, configPayload())
            if not ok then return false, tostring(encoded) end
            return writeConfig(encoded)
        end

        local function loadConfig()
            local text, source = readConfig()
            if text == nil then return false, source end
            local ok, decoded = pcall(HttpService.JSONDecode, HttpService, text)
            if not ok or type(decoded) ~= "table" then
                return false, "saved config is invalid"
            end

            -- Migrate the former combined Gear switches to Magic's separate
            -- Wand/Armor controls without overriding an explicit new value.
            if decoded.AutoBuyBest == true then
                if decoded.AutoBuyWand == nil then decoded.AutoBuyWand = true end
                if decoded.AutoBuyArmor == nil then decoded.AutoBuyArmor = true end
            end
            if decoded.AutoEquipBest == true then
                if decoded.AutoEquipWand == nil then decoded.AutoEquipWand = true end
                if decoded.AutoEquipArmor == nil then decoded.AutoEquipArmor = true end
            end
            if tonumber(decoded.RebirthLimit) ~= nil
                and tonumber(decoded.RebirthLimit) < 1
            then
                decoded.RebirthLimit = 41
            end

            for name, element in pairs(registry) do
                local value = decoded[name]
                if value ~= nil then
                    -- Set cfg synchronously: some UI controls dispatch their
                    -- callbacks asynchronously, which made defaults win at boot.
                    cfg[name] = value
                    pcall(function() element:Set(value) end)
                end
            end
            return true, source
        end

        local configGroup = bindGroup(tab:CreateSection("Config"))
        configGroup:AddButton({
            Text = "Save config",
            Callback = function()
                local ok, detail = saveConfig()
                notify(ok and "Config saved" or ("Config save failed: " .. tostring(detail)))
            end,
        })
        configGroup:AddButton({
            Text = "Load config",
            Callback = function()
                configReady = false
                local ok, detail = loadConfig()
                configReady = true
                if ok and loco ~= nil and type(loco.OnConfigLoaded) == "function" then
                    pcall(function() loco:OnConfigLoaded() end)
                end
                notify(ok and "Config loaded" or ("Config load failed: " .. tostring(detail)))
            end,
        })

        configGroup:AddButton({
            Text = "Unload InfinityGold",
            Callback = unloadSession,
        })

        -- Restore the saved values after every control has been registered.
        -- Missing filesystem support or a first run remains intentionally quiet.
        local loaded = loadConfig()
        configReady = true
        if loco ~= nil and type(loco.OnConfigLoaded) == "function" then
            pcall(function() loco:OnConfigLoaded() end)
        end
        if loaded then notify("Config auto-loaded", 3) end
    end

    -- Main movement loop -----------------------------------------------------------------

    -- Floating IG button: touch-friendly dashboard toggle in its own PlayerGui
    -- ScreenGui (the channel proven to render on every executor). Mobile has
    -- no Right Shift; this button always works and survives gui sweeps via
    -- the watchdog below. It is draggable so the user can place it anywhere,
    -- and the chosen position survives watchdog re-creation.
    local floatingGui
    -- Top-left anchored: AbsolutePosition reports the top-left corner, so
    -- drag math and clamping must operate on the same reference point. A
    -- bottom-right anchor makes the button jump by its own size on the
    -- first drag move.
    local floatingPosition = UDim2.new(1, -70, 1, -70)

    local function ensureFloatingToggle()
        pcall(function()
            local playerGui = player:FindFirstChildOfClass("PlayerGui")
            if playerGui == nil then return end
            if floatingGui ~= nil and floatingGui.Parent ~= nil then return end

            floatingGui = Instance.new("ScreenGui")
            floatingGui.Name = "InfinityGoldToggle"
            floatingGui.ResetOnSpawn = false
            floatingGui.DisplayOrder = 999999
            floatingGui.Parent = playerGui

            local button = Instance.new("TextButton")
            button.Name = "IG"
            button.AnchorPoint = Vector2.new(0, 0)
            button.Position = floatingPosition
            button.Size = UDim2.new(0, 54, 0, 54)
            button.BackgroundColor3 = Color3.fromRGB(245, 197, 66)
            button.Font = Enum.Font.GothamBold
            button.Text = "IG"
            button.TextColor3 = Color3.fromRGB(13, 13, 18)
            button.TextSize = 18
            button.AutoButtonColor = true
            button.Parent = floatingGui

            local rounding = Instance.new("UICorner")
            rounding.CornerRadius = UDim.new(1, 0)
            rounding.Parent = button

            local function toggleDashboard()
                local frame = dashboard.window and dashboard.window.Frame
                if frame == nil then return end
                local host = frame.Parent
                if host ~= nil and host.Parent == nil then
                    local target = player:FindFirstChildOfClass("PlayerGui")
                    if target ~= nil then host.Parent = target end
                end
                frame.Visible = not frame.Visible
                banner(frame.Visible and "dashboard shown" or "dashboard hidden")
            end

            -- Tap toggles the dashboard; dragging moves the button. A short
            -- travel threshold keeps accidental jitter from turning a tap
            -- into a drag, and the position is clamped to the viewport.
            local dragging = false
            local dragMoved = false
            local dragStart = nil
            local buttonOrigin = nil

            button.InputBegan:Connect(function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton1
                    or input.UserInputType == Enum.UserInputType.Touch
                then
                    dragging = true
                    dragMoved = false
                    dragStart = input.Position
                    buttonOrigin = button.AbsolutePosition
                end
            end)

            UserInputService.InputChanged:Connect(function(input)
                if not dragging then return end
                if input.UserInputType ~= Enum.UserInputType.MouseMovement
                    and input.UserInputType ~= Enum.UserInputType.Touch
                then
                    return
                end
                local delta = input.Position - dragStart
                if not dragMoved and delta.Magnitude < 6 then
                    return
                end
                dragMoved = true
                local viewport = floatingGui.AbsoluteSize
                local size = button.AbsoluteSize
                local x = math.clamp(buttonOrigin.X + delta.X, 0, math.max(0, viewport.X - size.X))
                local y = math.clamp(buttonOrigin.Y + delta.Y, 0, math.max(0, viewport.Y - size.Y))
                button.Position = UDim2.new(0, x, 0, y)
            end)

            UserInputService.InputEnded:Connect(function(input)
                if not dragging then return end
                if input.UserInputType ~= Enum.UserInputType.MouseButton1
                    and input.UserInputType ~= Enum.UserInputType.Touch
                then
                    return
                end
                dragging = false
                if dragMoved then
                    -- Keep the anchor-independent offset as the new position.
                    floatingPosition = button.Position
                else
                    toggleDashboard()
                end
            end)
        end)
    end

    ensureFloatingToggle()

    -- Emergency panel: if the dashboard gui can never render (0x0), give the
    -- user a minimal working control surface in the guaranteed channel.
    local function buildEmergencyPanel(reason)
        pcall(function()
            local playerGui = player:FindFirstChildOfClass("PlayerGui")
            if playerGui == nil or playerGui:FindFirstChild("InfinityGoldEmergency") then
                return
            end

            local panel = Instance.new("ScreenGui")
            panel.Name = "InfinityGoldEmergency"
            panel.ResetOnSpawn = false
            panel.DisplayOrder = 999998
            panel.Parent = playerGui
            emergencyGui = panel

            local frame = Instance.new("Frame")
            frame.AnchorPoint = Vector2.new(0, 1)
            frame.Position = UDim2.new(0, 16, 1, -16)
            frame.Size = UDim2.new(0, 230, 0, 170)
            frame.BackgroundColor3 = Color3.fromRGB(13, 13, 18)
            frame.Parent = panel

            local frameCorner = Instance.new("UICorner")
            frameCorner.CornerRadius = UDim.new(0, 10)
            frameCorner.Parent = frame

            local frameStroke = Instance.new("UIStroke")
            frameStroke.Color = Color3.fromRGB(245, 197, 66)
            frameStroke.Parent = frame

            local title = Instance.new("TextLabel")
            title.BackgroundTransparency = 1
            title.Position = UDim2.new(0, 10, 0, 6)
            title.Size = UDim2.new(1, -20, 0, 18)
            title.Font = Enum.Font.GothamBold
            title.Text = "InfinityGold (emergency)"
            title.TextColor3 = Color3.fromRGB(245, 197, 66)
            title.TextSize = 13
            title.TextXAlignment = Enum.TextXAlignment.Left
            title.Parent = frame

            local modeCycle = { "Ground", "Above", "Orbit", "Running", "Walking" }
            local modeIndex = 1

            local function addRow(offset, getText, onClick)
                local row = Instance.new("TextButton")
                row.Position = UDim2.new(0, 10, 0, offset)
                row.Size = UDim2.new(1, -20, 0, 30)
                row.BackgroundColor3 = Color3.fromRGB(28, 28, 38)
                row.Font = Enum.Font.Gotham
                row.TextSize = 13
                row.TextColor3 = Color3.fromRGB(235, 233, 228)
                row.AutoButtonColor = true
                row.Text = getText()
                row.Parent = frame
                local rowCorner = Instance.new("UICorner")
                rowCorner.CornerRadius = UDim.new(0, 6)
                rowCorner.Parent = row
                row.MouseButton1Click:Connect(function()
                    onClick()
                    row.Text = getText()
                end)
                return row
            end

            addRow(28, function()
                return (cfg.AutoFarm and "[x] " or "[ ] ") .. "Auto Farm"
            end, function()
                cfg.AutoFarm = not cfg.AutoFarm
            end)

            addRow(62, function()
                return "Mode: " .. tostring(cfg.FarmMode)
            end, function()
                modeIndex = modeIndex % #modeCycle + 1
                cfg.FarmMode = modeCycle[modeIndex]
            end)

            addRow(96, function()
                return (cfg.AutoPickup and "[x] " or "[ ] ") .. "Auto Pickup"
            end, function()
                cfg.AutoPickup = not cfg.AutoPickup
            end)

            local note = Instance.new("TextLabel")
            note.BackgroundTransparency = 1
            note.Position = UDim2.new(0, 10, 0, 130)
            note.Size = UDim2.new(1, -20, 0, 34)
            note.Font = Enum.Font.Gotham
            note.Text = tostring(reason)
            note.TextColor3 = Color3.fromRGB(154, 152, 146)
            note.TextSize = 11
            note.TextWrapped = true
            note.TextXAlignment = Enum.TextXAlignment.Left
            note.TextYAlignment = Enum.TextYAlignment.Top
            note.Parent = frame
        end)
    end

    -- Dashboard watchdog: some games sweep foreign ScreenGuis out of PlayerGui.
    -- If ours is unparented, re-attach and say so on the banner; if it was
    -- destroyed outright, keep the failure on screen instead of failing silently.
    do
        local wasAttached = true
        task.spawn(function()
            while sessionAlive do
                pcall(function()
                    ensureFloatingToggle()
                    local attached = Library._gui ~= nil and Library._gui.Parent ~= nil
                    if not attached then
                        local playerGui = player:FindFirstChildOfClass("PlayerGui")
                        if playerGui ~= nil and Library._gui ~= nil then
                            Library._gui.Parent = playerGui
                            attached = Library._gui.Parent ~= nil
                            if attached then
                                banner("dashboard gui was removed and re-attached")
                            end
                        end
                    end
                    if attached ~= wasAttached then
                        wasAttached = attached
                        if not attached then
                            banner("dashboard gui could not be re-attached (destroyed?)")
                        end
                    end
                end)
                task.wait(2)
            end
        end)
    end

    task.spawn(function()
        while sessionAlive do
            local ok, err = pcall(updateMovement)
            if not ok then
                setMovementStatus("movement error: " .. tostring(err))
            end
            task.wait(cfg.FarmMode == "Orbit" and 0.05 or 0.25)
        end
    end)

    setMovementStatus("ready")
    notify("loaded • tap the gold IG button (bottom-right) to toggle the dashboard")

    -- Dashboard render verification: measure the real engine layout instead
    -- of guessing. One run must be enough to see (or fix) the problem:
    --   * dead gui (AbsoluteSize 0x0) -> rebuilt; still dead -> emergency panel
    --   * healthy gui -> IG probe badge proves the layer draws
    --   * banner keeps the measurements on screen for 15 seconds
        task.spawn(function()
            task.wait(0.6)
            if not sessionAlive then return end
            banner("verifying dashboard render...")
        local verifyOk, verifyError = pcall(function()
            local windowGui = dashboard.window and dashboard.window.Gui
            local mainFrame = dashboard.window and dashboard.window.Frame
            if windowGui == nil or mainFrame == nil then
                banner("dashboard missing after build (window or gui nil)")
                return
            end

            local playerGui = player:FindFirstChildOfClass("PlayerGui")
            if windowGui.Parent == nil and playerGui ~= nil then
                windowGui.Parent = playerGui
            end

            local note = "ok"
            if windowGui.AbsoluteSize.X < 10 or mainFrame.AbsoluteSize.X < 10 then
                note = "rebuilt"
                local fresh = Instance.new("ScreenGui")
                fresh.Name = windowGui.Name
                fresh.ResetOnSpawn = false
                fresh.IgnoreGuiInset = true
                fresh.DisplayOrder = 1000000
                fresh.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
                fresh.Parent = playerGui
                mainFrame.Parent = fresh
                if Library._gui == windowGui then
                    Library._gui = fresh
                end
                dashboard.window.Gui = fresh
                task.wait(0.3)
                windowGui = fresh
            end

            local stillDead = windowGui.AbsoluteSize.X < 10
                or mainFrame.AbsoluteSize.X < 10
            if stillDead then
                buildEmergencyPanel(string.format(
                    "dashboard gui stays at %dx%d px; emergency controls active",
                    math.floor(mainFrame.AbsoluteSize.X),
                    math.floor(mainFrame.AbsoluteSize.Y)
                ))
                banner("dashboard cannot render here - emergency panel bottom-left")
                return
            end

            local badge = Instance.new("TextLabel")
            badge.Name = "IGProbe"
            badge.BackgroundColor3 = Color3.fromRGB(245, 197, 66)
            badge.Size = UDim2.new(0, 44, 0, 24)
            badge.Position = UDim2.new(0, 8, 0, 70)
            badge.Text = "IG"
            badge.TextColor3 = Color3.fromRGB(13, 13, 18)
            badge.Font = Enum.Font.GothamBold
            badge.TextSize = 14
            badge.ZIndex = 50
            badge.Parent = windowGui
            task.delay(12, function()
                pcall(function() badge:Destroy() end)
            end)

            banner(string.format(
                "dashboard %s: %dx%d px in %s [%d children] • gold IG button toggles it",
                note,
                math.floor(mainFrame.AbsoluteSize.X),
                math.floor(mainFrame.AbsoluteSize.Y),
                tostring(windowGui.Parent and windowGui.Parent.ClassName or "?"),
                #windowGui:GetChildren()
            ))
            task.delay(15, function()
                if bannerGui ~= nil then
                    pcall(function() bannerGui:Destroy() end)
                    bannerGui = nil
                end
            end)
        end)
        if not verifyOk then
            banner("verify error: " .. tostring(verifyError))
        end
    end)

    return {
        windowFrame = dashboard.window and dashboard.window.Frame or nil,
        windowGui = dashboard.window and dashboard.window.Gui or nil,
        floating = floatingGui,
        unload = unloadSession,
    }
end
