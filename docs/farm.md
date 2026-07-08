# farm

Stateless farming geometry plus a cast-worthiness predicate. Pick the best line
or point aim to hit the most creeps for wave-clear, then check whether the cast
clears your threshold before committing the cooldown.

Hero-agnostic and pure. Every function takes a world origin and a caller-supplied
list of units; nothing here calls the engine. The hero script owns the actual
creep / neutral enumeration (which engine calls vary by framework version) and
passes a plain list in, so this module stays fully testable with zero runtime-API
risk. Distances are in Hammer units; only the x / y of each position is used.

## Unit list contract

Each entry is a table. Only `pos` (a Vector with `.x` / `.y`) is required:

```lua
{ pos = <Vector>, hp = <number?>, is_neutral = <boolean?>, entity = <any?> }
```

`hp` is used only as a tie-break weight (a line / circle that catches more total
HP wins between two placements that hit the same count). Missing `hp` counts as 0.

## Aiming

`BestLineAim` finds the line-nuke aim (Lina Dragon Slave, Jakiro Macropyre, and
similar) that hits the most units. Candidate directions point toward each unit,
since a line's optimum always lies along some unit's bearing. It returns
`(aim_pos, hit_count, hits, bonus_hit_count)`, where `aim_pos` is
`origin + best_dir * length`, a point you feed straight to `issue_cast_position`.
Ties break by greater summed HP, then by the nearer cluster (a denser, closer pack
beats a marginal far one).

`BestPointAim` does the same for a circular AoE of `radius`, sampling a candidate
center at each unit position. It returns `(center, hit_count, hits)`.

`CountInLine` is the building block: given a normalized `aim_dir`, it counts how
many units a line of `length` and `half_width` would cover, returning
`(count, hits)`. The caller normalizes `aim_dir`.

```lua
local Farm = require("lib.farm")

-- best Dragon-Slave line (length 1075, half-width 110) from the hero:
local aim, hits = Farm.BestLineAim(hero_pos, creeps, 1075, 110)
if Farm.WorthCasting(hits, 3) then        -- only cast if it clears 3+ creeps
    issue_cast_position(dragon_slave, aim)
end

-- best 250-radius circle, plus a direct line count along a fixed bearing:
local center, n          = Farm.BestPointAim(creeps, 250)
local through, line_hits = Farm.CountInLine(hero_pos, aim_dir, 1075, 110, creeps)
```

### Hitting a hero behind the wave

`BestLineAim` takes an optional `opts` table for aiming a wave-clear nuke THROUGH
the creeps at a hero standing behind them. With `opts` omitted the behavior is the
plain densest-line search above.

```lua
local aim, prim, hits, bonus = Farm.BestLineAim(hero_pos, creeps, 1075, 110, {
    bonus_units  = { { pos = enemy_hero_pos, hp = enemy_hp } },
    bonus_weight = 3,   -- a hero outbids up to 3 creeps when choosing a line
    min_hits     = 2,   -- a line must still clear 2 creeps to qualify
})
```

`bonus_units` is a second list (same contract). Units it contains add
`bonus_weight` each to a candidate line's score, and their bearings join the
candidate set, so a line can be aimed through the wave to clip the hero too. The
returned `hit_count` still counts PRIMARY units only, so your cast threshold keeps
its meaning; `bonus_hit_count` reports the bonus units caught. A candidate must hit
at least one primary unit (a hero-only bearing is not a wave-clear line).

`min_hits` is the primary-hit qualification threshold. Lines meeting it form a
qualified pool that always beats any unqualified line regardless of score, so a
bonus-heavy line can never drag the pick below your cast gate while a qualifying
line exists. When no line qualifies, the raw best is returned and your gate rejects
it as usual.

## Cast-worthiness

`WorthCasting(hit_count, min_count)` is the policy gate: `true` when
`hit_count >= min_count` (`min_count` defaults to 1). Pair it with a `BestLineAim`
or `BestPointAim` hit count to decide whether a wave-clear is worth the cooldown.

| Function | Returns |
|----------|---------|
| `BestLineAim(origin, units, length, half_width [, opts])` | `(aim_pos, hit_count, hits, bonus_hit_count)`; `(nil, 0, {}, 0)` if nothing is hittable. `opts` = `{ bonus_units?, bonus_weight? (default 3), min_hits? }` |
| `BestPointAim(units, radius [, opts])` | `(center, hit_count, hits)`; `(nil, 0, {})` on empty input. `opts` reserved |
| `CountInLine(origin, aim_dir, length, half_width, units)` | `(count, hits)`; `(0, {})` on missing arguments. `aim_dir` is a normalized Vector |
| `WorthCasting(hit_count, min_count)` | `boolean`, `hit_count >= min_count` (`min_count` defaults to 1) |

## Jungle / target valuation

A separate suite for picking and clearing neutral camps. Same purity contract:
the hero precomputes per-creep HP (e.g. `Entity.GetHealth`), gold (e.g.
`NPC.GetGoldBountyMax`), and ally values (e.g. via `lib/hero_value`), then passes
plain tables and numbers in. Nothing here calls the engine.

### Creep list contract

A camp is a list of creep tables. Both fields are optional and missing values
count as 0:

```lua
{ { hp = <number?>, gold = <number?> }, ... }
```

`GoldValue(creeps)` sums the precomputed `gold` over the list and returns the
total gold the camp is worth. `EffectiveHP(creeps)` sums `hp` over the list, the
denominator for clear-feasibility. Both return 0 for a nil or empty list.

`CanClear(creeps, damage_budget)` is the feasibility predicate: `true` when the
camp's total HP fits inside `damage_budget`. The hero supplies the budget (for
example a per-cast damage from `lib/ability_data` times the planned number of
casts for this camp type). A nil budget counts as 0.

`ScoreTarget(opts)` returns a single value score for one farm candidate, higher is
better. It is `gold / time - risk * risk_weight`, where `opts` carries:

| field | meaning | default |
|-------|---------|---------|
| `gold` | candidate gold, e.g. from `GoldValue` | 0 |
| `time` | estimated seconds to acquire (travel + clear) | 0 |
| `risk` | safety-layer risk in 0..1 | 0 |
| `risk_weight` | gold/sec penalty per unit of risk | `Farm.DEFAULT_RISK_WEIGHT` (4.0) |

`time` is floored at 0.5s internally to avoid a divide-by-zero on a zero-travel
candidate.

`IsContestedByAlly(pos, allies, opts)` keeps the farm bot from stealing a spot an
allied core already owns. It returns `true` when any ally with value at least
`opts.min_value` (default 0) sits within `opts.radius` (default
`Farm.DEFAULT_CONTEST_RADIUS`, 700) of `pos`. The hero passes allies with
precomputed value, `{ { pos = {x, y}, value = number }, ... }`; this lib never
calls a hero-value module, staying pure.

`StructuralRisk(pos, opts)` returns a position-based farm risk in `[0, 1]`,
independent of live enemy vision. It is a gradient that rises toward the enemy
fountain (camps deeper on the enemy half are more exposed) plus explicit per-zone
bumps for known-contested spots the gradient alone cannot separate (for instance a
mid-river camp at the same axis distance as a safe own-jungle camp). `opts`:

| field | meaning |
|-------|---------|
| `our_fountain` | `{x, y}`, the 0 end of the gradient |
| `enemy_fountain` | `{x, y}`, the 1 end of the gradient |
| `half_weight` | gradient contribution at the enemy fountain (default 0.5) |
| `zones` | `{ {x, y, radius, bump}, ... }`, each adds `bump` when `pos` is inside `radius` |

With both fountains given, the gradient term is `half_weight * t` where `t` is the
projection of `pos` onto the our->enemy fountain axis, clamped to `[0, 1]`. Zone
bumps add on top, and the result is clamped to `[0, 1]`. Because it ignores live
vision, it ranks an own-side safelane camp safer than a contested mid camp even
when no enemy is on the minimap.

```lua
local Farm = require("lib.farm")

-- value one camp the hero can clear:
if Farm.CanClear(camp, march_damage_budget)
   and not Farm.IsContestedByAlly(camp_pos, allies) then
    local score = Farm.ScoreTarget({
        gold = Farm.GoldValue(camp),
        time = travel_secs + clear_secs,
        risk = Farm.StructuralRisk(camp_pos, {
            our_fountain   = our_fnt,
            enemy_fountain = enemy_fnt,
            zones          = contested_zones,
        }),
    })
end
```

| Function | Returns |
|----------|---------|
| `GoldValue(creeps)` | `number`, summed `gold` (0 for nil/empty) |
| `EffectiveHP(creeps)` | `number`, summed `hp` (0 for nil/empty) |
| `CanClear(creeps, damage_budget)` | `boolean`, `EffectiveHP(creeps) <= (damage_budget or 0)` |
| `ScoreTarget(opts)` | `number`, `gold / time - risk * risk_weight`; `opts` = `{ gold?, time?, risk?, risk_weight? }`; `time` floored at 0.5 |
| `IsContestedByAlly(pos, allies, opts)` | `boolean`; `opts` = `{ radius? (default 700), min_value? (default 0) }` |
| `StructuralRisk(pos, opts)` | `number` in `[0, 1]`; `opts` = `{ our_fountain?, enemy_fountain?, half_weight? (default 0.5), zones? }` |

## Camp pairing

Two helpers for clearing an adjacent camp PAIR with one wide cast (for example a
single Tinker March covering both). Pure scalar math, only the returned points are
Vectors, so both are offline-testable.

`PairClearClass(d, opts)` classifies, by the inter-camp distance `d` alone, how
well one centred cast (fired at roughly the midpoint) clears BOTH camps. Each camp
is modelled as a creep disc of radius `opts.disc` (default 200) centred `d/2` from
the cast, and `half` is `opts.march_len / 2` (default `march_len` 1800):

- `clean`: `d/2 + disc <= half`, the whole far disc is inside the rectangle, one
  cast clears both.
- `clip`: `d/2 - disc <= half`, the centre spills out but the near creeps still
  clip the rectangle, finish with extra casts plus the camp pulling in.
- `none`: even the nearest creep is outside, not a viable pair (farm it single).

It returns `{ class = "clean"|"clip"|"none", full_margin = number, clip_margin = number }`,
where `full_margin` is the outer-creep spare and `clip_margin` the nearest-creep
spare (each `>= 0` means that creep is inside), for a calibration readout.

`PairStandCandidates(A, B, opts)` returns an ordered list of stand spots for
clearing the two camps centred at Vectors `A` and `B` with one cast. The cast lands
at (near) the A-B midpoint so both camps stay within `+/- march_len/2`
longitudinally; standing off the A-B axis by a perpendicular lateral offset finds
walkable ground when the on-axis stand lands on terrain (the river pairs), at the
cost of tilting the coverage rectangle. Candidates are emitted for each back
distance x lateral offset (least-tilt first within each back), keeping only those
that (1) stay within cast range of the cast point and (2) still cover both camps
after the tilt. `opts`:

| field | meaning | default |
|-------|---------|---------|
| `cast_range` | cast range of the ability | 300 |
| `range_pad` | margin subtracted from `cast_range` | 20 |
| `halfwidth` | half-width of the coverage rectangle | 450 |
| `march_len` | length of the coverage rectangle | 1800 |
| `stand_ring` | default first back distance | 250 |
| `pair_offset` | shift the cast point along the A->B axis | 0 |
| `backs` | back distances to try (along the axis toward the stand) | `{ stand_ring, 180, 130 }` |
| `lats` | lateral offsets to try | `{ 0, 110, -110, 220, -220 }` |

Each entry is `{ stand = Vector, aim = Vector, back = number, lat = number, tilt = number }`,
where `stand` is where the hero stands, `aim` is the cast point, and `tilt` is the
far camp's offset from the tilted centreline (candidates whose tilt exceeds
`halfwidth` are dropped). It returns `{}` when the pair is too far apart to cover
longitudinally (`d/2 + |pair_offset| > march_len/2`) or the inputs are degenerate.
The hero applies walkability and enemy risk to the ordered list and takes the first
spot that passes.

| Function | Returns |
|----------|---------|
| `PairClearClass(d, opts)` | `{ class = "clean"|"clip"|"none", full_margin, clip_margin }`; `opts` = `{ march_len? (default 1800), disc? (default 200) }` |
| `PairStandCandidates(A, B, opts)` | ordered `{ {stand, aim, back, lat, tilt}, ... }`; `{}` when uncoverable/degenerate; `opts` keys above |

## What's new in this sync (from the Tinker farm line)

The `shove` module's crash-push cast geometry moved in here, alongside the
whole decision-support surface the farm brain grew:

- `Farm.CrashCast(wave, opts)` - the crash-push stand + aim (replaces `shove`).
- `Farm.MarchCovers` / `Farm.OutsideTowerRange` - farmability predicates.
- `Farm.GreedyPairs` - mutual-nearest camp pairing (stable, no flicker).
- `Farm.ClearBudget` - stack-aware cast budget from live effective HP.
- `Farm.CampCombatants` / `Farm.ClearTimeDPS` - per-camp fight math from
  neutral stat tables (Liquipedia-verified).
- `Farm.StackWindow` - the timed stack pull window for a camp.
- `Farm.DepthPoints` - graded depth-risk points past the enemy T1 line
  (Keen-ready shaves points); pairs with `Farm.PathRisk` (corridor risk
  sampling hero->stand).
- `Farm.WaveAimCenter`, `Farm.DeepFarmFactor`, `Farm.DepthLineRisk` - wave
  aim and depth economics helpers.
