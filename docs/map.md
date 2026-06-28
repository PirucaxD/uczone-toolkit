# map

Live map and location layer over the UCZone API v2.0. This is the engine-reading
counterpart to `map_data` (which only knows static spawn positions): `map` asks
the running game what is actually there right now, neutral camps and their live
creeps, towers, standing trees, ground height, and pathing.

The public queries are thin wrappers over the engine (`Camps` / `Camp` / `Towers`
/ `Trees` / `GridNav` / `World` / `NPCs` / `Entity`), so calling them only makes
sense in-game. The pure helpers (`_center_of_box`, `_in_box_xy`, `_filter_in_box`,
`_nearest`) do no engine work and are exported for offline tests. Nothing in the
module touches the engine at load time. Hero-agnostic throughout. Distances are in
Hammer units, and box / nearest math uses only the x / y of each position.

## Camps

A camp descriptor is the table `{ camp, center, type, box }`, where `center` is the
box midpoint and `box` is the engine AABB `{ min, max }`.

`CampCenter(camp)` returns the box midpoint Vector of one camp.

`Camps()` returns a descriptor for every neutral camp on the map.

`CampsInRadius(pos, r)` returns descriptors for camps within `r` of `pos`.

`AllNeutrals()` returns every live, non-dormant, non-spawning neutral creep on the
map as a flat list. Enumerate this once, then box-filter per camp, rather than
re-scanning the whole map for each camp you value in a pass.

`CampCreeps(camp, neutrals)` returns the live neutrals standing inside that camp's
box, padded by 150 units so idle creeps milling just outside the spawn box still
count (this stabilizes occupancy). Pass the list from `AllNeutrals()` as `neutrals`;
omit it and it falls back to a fresh full-map scan. The hero reads `.hp` / `.gold`
off the returned creeps.

`CampOccupied(camp)` returns `true` when the camp currently has any live creeps.

## Nearest anchor

`NearestAnchor(target, anchors)` returns `(anchor, distance)`: the entity in a
caller-supplied list closest to `target` by xy distance. The list is whatever the
hero enumerates (friendly buildings, creeps, and so on); the default reader uses
`Entity.GetAbsOrigin`. Returns `nil` when nothing is supplied.

## Towers and trees

`TowersInRadius(pos, r, teamNum, teamType)` returns towers within `r` of `pos`.
`teamType` defaults to enemy inside the API, so omitting it gives enemy towers, the
split-push targets.

`TreesInRadius(pos, r)` returns the standing (active) trees within `r`, the
tree-blink candidates.

`NearestTree(pos, r)` returns `(tree, tree_pos)` for the closest standing tree
within `r` (default 1200).

## Ground and pathing

`GroundPos(x, y)` returns a Vector at `(x, y)` with the correct world Z.

`Path(start, dest)` returns the real GridNav pathfinding waypoints from `start` to
`dest` (empty list if none).

`PathExists(start, dest)` returns `true` when a walkable path connects the two.

`Walkable(pos)` returns `true` when a single position is traversable.

## Usage

```lua
local Map = require("lib.map")

-- value occupied camps in one pass: enumerate neutrals once, filter per camp.
local neutrals = Map.AllNeutrals()
for _, c in ipairs(Map.CampsInRadius(hero_pos, 2500)) do
    local creeps = Map.CampCreeps(c.camp, neutrals)
    if #creeps > 0 and Map.PathExists(hero_pos, c.center) then
        -- c.center is a clean stand point; creeps carry .hp / .gold
    end
end

-- split-push: enemy towers nearby, plus a tree to blink over the wall.
local towers     = Map.TowersInRadius(hero_pos, 1200)
local tree, tpos = Map.NearestTree(hero_pos, 1200)
```
