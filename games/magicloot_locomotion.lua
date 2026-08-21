-- InfinityGold external locomotion controller — Magic-compatible Walking and
-- Running plus the native Broom jump.
--
-- This module never teleports the character and never changes movement speed.
-- It is loaded behind a protected bridge in the main script; a load/runtime
-- failure therefore cannot prevent InfinityGold itself from opening.

local Module = {}

function Module._entryDirection2D(stage, centerX, centerZ, neighborX, neighborZ)
    stage = tonumber(stage)
    centerX = tonumber(centerX)
    centerZ = tonumber(centerZ)
    neighborX = tonumber(neighborX)
    neighborZ = tonumber(neighborZ)
    if stage == nil or centerX == nil or centerZ == nil
        or neighborX == nil or neighborZ == nil
    then
        return nil, nil
    end

    local directionSign = stage > 1 and 1 or -1
    local deltaX = (neighborX - centerX) * directionSign
    local deltaZ = (neighborZ - centerZ) * directionSign
    local magnitude = math.sqrt(deltaX * deltaX + deltaZ * deltaZ)
    if magnitude < 1 then return nil, nil end
    return deltaX / magnitude, deltaZ / magnitude
end

-- Pure geometry helper kept on the module so the exact oriented-footprint
-- calculation can be exercised by the offline Luau smoke suite. The caller
-- supplies a unit direction already transformed into the stage's local space.
function Module._halfwayFootprintDistance(sizeX, sizeZ, localX, localZ)
    sizeX = tonumber(sizeX)
    sizeZ = tonumber(sizeZ)
    localX = tonumber(localX)
    localZ = tonumber(localZ)
    if sizeX == nil or sizeZ == nil or sizeX <= 0 or sizeZ <= 0
        or localX == nil or localZ == nil
    then
        return nil
    end

    local distanceToX = math.huge
    local distanceToZ = math.huge
    if math.abs(localX) > 0.0001 then
        distanceToX = sizeX * 0.5 / math.abs(localX)
    end
    if math.abs(localZ) > 0.0001 then
        distanceToZ = sizeZ * 0.5 / math.abs(localZ)
    end
    local edgeDistance = math.min(distanceToX, distanceToZ)
    if edgeDistance == math.huge then return nil end
    return edgeDistance * 0.5
end

function Module.create(context)
    context = type(context) == "table" and context or {}
    local runService = game:GetService("RunService")
    local players = game:GetService("Players")
    local replicatedStorage = game:GetService("ReplicatedStorage")
    local bindName = "InfinityGoldWalking_"
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
        mode = nil,
        stagePart = nil,
        humanoid = nil,
        root = nil,
        destination = nil,
        finalDestination = nil,
        phase = nil,
        bound = false,
        lastPosition = nil,
        lastMovedAt = 0,
        orbitAngle = 0,
        orbitRadius = 0,
        lastJumpAt = -math.huge,
        resetHumanoid = nil,
        resetCharacter = nil,
        resetDeadline = 0,
        resetUsedStage = nil,
        blockedStage = nil,
        settleUntil = 0,
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
    local broomStageSet = {
        [4] = true,
        [8] = true,
        [13] = true,
        [18] = true,
        [23] = true,
        [28] = true,
    }
    local BROOM_INITIAL_DELAY = 1
    local BROOM_CONFIRM_TIMEOUT = 5
    local BROOM_ARM_TIMEOUT = 30
    local MAX_BROOM_REQUEST_ATTEMPTS = 3
    local broom = {
        alive = true,
        installed = false,
        workerStarted = false,
        configReady = false,
        suspended = false,
        enabled = false,
        stage = nil,
        armed = false,
        readyAt = 0,
        giveUpAt = 0,
        finalConfirmationPending = false,
        reason = nil,
        waitingForBase = false,
        externalReturnPending = false,
        sawDungeon = false,
        returnEpisode = false,
        returnToken = 0,
        lastChallenge = nil,
        epoch = 0,
        transactionActive = false,
        lastAttemptAt = -math.huge,
        lastActivatedAt = -math.huge,
        requestAttempts = 0,
        activations = 0,
        status = "broom disabled",
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
        broom.giveUpAt = 0
        broom.finalConfirmationPending = false
        broom.reason = nil
        broom.requestAttempts = 0
    end

    local function armBroom(reason, now)
        broom.waitingForBase = false
        broom.sawDungeon = false
        broom.armed = true
        broom.reason = reason
        broom.requestAttempts = 0
        local delay = 0
        if reason == "inventory return" then
            delay = broomReturnDelay()
        elseif reason == "initial" then
            delay = BROOM_INITIAL_DELAY
        end
        broom.readyAt = math.max(now + delay, broom.lastAttemptAt + 2)
        broom.giveUpAt = broom.readyAt + BROOM_ARM_TIMEOUT
    end

    local function updateBroom()
        if not broom.configReady then
            broom.status = "broom waiting for config"
            return
        end
        if broom.suspended then
            broom.status = "broom paused for Alchemy"
            return
        end
        local enabled = broomToggle()
        local selected = broomStage(broomOption("BroomStage", "4"))
        local now = os.clock()
        local challenge = inDungeonChallenge()
        local arrivalToken = nil
        if type(context.returnArrivalToken) == "function"
            and type(context.acknowledgeReturnArrival) == "function"
        then
            local tokenOk, token = pcall(context.returnArrivalToken)
            token = tokenOk and math.floor(tonumber(token) or 0) or 0
            if token > 0 then arrivalToken = token end
        end
        local function acknowledgeArrival()
            if arrivalToken ~= nil
                and type(context.acknowledgeReturnArrival) == "function"
            then
                pcall(context.acknowledgeReturnArrival, arrivalToken)
            end
        end
        if not enabled then
            acknowledgeArrival()
            if broom.enabled or broom.transactionActive then invalidateBroomTransaction() end
            broom.enabled = false
            broom.stage = selected
            broom.waitingForBase = false
            broom.externalReturnPending = false
            broom.sawDungeon = false
            broom.returnEpisode = false
            broom.lastChallenge = nil
            disarmBroom()
            broom.status = "broom disabled"
            return
        end
        if selected == nil then
            acknowledgeArrival()
            if broom.enabled or broom.transactionActive then invalidateBroomTransaction() end
            broom.enabled = true
            broom.stage = nil
            broom.waitingForBase = false
            broom.externalReturnPending = false
            broom.returnEpisode = false
            broom.lastChallenge = nil
            disarmBroom()
            broom.status = "unsupported broom stage"
            return
        end
        if type(context.returnTravelPending) == "function" then
            local blockedOk, blocked = pcall(context.returnTravelPending)
            if blockedOk and blocked == true then
                broom.externalReturnPending = true
                broom.status = "broom waiting for inventory return travel"
                return
            end
        end
        local externalReturnReleased = broom.externalReturnPending
            or arrivalToken ~= nil
        broom.externalReturnPending = false
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
            broom.returnEpisode = externalReturnReleased
            armBroom(externalReturnReleased and "inventory return" or "initial", now)
        elseif changed then
            invalidateBroomTransaction()
            if externalReturnReleased then
                broom.returnEpisode = true
                armBroom("inventory return", now)
            elseif broom.waitingForBase then
                disarmBroom()
                broom.giveUpAt = now + BROOM_ARM_TIMEOUT
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
        elseif externalReturnReleased and wasEnabled and not changed then
            invalidateBroomTransaction()
            broom.returnEpisode = true
            armBroom("inventory return", now)
        elseif broom.waitingForBase then
            if broom.giveUpAt > 0 and now >= broom.giveUpAt then
                broom.waitingForBase = false
                broom.returnEpisode = false
                disarmBroom()
                broom.status = "broom return transition timed out"
                broomNotify(broom.status)
                return
            end
            broom.status = "broom waiting for InDungeonChallenge >0 -> 0"
            return
        end
        acknowledgeArrival()
        if broom.armed and broom.giveUpAt > 0 and now >= broom.giveUpAt then
            local reason = broom.reason
            if reason == "inventory return" then broom.returnEpisode = false end
            disarmBroom()
            broom.status = string.format(
                "broom stage %d paused: game state or remote stayed unavailable",
                selected
            )
            broomNotify(broom.status)
            return
        end
        if challenge == nil then
            broom.status = "broom waiting for InDungeonChallenge"
            return
        end
        if challenge > 0 then
            local attempts = broom.requestAttempts
            local reason = broom.reason
            if reason == "inventory return" then broom.returnEpisode = false end
            disarmBroom()
            if attempts > 0 then
                broom.status = string.format(
                    "broom stage %d confirmed after %d request(s)",
                    selected,
                    attempts
                )
            else
                broom.status = string.format(
                    "broom stage %d already active; request skipped",
                    selected
                )
            end
            return
        end
        if broom.finalConfirmationPending then
            if now < broom.readyAt then
                broom.status = string.format(
                    "broom stage %d final request sent; waiting %.1fs for room entry",
                    selected,
                    broom.readyAt - now
                )
                return
            end
            local attempts = broom.requestAttempts
            local reason = broom.reason
            if reason == "inventory return" then broom.returnEpisode = false end
            disarmBroom()
            broom.status = string.format(
                "broom stage %d sent %d time(s); no dungeon confirmation",
                selected,
                attempts
            )
            broomNotify(broom.status)
            return
        end
        if broom.transactionActive then return end
        if not broom.armed then return end
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
                if reason == "inventory return" then broom.returnEpisode = false end
                disarmBroom()
                broom.status = string.format(
                    "broom stage %d paused after %d failed request(s): %s",
                    selected,
                    attempts,
                    tostring(detail)
                )
                broomNotify(broom.status)
            else
                broom.readyAt = now + BROOM_CONFIRM_TIMEOUT
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
        broom.activations = broom.activations + 1
        broom.lastActivatedAt = os.clock()
        if broom.requestAttempts >= MAX_BROOM_REQUEST_ATTEMPTS then
            broom.finalConfirmationPending = true
            broom.readyAt = now + BROOM_CONFIRM_TIMEOUT
            broom.status = string.format(
                "broom stage %d final request %d/%d sent; waiting for room entry",
                selected,
                broom.requestAttempts,
                MAX_BROOM_REQUEST_ATTEMPTS
            )
            return
        end
        broom.readyAt = now + BROOM_CONFIRM_TIMEOUT
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

    local function resolveWalkingDestination(stage, stagePart, centerDestination)
        local stageNumber = tonumber(stage)
        if stageNumber == nil then return centerDestination, nil, nil end
        stageNumber = math.floor(stageNumber)

        local neighborStage = stageNumber > 1 and (stageNumber - 1) or 2
        local neighborPart = resolveStagePart(neighborStage)
        if neighborPart == nil then return centerDestination, nil, nil end

        local neighborPoint = groundPoint(neighborPart)
        -- Later stages face their predecessor. Stage 1 has no predecessor,
        -- so its entrance is the side opposite stage 2.
        local directionX, directionZ = Module._entryDirection2D(
            stageNumber,
            centerDestination.X,
            centerDestination.Z,
            neighborPoint.X,
            neighborPoint.Z
        )
        if directionX == nil then return centerDestination, nil, nil end

        local entryDirection = Vector3.new(directionX, 0, directionZ)
        local localDirection = stagePart.CFrame:VectorToObjectSpace(entryDirection)
        local halfwayDistance = Module._halfwayFootprintDistance(
            stagePart.Size.X,
            stagePart.Size.Z,
            localDirection.X,
            localDirection.Z
        )
        if halfwayDistance == nil then return centerDestination, nil, nil end

        return centerDestination + entryDirection * halfwayDistance,
            entryDirection,
            halfwayDistance * 2
    end

    local function chooseInitialDestination(
        stage,
        stagePart,
        root,
        centerDestination,
        finalDestination,
        entryDirection,
        entryOffset
    )
        if stage ~= 1 or isOverFootprint(stagePart, root.Position) then
            return finalDestination, "final"
        end

        -- Stages 1 and 2 define the centre line. Approaching stage 1 from
        -- the opposite side first prevents a diagonal cut from a train corner.
        if entryDirection == nil or entryOffset == nil then
            return finalDestination, "final"
        end
        local entry = centerDestination + entryDirection * (entryOffset + 6)
        return Vector3.new(entry.X, finalDestination.Y, entry.Z), "align"
    end

    local function chooseRunningInitialDestination(
        stage,
        stagePart,
        root,
        destination
    )
        if stage ~= 1 or isOverFootprint(stagePart, root.Position) then
            return destination, "final"
        end

        local secondStagePart = resolveStagePart(2)
        if secondStagePart == nil then
            return destination, "final"
        end

        local secondPoint = groundPoint(secondStagePart)
        local axisDelta = secondPoint - destination
        local planarAxis = Vector3.new(axisDelta.X, 0, axisDelta.Z)
        if planarAxis.Magnitude < 1 then
            return destination, "final"
        end

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
        local entry = destination + entryDirection * (entryOffset + 6)
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

    function api:Install(group)
        if broom.installed then return true end
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
        broom.externalReturnPending = false
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
        broom.externalReturnPending = false
        broom.sawDungeon = current ~= nil and current > 0
        disarmBroom()
        broom.giveUpAt = os.clock() + BROOM_ARM_TIMEOUT
        broom.status = "broom return token armed before DUNGEON_RETURN_TOWN"
        return true
    end

    function api:SetBroomSuspended(suspended)
        if not broom.alive then return false end
        broom.suspended = suspended == true
        if broom.suspended then
            broom.status = "broom paused for Alchemy"
        else
            broom.status = "broom resumed after Alchemy"
        end
        return true
    end

    function api:GetBroomStatus()
        return {
            enabled = broom.enabled,
            stage = broom.stage,
            armed = broom.armed,
            waitingForBase = broom.waitingForBase,
            returnToken = broom.returnToken,
            epoch = broom.epoch,
            transactionActive = broom.transactionActive,
            lastChallenge = broom.lastChallenge,
            configReady = broom.configReady,
            suspended = broom.suspended,
            requestAttempts = broom.requestAttempts,
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

    function api:Update(mode, stage, stagePart, root, destination)
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

        local finalDestination = destination
        local entryDirection = nil
        local entryOffset = nil
        if mode == "Walking" then
            finalDestination, entryDirection, entryOffset =
                resolveWalkingDestination(stage, stagePart, destination)
        end
        local finalDistance = planarDistance(finalDestination, root.Position)
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
            and planarDistance(state.finalDestination, finalDestination) <= 0.25

        if not sameRoute then
            stopMovement()
            local initialDestination
            local phase
            if mode == "Walking" then
                initialDestination, phase = chooseInitialDestination(
                    stage,
                    stagePart,
                    root,
                    destination,
                    finalDestination,
                    entryDirection,
                    entryOffset
                )
            else
                initialDestination, phase = chooseRunningInitialDestination(
                    stage,
                    stagePart,
                    root,
                    destination
                )
            end
            state.active = true
            state.enteredStage = isOverFootprint(stagePart, root.Position)
            state.generation = state.generation + 1
            state.mode = mode
            state.stage = stage
            state.stagePart = stagePart
            state.humanoid = humanoid
            state.root = root
            state.destination = initialDestination
            state.finalDestination = finalDestination
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
                return "stage "
                    .. tostring(stage)
                    .. " "
                    .. string.lower(mode)
                    .. " unavailable"
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
            state.destination = finalDestination
            state.lastPosition = root.Position
            state.lastMovedAt = now
            distance = planarDistance(finalDestination, root.Position)
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

    -- Temporarily suspend the per-frame walking driver without forgetting the
    -- prepared route or restarting EnterDelay. Alchemy uses this while it
    -- performs its short hidden actor/finish interaction.
    function api:PauseWalking()
        stopMovement()
    end

    function api:Stop()
        invalidateBroomTransaction()
        broom.alive = false
        broom.configReady = false
        broom.suspended = false
        broom.enabled = false
        broom.returnEpisode = false
        broom.waitingForBase = false
        broom.externalReturnPending = false
        broom.lastChallenge = nil
        disarmBroom()
        resetAll()
    end

    return api
end

return Module
