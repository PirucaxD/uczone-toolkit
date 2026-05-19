# npc

A tiny lib - four functions for the NPC checks that come up in every brain.
Hero-agnostic; each function takes an npc handle first and is nil-safe (pass
`nil`, get a falsy result, no crash).

## Functions

| Function | Returns |
|----------|---------|
| `has_shard(npc)` | bool: owns an Aghanim's Shard |
| `has_scepter(npc)` | bool: owns an Aghanim's Scepter |
| `item(npc, name, inventory_only)` | the item handle, or `nil` |
| `item_ready(npc, name, inventory_only)` | bool: owns it **and** it is off cooldown |

`item` / `item_ready` default to **inventory only** - the six active slots,
not backpack or stash, which is what you almost always want. Pass
`inventory_only = false` to widen the search.

```lua
local npc = require("lib.npc")

if npc.has_scepter(enemy) then ... end

if npc.item_ready(enemy, "item_black_king_bar") then
    -- they can BKB out of my combo
end
```

That is the whole lib. It is intentionally small - if you need item *stats*
(cost, cooldown, behavior) rather than the live handle, that is
[item_data](item_data.md).
