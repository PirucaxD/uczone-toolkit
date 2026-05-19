# ability_data

Every ability in the game as a static Lua table — per-level damage, cooldown,
cast point, cast range, mana, behavior, and the full `AbilityValues`.
**Generated** from Valve's KV data by `tools/gen_ability_data.py`; re-run the
generator (or `tools/update.py`) after a patch rather than hand-editing.

Pure data, no API calls. It reports **base** magnitudes — talent, facet and
Aghanim bonuses are stripped. When you have a live ability handle in-game,
`Ability.GetDamage` is authoritative (the engine has applied the bonuses);
this lib is the answer when you do *not* have a handle — an enemy's ability
you can see but cannot query, planning, tooltips.

## What it owns

`ABILITIES` — every ability keyed by name, with `id`, `type`, `behavior`,
`active`, `cooldown`, `cast_point`, `cast_range`, `mana`, `damage`,
`damage_type`, `channel_time`, `duration`, `max_level`, target flags,
`has_scepter` / `has_shard`, and `values` (the base `AbilityValues`).

Per-level fields are stored as `{l1, l2, l3, ...}` arrays.

## Helpers

| Function | Returns |
|----------|---------|
| `Get(name)` | the raw ability entry |
| `HasBehavior(name, flag)` | bool |
| `IsActive(name)` | bool: has a manual cast |
| `AtLevel(array, level)` | index a per-level array, clamped |
| `Damage(name, level)` | base damage at a level |
| `Cooldown(name, level)` | cooldown at a level |
| `CastPoint(name, level)` / `CastRange(name, level)` / `Mana(name, level)` | likewise |
| `Duration(name, level)` | duration at a level |
| `Value(name, key, level)` | any `AbilityValues` key at a level |

```lua
local AD = require("lib.ability_data")
local cd = AD.Cooldown("sniper_assassinate", 1)        -- first-level cooldown
local stun = AD.Value("sven_storm_bolt", "stun_duration", 2)
```
