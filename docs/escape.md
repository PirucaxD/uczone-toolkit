# escape

Danger-aware position picking for self-displacement saves and offensive
pushes. Hero-agnostic: every function takes entity / Vector arguments
explicitly (no hidden hero-state reads), matching the geometry lib
convention. Distances are Hammer units.

Nothing here issues an order. These are stateless decision-support helpers
that return positions, scores, or booleans; the hero script decides what to
do with them. The few stateful harnesses (the turn-then-fire and
re-issue-while-airborne tickers) keep their state in a caller-owned `pending`
struct and reach the engine through a `cfg` callback bundle, so the lib never
imports a hero's wrappers directly.

## Danger scoring

`DangerAtPos` is the core primitive: a proximity-weighted count of visible
enemy heroes near a position, scaled down by a turn-cost factor that biases
toward landings forcing the enemy to swing far off their current facing (the
chase-turn delay is free distance for the defender). Lower is safer. Towers
are intentionally not counted - there is no clean enemy-tower-in-radius API,
and the hero-only term closes the documented blind spot.

`SafePushDestination` validates one candidate landing: terrain traversability,
plus either a "must increase distance from this specific threat" gate (when the
threat caster is known) or a centroid-danger check against the current spot.
`PickDir` runs the search. It tries seven angles off straight-away from the
threat (`0, -35, 35, -65, 65, -90, 90` degrees), gates each through
`SafePushDestination` and an optional caller filter, and returns the unit
escape direction plus landing of the safest survivor. Ties favour the
straight-away baseline.

| Function | Returns |
|----------|---------|
| `DangerAtPos(me, pos)` | danger score at `pos` (higher = more dangerous), `0` if invalid |
| `SafePushDestination(me, dest_pos, threat_caster_hint, danger_now)` | `dest_pos` if the landing passes terrain and the threat / centroid gate, else `nil`; second return is the landing danger for reuse |
| `PickDir(me, me_pos, toward_threat, push_distance, threat_caster_hint, filter_fn)` | `(escape_dir, landing)` of the safest of 7 angles, `(nil, nil)` if all rejected |

## Self-displacement saves

`ComputeSafeDest` is the high-level "where do I escape TO". It builds the
toward-threat direction (the known caster if alive, otherwise the centroid of
enemy heroes within 1500u), hands off to `PickDir`, and returns the escape
direction and landing. The optional `threat_pos` lets the caller pass a
predicted position so the push aims away from where a charging threat is
heading rather than where it currently sits.

```lua
local Escape = require("lib.escape")

local dir, landing = Escape.ComputeSafeDest(me, threat_caster, 600)
if landing then
    -- the hero decides how to act on it; the lib never issues the order
end
```

`TrySelfPush` and `SelfPushTick` are the turn-then-fire harness behind Pike and
Force self-casts. `TrySelfPush` computes the destination and either fires
immediately (already facing within 30 degrees of the escape direction) or
issues a turn and returns a `pending` struct. The caller stashes that struct and
feeds it to `SelfPushTick` once per frame; the tick fires once facing aligns, or
drops the pending on timeout / threat-gone.

`QueueSafePostMove` and `PostAirborneMoveTick` are the re-issue-while-airborne
harness behind Eul and Windwaker (the airborne save is cast before this call;
these only stage the landing walk). `QueueSafePostMove` queues a
`MOVE_TO_POSITION` to a safe landing and returns a `pending`;
`PostAirborneMoveTick` waits for the airborne modifier to appear, then either
defers until it clears (Eul: no movement during the disable) or re-issues the
move while airborne (Windwaker: free pathing mid-lift), recomputing the
destination from the threat's live position each re-issue.

All four ticker entry points take a `cfg` table of hero-side callbacks
(`safe_issue`, `issue_item_self`, `tlog`, `now`, `uname`, `item_get`,
`item_ready`, optional `on_self_cast`, plus `hero_key` / `layer`). The lib calls
back through these so it stays free of any specific hero's wrappers.

| Function | Returns |
|----------|---------|
| `ComputeSafeDest(me, threat_caster, push_distance, threat_pos)` | `(escape_dir, landing)`, `(nil, nil)` if no direction or all candidates rejected |
| `TrySelfPush(me, intent, item, item_name, push_dist, threat_caster, cfg, threat_pos)` | `(pending, ok)`: `pending` to stash (`nil` on immediate fire / skip), `ok` whether an action issued |
| `SelfPushTick(me, pending, cfg)` | updated `pending` (`nil` once fired / timed out / threat gone) |
| `QueueSafePostMove(me, intent, push_dist, threat_caster, modifier_name, moves_during_airborne, cfg)` | `pending` to stash, `nil` if no safe destination |
| `PostAirborneMoveTick(me, pending, cfg)` | updated `pending` (`nil` once arrived / expired / dead) |

## Fog and gank awareness

`FogSnapshot` builds the shared per-call enemy roster: every living enemy hero,
visible or fogged. Visible enemies carry their true origin (`age = 0`); fogged
enemies carry their last-known position plus a `probable_radius` that grows with
time-since-seen (capped at 700 MS, 30s age) to model where they could have
moved. Pass the returned snapshot as `opts.snapshot` to the consumers below so
several checks in one frame share a single scan instead of each rescanning.

`NearbyEnemiesIncludingFog` counts enemies whose current possible position could
reach within a radius of a point. `AdvanceRiskScore` turns that into a composite
score (visible enemies weighted by closeness, fog enemies half-weighted for
uncertainty); the suggested read is `<= 30` safe, `30-60` risky, `> 60` abort,
but the caller picks the threshold.

`PossibleGankers` and `GankImminent` answer "who can reach this spot within N
seconds", `MissingFromMap` lists enemies off the minimap longest-first, and
`InitiatorAccountedFor` checks a named set of heroes for visibility (gate a combo
on "is their initiator visible"). `SafestSpotNear` grid-searches the eight points
around the defender plus the centre, scoring each via `AdvanceRiskScore` against
one shared snapshot, and returns the least dangerous.

```lua
local Escape = require("lib.escape")

local snap = Escape.FogSnapshot(me)                       -- one scan
if Escape.GankImminent(me, Entity.GetAbsOrigin(me), 3.0, 2,
                       { snapshot = snap }) then
    local spot, score = Escape.SafestSpotNear(me, 700,
                                              { snapshot = snap })
    -- retreat toward `spot`; the hero issues the move, not the lib
end
```

| Function | Returns |
|----------|---------|
| `FogSnapshot(me, opts)` | `{ t, heroes = {{entity, pos, age, probable_radius, visible}} }` for all living enemies |
| `NearbyEnemiesIncludingFog(me, pos, radius, opts)` | `(visible_count, fog_count, list)` of enemies that could reach near `pos` |
| `AdvanceRiskScore(me, landing, opts)` | `(score, breakdown)` composite danger at `landing` (lower = safer) |
| `PossibleGankers(me, pos, eta_s, opts)` | `{ gankers = {{entity, eta_seconds, dist, visibility, age}}, summary }` sorted by ETA |
| `GankImminent(me, pos, eta_s, min_count, opts)` | `(imminent, gankers)`: are `>= min_count` (default 2) enemies arrivable within `eta_s` |
| `MissingFromMap(me, min_age_s, opts)` | list of `{entity, age, last_pos}` off-map at least `min_age_s` (default 5), longest first |
| `InitiatorAccountedFor(me, initiator_names, opts)` | `{accounted, missing, visible, unmatched}` for a list of `npc_dota_hero_*` names |
| `SafestSpotNear(me, radius, opts)` | `(best_pos, best_score)` of the least dangerous of 9 grid samples |

## Offensive advance

The inverse of `ComputeSafeDest`: instead of "where do I escape TO", these ask
"is it safe to push TOWARD this enemy, and where do I land". Built for an
offensive Pike self-cast (push 600u along facing), but the geometry is reusable
for any directional push.

`PikeAdvanceLanding` is the pure geometry (a point `push_dist` along the facing
toward a target). `ComputeAdvanceDest` wraps it: accept a hero entity or a
Vector, compute the landing, score it with `AdvanceRiskScore`, and return
`(landing, score, breakdown)` so the caller decides fire-or-skip against its own
threshold. `BlinkInLanding` picks a blink destination that brings the target
within engage range while diving as little as possible (near edge) and never
beyond the blink range, returning the landing, its risk score, and whether the
target is actually reachable.

```lua
local Escape = require("lib.escape")

local landing, score = Escape.ComputeAdvanceDest(me, target, 600)
if landing and score <= 30 then   -- caller-chosen threshold
    -- safe to push in; the hero fires the item itself
end
```

| Function | Returns |
|----------|---------|
| `PikeAdvanceLanding(me_pos, target_pos, push_dist)` | landing `push_dist` units toward `target_pos`, `nil` on zero direction |
| `ComputeAdvanceDest(me, target, push_dist, opts)` | `(landing, score, breakdown)` for a push toward `target` (hero or Vector), `(nil, nil, nil)` if invalid |
| `BlinkInLanding(me, aim_pos, blink_range, engage_range, opts)` | `(landing, risk_score, reachable)` for a blink that engages `aim_pos` |
