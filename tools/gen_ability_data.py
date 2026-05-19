#!/usr/bin/env python
# tools/gen_ability_data.py - generate lib/ability_data.lua from the KV data.
#
# Reads C:\Umbrella\assets\data\npc_abilities.json and emits
# lib/ability_data.lua - a pure-data Lua module (no API calls, no callbacks;
# same shape as lib/threat_data.lua / lib/item_data.lua).
#
# Re-run after a Dota patch refreshes the KV file:
#   python tools/gen_ability_data.py
#
# The helper functions live in this generator (the HELPERS literal below) -
# this file is the single source of truth for lib/ability_data.lua.

import json
import os
import re

import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kv_paths

KV_DIR = kv_paths.resolve()
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "lib", "ability_data.lua")

IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
LUA_KEYWORDS = {
    "and", "break", "do", "else", "elseif", "end", "false", "for",
    "function", "goto", "if", "in", "local", "nil", "not", "or",
    "repeat", "return", "then", "true", "until", "while",
}

# AbilityValues sub-keys that are metadata, not a base value.
META_KEYS = {
    "var_type", "affected_by_aoe_increase", "CalculateSpellDamageTooltip",
    "RequiresScepter", "RequiresShard", "RequiresFacet", "ad_linked_ability",
    "ad_modifier_count", "levelkey", "dynamic_value", "linked_special_bonus",
    "linked_special_bonus_operation", "linked_special_bonus_field",
}

# AbilityValues keys promoted to top-level entry fields.
PROMOTE = {
    "AbilityCooldown": "cooldown",
    "AbilityCastPoint": "cast_point",
    "AbilityCastRange": "cast_range",
    "AbilityManaCost": "mana",
    "AbilityChannelTime": "channel_time",
    "AbilityDuration": "duration",
    "AbilityDamage": "damage",
    "damage": "damage",
}

ACTIVE_BEHAVIORS = {
    "no_target", "unit_target", "point", "toggle",
    "vector_targeting", "optional_unit_target",
}


# ---------------------------------------------------------------------------
# value coercion
# ---------------------------------------------------------------------------

def as_number(s):
    try:
        f = float(s)
    except (TypeError, ValueError):
        return None
    if f.is_integer():
        return int(f)
    return f


def coerce_scalar(val):
    """KV scalar -> int / float / [numbers] / bool / string."""
    if isinstance(val, bool):
        return val
    if isinstance(val, (int, float)):
        return val
    s = str(val).strip()
    n = as_number(s)
    if n is not None:
        return n
    parts = s.split()
    if len(parts) > 1:
        nums = [as_number(p) for p in parts]
        if all(x is not None for x in nums):
            return nums
    return s


def coerce_av(val):
    """An AbilityValues entry -> its BASE value (talent / facet bonuses and
    metadata dropped). Returns None when the entry has no base value."""
    if isinstance(val, dict):
        if "value" in val:
            return coerce_av(val["value"])
        sub = {}
        for k, v in val.items():
            if k.startswith("special_bonus") or k in META_KEYS:
                continue
            cv = coerce_av(v)
            if cv is not None:
                sub[k] = cv
        return sub or None
    return coerce_scalar(val)


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

def short_flags(s, prefix):
    out = []
    for chunk in s.split("|"):
        for f in chunk.split():        # tolerate malformed " "-joined flags
            f = f.strip()
            if f:
                out.append(f.replace(prefix, "").lower())
    return out


def build():
    raw = json.load(open(os.path.join(KV_DIR, "npc_abilities.json")))["DOTAAbilities"]
    abil = {k: v for k, v in raw.items() if isinstance(v, dict)}

    entries = []
    for name in sorted(abil.keys()):
        v = abil[name]
        av = v.get("AbilityValues")
        av = av if isinstance(av, dict) else {}

        beh = short_flags(v.get("AbilityBehavior", ""),
                          "DOTA_ABILITY_BEHAVIOR_")
        fields = []
        fields.append(("id", as_number(v.get("ID", ""))))
        if v.get("AbilityType"):
            fields.append(("type", v["AbilityType"]
                            .replace("ABILITY_TYPE_", "").lower()))
        if beh:
            fields.append(("behavior", beh))
        fields.append(("active", any(b in ACTIVE_BEHAVIORS for b in beh)))

        # promoted canonical fields: top-level Ability<X>, else AbilityValues
        for kv_key, field in PROMOTE.items():
            # `damage` may already be set from AbilityDamage; don't overwrite
            if any(f == field for f, _ in fields):
                continue
            src = None
            if kv_key in v:
                src = coerce_scalar(v[kv_key])
            elif kv_key in av:
                src = coerce_av(av[kv_key])
            if src is not None:
                fields.append((field, src))

        if "MaxLevel" in v:
            fields.append(("max_level", as_number(v["MaxLevel"])))
        if "AbilityUnitDamageType" in v:
            fields.append(("damage_type", v["AbilityUnitDamageType"]
                            .replace("DAMAGE_TYPE_", "").lower()))
        if "AbilityUnitTargetTeam" in v:
            fields.append(("target_team",
                            short_flags(v["AbilityUnitTargetTeam"],
                                        "DOTA_UNIT_TARGET_TEAM_")))
        if "AbilityUnitTargetType" in v:
            fields.append(("target_type",
                            short_flags(v["AbilityUnitTargetType"],
                                        "DOTA_UNIT_TARGET_")))
        if "SpellImmunityType" in v:
            fields.append(("spell_immunity", v["SpellImmunityType"]
                            .replace("SPELL_IMMUNITY_", "").lower()))
        if "SpellDispellableType" in v:
            fields.append(("dispellable", v["SpellDispellableType"]
                            .replace("SPELL_DISPELLABLE_", "").lower()))
        if v.get("HasScepterUpgrade") == "1":
            fields.append(("has_scepter", True))
        if v.get("HasShardUpgrade") == "1":
            fields.append(("has_shard", True))
        if v.get("Innate") == "1":
            fields.append(("innate", True))
        if v.get("IsBreakable") == "1":
            fields.append(("breakable", True))

        # values: AbilityValues minus the promoted keys, base-coerced
        vals = {}
        for k, val in av.items():
            if k in PROMOTE:
                continue
            cv = coerce_av(val)
            if cv is not None:
                vals[k] = cv
        if vals:
            fields.append(("values", vals))

        entries.append((name, emit_entry(fields)))

    return entries


# ---------------------------------------------------------------------------
# static sections
# ---------------------------------------------------------------------------

HEADER = '''---@meta
---lib/ability_data.lua - static ability reference, generated from the KV data.
---
---Data-only Tier 2 module (no API calls, no callbacks, no side effects -
---same discipline as lib/threat_data.lua / lib/item_data.lua). GENERATED by
---tools/gen_ability_data.py from C:\\\\Umbrella\\\\assets\\\\data\\\\npc_abilities.json.
---Do NOT hand-edit the ABILITIES table - re-run the generator after a patch.
---The helpers below live in the generator (edit them there).
---
---A static reference + fallback for the live `Ability.GetDamage` path: the
---engine applies talent / facet / Aghanim bonuses at runtime, so prefer the
---live API when an ability handle is available. This lib is the answer when
---it is not (an enemy ability you have no handle to, a pre-cast estimate).
---
---Owns:
---  - ABILITIES   ability name -> { id, type, behavior, active, cooldown,
---                cast_point, cast_range, mana, damage, damage_type,
---                channel_time, duration, max_level, target_team /
---                target_type, spell_immunity, dispellable, has_scepter /
---                has_shard, innate, breakable, values }
---  - Get / HasBehavior / IsActive / AtLevel / Damage / Cooldown /
---    CastPoint / CastRange / Mana / Duration / Value   (pure helpers)
---
---Field notes:
---  type        - basic / ultimate / attributes (talent) / hidden.
---  behavior    - short flag list, DOTA_ABILITY_BEHAVIOR_ prefix stripped.
---  active      - true if the ability has a manual cast (no_target /
---                unit_target / point / toggle / vector_targeting /
---                optional_unit_target).
---  cooldown / cast_point / cast_range / mana / damage / channel_time /
---  duration    - a number, or a per-level array {l1, l2, l3, ...}. Sourced
---                from the top-level Ability<X> field, falling back to the
---                AbilityValues entry of the same name.
---  values      - the ability's AbilityValues, BASE values only - talent
---                (special_bonus_*) and facet bonuses are dropped, so this
---                is the un-upgraded magnitude. {value=...} wrappers are
---                flattened. The promoted canonical keys are not duplicated
---                here.
---
---Usage in a hero script:
---```lua
---local AD = require("lib.ability_data")
---local dmg = AD.Damage("lina_laguna_blade", 3)        -- 750  (level 3)
---local cd  = AD.Cooldown("lion_finger_of_death", 1)   -- 110
---local r   = AD.Value("sniper_shrapnel", "radius", 2) -- 425
---if AD.HasBehavior("pudge_meat_hook", "point") then ... end
---```

local AbilityData = {}
'''

HELPERS = '''
----------------------------------------------------------------------------
-- helpers - pure, no API calls
----------------------------------------------------------------------------

local ABILITIES = AbilityData.ABILITIES

---Raw ability entry, or nil.
---@param name string
---@return table|nil
function AbilityData.Get(name)
    return ABILITIES[name]
end

---True if the ability carries the given short behavior flag.
---@param name string
---@param flag string  e.g. "point", "channelled", "passive", "unit_target"
---@return boolean
function AbilityData.HasBehavior(name, flag)
    local e = ABILITIES[name]
    if not e or not e.behavior then return false end
    for _, b in ipairs(e.behavior) do
        if b == flag then return true end
    end
    return false
end

---True if the ability has a manual cast (i.e. it is not purely passive).
---@param name string
---@return boolean
function AbilityData.IsActive(name)
    local e = ABILITIES[name]
    return e ~= nil and e.active == true
end

---Per-level array indexing. A scalar value is returned unchanged; a table
---is treated as a per-level array and indexed by `level` (1-based, clamped
---to [1, #array]). `level` defaults to 1.
---@param v any
---@param level integer|nil
---@return any
function AbilityData.AtLevel(v, level)
    if type(v) ~= "table" then return v end
    local n = #v
    if n == 0 then return nil end
    local i = level or 1
    if i < 1 then i = 1 elseif i > n then i = n end
    return v[i]
end

local AtLevel = AbilityData.AtLevel

local function field_at(name, field, level)
    local e = ABILITIES[name]
    if not e then return nil end
    return AtLevel(e[field], level)
end

---Base ability damage at the given level (1-based). Excludes talent / facet
---/ Aghanim bonuses - use the live API when a handle is available.
---@param name string
---@param level integer|nil
---@return number|nil
function AbilityData.Damage(name, level)
    return field_at(name, "damage", level)
end

---Base cooldown (seconds) at the given level.
---@param name string
---@param level integer|nil
---@return number|nil
function AbilityData.Cooldown(name, level)
    return field_at(name, "cooldown", level)
end

---Cast point (seconds) at the given level.
---@param name string
---@param level integer|nil
---@return number|nil
function AbilityData.CastPoint(name, level)
    return field_at(name, "cast_point", level)
end

---Cast range (units) at the given level.
---@param name string
---@param level integer|nil
---@return number|nil
function AbilityData.CastRange(name, level)
    return field_at(name, "cast_range", level)
end

---Mana cost at the given level.
---@param name string
---@param level integer|nil
---@return number|nil
function AbilityData.Mana(name, level)
    return field_at(name, "mana", level)
end

---Effect duration (seconds) at the given level.
---@param name string
---@param level integer|nil
---@return number|nil
function AbilityData.Duration(name, level)
    return field_at(name, "duration", level)
end

---Base value of an AbilityValues key at the given level. Returns the value
---unchanged for a non-array key.
---@param name string
---@param key string
---@param level integer|nil
---@return any
function AbilityData.Value(name, key, level)
    local e = ABILITIES[name]
    if not e or not e.values then return nil end
    return AtLevel(e.values[key], level)
end

return AbilityData
'''


def main():
    entries = build()

    out = [HEADER]
    out.append("")
    out.append("-" * 76)
    out.append("-- ABILITIES - generated from npc_abilities.json (%d entries)"
               % len(entries))
    out.append("-" * 76)
    out.append("")
    out.append("---@type table<string, table>")
    out.append("AbilityData.ABILITIES = {")
    for name, body in entries:
        out.append("    %s = %s," % (lua_key(name), body))
    out.append("}")
    out.append(HELPERS)

    text = "\n".join(out)
    with open(os.path.normpath(OUT), "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    print("wrote %s (%d abilities, %d bytes)"
          % (os.path.normpath(OUT), len(entries), len(text)))


if __name__ == "__main__":
    main()
