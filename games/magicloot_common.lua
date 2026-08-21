-- InfinityGold shared pure helpers.
--
-- Roblox-free logic shared between the core script and the offline Luau test
-- suite: drop gating/priority, farm stage selection and small utilities.
-- Everything here must stay side-effect free so it can run in the plain
-- Luau CLI during regression testing.

local Common = {}

-- Event drops carry a numeric GoldValue of exactly zero.
function Common.isEventDrop(goldValue)
    return type(goldValue) == "number" and goldValue == 0
end

-- Stable drop ordering:
--   1. event drops first (raw numeric GoldValue exactly 0)
--   2. then everything else by GoldValue descending
--   3. ties broken by lower tier first (nil tier last)
--   4. remaining ties keep discovery order
--
-- entries: array of { gold = number, tier = number?, order = index }
-- Returns a new array; the input is not modified.
function Common.sortDrops(entries)
    local sorted = {}
    for index = 1, #entries do
        sorted[index] = entries[index]
    end

    table.sort(sorted, function(left, right)
        local leftEvent = left.isEvent == true
            or (left.isEvent == nil and Common.isEventDrop(left.gold))
        local rightEvent = right.isEvent == true
            or (right.isEvent == nil and Common.isEventDrop(right.gold))
        if leftEvent ~= rightEvent then
            return leftEvent
        end

        local leftGold = math.floor(tonumber(left.gold) or 0)
        local rightGold = math.floor(tonumber(right.gold) or 0)
        if leftGold ~= rightGold then
            return leftGold > rightGold
        end

        local leftTier = tonumber(left.tier)
        local rightTier = tonumber(right.tier)
        if leftTier ~= rightTier then
            if leftTier == nil then return false end
            if rightTier == nil then return true end
            return leftTier < rightTier
        end

        return (left.order or 0) < (right.order or 0)
    end)

    return sorted
end

-- Gate a single drop candidate.
--
-- entry: { hasPrimaryPart = bool, landed = bool, inRange = bool,
--          gold = number, isEvent = bool, tier = number? }
-- options: { minValue = number, filterRarity = bool,
--            tiers = { [tierNumber] = true } }
--
-- Event drops bypass the minimum value and the rarity filter (but never the
-- physical gates: landed, primary part, range). With the rarity filter on and
-- a non-empty tier set, only selected tiers pass; an empty set passes nothing.
function Common.gateDrop(entry, options)
    if entry.hasPrimaryPart ~= true then return false end
    if entry.landed ~= true then return false end
    if entry.inRange ~= true then return false end

    if entry.isEvent == true then
        return true
    end

    local minValue = tonumber(options.minValue) or 0
    if math.floor(tonumber(entry.gold) or 0) < minValue then
        return false
    end

    if options.filterRarity == true then
        local tiers = options.tiers
        if type(tiers) ~= "table" then return false end
        local tier = tonumber(entry.tier)
        if tier == nil then return false end
        return tiers[tier] == true
    end

    return true
end

-- Resolve the stage that farming should target.
--   specific      -> exactly the selected stage
--   otherwise     -> max(cleared + 1, selected stage), so Auto Farm both
--                    progresses past the cleared run and respects a manually
--                    raised starting stage; always clamped to [1, maxStage].
function Common.farmStageTarget(cleared, selected, specific, maxStage)
    local ceiling = tonumber(maxStage) or 32
    ceiling = math.max(1, math.floor(ceiling))

    if specific then
        return math.clamp(math.floor(tonumber(selected) or 1), 1, ceiling)
    end

    local clearedNext = (tonumber(cleared) or 0) + 1
    local startStage = math.floor(tonumber(selected) or 1)
    return math.clamp(math.max(clearedNext, startStage), 1, ceiling)
end

-- Parse a tier selection (strings from the UI) into a numeric lookup set.
function Common.parseTierSelection(values)
    local tiers = {}
    if type(values) ~= "table" then return tiers end
    for key, value in pairs(values) do
        local selected = type(key) == "number" or value == true
        local number = tonumber(type(key) == "number" and value or key)
        if selected and number ~= nil then
            tiers[math.floor(number)] = true
        end
    end
    return tiers
end

-- Build the SELL_MATERIAL onlyIDList from the player's Bag. Magic Loot keeps
-- sellable materials as tp=2 entries and the server expects their unique
-- onlyID values, not an empty list and not the material configuration IDs.
function Common.sellOnlyIds(bag, selectedIds, isProtected)
    local onlyIds = {}
    if type(bag) ~= "table" then return onlyIds end

    for _, item in pairs(bag) do
        if type(item) == "table" then
            local id = tonumber(item.id)
            local onlyId = tonumber(item.onlyID)
            local locked = item.lock == true or tonumber(item.lock) == 1
            local selected = selectedIds == nil
                or (id ~= nil and selectedIds[id] == true)
            local protected = false
            if id ~= nil and type(isProtected) == "function" then
                protected = isProtected(id) == true
            end

            if not locked
                and tonumber(item.tp) == 2
                and id ~= nil
                and onlyId ~= nil
                and selected
                and not protected
            then
                table.insert(onlyIds, onlyId)
            end
        end
    end

    return onlyIds
end

return Common
