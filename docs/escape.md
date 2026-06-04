# escape

Danger-aware "where should the defender go" picker. Three small helpers,
all stateless, all take the defender entity as an explicit arg (no
implicit hero-state reads).

The reason for sharing this is the picking loop. Defensive items that
move the hero (Force Staff, Hurricane Pike, blink) only help when the
destination is meaningfully safer than the current spot. A push that
lands you next to a backliner because the straight-away vector points
right at them is a save that fired and did not save. The original use
case was Sniper's Pike-on-self: the picker checks 7 angles off the
straight-away axis and ranks landings by proximity-weighted enemy
density, so the brain stops shoving the hero into the worst possible
spot.

## Setup

```lua
local Escape = require("lib.escape")
local Target = require("lib.target")  -- escape uses Target internally
```

## DangerAtPos

```lua
local score = Escape.DangerAtPos(me, pos)
```

Proximity-weighted enemy-hero score at a world position. Lower is
safer. Each visible enemy hero within 1400u of `pos` contributes
`(1 - d/1400) * 30`, scaled by a turn-cost factor: landings that
force the enemy to turn far from their current facing rank as safer
because the turn delay during chase is free distance for the
defender. Towers and creeps are intentionally not counted - the
hero-only term closes the documented blind spot and avoids
overweighting wave positions.

Used inside `SafePushDestination` as the centroid-fallback gate and
inside `PickDir` as the ranker.

## SafePushDestination

```lua
local landing = Escape.SafePushDestination(me, dest_pos, threat_caster_hint)
if landing then ... end
```

Validates a candidate landing. Returns the destination on success,
`nil` on rejection. Three checks:

1. Terrain via `GridNav.IsTraversableFromTo(me_pos, dest_pos)`.
2. When a specific threat caster is known, the destination must
   INCREASE distance from that threat (avoids pushing the defender
   into the very threat the save is meant to escape).
3. Centroid fallback via `DangerAtPos` when no specific threat is
   known: a destination meaningfully more dangerous than the current
   spot is rejected (margin = 12 against the ~30 per-enemy scale,
   avoids flapping on a marginal diff).

## PickDir

```lua
local escape_dir, landing = Escape.PickDir(
    me, me_pos, toward_threat, push_distance,
    threat_caster_hint, filter_fn  -- both optional
)
if escape_dir then
    -- escape_dir is the unit vector from me to landing
    -- landing is the chosen destination
end
```

7-angle danger-aware destination picker. Tries angles
`{0, -35, 35, -65, 65, -90, 90}` (degrees) off straight-away from
`toward_threat`. Each candidate is gated by `SafePushDestination`
plus the optional `filter_fn(esc_dir, landing) -> bool`, then ranked
by `DangerAtPos` (lower is safer). Ties favor 0° via strict
less-than - a marginal angle does not win over the straight-away
baseline unless meaningfully safer.

The `filter_fn` is for callers that need extra per-candidate
constraints. A grenade-self save that needs the cast point to face
within 120° of the chosen escape direction can pass a filter that
returns true only when the angle check passes; the picker will skip
candidates that fail the filter even if they pass the danger
ranking.

Returns `(nil, nil)` when every candidate failed terrain or the
threat-distance gate. The caller falls through to the next save in
the chain.

## Typical caller shape

The hero's defensive `.fire` body computes `toward` (caster
direction or enemy-centroid fallback), picks a direction, optionally
checks current facing (cyclones / pushes that move along facing need
the hero turned the right way first), then issues the save.

```lua
local toward = (caster_pos - me_pos):Normalized()
local escape_dir, landing = Escape.PickDir(me, me_pos, toward, 600, caster)
if not escape_dir then return false end

-- Pike push is 600u along facing. If we are already facing within
-- 30 degrees of the chosen direction, fire immediately; otherwise
-- turn first via a move order and arm a pending-tick that fires the
-- push once alignment is reached.
local angle = math.deg(math.abs(NPC.FindRotationAngle(me, landing)))
if angle <= 30 then
    return issue_self_cast(pike)
end
-- queue MOVE_TO_POSITION landing; tick checks angle each frame
```

## Engine gotchas the helpers do NOT solve

These bite at the caller layer, not inside `Escape`:

- `NPC.FindRotationAngle` returns radians, not degrees. The 30°
  tolerance compare above only works because of the `math.deg` call.
  Without it the comparison is always true and the hero never turns.
- The first cast of a freshly-acquired item is silently dropped by
  the engine. Items like Hurricane Pike need a prime-cast workaround
  or a re-issue if the first cast looks like it failed.
