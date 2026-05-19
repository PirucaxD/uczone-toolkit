"""Locate the Dota 2 KV data directory the generators read from.

The generators turn Valve's shipped KV json (items, abilities, units,
heroes) into Lua data modules. That json lives inside your UCZone /
Umbrella install, and the install path differs per machine, so it is not
hard-coded.

Resolution order, first hit wins:
  1. an explicit path on the command line:  --kv-dir "C:\\path\\to\\data"
  2. the UCZONE_KV_DIR environment variable
  3. a short list of common default install locations

If none of those point at a real folder, a helpful error is raised.
"""
import os
import sys

# the KV files the generators consume — also used to sanity-check a folder
KV_FILES = [
    "items.json",
    "neutral_items.json",
    "npc_abilities.json",
    "npc_heroes.json",
    "npc_units.json",
]

# common spots an Umbrella install puts the data folder
DEFAULTS = [
    r"C:\Umbrella\assets\data",
    r"D:\Umbrella\assets\data",
    os.path.expanduser(r"~\Umbrella\assets\data"),
]


def _from_args(argv):
    """Pull a --kv-dir value out of an argv list, or return None."""
    for i, a in enumerate(argv):
        if a == "--kv-dir" and i + 1 < len(argv):
            return argv[i + 1]
        if a.startswith("--kv-dir="):
            return a.split("=", 1)[1]
    return None


def resolve(argv=None):
    """Return the KV data directory, or raise SystemExit with guidance.

    Pass `argv` (a list) to look for --kv-dir in it; defaults to the real
    command line.
    """
    if argv is None:
        argv = sys.argv[1:]

    candidates = []
    explicit = _from_args(argv)
    if explicit:
        candidates.append(explicit)
    env = os.environ.get("UCZONE_KV_DIR")
    if env:
        candidates.append(env)
    candidates.extend(DEFAULTS)

    for path in candidates:
        if path and os.path.isdir(path):
            return path

    raise SystemExit(
        "Could not find the Dota KV data directory.\n"
        "Tell the generator where it is, one of:\n"
        '  python tools/<generator>.py --kv-dir "C:\\path\\to\\assets\\data"\n'
        "  set UCZONE_KV_DIR=C:\\path\\to\\assets\\data   (then re-run)\n"
        "The folder should contain: " + ", ".join(KV_FILES)
    )
