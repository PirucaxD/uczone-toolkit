-- example_brain.lua - a tiny worked example of wiring the toolkit together.
--
-- This is NOT a finished hero brain. It is a skeleton that shows the shape:
-- how you require the libs, wire the event ones once at setup, build a menu,
-- and make a small decision each frame. Read it top to bottom, then go build
-- the real thing.
--
-- It is deliberately generic - no specific hero. Drop in your own ability
-- handles and combat logic where the comments point.

----------------------------------------------------------------------------
-- 1. require what we need
----------------------------------------------------------------------------

local Order   = require("lib.order")
local Damage  = require("lib.damage")
local Anim    = require("lib.anim")
local Target  = require("lib.target")
local geo     = require("lib.geometry")
local predict = require("lib.prediction")
local menu    = require("lib.menu")
local log     = require("lib.log").tag("example")

----------------------------------------------------------------------------
-- 2. menu - create the config widgets once
----------------------------------------------------------------------------

local cfg = menu.panel("Heroes", "Hero List", "Example", "Brain", "Core")
cfg:switch("Enable", true)
cfg:slider("Engage range", 200, 1200, 700, "%d")
cfg:bind("Combo key")

----------------------------------------------------------------------------
-- 3. the event-driven libs each take a one-time Wire() at setup
----------------------------------------------------------------------------

-- `callbacks` is the table of framework event handlers. The event libs chain
-- their own handlers into it, so you only manage your own logic below.
local callbacks = {}

Order.Wire(callbacks)    -- order dedup + arbitration
Damage.Wire(callbacks)   -- the recent-damage feed

-- anim: tell it what to watch, then subscribe to a role
Anim.Wire(callbacks)
Anim.Subscribe("hard_disable", function(ev)
    if ev.target_self then
        log.info("incoming disable from", ev.ability_name, "- react here")
    end
end)

----------------------------------------------------------------------------
-- 4. helpers
----------------------------------------------------------------------------

-- the lowest-HP enemy hero within `range`, or nil
local function pick_target(me, range)
    local best, best_hp = nil, math.huge
    for _, e in ipairs(Heroes.GetAll()) do
        if Target.IsEnemyHero(e, me) and Target.IsAlive(e)
           and Target.NotClone(e) and Target.IsVisible(e)
           and geo.within(me, e, range) then
            local hp = Entity.GetHealth(e)
            if hp < best_hp then best, best_hp = e, hp end
        end
    end
    return best
end

----------------------------------------------------------------------------
-- 5. per-frame logic
----------------------------------------------------------------------------

-- Note we APPEND to callbacks.OnUpdateEx: the event libs already put their
-- handlers there via Wire(), so we chain ours after instead of overwriting.
local prev_update = callbacks.OnUpdateEx
callbacks.OnUpdateEx = function()
    if prev_update then prev_update() end

    if not cfg:get("Enable") then return end

    local me = Heroes.GetLocal()
    if not me or not Entity.IsAlive(me) then return end

    local range  = cfg:get("Engage range")
    local target = pick_target(me, range)
    if not target then return end

    -- example: is the target low enough that a 600-magical-damage nuke kills?
    local kills = Damage.Kills(target, { magical = 600 })
    if kills then
        log.throttled("kill", 0.5, log.INFO,
            "nuke would kill", Entity.GetHealth(target), "HP target")
    end

    -- example: where to aim a projectile (speed 1200, 0.3s cast point) so it
    -- connects with the moving target
    local aim = predict.intercept(me, target, 1200, { cast_delay = 0.3 })
    if aim and cfg:down("Combo key") then
        -- Order.Issue(... order_type CAST_POSITION, position = aim ...)
        log.debug("combo key down - would cast at the predicted point")
    end
end

----------------------------------------------------------------------------
-- 6. hand the wired callbacks table back to whatever loads this script
----------------------------------------------------------------------------

return callbacks
