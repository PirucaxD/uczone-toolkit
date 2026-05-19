# damage

Two jobs: track recent damage taken, and do kill math correctly.

## Recent-damage feed

Call `Damage.GetRecentDamage(npc, window)` and you get the damage that unit
took in the last `window` seconds - without caring how it was measured. The
lib prefers the typed `OnEntityHurt` feed when the framework provides it and
falls back to polling `Hero.GetLastHurtTime` otherwise.

```lua
local Damage = require("lib.damage")
-- in setup:
Damage.Wire(callbacks)

-- later:
local taken = Damage.GetRecentDamage(my_hero, 1.5)   -- HP lost in 1.5s
local rate  = Damage.GetDamageRate(my_hero, 1.5)     -- HP per second
```

| Function | Purpose |
|----------|---------|
| `GetRecentDamage(npc, window)` | total damage taken in the window |
| `GetRecentDamageBySource(npc, source, window)` | damage from one attacker |
| `GetDamageRate(npc, window)` | damage / second over the window |
| `Forget(npc)` | drop a unit's buffer (e.g. on respawn) |
| `IsStage2Active()` | is the typed feed engaged |

## Kill math

The interesting part. A burst that mixes damage types must mitigate **each
instance by its matching defense**, then sum the results in raw HP. Add a
post-armor physical figure straight into a magic-resist total and your kill
check is wrong.

`Damage.MitigatedToRawHP(target, components)` and `Damage.Kills(...)` do it
right. `components` is a table of *pre-mitigation* amounts - any of
`physical`, `magical`, `pure`; omit what you do not have.

```lua
local kills, removed, hp = Damage.Kills(enemy, {
    magical  = 600,    -- before magic resist
    physical = 200,    -- before armor
}, regen_during_cast)
if kills then ... end
```

The optional third argument is extra raw HP to treat as survivable - cast-
time regen, a shield, or an overkill safety margin.
