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
