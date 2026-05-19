# anim

Turn an enemy's animations and spell particles into clean "they just cast X"
events. Instead of polling, you register what to watch for and subscribe to
roles like `gap_close` or `hard_disable`.

## How it works

1. **Register a map** for a unit - which `GameActivity` (or sequence name)
   means which ability, and what *role* that ability plays.
2. **Register particles** if an ability is better recognised by its particle
   than its animation.
3. **Subscribe** to a role. Your callback fires whenever any registered unit
   plays a matching animation/particle.

```lua
local Anim = require("lib.anim")
Anim.Wire(callbacks)

Anim.RegisterMap("npc_dota_hero_sven", {
    [Enum.GameActivity.ACT_DOTA_CAST_ABILITY_2] =
        { ability = "sven_storm_bolt", role = "hard_disable" },
})

Anim.Subscribe("hard_disable", function(ev)
    -- ev.caster, ev.ability_name, ev.role, ev.target_self, ev.raw
    if ev.target_self then
        -- a stun is coming at me - react
    end
end)
```

## API

| Function | Purpose |
|----------|---------|
| `RegisterMap(unit_name, map)` | activity/sequence -> `{ability, role, range?}` |
| `RegisterParticle(path, signature)` | particle path -> `{ability, role}` |
| `Subscribe(role, fn)` | run `fn(event)` for every event of that role |
| `Wire(callbacks)` | chain `OnUnitAnimation` + `OnParticleCreate` |

The event passed to a subscriber has `caster`, `target`, `ability_name`,
`role`, `target_self` (was it aimed at you) and `raw` (the original data).
Your own hero's animations are never dispatched - you already know your state.
