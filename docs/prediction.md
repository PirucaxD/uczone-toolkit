# prediction

The hard part of landing any non-instant spell: by the time it arrives, the
target has moved. This lib answers "where do I aim so the spell and the
target meet?".

Velocity is read from the engine's real velocity vector (`m_vecVelocity`),
**not** the move-speed stat — a unit standing still has a non-zero move-speed
stat but zero velocity, and a unit's facing is not always its travel
direction. If you smooth velocity yourself, pass it via `opts.velocity`.

## Two cases

**`lead`** — your spell has a fixed, known time-to-land (a ground zone with a
fixed wind-up, a fixed-duration channel). The aim point is just
`position + velocity * time`.

**`intercept`** — your spell is a projectile with a *speed*, so flight time
depends on how far the aim point ends up being. That is circular, so it is
solved as a quadratic.

## Functions

| Function | Returns |
|----------|---------|
| `velocity(target)` | the target's current velocity Vector (zero if still) |
| `lead(target, time_s, opts)` | where the target will be in `time_s` seconds |
| `intercept(launch, target, speed, opts)` | aim Vector + time-to-hit, or `nil` |
| `travel_time(launch, point, speed, delay)` | flight time to a fixed point |

`opts` may carry `cast_delay` (seconds before the projectile launches),
`velocity` (override the measured velocity) and `target_pos` (override the
target's current position).

`intercept` returns `nil` when there is no solution — the target is moving
away faster than the projectile can ever catch it.

## Example

```lua
local predict = require("lib.prediction")

-- a projectile nuke: cast point 0.3s, projectile speed 1200
local aim, t = predict.intercept(me, enemy, 1200, { cast_delay = 0.3 })
if aim then
    -- cast at `aim`; the spell will connect in `t` seconds
end

-- a ground spell that always lands 1.5s after you cast it
local spot = predict.lead(enemy, 1.5)
```
