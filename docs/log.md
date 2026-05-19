# log

`Log.Write` puts a line in the console and that is it - no levels, no rate
limiting. In a brain that runs every frame, one unguarded log line becomes
thousands of lines a second and buries everything useful.

This lib adds the three things you actually want.

## Levels

`log.DEBUG`, `log.INFO`, `log.WARN`, `log.ERROR`, and `log.SILENT`. Set a
threshold with `log.set_level(...)`; anything below it is skipped cheaply (the
message is never even built). Default threshold is `INFO`, so debug spam
stays hidden until you ask for it.

```lua
local log = require("lib.log")
log.set_level(log.DEBUG)   -- show everything while developing
log.info("brain loaded")
log.debug("tick", frame_count)
```

## Throttling

For log calls inside a hot loop:

- `log.throttled(key, interval, level, ...)` - emits at most once per
  `interval` seconds for that `key`.
- `log.once(key, level, ...)` - emits a single time, ever.
- `log.reset(key)` - forget the history for a key (or all keys if `nil`).

```lua
-- runs every frame, but only prints once a second
log.throttled("waiting", 1.0, log.DEBUG, "still waiting for cooldown")
```

## Tags

`log.tag(name)` returns a sub-logger that prefixes every line with `[name]`,
so you can tell which system spoke. Each tagged logger keeps its own throttle
history.

```lua
local clog = log.tag("combo")
clog.info("engaged", target_name)   -- prints: [INFO] [combo] engaged ...
```

If the framework `Log` global is missing (e.g. a plain Lua test run) it falls
back to `print`, so the same code works in the test harness.
