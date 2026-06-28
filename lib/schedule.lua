---@meta
---lib/schedule.lua - timing-anchored shove-cycle controller. Hero-agnostic, PURE: no engine calls, no
---clock, no loop. The hero assembles plain data (from lib/lane records + engine reads) and passes it in.
---Mirrors lib/route / lib/lane. See Tinker/TINKER_SCHEDULE_DESIGN.md.
local Schedule = {}

---hybrid clear-time: compute the cast COUNT from wave eff-HP / March damage (self-adjusting), with
---calibrated wall-clock per-cast durations. Pure.
---@param eff_hp number   the mid wave's effective HP (visible sum, or ExpectedWave when fogged)
---@param cal table { march_dmg_per_cast, cast_dur, robot_kill, rearm_channel }
---@return table { casts, t_clear }
function Schedule.ClearTime(eff_hp, cal)
    cal = cal or {}
    local dmg = cal.march_dmg_per_cast or 1
    if dmg <= 0 then dmg = 1 end
    -- Round to NEAREST, not up (N5): on a shove the wave is a CLASH, so our own
    -- creeps + tower clean a sub-half-cast remainder. ceil added a whole wasteful
    -- March (and ~1 rearm gap of cycle time) for a tiny leftover; round-half-up
    -- keeps the cast count honest. A genuine remainder the allies cannot finish is
    -- caught by the live wave-clear early-exit in the engage.
    local casts = math.max(1, math.floor((eff_hp or 0) / dmg + 0.5))
    local t_clear = casts * ((cal.cast_dur or 0) + (cal.robot_kill or 0))
                  + (casts - 1) * (cal.rearm_channel or 0)
    return { casts = casts, t_clear = t_clear }
end

---the cycle decision. CLOCK-INDEPENDENT: arrival must be `now + relative ETA` so `now` cancels in slack.
---ctx = { now, wave={arrival,eff_hp,present}, cal, travel_to_mid, mana, shove_cost, safe }.
---@return table { action="shove"|"jungle"|"recover", deadline, leave_by, slack, casts, t_clear, reason }
function Schedule.Plan(ctx)
    ctx = ctx or {}
    local wave = ctx.wave or {}
    local cl = Schedule.ClearTime(wave.eff_hp, ctx.cal)
    local lead = (ctx.cal and ctx.cal.lead) or 0
    local arrival = wave.arrival or 0
    local leave_by = arrival - (ctx.travel_to_mid or 0) - lead
    local slack = leave_by - (ctx.now or 0)

    local action, reason
    if not ctx.safe then                                action, reason = "recover", "unsafe"
    elseif (ctx.mana or 0) < (ctx.shove_cost or 0) then action, reason = "recover", "mana"
    elseif slack <= 0 then                              action, reason = "shove", "due"
    else                                                action, reason = "jungle", "slack" end

    return { action = action, deadline = arrival, leave_by = leave_by, slack = slack,
             casts = cl.casts, t_clear = cl.t_clear, reason = reason }
end

return Schedule
