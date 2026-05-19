# save_select

You are about to die and you have several escape items. Which one actually
saves you? `save_select` answers that - given a threat and the save items you
hold, it ranks the ones that genuinely counter it and picks the best.

It is pure logic: it classifies and ranks, nothing else. You decide which
items are available and ready and pass them in. It bridges two data libs -
[threat_data](threat_data.md) for what counters what, and
[item_data](item_data.md) for save geometry (push distance, cooldown).

## Why ranking, not a flat list

A save can *technically* fire and still not help. Eul on a tether only breaks
it if the cyclone's displacement clears the tether range from where you are
standing - too close and it fails. `save_select` scores that geometry in, so
a push-too-short save ranks last instead of being picked.

## API

| Function | Returns |
|----------|---------|
| `Effective(save, threat_mod, ctx)` | bool: does this save genuinely neutralise the threat |
| `ScoreSave(save, threat_mod, ctx)` | a heuristic score + reason string (`nil` if it does not counter) |
| `RankSaves(threat_mod, available, ctx)` | every available save, best first |
| `BestSave(threat_mod, available, ctx)` | the single top pick |
| `ThreatBrief(threat_mod)` | category / severity / timing / tether range / recommended list |

`available` is the save items you hold - a string array or a hash set. `ctx`
optionally carries `distance` (you-to-caster units), needed for tether math.

```lua
local SaveSelect = require("lib.save_select")
local held = { "item_hurricane_pike", "item_black_king_bar", "item_cyclone" }

local best = SaveSelect.BestSave("modifier_bane_fiends_grip", held,
                                 { distance = dist_to_bane })
-- `best` is the item name to use, picked for this threat at this range
```
