# examples/

## `example_brain.lua`

A small worked example - not a finished brain, a skeleton that shows the
shape of a script built on the toolkit:

- requiring the libs,
- building a menu panel,
- wiring the event-driven libs (`order`, `damage`, `anim`) once at setup,
- chaining your own `OnUpdateEx` logic after theirs,
- a per-frame decision that uses `target`, `geometry`, `damage` and
  `prediction` together.

Read it top to bottom. The comments point at the spots where your real hero
logic and ability handles go.

## The wiring pattern

The one thing worth internalising: the event libs do not run themselves. You
keep a `callbacks` table, each lib's `Wire(callbacks)` chains its handlers
into it, and you **append** your own logic instead of overwriting:

```lua
local prev = callbacks.OnUpdateEx
callbacks.OnUpdateEx = function()
    if prev then prev() end   -- let the libs run first
    -- ...your logic...
end
```

Skip the `if prev then prev() end` and you have just disabled the libs'
handlers. This is the single most common wiring mistake.

## Quick snippets

**Pure data - no setup, just require and read:**

```lua
local AD = require("lib.ability_data")
local cd = AD.Cooldown("sven_storm_bolt", 1)
```

**Geometry - entities or Vectors, interchangeably:**

```lua
local geo = require("lib.geometry")
local shove_to = geo.extend(me, enemy, 600)   -- a Force-Staff point
```

**Throttled logging inside a hot loop:**

```lua
local log = require("lib.log")
log.throttled("waiting", 1.0, log.DEBUG, "still on cooldown")
```
