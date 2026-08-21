-- InfinityGold controller ported from Magic Loot: locomotion, Broom and
-- selected Wand equip.
--
-- This module never teleports the character and never changes movement speed.
-- It is loaded behind a protected bridge in the main script; a load/runtime
-- failure therefore cannot prevent Magic Loot itself from opening.

local Module = {}

function Module.create(context)
    context = type(context) == "table" and context or {}
    local runService = game:GetService("RunService")
    local players = game:GetService("Players")
    local replicatedStorage = game:GetService("ReplicatedStorage")
    local bindName = "InfinityGoldLocomotionControl_"
        .. tostring(math.random(1, 1000000000))
        .. "_"
        .. tostring(os.clock())
    local state = {
        active = false,
        enteredStage = false,
        generation = 0,
        heartbeat = 0,
        preparedMode = nil,
        preparedStage = nil,
        preparedStagePart = nil,
        routeChangedAt = 0,
        stage = nil,
        stagePart = nil,
        humanoid = nil,
        root = nil,
        destination = nil,
        finalDestination = nil,
        phase = nil,
        bound = false,
        lastPosition = nil,
        lastMovedAt = 0,
        resetHumanoid = nil,
        resetCharacter = nil,
        resetDeadline = 0,
        resetUsedStage = nil,
        blockedStage = nil,
        settleUntil = 0,
        mode = nil,
        orbitAngle = 0,
        orbitRadius = 0,
        lastJumpAt = -math.huge,
    }

    local api = {}

    local DEFAULT_RUNNING_DISTANCE = 12
    local MIN_RUNNING_DISTANCE = 4
    local MAX_RUNNING_DISTANCE = 50
    local RUNNING_ORBIT_STEP = math.rad(45)
    local RUNNING_JUMP_INTERVAL = 0.9

    -- Broom only asks the server to jump to the selected stage. It deliberately
    -- never toggles/equips the broom; the game keeps ownership of the transition.
    local broomStages = { 4, 8, 13, 18, 23, 28 }
    local broomStageSet = { [4] = true, [8] = true, [13] = true, [18] = true, [23] = true, [28] = true }
    local BROOM_INITIAL_DELAY = 1
    local BROOM_CONFIRM_TIMEOUT = 5
    local MAX_BROOM_REQUEST_ATTEMPTS = 3
    local broom = {
        alive = true,
        installed = false,
        workerStarted = false,
        configReady = false,
        enabled = false,
        stage = nil,
        armed = false,
        readyAt = 0,
        delayStarted = false,
        delayDuration = 0,
        reason = nil,
        waitingForBase = false,
        sawDungeon = false,
        returnEpisode = false,
        returnToken = 0,
        lastChallenge = nil,
        epoch = 0,
        transactionActive = false,
        lastAttemptAt = -math.huge,
        lastActivatedAt = -math.huge,
        requestAttempts = 0,
        requestedStage = nil,
        activations = 0,
        status = "broom disabled",
    }
    local WAND_PLACEHOLDER = "Select a wand"
    local wand = {
        alive = true,
        installed = false,
        workerStarted = false,
        bridge = nil,
        labelsById = {},
        lastEquipAt = -math.huge,
    }

    local function broomOption(name, fallback)
        if type(context.option) ~= "function" then return fallback end
        local ok, value = pcall(context.option, name, fallback)
        return ok and value ~= nil and value or fallback
    end

    local function broomToggle()
        if type(context.toggle) ~= "function" then return false end
        local ok, value = pcall(context.toggle, "AutoBroom")
        return ok and value == true
    end

    local function broomStage(value)
        local number = tonumber(value)
        if number == nil then return nil end
        local stage = math.floor(number)
        if stage ~= number or not broomStageSet[stage] then return nil end
        return stage
    end

    local function broomReturnDelay()
        return math.clamp(tonumber(broomOption("BroomReturnDelay", 5)) or 5, 1, 30)
    end

    local function broomNotify(text)
        if type(context.notify) == "function" then
            pcall(context.notify, text)
        end
    end

    local function notifyBroomStageEntered(stage)
        if type(context.onBroomStageEntered) == "function" then
            pcall(context.onBroomStageEntered, stage)
        end
    end

    local function broomPriorityGate()
        if type(context.broomGate) ~= "function" then return true end
        local ok, allowed, detail = pcall(context.broomGate)
        if not ok then return false, "broom waiting for priority gate" end
        if allowed == true then return true end
        return false, tostring(detail or "broom waiting for base economy")
    end

    local function inDungeonChallenge()
        local player = players.LocalPlayer
        if player == nil then return nil end
        local value = player:FindFirstChild("InDungeonChallenge")
        if value == nil then return nil end
        local ok, result = pcall(function() return tonumber(value.Value) end)
        return ok and result or nil
    end

    local function locateBroomRequestRemote()
        local msg = replicatedStorage:FindFirstChild("Msg")
        local eventFolder = msg and msg:FindFirstChild("RemoteEvent") or nil
        local requestRemote = eventFolder and eventFolder:FindFirstChild("NetWorkRemoteEvent") or nil
        if requestRemote == nil or not requestRemote:IsA("RemoteEvent") then
            return nil, "NetWorkRemoteEvent unavailable"
        end
        local requestOk, requestCurrent = pcall(function()
            return requestRemote:IsDescendantOf(replicatedStorage)
        end)
        if not requestOk or not requestCurrent then
            return nil, "NetWorkRemoteEvent is stale"
        end
        return requestRemote, nil
    end

    local function invalidateBroomTransaction()
        broom.epoch = broom.epoch + 1
    end

    local function requestBroomStage(requestRemote, stage, now)
        if broom.transactionActive then return false, "transaction already active" end
        broom.epoch = broom.epoch + 1
        local token = broom.epoch
        broom.transactionActive = true
        broom.lastAttemptAt = now
        local requested, requestError = pcall(function()
            requestRemote:FireServer("关卡跳关请求", stage)
        end)
        local stillCurrent = broom.epoch == token
        broom.transactionActive = false
        if not requested then
            return false, "request failed: " .. tostring(requestError)
        end
        if not stillCurrent then
            return false, "stage request sent; result superseded by newer state"
        end
        return true, "stage request"
    end

    local function disarmBroom()
        broom.armed = false
        broom.readyAt = 0
        broom.delayStarted = false
        broom.delayDuration = 0
        broom.reason = nil
        broom.requestAttempts = 0
        broom.requestedStage = nil
    end

    local function scheduleBroomDelay(now, delay)
        broom.delayDuration = math.max(0, tonumber(delay) or 0)
        broom.delayStarted = true
        broom.readyAt = math.max(
            now + broom.delayDuration,
            broom.lastAttemptAt + 2
        )
    end

    local function deferBroomDelay()
        broom.delayStarted = false
        broom.readyAt = 0
    end

    local function armBroom(reason, _now)
        broom.waitingForBase = false
        broom.sawDungeon = false
        broom.armed = true
        broom.reason = reason
        broom.requestAttempts = 0
        broom.requestedStage = nil
        local delay = 0
        if reason == "inventory return" then
            delay = broomReturnDelay()
        elseif reason == "initial" then
            delay = BROOM_INITIAL_DELAY
        end
        broom.delayDuration = delay
        deferBroomDelay()
    end

    local function updateBroom()
        if not broom.configReady then
            broom.status = "broom waiting for config"
            return
        end
        local enabled = broomToggle()
        local selected = broomStage(broomOption("BroomStage", "4"))
        local now = os.clock()
        local challenge = inDungeonChallenge()
        if not enabled then
            if broom.enabled or broom.transactionActive then invalidateBroomTransaction() end
            broom.enabled = false
            broom.stage = selected
            broom.waitingForBase = false
            broom.sawDungeon = false
            broom.returnEpisode = false
            broom.lastChallenge = nil
            disarmBroom()
            broom.status = "broom disabled"
            return
        end
        if selected == nil then
            if broom.enabled or broom.transactionActive then invalidateBroomTransaction() end
            broom.enabled = true
            broom.stage = nil
            broom.waitingForBase = false
            broom.returnEpisode = false
            broom.lastChallenge = nil
            disarmBroom()
            broom.status = "unsupported broom stage"
            return
        end
        local wasEnabled = broom.enabled
        local changed = broom.stage ~= selected
        local previousChallenge = broom.lastChallenge
        if challenge ~= nil then broom.lastChallenge = challenge end
        local returnedToBase = previousChallenge ~= nil
            and previousChallenge > 0
            and challenge ~= nil
            and challenge <= 0
        broom.enabled = true
        broom.stage = selected
        if not wasEnabled then
            broom.returnEpisode = false
            armBroom("initial", now)
        elseif changed then
            invalidateBroomTransaction()
            if broom.waitingForBase then
                disarmBroom()
            elseif broom.returnEpisode then
                armBroom("inventory return", now)
            else
                armBroom("stage changed", now)
            end
        end
        if challenge ~= nil and challenge > 0 then broom.sawDungeon = true end
        if returnedToBase then
            invalidateBroomTransaction()
            broom.returnEpisode = true
            armBroom("inventory return", now)
        elseif broom.waitingForBase
            and challenge ~= nil
            and challenge <= 0
            and broom.sawDungeon
        then
            -- AutoReturn proved that this episode started inside a dungeon.
            -- Recover even if replication exposed nil between >0 and 0.
            invalidateBroomTransaction()
            broom.returnEpisode = true
            armBroom("inventory return", now)
        elseif broom.waitingForBase then
            broom.status = "broom waiting for InDungeonChallenge >0 -> 0"
            return
        end
        if challenge == nil then
            broom.status = "broom waiting for InDungeonChallenge"
            return
        end
        if challenge > 0 then
            local requestedStage = broom.requestedStage
            local reason = broom.reason
            if reason == "inventory return" then broom.returnEpisode = false end
            disarmBroom()
            if requestedStage == selected then
                -- Broom has now been accepted by replicated dungeon state.
                -- Hand the selected stage to the core so its configured Farm
                -- mode starts continuously without an EnterDelay pause. This
                -- latch is independent from requestAttempts because the retry
                -- counter intentionally returns to zero after every third send.
                notifyBroomStageEntered(selected)
                broom.status = string.format(
                    "broom stage %d confirmed; farm route released",
                    selected
                )
            else
                broom.status = string.format(
                    "broom stage %d already active; request skipped",
                    selected
                )
            end
            return
        end
        local priorityAllowed, priorityStatus = broomPriorityGate()
        if not priorityAllowed then
            -- Base economy owns the time before Broom. If its gate closes,
            -- restart the complete configured delay only after it reopens;
            -- Alchemy/Sell time must never consume BroomReturnDelay or retry
            -- confirmation timing.
            if broom.armed and broom.delayStarted then deferBroomDelay() end
            broom.status = priorityStatus
            return
        end
        if broom.transactionActive then return end
        if not broom.armed then return end
        if not broom.delayStarted then
            scheduleBroomDelay(now, broom.delayDuration)
        end
        if now < broom.readyAt then
            broom.status = string.format("broom stage %d armed in %.1fs", selected, broom.readyAt - now)
            return
        end
        local requestRemote, locateError = locateBroomRequestRemote()
        if requestRemote == nil then
            broom.status = "broom waiting: " .. tostring(locateError)
            return
        end
        local reason = broom.reason
        local requested, detail = requestBroomStage(
            requestRemote,
            selected,
            now
        )
        broom.requestAttempts = broom.requestAttempts + 1
        if not requested then
            if broom.requestAttempts >= MAX_BROOM_REQUEST_ATTEMPTS then
                local attempts = broom.requestAttempts
                broom.requestAttempts = 0
                broom.armed = true
                broom.reason = reason
                scheduleBroomDelay(now, BROOM_CONFIRM_TIMEOUT)
                broom.status = string.format(
                    "broom stage %d failed %d time(s); retry cycle in %.0fs: %s",
                    selected,
                    attempts,
                    BROOM_CONFIRM_TIMEOUT,
                    tostring(detail)
                )
                broomNotify(broom.status)
            else
                scheduleBroomDelay(now, BROOM_CONFIRM_TIMEOUT)
                broom.status = string.format(
                    "broom stage %d request %d/%d failed; retrying in %.0fs",
                    selected,
                    broom.requestAttempts,
                    MAX_BROOM_REQUEST_ATTEMPTS,
                    BROOM_CONFIRM_TIMEOUT
                )
            end
            return
        end
        broom.requestedStage = selected
        broom.activations = broom.activations + 1
        broom.lastActivatedAt = os.clock()
        if broom.requestAttempts >= MAX_BROOM_REQUEST_ATTEMPTS then
            local attempts = broom.requestAttempts
            broom.requestAttempts = 0
            broom.armed = true
            broom.reason = reason
            scheduleBroomDelay(now, BROOM_CONFIRM_TIMEOUT)
            broom.status = string.format(
                "broom stage %d sent %d time(s); retry cycle in %.0fs",
                selected,
                attempts,
                BROOM_CONFIRM_TIMEOUT
            )
            broomNotify(broom.status)
            return
        end
        scheduleBroomDelay(now, BROOM_CONFIRM_TIMEOUT)
        broom.status = string.format(
            "broom stage %d request %d/%d sent; waiting for room entry",
            selected,
            broom.requestAttempts,
            MAX_BROOM_REQUEST_ATTEMPTS
        )
    end

    local function startBroomWorker()
        if broom.workerStarted then return end
        broom.workerStarted = true
        task.spawn(function()
            while broom.alive do
                if type(context.alive) == "function" then
                    local aliveOk, hostAlive = pcall(context.alive)
                    if not aliveOk or hostAlive == false then break end
                end
                local ok, detail = pcall(updateBroom)
                if not ok then broom.status = "broom worker error: " .. tostring(detail) end
                task.wait(ok and 0.1 or 1)
            end
            broom.alive = false
        end)
    end

    local function wandCall(action, id)
        local bridge = wand.bridge
        if type(bridge) ~= "table" then return false, nil end
        if action == 1 and type(bridge[1]) == "function" then
            local ok, result = pcall(bridge[1], "weaponConf", 9)
            return ok, result
        end
        if action == 2 and type(bridge[2]) == "function" then
            local ok, result = pcall(bridge[2], id, 9)
            return ok, result
        end
        if action == 3 and type(bridge[3]) == "function" then
            local ok, result = pcall(bridge[3], "Wand")
            return ok, result
        end
        if action == 4 and type(bridge[4]) == "function" then
            local ok, result = pcall(bridge[4], "EQUIP_SHOP_EQUIP", {
                equipID = id,
                itemType = 9,
            })
            return ok, result
        end
        if action == 5 then
            local registry = bridge[5]
            local option = type(registry) == "table" and registry.AutoEquipWand
            if type(option) == "table" and type(option.SetValue) == "function" then
                local ok, result = pcall(option.SetValue, option, false)
                return ok, result
            end
            return true, true
        end
        return false, nil
    end

    local function selectedWandId(value)
        local direct = tonumber(value)
        if direct ~= nil and direct > 0 then return math.floor(direct) end
        if type(value) == "string" then
            local parsed = tonumber(string.match(value, "^#(%d+)"))
            return parsed and math.floor(parsed) or nil
        end
        if type(value) == "table" then
            for candidate, enabled in pairs(value) do
                if enabled then
                    local parsed = selectedWandId(candidate)
                    if parsed ~= nil then return parsed end
                end
            end
        end
        return nil
    end

    local function selectedWandOption()
        if type(context.option) ~= "function" then return WAND_PLACEHOLDER end
        local ok, value = pcall(context.option, "SelectedWand", WAND_PLACEHOLDER)
        return ok and value ~= nil and value or WAND_PLACEHOLDER
    end

    local function selectedWandToggle()
        if type(context.toggle) ~= "function" then return false end
        local ok, value = pcall(context.toggle, "AutoEquipSelectedWand")
        return ok and value == true
    end

    local function wandCatalogValues()
        local ok, raw = wandCall(1)
        local entries = {}
        local seen = {}
        if ok and type(raw) == "table" then
            for _, value in pairs(raw) do
                if type(value) == "table" then
                    local id = tonumber(value.id)
                        or tonumber(value.ID)
                        or tonumber(value.Id)
                    if id ~= nil and id > 0 then
                        id = math.floor(id)
                        if not seen[id] then
                            seen[id] = true
                            table.insert(entries, {
                                id = id,
                                price = tonumber(value.price)
                                    or tonumber(value.Price)
                                    or 0,
                                name = value.name
                                    or value.Name
                                    or value.ZhName
                                    or value.DisplayName,
                            })
                        end
                    end
                end
            end
        end
        table.sort(entries, function(left, right)
            if left.price ~= right.price then return left.price > right.price end
            return left.id < right.id
        end)

        local values = { WAND_PLACEHOLDER }
        local labelsById = {}
        for _, entry in ipairs(entries) do
            local name = type(entry.name) == "string" and entry.name ~= ""
                and entry.name
                or ("Wand " .. tostring(entry.id))
            labelsById[entry.id] = name
            table.insert(values, {
                Value = tostring(entry.id),
                Text = name,
            })
        end
        return values, labelsById
    end

    local function updateSelectedWand()
        if not broom.configReady or not selectedWandToggle() then return end
        local challenge = inDungeonChallenge()
        if challenge == nil or challenge <= 0 then return end
        local selectedId = selectedWandId(selectedWandOption())
        if selectedId == nil or wand.labelsById[selectedId] == nil then return end

        -- Selected Wand only owns equipment inside a stage. At the base it
        -- leaves manual equipment untouched.
        wandCall(5)
        local ownedOk, owned = wandCall(2, selectedId)
        if not ownedOk or owned ~= true then return end
        local currentOk, current = wandCall(3)
        if currentOk and math.floor(tonumber(current) or 0) == selectedId then return end
        local now = os.clock()
        if now - wand.lastEquipAt < 2 then return end
        wand.lastEquipAt = now
        wandCall(4, selectedId)
    end

    local function startWandWorker()
        if wand.workerStarted then return end
        wand.workerStarted = true
        task.spawn(function()
            while wand.alive do
                if type(context.alive) == "function" then
                    local aliveOk, hostAlive = pcall(context.alive)
                    if not aliveOk or hostAlive == false then break end
                end
                local ok = pcall(updateSelectedWand)
                task.wait(ok and 2 or 1)
            end
            wand.alive = false
        end)
    end

    local function clearPreparedRoute()
        state.preparedMode = nil
        state.preparedStage = nil
        state.preparedStagePart = nil
        state.routeChangedAt = 0
    end

    local function stopMovement()
        local wasActive = state.active
        local humanoid = state.humanoid
        local root = state.root

        if state.bound then
            pcall(function()
                runService:UnbindFromRenderStep(bindName)
            end)
        end

        state.generation = state.generation + 1
        state.active = false
        state.enteredStage = false
        state.heartbeat = 0
        state.mode = nil
        state.stage = nil
        state.stagePart = nil
        state.humanoid = nil
        state.root = nil
        state.destination = nil
        state.finalDestination = nil
        state.phase = nil
        state.bound = false
        state.lastPosition = nil
        state.lastMovedAt = 0
        state.orbitAngle = 0
        state.orbitRadius = 0
        state.lastJumpAt = -math.huge

        if wasActive and humanoid ~= nil and root ~= nil then
            pcall(function()
                humanoid:Move(Vector3.new(0, 0, 0), false)
            end)
        end
    end

    local function resetAll()
        stopMovement()
        clearPreparedRoute()
        state.settleUntil = 0
    end

    local function planarDistance(left, right)
        local delta = left - right
        return Vector3.new(delta.X, 0, delta.Z).Magnitude
    end

    local function readRunningDistance()
        if type(context) ~= "table" or type(context.option) ~= "function" then
            return DEFAULT_RUNNING_DISTANCE
        end
        local ok, value = pcall(
            context.option,
            "RunningDistance",
            DEFAULT_RUNNING_DISTANCE
        )
        local numeric = ok and tonumber(value) or DEFAULT_RUNNING_DISTANCE
        return math.clamp(
            numeric or DEFAULT_RUNNING_DISTANCE,
            MIN_RUNNING_DISTANCE,
            MAX_RUNNING_DISTANCE
        )
    end

    local function readEnterDelay()
        if type(context) ~= "table" or type(context.option) ~= "function" then
            return 0
        end
        local ok, value = pcall(context.option, "EnterDelay", 0)
        if not ok then
            return 0
        end
        return math.max(0, tonumber(value) or 0)
    end

    local function resolveStagePart(stage)
        if type(context) ~= "table" or type(context.stagePart) ~= "function" then
            return nil
        end
        local ok, part = pcall(context.stagePart, stage)
        if ok and part ~= nil and part:IsA("BasePart") then
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

    local function hasEnteredStage()
        if state.enteredStage then
            return true
        end
        if state.stagePart == nil or state.root == nil then
            return false
        end
        local ok, inside = pcall(function()
            return isOverFootprint(state.stagePart, state.root.Position)
        end)
        if ok and inside then
            state.enteredStage = true
        end
        return state.enteredStage
    end

    local function chooseInitialDestination(stage, stagePart, root, destination)
        if stage ~= 1 or isOverFootprint(stagePart, root.Position) then
            return destination, "final"
        end

        local secondStagePart = resolveStagePart(2)
        if secondStagePart == nil then
            return destination, "final"
        end

        local firstPoint = destination
        local secondPoint = groundPoint(secondStagePart)
        local axisDelta = secondPoint - firstPoint
        local planarAxis = Vector3.new(axisDelta.X, 0, axisDelta.Z)
        if planarAxis.Magnitude < 1 then
            return destination, "final"
        end

        -- Stages 1 and 2 define the centre line. Approaching stage 1 from
        -- the opposite side first prevents a diagonal cut from a train corner.
        local entryDirection = -planarAxis.Unit
        local localDirection = stagePart.CFrame:VectorToObjectSpace(entryDirection)
        local distanceToX = math.huge
        local distanceToZ = math.huge
        if math.abs(localDirection.X) > 0.0001 then
            distanceToX = stagePart.Size.X * 0.5 / math.abs(localDirection.X)
        end
        if math.abs(localDirection.Z) > 0.0001 then
            distanceToZ = stagePart.Size.Z * 0.5 / math.abs(localDirection.Z)
        end
        local entryOffset = math.min(distanceToX, distanceToZ)
        if entryOffset == math.huge then
            return destination, "final"
        end
        local entry = firstPoint + entryDirection * (entryOffset + 6)
        return Vector3.new(entry.X, destination.Y, entry.Z), "align"
    end

    local function runningOrbitPoint(stagePart, center, angle, radius)
        local localOffset = Vector3.new(
            math.cos(angle) * radius,
            0,
            math.sin(angle) * radius
        )
        local worldOffset = stagePart.CFrame:VectorToWorldSpace(localOffset)
        return center + Vector3.new(worldOffset.X, 0, worldOffset.Z)
    end

    local function startRunningOrbit(stagePart, root, center)
        local localRoot = stagePart.CFrame:PointToObjectSpace(root.Position)
        local planarMagnitude = Vector3.new(localRoot.X, 0, localRoot.Z).Magnitude
        local entryAngle = planarMagnitude >= 1
            and math.atan2(localRoot.Z, localRoot.X)
            or 0
        state.orbitAngle = entryAngle + RUNNING_ORBIT_STEP
        state.orbitRadius = readRunningDistance()
        state.destination = runningOrbitPoint(
            stagePart,
            center,
            state.orbitAngle,
            state.orbitRadius
        )
        state.phase = "orbit"
        state.lastPosition = root.Position
        state.lastMovedAt = os.clock()
    end

    local function updateRunningOrbit(stagePart, root, center)
        if state.phase ~= "orbit" then
            startRunningOrbit(stagePart, root, center)
        end

        local radius = readRunningDistance()
        if math.abs(radius - state.orbitRadius) > 0.05 then
            state.orbitRadius = radius
            state.destination = runningOrbitPoint(
                stagePart,
                center,
                state.orbitAngle,
                radius
            )
        end

        local distance = planarDistance(state.destination, root.Position)
        if distance <= 4 then
            state.orbitAngle = state.orbitAngle + RUNNING_ORBIT_STEP
            state.destination = runningOrbitPoint(
                stagePart,
                center,
                state.orbitAngle,
                state.orbitRadius
            )
            distance = planarDistance(state.destination, root.Position)
        end
        return distance
    end

    local function jumpWhileRunning(humanoid, now)
        if now - state.lastJumpAt < RUNNING_JUMP_INTERVAL then return end
        local grounded, floorMaterial = pcall(function()
            return humanoid.FloorMaterial
        end)
        if not grounded or floorMaterial == Enum.Material.Air then return end
        local jumped = pcall(function()
            humanoid.Jump = true
            humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
        end)
        if jumped then state.lastJumpAt = now end
    end

    local function notifyReset(mode)
        if type(context) == "table" and type(context.notify) == "function" then
            pcall(
                context.notify,
                tostring(mode) .. " stuck for 20s; resetting character"
            )
        end
    end

    local function updateStall(stage, mode, humanoid, character, root, now)
        if state.lastPosition == nil
            or planarDistance(root.Position, state.lastPosition) >= 1
        then
            state.lastPosition = root.Position
            state.lastMovedAt = now
        elseif now - state.lastMovedAt >= 20 then
            if state.resetUsedStage == stage then
                stopMovement()
                state.blockedStage = stage
                return "stage "
                    .. tostring(stage)
                    .. " "
                    .. string.lower(mode)
                    .. " paused after repeated stall"
            end
            local stuckHumanoid = humanoid
            local stuckCharacter = character
            stopMovement()
            state.resetUsedStage = stage
            state.resetHumanoid = stuckHumanoid
            state.resetCharacter = stuckCharacter
            state.resetDeadline = now + 15
            notifyReset(mode)
            local requested = pcall(function()
                stuckHumanoid:ChangeState(Enum.HumanoidStateType.Dead)
            end)
            if not requested then
                state.resetDeadline = now
                return "stage " .. tostring(stage) .. " character reset unavailable"
            end
            return "stage " .. tostring(stage) .. " resetting stuck character"
        end
        return nil
    end

    local function startWatchdog(generation)
        task.spawn(function()
            while state.active and state.generation == generation do
                task.wait(0.25)
                if state.active
                    and state.generation == generation
                    and os.clock() - state.heartbeat > 1
                then
                    resetAll()
                    break
                end
            end
        end)
    end

    function api:GetModes()
        return { "Walking", "Running" }
    end

    function api:Supports(mode)
        return mode == "Walking" or mode == "Running"
    end

    function api:Install(group, kind, bridge)
        if kind == 1 or kind == "Wand" then
            if wand.installed then return true end
            wand.bridge = bridge
            group:AddToggle("AutoEquipSelectedWand", {
                Text = "Auto Equip Selected Wand",
                Default = false,
            })
            local values, labelsById = wandCatalogValues()
            wand.labelsById = labelsById
            group:AddDropdown("SelectedWand", {
                Text = "Selected Wand",
                Values = values,
                Default = WAND_PLACEHOLDER,
                Multi = false,
                Searchable = true,
            })
            wand.installed = true
            startWandWorker()
            return true
        end
        if broom.installed then return true end
        group:AddSlider("RunningDistance", {
            Text = "Running distance from center",
            Default = DEFAULT_RUNNING_DISTANCE,
            Min = MIN_RUNNING_DISTANCE,
            Max = MAX_RUNNING_DISTANCE,
            Rounding = 0,
        })
        group:AddToggle("AutoBroom", {
            Text = "Auto Broom",
            Default = false,
        })
        group:AddDropdown("BroomStage", {
            Text = "Broom stage",
            Values = { "4", "8", "13", "18", "23", "28" },
            Default = "4",
            Multi = false,
        })
        group:AddSlider("BroomReturnDelay", {
            Text = "Broom delay after returning to base",
            Default = 5,
            Min = 1,
            Max = 30,
            Rounding = 0,
        })
        broom.installed = true
        startBroomWorker()
        return true
    end

    -- The core calls this only after every saved option has been restored.
    -- It also deliberately creates a fresh activation edge when the same
    -- already-enabled config is loaded again.
    function api:OnConfigLoaded()
        if not broom.alive then return false end
        invalidateBroomTransaction()
        broom.configReady = true
        broom.enabled = false
        broom.stage = nil
        broom.waitingForBase = false
        broom.sawDungeon = false
        broom.returnEpisode = false
        broom.lastChallenge = nil
        disarmBroom()
        broom.status = "broom config ready"
        return true
    end

    function api:OnAutoReturnFull()
        if not broomToggle() then return false end
        local selected = broomStage(broomOption("BroomStage", "4"))
        if selected == nil then return false end
        broom.enabled = true
        broom.stage = selected
        local current = inDungeonChallenge()
        if current ~= nil then broom.lastChallenge = current end
        if broom.returnEpisode then
            if current ~= nil and current > 0 then broom.sawDungeon = true end
            return true
        end
        invalidateBroomTransaction()
        broom.returnEpisode = true
        broom.returnToken = broom.returnToken + 1
        broom.waitingForBase = true
        -- The core calls this only after it has read InDungeonChallenge > 0.
        -- Preserve that proof if this module sees a transient nil during return.
        broom.sawDungeon = true
        disarmBroom()
        broom.status = "broom return token armed before DUNGEON_RETURN_TOWN"
        return true
    end

    function api:GetBroomStatus()
        return {
            enabled = broom.enabled,
            stage = broom.stage,
            armed = broom.armed,
            delayStarted = broom.delayStarted,
            delayDuration = broom.delayDuration,
            readyAt = broom.readyAt,
            waitingForBase = broom.waitingForBase,
            returnToken = broom.returnToken,
            epoch = broom.epoch,
            transactionActive = broom.transactionActive,
            lastChallenge = broom.lastChallenge,
            configReady = broom.configReady,
            requestAttempts = broom.requestAttempts,
            requestedStage = broom.requestedStage,
            activationCount = broom.activations,
            message = broom.status,
        }
    end

    function api:GetBroomStages()
        local result = {}
        for index, value in ipairs(broomStages) do result[index] = value end
        return result
    end

    function api:Prepare(mode, stage, stagePart)
        if (mode ~= "Walking" and mode ~= "Running") or stagePart == nil then
            resetAll()
            return
        end

        local now = os.clock()
        if state.resetUsedStage ~= nil and state.resetUsedStage ~= stage then
            state.resetUsedStage = nil
            state.blockedStage = nil
        end
        local routeChanged = state.preparedMode ~= mode
            or state.preparedStage ~= stage
            or state.preparedStagePart ~= stagePart

        if routeChanged then
            stopMovement()
            state.preparedMode = mode
            state.preparedStage = stage
            state.preparedStagePart = stagePart
            state.routeChangedAt = now
        end
    end

    function api:Update(mode, stage, stagePart, root, destination, bypassEnterDelay)
        if mode ~= "Walking" and mode ~= "Running" then
            resetAll()
            return "locomotion mode unavailable"
        end

        if stagePart == nil or root == nil or typeof(destination) ~= "Vector3" then
            resetAll()
            return "stage " .. tostring(stage) .. " waiting for destination"
        end

        if state.preparedMode ~= mode
            or state.preparedStage ~= stage
            or state.preparedStagePart ~= stagePart
        then
            api:Prepare(mode, stage, stagePart)
        end

        local now = os.clock()
        if bypassEnterDelay == true then
            state.routeChangedAt = now - readEnterDelay()
        end
        local remainingDelay = readEnterDelay() - (now - state.routeChangedAt)
        if remainingDelay > 0 then
            stopMovement()
            return string.format(
                "entering stage %s in %.1fs",
                tostring(stage),
                remainingDelay
            )
        end

        local character = root.Parent
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        if humanoid == nil or humanoid.Health <= 0 then
            stopMovement()
            return "stage " .. tostring(stage) .. " waiting for character"
        end

        if state.resetHumanoid ~= nil then
            if humanoid ~= state.resetHumanoid or character ~= state.resetCharacter then
                state.resetHumanoid = nil
                state.resetCharacter = nil
                state.resetDeadline = 0
                state.settleUntil = now + 1.5
            elseif now < state.resetDeadline then
                stopMovement()
                return "stage " .. tostring(stage) .. " waiting for character reset"
            else
                stopMovement()
                return "stage "
                    .. tostring(stage)
                    .. " reset not accepted; "
                    .. string.lower(mode)
                    .. " paused"
            end
        end

        if now < state.settleUntil then
            stopMovement()
            return string.format(
                "stage %s character settling %.1fs",
                tostring(stage),
                state.settleUntil - now
            )
        end

        if state.blockedStage == stage then
            stopMovement()
            return "stage "
                .. tostring(stage)
                .. " "
                .. string.lower(mode)
                .. " paused after repeated stall"
        end

        local finalDistance = planarDistance(destination, root.Position)
        if mode == "Walking" and finalDistance <= 4 then
            stopMovement()
            return "stage " .. tostring(stage) .. " walking arrived"
        end

        local sameRoute = state.active
            and state.mode == mode
            and state.stage == stage
            and state.stagePart == stagePart
            and state.humanoid == humanoid
            and state.root == root
            and state.finalDestination ~= nil
            and planarDistance(state.finalDestination, destination) <= 0.25

        if not sameRoute then
            stopMovement()
            local initialDestination, phase = chooseInitialDestination(
                stage,
                stagePart,
                root,
                destination
            )
            state.active = true
            state.enteredStage = isOverFootprint(stagePart, root.Position)
            state.generation = state.generation + 1
            state.mode = mode
            state.stage = stage
            state.stagePart = stagePart
            state.humanoid = humanoid
            state.root = root
            state.destination = initialDestination
            state.finalDestination = destination
            state.phase = phase
            state.lastPosition = root.Position
            state.lastMovedAt = now

            if mode == "Running" and state.enteredStage then
                startRunningOrbit(stagePart, root, destination)
            end

            local moved = pcall(function()
                runService:UnbindFromRenderStep(bindName)
                runService:BindToRenderStep(
                    bindName,
                    Enum.RenderPriority.Character.Value + 1,
                    function()
                        if not state.active
                            or state.humanoid ~= humanoid
                            or state.root ~= root
                            or state.destination == nil
                            or humanoid.Parent == nil
                            or humanoid.Health <= 0
                            or root.Parent == nil
                        then
                            return
                        end

                        local currentDelta = state.destination - root.Position
                        local currentPlanar = Vector3.new(
                            currentDelta.X,
                            0,
                            currentDelta.Z
                        )
                        if currentPlanar.Magnitude <= 4 then
                            humanoid:Move(Vector3.new(0, 0, 0), false)
                        else
                            humanoid:Move(currentPlanar.Unit, false)
                        end
                        if state.mode == "Running" and state.enteredStage then
                            -- Run after the normal character controller so its
                            -- per-frame Jump=false cannot cancel this request.
                            jumpWhileRunning(humanoid, os.clock())
                        end
                    end
                )
            end)
            if not moved then
                resetAll()
                return "stage " .. tostring(stage) .. " walking unavailable"
            end

            state.bound = true
            startWatchdog(state.generation)
        end

        local enteredStage = hasEnteredStage()

        if mode == "Running" and enteredStage then
            local distance = updateRunningOrbit(
                stagePart,
                root,
                destination
            )

            local stallStatus = updateStall(
                stage,
                mode,
                humanoid,
                character,
                root,
                now
            )
            if stallStatus ~= nil then return stallStatus end

            state.heartbeat = now
            return string.format(
                "stage %d running %.1f studs from center; waypoint %.1f studs",
                stage,
                state.orbitRadius,
                distance
            )
        end

        local distance = planarDistance(state.destination, root.Position)
        if state.phase == "align" and distance <= 4 then
            state.phase = "final"
            state.destination = destination
            state.lastPosition = root.Position
            state.lastMovedAt = now
            distance = planarDistance(destination, root.Position)
        end

        if mode == "Walking" and state.phase == "final" and distance <= 4 then
            stopMovement()
            return "stage " .. tostring(stage) .. " walking arrived"
        end

        local stallStatus = updateStall(
            stage,
            mode,
            humanoid,
            character,
            root,
            now
        )
        if stallStatus ~= nil then return stallStatus end

        state.heartbeat = now
        local action = state.phase == "align" and "aligning" or string.lower(mode)
        return string.format("stage %d %s %.1f studs", stage, action, distance)
    end

    function api:BlocksAttack()
        if state.active and os.clock() - state.heartbeat > 1 then
            resetAll()
        end
        return state.active and not hasEnteredStage()
    end

    function api:StopWalking()
        resetAll()
    end

    function api:Stop()
        invalidateBroomTransaction()
        broom.alive = false
        wand.alive = false
        broom.configReady = false
        broom.enabled = false
        broom.returnEpisode = false
        broom.waitingForBase = false
        broom.lastChallenge = nil
        disarmBroom()
        resetAll()
    end

    return api
end

return Module
