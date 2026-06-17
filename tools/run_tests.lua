#!/usr/bin/env lua
-- tools/run_tests.lua - pure-Lua test runner for the toolkit's lib helpers.
--
-- Runs unit tests on the lib/ modules that are pure enough to exercise
-- without a running game. The game-side API is stubbed at the top, so this
-- runs in a plain Lua interpreter.
--
-- Run it from the repo root:   lua tools/run_tests.lua

----------------------------------------------------------------------------
-- API STUBS - minimal stand-ins so the libs load without a running game
----------------------------------------------------------------------------

-- Vector stub carrying the native methods the libs delegate to
local VEC = {}
VEC.__index = VEC
function VEC:Distance2D(o)    local dx, dy = self.x-o.x, self.y-o.y return math.sqrt(dx*dx + dy*dy) end
function VEC:DistanceSqr2D(o) local dx, dy = self.x-o.x, self.y-o.y return dx*dx + dy*dy end
function VEC:IsInRange2D(o, r) return self:DistanceSqr2D(o) <= r*r end
function VEC:Lerp(b, t)       return Vector(self.x+(b.x-self.x)*t, self.y+(b.y-self.y)*t, self.z+(b.z-self.z)*t) end
function VEC:Extrapolate(d, s) return Vector(self.x + d.x*s, self.y + d.y*s, self.z) end
function VEC:AngleBetween2D(mid, p3)
    local a1x, a1y = self.x-mid.x, self.y-mid.y
    local a2x, a2y = p3.x-mid.x, p3.y-mid.y
    local l1 = math.sqrt(a1x*a1x + a1y*a1y)
    local l2 = math.sqrt(a2x*a2x + a2y*a2y)
    if l1 < 1e-9 or l2 < 1e-9 then return 0 end
    local d = (a1x*a2x + a1y*a2y) / (l1*l2)
    if d > 1 then d = 1 elseif d < -1 then d = -1 end
    return math.acos(d)
end
function Vector(x, y, z)
    return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, VEC)
end

NPC = NPC or {}
NPC.IsIllusion        = function() return false end
NPC.IsMeepoClone      = function() return false end
NPC.HasModifier       = function() return false end
NPC.HasState          = function() return false end
NPC.GetItem           = function() return nil end
NPC.GetMana           = function() return 100 end
NPC.GetStatesDuration = function() return 0 end
NPC.IsRunning         = function() return false end
NPC.IsAttacking       = function() return false end
NPC.GetAttackRange    = function() return 550 end
NPC.FindRotationAngle = function() return 0 end

Entity = Entity or {}
Entity.IsNPC        = function() return true end
Entity.IsAlive      = function() return true end
Entity.IsSameTeam   = function() return false end
Entity.IsEntity     = function(e) return type(e) == "table" and e.is_entity == true end
Entity.GetIndex     = function(e) return e and e.idx or 0 end
Entity.GetAbsOrigin = function(e) return e and e.pos or Vector(0, 0, 0) end
Entity.GetHealth    = function() return 1000 end
Entity.GetMaxHealth = function() return 1000 end

Ability = Ability or {}
Ability.IsReady     = function() return false end
Ability.GetCooldown = function() return 999 end
Ability.GetManaCost = function() return 0 end
Ability.GetLevel    = function() return 0 end

Hero = Hero or {}
Hero.GetLastVisibleTime = function() return nil end

GlobalVars = GlobalVars or {}
GlobalVars.GetCurTime = function() return 0 end

Enum = Enum or {}
Enum.ModifierState = setmetatable({}, { __index = function(_, k) return k end })
Enum.TeamType      = setmetatable({}, { __index = function(_, k) return k end })

-- Logger stub: the native leveled logger that lib/log.lua builds on
Logger = Logger or function(name)
    local noop = function() end
    return { _name = name, debug = noop, info = noop, warning = noop,
             error = noop, set_level = noop, get_level = function() return 1 end }
end

-- a tiny CMenuGroup stand-in for the menu lib
local function stub_menu_group()
    local g = { _w = {} }
    local function mk(name) local w = { _name = name,
        Get = function() return 0 end, IsDown = function() return false end,
        IsPressed = function() return false end, IsToggled = function() return false end }
        g._w[name] = w; return w end
    function g:Find(name) return self._w[name] end
    function g:Switch(name) return mk(name) end
    function g:Slider(name) return mk(name) end
    function g:Bind(name) return mk(name) end
    function g:Combo(name) return mk(name) end
    function g:Button(name) return mk(name) end
    function g:Label(text) return mk(text) end
    return g
end
Menu = Menu or { Create = function() return stub_menu_group() end }

-- let `require("lib.x")` resolve from the repo root
package.path = "./?.lua;./?/init.lua;" .. package.path

----------------------------------------------------------------------------
-- TEST FRAMEWORK
----------------------------------------------------------------------------

local pass, fail = 0, 0
local fails = {}
local function it(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1; print("  pass  " .. name)
    else fail = fail + 1; print("  FAIL  " .. name)
        fails[#fails + 1] = { name = name, err = err } end
end
local function describe(group, fn) print("[" .. group .. "]"); fn() end
local function assert_eq(a, b, msg)
    if a ~= b then error((msg or "expected eq") .. ": got " .. tostring(a)
        .. ", want " .. tostring(b), 2) end
end
local function assert_near(a, b, msg)
    if type(a) ~= "number" or math.abs(a - b) > 1e-6 then
        error((msg or "expected near") .. ": got " .. tostring(a)
            .. ", want " .. tostring(b), 2) end
end
local function assert_true(v, msg) if not v then error(msg or "expected true", 2) end end
local function assert_false(v, msg) if v then error(msg or "expected false", 2) end end

----------------------------------------------------------------------------
-- threat_data
----------------------------------------------------------------------------

local TD = require("lib.threat_data")

describe("threat_data - SAVE_KIND integrity", function()
    it("SAVE_KIND populated", function()
        local n = 0
        for _ in pairs(TD.SAVE_KIND) do n = n + 1 end
        assert_true(n > 10, "fewer than 10 SAVE_KIND entries")
    end)
    it("ESCAPE_ITEM_NAMES derived at load", function()
        assert_true(type(TD.ESCAPE_ITEM_NAMES) == "table", "not a table")
        assert_true(#TD.ESCAPE_ITEM_NAMES > 0, "empty escape list")
    end)
    it("ESCAPE_ITEM_NAMES includes BKB", function()
        local found = false
        for i = 1, #TD.ESCAPE_ITEM_NAMES do
            if TD.ESCAPE_ITEM_NAMES[i] == "item_black_king_bar" then
                found = true; break end
        end
        assert_true(found, "BKB missing from ESCAPE_ITEM_NAMES")
    end)
    it("ESCAPE_ITEM_NAMES holds only item_* names", function()
        for i = 1, #TD.ESCAPE_ITEM_NAMES do
            local s = TD.ESCAPE_ITEM_NAMES[i]
            assert_true(s:sub(1, 5) == "item_", "non-item in escape list: " .. s)
        end
    end)
end)

describe("threat_data - SaveCounters", function()
    it("BKB counters Bane Nightmare (magic_immune)", function()
        assert_true(TD.SaveCounters("item_black_king_bar", "modifier_bane_nightmare"))
    end)
    it("Force Staff does NOT counter Doom", function()
        assert_false(TD.SaveCounters("item_force_staff", "modifier_doom_bringer_doom"))
    end)
    it("Pike counters Pudge hook (displacement_perp)", function()
        assert_true(TD.SaveCounters("item_hurricane_pike", "modifier_pudge_meat_hook"))
    end)
    it("Cyclone does NOT counter Pudge hook in-flight", function()
        assert_false(TD.SaveCounters("item_cyclone", "modifier_pudge_meat_hook"))
    end)
end)

describe("threat_data - SeverityOf", function()
    it("returns low/medium/high for a known threat", function()
        local sev = TD.SeverityOf("modifier_bane_nightmare")
        assert_true(sev == "low" or sev == "medium" or sev == "high",
            "got severity=" .. tostring(sev))
    end)
end)

----------------------------------------------------------------------------
-- target / timing
----------------------------------------------------------------------------

local Target = require("lib.target")

describe("target - pure predicates", function()
    it("NotClone is nil-safe", function() assert_false(Target.NotClone(nil)) end)
end)

local Timing = require("lib.timing")

describe("timing - EscapeReadiness", function()
    it("returns 0 for an entity with no items", function()
        assert_eq(Timing.EscapeReadiness({ idx = 1 }, 2.0), 0)
    end)
end)

----------------------------------------------------------------------------
-- geometry
----------------------------------------------------------------------------

local G = require("lib.geometry")

-- entity stub: Entity.IsEntity checks .is_entity; GetAbsOrigin reads .pos.
local function gent(x, y) return { is_entity = true, idx = 0, pos = Vector(x, y, 0) } end

describe("geometry - distance", function()
    it("dist_between is a 3-4-5 triangle", function()
        assert_eq(G.dist_between(gent(0, 0), gent(300, 400)), 500)
    end)
    it("dist_between is nil-safe (math.huge)", function()
        assert_eq(G.dist_between(nil, gent(0, 0)), math.huge)
        assert_eq(G.dist_between(gent(0, 0), nil), math.huge)
    end)
    it("dist_from_to aliases dist_between", function()
        assert_eq(G.dist_from_to(gent(0, 0), gent(300, 400)), 500)
    end)
end)

describe("geometry - prediction (no lead without motion)", function()
    it("lead_target_pos returns current pos for a non-moving target", function()
        local p = G.lead_target_pos(gent(100, 200), nil, 1.5)
        assert_near(p.x, 100); assert_near(p.y, 200)
    end)
    it("PredictPos returns current pos for an un-sampled target", function()
        local p = G.PredictPos(gent(100, 200), 1.5)
        assert_near(p.x, 100); assert_near(p.y, 200)
    end)
    it("PredictPos is nil for an invalid target", function()
        assert_true(G.PredictPos(nil, 1.0) == nil)
    end)
end)

describe("geometry - smoothed velocity", function()
    it("SampleVelocities feeds PredictPos a real lead", function()
        local clock = 0
        local saved_time   = GlobalVars.GetCurTime
        local saved_radius = Entity.GetHeroesInRadius
        GlobalVars.GetCurTime = function() return clock end
        local mover = gent(0, 0); mover.idx = 77
        Entity.GetHeroesInRadius = function() return { mover } end
        -- two samples 0.1s apart, moving +x at 500 u/s
        clock = 0.0; mover.pos = Vector(0, 0, 0);  G.SampleVelocities(gent(0, 0), 1600)
        clock = 0.1; mover.pos = Vector(50, 0, 0); G.SampleVelocities(gent(0, 0), 1600)
        local p = G.PredictPos(mover, 1.0)         -- 50 (current) + 500*1.0 (lead)
        assert_near(p.x, 550)
        Entity.GetHeroesInRadius = saved_radius
        GlobalVars.GetCurTime    = saved_time
    end)
end)

describe("geometry - AoE / line placement", function()
    it("BestAoeCenter finds the densest cluster", function()
        local units = { gent(0, 0), gent(50, 0), gent(60, 30), gent(1000, 1000) }
        local center, hit = G.BestAoeCenter(units, 250, 0)
        assert_eq(hit, 3, "cluster of 3 within 250")
        assert_true(center ~= nil)
    end)
    it("BestLineAim picks the densest direction", function()
        local units = { gent(200, 0), gent(400, 0), gent(600, 0), gent(0, 400) }
        local aim, hit = G.BestLineAim(units, Vector(0, 0, 0), 110, 1075, 0)
        assert_eq(hit, 3, "expected 3 on the +x line")
        assert_true(aim ~= nil and aim.x > aim.y, "aim should point +x")
    end)
    it("empty inputs are safe", function()
        local c, h1 = G.BestAoeCenter({}, 250, 0)
        assert_true(c == nil and h1 == 0)
        local a, h2 = G.BestLineAim({}, Vector(0, 0, 0), 110, 1075, 0)
        assert_true(a == nil and h2 == 0)
    end)
end)

----------------------------------------------------------------------------
-- prediction
----------------------------------------------------------------------------

local P = require("lib.prediction")

describe("prediction - intercept", function()
    it("hits a stationary target at distance/speed", function()
        local aim, t = P.intercept(Vector(0, 0, 0), Vector(1000, 0, 0), 1000,
                                   { velocity = Vector(0, 0, 0) })
        assert_true(aim ~= nil, "no aim point")
        assert_near(t, 1.0)
    end)
    it("takes longer against a target moving away", function()
        local _, t = P.intercept(Vector(0, 0, 0), Vector(1000, 0, 0), 1000,
                                 { velocity = Vector(500, 0, 0) })
        assert_true(t and t > 1.0, "expected t > 1.0")
    end)
    it("returns nil when the target outruns the projectile", function()
        local aim = P.intercept(Vector(0, 0, 0), Vector(1000, 0, 0), 300,
                                { velocity = Vector(500, 0, 0) })
        assert_true(aim == nil, "expected no solution")
    end)
    it("lead projects along velocity", function()
        local p = P.lead(Vector(0, 0, 0), 2, { velocity = Vector(100, 0, 0) })
        assert_eq(p.x, 200)
    end)
end)

----------------------------------------------------------------------------
-- log
----------------------------------------------------------------------------

local log = require("lib.log")

describe("log - levels", function()
    it("level threshold filters lower levels", function()
        log.set_level(log.WARN)
        assert_eq(log.get_level(), log.WARN)
        log.set_level(log.INFO)            -- restore
    end)
    it("tag returns an independent logger", function()
        local tagged = log.tag("test")
        assert_true(type(tagged.info) == "function", "tagged logger has no info")
    end)
end)

----------------------------------------------------------------------------
-- menu
----------------------------------------------------------------------------

local menu = require("lib.menu")

describe("menu - panel builder", function()
    it("panel returns the same object for the same path", function()
        local a = menu.panel("T", "S", "T2", "T3", "G")
        local b = menu.panel("T", "S", "T2", "T3", "G")
        assert_true(a == b, "panel() should cache by path")
    end)
    it("a widget is created once and reused", function()
        local p = menu.panel("T", "S", "T2", "T3", "G")
        local w1 = p:switch("Enable", true)
        local w2 = p:switch("Enable", true)
        assert_true(w1 == w2, "switch should be idempotent")
    end)
end)

local Farm = require("lib.farm")

describe("lib/farm , pure geometry (v0.5.82)", function()
    local function u(x, y, hp) return { pos = { x = x, y = y, z = 0 }, hp = hp or 100 } end
    local origin = { x = 0, y = 0, z = 0 }

    it("WorthCasting respects min_count", function()
        assert_true(Farm.WorthCasting(3, 3))
        assert_false(Farm.WorthCasting(2, 3))
        assert_true(Farm.WorthCasting(1))
        assert_false(Farm.WorthCasting(0, 1))
    end)

    it("CountInLine counts units inside the line band", function()
        local units = { u(100, 0), u(500, 50), u(500, 300), u(-100, 0), u(1200, 0) }
        local n = Farm.CountInLine(origin, { x = 1, y = 0, z = 0 }, 1000, 100, units)
        assert_eq(n, 2, "expected 2 in-line")
    end)

    it("BestLineAim picks the densest direction", function()
        local units = { u(200, 0), u(400, 0), u(600, 0), u(0, 400) }
        local aim, hit = Farm.BestLineAim(origin, units, 1075, 110)
        assert_eq(hit, 3, "expected 3 hits on the +x line")
        assert_true(aim ~= nil and aim.x > aim.y, "aim should point +x")
    end)

    it("BestLineAim tie-break prefers the closer pack (v0.5.81)", function()
        local near = u(300, 0, 100)
        local far  = u(0, 900, 100)
        local aim, hit = Farm.BestLineAim(origin, { far, near }, 1075, 110)
        assert_eq(hit, 1)
        assert_true(aim.x > aim.y, "tie-break should favor the nearer (+x) unit")
    end)

    it("BestPointAim finds the densest cluster center", function()
        local units = { u(0, 0), u(50, 0), u(60, 30), u(1000, 1000) }
        local center, hit = Farm.BestPointAim(units, 250)
        assert_eq(hit, 3, "cluster of 3 within 250")
        assert_true(center ~= nil)
    end)

    it("empty / degenerate inputs are safe", function()
        local aim, h1 = Farm.BestLineAim(origin, {}, 1000, 100)
        assert_true(aim == nil and h1 == 0)
        local c, h2 = Farm.BestPointAim({}, 250)
        assert_true(c == nil and h2 == 0)
    end)
end)

----------------------------------------------------------------------------
-- REPORT
----------------------------------------------------------------------------

print()
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then
    print()
    for i = 1, #fails do
        print("FAIL: " .. fails[i].name)
        print("  " .. tostring(fails[i].err))
    end
    os.exit(1)
end
os.exit(0)
