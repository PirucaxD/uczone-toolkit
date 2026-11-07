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

`CampCenter(camp)` returns the box midpoint Vector of one camp, or nil when the
camp has no box.

`Camps()` returns a descriptor for every neutral camp that has a box
(`Camp.GetCampBox` can return nil); `center` and `box` are never nil.

`CampsInRadius(pos, r)` returns descriptors for camps within `r` of `pos`,
skipping box-less camps the same way.

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

## Map.Nav (was nav.lua)

Movement *policy* over the world model above. Where the queries so far answer
"what is there", `Nav` answers "so where do I actually go, and how do I get
there". It is pure and hero-agnostic: it reads no engine state at all, the
caller injects the safety predicate and the capability flags. That is what
makes it testable offline and reusable by any hero.

The idea is that a layer of your brain (laning, jungling, retreating) funnels
every movement decision through one clamp and one transport choice, instead of
scattering `MoveTo` calls that each decide safety for themselves.

`SafeDest(dest, retreat, safe, opts)` clamps a destination to the nearest safe
point. `retreat` is a unit vector pointing toward safety (in lane, toward your
own fountain); `safe` is your own predicate, for example "outside enemy tower
range". It returns `(pt, clamped)`: the destination unchanged and `false` when
it was already safe, otherwise the first safe point found stepping back along
`retreat`. `opts` takes `{ step = 100, max_steps = 40 }`.

`Ladder(d, ctx)` returns the transport rungs worth trying for a leg of length
`d`, in try-order, as an array of `"keen"` / `"rearm"` / `"blink"` / `"walk"`.
The caller executes the first rung that actually fires and falls through on
refusal. `ctx` carries what you have available:
`{ keened, keen_ready, keen_min_gain, blink_ready, blink_min, blink_max }`.
The name "keen" is Tinker's teleport, but the rung is just "your long-range
mobility"; swap in whatever your hero owns.

`Stuck(track, d, t, opts)` is no-progress detection, state-in / state-out:
you keep a small `track` table, feed it the current distance to the destination
and the time, and get back `(track, stuck)`. It reports stuck when the distance
has not meaningfully improved inside a window, defaults `{ eps = 60,
window = 3.0 }`. Useful because "I issued a move order" and "I am getting
closer" are different facts.

`TreeHideSpot(trees, from, threat, opts)` picks a spot behind a tree cluster to
blink into, given the standing trees (from `TreesInRadius`), where you are, and
where the threat is. Returns `nil` when nothing qualifies. Defaults
`{ blink_max = 950, cluster_r = 250, min_trees = 4, threat_min = 800 }`.

Old `require("lib.nav")` callers just switch to `Map.Nav`.

## Map.Towers (was towers.lua)

A small registry that turns repeated tower samples into two answers: is this
tower still alive, and if it is being hit right now, how long until it dies.
Pure state-in / state-out, so the hero owns the state table and does the
engine reads.

`Track(state, samples, now)` folds one sampling pass into the registry.
`samples` is `{ { key, hp, alive }, ... }` where `key` is any stable tower
identifier you choose. It maintains an HP slope internally.

`Alive(state, key)` returns `true`, `false` (a death latch, so a tower that
died stays dead even when it stops being visible), or `nil` when that tower has
never been sampled. The three-way answer matters: "I have not looked" is not
the same as "it is gone".

`DeathEta(state, key, now, opts)` returns seconds until predicted death from
`now`: `0` when already dead, otherwise HP over the measured slope, adjusted
for how stale the last sample is. It reports a very large number when the tower
is not currently losing HP, so "is it melting" and "how long" are one call.

This is what lets a brain stop walking toward an objective that will resolve
without it, or commit to one that is about to fall.

Old `require("lib.towers")` callers just switch to `Map.Towers`.

## Map.Positions

Hand-curated data plus a small pure classifier: which of the five Dota
positions each hero can plausibly be played in, and what that implies about
your allies.

Note the deliberate scope. This is read by ally-position reasoning and by
nothing that moves your hero, and it is worth keeping it that way: acting on a
guessed position is a much bigger design question than reading one. Unlike
`map_data`, this table is hand-maintained rather than generated from KV, which
is why it lives here in code cadence.

`Of(name)` returns the set of positions a hero can play.
`PreferredOf(name)` narrows that to the common ones.

`ObservedLane(h, min_n, min_share)` resolves a per-ally lane tally
`{ top, mid, bot, n }` to an observed lane, or `nil`. It deliberately requires
both a minimum sample count and a dominant share, because a single sample is
worthless: lane assignment from position is a coarse band and a hero walking
through the river will register somewhere misleading.

`LaneSlots(lane, team)` gives the position set a lane can hold from that team's
point of view (Radiant safelane is bot, Dire safelane is top; the standard
layout is safelane `{1,5}`, offlane `{3,4}`, mid `{2}`).

`Shadow(names)` takes your allied hero names and returns, per hero, the set of
positions still possible after naked-single elimination: the constraint-solving
step where "only this hero can be the 5" collapses the rest. It returns
residual sets, not answers, so an ambiguous draft stays honestly ambiguous.
