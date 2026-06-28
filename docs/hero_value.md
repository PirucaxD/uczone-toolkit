# hero_value

A per-hero combat-value score: how much a given enemy is worth flipping or
focusing right now. Use it to weight area-of-effect spell value (which enemies a
nuke actually kills) so a fed core counts for more than a starved support.

`of(enemy, peers)` is a role base times a live, peer-relative fed-ness
multiplier. Depends on `lib/hero_data` for the role tag. The live reads are
`pcall`-guarded and degrade to the base, so the module is deterministic and
offline-testable by stubbing the `Hero` / `NPC` globals.

## What it owns

`TAG_VALUE` - the base value per KV role tag (`Carry` 1.00 down to `Support`
0.45). `base()` keys on the PRIMARY (first) tag of a hero's `hero_data` role, so
every hero is covered by exact name and it stays patch-stable.

`HERO_VALUE_OVERRIDE` - a small hand-correction table for heroes whose primary
KV tag misreads their farm-position value (e.g. a `Carry`-tagged offlaner).

`DEFAULT_VALUE` (0.50) for an unknown hero. `LO` / `HI` (0.6 / 1.6) clamp the
live multiplier.

## Helpers

| Function | Returns |
|----------|---------|
| `base(unit_name)` | static role value (override, else tag, else default) |
| `live_mult(enemy, peers)` | peer-relative fed-ness multiplier, clamped to [LO, HI] |
| `of(enemy, peers)` | `base * live_mult`, fully guarded (0 with no enemy) |
| `debug_reads(u)` | `(networth or nil, level or nil)`, diagnostics |
| `debug_signals(u)` | `(max_hp, total_stats, true_max_damage)`, diagnostics |

The live multiplier reads total stats (str+agi+int, item-inclusive and readable
on visible enemies) relative to the peer set, falling back to hero level when
stats are unavailable. Fewer than two readable peers yields 1.0 (base alone), so
a lone target is never mis-scaled.

```lua
local HV = require("lib.hero_value")
-- weight a nuke by who it actually flips: a fed core is worth more than a support
local peers = enemy_heroes_in_radius(center, radius)
local worth = 0
for _, e in ipairs(flipped) do worth = worth + HV.of(e, peers) end
if worth >= 1.0 then commit_the_cooldown() end
```

## Cluster selection (AoE value)

`best_cluster(counts, values)` picks the best cluster of heroes for an
area-of-effect cast. Given two parallel per-anchor arrays (member `counts` and
summed `values`), it returns two indices:

| Return | Meaning |
|--------|---------|
| `best_idx` | argmax member count, EXACT-count ties broken by higher summed value (full ties keep the first) |
| `pure_idx` | the first argmax member count (the purely geometric pick) |

Strictly more bodies always wins, so value only breaks ties between
equal-count clusters: it never reduces the hit count. Empty input returns
`nil, nil`. `best_idx` is the value-aware pick; `pure_idx` is the
count-only pick, useful for a side-by-side diagnostic.

## Farm priority and roles

These functions answer "who owns farm here" for an auto-farm consumer that
gates stealing (a contested camp is one where a nearby ally outranks you).

`role(hero)` returns the player's position (1 = carry .. 5 = hard support) or
`nil`. As verified on the UCZone gitbook, UCZone exposes NO clean
position/role/assigned-lane API, so this currently returns `nil` for every
hero. It is the single place to wire a real read if such an API appears; until
then consumers rely on the role-tag fallbacks below.

`IsCore(hero, name, core_base)` answers whether a hero is a core (carry / mid /
offlane) for farm-ownership decisions. Role-FIRST: if `role(hero)` is available
it returns true for positions 1-3. Since `role` currently returns `nil`, it
falls back to the role-tag `base(name)` value being at or above `core_base`
(default `0.55`). At that threshold carry / nuker / pusher / initiator /
durable / disabler / escape read as cores, while jungler / support / default do
not. The base is fed-ness-independent, so an under-levelled offlaner still
reads as a core.

`FarmPriority(args)` returns a unified `0..1` farm-priority (pos1 carry highest,
pos5 hard support lowest). It takes a single table `args` with optional fields
`role` (`1..5` or `nil`) and `value` (a `hero_value.of` number or `nil`). It is
pure (no live reads).

| Source | Result |
|--------|--------|
| `args.role` is a valid `1..5` | `ROLE_PRIORITY[role]` (1.00, 0.80, 0.60, 0.30, 0.15) |
| otherwise | `(args.value or DEFAULT_VALUE) / VALUE_NORM`, clamped to `[0, 1]` |

Role is the ground truth when match positions are attributed; `hero_value` is
the fallback, normalized by `VALUE_NORM` (1.6, the `of` upper bound: base <= 1.0
times the live clamp HI of 1.6) onto the same scale.

```lua
-- gate auto-farm stealing: a nearby ally with a HIGHER FarmPriority contests this camp
local mine  = HV.FarmPriority({ role = my_pos, value = HV.of(me) })
local theirs = HV.FarmPriority({ role = ally_pos, value = HV.of(ally) })
if theirs > mine then leave_the_camp() end
```
