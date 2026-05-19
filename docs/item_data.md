# item_data

Every item in the game as a static Lua table — cost, behavior, cooldown,
recipe, the full `AbilityValues`. **Generated** from Valve's KV data by
`tools/gen_item_data.py`; do not hand-edit it, re-run the generator (or
`tools/update.py`) after a patch.

Pure data, no API calls. Use it when you want an item's *stats* without a
live handle — drafting logic, cost math, "is this item a save".

## What it owns

| Table | Contents |
|-------|----------|
| `ITEMS` | every item: `id`, `cost`, `quality`, `behavior`, `active`, `cooldown`, `mana`, `cast_range`, `cast_point`, `tags`, `recipe`, `neutral_tier`, `values` |
| `NEUTRAL_TIERS` | tiers 1–5: `start_time`, `craft_cost`, `items` |
| `SAVE_GEOMETRY` | curated, hand-verified geometry for ~20 save items |

`SAVE_GEOMETRY` is the precise data — Force pushes 600u, Pike pushes the
caster 600u but an enemy only 425u, BKB durations, cooldowns. It is what
[save_select](save_select.md) reads.

## Helpers

| Function | Returns |
|----------|---------|
| `Get(name)` | the raw item entry |
| `HasBehavior(name, flag)` | bool: carries a behavior flag |
| `IsActive(name)` | bool: has a manual cast (not purely passive) |
| `NeutralTier(name)` | 1–5, or `nil` |
| `Components(name)` | recursive leaf ingredients of the build |
| `BuildCost(name)` | total gold = sum of recursive leaf costs |
| `SaveGeometry(name)` | the curated save geometry, or `nil` |

```lua
local ID = require("lib.item_data")
local cost = ID.BuildCost("item_black_king_bar")     -- 4050
local pike = ID.SaveGeometry("item_hurricane_pike")
local enemy_push = pike and pike.enemy_push          -- 425
```

For a live, in-game item handle (cooldown remaining, charges) use
[npc](npc.md)'s `item` / `item_ready` instead — this lib is the static
reference.
