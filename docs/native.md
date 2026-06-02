# native

The framework's per-hero baseline keeps issuing orders while your
brain is trying to cast a multi-step combo. Hit & Run is the worst
offender: it fires a MOVE order every ~70 ms whenever there's
something to kite to, and a brain cast that hasn't entered its
cast point yet gets cancelled by the next MOVE that arrives.

`OnPrepareUnitOrders` cannot veto the flood (it only sees PLAYER
orders, and the native modules issue with `triggerCallBack=false`),
so the only lever you have is the framework's own menu switches.
This module pauses/restores those switches for your combo's duration
and ensures HR / Orb Walker come back to whatever the user had them
set to, exactly.

## Setup

There is no `Wire(callbacks)`; you call this lib when your combo is
about to run. State (handles / saved values / paused flag) is owned
inside the lib and keyed by the hero's MENU name, so callers just
toggle.

```lua
local Native = require("lib.native")

-- About to run a multi-step combo
local newly_paused, snapshot = Native.PauseHitRun("Lina")
-- ... issue your combo cast orders, run the step scheduler ...

-- Combo done (or aborted), put HR back
Native.RestoreHitRun("Lina")

-- 500 ms later, reassert in case something rewrote
Native.ReassertEnabled("Lina", snapshot)
```

`"Lina"` here is the menu name (Heroes > Hero List > **Lina**). The
lib then walks to `Heroes > Hero List > Lina > Extra Settings > Hit
& Run > {Override, Kiting, Enabled}` and `Heroes > Hero List > Lina
> Extra Settings > Orb Walker > {Override, Enabled}`.

## Why pause Hit & Run differently than Orb Walker

HR has three switches: Override, Kiting, Enabled. Orb Walker has two:
Override, Enabled. Some heroes do not have a particular widget
(Orb Walker often has no Enabled). Missing widgets resolve to nil
and are skipped safely.

A module's real off-switch is its `Enabled` widget; Kiting only tunes
how it moves. `Override=true` makes the per-hero value win over the
global default. When you pause HR you typically want
`Override=true, Enabled=false`; when you restore you put the saved
values back. The lib does this round-trip faithfully even for the
boolean `false` case (see the comment in `wget` about why
`ok and v or nil` collapses a legitimate `false` into nil).

## The `override=false` skip

There is one user-config the lib refuses to fight:

If `hr_override` is already `false` at pause-time, the user is
relying on the global HR config. Writing through to `hr_override=true`
for the combo window triggers a framework-side state latch that
breaks the user's mouse-follow even after `RestoreHitRun` puts
override back to false. The lib detects this and returns
`(false, "override_off")` from `PauseHitRun` instead, so the caller
can log "we didn't pause, the user runs a global config".

Practically: the brain still gets to fire its combo against whatever
the global HR config is doing; the user's mouse-follow config keeps
working. If the global HR interferes with combos, that's a separate
fix in the user's HR config, not something this lib should patch
behind their back.

## The reassert watchdog

The framework sometimes rewrites HR widgets between `RestoreHitRun`
returning and the user's next click (observed empirically; the exact
trigger varies). The recommended pattern is:

1. Restore at combo-end.
2. Wait ~500 ms.
3. Reassert.

`Native.ReassertEnabled` only writes `hr_enabled=true` when the
captured snapshot had `hr_enabled=true`. This guards against the
"saved=false, identical-shape reassert flips it back to true"
clobber that breaks a `hr_enabled=false` mouse-follow-with-HR-off
config.

## API

| Function | Purpose |
|----------|---------|
| `Native.Resolve(name)` | Resolve widget handles for `name`. Returns `{ hr_en, hr_ov, hr_ki, ow_en, ow_ov : bool }` indicating which widgets were found. Caches. |
| `Native.PauseHitRun(name)` | Pause HR (and OW). Returns `(newly_paused, snapshot_or_skip_reason)`. The string `"override_off"` as second value signals the lib refused to pause because the user's `hr_override` was already false. |
| `Native.RestoreHitRun(name)` | Restore HR + OW from the saved snapshot. Idempotent. Returns a probe table the caller can log to spot framework-side rewrites. |
| `Native.IsPaused(name)` | Boolean: is `name` currently paused. |
| `Native.ReassertEnabled(name, saved)` | The 500 ms post-restore watchdog. Only writes `hr_enabled=true` when saved.hr_enabled was true. |

## When to use this

Any combo that issues more than one order in sequence and where a
single-step cancel kills the whole sequence. Long cast points
(Sniper's Assassinate is the canonical 2.0s pain) are the obvious
case; multi-ability burst combos with cast-point chaining are the
other. If your combo is one immediate cast-no-target ability with no
follow-up, you do not need this; the cast point starts on the same
tick and the flood cannot cancel it.
