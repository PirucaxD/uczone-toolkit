# shove

Stateless crash-push cast geometry. Given the enemy wave's centroid and the
direction the creep line runs, it tells you where to stand back and where to aim
a wave-clear cast so the cast width crosses the creep line PERPENDICULARLY,
sweeping the whole wave and overrunning the lane toward the enemy tower (a
"crash" push).

Hero-agnostic and pure. There are no engine calls and no clock: the hero passes
plain `{x, y}` tables in and gets plain `{x, y}` tables back, so the module stays
fully testable with zero runtime-API risk. Distances are in Hammer units. It
pairs with the `lane` reads, which supply the clash centroid and the creep-line
direction this geometry consumes; `shove` only does the arithmetic of placing the
stand point and the aim point.

## The perpendicular-crash idea

A wave-clear cast laid ALONG the creep line clips a creep or two and stops. Laid
ACROSS it (perpendicular), the same width spans the full column of creeps and
keeps going into the lane behind them, which is what crashes the wave into the
tower. `CrashCast` returns the base stand and aim along the push axis, plus the
unit perpendicular vector so the hero can offset multiple casts along the creep
line for maximum coverage.

## CrashCast

```lua
Shove.CrashCast(clash_centroid, creep_line_dir, opts)
```

Inputs:

- `clash_centroid` (`{x, y}`): the enemy wave centroid, where the push is aimed.
- `creep_line_dir` (`{x, y}`): the direction the creep line runs. Need not be
  normalized.
- `opts` (table, optional): `{ standback?, cast_ahead?, fountain? }`.
  - `standback` (default `900`): how far back, toward the fountain, the stand
    point sits from the centroid. Only applied when `fountain` is given.
  - `cast_ahead` (default `280`): how far ahead of the stand point, toward the
    centroid, the base aim point sits.
  - `fountain` (`{x, y}`, optional): the friendly fountain. With it, the stand
    point is offset from the centroid toward the fountain (capped so it never
    overshoots the fountain). Without it, the stand point is the centroid itself.

Returns one table:

```lua
{ stand = {x, y}, cast_point = {x, y}, perp = {x, y} }
```

- `stand`: where to stand. The centroid offset back toward the fountain by
  `standback`, or the centroid itself when no fountain is supplied.
- `cast_point`: the base aim. A point `cast_ahead` from `stand` toward the
  centroid. This is the center aim before the hero applies any perpendicular
  offset.
- `perp`: the unit vector perpendicular to the creep line. Offset successive
  casts by `+/- perp` to fan the sweep across the wave.

Degenerate inputs are handled: a zero-length `creep_line_dir` yields
`perp = {0, 0}`, and when `stand` coincides with the centroid the `cast_point`
falls back to the centroid.

## Usage

```lua
local Shove = require("lib.shove")

-- centroid + creep-line direction come from the `lane` reads:
local geo = Shove.CrashCast(clash_centroid, creep_line_dir, {
    standback  = 900,
    cast_ahead = 280,
    fountain   = my_fountain_pos,
})

move_to(geo.stand)
-- fan three casts across the wave, perpendicular to the creep line:
issue_cast_position(wave_clear, geo.cast_point)
issue_cast_position(wave_clear, { x = geo.cast_point.x + geo.perp.x * 250,
                                  y = geo.cast_point.y + geo.perp.y * 250 })
issue_cast_position(wave_clear, { x = geo.cast_point.x - geo.perp.x * 250,
                                  y = geo.cast_point.y - geo.perp.y * 250 })
```

| Function | Returns |
|----------|---------|
| `CrashCast(clash_centroid, creep_line_dir [, opts])` | `{ stand{x,y}, cast_point{x,y}, perp{x,y} }`. `opts` = `{ standback? (default 900), cast_ahead? (default 280), fountain? }` |
