---@meta
---lib/shove.lua - crash-push cast geometry (perpendicular-to-creep-line March). Hero-agnostic, PURE:
---no engine calls, no clock. The hero passes plain {x,y} data in. The shove DECISION now lives in
---lib/schedule (Schedule.Plan); this file is just the cast geometry. See Tinker/TINKER_SCHEDULE_DESIGN.md.
local Shove = {}

---pure geometry for the crash-push March. stand = the enemy-wave centroid offset back toward the
---fountain by `standback` (matches update_wave_spot); `perp` = the unit vector PERPENDICULAR to the
---creep line (the hero offsets the multi-W casts along it so the robot sweep crosses the creep line
---for max hits); cast_point = a point `cast_ahead` from the stand toward the centroid (the base aim,
---before the hero applies the +/- perp offset). Degenerate dir -> perp {0,0}, cast at the centroid.
---@param clash_centroid table {x,y}
---@param creep_line_dir table {x,y}  the direction the creep line runs (need not be normalized)
---@param opts table|nil { standback?, cast_ahead?, fountain? }
---@return table { stand{x,y}, cast_point{x,y}, perp{x,y} }
function Shove.CrashCast(clash_centroid, creep_line_dir, opts)
    opts = opts or {}
    local standback = opts.standback or 900
    local cast_ahead = opts.cast_ahead or 280
    local c = clash_centroid

    local stand = { x = c.x, y = c.y }
    local fo = opts.fountain
    if fo then
        local dx, dy = fo.x - c.x, fo.y - c.y
        local dl = math.sqrt(dx * dx + dy * dy)
        if dl > 1 then
            local back = math.min(standback, dl)
            stand = { x = c.x + dx / dl * back, y = c.y + dy / dl * back }
        end
    end

    local lx, ly = (creep_line_dir and creep_line_dir.x) or 0, (creep_line_dir and creep_line_dir.y) or 0
    local ll = math.sqrt(lx * lx + ly * ly)
    local perp = (ll >= 1e-6) and { x = -ly / ll, y = lx / ll } or { x = 0, y = 0 }

    local sx, sy = c.x - stand.x, c.y - stand.y
    local sl = math.sqrt(sx * sx + sy * sy)
    local cast_point
    if sl < 1 then cast_point = { x = c.x, y = c.y }
    else cast_point = { x = stand.x + sx / sl * cast_ahead, y = stand.y + sy / sl * cast_ahead } end

    return { stand = stand, cast_point = cast_point, perp = perp }
end

return Shove
