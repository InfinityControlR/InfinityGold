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
local base = { hasPrimaryPart = true, landed = true, inRange = true, gold = 25, tier = 2 }
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

-- gateDrop: event drops bypass value and rarity filters
local eventDrop = { hasPrimaryPart = true, landed = true, inRange = true, gold = 0, isEvent = true, tier = 9 }
check("gate: event ignores minimum", Common.gateDrop(eventDrop, { minValue = 1000 }))
check("gate: event ignores rarity", Common.gateDrop(
    eventDrop,
    { minValue = 0, filterRarity = true, tiers = { [1] = true } }
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

-- gateDrop: rarity filter semantics
local rareDrop = { hasPrimaryPart = true, landed = true, inRange = true, gold = 50, tier = 3 }
check("gate: rarity selected", Common.gateDrop(
    rareDrop,
    { minValue = 0, filterRarity = true, tiers = { [3] = true } }
))
check("gate: rarity rejected", not Common.gateDrop(
    rareDrop,
    { minValue = 0, filterRarity = true, tiers = { [2] = true } }
))
check("gate: rarity empty set rejects", not Common.gateDrop(
    rareDrop,
    { minValue = 0, filterRarity = true, tiers = {} }
))
check("gate: rarity without tier rejects", not Common.gateDrop(
    { hasPrimaryPart = true, landed = true, inRange = true, gold = 50 },
    { minValue = 0, filterRarity = true, tiers = { [3] = true } }
))
check("gate: tier 10 selected", Common.gateDrop(
    { hasPrimaryPart = true, landed = true, inRange = true, gold = 50, tier = 10 },
    { minValue = 0, filterRarity = true, tiers = { [10] = true } }
))

-- farmStageTarget
check("farm: specific exact", Common.farmStageTarget(10, 5, true, 27) == 5)
check("farm: progress past clear", Common.farmStageTarget(10, 1, false, 27) == 11)
check("farm: raised start", Common.farmStageTarget(2, 15, false, 27) == 15)
check("farm: clamp to ceiling", Common.farmStageTarget(30, 1, false, 27) == 27)
check("farm: clamp specific", Common.farmStageTarget(10, 99, true, 27) == 27)
check("farm: nil cleared uses selected", Common.farmStageTarget(nil, 3, false, 27) == 3)

-- parseTierSelection
local tiers = Common.parseTierSelection({ "1", "3", "x", 4 })
check("tiers: 1,3,4 selected", tiers[1] and tiers[3] and tiers[4] and not tiers[2])
local tierMap = Common.parseTierSelection({ ["2"] = true, ["5"] = true, ["8"] = false })
check("tiers: multi-select map", tierMap[2] and tierMap[5] and not tierMap[8])
local highTiers = Common.parseTierSelection({ "9", "10" })
check("tiers: 9 and 10", highTiers[9] and highTiers[10])
check("tiers: non-table", next(Common.parseTierSelection(nil)) == nil)

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
