# defense

A save-dispatcher with a per-threat lock domain. You give it your hero's
data (save_fire map, chain tables, overrides, filter sets) plus a cfg
of accessors at init, and after that every site in your brain that
wants to fire a save calls `Dispatch` instead of issuing the save
itself.

The reason for sharing this is the lock. When a brain has more than
one route into the save chain (an anim subscriber that fires at
cast-start, an armed-tick handler that fires at impact, a
modifier-create callback that fires on the threat's modifier landing,
a line-projectile intercept), two of those routes can see the same
threat in the same window and each independently walk the chain. The
brain ends up burning Wind Waker AND Hurricane Pike against one
charge that one save would have stopped.

`Dispatch` takes a `(target_idx, canonical_mod, caster_idx)` lock
when it fires. The second route on the same threat sees
`dispatch_blocked` with the existing fire's intent and stops without
running its chain. The lock holds for a per-threat TTL that the cfg
supplies via `cfg.eta_resolver` (typically `cast_point_remaining`
for a casted-threat, `distance / speed` for a homing close-gap, the
modifier's remaining duration for an instant disable, capped at
~2.2s for periodic re-fire patterns so the next periodic tick can
re-acquire). When the resolver does not have an entry for the
canonical mod the lock falls back to a fixed window.

## Why a *canonical* mod name

The engine often applies several sibling modifiers for the same
threat (Spirit Breaker's Charge of Darkness applies the bare name
on the caster, `_vision` on the victim, and `_target` after impact;
Tusk's Snowball applies `_movement` on the carrier and `_target` on
the victim). The anim subscriber typically sees one spelling and
the armed-tick handler the other. If the lock keyed on the raw
modifier name, the two routes would key into different lock entries
and each fire independently.

The hero supplies a `cfg.canonicalize_mod(mod)` that maps every
sibling onto a single canonical key. With this in place, both routes
key into the same lock entry and one wins. Without it, the dispatcher
falls through to identity canonicalisation (the raw mod name is the
key) and the lock degenerates into the legacy "best effort" behaviour
that does not handle sibling-name threats.

[threat_data.md](threat_data.md) ships a `CanonicalMod` function and
a `CANONICAL_MOD_ALIASES` table you can wire as `cfg.canonicalize_mod`
directly if you do not need anything bespoke.

## Setup

```lua
local Defense = require("lib.defense")
local TD      = require("lib.threat_data")

local dispatcher = Defense.New {
    -- Data your brain owns: chains, overrides, save_fire map, filter sets
    anim_save_overrides     = SAVE_OVERRIDES_BY_ABILITY,
    hero_save_overrides     = SAVE_OVERRIDES_BY_THREAT,
    patched_recommended     = PATCHED_RECOMMENDED_SAVES,
    category_chains         = CATEGORY_CHAINS,
    default_chain           = DEFAULT_SAVE_CHAIN,
    save_fire               = SAVE_FIRE,
    ability_saves           = ABILITY_SAVES,
    self_displacement_saves = SELF_DISPLACEMENT_SAVES,

    -- Hero-side accessors (the lib calls these; you implement them)
    self_npc                = function() return state.self_npc end,
    save_is_ready           = save_is_ready,
    self_can_cast_abilities = self_can_cast_abilities,
    defense_enabled         = function() return menu.defense_enabled:Get() end,
    threats_on_self         = THREATS_ON_SELF,
    armed_threats           = state.armed_threats,
    throttle_state          = state,
    now                     = GlobalVars.GetCurTime,
    tlog                    = my_logger,
    dist_to                 = function(c) return ... end,
    reaction_window         = 0.1,
    reserve_skip_floor      = -20,
    concurrent_penalty      = 15,

    -- The lock domain accessors (all optional; missing means unlocked)
    canonicalize_mod        = TD.CanonicalMod,
    eta_resolver            = MY_ETA_RESOLVERS,  -- table: mod -> resolver fn
    entity_index            = function(ent)
                                  if not ent then return nil end
                                  local ok, i = pcall(Entity.GetIndex, ent)
                                  if ok and type(i) == "number" then return i end
                                  return nil
                              end,
    ability_handle          = function(name)
                                  if not name then return nil end
                                  local ok, h = pcall(NPC.GetAbility, state.self_npc, name)
                                  return ok and h or nil
                              end,
    lock_buffer_s           = 0.3,   -- default
    fallback_lock_ttl_s     = 2.0,   -- default

    TD                      = TD,
}
```

## API

| Function | Purpose |
|----------|---------|
| `Defense.New(cfg)` | Create a dispatcher bound to one hero's data and accessors |
| `dispatcher:Dispatch(intent, mod, caster, target, fire_thunk, category, ability_name, armed_entry, on_save_fired, ctx)` | One-shot save fire. Takes the lock, runs the optional `fire_thunk` or the default chain walk, holds the lock on success. |
| `dispatcher:DispatchAlly(intent, mod, caster, ally, fire_thunk, ally_chain, category, ability_name, armed_entry, on_save_fired, ctx)` | Same shape but in a separate ally-domain lock map, so a self-save does not silence a same-threat ally-save. |
| `dispatcher:TrySaveSelf(intent, mod, caster, category, ability_name, on_save_fired, armed_entry, ctx)` | Thin compat wrapper around `Dispatch` with `target=cfg.self_npc()`; existing callers that pre-date `Dispatch` keep working. |
| `dispatcher:TryAcquireLock(target, canonical_mod, caster, ttl)` | Lock primitive. `(ok, existing_lock_info)` |
| `dispatcher:ReleaseLock(target, canonical_mod, caster)` | Lock primitive. Idempotent. |
| `dispatcher:ForceNextDispatch(target, canonical_mod, caster)` | One-shot lock-bypass for panic-key paths. Drops the lock for the next `Dispatch` on the matching tuple. |
| `dispatcher:ResolveSaveOrder(mod, category_hint, ability_name, ctx)` | Returns the resolved chain + `is_authoritative`. `ctx` is an optional context table the chain walk consults (e.g. demoting one save under a condition the hero signals). |
| `dispatcher:CanFire()` | Throttle gate. Returns true iff `now - last_save_t >= cfg.reaction_window`. |
| `dispatcher:MarkFired(threat_caster)` | Writes `cfg.throttle_state.last_save_t = cfg.now()`. The lib does NOT call this on its own; the hero's on_save_fired callback does, so heroes that need the chain to pass through their own bookkeeping keep ownership. |
| `dispatcher:CountConcurrentExcluding(armed_entry)` | Counts armed_threats rows excluding `armed_entry` by handle identity. Used inside the reserve-penalty math; also exposed so a hero-side chain peek can mirror the same count. |

## A typical dispatch

```lua
local fired = dispatcher:Dispatch(
    "gap_close_" .. ev.ability_name,   -- intent (free-form identifier)
    threat_mod,                        -- modifier name, gets canonicalised
    ev.caster,                         -- enemy hero firing the threat
    state.self_npc,                    -- target of the threat (self here)
    nil,                               -- no fire_thunk: use chain walk
    "close_gap",                       -- category_hint
    ev.ability_name,
    nil,                               -- no armed_entry
    record_save,                       -- on_save_fired callback
    { fs_shard_window = my_shard_active() }   -- optional ctx
)
```

When the same threat triggers a second route in your brain (e.g. the
armed_threats_tick handler fires next, against the same Bara charge),
the second `Dispatch` call sees the existing lock and returns false
with a `dispatch_blocked` tlog. One charge, one save.

## `fire_thunk` for off-chain fires

`Dispatch` runs the chain walk by default. If your hero has a save
that lives outside the standard chain (a direct item-cast, a custom
sequence), pass a `fire_thunk` closure:

```lua
local fire_thunk = function(intent, mod, caster)
    if issue_item_self(intent .. "_lotus", "def",
                       NPCLib.item(state.self_npc, "item_lotus_orb")) then
        record_save(intent, "lotus", mod, caster)
        return true
    end
    return false
end

dispatcher:Dispatch(intent, mod, caster, state.self_npc, fire_thunk,
                    nil, "item_lotus_orb", nil, nil, nil)
```

The lock still applies; the only difference is that on success the
thunk's return-value (`true`) keeps the lock HELD instead of letting
the chain walk decide.

## Why `MarkFired` is not called by the lib

The chain walk would prefer to set `last_save_t` itself, but heroes
typically run an on_save_fired callback that adds telemetry, updates
state, maybe runs a per-save side-effect. If both the lib and the
callback wrote `last_save_t`, the throttle would advance twice for
one fire. So the contract is: the callback owns it. The lib's
`MarkFired` is available as a primitive; the canonical pattern is
`on_save_fired -> hero record_save -> hero mark_layer2_fired ->
dispatcher:MarkFired`. Heroes that bypass the chain walk and fire
directly (a fast-path lotus, an ally-save closure) call `MarkFired`
through the same record_save adapter.
