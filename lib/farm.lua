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

---Two-camp stand search: ordered candidate stand spots for clearing an ADJACENT
---camp PAIR with ONE March. Pure scalar math (only Vector(x,y,z) for the returned
---points), so it is offline-testable; the hero applies walkability + enemy risk to
---the ordered list and takes the first that passes.
---
---March coverage is a rectangle CENTRED on the cast point, oriented along the hero's
---facing (from the stand toward the cast). Casting at (near) the midpoint of the two
---camps keeps both within +/- march_len/2 longitudinally. Standing off the A->B axis
---by a perpendicular `lat` offset finds walkable ground when the on-axis midpoint
---stand lands on terrain (the river pairs), at the cost of TILTING the rectangle: the
---farther camp then sits far_long*sin(theta) off the tilted centreline, so candidates
---whose tilt pushes it past the half-width are dropped (coverage lost).
---
---Candidates are emitted for each back distance (along -D toward the stand) x lateral
---offset, in the given order (least-tilt first within each back), keeping only those
---that (1) stay within March cast range of the cast point and (2) still cover both
---camps. Each lateral offset is clamped to the in-cast-range circle (back^2+lat^2 <=
---(cast_range-range_pad)^2). Returns {} when the pair is too far apart to cover
---longitudinally (d/2+|pair_offset| > march_len/2) or the inputs are degenerate.
---@param A table camp-center Vector A (reads .x/.y/.z)
---@param B table partner camp-center Vector B
---@param opts table|nil { cast_range?, range_pad?, halfwidth?, march_len?, stand_ring?, pair_offset?, backs?, lats? }
---@return table candidates ordered { stand=Vector, aim=Vector, back=number, lat=number, tilt=number }
function Farm.PairStandCandidates(A, B, opts)
    if not (A and B) then return {} end
    opts = opts or {}
    local cast_range = opts.cast_range or 300
    local range_pad  = opts.range_pad  or 20
    local halfwidth  = opts.halfwidth  or 450
    local march_len  = opts.march_len  or 1800
    local stand_ring = opts.stand_ring or 250
    local off        = opts.pair_offset or 0
    local backs      = opts.backs or { stand_ring, 180, 130 }
    local lats       = opts.lats  or { 0, 110, -110, 220, -220 }
    local half       = march_len * 0.5
    local rmax       = cast_range - range_pad

    local dx, dy = B.x - A.x, B.y - A.y
    local d = math.sqrt(dx * dx + dy * dy)
    if d < 1 then return {} end                          -- degenerate / coincident
    local far_long = d * 0.5 + math.abs(off)             -- longitudinal dist of the farther camp from the cast
    if far_long > half then return {} end                -- cannot cover both even on-axis

    local ux, uy = dx / d, dy / d                        -- D = unit(B-A)
    local perpx, perpy = -uy, ux                         -- perpendicular to D
    local castx = (A.x + B.x) * 0.5 + ux * off
    local casty = (A.y + B.y) * 0.5 + uy * off
    local z = A.z or 0

    local out = {}
    for bi = 1, #backs do
        local back = backs[bi]
        local maxlat2 = rmax * rmax - back * back         -- in-range circle: back^2 + lat^2 <= rmax^2
        if maxlat2 > 0 then
            local maxlat = math.sqrt(maxlat2)
            for li = 1, #lats do
                local lat = lats[li]
                if lat > maxlat then lat = maxlat elseif lat < -maxlat then lat = -maxlat end
                local hyp = math.sqrt(back * back + lat * lat)
                local sintheta = (hyp > 0) and (math.abs(lat) / hyp) or 0
                local tilt = far_long * sintheta          -- far-camp offset from the tilted centreline
                if tilt <= halfwidth then
                    out[#out + 1] = {
                        stand = Vector(castx - ux * back + perpx * lat,
                                       casty - uy * back + perpy * lat, z),
                        aim   = Vector(castx, casty, z),
                        back  = back, lat = lat, tilt = tilt,
                    }
                end
            end
        end
    end
    return out
end

---Tight-pair clear classification ("best distance" model): given the inter-camp
---distance `d`, how well does one centred March (cast at ~the midpoint) clear BOTH
---camps? Models each camp as a creep disc of radius `disc` centred d/2 from the cast.
---  clean: d/2 + disc <= half  -> the whole far disc is inside +/- march_len/2, one
---         March clears both.
---  clip : d/2 - disc <= half  -> the centre spills out but the NEAR creeps still clip
---         the rectangle; finish with extra Marches + the camp aggro-pulling in.
---  none : even the nearest creep is outside -> not a viable pair (farm single).
---Pure; the hero/diagnostic passes march_len + the calibrated disc. Returns the class
---plus both margins (>=0 = inside) for the calibration readout. (R4 / pairing policy)
---@param d number|nil inter-camp distance
---@param opts table|nil { march_len?, disc? }
---@return table { class = "clean"|"clip"|"none", full_margin = number, clip_margin = number }
function Farm.PairClearClass(d, opts)
    opts = opts or {}
    local half = (opts.march_len or 1800) * 0.5
    local disc = opts.disc or 200
    if not d or d <= 0 then
        return { class = "none", full_margin = -math.huge, clip_margin = -math.huge }
    end
    local full_margin = half - (d * 0.5 + disc)   -- outer creep spare; >=0 => clean
    local clip_margin = half - (d * 0.5 - disc)   -- nearest creep spare; >=0 => at least clips
    local class = (full_margin >= 0 and "clean") or (clip_margin >= 0 and "clip") or "none"
    return { class = class, full_margin = full_margin, clip_margin = clip_margin }
end

-- Tinker farm: valuation / clear-feasibility / scoring / ally-respect helpers.
-- Hero-agnostic and PURE: the hero precomputes per-creep hp (Entity.GetHealth),
-- gold (NPC.GetGoldBountyMax), and ally values (lib/hero_value), passing plain
-- tables/numbers in. No engine calls here. See Tinker/TINKER_FARM_DESIGN.md.
-- Creep-list contract: { { hp = <number?>, gold = <number?> }, ... }

Farm.DEFAULT_RISK_WEIGHT    = 4.0   -- gold/sec penalty per unit of risk (0..1)
Farm.DEFAULT_CONTEST_RADIUS = 700   -- an allied core this close "owns" the spot
local FARM_TIME_EPS = 0.5           -- floor on time-to-acquire (avoid div-by-zero)

---Sum precomputed gold over a creep list. Missing gold counts as 0. (R4 input)
---@param creeps table|nil
---@return number
function Farm.GoldValue(creeps)
    local g = 0
    if not creeps then return 0 end
    for i = 1, #creeps do g = g + (creeps[i].gold or 0) end
    return g
end

---Sum hp over a creep list. Missing hp counts as 0. (R3 denominator)
---@param creeps table|nil
---@return number
function Farm.EffectiveHP(creeps)
    local h = 0
    if not creeps then return 0 end
    for i = 1, #creeps do h = h + (creeps[i].hp or 0) end
    return h
end

---Can the hero clear these creeps with the given damage budget? The hero
---computes damage_budget (e.g. March damage-per-cast from lib/ability_data
---times the planned casts for this camp type). (R3)
---@param creeps table|nil
---@param damage_budget number|nil
---@return boolean
function Farm.CanClear(creeps, damage_budget)
    return Farm.EffectiveHP(creeps) <= (damage_budget or 0)
end

---Value score for one farm candidate; higher is better. The hero supplies an
---estimated time-to-acquire (travel + clear seconds; Keen TP shrinks travel)
---and an optional risk in 0..1 from the safety layer. (R4)
---@param opts table|nil { gold=number, time=number, risk=number?, risk_weight=number? }
---@return number
function Farm.ScoreTarget(opts)
    if not opts then return 0 end
    local gold = opts.gold or 0
    local time = opts.time or 0
    local risk = opts.risk or 0
    local rw   = opts.risk_weight or Farm.DEFAULT_RISK_WEIGHT
    if time < FARM_TIME_EPS then time = FARM_TIME_EPS end
    return gold / time - risk * rw
end

---Is `pos` contested by an allied core, so the farm bot should not steal it?
---The hero passes allies with PRECOMPUTED value (from lib/hero_value); this lib
---never calls hero_value, staying pure. (R2)
---@param pos table|nil { x, y }
---@param allies table|nil { { pos = {x,y}, value = number }, ... }
---@param opts table|nil { radius=number?, min_value=number? }
---@return boolean
function Farm.IsContestedByAlly(pos, allies, opts)
    if not (pos and allies) then return false end
    local radius = (opts and opts.radius) or Farm.DEFAULT_CONTEST_RADIUS
    local minval = (opts and opts.min_value) or 0
    local r2 = radius * radius
    for i = 1, #allies do
        local a = allies[i]
        if a and a.pos and (a.value or 0) >= minval then
            local dx, dy = a.pos.x - pos.x, a.pos.y - pos.y
            if (dx * dx + dy * dy) <= r2 then return true end
        end
    end
    return false
end

---Structural (position-based) farm risk in [0,1]: a gradient that rises toward the enemy fountain
---(camps deeper on the enemy half are more exposed) PLUS explicit per-zone bumps for known-contested
---camps the gradient alone cannot separate (e.g. a mid-river ancient at the same axis-distance as a
---safe own-jungle camp). Pure; the hero passes its fountains + contested-zone tags. Independent of
---live enemy vision, so it ranks an own-side safelane camp safer than a contested mid camp even when
---no enemy is on the minimap.
---@param pos table { x, y }
---@param opts table|nil { our_fountain={x,y}, enemy_fountain={x,y}, half_weight=number?, zones={ {x,y,radius,bump}, ... }? }
---@return number risk 0..1
function Farm.StructuralRisk(pos, opts)
    opts = opts or {}
    local r = 0
    local of, ef = opts.our_fountain, opts.enemy_fountain
    if of and ef and pos then
        local ax, ay = ef.x - of.x, ef.y - of.y
        local denom = ax * ax + ay * ay
        if denom > 1 then
            local t = ((pos.x - of.x) * ax + (pos.y - of.y) * ay) / denom   -- 0 our fountain .. 1 enemy fountain
            if t < 0 then t = 0 elseif t > 1 then t = 1 end
            r = (opts.half_weight or 0.5) * t
        end
    end
    if pos then
        for i = 1, #(opts.zones or {}) do
            local z = opts.zones[i]
            local dx, dy = pos.x - z.x, pos.y - z.y
            local rad = z.radius or 0
            if dx * dx + dy * dy <= rad * rad then r = r + (z.bump or 0) end
        end
    end
    if r < 0 then r = 0 elseif r > 1 then r = 1 end
    return r
end

return Farm
