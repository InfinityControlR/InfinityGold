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
| `games/magicloot_locomotion.lua` | Walking locomotion, EnterDelay, stuck reset, Auto Broom |
| `games/magicloot.lua` | Core script: farm modes, combat, pickup, progress, dashboard |
| `diagnostics/click_action_inspector.lua` | Passive real-click, remote and numeric-delta inspector |
| `tests/` | Python regression suite + Luau smoke tests |
| `tools/` | Luau toolchain provisioning, loader template |

## Features

- **Farm**: Auto Farm (progresses from `DungeonRunMaxClear + 1`, respects a
  raised start stage, up to stage 32), specific-stage farming, modes `Ground`,
  `Above`, `Orbit`, `Running`, `Walking`, configurable height/orbit/enter delay.
- **Walking**: `humanoid:Move` driven from a render-step binding at
  `Enum.RenderPriority.Character + 1`. No teleports, no WalkSpeed/JumpPower
  changes. Its final farm point is halfway between the stage entrance edge
  and its centre; EnterDelay applies per stage change, 20-second stuck
  detection performs a single bounded character reset per stage, and stage
  entry releases the attack block (`enteredStage` latch).
- **Running**: enters with native `Humanoid:MoveTo`, then immediately follows
  45-degree waypoints around the stage centre instead of stopping there. It
  jumps every 0.9 seconds only while grounded and rereads the configurable
  4–50 stud `RunningDistance` on every movement update; no CFrame teleport or
  speed/jump-power mutation is used.
- **Combat**: Auto Attack (0.2 s cadence) and Auto Click
  (`1 / max(1, ClickRate)`), sharing one attack block fed by the locomotion
  bridge. Auto Click continuously sends the confirmed `TRAIN_MANUAL_CLICK`
  power request (one request in flight at a time) and releases the normal
  attack skill against the nearest monster, without injecting mouse input or
  moving the real cursor.
- **Loot**: Auto Pickup with the modern drop schema (`ItemId` attribute,
  `DropLanded`, `GoldValue`, `Xyd`) plus legacy `DropItem` models. The rarity
  selector exposes tiers 1–10 in a compact scrolling list. Its minimum gold
  value is a full-width manual numeric input with no slider ceiling. Event drops
  (numeric `GoldValue` exactly equal to 0) bypass minimum value and rarity filters
  and are collected first. Auto Sell All, Auto Sell Specific and Sell All Now
  enumerate the player's Bag and send the eligible materials' unique `onlyID`
  values, excluding locked items and materials reserved for Alchemy recipes.
  The All/Specific switches are mutually exclusive and their catalog refreshes
  after late game-module initialization without losing selections. Automatic
  selling runs only at base. When Auto Brew is enabled, the base-economy worker runs
  Alchemy first and sells only after a craft was confirmed or while a potion is
  already brewing; a pickup confirmation alone never unlocks selling. Dungeon
  drops live in the small temporary `LimitBag` while farming and move into the
  visible 999-slot `PlayerData.Bag` only at base. Best Craftable watches that
  handoff, refreshes the local Alchemy facade and sends the highest recipe whose
  material predicate is positive in the first base cycle. A stale rebirth hint
  is diagnostic rather than a veto because the server still validates the one
  selected ID. It never walks guessed recipe IDs. A confirmed pickup chains the
  next brew in the same base cycle without invalidating the unchanged material
  snapshot. The game has one brewing slot, so a live
  `brewing (one potion at a time)` state is an intentional wait for the current
  potion rather than a recipe-search delay.
- **Broom**: offers stages 4, 8, 13, 18, 23 and 28, sends only the
  selected-stage request (`关卡跳关请求`) and never
  toggles/equips the broom. It keeps single-flight epoch tokens, invalidation
  on toggle/stage/return changes, and base detection through the numeric
  `InDungeonChallenge` transition. Startup waits until config restoration has
  finished; an unconfirmed request is retried at most three times, five seconds
  apart, and room entry cancels every pending retry immediately.
- **Progress**: Auto Rebirth uses the payload-free invoke contract and stops at
  the selected value from 1–41. Auto Train can use a selected ground or the
  highest unlocked ground, moves to its zone, updates `TRAIN_ZONE_UPDATE` and
  invokes `TRAIN_MANUAL_CLICK`; farming and training switches exclude one
  another. Auto Return still handles the full temporary bag. Index claims are
  built from live `IndexView` snapshots and online rewards are filtered through
  `OnlineBox` before individual claims.
- **Potions and gear**: Auto Drink sends each selected potion inventory
  `onlyID`; its selector also refreshes when the catalog arrives late. Wand and
  armor buying/equipping are separate, choose the best affordable/unowned or
  best owned entry, and use Magic's item types 9 and 13. All integrations stay
  fail-open when a required game module is unavailable.
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
  capacity source so this can be verified without another diagnostic script.
- The statically recovered Magic contracts are now reproduced: payload-free
  `PLAYER_REBIRTH`; `INDEX_CLAIM_REWARD` with snapshot `tag` and
  `targetProgress`; `DRINK_POTION` with the selected Bag item's `onlyID`;
  shop buy/equip with `equipID` plus item type 9/13; and training through
  `CanEnterTrainGround`, `FindZonePartByTrainId`, zone update and manual click.
  Their live server acceptance and current catalog contents still require an
  in-client confirmation.
- Alchemy resolves `GetData.Alchemy` and sends only one locally selected Best
  recipe, never a server-side ID walk. It distinguishes the temporary LimitBag
  from the permanent 999-slot Bag, reserves the short return window until a
  material delta is visible, then evaluates `CanCraftRecipe` immediately. A
  positive `CanMeetRecipeRebirth` is preferred, but its false/error result no
  longer hides a material-positive recipe that manual selection can submit.
  Craft and pickup
  use the verified InvokeServer actions only when `InDungeonChallenge <= 0`,
  without moving the character or suspending Walking, Running or Broom.
  Automatic selling still waits for a confirmed brew.
