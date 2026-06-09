---@meta
---lib/escape.lua - danger-aware escape destination picking.
---
---Hero-agnostic. All functions take entity / vector args explicitly
---(no implicit hero-state reads), matching the lib/geometry.lua
---convention.
---
---Extracted from Sniper.lua during Lina Phase 5 (positioning
---intelligence for self-displacement saves). The three helpers form
---a small module:
---  - Escape.DangerAtPos(me, pos)
---  - Escape.SafePushDestination(me, dest, threat_hint)
---  - Escape.PickDir(me, me_pos, toward, push, threat_hint, filter?)
---
---Sniper.lua reaches them via thin state.* wrappers so its existing
---call sites do not change. Lina.lua's Phase 5 .fire bodies (Pike
---first, then Force / EUL / WW) call them directly.
---
---No engine API surprises beyond the two already-documented gotchas:
---  - NPC.FindRotationAngle returns RADIANS (math.deg before any
---    deg-based compare). NOT used inside this module - the angle
---    math is in the callers' turn-then-fire harness.
---  - First cast of a freshly-acquired item silently dropped. Also
---    a caller concern (Sniper's pike_prime + Lina's pike_reissue).
---
---v0.5.61 fix: require lib/target here. The original v0.5.57 extraction
---left Target as a global ref expecting it to be available in the lib's
---scope, but lib modules do not inherit the hero script's upvalues.
---Latent bug bit EUL on first self-cast (v0.5.60 demo log L2712:
---'attempt to index a nil value (global Target)' inside
---Escape.SafePushDestination). The Pike / Force code path would have
---crashed identically; v0.5.58 demo never triggered Pike's self-cast
---branch (all Pike fires went enemy-target via the unchanged primary
---branch) so it stayed latent.
---
---v0.5.75 lift (lib-first audit bucket B + C + D): three more helpers
---moved out of Lina.lua into this module so future heroes (Sniper next)
---pick them up via require with zero rewrite:
---  - Escape.ComputeSafeDest (stateless): toward = caster-or-centroid,
---    then PickDir. Returns (escape_dir, landing) or (nil, nil).
---  - Escape.TrySelfPush + Escape.SelfPushTick: the turn-then-fire
---    harness Pike + Force self-cast both use. Stateful via a caller-
---    owned pending struct (return-the-pending pattern, matches v0.5.74's
---    ThreatData.ComputeArrivalTime closure shape: lib stays stateless,
---    hero owns the slot + ticks once per frame).
---  - Escape.QueueSafePostMove + Escape.PostAirborneMoveTick: the
---    re-issue-while-airborne harness EUL + WW use to walk Lina toward
---    a danger-aware landing during / after airborne. Same return-the-
---    pending shape.
---
---All five stateful entry points take a cfg table with hero-side
---callbacks (safe_issue, issue_item_self, tlog, now, uname, item_get,
---item_ready, on_self_cast) so the lib never imports a hero's wrappers
---directly. cfg shape documented above each function. Sniper migration
---is a separate slice (replace state.compute_safe_dest / pick_escape_dir
---/ pending_pike_self / pending_pike_self_tick call sites with Escape.*
---calls passing his own cfg); Sniper.lua is intentionally untouched in
---v0.5.75.

local Target = require("lib.target")

local UO = Enum.UnitOrder

local Escape = {}

---Stateless danger score at a world position. Proximity-weighted
---count of visible enemy heroes near pos, with a turn-cost factor
---that biases toward landings forcing the enemy to TURN far from
---their current facing (the turn delay during chase is "free"
---distance for the defender).
---
---Per-enemy contribution:
---  base = (1 - d / 1400) * 30
---  turn_factor in [0, 1] (1 = enemy facing 180deg away from landing)
---  score += base * (1 - turn_factor * 0.5)   -- cap reduction at 50%
---
---Towers intentionally not counted - no clean enemy-tower-in-radius
---API and the hero-only term closes the documented blind spot.
---
---@param me userdata defender entity (for team lookup)
---@param pos userdata world position to score
---@return number score (higher = more dangerous; lower is safer)
function Escape.DangerAtPos(me, pos)
    if not me or not pos then return 0 end
    local list = Heroes.InRadius(pos, 1400, Entity.GetTeamNum(me),
                                 Enum.TeamType.TEAM_ENEMY)
    if not list then return 0 end
    local score = 0
    for i = 1, #list do
        local e = list[i]
        if e and Target.IsAlive(e) and Target.NotIllusion(e) then
            local ep = Entity.GetAbsOrigin(e)
            if ep then
                local d = pos:Distance2D(ep)
                if d < 1400 then
                    local base = (1 - d / 1400) * 30
                    local turn_factor = 0
                    if NPC.GetForwardVector then
                        local fwd = NPC.GetForwardVector(e)
                        if fwd then
                            local cdx, cdy = pos.x - ep.x, pos.y - ep.y
                            local clen = math.sqrt(cdx * cdx + cdy * cdy)
                            if clen > 1 then
                                local nx, ny = cdx / clen, cdy / clen
                                local dot = fwd.x * nx + fwd.y * ny
                                turn_factor = (1 - dot) * 0.5
                                if turn_factor < 0 then
                                    turn_factor = 0
                                elseif turn_factor > 1 then
                                    turn_factor = 1
                                end
                            end
                        end
                    end
                    score = score + base * (1 - turn_factor * 0.5)
                end
            end
        end
    end
    return score
end

---Validate a candidate landing as a save target. Checks:
---  (1) terrain traversability via GridNav.IsTraversableFromTo
---  (2) when a specific threat is known, dest must INCREASE distance
---      from that threat (avoids pushing the defender into the very
---      threat the save is meant to escape)
---  (3) centroid fallback via DangerAtPos when no specific threat is
---      known: a destination meaningfully more dangerous than the
---      current spot is rejected (margin = 12 against a ~30/enemy
---      scale, avoids flapping on a marginal diff).
---
---@param me userdata defender entity
---@param dest_pos userdata candidate landing
---@param threat_caster_hint userdata|nil specific threat caster, if known
---@return userdata|nil dest_pos if safe, nil otherwise
function Escape.SafePushDestination(me, dest_pos, threat_caster_hint)
    if not me or not dest_pos then return nil end
    local me_pos = Entity.GetAbsOrigin(me)
    if not me_pos then return nil end
    if not GridNav.IsTraversableFromTo(me_pos, dest_pos) then return nil end

    if threat_caster_hint and Entity.IsEntity(threat_caster_hint)
       and Target.IsAlive(threat_caster_hint) then
        local cp = Entity.GetAbsOrigin(threat_caster_hint)
        if not cp then return dest_pos end
        local d_now  = me_pos:DistanceSqr2D(cp)
        local d_dest = dest_pos:DistanceSqr2D(cp)
        if d_dest <= d_now then return nil end
        return dest_pos
    end

    if Escape.DangerAtPos(me, dest_pos) > Escape.DangerAtPos(me, me_pos) + 12 then
        return nil
    end
    return dest_pos
end

---7-angle danger-aware escape destination picker. Tries angles
---{0, -35, 35, -65, 65, -90, 90} (degrees) off straight-away from
---toward_threat. Each candidate is gated by SafePushDestination +
---optional per-candidate filter, then ranked by DangerAtPos (lower
---is safer). Ties favor 0deg (straight-away baseline) via strict
---less-than - a marginal angle does not win over straight-away
---unless meaningfully safer.
---
---Returns (escape_dir, landing) where escape_dir is the unit vector
---FROM defender TO the chosen landing; (nil, nil) if every candidate
---failed terrain or the threat-distance gate.
---
---filter_fn(esc_dir, landing) -> bool runs AFTER SafePushDestination
---so callers' extra constraints (Sniper grenade's 120deg facing gate
---to a cast_point) only see candidates that already pass terrain +
---threat-distance. Returning false drops the candidate.
---
---@param me userdata defender entity
---@param me_pos userdata defender's current position
---@param toward_threat userdata unit vector FROM defender TOWARD threat
---@param push_distance number how far the save moves the defender
---@param threat_caster_hint userdata|nil specific threat, if known
---@param filter_fn fun(esc_dir:userdata, landing:userdata):boolean|nil
---@return userdata|nil escape_dir (unit vector)
---@return userdata|nil landing
function Escape.PickDir(me, me_pos, toward_threat, push_distance,
                        threat_caster_hint, filter_fn)
    if not me or not me_pos or not toward_threat or not push_distance then
        return nil, nil
    end
    local best_dir, best_landing, best_danger
    for _, deg in ipairs({ 0, -35, 35, -65, 65, -90, 90 }) do
        local rad = math.rad(deg)
        local c, s = math.cos(rad), math.sin(rad)
        local rx = toward_threat.x * c - toward_threat.y * s
        local ry = toward_threat.x * s + toward_threat.y * c
        local esc_dir = Vector(-rx, -ry, 0)
        local landing = me_pos + esc_dir * push_distance
        if Escape.SafePushDestination(me, landing, threat_caster_hint)
           and (not filter_fn or filter_fn(esc_dir, landing)) then
            local dng = Escape.DangerAtPos(me, landing)
            if not best_danger or dng < best_danger then
                best_danger, best_dir, best_landing = dng, esc_dir, landing
            end
        end
    end
    return best_dir, best_landing
end

---Derive a danger-aware escape destination for a self-displacement save.
---toward = unit-vector defender -> threat caster if known and alive;
---otherwise unit-vector defender -> centroid of enemy heroes within
---1500u. PickDir then picks the best of 7 angles off straight-away.
---
---Returns (escape_dir, landing) where landing = me_pos + escape_dir *
---push_dist. (nil, nil) when no toward direction exists (no caster, no
---nearby enemies) or when PickDir rejects every candidate.
---
---@param me userdata defender entity
---@param threat_caster userdata|nil specific threat, if known
---@param push_distance number how far the save moves the defender
---@return userdata|nil escape_dir
---@return userdata|nil landing
function Escape.ComputeSafeDest(me, threat_caster, push_distance)
    if not me or not push_distance then return nil, nil end
    local me_pos = Entity.GetAbsOrigin(me)
    if not me_pos then return nil, nil end
    local toward
    local cp = threat_caster and Entity.IsEntity(threat_caster)
               and Target.IsAlive(threat_caster)
               and Entity.GetAbsOrigin(threat_caster) or nil
    if cp then
        local diff = cp - me_pos
        if diff:Length2DSqr() < 1 then return nil, nil end
        toward = diff:Normalized()
    else
        local enemies = Heroes.InRadius(me_pos, 1500, Entity.GetTeamNum(me),
                                        Enum.TeamType.TEAM_ENEMY)
        if enemies and #enemies > 0 then
            local cx, cy, n = 0, 0, 0
            for i = 1, #enemies do
                local ep = Entity.GetAbsOrigin(enemies[i])
                if ep then cx, cy, n = cx + ep.x, cy + ep.y, n + 1 end
            end
            if n > 0 then
                local cen = Vector(cx / n, cy / n, me_pos.z)
                local diff = cen - me_pos
                if diff:Length2DSqr() > 1 then toward = diff:Normalized() end
            end
        end
    end
    if not toward then return nil, nil end
    local escape_dir = Escape.PickDir(me, me_pos, toward, push_distance,
                                      threat_caster)
    if not escape_dir then return nil, nil end
    local landing = me_pos + escape_dir * push_distance
    return escape_dir, landing
end

---@class EscapeCfg
---@field safe_issue        fun(spec:table):boolean        @order.Issue wrapper with dedup + cast-verify
---@field issue_item_self   fun(intent:string, layer:string, item:userdata):boolean
---@field tlog              fun(level:integer, name:string, kv:table)
---@field now               fun():number                   @monotonic seconds (GlobalVars.GetCurTime in UCZone)
---@field uname             fun(ent:userdata):string       @short entity name for logs
---@field hero_key          string                         @"lina" / "sniper" / ...
---@field layer             string|nil                     @"def" if omitted
---@field item_get          fun(me:userdata, item_name:string):userdata|nil  @NPCLib.item adapter
---@field item_ready        fun(me:userdata, item_name:string):boolean       @NPCLib.item_ready adapter
---@field on_self_cast      fun(item_name:string, me:userdata)|nil           @optional post-cast hook (Pike's pike_reissue stamp)

---Shared self-push harness used by Pike + Force self-cast saves.
---Computes a danger-aware destination and either:
---  - fires the item immediately (Lina already facing within 30 deg of
---    the escape direction) and returns (nil, ok) - no pending to stash
---  - turns toward away_pt then arms a pending struct the caller stores
---    and feeds to Escape.SelfPushTick each frame. Returns (pending, ok)
---    where ok is the result of the turn MOVE issue.
---
---The 30 deg gate is on facing angle, not landing distance. NPC.FindRot-
---ationAngle returns RADIANS (see reference_uczone_api_gotchas); math.deg
---before the gate.
---
---Pike-specific behaviour (item_name == "item_hurricane_pike"): when
---cfg.on_self_cast is provided it fires right after a successful issue,
---so heroes that need the first-cast-drop pike_reissue stamp can install
---it without the lib knowing about Pike internals.
---
---@param me userdata defender entity
---@param intent string intent string for safe_issue dedup / cast_verify
---@param item userdata item ability handle
---@param item_name string canonical item_* name (controls tlog short name)
---@param push_dist number distance the cast will push (typically 600)
---@param threat_caster userdata|nil specific threat, if known
---@param cfg EscapeCfg hero-side callbacks
---@return table|nil pending struct to stash (nil = immediate fire or skip)
---@return boolean ok did the harness issue an action (cast OR turn)
function Escape.TrySelfPush(me, intent, item, item_name, push_dist,
                            threat_caster, cfg)
    if not (me and item and cfg) then return nil, false end
    local me_pos = Entity.GetAbsOrigin(me)
    if not me_pos then return nil, false end
    local escape_dir, _ = Escape.ComputeSafeDest(me, threat_caster, push_dist)
    if not escape_dir then return nil, false end
    local away_pt = Vector(me_pos.x + escape_dir.x * 400,
                           me_pos.y + escape_dir.y * 400, me_pos.z)
    local angle_ok, angle_rad = pcall(NPC.FindRotationAngle, me, away_pt)
    local angle = (angle_ok and angle_rad)
                  and math.deg(math.abs(angle_rad)) or 0
    local short = (item_name == "item_hurricane_pike") and "pike_self"
                  or "force_self"
    local tlog = cfg.tlog
    local layer = cfg.layer or "def"
    if angle <= 30 then
        local ok = cfg.issue_item_self(intent, layer, item)
        if ok and cfg.on_self_cast then cfg.on_self_cast(item_name, me) end
        if tlog then
            tlog(1, short .. "_fired", {
                angle = string.format("%.0f", angle), phase = "immediate",
            })
        end
        return nil, ok
    end
    local moved = cfg.safe_issue {
        hero = cfg.hero_key, layer = layer,
        intent = intent .. "_turnaway",
        order_type = UO.DOTA_UNIT_ORDER_MOVE_TO_POSITION,
        unit = me, position = away_pt,
    }
    local pending = {
        caster    = threat_caster,
        away_pt   = away_pt,
        deadline  = cfg.now() + 0.7,
        intent    = intent,
        item_name = item_name,
    }
    if tlog then
        tlog(1, short .. "_turnaway", {
            angle = string.format("%.0f", angle),
            caster = (threat_caster and cfg.uname
                      and cfg.uname(threat_caster)) or "centroid",
        })
    end
    return pending, moved
end

---Tick the self-push pending struct armed by Escape.TrySelfPush. Call
---once per frame from OnUpdateEx. Returns the updated pending (nil when
---fired / timed out / caster gone). Caller stashes the result back into
---its slot.
---
---Three exit paths from a non-nil pending:
---  - deadline elapsed -> emit *_turnaway_timeout, return nil
---  - caster died / TP'd -> silent drop, return nil
---  - facing within 30 deg AND item ready -> fire + emit *_fired, return nil
---  - facing still > 30 deg -> return pending (keep waiting)
---
---@param me userdata defender entity
---@param pending table|nil current pending struct (nil = nothing armed)
---@param cfg EscapeCfg hero-side callbacks
---@return table|nil updated pending (nil = consumed)
function Escape.SelfPushTick(me, pending, cfg)
    if not pending then return nil end
    if not me or not Target.IsAlive(me) then return nil end
    local short = (pending.item_name == "item_hurricane_pike")
                  and "pike_self" or "force_self"
    local tlog = cfg.tlog
    if cfg.now() > pending.deadline then
        if tlog then tlog(2, short .. "_turnaway_timeout", {}) end
        return nil
    end
    if pending.caster and not (Entity.IsEntity(pending.caster)
                               and Target.IsAlive(pending.caster)) then
        return nil
    end
    local angle_ok, angle_rad = pcall(NPC.FindRotationAngle, me,
                                       pending.away_pt)
    local angle = (angle_ok and angle_rad)
                  and math.deg(math.abs(angle_rad)) or 0
    if angle > 30 then return pending end
    local it = cfg.item_get and cfg.item_get(me, pending.item_name) or nil
    if it and cfg.item_ready and cfg.item_ready(me, pending.item_name) then
        local intent = (pending.intent or short) .. "_aligned"
        if cfg.issue_item_self(intent, cfg.layer or "def", it) then
            if cfg.on_self_cast then
                cfg.on_self_cast(pending.item_name, me)
            end
            if tlog then
                tlog(1, short .. "_fired", {
                    angle = string.format("%.0f", angle), phase = "turned",
                })
            end
        end
    end
    return nil
end

---Queue a danger-aware MOVE_TO_POSITION to land Lina at a safe spot
---after an airborne save (EUL, WW). Cast happens BEFORE this call;
---this only stages the post-cast movement.
---
---Two layers of survival against baseline orbwalker preemption:
---  1. Belt: queue=true MOVE_TO_POSITION issued here. If the engine
---     honours it across airborne, Lina starts walking the instant she
---     lands.
---  2. Suspenders: returns a pending struct the caller feeds to
---     Escape.PostAirborneMoveTick. The tick re-issues MOVE_TO_POSITION
---     every ~100ms with a unique intent (bypasses safe_issue dedup) so
---     the brain's order dominates the most-recent-order tiebreaker
---     against baseline USER MOVEs.
---
---moves_during_airborne switches tick semantics:
---  true (WW per Liquipedia: 300 MS fixed, free pathing) -> reissue
---       WHILE the modifier is present; Lina travels mid-lift.
---  false (EUL per Liquipedia: full disable, no horizontal movement)
---        -> defer reissues until the modifier clears; orders during
---        the disable would no-op.
---
---Returns nil when no safe destination exists (Lina lands in place;
---the save still served its purpose by surviving the threat).
---
---@param me userdata defender entity
---@param intent string intent prefix (intent .. "_post_move" is the tlog)
---@param push_dist number distance the post-airborne walk should cover
---@param threat_caster userdata|nil specific threat, if known
---@param modifier_name string airborne modifier (e.g. "modifier_eul_cyclone")
---@param moves_during_airborne boolean see above
---@param cfg EscapeCfg hero-side callbacks
---@return table|nil pending struct to stash (nil = no safe dest)
function Escape.QueueSafePostMove(me, intent, push_dist, threat_caster,
                                  modifier_name, moves_during_airborne, cfg)
    if not (me and cfg) then return nil end
    local _, landing = Escape.ComputeSafeDest(me, threat_caster, push_dist)
    if not landing then return nil end
    cfg.safe_issue {
        hero = cfg.hero_key, layer = cfg.layer or "def",
        intent = intent .. "_post_move",
        order_type = UO.DOTA_UNIT_ORDER_MOVE_TO_POSITION,
        unit = me, position = landing,
        queue = true,
    }
    local pending = {
        dest                  = landing,
        modifier_name         = modifier_name,
        moves_during_airborne = moves_during_airborne or false,
        deadline              = cfg.now() + 7.0,
        intent                = intent,
        observed_airborne     = false,
        last_reissue_t        = 0,
        reissue_seq           = 0,
    }
    if cfg.tlog then
        cfg.tlog(1, intent .. "_post_move", {
            x = string.format("%.0f", landing.x),
            y = string.format("%.0f", landing.y),
            caster = (threat_caster and cfg.uname
                      and cfg.uname(threat_caster)) or "centroid",
            movable = (moves_during_airborne and "y") or "n",
        })
    end
    return pending
end

---Tick the post-airborne move pending struct armed by Escape.QueueSafe-
---PostMove. Call once per frame from OnUpdateEx. Three phases:
---  1. Wait for the airborne modifier to appear at least once (cast
---     takes a few frames to resolve into the modifier; without this
---     latch the tick fires MOVE before the cast lands).
---  2. While airborne AND moves_during_airborne=false -> defer.
---  3. Airborne ended OR moves_during_airborne=true -> reissue MOVE_TO_
---     POSITION every ~100ms until Lina is within 100u of dest OR the
---     7s deadline expires. Unique intent each call (intent .. "_post_
---     move_fire_" .. seq) bypasses safe_issue's identifier dedup.
---
---Returns the updated pending (nil when arrived / expired / Lina died).
---
---@param me userdata defender entity
---@param pending table|nil current pending struct (nil = nothing armed)
---@param cfg EscapeCfg hero-side callbacks
---@return table|nil updated pending (nil = consumed)
function Escape.PostAirborneMoveTick(me, pending, cfg)
    if not pending then return nil end
    if not me or not Target.IsAlive(me) then return nil end
    local tlog = cfg.tlog
    if cfg.now() > pending.deadline then
        if tlog then
            tlog(2, pending.intent .. "_post_move_expired",
                 { reissues = pending.reissue_seq or 0 })
        end
        return nil
    end
    local airborne = NPC.HasModifier
                     and NPC.HasModifier(me, pending.modifier_name) or false
    if airborne then
        pending.observed_airborne = true
        if not pending.moves_during_airborne then return pending end
    elseif not pending.observed_airborne then
        return pending
    end
    local me_pos = Entity.GetAbsOrigin(me)
    if me_pos then
        local dx = me_pos.x - pending.dest.x
        local dy = me_pos.y - pending.dest.y
        if (dx * dx + dy * dy) < (100 * 100) then
            if tlog then
                tlog(1, pending.intent .. "_post_move_arrived", {
                    reissues = pending.reissue_seq or 0,
                    x = string.format("%.0f", me_pos.x),
                    y = string.format("%.0f", me_pos.y),
                })
            end
            return nil
        end
    end
    if (cfg.now() - (pending.last_reissue_t or 0)) < 0.1 then
        return pending
    end
    pending.last_reissue_t = cfg.now()
    pending.reissue_seq    = (pending.reissue_seq or 0) + 1
    cfg.safe_issue {
        hero = cfg.hero_key, layer = cfg.layer or "def",
        intent = pending.intent .. "_post_move_fire_" .. pending.reissue_seq,
        order_type = UO.DOTA_UNIT_ORDER_MOVE_TO_POSITION,
        unit = me, position = pending.dest,
    }
    if pending.reissue_seq == 1 and tlog then
        tlog(1, pending.intent .. "_post_move_fired", {
            x = string.format("%.0f", pending.dest.x),
            y = string.format("%.0f", pending.dest.y),
        })
    end
    return pending
end

----------------------------------------------------------------------------
-- v0.5.76: PIKE-ADVANCE RISK ANALYSIS (offensive counterpart to ComputeSafeDest)
----------------------------------------------------------------------------
---
---ComputeSafeDest answers "where should I escape TO" (away from threat).
---ComputeAdvanceDest answers the inverse: "is it safe to push TOWARD this
---enemy, and where do I land if I do". Built for Pike self-cast offensive
---use (push 600u along facing-toward-target) but the geometry helper is
---reusable for any directional push (Force Staff offensive, etc).
---
---Risk includes BOTH visible enemies near the landing AND fog enemies whose
---probable-position cone (last-known-pos + max travel since last seen)
---overlaps the landing. The fog component answers the user's specific ask:
---"check up for possible heroes on the fog might be on PI last seen
---enemies". Uses Hero.GetLastMaphackPos + Hero.GetLastVisibleTime per
---API_GOTCHAS: nil GetLastVisibleTime means never-fogged (fresh visible),
---treated as age=0.

---Max enemy move speed cap for fog probable-radius growth. 700 = generous
---ceiling for any hero with movement items / talents / haste. Going much
---higher just makes the cone meaningless (after 10s any fog enemy could be
---"anywhere within 7000u" which scores every landing identically). 30s cap
---on age keeps the radius bounded even for very-stale-fog enemies.
local PROBE_MAX_MS = 700
local PROBE_MAX_AGE_S = 30

---Enumerate enemy heroes whose CURRENT possible position could be within
---`radius` of `pos`. Visible enemies always count (age = 0, probable_radius
---= 0). Fogged enemies count when (probable_radius + dist(last_pos, pos))
---<= radius, i.e. the probable-position circle reaches the engage zone.
---
---Returns a unified list so callers can score visible and fog with
---different weights (see AdvanceRiskScore).
---
---@param me userdata defender / advancer entity (team-membership lookup only)
---@param pos userdata position to score around
---@param radius number engagement radius (e.g. 800 for Pike landing risk)
---@param opts table|nil {max_ms=700, now=fn()->seconds}
---@return integer visible_count
---@return integer fog_count
---@return table list of {entity, last_pos, age, probable_radius, visible}
function Escape.NearbyEnemiesIncludingFog(me, pos, radius, opts)
    if not (me and pos and radius) then return 0, 0, {} end
    opts = opts or {}
    local max_ms = opts.max_ms or PROBE_MAX_MS
    local now_fn = opts.now or function() return GlobalVars.GetCurTime() end
    local team   = Entity.GetTeamNum(me)
    local out, seen = {}, {}
    local v_cnt, f_cnt = 0, 0

    -- Visible: Heroes.InRadius is the canonical proximity API. omitDormant
    -- defaults true so we only see currently-visible enemies here.
    local visible = Heroes.InRadius(pos, radius, team, Enum.TeamType.TEAM_ENEMY)
    if visible then
        for i = 1, #visible do
            local e = visible[i]
            if e and Target.IsAlive(e) and Target.NotIllusion(e) then
                local ep = Entity.GetAbsOrigin(e)
                if ep then
                    seen[e] = true
                    v_cnt = v_cnt + 1
                    out[#out + 1] = {
                        entity = e, last_pos = ep, age = 0,
                        probable_radius = 0, visible = true,
                    }
                end
            end
        end
    end

    -- Fog: walk Heroes.GetAll() for enemies not in the visible set above.
    -- Hero.GetLastMaphackPos returns nil for heroes never seen; Hero.Get-
    -- LastVisibleTime returns nil for never-fogged (gotcha: nil = "fresh
    -- visible", treat as age=0 per API_GOTCHAS).
    if Heroes.GetAll then
        local all = Heroes.GetAll() or {}
        for i = 1, #all do
            local e = all[i]
            if e and not seen[e]
               and Entity.GetTeamNum(e) ~= team
               and Target.IsAlive(e) and Target.NotIllusion(e) then
                local last_pos = Hero.GetLastMaphackPos
                                 and Hero.GetLastMaphackPos(e) or nil
                local last_t   = Hero.GetLastVisibleTime
                                 and Hero.GetLastVisibleTime(e) or nil
                local age = (last_t and (now_fn() - last_t)) or 0
                if age < 0 then age = 0 end
                if age > PROBE_MAX_AGE_S then age = PROBE_MAX_AGE_S end
                local probable_radius = age * max_ms
                if last_pos then
                    local d = pos:Distance2D(last_pos)
                    if d <= probable_radius + radius then
                        f_cnt = f_cnt + 1
                        out[#out + 1] = {
                            entity = e, last_pos = last_pos,
                            age = age, probable_radius = probable_radius,
                            visible = false,
                        }
                    end
                end
            end
        end
    end

    return v_cnt, f_cnt, out
end

---Composite risk score for a candidate landing position. Lower is safer;
---0 = no enemies in or near the engage radius.
---
---Components:
---  visible_score: for each visible enemy in engage_radius, add
---    (1 - dist/engage_radius) * 30  -- max 30 per enemy at zero distance
---  fog_score: 15 per fog enemy whose probable-position circle overlaps
---    engage_radius (half-weighted -- uncertainty discount).
---
---Default engage_radius = 800u (typical Pike-landing follow-up range).
---Suggested threshold: <= 30 safe-to-advance, 30-60 risky-but-survivable,
--->60 abort. Caller picks the threshold; lib only scores.
---
---@param me userdata
---@param landing userdata candidate position
---@param opts table|nil {engage_radius=800, max_ms=700, now=fn}
---@return number score
---@return table breakdown {visible_score, fog_score, visible_count, fog_count, engage_radius, enemies}
function Escape.AdvanceRiskScore(me, landing, opts)
    if not (me and landing) then
        return math.huge, { visible_score = 0, fog_score = 0,
                            visible_count = 0, fog_count = 0,
                            engage_radius = 0, enemies = {} }
    end
    opts = opts or {}
    local engage_radius = opts.engage_radius or 800
    local v_cnt, f_cnt, list =
        Escape.NearbyEnemiesIncludingFog(me, landing, engage_radius, opts)
    local visible_score, fog_score = 0, 0
    for i = 1, #list do
        local e = list[i]
        if e.visible then
            local d = landing:Distance2D(e.last_pos)
            local frac = d / engage_radius
            if frac > 1 then frac = 1 end
            visible_score = visible_score + (1 - frac) * 30
        else
            fog_score = fog_score + 15
        end
    end
    return visible_score + fog_score, {
        visible_score = visible_score,
        fog_score     = fog_score,
        visible_count = v_cnt,
        fog_count     = f_cnt,
        engage_radius = engage_radius,
        enemies       = list,
    }
end

---Deterministic Pike self-cast landing for an OFFENSIVE advance: Lina
---fires Pike facing toward target_pos, lands push_dist units along that
---facing. Geometry is the same for any directional self-push item (Force
---Staff offensive, future displacement items). Pike push_dist is 600u.
---
---Returns nil when me_pos == target_pos (zero direction; can't pick a
---facing).
---
---@param me_pos userdata defender position
---@param target_pos userdata target position to advance toward
---@param push_dist number distance the item will push (Pike = 600)
---@return userdata|nil landing
function Escape.PikeAdvanceLanding(me_pos, target_pos, push_dist)
    if not (me_pos and target_pos and push_dist and push_dist > 0) then
        return nil
    end
    local diff = target_pos - me_pos
    if diff:Length2DSqr() < 1 then return nil end
    local dir = diff:Normalized()
    return me_pos + dir * push_dist
end

---Pike-advance pick: compute landing for a self-cast Pike toward `target`,
---score risk, return (landing, score, breakdown) for caller to decide
---fire / skip. Returns (nil, nil, nil) when target invalid or zero
---direction. Lib does NOT issue any orders -- this is a pure decision-
---support primitive.
---
---target may be a hero entity (userdata, IsAlive-checked) or a Vector
---world position; the function dispatches accordingly.
---
---Pairs naturally with the AdvanceRiskScore threshold check:
---  local landing, score, brk = Escape.ComputeAdvanceDest(me, hero, 600)
---  if landing and score <= 30 then  -- caller-chosen threshold
---      fire_pike_self()
---  end
---
---@param me userdata
---@param target userdata|userdata entity (hero) OR Vector position
---@param push_dist number typically 600 for Pike
---@param opts table|nil see AdvanceRiskScore
---@return userdata|nil landing
---@return number|nil score
---@return table|nil breakdown
function Escape.ComputeAdvanceDest(me, target, push_dist, opts)
    if not (me and target and push_dist) then return nil, nil, nil end
    local me_pos = Entity.GetAbsOrigin(me)
    if not me_pos then return nil, nil, nil end
    local target_pos
    if type(target) == "userdata"
       and Entity.IsEntity and Entity.IsEntity(target) then
        if not (Target.IsAlive and Target.IsAlive(target)) then
            return nil, nil, nil
        end
        target_pos = Entity.GetAbsOrigin(target)
    else
        target_pos = target
    end
    if not target_pos then return nil, nil, nil end
    local landing = Escape.PikeAdvanceLanding(me_pos, target_pos, push_dist)
    if not landing then return nil, nil, nil end
    local score, breakdown = Escape.AdvanceRiskScore(me, landing, opts)
    return landing, score, breakdown
end

return Escape
