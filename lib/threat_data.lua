---@meta
---lib/threat_data.lua - universal threat / save classification data.
---
---Data-only Tier 2 extraction. The tables and pure helpers in this module
---don't change per hero - Pike's push distance is 425u for everyone, Bane
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
---  - Ability-name -> threat-modifier map    (ABILITY_TO_THREAT)
---  - SaveCounters() predicate              (pure set intersection)
---  - WillTetherBreak() predicate           (pure geometry)
---
---**Does NOT own (stays per-hero):**
---  - Save chain execution order
---  - Hero-specific save abilities (your hero's grenade-self, etc.)
---  - The save-chain executor and armed-threat tracking - that is behaviour,
---    and it belongs in your brain (or a future `lib/defense.lua`), not in a
---    data module.
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

-- item_data.lua's generated SAVE_GEOMETRY table is the single source of
-- truth for save-item push / blink distances. sg() pulls a numeric field
-- from it with a patch-stable literal fallback. item_data is a pure data
-- module that requires nothing back, so there is no cycle and no load-order
-- risk.
local ItemData = require("lib.item_data")
local function sg(name, field, fallback)
    local g = ItemData.SAVE_GEOMETRY and ItemData.SAVE_GEOMETRY[name]
    local v = g and g[field]
    return (type(v) == "number" and v) or fallback
end

----------------------------------------------------------------------------
-- SAVE_KIND - every save item / ability classified by what it does
----------------------------------------------------------------------------

---Save-effect categories. A save is "effective" against a threat iff any of
---its kinds appears in the threat's counter list.
---
---Kind meanings:
---  invuln                   - caster goes invuln (Eul cyclone, Aeon trigger,
---                             Wind Waker cyclone)
---  dispel_basic             - applies basic dispel (Eul exit, Manta split,
---                             Satanic active, Diffusal/Disperser purge)
---  magic_immune             - magic immunity (BKB)
---  magic_barrier            - absorbs magic damage via barrier (Eternal
---                             Shroud, Pipe of Insight)
---  magic_resist             - passive flat magic resist buff (Glimmer)
---  reflect_target           - Lotus Orb reflects single-target enemy casts
---  invis                    - invisibility breaks attack target-lock
---                             (Glimmer, Silver Edge wind-walk, Solar Crest)
---  damage_block             - flat physical damage reduction (Crimson
---                             Guard active barrier)
---  damage_return            - reflects physical damage back (Blade Mail)
---  physical_immune          - immune to physical attacks (Ghost active)
---  displacement_perp        - perpendicular 400-500u (Pike, Force,
---                             Grenade-self) - works vs LINE projectiles +
---                             DELAYED-AOE
---  displacement_far         - 500u+ displacement (Pike, Force) - works vs
---                             TETHER channels that break at range
---  displacement_blink       - instant 1200u teleport (Blink Dagger and
---                             variants) - breaks any tether
---  displacement_at_source   - knocks the THREAT CASTER off their position
---                             (grenade-at-caster) - breaks Bara Charge,
---                             Tusk Snowball via forced movement
---  channel_break            - interrupts enemy channel via ROOT_DISABLES
---                             (grenade-at-caster, hex, stun on caster)
---  phase                    - phase movement, walks through units
---                             (Phase Boots active) - minor save
---@type table<string, string[]>
ThreatData.SAVE_KIND = {
    -- Self-protection items
    item_cyclone            = { "invuln", "dispel_basic" },     -- 2.5s cyclone
    item_wind_waker         = { "invuln", "dispel_basic" },     -- 3.5s cyclone, dispel on exit, can act during cyclone
    -- Aeon Disk applies STRONG dispel on trigger (Liquipedia 7.41).
    -- Strong dispel supersets basic dispel - can counter Nightmare, Doom,
    -- Ensnare even after they land.
    item_aeon_disk          = { "invuln", "dispel_basic" },     -- auto-trigger 1.5s invuln + strong dispel at <=80% HP
    item_lotus_orb          = { "reflect_target" },
    item_glimmer_cape       = { "invis", "magic_resist" },
    item_solar_crest        = { "invis", "magic_resist" },      -- self-cast: 6s invis + armor buff
    -- BKB now applies basic dispel on cast (7.41 change
    -- per Liquipedia). Useful against Naga Ensnare and other dispel-only
    -- counterable threats.
    item_black_king_bar     = { "magic_immune", "dispel_basic" },
    -- item_eternal_shroud was REMOVED in 7.41 - entry deleted.
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
    -- your hero hero-specific (registered here so the kind-intersection filter
    -- works; hero file owns the fire closures via its SAVE_FIRE table).
    grenade_self            = { "displacement_perp" },          -- 475u radial from cast point
    grenade_at_caster       = { "channel_break", "displacement_at_source" },
}

----------------------------------------------------------------------------
-- THREAT_COUNTER - which kinds actually counter each threat
----------------------------------------------------------------------------

---Threat modifier -> list of save-kind names that effectively counter it.
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
    -- the cheapest counter when the caster is in 600u - preferred over self-
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
    -- their path) actually CANCELS Bara Charge / Tusk Snowball - forced
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
    -- Kez Grappling Claw - Kez swings to a unit-target, 80%
    -- MS-slows them on hook collision, then lands a lifesteal hit. Gap-close
    -- profile; unlike Tusk's snowball Kez is NOT displacement-immune, so
    -- pushing the caster (or self) is viable. (verify modifier name -
    -- modseen harvest; modifier_kez_grappling_claw is the best guess.)
    modifier_kez_grappling_claw          = {
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
    -- dropped `invuln` - cyclone does NOT break a flying hook;
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
    modifier_razor_static_link           = {
        "invuln", "displacement_far", "displacement_blink", "dispel_basic",
    },  -- pierces BKB
    modifier_lion_mana_drain             = {
        "invuln", "displacement_far", "displacement_perp", "displacement_blink",
        "dispel_basic",
    },
    -- Lockdown - Blade Mail returns damage during forced attacks
    modifier_legion_commander_duel       = { "invuln", "dispel_basic", "damage_return" },
    -- Misc CC
    modifier_axe_berserkers_call         = { "magic_immune", "damage_return" },  -- BKB or Blade Mail (forced attacks return damage)
    -- entries (modifier names marked (verify) need in-game check)
    modifier_shadow_shaman_voodoo        = { "invuln", "magic_immune", "reflect_target", "dispel_basic" },
    modifier_zuus_lightning_bolt         = { "invuln", "magic_immune", "magic_barrier", "reflect_target" },
    modifier_zuus_thundergods_wrath      = { "invuln", "magic_immune", "magic_barrier" },  -- global AoE; no reflect (not single-target)
    modifier_tidehunter_ravage           = { "invuln", "magic_immune", "displacement_blink", "magic_barrier", "dispel_basic" },
    modifier_earthshaker_echo_slam       = { "invuln", "magic_immune", "displacement_far", "displacement_perp", "displacement_blink", "magic_barrier" },
    modifier_magnataur_reverse_polarity  = { "invuln", "magic_immune", "displacement_blink" },  -- 1700u radius; only blink reliably escapes
    modifier_disruptor_static_storm_thinker = { "magic_immune", "displacement_far", "displacement_perp", "displacement_blink", "magic_barrier" },
    modifier_treant_overgrowth           = { "invuln", "magic_immune", "displacement_blink", "dispel_basic" },
    modifier_magnataur_skewer            = { "invuln", "displacement_perp", "displacement_blink", "magic_immune" },
    modifier_sven_storm_bolt             = { "invuln", "displacement_perp", "displacement_blink", "magic_immune" },
    modifier_earth_spirit_rolling_boulder= { "invuln", "displacement_perp", "displacement_blink", "magic_immune" },
    modifier_life_stealer_open_wounds    = { "dispel_basic", "invis", "invuln", "physical_immune", "damage_block", "damage_return" },
    modifier_pugna_life_drain            = { "invuln", "displacement_far", "displacement_blink", "dispel_basic" },
    -- Disruptor Kinetic Field. The wall blocks forced movement
    -- (Pike, Force, Blink) entirely - only knockback motion crosses it.
    -- User-observed in 7.41C. (verify modifier name - likely
    -- modifier_disruptor_kinetic_field_remnant once empirically confirmed
    -- via modseen.)
    modifier_disruptor_kinetic_field_remnant = { "displacement_perp" },
}

----------------------------------------------------------------------------
-- SAVE_PUSH_DISTANCE - how far each displacement save moves the user
----------------------------------------------------------------------------

---Save key -> push distance in units. Non-displacement saves omitted
---(treated as 0 and not constrained by tether geometry).
---@type table<string, number>
-- Pike-on-enemy push = 425. Pike pushes radially outward from the caster -
-- both caster and enemy move apart. Pike-on-self push = 600 but direction =
-- the hero's facing. The conservative value used here is the enemy-target
-- mode (enemy_push) since that is the reliable-direction case for tether
-- breaks.
-- The item entries derive from item_data.SAVE_GEOMETRY (the generated table
-- that grounds SAVE_PUSH_DISTANCE) -- displacement items take enemy_push,
-- blink items take range. The literal in each sg() call is a patch-stable
-- fallback only. grenade_self stays literal: it is a hero ability
-- (npc_abilities KV), not an item, so SAVE_GEOMETRY has no entry for it.
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
-- THREAT_TETHER_RANGE - distance at which a tether channel breaks
----------------------------------------------------------------------------

---Threat modifier -> tether range in units. self-to-caster distance plus
---displacement push must exceed this for the displacement save to actually
---break the channel. Threats without listed ranges are unconstrained.
---@type table<string, number>
-- cross-checked against Liquipedia 7.41C.
-- Static Link 900 -> 800, Mana Drain 850 -> 1000, Death Ward 1100 -> 650.
-- Death Ward "tether" was way off - actual ward attack range is 650 at
-- level 3 (was using a fictional 1100). Old value caused over-saves where
-- the brain thought Death Ward reached farther than it does.
-- Shaman Shackles 800 is a HEURISTIC - Liquipedia documents no actual
-- distance-break for Shackles (channel only breaks via stun/silence/
-- disjoint). Kept for the displacement save's geometry score but flagged.
-- Bane Fiend Grip 875 is unverified by Liquipedia text (cast range 625;
-- typical Dota tether allows ~200 buffer). Keep 875 pending in-game verify.
ThreatData.THREAT_TETHER_RANGE = {
    modifier_bane_fiends_grip          = 875,
    modifier_pudge_dismember_pull           = 200,
    modifier_shadow_shaman_shackles    = 800,    -- HEURISTIC; no real distance-break (verify in-game)
    modifier_razor_static_link         = 800,
    modifier_lion_mana_drain           = 1000,
    modifier_witch_doctor_death_ward   = 650,    -- ward attack range at level 3
    modifier_pugna_life_drain          = 1100,   -- (verify): typical channel tether
}

----------------------------------------------------------------------------
-- THREATS_ON_SELF - modifier names hero scripts react to via OnModifierCreate
----------------------------------------------------------------------------

---Modifier -> { role, save } metadata. `role` drives the dispatch path in the
---hero script; `save` is human-readable shorthand for diagnostics. Hero scripts
---will typically also pass the modifier name through to the save chain as the
---threat-mod filter input.
---@type table<string, { role:string, save:string }>
ThreatData.THREATS_ON_SELF = {
    modifier_bane_nightmare              = { role = "hard_disable",  save = "eul_or_bkb" },
    modifier_lion_voodoo                 = { role = "hard_disable",  save = "pre_arm" },
    modifier_shadow_shaman_shackles      = { role = "channel_on_me", save = "bkb_or_grenade_source" },
    modifier_pudge_dismember_pull             = { role = "channel_on_me", save = "bkb_or_grenade_source" },
    modifier_bane_fiends_grip            = { role = "channel_on_me", save = "bkb_or_grenade_source" },
    modifier_doom_bringer_doom           = { role = "hard_disable",  save = "bkb_or_lotus" },
    modifier_razor_static_link           = { role = "drain",         save = "force_or_pike" },
    modifier_ursa_overpower              = { role = "physical_burst",save = "glimmer_or_pike" },
    modifier_legion_commander_duel       = { role = "lockdown",      save = "satanic_or_grenade_self" },
    modifier_axe_berserkers_call         = { role = "taunt",         save = "informational" },
    modifier_phantom_assassin_phantom_strike_target = { role = "gap_close", save = "glimmer_or_pike" },
    modifier_spirit_breaker_charge_of_darkness      = { role = "gap_close", save = "pike_or_grenade" },
    modifier_tusk_snowball_movement                 = { role = "gap_close", save = "pike_or_grenade" },
    modifier_kez_grappling_claw                     = { role = "gap_close", save = "pike_or_grenade" },  -- (verify) - Kez Grappling Claw
    -- modern hero pool (verify modifier names via modseen)
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
    -- older-hero kidnaps / gap-closes / catches
    modifier_faceless_void_chronosphere             = { role = "delayed_aoe",      save = "blink_or_bkb" },
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
    modifier_skywrath_mage_mystic_flare             = { role = "delayed_aoe",      save = "displacement" },
    modifier_mars_gods_rebuke                       = { role = "physical_burst",   save = "glimmer_or_ghost" },
    modifier_snapfire_scatterblast                  = { role = "magic_burst",      save = "bkb_or_displacement" },
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
    -- . Modifier names marked (verify) need
    -- in-game confirmation via :FindAllModifiers() print before relying on.
    modifier_shadow_shaman_voodoo        = { role = "hard_disable",  save = "lotus_or_eul" },           -- (verify) - Hex
    modifier_zuus_lightning_bolt         = { role = "magic_burst",   save = "bkb_or_lotus" },          -- (verify)
    modifier_zuus_thundergods_wrath      = { role = "magic_burst",   save = "bkb_or_pipe" },           -- (verify) - global ult, 2s cast point
    modifier_tidehunter_ravage           = { role = "delayed_aoe",   save = "bkb_or_blink" },          -- (verify)
    modifier_earthshaker_echo_slam       = { role = "delayed_aoe",   save = "bkb_or_blink" },          -- (verify)
    modifier_magnataur_reverse_polarity  = { role = "delayed_aoe",   save = "bkb_or_blink" },          -- (verify) - 1700u radius
    modifier_disruptor_static_storm_thinker = { role = "delayed_aoe", save = "displacement_or_bkb" },  -- (verify) - channel
    modifier_treant_overgrowth           = { role = "delayed_aoe",   save = "blink_or_manta" },        -- (verify) - AoE root
    modifier_magnataur_skewer            = { role = "line_projectile", save = "perp_displacement" },   -- (verify) - pre_cast save
    modifier_sven_storm_bolt             = { role = "line_projectile", save = "perp_displacement" },   -- (verify)
    modifier_earth_spirit_rolling_boulder= { role = "line_projectile", save = "perp_displacement" },   -- (verify)
    modifier_life_stealer_open_wounds    = { role = "physical_burst", save = "manta_or_pike" },        -- (verify) - debuff
    modifier_pugna_life_drain            = { role = "drain",         save = "force_or_pike" },         -- (verify) - channel
    -- Disruptor Kinetic Field - trapped. Only knockback escapes.
    modifier_disruptor_kinetic_field_remnant = { role = "trapped",   save = "knockback_only" },         -- (verify)
}

----------------------------------------------------------------------------
-- LOTUS_WORTHY_INCOMING - single-target enemy ults Lotus reflects
----------------------------------------------------------------------------

---@type table<string, boolean>
ThreatData.LOTUS_WORTHY_INCOMING = {
    modifier_lina_laguna_blade    = true,
    modifier_lion_finger_of_death = true,
}

----------------------------------------------------------------------------
-- ENEMY_CHANNEL_MODIFIERS - Layer 1.5 channel-punish / TP-interrupt triggers
----------------------------------------------------------------------------

---@type table<string, boolean>
ThreatData.ENEMY_CHANNEL_MODIFIERS = {
    modifier_bane_fiends_grip              = true,
    modifier_pudge_dismember_pull               = true,
    modifier_witch_doctor_death_ward       = true,
    modifier_crystal_maiden_freezing_field = true,
    modifier_enigma_black_hole             = true,
    modifier_teleporting                   = true,  -- TP-out interrupt
    -- (verify modifier names):
    modifier_disruptor_static_storm_thinker = true,
    modifier_pugna_life_drain              = true,
}

----------------------------------------------------------------------------
-- ABILITY_TO_THREAT - ability name (from anim events) -> threat modifier
----------------------------------------------------------------------------

---@type table<string, string|nil>
ThreatData.ABILITY_TO_THREAT = {
    bane_nightmare                      = "modifier_bane_nightmare",
    bane_fiends_grip                    = "modifier_bane_fiends_grip",
    bane_brain_sap                      = nil,   -- instant nuke, no incoming-side save
    pudge_dismember                     = "modifier_pudge_dismember_pull",
    pudge_meat_hook                     = "modifier_pudge_meat_hook",
    spirit_breaker_charge_of_darkness   = "modifier_spirit_breaker_charge_of_darkness",
    spirit_breaker_nether_strike        = "modifier_spirit_breaker_nether_strike",  -- (verify) - promoted from nil: blink-strike ult
    tusk_snowball                       = "modifier_tusk_snowball_movement",
    kez_grappling_claw                  = "modifier_kez_grappling_claw",       -- (verify) - Kez gap-close swing
    -- defense catalog refresh, batch 1: the modern hero pool.
    -- KV exposes no modifier names, so every modifier_<ability> below is a
    -- best-effort (verify) guess - confirm via the threat_unrecognized harvest
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
    -- batch 2: older-hero kidnaps / gap-closes / catches.
    faceless_void_chronosphere          = "modifier_faceless_void_chronosphere",
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
    -- modifier_<ability> guesses, all (verify) - corrected via threat_unrecognized.
    necrolyte_reapers_scythe            = "modifier_necrolyte_reapers_scythe",
    obsidian_destroyer_sanity_eclipse   = "modifier_obsidian_destroyer_sanity_eclipse",
    lich_chain_frost                    = "modifier_lich_chain_frost",
    skywrath_mage_mystic_flare          = "modifier_skywrath_mage_mystic_flare",
    mars_gods_rebuke                    = "modifier_mars_gods_rebuke",
    snapfire_scatterblast               = "modifier_snapfire_scatterblast",
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
    -- . Modifier names with (verify) need
    -- in-game confirmation via :FindAllModifiers() before relying on the
    -- exact suffix. Mobility-only abilities map to nil (no save target;
    -- they're informational pre-threats indicating the followup is coming).
    faceless_void_time_walk             = nil,   -- mobility only
    storm_spirit_ball_lightning         = nil,   -- mobility only
    antimage_blink                      = nil,   -- mobility only
    queenofpain_blink                   = nil,   -- mobility only
    magnataur_skewer                    = "modifier_magnataur_skewer",                 -- (verify)
    magnataur_reverse_polarity          = "modifier_magnataur_reverse_polarity",       -- (verify)
    earth_spirit_rolling_boulder        = "modifier_earth_spirit_rolling_boulder",     -- (verify)
    sven_storm_bolt                     = "modifier_sven_storm_bolt",                  -- (verify)
    shadow_shaman_voodoo                = "modifier_shadow_shaman_voodoo",             -- (verify) - Hex
    zuus_lightning_bolt                 = "modifier_zuus_lightning_bolt",              -- (verify)
    zuus_thundergods_wrath              = "modifier_zuus_thundergods_wrath",           -- (verify)
    tidehunter_ravage                   = "modifier_tidehunter_ravage",                -- (verify)
    earthshaker_echo_slam               = "modifier_earthshaker_echo_slam",            -- (verify)
    disruptor_static_storm              = "modifier_disruptor_static_storm_thinker",   -- (verify)
    treant_overgrowth                   = "modifier_treant_overgrowth",                -- (verify)
    life_stealer_open_wounds            = "modifier_life_stealer_open_wounds",         -- (verify)
    pugna_life_drain                    = "modifier_pugna_life_drain",                 -- (verify)
    disruptor_kinetic_field             = "modifier_disruptor_kinetic_field_remnant",  -- (verify) -
}

----------------------------------------------------------------------------
-- RECOMMENDED_SAVES - best-to-worst save priority per threat
--
-- The default chain order (Eul -> Lotus -> Manta -> Satanic -> Glimmer -> Pike ->
-- Force -> Grenade-self -> BKB -> Aeon) is generic. For specific threats,
-- different items are clearly better. Examples:
--
--  - **Pudge Dismember (200u tether)**: Pike or grenade-self breaks it
--    instantly. Eul (2.5s cyclone) works but locks your hero out of attacks for
--    longer than the break needs. BKB doesn't help (Dismember pierces magic
--    immunity). Recommended: Pike -> grenade-self -> Force -> Eul -> Manta.
--
--  - **Bara Charge (homing stun)**: Pike/Force/grenade-self are useless
--    (homing re-targets). BKB blocks the stun on impact. Eul invuln spans the
--    impact. Recommended: BKB -> Eul -> Lotus -> Manta.
--
--  - **Bane Nightmare (entity-targeted sleep)**: Eul (invuln cyclone fizzles
--    the cast) is best. BKB blocks during cast point. Manta dispels after.
--    Recommended: Eul -> Lotus -> Manta -> BKB.
--
-- This list lets each hero get the OPTIMAL save per threat instead of always
-- firing the first chain entry that happens to qualify. Hero scripts can
-- ADD hero-specific saves (like your hero's grenade-self) by extending the list
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
        -- Eternal Shroud removed in 7.41 - was previously listed here.
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
        "grenade_self", "item_hurricane_pike", "item_force_staff",
        "item_blink", "item_swift_blink", "item_arcane_blink", "item_overwhelming_blink",
        "item_cyclone", "item_wind_waker", "item_manta", "item_disperser",
    },
    modifier_bane_fiends_grip = {
        -- 875u tether (HEURISTIC - Liquipedia doesn't document explicit leash);
        -- Pike push 425u only breaks when Bane is >450u away.
        -- Blink ALWAYS works. Eul/Manta are most reliable dispels.
        -- BKB does NOT work (pierces).
        "item_cyclone", "item_wind_waker", "item_manta", "item_satanic",
        "item_disperser", "item_blink", "item_arcane_blink",
        "item_hurricane_pike", "item_force_staff",
    },
    modifier_shadow_shaman_shackles = {
        "item_cyclone", "item_wind_waker", "item_manta", "item_satanic",
        "item_disperser", "item_blink",
        "grenade_self", "item_hurricane_pike", "item_force_staff",
    },
    modifier_witch_doctor_death_ward = {
        -- ward attack range is 650 at level 3 (was using fictional 1100).
        -- Pike (425) / Force (600) sometimes break; Blink always breaks.
        "item_hurricane_pike", "item_force_staff", "item_blink",
        "item_black_king_bar", "item_cyclone", "item_wind_waker",
        "item_pipe_of_insight",
    },
    -- Homing charges: displacement USELESS on self (re-targets). Need
    -- invuln/immune at impact. grenade_at_caster knocks the charger and
    -- cancels the modifier - that's the cheap option for your hero.
    modifier_spirit_breaker_charge_of_darkness = {
        "item_black_king_bar", "item_cyclone", "item_wind_waker", "item_lotus_orb",
        "item_manta", "item_aeon_disk", "item_ghost",
    },
    modifier_tusk_snowball_movement = {
        "item_black_king_bar", "item_cyclone", "item_wind_waker",
        "item_manta", "item_aeon_disk",
    },
    -- Kez Grappling Claw. The 80% slow is the danger (your hero
    -- can't kite). Eul / Wind Waker fully dodge the swing-in + the landing
    -- hit; BKB blocks the slow and keeps your hero attacking; Pike / grenade
    -- push the caster off (Kez is not displacement-immune).
    modifier_kez_grappling_claw = {
        "item_cyclone", "item_wind_waker", "item_black_king_bar",
        "item_hurricane_pike", "item_force_staff", "grenade_self",
        "item_manta", "item_aeon_disk",
    },
    -- Delayed AoEs: displacement works (target the EFFECT, not the entity)
    modifier_lina_light_strike_array = {
        "item_hurricane_pike", "item_force_staff", "grenade_self", "item_blink",
        "item_cyclone", "item_wind_waker", "item_black_king_bar",
        "item_manta",
    },
    modifier_enigma_black_hole = {
        "item_black_king_bar", "item_hurricane_pike", "item_force_staff",
        "item_blink", "item_arcane_blink", "item_overwhelming_blink",
        "item_cyclone", "item_wind_waker", "item_manta",
    },
    modifier_crystal_maiden_freezing_field = {
        "item_black_king_bar", "item_hurricane_pike", "item_force_staff",
        "item_blink", "grenade_self", "item_pipe_of_insight",
    },
    -- Line projectiles: perpendicular displacement
    modifier_pudge_meat_hook = {
        "item_hurricane_pike", "item_force_staff", "grenade_self", "item_blink",
        "item_cyclone", "item_wind_waker",
    },
    -- Tusk Ice Shards - slow-moving line projectile, perp
    -- displacement / blink avoids. Mirrors hook ordering.
    modifier_tusk_ice_shards_thinker = {
        "item_hurricane_pike", "item_force_staff", "grenade_self", "item_blink",
        "item_cyclone", "item_wind_waker",
    },
    modifier_slark_pounce = {
        "item_force_staff", "item_hurricane_pike", "grenade_self", "item_blink",
        "item_cyclone", "item_wind_waker", "item_manta", "item_black_king_bar",
    },
    modifier_mirana_arrow = {
        "item_hurricane_pike", "item_force_staff", "grenade_self", "item_blink",
        "item_cyclone",
    },
    -- Physical chase: invis breaks target-lock; BKB doesn't help. Ghost makes
    -- attacks miss entirely. Blade Mail returns damage. Crimson blocks.
    modifier_phantom_assassin_phantom_strike_target = {
        "item_glimmer_cape", "item_ghost", "item_blade_mail",
        "item_hurricane_pike", "item_force_staff", "item_blink",
        "grenade_self", "item_cyclone", "item_crimson_guard", "item_solar_crest",
    },
    modifier_ursa_overpower = {
        "item_glimmer_cape", "item_ghost", "item_blade_mail",
        "item_hurricane_pike", "item_force_staff", "item_blink",
        "item_cyclone", "item_crimson_guard", "item_solar_crest",
    },
    -- Drain: pierces BKB
    modifier_razor_static_link = {
        "item_cyclone", "item_wind_waker", "item_manta",
        "item_hurricane_pike", "item_force_staff", "item_blink",
    },
    modifier_lion_mana_drain = {
        "item_cyclone", "item_wind_waker", "item_manta",
        "item_hurricane_pike", "item_force_staff", "item_blink",
        "grenade_self",
    },
    -- Lockdown - Satanic for lifesteal-tank, Blade Mail returns Duel damage
    modifier_legion_commander_duel = {
        "item_satanic", "item_blade_mail", "item_cyclone", "item_wind_waker",
        "item_manta",
    },
    -- Misc
    modifier_axe_berserkers_call = {
        "item_black_king_bar", "item_blade_mail",  -- BKB ignores taunt; Blade Mail returns forced-attack damage
    },
    -- entries
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
    modifier_magnataur_reverse_polarity = {
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
    -- Disruptor Kinetic Field. Wall blocks forced movement, blink,
    -- and cyclone displacement. Only knockback (Concussive Grenade) crosses.
    -- grenade_at_caster pushes Disruptor, not the trapped hero, so it does
    -- not free the trapped unit; only grenade_self (directional push from
    -- the trapped hero's own facing) gets the hero out of the field.
    modifier_disruptor_kinetic_field_remnant = {
        "grenade_self",
    },
    modifier_treant_overgrowth = {
        "item_black_king_bar", "item_blink", "item_swift_blink",
        "item_cyclone", "item_wind_waker", "item_manta",
        "item_aeon_disk",
    },
    modifier_magnataur_skewer = {
        "item_hurricane_pike", "item_force_staff", "grenade_self",
        "item_blink", "item_black_king_bar", "item_cyclone",
    },
    modifier_sven_storm_bolt = {
        "item_hurricane_pike", "item_force_staff", "grenade_self",
        "item_blink", "item_cyclone",
    },
    modifier_earth_spirit_rolling_boulder = {
        "item_hurricane_pike", "item_force_staff", "grenade_self",
        "item_blink", "item_cyclone",
    },
    modifier_life_stealer_open_wounds = {
        "item_glimmer_cape", "item_ghost", "item_blade_mail", "item_manta",
        "item_hurricane_pike", "item_force_staff", "item_satanic",
        "item_crimson_guard",
    },
    modifier_pugna_life_drain = {
        "item_cyclone", "item_wind_waker", "item_manta", "item_blink",
        "item_hurricane_pike", "item_force_staff", "grenade_self",
    },
}

----------------------------------------------------------------------------
-- THREAT_TIMING - when to fire the save relative to the threat
----------------------------------------------------------------------------

---When the hero should fire its save. Values:
---  `pre_cast`     - fire during the cast point window, BEFORE modifier lands
---                   (target invuln/immune at impact = cast fizzles)
---  `at_impact`    - fire just before threat impact (homing charges; the
---                   armed-ETA system handles this in the brain)
---  `mid_channel`  - fire any time during the channel (Dismember tick by tick)
---  `reactive`     - fire after modifier lands; the save dispels or escapes
---  `prophylactic` - pre-arm before threat manifests (rare; Doom is unfixable
---                   post-cast, so saves are pre-cast or none)
---
---These describe WHEN to fire. See THREAT_CATEGORY below for WHAT KIND of
---response is best (anti-close-gap vs threat-stopper vs etc.). Timing and
---category are independent axes - a `close_gap` threat is dispatched via
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
    modifier_kez_grappling_claw          = "at_impact",  -- (verify) - fire as Kez swings in
    -- modern hero pool
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
    -- older-hero kidnaps / gap-closes / catches
    modifier_faceless_void_chronosphere  = "pre_cast",
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
    modifier_skywrath_mage_mystic_flare             = "pre_cast",
    modifier_mars_gods_rebuke                       = "pre_cast",
    modifier_snapfire_scatterblast                  = "pre_cast",
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
    modifier_razor_static_link           = "reactive",
    modifier_lion_mana_drain             = "reactive",
    modifier_phantom_assassin_phantom_strike_target = "reactive",  -- already blinked
    modifier_ursa_overpower              = "reactive",
    modifier_legion_commander_duel       = "reactive",
    modifier_tusk_ice_shards_thinker     = "pre_cast",

    modifier_shadow_shaman_voodoo        = "pre_cast",
    modifier_zuus_lightning_bolt         = "pre_cast",
    modifier_zuus_thundergods_wrath      = "pre_cast",  -- 2s cast point - plenty of time
    modifier_tidehunter_ravage           = "pre_cast",
    modifier_earthshaker_echo_slam       = "pre_cast",
    modifier_magnataur_reverse_polarity  = "pre_cast",
    modifier_disruptor_static_storm_thinker = "mid_channel",
    modifier_treant_overgrowth           = "pre_cast",
    modifier_magnataur_skewer            = "pre_cast",  -- save fires during Magnus's cast point; once grabbed, perp is useless
    modifier_sven_storm_bolt             = "at_impact",
    modifier_earth_spirit_rolling_boulder = "at_impact",
    modifier_life_stealer_open_wounds    = "reactive",
    modifier_pugna_life_drain            = "reactive",
    modifier_disruptor_kinetic_field_remnant = "reactive",  -- fires once trapped
}

----------------------------------------------------------------------------
-- THREAT_CATEGORY - semantic classification of what KIND of response wins
--
-- This is the "anti-close-gap vs threat-stopper" axis the user asked about,
-- broken out as data so the brain logs it and per-hero overrides can tune
-- by category. The flat RECOMMENDED_SAVES list still drives selection - but
-- the category tells us at a glance what RESPONSE PROFILE matters:
--
--  `close_gap`         - homing approach (Bara Charge, Tusk Snowball).
--                        Best response: cancel-on-caster (grenade-at-caster,
--                        Pike-on-Bara forced movement). Save fires during
--                        approach via armed_threats_tick.
--  `channel_on_self`   - enemy channels on your hero (Dismember, Fiend Grip,
--                        Shackles, Death Ward). Best response: break channel
--                        (grenade-at-caster ROOT_DISABLES) OR self-dispel
--                        (Manta, Eul). Fires pre-cast via anim or reactive
--                        via OnModifierCreate.
--  `targeted_disable`  - pre-cast hard CC (Nightmare, Hex, Ensnare, Doom).
--                        Best response: invuln/immune during cast point so
--                        the cast fizzles or the modifier never lands.
--  `targeted_burst`    - high-damage targeted ult (Finger, Laguna). Best
--                        response: invuln / magic_barrier / reflect to
--                        absorb or bounce.
--  `delayed_aoe`       - AoE landing after a delay (LSA, Black Hole,
--                        Freezing Field). Best response: displacement
--                        (Pike, Force, Blink, grenade-self) - get out.
--  `line_projectile`   - dodgeable line shot (Hook, Pounce, Ice Shards,
--                        Arrow). Best response: perpendicular displacement.
--  `physical_chase`    - sustained physical pressure (PA Strike, Ursa
--                        Overpower). Best response: invis breaks target-
--                        lock, Ghost/Crimson/Blade Mail reduce/return.
--  `drain`             - resource/HP drain channels (Static Link, Mana
--                        Drain). Best response: dispel or move out of
--                        tether range.
--  `lockdown`          - forced attack-only or taunt (Duel, Berserker's
--                        Call). Best response: Satanic lifesteal-through
--                        or Blade Mail return-damage.
--
-- For the user's "separate section" question: this categorization PROVIDES
-- the separation in data without splitting code paths. Each save-issue site
-- (armed_threats_tick / anim_channel_start / OnModifierCreate / etc.) still
-- goes through `try_save_self` - the per-threat overrides in each hero's
-- SAVE_OVERRIDES table express the category-appropriate preferences.
----------------------------------------------------------------------------

---@type table<string, string>
ThreatData.THREAT_CATEGORY = {
    -- Close-gap (homing)
    modifier_spirit_breaker_charge_of_darkness = "close_gap",
    modifier_tusk_snowball_movement            = "close_gap",
    modifier_kez_grappling_claw                = "close_gap",       -- (verify) - Kez Grappling Claw
    -- modern hero pool
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
    -- older-hero kidnaps / gap-closes / catches
    modifier_faceless_void_chronosphere        = "delayed_aoe",
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
    modifier_skywrath_mage_mystic_flare             = "delayed_aoe",
    modifier_mars_gods_rebuke                       = "targeted_burst",
    modifier_snapfire_scatterblast                  = "targeted_burst",
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
    modifier_razor_static_link                 = "drain",
    modifier_lion_mana_drain                   = "drain",
    -- Lockdown
    modifier_legion_commander_duel             = "lockdown",
    modifier_axe_berserkers_call               = "lockdown",

    modifier_shadow_shaman_voodoo              = "targeted_disable",
    modifier_zuus_lightning_bolt               = "targeted_burst",
    modifier_zuus_thundergods_wrath            = "targeted_burst",
    modifier_tidehunter_ravage                 = "delayed_aoe",
    modifier_earthshaker_echo_slam             = "delayed_aoe",
    modifier_magnataur_reverse_polarity        = "delayed_aoe",
    modifier_disruptor_static_storm_thinker    = "delayed_aoe",
    modifier_treant_overgrowth                 = "delayed_aoe",
    modifier_magnataur_skewer                  = "line_projectile",
    modifier_sven_storm_bolt                   = "line_projectile",
    modifier_earth_spirit_rolling_boulder      = "line_projectile",
    modifier_life_stealer_open_wounds          = "physical_chase",
    modifier_pugna_life_drain                  = "drain",
    modifier_disruptor_kinetic_field_remnant   = "trap",
}

---@param threat_mod string|nil
---@return string  -- the category name, defaulting to "reactive" for unmapped
function ThreatData.CategoryOf(threat_mod)
    if not threat_mod then return "reactive" end
    return ThreatData.THREAT_CATEGORY[threat_mod] or "reactive"
end

----------------------------------------------------------------------------
-- THREAT_SEVERITY - drives CD-tier reservation logic
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
    modifier_kez_grappling_claw          = "medium",  -- (verify) - gap-close + 80% slow + lifesteal hit
    -- modern hero pool
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
    -- older-hero kidnaps / gap-closes / catches
    modifier_faceless_void_chronosphere  = "high",
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
    modifier_skywrath_mage_mystic_flare             = "high",
    modifier_mars_gods_rebuke                       = "medium",
    modifier_snapfire_scatterblast                  = "medium",
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
    modifier_razor_static_link           = "low",   -- escape-by-running often viable
    modifier_lion_mana_drain             = "low",
    modifier_ursa_overpower              = "low",
    -- bumped to medium so the BKB-first RECOMMENDED_SAVES entry
    -- isn't reserve-penalized below the firing threshold. Berserker's Call
    -- locks a your hero for 3s of attack-forced - BKB is the genuine answer.
    modifier_axe_berserkers_call         = "medium",
    modifier_tusk_ice_shards_thinker     = "low",

    modifier_zuus_thundergods_wrath      = "high",   -- global ult, can finish low-HP heroes
    modifier_tidehunter_ravage           = "high",   -- 2.5s AoE stun
    modifier_earthshaker_echo_slam       = "high",   -- AoE stun + damage scales with units in radius
    modifier_magnataur_reverse_polarity  = "high",   -- 3.75s AoE stun, 1700u radius
    modifier_treant_overgrowth           = "high",   -- 5s AoE root
    modifier_disruptor_static_storm_thinker = "medium", -- channel, can walk out
    modifier_shadow_shaman_voodoo        = "medium", -- 3-4s hex
    modifier_zuus_lightning_bolt         = "medium", -- single-target burst
    modifier_magnataur_skewer            = "medium", -- 2.25s stun + grab
    modifier_sven_storm_bolt             = "low",    -- 1.75s stun
    modifier_earth_spirit_rolling_boulder= "medium", -- line stun, hard to dodge close-range
    modifier_life_stealer_open_wounds    = "medium", -- chase enabler; depends on Naix HP
    modifier_pugna_life_drain            = "medium", -- HP drain channel
    modifier_disruptor_kinetic_field_remnant = "high", -- trap usually paired with Static Storm
}

----------------------------------------------------------------------------
-- SAVE_COOLDOWN_TIER - reserve-the-good-stuff logic
----------------------------------------------------------------------------

---Save items by CD tier. High-tier saves (long CD, big effect) get a -score
---penalty when the threat is low-severity, so the brain reserves them for
---genuine emergencies. low/medium/high.
---@type table<string, string>
-- cooldown tier audit against Liquipedia 7.41C.
--   Wind Waker 60s -> 19s (low tier now, was medium)
--   Blade Mail 16s -> 25s (medium tier now, was low)
--   item_eternal_shroud REMOVED from game in 7.41 - entry deleted.
--   Lotus Orb "limited charges" comment stale (charge system removed; 15s CD).
ThreatData.SAVE_COOLDOWN_TIER = {
    -- Existing self-protection / dispel
    item_cyclone        = "low",     -- 23s CD
    item_glimmer_cape   = "low",     -- 15s CD
    item_force_staff    = "low",     -- 19s CD
    item_hurricane_pike = "low",     -- 19s CD
    grenade_self        = "low",     -- 10s CD (your hero grenade)
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
-- Pure helpers - no side effects, no entity introspection
----------------------------------------------------------------------------

---Returns true iff `save_name`'s kinds intersect the threat's counter list.
---When `threat_mod` is nil (no filter requested) returns true.
---Unknown saves / threats also return true (allow rather than reject -
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
    if not distance then return true end  -- distance unknown -> allow (conservative)
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
-- ENEMY_BUFF_THREATS
--
-- Buffs that the ENEMY casts on themselves which threaten your hero. Distinct
-- from THREATS_ON_SELF (debuffs on your hero). OnModifierCreate routes here
-- when `npc != self` and the modifier name matches. The brain then fires
-- a hero-side defensive response (typically physical-chase counters:
-- Ghost form, Blade Mail, Crimson Guard, Glimmer, displacement).
--
-- `category`: free-form tag for diagnostic logs.
-- `role`: which counter-kinds to prefer (drives RECOMMENDED_SAVES override).
-- `severity`: scales reserve penalty just like THREATS_ON_SELF entries.
--
-- Modifier names are guess-extrapolated from npc_abilities.json suffix
-- conventions; flag as `verify=true` until in-game `:FindAllModifiers()`
-- confirms (use the `modseen` diagnostic at verbosity 3).
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
    -- Silver Edge break = passive (Headshot) disabled. Informational -
    -- offense DPS estimate over-counts when broken; no defense action.
    modifier_item_silver_edge_debuff = {
        category = "passive_break", role = "informational",
        severity = "low",    verify = true,
    },
}

----------------------------------------------------------------------------
-- derived ESCAPE_ITEM_NAMES
--
-- Single source of truth: a target's "escape items" are exactly the items
-- in SAVE_KIND that carry one of {invuln, dispel_basic, reflect_target,
-- magic_immune}. Previously lib/target.lua hardcoded a parallel list that
-- drifted when SAVE_KIND changed (BKB gained dispel_basic; Diffusal/
-- Disperser carry dispel_basic but weren't in target.lua's list).
--
-- Derived at module-load time. SAVE_KIND is data - adding a new save here
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
-- and modifier_pudge_dismember_pull (the pull component). Both land, so the
-- catalog (keyed on the _pull name) must also answer to the bare name.
-- Mirror every modifier-keyed table entry onto it.
for _, t in pairs(ThreatData) do
    if type(t) == "table" and t.modifier_pudge_dismember_pull ~= nil then
        t.modifier_pudge_dismember = t.modifier_pudge_dismember_pull
    end
end

return ThreatData
