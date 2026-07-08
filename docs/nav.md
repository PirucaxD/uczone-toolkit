# nav

Movement composition for a farming or roaming hero: one structural clamp for
every destination, one transport ladder for every leg, one stuck signal for
every watchdog. Pure - the engine reads (walkability, tower positions, tree
lists) are injected as predicates and data, so everything here runs in the
offline suite.

## Why a chokepoint

Hand-rolled movement code accumulates near-duplicates: three standback
computations, three stuck trackers, per-caller tower checks. Each copy drifts
and each drift is a bug (a stand that slides under a tower, a watchdog that
fires during a deliberate wait). `nav` collapses those into single producers
the hero glues together.

## API

### Nav.SafeDest(dest, retreat_dir, safe_fn) -> pos, clamped

Clamp a destination through an injected safety predicate. If `safe_fn(dest)`
holds, `dest` comes back unchanged. Otherwise the point walks back along
`retreat_dir` (a unit vector, usually toward your fountain) in steps until the
predicate accepts, returning the first safe point and `clamped = true`. The
predicate carries your rules (tower range, walkability, whatever) - `nav` owns
only the geometry.

### Nav.Ladder(gap, opts) -> rungs

Rank the transport options for a leg of `gap` units. Returns an ordered list of
rung names from `{ "keen", "blink", "walk", ... }` given `opts`:

- `keened` - this leg already spent its teleport (do not ladder back onto it)
- `keen_ready` - the teleport is castable now
- `keen_min_gain` - minimum gap for a teleport to be worth the channel

The hero walks the rungs in order and takes the first one that fires. Small
gaps rank `walk` first; big gaps rank the teleport; the blink rung slots when
the item is up (the caller applies its own safety gates before casting).

### Nav.Stuck(track, dist, now, opts) -> track, stuck

No-progress detection on distance-to-target, not position: orbiting a target
without approaching counts as stuck, standing still at the target does not.
Feed it the current distance each tick; it returns the updated track plus
`stuck = true` once distance has not improved by `opts.eps` for `opts.window`
seconds. Reset the track (pass nil) when the target changes or a deliberate
wait starts.

### Nav.TreeHideSpot(pos, trees, opts) -> spot

Pick a tree-cluster hiding spot near `pos` from an injected tree list - the
landing point for a defensive blink. Returns nil when no cluster qualifies, so
the caller can fall back to an open safest-spot search.
