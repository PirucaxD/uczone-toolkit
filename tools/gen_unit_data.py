#!/usr/bin/env python
# tools/gen_unit_data.py - generate lib/unit_data.lua from the KV data.
#
# Reads C:\Umbrella\assets\data\npc_units.json and emits lib/unit_data.lua -
# a pure-data Lua module (no API calls, no callbacks; same shape as
# lib/threat_data.lua / lib/item_data.lua / lib/ability_data.lua).
#
# Re-run after a Dota patch refreshes the KV file:
#   python tools/gen_unit_data.py
#
# The helper functions live in this generator (the HELPERS literal below) -
# this file is the single source of truth for lib/unit_data.lua.

import json
import os
import re

import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kv_paths

KV_DIR = kv_paths.resolve()
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "lib", "unit_data.lua")

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

ATTACK_CAP = {
    "DOTA_UNIT_CAP_MELEE_ATTACK": "melee",
    "DOTA_UNIT_CAP_RANGED_ATTACK": "ranged",
    "DOTA_UNIT_CAP_NO_ATTACK": "none",
}
MOVE_CAP = {
    "DOTA_UNIT_CAP_MOVE_GROUND": "ground",
    "DOTA_UNIT_CAP_MOVE_FLY": "fly",
    "DOTA_UNIT_CAP_MOVE_NONE": "none",
}


def strip_lower(s, prefix):
    return str(s).replace(prefix, "").lower()


def build():
    raw = json.load(open(os.path.join(KV_DIR, "npc_units.json")))["DOTAUnits"]
    units = {k: v for k, v in raw.items() if isinstance(v, dict)}

    entries = []
    for name in sorted(units.keys()):
        v = units[name]
        f = []

        if v.get("BaseClass"):
            f.append(("base_class", v["BaseClass"]))
        f.append(("level", num(v.get("Level"))))
        f.append(("health", num(v.get("StatusHealth"))))
        f.append(("health_regen", num(v.get("StatusHealthRegen"))))
        f.append(("mana", num(v.get("StatusMana"))))
        f.append(("mana_regen", num(v.get("StatusManaRegen"))))
        f.append(("armor", num(v.get("ArmorPhysical"))))
        f.append(("magic_resist", num(v.get("MagicalResistance"))))

        cap = v.get("AttackCapabilities", "")
        if cap in ATTACK_CAP:
            f.append(("attack_type", ATTACK_CAP[cap]))
        f.append(("attack_min", num(v.get("AttackDamageMin"))))
        f.append(("attack_max", num(v.get("AttackDamageMax"))))
        f.append(("attack_rate", num(v.get("AttackRate"))))
        f.append(("attack_range", num(v.get("AttackRange"))))
        f.append(("attack_point", num(v.get("AttackAnimationPoint"))))
        f.append(("acquisition_range", num(v.get("AttackAcquisitionRange"))))
        if v.get("AttackDamageType"):
            f.append(("damage_type",
                      strip_lower(v["AttackDamageType"], "DAMAGE_TYPE_")))
        f.append(("projectile_speed", num(v.get("ProjectileSpeed"))))

        mc = v.get("MovementCapabilities", "")
        if mc in MOVE_CAP:
            f.append(("move_type", MOVE_CAP[mc]))
        f.append(("move_speed", num(v.get("MovementSpeed"))))
        f.append(("turn_rate", num(v.get("MovementTurnRate"))))
        f.append(("vision_day", num(v.get("VisionDaytimeRange"))))
        f.append(("vision_night", num(v.get("VisionNighttimeRange"))))

        f.append(("bounty_gold_min", num(v.get("BountyGoldMin"))))
        f.append(("bounty_gold_max", num(v.get("BountyGoldMax"))))
        f.append(("bounty_xp", num(v.get("BountyXP"))))

        if v.get("TeamName"):
            f.append(("team", strip_lower(v["TeamName"], "DOTA_TEAM_")))
        if v.get("UnitRelationshipClass"):
            f.append(("relationship",
                      strip_lower(v["UnitRelationshipClass"],
                                  "DOTA_NPC_UNIT_RELATIONSHIP_TYPE_")))
        if v.get("BoundsHullName"):
            f.append(("bounds_hull",
                      strip_lower(v["BoundsHullName"], "DOTA_HULL_SIZE_")))
        f.append(("ring_radius", num(v.get("RingRadius"))))

        # abilities: Ability1..Ability30, drop empties and talent slots
        abilities = []
        for i in range(1, 31):
            a = v.get("Ability%d" % i, "")
            a = (a or "").strip()
            if a and not a.startswith("special_bonus"):
                abilities.append(a)
        if abilities:
            f.append(("abilities", abilities))

        # boolean flags
        for kv_key, field in (("IsSummoned", "summoned"),
                              ("IsAncient", "ancient"),
                              ("IsNeutralUnitType", "neutral"),
                              ("ConsideredHero", "considered_hero"),
                              ("HasInventory", "has_inventory"),
                              ("IsRoshan", "roshan")):
            if v.get(kv_key) == "1":
                f.append((field, True))

        entries.append((name, emit_entry(f)))

    return entries


# ---------------------------------------------------------------------------
# static sections
# ---------------------------------------------------------------------------

HEADER = '''---@meta
---lib/unit_data.lua - static non-hero unit reference, generated from the KV
---data.
---
---Data-only Tier 2 module (no API calls, no callbacks, no side effects -
---same discipline as lib/threat_data.lua / lib/item_data.lua /
---lib/ability_data.lua). GENERATED by tools/gen_unit_data.py from
---C:\\\\Umbrella\\\\assets\\\\data\\\\npc_units.json. Do NOT hand-edit the UNITS table -
---re-run the generator after a patch. The helpers below live in the
---generator (edit them there).
---
---Covers lane / neutral creeps, summons, wards, buildings and Roshan -
---everything that is a unit but not a hero. Useful for last-hit / clear
---logic, and for summon-vs-illusion awareness (an illusion is a copy of a
---hero and is NOT in this table; a controllable unit IS - a true summon
---such as a Furion treant, Warlock golem, forged spirit or necronomicon
---unit carries `summoned = true`, whereas a hero-grade pet such as the
---Lone Druid Spirit Bear is flagged `considered_hero = true` instead - the
---KV data does not tag the bear `IsSummoned`).
---
---Owns:
---  - UNITS   unit name -> { base_class, level, health, health_regen, mana,
---            mana_regen, armor, magic_resist, attack_type, attack_min /
---            attack_max, attack_rate, attack_range, attack_point,
---            acquisition_range, damage_type, projectile_speed, move_type,
---            move_speed, turn_rate, vision_day / vision_night,
---            bounty_gold_min / bounty_gold_max, bounty_xp, team,
---            relationship, bounds_hull, ring_radius, abilities, and the
---            flags summoned / ancient / neutral / considered_hero /
---            has_inventory / roshan }
---  - Get / HasAbility / IsSummon / IsAncient / IsNeutral / IsWard /
---    IsBuilding / AvgAttackDamage   (pure helpers)
---
---Field notes:
---  attack_type   - melee / ranged / none.
---  move_type     - ground / fly / none.
---  relationship  - default / ward / building / barracks / siege / tower.
---  abilities     - real ability names; special_bonus_* talent slots are
---                  dropped.
---  flags         - present (true) only when set; absent otherwise.
---
---Usage in a hero script:
---```lua
---local UD = require("lib.unit_data")
---if UD.IsSummon(unit_name) then ... end           -- a real summon
---local hp  = (UD.Get(unit_name) or {}).health
---local dmg = UD.AvgAttackDamage("npc_dota_creep_badguys_melee")  -- 21
---```

local UnitData = {}
'''

HELPERS = '''
----------------------------------------------------------------------------
-- helpers - pure, no API calls
----------------------------------------------------------------------------

local UNITS = UnitData.UNITS

local BUILDING_REL = {
    building = true, barracks = true, siege = true, tower = true,
}

---Raw unit entry, or nil.
---@param name string
---@return table|nil
function UnitData.Get(name)
    return UNITS[name]
end

---True if the unit has the named ability in one of its ability slots.
---@param name string
---@param ability string
---@return boolean
function UnitData.HasAbility(name, ability)
    local e = UNITS[name]
    if not e or not e.abilities then return false end
    for _, a in ipairs(e.abilities) do
        if a == ability then return true end
    end
    return false
end

---True if the unit is a real summon (Spirit Bear, golem, necronomicon
---units, ...). Illusions are hero copies and are not in this table.
---@param name string
---@return boolean
function UnitData.IsSummon(name)
    local e = UNITS[name]
    return e ~= nil and e.summoned == true
end

---True if the unit is an Ancient creep / unit.
---@param name string
---@return boolean
function UnitData.IsAncient(name)
    local e = UNITS[name]
    return e ~= nil and e.ancient == true
end

---True if the unit is a neutral-type unit.
---@param name string
---@return boolean
function UnitData.IsNeutral(name)
    local e = UNITS[name]
    return e ~= nil and e.neutral == true
end

---True if the unit is a ward (observer / sentry / ability ward).
---@param name string
---@return boolean
function UnitData.IsWard(name)
    local e = UNITS[name]
    return e ~= nil and e.relationship == "ward"
end

---True if the unit is a building (tower / barracks / siege / generic
---building).
---@param name string
---@return boolean
function UnitData.IsBuilding(name)
    local e = UNITS[name]
    return e ~= nil and e.relationship ~= nil
        and BUILDING_REL[e.relationship] == true
end

---Mean attack damage = (attack_min + attack_max) / 2. Returns 0 for a unit
---with no attack data.
---@param name string
---@return number
function UnitData.AvgAttackDamage(name)
    local e = UNITS[name]
    if not e or not e.attack_min or not e.attack_max then return 0 end
    return (e.attack_min + e.attack_max) / 2
end

return UnitData
'''


def main():
    entries = build()

    out = [HEADER]
    out.append("")
    out.append("-" * 76)
    out.append("-- UNITS - generated from npc_units.json (%d entries)"
               % len(entries))
    out.append("-" * 76)
    out.append("")
    out.append("---@type table<string, table>")
    out.append("UnitData.UNITS = {")
    for name, body in entries:
        out.append("    %s = %s," % (lua_key(name), body))
    out.append("}")
    out.append(HELPERS)

    text = "\n".join(out)
    with open(os.path.normpath(OUT), "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    print("wrote %s (%d units, %d bytes)"
          % (os.path.normpath(OUT), len(entries), len(text)))


if __name__ == "__main__":
    main()
