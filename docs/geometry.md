# geometry

2D position, distance and direction math. Dota is played on a flat plane, so
everything here is 2D - the z (height) component is carried along but ignored
for distances and angles. Distances are in Hammer units, angles in degrees.

Every function takes **an entity or a Vector**, interchangeably - internally
`pos()` resolves either to a position. Bad input gets a sensible default
(`math.huge` for a distance, `nil` for a point) instead of an error, so you
can write `geometry.lead(...) or fallback` without a guard.

## Functions

| Function | Returns |
|----------|---------|
| `pos(e)` | the position Vector of an entity, or the Vector itself |
| `dist2d(a, b)` | 2D distance (`math.huge` if either is invalid) |
| `dist2d_sqr(a, b)` | squared distance - skip the sqrt for compares |
| `within(a, b, range)` | bool: is `b` within `range` of `a` (cheap) |
| `direction(from, to)` | normalized direction Vector, `nil` if coincident |
| `midpoint(a, b)` | the point halfway between |
| `extend(from, to, dist)` | a point `dist` units past `to` along the line |
| `clamp_distance(origin, point, max)` | `point` pulled within `max` of `origin` |
| `rotate(vec, degrees)` | a 2D vector rotated counter-clockwise |
| `angle_between(a, vertex, b)` | the angle at `vertex` (0-180 degrees) |
| `point_in_cone(apex, dir, point, half_angle, range)` | bool |
| `closest_point_on_segment(a, b, p)` | nearest point on segment `a->b` |
| `dist_to_segment(a, b, p)` | shortest distance from `p` to the segment |
| `segment_hits_circle(a, b, center, radius)` | bool: does the line clip a unit |

`dist_between` and `dist_from_to` are aliases of `dist2d`.

## Examples

```lua
local geo = require("lib.geometry")

-- am I in melee range of the enemy?
if geo.within(me, enemy, 200) then ... end

-- a Force-Staff point that shoves a target away from me
local shove_to = geo.extend(me, enemy, 600)

-- will my line-projectile clip this enemy on the way to its target?
local hits = geo.segment_hits_circle(me, aim_point, enemy, 100)

-- is the enemy inside my frontal cone ability?
local facing = geo.direction(me, cursor)
if geo.point_in_cone(me, facing, enemy, 22.5, 900) then ... end
```

For "where will the target be when my spell lands", see
[prediction](prediction.md).
