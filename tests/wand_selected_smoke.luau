local workers = {}
task = {
    spawn = function(callback)
        table.insert(workers, callback)
    end,
    wait = function()
        error("stop worker", 0)
    end,
}

local runService = {}
local challenge = 0
local challengeValue = { Value = 0 }
local player = {}
function player:FindFirstChild(name)
    assert(name == "InDungeonChallenge")
    challengeValue.Value = challenge
    return challengeValue
end
local players = { LocalPlayer = player }
local replicatedStorage = {}
game = {}
function game:GetService(name)
    if name == "RunService" then return runService end
    if name == "Players" then return players end
    if name == "ReplicatedStorage" then return replicatedStorage end
    error("unexpected service " .. tostring(name))
end

local selectedValue = "#22 Vampiric"
local selectedEnabled = true
local context = {}
function context.option(name, fallback)
    if name == "SelectedWand" then return selectedValue end
    return fallback
end
function context.toggle(name)
    return name == "AutoEquipSelectedWand" and selectedEnabled
end
function context.alive()
    return true
end

local catalog = {
    { id = 10, price = 100, name = "Strong" },
    { id = 22, price = 90, name = "Vampiric" },
}
local owned = { [10] = true, [22] = true }
local equipped = 10
local equipCalls = {}
local bestDisabled = 0
local catalogCalls = 0
local registry = {
    AutoEquipWand = {
        SetValue = function(_, value)
            assert(value == false)
            bestDisabled = bestDisabled + 1
        end,
    },
}
local bridge = {
    [1] = function(configName, itemType)
        assert(configName == "weaponConf")
        assert(itemType == 9)
        catalogCalls = catalogCalls + 1
        return catalog
    end,
    [2] = function(id, itemType)
        assert(itemType == 9)
        return owned[id] == true
    end,
    [3] = function(kind)
        assert(kind == "Wand")
        return equipped
    end,
    [4] = function(action, payload)
        table.insert(equipCalls, { action = action, payload = payload })
        equipped = payload.equipID
        return true
    end,
    [5] = registry,
}

local controls = {}
local dropdown = { values = {} }
local group = {}
function group:AddToggle(key, options)
    table.insert(controls, { kind = "toggle", key = key, options = options })
end
function group:AddDropdown(key, options)
    table.insert(controls, { kind = "dropdown", key = key, options = options })
    dropdown.values = options.Values
    return dropdown
end

local Locomotion = require("../games/magicloot_locomotion")
local controller = Locomotion.create(context)
assert(controller:Install(group, 1, bridge))
controller:OnConfigLoaded()

assert(#controls == 2)
assert(controls[1].key == "AutoEquipSelectedWand")
assert(controls[2].key == "SelectedWand")
assert(controls[2].options.Searchable == true)
assert(dropdown.values[1] == "Select a wand")
assert(dropdown.values[2].Value == "10" and dropdown.values[2].Text == "Strong")
assert(dropdown.values[3].Value == "22" and dropdown.values[3].Text == "Vampiric")
assert(catalogCalls == 1)
assert(#workers == 1)

-- Outside a stage, Selected Wand must not disable Best or touch equipment.
local ok, detail = pcall(workers[1])
assert(not ok and tostring(detail) == "stop worker")
assert(bestDisabled == 0)
assert(#equipCalls == 0)
assert(equipped == 10)

-- Updating the live catalog does not mutate an already-installed list.
-- A full script reload will read the updated catalog during Install instead.
catalog = {
    { id = 33, price = 120, name = "Future" },
    { id = 10, price = 100, name = "Strong" },
    { id = 22, price = 90, name = "Vampiric II" },
}
owned[33] = false
challenge = 1
ok, detail = pcall(workers[1])
assert(not ok and tostring(detail) == "stop worker")
assert(catalogCalls == 1)
assert(dropdown.values[2].Value == "10" and dropdown.values[2].Text == "Strong")
assert(dropdown.values[3].Value == "22" and dropdown.values[3].Text == "Vampiric")
assert(bestDisabled == 1)
assert(#equipCalls == 1)
assert(equipCalls[1].action == "EQUIP_SHOP_EQUIP")
assert(equipCalls[1].payload.equipID == 22)
assert(equipCalls[1].payload.itemType == 9)
assert(equipped == 22)

-- Once equipped, the 2-second worker confirms state and sends no duplicate.
ok, detail = pcall(workers[1])
assert(not ok and tostring(detail) == "stop worker")
assert(#equipCalls == 1)

-- Leaving the stage stops enforcement and allows any manual equipment.
local disabledInside = bestDisabled
challenge = 0
equipped = 10
ok, detail = pcall(workers[1])
assert(not ok and tostring(detail) == "stop worker")
assert(#equipCalls == 1)
assert(bestDisabled == disabledInside)
assert(equipped == 10)

-- A new controller (full script reload) sees future catalog entries.
local controls2 = {}
local dropdown2 = { values = {} }
local group2 = {}
function group2:AddToggle(key, options)
    table.insert(controls2, { kind = "toggle", key = key, options = options })
end
function group2:AddDropdown(key, options)
    table.insert(controls2, { kind = "dropdown", key = key, options = options })
    dropdown2.values = options.Values
    return dropdown2
end
local controller2 = Locomotion.create(context)
assert(controller2:Install(group2, 1, bridge))
controller2:OnConfigLoaded()
assert(catalogCalls == 2)
assert(dropdown2.values[1] == "Select a wand")
assert(dropdown2.values[2].Value == "33" and dropdown2.values[2].Text == "Future")
assert(dropdown2.values[3].Value == "10" and dropdown2.values[3].Text == "Strong")
assert(dropdown2.values[4].Value == "22" and dropdown2.values[4].Text == "Vampiric II")

-- A visible but unowned wand is never sent to the equip action inside a stage.
selectedValue = "#33 Future"
challenge = 1
ok, detail = pcall(workers[2])
assert(not ok and tostring(detail) == "stop worker")
assert(#equipCalls == 1)

print("wand_selected_smoke=ok")
