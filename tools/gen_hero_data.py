#!/usr/bin/env python
# tools/gen_hero_data.py - generate lib/hero_data.lua from the KV data.
#
# Reads C:\Umbrella\assets\data\npc_heroes.json and emits lib/hero_data.lua -
# a pure-data Lua module (no API calls, no callbacks; same shape as
# lib/item_data.lua / lib/ability_data.lua / lib/unit_data.lua).
#
# Re-run after a Dota patch refreshes the KV file:
#   python tools/gen_hero_data.py
#
# The helper functions live in this generator (the HELPERS literal below) -
# this file is the single source of truth for lib/hero_data.lua.

import json
import os
import re

import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kv_paths

KV_DIR = kv_paths.resolve()
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "lib", "hero_data.lua")

IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
LUA_KEYWORDS = {
    "and", "break", "do", "else", "elseif", "end", "false", "for",
    "function", "goto", "if", "in", "local", "nil", "not", "or",
    "repeat", "return", "then", "true", "until", "while",
}


def as_number(s):
    try:
        f = float(s)
    except (TypeError, ValueError):
        return None
    if f.is_integer():
        return int(f)
    return f


def num(v):
    """Numeric coercion; None for an empty / non-numeric string."""
    if isinstance(v, (int, float)):
        return v
    if v is None:
        return None
    s = str(v).strip()
    if not s:
        return None
    return as_number(s)


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


ATTACK_CAP = {
    "DOTA_UNIT_CAP_MELEE_ATTACK": "melee",
    "DOTA_UNIT_CAP_RANGED_ATTACK": "ranged",
}
PRIMARY_ATTR = {
    "DOTA_ATTRIBUTE_STRENGTH": "str",
    "DOTA_ATTRIBUTE_AGILITY": "agi",
    "DOTA_ATTRIBUTE_INTELLECT": "int",
    "DOTA_ATTRIBUTE_ALL": "all",
}


def build():
    raw = json.load(open(os.path.join(KV_DIR, "npc_heroes.json")))["DOTAHeroes"]
    heroes = {k: v for k, v in raw.items()
              if isinstance(v, dict) and k.startswith("npc_dota_hero_")
              and "HeroID" in v}

    entries = []
    for name in sorted(heroes.keys()):
        v = heroes[name]
        f = []
        f.append(("id", as_number(v.get("HeroID"))))
        if v.get("Role"):
            f.append(("role", v["Role"]))
        f.append(("complexity", num(v.get("Complexity"))))

        # kit abilities (Ability1..9) and talents (Ability10..30)
        abilities, talents = [], []
        for i in range(1, 31):
            a = (v.get("Ability%d" % i) or "").strip()
            if not a:
                continue
            if a.startswith("special_bonus"):
                talents.append(a)
            else:
                abilities.append(a)
        if abilities:
            f.append(("abilities", abilities))
        if talents:
            f.append(("talents", talents))

        facets = v.get("Facets")
        if isinstance(facets, dict) and facets:
            f.append(("facets", sorted(facets.keys())))

        cap = v.get("AttackCapabilities", "")
        if cap in ATTACK_CAP:
            f.append(("attack_type", ATTACK_CAP[cap]))
        f.append(("attack_min", num(v.get("AttackDamageMin"))))
        f.append(("attack_max", num(v.get("AttackDamageMax"))))
        f.append(("attack_rate", num(v.get("AttackRate"))))
        f.append(("attack_point", num(v.get("AttackAnimationPoint"))))
        f.append(("attack_range", num(v.get("AttackRange"))))
        f.append(("acquisition_range", num(v.get("AttackAcquisitionRange"))))
        f.append(("projectile_speed", num(v.get("ProjectileSpeed"))))
        f.append(("armor", num(v.get("ArmorPhysical"))))

        if v.get("AttributePrimary") in PRIMARY_ATTR:
            f.append(("primary_attribute", PRIMARY_ATTR[v["AttributePrimary"]]))
        f.append(("str_base", num(v.get("AttributeBaseStrength"))))
        f.append(("str_gain", num(v.get("AttributeStrengthGain"))))
        f.append(("agi_base", num(v.get("AttributeBaseAgility"))))
        f.append(("agi_gain", num(v.get("AttributeAgilityGain"))))
        f.append(("int_base", num(v.get("AttributeBaseIntelligence"))))
        f.append(("int_gain", num(v.get("AttributeIntelligenceGain"))))

        f.append(("move_speed", num(v.get("MovementSpeed"))))
        f.append(("turn_rate", num(v.get("MovementTurnRate"))))
        f.append(("vision_day", num(v.get("VisionDaytimeRange"))))
        f.append(("vision_night", num(v.get("VisionNighttimeRange"))))

        entries.append((name, emit_entry(f)))

    return entries


HEADER = '''---@meta
---lib/hero_data.lua - static hero reference, generated from the KV data.
---
---Data-only Tier 2 module (no API calls, no callbacks, no side effects -
---same discipline as lib/item_data.lua / lib/ability_data.lua /
---lib/unit_data.lua). GENERATED by tools/gen_hero_data.py from
---C:\\\\Umbrella\\\\assets\\\\data\\\\npc_heroes.json. Do NOT hand-edit the HEROES
---table - re-run the generator after a patch. The helpers below live in the
---generator (edit them there).
---
---This completes the KV-data lib set: item / ability / unit / hero.
---
---Owns:
---  - HEROES   hero name -> { id, role, complexity, abilities, talents,
---             facets, attack_type, attack_min / attack_max, attack_rate,
---             attack_point, attack_range, acquisition_range,
---             projectile_speed, armor, primary_attribute, str_base /
---             str_gain / agi_base / agi_gain / int_base / int_gain,
---             move_speed, turn_rate, vision_day / vision_night }
---  - Get / HasAbility / Talents / Facets / PrimaryAttribute /
---    AttributeAt / AvgAttackDamage   (pure helpers)
---
---Field notes:
---  Keys are full unit names, e.g. `npc_dota_hero_sniper`.
---  All stats are the hero's BASE values (level 1, no items, no talents).
---  attack_min / attack_max are the white base damage BEFORE the primary
---  attribute is added; the live API (`NPC.GetTrueDamage`) is authoritative
---  for the in-game number. armor is base armor before the agility bonus.
---  Health and mana are intentionally absent: they are derived from
---  strength / intelligence by per-patch constants - read them live, or
---  compute from `str_base`/`int_base` with the current patch's multipliers.
---
---Usage in a hero script:
---```lua
---local HD = require("lib.hero_data")
---local h = HD.Get("npc_dota_hero_sniper")
---local agi_at_25 = HD.AttributeAt("npc_dota_hero_sniper", "agi", 25)
---if HD.PrimaryAttribute(enemy_name) == "int" then ... end
---```

local HeroData = {}
'''

HELPERS = '''
----------------------------------------------------------------------------
-- helpers - pure, no API calls
----------------------------------------------------------------------------

local HEROES = HeroData.HEROES

---Raw hero entry, or nil.
---@param name string  full unit name, e.g. "npc_dota_hero_sniper"
---@return table|nil
function HeroData.Get(name)
    return HEROES[name]
end

---True if the hero has the named ability in its base kit (talents excluded).
---@param name string
---@param ability string
---@return boolean
function HeroData.HasAbility(name, ability)
    local e = HEROES[name]
    if not e or not e.abilities then return false end
    for _, a in ipairs(e.abilities) do
        if a == ability then return true end
    end
    return false
end

---The hero's talent ability names (the level 10/15/20/25 choices), or {}.
---@param name string
---@return string[]
function HeroData.Talents(name)
    local e = HEROES[name]
    return (e and e.talents) or {}
end

---The hero's facet names, or {}.
---@param name string
---@return string[]
function HeroData.Facets(name)
    local e = HEROES[name]
    return (e and e.facets) or {}
end

---Primary attribute: "str" / "agi" / "int" / "all", or nil.
---@param name string
---@return string|nil
function HeroData.PrimaryAttribute(name)
    local e = HEROES[name]
    return e and e.primary_attribute or nil
end

---A hero attribute at a given level: base + gain * (level - 1).
---attr is "str", "agi" or "int". level defaults to 1. Returns nil if the
---hero or the attribute data is missing.
---@param name string
---@param attr string
---@param level integer|nil
---@return number|nil
function HeroData.AttributeAt(name, attr, level)
    local e = HEROES[name]
    if not e then return nil end
    local base = e[attr .. "_base"]
    local gain = e[attr .. "_gain"]
    if base == nil then return nil end
    local lvl = level or 1
    if lvl < 1 then lvl = 1 end
    return base + (gain or 0) * (lvl - 1)
end

---Mean BASE attack damage = (attack_min + attack_max) / 2. This is the white
---damage before the primary attribute is added; for the live in-game number
---use NPC.GetTrueDamage. Returns 0 if the hero has no attack data.
---@param name string
---@return number
function HeroData.AvgAttackDamage(name)
    local e = HEROES[name]
    if not e or not e.attack_min or not e.attack_max then return 0 end
    return (e.attack_min + e.attack_max) / 2
end

return HeroData
'''


def main():
    entries = build()
    out = [HEADER]
    out.append("")
    out.append("-" * 76)
    out.append("-- HEROES - generated from npc_heroes.json (%d heroes)"
               % len(entries))
    out.append("-" * 76)
    out.append("")
    out.append("---@type table<string, table>")
    out.append("HeroData.HEROES = {")
    for name, body in entries:
        out.append("    %s = %s," % (lua_key(name), body))
    out.append("}")
    out.append(HELPERS)

    text = "\n".join(out)
    with open(os.path.normpath(OUT), "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    print("wrote %s (%d heroes, %d bytes)"
          % (os.path.normpath(OUT), len(entries), len(text)))


if __name__ == "__main__":
    main()
