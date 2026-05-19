#!/usr/bin/env python
# tools/gen_item_data.py - generate lib/item_data.lua from the KV data.
#
# Reads the static KV files:
#   C:\Umbrella\assets\data\items.json
#   C:\Umbrella\assets\data\neutral_items.json
# and emits lib/item_data.lua - a pure-data Lua module (no API calls, no
# callbacks; same shape as lib/threat_data.lua).
#
# Re-run after a Dota patch refreshes the KV files:
#   python tools/gen_item_data.py
#
# The curated SAVE_GEOMETRY table and the helper functions live in this
# generator (as the SAVE_GEOMETRY / HELPERS literals below) - this file is
# the single source of truth for lib/item_data.lua.

import json
import os
import re

import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kv_paths

KV_DIR = kv_paths.resolve()
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "lib", "item_data.lua")

IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
LUA_KEYWORDS = {
    "and", "break", "do", "else", "elseif", "end", "false", "for",
    "function", "goto", "if", "in", "local", "nil", "not", "or",
    "repeat", "return", "then", "true", "until", "while",
}


# ---------------------------------------------------------------------------
# value coercion
# ---------------------------------------------------------------------------

def as_number(s):
    """Return an int/float for a numeric string, else None."""
    try:
        f = float(s)
    except (TypeError, ValueError):
        return None
    if f.is_integer():
        return int(f)
    return f


def coerce(val):
    """KV string/dict -> Lua-emittable Python value.

    - "12"            -> 12
    - "9 8 7"         -> [9, 8, 7]            (per-level array)
    - "teleport;mob"  -> kept as string (handled by caller for tags)
    - {"value": ...}  -> coerce(value)        (drop var_type metadata)
    - other dict      -> {k: coerce(v)}       (nested AbilityValues group)
    - other string    -> string
    """
    if isinstance(val, dict):
        if "value" in val:
            return coerce(val["value"])
        return {k: coerce(v) for k, v in val.items()}
    if isinstance(val, (int, float)):
        return val
    s = str(val).strip()
    n = as_number(s)
    if n is not None:
        return n
    parts = s.split()
    if len(parts) > 1:
        nums = [as_number(p) for p in parts]
        if all(n is not None for n in nums):
            return nums
    return s


# ---------------------------------------------------------------------------
# Lua emission
# ---------------------------------------------------------------------------

def lua_str(s):
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"') + '"'


def lua_key(k):
    k = str(k)
    if IDENT.match(k) and k not in LUA_KEYWORDS:
        return k
    return "[" + lua_str(k) + "]"


def lua_val(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return repr(v)
    if isinstance(v, str):
        return lua_str(v)
    if isinstance(v, list):
        return "{ " + ", ".join(lua_val(x) for x in v) + " }"
    if isinstance(v, dict):
        inner = ", ".join("%s = %s" % (lua_key(k), lua_val(x))
                          for k, x in v.items())
        return "{ " + inner + " }"
    raise TypeError("cannot emit %r" % (v,))


def emit_entry(fields):
    """One-line-per-field item entry body."""
    parts = []
    for k, v in fields:
        if v is None:
            continue
        if isinstance(v, (list, dict)) and len(v) == 0:
            continue
        parts.append("%s = %s" % (lua_key(k), lua_val(v)))
    return "{ " + ", ".join(parts) + " }"


# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------

def short_behavior(beh):
    out = []
    for f in beh.split("|"):
        f = f.strip()
        if not f:
            continue
        out.append(f.replace("DOTA_ABILITY_BEHAVIOR_", "").lower())
    return out


ACTIVE_BEHAVIORS = {
    "no_target", "unit_target", "point", "toggle",
    "vector_targeting", "optional_unit_target",
}


def short_enum(s, prefix):
    out = []
    for f in s.split("|"):
        f = f.strip()
        if not f:
            continue
        out.append(f.replace(prefix, "").lower())
    return out


def build():
    items_raw = json.load(open(os.path.join(KV_DIR, "items.json")))["DOTAAbilities"]
    neutral = json.load(open(os.path.join(KV_DIR, "neutral_items.json")))["neutral_items"]

    items = {k: v for k, v in items_raw.items() if isinstance(v, dict)}

    # neutral tier lookup: item -> tier
    neutral_tier = {}
    tiers_out = {}
    for tier, tdata in neutral.get("neutral_tiers", {}).items():
        tn = as_number(tier)
        members = list(tdata.get("items", {}).keys())
        for it in members:
            neutral_tier[it] = tn
        tiers_out[tn] = {
            "start_time": tdata.get("start_time"),
            "craft_cost": as_number(tdata.get("craft_cost", "0")),
            "items": members,
        }

    # recipe graph: result item -> list of alternative ingredient sets
    recipe_of = {}
    for name, v in items.items():
        if v.get("ItemRecipe") != "1":
            continue
        result = v.get("ItemResult")
        if not result:
            continue
        reqs = v.get("ItemRequirements", {})
        if not isinstance(reqs, dict):
            # legacy items carry an empty-string ItemRequirements
            continue
        alts = []
        for _, req in sorted(reqs.items()):
            comps = [c.strip().rstrip("*") for c in req.split(";") if c.strip()]
            comps.append(name)  # the recipe scroll itself
            alts.append(comps)
        if alts:
            recipe_of.setdefault(result, []).extend(alts)

    entries = []
    for name in sorted(items.keys()):
        v = items[name]
        beh = short_behavior(v.get("AbilityBehavior", ""))
        fields = []
        fields.append(("id", as_number(v.get("ID", ""))))
        fields.append(("cost", as_number(v.get("ItemCost", ""))))
        fields.append(("quality", v.get("ItemQuality")))
        if beh:
            fields.append(("behavior", beh))
        fields.append(("active", any(b in ACTIVE_BEHAVIORS for b in beh)))
        if "AbilityCooldown" in v:
            fields.append(("cooldown", coerce(v["AbilityCooldown"])))
        if "AbilityManaCost" in v:
            fields.append(("mana", coerce(v["AbilityManaCost"])))
        if "AbilityCastRange" in v:
            fields.append(("cast_range", coerce(v["AbilityCastRange"])))
        if "AbilityCastPoint" in v:
            fields.append(("cast_point", coerce(v["AbilityCastPoint"])))
        if "AbilityCharges" in v:
            fields.append(("charges", coerce(v["AbilityCharges"])))
        if "AbilitySharedCooldown" in v:
            fields.append(("shared_cooldown", v["AbilitySharedCooldown"]))
        if "AbilityUnitDamageType" in v:
            fields.append(("damage_type",
                            v["AbilityUnitDamageType"]
                            .replace("DAMAGE_TYPE_", "").lower()))
        if "AbilityUnitTargetTeam" in v:
            fields.append(("target_team",
                            short_enum(v["AbilityUnitTargetTeam"],
                                       "DOTA_UNIT_TARGET_TEAM_")))
        if "AbilityUnitTargetType" in v:
            fields.append(("target_type",
                            short_enum(v["AbilityUnitTargetType"],
                                       "DOTA_UNIT_TARGET_")))
        tags = [t for t in v.get("ItemShopTags", "").split(";") if t]
        if tags:
            fields.append(("tags", tags))
        if v.get("ItemPurchasable") == "0":
            fields.append(("purchasable", False))
        if v.get("ItemStackable") == "1":
            fields.append(("stackable", True))
        if "ItemInitialCharges" in v:
            fields.append(("initial_charges",
                            as_number(v["ItemInitialCharges"])))
        if v.get("ItemRecipe") == "1":
            fields.append(("is_recipe", True))
            fields.append(("result", v.get("ItemResult")))
        if name in recipe_of:
            fields.append(("recipe", recipe_of[name]))
        if name in neutral_tier:
            fields.append(("neutral_tier", neutral_tier[name]))
        av = v.get("AbilityValues")
        if isinstance(av, dict) and av:
            vals = {}
            for k, val in av.items():
                vals[k] = coerce(val)
            fields.append(("values", vals))
        entries.append((name, emit_entry(fields)))

    return entries, tiers_out


# ---------------------------------------------------------------------------
# static sections (header / SAVE_GEOMETRY / helpers)
# ---------------------------------------------------------------------------

HEADER = '''---@meta
---lib/item_data.lua - static item reference, generated from the KV data.
---
---Data-only Tier 2 module (no API calls, no callbacks, no side effects -
---same discipline as lib/threat_data.lua). GENERATED by
---tools/gen_item_data.py from C:\\\\Umbrella\\\\assets\\\\data\\\\items.json +
---neutral_items.json. Do NOT hand-edit the ITEMS / NEUTRAL_TIERS tables -
---re-run the generator after a patch. The curated SAVE_GEOMETRY table and
---the helpers below DO live in the generator (edit them there).
---
---Owns:
---  - ITEMS           item name -> { id, cost, quality, behavior, active,
---                    cooldown, mana, cast_range, cast_point, tags, recipe,
---                    neutral_tier, values, ... }
---  - NEUTRAL_TIERS   tier -> { start_time, craft_cost, items }
---  - SAVE_GEOMETRY   curated save-item geometry (push distance, durations,
---                    cast ranges) - the data lib/threat_data.lua's
---                    SAVE_PUSH_DISTANCE / SAVE_KIND can be grounded against.
---  - Get / HasBehavior / IsActive / NeutralTier / Components / BuildCost /
---    SaveGeometry  (pure helpers)
---
---Field notes:
---  behavior   - short flag list, DOTA_ABILITY_BEHAVIOR_ prefix stripped.
---  active     - true if the item has a manual cast (no_target / unit_target
---               / point / toggle / vector_targeting / optional_unit_target).
---  cooldown / mana / cast_range / cast_point - a number, or a per-level
---               array {a, b, c} when the KV value was space-separated.
---  recipe     - list of alternative build sets; each set is a list of the
---               direct ingredient item names incl. the recipe scroll.
---  values     - the item's AbilityValues, numeric strings coerced to
---               numbers; {value=...} wrappers flattened to the value.
---
---Usage in a hero script:
---```lua
---local ID = require("lib.item_data")
---local pike = ID.SaveGeometry("item_hurricane_pike")
---if pike then local enemy_push = pike.enemy_push end   -- 425
---local cost = ID.BuildCost("item_black_king_bar")      -- 4050
---if ID.IsActive("item_blade_mail") then ... end
---```

local ItemData = {}
'''

SAVE_GEOMETRY = '''
----------------------------------------------------------------------------
-- SAVE_GEOMETRY - curated save-item geometry
--
-- The save-relevant numbers, hand-verified against the KV AbilityValues so a
-- consumer (e.g. lib/threat_data.lua's SAVE_PUSH_DISTANCE) has a data-grounded
-- source instead of hand-maintained constants. `kind` mirrors a SAVE_KIND
-- category. Distances in Hammer units, durations in seconds.
--
-- Pike pushes the CASTER 600u but an ENEMY only 425u (self_push vs
-- enemy_push). Force pushes any target 600u.
----------------------------------------------------------------------------

---@type table<string, table>
ItemData.SAVE_GEOMETRY = {
    item_force_staff        = { kind = "displacement",   self_push = 600, enemy_push = 600, push_time = 0.5, cast_range = 550, enemy_cast_range = 850, cooldown = 19, shared_cd = "force" },
    item_hurricane_pike     = { kind = "displacement",   self_push = 600, enemy_push = 425, push_time = 0.5, cast_range = 650, enemy_cast_range = 425, cooldown = 19, shared_cd = "force" },
    item_cyclone            = { kind = "invuln_cyclone", cyclone = 2.5, cast_range = 550, cooldown = 23, shared_cd = "cyclone" },
    item_wind_waker         = { kind = "invuln_cyclone", cyclone = 2.5, cast_range = 550, cooldown = 19, shared_cd = "cyclone", tornado_speed = 300, can_move = true },
    item_lotus_orb          = { kind = "reflect",        active_duration = 5, cast_range = 900, cooldown = 15 },
    item_black_king_bar     = { kind = "magic_immune",   duration = { 9, 8, 7 }, cooldown = 95 },
    item_aeon_disk          = { kind = "invuln_trigger", trigger_hp_pct = 70, invuln = 2.5, status_resist = 75, cooldown = { 105, 125, 145, 165 }, initial_cooldown = 6 },
    item_glimmer_cape       = { kind = "invis",          fade_delay = 0.5, duration = 5, barrier = 375, cast_range = 600, cooldown = 15 },
    item_blink              = { kind = "blink",          range = 1200, clamp = 960, damage_cooldown = 3, cooldown = 15 },
    item_overwhelming_blink = { kind = "blink",          range = 1200, clamp = 960, damage_cooldown = 3, cooldown = 15 },
    item_swift_blink        = { kind = "blink",          range = 1200, clamp = 960, damage_cooldown = 3, cooldown = 15 },
    item_arcane_blink       = { kind = "blink",          range = 1400, clamp = 1120, damage_cooldown = 3, cooldown = 9 },
    item_ghost              = { kind = "physical_immune", duration = 4, cooldown = 22 },
    item_blade_mail         = { kind = "damage_return",  duration = 5.5, reflect_pct = 85, cooldown = 25 },
    item_manta              = { kind = "dispel_invuln",  invuln = 0.1, illusions = 2, cooldown = 34 },
    item_sphere             = { kind = "spell_block",    damage_absorb = 300, absorb_duration = 10, cast_range = 700, cooldown = 14 },
    item_crimson_guard      = { kind = "damage_block",   duration = 7, block_active = 70, block_chance_active = 100, cast_range = 1200, cooldown = 40 },
    item_pipe               = { kind = "magic_barrier",  barrier = 425, barrier_duration = 8, cast_range = 1200, cooldown = 60 },
    item_satanic            = { kind = "lifesteal_dispel", unholy_duration = 6, lifesteal_pct = 175, cooldown = 30 },
    item_solar_crest        = { kind = "armor_buff",     absorb = 350, duration = 7, cast_range = 1000, cooldown = 16 },
}
'''

HELPERS = '''
----------------------------------------------------------------------------
-- helpers - pure, no API calls
----------------------------------------------------------------------------

local ITEMS = ItemData.ITEMS

---Raw item entry, or nil.
---@param name string
---@return table|nil
function ItemData.Get(name)
    return ITEMS[name]
end

---True if the item carries the given short behavior flag.
---@param name string
---@param flag string  e.g. "unit_target", "passive", "no_target"
---@return boolean
function ItemData.HasBehavior(name, flag)
    local e = ITEMS[name]
    if not e or not e.behavior then return false end
    for _, b in ipairs(e.behavior) do
        if b == flag then return true end
    end
    return false
end

---True if the item has a manual cast (i.e. it is not purely passive).
---@param name string
---@return boolean
function ItemData.IsActive(name)
    local e = ITEMS[name]
    return e ~= nil and e.active == true
end

---Neutral-item tier (1-5), or nil if not a neutral item.
---@param name string
---@return integer|nil
function ItemData.NeutralTier(name)
    local e = ITEMS[name]
    return e and e.neutral_tier or nil
end

---Recursive leaf ingredients of the item's first build recipe. Recipe
---scrolls and basic (recipe-less) items are leaves. Returns {} for an item
---with no recipe.
---@param name string
---@param _seen table|nil  internal cycle guard
---@return string[]
function ItemData.Components(name, _seen)
    local e = ITEMS[name]
    if not e or not e.recipe then return {} end
    _seen = _seen or {}
    local out = {}
    for _, part in ipairs(e.recipe[1]) do
        local sub = ITEMS[part]
        if sub and sub.recipe and not _seen[part] then
            _seen[part] = true
            for _, leaf in ipairs(ItemData.Components(part, _seen)) do
                out[#out + 1] = leaf
            end
        else
            out[#out + 1] = part
        end
    end
    return out
end

---Total gold cost = sum of recursive leaf component costs. For a basic
---(recipe-less) item this is just its own cost.
---@param name string
---@return integer
function ItemData.BuildCost(name)
    local e = ITEMS[name]
    if not e then return 0 end
    if not e.recipe then return e.cost or 0 end
    local total = 0
    for _, leaf in ipairs(ItemData.Components(name)) do
        local le = ITEMS[leaf]
        total = total + ((le and le.cost) or 0)
    end
    return total
end

---Curated save geometry for an item, or nil if it is not a save item.
---@param name string
---@return table|nil
function ItemData.SaveGeometry(name)
    return ItemData.SAVE_GEOMETRY[name]
end

return ItemData
'''


def main():
    entries, tiers = build()

    out = [HEADER]
    out.append("")
    out.append("-" * 76)
    out.append("-- ITEMS - generated from items.json (%d entries)" % len(entries))
    out.append("-" * 76)
    out.append("")
    out.append("---@type table<string, table>")
    out.append("ItemData.ITEMS = {")
    for name, body in entries:
        out.append("    %s = %s," % (name, body))
    out.append("}")
    out.append("")
    out.append("-" * 76)
    out.append("-- NEUTRAL_TIERS - generated from neutral_items.json")
    out.append("-" * 76)
    out.append("")
    out.append("---@type table<integer, table>")
    out.append("ItemData.NEUTRAL_TIERS = {")
    for tn in sorted(tiers.keys()):
        td = tiers[tn]
        out.append("    [%d] = %s," % (tn, lua_val(td)))
    out.append("}")
    out.append(SAVE_GEOMETRY)
    out.append(HELPERS)

    text = "\n".join(out)
    with open(os.path.normpath(OUT), "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    print("wrote %s (%d items, %d tiers, %d bytes)"
          % (os.path.normpath(OUT), len(entries), len(tiers), len(text)))


if __name__ == "__main__":
    main()
