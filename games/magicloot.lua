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
local MAX_FARM_STAGE = 27
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
            if type(previousUnload) == "function" then pcall(previousUnload) end
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
        -- Progress
        AutoRebirth = false,
        RebirthLimit = 0,
        AutoTrain = false,
        -- Broom (installed by the locomotion module)
        AutoBroom = false,
        BroomStage = "4",
        BroomReturnDelay = 5,
        -- Alchemy
        AutoBrew = false,
        BrewRecipe = "Best craftable",
        AutoDrinkPotion = false,
        AutoPickupPotion = true,
        -- Rewards
        AutoClaimIndex = false,
        AutoClaimOnline = false,
        -- Gear
        AutoBuyBest = false,
        AutoEquipBest = false,
    }

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

    local function invokeAction(action, payload)
        local network = resolveNet()
        if network == nil then return false, nil, net.status end
        local remote = remoteFor(action)
        if remote == nil then return false, nil, action .. " remote unavailable" end
        local methodOk, invokeServer = pcall(function()
            return network.InvokeServer
        end)
        if not methodOk or type(invokeServer) ~= "function" then
            return false, nil, "NetWork.InvokeServer unavailable"
        end
        local ok, result
        if payload == nil then
            ok, result = pcall(invokeServer, remote)
        else
            ok, result = pcall(invokeServer, remote, payload)
        end
        if not ok then return false, nil, tostring(result) end
        return true, result
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

    local function resolveRuntimeModule(name)
        if runtimeModules[name] ~= nil then return runtimeModules[name] end
        local utils = resolveClientUtils()
        if utils == nil then return nil end

        local candidate = readUtilsEntry(utils, name)
        if candidate == nil then return nil end

        if typeof(candidate) == "Instance" then
            local ok
            ok, candidate = pcall(require, candidate)
            if not ok then return nil end
        end
        if type(candidate) ~= "table" then return nil end

        runtimeModules[name] = candidate
        return candidate
    end

    local function resolveGetData()
        -- UtilsSystem is populated asynchronously on some clients. Cache only
        -- a successful resolution so an early probe cannot disable every
        -- GetData-backed feature for the rest of the session.
        if getData ~= nil then return getData end
        getData = resolveRuntimeModule("GetData")
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

    local function sellAllMaterials()
        local bag, bagError = playerBag()
        if bag == nil then return false, 0, bagError or "inventory unavailable" end
        local ok, onlyIds = pcall(
            Common.sellOnlyIds,
            bag,
            nil,
            isProtectedAlchemyMaterial
        )
        if not ok or type(onlyIds) ~= "table" then
            return false, 0, "inventory scan failed"
        end
        if #onlyIds == 0 then return false, 0, "nothing to sell" end

        local sent, _, err = invokeAction("SELL_MATERIAL", { onlyIDList = onlyIds })
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

    local alchemyBusy = false
    local alchemyTravelEpoch = 0
    local pauseAlchemyMovement = function() end
    local alchemyTelemetry = {
        status = "waiting",
        recipes = 0,
        selected = nil,
        craftAttempts = 0,
        pickupAttempts = 0,
        lastError = nil,
    }

    local function resolveAlchemy()
        local data = resolveGetData()
        local alchemy = data and data.Alchemy
        if type(alchemy) ~= "table" then
            return nil, "GetData.Alchemy unavailable"
        end
        return alchemy
    end

    local function rawAlchemyRecipes(alchemy)
        -- The original client builds this list from potionConf. Keep recipe
        -- ids dynamic; the Alchemy method is only a compatibility fallback.
        local cfgFind = resolveRuntimeModule("CfgFind")
        if cfgFind ~= nil and type(cfgFind.GetCfgByName) == "function" then
            local ok, recipes = pcall(cfgFind.GetCfgByName, "potionConf")
            if ok and type(recipes) == "table" then return recipes end
        end
        if type(alchemy.GetRecipeList) == "function" then
            local ok, recipes = pcall(alchemy.GetRecipeList)
            if ok and type(recipes) == "table" then return recipes end
        end
        return nil, "alchemy recipe list unavailable"
    end

    local function alchemyRecipeCatalog(alchemy)
        local rawRecipes, err = rawAlchemyRecipes(alchemy)
        if rawRecipes == nil then return nil, err end

        local catalog = {}
        for _, raw in pairs(rawRecipes) do
            if type(raw) == "table" then
                local id = math.floor(tonumber(raw.recipeId or raw.id) or 0)
                if id > 0 then
                    local name = raw.Name or raw.name or raw.ZhName
                    if type(name) ~= "string" or name == "" then
                        name = "Recipe " .. tostring(id)
                    end
                    table.insert(catalog, {
                        id = id,
                        potionId = math.floor(tonumber(raw.PID) or 0),
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
        if type(alchemy.CanMeetRecipeRebirth) ~= "function"
            or type(alchemy.CanCraftRecipe) ~= "function"
        then
            return false, "alchemy recipe checks unavailable"
        end
        local rebirthOk, meetsRebirth = pcall(
            alchemy.CanMeetRecipeRebirth,
            player,
            recipe.recipe
        )
        if not rebirthOk then return false, tostring(meetsRebirth) end
        if not meetsRebirth then return false end

        local craftOk, canCraft = pcall(alchemy.CanCraftRecipe, player, recipe.recipe)
        if not craftOk then return false, tostring(canCraft) end
        return not not canCraft
    end

    local function selectAlchemyRecipe(alchemy, selection)
        local catalog, err = alchemyRecipeCatalog(alchemy)
        if catalog == nil then return nil, err end

        selection = tostring(selection or "Best craftable")
        if selection == "Best craftable" then
            local best = nil
            local lastError = nil
            for _, recipe in ipairs(catalog) do
                local craftable, checkError = isAlchemyRecipeCraftable(alchemy, recipe)
                if craftable then best = recipe end
                if checkError ~= nil then lastError = checkError end
            end
            if best ~= nil then return best end
            return nil, lastError or "no craftable recipe"
        end

        for _, recipe in ipairs(catalog) do
            if selection == recipe.label or selection == tostring(recipe.id) then
                local craftable, checkError = isAlchemyRecipeCraftable(alchemy, recipe)
                if craftable then return recipe end
                return nil, checkError or "selected recipe is not craftable"
            end
        end
        return nil, "selected recipe is unavailable"
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

    local function restoreAlchemyRoot(travel)
        if travel == nil or travel.root == nil or travel.root.Parent == nil then return end
        local shouldRestore = true
        local positionOk, distance = pcall(function()
            return (travel.root.Position - travel.destination.Position).Magnitude
        end)
        -- A Broom/return/respawn may have moved the player while the
        -- RemoteFunction was yielding. Never teleport that newer state back
        -- to the stale pre-Alchemy CFrame.
        if positionOk and distance > 12 then shouldRestore = false end
        if shouldRestore then
            pcall(function() travel.root.CFrame = travel.home end)
        end
    end

    local function beginAlchemyTravel(alchemy, resolverName)
        local parts = characterParts()
        if parts == nil then return nil end
        local resolver = alchemy[resolverName]
        if type(resolver) ~= "function" then return nil end

        local ok, target = pcall(resolver)
        if not ok or typeof(target) ~= "CFrame" then return nil end

        local root = parts.root
        local destination = target + Vector3.new(0, 3, 0)
        alchemyTravelEpoch += 1
        local travel = {
            root = root,
            home = root.CFrame,
            destination = destination,
            epoch = alchemyTravelEpoch,
        }
        alchemyBusy = true
        pauseAlchemyMovement()
        local moved = pcall(function()
            root.CFrame = destination
        end)
        if not moved then
            alchemyBusy = false
            return nil
        end
        -- InvokeServer is not cancellable. If an executor/game build leaves it
        -- yielding forever, release the physical farm after a bounded window.
        task.delay(3, function()
            if alchemyBusy and alchemyTravelEpoch == travel.epoch then
                restoreAlchemyRoot(travel)
                alchemyBusy = false
            end
        end)
        task.wait(0.2)
        return travel
    end

    local function finishAlchemyTravel(travel)
        if travel == nil or travel.epoch ~= alchemyTravelEpoch then return end
        restoreAlchemyRoot(travel)
        alchemyBusy = false
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
        if not cfg.AutoBrew and not cfg.AutoPickupPotion then
            alchemyTelemetry.status = "disabled"
            return false
        end

        local alchemy, resolveError = resolveAlchemy()
        if alchemy == nil then
            alchemyTelemetry.status = "waiting for game data"
            alchemyTelemetry.lastError = resolveError
            return false, resolveError
        end
        if type(alchemy.CanUseAlchemy) ~= "function" then
            alchemyTelemetry.status = "waiting for Alchemy API"
            alchemyTelemetry.lastError = "CanUseAlchemy unavailable"
            return false, alchemyTelemetry.lastError
        end

        local canUseOk, canUse = pcall(alchemy.CanUseAlchemy, player)
        if not canUseOk or not canUse then
            alchemyTelemetry.status = "alchemy unavailable"
            alchemyTelemetry.lastError = canUseOk and nil or tostring(canUse)
            return false, alchemyTelemetry.lastError
        end

        if cfg.AutoPickupPotion then
            if type(alchemy.IsBrewReadyForPickup) ~= "function" then
                alchemyTelemetry.status = "waiting for pickup API"
                alchemyTelemetry.lastError = "IsBrewReadyForPickup unavailable"
                return false, alchemyTelemetry.lastError
            end
            local readyOk, ready = pcall(alchemy.IsBrewReadyForPickup, player)
            if not readyOk then
                alchemyTelemetry.status = "pickup check failed"
                alchemyTelemetry.lastError = tostring(ready)
                return false, alchemyTelemetry.lastError
            end
            if ready then
                local travel = beginAlchemyTravel(alchemy, "ResolveFinishSpawnCFrame")
                if not sessionAlive or not cfg.AutoPickupPotion then
                    finishAlchemyTravel(travel)
                    alchemyTelemetry.status = "pickup cancelled"
                    return false, "pickup cancelled"
                end
                alchemyTelemetry.pickupAttempts += 1
                local callOk, sent, _, err = pcall(
                    invokeAction,
                    "ALCHEMY_PICKUP_FINISH_POTION"
                )
                if not callOk then
                    err = tostring(sent)
                    sent = false
                end
                alchemyTelemetry.lastError = sent and nil or err
                alchemyTelemetry.status = sent and "pickup requested" or "pickup failed"
                refreshAlchemyUi()
                task.wait(0.5)
                finishAlchemyTravel(travel)
                return sent, err
            end
        end

        if not cfg.AutoBrew then
            alchemyTelemetry.status = "waiting for brewed potion"
            return false
        end
        if type(alchemy.IsBrewInProgress) ~= "function" then
            alchemyTelemetry.status = "waiting for brew API"
            alchemyTelemetry.lastError = "IsBrewInProgress unavailable"
            return false, alchemyTelemetry.lastError
        end

        local progressOk, inProgress = pcall(alchemy.IsBrewInProgress, player)
        if not progressOk then
            alchemyTelemetry.status = "brew check failed"
            alchemyTelemetry.lastError = tostring(inProgress)
            return false, alchemyTelemetry.lastError
        end
        if inProgress then
            alchemyTelemetry.status = "brewing"
            alchemyTelemetry.lastError = nil
            return false
        end

        local recipe, recipeError = selectAlchemyRecipe(alchemy, cfg.BrewRecipe)
        if recipe == nil then
            alchemyTelemetry.status = "no craftable recipe"
            alchemyTelemetry.lastError = recipeError
            return false, recipeError
        end

        alchemyTelemetry.selected = recipe.label
        local travel = beginAlchemyTravel(alchemy, "ResolveBrewActorCFrame")
        if not sessionAlive or not cfg.AutoBrew then
            finishAlchemyTravel(travel)
            alchemyTelemetry.status = "brew cancelled"
            return false, "brew cancelled"
        end
        alchemyTelemetry.craftAttempts += 1
        local callOk, sent, _, err = pcall(
            invokeAction,
            "ALCHEMY_CRAFT_RECIPE",
            { recipeId = recipe.id }
        )
        if not callOk then
            err = tostring(sent)
            sent = false
        end
        alchemyTelemetry.lastError = sent and nil or err
        alchemyTelemetry.status = sent and "brew requested" or "brew failed"
        task.wait(0.4)
        refreshAlchemyUi()
        finishAlchemyTravel(travel)
        return sent, err
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
        })
        if ok and type(module) == "table" then
            loco = module
        end
    end

    local lastFarmMode = nil

    local running = {
        targets = {},
        lastEmit = 0,
        lastJump = 0,
        lastPosition = nil,
        lastProgress = 0,
        retryUntil = 0,
        arrived = false,
        active = false,
        humanoid = nil,
        root = nil,
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
        if humanoid ~= nil and root ~= nil then
            pcall(function() humanoid:MoveTo(root.Position) end)
            pcall(function() humanoid:Move(Vector3.new(0, 0, 0), false) end)
        end
    end

    pauseAlchemyMovement = function()
        if cfg.FarmMode == "Walking" and loco ~= nil then
            if type(loco.PauseWalking) == "function" then
                pcall(function() loco:PauseWalking() end)
            else
                pcall(function() loco:StopWalking() end)
            end
            return
        end
        if cfg.FarmMode == "Running" then
            stopMovementModes()
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
                returnEpisode.fired = true
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

    local function updateRunning(stage, stagePartInstance, parts, destination)
        local now = os.clock()
        local humanoid = parts.humanoid
        local root = parts.root

        local runningDestination = running.targets[stage]
        if runningDestination == nil then
            runningDestination = destination
        end

        local delta = runningDestination - root.Position
        local planar = Vector3.new(delta.X, 0, delta.Z)
        if planar.Magnitude <= 4 then
            running.active = false
            running.arrived = true
            return string.format("stage %d running arrived", stage)
        end

        running.active = true
        running.arrived = false
        running.humanoid = humanoid
        running.root = root

        if now >= running.retryUntil then
            if now - running.lastEmit >= 3.5 then
                pcall(function() humanoid:MoveTo(runningDestination) end)
                running.lastEmit = now
            end
            if now - running.lastJump >= 0.9
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

        return string.format(
            "stage %d running %.1f studs",
            stage,
            planar.Magnitude
        )
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
        end

        if alchemyBusy then
            pauseAlchemyMovement()
            setMovementStatus("alchemy action in progress")
            return
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

    task.spawn(function() -- rebirth
        while sessionAlive do
            if cfg.AutoRebirth then
                local rebirths = playerNumber("Rebirths") or 0
                local limit = tonumber(cfg.RebirthLimit) or 0
                if limit <= 0 or rebirths < limit then
                    sendAction("PLAYER_REBIRTH")
                end
            end
            task.wait(2)
        end
    end)

    task.spawn(function() -- train
        while sessionAlive do
            if cfg.AutoTrain then
                local trainId = playerNumber("TrainGroundId")
                if trainId ~= nil and trainId > 0 then
                    local data = resolveGetData()
                    local allowed = true
                    if data ~= nil
                        and type(data.Train) == "table"
                        and type(data.Train.CanEnterTrainGround) == "function"
                    then
                        local ok, result = pcall(data.Train.CanEnterTrainGround, trainId)
                        if ok and result == false then
                            allowed = false
                        end
                    end
                    if allowed then
                        if sendAction("TRAIN_ZONE_UPDATE", { trainId = trainId }) then
                            task.wait(0.2)
                        end
                    end
                end
            end
            task.wait(1)
        end
    end)

    task.spawn(function() -- index claims
        while sessionAlive do
            if cfg.AutoClaimIndex then
                sendAction("INDEX_CLAIM_REWARD")
            end
            task.wait(5)
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

    task.spawn(function() -- sell
        while sessionAlive do
            if cfg.AutoSell then
                local sold = sellAllMaterials()
                if sold then
                    task.wait(2)
                end
            end
            task.wait(2)
        end
    end)

    task.spawn(function() -- potions
        while sessionAlive do
            if cfg.AutoDrinkPotion then
                sendAction("DRINK_POTION")
            end
            task.wait(3)
        end
    end)

    task.spawn(function() -- alchemy
        while sessionAlive do
            if cfg.AutoBrew or cfg.AutoPickupPotion then
                local ok, err = pcall(runAlchemyCycle)
                if not ok then
                    alchemyBusy = false
                    alchemyTelemetry.status = "alchemy error"
                    alchemyTelemetry.lastError = tostring(err)
                end
            end
            task.wait(2)
        end
    end)

    task.spawn(function() -- gear
        while sessionAlive do
            if cfg.AutoBuyBest or cfg.AutoEquipBest then
                local data = resolveGetData()
                if data ~= nil and type(data.GetCfgByName) == "function" then
                    local gold = playerGold() or 0
                    for _, confName in ipairs({ "weaponConf", "armorConf" }) do
                        local ok, entries = pcall(data.GetCfgByName, confName)
                        if ok and type(entries) == "table" then
                            local best = nil
                            for _, entry in ipairs(entries) do
                                if type(entry) == "table"
                                    and entry.id ~= nil
                                    and tonumber(entry.price or 0) <= gold
                                    and (best == nil
                                        or tonumber(entry.price or 0) > tonumber(best.price or 0))
                                then
                                    best = entry
                                end
                            end
                            if best ~= nil then
                                if cfg.AutoBuyBest then
                                    sendAction("EQUIP_SHOP_BUY", { id = best.id })
                                end
                                if cfg.AutoEquipBest then
                                    sendAction("EQUIP_SHOP_EQUIP", { id = best.id })
                                end
                            end
                        end
                    end
                end
            end

            task.wait(5)
        end
    end)

    -- Anti-AFK -----------------------------------------------------------------------

    pcall(function()
        local connections = getconnections(player.Idled)
        for _, connection in ipairs(connections) do
            connection:Disable()
        end
    end)

    -- Dashboard -----------------------------------------------------------------------

    local window = Library:CreateWindow({
        Title = BRAND,
        SubTitle = "Magic Loot suite • " .. Library.Version,
    })
    dashboard.window = window

    unloadSession = function()
        if unloaded then return end
        unloaded = true
        sessionAlive = false
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
                    Callback = function(value) cfg[name] = value end,
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
                local element = section:AddInput({
                    Text = options.Text,
                    Default = options.Default,
                    Placeholder = options.Placeholder,
                    Callback = function(value) cfg[name] = value end,
                })
                return bind(name, element)
            end,
            AddLabel = function(_, text)
                return section:AddLabel(text)
            end,
        }
    end

    -- Farm tab
    do
        local tab = window:CreateTab({ Name = "Farm", Icon = ">" })
        local group = bindGroup(tab:CreateSection("Auto Farm"))
        group:AddToggle("AutoFarm", { Text = "Auto Farm", Default = false })
        group:AddToggle("AutoFarmSpecific", {
            Text = "Farm specific stage only",
            Default = false,
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
        group:AddSlider("PickupMinValue", {
            Text = "Minimum gold value",
            Default = 0, Min = 0, Max = 100000, Rounding = 0,
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

        local sellGroup = bindGroup(tab:CreateSection("Selling"))
        sellGroup:AddToggle("AutoSell", { Text = "Auto Sell (all)", Default = false })
        sellGroup:AddButton({
            Text = "Sell All Now",
            Callback = function()
                local sold, count, err = sellAllMaterials()
                if sold then
                    notify("Sell request sent for " .. tostring(count) .. " items")
                else
                    notify(err or "Nothing to sell")
                end
            end,
        })

        local stats = tab:CreateSection("Session"):AddLabel("drops: 0 • picked: 0")
        task.spawn(function()
            while sessionAlive do
                pcall(function()
                    stats:Set(string.format(
                        "drops nearby: %d • picked this session: %d",
                        dropsNearby,
                        pickupCount
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
            Text = "Stop at rebirths (0 = unlimited)",
            Default = 0, Min = 0, Max = 100, Rounding = 0,
        })
        group:AddToggle("AutoTrain", { Text = "Auto Train (current zone)", Default = false })

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
        if #recipeValues == 1 then
            task.spawn(function()
                while sessionAlive do
                    local refreshed = alchemyDropdownValues()
                    if #refreshed > 1 then
                        local desired = tostring(cfg.BrewRecipe or "Best craftable")
                        local found = false
                        for _, value in ipairs(refreshed) do
                            if value == desired then found = true break end
                        end
                        if not found then desired = "Best craftable" end
                        pcall(function()
                            recipeDropdown:SetValues(refreshed)
                            recipeDropdown:Set(desired)
                        end)
                        cfg.BrewRecipe = desired
                        break
                    end
                    task.wait(2)
                end
            end)
        end
        group:AddToggle("AutoDrinkPotion", { Text = "Auto Drink Potion", Default = false })
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
                    alchemyStatus:Set(string.format(
                        "Alchemy: %s • recipes: %d • craft: %d • pickup: %d%s%s",
                        alchemyTelemetry.status,
                        alchemyTelemetry.recipes,
                        alchemyTelemetry.craftAttempts,
                        alchemyTelemetry.pickupAttempts,
                        selected,
                        lastError
                    ))
                end)
                task.wait(1)
            end
        end)
        tab:CreateSection("Notes"):AddParagraph({
            Title = "Automatic brewing",
            Text = "Best craftable selects the highest recipe whose rebirth "
                .. "and materials are available. Creation and pickup use the "
                .. "game's Alchemy state and work while farming.",
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
        local group = bindGroup(tab:CreateSection("Shop"))
        group:AddToggle("AutoBuyBest", { Text = "Auto Buy Best Affordable", Default = false })
        group:AddToggle("AutoEquipBest", { Text = "Auto Equip Best Owned", Default = false })
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
                local ok, detail = loadConfig()
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
