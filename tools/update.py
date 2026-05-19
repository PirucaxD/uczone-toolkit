#!/usr/bin/env python
"""Regenerate every KV-backed data lib in one command.

The data libs (item / ability / unit / hero) are generated from Valve's
KV json. After a Dota patch that json changes, and the libs drift out of
date. This script regenerates the ones whose source data actually moved.

  python tools/update.py                  regenerate stale libs
  python tools/update.py --check          report staleness, change nothing
  python tools/update.py --force          regenerate everything
  python tools/update.py --kv-dir PATH    use a non-default KV folder

How staleness works: the KV json files are hashed and the hashes stored in
tools/.kv_manifest.json. A lib is stale when the json it is built from has
a different hash than last run. --check just prints the verdict, which is
handy in a "did the patch break my libs?" routine.
"""
import hashlib
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import kv_paths

MANIFEST = os.path.join(HERE, ".kv_manifest.json")

# each generator and the KV files it reads
GENERATORS = [
    ("gen_item_data.py",    ["items.json", "neutral_items.json"]),
    ("gen_ability_data.py", ["npc_abilities.json"]),
    ("gen_unit_data.py",    ["npc_units.json"]),
    ("gen_hero_data.py",    ["npc_heroes.json"]),
]


def file_hash(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def load_manifest():
    if os.path.isfile(MANIFEST):
        try:
            with open(MANIFEST, encoding="utf-8") as f:
                return json.load(f).get("hashes", {})
        except (ValueError, OSError):
            pass
    return {}


def main():
    args = sys.argv[1:]
    check_only = "--check" in args
    force = "--force" in args

    kv_dir = kv_paths.resolve(args)

    # hash every KV file the generators care about
    current = {}
    for _, files in GENERATORS:
        for fn in files:
            if fn in current:
                continue
            path = os.path.join(kv_dir, fn)
            if not os.path.isfile(path):
                raise SystemExit("missing KV file: " + path)
            current[fn] = file_hash(path)

    old = load_manifest()
    stale = [gen for gen, files in GENERATORS
             if force or any(current.get(f) != old.get(f) for f in files)]

    if check_only:
        if stale:
            print("STALE: these libs are behind the KV data:")
            for gen in stale:
                print("  - " + gen)
            print("run `python tools/update.py` to refresh them.")
            sys.exit(1)
        print("up to date: every data lib matches the current KV data.")
        return

    if not stale:
        print("up to date: nothing to regenerate. "
              "(use --force to rebuild anyway.)")
        return

    print("KV data folder: " + kv_dir)
    for gen in stale:
        print("regenerating via " + gen + " ...")
        rc = subprocess.call(
            [sys.executable, os.path.join(HERE, gen), "--kv-dir", kv_dir])
        if rc != 0:
            raise SystemExit(gen + " failed (exit code %d)" % rc)

    with open(MANIFEST, "w", encoding="utf-8") as f:
        json.dump({"kv_dir": kv_dir, "hashes": current}, f, indent=2)
    print("done: %d data lib(s) regenerated." % len(stale))


if __name__ == "__main__":
    main()
