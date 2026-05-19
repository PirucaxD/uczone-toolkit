# menu

Building a menu by hand means three chores repeated for every widget: calling
`Menu.Create` for the group, holding each widget handle in its own variable,
and making the whole thing safe to run twice (a script reload must not stack
a second copy of every widget).

This lib wraps that up into a **panel**. You ask a panel for a widget by name;
it creates the widget the first time and returns the *same* widget every call
after. So a reload re-attaches to the existing widgets instead of duplicating
them, and you never keep a handle yourself.

## Getting a panel

```lua
local menu = require("lib.menu")
local cfg  = menu.panel("Heroes", "Hero List", "Lina", "Brain", "Core")
```

The five strings are the tab path `Menu.Create` expects. Calling `panel(...)`
again with the same path returns the same panel, so you can split menu setup
across files.

## Adding widgets

Each method creates the widget (or returns the existing one) and registers it
under its name. Arguments mirror the framework's `CMenuGroup` methods.

| Method | Widget |
|--------|--------|
| `:switch(name, default, icon)` | on/off toggle |
| `:slider(name, min, max, default, fmt)` | numeric slider |
| `:bind(name, default_key, icon)` | key bind |
| `:combo(name, items, default)` | dropdown |
| `:button(name, callback, alt, width)` | clickable button |
| `:label(text, icon)` | static text |

## Reading values

| Method | Returns |
|--------|---------|
| `:get(name)` | the widget's value — for switch / slider / combo |
| `:down(name)` | bool: is this bind's key held down |
| `:pressed(name)` | bool: was it pressed this frame |
| `:toggled(name)` | bool: the bind's toggle state |
| `:find(name)` | the raw widget handle, or `nil` |
| `:raw()` | the underlying `CMenuGroup` |

## Example

```lua
local menu = require("lib.menu")
local cfg  = menu.panel("Heroes", "Hero List", "Lina", "Brain", "Core")

cfg:switch("Enable brain", true)
cfg:slider("Aggression", 0, 100, 60, "%d%%")
cfg:bind("Combo key")

-- later, every frame:
if cfg:get("Enable brain") and cfg:down("Combo key") then
    local aggression = cfg:get("Aggression")
    ...
end
```
