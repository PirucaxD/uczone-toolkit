# towers

A per-tower registry with two reads a decision layer keeps asking for: *is
tower X still alive?* and *when will this tower die?* Pure state-in/state-out -
the hero injects samples from its own engine reads, the module never touches
the API.

## Why measured, not modeled

Predicting a tower's death from creep DPS tables means modeling wave
composition, tower armor, glyphs, and backdoor protection - and being wrong
whenever any of them changes. The tower's HP is directly readable while your
creeps attack it (they give you vision), so the registry just measures the
slope and extrapolates:

```
eta = hp / observed_hp_per_second
```

The prediction only exists while a tower is *actively melting* (slope above a
floor, sample fresh). Undamaged towers, towers healing back up (glyph), and
towers gone stale under fog all predict `math.huge` - which callers treat as
"no prediction", so the read degrades to doing nothing rather than guessing.

## Sampling

Feed one pass per scan tick (a couple of seconds is plenty). Buildings are
always visible in Dota, so a spot that stops returning a tower entity after
having been seen alive is a confirmed kill:

```lua
local samples = {}
for _, t in ipairs(MapData.TOWERS) do
    local key = t.name .. "@" .. tostring(t.team)
    local ent = find_alive_tower_near(t.pos)          -- your engine read
    if ent then
        samples[#samples + 1] = { key = key, hp = Entity.GetHealth(ent), alive = true }
    elseif Towers.Alive(track, key) then              -- seen alive before, gone now
        samples[#samples + 1] = { key = key, alive = false }
    end
end
track = Towers.Track(track, samples, GameRules.GetGameTime())
```

## API

### Towers.Track(state, samples, now) -> state

Update the registry. Each sample is `{ key, hp, alive }`. An `alive = false`
sample sets a **permanent dead latch** (towers never revive; later noise cannot
resurrect one). Alive samples update the stored HP and an EMA damage slope; an
HP *increase* (glyph, backdoor regen) resets the melt read.

### Towers.Alive(state, key) -> true | false | nil

`false` once the dead latch is set, `true` while sampled alive, `nil` for a
key never sampled - callers distinguish "known dead" from "never looked".

### Towers.DeathEta(state, key, now, opts?) -> seconds

`0` when dead. While actively melting (slope at least `opts.floor`, default 20
hp/s, on a sample no older than `opts.stale_s`, default 6s): the extrapolated
seconds until death. Everything else: `math.huge`.

## The consumer pattern

Use the ETA as a *schedule exclusion*, not a positional veto: a plan whose
terminus is a tower predicted dead before you arrive is skipped this decide and
re-evaluated on the next one. Use the alive flag as a *commit tripwire*: a plan
whose tower died mid-execution re-decides immediately instead of waiting on
geometry that no longer exists.
