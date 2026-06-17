# item_saves

Hero-agnostic defensive ITEM save bodies. Item-save behavior is a property of
the item and the threat geometry, not of the hero ("Wind Waker out of a
Disruptor field" is the same cast as "Wind Waker out of an Underlord pit"), so
every hero shares these. The lib owns one builder per defensive item; the hero
wires the results into its own dispatch chain.

## The shape

Each builder takes a `cfg` table and returns a save entry:

```lua
{ short = "bkb", fire = function(intent, threat_caster, threat_mod) ... end }
```

`short` is a stable label for logs/HUD. `fire` is the body that actually casts,
returning `true` if it issued the order and `false` if it held off (item not
owned, a gate said no, already buffed). The hero calls `fire` from its save
dispatcher when that item is the chosen response to an incoming threat. Builders
read `cfg` at call time, not at build time, so a hero may register policy hooks
after `build()`.

## cfg: the hero's cast wrapper

`cfg` is the thin bundle of cast primitives and optional policy callbacks the
hero supplies. The lib stays hero-agnostic by never touching the engine
directly: it asks `cfg` to issue every order and to answer every hero-state
question. There is no rigid schema enforced in code, so treat the source header
as the contract; the fields a builder reaches for fall into a few groups.

Cast primitives (the order issuers) include `issue_self`, `issue_no_target`,
`issue_target`, and `issue_position`, plus `item(name)` to resolve an owned item
and `self_npc()` to get the hero entity. State and logging helpers include
`tlog(level, tag, fields)`, `uname(npc)`, `dist_to(npc)`, and `recent_damage(s)`.

Optional policy hooks let a hero override default behavior without forking a
builder: `lotus_gate`, `cyclone_target`, `self_push`, `queue_post_move`,
`compute_safe_dest`, `pike_enemy_range`, `pike_after_target_fire`, and the
launch-in-vain probes `armed_cp_t` / `armed_threat_mod`. When a hook is absent
the builder uses a sane default (for example, Lotus falls back to an 85% HP
gate; the cyclone target/self choice defaults to self). See the header of
`lib/item_saves.lua` for the authoritative per-field notes.

## Builders

`ItemSaves.build(cfg)` is the factory: it runs every builder against one `cfg`
and returns a map keyed by item name, ready to merge into the hero's save map.

```lua
local ItemSaves = require("lib.item_saves")

-- in setup, after the hero has assembled its cast wrapper:
local item_map = ItemSaves.build(cfg)
for name, entry in pairs(item_map) do
    my_save_fire[name] = entry          -- merge alongside hero-ability saves
end

-- later, when a threat picks this item as the response:
local fired = item_map["item_black_king_bar"].fire(intent, threat_caster, threat_mod)
```

You can also call a single builder directly when you only want one entry:

```lua
local ItemSaves = require("lib.item_saves")
local bkb = ItemSaves.black_king_bar(cfg)   -- { short = "bkb", fire = ... }
```

| Builder | Item | Cast |
|---------|------|------|
| `glimmer_cape(cfg)` | Glimmer Cape | self-target (guarded by fade buff) |
| `black_king_bar(cfg)` | Black King Bar | no-target (guarded by immunity buff) |
| `manta(cfg)` | Manta Style | no-target |
| `invis_sword(cfg)` | Shadow Blade | no-target |
| `silver_edge(cfg)` | Silver Edge | no-target |
| `ethereal_blade_self(cfg)` | Ethereal Blade | self-target |
| `lotus_orb(cfg)` | Lotus Orb | self-target, gated by `lotus_gate` (default 85% HP) |
| `wind_waker(cfg [, opts])` | Wind Waker | self/target cyclone, launch-in-vain gate, queues a post-cast move (airborne is movable) |
| `cyclone(cfg [, opts])` | Eul's Scepter | self/target cyclone, launch-in-vain gate, no post-move |
| `force_staff(cfg)` | Force Staff | `self_push` keep-away if provided, else self-cast |
| `blink(cfg [, opts])` | Blink Dagger | position-target to a safe landing, skipped if the dagger is damage-broken |
| `hurricane_pike(cfg)` | Hurricane Pike | enemy-target the threat if in range and not immune, else `self_push` / self-cast |
| `ghost(cfg)` | Ghost Scepter | no-target |
| `satanic(cfg)` | Satanic | no-target |
| `pipe(cfg)` | Pipe of Insight | no-target |
| `crimson_guard(cfg)` | Crimson Guard | no-target |
| `blade_mail(cfg)` | Blade Mail | no-target |
| `phase_boots(cfg)` | Phase Boots | no-target |
| `solar_crest(cfg)` | Solar Crest | self-target |
| `disperser(cfg)` | Disperser | self-target |
| `diffusal_blade(cfg)` | Diffusal Blade | enemy-target purge of the threat (range 600), no-op without a valid caster |

The three upgraded blink daggers (Swift, Arcane, Overwhelming) reuse the
`blink` body and are registered in the factory under `item_swift_blink`,
`item_arcane_blink`, and `item_overwhelming_blink`.

## Cyclone launch gate

`ItemSaves.cyclone_launch_decision(cp_t, has_marker)` is the pure predicate
behind Wind Waker / Eul's "do not launch in vain" logic, exposed for offline
testing. `cp_t` is the cast-point time remaining on the armed threat (`nil`
means no cast-point gate is active) and `has_marker` is whether the during-cast
threat modifier is currently on the hero. It returns one of four strings:

| Return | Meaning |
|--------|---------|
| `"fire"` | proceed with the cast (no gate, or the threat is committed) |
| `"instant"` | proceed: the threat is about to land and there is no marker yet |
| `"defer"` | hold: still mid cast-point, wait for the marker |
| `"skip"` | hold: the cast-point window passed with no marker (the threat was cancelled) |

The cyclone builders consume this internally; you only need it directly if you
are testing or replicating the gate.
