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

local Target = require("lib.target")

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

return Escape
