# threat_data

A catalogue of dangerous enemy abilities and what beats them. Pure data plus
pure helpers, no API calls and no callbacks. Pike's push is the same distance
for everyone and Bane Nightmare is beaten by invuln/dispel regardless of who
is defending, so this knowledge does not belong per-hero.

It is the backing data for [save_select](save_select.md), but you can read it
directly too. The whole module is returned as one `ThreatData` table.

## The counter axis

The headline feature. Older versions hand-wrote, per threat, the list of
save-kinds that beat it. That list is now *derived* from facts about the
threat, so a save is only ever offered when it actually works.

Each threat carries a fact profile in `THREAT_PROFILE`: how it is delivered
(`delivery` = spell / channel / projectile_line / homing_charge / leap / ...),
its `school` and `damage_type`, whether it `pierces_spell_immunity`, whether it
is `dispellable`, positional flags (`positional`, `blocks_forced_movement`,
`zone_outlasts_cyclone`), and timing (`pre_cast`, `at_impact`, `mid_channel`,
`reactive`, `post_apply`). Each entry also records a `note` with the
Liquipedia/KV source and any conflict between the two.

`DeriveCounters(profile)` is a pure function that turns those facts into the
set of save-kinds that counter the threat. The rules read naturally: a magical
spell that does not pierce immunity gets `magic_immune`; a single-target
cast-time spell gets `reflect_target` (Lotus); a line projectile gets the
displacement kinds; a channel gets `channel_break`; pure burst gets no
damage-mitigation kind because nothing reduces it. Per-entry `add_kinds` /
`drop_kinds` patch the rare cases the rules cannot express.

At module load, `THREAT_COUNTER` is assembled by running every profile through
`DeriveCounters`. Threats with a profile are constrained to their derived set;
threats without one stay unlisted (and therefore unconstrained).

`SaveCounters(save_name, threat_mod)` is the compose-time filter that consumes
all of this: it intersects the save's kinds (`SAVE_KIND[save]`) with the
threat's derived counters (`THREAT_COUNTER[threat]`) and returns whether they
overlap. An unknown save or unknown threat returns `true` (not constrained).

```lua
local ThreatData = require("lib.threat_data")

-- Does BKB's magic-immunity actually beat Bane Nightmare?
if ThreatData.SaveCounters("item_black_king_bar", "modifier_bane_nightmare") then
    -- yes: fire it
end

-- Inspect why, straight from the facts:
local counters = ThreatData.DeriveCounters(
    ThreatData.THREAT_PROFILE["modifier_bane_nightmare"])
-- counters == { "invuln", "magic_immune", "reflect_target", "dispel_basic", "dispel_strong" }
```

| Function / table | Purpose |
|------------------|---------|
| `THREAT_PROFILE` | per-threat fact profile (delivery, school, damage_type, pierces, dispellable, positional flags, timing, `note`) |
| `DeriveCounters(profile)` | pure: fact profile -> ordered list of counter-effect kinds |
| `THREAT_COUNTER` | assembled at load from every profile via `DeriveCounters`; threat -> counter kinds |
| `SaveCounters(save_name, threat_mod)` | bool: do the save's kinds intersect the threat's counters (the compose-time filter) |

## Static catalogs

The data tables. None of these change per hero.

| Table | What it holds |
|-------|---------------|
| `SAVE_KIND` | each save item/ability -> the effect kinds it provides (the input side of `SaveCounters`) |
| `ESCAPE_ITEM_NAMES` | derived at load from `SAVE_KIND`: items carrying invuln / dispel / reflect / magic-immune (an enemy's escape window) |
| `SAVE_PUSH_DISTANCE` | displacement saves -> how far they shove (sourced from `item_data`) |
| `SAVE_COOLDOWN_TIER` | save -> `low` / `medium` / `high` cooldown tier (drives reserve scoring) |
| `THREAT_TETHER_RANGE` | channel/tether threats -> the range they break at |
| `THREATS_ON_SELF` | debuff modifiers that, landing on you, mean trouble; each maps to a `{ role, save }` hint |
| `ENEMY_BUFF_THREATS` | self-buffs an enemy casts that threaten you (distinct from debuffs on you) |
| `ABILITY_TO_THREAT` | ability name -> the threat modifier it applies |
| `LOTUS_WORTHY_INCOMING` | single-target ults worth reflecting with Lotus |
| `ENEMY_CHANNEL_MODIFIERS` / `WORTHY_CHANNEL_ABILITIES` | enemy channels worth interrupting |
| `CAST_POINT_THREATS` | threats armed during a cast point (back-filled with `cp_default` from the timing catalog) |
| `RECOMMENDED_SAVES` | hand-tuned save-priority list per threat |
| `CATEGORY_CHAINS` | per-category default save chain (`close_gap`, `channel_on_self`, `line_projectile`, `targeted_disable`, `delayed_aoe`, `trap`, `drain`, `physical_chase`, `lockdown`, `targeted_burst`) |

## Classification

Three independent axes describe a threat: what it is (`category`), how
dangerous it is (`severity`), and when to respond (`timing`). Category and
timing are orthogonal: a `close_gap` threat is dispatched `at_impact`, a
`channel_on_self` threat `mid_channel`.

Severity drives cooldown reservation: `SaveReservePenalty` returns a negative
score so a high-cooldown save (BKB, Aeon Disk) is not burned on a low-severity
threat.

| Function | Returns |
|----------|---------|
| `CategoryOf(threat_mod)` | category string, default `reactive` |
| `CategoryChain(category)` | the default save chain for a category, or `nil` |
| `SeverityOf(threat_mod)` | `low` / `medium` / `high`, default `medium` |
| `TimingFor(threat_mod)` | `pre_cast` / `at_impact` / `mid_channel` / `reactive` / `prophylactic`, default `reactive` |
| `SaveReservePenalty(save_name, threat_mod)` | score penalty (0, negative) for a high-CD save vs a low-severity threat |
| `RecommendedSaves(threat_mod)` | the tuned save list for a threat, or `nil` |
| `WillTetherBreak(save_name, threat_mod, distance)` | bool: pure geometry, will the push break the tether |

## Arrival timing

A slow save (one with a cast point or prep window) has to be fired early enough
to land when the threat actually arrives, not when it is detected. The
`THREAT_ARRIVAL_TIMING` catalog gives, per threat, the inputs to compute that:
a `speed_source` (live move speed, KV special value, ramped charge, or instant),
a `speed_fallback`, a `cast_point`, a `post_cast_delay`, and `impact_pos`
(`self` or `caster`, which tells a defensive AoE where to aim).

`ComputeArrivalTime(threat_mod, caster, target, modifier_handle, kv_lookup, opts)`
combines an entry with the live caster/target positions and optional KV reads
and returns `impact_t, impact_pos, entry, speed`. It returns `nil` when the
threat is uncatalogued or either unit is invalid/dead. Ramping charges (Spirit
Breaker) integrate the wind-up exactly via the helper kinematics rather than a
flat speed.

```lua
local ThreatData = require("lib.threat_data")
local impact_t = ThreatData.ComputeArrivalTime(
    threat_mod, caster, self_npc, modifier_handle, kv_lookup,
    { elapsed_s = time_since_armed })
if impact_t and impact_t <= W_PREP + slack then
    fire_save_now()
end
```

| Function / table | Purpose |
|------------------|---------|
| `THREAT_ARRIVAL_TIMING` | per-threat cast point / travel-speed source / impact position |
| `ComputeArrivalTime(threat_mod, caster, target, modifier_handle, kv_lookup, opts)` | `impact_t, impact_pos, entry, speed` (or `nil`) |
| `RampTravel` / `RampImpactT` / `ChargeRampKinematics` | the ramped-charge kinematics `ComputeArrivalTime` uses internally |

## Line projectiles

`LINE_PROJECTILE_INTERCEPTS` is a small catalog keyed on the projectile's
*source* unit name (Pudge, Mirana, Magnataur, Clockwerk). Each entry gives the
`ability`, the victim-side `threat_mod` (nilable), and a `hit_radius` (the
collision width on the victim). It feeds the line-projectile dispatch from an
`OnLinearProjectileCreate` hook: catch the projectile in flight and displace
perpendicular to break the line, sharing one save-lock with the reactive
on-self path.

## Canonicalization

One engine threat often ships several sibling modifiers for the same instance
(Bara Charge stamps `_vision` / `_target` / `_debuff`; Tusk Snowball stamps
`_movement` and `_target`). For lock and catalog purposes these must fold to a
single canonical name, or the second sibling double-fires the save.

`CanonicalMod(mod_name)` does the fold: it maps a sibling listed in
`CANONICAL_MOD_ALIASES` to its canonical name, returns the name unchanged when
it is already canonical or uncatalogued, and `nil` for a nil/empty input.
`CanonicalizeThreatMod` and `Canonicalize` are exported aliases of the same
function. `AbilityToCanonical(ability_name)` composes `ABILITY_TO_THREAT` with
the fold for the line-projectile path, where the save key must be derived from
the ability name alone (no modifier on the victim yet).

```lua
local ThreatData = require("lib.threat_data")
ThreatData.CanonicalMod("modifier_tusk_snowball_target")
-- "modifier_tusk_snowball_movement"
```

| Function / table | Purpose |
|------------------|---------|
| `CANONICAL_MOD_ALIASES` | sibling modifier name -> canonical name |
| `CanonicalMod(mod_name)` (= `CanonicalizeThreatMod`, `Canonicalize`) | fold a modifier to its canonical lock key, `nil` on nil/empty |
| `AbilityToCanonical(ability_name)` | ability name -> canonical modifier it stamps, or `nil` |

## Two protective sets

Two small lookup sets guard against wasting a save.

`UNKILLABLE_MODIFIERS` are modifiers (Dazzle Shallow Grave, Oracle False
Promise) that mean a target cannot be killed right now, so the brain should not
spend a kill combo on it and should prefer a killable target.

`SPELL_DEFLECT_MODIFIERS` are modifiers (Nyx Spiked Carapace) that reflect a
single-target spell back at the caster, so the brain must not cast a targeted
spell into them.

| Table | What it holds |
|-------|---------------|
| `UNKILLABLE_MODIFIERS` | modifiers that make a target unkillable (do not waste a kill) |
| `SPELL_DEFLECT_MODIFIERS` | reflect modifiers (do not cast a targeted spell into them) |

## A note on modifier names

Valve's KV data exposes ability names but not modifier names. Where a threat's
modifier name could not be confirmed it is a best-effort `modifier_<ability>`
guess (marked `verify` in the source, recoverable by grepping the VPK or seeing
the real name in a game). A wrong guess just means that one threat is not
recognised, which is harmless and correctable. It is the one soft spot in
otherwise solid data.
