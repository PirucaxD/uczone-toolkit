# lane

Hero-agnostic lane intelligence. Reads lane creep waves at full granularity,
predicts where a wave clash settles (pushing, or crashing into a tower), works
out the cheapest way to reach a lane (teleport vs walk), and fills fogged lanes
from an expected-wave model keyed on game time.

Split into a pure analysis core and a thin set of engine wrappers, mirroring
`lib/map.lua`. The pure functions use scalar math (read `.x` / `.y`, build
`{x, y}`) and never touch the engine, so they are fully offline-testable. Only
the wrappers (`ScanLanes` and the readers it calls) hit the live API, and nothing
calls the engine at load time. Distances are in Hammer units.

## Input contracts

The pure core takes plain lists you build yourself, so it stays testable.

A creep entry needs `pos` and `team`; `hp` and `gold` feed the wave totals:

```lua
{ pos = {x=, y=}, team = <number>, hp = <number?>, gold = <number?>, max_hp = <number?> }
```

A tower entry: `{ pos, team, range, alive }`. A hero entry: `{ pos, team }`. A
teleport anchor: `{ pos, ready = <boolean>, kind = <string?> }`.

## Wave scanning

`DetectWaves(creeps, push_dir, opts)` builds wave structs from one team's creep
list. It single-link clusters the creeps (`opts.cluster_radius`, default 600),
assigns each cluster a lane, and returns a list of waves. `push_dir` is a vector
pointing toward the enemy base (need not be normalized); it sets the `front`, the
member furthest along that bearing. Each wave is:

```lua
{ team, lane, centroid, front, count, hp, gold, strength, creeps }
```

`strength` defaults to summed HP; pass `opts.strength_fn(members)` to override the
push-weight metric. Lanes are assigned by `_assign_lane`: the SW->NE diagonal is
mid (within `opts.mid_band`, default 2500 half-width), upper-left is top,
lower-right is bot.

## Clash prediction

`PredictClash(enemy_wave, ally_wave, towers, opts)` predicts the equilibrium for
one lane. The contact point is where the two fronts meet (or the lone front if one
side is empty). Each side's weight is its wave `strength` plus `opts.tower_weight`
(default 4000) for each friendly tower whose range covers the contact. The clash
drifts toward the weaker side at a rate proportional to the imbalance, clamped at
the nearest defending tower ahead. Returns:

```lua
{ contact, settle, drift_dir, settle_eta, w_enemy, w_ally,
  pushing, moving, crashing, crash_tower }
```

`pushing` is `"enemy"`, `"ally"`, or `"even"`; `crashing` is true when the drift
reaches a defending tower (`crash_tower`), meaning the wave pushes up into it.
Calibration knobs: `drift_coeff`, `horizon`, `creep_speed`, `move_threshold`,
`tower_weight`. Pure.

## Intercept and anchors

`InterceptETA(from_pos, anchors, move_speed, tp, target, clearable_until)` returns
the time to reach `target` via the best ready teleport anchor or a plain walk,
whichever is faster. `tp.channel` adds the teleport channel time to an anchor
route. Use it both for "can I reach this wave now" (`from_pos` = hero) and "ETA to
the next lane" (`from_pos` = a settle point). Returns:

```lua
{ best_anchor, eta, reachable }
```

`reachable` is true when `clearable_until` is nil or `eta <= clearable_until`. The
caller applies any hero-specific teleport rules upstream (this is a generic anchor
list).

`NearestTeleportAnchor(point, anchors, allowed_kinds)` returns the nearest ready
anchor of an allowed kind (nil `allowed_kinds` = any) and its distance:
`(anchor, distance)`.

## Fog-fill expected wave

`ExpectedWave(game_time, opts)` returns the composition and value of the wave that
should exist at `game_time` (seconds on the game clock, 0 = first wave). It is used
to estimate an unseen enemy wave in a fogged lane (composition and gold only, no
position). The schedule and per-creep stats are parametrized from Liquipedia's
lane-creep data: melee/ranged/siege/flagbearer counts by time, per-cycle HP and
gold scaling (cycle = `floor(t/450)`, capped at 30), and the siege/flagbearer
cadence. `opts.super` / `opts.mega` swap in barracks-down stats. Returns:

```lua
{ wave, cycle, melee, ranged, siege, flagbearer, count, hp, gold, strength }
```

Gold uses the max bounty of each creep, matching the visible-wave path so fogged
and visible lane gold are comparable. Pure.

## Assembling lane state

`BuildLaneStates(creeps, towers, heroes, opts)` composes the full per-lane state
from plain inputs. It splits creeps by team, detects waves per side (push
directions from `opts.enemy_push` / `opts.ally_push`), picks the biggest wave per
lane per side, predicts the clash, counts heroes within `opts.hero_radius`
(default 1200) of the contact, and (when anchors and kinematics are supplied)
computes the intercept to the settle point. If a lane has no visible enemy wave and
`opts.game_time` is set, it fills one from `ExpectedWave` (composition only; the
clash stays visible-only). Returns a table keyed `top` / `mid` / `bot`, each:

```lua
{ lane, enemy_wave, ally_wave, gold, towers, enemy_heroes, ally_heroes, clash, intercept }
```

`opts.team` is your team; intercept opts are `anchors`, `hero_pos`, `move_speed`,
`tp`, `allowed_kinds` (include `"creep"` / `"ally"` to use those as anchors), and
`clear_window`. Pure.

## Live read

`ScanLanes(opts)` is the engine wrapper: it reads live lane creeps
(`TYPE_LANE_CREEP`), towers, and heroes, then calls `BuildLaneStates`. `opts.team`
defaults to the local hero's team; every calibration and anchor option passes
straight through. This is the only entry point that touches the engine.

```lua
local Lane = require("lib.lane")

-- full live scan with intercept from the hero:
local me     = Heroes.GetLocal()
local hero_p = Entity.GetAbsOrigin(me)
local lanes  = Lane.ScanLanes({
    hero_pos      = { x = hero_p.x, y = hero_p.y },
    move_speed    = NPC.GetMoveSpeed(me),
    anchors       = my_tp_anchors,        -- { {pos, ready, kind}, ... }
    allowed_kinds = { "creep", "ally" },
    game_time     = GameRules.GetGameTime(),
})

local mid = lanes.mid
if mid.clash and mid.clash.crashing then
    -- enemy wave is about to crash our mid tower; intercept if we can clear in time
    if mid.intercept and mid.intercept.reachable then
        go_to(mid.clash.settle)
    end
end
```

| Function | Returns |
|----------|---------|
| `DetectWaves(creeps, push_dir, opts)` | list of `{team, lane, centroid, front, count, hp, gold, strength, creeps}` |
| `PredictClash(enemy_wave, ally_wave, towers, opts)` | `{contact, settle, drift_dir, settle_eta, w_enemy, w_ally, pushing, moving, crashing, crash_tower}` or nil |
| `InterceptETA(from_pos, anchors, move_speed, tp, target, clearable_until)` | `{best_anchor, eta, reachable}` |
| `NearestTeleportAnchor(point, anchors, allowed_kinds)` | `(anchor, distance)` or `(nil, nil)` |
| `ExpectedWave(game_time, opts)` | `{wave, cycle, melee, ranged, siege, flagbearer, count, hp, gold, strength}` |
| `BuildLaneStates(creeps, towers, heroes, opts)` | `{top=, mid=, bot=}`, each a per-lane state table |
| `ScanLanes(opts)` | same as `BuildLaneStates`, read from the live engine |

## What's new in this sync (from the Tinker farm line)

- Lane-path polylines: `Lane.BuildLanePaths`, `Lane.PathLength`,
  `Lane.PointAtArc`, `Lane.ArcOfPoint`, `Lane.PathTangent` - arc-length
  geometry along the real (bent) lane paths.
- Fogged-wave MIRROR: `Lane.MirrorWave` (your visible wave in the role-paired
  lane, reflected by arc length = the fogged enemy wave's position) +
  `Lane.ClampBeyondSight` (a fogged front cannot sit inside your creeps'
  sight - absence of vision is data). Measured error ~300u median.
- Meeting kinematics: `Lane.MeetingPoint` (closure-aware midpoint) and
  `Lane.PredictMeeting` (one closing-speed expression for all three lanes).
- Combat sim: `Lane.SimFight` (per-attacker attrition with focus order),
  `Lane.WaveCombatants`, `Lane.PushForecast` (who wins the creep fight and
  when it resolves - a timing input, not a go/no-go gate; 90% sign-match in
  the validation runs).
- `Lane.ScanLanes` - the one-call driver: waves, clash, meeting, estimates
  per lane, with the fog-fill and mirror wired in.
