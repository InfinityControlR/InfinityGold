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
| `games/magicloot_common.lua` | Pure, Roblox-free helpers: drop sorting/gating, farm stage selection |
| `games/magicloot_locomotion.lua` | Walking locomotion, EnterDelay, stuck reset, Auto Broom |
| `games/magicloot.lua` | Core script: farm modes, combat, pickup, progress, dashboard |
| `diagnostics/click_action_inspector.lua` | Passive real-click, remote and numeric-delta inspector |
| `tests/` | Python regression suite + Luau smoke tests |
| `tools/` | Luau toolchain provisioning, loader template |

## Features

- **Farm**: Auto Farm (progresses from `DungeonRunMaxClear + 1`, respects a
  raised start stage), specific-stage farming, modes `Ground`, `Above`,
  `Orbit`, `Running`, `Walking`, configurable height/orbit/enter delay.
- **Walking**: `humanoid:Move` driven from a render-step binding at
  `Enum.RenderPriority.Character + 1`. No teleports, no WalkSpeed/JumpPower
  changes, EnterDelay per stage change, 20-second stuck detection with a
  single bounded character reset per stage, stage-entry releases the attack
  block (`enteredStage` latch).
- **Combat**: Auto Attack (0.2 s cadence) and Auto Click
  (`1 / max(1, ClickRate)`), sharing one attack block fed by the locomotion
  bridge. Auto Click continuously sends the confirmed `TRAIN_MANUAL_CLICK`
  power request (one request in flight at a time) and releases the normal
  attack skill against the nearest monster, without injecting mouse input or
  moving the real cursor.
- **Loot**: Auto Pickup with the modern drop schema (`ItemId` attribute,
  `DropLanded`, `GoldValue`, `Xyd`) plus legacy `DropItem` models. Event drops
  (numeric `GoldValue` exactly equal to 0) bypass minimum value and rarity filters
  and are collected first. Auto Sell and Sell All Now enumerate the player's
  Bag and send the eligible materials' unique `onlyID` values, excluding
  locked items and materials reserved for Alchemy recipes.
- **Broom**: exactly the observed two-step remote flow
  (`关卡跳关请求` then `上下扫帚` after 0.25 s), single-flight with epoch
  tokens, invalidation on toggle/stage/return changes, base detection through
  the numeric `InDungeonChallenge` transition.
- **Progress**: Auto Rebirth (with limit), Auto Train (current zone via
  `TRAIN_ZONE_UPDATE`), Auto Return when the bag is full, index/online claims,
  potion brewing/drinking, best-affordable shop automation (fail-open).
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
- `PLAYER_REBIRTH`, `INDEX_CLAIM_REWARD`, `CLAIM_ONLINE_AWARD`,
  `DRINK_POTION` payload shapes (currently sent without arguments).
- `GetData.GetCfgByName("weaponConf"|"armorConf")` shape for shop automation.
- Brew recipe selection currently picks the first entry of
  `GetData.GetRecipeList()`.
