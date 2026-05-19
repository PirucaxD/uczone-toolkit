---@meta
---lib/menu.lua - a small builder over Menu.Create / CMenuGroup.
---
---Building a menu by hand means three chores repeated for every widget:
---calling `Menu.Create` for the group, holding onto each widget handle in
---its own variable, and making the whole thing safe to run twice (a script
---reload must not stack a second copy of every widget).
---
---This wraps that up. You ask a `panel` for a widget by name; it creates it
---the first time and hands back the SAME widget every call after - so a
---reload re-attaches to the existing widgets instead of duplicating them,
---and you never have to keep a handle yourself. Read a value back by name
---with `:get()`.
---
---```lua
---local menu  = require("lib.menu")
---local cfg   = menu.panel("Heroes", "Hero List", "Lina", "Brain", "Core")
---cfg:switch("Enable brain", true)
---cfg:slider("Aggression", 0, 100, 60, "%d%%")
---cfg:bind("Combo key")
---
---if cfg:get("Enable brain") then
---    local aggression = cfg:get("Aggression")
---    if cfg:down("Combo key") then ... end
---end
---```
---
---The widget-creation calls mirror the framework API one-to-one, so the
---argument order is whatever `CMenuGroup:Switch/Slider/Bind/...` expects.

local M = {}

-- one wrapper per tab path, so two panel() calls for the same path share
-- the same widget registry
local panels = {}

----------------------------------------------------------------------------
-- panel object
----------------------------------------------------------------------------

local Panel = {}
Panel.__index = Panel

-- Find an existing widget by name, so a re-run of setup re-attaches instead
-- of creating a duplicate. Returns the cached handle, then the group's own
-- Find, then nil.
local function existing(self, name)
    local w = self.w[name]
    if w ~= nil then return w end
    if self.group and self.group.Find then
        local ok, found = pcall(self.group.Find, self.group, name)
        if ok and found then
            self.w[name] = found
            return found
        end
    end
    return nil
end

---The raw `CMenuGroup` this panel wraps, in case you need an API method
---the wrapper does not expose.
---@return userdata|nil
function Panel:raw() return self.group end

---A boolean toggle. Returns the `CMenuSwitch`.
---@param name string
---@param default boolean|nil
---@param icon string|nil
---@return userdata
function Panel:switch(name, default, icon)
    local w = existing(self, name)
    if not w then
        w = self.group:Switch(name, default and true or false, icon or "")
        self.w[name] = w
    end
    return w
end

---An integer / float slider. Returns the slider widget.
---@param name string
---@param min number
---@param max number
---@param default number
---@param fmt string|nil  format string or function, e.g. "%d" or "%d%%"
---@return userdata
function Panel:slider(name, min, max, default, fmt)
    local w = existing(self, name)
    if not w then
        w = self.group:Slider(name, min, max, default, fmt)
        self.w[name] = w
    end
    return w
end

---A key bind. Returns the `CMenuBind`.
---@param name string
---@param default_key integer|nil  an Enum.ButtonCode
---@param icon string|nil
---@return userdata
function Panel:bind(name, default_key, icon)
    local w = existing(self, name)
    if not w then
        w = self.group:Bind(name, default_key, icon or "")
        self.w[name] = w
    end
    return w
end

---A dropdown. `items` is a string array; `default` is a 0-based index.
---Returns the `CMenuComboBox`.
---@param name string
---@param items string[]
---@param default integer|nil
---@return userdata
function Panel:combo(name, items, default)
    local w = existing(self, name)
    if not w then
        w = self.group:Combo(name, items, default or 0)
        self.w[name] = w
    end
    return w
end

---A clickable button. `callback` receives the button widget.
---@param name string
---@param callback fun(widget: userdata)
---@param alt_style boolean|nil
---@param width number|nil  0.0-1.0
---@return userdata
function Panel:button(name, callback, alt_style, width)
    local w = existing(self, name)
    if not w then
        w = self.group:Button(name, callback, alt_style, width)
        self.w[name] = w
    end
    return w
end

---A static text label. The text doubles as its lookup key.
---@param text string
---@param icon string|nil
---@return userdata
function Panel:label(text, icon)
    local w = existing(self, text)
    if not w then
        w = self.group:Label(text, icon or "")
        self.w[text] = w
    end
    return w
end

---The widget registered under `name`, or nil if it was never created.
---@param name string
---@return userdata|nil
function Panel:find(name) return existing(self, name) end

---Read a widget's value by name. Works for switch / slider / combo (their
---`:Get()`), and returns nil for an unknown name. For a key bind use
---`:down` / `:pressed` / `:toggled` instead - a bind's `:Get()` is a key
---code, not an on/off state.
---@param name string
---@return any
function Panel:get(name)
    local w = existing(self, name)
    if w and w.Get then
        local ok, v = pcall(w.Get, w)
        if ok then return v end
    end
    return nil
end

---True while the named bind's key is held down.
---@param name string
---@return boolean
function Panel:down(name)
    local w = existing(self, name)
    return (w and w.IsDown and w:IsDown()) or false
end

---True on the frame the named bind's key is first pressed.
---@param name string
---@return boolean
function Panel:pressed(name)
    local w = existing(self, name)
    return (w and w.IsPressed and w:IsPressed()) or false
end

---The named bind's toggle state (a bind flips this each press).
---@param name string
---@return boolean
function Panel:toggled(name)
    local w = existing(self, name)
    return (w and w.IsToggled and w:IsToggled()) or false
end

----------------------------------------------------------------------------
-- entry point
----------------------------------------------------------------------------

---Get a panel for a menu location. The five strings are the tab path the
---framework's `Menu.Create` expects (first tab / section / second tab /
---third tab / group). Calling this twice for the same path returns the
---same panel, so you can split menu setup across files.
---@param t1 string
---@param section string
---@param t2 string
---@param t3 string
---@param group string
---@return table  a Panel
function M.panel(t1, section, t2, t3, group)
    local key = table.concat({ t1, section, t2, t3, group }, "\1")
    local p = panels[key]
    if p then return p end
    p = setmetatable({
        group = Menu.Create(t1, section, t2, t3, group),
        w = {},
    }, Panel)
    panels[key] = p
    return p
end

return M
