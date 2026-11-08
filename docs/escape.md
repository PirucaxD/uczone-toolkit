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
imports a hero's wrappers directly. The other stateful resident is
`Escape.Vision`, the shared enemy last-seen tracker absorbed from the old
vision lib; it gets its own section below.

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

## Vision: the shared last-seen tracker (`Escape.Vision`)

The absorbed vision lib mounts here as `Escape.Vision`. It answers the one
question no engine API answers: how long ago was this enemy hero last visible?

Why it has to exist: `Hero.GetLastVisibleTime` is dead. It is documented
nilable, and measured nil on 405 of 405 fogged reads across all five enemy
heroes in one full match, so any fog-age model built on it is inert. And
`FogOfWar.IsPointVisible` answers "is this POINT visible now", not "when did I
last see this hero". So the timestamp gets built by hand: an `OnSetDormant`
handler stamps the moment a hero entity leaves vision, and `Age` reads it back.

Wire it with `Vision.Wire(callbacks)`: it chains the handler onto your
callbacks table's `OnSetDormant`, preserving any handler already there, and is
idempotent per table (wiring the same table twice never double-fires). The
`type` argument is the documented `Enum.DormancyType` and it decides: 1
(`ENTITY_DORMANT`) stamps. `Entity.IsDormant` is only recorded, because it
reads false inside the callback (the engine sets the flag afterwards).
Creeps are ignored (heroes only; creeps fog constantly).

`Age(e)` returns 0 for a currently visible hero, seconds-since-fogged for a
dormant one, and nil for a hero it never observed. nil is the safety valve:
consumers apply their own default, and `FogSnapshot`'s existing `or 0` turns
nil into "fresh visible", byte-for-byte the pre-tracker behavior, so an empty
tracker (say `OnSetDormant` never fires on some engine build) changes nothing
anywhere. `Stats()` reports `{ tracked, events, types }`; `events` staying 0
in a real game is the tell that the callback never fires and the whole
facility is inert.

Two design points worth copying. First, the tracker owns its clock: both the
stamp and the age read come from the same internal monotonic clock
(`GlobalVars.GetCurTime`, falling back to `GameRules.GetGameTime`). A
caller-supplied clock is exactly how ages go silently negative (mixing the
on-screen `GetDOTATime` against an engine-clock timestamp) and clamp to 0
forever; owning the clock makes that class of bug structurally impossible.
Second, the state lives in an anchored store, not module locals: the shared
tables sit under a `package.loaded` pseudo-key, so they survive a re-require.
Hero scripts commonly cache-clear lib modules at load; with plain module
locals each hero would fork an empty tracker, only the last-wired instance
would stamp, and the others would read eternally-empty fog ages with every
gate green. The anchor is `package.loaded` rather than `_G` because the
scripting sandbox does not expose `_G`. Known ceiling: the store also survives
across matches in one client session, so a recycled entity handle can inherit
a stale stamp (a very large age). `FogProximityRisk` drops such a ghost at any
`age_cap` below 30, including the default 5 (its snapshot age reads 30s), and
so does `NearestEnemyEdge` given such a cap (the `nil` default keeps it);
`NearbyEnemiesIncludingFog`, `PossibleGankers` and the functions built on them
treat it as able to be almost anywhere (more caution) unless the caller passes
them an `age_cap` below 30 (see the fog section below).

| Function | Returns |
|----------|---------|
| `Vision.Age(e)` | `0` when visible now; seconds since last seen; `nil` when never observed |
| `Vision.LastSeen(e)` | the raw stamp (monotonic seconds), diagnostics only |
| `Vision.Stats()` | `{ tracked, events, types }` probe counters |
| `Vision.Init()` | idempotent init, mirrors the other libs' Init contract |
| `Vision.Wire(callbacks)` | chains the dormancy handler onto `callbacks.OnSetDormant`, idempotent per table |

## Fog and gank awareness

`FogSnapshot` builds the shared per-call enemy roster: every living enemy hero,
visible or fogged. Visible enemies carry their true origin (`age = 0`); fogged
enemies carry their last-known position plus a `probable_radius` that grows with
time-since-seen (capped at 700 MS, 30s age) to model where they could have
moved. The time-since-seen comes from the `Escape.Vision` tracker above (its
nil collapses to 0 here). Pass the returned snapshot as `opts.snapshot` to the
consumers below so several checks in one frame share a single scan instead of
each rescanning.

`NearbyEnemiesIncludingFog` counts enemies whose current possible position could
reach within a radius of a point. `AdvanceRiskScore` turns that into a composite
score (visible enemies weighted by closeness, fog enemies half-weighted for
uncertainty); the suggested read is `<= 30` safe, `30-60` risky, `> 60` abort,
but the caller picks the threshold.

`ReachableFog` is the tighter fog count: only enemies fogged within `fresh_s`
seconds count, and each one's probable-disc reach is capped at `reach_cap`, so
a stale blip's huge disc is rejected rather than trusted. `MissingCount` counts
the fogged (alive but not visible) enemies in a snapshot, the classic "how many
are missing before I take a deep camp" lever.

`PossibleGankers` and `GankImminent` answer "who can reach this spot within N
seconds", `MissingFromMap` lists enemies off the minimap longest-first, and
`InitiatorAccountedFor` checks a named set of heroes for visibility (gate a combo
on "is their initiator visible"). `SafestSpotNear` grid-searches the eight points
around the defender plus the centre, scoring each via `AdvanceRiskScore` against
one shared snapshot, and returns the least dangerous.

`FogProximityRisk` is a continuous `0..1` proximity risk: the max over enemies of
a distance falloff. A visible enemy (or just-vanished fog at age 0) reduces to the
plain nearest-enemy falloff `(1 - dist / risk_radius)^2`, so consumers see no
change for visible foes. A recently-fogged enemy is modeled as a
growing-but-decaying reachable disc: the disc radius grows with age (`age * fog_ms`,
how far it could have travelled) while the confidence it contributes decays as it
spreads (`fog_spread / (fog_spread + radius)`), and its falloff is measured from
the disc edge rather than the last-known point. Fog enemies older than `age_cap`
seconds are ignored. It reuses `FogSnapshot`: the first argument is either a
snapshot to reuse or an entity (in which case it scans internally). The disc radius
is recomputed here from age and `fog_ms` rather than read from the snapshot's
`probable_radius`, so `fog_ms` and the snapshot's `max_ms` cannot silently diverge.
The `opts` are `risk_radius` (default 1400), `fog_ms` (default 550), `fog_spread`
(default 900), and `age_cap` (default 5), plus the usual `now` / `max_ms`.

`NearbyEnemiesIncludingFog` and `PossibleGankers` take an opt-in `age_cap`
(default `nil`, no cap) with a different rule: a fogged enemy older than
`age_cap` seconds is treated as age 0 at its last-seen spot (a zero disc, no ETA
credit for time in fog), where `FogProximityRisk` would drop it. Only the reach
and ETA tests change; returned rows keep the snapshot's raw `age` and
`probable_radius`, and visible enemies are untouched. Every function whose
`opts` reach these two applies it as well: `AdvanceRiskScore`, `SafestSpotNear`
and `GankImminent` here, `ComputeAdvanceDest` and `BlinkInLanding` below. One
`opts` table with an `age_cap`, given to `FogProximityRisk` (or to
`NearestEnemyEdge`, which drops the same way) and to any of these, applies
both rules. `FogSnapshot` ignores the key, so `MissingFromMap` keeps
listing long-missing enemies. The cap only matters once `Escape.Vision` is wired
(until then every fogged age is 0); pass the same value you give
`FogProximityRisk` (default 5). `FogSnapshot` clamps ages at 30s, so on its
snapshots a cap of 30 or more never fires.

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
| `ReachableFog(snapshot, pos, opts)` | count of fresh-fogged enemies whose capped disc reaches within `radius` of `pos`; `opts` = `{ radius? (1000), reach_cap? (450), fresh_s? (1.5) }` |
| `MissingCount(snapshot)` | count of fogged (alive, not visible) enemies in the snapshot |
| `AdvanceRiskScore(me, landing, opts)` | `(score, breakdown)` composite danger at `landing` (lower = safer) |
| `PossibleGankers(me, pos, eta_s, opts)` | `{ gankers = {{entity, eta_seconds, dist, visibility, age}}, summary }` sorted by ETA |
| `GankImminent(me, pos, eta_s, min_count, opts)` | `(imminent, gankers)`: are `>= min_count` (default 2) enemies arrivable within `eta_s` |
| `MissingFromMap(me, min_age_s, opts)` | list of `{entity, age, last_pos}` off-map at least `min_age_s` (default 5), longest first |
| `InitiatorAccountedFor(me, initiator_names, opts)` | `{accounted, missing, visible, unmatched}` for a list of `npc_dota_hero_*` names |
| `SafestSpotNear(me, radius, opts)` | `(best_pos, best_score)` of the least dangerous of 9 grid samples |
| `FogProximityRisk(snapshot_or_me, pt, opts)` | continuous `0..1` proximity risk at `pt`, max over enemies of a fog-aware distance falloff |

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

## Chase cutoff geometry

Two pure helpers for deciding a straight-line chase / cutoff. Both take plain
positions, velocities, and option tables (no engine reads), so they are
offline-testable. They model an unobstructed flight that grants no speed bonus:
the chaser moves at its own base move speed, and the only value is taking the
terrain shortcut a walking path cannot.

`ChaseWindow` compares two clocks for the same chase. `catch_eta` is the
straight-line time to reach the target at `opts.fly_speed` (default 300, the
chaser's base MS). `escape_eta` is the soonest the target slips away: the time it
takes the target, moving at `vel`, to exit `opts.kill_reach` (default 1000) of the
chaser, lowered by the time to enter any protection circle in `opts.tower_circles`
(each `{ pos, range }`). A `catch_eta` below `escape_eta` means the chase lands
before the target reaches safety. Positions are `{x, y, z}` tables, `vel` is
`{x, y}` world units per second. Returns `{ catch_eta, escape_eta, intercept,
reason }`, or `nil` on missing arguments or a near-zero `fly_speed`.

`CutoffLock` decides whether the straight flight is a meaningful shortcut over the
walking path that detours around terrain and trees. Given the chaser position, the
intercept point, and a walk path (an array of `{x, y}` waypoints, typically a
`GridNav.BuildPath` result), it sums the walk length and compares it to the
straight-line distance. It locks only when the walk is both at least
`opts.ratio` times the straight distance (default 1.3) and longer by at least
`opts.min_gain` absolute units (default 250), so a marginally longer walk does not
trigger a cutoff. A missing or too-short path is reported unlocked with `ratio = 1`.

```lua
local Escape = require("lib.escape")

local win = Escape.ChaseWindow(me_pos, target_pos, target_vel,
                               { fly_speed = base_ms, kill_reach = 1000 })
if win and win.catch_eta < win.escape_eta then
    local cut = Escape.CutoffLock(me_pos, win.intercept, walk_path)
    if cut.locked then
        -- the straight flight is worth it; the hero acts on the decision
    end
end
```

| Function | Returns |
|----------|---------|
| `ChaseWindow(me_pos, target_pos, vel, opts)` | `{ catch_eta, escape_eta, intercept, reason }`, `nil` on missing args or zero `fly_speed` |
| `CutoffLock(me_pos, intercept, walk_path, opts)` | `{ locked, walk, straight, ratio }`: is the straight flight a worthwhile shortcut over the walk |

## Calibration and diagnostics helpers

`CommitWiden` turns commit-time exposure into a danger-radius widening
distance: `approach_speed * (travel_s + stand_s)`, clamped to `[0, widen_max]`.
The caller supplies the travel time it already computed, so there is no
division anywhere in the function and no way for a 0/0 or NaN to be born here.
`approach_speed <= 0` returns 0 (a no-code-edit kill switch), and a negative or
NaN cap is sanitised to 0: a negative widen would SHRINK every danger radius
and make the bot blind rather than cautious, silently and exactly backwards.
The clamp is `min(cap, max(0, w))` in that exact order so a NaN exposure lands
on 0, not on the cap.

`NearestEnemyEdge` reports the nearest enemy EDGE distance to a point, using
the same edge rule as `FogProximityRisk` (visible = plain distance; fogged =
distance minus the age disc, floored at 0). It is an instrument, never a gate:
`FogProximityRisk` returns exactly 0 for everything past its radius, so a
logged risk of 0.00 cannot distinguish "widen too small" from "nobody there",
and this field fills that calibration hole. It returns `math.huge` on an empty
snapshot so "no enemies" is distinguishable from "enemy at 0u". Component
math on `.x` / `.y`, so plain `{x, y}` tables work as well as engine Vectors.

By default (`opts.age_cap` nil) it carries no age cap, so no enemy is
dropped. That only reads well while every fogged row has age 0, i.e. before
`Escape.Vision` is wired. Once Vision is wired the ages are real, and an
uncapped stale ghost's disc (`age * fog_ms`, 16500u for a 30s ghost) covers
the point from almost anywhere and zeroes the edge: Tinker measured its `ne=`
p50 collapsing from ~1400 to 0. So if you wire Vision, pass `age_cap` (use the
same value you give `FogProximityRisk`, whose default is 5): a fogged enemy
older than `age_cap` is then dropped entirely, as in `FogProximityRisk`, the
other ghosts keep the normal disc shrink, and visible enemies are never
dropped. If the cap drops every enemy the result is still `math.huge`.

`DiagGate` is a keyed throttle for diagnostic log lines: it returns `true`
when the caller should emit, and stamps only then. Distinct keys never starve
each other (a single shared stamp would alias to whichever call site runs
first), and a backwards clock emits rather than suppresses: an instrument's
failure direction must be noisy, never silent.

| Function | Returns |
|----------|---------|
| `CommitWiden(travel_s, stand_s, approach_speed, widen_max)` | widening distance in units, always finite and `>= 0`; `nil` cap = uncapped, `0` = zero widen |
| `NearestEnemyEdge(snap, pt, opts)` | nearest enemy edge distance to `pt`, `math.huge` when there is nobody to measure; `opts` = `{ fog_ms? (default 550), age_cap? (default nil = uncapped; set it once Vision is wired) }` |
| `DiagGate(stamps, key, t, window)` | `true` when the keyed diagnostic should emit (and stamps it), `false` inside the window |
