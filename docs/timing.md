# timing

Will the target slip out of your combo before it lands? `timing` predicts
near-future invuln / magic-immune / dispel states so you do not commit a long
cast into a target who is about to press BKB or Eul.

Pure helpers — you feed in the target and a look-ahead window, you get an
answer. No game-state mutation.

## Functions

| Function | Returns |
|----------|---------|
| `IsInvulnNow(entity)` | bool: already invuln / magic-immune / out of game |
| `WillBeInvulnIn(entity, window_s)` | `bool, reason` — invuln within the window |
| `EscapeReadiness(entity, window_s)` | a 0–1 score of how likely an escape is |

`WillBeInvulnIn` checks current states, active state durations, and any escape
*item* the target could press in time (BKB, Manta, Eul, Wind Waker, Aeon Disk,
Lotus, Satanic). It is mana-gated, and Aeon Disk is HP-gated (it only triggers
below its HP threshold). The second return value tells you *why* — `"now"`,
`"state_active"`, or the item name.

`EscapeReadiness` is the soft version: `0` means nothing available, `1` means
something is ready right now, with `0.3` / `0.6` for "comes off cooldown
within 2× / 1× the window".

```lua
local timing = require("lib.timing")

local cast_time = 2.4
if timing.EscapeReadiness(enemy, cast_time) > 0.6 then
    -- they'll likely dispel mid-cast — poke instead of committing the ult
end
```

This is the forward-looking companion to [target](target.md)'s
`WillBeInvulnIn`, which only reads the *current* state.
