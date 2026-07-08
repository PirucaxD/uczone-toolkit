# schedule

A timing-anchored shove-cycle controller. It answers one question for a farming
hero: do I keep clearing this lane wave now, slip into the jungle for a moment,
or back off to recover? It decides by computing how much *slack* you have before
the wave demands you, then picks the action that keeps your lane crashing on time.

Hero-agnostic and pure. Nothing here calls the engine, reads a clock, or runs a
loop. The hero assembles plain data (wave records from `lane`, slack inputs from
`route`, plus a few engine reads) and passes it in, so this module stays fully
testable with zero runtime-API risk. All times are in seconds.

## The slack idea, and why the clock cancels

The core trick is that `Plan` never compares against absolute game time. It works
in *relative* terms:

```
leave_by = arrival - travel_to_mid - lead
slack    = leave_by - now
```

As long as `arrival` is expressed as `now + (relative ETA)`, the `now` term
cancels in `slack`, so the decision is the same no matter what the clock reads.
Slack is simply how many seconds you can spend elsewhere before you must leave to
make the next wave on time. Positive slack means there is room to jungle, zero or
negative slack means the wave is due and you should be shoving.

This pairs with `lane` (which supplies *where* and *when* the wave arrives) and
`route` (which supplies the *slack* budget and travel estimates).

## ClearTime

`ClearTime(eff_hp, cal)` estimates how long a wave takes to clear. It is a hybrid:
the cast COUNT is derived from the wave's effective HP divided by per-cast damage
(so it self-adjusts as creeps scale), while the wall-clock duration comes from
calibrated per-cast timings.

- `eff_hp` is the wave's effective HP: the visible sum, or the assumed
  `ExpectedWave` value when the lane is fogged.
- `cal` is the calibration table:
  - `march_dmg_per_cast` damage one clear-cast deals (defaults to 1, guarded so a
    zero or negative value never divides).
  - `cast_dur` wall-clock duration of a single cast.
  - `robot_kill` extra time per cast for follow-up kills.
  - `rearm_channel` channel time paid *between* casts (applied `casts - 1` times).

Returns `{ casts, t_clear }`: the integer cast count (at least 1) and the total
estimated clear time.

## Plan

`Plan(ctx)` is the cycle decision. It calls `ClearTime` internally, computes
`leave_by` and `slack`, then chooses an action.

`ctx` fields:

- `now` current time (any reference, since it cancels in slack).
- `wave` table `{ arrival, eff_hp, present }`: when the next wave arrives (as
  `now + ETA`), its effective HP (fed to `ClearTime`), and whether it is present.
- `cal` the calibration table passed through to `ClearTime`, plus an optional
  `lead` (seconds of safety margin to arrive early).
- `travel_to_mid` seconds to travel from your current spot back to the lane.
- `mana` your current mana.
- `shove_cost` mana needed for one shove cycle.
- `safe` boolean, false when you are under threat.

The action is picked in priority order:

| Condition | `action` | `reason` |
|-----------|----------|----------|
| not `safe` | `recover` | `unsafe` |
| `mana < shove_cost` | `recover` | `mana` |
| `slack <= 0` | `shove` | `due` |
| otherwise | `jungle` | `slack` |

Returns `{ action, deadline, leave_by, slack, casts, t_clear, reason }`, where
`action` is `"shove"`, `"jungle"`, or `"recover"`, `deadline` is the raw wave
`arrival`, and `casts` / `t_clear` come straight from `ClearTime`. When the action
is `jungle`, `slack` is your budget: how many seconds you can spend before
`leave_by`.

## Usage

```lua
local Schedule = require("lib.schedule")

local cal = {
    march_dmg_per_cast = 260, cast_dur = 0.5, robot_kill = 0.3,
    rearm_channel = 1.5, lead = 1.0,
}

local plan = Schedule.Plan({
    now           = GameRules.GetGameTime(),
    wave          = { arrival = next_wave_eta, eff_hp = wave_eff_hp, present = true },
    cal           = cal,
    travel_to_mid = travel_seconds,
    mana          = my_mana,
    shove_cost    = 300,
    safe          = not under_threat,
})

if plan.action == "shove" then
    -- clear the wave now
elseif plan.action == "jungle" then
    -- plan.slack seconds to farm before leaving for the lane
else
    -- recover (unsafe or out of mana)
end
```

## What's new in this sync (from the Tinker farm line)

- `Schedule.Plan` v2: the veto cascade lives lib-side as tested rules -
  thin-wave (VISIBLE only; fogged estimates never veto), far-wave travel
  economics (`camp_alt_s`), gone-by-arrival, no-safe-stand, defend-crash
  (never overrides unsafe), suppression, and the lane-first filler with its
  invariant (a vetoed wave never resurrects through the filler). The mana
  gate is regen-aware (mana at leave-by, not now).
- `Schedule.NextWaveArrival` - wave-cadence prediction on the spawn grid,
  measured-phase first (your last observed arrival), spawn-clock fallback.
- `Schedule.NextOnGrid` / `Schedule.NextEvent` - the Dota clock (rune spawns,
  neutral respawns) as one lookup.
- `Schedule.SeqFits` - does an ability/channel sequence fit a time window.
- `Schedule.StackWindow` - when to aggro a camp so it leaves at :53-:55.
