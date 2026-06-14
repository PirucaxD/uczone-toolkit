---@meta
---lib/farm.lua - stateless farming geometry + cast-worthiness policy.
---
---Hero-agnostic. Every function takes explicit inputs (a world origin and a
---caller-supplied list of units); NONE of them call the engine API. The hero
---script owns the actual creep/neutral enumeration (which engine calls vary by
---framework version) and passes a plain unit list in. That keeps this module
---pure math: fully testable, zero runtime-API risk, reusable by any hero with
---an AoE / line nuke (Lina Dragon Slave, Jakiro Macropyre, etc.).
---
---v0.5.78: created for Lina's HOLD wave-clear (mana + stack aware). The
---line/point AoE-count optimizers are general enough that offensive W/Q aim
---could later consume them too; left here under "farm" for cohesion with the
---WorthCasting policy. Could lift the pure optimizers to lib/geometry.lua if a
---second non-farm consumer appears.
---
---Unit list contract (each entry):
---  { pos = <Vector>, hp = <number?>, is_neutral = <boolean?>, entity = <any?> }
---Only `pos` (with .x / .y) is required. `hp` is used as a tie-break weight.

local Farm = {}

---Count units whose center falls inside a line segment of `length` and
---half-width `half_width`, starting at (ox, oy) heading along the UNIT vector
---(dx, dy). Internal scalar form (no Vector allocation).
---@return integer count
---@return table hits subset of `units`
local function _count_in_line(ox, oy, dx, dy, length, half_width, units)
    local n, hits, sumt = 0, {}, 0
    local hw2 = half_width * half_width
    for i = 1, #units do
        local p = units[i].pos
        if p then
            local rx, ry = p.x - ox, p.y - oy
            local t = rx * dx + ry * dy           -- projection onto dir
            if t >= 0 and t <= length then
                local perpx = rx - t * dx
                local perpy = ry - t * dy
                local pd2 = perpx * perpx + perpy * perpy
                if pd2 <= hw2 then
                    n = n + 1
                    hits[#hits + 1] = units[i]
                    sumt = sumt + t              -- accumulate projection for the
                                                 -- closer-pack tie-break (v0.5.81)
                end
            end
        end
    end
    return n, hits, sumt
end

---Sum of hp over a unit list (tie-break weight). Missing hp counts as 0.
local function _sum_hp(units)
    local s = 0
    for i = 1, #units do s = s + (units[i].hp or 0) end
    return s
end

---Count units a line nuke fired from `origin` along unit-vector `aim_dir`
---would hit. Public wrapper around the scalar helper.
---@param origin userdata Vector cast origin
---@param aim_dir userdata Vector UNIT direction (caller normalizes)
---@param length number line length
---@param half_width number half the line width
---@param units table unit list (see contract)
---@return integer count
---@return table hits
function Farm.CountInLine(origin, aim_dir, length, half_width, units)
    if not (origin and aim_dir and length and half_width and units) then
        return 0, {}
    end
    return _count_in_line(origin.x, origin.y, aim_dir.x, aim_dir.y,
                          length, half_width, units)
end

---Find the line-nuke aim that hits the most units. Candidate directions are
---taken toward each unit (a line nuke's optimum always points at some unit's
---bearing). Ties broken by greater summed hp, then by a nearer cluster
---(shorter mean projection), so a denser/closer pack wins over a marginal far
---one.
---
---v0.5.111 hero-clip bonus (opts, all optional; opts nil = behavior identical
---to pre-v0.5.111):
---  opts.bonus_units  second unit list (same contract). Units hit by a
---                    candidate line add bonus_weight each to that line's
---                    SCORE, and their bearings join the candidate set
---                    (so a line can be aimed THROUGH the wave at a hero
---                    standing behind it). The returned hit_count stays
---                    PRIMARY units only, so caller cast-thresholds keep
---                    their meaning.
---  opts.bonus_weight score per bonus hit (default 3: a hero outbids up
---                    to 3 creeps when choosing between lines).
---  opts.min_hits     primary-hit qualification threshold. Lines meeting
---                    it form the QUALIFIED pool and always beat any
---                    unqualified line regardless of score, so a
---                    bonus-heavy line can never drag the pick below the
---                    caller's cast gate while a qualifying line exists.
---                    When NO line qualifies, the raw best is returned
---                    and the caller's gate rejects it exactly as today.
---A candidate must hit at least one PRIMARY unit (a hero-only bearing is
---not a wave-clear line).
---
---Returns (aim_pos, hit_count, hits, bonus_hit_count) where aim_pos =
---origin + best_dir * length (a point defining the cast line for
---issue_cast_position). (nil, 0, {}, 0) when no unit is hittable.
---@param origin userdata Vector cast origin (hero pos)
---@param units table unit list (see contract)
---@param length number line length
---@param half_width number half the line width
---@param opts table|nil { bonus_units?, bonus_weight?, min_hits? }
---@return userdata|nil aim_pos
---@return integer hit_count       primary hits on the chosen line
---@return table hits              primary hit subset
---@return integer bonus_hit_count bonus hits on the chosen line
function Farm.BestLineAim(origin, units, length, half_width, opts)
    if not (origin and units and #units > 0 and length and half_width) then
        return nil, 0, {}, 0
    end
    local bonus    = opts and opts.bonus_units
    local bweight  = (opts and opts.bonus_weight) or 3
    local min_hits = opts and opts.min_hits
    if bonus and #bonus == 0 then bonus = nil end
    local ox, oy, oz = origin.x, origin.y, origin.z
    local best_score, best_hp, best_proj = -1, -1, nil
    local best_q = false
    local best_n, best_bn = 0, 0
    local best_dx, best_dy, best_hits = nil, nil, {}
    local function consider(px, py)
        local dx, dy = px - ox, py - oy
        local len = math.sqrt(dx * dx + dy * dy)
        if len <= 1 then return end
        dx, dy = dx / len, dy / len
        local n, hits, sumt = _count_in_line(ox, oy, dx, dy, length,
                                             half_width, units)
        if n == 0 then return end  -- must clear creeps; hero-only is not wave-clear
        local bn = 0
        if bonus then
            bn = _count_in_line(ox, oy, dx, dy, length, half_width, bonus)
        end
        local score = n + bn * bweight
        local qual  = (min_hits == nil) or (n >= min_hits)
        local hp = _sum_hp(hits)
        local mean_proj = sumt / n   -- closer pack = lower mean t
        -- Selection ladder: qualified pool first (see opts.min_hits), then
        -- score (primary + weighted bonus; == raw hit count when opts is
        -- nil), then summed hp, then nearer cluster (shorter mean
        -- projection) so a denser/closer pack wins over an equally-scoring
        -- marginal far one (v0.5.81).
        if (qual and not best_q)
           or (qual == best_q and (score > best_score
               or (score == best_score and hp > best_hp)
               or (score == best_score and hp == best_hp
                   and (best_proj == nil or mean_proj < best_proj)))) then
            best_q, best_score, best_hp, best_proj = qual, score, hp, mean_proj
            best_n, best_bn = n, bn
            best_dx, best_dy, best_hits = dx, dy, hits
        end
    end
    for i = 1, #units do
        local p = units[i].pos
        if p then consider(p.x, p.y) end
    end
    if bonus then
        for i = 1, #bonus do
            local p = bonus[i].pos
            if p then consider(p.x, p.y) end
        end
    end
    if not best_dx then return nil, 0, {}, 0 end
    local aim_pos = Vector(ox + best_dx * length, oy + best_dy * length, oz)
    return aim_pos, best_n, best_hits, best_bn
end

---Find the AoE-circle center (of `radius`) that catches the most units. Centers
---are sampled at each unit position (an optimal circle can always be slid until
---a unit sits on its rim, and unit-centered candidates are a strong, cheap
---approximation). Ties broken by greater summed hp.
---
---Returns (center, hit_count, hits) or (nil, 0, {}).
---@param units table unit list (see contract)
---@param radius number AoE radius
---@param opts table|nil reserved
---@return userdata|nil center
---@return integer hit_count
---@return table hits
function Farm.BestPointAim(units, radius, opts)
    if not (units and #units > 0 and radius) then return nil, 0, {} end
    local r2 = radius * radius
    local best_n, best_hp, best_center, best_hits = 0, -1, nil, {}
    for i = 1, #units do
        local c = units[i].pos
        if c then
            local n, hits = 0, {}
            for j = 1, #units do
                local p = units[j].pos
                if p then
                    local dx, dy = p.x - c.x, p.y - c.y
                    if (dx * dx + dy * dy) <= r2 then
                        n = n + 1
                        hits[#hits + 1] = units[j]
                    end
                end
            end
            local hp = _sum_hp(hits)
            if n > best_n or (n == best_n and hp > best_hp) then
                best_n, best_hp, best_center, best_hits = n, hp, c, hits
            end
        end
    end
    if not best_center then return nil, 0, {} end
    return best_center, best_n, best_hits
end

---Policy predicate: is a cast worth it given how many units it would hit.
---@param hit_count integer|nil
---@param min_count integer|nil default 1
---@return boolean
function Farm.WorthCasting(hit_count, min_count)
    return (hit_count or 0) >= (min_count or 1)
end

return Farm
