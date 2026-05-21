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

## Picking the right `ACT_DOTA_CAST_ABILITY_N`

The map key is a cast-activity: `ACT_DOTA_CAST_ABILITY_1` through `_6`. The
number is the unit's **spell-bar slot** - Q is 1, W is 2, E is 3, the
ultimate is 4 - NOT the raw index of the ability in the hero's KV ability
list. The two differ: the KV list is padded with `generic_hidden`
placeholders, innate abilities and hidden sub-abilities, so an ult that
sits at KV index 6 still casts on `ACT_DOTA_CAST_ABILITY_4`.

You can derive the slot for any hero deterministically from `hero_data` +
`ability_data`: walk the hero's ability list, skip every entry that is
`generic_hidden`, innate, hidden / not-learnable, a pure passive, or a
talent (`ABILITY_TYPE_ATTRIBUTES`). Of what remains, the ultimate is slot 4
and the first three others are slots 1, 2, 3. A short generator can emit
every hero's map this way and be re-run after a patch - much better than
hand-keying activity numbers.

One limit worth knowing: the KV data carries ability names, behaviors and
values but never `modifier_*` names. Anything keyed on ability names or
cast-activity slots (like this map) is fully data-derivable; a catalog keyed
on modifier names is not, and has to be confirmed from in-game observation.
