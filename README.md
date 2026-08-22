# InfinityGold for Magic Loot

Original automation suite for the Roblox game **Magic Loot**, built from
scratch for the InfinityGold brand. Every shipped file is our own code:
the interface library, the shared helpers, the locomotion module and the
core script. No obfuscated payloads, no third-party UI libraries, no
unpinned downloads.

## Status

Brand-new implementation. The game-integration surfaces (remotes, player
values, stage layout, drop schema) follow the behaviour documented during
the Magic Loot analysis; everything that could not be verified statically
is implemented fail-open and is listed under *Runtime verification* below.

## Load InfinityGold

Use this permanent loader. It follows `main`, while every executable module
downloaded by the loader remains pinned to an audited commit:

```lua
loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/InfinityControlR/InfinityGold/refs/heads/main/loader.lua?t="
    .. tostring(os.time())
))()
```

The scripts under `diagnostics/` are standalone inspectors; they do not load
the InfinityGold dashboard.

## Layout

| File | Purpose |
| --- | --- |
| `loader.lua` | Executor/game guards, downloads pinned modules + core, protected factory injection |
| `ui/InfinityUI.lua` | Original dashboard library (window, tabs, toggles, sliders, dropdowns, toasts) |
| `games/magicloot_common.lua` | Pure, Roblox-free helpers: drop sorting/gating, catalog and inventory selection, farm stage selection |
| `games/magicloot_locomotion.lua` | Magic-compatible Walking/Running, Auto Broom and selected-Wand worker |
| `games/magicloot.lua` | Core script: farm modes, combat, pickup, progress, dashboard |
| `diagnostics/click_action_inspector.lua` | Passive real-click, remote and numeric-delta inspector |
| `tests/` | Python regression suite + Luau smoke tests |
| `tools/` | Luau toolchain provisioning, loader template |

## Features

- **Farm**: Auto Farm (progresses from `DungeonRunMaxClear + 1`, respects a
  raised start stage, up to stage 32), specific-stage farming, modes `Ground`,
  `Above`, `Orbit`, `Running`, `Walking`, configurable height/orbit/enter delay.
  Walking/Running start their route directly from base; they do not wait for
  `InDungeonChallenge > 0` before moving toward a stage.
- **Walking**: `humanoid:Move` driven from a render-step binding at
  `Enum.RenderPriority.Character + 1`. No teleports, no WalkSpeed/JumpPower
  changes. Its final farm point is the stage centre, matching Magic; EnterDelay
  applies per stage change, 20-second stuck
  detection performs a single bounded character reset per stage, and stage
  entry releases the attack block (`enteredStage` latch).
- **Running**: uses the Magic locomotion contract: `humanoid:Move` runs every
  render step after the normal character controller, follows 45-degree
  waypoints around the stage centre, and requests a grounded jump every 0.9
  seconds from that same callback. It rereads the configurable 4–50 stud
  `RunningDistance` live; no `MoveTo`, CFrame teleport, captured points, or
  speed/jump-power mutation is used.
- **Combat**: Auto Attack (0.2 s cadence) and Auto Click
  (`1 / max(1, ClickRate)`), sharing one attack block fed by the locomotion
  bridge. Auto Attack resolves the nested skill modules without yielding; if
  one is not replicated yet, that tick reports the missing step and retries
  0.2 s later. Auto Click continuously sends the confirmed `TRAIN_MANUAL_CLICK`
  power request (one request in flight at a time) and releases the normal
  attack skill against the nearest monster, without injecting mouse input or
  moving the real cursor.
- **Loot**: Auto Pickup with the modern drop schema (`ItemId` attribute,
  `DropLanded`, `GoldValue`, `Xyd`) plus legacy `DropItem` models. Its optional
  item filter uses the same live material catalog as Sell. The minimum gold value
  is a full-width manual numeric input with no slider ceiling. Event drops
  (numeric `GoldValue` exactly equal to 0) bypass minimum value and item filters
  and are collected first. Auto Sell All, Auto Sell Specific and Sell All Now
  enumerate the player's Bag and send the eligible materials' unique `onlyID`
  values, excluding locked items and materials reserved for Alchemy recipes.
  The All/Specific switches are mutually exclusive and their catalog stays live:
  every two seconds it re-reads both game config facades, accepts array/map and
  shallow wrapped schemas plus common ID/name/price aliases, and adds patch-day
  material IDs without a hub update or losing existing selections. Catalog
  lists retain stable numeric IDs internally, including migration of old saved
  `#ID name` selections. Training Ground and Selected Wand additionally remove
  legacy `#ID` prefixes and replace untranslated CJK keys with an English typed
  fallback. Automatic
  selling runs only at base through a strict `Alchemy -> Sell -> Broom` state
  machine. Alchemy releases Sell only after a brew is confirmed/already brewing,
  a finished potion occupies the slot, or a non-empty valid recipe catalog proves
  that no recipe is craftable, or a finished potion is picked up successfully.
  Sell releases Broom only after a follow-up inventory
  scan reports that no configured item remains sellable; transport success alone
  is not confirmation. A confirmed pickup frees the station slot and, while
  Auto Brew remains enabled, immediately starts the highest locally available
  Best recipe in the same base pass. If that material check proves no recipe is
  craftable, Alchemy releases Sell/Broom/farming without sending a request. Dungeon
  drops live in the small temporary `LimitBag` while farming and move into the
  visible 999-slot `PlayerData.Bag` only at base. Best Craftable watches that
  handoff, uses the recipe/MID/NeedCount snapshot captured once on script load,
  aggregates duplicate material rows, compares each raw recipe's
  `MID` and `NeedCount`, and sends exactly the highest locally available recipe
  in the first base cycle. If `LimitBagUsed`
  clears before the permanent Bag changes, the later material fingerprint rearms
  that refresh and is ranked immediately instead of reusing the stale facade.
  A stale rebirth hint
  is diagnostic rather than a veto because the server still validates the one
  selected ID. The observed `CanCraftRecipe` result remains diagnostic because
  it can report all false despite a positive MID/NeedCount calculation. It never
  walks recipe IDs. The game has one brewing slot,
  so a live
  `brewing (one potion at a time)` state is an intentional wait for the current
  potion rather than a recipe-search delay. `Copy Best diagnostic` copies a
  bounded, passive snapshot of the real recipe rows, material Bag rows and local
  predicate results; it sends no game action. Objective timing is strictly
  sequential: `Alchemy -> Sell -> Broom -> Farm`. Broom Return Delay and retry
  timers start only after Sell settles. Farm/Train stays blocked until Broom
  enters a stage, or is skipped because Auto Broom is disabled; only then does
  the full Enter Delay begin.
  A stage entered through a confirmed Broom request is the exception: that
  Broom stage becomes the effective Farm route for the whole dungeon stay and
  the configured Running, Walking, Ground, Above or Orbit mode starts
  continuously without applying Enter Delay. Returning to base clears the
  override.
  When Auto Broom, Auto Farm and Farm Specific are all off, a confirmed brew
  keeps a one-second readiness watch at base. It reads only
  `IsBrewReadyForPickup`; when true, Alchemy collects it and immediately starts
  the next Best recipe, repeating until the material scan finds no candidate.
  Recipe `Time` is nominal duration, not authoritative remaining time.
  A game update is incorporated by re-running the loader, which captures the
  new recipe configuration before the next Best calculation.
  Pickup prepares each real prompt with zero hold duration and expands its
  activation distance to the configured pickup range before firing it.
- **Broom**: offers stages 4, 8, 13, 18, 23 and 28, sends only the
  selected-stage request (`关卡跳关请求`) and never
  toggles/equips the broom. It keeps single-flight epoch tokens, invalidation
  on toggle/stage/return changes, and base detection through the numeric
  `InDungeonChallenge` transition. Startup waits until config restoration has
  finished. Alchemy and Sell gate every request while their phases are active.
  Unconfirmed requests run in cycles of three attempts separated by five seconds;
  a new cycle starts automatically until room entry confirms success. The selected
  stage remains latched independently of that cycle counter, so confirmation
  after the third-attempt reset still releases the configured Farm mode with no
  Enter Delay. That override owns only the initial landing: once progressive
  Auto Farm calculates a higher cleared+1 target, it releases Broom and continues
  to the next stage with the normal per-stage timing. A transient
  nil during AutoReturn cannot leave `waitingForBase` latched.
- **Progress**: Auto Rebirth uses the payload-free invoke contract, stops at
  the selected value from 1–41, and waits until `leaderstats.Level` reaches the
  next `rebirthConf.LvNeed`. Auto Train can use a selected ground or the
  highest unlocked ground, moves to its zone, updates `TRAIN_ZONE_UPDATE` and
  invokes `TRAIN_MANUAL_CLICK`; enabling Auto Train immediately disables Auto
  Broom and both farming switches, so its route is `Alchemy -> Sell -> Train`.
  Auto Return still handles the full temporary bag. Index claims are
  built from live `IndexView` snapshots and online rewards are filtered through
  `OnlineBox` before individual claims. Auto Claim Event performs an invisible
  server-state refresh, discovers the current timed, daily and once-per-event
  quest rows already loaded by the game, and submits only rows whose live
  `canClaim` state is true (or whose accepted progress meets the dynamically
  discovered requirement). Quest names and requirements come from `onlyTag`,
  `Accepted`, `Progress`, `Completed` and `need`; none of the current quests is
  hard-coded, so reloading the script incorporates future event catalogs. It
  never clicks the Event button or changes local interface visibility.
- **Potions and gear**: Auto Drink sends each selected potion inventory
  `onlyID`; its selector continuously discovers new live potion config rows.
  Alchemy captures the game's sparse/keyed recipe list once per full script
  load; reloading after a game update captures new rows and requirements. Wand
  adds Magic's stage-only selected-Wand worker: its catalog is
  captured once per full load, it disables Best only inside a stage, verifies
  ownership and equips by stable ID. Wand and
  armor buying/equipping are separate, choose the best affordable/unowned or
  best owned entry, use Magic's item types 9 and 13, and re-evaluate the current
  weapon/armor configs on every worker cycle. Training grounds use the same live
  catalog sync. All integrations stay fail-open when a required game module is
  unavailable.
- **Utility**: Anti AFK is enabled by default and can restore the original idle
  connections when switched off.
- **Dashboard**: InfinityUI — obsidian-black surface, gold accents, draggable
  window, Right Shift toggles visibility, toasts with progress bars, session
  info, config save/load, rejoin, unload.

## Validation

```bash
python tools/ensure_luau.py          # provisions Luau 0.731 if missing
python -m unittest discover -s tests -v
```

The suite compiles every shipped source with the official Luau compiler,
runs the pure-helper smoke tests under the Luau CLI, and enforces the
behavioural invariants (cadences, no-teleport Walking, Broom single-flight,
branding, loader pins).

## Passive click inspector

This standalone diagnostic identifies what a real left click does in the
current game client. It observes `InputBegan`/`InputEnded`, nearby outgoing
remotes and replicated numeric changes without synthesizing input, invoking
an inspected callback or sending a remote.

```lua
loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/InfinityControlR/InfinityGold/refs/heads/main/diagnostics/click_action_inspector.lua?t="
    .. tostring(os.time())
))()
```

For a clean capture, turn Auto Attack, Auto Click and Auto Train off, run the
inspector, click empty game space three times about one second apart, wait one
second, and use **Copiar**. Repeat once in a training area and once in a stage
if the click behaviour differs by context.

## Publish flow (two commits)

1. Change modules, compile, test, commit and push **without** touching
   `loader.lua`; note the full SHA (`git rev-parse HEAD`).
2. Regenerate `loader.lua` from `tools/loader.template.lua` with that SHA,
   update `tests/fixtures/expected_pins.json`, test again, commit and push.
   Optionally run with `INFINITYGOLD_VERIFY_REMOTE=1` to byte-compare the
   pinned URLs against the published files.

## Runtime verification

These surfaces need confirmation inside Roblox (fail-open until then):

- Auto-return now follows the original game contract exactly: bag capacity is
  `GetData.GetItemCountByID(LocalPlayer, 5)` and usage is
  `LocalPlayer.LimitBagUsed`. The Farm tab shows both live values and the
  capacity source. After `ReturnDelay`, it retries `DUNGEON_RETURN_TOWN` every
  two seconds until `InDungeonChallenge <= 0` confirms arrival; it does not
  abandon an active full-bag episode after an arbitrary request count.
- The statically recovered Magic contracts are now reproduced: payload-free
  `PLAYER_REBIRTH`; `INDEX_CLAIM_REWARD` with snapshot `tag` and
  `targetProgress`; `DRINK_POTION` with the selected Bag item's `onlyID`;
  shop buy/equip with `equipID` plus item type 9/13; and training through
  `CanEnterTrainGround`, `FindZonePartByTrainId`, zone update and manual click.
  Their live server acceptance and current catalog contents still require an
  in-client confirmation.
- Alchemy resolves `GetData.Alchemy` and sends only one locally selected Best
  recipe, never a server-side ID walk. It distinguishes the temporary LimitBag
  from the permanent 999-slot Bag, watches the bounded transfer window for a
  material delta, then evaluates `CanCraftRecipe` immediately. A
  positive `CanMeetRecipeRebirth` is preferred, but its false/error result no
  longer hides a material-positive recipe that manual selection can submit.
  Craft and pickup use the verified InvokeServer actions only when
  `InDungeonChallenge <= 0`. This test build is completely remote-only: it never
  resolves the actor positions and never writes the character CFrame.
  Automatic selling waits for a terminal Alchemy outcome; Broom waits for the
  subsequent empty Sell rescan.
