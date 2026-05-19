# dedup

"Did I already react to this?" - small helpers for two recurring problems:

- **anim-log dedup** - the same animation event fires several times; you want
  to log it once.
- **threat dedup** - one enemy cast can be seen by several observers (an anim
  event *and* a modifier-create event); you want to respond to it once.

## State-container design

The lib does **not** own the dedup tables. Every function takes a
caller-owned table as its first argument. That keeps the data visible to your
brain - you can still iterate, clear or GC it yourself (e.g. wiping it on a
respawn), which a module-private table would hide from you.

## API

| Function | Purpose |
|----------|---------|
| `anim_throttled(tbl, caster, ability)` | true if logged recently; stamps `tbl` either way |
| `threat_already_responded(tbl, caster, mod)` | read-only check |
| `threat_mark_responded(tbl, caster, mod)` | mark a threat handled (call after reacting) |
| `threat_clear_responded(tbl, caster, mod)` | un-mark, so the next sighting counts as fresh |
| `gc(responded_tbl, anim_tbl, now)` | drop stale entries - call periodically |

Constants: `ANIM_WINDOW` (1.0s) and `THREAT_WINDOW` (2.0s).

```lua
local Dedup = require("lib.dedup")
local responded = {}   -- you own this table

if not Dedup.threat_already_responded(responded, caster, mod) then
    fire_the_save()
    Dedup.threat_mark_responded(responded, caster, mod)
end
```

`threat_clear_responded` matters for an ability cast twice in quick
succession (e.g. a repeated blink): each cast deserves its own response, and
the flat window would otherwise swallow the second one - clear the mark when
you detect a genuinely new instance.
