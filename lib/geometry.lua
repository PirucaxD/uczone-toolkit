---@meta
---lib/geometry.lua - 2D position, distance and direction helpers.
---
---Hero-agnostic and side-effect free. Every function takes entities or
---Vectors explicitly - nothing reads hero state on its own.
---
---Dota is played on a flat plane, so the math here is 2D: the z (height)
---component is carried through positions but ignored for distance and
---angle. Distances are in Hammer units, angles in degrees.
---
---Anything handed a bad value returns a sensible default - math.huge for
---a distance, nil for a point - instead of crashing, so call sites can
---skip the nil-check and just use `... or fallback`.

local Geometry = {}

local sqrt, cos, sin, acos = math.sqrt, math.cos, math.sin, math.acos
local pi = math.pi
local DEG = 180 / pi
local RAD = pi / 180

----------------------------------------------------------------------------
-- position normalization
----------------------------------------------------------------------------

---Resolve an argument to a position Vector. Accepts a live entity (reads
---its origin), a Vector (returned as-is), or nil (returns nil). This is
---what lets every helper below take "an entity or a point" interchangeably.
---@param e userdata|nil  entity or Vector
---@return userdata|nil   Vector, or nil
function Geometry.pos(e)
    if e == nil then return nil end
    if Entity and Entity.IsEntity and Entity.IsEntity(e) then
        return Entity.GetAbsOrigin(e)
    end
    -- assume it is already a Vector; probe a field behind pcall so a
    -- userdata of some other type can't blow up the caller
    local ok, x = pcall(function() return e.x end)
    if ok and x ~= nil then return e end
    return nil
end

----------------------------------------------------------------------------
-- distance
----------------------------------------------------------------------------

---2D distance between two points/entities. math.huge if either is invalid.
---@param a userdata|nil
---@param b userdata|nil
---@return number
function Geometry.dist2d(a, b)
    local pa, pb = Geometry.pos(a), Geometry.pos(b)
    if not pa or not pb then return math.huge end
    local dx, dy = pa.x - pb.x, pa.y - pb.y
    return sqrt(dx * dx + dy * dy)
end

-- Aliases - same function, different mental model at the call site.
Geometry.dist_between = Geometry.dist2d
Geometry.dist_from_to = Geometry.dist2d

---Squared 2D distance - skip the sqrt when you only need to compare two
---distances against each other or against a fixed radius.
---@param a userdata|nil
---@param b userdata|nil
---@return number
function Geometry.dist2d_sqr(a, b)
    local pa, pb = Geometry.pos(a), Geometry.pos(b)
    if not pa or not pb then return math.huge end
    local dx, dy = pa.x - pb.x, pa.y - pb.y
    return dx * dx + dy * dy
end

---True if `b` is within `range` units of `a` (cheap - squared compare).
---@param a userdata|nil
---@param b userdata|nil
---@param range number
---@return boolean
function Geometry.within(a, b, range)
    return Geometry.dist2d_sqr(a, b) <= (range * range)
end

----------------------------------------------------------------------------
-- directions and points
----------------------------------------------------------------------------

---Normalized 2D direction Vector pointing from `from` to `to` (z = 0).
---Returns nil when the two points coincide (no meaningful direction).
---@param from userdata|nil
---@param to userdata|nil
---@return userdata|nil
function Geometry.direction(from, to)
    local pf, pt = Geometry.pos(from), Geometry.pos(to)
    if not pf or not pt then return nil end
    local dx, dy = pt.x - pf.x, pt.y - pf.y
    local len = sqrt(dx * dx + dy * dy)
    if len < 1e-6 then return nil end
    return Vector(dx / len, dy / len, 0)
end

---Midpoint between two points/entities.
---@param a userdata|nil
---@param b userdata|nil
---@return userdata|nil
function Geometry.midpoint(a, b)
    local pa, pb = Geometry.pos(a), Geometry.pos(b)
    if not pa or not pb then return nil end
    return Vector((pa.x + pb.x) * 0.5, (pa.y + pb.y) * 0.5, pa.z)
end

---A point `distance` units past `to`, continuing along the from->to line.
---Negative `distance` pulls back toward `from`. Handy for placing a knock-
---back cast behind a target, or an over-shoot aim point.
---@param from userdata|nil
---@param to userdata|nil
---@param distance number
---@return userdata|nil
function Geometry.extend(from, to, distance)
    local pt = Geometry.pos(to)
    local dir = Geometry.direction(from, to)
    if not pt or not dir then return pt end
    return Vector(pt.x + dir.x * distance,
                  pt.y + dir.y * distance, pt.z)
end

---Clamp `point` so it is at most `max_dist` units from `origin`. If it is
---already within range it is returned unchanged. This is the Blink-Dagger
---rule: an order past the dagger's range lands at the range limit.
---@param origin userdata|nil
---@param point userdata|nil
---@param max_dist number
---@return userdata|nil
function Geometry.clamp_distance(origin, point, max_dist)
    local po, pp = Geometry.pos(origin), Geometry.pos(point)
    if not po or not pp then return pp end
    local dx, dy = pp.x - po.x, pp.y - po.y
    local len = sqrt(dx * dx + dy * dy)
    if len <= max_dist or len < 1e-6 then return pp end
    local s = max_dist / len
    return Vector(po.x + dx * s, po.y + dy * s, pp.z)
end

---Rotate a 2D vector (or the offset of a point from the origin) by
---`degrees`, counter-clockwise. Pass a direction Vector to swivel an aim.
---@param vec userdata|nil  a Vector (treated as an offset from 0,0)
---@param degrees number
---@return userdata|nil
function Geometry.rotate(vec, degrees)
    if not vec then return nil end
    local a = degrees * RAD
    local c, s = cos(a), sin(a)
    return Vector(vec.x * c - vec.y * s,
                  vec.x * s + vec.y * c, vec.z or 0)
end

----------------------------------------------------------------------------
-- angles
----------------------------------------------------------------------------

---The angle in degrees (0-180) at `vertex`, formed by the rays
---vertex->`a` and vertex->`b`. Returns 0 when either ray has no length.
---@param a userdata|nil
---@param vertex userdata|nil
---@param b userdata|nil
---@return number
function Geometry.angle_between(a, vertex, b)
    local d1 = Geometry.direction(vertex, a)
    local d2 = Geometry.direction(vertex, b)
    if not d1 or not d2 then return 0 end
    local dot = d1.x * d2.x + d1.y * d2.y
    if dot > 1 then dot = 1 elseif dot < -1 then dot = -1 end
    return acos(dot) * DEG
end

---True if `point` falls inside the cone with its tip at `apex`, opening
---along `aim_dir`, with a half-angle of `half_angle_deg` and reaching out
---to `max_range`. A `max_range` of nil or 0 means unbounded range.
---Useful for "is this enemy in front of me" / will-a-cone-spell-hit checks.
---@param apex userdata|nil
---@param aim_dir userdata|nil   a direction Vector (need not be normalized)
---@param point userdata|nil
---@param half_angle_deg number
---@param max_range number|nil
---@return boolean
function Geometry.point_in_cone(apex, aim_dir, point, half_angle_deg, max_range)
    local pa, pp = Geometry.pos(apex), Geometry.pos(point)
    if not pa or not pp or not aim_dir then return false end
    local dx, dy = pp.x - pa.x, pp.y - pa.y
    local len = sqrt(dx * dx + dy * dy)
    if len < 1e-6 then return true end          -- point sits on the apex
    if max_range and max_range > 0 and len > max_range then return false end
    local alen = sqrt(aim_dir.x * aim_dir.x + aim_dir.y * aim_dir.y)
    if alen < 1e-6 then return false end
    local dot = (dx * aim_dir.x + dy * aim_dir.y) / (len * alen)
    if dot > 1 then dot = 1 elseif dot < -1 then dot = -1 end
    return (acos(dot) * DEG) <= half_angle_deg
end

----------------------------------------------------------------------------
-- segments - collision math for line/skillshot reasoning
----------------------------------------------------------------------------

---The point on segment `a`->`b` closest to `p`. Clamped to the segment, so
---the result is never past either endpoint.
---@param a userdata|nil
---@param b userdata|nil
---@param p userdata|nil
---@return userdata|nil
function Geometry.closest_point_on_segment(a, b, p)
    local pa, pb, pp = Geometry.pos(a), Geometry.pos(b), Geometry.pos(p)
    if not pa or not pb or not pp then return nil end
    local abx, aby = pb.x - pa.x, pb.y - pa.y
    local len2 = abx * abx + aby * aby
    if len2 < 1e-6 then return pa end           -- degenerate segment
    local t = ((pp.x - pa.x) * abx + (pp.y - pa.y) * aby) / len2
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    return Vector(pa.x + abx * t, pa.y + aby * t, pa.z)
end

---Shortest 2D distance from point `p` to segment `a`->`b`.
---@param a userdata|nil
---@param b userdata|nil
---@param p userdata|nil
---@return number
function Geometry.dist_to_segment(a, b, p)
    local cp = Geometry.closest_point_on_segment(a, b, p)
    if not cp then return math.huge end
    return Geometry.dist2d(cp, p)
end

---True if the segment `a`->`b` passes within `radius` of `center`. This is
---the test for "does this line/projectile path clip a unit" - feed it the
---unit's position and its bounding-hull radius (plus the projectile width).
---@param a userdata|nil
---@param b userdata|nil
---@param center userdata|nil
---@param radius number
---@return boolean
function Geometry.segment_hits_circle(a, b, center, radius)
    return Geometry.dist_to_segment(a, b, center) <= radius
end

return Geometry
