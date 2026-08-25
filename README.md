# uczone-toolkit

A set of Lua libraries for writing UCZone hero scripts. It's the plumbing
you'd otherwise rewrite (badly) every time you start something new.

If you've poked at scripting for this API, you've probably noticed most
scripts reinvent the same handful of things from scratch: issuing orders,
tracking damage, reading enemy animations, doing kill math, building a menu.
It's the kind of code that's fiddly to get right and boring to write twice.
This is that code, written once, with the sharp edges already found.

It's aimed at people who are still learning. Every function is documented,
nil-safe where it can be, and the comments explain *why* a thing is done a
certain way, not just what it does. If you're new to this, reading the libs
is half the point.

## What's inside

Full overview lives in [docs/](docs/), one page per lib. The short version:

**Building blocks** - small, general, drop in anywhere:
`geometry` (2D math, movement prediction, AoE / line placement),
`farm` (pick the line / point that clears the most creeps),
`prediction` (aim a projectile at a moving target), `log` (leveled +
throttled logging), `menu` (a builder over `Menu.Create`), `npc`,
`dedup`, `signal`.

**Event plumbing** - wire once, then forget:
`order` (one validated chokepoint for every order you issue), `damage`
(recent-damage feed + correct kill math), `anim` (enemy animations ->
"they just cast X" events), `native` (pause/resume + reassert the
framework's Hit & Run / Orb Walker so your combo's cast points
aren't cancelled by the order flood).

**Combat reasoning:**
`target` (composable unit predicates), `timing` (will they dodge my combo),
`escape` (danger-aware "where should I go" picker for displacement
items; ranks 7 angles off straight-away by enemy density so the
brain stops shoving you into the worst possible spot, and now carries
`Escape.Vision`, a shared enemy last-seen tracker: "how stale is my
read on that fogged hero?"),
`defense` (the save dispatcher: a threat comes in, it resolves a
ranked chain of your save items and fires the first one that counters
it, with a per-(target, mod, caster) lock domain so two of your fire
paths can't double-save against one threat), `item_saves`
(hero-agnostic defensive item save bodies: BKB, Lotus, Force, Pike,
cyclones, blink, and more), `channel_gate` (a pure kit-aware
predicate: is an enemy in reach whose kit can break the channel I'm
about to start), `hero_value` (per-hero combat value: a KV role base
times a live, peer-relative fed-ness multiplier).

**Farming and lanes** - read the map and plan where to farm:
`map` (live camp / tower / tree / pathing reads plus nearest-anchor
helpers, and three sub-modules: `Map.Nav` for movement composition -
a predicate-clamped safe destination, a keen/blink/walk transport
ladder, stuck detection, tree-hide spots; `Map.Towers`, a per-tower
registry with alive flags, a permanent dead latch, and a measured
HP-slope death prediction; `Map.Positions`, hand-curated per-hero
position data with a shadow classifier), `map_data` (static map
positions: camps, towers, outposts, fountains, lane creep spawns),
`lane` (lane intel: creep waves, lane-path polylines with an
arc-length mirror for fogged waves, clash / equilibrium prediction,
a creep-fight simulator with a push forecast, intercept ETA, and wave
estimates from the spawn schedule; plus `Lane.Route`, a
receding-horizon planner that maximizes risk-adjusted gold within a
time horizon with return-leg-aware camp selection, and
`Lane.Schedule`, a timing-anchored shove-cycle controller:
clock-independent plan, wave-cadence prediction, stack windows,
ability-sequence fitting), `march_sim` (a pure, deterministic
attrition simulator for AoE-stream vs creep-wave interactions, for
calibrating cast geometry and leads offline, no game needed). The
`shove` module's cast geometry moved into `farm` (`Farm.CrashCast`).

**Static game data**, generated from Valve's KV files:
`item_data`, `ability_data`, `unit_data`, `hero_data`, `threat_data`.

## Getting started

Put the `lib/` folder somewhere your scripts can reach, then `require` what
you want:

```lua
local geometry = require("lib.geometry")
local Order    = require("lib.order")

local dist = geometry.dist_between(me, enemy)
```

The data libs are pure - just require and read. The event libs need a
one-line `Wire(callbacks)` at setup. See [examples/](examples/) for the
wiring pattern; it's the one thing worth getting right early.

## Keeping the data libs fresh

`item_data`, `ability_data`, `unit_data` and `hero_data` are *generated* from
the KV data Valve ships inside your Dota/UCZone install. After a balance
patch that data changes. One command catches the libs back up:

```bash
python tools/update.py            # regenerate whatever the patch changed
python tools/update.py --check    # just tell me if anything is stale
```

It figures out where your KV data lives, or tells you how to point it there.
Details in [tools/README.md](tools/README.md).

## Running the tests

Pure-Lua unit tests, no game needed:

```bash
lua tools/run_tests.lua
```

## Repo layout

```
lib/        the libraries - this is the thing you use
docs/       one explainer page per lib
examples/   a worked example script + snippets
tools/      the data-lib generators, the updater, the test runner
```

## Contributing

Found a bug, or a wrong number in the data? Open an issue or a PR. If you
build something useful on top of this, a link back is appreciated but not
required.

## License

MIT - see [LICENSE](LICENSE). Do what you like with it.
