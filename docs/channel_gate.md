# channel_gate

A pure kit-awareness predicate for one question: **if I start a channel right
here, is there an enemy in reach whose kit can break it?** Channels (Rearm-class
self-channels, TPs, and similar) break on stuns, hexes, and forced movement, NOT
on attack damage, so starting one inside a ready disabler's cast range is a
guaranteed loss: the channel dies and the mana stays spent. A generic
"lane unsafe" trade rule can never gate this (trading vs a lone laner is often
correct while channeling next to them is not), so this module supplies the
missing static half of "don't channel near a ready disabler".

Everything is pure over the three data tables: no engine reads, no internal
state. The caller passes a `hero_data` abilities list plus the
[ability_data](ability_data.md) and [threat_data](threat_data.md) MODULES, and
caches the result per hero name (kits don't change mid-game).

## What counts as a breaker

`Breakers` walks a kit's abilities through `threat_data.ABILITY_TO_THREAT` ->
`THREATS_ON_SELF` and keeps an ability when either:

- its role is `hard_disable` (stuns, hexes, roots-that-break) or
  `channel_on_me` (enemy channels that lock you, Dismember-class), or
- its threat entry is tagged `breaks_channel`, regardless of role. The role
  taxonomy encodes SAVE semantics, and some `delayed_aoe` / `magic_burst`
  entries carry full stuns or ministuns that break channels all the same.

Each breaker gets its `ability_data.CastRange` at max level as the gate range,
floored at 250 so melee-range disables (Bash-class) still gate on arrival. Every
entry also carries an `ult` flag, because an ultimate cannot be skilled before
hero level 6 (see `LevelCleared` below).

**Deliberately excluded: gap-closers.** Charge-class abilities read huge or
global cast ranges, so gating on them would block every channel all game. An
armed gap-closer is an EVENT (you see the cast, you react), not a proximity
fact, and handling it belongs to the caller's event-driven layer.

## How a hero feeds it

```lua
local CG = require("lib.channel_gate")
local AD = require("lib.ability_data")
local TD = require("lib.threat_data")
local HD = require("lib.hero_data")

-- once per enemy hero name, cached:
local kit      = HD.HEROES[enemy_name] and HD.HEROES[enemy_name].abilities
local breakers = CG.Breakers(kit, AD, TD)          -- nil if the kit has none

-- before starting a channel: any breaker in reach and plausibly ready?
for _, b in ipairs(breakers or {}) do
    if dist_to(enemy) <= b.range + margin
       and CG.ReadyAt(stamps, enemy_name, b.ability, now)
       and not CG.LevelCleared(b, my_level_obs[enemy_name], now) then
        return false   -- do not start the channel
    end
end
```

`DisableRange` is the older single-number form: the max gate range over the
kit's breakers, `nil` when the kit has none. Handy when all you want is one
"stay this far away" radius.

## Readiness stamps

Assume-ready is the conservative default, but it over-gates once you have seen
the disable go on cooldown. `Stamp` / `ReadyAt` are the pure half of tracking
that: the hero owns the `stamps` table and the clock, and calls `Stamp` when it
OBSERVES a cast (the ability cannot be ready again before `t + cd`). `ReadyAt`
then answers "plausibly ready at time t?", with unstamped abilities assumed
ready.

## Proving a breaker unskilled

`LevelCleared(b, obs, t)` returns `true` when a breaker provably cannot fire,
from caller-owned level observations `{ abil = { lvl, t }, hero = { lvl, t } }`.
Two facts, both age-guarded:

1. the ability itself was seen at level 0 within the last
   `ChannelGate.ABIL_FRESH_S` (25s). Short on purpose: a banked skill point can
   be spent invisibly at any moment.
2. the ULT fact: the breaker is an ultimate and the seen hero level, aged
   forward at the fastest plausible leveling pace (`LVL_PACE_S`, 25s per
   level), still cannot have reached 6. Aging OVERESTIMATES their level, so
   this fact under-claims; it never clears basic abilities.

Unobserved means not cleared: assume ready.

| Function | Returns |
|----------|---------|
| `Breakers(abilities, AD, TD)` | list of `{ ability, mod, range, ult }`, `nil` if the kit has no breakers or any argument is missing |
| `DisableRange(abilities, AD, TD)` | max breaker cast range as a number, `nil` if none |
| `Stamp(stamps, caster_name, ability, t, cd)` | records an observed cast into the caller-owned `stamps` table (expiry `t + cd`) |
| `ReadyAt(stamps, caster_name, ability, t)` | `boolean`, `true` when plausibly ready (unstamped = ready) |
| `LevelCleared(b, obs, t)` | `boolean`, `true` when the breaker provably cannot fire from level observations |

This is a lower-level building block: it knows kits, not positions. The hero
script still owns enemy enumeration, distance checks, the stamps table, and the
decision of what to do when the gate says no (walk away, juke, or channel
anyway behind a wall of allies).
