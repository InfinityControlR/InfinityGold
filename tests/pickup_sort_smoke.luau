-- Offline Luau smoke tests for the shared pure helpers.
-- Run with: luau tests/pickup_sort_smoke.luau  (from the repository root)
--
-- Exercises the exact sorting, gating and stage-selection logic the core
-- script uses at runtime, without any Roblox instances.

local Common = require("../games/magicloot_common")

local failures = {}

local function check(name, condition)
    if condition then
        print("ok   " .. name)
    else
        table.insert(failures, name)
        print("FAIL " .. name)
    end
end

-- isEventDrop
check("event drop: exact zero", Common.isEventDrop(0))
check("non event: fractional value", not Common.isEventDrop(0.4))
check("event drop: negative zero", Common.isEventDrop(-0.0))
check("non event: one", not Common.isEventDrop(1))
check("non event: nil gold", not Common.isEventDrop(nil))
check("non event: numeric string", not Common.isEventDrop("0"))

-- sortDrops: event first, gold desc, tier asc, stable
local sorted = Common.sortDrops({
    { gold = 100, tier = 2, order = 1 },
    { gold = 0,   tier = 5, order = 2 },
    { gold = 300, tier = 1, order = 3 },
    { gold = 0,   tier = 1, order = 4 },
    { gold = 100, tier = 1, order = 5 },
})
check("sort: four results", #sorted == 5)
check("sort: events first, tier asc among them", sorted[1].order == 4 and sorted[2].order == 2)
check("sort: gold descending", sorted[3].gold == 300)
check("sort: tie tier ascending", sorted[4].tier == 1 and sorted[5].tier == 2)

local stable = Common.sortDrops({
    { gold = 50, tier = 3, order = 1 },
    { gold = 50, tier = 3, order = 2 },
    { gold = 50, tier = 3, order = 3 },
})
check("sort: stable on full tie", stable[1].order == 1 and stable[3].order == 3)

-- gateDrop: physical gates always apply
local base = {
    hasPrimaryPart = true,
    landed = true,
    inRange = true,
    gold = 25,
    itemId = 21,
}
check("gate: passes plain drop", Common.gateDrop(base, { minValue = 0 }))
check("gate: no primary part", not Common.gateDrop(
    { hasPrimaryPart = false, landed = true, inRange = true, gold = 25 },
    { minValue = 0 }
))
check("gate: not landed", not Common.gateDrop(
    { hasPrimaryPart = true, landed = false, inRange = true, gold = 25 },
    { minValue = 0 }
))
check("gate: out of range", not Common.gateDrop(
    { hasPrimaryPart = true, landed = true, inRange = false, gold = 0 },
    { minValue = 0 }
))

-- gateDrop: event drops bypass value and item filters
local eventDrop = {
    hasPrimaryPart = true,
    landed = true,
    inRange = true,
    gold = 0,
    isEvent = true,
    itemId = 999,
}
check("gate: event ignores minimum", Common.gateDrop(eventDrop, { minValue = 1000 }))
check("gate: event ignores item filter", Common.gateDrop(
    eventDrop,
    { minValue = 0, filterItems = true, itemIds = { [1] = true } }
))
check("gate: normal respects minimum", not Common.gateDrop(
    { hasPrimaryPart = true, landed = true, inRange = true, gold = 5, tier = 1 },
    { minValue = 10 }
))
check("gate: accepts a drop above a multi-billion minimum", Common.gateDrop(
    { hasPrimaryPart = true, landed = true, inRange = true, gold = 7500000000000, tier = 1 },
    { minValue = 5000000000000 }
))
check("gate: rejects a drop below a multi-billion minimum", not Common.gateDrop(
    { hasPrimaryPart = true, landed = true, inRange = true, gold = 4500000000000, tier = 1 },
    { minValue = 5000000000000 }
))

-- gateDrop: item filter semantics
local selectedDrop = {
    hasPrimaryPart = true,
    landed = true,
    inRange = true,
    gold = 50,
    itemId = 103,
}
check("gate: item selected", Common.gateDrop(
    selectedDrop,
    { minValue = 0, filterItems = true, itemIds = { [103] = true } }
))
check("gate: item rejected", not Common.gateDrop(
    selectedDrop,
    { minValue = 0, filterItems = true, itemIds = { [104] = true } }
))
check("gate: item empty set rejects", not Common.gateDrop(
    selectedDrop,
    { minValue = 0, filterItems = true, itemIds = {} }
))
check("gate: missing item id rejects", not Common.gateDrop(
    { hasPrimaryPart = true, landed = true, inRange = true, gold = 50 },
    { minValue = 0, filterItems = true, itemIds = { [103] = true } }
))

-- farmStageTarget
check("farm: specific exact", Common.farmStageTarget(10, 5, true, 32) == 5)
check("farm: progress past clear", Common.farmStageTarget(10, 1, false, 32) == 11)
check("farm: raised start", Common.farmStageTarget(2, 28, false, 32) == 28)
check("farm: progresses through stage 32", Common.farmStageTarget(31, 1, false, 32) == 32)
check("farm: clamp to ceiling", Common.farmStageTarget(40, 1, false, 32) == 32)
check("farm: clamp specific", Common.farmStageTarget(10, 99, true, 32) == 32)
check("farm: default ceiling is 32", Common.farmStageTarget(40, 1, false) == 32)
check("farm: nil cleared uses selected", Common.farmStageTarget(nil, 3, false, 32) == 3)

local orbitX, orbitZ = Common.runningOrbitOffset(0, 12)
check("running orbit: zero angle", math.abs(orbitX - 12) < 0.001
    and math.abs(orbitZ) < 0.001)
orbitX, orbitZ = Common.runningOrbitOffset(math.pi * 0.5, 20)
check("running orbit: quarter turn", math.abs(orbitX) < 0.001
    and math.abs(orbitZ - 20) < 0.001)

-- parseIdSelection: stable IDs, legacy labels and persisted table shapes.
local selectedIds = Common.parseIdSelection({ "#21 Ember", "34" })
check("ids: label selection", selectedIds[21] and selectedIds[34])
local selectedIdMap = Common.parseIdSelection({ ["#55 Potion"] = true, ["66"] = false })
check("ids: multiselect map", selectedIdMap[55] and not selectedIdMap[66])
local selectedNumericIdMap = Common.parseIdSelection({ [77] = true, [88] = false })
check("ids: numeric lookup map", selectedNumericIdMap[77] and not selectedNumericIdMap[88])
check("ids: non-table", next(Common.parseIdSelection(nil)) == nil)

-- catalogEntries: live configs use Price while older fixtures use price.
local catalog = Common.catalogEntries({
    [4] = { ZhName = "Starter", Price = 10 },
    [8] = { id = 8, name = "Best", price = 500 },
    bad = { Price = 999 },
}, 9)
check("catalog: normalized and sorted", #catalog == 2
    and catalog[1].id == 8
    and catalog[1].price == 500
    and catalog[2].itemType == 9)

-- New game patches may wrap a config and change field capitalization. These
-- rows must appear automatically without adding their IDs to InfinityGold.
local patchedCatalog = Common.catalogEntries({
    Data = {
        { ID = 101, Name = "Patch item", Cost = 700, ItemType = 2 },
        { ItemId = 102, DisplayName = "Patch potion", Gold = 900 },
        { itemID = 103, ZhName = "Patch gear", price = 800 },
    },
    Items = {
        duplicate = { id = 101, Price = 0 },
        train = { trainId = 104, name = "Patch ground", Price = 600 },
    },
}, 9)
check("catalog: patch aliases and wrappers", #patchedCatalog == 4
    and patchedCatalog[1].id == 102
    and patchedCatalog[2].id == 103
    and patchedCatalog[3].id == 101
    and patchedCatalog[3].name == "Patch item"
    and patchedCatalog[4].id == 104)

local owned = Common.ownedItemIds({
    { id = 4, tp = 9 },
    { id = 8, tp = 13 },
}, 9)
check("catalog: owned item type", owned[4] and not owned[8])

local potionOnlyIds = Common.selectedOnlyIds({
    { id = 21, onlyID = 901, lock = false },
    { id = 22, onlyID = 902, lock = true },
    { id = 23, onlyID = 903, lock = 0 },
}, { [21] = true, [22] = true })
check("potions: selected onlyID and lock gate",
    #potionOnlyIds == 1 and potionOnlyIds[1] == 901)

-- sellOnlyIds: send unique inventory IDs for unlocked tp=2 materials only.
local sellIds = Common.sellOnlyIds({
    { id = 10, onlyID = 101, tp = 2, lock = false },
    { id = 11, onlyID = 102, tp = 2, lock = true },
    { id = 12, onlyID = 103, tp = 1, lock = false },
    { id = 13, onlyID = 104, tp = 2, lock = 0 },
    { id = 14, onlyID = 105, tp = 2, lock = false },
    { id = 15, tp = 2, lock = false },
}, nil, function(id)
    return id == 14
end)
check("sell: exact eligible onlyIDs", #sellIds == 2 and sellIds[1] == 101 and sellIds[2] == 104)

local selectedSellIds = Common.sellOnlyIds({
    { id = 20, onlyID = 201, tp = 2 },
    { id = 21, onlyID = 202, tp = 2 },
}, { [21] = true })
check("sell: selected material IDs", #selectedSellIds == 1 and selectedSellIds[1] == 202)
check("sell: missing bag", #Common.sellOnlyIds(nil) == 0)

if #failures > 0 then
    print(string.format("%d smoke checks failed", #failures))
    error("pickup_sort_smoke failed")
end

print("all pickup_sort_smoke checks passed")
