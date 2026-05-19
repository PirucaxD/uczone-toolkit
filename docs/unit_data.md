# unit_data

Every **non-hero** unit as a static Lua table - lane and neutral creeps,
summons, wards, buildings, Roshan. **Generated** from Valve's KV data by
`tools/gen_unit_data.py`; re-run the generator (or `tools/update.py`) after a
patch.

Pure data, no API calls. Useful for last-hit / jungle logic and for telling a
real summon apart from an illusion.

## What it owns

`UNITS` - every unit keyed by name, with `base_class`, `level`, `health` /
`health_regen`, `mana` / `mana_regen`, `armor`, `magic_resist`, attack stats,
`damage_type`, `move_speed`, vision, bounty (`bounty_gold_min/max`,
`bounty_xp`), `abilities`, and the flags `summoned`, `ancient`, `neutral`,
`considered_hero`, `has_inventory`, `roshan`.

## Helpers

| Function | Returns |
|----------|---------|
| `Get(name)` | the raw unit entry |
| `HasAbility(name, ability)` | bool |
| `IsSummon(name)` | bool: a hero-owned summon |
| `IsAncient(name)` | bool |
| `IsNeutral(name)` | bool |
| `IsWard(name)` | bool: observer / sentry |
| `IsBuilding(name)` | bool |
| `AvgAttackDamage(name)` | mean of attack min/max |

```lua
local UD = require("lib.unit_data")
local rosh = UD.Get("npc_dota_roshan")
local gold = UD.Get("npc_dota_creep_badguys_melee").bounty_gold_max
```

**Summon vs illusion:** an illusion is a hero copy and is *not* in this table.
A true summon (treant, golem, forged spirit) has `summoned = true`. The Lone
Druid Spirit Bear is special - Valve flags it `considered_hero`, not
`summoned`, so `IsSummon` is false for it; check `considered_hero` for that
case.
