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
`geometry` (2D math, cones, segment collision), `prediction` (aim a
projectile at a moving target), `log` (leveled + throttled logging),
`menu` (a builder over `Menu.Create`), `npc`, `dedup`, `signal`.

**Event plumbing** - wire once, then forget:
`order` (one validated chokepoint for every order you issue), `damage`
(recent-damage feed + correct kill math), `anim` (enemy animations ->
"they just cast X" events), `native` (pause/resume + reassert the
framework's Hit & Run / Orb Walker so your combo's cast points
aren't cancelled by the order flood).

**Combat reasoning:**
`target` (composable unit predicates), `timing` (will they dodge my combo),
`save_select` (which of my escape items actually counters this threat),
`defense` (a full save-dispatcher with a per-(target, mod, caster)
lock domain so two of your fire paths can't double-save against one
threat).

**Static game data**, generated from Valve's KV files:
`item_data`, `ability_data`, `unit_data`, `hero_data`, `threat_data`.

## Getting started

Put the `lib/` folder somewhere your scripts can reach, then `require` what
you want:

```lua
local geometry = require("lib.geometry")
local Order    = require("lib.order")

local dist = geometry.dist2d(me, enemy)
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
