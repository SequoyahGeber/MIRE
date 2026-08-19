#!/usr/bin/env python3
"""F-057: proves build_crafting_stations.py's rebuild is actually
byte-identical, rather than trusting the claim in docs/ASSET_TRACKER.md.

    python3 tools/blender/crafting_stations_repro_check.py

Runs `Blender --background --python build_crafting_stations.py` -- two
SEPARATE processes, exactly the way `docs/ASSET_TRACKER.md`'s contract and
the script's own docstring say to run it -- and snapshots the real output
(exports/*.glb, catalog.json) after each. Every file must be byte-identical
between the two runs.

This does write into the real `assets/crafting_stations/` on every run, the
same as running the build script by hand does; that is fine precisely because
the output is supposed to be deterministic, so a passing run always leaves the
tree in the same state a human running the build script once would. It is NOT
equivalent to calling `build_crafting_stations.main()` twice inside one
Blender process: that leaves the first run's mesh/object datablocks alive in
`bpy.data` (Blender purges orphans on file reload, not on `object.delete()`),
so the second in-process call collides with the first run's leftover
"Leg_1_1_Mesh" etc. and gets auto-suffixed ".001" -- a real effect, but one
that never happens in the actual pipeline, which always launches a fresh
Blender process per rebuild.

Previews are excluded on purpose -- F-042 already established that two
Cycles/Eevee renders are never byte-identical even when every decoded pixel
matches, so a byte diff on the PNGs would fail regardless of this bug.

The bug this guards: mire_art.box()'s bevel modifier changed a handful of
float bytes between otherwise identical background exports on Apple Silicon
(first found in build_ward_set.py). This kit's own box() override (see
build_crafting_stations.py) drops the bevel modifier entirely rather than
trusting the drift not to recur.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

BLENDER = "/Applications/Blender.app/Contents/MacOS/Blender"
ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tools" / "blender" / "build_crafting_stations.py"
EXPORT_DIR = ROOT / "assets" / "crafting_stations" / "exports"
CATALOG = ROOT / "assets" / "crafting_stations" / "catalog.json"

failures: list[str] = []


def check(label: str, condition: bool) -> None:
    if condition:
        print(f"PASS: {label}")
    else:
        failures.append(label)
        print(f"FAIL: {label}")


def rebuild_and_snapshot(tmp: Path, tag: str) -> Path:
    subprocess.run(
        [BLENDER, "--background", "--python", str(SCRIPT)],
        check=True, capture_output=True, text=True, cwd=ROOT,
    )
    dest = tmp / tag
    dest.mkdir()
    for glb in sorted(EXPORT_DIR.glob("*.glb")):
        shutil.copy2(glb, dest / glb.name)
    shutil.copy2(CATALOG, dest / "catalog.json")
    return dest


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="mire_crafting_stations_repro_") as raw_tmp:
        tmp = Path(raw_tmp)
        run1 = rebuild_and_snapshot(tmp, "run1")
        run2 = rebuild_and_snapshot(tmp, "run2")

        names = sorted(p.name for p in run1.glob("*.glb"))
        check(f"{len(names)} GLBs exported, both runs agree on the set", names == sorted(p.name for p in run2.glob("*.glb")))
        for name in names:
            check(f"{name}: byte-identical across two re-renders", (run1 / name).read_bytes() == (run2 / name).read_bytes())
        check("catalog.json: byte-identical across two re-renders", (run1 / "catalog.json").read_bytes() == (run2 / "catalog.json").read_bytes())

    verdict = "PASS" if not failures else f"FAIL ({len(failures)})"
    print(f"\nCRAFTING_STATIONS_REPRO_CHECK {verdict}")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
