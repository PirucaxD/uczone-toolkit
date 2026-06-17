# geometry

Hero-agnostic 2D position, distance, and movement-prediction helpers. Every
function takes entity or Vector arguments explicitly, so nothing here reads
hidden hero state. Distances are in Hammer units; the z (height) component is
carried but ignored for 2D math.

## Distance

```lua
local Geom = require("lib.geometry")
local d = Geom.dist_between(my_hero, target)   -- math.huge if either is nil
```

| Function | Returns |
|----------|---------|
| `dist_between(a, b)` | 2D distance between two entities, `math.huge` if either is nil |
| `dist_from_to(from, to)` | the same value, with a directional "from to" reading |

## Movement prediction

The useful part. A skill with a cast point or travel time has to be aimed where
the target WILL be, not where it is now. Two models are provided.

`lead_target_pos` is the cheap one: it reads the target's instantaneous velocity
(the engine's `m_vecVelocity`) and projects `lead_s` seconds ahead. A standing
unit gets no lead (zero velocity keeps the point on the target). It returns `nil`
for an invalid target, so callers pair it with a fallback:

```lua
local aim = Geom.lead_target_pos(target, me, 0.5) or current_target_pos
```

`PredictPos` is the steady one. It averages velocity over a short history buffer,
which removes the jitter of a single-frame read, and falls back to the
instantaneous lead (capped at foot speed) when there is no history. Feed it by
calling `SampleVelocities` once per tick from your `OnUpdateEx`:

```lua
-- once per tick:
Geom.SampleVelocities(me, 1600)          -- record nearby enemy positions
-- when you need an aim point:
local aim = Geom.PredictPos(target, 0.5) or current_target_pos
```

A vision gap over 0.25s, or a per-tick jump beyond foot speed (a blink or
teleport), resets that unit's buffer, so prediction never leads off a phantom
velocity. Hard-CC'd targets (stunned / rooted / frozen) get no lead.

| Function | Returns |
|----------|---------|
| `lead_target_pos(target, me, lead_s)` | instantaneous-velocity lead Vector, `nil` if invalid (`me` is unused, kept for API stability) |
| `SampleVelocities(me, radius)` | records nearby enemy positions into the history buffers (call once per tick; default radius 1600) |
| `PredictPos(target, lead_s)` | smoothed-velocity lead Vector, with the fallbacks above |

This is the entity-and-history prediction the brain actually casts on. For the
lower-level pure-vector intercept math (solve a projectile lead from a known
velocity), see [prediction](prediction.md).

## AoE and line placement

Given a set of targets, where do you drop a circular AoE, or which way do you aim
a line, to catch the most of them? Both predict each unit `lead_s` ahead first,
then search candidate placements (including points BETWEEN units, so two units up
to `2 * radius` apart can both be caught).

```lua
-- circular AoE (e.g. a stun zone), radius 250:
local center, n = Geom.BestAoeCenter(enemies, 250, 0.4)

-- line / projectile (half-width 110, length 1075) cast from `source`:
local aim, n = Geom.BestLineAim(enemies, source_pos, 110, 1075, 0.4)
```

Pass `must_cover` (an entity) as the last argument when one target has to be hit
no matter what (e.g. the primary kill target): only placements that cover it are
considered, and the search maximizes the others around it. Both return `(nil, 0)`
on empty input.

| Function | Returns |
|----------|---------|
| `BestAoeCenter(units, radius, lead_s [, must_cover])` | `(center Vector, count)` catching the most units |
| `BestLineAim(units, source, half_width, length, lead_s [, must_cover])` | `(aim_point Vector, count)` for the densest line |
