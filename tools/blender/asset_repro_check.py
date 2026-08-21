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

The builders run against the real asset directory, because that is where they
write and reproducing the real pipeline is the whole point. What they change is
no longer left behind: `asset_tree_guard` snapshots the family directory (the
parent of `--export-dir`, plus any `--guard-dir`) and `assets/source/` first,
then puts back every byte afterwards (F-329). The GLBs and catalog genuinely are
deterministic -- that is what this check proves -- but a builder also saves its
`.blend` and renders previews, and neither of those is, so before the guard
existed every run of this check silently rewrote tracked files it never looked
at. The guard also fails the check if a builder writes anywhere under `assets/`
that the invocation did not declare, which is how a family with an unusual
output location gets noticed instead of quietly dirtying the tree.

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

sys.path.append(str(Path(__file__).resolve().parent))
from asset_tree_guard import asset_tree_guard  # noqa: E402

BLENDER = "/Applications/Blender.app/Contents/MacOS/Blender"
ROOT = Path(__file__).resolve().parents[2]

failures: list[str] = []


def check(label: str, condition: bool) -> None:
    if condition:
        print(f"PASS: {label}")
    else:
        failures.append(label)
        print(f"FAIL: {label}")


def rebuild_and_snapshot(guard, script: Path, export_dir: Path, catalog: Path, tmp: Path, tag: str) -> Path:
    # `guard.builder_run()` brackets ONLY the Blender launch: the builder holds the Godot import
    # lock for its whole write, so nothing else can touch the tree inside this window and any
    # out-of-root change really is this builder's (F-329).
    with guard.builder_run():
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
    parser.add_argument(
        "--guard-dir", action="append", default=[],
        help="extra directory this family's builder writes, relative to repo root. The family "
             "directory (the parent of --export-dir) and assets/source/ are always guarded; use "
             "this for a builder that also writes somewhere else, rather than letting the run "
             "fail on a stray.",
    )
    args = parser.parse_args()

    script = ROOT / args.script
    export_dir = ROOT / args.export_dir
    catalog = ROOT / args.catalog

    # The family directory, not just `exports/` -- the previews and the catalog live beside it.
    guarded = [export_dir.parent] + [ROOT / extra for extra in args.guard_dir]

    with tempfile.TemporaryDirectory(prefix="mire_asset_repro_") as raw_tmp:
        tmp = Path(raw_tmp)
        with asset_tree_guard(guarded, label=f"{args.label} repro") as guard:
            run1 = rebuild_and_snapshot(guard, script, export_dir, catalog, tmp, "run1")
            run2 = rebuild_and_snapshot(guard, script, export_dir, catalog, tmp, "run2")

            names = sorted(p.name for p in run1.glob("*.glb"))
            check(f"{len(names)} GLBs exported, both runs agree on the set", names == sorted(p.name for p in run2.glob("*.glb")))
            for name in names:
                check(f"{name}: byte-identical across two re-renders", (run1 / name).read_bytes() == (run2 / name).read_bytes())
            check("catalog.json: byte-identical across two re-renders", (run1 / "catalog.json").read_bytes() == (run2 / "catalog.json").read_bytes())

    print(f"asset tree guard: {guard.summary()}")
    for path in guard.restored:
        print(f"  restored {path}")
    for path in guard.removed:
        print(f"  removed  {path}")
    check("no builder wrote outside the declared asset roots", not guard.strays)
    for path in guard.strays:
        print(f"  STRAY    {path}")

    verdict = "PASS" if not failures else f"FAIL ({len(failures)})"
    print(f"\n{args.label}_ASSET_REPRO_CHECK {verdict}")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
