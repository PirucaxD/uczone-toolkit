---@meta
---lib/threat_data.lua , universal threat / save classification data.
---
---Data-only Tier 2 extraction. The tables and pure helpers in this module
---don't change per hero , Pike's push distance is 425u for everyone, Bane
---Nightmare is countered by invuln/magic_immune/dispel/reflect regardless
---of who's defending against it.
---
---**Scope intentionally narrow.** This module owns:
---  - Save-item kind classification         (SAVE_KIND)
---  - Threat counter-effectiveness map      (THREAT_COUNTER)
---  - Displacement push distances           (SAVE_PUSH_DISTANCE)
---  - Tether-channel ranges                 (THREAT_TETHER_RANGE)
---  - Threat-on-self whitelist + roles      (THREATS_ON_SELF)
---  - Lotus-reflect-worthy incoming ults    (LOTUS_WORTHY_INCOMING)
---  - Enemy channel modifiers for Layer 1.5 (ENEMY_CHANNEL_MODIFIERS)
---  - Ability-name → threat-modifier map    (ABILITY_TO_THREAT)
---  - SaveCounters() predicate              (pure set intersection)
---  - WillTetherBreak() predicate           (pure geometry)
---
---**Does NOT own (stays per-hero):**
---  - Save chain execution order
---  - Hero-specific save abilities (Sniper's grenade-self, etc.)
---  - try_save_self, armed_threats_tick , these are logic that we'll
---    extract to `lib/defense.lua` once a second hero proves the API shape
---    (project's "two-hero rule").
---
---Usage in a hero script:
---```lua
---local TD = require("lib.threat_data")
---if TD.SaveCounters("item_cyclone", "modifier_bane_nightmare") then
---    -- Eul counters Nightmare; fire it
---end
---if TD.WillTetherBreak("item_hurricane_pike",
---                      "modifier_bane_fiends_grip",
---                      dist_bane_to_self) then
---    -- Pike's 425u push will break the 875u tether from this distance
---end
---```

local ThreatData = {}

-- v6.15.208 (KV-derivation): item_data.lua's generated SAVE_GEOMETRY table is
-- the single source of truth for save-item push/blink distances. sg() pulls a
-- numeric field from it with a patch-stable literal fallback. item_data is a
-- pure data module (no API calls / callbacks) and requires nothing back, so
-- there is no cycle and no load-order risk.
local ItemData = require("lib.item_data")
local function sg(name, field, fallback)
    local g = ItemData.SAVE_GEOMETRY and ItemData.SAVE_GEOMETRY[name]
    local v = g and g[field]
    return (type(v) == "number" and v) or fallback
end

----------------------------------------------------------------------------
-- SAVE_KIND , every save item / ability classified by what it does
----------------------------------------------------------------------------

---Save-effect categories. A save is "effective" against a threat iff any of
---its kinds appears in the threat's counter list.
---
---Kind meanings:
---  invuln                   , caster goes invuln (Eul cyclone, Aeon trigger,
---                             Wind Waker cyclone)
---  dispel_basic             , applies basic dispel (Eul exit, Manta split,
---                             Satanic active, Diffusal/Disperser purge)
---  magic_immune             , magic immunity (BKB)
---  magic_barrier            , absorbs magic damage via barrier (Eternal
---                             Shroud, Pipe of Insight)
---  magic_resist             , passive flat magic resist buff (Glimmer)
---  reflect_target           , Lotus Orb reflects single-target enemy casts
---  invis                    , invisibility breaks attack target-lock
---                             (Glimmer, Silver Edge wind-walk, Solar Crest)
---  damage_block             , flat physical damage reduction (Crimson
---                             Guard active barrier)
---  damage_return            , reflects physical damage back (Blade Mail)
---  physical_immune          , immune to physical attacks (Ghost active)
---  displacement_perp        , perpendicular 400-500u (Pike, Force,
---                             Grenade-self) , works vs LINE projectiles +
---                             DELAYED-AOE
---  displacement_far         , 500u+ displacement (Pike, Force) , works vs
---                             TETHER channels that break at range
---  displacement_blink       , instant 1200u teleport (Blink Dagger and
---                             variants) , breaks any tether
---  displacement_at_source   , knocks the THREAT CASTER off their position
---                             (grenade-at-caster) , breaks Bara Charge,
---                             Tusk Snowball via forced movement
---  channel_break            , interrupts enemy channel via ROOT_DISABLES
---                             (grenade-at-caster, hex, stun on caster)
---  phase                    , phase movement, walks through units
---                             (Phase Boots active) , minor save
---@type table<string, string[]>
ThreatData.SAVE_KIND = {
    -- Self-protection items
    item_cyclone            = { "invuln", "dispel_basic" },     -- 2.5s cyclone
    item_wind_waker         = { "invuln", "dispel_basic" },     -- 3.5s cyclone, dispel on exit, can act during cyclone
    -- v6.7: Aeon Disk applies STRONG dispel on trigger (Liquipedia 7.41).
    -- Strong dispel supersets basic dispel , can counter Nightmare, Doom,
    -- Ensnare even after they land.
    item_aeon_disk          = { "invuln", "dispel_basic" },     -- auto-trigger 1.5s invuln + strong dispel at <=80% HP
    item_lotus_orb          = { "reflect_target" },
    item_glimmer_cape       = { "invis", "magic_resist" },
    item_solar_crest        = { "invis", "magic_resist" },      -- self-cast: 6s invis + armor buff
    -- v6.7 (2026-05-11): BKB now applies basic dispel on cast (7.41 change
    -- per Liquipedia). Useful against Naga Ensnare and other dispel-only
    -- counterable threats.
    item_black_king_bar     = { "magic_immune", "dispel_basic" },
    -- v6.7: item_eternal_shroud was REMOVED in 7.41 , entry deleted.
    item_pipe_of_insight    = { "magic_barrier" },              -- AoE magic barrier on team
    item_crimson_guard      = { "damage_block" },               -- AoE flat damage block + team barrier
    item_blade_mail         = { "damage_return" },
    item_ghost              = { "physical_immune" },            -- 4s ghost form: immune physical, takes 40% more magic
    -- Dispel-on-self items
    item_satanic            = { "dispel_basic" },
    item_manta              = { "dispel_basic" },
    item_disperser          = { "dispel_basic" },               -- self-cast strong dispel + slow split
    item_diffusal_blade     = { "dispel_basic" },               -- target enemy: purge + slow
    -- Displacement items
    item_hurricane_pike     = { "displacement_far", "displacement_perp" },
    item_force_staff        = { "displacement_far", "displacement_perp" },
    item_blink              = { "displacement_blink" },
    item_swift_blink        = { "displacement_blink" },
    item_arcane_blink       = { "displacement_blink" },
    item_overwhelming_blink = { "displacement_blink" },
    item_phase_boots        = { "phase" },                      -- minor save: pass through units
    -- Sniper hero-specific (registered here so the kind-intersection filter
    -- works; hero file owns the fire closures via its SAVE_FIRE table).
    grenade_self            = { "displacement_perp" },          -- 475u radial from cast point
    grenade_at_caster       = { "channel_break", "displacement_at_source" },
}

----------------------------------------------------------------------------
-- THREAT_COUNTER , which kinds actually counter each threat
----------------------------------------------------------------------------

---Threat modifier → list of save-kind names that effectively counter it.
---Threats not listed are unconstrained (any save kind is allowed).
---@type table<string, string[]>
ThreatData.THREAT_COUNTER = {
    -- Entity-targeted spells: position doesn't matter, displacement useless
    modifier_bane_nightmare              = { "invuln", "magic_immune", "dispel_basic", "reflect_target" },
    modifier_lion_voodoo                 = { "invuln", "magic_immune", "reflect_target" },
    -- Magic-damage ults: magic_barrier absorbs some of the burst
    modifier_lion_finger_of_death        = { "invuln", "magic_immune", "reflect_target", "magic_barrier" },
    modifier_lina_laguna_blade           = { "invuln", "magic_immune", "reflect_target", "magic_barrier" },
    modifier_naga_siren_ensnare          = { "invuln", "dispel_basic", "reflect_target" },  -- ensnare pierces BKB
    modifier_doom_bringer_doom           = { "invuln", "magic_immune", "reflect_target", "magic_barrier" },
    -- Channel-tethers: far displacement breaks tether range. `channel_break`
    -- (grenade-on-caster knockback breaks the channel via ROOT_DISABLES) is
    -- the cheapest counter when the caster is in 600u , preferred over self-
    -- save items when readiness allows. `displacement_blink` (1200u Blink)
    -- always breaks any tether reliably. `magic_barrier` absorbs damage
    -- ticks for channels that deal magic damage (Grip, Dismember).
    modifier_bane_fiends_grip            = {
        "invuln", "dispel_basic", "displacement_far", "displacement_blink",
        "channel_break", "magic_barrier",
    },
    modifier_pudge_dismember_pull             = {
        "invuln", "dispel_basic", "displacement_far", "displacement_perp",
        "displacement_blink", "channel_break", "magic_barrier",
    },
    modifier_shadow_shaman_shackles      = {
        "invuln", "dispel_basic", "displacement_far", "displacement_perp",
        "displacement_blink", "channel_break",
    },
    modifier_witch_doctor_death_ward     = {
        "displacement_far", "displacement_perp", "displacement_blink",
        "magic_immune", "channel_break", "magic_barrier",
    },
    -- Homing charges: invuln/magic_immune are the BEST counters (prevent stun
    -- on impact entirely). `displacement_at_source` (knock the CHARGER off
    -- their path) actually CANCELS Bara Charge / Tusk Snowball , forced
    -- movement on the charger dispels the charge modifier. Self-displacement
    -- is just a delay (homing re-targets).
    modifier_spirit_breaker_charge_of_darkness = {
        "invuln", "magic_immune", "dispel_basic",
        "displacement_at_source", "channel_break",
        "displacement_perp", "displacement_far",     -- self-push is delay-only
    },
    modifier_tusk_snowball_movement      = {
        "invuln", "magic_immune", "dispel_basic",
        "displacement_at_source", "channel_break",
        "displacement_perp", "displacement_far",
    },
    -- v6.15.162: Kez Grappling Claw , Kez swings to a unit-target, 80%
    -- MS-slows them on hook collision, then lands a lifesteal hit. Gap-close
    -- profile; unlike Tusk's snowball Kez is NOT displacement-immune, so
    -- pushing the caster (or self) is viable. (verify modifier name ,
    -- modseen harvest; modifier_kez_grappling_claw_slow is the best guess.)
    modifier_kez_grappling_claw_slow          = {
        "invuln", "magic_immune", "dispel_basic",
        "displacement_at_source", "displacement_perp", "displacement_far",
    },
    -- Delayed AoE: position matters, displacement breaks the trap.
    -- displacement_blink always works. magic_barrier absorbs magic ticks.
    modifier_lina_light_strike_array     = {
        "invuln", "magic_immune", "displacement_perp", "displacement_far",
        "displacement_blink", "dispel_basic", "magic_barrier",
    },
    modifier_enigma_black_hole           = {
        "invuln", "magic_immune", "displacement_far", "displacement_perp",
        "displacement_blink", "dispel_basic", "magic_barrier",
    },
    modifier_crystal_maiden_freezing_field = {
        "magic_immune", "displacement_far", "displacement_perp",
        "displacement_blink", "magic_barrier",
    },
    -- Line projectiles: perpendicular displacement = miss. Blink = miss.
    -- v6.14.1 M3: dropped `invuln` , cyclone does NOT break a flying hook;
    -- the hook latches as it arrives and pulls you out of cyclone's landing
    -- position. Eul/Wind Waker only help if cast BEFORE the hook leaves
    -- Pudge's hand (the pre-cast path, which we don't currently detect).
    modifier_pudge_meat_hook             = {
        "displacement_perp", "displacement_far", "displacement_blink",
    },
    modifier_slark_pounce                = {
        "invuln", "displacement_perp", "displacement_blink",
        "dispel_basic", "magic_immune",
    },
    modifier_tusk_ice_shards_thinker     = {
        "invuln", "displacement_perp", "displacement_far", "displacement_blink",
    },
    modifier_mirana_arrow                = {
        "invuln", "displacement_perp", "displacement_blink",
    },
    -- Physical chase: invis breaks target-lock, BKB doesn't help. Physical-
    -- immune (Ghost) makes attackers' damage zero. Damage-block (Crimson
    -- Guard) flatly reduces. Damage-return (Blade Mail) punishes attackers.
    modifier_phantom_assassin_phantom_strike_target = {
        "invis", "invuln", "displacement_far", "displacement_perp",
        "displacement_blink", "physical_immune", "damage_block", "damage_return",
    },
    modifier_ursa_overpower              = {
        "invis", "invuln", "displacement_far", "displacement_perp",
        "displacement_blink", "physical_immune", "damage_block", "damage_return",
    },
    -- Drain channels: tether range, blink always works
    modifier_razor_static_link_debuff           = {
        "invuln", "displacement_far", "displacement_blink", "dispel_basic",
    },  -- pierces BKB
    modifier_lion_mana_drain             = {
        "invuln", "displacement_far", "displacement_perp", "displacement_blink",
        "dispel_basic",
    },
    -- Lockdown , Blade Mail returns damage during forced attacks
    modifier_legion_commander_duel       = { "invuln", "dispel_basic", "damage_return" },
    -- Misc CC
    modifier_axe_berserkers_call         = { "magic_immune", "damage_return" },  -- LISTED FOR COMPLETENESS BUT NEITHER ACTUALLY COUNTERS: Berserker's Call pierces spell immunity (BKB does nothing), and Blade Mail returns Sniper's own attack damage at full vs the original armor-mitigated amount , a net loss. THREATS_ON_SELF entry correctly tags save="informational" → dispatcher no-op via v6.15.202 (D1) catch-all.
    -- v6.7 extrapolation entries (modifier names marked (verify) need in-game check)
    modifier_shadow_shaman_voodoo        = { "invuln", "magic_immune", "reflect_target", "dispel_basic" },
    modifier_zuus_lightning_bolt         = { "invuln", "magic_immune", "magic_barrier", "reflect_target" },
    modifier_zuus_thundergods_wrath      = { "invuln", "magic_immune", "magic_barrier" },  -- global AoE; no reflect (not single-target)
    modifier_tidehunter_ravage           = { "invuln", "magic_immune", "displacement_blink", "magic_barrier", "dispel_basic" },
    modifier_earthshaker_echo_slam       = { "invuln", "magic_immune", "displacement_far", "displacement_perp", "displacement_blink", "magic_barrier" },
    modifier_magnataur_reverse_polarity_stun  = { "invuln", "magic_immune", "displacement_blink" },  -- 1700u radius; only blink reliably escapes
    modifier_disruptor_static_storm_thinker = { "magic_immune", "displacement_far", "displacement_perp", "displacement_blink", "magic_barrier" },
    modifier_treant_overgrowth           = { "invuln", "magic_immune", "displacement_blink", "dispel_basic" },
    modifier_magnataur_skewer            = { "invuln", "displacement_perp", "displacement_blink", "magic_immune" },
    modifier_sven_storm_bolt             = { "invuln", "displacement_perp", "displacement_blink", "magic_immune" },
    modifier_earth_spirit_rolling_boulder= { "invuln", "displacement_perp", "displacement_blink", "magic_immune" },
    modifier_life_stealer_open_wounds    = { "dispel_basic", "invis", "invuln", "physical_immune", "damage_block", "damage_return" },
    modifier_pugna_life_drain            = { "invuln", "displacement_far", "displacement_blink", "dispel_basic" },
    -- v6.15.10: Disruptor Kinetic Field. The wall blocks forced movement
    -- (Pike, Force, Blink) entirely , only knockback motion crosses it.
    -- User-observed in 7.41C. (verify modifier name , likely
    -- modifier_disruptor_kinetic_field_remnant once empirically confirmed
    -- via modseen.)
    modifier_disruptor_kinetic_field_remnant = { "displacement_perp" },
    -- v6.15.256: Underlord Pit of Malice. 400u-radius (500u with shard)
    -- snare pit, re-snares every 3.6s for 12s; each snare is a 1.5-1.8s
    -- root. Same escape profile as Kinetic Field: only knockback motion
    -- (grenade-self push, pike-self push, Force push) reliably moves
    -- Sniper out of the pit. Blink works too (the pit doesn't block
    -- teleports). (verify) , modifier name from KV naming convention,
    -- not yet harvested from a real match.
    modifier_abyssal_underlord_pit_of_malice_ensare = { "displacement_perp", "displacement_blink" },
}

----------------------------------------------------------------------------
-- SAVE_PUSH_DISTANCE , how far each displacement save moves the user
----------------------------------------------------------------------------

---Save key → push distance in units. Non-displacement saves omitted
---(treated as 0 and not constrained by tether geometry).
---@type table<string, number>
-- Pike-on-enemy push = 425. Pike pushes radially outward from caster , both
-- caster and enemy move apart. Pike-on-self push = 600 but direction =
-- Sniper's facing (often toward threat). The brain prefers Pike-on-enemy
-- whenever the enemy is in 425u cast range; otherwise falls back to
-- Pike-on-self. The conservative value used here is the enemy-target mode
-- (enemy_push) since that's the reliable-direction case for tether breaks.
-- v6.15.208 (KV-derivation): the item entries derive from
-- item_data.SAVE_GEOMETRY (the generated table item_data's docstring
-- designates as the grounding source for SAVE_PUSH_DISTANCE) , displacement
-- items take enemy_push, blink items take range. The literal in each sg()
-- call is a patch-stable fallback only. grenade_self stays literal: it is a
-- Sniper ability (npc_abilities KV), not an item, so SAVE_GEOMETRY has no
-- entry for it.
ThreatData.SAVE_PUSH_DISTANCE = {
    item_hurricane_pike     = sg("item_hurricane_pike",     "enemy_push", 425),
    item_force_staff        = sg("item_force_staff",        "enemy_push", 600),
    grenade_self            = 475,
    -- Blink variants: instant teleport. Always breaks any tether.
    item_blink              = sg("item_blink",              "range", 1200),
    item_swift_blink        = sg("item_swift_blink",        "range", 1200),
    item_arcane_blink       = sg("item_arcane_blink",       "range", 1400),
    item_overwhelming_blink = sg("item_overwhelming_blink", "range", 1200),
}

----------------------------------------------------------------------------
-- THREAT_TETHER_RANGE , distance at which a tether channel breaks
----------------------------------------------------------------------------

---Threat modifier → tether range in units. Sniper-to-caster distance plus
---displacement push must exceed this for the displacement save to actually
---break the channel. Threats without listed ranges are unconstrained.
---@type table<string, number>
-- v6.7 (2026-05-11): cross-checked against Liquipedia 7.41C.
-- Static Link 900 → 800, Mana Drain 850 → 1000, Death Ward 1100 → 650.
-- Death Ward "tether" was way off , actual ward attack range is 650 at
-- level 3 (was using a fictional 1100). Old value caused over-saves where
-- the brain thought Death Ward reached farther than it does.
-- Shaman Shackles 800 is a HEURISTIC , Liquipedia documents no actual
-- distance-break for Shackles (channel only breaks via stun/silence/
-- disjoint). Kept for the displacement save's geometry score but flagged.
-- Bane Fiend Grip 875 is unverified by Liquipedia text (cast range 625;
-- typical Dota tether allows ~200 buffer). Keep 875 pending in-game verify.
ThreatData.THREAT_TETHER_RANGE = {
    modifier_bane_fiends_grip          = 875,
    modifier_pudge_dismember_pull           = 200,
    modifier_shadow_shaman_shackles    = 800,    -- HEURISTIC; no real distance-break (verify in-game)
    modifier_razor_static_link_debuff         = 800,
    modifier_lion_mana_drain           = 1000,
    modifier_witch_doctor_death_ward   = 650,    -- ward attack range at level 3
    modifier_pugna_life_drain          = 1100,   -- v6.7 (verify): typical channel tether
}

----------------------------------------------------------------------------
-- THREATS_ON_SELF , modifier names hero scripts react to via OnModifierCreate
----------------------------------------------------------------------------

---Modifier → { role, save } metadata. `role` drives the dispatch path in the
---hero script; `save` is human-readable shorthand for diagnostics. Hero scripts
---will typically also pass the modifier name through to the save chain as the
---threat-mod filter input.
---@type table<string, { role:string, save:string }>
ThreatData.THREATS_ON_SELF = {
    modifier_bane_nightmare              = { role = "hard_disable",  save = "eul_or_bkb" },
    modifier_lion_voodoo                 = { role = "hard_disable",  save = "pre_arm" },
    -- v6.15.262: Lion Mana Drain (channel modifier on Sniper). Catalog gap
    -- caught by v6.15.261 demo log: anim_channel_start fires correctly but
    -- OnModifierCreate skips because THREATS_ON_SELF lookup returns nil ->
    -- threat_unrecognized event, no save dispatched. At 1000u tether range,
    -- Lion can drain Sniper from outside grenade_at_caster's 600u cast
    -- range, so Layer 1.5 grenade-on-source also fails -- the reactive
    -- self-save chain is the only one that fires. Force-self (600u) and
    -- pike-self (425u) push Sniper toward the tether-break radius;
    -- grenade-self is the 475u-push fallback.
    modifier_lion_mana_drain             = { role = "drain",         save = "force_or_pike" },
    modifier_shadow_shaman_shackles      = { role = "channel_on_me", save = "bkb_or_grenade_source" },
    modifier_pudge_dismember_pull             = { role = "channel_on_me", save = "bkb_or_grenade_source" },
    modifier_bane_fiends_grip            = { role = "channel_on_me", save = "bkb_or_grenade_source" },
    modifier_doom_bringer_doom           = { role = "hard_disable",  save = "bkb_or_lotus" },
    modifier_razor_static_link_debuff           = { role = "drain",         save = "force_or_pike" },
    modifier_ursa_overpower              = { role = "physical_burst",save = "glimmer_or_pike" },
    modifier_legion_commander_duel       = { role = "lockdown",      save = "satanic_or_grenade_self" },
    -- Naga Ensnare: physical root, BKB-piercing. Modifier name verified via
    -- VPK binary-grep on pak01_009.vpk (2026-06-01, per lesson 13). All sibling
    -- tables already cataloged the modifier (ABILITY_TO_THREAT, RECOMMENDED_SAVES,
    -- THREAT_TIMING pre_cast, CATEGORY_OVERRIDES targeted_disable, SeverityOf
    -- medium, COUNTER_LAYERS invuln+dispel_basic+reflect_target). THREATS_ON_SELF
    -- was the missing entry: surfaced via v0.5.23 A3b Lina demo as
    -- `threat_unrecognized | mod=modifier_naga_siren_ensnare`. Role=lockdown
    -- matches LC Duel (also BKB-piercing physical). Counters: cyclone-airborne
    -- (Eul/WW phase out of root), basic dispel (Manta/Disperser), Lotus reflect.
    modifier_naga_siren_ensnare          = { role = "lockdown",      save = "manta_or_eul" },
    modifier_axe_berserkers_call         = { role = "taunt",         save = "informational" },
    modifier_phantom_assassin_phantom_strike_target = { role = "gap_close", save = "glimmer_or_pike" },
    modifier_spirit_breaker_charge_of_darkness      = { role = "gap_close", save = "pike_or_grenade" },
    modifier_tusk_snowball_movement                 = { role = "gap_close", save = "pike_or_grenade" },
    modifier_kez_grappling_claw_slow                     = { role = "gap_close", save = "pike_or_grenade" },  -- v6.15.162 (verify) , Kez Grappling Claw
    -- v6.15.163 batch 1 , modern hero pool (verify modifier names via modseen)
    modifier_ringmaster_impalement                  = { role = "line_projectile", save = "perp_displacement" },
    modifier_marci_grapple                          = { role = "gap_close",       save = "pike_or_grenade" },
    modifier_muerta_dead_shot                       = { role = "hard_disable",     save = "eul_or_bkb" },
    modifier_primal_beast_onslaught                 = { role = "gap_close",        save = "pike_or_grenade" },
    modifier_dawnbreaker_celestial_hammer           = { role = "gap_close",        save = "pike_or_grenade" },
    modifier_hoodwink_bushwhack                     = { role = "delayed_aoe",      save = "displacement" },
    modifier_snapfire_mortimer_kisses               = { role = "delayed_aoe",      save = "displacement" },
    modifier_void_spirit_aether_remnant             = { role = "hard_disable",     save = "eul_or_bkb" },
    modifier_mars_spear                             = { role = "line_projectile",  save = "perp_displacement" },
    modifier_grimstroke_ink_creature                = { role = "hard_disable",     save = "dispel_or_bkb" },
    modifier_pangolier_swashbuckle                  = { role = "gap_close",        save = "pike_or_grenade" },
    modifier_dark_willow_cursed_crown               = { role = "hard_disable",     save = "eul_or_bkb" },
    -- v6.15.164 batch 2 , older-hero kidnaps / gap-closes / catches
    modifier_faceless_void_chronosphere_freeze             = { role = "delayed_aoe",      save = "blink_or_bkb" },
    modifier_batrider_flaming_lasso                 = { role = "hard_disable",     save = "bkb_or_eul" },
    modifier_tiny_toss                              = { role = "hard_disable",     save = "eul_or_bkb" },
    modifier_vengefulspirit_nether_swap             = { role = "hard_disable",     save = "bkb_or_eul" },
    modifier_chaos_knight_reality_rift              = { role = "gap_close",        save = "pike_or_grenade" },
    modifier_rattletrap_hookshot                    = { role = "gap_close",        save = "pike_or_grenade" },
    modifier_spirit_breaker_nether_strike           = { role = "gap_close",        save = "bkb_or_pike" },
    modifier_huskar_life_break                      = { role = "gap_close",        save = "pike_or_grenade" },
    modifier_sandking_burrowstrike                  = { role = "line_projectile",  save = "perp_displacement" },
    modifier_nyx_assassin_impale                    = { role = "line_projectile",  save = "perp_displacement" },
    -- batch 3-4 (defense catalog refresh, 2026-05-17)
    modifier_necrolyte_reapers_scythe               = { role = "magic_burst",      save = "bkb_or_lotus" },
    modifier_obsidian_destroyer_sanity_eclipse      = { role = "magic_burst",      save = "bkb_or_lotus" },
    modifier_lich_chain_frost                       = { role = "magic_burst",      save = "bkb_or_lotus" },
    modifier_skywrath_mystic_flare_aura_effect             = { role = "delayed_aoe",      save = "displacement" },
    modifier_mars_gods_rebuke                       = { role = "physical_burst",   save = "glimmer_or_ghost" },
    modifier_snapfire_scatterblast_slow                  = { role = "magic_burst",      save = "bkb_or_displacement" },
    modifier_bloodseeker_rupture                    = { role = "magic_burst",      save = "dispel" },
    modifier_obsidian_destroyer_astral_imprisonment = { role = "hard_disable",     save = "eul_or_bkb" },
    modifier_skywrath_mage_ancient_seal             = { role = "hard_disable",     save = "eul_or_bkb" },
    modifier_chaos_knight_chaos_bolt                = { role = "hard_disable",     save = "eul_or_bkb" },
    modifier_beastmaster_primal_roar                = { role = "hard_disable",     save = "eul_or_bkb" },
    modifier_shadow_demon_disruption                = { role = "hard_disable",     save = "eul_or_bkb" },
    modifier_shadow_demon_demonic_purge             = { role = "hard_disable",     save = "bkb_or_eul" },
    modifier_winter_wyvern_winters_curse            = { role = "hard_disable",     save = "bkb_or_eul" },
    modifier_enigma_malefice                        = { role = "hard_disable",     save = "eul_or_bkb" },
    modifier_windrunner_shackleshot                 = { role = "hard_disable",     save = "eul_or_bkb" },
    modifier_morphling_adaptive_strike_agi          = { role = "hard_disable",     save = "eul_or_bkb" },
    modifier_puck_waning_rift                       = { role = "hard_disable",     save = "eul_or_bkb" },
    modifier_lich_sinister_gaze                     = { role = "channel_on_me",    save = "bkb_or_grenade" },
    modifier_primal_beast_pulverize                 = { role = "channel_on_me",    save = "bkb_or_grenade" },
    modifier_grimstroke_soul_chain                  = { role = "channel_on_me",    save = "bkb_or_eul" },
    modifier_puck_dream_coil                        = { role = "delayed_aoe",      save = "displacement" },
    modifier_leshrac_split_earth                    = { role = "delayed_aoe",      save = "displacement" },
    modifier_jakiro_ice_path                        = { role = "delayed_aoe",      save = "displacement" },
    modifier_mars_arena_of_blood                    = { role = "delayed_aoe",      save = "blink_or_bkb" },
    modifier_sandking_epicenter                     = { role = "delayed_aoe",      save = "displacement" },
    modifier_templar_assassin_psionic_trap          = { role = "trapped",          save = "displacement" },
    modifier_naga_siren_song_of_the_siren           = { role = "delayed_aoe",      save = "bkb_or_displacement" },
    modifier_dark_willow_terrorize                  = { role = "delayed_aoe",      save = "displacement" },
    modifier_dark_willow_bramble_maze               = { role = "delayed_aoe",      save = "displacement" },
    modifier_ringmaster_the_box                     = { role = "trapped",          save = "knockback_or_blink" },
    modifier_ringmaster_wheel                       = { role = "delayed_aoe",      save = "displacement" },
    modifier_kez_raptor_dance                       = { role = "delayed_aoe",      save = "displacement" },
    modifier_void_spirit_astral_step                = { role = "gap_close",        save = "pike_or_grenade" },
    modifier_pangolier_gyroshell                    = { role = "gap_close",        save = "pike_or_grenade" },
    modifier_nyx_assassin_vendetta                  = { role = "gap_close",        save = "pike_or_grenade" },
    modifier_slark_pounce                = { role = "gap_close", save = "force_or_pike" },
    -- v6.15.258 zero-coverage fill batch 1: single-target stuns / silences
    -- from heroes Sniper actually faces. All modifier names are (verify) --
    -- guessed from KV ability names; demos will confirm via threat_unrecognized.
    modifier_dragon_knight_dragon_tail   = { role = "hard_disable",  save = "eul_or_bkb" },         -- (verify) , 0.45 cast, 1.7-2.75s stun
    modifier_night_stalker_void          = { role = "hard_disable",  save = "eul_or_bkb" },         -- (verify) , 0.3 cast, mini-stun + slow (full stun at night)
    modifier_ogre_magi_fireblast         = { role = "hard_disable",  save = "eul_or_bkb" },         -- (verify) , 0.45 cast, 1.5-2.4s stun
    modifier_rubick_telekinesis_stun          = { role = "hard_disable",  save = "eul_or_bkb" },         -- (verify) , 0.1 cast, lift+land stun
    modifier_silencer_last_word          = { role = "silence_on_me", save = "bkb_or_dispel" },      -- (verify) , silence on cast / 4s timer
    modifier_death_prophet_silence       = { role = "silence_on_me", save = "bkb_or_dispel" },      -- (verify) , point-AOE 5-6s silence
    -- v6.15.263 zero-coverage fill batch 2: AOE delayed killers + single-target
    -- bursts Sniper actually faces. Anim-path detection is primary for abilities
    -- without a Sniper-side modifier (Mana Void, Sunder).
    modifier_cold_feet     = { role = "hard_disable", save = "eul_or_bkb" },        -- (verify) , 4s timer, stun if Sniper hasn't moved 715u
    modifier_ice_blast     = { role = "magic_burst",  save = "bkb_or_lotus" },      -- (verify) , frost mark, executes <12% HP. BKB blocks (SPELL_IMMUNITY_ENEMIES_YES)
    modifier_gyrocopter_homing_missile        = { role = "line_projectile", save = "perp_displacement" },  -- (verify) , homing target debuff, missile is dodgeable
    modifier_gyrocopter_call_down_slow        = { role = "kiting_slow",  save = "informational" },     -- (verify) , per-rocket slow proc
    modifier_kunkka_torrent_thinker           = { role = "delayed_aoe",  save = "displacement" },      -- (verify) , geyser warning placed, hits ~1.5s later
    modifier_kunkka_torrent_stun              = { role = "hard_disable", save = "eul_or_bkb" },        -- (verify) , stun applied at geyser impact
    modifier_kunkka_x_marks_the_spot          = { role = "hard_disable", save = "bkb_or_dispel" },     -- (verify) , drag-back debuff, removable by dispel
    modifier_nevermore_requiem                = { role = "magic_burst",  save = "bkb_or_lotus" },      -- (verify) , fear + magic damage radial
    -- v6.15.265 zero-coverage fill batch 3: mid-game mixed threats
    modifier_doom_bringer_infernal_blade      = { role = "hard_disable", save = "eul_or_bkb" },        -- (verify) , autocast mini-stun + damage on Doom right-clicks
    modifier_furion_sprout                    = { role = "hard_disable", save = "bkb_or_dispel" },     -- (verify) , root cage; basic dispel (Manta) removes the trees
    modifier_visage_grave_chill               = { role = "hard_disable", save = "bkb_or_dispel" },     -- (verify) , slow + silence steal
    modifier_venomancer_venomous_gale         = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- (verify) , slow + dot line; dispel removes
    modifier_spectre_spectral_dagger          = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- (verify) , slow + can-chase-through-walls debuff
    -- v6.15.266 zero-coverage fill batch 4: carry / active threats
    modifier_juggernaut_omni_slash            = { role = "channel_on_me", save = "bkb_or_eul" },       -- (verify) , 4s channel, target locked + massive damage; BKB / Aeon / Manta dispel
    modifier_phantom_lancer_spirit_lance      = { role = "kiting_slow",  save = "informational" },     -- (verify) , slow + damage proc, recoverable
    modifier_meepo_earthbind                  = { role = "hard_disable", save = "bkb_or_dispel" },     -- (verify) , 2s root delayed AoE, dispel removes
    modifier_monkey_king_wukongs_command_aura = { role = "delayed_aoe",  save = "displacement" },      -- (verify) , cage area, clones attack inside
    modifier_slardar_amplify_damage           = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- (verify) , armor reduction debuff, dispellable
    modifier_slardar_slithereen_crush         = { role = "hard_disable", save = "eul_or_bkb" },        -- (verify) , AoE stun around Slardar
    modifier_bristleback_hairball_slow        = { role = "kiting_slow",  save = "informational" },     -- (verify) , line of goo slows, recoverable
    -- v6.15.267 zero-coverage fill batch 5: reactive-detectable threats
    modifier_invoker_cold_snap_freeze         = { role = "hard_disable", save = "bkb_or_dispel" },     -- (verify) , recurring mini-stun on damage; dispel removes
    modifier_riki_smoke_screen                = { role = "silence_on_me", save = "bkb_or_dispel" },    -- (verify) , AoE silence + miss chance
    modifier_lone_druid_entangle_effect       = { role = "hard_disable", save = "bkb_or_dispel" },     -- (verify) , bear-attack root proc (1.5s)
    modifier_undying_decay                    = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- (verify) , STR drain debuff (reduces Sniper max HP)
    modifier_dazzle_poison_touch              = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- (verify) , slow + delayed stun if not removed
    modifier_weaver_the_swarm                 = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- (verify) , armor reduction + attack-trigger damage
    -- v6.15.268 zero-coverage fill batch 6: stuns + snares + nukes
    modifier_alchemist_unstable_concoction    = { role = "hard_disable", save = "eul_or_bkb" },        -- (verify) , variable stun (1-4s based on charge), instant when thrown
    modifier_broodmother_sticky_snare         = { role = "hard_disable", save = "bkb_or_dispel" },     -- (verify) , 2s root from placed snare; dispellable
    modifier_medusa_gorgon_grasp              = { role = "hard_disable", save = "eul_or_bkb" },        -- (verify) , point-AOE stun
    modifier_medusa_mystic_snake              = { role = "kiting_slow",  save = "informational" },     -- (verify) , bouncing damage + mana drain, recoverable
    modifier_troll_warlord_whirling_axes_ranged = { role = "silence_on_me", save = "bkb_or_dispel" }, -- (verify) , multi-axe silence + damage
    modifier_dark_seer_vacuum                 = { role = "hard_disable", save = "bkb_or_dispel" },     -- (verify) , pulls Sniper to vacuum point; BKB blocks
    modifier_dark_seer_ion_shell              = { role = "kiting_slow",  save = "informational" },     -- (verify) , area damage aura around target; doesn't stop kiting
    modifier_ember_spirit_sleight_of_fist_caster = { role = "kiting_slow", save = "informational" }, -- (verify) , Ember in untargetable phase; informational
    -- v6.15.269 zero-coverage fill batch 7: remaining mid-impact threats
    modifier_bounty_hunter_shuriken_toss      = { role = "kiting_slow",  save = "informational" },     -- (verify) , slow + damage proc, recoverable
    modifier_brewmaster_cinder_brew           = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- (verify) , POINT-AOE slow + dot, ignites on damage; dispel removes
    modifier_phoenix_sun_ray                  = { role = "kiting_slow",  save = "informational" },     -- (verify) , line beam damage + slow (Phoenix channels)
    modifier_shredder_chakram                 = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- (verify) , chakram line slow + disarm
    modifier_arc_warden_flux                  = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- (verify) , damage-when-isolated debuff; dispel breaks the lone-target check
    -- v6.15.270 zero-coverage final mop-up
    modifier_chen_penitence                   = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- (verify) , slow + damage amp on Sniper
    modifier_omniknight_hammer_of_purity      = { role = "kiting_slow",  save = "informational" },     -- (verify) , autocast purity attack proc, single-target damage
    modifier_largo_catchy_lick                = { role = "kiting_slow",  save = "informational" },     -- (verify) , Largo lick debuff, single-target proc
    -- v6.15.271 ranked-match harvest: real modifier names verified from
    -- threat_unrecognized log lines in a 100k-line live match.
    modifier_tusk_snowball_target             = { role = "hard_disable", save = "eul_or_bkb" },         -- harvested 2026-05-24: root + delivery debuff on Sniper after snowball impact
    modifier_tusk_walrus_punch_air_time       = { role = "hard_disable", save = "eul_or_bkb" },         -- harvested 2026-05-24: knockup stun phase (1.6s+)
    modifier_tusk_walrus_punch_slow           = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- harvested 2026-05-24: post-punch slow
    modifier_tusk_tag_team_attack_slow        = { role = "kiting_slow",  save = "informational" },     -- harvested 2026-05-24: passive proc slow on Tusk attacks
    modifier_tusk_tag_team_slow               = { role = "kiting_slow",  save = "informational" },     -- harvested 2026-05-24: paired-attack slow
    modifier_tiny_avalanche_stun              = { role = "hard_disable", save = "eul_or_bkb" },         -- harvested 2026-05-24: Avalanche stun (POINT-AOE, 1.5-1.8s)
    -- (Skywrath Mystic Flare: the bare `modifier_skywrath_mage_mystic_flare`
    -- entries throughout this file were renamed to the actual harvested
    -- name `modifier_skywrath_mystic_flare_aura_effect` in v6.15.271. No
    -- new entry needed -- the existing role/timing/category/severity
    -- stay as they were under the new key.)
    modifier_skywrath_mage_concussive_shot_slow = { role = "kiting_slow", save = "informational" },    -- harvested 2026-05-24: Concussive Shot slow proc
    modifier_keeper_of_the_light_blinding_light = { role = "hard_disable", save = "bkb_or_dispel" },   -- harvested 2026-05-24: miss-chance debuff on Sniper (devastating to a right-clicker)
    modifier_blinding_light_knockback         = { role = "kiting_slow",  save = "informational" },     -- harvested 2026-05-24: knockback marker from Blinding Light
    modifier_keeper_of_the_light_will_o_wisp  = { role = "hard_disable", save = "eul_or_bkb" },         -- harvested 2026-05-24: delayed AoE stun ult
    modifier_keeper_of_the_light_radiant_bind = { role = "hard_disable", save = "bkb_or_dispel" },     -- harvested 2026-05-24: anti-ranged-attack disable via facet -- HIGH PRIORITY for Sniper
    modifier_legion_commander_intimidate_slow = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- harvested 2026-05-24: newer LC ability slow
    -- v6.15.272 second-match harvest: Faceless Void / Largo / Razor / Rubick
    modifier_faceless_void_timelock_freeze    = { role = "kiting_slow",  save = "informational" },     -- harvested 2026-05-25: passive proc mini-stun on attack, recoverable
    modifier_faceless_void_time_dilation_distortion = { role = "kiting_slow", save = "bkb_or_dispel" }, -- harvested 2026-05-25: slow + ability CD stall
    modifier_largo_frogstomp_debuff           = { role = "hard_disable", save = "eul_or_bkb" },         -- harvested 2026-05-25: POINT-AOE stomp stun
    modifier_largo_croak_of_genius_debuff     = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- harvested 2026-05-25: damage/debuff
    modifier_largo_catchy_lick_knockback      = { role = "kiting_slow",  save = "informational" },     -- harvested 2026-05-25: knockback marker
    modifier_razor_plasma_field_slow          = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- harvested 2026-05-25: Plasma Field ring slow
    modifier_razor_storm_surge_slow           = { role = "kiting_slow",  save = "informational" },     -- harvested 2026-05-25: ms-trade facet
    modifier_razor_eye_of_the_storm_armor     = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- harvested 2026-05-25: ult armor reduction
    modifier_rubick_fade_bolt_debuff          = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- harvested 2026-05-25: damage debuff
    -- v6.15.273 third-match harvest: AA / Magnus / Snapfire / Spectre / WD
    modifier_ancientapparition_coldfeet_freeze = { role = "hard_disable", save = "bkb_or_dispel" },    -- harvested 2026-05-25: AA Cold Feet freeze phase (hero prefix written ancientapparition with no underscore!)
    modifier_ancient_apparition_bone_chill_debuff = { role = "kiting_slow", save = "bkb_or_dispel" }, -- harvested 2026-05-25: AA Bone Chill stacking slow
    modifier_chilling_touch_slow              = { role = "kiting_slow",  save = "informational" },     -- harvested 2026-05-25: AA Chilling Touch attack slow proc (no hero prefix!)
    modifier_chilling_touch_super_slow        = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- harvested 2026-05-25: AA Chilling Touch upgraded variant
    modifier_ice_vortex                       = { role = "kiting_slow",  save = "informational" },     -- harvested 2026-05-25: AA Ice Vortex slow (no hero prefix!)
    modifier_magnataur_skewer_impact          = { role = "hard_disable", save = "eul_or_bkb" },         -- harvested 2026-05-25: Skewer impact stun
    modifier_magnataur_skewer_slow            = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- harvested 2026-05-25: Skewer post-impact slow
    modifier_magnataur_shockwave_pull         = { role = "hard_disable", save = "bkb_or_dispel" },     -- harvested 2026-05-25: Shockwave pull-back (newer ability?)
    modifier_snapfire_lil_shredder_debuff     = { role = "kiting_slow",  save = "informational" },     -- harvested 2026-05-25: Lil' Shredder attack-replacement debuff
    modifier_snapfire_magma_burn_slow         = { role = "kiting_slow",  save = "informational" },     -- harvested 2026-05-25: Magma burn slow proc
    modifier_spectre_spectral_dagger_in_path  = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- harvested 2026-05-25: Spectre in-path-of-dagger chase marker
    modifier_maledict                         = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- harvested 2026-05-25: WD Maledict mark (no hero prefix!)
    modifier_maledict_dot                     = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- harvested 2026-05-25: WD Maledict periodic damage tick
    -- v6.7 extrapolation (2026-05-11). Modifier names marked (verify) need
    -- in-game confirmation via :FindAllModifiers() print before relying on.
    modifier_shadow_shaman_voodoo        = { role = "hard_disable",  save = "lotus_or_eul" },           -- (verify) , Hex
    modifier_zuus_lightning_bolt         = { role = "magic_burst",   save = "bkb_or_lotus" },          -- (verify)
    modifier_zuus_thundergods_wrath      = { role = "magic_burst",   save = "bkb_or_pipe" },           -- (verify) , global ult, 2s cast point
    modifier_tidehunter_ravage           = { role = "delayed_aoe",   save = "bkb_or_blink" },          -- (verify)
    modifier_earthshaker_echo_slam       = { role = "delayed_aoe",   save = "bkb_or_blink" },          -- (verify)
    modifier_magnataur_reverse_polarity_stun  = { role = "delayed_aoe",   save = "bkb_or_blink" },          -- (verify) , 1700u radius
    modifier_disruptor_static_storm_thinker = { role = "delayed_aoe", save = "displacement_or_bkb" },  -- (verify) , channel
    modifier_treant_overgrowth           = { role = "delayed_aoe",   save = "blink_or_manta" },        -- (verify) , AoE root
    modifier_magnataur_skewer            = { role = "line_projectile", save = "perp_displacement" },   -- (verify) , pre_cast save
    modifier_sven_storm_bolt             = { role = "line_projectile", save = "perp_displacement" },   -- (verify)
    modifier_earth_spirit_rolling_boulder= { role = "line_projectile", save = "perp_displacement" },   -- (verify)
    modifier_life_stealer_open_wounds    = { role = "physical_burst", save = "manta_or_pike" },        -- (verify) , debuff
    modifier_pugna_life_drain            = { role = "drain",         save = "force_or_pike" },         -- (verify) , channel
    -- v6.15.10: Disruptor Kinetic Field , trapped. Only knockback escapes.
    modifier_disruptor_kinetic_field_remnant = { role = "trapped",   save = "knockback_only" },         -- (verify)
    -- v6.15.256: Underlord Pit of Malice , same trapped pattern as Kinetic
    -- Field. Snare ticks ~3.6s for 12s; escape via displacement breaks the
    -- root and removes Sniper from the 400u pit area.
    modifier_abyssal_underlord_pit_of_malice_ensare = { role = "trapped",   save = "knockback_only" },         -- (verify)
    -- v6.15.198 harvest , modifier names captured from threat_unrecognized
    -- across three bot matches (post v6.15.194 / .195 / .197). All names
    -- below are HARVESTED (observed in real logs), not guessed; remove the
    -- (verify) caveat for any entry that's confirmed via repeat hits.
    -- Most are kiting / DOT threats Sniper just tanks (save="informational")
    -- , they exist in the catalog so threat_unrecognized stops re-logging
    -- them and so the brain's score-bonus / save-chain dispatcher knows
    -- the kind. Genuine R-blockers (silence, channel-on-me, dispel) get
    -- a real save mapping.
    modifier_phantom_assassin_stiflingdagger    = { role = "light_slow",       save = "informational" },  -- harvested 2026-05-19: brief slow + minor dmg; Sniper just tanks
    modifier_drow_ranger_frost_arrows_slow      = { role = "kiting_slow",      save = "bkb_or_dispel"  },  -- harvested 2026-05-19: per-auto slow, accumulates while Drow chases
    modifier_oracle_fortunes_end_channel_target = { role = "channel_on_me",    save = "bkb_or_dispel"  },  -- harvested 2026-05-20: 2.6s channel pre-dispel marker
    modifier_oracle_fortunes_end_purge          = { role = "dispel_on_me",     save = "informational"  },  -- harvested 2026-05-20: basic dispel landed (BKB/Pike/Aether already gone)
    modifier_oracle_purifying_flames            = { role = "dot",              save = "informational"  },  -- harvested 2026-05-20: damage then heal-over-time (net minor)
    modifier_skeleton_king_reincarnate_slow     = { role = "aura_slow",        save = "informational"  },  -- harvested 2026-05-20: slow on enemies near WK's revival
    modifier_skeleton_king_reincarnation_spawn_skeletons = { role = "aux",     save = "informational"  },  -- harvested 2026-05-20: spawn marker; the skeletons are a separate threat
    modifier_viper_corrosive_skin_slow          = { role = "attacker_slow",    save = "informational"  },  -- harvested 2026-05-20: slow on Viper's attackers; counter is to stop attacking
    modifier_viper_nethertoxin                  = { role = "zone_dot",         save = "informational"  },  -- harvested 2026-05-20: AoE zone DOT; counter is to leave the zone
    modifier_viper_nethertoxin_mute             = { role = "silence_on_me",    save = "bkb_or_dispel"  },  -- harvested 2026-05-20: silence at full Nethertoxin stacks , REAL R-blocker
    modifier_viper_poison_attack_slow           = { role = "kiting_slow",      save = "bkb_or_dispel"  },  -- harvested 2026-05-20: Viper Q applied via auto, slow + DOT
    modifier_necrolyte_heartstopper_aura_effect = { role = "aura_dot",         save = "informational"  },  -- harvested 2026-05-20: %-max-HP aura DOT; counter is move out of range (~1500u)
    modifier_vengefulspirit_retribution_tracker = { role = "tracker",          save = "informational"  },  -- harvested 2026-05-20: VS shard/talent tracker; no direct threat
}

----------------------------------------------------------------------------
-- LOTUS_WORTHY_INCOMING , single-target enemy ults Lotus reflects
----------------------------------------------------------------------------

---@type table<string, boolean>
ThreatData.LOTUS_WORTHY_INCOMING = {
    modifier_lina_laguna_blade    = true,
    modifier_lion_finger_of_death = true,
}

----------------------------------------------------------------------------
-- CAST_POINT_THREATS , pre-cast-armed threats with sub-second windows
----------------------------------------------------------------------------
--
-- v0.5.39 BUG-3: enemy ults / nukes that have a meaningful cast-point window
-- during which the brain should ARM (record the threat and the caster's
-- live cast point) and FIRE the save AT THE END of the cast point (via
-- SAVE_ETA_TRIGGER on the chain head save), NOT immediately on detection.
-- Mirrors the v0.5.6/0.5.7 SAVE_ETA_TRIGGER design used for homing close-gap
-- threats (Bara Charge, Tusk Snowball) but extends it to cast-point ults
-- whose impact lands at end-of-cast-point rather than via flight-time.
--
-- Entry shape:
--   ability      KV-stable ability name (used to resolve the live cast point
--                via Ability.GetCastPoint, and as the reverse-lookup key for
--                anim-path arming - on_hard_disable / on_channel_start).
--   cp_default   fallback cast point (seconds) when Ability.GetCastPoint is
--                unavailable. KV-derivation: matches npc_abilities CastPoint.
--   category     THREAT_CATEGORY-compatible string. Drives the save chain
--                via Dispatcher:ResolveSaveOrder when the brain arms.
--   max_dist     proximity gate (DOTA units). If dist(self, caster) exceeds
--                this at any tick after arming, the entry is GC'd with a
--                cast_point_threat_abort_dist event. Use a large sentinel
--                (e.g. 99999) for global-range threats (Sniper Assassinate,
--                Zeus Thundergod's Wrath, AA Ice Blast).
--
-- Roster v0.5.39 (user-approved):
--   - sniper_assassinate         single-target magical execute, ~2.0s cast
--   - lion_finger_of_death       single-target nuke, 0.6s cast, 600u range
--   - lina_laguna_blade          single-target nuke, 0.45s cast, 750u range.
--                                Hero brains MUST skip self-arming when the
--                                caster is OUR Lina (mirror artifacts).
--   - ancient_apparition_ice_blast frost mark + execute, ~0.5s cast, global
--   - obsidian_destroyer_sanity_eclipse AoE mana-based magic, ~1.7s cast
--   - tinker_laser               single-target stun + nuke, 0.45s cast
--   - zuus_thundergods_wrath     global AoE ult, 0.6s effective windup
--   - doom_bringer_doom          single-target 12s silence. MIGRATED from
--                                LINA_INSTANT_DISABLE_MODS -> CAST_POINT.
--                                Doom's cast is INSTANT in-game (0.5s cast
--                                point but no projectile flight); the brain
--                                now waits ~0.5s before firing BKB/Lotus so
--                                the save lands at modifier-impact time
--                                rather than burning at-cast-start.
--
-- Hero brains pull this table into a module-local upvalue and consult it
-- in OnModifierCreate (catch-all entry) and in their anim subscribers
-- (anim is the primary entry; OnModifierCreate is fallback). The arm-key
-- convention is "castpt:<mod>:<caster_idx>" so concurrent casters of the
-- same ult don't collide.
---@type table<string, { ability:string, cp_default:number, category:string, max_dist:number }>
ThreatData.CAST_POINT_THREATS = {
    modifier_sniper_assassinate                = { ability = "sniper_assassinate",                cp_default = 2.0,  category = "targeted_burst",  max_dist = 99999 },
    modifier_lion_finger_of_death              = { ability = "lion_finger_of_death",              cp_default = 0.6,  category = "targeted_burst",  max_dist = 600   },
    modifier_lina_laguna_blade                 = { ability = "lina_laguna_blade",                 cp_default = 0.45, category = "targeted_burst",  max_dist = 750   },
    modifier_ice_blast                         = { ability = "ancient_apparition_ice_blast",      cp_default = 0.5,  category = "targeted_burst",  max_dist = 99999 },
    modifier_obsidian_destroyer_sanity_eclipse = { ability = "obsidian_destroyer_sanity_eclipse", cp_default = 1.7,  category = "delayed_aoe",     max_dist = 600   },
    modifier_tinker_laser                      = { ability = "tinker_laser",                      cp_default = 0.45, category = "targeted_burst",  max_dist = 550   },
    modifier_zuus_thundergods_wrath            = { ability = "zuus_thundergods_wrath",            cp_default = 0.6,  category = "targeted_burst",  max_dist = 99999 },
    modifier_doom_bringer_doom                 = { ability = "doom_bringer_doom",                 cp_default = 0.5,  category = "targeted_disable", max_dist = 600  },
}

----------------------------------------------------------------------------
-- ENEMY_CHANNEL_MODIFIERS , Layer 1.5 channel-punish / TP-interrupt triggers
----------------------------------------------------------------------------

---@type table<string, boolean>
ThreatData.ENEMY_CHANNEL_MODIFIERS = {
    modifier_bane_fiends_grip              = true,
    modifier_pudge_dismember_pull               = true,
    modifier_witch_doctor_death_ward       = true,
    modifier_crystal_maiden_freezing_field = true,
    modifier_enigma_black_hole             = true,
    modifier_teleporting                   = true,  -- TP-out interrupt
    -- v6.7 (verify modifier names):
    modifier_disruptor_static_storm_thinker = true,
    modifier_pugna_life_drain              = true,
}

----------------------------------------------------------------------------
-- WORTHY_CHANNEL_ABILITIES , allowlist for the channel-interrupt bonus
----------------------------------------------------------------------------
-- Keyed by the CHANNELLING ability name (what GetChannellingAbility +
-- Ability.GetName returns on the casting hero), NOT the modifier name -- the
-- channel modifiers above often live on the victim, not the channelling
-- caster. A long-cast nuke ult (Sniper Assassinate, ~2s) is only worth
-- burning to interrupt a channel that will still be active when it lands.
-- This list is the curated set of long, high-value channels worth that
-- trade. A generic channel detector (NPC.GetChannellingAbility) catches
-- EVERY channel, including low-value player-releasable ones (Keeper of the
-- Light Illuminate releases on command and finishes before a 2s cast
-- lands), so the interrupt bonus must gate on this allowlist rather than
-- firing on any channel. A killable channeler still draws the ult via the
-- kill bonus -- this list governs only the interrupt-for-its-own-sake bonus.
---@type table<string, boolean>
ThreatData.WORTHY_CHANNEL_ABILITIES = {
    bane_fiends_grip              = true,
    pudge_dismember               = true,
    witch_doctor_death_ward       = true,
    crystal_maiden_freezing_field = true,
    enigma_black_hole             = true,
    disruptor_static_storm        = true,
    pugna_life_drain              = true,
}

----------------------------------------------------------------------------
-- ABILITY_TO_THREAT , ability name (from anim events) → threat modifier
----------------------------------------------------------------------------

---@type table<string, string|nil>
ThreatData.ABILITY_TO_THREAT = {
    bane_nightmare                      = "modifier_bane_nightmare",
    bane_fiends_grip                    = "modifier_bane_fiends_grip",
    bane_brain_sap                      = nil,   -- instant nuke, no incoming-side save
    pudge_dismember                     = "modifier_pudge_dismember_pull",
    pudge_meat_hook                     = "modifier_pudge_meat_hook",
    spirit_breaker_charge_of_darkness   = "modifier_spirit_breaker_charge_of_darkness",
    spirit_breaker_nether_strike        = "modifier_spirit_breaker_nether_strike",  -- v6.15.164 (verify) , promoted from nil: blink-strike ult
    tusk_snowball                       = "modifier_tusk_snowball_movement",
    kez_grappling_claw                  = "modifier_kez_grappling_claw_slow",       -- v6.15.162 (verify) , Kez gap-close swing
    -- v6.15.163 , defense catalog refresh, batch 1: the modern hero pool.
    -- KV exposes no modifier names, so every modifier_<ability> below is a
    -- best-effort (verify) guess , confirm via the threat_unrecognized harvest
    -- log and correct any wrong suffix.
    ringmaster_impalement               = "modifier_ringmaster_impalement",
    marci_grapple                       = "modifier_marci_grapple",
    muerta_dead_shot                    = "modifier_muerta_dead_shot",
    primal_beast_onslaught              = "modifier_primal_beast_onslaught",
    dawnbreaker_celestial_hammer        = "modifier_dawnbreaker_celestial_hammer",
    hoodwink_bushwhack                  = "modifier_hoodwink_bushwhack",
    snapfire_mortimer_kisses            = "modifier_snapfire_mortimer_kisses",
    void_spirit_aether_remnant          = "modifier_void_spirit_aether_remnant",
    mars_spear                          = "modifier_mars_spear",
    grimstroke_ink_creature             = "modifier_grimstroke_ink_creature",
    pangolier_swashbuckle               = "modifier_pangolier_swashbuckle",
    dark_willow_cursed_crown            = "modifier_dark_willow_cursed_crown",
    -- v6.15.164 , batch 2: older-hero kidnaps / gap-closes / catches.
    faceless_void_chronosphere          = "modifier_faceless_void_chronosphere_freeze",
    batrider_flaming_lasso              = "modifier_batrider_flaming_lasso",
    tiny_toss                           = "modifier_tiny_toss",
    vengefulspirit_nether_swap          = "modifier_vengefulspirit_nether_swap",
    chaos_knight_reality_rift           = "modifier_chaos_knight_reality_rift",
    rattletrap_hookshot                 = "modifier_rattletrap_hookshot",
    huskar_life_break                   = "modifier_huskar_life_break",
    sandking_burrowstrike               = "modifier_sandking_burrowstrike",
    nyx_assassin_impale                 = "modifier_nyx_assassin_impale",
    -- batch 3-4 (defense catalog refresh, 2026-05-17): executes, targeted
    -- disables, channels, delayed-AoE / traps, gap-close secondaries.
    -- modifier_<ability> guesses, all (verify) , corrected via threat_unrecognized.
    necrolyte_reapers_scythe            = "modifier_necrolyte_reapers_scythe",
    obsidian_destroyer_sanity_eclipse   = "modifier_obsidian_destroyer_sanity_eclipse",
    lich_chain_frost                    = "modifier_lich_chain_frost",
    skywrath_mage_mystic_flare          = "modifier_skywrath_mystic_flare_aura_effect",
    mars_gods_rebuke                    = "modifier_mars_gods_rebuke",
    snapfire_scatterblast               = "modifier_snapfire_scatterblast_slow",
    bloodseeker_rupture                 = "modifier_bloodseeker_rupture",
    obsidian_destroyer_astral_imprisonment = "modifier_obsidian_destroyer_astral_imprisonment",
    skywrath_mage_ancient_seal          = "modifier_skywrath_mage_ancient_seal",
    chaos_knight_chaos_bolt             = "modifier_chaos_knight_chaos_bolt",
    beastmaster_primal_roar             = "modifier_beastmaster_primal_roar",
    shadow_demon_disruption             = "modifier_shadow_demon_disruption",
    shadow_demon_demonic_purge          = "modifier_shadow_demon_demonic_purge",
    winter_wyvern_winters_curse         = "modifier_winter_wyvern_winters_curse",
    enigma_malefice                     = "modifier_enigma_malefice",
    windrunner_shackleshot              = "modifier_windrunner_shackleshot",
    morphling_adaptive_strike_agi       = "modifier_morphling_adaptive_strike_agi",
    puck_waning_rift                    = "modifier_puck_waning_rift",
    lich_sinister_gaze                  = "modifier_lich_sinister_gaze",
    primal_beast_pulverize              = "modifier_primal_beast_pulverize",
    grimstroke_soul_chain               = "modifier_grimstroke_soul_chain",
    puck_dream_coil                     = "modifier_puck_dream_coil",
    leshrac_split_earth                 = "modifier_leshrac_split_earth",
    jakiro_ice_path                     = "modifier_jakiro_ice_path",
    mars_arena_of_blood                 = "modifier_mars_arena_of_blood",
    sandking_epicenter                  = "modifier_sandking_epicenter",
    templar_assassin_psionic_trap       = "modifier_templar_assassin_psionic_trap",
    naga_siren_song_of_the_siren        = "modifier_naga_siren_song_of_the_siren",
    dark_willow_terrorize               = "modifier_dark_willow_terrorize",
    dark_willow_bramble_maze            = "modifier_dark_willow_bramble_maze",
    ringmaster_the_box                  = "modifier_ringmaster_the_box",
    ringmaster_wheel                    = "modifier_ringmaster_wheel",
    kez_raptor_dance                    = "modifier_kez_raptor_dance",
    void_spirit_astral_step             = "modifier_void_spirit_astral_step",
    pangolier_gyroshell                 = "modifier_pangolier_gyroshell",
    nyx_assassin_vendetta               = "modifier_nyx_assassin_vendetta",
    tusk_ice_shards                     = "modifier_tusk_ice_shards_thinker",
    lion_voodoo                         = "modifier_lion_voodoo",
    lion_finger_of_death                = "modifier_lion_finger_of_death",
    lion_impale                         = nil,   -- line, instant landing
    lion_mana_drain                     = "modifier_lion_mana_drain",
    lina_laguna_blade                   = "modifier_lina_laguna_blade",
    lina_light_strike_array             = "modifier_lina_light_strike_array",
    naga_siren_ensnare                  = "modifier_naga_siren_ensnare",
    phantom_assassin_phantom_strike     = "modifier_phantom_assassin_phantom_strike_target",
    slark_pounce                        = "modifier_slark_pounce",
    shadow_shaman_shackles              = "modifier_shadow_shaman_shackles",
    witch_doctor_death_ward             = "modifier_witch_doctor_death_ward",
    enigma_black_hole                   = "modifier_enigma_black_hole",
    crystal_maiden_freezing_field       = "modifier_crystal_maiden_freezing_field",
    mirana_arrow                        = "modifier_mirana_arrow",
    -- v6.7 extrapolation (2026-05-11). Modifier names with (verify) need
    -- in-game confirmation via :FindAllModifiers() before relying on the
    -- exact suffix. Mobility-only abilities map to nil (no save target;
    -- they're informational pre-threats indicating the followup is coming).
    faceless_void_time_walk             = nil,   -- mobility only
    storm_spirit_ball_lightning         = nil,   -- mobility only
    antimage_blink                      = nil,   -- mobility only
    queenofpain_blink                   = nil,   -- mobility only
    magnataur_skewer                    = "modifier_magnataur_skewer",                 -- (verify)
    magnataur_reverse_polarity          = "modifier_magnataur_reverse_polarity_stun",       -- (verify)
    earth_spirit_rolling_boulder        = "modifier_earth_spirit_rolling_boulder",     -- (verify)
    sven_storm_bolt                     = "modifier_sven_storm_bolt",                  -- (verify)
    shadow_shaman_voodoo                = "modifier_shadow_shaman_voodoo",             -- (verify) , Hex
    zuus_lightning_bolt                 = "modifier_zuus_lightning_bolt",              -- (verify)
    zuus_thundergods_wrath              = "modifier_zuus_thundergods_wrath",           -- (verify)
    tidehunter_ravage                   = "modifier_tidehunter_ravage",                -- (verify)
    earthshaker_echo_slam               = "modifier_earthshaker_echo_slam",            -- (verify)
    disruptor_static_storm              = "modifier_disruptor_static_storm_thinker",   -- (verify)
    treant_overgrowth                   = "modifier_treant_overgrowth",                -- (verify)
    life_stealer_open_wounds            = "modifier_life_stealer_open_wounds",         -- (verify)
    pugna_life_drain                    = "modifier_pugna_life_drain",                 -- (verify)
    disruptor_kinetic_field             = "modifier_disruptor_kinetic_field_remnant",  -- (verify) , v6.15.10
    abyssal_underlord_pit_of_malice     = "modifier_abyssal_underlord_pit_of_malice_ensare",   -- (verify) , v6.15.256
    -- v6.15.258 zero-coverage fill batch 1
    dragon_knight_dragon_tail           = "modifier_dragon_knight_dragon_tail",          -- (verify) , v6.15.258
    night_stalker_void                  = "modifier_night_stalker_void",                 -- (verify) , v6.15.258
    ogre_magi_fireblast                 = "modifier_ogre_magi_fireblast",                -- (verify) , v6.15.258
    ogre_magi_unrefined_fireblast       = "modifier_ogre_magi_fireblast",                -- (verify) , v6.15.258 (shares modifier with fireblast)
    rubick_telekinesis                  = "modifier_rubick_telekinesis_stun",                 -- (verify) , v6.15.258
    silencer_last_word                  = "modifier_silencer_last_word",                 -- (verify) , v6.15.258
    death_prophet_silence               = "modifier_death_prophet_silence",              -- (verify) , v6.15.258
    -- v6.15.263 zero-coverage fill batch 2: AOE delayed killers
    ancient_apparition_cold_feet        = "modifier_cold_feet",       -- (verify) , v6.15.263
    ancient_apparition_ice_blast        = "modifier_ice_blast",       -- (verify) , v6.15.263
    antimage_mana_void                  = nil,                                            -- v6.15.263: no Sniper modifier (instant burst); anim-path only
    gyrocopter_homing_missile           = "modifier_gyrocopter_homing_missile",          -- (verify) , v6.15.263
    gyrocopter_call_down                = "modifier_gyrocopter_call_down_slow",          -- (verify) , v6.15.263
    kunkka_torrent                      = "modifier_kunkka_torrent_thinker",             -- (verify) , v6.15.263 (thinker entity for AOE warning)
    kunkka_x_marks_the_spot             = "modifier_kunkka_x_marks_the_spot",            -- (verify) , v6.15.263
    nevermore_requiem_of_souls          = "modifier_nevermore_requiem",                  -- (verify) , v6.15.263
    terrorblade_sunder                  = nil,                                            -- v6.15.263: no Sniper modifier (instant HP swap); anim-path only
    -- v6.15.265 zero-coverage fill batch 3
    doom_bringer_infernal_blade         = "modifier_doom_bringer_infernal_blade",        -- (verify) , v6.15.265
    furion_sprout                       = "modifier_furion_sprout",                       -- (verify) , v6.15.265
    visage_grave_chill                  = "modifier_visage_grave_chill",                  -- (verify) , v6.15.265
    visage_soul_assumption              = nil,                                            -- v6.15.265: no Sniper modifier (instant burst); anim-path only
    venomancer_venomous_gale            = "modifier_venomancer_venomous_gale",            -- (verify) , v6.15.265
    luna_lucent_beam                    = nil,                                            -- v6.15.265: no Sniper modifier (instant mini-stun); anim-path only
    spectre_spectral_dagger             = "modifier_spectre_spectral_dagger",             -- (verify) , v6.15.265
    -- v6.15.266 zero-coverage fill batch 4
    juggernaut_omni_slash               = "modifier_juggernaut_omni_slash",               -- (verify) , v6.15.266
    juggernaut_swift_slash              = nil,                                            -- v6.15.266: no Sniper modifier (gap-close attacks); anim-path only
    phantom_lancer_spirit_lance         = "modifier_phantom_lancer_spirit_lance",         -- (verify) , v6.15.266
    meepo_earthbind                     = "modifier_meepo_earthbind",                     -- (verify) , v6.15.266
    meepo_poof                          = nil,                                            -- v6.15.266: no Sniper modifier (caster gap-close channel); anim-path only
    monkey_king_wukongs_command         = "modifier_monkey_king_wukongs_command_aura",    -- (verify) , v6.15.266
    slardar_slithereen_crush            = "modifier_slardar_slithereen_crush",            -- (verify) , v6.15.266
    slardar_amplify_damage              = "modifier_slardar_amplify_damage",              -- (verify) , v6.15.266
    bristleback_hairball                = "modifier_bristleback_hairball_slow",           -- (verify) , v6.15.266
    -- v6.15.267 zero-coverage fill batch 5
    invoker_cold_snap                   = "modifier_invoker_cold_snap_freeze",            -- (verify) , v6.15.267
    invoker_sun_strike                  = nil,                                            -- v6.15.267: no Sniper modifier (delayed AoE burst); needs OnParticleCreate
    invoker_emp                         = nil,                                            -- v6.15.267: no Sniper modifier (delayed AoE mana burn); needs OnParticleCreate
    riki_smoke_screen                   = "modifier_riki_smoke_screen",                   -- (verify) , v6.15.267
    riki_blink_strike                   = nil,                                            -- v6.15.267: no Sniper modifier (gap-close); anim path
    lone_druid_spirit_bear_entangle     = "modifier_lone_druid_entangle_effect",          -- (verify) , v6.15.267 (bear passive root proc)
    lone_druid_savage_roar              = nil,                                            -- v6.15.267: no Sniper modifier (NO_TARGET fear AoE); anim path
    undying_decay                       = "modifier_undying_decay",                       -- (verify) , v6.15.267
    dazzle_poison_touch                 = "modifier_dazzle_poison_touch",                 -- (verify) , v6.15.267
    weaver_the_swarm                    = "modifier_weaver_the_swarm",                    -- (verify) , v6.15.267
    centaur_double_edge                 = nil,                                            -- v6.15.267: no Sniper modifier (instant burst); anim path
    phoenix_launch_fire_spirit          = nil,                                            -- v6.15.267: no Sniper modifier (line projectile); anim path (ACT_INVALID -- may not fire)
    -- v6.15.268 zero-coverage fill batch 6
    alchemist_unstable_concoction_throw = "modifier_alchemist_unstable_concoction",      -- (verify) , v6.15.268
    broodmother_sticky_snare            = "modifier_broodmother_sticky_snare",            -- (verify) , v6.15.268
    medusa_gorgon_grasp                 = "modifier_medusa_gorgon_grasp",                 -- (verify) , v6.15.268
    medusa_mystic_snake                 = "modifier_medusa_mystic_snake",                 -- (verify) , v6.15.268
    troll_warlord_whirling_axes_ranged  = "modifier_troll_warlord_whirling_axes_ranged",  -- (verify) , v6.15.268
    dark_seer_vacuum                    = "modifier_dark_seer_vacuum",                    -- (verify) , v6.15.268
    dark_seer_ion_shell                 = "modifier_dark_seer_ion_shell",                 -- (verify) , v6.15.268
    ember_spirit_sleight_of_fist        = "modifier_ember_spirit_sleight_of_fist_caster", -- (verify) , v6.15.268 (caster-side phase marker)
    -- v6.15.269 zero-coverage fill batch 7
    bounty_hunter_shuriken_toss         = "modifier_bounty_hunter_shuriken_toss",        -- (verify) , v6.15.269
    brewmaster_cinder_brew              = "modifier_brewmaster_cinder_brew",              -- (verify) , v6.15.269
    phoenix_sun_ray                     = "modifier_phoenix_sun_ray",                     -- (verify) , v6.15.269
    shredder_chakram                    = "modifier_shredder_chakram",                    -- (verify) , v6.15.269
    arc_warden_flux                     = "modifier_arc_warden_flux",                     -- (verify) , v6.15.269
    -- v6.15.270 final mop-up
    abaddon_aphotic_shield              = nil,                                            -- v6.15.270: cast on ALLY; explosion AOE damage is the threat but no Sniper modifier
    -- v0.5.14 E9 (BL-B5): duplicate centaur_double_edge = nil removed (live entry preserved earlier in file at v6.15.267 block; this v6.15.270 duplicate was an editing trap)
    chen_penitence                      = "modifier_chen_penitence",                      -- (verify) , v6.15.270
    enchantress_impetus                 = nil,                                            -- v6.15.270: autocast passive proc damage; no specific modifier (raw projectile damage)
    omniknight_hammer_of_purity         = "modifier_omniknight_hammer_of_purity",         -- (verify) , v6.15.270
    largo_catchy_lick                   = "modifier_largo_catchy_lick",                   -- (verify) , v6.15.270
    -- v0.5.14 E9 (BL-B5): duplicate largo_frogstomp / largo_croak_of_genius nil placeholders removed; the live string-valued entries in the v6.15.272 second-match harvest block below are authoritative
    -- v6.15.271 ranked-match harvest
    tusk_walrus_punch                   = "modifier_tusk_walrus_punch_air_time",          -- harvested 2026-05-24
    tusk_tag_team                       = "modifier_tusk_tag_team_attack_slow",           -- harvested 2026-05-24 (passive proc)
    tiny_avalanche                      = "modifier_tiny_avalanche_stun",                 -- harvested 2026-05-24
    skywrath_mage_concussive_shot       = "modifier_skywrath_mage_concussive_shot_slow",  -- harvested 2026-05-24
    keeper_of_the_light_blinding_light  = "modifier_keeper_of_the_light_blinding_light",  -- harvested 2026-05-24
    keeper_of_the_light_will_o_wisp     = "modifier_keeper_of_the_light_will_o_wisp",     -- harvested 2026-05-24
    keeper_of_the_light_radiant_bind    = "modifier_keeper_of_the_light_radiant_bind",    -- harvested 2026-05-24 (anti-ranged disable)
    legion_commander_press_the_attack   = "modifier_legion_commander_intimidate_slow",    -- harvested 2026-05-24 (verify ability name)
    -- v6.15.272 second-match harvest
    faceless_void_timelock              = "modifier_faceless_void_timelock_freeze",       -- harvested 2026-05-25 (passive)
    faceless_void_time_dilation         = "modifier_faceless_void_time_dilation_distortion", -- harvested 2026-05-25
    largo_frogstomp                     = "modifier_largo_frogstomp_debuff",              -- harvested 2026-05-25 (was nil placeholder in v6.15.270)
    largo_croak_of_genius               = "modifier_largo_croak_of_genius_debuff",        -- harvested 2026-05-25 (was nil placeholder in v6.15.270)
    razor_plasma_field                  = "modifier_razor_plasma_field_slow",             -- harvested 2026-05-25
    razor_storm_surge                   = "modifier_razor_storm_surge_slow",              -- harvested 2026-05-25
    razor_eye_of_the_storm              = "modifier_razor_eye_of_the_storm_armor",        -- harvested 2026-05-25
    rubick_fade_bolt                    = "modifier_rubick_fade_bolt_debuff",             -- harvested 2026-05-25
    -- v6.15.273 third-match harvest
    ancient_apparition_chilling_touch   = "modifier_chilling_touch_slow",                 -- harvested 2026-05-25
    ancient_apparition_ice_vortex       = "modifier_ice_vortex",                          -- harvested 2026-05-25
    ancient_apparition_bone_chill       = "modifier_ancient_apparition_bone_chill_debuff", -- harvested 2026-05-25
    magnataur_shockwave                 = "modifier_magnataur_shockwave_pull",            -- harvested 2026-05-25 (verify ability name)
    snapfire_lil_shredder               = "modifier_snapfire_lil_shredder_debuff",        -- harvested 2026-05-25
    snapfire_magma_burn                 = "modifier_snapfire_magma_burn_slow",            -- harvested 2026-05-25 (verify ability name)
    witch_doctor_maledict               = "modifier_maledict",                            -- harvested 2026-05-25
    -- v6.15.198 harvest , anim-route mappings for the threats harvested
    -- into THREATS_ON_SELF this version. Where one ability lands MULTIPLE
    -- modifiers on the victim (PA Stifling Dagger, Viper Nethertoxin
    -- variants, SK Reincarnation variants), we route the ability to the
    -- PRIMARY threat-modifier , the actively-debuffing one , since the
    -- score-bonus / save-chain dispatcher reads from one name. The
    -- secondary modifier names are still in THREATS_ON_SELF so the
    -- threat_unrecognized harvest loop doesn't re-flag them.
    phantom_assassin_stifling_dagger    = "modifier_phantom_assassin_stiflingdagger",      -- harvested
    drow_ranger_frost_arrows            = "modifier_drow_ranger_frost_arrows_slow",         -- harvested (passive on-attack)
    oracle_fortunes_end                 = "modifier_oracle_fortunes_end_channel_target",    -- harvested , channel marker is primary
    oracle_purifying_flames             = "modifier_oracle_purifying_flames",               -- harvested
    skeleton_king_reincarnation         = "modifier_skeleton_king_reincarnate_slow",        -- harvested , slow aura is the on-Sniper effect
    viper_corrosive_skin                = "modifier_viper_corrosive_skin_slow",              -- harvested (passive on-attack)
    viper_nethertoxin                   = "modifier_viper_nethertoxin_mute",                 -- harvested , silence variant is the R-blocker
    viper_poison_attack                 = "modifier_viper_poison_attack_slow",               -- harvested (passive on-attack)
    necrolyte_heartstopper_aura         = "modifier_necrolyte_heartstopper_aura_effect",     -- harvested (passive aura)
    vengefulspirit_retribution          = "modifier_vengefulspirit_retribution_tracker",     -- harvested (shard tracker)
}

----------------------------------------------------------------------------
-- RECOMMENDED_SAVES , best-to-worst save priority per threat
--
-- The default chain order (Eul → Lotus → Manta → Satanic → Glimmer → Pike →
-- Force → Grenade-self → BKB → Aeon) is generic. For specific threats,
-- different items are clearly better. Examples:
--
--  - **Pudge Dismember (200u tether)**: Pike or grenade-self breaks it
--    instantly. Eul (2.5s cyclone) works but locks Sniper out of attacks for
--    longer than the break needs. BKB doesn't help (Dismember pierces magic
--    immunity). Recommended: Pike → grenade-self → Force → Eul → Manta.
--
--  - **Bara Charge (homing stun)**: Pike/Force/grenade-self are useless
--    (homing re-targets). BKB blocks the stun on impact. Eul invuln spans the
--    impact. Recommended: BKB → Eul → Lotus → Manta.
--
--  - **Bane Nightmare (entity-targeted sleep)**: Eul (invuln cyclone fizzles
--    the cast) is best. BKB blocks during cast point. Manta dispels after.
--    Recommended: Eul → Lotus → Manta → BKB.
--
-- This list lets each hero get the OPTIMAL save per threat instead of always
-- firing the first chain entry that happens to qualify. Hero scripts can
-- ADD hero-specific saves (like Sniper's grenade-self) by extending the list
-- via their own HERO_SAVE_OVERRIDES table.
--
-- Names match SAVE_KIND keys (item_* or generic ability identifiers).
----------------------------------------------------------------------------

---@type table<string, string[]>
ThreatData.RECOMMENDED_SAVES = {
    -- Entity-targeted spells: best = invuln / magic_immune / reflect.
    -- Wind Waker is a strict Eul upgrade (3.5s vs 2.5s, can-act-during).
    modifier_bane_nightmare = {
        "item_cyclone", "item_wind_waker", "item_lotus_orb", "item_manta",
        "item_black_king_bar", "item_aeon_disk",
    },
    modifier_lion_voodoo = {
        "item_lotus_orb", "item_black_king_bar", "item_cyclone", "item_wind_waker",
        "item_aeon_disk",
    },
    modifier_lion_finger_of_death = {
        -- magic_barrier (Pipe of Insight) absorbs a lot of the burst.
        -- v6.7: Eternal Shroud removed in 7.41 , was previously listed here.
        "item_lotus_orb", "item_black_king_bar", "item_cyclone", "item_wind_waker",
        "item_aeon_disk", "item_pipe_of_insight",
    },
    modifier_lina_laguna_blade = {
        "item_lotus_orb", "item_black_king_bar", "item_cyclone", "item_wind_waker",
        "item_aeon_disk", "item_pipe_of_insight",
    },
    modifier_naga_siren_ensnare = {
        -- pierces BKB
        "item_cyclone", "item_wind_waker", "item_lotus_orb", "item_manta",
        "item_satanic", "item_disperser", "item_aeon_disk",
    },
    modifier_doom_bringer_doom = {
        "item_lotus_orb", "item_black_king_bar", "item_cyclone", "item_wind_waker",
        "item_aeon_disk",
    },
    -- Channel-tethers: prefer cheap displacement, fall through to dispel/invuln.
    -- Blink always works (1200u >> any tether).
    modifier_pudge_dismember_pull = {
        -- v6.15.261: hero-agnostic; hero brains insert their own knockback
        -- saves via *_THREAT_PATCHES if applicable. Sniper prepends grenade_self.
        "item_hurricane_pike", "item_force_staff",
        "item_blink", "item_swift_blink", "item_arcane_blink", "item_overwhelming_blink",
        "item_cyclone", "item_wind_waker", "item_manta", "item_disperser",
    },
    modifier_bane_fiends_grip = {
        -- 875u tether (HEURISTIC , Liquipedia doesn't document explicit leash);
        -- Pike push 425u only breaks when Bane is >450u away.
        -- Blink ALWAYS works. Eul/Manta are most reliable dispels.
        -- BKB does NOT work (pierces).
        "item_cyclone", "item_wind_waker", "item_manta", "item_satanic",
        "item_disperser", "item_blink", "item_arcane_blink",
        "item_hurricane_pike", "item_force_staff",
    },
    modifier_shadow_shaman_shackles = {
        -- v6.15.261: hero-agnostic.
        "item_cyclone", "item_wind_waker", "item_manta", "item_satanic",
        "item_disperser", "item_blink",
        "item_hurricane_pike", "item_force_staff",
    },
    modifier_witch_doctor_death_ward = {
        -- v6.7: ward attack range is 650 at level 3 (was using fictional 1100).
        -- Pike (425) / Force (600) sometimes break; Blink always breaks.
        "item_hurricane_pike", "item_force_staff", "item_blink",
        "item_black_king_bar", "item_cyclone", "item_wind_waker",
        "item_pipe_of_insight",
    },
    -- Homing charges: displacement USELESS on self (re-targets). Need
    -- invuln/immune at impact. grenade_at_caster knocks the charger and
    -- cancels the modifier , that's the cheap option for Sniper.
    modifier_spirit_breaker_charge_of_darkness = {
        "item_black_king_bar", "item_cyclone", "item_wind_waker", "item_lotus_orb",
        "item_manta", "item_aeon_disk", "item_ghost",
    },
    modifier_tusk_snowball_movement = {
        "item_black_king_bar", "item_cyclone", "item_wind_waker",
        "item_manta", "item_aeon_disk",
    },
    -- v6.15.162: Kez Grappling Claw. The 80% slow is the danger (Sniper
    -- can't kite). Eul / Wind Waker fully dodge the swing-in + the landing
    -- hit; BKB blocks the slow and keeps Sniper attacking; Pike / grenade
    -- push the caster off (Kez is not displacement-immune).
    modifier_kez_grappling_claw_slow = {
        -- v6.15.261: hero-agnostic.
        "item_cyclone", "item_wind_waker", "item_black_king_bar",
        "item_hurricane_pike", "item_force_staff",
        "item_manta", "item_aeon_disk",
    },
    -- Delayed AoEs: displacement works (target the EFFECT, not the entity)
    modifier_lina_light_strike_array = {
        -- v6.15.261: hero-agnostic.
        "item_hurricane_pike", "item_force_staff", "item_blink",
        "item_cyclone", "item_wind_waker", "item_black_king_bar",
        "item_manta",
    },
    modifier_enigma_black_hole = {
        "item_black_king_bar", "item_hurricane_pike", "item_force_staff",
        "item_blink", "item_arcane_blink", "item_overwhelming_blink",
        "item_cyclone", "item_wind_waker", "item_manta",
    },
    modifier_crystal_maiden_freezing_field = {
        -- v6.15.261: hero-agnostic.
        "item_black_king_bar", "item_hurricane_pike", "item_force_staff",
        "item_blink", "item_pipe_of_insight",
    },
    -- Line projectiles: perpendicular displacement
    modifier_pudge_meat_hook = {
        -- v6.15.261: hero-agnostic.
        "item_hurricane_pike", "item_force_staff", "item_blink",
        "item_cyclone", "item_wind_waker",
    },
    -- v6.14.1 M9: Tusk Ice Shards , slow-moving line projectile, perp
    -- displacement / blink avoids. Mirrors hook ordering.
    modifier_tusk_ice_shards_thinker = {
        -- v6.15.261: hero-agnostic.
        "item_hurricane_pike", "item_force_staff", "item_blink",
        "item_cyclone", "item_wind_waker",
    },
    modifier_slark_pounce = {
        -- v6.15.261: hero-agnostic.
        "item_force_staff", "item_hurricane_pike", "item_blink",
        "item_cyclone", "item_wind_waker", "item_manta", "item_black_king_bar",
    },
    modifier_mirana_arrow = {
        -- v6.15.261: hero-agnostic.
        "item_hurricane_pike", "item_force_staff", "item_blink",
        "item_cyclone",
    },
    -- Physical chase: invis breaks target-lock; BKB doesn't help. Ghost makes
    -- attacks miss entirely. Blade Mail returns damage. Crimson blocks.
    modifier_phantom_assassin_phantom_strike_target = {
        -- v6.15.261: hero-agnostic.
        "item_glimmer_cape", "item_ghost", "item_blade_mail",
        "item_hurricane_pike", "item_force_staff", "item_blink",
        "item_cyclone", "item_crimson_guard", "item_solar_crest",
    },
    modifier_ursa_overpower = {
        "item_glimmer_cape", "item_ghost", "item_blade_mail",
        "item_hurricane_pike", "item_force_staff", "item_blink",
        "item_cyclone", "item_crimson_guard", "item_solar_crest",
    },
    -- Drain: pierces BKB
    modifier_razor_static_link_debuff = {
        "item_cyclone", "item_wind_waker", "item_manta",
        "item_hurricane_pike", "item_force_staff", "item_blink",
    },
    modifier_lion_mana_drain = {
        -- v6.15.261: hero-agnostic.
        "item_cyclone", "item_wind_waker", "item_manta",
        "item_hurricane_pike", "item_force_staff", "item_blink",
    },
    -- Lockdown , Satanic for lifesteal-tank, Blade Mail returns Duel damage
    modifier_legion_commander_duel = {
        "item_satanic", "item_blade_mail", "item_cyclone", "item_wind_waker",
        "item_manta",
    },
    -- Misc
    -- v6.15.203 (audit D5): the comment claim "BKB ignores taunt" is
    -- WRONG , Berserker's Call PIERCES spell immunity (Liquipedia). Blade
    -- Mail returns the post-armor attack damage Sniper deals to Axe at
    -- FULL strength against Sniper's own armor , net loss. Entry kept
    -- for documentation but never consumed: THREATS_ON_SELF tags
    -- save="informational" and the v6.15.202 D1 dispatcher catch-all
    -- correctly no-ops on that.
    modifier_axe_berserkers_call = {
        "item_black_king_bar", "item_blade_mail",
    },
    -- v6.7 extrapolation entries
    modifier_shadow_shaman_voodoo = {
        "item_lotus_orb", "item_black_king_bar", "item_cyclone", "item_wind_waker",
        "item_aeon_disk", "item_manta",
    },
    modifier_zuus_lightning_bolt = {
        "item_lotus_orb", "item_black_king_bar", "item_cyclone", "item_wind_waker",
        "item_aeon_disk", "item_pipe_of_insight",
    },
    modifier_zuus_thundergods_wrath = {
        -- Global ult, 2s cast point. NOT reflectable (AoE, not single-target).
        "item_black_king_bar", "item_cyclone", "item_wind_waker", "item_aeon_disk",
        "item_pipe_of_insight",
    },
    modifier_tidehunter_ravage = {
        "item_black_king_bar", "item_blink", "item_arcane_blink", "item_swift_blink",
        "item_cyclone", "item_wind_waker", "item_manta", "item_aeon_disk",
        "item_pipe_of_insight",
    },
    modifier_earthshaker_echo_slam = {
        "item_black_king_bar", "item_blink", "item_arcane_blink",
        "item_hurricane_pike", "item_force_staff", "item_cyclone",
        "item_wind_waker", "item_pipe_of_insight",
    },
    modifier_magnataur_reverse_polarity_stun = {
        -- 1700u radius. Only Blink (1200-1400) reliably escapes; BKB / Aeon
        -- carry through the stun.
        "item_blink", "item_arcane_blink", "item_black_king_bar",
        "item_cyclone", "item_wind_waker", "item_aeon_disk",
    },
    modifier_disruptor_static_storm_thinker = {
        "item_hurricane_pike", "item_force_staff", "item_blink",
        "item_black_king_bar", "item_cyclone", "item_wind_waker",
        "item_pipe_of_insight",
    },
    -- v6.15.10: Disruptor Kinetic Field. Wall blocks forced movement, blink,
    -- and cyclone displacement. Only KNOCKBACK crosses -- which no item
    -- provides, only hero-specific abilities (Sniper Concussive Grenade,
    -- etc.). v6.15.261: lib entry is empty (no item works); hero brains
    -- inject knockback via *_THREAT_PATCHES. The dispatcher falls through to
    -- the trap category chain (blinks) if no patch is registered -- blinks
    -- also do not work against KF in practice, but the failure is silent.
    modifier_disruptor_kinetic_field_remnant = {},
    -- v6.15.256: Underlord Pit of Malice. Same trap escape posture as
    -- Kinetic Field; only hero-knockback escapes the snare reliably.
    -- v6.15.261: hero-agnostic empty chain; hero patches inject knockback.
    modifier_abyssal_underlord_pit_of_malice_ensare = {},
    modifier_treant_overgrowth = {
        "item_black_king_bar", "item_blink", "item_swift_blink",
        "item_cyclone", "item_wind_waker", "item_manta",
        "item_aeon_disk",
    },
    modifier_magnataur_skewer = {
        -- v6.15.261: hero-agnostic.
        "item_hurricane_pike", "item_force_staff",
        "item_blink", "item_black_king_bar", "item_cyclone",
    },
    modifier_sven_storm_bolt = {
        -- v6.15.261: hero-agnostic.
        "item_hurricane_pike", "item_force_staff",
        "item_blink", "item_cyclone",
    },
    modifier_earth_spirit_rolling_boulder = {
        -- v6.15.261: hero-agnostic.
        "item_hurricane_pike", "item_force_staff",
        "item_blink", "item_cyclone",
    },
    modifier_life_stealer_open_wounds = {
        "item_glimmer_cape", "item_ghost", "item_blade_mail", "item_manta",
        "item_hurricane_pike", "item_force_staff", "item_satanic",
        "item_crimson_guard",
    },
    modifier_pugna_life_drain = {
        -- v6.15.261: hero-agnostic.
        "item_cyclone", "item_wind_waker", "item_manta", "item_blink",
        "item_hurricane_pike", "item_force_staff",
    },
}

----------------------------------------------------------------------------
-- CATEGORY_CHAINS , per-category fallback save chains
----------------------------------------------------------------------------

---Default save chain per THREAT_CATEGORY. Used by the resolver when a threat
---has no entry in RECOMMENDED_SAVES and no hero-side override. These are the
---chains validated on the tested heroes; new threats with a known category
---get the canonical response for their behavioral class without per-modifier
---tuning.
---
---v6.15.259: extracted from Sniper/Sniper.lua so other hero brains can
---consume the same category-keyed defaults.
---v6.15.260: HERO-AGNOSTIC -- no per-hero save names appear in any chain.
---Hero brains insert their own abilities via per-hero category-patch tables
---(Sniper uses SNIPER_CATEGORY_PATCHES with {prepend, insert_after, append}
---semantics). The lib chain is the items-only baseline; the hero patch
---adds hero-specific saves around the baseline.
---@type table<string, string[]>
ThreatData.CATEGORY_CHAINS = {
    -- Chase / gap-close (Bara, Tusk, PA Strike, Slark Pounce, Storm Ball
    -- Lightning, Magnus Skewer/RP-prep, anything homing toward the hero).
    -- Pike-on-enemy radial-pushes them, Force pushes self, BKB blocks damage.
    close_gap = {
        "item_hurricane_pike",
        "item_force_staff",
        "item_black_king_bar", "item_cyclone", "item_wind_waker",
        "item_lotus_orb", "item_manta", "item_aeon_disk", "item_ghost",
    },
    -- Tether channels on the hero (Pudge Dismember, Bane Grip, Shaman
    -- Shackles, WD Death Ward, Legion Duel, Pugna Life Drain -- anything
    -- that locks the hero at range from the caster). Force/Pike push breaks
    -- the tether; Manta/Satanic dispel some; BKB blocks damage.
    channel_on_self = {
        "item_hurricane_pike",
        "item_force_staff",
        "item_manta", "item_satanic", "item_disperser",
        "item_cyclone", "item_wind_waker", "item_aeon_disk",
    },
    -- Line projectiles (Mirana Arrow, Pudge Hook, Magnus Skewer, Sven Bolt,
    -- Earth Spirit Boulder). Perpendicular displacement breaks the line.
    line_projectile = {
        "item_force_staff", "item_hurricane_pike",
        "item_cyclone", "item_manta", "item_black_king_bar",
    },
    -- Single-target hard disable (Hex, Doom debuff cast, Lion Voodoo,
    -- Shaman Voodoo). Instant-cast invuln (Eul/Wind Waker/Lotus) ideal.
    targeted_disable = {
        "item_cyclone", "item_wind_waker", "item_lotus_orb",
        "item_manta", "item_aeon_disk", "item_black_king_bar",
    },
    -- AoE lockdown ults (Tide Ravage, ES Echo Slam, Magnus RP, Naga Siren,
    -- Treant Overgrowth, Disruptor Static Storm). Blink/Pike out, BKB the
    -- damage, Aeon trigger on health drop.
    delayed_aoe = {
        "item_hurricane_pike", "item_force_staff",
        "item_blink", "item_arcane_blink", "item_swift_blink",
        "item_black_king_bar", "item_cyclone", "item_wind_waker",
        "item_pipe_of_insight", "item_aeon_disk",
    },
    -- Area-deny traps (Disruptor Kinetic Field, Underlord Pit of Malice,
    -- Faceless Void Chrono edge). Forced movement blocked -- only knockback
    -- and blink escape. Hero-specific knockback abilities patch in via
    -- per-hero CATEGORY_PATCHES.
    trap = {
        "item_blink", "item_arcane_blink", "item_swift_blink",
    },
    -- Drain channels (Pugna Life Drain, Lion Mana Drain). Force/Pike
    -- breaks tether.
    drain = {
        "item_force_staff", "item_hurricane_pike",
        "item_cyclone", "item_manta",
    },
    -- Physical-chase debuffs (Lifestealer Open Wounds, Slark Essence Shift).
    -- Pike pushes chaser, Glimmer/Ghost break attack target-lock.
    physical_chase = {
        "item_hurricane_pike", "item_force_staff",
        "item_glimmer_cape", "item_ghost",
        "item_manta", "item_black_king_bar",
    },
    -- Lockdown buffs on enemy (Bristleback turn, Troll trance, Ursa Enrage).
    -- The enemy is now extra-tanky -- defensive items rather than displacement.
    lockdown = {
        "item_cyclone", "item_wind_waker", "item_lotus_orb",
        "item_manta", "item_aeon_disk", "item_black_king_bar",
    },
    -- Single-target burst (Lina Laguna, Lion Finger, Zeus Bolt, single-target
    -- nukes). Lotus reflects, BKB blocks, magic_barrier eats.
    targeted_burst = {
        "item_lotus_orb",
        "item_black_king_bar", "item_pipe_of_insight",
        "item_cyclone", "item_wind_waker", "item_glimmer_cape",
        "item_manta", "item_aeon_disk",
    },
}

---Look up the default save chain for a category. Returns nil if no entry.
---@param category string|nil
---@return string[]|nil
function ThreatData.CategoryChain(category)
    if not category then return nil end
    return ThreatData.CATEGORY_CHAINS[category]
end

----------------------------------------------------------------------------
-- THREAT_TIMING , when to fire the save relative to the threat
----------------------------------------------------------------------------

---When the hero should fire its save. Values:
---  `pre_cast`     , fire during the cast point window, BEFORE modifier lands
---                   (target invuln/immune at impact = cast fizzles)
---  `at_impact`    , fire just before threat impact (homing charges; the
---                   armed-ETA system handles this in the brain)
---  `mid_channel`  , fire any time during the channel (Dismember tick by tick)
---  `reactive`     , fire after modifier lands; the save dispels or escapes
---  `prophylactic` , pre-arm before threat manifests (rare; Doom is unfixable
---                   post-cast, so saves are pre-cast or none)
---
---These describe WHEN to fire. See THREAT_CATEGORY below for WHAT KIND of
---response is best (anti-close-gap vs threat-stopper vs etc.). Timing and
---category are independent axes , a `close_gap` threat is dispatched via
---`at_impact` timing, a `channel_on_self` threat via `mid_channel`.
---@type table<string, string>
ThreatData.THREAT_TIMING = {
    modifier_bane_nightmare              = "pre_cast",
    modifier_bane_fiends_grip            = "pre_cast",
    modifier_lion_voodoo                 = "pre_cast",
    modifier_lion_finger_of_death        = "pre_cast",
    modifier_lina_laguna_blade           = "pre_cast",
    modifier_lina_light_strike_array     = "pre_cast",   -- 0.5s delayed; act in cast point
    modifier_naga_siren_ensnare          = "pre_cast",
    modifier_doom_bringer_doom           = "pre_cast",
    modifier_pudge_dismember_pull             = "mid_channel",
    modifier_shadow_shaman_shackles      = "mid_channel",
    modifier_witch_doctor_death_ward     = "mid_channel",
    modifier_enigma_black_hole           = "mid_channel",
    modifier_crystal_maiden_freezing_field = "mid_channel",
    modifier_spirit_breaker_charge_of_darkness = "at_impact",
    modifier_tusk_snowball_movement      = "at_impact",
    modifier_kez_grappling_claw_slow          = "at_impact",  -- v6.15.162 (verify) , fire as Kez swings in
    -- v6.15.163 batch 1 , modern hero pool
    modifier_ringmaster_impalement       = "pre_cast",
    modifier_marci_grapple               = "at_impact",
    modifier_muerta_dead_shot            = "pre_cast",
    modifier_primal_beast_onslaught      = "at_impact",
    modifier_dawnbreaker_celestial_hammer = "at_impact",
    modifier_hoodwink_bushwhack          = "pre_cast",
    modifier_snapfire_mortimer_kisses    = "pre_cast",
    modifier_void_spirit_aether_remnant  = "pre_cast",
    modifier_mars_spear                  = "pre_cast",
    modifier_grimstroke_ink_creature     = "reactive",
    modifier_pangolier_swashbuckle       = "at_impact",
    modifier_dark_willow_cursed_crown    = "pre_cast",
    -- v6.15.164 batch 2 , older-hero kidnaps / gap-closes / catches
    modifier_faceless_void_chronosphere_freeze  = "pre_cast",
    modifier_batrider_flaming_lasso      = "reactive",
    modifier_tiny_toss                   = "pre_cast",
    modifier_vengefulspirit_nether_swap  = "reactive",
    modifier_chaos_knight_reality_rift   = "at_impact",
    modifier_rattletrap_hookshot         = "at_impact",
    modifier_spirit_breaker_nether_strike = "at_impact",
    modifier_huskar_life_break           = "at_impact",
    modifier_sandking_burrowstrike       = "pre_cast",
    modifier_nyx_assassin_impale         = "pre_cast",
    -- batch 3-4 (defense catalog refresh, 2026-05-17)
    modifier_necrolyte_reapers_scythe               = "pre_cast",
    modifier_obsidian_destroyer_sanity_eclipse      = "pre_cast",
    modifier_lich_chain_frost                       = "pre_cast",
    modifier_skywrath_mystic_flare_aura_effect             = "pre_cast",
    modifier_mars_gods_rebuke                       = "pre_cast",
    modifier_snapfire_scatterblast_slow                  = "pre_cast",
    modifier_bloodseeker_rupture                    = "pre_cast",
    modifier_obsidian_destroyer_astral_imprisonment = "pre_cast",
    modifier_skywrath_mage_ancient_seal             = "pre_cast",
    modifier_chaos_knight_chaos_bolt                = "pre_cast",
    modifier_beastmaster_primal_roar                = "pre_cast",
    modifier_shadow_demon_disruption                = "pre_cast",
    modifier_shadow_demon_demonic_purge             = "pre_cast",
    modifier_winter_wyvern_winters_curse            = "pre_cast",
    modifier_enigma_malefice                        = "reactive",
    modifier_windrunner_shackleshot                 = "pre_cast",
    modifier_morphling_adaptive_strike_agi          = "pre_cast",
    modifier_puck_waning_rift                       = "reactive",
    modifier_lich_sinister_gaze                     = "mid_channel",
    modifier_primal_beast_pulverize                 = "mid_channel",
    modifier_grimstroke_soul_chain                  = "pre_cast",
    modifier_puck_dream_coil                        = "pre_cast",
    modifier_leshrac_split_earth                    = "pre_cast",
    modifier_jakiro_ice_path                        = "pre_cast",
    modifier_mars_arena_of_blood                    = "pre_cast",
    modifier_sandking_epicenter                     = "pre_cast",
    modifier_templar_assassin_psionic_trap          = "reactive",
    modifier_naga_siren_song_of_the_siren           = "pre_cast",
    modifier_dark_willow_terrorize                  = "pre_cast",
    modifier_dark_willow_bramble_maze               = "pre_cast",
    modifier_ringmaster_the_box                     = "reactive",
    modifier_ringmaster_wheel                       = "pre_cast",
    modifier_kez_raptor_dance                       = "pre_cast",
    modifier_void_spirit_astral_step                = "at_impact",
    modifier_pangolier_gyroshell                    = "at_impact",
    modifier_nyx_assassin_vendetta                  = "at_impact",
    modifier_pudge_meat_hook             = "at_impact",  -- when hook is in flight
    modifier_slark_pounce                = "at_impact",
    modifier_mirana_arrow                = "at_impact",
    modifier_razor_static_link_debuff           = "reactive",
    modifier_lion_mana_drain             = "reactive",
    modifier_phantom_assassin_phantom_strike_target = "reactive",  -- already blinked
    modifier_ursa_overpower              = "reactive",
    modifier_legion_commander_duel       = "reactive",
    modifier_tusk_ice_shards_thinker     = "pre_cast",
    -- v6.7 extrapolation
    modifier_shadow_shaman_voodoo        = "pre_cast",
    modifier_zuus_lightning_bolt         = "pre_cast",
    modifier_zuus_thundergods_wrath      = "pre_cast",  -- 2s cast point , plenty of time
    modifier_tidehunter_ravage           = "pre_cast",
    modifier_earthshaker_echo_slam       = "pre_cast",
    modifier_magnataur_reverse_polarity_stun  = "pre_cast",
    modifier_disruptor_static_storm_thinker = "mid_channel",
    modifier_treant_overgrowth           = "pre_cast",
    modifier_magnataur_skewer            = "pre_cast",  -- save fires during Magnus's cast point; once grabbed, perp is useless
    modifier_sven_storm_bolt             = "at_impact",
    modifier_earth_spirit_rolling_boulder = "at_impact",
    modifier_life_stealer_open_wounds    = "reactive",
    modifier_pugna_life_drain            = "reactive",
    modifier_disruptor_kinetic_field_remnant = "reactive",  -- v6.15.10 , fires once trapped
    modifier_abyssal_underlord_pit_of_malice_ensare = "reactive",  -- v6.15.256 , fires once snared
}

----------------------------------------------------------------------------
-- THREAT_CATEGORY , semantic classification of what KIND of response wins
--
-- This is the "anti-close-gap vs threat-stopper" axis the user asked about,
-- broken out as data so the brain logs it and per-hero overrides can tune
-- by category. The flat RECOMMENDED_SAVES list still drives selection , but
-- the category tells us at a glance what RESPONSE PROFILE matters:
--
--  `close_gap`         , homing approach (Bara Charge, Tusk Snowball).
--                        Best response: cancel-on-caster (grenade-at-caster,
--                        Pike-on-Bara forced movement). Save fires during
--                        approach via armed_threats_tick.
--  `channel_on_self`   , enemy channels on Sniper (Dismember, Fiend Grip,
--                        Shackles, Death Ward). Best response: break channel
--                        (grenade-at-caster ROOT_DISABLES) OR self-dispel
--                        (Manta, Eul). Fires pre-cast via anim or reactive
--                        via OnModifierCreate.
--  `targeted_disable`  , pre-cast hard CC (Nightmare, Hex, Ensnare, Doom).
--                        Best response: invuln/immune during cast point so
--                        the cast fizzles or the modifier never lands.
--  `targeted_burst`    , high-damage targeted ult (Finger, Laguna). Best
--                        response: invuln / magic_barrier / reflect to
--                        absorb or bounce.
--  `delayed_aoe`       , AoE landing after a delay (LSA, Black Hole,
--                        Freezing Field). Best response: displacement
--                        (Pike, Force, Blink, grenade-self) , get out.
--  `line_projectile`   , dodgeable line shot (Hook, Pounce, Ice Shards,
--                        Arrow). Best response: perpendicular displacement.
--  `physical_chase`    , sustained physical pressure (PA Strike, Ursa
--                        Overpower). Best response: invis breaks target-
--                        lock, Ghost/Crimson/Blade Mail reduce/return.
--  `drain`             , resource/HP drain channels (Static Link, Mana
--                        Drain). Best response: dispel or move out of
--                        tether range.
--  `lockdown`          , forced attack-only or taunt (Duel, Berserker's
--                        Call). Best response: Satanic lifesteal-through
--                        or Blade Mail return-damage.
--
-- For the user's "separate section" question: this categorization PROVIDES
-- the separation in data without splitting code paths. Each save-issue site
-- (armed_threats_tick / anim_channel_start / OnModifierCreate / etc.) still
-- goes through `try_save_self` , the per-threat overrides in each hero's
-- SAVE_OVERRIDES table express the category-appropriate preferences.
----------------------------------------------------------------------------

---@type table<string, string>
ThreatData.THREAT_CATEGORY = {
    -- Close-gap (homing)
    modifier_spirit_breaker_charge_of_darkness = "close_gap",
    modifier_tusk_snowball_movement            = "close_gap",
    modifier_kez_grappling_claw_slow                = "close_gap",       -- v6.15.162 (verify) , Kez Grappling Claw
    -- v6.15.163 batch 1 , modern hero pool
    modifier_ringmaster_impalement             = "line_projectile",
    modifier_marci_grapple                     = "close_gap",
    modifier_muerta_dead_shot                  = "targeted_disable",
    modifier_primal_beast_onslaught            = "close_gap",
    modifier_dawnbreaker_celestial_hammer      = "close_gap",
    modifier_hoodwink_bushwhack                = "delayed_aoe",
    modifier_snapfire_mortimer_kisses          = "delayed_aoe",
    modifier_void_spirit_aether_remnant        = "targeted_disable",
    modifier_mars_spear                        = "line_projectile",
    modifier_grimstroke_ink_creature           = "targeted_disable",
    modifier_pangolier_swashbuckle             = "close_gap",
    modifier_dark_willow_cursed_crown          = "targeted_disable",
    -- v6.15.164 batch 2 , older-hero kidnaps / gap-closes / catches
    modifier_faceless_void_chronosphere_freeze        = "delayed_aoe",
    modifier_batrider_flaming_lasso            = "targeted_disable",
    modifier_tiny_toss                         = "targeted_disable",
    modifier_vengefulspirit_nether_swap        = "targeted_disable",
    modifier_chaos_knight_reality_rift         = "close_gap",
    modifier_rattletrap_hookshot               = "close_gap",
    modifier_spirit_breaker_nether_strike      = "close_gap",
    modifier_huskar_life_break                 = "close_gap",
    modifier_sandking_burrowstrike             = "line_projectile",
    modifier_nyx_assassin_impale               = "line_projectile",
    -- batch 3-4 (defense catalog refresh, 2026-05-17)
    modifier_necrolyte_reapers_scythe               = "targeted_burst",
    modifier_obsidian_destroyer_sanity_eclipse      = "targeted_burst",
    modifier_lich_chain_frost                       = "targeted_burst",
    modifier_skywrath_mystic_flare_aura_effect             = "delayed_aoe",
    modifier_mars_gods_rebuke                       = "targeted_burst",
    modifier_snapfire_scatterblast_slow                  = "targeted_burst",
    modifier_bloodseeker_rupture                    = "targeted_burst",
    modifier_obsidian_destroyer_astral_imprisonment = "targeted_disable",
    modifier_skywrath_mage_ancient_seal             = "targeted_disable",
    modifier_chaos_knight_chaos_bolt                = "targeted_disable",
    modifier_beastmaster_primal_roar                = "targeted_disable",
    modifier_shadow_demon_disruption                = "targeted_disable",
    modifier_shadow_demon_demonic_purge             = "targeted_disable",
    modifier_winter_wyvern_winters_curse            = "targeted_disable",
    modifier_enigma_malefice                        = "targeted_disable",
    modifier_windrunner_shackleshot                 = "targeted_disable",
    modifier_morphling_adaptive_strike_agi          = "targeted_disable",
    modifier_puck_waning_rift                       = "targeted_disable",
    modifier_lich_sinister_gaze                     = "channel_on_self",
    modifier_primal_beast_pulverize                 = "channel_on_self",
    modifier_grimstroke_soul_chain                  = "channel_on_self",
    modifier_puck_dream_coil                        = "delayed_aoe",
    modifier_leshrac_split_earth                    = "delayed_aoe",
    modifier_jakiro_ice_path                        = "delayed_aoe",
    modifier_mars_arena_of_blood                    = "delayed_aoe",
    modifier_sandking_epicenter                     = "delayed_aoe",
    modifier_templar_assassin_psionic_trap          = "trap",
    modifier_naga_siren_song_of_the_siren           = "delayed_aoe",
    modifier_dark_willow_terrorize                  = "delayed_aoe",
    modifier_dark_willow_bramble_maze               = "delayed_aoe",
    modifier_ringmaster_the_box                     = "trap",
    modifier_ringmaster_wheel                       = "delayed_aoe",
    modifier_kez_raptor_dance                       = "delayed_aoe",
    modifier_void_spirit_astral_step                = "close_gap",
    modifier_pangolier_gyroshell                    = "close_gap",
    modifier_nyx_assassin_vendetta                  = "close_gap",
    modifier_phantom_assassin_phantom_strike_target = "close_gap",  -- already landed, but the chase profile is gap-close
    modifier_slark_pounce                      = "close_gap",       -- gap-close + leash
    -- Channel on self
    modifier_pudge_dismember_pull                   = "channel_on_self",
    modifier_bane_fiends_grip                  = "channel_on_self",
    modifier_shadow_shaman_shackles            = "channel_on_self",
    modifier_witch_doctor_death_ward           = "channel_on_self",
    -- Targeted disable (pre-cast)
    modifier_bane_nightmare                    = "targeted_disable",
    modifier_lion_voodoo                       = "targeted_disable",
    modifier_naga_siren_ensnare                = "targeted_disable",
    modifier_doom_bringer_doom                 = "targeted_disable",
    -- Targeted burst
    modifier_lion_finger_of_death              = "targeted_burst",
    modifier_lina_laguna_blade                 = "targeted_burst",
    -- Delayed AoE
    modifier_lina_light_strike_array           = "delayed_aoe",
    modifier_enigma_black_hole                 = "delayed_aoe",
    modifier_crystal_maiden_freezing_field     = "delayed_aoe",
    -- Line projectile
    modifier_pudge_meat_hook                   = "line_projectile",
    modifier_tusk_ice_shards_thinker           = "line_projectile",
    modifier_mirana_arrow                      = "line_projectile",
    -- Physical chase
    modifier_ursa_overpower                    = "physical_chase",
    -- Drain
    modifier_razor_static_link_debuff                 = "drain",
    modifier_lion_mana_drain                   = "drain",
    -- Lockdown
    modifier_legion_commander_duel             = "lockdown",
    modifier_axe_berserkers_call               = "lockdown",
    -- v6.7 extrapolation
    modifier_shadow_shaman_voodoo              = "targeted_disable",
    modifier_zuus_lightning_bolt               = "targeted_burst",
    modifier_zuus_thundergods_wrath            = "targeted_burst",
    modifier_tidehunter_ravage                 = "delayed_aoe",
    modifier_earthshaker_echo_slam             = "delayed_aoe",
    modifier_magnataur_reverse_polarity_stun        = "delayed_aoe",
    modifier_disruptor_static_storm_thinker    = "delayed_aoe",
    modifier_treant_overgrowth                 = "delayed_aoe",
    modifier_magnataur_skewer                  = "line_projectile",
    modifier_sven_storm_bolt                   = "line_projectile",
    modifier_earth_spirit_rolling_boulder      = "line_projectile",
    modifier_life_stealer_open_wounds          = "physical_chase",
    modifier_pugna_life_drain                  = "drain",
    modifier_disruptor_kinetic_field_remnant   = "trap",         -- v6.15.10
    modifier_abyssal_underlord_pit_of_malice_ensare   = "trap",         -- v6.15.256
    -- v6.15.258 zero-coverage fill batch 1
    modifier_dragon_knight_dragon_tail         = "targeted_disable",  -- v6.15.258
    modifier_night_stalker_void                = "targeted_disable",  -- v6.15.258
    modifier_ogre_magi_fireblast               = "targeted_disable",  -- v6.15.258
    modifier_rubick_telekinesis_stun                = "targeted_disable",  -- v6.15.258
    modifier_silencer_last_word                = "targeted_disable",  -- v6.15.258 (silence is a disable)
    modifier_death_prophet_silence             = "targeted_disable",  -- v6.15.258 (silence)
    -- v6.15.263 zero-coverage fill batch 2
    modifier_cold_feet      = "targeted_disable",  -- v6.15.263 (delayed stun)
    modifier_ice_blast      = "targeted_burst",    -- v6.15.263 (frost mark + magic burst, executes low HP)
    modifier_gyrocopter_homing_missile         = "line_projectile",   -- v6.15.263 (homing but dodgeable)
    modifier_kunkka_torrent_thinker            = "delayed_aoe",       -- v6.15.263 (geyser warning)
    modifier_kunkka_torrent_stun               = "targeted_disable",  -- v6.15.263 (stun applied at impact)
    modifier_kunkka_x_marks_the_spot           = "targeted_disable",  -- v6.15.263 (drag-back debuff)
    modifier_nevermore_requiem                 = "delayed_aoe",       -- v6.15.263 (fear radial)
    -- v6.15.264: ES Rolling Boulder caster-side -- routed via ENEMY_BUFF_THREATS
    modifier_earth_spirit_rolling_boulder_caster = "line_projectile",  -- v6.15.264
    -- v6.15.265 zero-coverage fill batch 3
    modifier_doom_bringer_infernal_blade       = "targeted_disable",  -- v6.15.265 (mini-stun)
    modifier_furion_sprout                     = "targeted_disable",  -- v6.15.265 (root cage)
    modifier_visage_grave_chill                = "targeted_disable",  -- v6.15.265 (slow + silence)
    modifier_venomancer_venomous_gale          = "line_projectile",   -- v6.15.265 (line aoe slow+dot)
    modifier_spectre_spectral_dagger           = "line_projectile",   -- v6.15.265 (gap-close debuff)
    -- v6.15.266 zero-coverage fill batch 4
    modifier_juggernaut_omni_slash             = "channel_on_self",   -- v6.15.266 (target-locked channel)
    modifier_phantom_lancer_spirit_lance       = "kiting_slow",       -- v6.15.266 (slow + damage proc)
    modifier_meepo_earthbind                   = "targeted_disable",  -- v6.15.266 (delayed AoE root)
    modifier_monkey_king_wukongs_command_aura  = "delayed_aoe",       -- v6.15.266 (cage area)
    modifier_slardar_amplify_damage            = "kiting_slow",       -- v6.15.266 (armor reduction setup)
    modifier_slardar_slithereen_crush          = "targeted_disable",  -- v6.15.266 (AoE stun)
    modifier_bristleback_hairball_slow         = "kiting_slow",       -- v6.15.266 (slow line)
    -- v6.15.267 zero-coverage fill batch 5
    modifier_invoker_cold_snap_freeze          = "targeted_disable",  -- v6.15.267 (recurring mini-stun)
    modifier_riki_smoke_screen                 = "targeted_disable",  -- v6.15.267 (AoE silence)
    modifier_lone_druid_entangle_effect        = "targeted_disable",  -- v6.15.267 (bear attack root proc)
    modifier_undying_decay                     = "kiting_slow",       -- v6.15.267 (STR drain)
    modifier_dazzle_poison_touch               = "kiting_slow",       -- v6.15.267 (slow + dot + delayed stun)
    modifier_weaver_the_swarm                  = "kiting_slow",       -- v6.15.267 (armor reduction + attack proc)
    -- v6.15.268 zero-coverage fill batch 6
    modifier_alchemist_unstable_concoction     = "targeted_disable",  -- v6.15.268 (variable stun on hit)
    modifier_broodmother_sticky_snare          = "targeted_disable",  -- v6.15.268 (placed snare root)
    modifier_medusa_gorgon_grasp               = "targeted_disable",  -- v6.15.268 (point-AOE stun)
    modifier_medusa_mystic_snake               = "kiting_slow",       -- v6.15.268 (bouncing damage)
    modifier_troll_warlord_whirling_axes_ranged = "targeted_disable", -- v6.15.268 (multi-axe silence)
    modifier_dark_seer_vacuum                  = "targeted_disable",  -- v6.15.268 (pull AoE)
    modifier_dark_seer_ion_shell               = "kiting_slow",       -- v6.15.268 (damage aura around target)
    modifier_ember_spirit_sleight_of_fist_caster = "kiting_slow",     -- v6.15.268 (caster phase marker)
    -- v6.15.269 zero-coverage fill batch 7
    modifier_bounty_hunter_shuriken_toss       = "kiting_slow",       -- v6.15.269 (slow + damage)
    modifier_brewmaster_cinder_brew            = "kiting_slow",       -- v6.15.269 (slow + dot AoE)
    modifier_phoenix_sun_ray                   = "kiting_slow",       -- v6.15.269 (line beam DoT)
    modifier_shredder_chakram                  = "kiting_slow",       -- v6.15.269 (line slow + disarm)
    modifier_arc_warden_flux                   = "kiting_slow",       -- v6.15.269 (isolated-target debuff)
    -- v6.15.270 final mop-up
    modifier_chen_penitence                    = "kiting_slow",       -- v6.15.270 (slow + dmg amp)
    modifier_omniknight_hammer_of_purity       = "kiting_slow",       -- v6.15.270 (autocast nuke)
    modifier_largo_catchy_lick                 = "kiting_slow",       -- v6.15.270 (Largo lick debuff)
    -- v6.15.271 ranked-match harvest
    modifier_tusk_snowball_target              = "targeted_disable",  -- v6.15.271 (root + delivery debuff)
    modifier_tusk_walrus_punch_air_time        = "targeted_disable",  -- v6.15.271 (knockup stun)
    modifier_tusk_walrus_punch_slow            = "kiting_slow",       -- v6.15.271 (post-punch slow)
    modifier_tusk_tag_team_attack_slow         = "kiting_slow",       -- v6.15.271 (passive proc slow)
    modifier_tusk_tag_team_slow                = "kiting_slow",       -- v6.15.271 (paired-attack slow)
    modifier_tiny_avalanche_stun               = "targeted_disable",  -- v6.15.271 (POINT-AOE stun)
    modifier_skywrath_mage_concussive_shot_slow = "kiting_slow",      -- v6.15.271 (slow proc)
    modifier_keeper_of_the_light_blinding_light = "targeted_disable", -- v6.15.271 (miss chance)
    modifier_blinding_light_knockback          = "line_projectile",   -- v6.15.271 (knockback marker)
    modifier_keeper_of_the_light_will_o_wisp   = "delayed_aoe",       -- v6.15.271 (delayed AoE stun ult)
    modifier_keeper_of_the_light_radiant_bind  = "targeted_disable",  -- v6.15.271 (anti-ranged disable, critical for Sniper)
    modifier_legion_commander_intimidate_slow  = "kiting_slow",       -- v6.15.271 (newer LC ability slow)
    -- v6.15.272 second-match harvest
    modifier_faceless_void_timelock_freeze     = "kiting_slow",       -- v6.15.272 (passive mini-stun proc)
    modifier_faceless_void_time_dilation_distortion = "kiting_slow",  -- v6.15.272 (slow + CD stall)
    modifier_largo_frogstomp_debuff            = "targeted_disable",  -- v6.15.272 (stomp stun)
    modifier_largo_croak_of_genius_debuff      = "kiting_slow",       -- v6.15.272
    modifier_largo_catchy_lick_knockback       = "line_projectile",   -- v6.15.272 (knockback marker)
    modifier_razor_plasma_field_slow           = "kiting_slow",       -- v6.15.272
    modifier_razor_storm_surge_slow            = "kiting_slow",       -- v6.15.272
    modifier_razor_eye_of_the_storm_armor      = "kiting_slow",       -- v6.15.272 (armor reduction)
    modifier_rubick_fade_bolt_debuff           = "kiting_slow",       -- v6.15.272
    -- v6.15.273 third-match harvest
    modifier_ancientapparition_coldfeet_freeze = "targeted_disable",  -- v6.15.273 (Cold Feet freeze phase)
    modifier_ancient_apparition_bone_chill_debuff = "kiting_slow",    -- v6.15.273 (stacking slow)
    modifier_chilling_touch_slow               = "kiting_slow",       -- v6.15.273 (attack proc slow)
    modifier_chilling_touch_super_slow         = "kiting_slow",       -- v6.15.273 (upgraded)
    modifier_ice_vortex                        = "kiting_slow",       -- v6.15.273 (AoE slow zone)
    modifier_magnataur_skewer_impact           = "targeted_disable",  -- v6.15.273 (impact stun)
    modifier_magnataur_skewer_slow             = "kiting_slow",       -- v6.15.273 (post-impact slow)
    modifier_magnataur_shockwave_pull          = "targeted_disable",  -- v6.15.273 (pull-back disable)
    modifier_snapfire_lil_shredder_debuff      = "kiting_slow",       -- v6.15.273
    modifier_snapfire_magma_burn_slow          = "kiting_slow",       -- v6.15.273
    modifier_spectre_spectral_dagger_in_path   = "kiting_slow",       -- v6.15.273 (chase marker)
    modifier_maledict                          = "kiting_slow",       -- v6.15.273 (WD Maledict mark)
    modifier_maledict_dot                      = "kiting_slow",       -- v6.15.273 (WD Maledict tick)
}

---@param threat_mod string|nil
---@return string  -- the category name, defaulting to "reactive" for unmapped
function ThreatData.CategoryOf(threat_mod)
    if not threat_mod then return "reactive" end
    return ThreatData.THREAT_CATEGORY[threat_mod] or "reactive"
end

----------------------------------------------------------------------------
-- THREAT_SEVERITY , drives CD-tier reservation logic
----------------------------------------------------------------------------

---How dangerous is this threat? Low-severity threats shouldn't burn high-CD
---saves (BKB, Aeon Disk); save those for high-severity. Values: low/medium/high.
---@type table<string, string>
ThreatData.THREAT_SEVERITY = {
    -- High: lethal disable or burst that requires a top-tier save
    modifier_bane_fiends_grip            = "high",  -- 7s lockdown + heavy damage
    modifier_bane_nightmare              = "high",  -- 7s sleep + Fiend Grip follow-up
    modifier_lion_finger_of_death        = "high",  -- 575+ magic damage
    modifier_lina_laguna_blade           = "high",
    modifier_doom_bringer_doom           = "high",  -- 12s silence
    modifier_spirit_breaker_charge_of_darkness = "high",  -- 1.7s stun + team setup
    modifier_enigma_black_hole           = "high",  -- 4s AoE channel
    modifier_legion_commander_duel       = "high",
    -- Medium: significant but recoverable
    modifier_pudge_dismember_pull             = "medium",  -- breakable channel
    modifier_lion_voodoo                 = "medium",  -- 1.5s hex
    modifier_lina_light_strike_array     = "medium",
    modifier_naga_siren_ensnare          = "medium",
    modifier_shadow_shaman_shackles      = "medium",
    modifier_tusk_snowball_movement      = "medium",
    modifier_kez_grappling_claw_slow          = "medium",  -- v6.15.162 (verify) , gap-close + 80% slow + lifesteal hit
    -- v6.15.163 batch 1 , modern hero pool
    modifier_ringmaster_impalement       = "medium",
    modifier_marci_grapple               = "high",
    modifier_muerta_dead_shot            = "medium",
    modifier_primal_beast_onslaught      = "high",
    modifier_dawnbreaker_celestial_hammer = "medium",
    modifier_hoodwink_bushwhack          = "medium",
    modifier_snapfire_mortimer_kisses    = "high",
    modifier_void_spirit_aether_remnant  = "high",
    modifier_mars_spear                  = "high",
    modifier_grimstroke_ink_creature     = "medium",
    modifier_pangolier_swashbuckle       = "medium",
    modifier_dark_willow_cursed_crown    = "medium",
    -- v6.15.164 batch 2 , older-hero kidnaps / gap-closes / catches
    modifier_faceless_void_chronosphere_freeze  = "high",
    modifier_batrider_flaming_lasso      = "high",
    modifier_tiny_toss                   = "medium",
    modifier_vengefulspirit_nether_swap  = "high",
    modifier_chaos_knight_reality_rift   = "medium",
    modifier_rattletrap_hookshot         = "high",
    modifier_spirit_breaker_nether_strike = "high",
    modifier_huskar_life_break           = "high",
    modifier_sandking_burrowstrike       = "medium",
    modifier_nyx_assassin_impale         = "medium",
    -- batch 3-4 (defense catalog refresh, 2026-05-17)
    modifier_necrolyte_reapers_scythe               = "high",
    modifier_obsidian_destroyer_sanity_eclipse      = "high",
    modifier_lich_chain_frost                       = "high",
    modifier_skywrath_mystic_flare_aura_effect             = "high",
    modifier_mars_gods_rebuke                       = "medium",
    modifier_snapfire_scatterblast_slow                  = "medium",
    modifier_bloodseeker_rupture                    = "high",
    modifier_obsidian_destroyer_astral_imprisonment = "high",
    modifier_skywrath_mage_ancient_seal             = "medium",
    modifier_chaos_knight_chaos_bolt                = "medium",
    modifier_beastmaster_primal_roar                = "high",
    modifier_shadow_demon_disruption                = "medium",
    modifier_shadow_demon_demonic_purge             = "high",
    modifier_winter_wyvern_winters_curse            = "high",
    modifier_enigma_malefice                        = "medium",
    modifier_windrunner_shackleshot                 = "medium",
    modifier_morphling_adaptive_strike_agi          = "medium",
    modifier_puck_waning_rift                       = "medium",
    modifier_lich_sinister_gaze                     = "medium",
    modifier_primal_beast_pulverize                 = "high",
    modifier_grimstroke_soul_chain                  = "high",
    modifier_puck_dream_coil                        = "medium",
    modifier_leshrac_split_earth                    = "medium",
    modifier_jakiro_ice_path                        = "medium",
    modifier_mars_arena_of_blood                    = "high",
    modifier_sandking_epicenter                     = "high",
    modifier_templar_assassin_psionic_trap          = "medium",
    modifier_naga_siren_song_of_the_siren           = "medium",
    modifier_dark_willow_terrorize                  = "medium",
    modifier_dark_willow_bramble_maze               = "medium",
    modifier_ringmaster_the_box                     = "medium",
    modifier_ringmaster_wheel                       = "high",
    modifier_kez_raptor_dance                       = "medium",
    modifier_void_spirit_astral_step                = "medium",
    modifier_pangolier_gyroshell                    = "high",
    modifier_nyx_assassin_vendetta                  = "medium",
    modifier_witch_doctor_death_ward     = "medium",
    modifier_crystal_maiden_freezing_field = "medium",
    modifier_phantom_assassin_phantom_strike_target = "medium",
    -- Low: annoyance, save items shouldn't burn for these alone
    modifier_pudge_meat_hook             = "low",   -- can be dodged with sidestep
    modifier_slark_pounce                = "low",
    modifier_mirana_arrow                = "low",
    modifier_razor_static_link_debuff           = "low",   -- escape-by-running often viable
    modifier_lion_mana_drain             = "low",
    modifier_ursa_overpower              = "low",
    -- v6.14.1 M4: bumped to medium so the BKB-first RECOMMENDED_SAVES entry
    -- isn't reserve-penalized below the firing threshold. Berserker's Call
    -- locks a Sniper for 3s of attack-forced , BKB is the genuine answer.
    modifier_axe_berserkers_call         = "medium",
    modifier_tusk_ice_shards_thinker     = "low",
    -- v6.7 extrapolation
    modifier_zuus_thundergods_wrath      = "high",   -- global ult, can finish low-HP heroes
    modifier_tidehunter_ravage           = "high",   -- 2.5s AoE stun
    modifier_earthshaker_echo_slam       = "high",   -- AoE stun + damage scales with units in radius
    modifier_magnataur_reverse_polarity_stun  = "high",   -- 3.75s AoE stun, 1700u radius
    modifier_treant_overgrowth           = "high",   -- 5s AoE root
    modifier_disruptor_static_storm_thinker = "medium", -- channel, can walk out
    modifier_shadow_shaman_voodoo        = "medium", -- 3-4s hex
    modifier_zuus_lightning_bolt         = "medium", -- single-target burst
    modifier_magnataur_skewer            = "medium", -- 2.25s stun + grab
    modifier_sven_storm_bolt             = "low",    -- 1.75s stun
    modifier_earth_spirit_rolling_boulder= "medium", -- line stun, hard to dodge close-range
    modifier_life_stealer_open_wounds    = "medium", -- chase enabler; depends on Naix HP
    modifier_pugna_life_drain            = "medium", -- HP drain channel
    modifier_disruptor_kinetic_field_remnant = "high", -- v6.15.10 trap usually paired with Static Storm
    modifier_abyssal_underlord_pit_of_malice_ensare = "medium", -- v6.15.256 1.5-1.8s root, recurring; less lethal than KF
    -- v6.15.258 zero-coverage fill batch 1
    modifier_dragon_knight_dragon_tail   = "medium",  -- v6.15.258 1.7-2.75s stun, recoverable
    modifier_night_stalker_void          = "medium",  -- v6.15.258 1-2.5s stun (longer at night)
    modifier_ogre_magi_fireblast         = "medium",  -- v6.15.258 1.5-2.4s stun
    modifier_rubick_telekinesis_stun          = "medium",  -- v6.15.258 lift+land ~2.5s total disable
    modifier_silencer_last_word          = "low",     -- v6.15.258 silence -- annoying but not lethal alone
    modifier_death_prophet_silence       = "low",     -- v6.15.258 silence AOE -- locks BKB but not lethal alone
    -- v6.15.263 zero-coverage fill batch 2
    modifier_cold_feet = "medium", -- v6.15.263 4s stun if not moved
    modifier_ice_blast = "high",   -- v6.15.263 executes low-HP, hard to remove
    modifier_gyrocopter_homing_missile    = "medium", -- v6.15.263 3s stun + damage if not destroyed
    modifier_kunkka_torrent_thinker       = "medium", -- v6.15.263 1.5s warning + delayed stun
    modifier_kunkka_x_marks_the_spot      = "low",    -- v6.15.263 mostly setup for combo, dispellable
    modifier_nevermore_requiem            = "high",   -- v6.15.263 high magic damage + fear
    -- v6.15.264
    modifier_earth_spirit_rolling_boulder_caster = "medium", -- v6.15.264 1.5-2s stun on hit
    -- v6.15.265
    modifier_doom_bringer_infernal_blade  = "low",    -- v6.15.265 0.4s mini-stun per autocast
    modifier_furion_sprout                = "medium", -- v6.15.265 3-5s root, dispellable
    modifier_visage_grave_chill           = "medium", -- v6.15.265 4s slow+silence
    modifier_venomancer_venomous_gale     = "low",    -- v6.15.265 slow + dot
    modifier_spectre_spectral_dagger      = "low",    -- v6.15.265 slow + chase debuff
    -- v6.15.266
    modifier_juggernaut_omni_slash        = "high",   -- v6.15.266 4s invuln + massive damage, kill threat
    modifier_phantom_lancer_spirit_lance  = "low",    -- v6.15.266 instant slow proc
    modifier_meepo_earthbind              = "medium", -- v6.15.266 2s AoE root sets up Poof gank
    modifier_monkey_king_wukongs_command_aura = "high", -- v6.15.266 cage prevents leaving + clones attack
    modifier_slardar_amplify_damage       = "low",    -- v6.15.266 armor debuff alone, setup-only
    modifier_slardar_slithereen_crush     = "medium", -- v6.15.266 AoE stun around Slardar
    modifier_bristleback_hairball_slow    = "low",    -- v6.15.266 slow + damage line, recoverable
    -- v6.15.267
    modifier_invoker_cold_snap_freeze     = "medium", -- v6.15.267 mini-stun per damage instance
    modifier_riki_smoke_screen            = "medium", -- v6.15.267 AOE silence + miss
    modifier_lone_druid_entangle_effect   = "low",    -- v6.15.267 1.5s root on bear attack proc
    modifier_undying_decay                = "low",    -- v6.15.267 temporary STR drain
    modifier_dazzle_poison_touch          = "low",    -- v6.15.267 slow + dot, dispellable
    modifier_weaver_the_swarm             = "low",    -- v6.15.267 armor reduction, dispellable
    -- v6.15.268
    modifier_alchemist_unstable_concoction = "high",  -- v6.15.268 4-5s stun at full charge, kill setup
    modifier_broodmother_sticky_snare      = "medium",-- v6.15.268 2s root, dispellable
    modifier_medusa_gorgon_grasp           = "medium",-- v6.15.268 point-AOE stun
    modifier_medusa_mystic_snake           = "low",   -- v6.15.268 bouncing damage, recoverable
    modifier_troll_warlord_whirling_axes_ranged = "medium", -- v6.15.268 silence prevents BKB
    modifier_dark_seer_vacuum              = "medium",-- v6.15.268 pull sets up combo
    modifier_dark_seer_ion_shell           = "low",   -- v6.15.268 aura damage
    modifier_ember_spirit_sleight_of_fist_caster = "low", -- v6.15.268 informational
    -- v6.15.269
    modifier_bounty_hunter_shuriken_toss   = "low",  -- v6.15.269 slow + minor damage
    modifier_brewmaster_cinder_brew        = "low",  -- v6.15.269 slow + dot, dispel removes
    modifier_phoenix_sun_ray               = "low",  -- v6.15.269 line beam DoT, Phoenix channels
    modifier_shredder_chakram              = "low",  -- v6.15.269 slow + disarm line
    modifier_arc_warden_flux               = "low",  -- v6.15.269 isolated-target debuff
    -- v6.15.270 final mop-up
    modifier_chen_penitence                = "low",  -- v6.15.270 slow + dmg amp, dispellable
    modifier_omniknight_hammer_of_purity   = "low",  -- v6.15.270 autocast nuke proc
    modifier_largo_catchy_lick             = "low",  -- v6.15.270 lick debuff
    -- v6.15.271 ranked-match harvest
    modifier_tusk_snowball_target          = "medium", -- v6.15.271 root + setup
    modifier_tusk_walrus_punch_air_time    = "high",   -- v6.15.271 long knockup, kill setup
    modifier_tusk_walrus_punch_slow        = "low",    -- v6.15.271 post-punch slow
    modifier_tusk_tag_team_attack_slow     = "low",    -- v6.15.271 passive proc
    modifier_tusk_tag_team_slow            = "low",    -- v6.15.271
    modifier_tiny_avalanche_stun           = "medium", -- v6.15.271 1.5-1.8s stun
    modifier_skywrath_mage_concussive_shot_slow = "low",  -- v6.15.271 slow proc
    modifier_keeper_of_the_light_blinding_light = "high", -- v6.15.271 miss chance destroys Sniper right-clicks
    modifier_blinding_light_knockback      = "low",    -- v6.15.271 informational
    modifier_keeper_of_the_light_will_o_wisp = "high", -- v6.15.271 delayed AoE stun ult
    modifier_keeper_of_the_light_radiant_bind = "high", -- v6.15.271 anti-ranged disable, anti-Sniper
    modifier_legion_commander_intimidate_slow = "low", -- v6.15.271 slow proc
    -- v6.15.272 second-match harvest
    modifier_faceless_void_timelock_freeze     = "low",    -- v6.15.272 passive proc
    modifier_faceless_void_time_dilation_distortion = "medium", -- v6.15.272 CD stall + slow
    modifier_largo_frogstomp_debuff            = "medium", -- v6.15.272 stomp stun
    modifier_largo_croak_of_genius_debuff      = "low",    -- v6.15.272
    modifier_largo_catchy_lick_knockback       = "low",    -- v6.15.272
    modifier_razor_plasma_field_slow           = "low",    -- v6.15.272
    modifier_razor_storm_surge_slow            = "low",    -- v6.15.272 ms-trade
    modifier_razor_eye_of_the_storm_armor      = "low",    -- v6.15.272 armor reduction
    modifier_rubick_fade_bolt_debuff           = "low",    -- v6.15.272
    -- v6.15.273 third-match harvest
    modifier_ancientapparition_coldfeet_freeze = "medium", -- v6.15.273 freeze phase stun
    modifier_ancient_apparition_bone_chill_debuff = "low", -- v6.15.273
    modifier_chilling_touch_slow               = "low",    -- v6.15.273
    modifier_chilling_touch_super_slow         = "low",    -- v6.15.273
    modifier_ice_vortex                        = "low",    -- v6.15.273
    modifier_magnataur_skewer_impact           = "high",   -- v6.15.273 long stun, kill setup
    modifier_magnataur_skewer_slow             = "low",    -- v6.15.273
    modifier_magnataur_shockwave_pull          = "medium", -- v6.15.273
    modifier_snapfire_lil_shredder_debuff      = "low",    -- v6.15.273
    modifier_snapfire_magma_burn_slow          = "low",    -- v6.15.273
    modifier_spectre_spectral_dagger_in_path   = "low",    -- v6.15.273
    modifier_maledict                          = "medium", -- v6.15.273 setup for pickoff burst
    modifier_maledict_dot                      = "low",    -- v6.15.273
}

----------------------------------------------------------------------------
-- SAVE_COOLDOWN_TIER , reserve-the-good-stuff logic
----------------------------------------------------------------------------

---Save items by CD tier. High-tier saves (long CD, big effect) get a -score
---penalty when the threat is low-severity, so the brain reserves them for
---genuine emergencies. low/medium/high.
---@type table<string, string>
-- v6.7 (2026-05-11): cooldown tier audit against Liquipedia 7.41C.
--   Wind Waker 60s → 19s (low tier now, was medium)
--   Blade Mail 16s → 25s (medium tier now, was low)
--   item_eternal_shroud REMOVED from game in 7.41 , entry deleted.
--   Lotus Orb "limited charges" comment stale (charge system removed; 15s CD).
ThreatData.SAVE_COOLDOWN_TIER = {
    -- Existing self-protection / dispel
    item_cyclone        = "low",     -- 23s CD
    item_glimmer_cape   = "low",     -- 15s CD
    item_force_staff    = "low",     -- 19s CD
    item_hurricane_pike = "low",     -- 19s CD
    grenade_self        = "low",     -- 10s CD (Sniper grenade)
    grenade_at_caster   = "low",     -- shares grenade slot (10s CD)
    item_manta          = "medium",  -- 34s CD
    item_lotus_orb      = "medium",  -- 15s CD (no charge system in 7.41)
    item_satanic        = "medium",  -- 30s CD
    item_black_king_bar = "high",    -- 95s CD (7.41B)
    item_aeon_disk      = "high",    -- 105/125/145/165s scaling
    -- New items
    item_wind_waker     = "low",     -- 19s CD (was 60s in earlier patch)
    item_pipe_of_insight = "medium", -- 60s CD, team buff
    item_crimson_guard  = "medium",  -- 40s CD
    item_blade_mail     = "medium",  -- 25s CD, 5.5s duration, 85% reflect
    item_ghost          = "low",     -- 22s CD
    item_solar_crest    = "low",     -- 16s CD
    item_disperser      = "low",     -- 12s CD
    item_diffusal_blade = "low",     -- 12s CD
    item_blink          = "low",     -- 12s CD
    item_swift_blink    = "low",     -- 15s CD
    item_arcane_blink   = "low",     -- 12s CD
    item_overwhelming_blink = "low", -- 15s CD
    item_phase_boots    = "low",     -- 5s CD
}

----------------------------------------------------------------------------
-- Pure helpers , no side effects, no entity introspection
----------------------------------------------------------------------------

---Returns true iff `save_name`'s kinds intersect the threat's counter list.
---When `threat_mod` is nil (no filter requested) returns true.
---Unknown saves / threats also return true (allow rather than reject ,
---defensive default for not-yet-mapped cases).
---@param save_name  string   key into SAVE_KIND
---@param threat_mod string|nil  modifier name (key into THREAT_COUNTER)
---@return boolean
function ThreatData.SaveCounters(save_name, threat_mod)
    if not threat_mod then return true end
    local kinds = ThreatData.SAVE_KIND[save_name]
    local needs = ThreatData.THREAT_COUNTER[threat_mod]
    if not kinds or not needs then return true end
    for _, k in ipairs(kinds) do
        for _, n in ipairs(needs) do
            if k == n then return true end
        end
    end
    return false
end

---Returns true iff a displacement save will plausibly break the tether,
---given the current sniper-to-caster distance. Best case assumes the push
---is directly away from the caster (the chain's job is to issue the right
---direction). For non-displacement saves (push distance not registered)
---or threats without tether ranges, returns true (not constrained).
---@param save_name string         key into SAVE_KIND / SAVE_PUSH_DISTANCE
---@param threat_mod string|nil    modifier name (key into THREAT_TETHER_RANGE)
---@param distance number|nil      current dist(caster, self) in units
---@return boolean
function ThreatData.WillTetherBreak(save_name, threat_mod, distance)
    local push = ThreatData.SAVE_PUSH_DISTANCE[save_name]
    if not push or push == 0 then return true end
    local tether = ThreatData.THREAT_TETHER_RANGE[threat_mod or ""]
    if not tether then return true end
    if not distance then return true end  -- distance unknown → allow (conservative)
    return (distance + push) > tether
end

---Returns the recommended save-priority list for a threat, or nil if the
---threat has no specific recommendation (caller falls back to its default
---chain).
---@param threat_mod string|nil
---@return string[]|nil
function ThreatData.RecommendedSaves(threat_mod)
    if not threat_mod then return nil end
    return ThreatData.RECOMMENDED_SAVES[threat_mod]
end

---Returns the timing classification for a threat (`pre_cast`, `at_impact`,
---`mid_channel`, `reactive`, `prophylactic`). Default `reactive` for unmapped.
---@param threat_mod string|nil
---@return string
function ThreatData.TimingFor(threat_mod)
    if not threat_mod then return "reactive" end
    return ThreatData.THREAT_TIMING[threat_mod] or "reactive"
end

---Returns the severity classification (`low`, `medium`, `high`). Default
---`medium` for unmapped.
---@param threat_mod string|nil
---@return string
function ThreatData.SeverityOf(threat_mod)
    if not threat_mod then return "medium" end
    return ThreatData.THREAT_SEVERITY[threat_mod] or "medium"
end

---Score-penalty for firing a high-CD save against a low-severity threat.
---Returns a negative number to subtract from save score. Brain combines
---this with the kind-match bonus to pick the optimal save.
---@param save_name string
---@param threat_mod string|nil
---@return number  -- 0, -10, or -25
function ThreatData.SaveReservePenalty(save_name, threat_mod)
    local tier = ThreatData.SAVE_COOLDOWN_TIER[save_name]
    if not tier then return 0 end
    local sev = ThreatData.SeverityOf(threat_mod)
    if tier == "high" and sev == "low" then return -25 end
    if tier == "high" and sev == "medium" then return -10 end
    if tier == "medium" and sev == "low" then return -5 end
    return 0
end

----------------------------------------------------------------------------
-- v6.13 Defense F#12 , ENEMY_BUFF_THREATS
--
-- Buffs that the ENEMY casts on themselves which threaten Sniper. Distinct
-- from THREATS_ON_SELF (debuffs on Sniper). OnModifierCreate routes here
-- when `npc != self` and the modifier name matches. The brain then fires
-- a Sniper-side defensive response (typically physical-chase counters:
-- Ghost form, Blade Mail, Crimson Guard, Glimmer, displacement).
--
-- `category`: free-form tag for diagnostic logs.
-- `role`: which counter-kinds to prefer (drives RECOMMENDED_SAVES override).
-- `severity`: scales reserve penalty just like THREATS_ON_SELF entries.
--
-- Modifier names are guess-extrapolated from npc_abilities.json suffix
-- conventions; flag as `verify=true` until in-game `:FindAllModifiers()`
-- confirms (use the v6.13 `modseen` diagnostic at verbosity 3).
----------------------------------------------------------------------------
ThreatData.ENEMY_BUFF_THREATS = {
    modifier_bristleback_quill_spray_stack = {
        category = "physical_chase_buff", role = "physical_burst",
        severity = "medium", verify = true,
    },
    modifier_sven_gods_strength = {
        category = "physical_chase_buff", role = "physical_burst",
        severity = "high",   verify = true,
    },
    modifier_troll_warlord_battle_trance = {
        category = "physical_chase_buff", role = "physical_burst",
        severity = "high",   verify = true,
    },
    modifier_ursa_enrage = {
        category = "physical_chase_buff", role = "physical_burst",
        severity = "high",   verify = true,
    },
    -- Silver Edge break = passive (Headshot) disabled. Informational ,
    -- offense DPS estimate over-counts when broken; no defense action.
    modifier_item_silver_edge_debuff = {
        category = "passive_break", role = "informational",
        severity = "low",    verify = true,
    },
    -- v6.15.264: Earth Spirit Rolling Boulder. The caster-side modifier
    -- appears on ES when the boulder is rolling. Sniper-side modifier
    -- from boulder hit is generic modifier_stunned (uncatchable). The
    -- anim path doesn't fire reliably (POINT cast with 0 cast point, no
    -- AbilityCastAnimation slot). Caster-side modifier dispatch is the
    -- only reliable detector -- when ES is rolling, fire the
    -- line_projectile chain (force / pike / grenade-self) to evade
    -- regardless of whether Sniper is currently in the boulder line.
    -- Worst case is wasted CD if the boulder rolls elsewhere; the
    -- alternative is getting stunned with no save.
    modifier_earth_spirit_rolling_boulder_caster = {
        category = "line_projectile", role = "line_projectile",
        severity = "medium",
    },
    -- v6.15.270: Centaur Stampede + Lycan Howl. Team-buff ults that
    -- enable enemy team to gank Sniper (Stampede: global MS + phasing;
    -- Howl: team damage buff). Sniper response: defensive item or
    -- reposition; informational-grade since saves don't directly cancel
    -- the buff, but the brain should be on alert.
    modifier_centaur_stampede = {
        category = "team_mobility_buff", role = "informational",
        severity = "medium", verify = true,
    },
    modifier_lycan_howl = {
        category = "team_damage_buff", role = "informational",
        severity = "medium", verify = true,
    },
}

----------------------------------------------------------------------------
-- v6.13 Cross F#7 , derived ESCAPE_ITEM_NAMES
--
-- Single source of truth: a target's "escape items" are exactly the items
-- in SAVE_KIND that carry one of {invuln, dispel_basic, reflect_target,
-- magic_immune}. Previously lib/target.lua hardcoded a parallel list that
-- drifted when SAVE_KIND changed (v6.7 BKB gained dispel_basic; Diffusal/
-- Disperser carry dispel_basic but weren't in target.lua's list).
--
-- Derived at module-load time. SAVE_KIND is data , adding a new save here
-- automatically updates the escape-window detection.
----------------------------------------------------------------------------
do
    local ESCAPE_KINDS = {
        invuln = true, dispel_basic = true,
        reflect_target = true, magic_immune = true,
    }
    local names = {}
    for save_name, kinds in pairs(ThreatData.SAVE_KIND) do
        if save_name:sub(1, 5) == "item_" then
            for _, k in ipairs(kinds) do
                if ESCAPE_KINDS[k] then
                    names[#names + 1] = save_name
                    break
                end
            end
        end
    end
    ThreatData.ESCAPE_ITEM_NAMES = names
end

-- Pudge Dismember puts TWO modifiers on the victim: modifier_pudge_dismember
-- and modifier_pudge_dismember_pull (the pull component). A field test showed
-- both land, so the catalog (keyed on the harvested _pull name) must also
-- answer to the bare name. Mirror every modifier-keyed table entry onto it.
for _, t in pairs(ThreatData) do
    if type(t) == "table" and t.modifier_pudge_dismember_pull ~= nil then
        t.modifier_pudge_dismember = t.modifier_pudge_dismember_pull
    end
end

-- v0.5.35: Target-side spell-deflect modifiers. When the R target has any of
-- these active, the brain MUST refuse R (the cast reflects damage back). This
-- is OFFENSIVE-side guarding (hero-as-attacker), distinct from THREATS_ON_SELF
-- (hero-as-defender). Lotus stays out of this table - Target.HasReadyLotus is
-- engine-side and already filtered by r_target_blocked (Lina.lua:2178).
-- Add a new entry only when (a) the modifier name is VPK-verified per lesson
-- 13, and (b) the effect reflects damage back to the caster (not merely
-- absorbs or dispels - those are separate concerns).
ThreatData.SPELL_DEFLECT_MODIFIERS = {
    modifier_nyx_assassin_spiked_carapace = true,
}

----------------------------------------------------------------------------
-- v0.5.40 TIER 0 (A2): canonical-modifier-name resolution
--
-- The Dispatcher's per-threat lock domain (lib/defense.lua v0.5.40) keys on
-- the tuple (target_idx, canonical_mod, caster_idx) per v0.5.14 BL-A5/BL-B7.
-- An engine threat often ships SIBLING modifiers that name the same threat
-- instance (Bara Charge applies both modifier_spirit_breaker_charge_of_darkness
-- on the caster AND modifier_spirit_breaker_charge_of_darkness_vision /
-- _target on the victim; Tusk Snowball stamps _movement on the carrier AND
-- _target on the victim; PA Phantom Strike stamps _target on the victim while
-- the catalog keys on _target itself). Two different sibling names landing
-- within the lock window for the SAME engagement must hash to the SAME lock
-- key, or the second sibling silently bypasses the lock and double-fires.
--
-- v0.5.39 demo failure modes that motivated this:
--   (1) Bara Charge double-fire (WW via on_gap_close anim hits with the bare
--       canonical name, Pike via armed_threats_tick homing branch hits with
--       _vision). With sibling-collapse both route through the same
--       (target_idx, modifier_spirit_breaker_charge_of_darkness, caster_idx)
--       lock; the second arm sees dispatcher_lock_skip.
--   (2) Sniper Assassinate second-save: the lotus_pending:* slot and the
--       castpt:* slot in armed_threats_tick reference the same engagement; if
--       a sibling spelling ever leaked the locks would diverge.
--
-- Canonical names match the existing CATALOG KEYS (LINA_SAVE_OVERRIDES,
-- CAST_POINT_THREATS, THREATS_ON_SELF, RECOMMENDED_SAVES). Aliases are the
-- sibling modifiers that should fold INTO the catalog key for lock-domain
-- purposes. The catalog keys themselves are identity entries (covered by the
-- nil-fallback in CanonicalMod -- no need to enumerate them).
--
-- Source-of-truth markers in comments:
--   vpk     -- confirmed via grep against pak01_*.vpk
--   audit   -- LINA_DEFER_TO_ARMED (Lina.lua L728-741) or other in-tree usage
--   manual  -- known-pair from threat catalog ownership, no separate VPK hit
----------------------------------------------------------------------------

---@type table<string, string>
ThreatData.CANONICAL_MOD_ALIASES = {
    -- Spirit Breaker Charge of Darkness. Canonical = the bare name (matches
    -- LINA_SAVE_OVERRIDES key and ABILITY_TO_THREAT value).
    -- vpk: pak01_009 ships modifier_spirit_breaker_charge_of_darkness,
    --      _debuff, _target as engine-visible names.
    -- audit: Lina.lua LINA_DEFER_TO_ARMED L730 maps _vision -> "bara_charge",
    --        confirming _vision is a real victim-side sibling the brain sees.
    modifier_spirit_breaker_charge_of_darkness_vision = "modifier_spirit_breaker_charge_of_darkness",  -- audit
    modifier_spirit_breaker_charge_of_darkness_target = "modifier_spirit_breaker_charge_of_darkness",  -- vpk
    modifier_spirit_breaker_charge_of_darkness_debuff = "modifier_spirit_breaker_charge_of_darkness",  -- vpk

    -- Tusk Snowball. Canonical = _movement (LINA_SAVE_OVERRIDES key,
    -- ABILITY_TO_THREAT value, RECOMMENDED_SAVES key). _target is the
    -- victim-side root-on-impact debuff; _movement_friendly is the carried-ally
    -- variant (Lina-as-ally; lock-domain irrelevant but folded for safety).
    -- audit: Lina.lua LINA_DEFER_TO_ARMED L729 maps _target -> "tusk_snowball".
    -- vpk: pak01_009 ships _movement_friendly. Canonical _movement itself is
    -- field-validated (THREATS_ON_SELF, ABILITY_TO_THREAT) rather than direct
    -- VPK-grep-validated; engine-vs-VPK distinction documented per verifier.
    modifier_tusk_snowball_target              = "modifier_tusk_snowball_movement",  -- audit
    modifier_tusk_snowball                     = "modifier_tusk_snowball_movement",  -- manual (bare-name guard)
    modifier_tusk_snowball_movement_friendly   = "modifier_tusk_snowball_movement",  -- vpk

    -- PA Phantom Strike. Canonical = _target (catalog key, anim-stamp target).
    -- audit: Lina.lua LINA_DEFER_TO_ARMED L740 maps _target -> instant_blink arm,
    -- confirming _target IS the canonical the brain reasons in.
    -- The bare modifier_phantom_assassin_phantom_strike does NOT exist as a
    -- separate engine modifier (pak01 grep returns only the aghsfort variant);
    -- entry kept as defensive guard for any future engine rename.
    modifier_phantom_assassin_phantom_strike   = "modifier_phantom_assassin_phantom_strike_target",  -- manual

    -- Pudge Dismember. Canonical = _pull (LINA_SAVE_OVERRIDES key, the pull
    -- component is what the brain saves against). The legacy bare-name folder
    -- earlier in this file (the `for _, t in pairs(ThreatData)` loop targeting
    -- modifier_pudge_dismember_pull at L2144) handles catalog mirroring; here
    -- we collapse the lock-domain side too.
    -- vpk: pak01 ships modifier_pudge_dismember (bare) and _pull.
    modifier_pudge_dismember                   = "modifier_pudge_dismember_pull",    -- vpk

    -- Bane Fiends Grip. Canonical = bare. VPK sweep (pak01_009) finds the
    -- bare canonical; no _cast_illusion sibling reproducible in the current
    -- build. No fold today; add here with a 'manual' marker if the engine
    -- grows an illusion-side stamp.

    -- Legion Commander Duel. Canonical = bare. _damage_boost is the post-duel
    -- winner stamp (caster-side); only present here so an accidental brain-side
    -- detector folds correctly.
    -- vpk: pak01_009 ships _damage_boost.
    modifier_legion_commander_duel_damage_boost = "modifier_legion_commander_duel",  -- vpk

    -- Earthshaker Fissure (modifier_earthshaker_fissure_stun +
    -- modifier_fissure_rooted, both ship in pak01_009): NOT a Lina-defended
    -- threat today (no THREATS_ON_SELF entry, no RECOMMENDED_SAVES chain).
    -- An alias-only pairing would strand the lock_key; catalog the canonical
    -- first, then re-add the _rooted alias here.

    -- Magnataur Skewer. Canonical = _impact (the impact stun). _slow is the
    -- separate post-impact slow that the brain treats independently in
    -- RECOMMENDED_SAVES; we do NOT alias _slow -> _impact (different threats,
    -- different save preferences). Documenting the deliberate omission here so
    -- a future contributor doesn't fold them by mistake.
    -- (no entry: _impact and _slow are siblings of the SAME ability but distinct
    -- threats in the catalog; the dispatcher's caster_idx in the lock tuple is
    -- enough to keep them from racing.)

    -- Lion Finger of Death. Canonical = bare (CAST_POINT_THREATS key).
    -- vpk: pak01_009 ships _delay and _kill_counter siblings.
    modifier_lion_finger_of_death_delay        = "modifier_lion_finger_of_death",    -- vpk
    modifier_lion_finger_of_death_kill_counter = "modifier_lion_finger_of_death",    -- vpk

    -- Tinker Laser. Canonical = bare (CAST_POINT_THREATS key). _blind is the
    -- miss-chance debuff sibling.
    -- vpk: pak01_009 ships _blind.
    modifier_tinker_laser_blind                = "modifier_tinker_laser",            -- vpk

    -- OD Sanity Eclipse. Canonical = bare (CAST_POINT_THREATS key).
    -- vpk: pak01_009 ships _charge (caster-side mana-charge stack).
    modifier_obsidian_destroyer_sanity_eclipse_charge = "modifier_obsidian_destroyer_sanity_eclipse",  -- vpk

    -- Doom. Canonical = modifier_doom_bringer_doom (CAST_POINT_THREATS key).
    -- VPK sweep (pak01_009) found only the bare canonical; no _aura_enemy /
    -- _aura_self siblings reproducible in the current build. No fold today;
    -- add here with a 'manual' marker if a future engine version introduces
    -- a victim-side aura modifier the brain detects.

    -- Disruptor Static Storm. Canonical = _thinker (the channel-on-thinker
    -- mod; THREATS_ON_SELF + ENEMY_CHANNEL_MODIFIERS key). The bare name lives
    -- on the victim during the channel; fold so a victim-side detector also
    -- routes to the thinker-keyed lock.
    -- audit: lib/threat_data.lua ENEMY_CHANNEL_MODIFIERS keys on _thinker; the
    --        bare name is a real engine sibling per pak01_009 grep.
    modifier_disruptor_static_storm            = "modifier_disruptor_static_storm_thinker",  -- vpk
}

----------------------------------------------------------------------------
-- ThreatData.CanonicalMod(mod_name) -- alias-fold a modifier name to its
-- canonical lock-domain key.
--
-- Signature:
--   (mod_name: string|nil) -> string|nil
--
-- Semantics:
--   - nil / empty / non-string -> nil (caller must treat as "unresolvable";
--     defense.lua falls through to the v0.5.39 unlocked path on nil).
--   - alias in CANONICAL_MOD_ALIASES -> the canonical string.
--   - everything else -> identity (already canonical OR uncatalogued; the
--     dispatcher will tlog 'eta_resolver_fallback' on uncatalogued mods so
--     they get added to CANONICAL_MOD_ALIASES on the next iteration).
--
-- Pure: no side-effects, table lookups only.
--
-- Caller contract (lib/defense.lua Dispatcher:_LockKey):
--   local canon = c.TD.CanonicalMod(threat_mod)
--   if not canon then return nil end   -- unlocked path
--   return string.format('%d:%s:%d', target_idx, canon, caster_idx)
----------------------------------------------------------------------------
function ThreatData.CanonicalMod(mod_name)
    if type(mod_name) ~= "string" or mod_name == "" then
        return nil
    end
    local canon = ThreatData.CANONICAL_MOD_ALIASES[mod_name]
    if canon then
        return canon
    end
    return mod_name
end

-- Exported alias under the longer name used in the audit doc. Both names
-- resolve to the same function so Lina.lua / lib/defense.lua can pick whichever
-- reads better at call site without an extra indirection.
ThreatData.CanonicalizeThreatMod = ThreatData.CanonicalMod
-- Third alias under the bare 'Canonicalize' spelling: zero-cost defensive
-- shim so any future doc / call site that references the shorter name finds
-- the same closure (v0.5.40 verifier optional finding).
ThreatData.Canonicalize          = ThreatData.CanonicalMod

----------------------------------------------------------------------------
-- ThreatData.AbilityToCanonical(ability_name) -- compose ABILITY_TO_THREAT
-- with CanonicalMod. Used by lib/defense.lua when the anim-path fires before
-- any modifier is on the victim (line projectiles: hook, arrow, storm bolt)
-- and the lock_key must be derived from the ability name alone.
--
-- Signature:
--   (ability_name: string|nil) -> string|nil
--
-- Returns the canonical modifier name the ability stamps, or nil if the
-- ability is unmapped / its threat_modifier is nil (mobility-only abilities
-- like queenofpain_blink that map to nil in ABILITY_TO_THREAT).
----------------------------------------------------------------------------
function ThreatData.AbilityToCanonical(ability_name)
    if type(ability_name) ~= "string" or ability_name == "" then
        return nil
    end
    local mod = ThreatData.ABILITY_TO_THREAT[ability_name]
    if not mod then
        return nil
    end
    return ThreatData.CanonicalMod(mod)
end

return ThreatData
