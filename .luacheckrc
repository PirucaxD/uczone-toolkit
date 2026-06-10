-- .luacheckrc , static-analysis config for the UCZone / Umbrella hero-brain Lua.
--
-- luacheck is NOT bundled with the framework. Install once:
--     luarocks install luacheck
-- Then run from the repo root:
--     luacheck Lina.lua lib/ tools/
--
-- This config whitelists the engine-provided globals so static analysis does
-- not drown in false "accessing undefined global" warnings, and relaxes a few
-- checks that are intentional in this codebase (very long banner line, fixed
-- callback signatures with some unused args).

std = "max"
max_line_length = false        -- the trailing LOG:info banner line is huge by design

-- Engine globals provided by the UCZone / Umbrella runtime (read-only from
-- script code). Extra names here are harmless; they only suppress
-- undefined-global warnings when referenced.
read_globals = {
  "Entity", "NPC", "NPCs", "Ability", "Item", "Hero", "Heroes", "Modifier",
  "Vector", "Enum", "GridNav", "GlobalVars", "Humanizer", "Order", "Menu",
  "LOG", "GameRules", "Players", "Player", "Engine", "Renderer", "Input",
  "Damage", "Physics", "Particle", "Sound", "Cursor", "Camera", "Tree", "Trees",
  "Unit", "Units", "Buildings", "Convars", "Time",
}

ignore = {
  "212",  -- unused argument (callbacks have fixed signatures; some args unused)
  "213",  -- unused loop variable
  "542",  -- empty if branch (intentional no-op guards)
}

-- Generated / vendored files are not hand-maintained; skip them.
exclude_files = {
  "tools/_anim_maps_generated.lua",
  "types/",
}
