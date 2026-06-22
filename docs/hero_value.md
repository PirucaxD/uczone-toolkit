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
