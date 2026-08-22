local Common = require("../games/magicloot_common")

assert(Common.dragonWorldEventId(3) == 3)
assert(Common.dragonWorldEventId("4") == 4)
assert(Common.dragonWorldEventId(2) == nil)
assert(Common.dragonWorldEventId("FireDragon") == nil)

local phase, activeId, completedId, finished = Common.worldEventTransition(
    "idle", nil, nil, 3, 0, true
)
assert(phase == "seeking" and activeId == 3 and completedId == nil)
assert(finished == false)

phase, activeId, completedId, finished = Common.worldEventTransition(
    phase, activeId, completedId, 3, 1, true
)
assert(phase == "combat" and activeId == 3 and finished == false)

-- The server clearing InEventCombat is the only completion signal. No local
-- timer or dragon health/name is involved.
phase, activeId, completedId, finished = Common.worldEventTransition(
    phase, activeId, completedId, 3, 0, true
)
assert(phase == "cooldown" and activeId == nil and completedId == 3)
assert(finished == true)

-- curEventId can remain replicated briefly after the forced return. The same
-- event must not be entered twice.
phase, activeId, completedId, finished = Common.worldEventTransition(
    phase, activeId, completedId, 3, 0, true
)
assert(phase == "cooldown" and completedId == 3 and finished == false)

phase, activeId, completedId, finished = Common.worldEventTransition(
    phase, activeId, completedId, 2, 0, true
)
assert(phase == "idle" and activeId == nil and completedId == nil)

phase, activeId, completedId, finished = Common.worldEventTransition(
    phase, activeId, completedId, 4, 0, true
)
assert(phase == "seeking" and activeId == 4)

phase, activeId, completedId, finished = Common.worldEventTransition(
    phase, activeId, completedId, 4, 1, false
)
assert(phase == "idle" and activeId == nil and completedId == nil)

print("world_event_flow_smoke=ok")
