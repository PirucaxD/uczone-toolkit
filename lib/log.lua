---@meta
---lib/log.lua - leveled logging with rate limiting.
---
---The framework already ships a `Logger` class that does leveled logging:
---`debug` / `info` / `warning` / `error` methods, a per-logger name, and a
---`[LEVEL] [name]` prefix on every line. There is no reason to rebuild that,
---so this lib sits straight on top of it.
---
---What it adds is the one thing `Logger` does not have: **rate limiting**.
---In a brain that runs every frame, an unguarded log line turns into
---thousands of lines a second. `throttled()` emits at most once per
---interval, `once()` emits a single time. That is the actual value here.
---
---```lua
---local log = require("lib.log")
---log.set_level(log.INFO)             -- hide debug spam in a release build
---local clog = log.tag("combo")
---clog.info("engaged", target_name)
---clog.throttled("wait", 1.0, log.DEBUG, "still waiting for cooldown")
---```
---
---If the framework `Logger` global is not present (a plain Lua test run) it
---falls back to `Log.Write` / `print`, so the same code runs in a harness.

local M = {}

----------------------------------------------------------------------------
-- levels
----------------------------------------------------------------------------

M.DEBUG  = 1
M.INFO   = 2
M.WARN   = 3
M.ERROR  = 4
M.SILENT = 5   -- set as the threshold to mute everything

local LEVEL_NAME    = { "DEBUG", "INFO", "WARN", "ERROR" }
-- our level index -> the matching native Logger method name
local NATIVE_METHOD = { "debug", "info", "warning", "error" }

-- The threshold lives here, not on the native logger: it keeps the level
-- scale stable and testable, and it is the scale `throttled()` reports
-- against. Filtering is a single integer compare; the native logger owns
-- the part that is actually worth delegating (formatting and output).
local threshold = M.INFO

---Set the minimum level that will be printed. Calls below it are skipped
---before the message is ever formatted.
---@param level integer  M.DEBUG / M.INFO / M.WARN / M.ERROR / M.SILENT
function M.set_level(level)
    if type(level) == "number" then threshold = level end
end

---The current threshold level.
---@return integer
function M.get_level() return threshold end

----------------------------------------------------------------------------
-- internals
----------------------------------------------------------------------------

-- the native Logger is a global constructor inside the framework; absent in
-- a plain Lua test run, where we fall back to Log.Write / print
local has_native = (type(Logger) == "function")

local function now()
    if GlobalVars and GlobalVars.GetCurTime then
        local ok, t = pcall(GlobalVars.GetCurTime)
        if ok and t then return t end
    end
    return os.clock()
end

-- fallback formatter, only used when the native Logger is unavailable
local function fallback(name, level, ...)
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do parts[i] = tostring((select(i, ...))) end
    local prefix = "[" .. LEVEL_NAME[level] .. "] "
    if name ~= "" then prefix = prefix .. "[" .. name .. "] " end
    local line = prefix .. table.concat(parts, " ")
    if Log and Log.Write then Log.Write(line)
    elseif print then print(line) end
end

----------------------------------------------------------------------------
-- a logger object - the module itself is the default (untagged) logger
----------------------------------------------------------------------------

local function build(name)
    local L = {}
    local native = has_native and Logger(name ~= "" and name or "log") or nil

    -- one place that level-gates, then hands off to the native logger
    local function out(level, ...)
        if level < threshold then return end
        if native then
            native[NATIVE_METHOD[level]](native, ...)
        else
            fallback(name, level, ...)
        end
    end

    function L.debug(...) out(M.DEBUG, ...) end
    function L.info(...)  out(M.INFO,  ...) end
    function L.warn(...)  out(M.WARN,  ...) end
    function L.error(...) out(M.ERROR, ...) end

    -- per-logger throttle bookkeeping
    local last = {}

    ---Emit at most once per `interval` seconds for a given `key`. Put this
    ---inside a per-frame loop where a plain log call would spam.
    ---@param key string       a stable id for this log site
    ---@param interval number  minimum seconds between emits
    ---@param level integer    M.DEBUG / M.INFO / M.WARN / M.ERROR
    function L.throttled(key, interval, level, ...)
        local t = now()
        local prev = last[key]
        if prev and (t - prev) < (interval or 1) then return end
        last[key] = t
        out(level or M.INFO, ...)
    end

    ---Emit a single time ever, for a given `key`. Good for "this path was
    ---reached" / one-off warnings you do not want repeated.
    ---@param key string
    ---@param level integer
    function L.once(key, level, ...)
        if last[key] ~= nil then return end
        last[key] = now()
        out(level or M.INFO, ...)
    end

    ---Drop throttle/once history (so a throttled key may fire again).
    ---Pass a key to clear just that one, or nothing to clear all.
    ---@param key string|nil
    function L.reset(key)
        if key == nil then last = {} else last[key] = nil end
    end

    return L
end

-- the module table doubles as the default, untagged logger
local default = build("")
M.debug, M.info, M.warn, M.error =
    default.debug, default.info, default.warn, default.error
M.throttled, M.once, M.reset =
    default.throttled, default.once, default.reset

---Create a sub-logger with its own name (the native Logger's `[name]`
---prefix) and its own throttle history.
---@param name string
---@return table  a logger with the same methods as the module
function M.tag(name)
    return build(name)
end

return M
