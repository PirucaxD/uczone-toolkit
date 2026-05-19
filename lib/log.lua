---@meta
---lib/log.lua - leveled, throttled logging on top of Log.Write.
---
---`Log.Write` puts a line in the console and that is it - no levels, no
---rate limiting. In a brain that runs every frame, an unguarded log line
---becomes thousands of lines a second and drowns out everything useful.
---
---This module adds the three things you actually want:
---  - **levels**    debug / info / warn / error, with a threshold so you
---                  can silence the noisy ones without deleting the calls.
---  - **throttling** `throttled()` emits at most once per interval, `once()`
---                  emits a single time - for stuff inside a hot loop.
---  - **tags**      `tag("combo")` gives you a sub-logger that prefixes
---                  every line, so you can tell which system spoke.
---
---Suggested use:
---```lua
---local log = require("lib.log")
---log.set_level(log.INFO)            -- hide debug spam in a release build
---local clog = log.tag("combo")
---clog.info("engaged", target_name)
---clog.throttled("wait", 1.0, log.DEBUG, "still waiting for cooldown")
---```
---
---Falls back to `print` if the framework `Log` global is not present, so
---the same code runs in a plain Lua test harness.

local M = {}

----------------------------------------------------------------------------
-- levels
----------------------------------------------------------------------------

M.DEBUG  = 1
M.INFO   = 2
M.WARN   = 3
M.ERROR  = 4
M.SILENT = 5   -- set as the threshold to mute everything

local LEVEL_NAME = { [1] = "DEBUG", [2] = "INFO", [3] = "WARN", [4] = "ERROR" }

local threshold = M.INFO

---Set the minimum level that will be printed. Calls below it are skipped
---cheaply (the message is never even formatted).
---@param level integer  one of M.DEBUG / M.INFO / M.WARN / M.ERROR / M.SILENT
function M.set_level(level)
    if type(level) == "number" then threshold = level end
end

---The current threshold level.
---@return integer
function M.get_level() return threshold end

----------------------------------------------------------------------------
-- internals
----------------------------------------------------------------------------

local function now()
    if GlobalVars and GlobalVars.GetCurTime then
        local ok, t = pcall(GlobalVars.GetCurTime)
        if ok and t then return t end
    end
    return os.clock()
end

local function sink(line)
    if Log and Log.Write then
        Log.Write(line)
    elseif print then
        print(line)
    end
end

-- Join varargs into one string, tostring-ing each piece. nil-safe.
local function join(...)
    local n = select("#", ...)
    if n == 0 then return "" end
    local parts = {}
    for i = 1, n do
        parts[i] = tostring((select(i, ...)))
    end
    return table.concat(parts, " ")
end

local function emit(level, tag, msg)
    if level < threshold then return end
    local name = LEVEL_NAME[level] or "INFO"
    if tag and tag ~= "" then
        sink("[" .. name .. "] [" .. tag .. "] " .. msg)
    else
        sink("[" .. name .. "] " .. msg)
    end
end

----------------------------------------------------------------------------
-- a logger object - the module itself is the default (untagged) logger
----------------------------------------------------------------------------

-- Build the four level methods plus throttled/once onto a logger table that
-- carries a fixed `tag`. The module table `M` is the tagless logger; `tag()`
-- produces more of the same with a prefix set.
local function build(target, tag)
    function target.debug(...) emit(M.DEBUG, tag, join(...)) end
    function target.info(...)  emit(M.INFO,  tag, join(...)) end
    function target.warn(...)  emit(M.WARN,  tag, join(...)) end
    function target.error(...) emit(M.ERROR, tag, join(...)) end

    -- per-logger throttle bookkeeping
    local last = {}

    ---Emit at most once per `interval` seconds for a given `key`. Put this
    ---inside a per-frame loop where a plain log call would spam.
    ---@param key string         a stable id for this log site
    ---@param interval number    minimum seconds between emits
    ---@param level integer      M.DEBUG / M.INFO / M.WARN / M.ERROR
    function target.throttled(key, interval, level, ...)
        local t = now()
        local prev = last[key]
        if prev and (t - prev) < (interval or 1) then return end
        last[key] = t
        emit(level or M.INFO, tag, join(...))
    end

    ---Emit a single time ever, for a given `key`. Good for "this code path
    ---was reached" / one-off warnings you do not want repeated.
    ---@param key string
    ---@param level integer
    function target.once(key, level, ...)
        if last[key] ~= nil then return end
        last[key] = now()
        emit(level or M.INFO, tag, join(...))
    end

    ---Drop throttle/once history (so a throttled key may fire again).
    ---Pass a key to clear just that one, or nothing to clear all.
    ---@param key string|nil
    function target.reset(key)
        if key == nil then last = {} else last[key] = nil end
    end

    return target
end

build(M, nil)

---Create a sub-logger that prefixes every line with `[name]`. Each tagged
---logger keeps its own throttle history, so two systems throttling the
---same key do not interfere.
---@param name string
---@return table  a logger with the same methods as the module
function M.tag(name)
    return build({}, name)
end

return M
