# map_data

Static map positions for the current Dota map: neutral camp spawners, towers,
watch towers (outposts), and fountains. Pure data, no engine calls. This is the
fallback / offline counterpart to the live `map` lib, useful when you want known
positions without querying the running game (tests, planning, or before entities
have spawned).

The numbers are generated, not hand-written: `tools/gen_map_data.lua` dumps them
from an in-client `dump_positions()` run, so the table is regenerated when the map
changes rather than edited in place. Coordinates are in Hammer units, centered
system (origin at map center). Teams use the engine convention: `2` = Radiant,
`3` = Dire.

The module returns one table, `MapData`, with these fields.

## TIER

A lookup from the neutral camp tier integer to a human label:

```lua
MapData.TIER = { [0]="small", [1]="medium", [2]="large", [3]="ancient" }
```

## CAMPS

A list of 28 neutral camp spawners. Each entry:

```lua
{ tier = <0..3>, center = {x, y, z}, box = {minx, miny, maxx, maxy} }
```

`tier` indexes into `MapData.TIER`. `center` is the spawner position (3 components,
Hammer units). `box` is the camp's axis-aligned spawn box as `{minx, miny, maxx, maxy}`
(2D extent, no z). Camps are not tagged by team or by side, just position and tier.

## TOWERS

Every tower and fort (the `*_fort` entries are the Ancients), one entry per
structure:

```lua
{ name = "dota_goodguys_tower1_mid", team = 2, pos = {x, y, z} }
```

`name` is the engine entity name (the `tower1/2/3/4` suffix is the tier, `_top` /
`_mid` / `_bot` the lane), `team` is `2` or `3`, `pos` is the structure position.

## OUTPOSTS

The two watch towers, same entry shape as towers:

```lua
{ name = "npc_dota_watch_tower_top", team = 3, pos = {x, y, z} }
```

`team` here is the watch tower's starting side, not ownership (outposts are
capturable in game).

## FOUNTAINS

The two fountains (`ent_dota_fountain_good` / `_bad`), same entry shape:

```lua
{ name = "ent_dota_fountain_good", team = 2, pos = {x, y, z} }
```

## Usage

```lua
local MapData = require("lib.map_data")

-- list the ancient camps with their labels:
for _, camp in ipairs(MapData.CAMPS) do
    if camp.tier == 3 then
        print(MapData.TIER[camp.tier], camp.center[1], camp.center[2])
    end
end

-- find the enemy (Dire) Ancient position:
for _, t in ipairs(MapData.TOWERS) do
    if t.name == "dota_badguys_fort" then
        local x, y, z = t.pos[1], t.pos[2], t.pos[3]
    end
end
```

## What's new in this sync

`MapData.SPAWNS` - the four side-lane creep spawn positions (captured from
live games), the anchor points for fogged-wave estimation and the lane-path
polylines in `lane`.
