#!/usr/bin/env python3
"""F-198: generic byte-identical-rebuild proof for any Blender asset-batch
builder, generalizing crafting_stations_repro_check.py (F-057's original,
single-family version) so a family doesn't need its own copy.

    python3 tools/blender/asset_repro_check.py \\
        --script tools/blender/build_tool_weapon_set.py \\
        --export-dir assets/tools_weapons/exports \\
        --catalog assets/tools_weapons/catalog.json \\
        --label A-004

Runs `Blender --background --python <script>` -- two SEPARATE processes,
the way every family's docs/ASSET_TRACKER.md contract requires -- and
snapshots the real output (exports/*.glb, catalog.json) after each. Every
file must be byte-identical between the two runs.

This writes into the real asset directory on every run, the same as running
the build script by hand does; that is fine precisely because the output is
supposed to be deterministic, so a passing run always leaves the tree in the
state a human running the build script once would.

It is NOT equivalent to calling a build script's main() twice inside one
Blender process: Blender purges orphan datablocks on file reload, not on
`object.delete()`, so a second in-process call collides with the first run's
leftover mesh/object names and gets auto-suffixed ".001" -- a real effect,
but one that never happens in the actual pipeline, which always launches a
fresh Blender process per rebuild.

Previews are excluded on purpose -- F-042 already established that two
Cycles/Eevee renders are never byte-identical even when every decoded pixel
matches, so a byte diff on the PNGs would fail regardless of any real bug.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

BLENDER = "/Applications/Blender.app/Contents/MacOS/Blender"
ROOT = Path(__file__).resolve().parents[2]

failures: list[str] = []


def check(label: str, condition: bool) -> None:
    if condition:
        print(f"PASS: {label}")
    else:
        failures.append(label)
        print(f"FAIL: {label}")


def rebuild_and_snapshot(script: Path, export_dir: Path, catalog: Path, tmp: Path, tag: str) -> Path:
    subprocess.run(
        [BLENDER, "--background", "--python", str(script)],
        check=True, capture_output=True, text=True, cwd=ROOT,
    )
    dest = tmp / tag
    dest.mkdir()
    for glb in sorted(export_dir.glob("*.glb")):
        shutil.copy2(glb, dest / glb.name)
    shutil.copy2(catalog, dest / "catalog.json")
    return dest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--script", required=True, help="build script, relative to repo root")
    parser.add_argument("--export-dir", required=True, help="directory of *.glb exports, relative to repo root")
    parser.add_argument("--catalog", required=True, help="catalog.json, relative to repo root")
    parser.add_argument("--label", required=True, help="tracker id for the verdict line, e.g. A-004")
    args = parser.parse_args()

    script = ROOT / args.script
    export_dir = ROOT / args.export_dir
    catalog = ROOT / args.catalog

    with tempfile.TemporaryDirectory(prefix="mire_asset_repro_") as raw_tmp:
        tmp = Path(raw_tmp)
        run1 = rebuild_and_snapshot(script, export_dir, catalog, tmp, "run1")
        run2 = rebuild_and_snapshot(script, export_dir, catalog, tmp, "run2")

        names = sorted(p.name for p in run1.glob("*.glb"))
        check(f"{len(names)} GLBs exported, both runs agree on the set", names == sorted(p.name for p in run2.glob("*.glb")))
        for name in names:
            check(f"{name}: byte-identical across two re-renders", (run1 / name).read_bytes() == (run2 / name).read_bytes())
        check("catalog.json: byte-identical across two re-renders", (run1 / "catalog.json").read_bytes() == (run2 / "catalog.json").read_bytes())

    verdict = "PASS" if not failures else f"FAIL ({len(failures)})"
    print(f"\n{args.label}_ASSET_REPRO_CHECK {verdict}")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
