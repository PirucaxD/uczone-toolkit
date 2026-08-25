# lane

Hero-agnostic lane intelligence. Reads lane creep waves at full granularity,
predicts where a wave clash settles (pushing, or crashing into a tower), works
out the cheapest way to reach a lane (teleport vs walk), and fills fogged lanes
from an expected-wave model keyed on game time. Two former standalone modules
now live inside it as sub-tables: `Lane.Route` (the farm-route planner,
previously `lib/route.lua`) and `Lane.Schedule` (the shove-cycle scheduler,
previously `lib/schedule.lua`). If you required those files before, the same
functions moved unchanged: `Route.Plan` is now `Lane.Route.Plan`,
`Schedule.Plan` is `Lane.Schedule.Plan`, and so on.

Split into a pure analysis core and a thin set of engine wrappers, mirroring
`lib/map.lua`. The pure functions use scalar math (read `.x` / `.y`, build
`{x, y}`) and never touch the engine, so they are fully offline-testable. Only
the wrappers (`ScanLanes` and the readers it calls) hit the live API, and nothing
calls the engine at load time. Distances are in Hammer units.

## Input contracts

The pure core takes plain lists you build yourself, so it stays testable.

A creep entry needs `pos` and `team`; `hp` and `gold` feed the wave totals,
`kind` feeds the combat sim, `speed` feeds the fogged-wave mirror (the live
reader fills all of them):

```lua
{ pos = {x=, y=}, team = <number>, hp = <number?>, gold = <number?>, max_hp = <number?>,
  kind = <"melee"|"ranged"|"siege"|"flagbearer"?>, speed = <number?> }
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
drifts toward the weaker side at a rate proportional to the imbalance. Returns:

```lua
{ contact, settle, drift_dir, settle_eta, w_enemy, w_ally,
  pushing, moving, crashing, crash_tower }
```

`pushing` is `"enemy"`, `"ally"`, or `"even"`; `crashing` is true when the bounded
drift segment enters a defending tower's attack range (`crash_tower`), meaning
the wave pushes up into it. A tower the drift cannot physically reach never
counts as a crash target. Calibration knobs: `drift_coeff`, `horizon`,
`creep_speed`, `move_threshold`, `tower_weight`. Pure.

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
to estimate an unseen enemy wave in a fogged lane. The schedule and per-creep
stats are parametrized from Liquipedia's lane-creep data: melee/ranged/siege/
flagbearer counts by time, per-cycle HP and gold scaling (cycle = `floor(t/450)`,
capped at 30), and the siege/flagbearer cadence. `opts.super` / `opts.mega` swap
in barracks-down stats. Returns:

```lua
{ wave, cycle, melee, ranged, siege, flagbearer, count, hp, gold, strength }
```

Gold uses the max bounty of each creep, matching the visible-wave path so fogged
and visible lane gold are comparable. `CreepStats(kind, game_time)` exposes the
underlying per-creep table for one kind (`{hp, gold, dmg, atk, armor, atype}`),
the stat source the combat sim uses. Pure.

## Lane paths, mirror, and combat sim

Arc-length geometry along the real (bent) lane paths, and what it buys:

- `BuildLanePaths(towers, spawns, opts)` builds one polyline per lane from the
  static tower positions (plus optional creep-spawn end caps), ordered from the
  Radiant end to the Dire end. `PathLength`, `PointAtArc`, `ArcOfPoint`, and
  `PathTangent` are the arc-length primitives over those polylines (the tangent
  is the real creep-line axis at a lane point).
- `MirrorWave(our_wave, our_path, enemy_path, team)` estimates a fogged enemy
  wave by symmetry rather than modeling it: your role-paired wave at
  arc-distance `s` from your end of its lane puts theirs at `s` from their end
  (same spawn cadence, travel, and speed). Speed is read off your own creeps.
  `ClampBeyondSight(est_front, our_front, path, team, vis)` then keeps the
  estimate honest: a fogged front cannot sit where your own creeps would see
  it, so absence of vision is data too.
- `MeetingPoint(ally_wave, enemy_wave, mid_point, push_dir)` is where the two
  engaged waves collide (the wave-clear aim point); `PredictMeeting(a, b)` is
  the kinematic version: `{ point, eta }` from two closing `{ pos, speed }`
  records, one expression for all three lanes.
- `WaveSpeed(w)` and `TrackFrontSpeed(track, key, front, now, opts)` prefer the
  measured front displacement over the stat speed: a body-blocked wave reads
  full move speed while standing still, so stat-fed ETAs run optimistic.
- `SimFight(a, b, opts)` is a deterministic attrition sim between two combatant
  lists (both sides focus the first living foe; towers ride along as
  untargetable support). `WaveCombatants(wave, cycle)` builds those lists from
  a wave (live HP when visible, full-HP records from counts when estimated),
  and `PushForecast(ally_wave, enemy_wave, opts)` iterates the fight across
  reinforcing waves into a signed lane balance (`bal`, + = ally wins).
- `DepthRuler(towers, fountains, team)` plus `Depth(ruler, pos, lane)` give a
  signed per-lane depth: 0 at the lane's own T1 midpoint (where waves actually
  meet), positive toward the enemy side.

## Assembling lane state

`BuildLaneStates(creeps, towers, heroes, opts)` composes the full per-lane state
from plain inputs. It splits creeps by team, detects waves per side (push
directions from `opts.enemy_push` / `opts.ally_push`), picks the ENGAGED wave per
lane per side (the cluster whose front is furthest advanced along the team's
push; the biggest cluster is usually the fresh wave back at a tower), predicts
the clash against that lane's own towers, counts heroes within `opts.hero_radius`
(default 1200) of the contact, and (when anchors and kinematics are supplied)
computes the intercept to the settle point. If a lane has no visible enemy wave
and `opts.game_time` is set, it fills one from `ExpectedWave`; pass `opts.paths`
(from `BuildLanePaths`) and the estimate also gets a mirrored front position via
`MirrorWave` + `ClampBeyondSight` (the clash itself stays visible-only). Returns
a table keyed `top` / `mid` / `bot`, each:

```lua
{ lane, enemy_wave, ally_wave, gold, towers, enemy_heroes, ally_heroes,
  clash, intercept, meeting }
```

`meeting` is the `MeetingPoint` of the two engaged waves. `opts.team` is your
team; intercept opts are `anchors`, `hero_pos`, `move_speed`, `tp`,
`allowed_kinds` (include `"creep"` / `"ally"` to use those as anchors), and
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

## Lane.Route (was route.lua)

The farm-route planner: pure, receding-horizon, prize-collecting within a time
budget, over a unified FarmTarget set. Stateless: no engine calls, no clock, no
background loop. You pass plain FarmTarget records plus your kinematic state and
weights, get back the best ordered sequence, and execute ONLY the first leg,
re-planning on your own cadence (a far target's leg shrinks as you close on it,
so nothing is ever permanently committed). Old `require("lib.route")` callers
just switch to `Lane.Route`.

A FarmTarget:

```lua
{ pos = {x=, y=}, value = <gold>, clear_t = <seconds>, risk = <0..1?>,
  contested = <boolean?>,
  window = { from=, to= },            -- optional, absolute game-clock times
  mana_cost = <number?>, hp_cost = <number?>,
  decay_per_s = <number?>, born = <time?>, value_floor = <number?>,
  restore = <boolean?> }              -- refill node: tops up mana/hp, no value
```

`hero_state` carries `pos`, `move_speed`, `anchors`, and `tp` (the same shapes
`InterceptETA` takes: each leg costs the cheaper of a plain walk or a ready
teleport anchor), plus optional resource state (`mana`, `hp`, `mana_regen`,
`hp_regen`, `max_mana`, `max_hp`, `reserve_mana`, `hp_floor`, `refill_frac`).
With no resources given, the mana/hp gating is inert.

`Route.Plan(targets, hero_state, opts)` drops contested, hard-risk-vetoed
(`risk >= opts.risk_hard`), and unreachable (`opts.max_leg_s`) targets, trims to
the top `opts.pool_cap` by a cheap risk-adjusted value/time score, then runs a
bounded DFS over ordered sequences with feasibility pruning (a sequence is only
as good as its collectable prefix) and an optimistic value bound. The objective
is max risk-adjusted gold within `opts.horizon_s`, ties break on less time. A
target only collects if it finishes inside the horizon and before its
`window.to`; `decay_per_s` ages a wave's value from `born` down to
`value_floor`, so decaying targets naturally sort first. `opts.return_pos`
reserves time to get back by the deadline, and `opts.step_decay` (0..1)
discounts later steps in the score only, so a plan that banks its value early
wins ties against one that promises it later.

| Function | Returns |
|----------|---------|
| `Route.Plan(targets, hero_state, opts)` | `{ steps = {FarmTarget,...}, gold, time, score }`; opts: `now`, `horizon_s` (default 30), `max_steps` (4), `risk_weight`, `risk_hard` (1.0), `pool_cap` (10), `max_leg_s`, `step_decay`, `return_pos` / `return_speed` / `return_anchors` / `return_tp`, `refill_frac` |
| `Route.Select(targets, hero_state, opts)` | the single first leg to execute now, or nil |

## Lane.Schedule (was schedule.lua)

The timing-anchored shove-cycle controller: everything keyed to the game clock,
from "when does the next wave arrive" to "shove, jungle, or recover". Pure: you
assemble plain data (from lane records plus engine reads) and pass it in. Old
`require("lib.schedule")` callers just switch to `Lane.Schedule`.

`ClearTime(eff_hp, cal)` returns `{ casts, t_clear }`: the wave-clear cast count
from effective HP / per-cast damage (rounded to NEAREST: allied creeps finish
sub-half remainders), with calibrated wall-clock durations.
`cal = { march_dmg_per_cast, cast_dur, robot_kill, rearm_channel }`: per-cast
damage, per-cast duration, a one-time damage tail, and a between-casts
re-channel. The field names come from the hero it was calibrated on; the math is
generic to any wave-clear nuke.

`NextOnGrid(now, period, phase)` returns the next time on a period grid at a
phase, strictly after `now`. `NextWaveArrival(now, period, phase, last_wave_t,
fresh_window)` builds on it for waves: it uses the MEASURED rhythm
(`last_wave_t % period`) while the last observation is fresh, else the
calibrated spawn-clock phase, so anticipation survives fog and missed waves.
Feed an ARRIVAL time as `last_wave_t`, never the wave's death time.

`Schedule.EVENTS` is the whole Dota clock in one table (`wave_spawn`,
`neutral_respawn`, `bounty_rune`, `power_rune`, `water_rune`, `lotus`,
`tormentor`, `day_start`, `night_start`), and `NextEvent(name, now, last)` looks
one up: grid events repeat on `{ period, phase [, first] }`, one-shots carry
`{ times }`, and kill-anchored events (tormentor) take the last kill time as
`last`. `SeqFits(durations, deadline, now)` answers whether a sequence of
durations fits before a deadline (a combo inside a stun window, a save before a
projectile lands): `{ fits, total, start_by }`.

`Schedule.Plan(ctx)` is the cycle decision itself: the base verdict is recover
(unsafe, or the shove is unfundable at leave time), shove (the wave is due), or
jungle (there is slack), and then a set of declared, ordered rules refines it:
economy vetoes (`far_travel_s`/`min_wave_ehp`, `camp_alt_s`, `gone`,
`thin_ehp`), a stand-safety veto (`covers == false`), a push-sim veto
(`bal <= bal_min`), a lane-first filler that converts short slack into an early
shove or a fountain trip, an HP floor, and a `defend_crash` override that
forces the clear when the enemy wave is crashing your own tower (but never over
unsafe, unfundable, or below the HP bar). Every optional ctx field that is nil
leaves its rule inactive, so a minimal
`ctx = { now, cal, travel_to_mid, mana, shove_cost, safe, wave = { arrival, eff_hp } }`
behaves like the plain version. One invariant is pinned: the deadline is always
the CURRENT wave's arrival; there is deliberately no defer-to-next-wave.

| Function | Returns |
|----------|---------|
| `ClearTime(eff_hp, cal)` | `{ casts, t_clear }` |
| `NextWaveArrival(now, period, phase, last_wave_t, fresh_window)` | next arrival, strictly > now |
| `NextOnGrid(now, period, phase)` | next grid time, strictly > now |
| `NextEvent(name, now, last)` | next occurrence of a named clock event, or nil |
| `SeqFits(durations, deadline, now)` | `{ fits, total, start_by }` |
| `Plan(ctx)` | `{ action = "shove"|"jungle"|"recover", reason, deadline, leave_by, slack, casts, t_clear, mana_at_leave_by, recover_fits }` |
| `WaveCycleCost(c)` | mana cost of the next full wave cycle, `2 * (c.w + c.rearm + c.keen)` |
| `CycleFill(ctx)` | `{ fill = "fountain", need }` when the pool cannot fund the next wave (`ctx.broke_bar`), else `{ fill = "park" }` |
| `StackWindow(now, opts)` | `{ aggro_at, from, done, clear_t, to }`: aggro at ~:54 (`opts.aggro_sec`) so the camp walks across the :00 respawn and doubles |
