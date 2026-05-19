# hero_data

Every hero as a static Lua table — base stats, the ability kit, talents,
facets, attributes. **Generated** from Valve's KV data by
`tools/gen_hero_data.py`; re-run the generator (or `tools/update.py`) after a
patch.

Pure data, no API calls. Reach for it when you want a hero's reference numbers
without a live handle — an enemy's base stats, "what is this hero's primary
attribute", "what talents can they pick".

## What it owns

`HEROES` — every hero keyed by full unit name (`npc_dota_hero_lina`), with
`id`, `role`, `complexity`, `abilities` (the base kit), `talents`, `facets`,
`attack_type`, attack stats, `armor`, `primary_attribute`, the six attribute
fields (`str_base` / `str_gain` / `agi_base` / ...), `move_speed`,
`turn_rate`, vision.

All values are **base** — level 1, no items, no talents. Health and mana are
deliberately absent: they derive from strength/intelligence by per-patch
constants, so read them live or compute them with the current patch's
multipliers (hard-coding the constant would be exactly the kind of rot this
lib avoids).

## Helpers

| Function | Returns |
|----------|---------|
| `Get(name)` | the raw hero entry |
| `HasAbility(name, ability)` | bool: in the base kit (talents excluded) |
| `Talents(name)` | the hero's talent ability names |
| `Facets(name)` | the hero's facet names |
| `PrimaryAttribute(name)` | `"str"` / `"agi"` / `"int"` / `"all"` |
| `AttributeAt(name, attr, level)` | base + gain × (level − 1) |
| `AvgAttackDamage(name)` | mean of base attack min/max |

```lua
local HD = require("lib.hero_data")
if HD.PrimaryAttribute("npc_dota_hero_lina") == "int" then ... end
local agi_at_25 = HD.AttributeAt("npc_dota_hero_sniper", "agi", 25)
```
