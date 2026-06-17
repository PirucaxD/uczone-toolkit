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
| `dispatcher:ResolveSaveOrder(mod, category_hint, ability_name, ctx)` | Returns the resolved chain + `is_authoritative`. `ctx` is an optional context table forwarded to `cfg.post_pick_filter` (when the hero registers one) so the chain can be rewritten on live game state (e.g. demoting one save under a condition the hero signals). |
| `dispatcher:CanFire()` | Throttle gate. Returns true iff `now - last_save_t >= cfg.reaction_window`. |
| `dispatcher:MarkFired(threat_caster)` | Writes `cfg.throttle_state.last_save_t = cfg.now()`. The lib does NOT call this on its own; the hero's on_save_fired callback does, so heroes that need the chain to pass through their own bookkeeping keep ownership. |
| `dispatcher:CountConcurrentExcluding(armed_entry)` | Counts armed_threats rows excluding `armed_entry` by handle identity. Used inside the reserve-penalty math; also exposed so a hero-side chain peek can mirror the same count. |
| `dispatcher:HandleLineProjectile(data, opts)` | The lifted line-projectile intercept. Call from an `OnLinearProjectileCreate` hook; fires a perpendicular-distance displacement save before the projectile connects. See [Line-projectile intercept](#line-projectile-intercept). |

## Composing a chain (`Defense.ComposeChain`)

`Defense.ComposeChain(item_chain, injections, exclusions)` is the pure
save-chain composer. It is what `ResolveSaveOrder` uses internally to build a
composed category chain, and heroes call it directly to assemble bespoke chains
at load time. PURE: no engine calls, no dispatcher state, safe at hero load. It
NEVER mutates `item_chain` (typically the shared `TD.CATEGORY_CHAINS` entry) and
always returns a new list.

The algorithm, in order:

1. **filter exclusions** - drop any name in `exclusions` (a
   `{ item_name = true }` set) from the item backbone.
2. **splice injections** - each injection `{ save = "name", anchor = ... }`, in
   declared order, is placed at its anchor: `"head"` -> position 1; `"tail"` ->
   appended; `{ before = "X" }` -> immediately before the first `X`;
   `{ after = "X" }` -> immediately after the first `X`. If the before/after
   target is absent (or the anchor is `nil` / unrecognized) the save goes to the
   tail. A save is ALWAYS placed, never dropped.
3. **dedupe, first occurrence wins** - so an injected save that is also in the
   backbone MOVES to its anchor when anchored earlier (the committed-ranged
   cyclone-to-head case relies on this).

```lua
local chain = Defense.ComposeChain(
    TD.CATEGORY_CHAINS["close_gap"],            -- item backbone (not mutated)
    { { save = "lina_flame_cloak", anchor = "head" } },
    { item_blink = true })                       -- exclude from this chain
```

| Function | Returns |
|----------|---------|
| `Defense.ComposeChain(item_chain, injections, exclusions)` | a NEW composed chain list; filters `exclusions`, splices `injections` at their anchors, dedupes first-wins, never mutates `item_chain` |

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

## Hook: rewriting the chain on live ctx (`cfg.post_pick_filter`)

`ResolveSaveOrder` picks a chain from the chain tables (anim override,
hero override, patched-recommended, category, default fallback). If
your hero has a save whose preferred position depends on a live
game-state condition (a buff window, a Scepter / Shard configuration,
a per-engagement latch), you can register a chain rewrite hook:

```lua
local dispatcher = Defense.New {
    -- ... other cfg fields ...
    post_pick_filter = function(picked, ctx, threat_mod, authoritative)
        if not (ctx and ctx.my_window_active) then
            return picked, authoritative
        end
        -- Build a NEW chain; do not mutate `picked` since it may be
        -- aliased into the cfg-supplied override / category / default
        -- tables.
        local rewritten = {}
        for i = 1, #picked do
            if picked[i] ~= "my_save_to_demote" then
                rewritten[#rewritten + 1] = picked[i]
            end
        end
        rewritten[#rewritten + 1] = "my_save_to_demote"
        return rewritten, authoritative
    end,
}
```

The hook fires after chain resolution, before `ResolveSaveOrder`
returns. The lib applies `new_auth` only when non-nil so a hook that
returns just a new chain preserves the original `authoritative` flag.
Return `nil` for `picked` to keep the resolved chain unchanged.

`ctx` is the optional table the caller passes to `Dispatch` /
`DispatchAlly` / `TrySaveSelf` / `ResolveSaveOrder`. The lib treats
it as opaque, so the hero owns its shape and what keys it cares
about. A typical pattern is a hero-side helper
`fun() -> { my_window_active = <predicate>, ... }` called at each
dispatch site so the hook reads a fresh snapshot.

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

## Line-projectile intercept

`dispatcher:HandleLineProjectile(data, opts)` is the general item-save mechanism
for hooks / arrows / bolts that travel in a straight line and grab or stun the
FIRST unit in their path (Pudge Hook, Mirana Arrow, Magnus Skewer, Sven Bolt,
ES Fissure, Clockwerk Hookshot). It computes the projectile geometry, and if you
are inside the line, fires a perpendicular-distance displacement save (Force /
Pike / Blink / WW via the `line_projectile` chain) in the
projectile-create -> arrival window, so you are pushed OUT of the line BEFORE it
connects. An `OnModifierCreate`-based save only fires AFTER the grab is already
committed; this is the earlier route.

Call it from your `OnLinearProjectileCreate` hook, passing the raw event `data`
(the lib reads `data.source`, `data.origin`, `data.velocity`) and an `opts`
table of hero glue. The fire goes through this same dispatcher's `Dispatch` with
`category_hint = "line_projectile"`, so the per-threat lock still applies. Only
the data and glue arrive via `opts`; the lib holds no hero wrappers.

`opts` fields: `me`, `catalog` (the per-caster intercept table, e.g.
`TD.LINE_PROJECTILE_INTERCEPTS`), `tlog3` (bool, gate level-3 skip logs),
`enabled()`, `subsystem_on()`, `origin(npc)`, `uname(npc)`,
`is_enemy_hero(src, me)`, `dedup_responded(src, mod)`, `dedup_mark(src, mod)`,
`record_save`, `fs_shard_window()`.

| Function | Returns |
|----------|---------|
| `dispatcher:HandleLineProjectile(data, opts)` | nothing; fires a displacement save via `Dispatch` when you are within the projectile's `hit_radius + 75` perpendicular floor and heading-toward, after the dedup gate |

## ETA resolvers (lock-TTL math)

The dispatcher's per-threat lock holds for a TTL the cfg supplies via
`cfg.eta_resolver` (a `canonical_mod -> resolver_fn` map) plus
`cfg.eta_resolver_default`. A resolver returns seconds-until-resolution for its
threat. Rather than hand-write these, build them from the `Defense.EtaResolvers`
factory set: each factory returns a closure matching the resolver signature
`(caster, target, armed_entry, ability_handle, now_t, canonical_mod)`. All four
are stateless and engine-only, so no hero state leaks into the closures.

```lua
local EtaR = Defense.EtaResolvers
local MY_ETA_RESOLVERS = {
    modifier_lion_voodoo  = EtaR.Remaining("modifier_lion_voodoo", nil, 0.5),
    modifier_some_charge  = EtaR.DistSpeed(550, 2.0),
    modifier_pudge_hook   = EtaR.Line(1600),
    -- cast-point class entries:
    modifier_some_nuke    = EtaR.CastPoint(0.5),
}
```

- **`CastPoint(cp_default, floor_s)`** - pre-cast / cast-point class. Prefers the
  armed entry's stamped `cast_point + arm_t` (drift-free), falls back to a live
  `Ability.GetCastPoint(handle, true)`, then `cp_default`. Clamped to
  `>= floor_s` (default 0.1).
- **`Remaining(mod_name, cap_s, floor_s)`** - active-debuff class. Reads
  `NPC.GetModifierRemaining(target, mod_name)`. `cap_s` clamps the result so a
  periodic re-fire pattern can re-acquire before the TTL elapses; `floor_s`
  default 0.1.
- **`DistSpeed(default_speed, blink_cap)`** - armed-chain / instant-blink class.
  Returns `dist(caster, target) / speed`, using the armed entry's stamped
  `eta_speed` when present else `default_speed`. `blink_cap` clamps for blink
  classes (nil = no cap); floored at 0.05s.
- **`Line(speed, fog_fallback)`** - line-projectile class. Returns
  `dist / speed` when both caster and target exist; falls back to the armed
  entry's `eta_trigger` or `fog_fallback` (default 1.0) when the caster is in
  fog.

`Defense.MakeGenericEtaResolver(TD, opts)` is the catch-all you wire as
`cfg.eta_resolver_default`. It returns a closure bound to the supplied `TD` (so
the lib takes no circular dependency on `threat_data`), reads the canonical mod's
`THREAT_ARRIVAL_TIMING` entry, and branches by `entry.kind`:
`channel_at_caster` -> caster-side `GetModifierRemaining`; `cast_point_*` ->
`cast_point + post_cast_delay`; homing / blink kinds ->
`dist(caster, target) / speed_fallback`; no catalog entry -> target-side
`GetModifierRemaining`; nothing usable -> `nil` (the lib then falls back to
`cfg.fallback_lock_ttl_s`). `opts.lock_cap_s` caps the result (default 1.7s).

| Function | Returns |
|----------|---------|
| `Defense.EtaResolvers.CastPoint(cp_default, floor_s)` | resolver: armed cast-point, else live `GetCastPoint`, else `cp_default`; clamped `>= floor_s` (0.1) |
| `Defense.EtaResolvers.Remaining(mod_name, cap_s, floor_s)` | resolver: `GetModifierRemaining(target, mod_name)`, clamped to `cap_s` / `>= floor_s` (0.1) |
| `Defense.EtaResolvers.DistSpeed(default_speed, blink_cap)` | resolver: `dist / (armed.eta_speed or default_speed)`, capped by `blink_cap`, floored 0.05 |
| `Defense.EtaResolvers.Line(speed, fog_fallback)` | resolver: `dist / speed`, or armed `eta_trigger` / `fog_fallback` (1.0) when caster is fogged |
| `Defense.MakeGenericEtaResolver(TD, opts)` | catalog-aware default resolver bound to `TD`; branches on `THREAT_ARRIVAL_TIMING[mod].kind`, capped by `opts.lock_cap_s` (1.7) |

## Per-save fire window (`Defense.ComputeSaveFireWindow`)

`Defense.ComputeSaveFireWindow(threat_entry, speed, save_entry)` is the public
helper for the per-save fire-window math: given a catalog entry
(`THREAT_ARRIVAL_TIMING[mod]`), the effective threat `speed`, and the
`SAVE_FIRE[name]` entry (which must carry `prep_time`), it returns
`(lower, upper)` seconds. The chain walker no longer gates on this itself (hero
`.fire` bodies own their timing), so this is exposed for those `.fire` bodies and
any hero-side preview that wants one source of truth for the window.

It returns an always-open window `(0, math.huge)` for `channel_at_caster` and
`cast_point_targeted` kinds (timing handled elsewhere), a geometric upper
(`prep + catch_radius / speed`) for AoE-catch saves on homing kinds when the save
declares a `catch_radius` and `speed > 0`, and otherwise a tight
`(prep, prep + 0.10)` (a singular fire moment with a small frame-slack margin).

| Function | Returns |
|----------|---------|
| `Defense.ComputeSaveFireWindow(threat_entry, speed, save_entry)` | `(lower, upper)` fire-window seconds for one save against one catalog threat |
