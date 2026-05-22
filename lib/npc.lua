---@meta
---lib/npc.lua - generic NPC stat & inventory queries.
---
---Hero-agnostic. Each function takes an npc handle as the first argument.
---Small on purpose - it covers the two checks every brain ends up needing:
---  - Aghanim's Shard / Scepter ownership
---  - item lookup + off-cooldown checks
---
---Every getter is nil-safe: pass a nil handle and you get a falsy result
---back instead of a crash, so you can skip the guard at the call site.

local NPC_lib = {}

---Aghanim's Shard ownership.
---@param npc userdata|nil
---@return boolean
function NPC_lib.has_shard(npc)
    if not npc then return false end
    return (NPC.HasShard and NPC.HasShard(npc)) or false
end

---Aghanim's Scepter ownership.
---@param npc userdata|nil
---@return boolean
function NPC_lib.has_scepter(npc)
    if not npc then return false end
    return (NPC.HasScepter and NPC.HasScepter(npc)) or false
end

---Item lookup by name. Defaults to INVENTORY ONLY (the six active slots,
---not backpack/stash) - that is what you almost always want. Pass
---`inventory_only = false` to also scan backpack + stash.
---@param npc userdata|nil
---@param name string
---@param inventory_only? boolean (default true)
---@return userdata|nil
function NPC_lib.item(npc, name, inventory_only)
    if not npc or not name then return nil end
    if inventory_only == nil then inventory_only = true end
    return NPC.GetItem(npc, name, inventory_only)
end

---Item is owned AND ready (off cooldown, etc.). Inventory-only by default.
---@param npc userdata|nil
---@param name string
---@param inventory_only? boolean (default true)
---@return boolean
function NPC_lib.item_ready(npc, name, inventory_only)
    local it = NPC_lib.item(npc, name, inventory_only)
    return it ~= nil and Ability.IsReady(it)
end

---Stale-safe absolute-origin read. `Entity.GetAbsOrigin` THROWS
---("arg is not an Entity") on a stale / garbage handle; `Entity.IsEntity`
---rejects that. The result is STILL nilable - a valid but dead or
---mid-respawn entity returns nil - so callers must still nil-check the
---return. This is the typed safe-read for the throw-on-stale-handle case.
---@param e userdata|nil
---@return userdata|nil  Vector position, or nil if e is invalid / dead
function NPC_lib.origin(e)
    if not e or not Entity.IsEntity(e) then return nil end
    return Entity.GetAbsOrigin(e)
end

---Safe ability-name read. `Ability.GetName` throws on a real entity that
---is not an ability (the typical case is an item handle resolved from a
---native order queue's abilityIndex). `pcall` is the correct guard for a
---throw-on-valid-entity API; an `IsEntity` check alone is not enough.
---@param ab userdata|nil
---@return string|nil  the ability name, or nil on a bad / nameless handle
function NPC_lib.ability_name(ab)
    if not ab then return nil end
    local ok, n = pcall(Ability.GetName, ab)
    return (ok and type(n) == "string" and n ~= "") and n or nil
end

return NPC_lib
