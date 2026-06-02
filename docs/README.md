# docs/

One page per lib. Each page is the short version - what the lib is for, the
functions it gives you, and a snippet. The lib files themselves carry full
doc comments on every function, so your editor's hover/autocomplete is the
real reference; these pages are the "do I want this lib at all?" overview.

## The libs at a glance

**Building blocks** - small, general, safe to use anywhere:

| Lib | What it does |
|-----|--------------|
| [geometry](geometry.md) | 2D distance, direction, angles, cones, segment math |
| [prediction](prediction.md) | where to aim so a projectile meets a moving target |
| [log](log.md) | leveled + throttled logging, so a per-frame log call can't spam |
| [menu](menu.md) | a builder over `Menu.Create` - create widgets by name, read them by name |
| [npc](npc.md) | tiny: shard/scepter checks, item lookup |
| [dedup](dedup.md) | "did I already react to this event?" helpers |
| [signal](signal.md) | a message bus so several of your hero brains can talk |

**Event plumbing** - wire these into your script's callbacks:

| Lib | What it does |
|-----|--------------|
| [order](order.md) | one chokepoint for every order you issue, with validation + dedup |
| [damage](damage.md) | recent-damage feed, plus frame-correct kill math |
| [anim](anim.md) | turn enemy animations/particles into "they just cast X" events |
| [native](native.md) | pause/resume + reassert the framework's Hit & Run / Orb Walker so a multi-step combo's cast points aren't cancelled by the order flood |

**Combat reasoning:**

| Lib | What it does |
|-----|--------------|
| [target](target.md) | composable predicates - is this a real enemy hero, is it killable... |
| [timing](timing.md) | will the target be invuln / dispel out of my combo? |
| [save_select](save_select.md) | given a threat, rank which of my save items actually counter it |
| [defense](defense.md) | a save-dispatcher with a per-(target, mod, caster) lock so two of your fire paths can't double-save against one threat |

**Static game data** - generated from Valve's KV files (see `tools/`):

| Lib | What it does |
|-----|--------------|
| [threat_data](threat_data.md) | which enemy abilities are dangerous and what saves beat them |
| [item_data](item_data.md) | every item: cost, behavior, recipe, values |
| [ability_data](ability_data.md) | every ability: damage, cooldown, cast range, values |
| [unit_data](unit_data.md) | every non-hero unit: creeps, summons, wards, Roshan |
| [hero_data](hero_data.md) | every hero: base stats, abilities, talents, facets |

## Using a lib

Drop the toolkit's `lib/` folder where your scripts can reach it and
`require` what you need:

```lua
local geometry = require("lib.geometry")
local Order    = require("lib.order")
```

The data libs (`item_data` and friends) and `threat_data` are pure data - no
setup, just `require` and read. The event libs (`order`, `damage`, `anim`)
have a `Wire(callbacks)` call you make once during setup; their pages explain
it.
