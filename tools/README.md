# tools/

Developer utilities. None of these run inside the game — they are either
build tools that regenerate the `lib/` data modules, or a test runner.

## Keeping the data libs fresh — `update.py`

Four of the libs (`item_data`, `ability_data`, `unit_data`, `hero_data`) are
**generated** from Valve's KV data. After a Dota patch that KV data changes,
and the libs drift out of date. `update.py` is the one command that fixes
that:

```bash
python tools/update.py            # regenerate the libs whose data changed
python tools/update.py --check    # just tell me if anything is stale
python tools/update.py --force    # regenerate everything no matter what
```

It hashes the KV json, remembers the hashes in `tools/.kv_manifest.json`, and
only re-runs the generators whose source data actually moved. `--check`
changes nothing and exits non-zero when something is stale — handy in a
post-patch routine.

### Where the KV data lives

The generators read Valve's KV json out of your UCZone / Umbrella install.
That path is different on every machine, so it is **not** hard-coded. The
toolkit looks, in order:

1. a path you pass on the command line — `--kv-dir "C:\path\to\assets\data"`
2. the `UCZONE_KV_DIR` environment variable
3. a few common default install locations (e.g. `C:\Umbrella\assets\data`)

If it cannot find the folder it tells you exactly how to point it at one. The
folder should contain `items.json`, `neutral_items.json`, `npc_abilities.json`,
`npc_heroes.json` and `npc_units.json`.

## The generators — `gen_*.py`

`update.py` calls these for you, but you can run any one directly:

```bash
python tools/gen_item_data.py
python tools/gen_ability_data.py
python tools/gen_unit_data.py
python tools/gen_hero_data.py
```

Each turns one or two KV files into a pure-data Lua module. The helper
functions and any curated tables (like `item_data`'s `SAVE_GEOMETRY`) live as
literals **inside the generator** — that makes the generator the single
source of truth. **Do not hand-edit a generated lib**; edit the generator and
re-run it. They need Python 3, nothing else.

## Tests — `run_tests.lua`

Pure-Lua unit tests for the lib helpers that can run without a live game. The
game API is stubbed at the top of the file.

```bash
lua tools/run_tests.lua
```

Run it from the repo root (the test file puts `./` on `package.path` so
`require("lib.x")` resolves). Needs Lua 5.1+ on your PATH — grab it from
<https://www.lua.org/download.html> or `winget install -e --id DEVCOM.Lua`.

Add a `describe(...)` block when you add a lib or a helper.
