# march_sim

A pure, deterministic attrition simulator for stream-style AoE vs a lane wave,
modeled on Tinker's March of the Machines. March is a robot STREAM, not an
instant nuke: 144 robots over 6 seconds, each moving at 400, dying on its first
collision and splashing 150 around the impact. Whether the trailing ranged
creep dies in two casts therefore depends on how the melee screen intercepts
the stream, which changes with the cast angle. This sim answers that kind of
question OFFLINE, before any hero code is written.

Pure component math: no engine reads, no randomness. The game spawns robots at
random lateral offsets along the spawn edge; the sim replaces that with a
golden-ratio lateral spread, so the same inputs always produce the same kill
timeline. That determinism is the point: you can diff two cast patterns, or two
cast timings, and know the difference came from the geometry, not the dice.
It is consumed by offline tooling (test runners, report generators), not by a
hero script at runtime.

## The model

Constants live in `MarchSim.K` (from Valve KV data plus in-client calibration):
cast range 300, cast point 0.53s, a coverage box of roughly 1800x1800 centered
on the cast point and oriented along hero -> cast point, robot speed 400, 24
robots/s for 6s, splash 150. `HIT_R` (75) is the collision radius plus an
approximate creep hull; recalibrate in-client if kill counts read off.

## Building a scenario

`Cast(hero, aim, theta_deg, behind)` resolves one cast's geometry: the cast
point plus a unit facing, with robots spawning on the edge `HALF` behind the
cast point and sweeping forward. `theta_deg` rotates the facing off the
hero -> aim axis (an "X arm" cast); `behind` instead flips the cast a small
backstep behind the hero, robots spawning beyond the aim and sweeping back.

`MakeWave(o)` builds a standard creep wave anchored on the trailing ranged
creep: `n_melee` melees (default 3) placed `gap` (200) ahead along the walk
direction with lateral `spread` (120), the ranged last. It returns a plain
creeps list ready for `Simulate`.

```lua
local MS = require("lib.march_sim")

local creeps = MS.MakeWave({
    ranged = { x = 0, y = 0 }, walk = { x = -1, y = 0 },
    melee_hp = 550, ranged_hp = 300,
})
local r = MS.Simulate({
    hero   = { x = -810, y = 0 },
    creeps = creeps,
    walk   = { x = -1, y = 0 }, wave_speed = 325,
    dmg    = 46,
    casts  = { { t = 0 }, { t = 2.5, theta = 25 } },
    bg_dps = 60,
})
-- r.cleared, r.cs, and per-creep death time / killing cast / cause
```

## What Simulate does

Robots spawn per cast at `t + CAST_POINT + i/RATE`, fly straight, and pop on
their first creep contact (or expire after crossing the box), splashing `dmg`
to everything within 150. Cast aim is resolved at cast time from the LIVE
ranged creep (falling back to the living-creep centroid), so a second cast
re-aims at whatever survived the first.

Creeps walk along `walk` at `wave_speed` until "in combat" (first robot hit, or
within 150 of the hero), a deliberately coarse stop model. `bg_dps` is the
last-hit race term: your own wave's continuous dps per enemy creep once it is
stopped. A creep finished by `bg_dps` died to the wave, not to you
(`died_to = "bg"`), and `cs` counts robot kills only, so the sim tells you not
just whether the wave dies but whether YOU get paid for it.

| Function | Returns |
|----------|---------|
| `Cast(hero, aim, theta_deg, behind)` | `{ cx, cy, fx, fy }`, cast point + unit facing |
| `MakeWave(o)` | creeps list (melees first, ranged last); `o` = `{ ranged, walk, n_melee?, gap?, spread?, melee_hp, ranged_hp }` |
| `Simulate(opts)` | `{ robots, hits, cs, cleared, creeps }`; each result creep = `{ kind, hp, died_at, died_cast, died_to, hits }` |

`Simulate` opts: `hero`, `creeps`, `casts` (list of `{ t, theta?, behind? }`),
`dmg` per robot, `walk` + `wave_speed` (default 0, stationary), `dt` (default
1/30), `hit_r` override, `bg_dps` (default 0).

## What it's for (and what it isn't)

This is an offline calibration tool, a lower-level building block. Typical
questions: does the trailing ranged die in 2 casts from the standard stand, how
much does an X-arm angle help vs straight front/behind, how early must the
second cast land before the wave stops. You sweep parameters in a test script,
read the deterministic kill timelines, and bake the WINNING numbers (cast
leads, angles, stand distances) into the hero script as plain constants. The
sim itself never runs in-game.

It is honest about its coarseness: no creep-vs-creep collision, no tower actor,
a blunt stop model, and a hull-padded hit radius. Good enough to rank cast
patterns against each other; not a frame-accurate replay of the engine.
