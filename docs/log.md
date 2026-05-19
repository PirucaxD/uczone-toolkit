# log

The framework already ships a `Logger` class that does leveled logging:
`debug` / `info` / `warning` / `error` methods, per-logger names, and a
`[LEVEL] [name]` prefix on every line. No reason to rebuild that, so this lib
sits straight on top of it.

What it adds is the one thing `Logger` is missing: **rate limiting**. In a
brain that runs every frame, one unguarded log line becomes thousands of
lines a second and buries everything useful. `throttled()` and `once()` fix
that. That is the actual reason this lib exists.

## Levels

`log.DEBUG`, `log.INFO`, `log.WARN`, `log.ERROR`, and `log.SILENT`. Set a
threshold with `log.set_level(...)`; anything below it is skipped before the
message is ever built. Default is `INFO`, so debug spam stays hidden until
you ask for it.

```lua
local log = require("lib.log")
log.set_level(log.DEBUG)   -- show everything while developing
log.info("brain loaded")
log.debug("tick", frame_count)
```

## Throttling

For log calls inside a hot loop:

- `log.throttled(key, interval, level, ...)` emits at most once per
  `interval` seconds for that `key`.
- `log.once(key, level, ...)` emits a single time, ever.
- `log.reset(key)` forgets the history for a key (or all keys if `nil`).

```lua
-- runs every frame, but only prints once a second
log.throttled("waiting", 1.0, log.DEBUG, "still waiting for cooldown")
```

## Tags

`log.tag(name)` returns a sub-logger backed by its own native `Logger(name)`,
so every line carries `[name]` and you can tell which system spoke. Each
tagged logger keeps its own throttle history.

```lua
local clog = log.tag("combo")
clog.info("engaged", target_name)   -- prints: [INFO] [combo] engaged ...
```

If the framework `Logger` global is missing (a plain Lua test run) it falls
back to `Log.Write` / `print`, so the same code works in the test harness.
