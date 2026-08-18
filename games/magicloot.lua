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
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local RunService = game:GetService("RunService")
    local TeleportService = game:GetService("TeleportService")
    local HttpService = game:GetService("HttpService")

    local player = Players.LocalPlayer
    if player == nil then
        Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
        player = Players.LocalPlayer
    end

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
        AutoDrinkPotion = false,
        AutoPickupPotion = false,
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
        network = nil,
        messages = nil,
        status = "resolving",
    }

    local function resolveNet()
        if net.network ~= nil then
            return net.network
        end
        local ok, utils = pcall(function()
            local allSide = ReplicatedStorage:WaitForChild("AllSideCode", 8)
            if allSide == nil then return nil end
            return require(allSide:WaitForChild("UtilsSystem", 8))
        end)
        if not ok or type(utils) ~= "table" then
            net.status = "UtilsSystem unavailable"
            return nil
        end
        local network = type(utils.NetWork) == "table" and utils.NetWork
            or type(utils.NetWork) == "userdata" and utils.NetWork
            or nil
        if network == nil then
            net.status = "NetWork unavailable"
            return nil
        end
        net.utils = utils
        net.network = network
        net.messages = utils.NetMsg
        net.status = "ready"
        return network
    end

    local function remoteFor(action)
        local network = resolveNet()
        if network == nil or net.messages == nil then
            return nil
        end
        local ok, remote = pcall(function()
            return net.messages[action]
        end)
        if ok and typeof(remote) == "Instance" then
            return remote
        end
        return nil
    end

    local function sendAction(action, payload)
        local network = resolveNet()
        if network == nil then return false, net.status end
        local remote = remoteFor(action)
        if remote == nil then return false, action .. " remote unavailable" end
        local ok, err
        if payload == nil then
            ok, err = pcall(function() network:FireServer(remote) end)
        else
            ok, err = pcall(function() network:FireServer(remote, payload) end)
        end
        if not ok then return false, tostring(err) end
        return true
    end

    local function invokeAction(action, payload)
        local network = resolveNet()
        if network == nil then return false, nil, net.status end
        local remote = remoteFor(action)
        if remote == nil then return false, nil, action .. " remote unavailable" end
        local ok, result, err
        if payload == nil then
            ok, result, err = pcall(function() return network:InvokeServer(remote) end)
        else
            ok, result, err = pcall(function() return network:InvokeServer(remote, payload) end)
        end
        if not ok then return false, nil, tostring(result) end
        return true, result
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
    local getDataResolved = false

    local runtimeModules = {}

    local function resolveRuntimeModule(name)
        if runtimeModules[name] ~= nil then return runtimeModules[name] end
        local network = resolveNet()
        if network == nil or net.utils == nil then return nil end

        local function readModule()
            return net.utils[name]
        end

        local ok, candidate = pcall(readModule)
        if (not ok or candidate == nil)
            and type(getthreadidentity) == "function"
            and type(setthreadidentity) == "function"
        then
            local elevatedOk, elevatedCandidate = pcall(function()
                local identity = getthreadidentity()
                setthreadidentity(2)
                local readOk, result = pcall(readModule)
                setthreadidentity(identity)
                if not readOk then error(result) end
                return result
            end)
            if elevatedOk then
                ok, candidate = true, elevatedCandidate
            end
        end
        if not ok or candidate == nil then return nil end

        if typeof(candidate) == "Instance" then
            ok, candidate = pcall(require, candidate)
            if not ok then return nil end
        end
        if type(candidate) ~= "table" then return nil end

        runtimeModules[name] = candidate
        return candidate
    end

    local function resolveGetData()
        if getDataResolved then return getData end
        getDataResolved = true
        getData = resolveRuntimeModule("GetData")
        return getData
    end

    local function playerBag()
        local playerData = resolveRuntimeModule("PlayerData")
        if playerData == nil or type(playerData.GetPlrDataByKey) ~= "function" then
            return nil
        end
        local ok, bag = pcall(playerData.GetPlrDataByKey, player, "Bag")
        if ok and type(bag) == "table" then return bag end
        return nil
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
        local bag = playerBag()
        if bag == nil then return false, 0, "inventory unavailable" end
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

    local bagCapacityNames = { "LimitBagMax", "LimitBagCapacity", "LimitBagCount" }

    local function bagCapacity()
        for _, name in ipairs(bagCapacityNames) do
            local value = playerNumber(name)
            if value ~= nil and value > 0 then return value end
        end
        local data = resolveGetData()
        if data ~= nil and type(data.GetPlrDataByKey) == "function" then
            for _, key in ipairs({ "LimitBagMax", "LimitBagCapacity" }) do
                local ok, value = pcall(data.GetPlrDataByKey, key)
                if ok and tonumber(value) ~= nil and tonumber(value) > 0 then
                    return tonumber(value)
                end
            end
        end
        return nil
    end

    local function bagFull()
        local used = playerNumber("LimitBagUsed")
        local capacity = bagCapacity()
        if used == nil or capacity == nil or capacity <= 0 then
            return false, false -- not full, capacity unknown
        end
        return used >= capacity, true
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

    -- Attack -----------------------------------------------------------------

    local attack = {
        skillInput = nil,
        slotIndex = nil,
        status = "resolving",
    }

    local function withElevatedIdentity(callback)
        local getIdentity = getthreadidentity
        local setIdentity = setthreadidentity
        if type(getIdentity) == "function" and type(setIdentity) == "function" then
            local ok, original = pcall(getIdentity)
            if ok and type(original) == "number" then
                pcall(setIdentity, math.max(original, 2))
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
            if playerScripts == nil then return nil end
            local manager = playerScripts:WaitForChild("PlayerSkillClientManager", 8)
            if manager == nil then return nil end
            local inputModule = manager:WaitForChild("PlayerSkillInput", 8)
            local configModule = manager:WaitForChild("SkillSlotConfig", 8)
            if inputModule == nil or configModule == nil then return nil end
            local inputTable = require(inputModule)
            local configTable = require(configModule)
            if type(inputTable) ~= "table"
                or type(inputTable.simulateSlotPressRelease) ~= "function"
                or type(configTable) ~= "table"
                or configTable.NORMAL_ATTACK_SLOT_INDEX == nil
            then
                return nil
            end
            return { input = inputTable, slot = configTable.NORMAL_ATTACK_SLOT_INDEX }
        end)
        if ok and type(result) == "table" then
            attack.skillInput = result.input
            attack.slotIndex = result.slot
            attack.status = "ready"
            return attack.skillInput
        end
        attack.status = "skill modules unavailable"
        return nil
    end

    local function setNowTarget(target)
        local value = player:FindFirstChild("NowTargetCurrent")
        if value == nil then
            value = player:FindFirstChildOfClass("ObjectValue")
        end
        if value == nil then return end
        pcall(function() value.Value = target end)
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
                        if humanoid == nil or humanoid.Health <= 0 then return false end
                        local anchor = model.PrimaryPart
                            or model:FindFirstChild("HumanoidRootPart")
                        if anchor == nil then return false end
                        return true
                    end)
                    if ok and usable then
                        local anchor = model.PrimaryPart
                            or model:FindFirstChild("HumanoidRootPart")
                        local distance = (anchor.Position - parts.root.Position).Magnitude
                        if distance <= range and (bestDistance == nil or distance < bestDistance) then
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
        setNowTarget(target)
        local ok = withElevatedIdentity(function()
            input.simulateSlotPressRelease(attack.slotIndex, true)
        end)
        if not ok then return false, "simulateSlotPressRelease failed" end
        return true
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
    }

    local function blocksAttack()
        if loco ~= nil and cfg.FarmMode == "Walking" then
            local ok, blocked = pcall(function() return loco:BlocksAttack() end)
            if ok and blocked then return true end
        end
        if cfg.FarmMode == "Running" and running.active and not running.arrived then
            return true
        end
        return false
    end

    local function stopMovementModes()
        if loco ~= nil then
            pcall(function() loco:StopWalking() end)
        end
        running.active = false
        running.arrived = false
    end

    -- Return episode (inventory full) ------------------------------------------

    local returnEpisode = {
        active = false,
        requestedAt = 0,
        fired = false,
        lastChallenge = nil,
    }

    local function startReturnEpisode(reason)
        if returnEpisode.active then return end
        returnEpisode.active = true
        returnEpisode.requestedAt = os.clock()
        returnEpisode.fired = false
        if loco ~= nil then
            pcall(function() loco:OnAutoReturnFull() end)
        end
        notify("Inventory full; returning to base (" .. tostring(reason) .. ")")
    end

    local function updateReturnEpisode()
        if not returnEpisode.active then return end
        local now = os.clock()
        local challenge = playerNumber("InDungeonChallenge")

        if challenge ~= nil and challenge > 0 then
            returnEpisode.lastChallenge = challenge
        end

        if not returnEpisode.fired then
            if now - returnEpisode.requestedAt < math.max(0, tonumber(cfg.ReturnDelay) or 0) then
                return
            end
            if challenge ~= nil and challenge > 0 then
                local ok = sendAction("DUNGEON_RETURN_TOWN")
                if ok then
                    returnEpisode.fired = true
                end
            else
                -- already at base; nothing to request
                returnEpisode.fired = true
            end
        end

        local settled = returnEpisode.fired
            and challenge ~= nil
            and challenge <= 0
        local timedOut = now - returnEpisode.requestedAt > 30
        if settled or timedOut then
            returnEpisode.active = false
            returnEpisode.fired = false
            returnEpisode.lastChallenge = nil
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
            lastFarmMode = cfg.FarmMode
            enterDelay.stage = nil
            running.lastPosition = nil
            running.lastProgress = os.clock()
            running.arrived = false
        end

        updateReturnEpisode()

        if not (cfg.AutoFarm or cfg.AutoFarmSpecific) then
            if movementStatus ~= "idle" then
                stopMovementModes()
                setMovementStatus("idle")
            end
            return
        end

        if returnEpisode.active then
            stopMovementModes()
            setMovementStatus("inventory full; returning to base")
            return
        end

        local full, capacityKnown = bagFull()
        if cfg.AutoReturnFull and full then
            stopMovementModes()
            startReturnEpisode("bag")
            return
        end

        local cleared = playerNumber("DungeonRunMaxClear") or 0
        local stage = Common.farmStageTarget(
            cleared,
            cfg.FarmStage,
            cfg.AutoFarmSpecific == true,
            MAX_FARM_STAGE
        )

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

        local mode = cfg.FarmMode

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
            if cfg.AutoAttack and not blocksAttack() then
                local target = findAttackTarget(tonumber(cfg.AttackRange) or 120)
                if target ~= nil then
                    local ok, err = attackTarget(target)
                    if not ok and attack.status ~= "skill modules unavailable" then
                        attack.status = tostring(err or "attack failed")
                    end
                end
            end
            task.wait(0.2)
        end
    end)

    task.spawn(function()
        while sessionAlive do
            if cfg.AutoClick and not blocksAttack() then
                local target = findAttackTarget(tonumber(cfg.AttackRange) or 120)
                if target ~= nil then
                    attackTarget(target)
                else
                    sendAction("TRAIN_MANUAL_CLICK", {})
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
        for _, entry in ipairs(sorted) do
            if Common.gateDrop(entry, {
                minValue = minValue,
                filterRarity = cfg.PickupFilterRarity == true,
                tiers = tierSet,
            }) then
                local prompt = pickupPrompt(entry.primaryPart)
                if prompt ~= nil then
                    local activated = activatePrompt(prompt)
                    if activated then
                        pickupCount = pickupCount + 1
                        task.wait(0.4)
                        return
                    end
                end
            end
        end
    end

    task.spawn(function()
        while sessionAlive do
            if cfg.AutoPickup then
                local ok, err = pcall(collectDrops)
                if not ok then
                    -- transient scan failure; retry on the next tick
                end
            end
            task.wait(0.5)
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

    task.spawn(function() -- claims
        while sessionAlive do
            if cfg.AutoClaimIndex then
                sendAction("INDEX_CLAIM_REWARD")
            end
            if cfg.AutoClaimOnline then
                sendAction("CLAIM_ONLINE_AWARD")
            end
            task.wait(5)
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
            if cfg.AutoPickupPotion then
                sendAction("ALCHEMY_PICKUP_FINISH_POTION")
            end
            task.wait(3)
        end
    end)

    task.spawn(function() -- brew + gear
        while sessionAlive do
            if cfg.AutoBrew then
                local data = resolveGetData()
                local parts = characterParts()
                if data ~= nil
                    and type(data.ResolveBrewActorCFrame) == "function"
                    and parts ~= nil
                    and cfg.FarmMode ~= "Walking"
                    and cfg.FarmMode ~= "Running"
                then
                    local ok, actorCFrame = pcall(data.ResolveBrewActorCFrame)
                    if ok and typeof(actorCFrame) == "CFrame" then
                        local homeCFrame = parts.root.CFrame
                        pcall(function() parts.root.CFrame = actorCFrame end)
                        task.wait(0.3)
                        local recipes = {}
                        pcall(function()
                            if type(data.GetRecipeList) == "function" then
                                recipes = data.GetRecipeList() or {}
                            end
                        end)
                        local first = recipes[1]
                        if type(first) == "table" and first.id ~= nil then
                            invokeAction("ALCHEMY_CRAFT_RECIPE", { recipeId = first.id })
                        elseif type(first) == "number" then
                            invokeAction("ALCHEMY_CRAFT_RECIPE", { recipeId = first })
                        end
                        task.wait(0.4)
                        pcall(function() parts.root.CFrame = homeCFrame end)
                    end
                end
            end

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
        pcall(function() Library:Destroy() end)
    end
    window.OnClose = unloadSession

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
        tab:CreateSection("Notes"):AddParagraph({
            Title = "Attack blocking",
            Text = "Auto Attack and Auto Click pause while Walking or Running "
                .. "has not entered the target stage yet, then resume for the "
                .. "rest of the route.",
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
        for tier = 1, 8 do
            table.insert(tierValues, tostring(tier))
        end
        group:AddDropdown("PickupTiers", {
            Text = "Rarities",
            Values = tierValues,
            Default = {},
            Multi = true,
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
        group:AddToggle("AutoDrinkPotion", { Text = "Auto Drink Potion", Default = false })
        group:AddToggle("AutoPickupPotion", { Text = "Auto Pickup Brewed Potion", Default = false })
        tab:CreateSection("Notes"):AddParagraph({
            Title = "Fail-open",
            Text = "Brewing resolves the game's brew actor and first recipe; "
                .. "if the game data is unavailable the feature waits instead "
                .. "of erroring.",
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

        local configGroup = bindGroup(tab:CreateSection("Config"))
        configGroup:AddButton({
            Text = "Save config",
            Callback = function()
                local payload = {}
                for name in pairs(registry) do
                    payload[name] = cfg[name]
                end
                local ok = pcall(function()
                    if isfolder and not isfolder(BRAND) then
                        makefolder(BRAND)
                    end
                    writefile(
                        BRAND .. "/config.json",
                        HttpService:JSONEncode(payload)
                    )
                end)
                notify(ok and "Config saved" or "Filesystem unavailable")
            end,
        })
        configGroup:AddButton({
            Text = "Load config",
            Callback = function()
                local ok, decoded = pcall(function()
                    return HttpService:JSONDecode(readfile(BRAND .. "/config.json"))
                end)
                if not ok or type(decoded) ~= "table" then
                    notify("No saved config")
                    return
                end
                for name, element in pairs(registry) do
                    if decoded[name] ~= nil then
                        pcall(function() element:Set(decoded[name]) end)
                    end
                end
                notify("Config loaded")
            end,
        })

        configGroup:AddButton({
            Text = "Unload InfinityGold",
            Callback = unloadSession,
        })
    end

    -- Main movement loop -----------------------------------------------------------------

    -- Floating IG button: touch-friendly dashboard toggle in its own PlayerGui
    -- ScreenGui (the channel proven to render on every executor). Mobile has
    -- no Right Shift; this button always works and survives gui sweeps via
    -- the watchdog below.
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
            button.AnchorPoint = Vector2.new(1, 1)
            button.Position = UDim2.new(1, -16, 1, -16)
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

            button.MouseButton1Click:Connect(function()
                local frame = dashboard.window and dashboard.window.Frame
                if frame == nil then return end
                local host = frame.Parent
                if host ~= nil and host.Parent == nil then
                    local target = player:FindFirstChildOfClass("PlayerGui")
                    if target ~= nil then host.Parent = target end
                end
                frame.Visible = not frame.Visible
                banner(frame.Visible and "dashboard shown" or "dashboard hidden")
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
