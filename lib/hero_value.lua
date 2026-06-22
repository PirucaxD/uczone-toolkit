---@meta
---lib/hero_value.lua: per-hero combat-value model for the FC TF value-arbiter
---(Phase D). HeroValue.of(enemy, peers) = a role base x a live, peer-relative
---fed-ness multiplier.
---
---Role base: DERIVED from lib/hero_data's KV role tag (the PRIMARY/first tag -> a
---value), so all heroes are covered with exact names and it stays patch-stable;
---a small HERO_VALUE_OVERRIDE table hand-corrects tag-vs-position misreads.
---
---Live multiplier: peer-relative TOTAL STATS (str+agi+int), with hero level as
---the fallback. Stats read on visible enemies AND include item bonuses (so a fed
---enemy reads higher), unlike networth which reads nil on enemies (no CPlayer
---owner). All reads are pcall-guarded and degrade to the base, so the module is
---deterministic and offline-testable by stubbing the Hero/NPC globals. Reusable
---across heroes; LOCAL until public-synced (depends on lib/hero_data).

local HeroValue = {}

local HD = require("lib.hero_data")   -- KV-generated hero reference (role tags, stats)

-- KV role TAG -> base value. base() keys on the PRIMARY (first) tag of HD.role.
-- KV tags: Carry, Nuker, Pusher, Initiator, Durable, Disabler, Escape, Support,
-- Jungler. A "Carry" core is ~1.0 (the K.FC_FLIP_VALUE unit); a pure support ~0.45.
HeroValue.TAG_VALUE = {
    Carry     = 1.00,
    Nuker     = 0.80,
    Pusher    = 0.70,
    Initiator = 0.70,
    Durable   = 0.70,
    Disabler  = 0.60,
    Escape    = 0.60,
    Jungler   = 0.50,
    Support   = 0.45,
}
HeroValue.DEFAULT_VALUE = 0.50   -- unknown hero / missing role

-- per-hero overrides where the primary KV tag misreads farm-position value.
-- Outliers only; grows as demos / the user surface misreads.
HeroValue.HERO_VALUE_OVERRIDE = {
    npc_dota_hero_doom_bringer  = 0.70,  -- KV "Carry", but canonically offlane
    npc_dota_hero_earth_spirit  = 0.50,  -- KV "Nuker", but a pos-4 roamer
    npc_dota_hero_bounty_hunter = 0.50,  -- KV "Escape", but a pos-4 roamer
}

local LO, HI = 0.6, 1.6   -- live multiplier clamp (mirror of K.HV_LIVE_LO / K.HV_LIVE_HI)

function HeroValue.base(unit_name)
    if not unit_name then return HeroValue.DEFAULT_VALUE end
    local ov = HeroValue.HERO_VALUE_OVERRIDE[unit_name]
    if ov then return ov end
    local h = HD.HEROES and HD.HEROES[unit_name]
    local role = h and h.role
    if type(role) ~= "string" then return HeroValue.DEFAULT_VALUE end
    local primary = role:match("^(%a+)")
    return (primary and HeroValue.TAG_VALUE[primary]) or HeroValue.DEFAULT_VALUE
end

local function safe_num(fn)
    local ok, v = pcall(fn)
    if ok and type(v) == "number" then return v end
    return nil
end

-- Read total stats (str+agi+int) for a unit, or nil. Item-inclusive and reads on
-- visible enemies; the primary live fed-ness signal.
local function read_stats(u)
    local s = safe_num(function() return Hero.GetStrengthTotal and Hero.GetStrengthTotal(u) end)
    local a = safe_num(function() return Hero.GetAgilityTotal and Hero.GetAgilityTotal(u) end)
    local i = safe_num(function() return Hero.GetIntellectTotal and Hero.GetIntellectTotal(u) end)
    if s and a and i then return s + a + i end
    return nil
end

-- Read hero level for a unit, or nil. The fallback signal when stats are unavailable.
local function read_lvl(u)
    local ok, lvl = pcall(function() return NPC.GetCurrentLevel and NPC.GetCurrentLevel(u) end)
    if ok and type(lvl) == "number" and lvl >= 1 and lvl <= 30 then return lvl end
    return nil
end

-- Read networth for a unit (via its owning player), or nil. NOT used by live_mult
-- (reads nil on enemies); retained for the hero_value_eval diagnostic only.
local function read_nw(u)
    local ok_pw, pw = pcall(function() return NPC.GetPlayerOwner and NPC.GetPlayerOwner(u) end)
    if not (ok_pw and pw) then return nil end
    local ok, tp = pcall(function() return Player.GetTeamPlayer and Player.GetTeamPlayer(pw) end)
    if ok and type(tp) == "table" and type(tp.networth) == "number" and tp.networth > 0 then
        return tp.networth
    end
    return nil
end

-- Peer-relative fed-ness multiplier. Total stats are used if they read for the
-- enemy AND every peer (apples-to-apples ratio); otherwise level for all. The
-- peer set includes the enemy itself (the cluster mean). < 2 samples -> 1.0.
function HeroValue.live_mult(enemy, peers)
    if not (enemy and peers) then return 1.0 end
    local reader = read_stats
    local my_v = read_stats(enemy)
    if my_v then
        for i = 1, #peers do
            if not read_stats(peers[i]) then my_v = nil; break end
        end
    end
    if not my_v then
        reader = read_lvl
        my_v = read_lvl(enemy)
    end
    if not my_v then return 1.0 end
    local sum, n = 0, 0
    for i = 1, #peers do
        local v = reader(peers[i])
        if v then sum = sum + v; n = n + 1 end
    end
    if n < 2 then return 1.0 end
    local mean = sum / n
    if mean <= 0 then return 1.0 end
    local mult = my_v / mean
    if mult < LO then return LO elseif mult > HI then return HI end
    return mult
end

function HeroValue.of(enemy, peers)
    if not enemy then return 0 end
    local name
    local ok = pcall(function() name = NPC.GetUnitName and NPC.GetUnitName(enemy) end)
    if not ok then name = nil end
    return HeroValue.base(name) * HeroValue.live_mult(enemy, peers)
end

-- diagnostics only: the raw reads behind the live multiplier + alternatives, so
-- the hero_value_eval log can show what's driving the scale. debug_reads returns
-- (networth|nil, level|nil); debug_signals returns (max_hp, total_stats,
-- true_max_damage) -- the candidate item-sensitive signals. Any unreadable -> nil.
function HeroValue.debug_reads(u)
    return read_nw(u), read_lvl(u)
end

function HeroValue.debug_signals(u)
    local maxhp = safe_num(function() return Entity.GetMaxHealth and Entity.GetMaxHealth(u) end)
    local stats = read_stats(u)
    local dmg   = safe_num(function() return NPC.GetTrueMaximumDamage and NPC.GetTrueMaximumDamage(u) end)
    return maxhp, stats, dmg
end

return HeroValue
