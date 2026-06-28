---@meta
---lib/lane.lua - lane intelligence (creep waves, equilibrium, intercept). Hero-agnostic.
---Pure analysis core (offline-tested) + thin engine wrappers (verified in-game), mirroring
---lib/map.lua. Pure functions use scalar math (read .x/.y, build {x,y}); only the wrappers
---touch the engine, and NOTHING calls the engine at load time. See Tinker/TINKER_LANE_DESIGN.md.
local Lane = {}

-- ---- pure helpers --------------------------------------------------------

---centroid {x,y} of a member list (nil if empty).
local function _centroid(members)
    local sx, sy, n = 0, 0, #members
    if n == 0 then return nil end
    for i = 1, n do sx = sx + members[i].pos.x; sy = sy + members[i].pos.y end
    return { x = sx / n, y = sy / n }
end
Lane._centroid = _centroid

---summed hp over members (missing hp = 0).
local function _hp(members)
    local h = 0
    for i = 1, #members do h = h + (members[i].hp or 0) end
    return h
end
Lane._hp = _hp

---summed gold bounty over members (missing gold = 0).
function Lane._gold(members)
    local g = 0
    for i = 1, #members do g = g + (members[i].gold or 0) end
    return g
end

---push weight of a wave: default summed hp; opts.strength_fn(members) overrides.
function Lane._strength(members, opts)
    if opts and opts.strength_fn then return opts.strength_fn(members) end
    return _hp(members)
end

---front {x,y}: the member furthest along push_dir (a vector toward the enemy base; need not be
---normalized, argmax of the projection is scale-invariant). nil if empty.
function Lane._front(members, push_dir)
    local best, bestp = nil, -math.huge
    for i = 1, #members do
        local p = members[i].pos
        local proj = p.x * push_dir.x + p.y * push_dir.y
        if proj > bestp then best, bestp = p, proj end
    end
    return best and { x = best.x, y = best.y } or nil
end

-- ---- cluster / lane assignment / wave detection --------------------------

---single-link proximity clustering of a creep list: members within `radius` of ANY current
---member join the cluster (transitive). O(n^2) per component; n (lane creeps) is small.
---@return table clusters list of member-lists
function Lane._cluster(creeps, radius)
    local r2 = radius * radius
    local n = #creeps
    local seen, clusters = {}, {}
    for i = 1, n do
        if not seen[i] then
            local stack, group = { i }, {}
            seen[i] = true
            while #stack > 0 do
                local k = stack[#stack]; stack[#stack] = nil
                group[#group + 1] = creeps[k]
                local pk = creeps[k].pos
                for j = 1, n do
                    if not seen[j] then
                        local pj = creeps[j].pos
                        local dx, dy = pk.x - pj.x, pk.y - pj.y
                        if dx * dx + dy * dy <= r2 then seen[j] = true; stack[#stack + 1] = j end
                    end
                end
            end
            clusters[#clusters + 1] = group
        end
    end
    return clusters
end

---lane region of a point. The mid lane runs along the SW->NE diagonal (y=x); top hugs the
---upper-left (y>x), bot the lower-right (x>y). `opts.mid_band` = half-width of the mid band
---(default 2500). The precise bent-lane polyline path is a deferred refinement (design sec 7).
function Lane._assign_lane(point, opts)
    local band = (opts and opts.mid_band) or 2500
    local d = point.x - point.y
    if d > band then return "bot"
    elseif d < -band then return "top"
    else return "mid" end
end

---build wave structs from a creep list (one team's creeps) given the team's push direction
---(toward the enemy base). Clusters, assigns lanes, computes count/hp/gold/strength + front,
---retains the member list. Pure.
function Lane.DetectWaves(creeps, push_dir, opts)
    opts = opts or {}
    local radius = opts.cluster_radius or 600
    local waves = {}
    for _, group in ipairs(Lane._cluster(creeps, radius)) do
        local centroid = _centroid(group)
        waves[#waves + 1] = {
            team = group[1].team, lane = Lane._assign_lane(centroid, opts), centroid = centroid,
            front = Lane._front(group, push_dir), count = #group,
            hp = _hp(group), gold = Lane._gold(group), strength = Lane._strength(group, opts),
            creeps = group,
        }
    end
    return waves
end

-- ---- clash equilibrium + intercept ---------------------------------------

---equilibrium + movement prediction for a lane. contact = where the fronts meet; each side's
---weight = wave strength + opts.tower_weight per friendly tower within range of the contact; the
---clash drifts toward the weaker side at a rate proportional to the imbalance, clamped at the
---nearest defending tower line. opts: drift_coeff, horizon, creep_speed, move_threshold,
---tower_weight (all calibratable). Pure.
function Lane.PredictClash(enemy_wave, ally_wave, towers, opts)
    opts = opts or {}
    local tower_weight = opts.tower_weight or 4000
    local drift_coeff  = opts.drift_coeff or 0.5
    local horizon      = opts.horizon or 6
    local creep_speed  = opts.creep_speed or 325
    local move_thresh  = opts.move_threshold or 0.1

    local ef = enemy_wave and enemy_wave.front
    local af = ally_wave and ally_wave.front
    local contact
    if ef and af then contact = { x = (ef.x + af.x) * 0.5, y = (ef.y + af.y) * 0.5 }
    elseif ef then contact = { x = ef.x, y = ef.y }
    elseif af then contact = { x = af.x, y = af.y }
    else return nil end

    local we = (enemy_wave and enemy_wave.strength) or 0
    local wa = (ally_wave and ally_wave.strength) or 0
    for _, t in ipairs(towers or {}) do
        if t.alive ~= false and t.pos then
            local dx, dy = t.pos.x - contact.x, t.pos.y - contact.y
            local rng = t.range or 0
            if dx * dx + dy * dy <= rng * rng then
                if enemy_wave and t.team == enemy_wave.team then we = we + tower_weight
                elseif ally_wave and t.team == ally_wave.team then wa = wa + tower_weight end
            end
        end
    end

    local total = we + wa
    local b = (total > 0) and (we - wa) / total or 0
    local moving = math.abs(b) >= move_thresh
    local pushing = (not moving) and "even" or (b > 0 and "enemy" or "ally")
    -- drift toward the losing side's front: enemy stronger (b>0) -> toward the ally front; else
    -- toward the enemy front. Uncontested push (only one front) -> away from contact toward it.
    local toward = (b > 0) and (af or ef) or (ef or af)
    local drift_dir = { x = 0, y = 0 }
    if toward then
        local dx, dy = toward.x - contact.x, toward.y - contact.y
        local len = math.sqrt(dx * dx + dy * dy)
        if len > 1 then drift_dir = { x = dx / len, y = dy / len } end
    end

    local settle, settle_eta = { x = contact.x, y = contact.y }, 0
    local crashing, crash_tower = false, nil
    if moving then
        local rate = drift_coeff * math.abs(b) * creep_speed
        local travel = rate * horizon
        local defend_team = (b > 0) and (ally_wave and ally_wave.team) or (enemy_wave and enemy_wave.team)
        for _, t in ipairs(towers or {}) do        -- clamp at the nearest defending tower ahead; reaching one = crashing
            if t.alive ~= false and t.pos and t.team == defend_team then
                local along = (t.pos.x - contact.x) * drift_dir.x + (t.pos.y - contact.y) * drift_dir.y
                if along > 0 and along < travel then travel = along; crash_tower = t end
            end
        end
        crashing = crash_tower ~= nil                -- the wave pushes up to a defending tower (crashes into it)
        settle = { x = contact.x + drift_dir.x * travel, y = contact.y + drift_dir.y * travel }
        settle_eta = (rate > 0) and (travel / rate) or 0
    end

    return { contact = contact, settle = settle, drift_dir = drift_dir, settle_eta = settle_eta,
             w_enemy = we, w_ally = wa, pushing = pushing, moving = moving,
             crashing = crashing, crash_tower = crash_tower }
end

---ETA to reach `target` from `from_pos`, via the best ready teleport anchor or plain walk. Used
---both for "can I reach this wave now" (from_pos = hero) and "ETA to the next lane" (from_pos =
---a lane's settle point). Generic anchor list; the hero's Keen-level rules are applied upstream.
function Lane.InterceptETA(from_pos, anchors, move_speed, tp, target, clearable_until)
    local ms = math.max(150, move_speed or 300)
    local function dist(a, b) local dx, dy = a.x - b.x, a.y - b.y; return math.sqrt(dx * dx + dy * dy) end
    local channel = (tp and tp.channel) or 0
    local eta, best = dist(from_pos, target) / ms, nil   -- plain walk baseline
    for _, a in ipairs(anchors or {}) do
        if a.ready and a.pos then
            local e = channel + dist(a.pos, target) / ms
            if e < eta then eta, best = e, a end
        end
    end
    return { best_anchor = best, eta = eta,
             reachable = (clearable_until == nil) or (eta <= clearable_until) }
end

---nearest READY anchor of an allowed kind to `point` (nil allowed_kinds = any kind).
---@return table|nil anchor
---@return number|nil distance
function Lane.NearestTeleportAnchor(point, anchors, allowed_kinds)
    local allow
    if allowed_kinds then allow = {}; for _, k in ipairs(allowed_kinds) do allow[k] = true end end
    local best, bestd2 = nil, math.huge
    for _, a in ipairs(anchors or {}) do
        if a.ready and a.pos and (not allow or allow[a.kind]) then
            local dx, dy = a.pos.x - point.x, a.pos.y - point.y
            local d2 = dx * dx + dy * dy
            if d2 < bestd2 then best, bestd2 = a, d2 end
        end
    end
    return best, best and math.sqrt(bestd2) or nil
end

-- ---- assembler -----------------------------------------------------------

---compose the full per-lane state from plain inputs. Splits creeps by team, detects waves per
---side (with each team's push direction from opts.enemy_push / opts.ally_push), picks the biggest
---wave per lane per side, predicts the clash, counts heroes near it, and (if anchors + kinematics
---are present) computes the intercept to the clash settle point. Pure.
function Lane.BuildLaneStates(creeps, towers, heroes, opts)
    opts = opts or {}
    local team = opts.team
    local enemy_push = opts.enemy_push or { x = 1, y = 1 }
    local ally_push  = opts.ally_push or { x = -1, y = -1 }

    local mine, theirs = {}, {}
    for _, cc in ipairs(creeps or {}) do
        if cc.team == team then mine[#mine + 1] = cc else theirs[#theirs + 1] = cc end
    end
    local enemy_waves = Lane.DetectWaves(theirs, enemy_push, opts)
    local ally_waves  = Lane.DetectWaves(mine, ally_push, opts)

    local function biggest_by_lane(waves)
        local by = {}
        for _, w in ipairs(waves) do
            if not by[w.lane] or w.count > by[w.lane].count then by[w.lane] = w end
        end
        return by
    end
    local eByLane, aByLane = biggest_by_lane(enemy_waves), biggest_by_lane(ally_waves)

    local towers_by_lane = { top = {}, mid = {}, bot = {} }
    for _, t in ipairs(towers or {}) do
        if t.pos then local ln = Lane._assign_lane(t.pos, opts); towers_by_lane[ln][#towers_by_lane[ln] + 1] = t end
    end

    local hero_r2 = (opts.hero_radius or 1200) ^ 2
    local lanes = {}
    for _, lane in ipairs({ "top", "mid", "bot" }) do
        local ew, aw = eByLane[lane], aByLane[lane]
        local clash = (ew or aw) and Lane.PredictClash(ew, aw, towers, opts) or nil  -- clash from VISIBLE positions only
        if not ew and opts.game_time then            -- fog-fill: estimate the unseen enemy wave by game time
            local est = Lane.ExpectedWave(opts.game_time, { super = opts.super, mega = opts.mega })
            est.lane, est.estimated = lane, true
            est.team = (opts.team == 2) and 3 or 2
            ew = est                                 -- composition/gold only (no position); clash stays visible-only
        end

        local en, an = 0, 0
        if clash then
            for _, h in ipairs(heroes or {}) do
                local dx, dy = h.pos.x - clash.contact.x, h.pos.y - clash.contact.y
                if dx * dx + dy * dy <= hero_r2 then
                    if h.team == team then an = an + 1 else en = en + 1 end
                end
            end
        end

        local intercept = nil
        if clash and opts.anchors and opts.hero_pos and opts.move_speed then
            local anchors = {}
            for _, a in ipairs(opts.anchors) do anchors[#anchors + 1] = a end
            local allow = {}
            for _, k in ipairs(opts.allowed_kinds or {}) do allow[k] = true end
            if allow.creep then for _, cc in ipairs(mine) do anchors[#anchors + 1] = { pos = cc.pos, ready = true, kind = "creep" } end end
            if allow.ally then for _, h in ipairs(heroes or {}) do if h.team == team then anchors[#anchors + 1] = { pos = h.pos, ready = true, kind = "ally" } end end end
            local clearable_until = (clash.settle_eta or 0) + (opts.clear_window or 5)
            intercept = Lane.InterceptETA(opts.hero_pos, anchors, opts.move_speed, opts.tp, clash.settle, clearable_until)
        end

        lanes[lane] = {
            lane = lane, enemy_wave = ew, ally_wave = aw,
            gold = (ew and ew.gold) or 0, towers = towers_by_lane[lane],
            enemy_heroes = en, ally_heroes = an, clash = clash, intercept = intercept,
        }
    end
    return lanes
end

-- ---- expected wave by game time (Liquipedia-validated parametrization) ----
-- Composition + per-cycle scaling for fog estimates + gold valuation. game_time in seconds on the
-- GAME CLOCK (0 = the first wave at 00:00). See Tinker/TINKER_LANE_DESIGN.md + Liquipedia Lane_Creeps.

-- base melee/ranged by time threshold (ascending); siege/flagbearer handled by wave cadence below.
local WAVE_COMP = {
    { 0, 3, 1 }, { 900, 4, 1 }, { 1800, 5, 1 }, { 2400, 5, 2 }, { 2700, 6, 2 },
}
-- per-creep { hp, gold, hpc = hp/cycle, goldc = gold/cycle } at cycle 0 (cycle = floor(t/450), max 30).
-- gold = the MAX bounty of the range, to match the visible path (sums NPC.GetGoldBountyMax) + the
-- camp-farm convention, so fogged-vs-visible lane gold is apples-to-apples.
local CREEP_STATS = {
    melee   = { hp = 550,  gold = 39, hpc = 12, goldc = 1 },
    ranged  = { hp = 300,  gold = 52, hpc = 12, goldc = 3 },
    siege   = { hp = 935,  gold = 72, hpc = 0,  goldc = 0 },   -- siege does not upgrade per-cycle
    smelee  = { hp = 700,  gold = 26, hpc = 19, goldc = 1.5 }, -- super (post-barracks)
    sranged = { hp = 475,  gold = 25, hpc = 18, goldc = 6 },
    mmelee  = { hp = 1270, gold = 26, hpc = 0,  goldc = 0 },   -- mega (base-only; end-game)
    mranged = { hp = 1015, gold = 25, hpc = 0,  goldc = 0 },
}
local function _stat_hp(s, cyc)   return s.hp + s.hpc * cyc end
local function _stat_gold(s, cyc) return s.gold + s.goldc * cyc end

---expected wave composition + value at `game_time` (seconds, game clock). opts.super / opts.mega
---swap regular melee/ranged for super/mega stats (barracks state; default regular). Pure.
---@return table { wave, cycle, melee, ranged, siege, flagbearer, count, hp, gold, strength }
function Lane.ExpectedWave(game_time, opts)
    opts = opts or {}
    local t = math.max(0, game_time or 0)
    local wave = math.floor(t / 30) + 1
    local cyc = math.min(30, math.floor(t / 450))

    local melee, ranged = 3, 1
    for i = 1, #WAVE_COMP do
        if t >= WAVE_COMP[i][1] then melee, ranged = WAVE_COMP[i][2], WAVE_COMP[i][3] end
    end

    local siege = 0                                       -- every 10th wave from wave 11; 1 -> 2 (30:00) -> 3 (60:00)
    if wave >= 11 and (wave - 11) % 10 == 0 then
        siege = (t >= 3600 and 3) or (t >= 1800 and 2) or 1
    end
    local flagbearer = 0                                  -- every 2nd wave from wave 5; replaces a melee (regular only)
    if not (opts.super or opts.mega) and wave >= 5 and (wave - 5) % 2 == 0 then
        flagbearer = 1; melee = melee - 1
    end

    local ms = (opts.mega and CREEP_STATS.mmelee) or (opts.super and CREEP_STATS.smelee) or CREEP_STATS.melee
    local rs = (opts.mega and CREEP_STATS.mranged) or (opts.super and CREEP_STATS.sranged) or CREEP_STATS.ranged
    local fs, ss = CREEP_STATS.melee, CREEP_STATS.siege   -- flagbearer = melee stats (regular waves only)

    local hp = melee * _stat_hp(ms, cyc) + ranged * _stat_hp(rs, cyc)
             + siege * _stat_hp(ss, cyc) + flagbearer * _stat_hp(fs, cyc)
    local gold = melee * _stat_gold(ms, cyc) + ranged * _stat_gold(rs, cyc)
             + siege * _stat_gold(ss, cyc) + flagbearer * _stat_gold(fs, cyc)
    if flagbearer > 0 then gold = gold + flagbearer * (10 + _stat_gold(fs, cyc)) end  -- flagbearer area gold (10 + bounty)

    return { wave = wave, cycle = cyc, melee = melee, ranged = ranged, siege = siege,
             flagbearer = flagbearer, count = melee + ranged + siege + flagbearer,
             hp = hp, gold = gold, strength = hp }
end

-- ---- engine wrappers (verified in-game; nothing runs at load) -------------
-- Lane-creep enumeration uses the TYPE_LANE_CREEP unit-type flag (confirmed prior-art: the
-- AutofarmV2 script + our own TYPE_STRUCTURE idiom). Pure-core tests never call these.

local function _read_lane_creeps()
    local out = {}
    for _, n in ipairs(NPCs.GetAll(Enum.UnitTypeFlags.TYPE_LANE_CREEP) or {}) do
        if Entity.IsAlive(n) and not Entity.IsDormant(n)
           and not (NPC.IsWaitingToSpawn and NPC.IsWaitingToSpawn(n)) then
            local p = Entity.GetAbsOrigin(n)
            if p then
                out[#out + 1] = { pos = { x = p.x, y = p.y }, team = Entity.GetTeamNum(n),
                                  hp = Entity.GetHealth(n) or 0, max_hp = Entity.GetMaxHealth(n) or 0,
                                  gold = (NPC.GetGoldBountyMax and NPC.GetGoldBountyMax(n)) or 0 }
            end
        end
    end
    return out
end

local function _read_towers()
    local out = {}
    for _, t in ipairs(Towers.GetAll() or {}) do
        local p = Entity.GetAbsOrigin(t)
        if p then out[#out + 1] = { pos = { x = p.x, y = p.y }, team = Entity.GetTeamNum(t),
                                    range = (NPC.GetAttackRange and NPC.GetAttackRange(t)) or 700,
                                    alive = Entity.IsAlive(t) } end
    end
    return out
end

local function _read_heroes()
    local out = {}
    for _, h in ipairs(Heroes.GetAll() or {}) do
        if Entity.IsAlive(h) and (not NPC.IsIllusion or not NPC.IsIllusion(h)) then
            local p = (not Entity.IsDormant(h)) and Entity.GetAbsOrigin(h) or Hero.GetLastMaphackPos(h)
            if p then out[#out + 1] = { pos = { x = p.x, y = p.y }, team = Entity.GetTeamNum(h) } end
        end
    end
    return out
end

---read the live map and return per-lane state. opts.team defaults to the local hero's team; all
---calibration/anchor opts pass straight through to BuildLaneStates.
function Lane.ScanLanes(opts)
    opts = opts or {}
    if opts.team == nil then
        local me = Heroes.GetLocal and Heroes.GetLocal()
        opts.team = me and Entity.GetTeamNum(me) or nil
    end
    return Lane.BuildLaneStates(_read_lane_creeps(), _read_towers(), _read_heroes(), opts)
end

return Lane
