# route

A pure, receding-horizon farm-route planner. Given a set of farm targets (jungle
camps and lane waves) with values, positions, time windows and risk, it returns
the best ordered sequence that maximizes risk-adjusted gold collectable within a
time horizon. You execute only the first leg, then re-plan on your own cadence:
the plan is a snapshot, not a commitment, so it stays honest as the map changes.

Hero-agnostic and stateless. Nothing here calls the engine, reads a clock, or
runs a background loop. The hero script passes plain target records plus its own
kinematic state plus weights, and gets back a sequence. That keeps the module
fully testable with zero runtime-API risk. It pairs with the `lane` lib for leg
travel times, so `require("lib.lane")` must resolve (it does the InterceptETA
math used to chain legs through teleports or a plain walk).

## Target contract

Each target is a table. Only `pos` (a Vector with `.x` / `.y`) is required:

```lua
{
  pos        = <Vector>,    -- target position (required)
  value      = <number?>,   -- gold this target is worth (missing = 0)
  risk       = <number?>,   -- 0..1 danger; >= opts.risk_hard vetoes it outright
  clear_t    = <number?>,   -- seconds to clear once you arrive (missing = 0)
  contested  = <boolean?>,  -- true drops the target before planning
  window     = { from = <number?>, to = <number?> },  -- absolute game-clock availability
  born       = <number?>,   -- clock time the value started decaying (defaults to opts.now)
  decay_per_s = <number?>,  -- gold lost per second of age (lane waves)
  value_floor = <number?>,  -- decay never drops value below this (missing = 0)
  restore    = <boolean?>,  -- refill node: tops up mana/hp, contributes no gold
  mana_cost  = <number?>,   -- mana spent on collection (gated against reserve_mana)
  hp_cost    = <number?>,   -- hp spent on collection (gated against hp_floor)
}
```

A `window` is in absolute game-clock time on the same scale as `opts.now`. If a
target cannot be reached before `window.from`, the planner waits; if it would
finish after `window.to`, it is skipped. Decaying targets (lane waves lose gold
as they age toward the next wave or get denied) are valued at the moment of
collection, so the planner naturally orders them first to catch them fresh.

## Hero state

The second argument carries the hero's kinematics and (optionally) resources:

```lua
{
  pos = <Vector>, move_speed = <number>, anchors = <table>, tp = <table>,  -- for lane.InterceptETA
  mana = <number?>, hp = <number?>,           -- omit both for resource-free planning
  mana_regen, hp_regen, max_mana, max_hp,     -- regen accrues over travel + wait
  reserve_mana, hp_floor,                     -- spend gates (keep this much in reserve)
  refill_frac,                                -- fraction a restore node tops up to (default 1)
}
```

When `mana` and `hp` are both nil, all resource gating is inert, so existing
resource-free callers keep working unchanged.

## Planning

`Plan(targets, hero_state, opts)` is the main entry point. It filters out
contested and hard-risk-vetoed targets, trims the rest to a search pool by a
cheap one-step value-per-time score, then runs a bounded depth-first search over
ordered sequences (each target used at most once) with feasibility pruning and an
optimistic value bound. It returns the optimum within that bound:

```lua
{ steps = { <FarmTarget>, ... }, gold = <number>, time = <number>, score = <number> }
```

`steps` is the chosen sequence, `gold` the total collected value, `time` the
seconds the run takes, and `score` the risk-adjusted objective
(`sum(value) - risk_weight * sum(risk)` over collected targets). An empty result
is `{ steps = {}, gold = 0, time = 0, score = 0 }`. Restore nodes are never
trimmed from the pool, so a refill stays available even in a crowded field.

`opts` fields, all optional:

| Field | Default | Meaning |
|-------|---------|---------|
| `now` | `0` | current game-clock time; windows and `born` are on this scale |
| `horizon_s` | `30` | planning horizon; a target must finish within `now + horizon_s` |
| `max_steps` | `4` | maximum legs in a sequence |
| `risk_weight` | `0` | gold-per-risk trade in the objective |
| `risk_hard` | `1.0` | targets with `risk >= risk_hard` are vetoed before planning |
| `pool_cap` | `10` | search pool size after the cheap pre-trim (bounds the search) |
| `refill_frac` | `1` | fraction a restore node refills to (hero_state may override) |

`Select(targets, hero_state, opts)` is the convenience wrapper: it returns just
the first leg of the plan (the target to act on now), or `nil` if there is no
plan. This is the receding-horizon call you make each tick.

## Scoring internals

These are public for testing and custom scoring; most callers only need `Plan` /
`Select`.

`_timeline(seq, hero_state, opts)` walks a fixed ordered sequence and returns the
collected prefix plus totals: `{ collected = {...}, gold, time }`. Starting at
`hero_state.pos` and `opts.now`, each target adds a leg (`lane.InterceptETA`), a
wait until `window.from`, and `clear_t`. Regen accrues over travel and wait;
collection is gated on affordability against `reserve_mana` / `hp_floor`. The
walk stops at the first uncollectable target, since a sequence is only as good as
its collectable prefix.

`_score(seq, hero_state, opts)` wraps the timeline into the risk-adjusted
objective: `{ score, gold, time, collected }`.

`_leg_time(from_pos, target, hero_state)` is the single-leg travel time via the
best ready teleport anchor or a plain walk (a pure scalar from `lane.InterceptETA`).

## Usage

```lua
local Route = require("lib.route")

-- targets you assembled from camps + waves this tick
local plan = Route.Plan(targets, hero_state, {
    now         = game_time,
    horizon_s   = 25,
    risk_weight = 80,    -- 80 gold of value is worth one unit of risk
    risk_hard   = 0.8,   -- never route into a target at 0.8+ risk
})

local next_target = plan.steps[1]   -- execute only the first leg
if next_target then
    go_farm(next_target)            -- then re-plan next tick (receding horizon)
end

-- or skip straight to the first leg:
local now_target = Route.Select(targets, hero_state, { now = game_time })
```
