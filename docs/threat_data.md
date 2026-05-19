# threat_data

A catalogue of dangerous enemy abilities and what beats them. Pure data plus
two pure helpers - no API calls, no callbacks. Pike's push is 600u for
everyone and Bane Nightmare is beaten by invuln/dispel regardless of who is
defending, so this knowledge does not belong per-hero.

It is the backing data for [save_select](save_select.md), but you can read it
directly too.

## The tables

| Table | What it holds |
|-------|---------------|
| `SAVE_KIND` | each save item/ability -> the effect kinds it provides |
| `THREAT_COUNTER` | a threat -> the effect kinds that counter it |
| `SAVE_PUSH_DISTANCE` | displacement saves -> how far they shove |
| `THREAT_TETHER_RANGE` | channel/tether threats -> the range they break at |
| `THREATS_ON_SELF` | modifiers that, landing on you, mean trouble |
| `ABILITY_TO_THREAT` | ability name -> the threat modifier it applies |
| `LOTUS_WORTHY_INCOMING` | single-target ults worth reflecting with Lotus |
| `ENEMY_CHANNEL_MODIFIERS` | enemy channels worth interrupting |
| `ENEMY_BUFF_THREATS` | self-buffs an enemy casts that threaten you |
| `THREAT_CATEGORY` / `THREAT_SEVERITY` / `THREAT_TIMING` | per-threat classification |
| `RECOMMENDED_SAVES` | hand-tuned save priority per threat |

## Helpers

| Function | Returns |
|----------|---------|
| `SaveCounters(save, threat_mod)` | bool: do the kinds intersect |
| `WillTetherBreak(save, threat_mod, distance)` | bool: pure geometry |
| `CategoryOf` / `SeverityOf` / `TimingFor` | the classification of a threat |
| `RecommendedSaves(threat_mod)` | the tuned save list for a threat |

```lua
local TD = require("lib.threat_data")
if TD.SaveCounters("item_black_king_bar", "modifier_bane_nightmare") then
    -- BKB's magic-immunity beats Nightmare
end
```

## A note on modifier names

Valve's KV data exposes ability names but **not** modifier names. Where a
threat's modifier name could not be confirmed it is a best-effort
`modifier_<ability>` guess marked `(verify)` in the source. A wrong guess just
means that one threat is not recognised - harmless, and correctable once you
see the real name in a game. It is the one soft spot in otherwise solid data.
