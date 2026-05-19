---@meta
---lib/prediction.lua - projectile-intercept solver.
---
---The hard part of landing any non-instant spell: by the time your
---projectile arrives, the target has moved. This module answers "where do
---I aim so the projectile and the target meet?".
---
---Two cases, two functions:
---  - `lead`      - the target keeps a roughly constant velocity and your
---                  spell takes a known, fixed time to land (a ground zone
---                  with a fixed wind-up, a fixed-duration channel). The
---                  intercept is just `position + velocity * time`.
---  - `intercept` - the spell is a projectile with a SPEED, so the flight
---                  time depends on how far the aim point ends up being.
---                  That is circular, so it is solved as a quadratic.
---
---Velocity is read from the engine's real velocity vector
---(`m_vecVelocity`), not the move-speed stat - a unit standing still has a
---non-zero move-speed stat but zero velocity, and a unit's facing is not
---always its travel direction. If you smooth velocity yourself (e.g. over
---a few frames), pass it in via `opts.velocity` and it is used as-is.
---
---Side-effect free. Positions accept an entity or a Vector.

local Prediction = {}

local sqrt = math.sqrt

----------------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------------

local function pos(e)
    if e == nil then return nil end
    if Entity and Entity.IsEntity and Entity.IsEntity(e) then
        return Entity.GetAbsOrigin(e)
    end
    local ok, x = pcall(function() return e.x end)
    if ok and x ~= nil then return e end
    return nil
end

---The target's current velocity Vector (units/second). Reads the engine
---field `m_vecVelocity`; returns a zero Vector when it cannot be read or
---the target is standing still.
---@param target userdata|nil
---@return userdata  Vector
function Prediction.velocity(target)
    if target and Entity and Entity.GetField then
        local ok, v = pcall(Entity.GetField, target, "m_vecVelocity")
        if ok and v then
            local okx = pcall(function() return v.x end)
            if okx and v.x then return v end
        end
    end
    return Vector(0, 0, 0)
end

----------------------------------------------------------------------------
-- linear lead
----------------------------------------------------------------------------

---Where the target will be `time_s` seconds from now, assuming it holds
---its current velocity. Use this for a spell whose travel/wind-up time is
---fixed and known. Returns the target's current position when it is not
---moving, and nil when the target is invalid.
---
---`opts.velocity` overrides the measured velocity (pass your own smoothed
---value here if you track one).
---@param target userdata|nil
---@param time_s number
---@param opts table|nil   { velocity?: Vector }
---@return userdata|nil    predicted Vector
function Prediction.lead(target, time_s, opts)
    local p = pos(target)
    if not p then return nil end
    local v = (opts and opts.velocity) or Prediction.velocity(target)
    return Vector(p.x + (v.x or 0) * time_s,
                  p.y + (v.y or 0) * time_s,
                  p.z)
end

----------------------------------------------------------------------------
-- projectile intercept
----------------------------------------------------------------------------

---Solve for the aim point of a projectile.
---
---Given a launch point, a moving target and the projectile's `speed`, find
---the spot to aim at so the projectile meets the target. Because the
---flight time depends on the (unknown) aim point, this is a quadratic in
---time; the earliest valid solution is returned.
---
---`opts`:
---  - `cast_delay`  seconds between "now" and the projectile actually
---                  launching (cast point + activation). The target keeps
---                  moving during the delay. Default 0.
---  - `velocity`    override the measured target velocity with your own.
---  - `target_pos`  override the target's current position.
---
---Returns the aim Vector and the total time-to-hit (seconds, measured from
---now). Returns nil when there is no solution - the target is moving away
---faster than the projectile can catch it.
---@param launch userdata|nil   launch point (entity or Vector)
---@param target userdata|nil   the moving target
---@param speed number          projectile speed, units/second
---@param opts table|nil
---@return userdata|nil aim_point, number|nil time_to_hit
function Prediction.intercept(launch, target, speed, opts)
    opts = opts or {}
    local c = pos(launch)
    local t0 = opts.target_pos or pos(target)
    if not c or not t0 or not speed or speed <= 0 then return nil end

    local delay = opts.cast_delay or 0
    local v = opts.velocity or Prediction.velocity(target)
    local vx, vy = v.x or 0, v.y or 0

    -- Relative start: P = target - launch. We want a total time t such that
    -- the target's position at t is exactly `speed * (t - delay)` away from
    -- the launch point.  |P + V*t|^2 = speed^2 * (t - delay)^2
    -- expands to a*t^2 + b*t + cc = 0:
    local px, py = t0.x - c.x, t0.y - c.y
    local s2 = speed * speed
    local a  = (vx * vx + vy * vy) - s2
    local b  = 2 * (px * vx + py * vy) + 2 * s2 * delay
    local cc = (px * px + py * py) - s2 * delay * delay

    local t
    if a > -1e-6 and a < 1e-6 then
        -- target speed ~= projectile speed: equation is linear in t
        if b > -1e-6 and b < 1e-6 then return nil end
        t = -cc / b
    else
        local disc = b * b - 4 * a * cc
        if disc < 0 then return nil end             -- never catches up
        local r = sqrt(disc)
        local t1 = (-b + r) / (2 * a)
        local t2 = (-b - r) / (2 * a)
        -- earliest time that is at/after the launch delay
        if t1 > t2 then t1, t2 = t2, t1 end
        if t1 >= delay then t = t1
        elseif t2 >= delay then t = t2
        else return nil end
    end
    if not t or t < delay then return nil end

    local aim = Vector(t0.x + vx * t, t0.y + vy * t, t0.z)
    return aim, t
end

---Plain flight time of a projectile to a FIXED point: `cast_delay`
---plus distance / speed. (For a moving target, use `intercept`.)
---@param launch userdata|nil
---@param point userdata|nil
---@param speed number
---@param cast_delay number|nil
---@return number|nil seconds
function Prediction.travel_time(launch, point, speed, cast_delay)
    local c, p = pos(launch), pos(point)
    if not c or not p or not speed or speed <= 0 then return nil end
    local dx, dy = p.x - c.x, p.y - c.y
    return (cast_delay or 0) + sqrt(dx * dx + dy * dy) / speed
end

return Prediction
