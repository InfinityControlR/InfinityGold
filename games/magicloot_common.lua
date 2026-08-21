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
--          gold = number, isEvent = bool, itemId = number? }
-- options: { minValue = number, filterItems = bool,
--            itemIds = { [itemId] = true } }
--
-- Event drops bypass the minimum value and the item filter (but never the
-- physical gates: landed, primary part, range). With the item filter enabled,
-- only selected material IDs pass; an empty selection passes nothing.
function Common.gateDrop(entry, options)
    options = type(options) == "table" and options or {}
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

    if options.filterItems == true then
        local itemIds = options.itemIds
        if type(itemIds) ~= "table" then return false end
        local itemId = tonumber(entry.itemId)
        if itemId == nil then return false end
        return itemIds[math.floor(itemId)] == true
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

-- Broom owns only the initial landing stage. Progressive Auto Farm resumes as
-- soon as its normal target advances beyond that landing; Farm Specific keeps
-- its explicit route unchanged.
function Common.broomFarmStageTarget(normalStage, broomStage, progressive)
    local normal = math.max(1, math.floor(tonumber(normalStage) or 1))
    local broom = tonumber(broomStage)
    if broom == nil then return normal, false end
    broom = math.max(1, math.floor(broom))
    if progressive == true and normal > broom then
        return normal, true
    end
    return broom, false
end

-- Local-space offset for Running's circular waypoints. Keeping the trigonometry
-- pure makes the orbit contract testable without Roblox services.
function Common.runningOrbitOffset(angle, radius)
    local numericAngle = tonumber(angle) or 0
    local numericRadius = math.max(0, tonumber(radius) or 0)
    return math.cos(numericAngle) * numericRadius,
        math.sin(numericAngle) * numericRadius
end

-- Parse the multi-select values used by Magic's material/potion dropdowns.
-- New values are stable numeric ID strings. Older configs may still contain
-- "#123 Name" labels, numeric keys/values, or a boolean lookup table.
function Common.parseIdSelection(values)
    local ids = {}
    if type(values) ~= "table" then return ids end
    for key, value in pairs(values) do
        local numericKeyLookup = type(key) == "number" and value == true
        local candidate = numericKeyLookup and key
            or (type(key) == "number" and value or key)
        local selected = numericKeyLookup
            or (type(key) == "number" and value ~= false)
            or value == true
        if selected then
            local id = tonumber(candidate)
                or tonumber(string.match(tostring(candidate), "^#?(%d+)"))
            if id ~= nil and id > 0 then
                ids[math.floor(id)] = true
            end
        end
    end
    return ids
end

-- Normalize live game config maps into the descriptor order used by Magic's
-- shop and selector workers. Patch releases have exposed arrays, dictionaries
-- and shallow wrapper tables, with several ID/price/name spellings. Keep this
-- pure and schema-tolerant so new rows appear without a hub update.
function Common.catalogEntries(raw, itemType)
    if type(raw) ~= "table" then return {} end

    local byId = {}
    local visited = {}
    local wrapperKeys = {
        Config = true, config = true,
        Configs = true, configs = true,
        Data = true, data = true,
        Items = true, items = true,
        List = true, list = true,
        Rows = true, rows = true,
        Values = true, values = true,
    }

    local function scan(container, depth)
        if type(container) ~= "table" or visited[container] then return end
        visited[container] = true

        for key, value in pairs(container) do
            if type(value) == "table" then
                local id = tonumber(value.id)
                    or tonumber(value.ID)
                    or tonumber(value.Id)
                    or tonumber(value.itemId)
                    or tonumber(value.ItemId)
                    or tonumber(value.itemID)
                    or tonumber(value.equipID)
                    or tonumber(value.trainId)
                    or tonumber(value.recipeId)
                    or tonumber(value.potionId)
                    or tonumber(value.materialId)
                    or tonumber(value.weaponId)
                    or tonumber(value.armorId)
                    or tonumber(key)
                if id ~= nil and id > 0 then
                    id = math.floor(id)
                    local candidate = {
                        id = id,
                        itemType = tonumber(value.itemType)
                            or tonumber(value.ItemType)
                            or tonumber(value.tp)
                            or tonumber(value.Type)
                            or itemType,
                        price = tonumber(value.Price)
                            or tonumber(value.price)
                            or tonumber(value.Cost)
                            or tonumber(value.cost)
                            or tonumber(value.Gold)
                            or tonumber(value.gold)
                            or tonumber(value.NeedGold)
                            or 0,
                        name = value.ZhName
                            or value.Name
                            or value.name
                            or value.DisplayName
                            or value.displayName
                            or value.Title,
                        raw = value,
                    }
                    local previous = byId[id]
                    if previous == nil then
                        byId[id] = candidate
                    else
                        if previous.name == nil then previous.name = candidate.name end
                        if previous.itemType == nil then
                            previous.itemType = candidate.itemType
                        end
                        if candidate.price > previous.price then
                            previous.price = candidate.price
                        end
                    end
                elseif depth < 2 and wrapperKeys[key] == true then
                    scan(value, depth + 1)
                end
            end
        end
    end

    scan(raw, 0)

    local entries = {}
    for _, entry in pairs(byId) do
        table.insert(entries, entry)
    end

    table.sort(entries, function(left, right)
        if left.price ~= right.price then return left.price > right.price end
        return left.id > right.id
    end)
    return entries
end

function Common.ownedItemIds(bag, itemType)
    local owned = {}
    if type(bag) ~= "table" then return owned end
    for _, item in pairs(bag) do
        if type(item) == "table" then
            local id = tonumber(item.id)
            local tp = tonumber(item.tp)
            if id ~= nil and (itemType == nil or tp == tonumber(itemType)) then
                owned[math.floor(id)] = true
            end
        end
    end
    return owned
end

-- Return the unique inventory object IDs for selected config IDs. This is the
-- exact identity shape needed by DRINK_POTION; config IDs are never sent in
-- place of the per-item onlyID.
function Common.selectedOnlyIds(bag, selectedIds)
    local onlyIds = {}
    if type(bag) ~= "table" or type(selectedIds) ~= "table" then
        return onlyIds
    end
    for _, item in pairs(bag) do
        if type(item) == "table" then
            local id = tonumber(item.id)
            local onlyId = tonumber(item.onlyID)
            local locked = item.lock == true or tonumber(item.lock) == 1
            if id ~= nil
                and onlyId ~= nil
                and selectedIds[math.floor(id)] == true
                and not locked
            then
                table.insert(onlyIds, onlyId)
            end
        end
    end
    return onlyIds
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
