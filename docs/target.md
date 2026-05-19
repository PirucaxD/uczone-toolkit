# target

A bag of small **predicates** for reasoning about units. There is deliberately
no `Target.Pick()` - picking a target is per-hero, and the framework's own
target selection covers the default case. You compose these instead.

Every predicate accepts `nil` and returns `false` (or `0` for numeric ones),
so you never need a nil-check at the call site.

## Existence and type

`IsValid`, `IsAlive`, `IsHero`, `IsConsideredHero`, `IsEnemyHero(e, source)`,
`IsAllyHero(e, source)`, `IsVisible`.

## Filtering out fakes

`NotIllusion`, `NotMeepoClone`, `NotClone` (illusion + Meepo + Arc Warden
double), `NotSummon` (filters spirit bears, spiders, familiars - real heroes
pass).

## State and protection

`IsKillable`, `HasState(e, state)`, `IsSafeTarget`, `HasReadyLinkens`,
`HasReadyLotus`, `HasAegis`. The protection checks use the framework's own
primitives, so they account for charges and break correctly.

## Killability math

| Function | Returns |
|----------|---------|
| `EffectiveHpVs(target, source, damage_type)` | HP a burst of that type must chew through (`math.huge` if immune) |
| `WillBeInvulnIn(entity, ms)` | will the target be invuln in the window |

## Escape-item awareness

`HasReadyEscapeItem(e)` - does the target have an off-cooldown invuln / dispel
/ magic-immune item. `EscapeItemWindowState(e, window)` is the richer version:
returns `"active"`, `"ready"`, `"soon"`, `"long"` or `"none"` so you can tell
"they will dispel my combo" from "they have nothing".

## Kite / chase reads

`IsKitingUs(target, me)` - is the target actively running away from you.
`IsRightClicking(target, me)` - is it attacking you from inside its range.

```lua
local Target = require("lib.target")
if Target.IsEnemyHero(e, me) and Target.NotClone(e)
   and not Target.HasReadyLinkens(e) then
    -- safe to single-target nuke
end
```
