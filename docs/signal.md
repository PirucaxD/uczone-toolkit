# signal

A small message bus for **cross-hero coordination**. If you run brains on
several heroes at once, they share one Lua state - `signal` lets them publish
intent to each other and look up each other's APIs.

The registry lives on the module table itself. Lua's `require` cache means
every script that `require("lib.signal")` sees the same registry. (The
UCZone sandbox does not expose `_G`, so this module-singleton trick is the
workaround for shared state.)

## Two things it does

**API registry** - a brain publishes its public surface, others look it up:

```lua
local Signal = require("lib.signal")
Signal.Register("Lina", { request_save = function(ally) ... end })

-- from another hero's brain:
local lina = Signal.Get("Lina")
if lina then lina.request_save(me) end
```

**Channels** - publish/subscribe for sparse, intent-level messages:

```lua
-- support brain subscribes:
Signal.Subscribe("save_request", function(payload)
    -- payload.ally needs saving
end)

-- carry brain broadcasts:
Signal.Broadcast("save_request", { ally = me })
```

## API

| Function | Purpose |
|----------|---------|
| `Register(name, api)` | publish a hero's API table |
| `Get(name)` | look up another hero's API |
| `Subscribe(channel, fn)` | listen on a channel, returns a token |
| `Unsubscribe(channel, token)` | stop listening |
| `Broadcast(channel, payload)` | send to all subscribers |
| `Last(channel)` | the last payload sent on a channel, without subscribing |
| `Clear(channel)` | drop a channel's cached payload (or all if `nil`) |

Subscriber errors are caught and logged, so one bad brain cannot break the
chain. Use signals for sparse coordination - not as a replacement for
per-frame polling.
