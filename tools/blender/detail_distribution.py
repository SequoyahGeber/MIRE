"""Find assets whose detail only exists on the side the author's camera faced.

Run with:
  Blender --background --python detail_distribution.py -- [--outdir DIR]

The defect this measures
------------------------
A fallen log with three branch stubs that all leave the same side of the trunk,
all pointing the same way, and a bare far side. It looks right in the one
preview the batch rendered and wrong from every other angle. The same hand shows
up as moss painted as a single flat oval on one face, and as bare undersides.

How it is measured
------------------
Take the asset's principal axis. Project every vertex into the plane across that
axis and keep the ones sticking out past the body — those are the *detail*.
Bin their angles around the axis into twelve 30-degree sectors and ask two
questions:

* how many sectors have any detail at all (coverage), and
* how tightly clustered the detail is in one direction, via the mean resultant
  length R of the angles. R near 0 means detail is spread around the axis; R
  near 1 means it all points one way.

A log with branches all round reads well from anywhere. A log scoring coverage
3/12 and R 0.9 is the defect, stated as a number.
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

import bpy
import numpy as np
from mathutils import Vector

BINS = 12
PROTRUSION_FACTOR = 1.30


def argv() -> list[str]:
    return sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []


def opt(name: str, default: str) -> str:
    a = argv()
    return a[a.index(name) + 1] if name in a else default


def clear() -> None:
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for blocks in (bpy.data.meshes, bpy.data.materials, bpy.data.objects):
        for b in list(blocks):
            try:
                blocks.remove(b, do_unlink=True)
            except (RuntimeError, ReferenceError):
                pass


def analyse(verts: np.ndarray, axis: int) -> dict:
    """Angular spread of protruding geometry around ``axis``."""
    other = [i for i in range(3) if i != axis]
    plane = verts[:, other]
    centre = plane.mean(axis=0)
    rel = plane - centre
    radius = np.hypot(rel[:, 0], rel[:, 1])
    if radius.size == 0:
        return {}
    body = float(np.median(radius))
    if body <= 1e-6:
        return {}
    mask = radius > body * PROTRUSION_FACTOR
    if mask.sum() < 3:
        return {
            "protruding_vertices": int(mask.sum()),
            "sectors_with_detail": 0,
            "concentration_R": 0.0,
            "verdict": "no protruding detail",
        }
    ang = np.arctan2(rel[mask, 1], rel[mask, 0])
    # Weight by how far each vertex sticks out, so a big branch counts for more
    # than a stray vertex on a slightly lumpy surface.
    w = radius[mask] - body
    R = float(np.hypot((w * np.cos(ang)).sum(), (w * np.sin(ang)).sum()) / w.sum())
    hist = np.histogram(ang, bins=BINS, range=(-math.pi, math.pi), weights=w)[0]
    occupied = int((hist > w.sum() * 0.01).sum())
    mean_dir = math.degrees(math.atan2((w * np.sin(ang)).sum(), (w * np.cos(ang)).sum())) % 360
    return {
        "protruding_vertices": int(mask.sum()),
        "sectors_with_detail": occupied,
        "sectors_total": BINS,
        "concentration_R": round(R, 3),
        "mean_detail_direction_deg": round(mean_dir, 1),
        "verdict": "ONE-SIDED" if (occupied <= 5 and R > 0.45) else "ok",
    }


def main() -> None:
    root = Path("/Users/sequoyahgeber/Desktop/MIRE")
    outdir = Path(opt("--outdir", "."))
    glbs = sorted(p for p in (root / "assets").rglob("*.glb"))
    # Checkpoint per asset so an interrupted run keeps everything it finished
    # (AGENTS.md, "Any agent working a list must be killable at any moment").
    ledger = outdir / "detail_distribution.jsonl"
    out: dict[str, dict] = {}
    if ledger.exists():
        for line in ledger.read_text().splitlines():
            if line.strip():
                try:
                    out.update(json.loads(line))
                except json.JSONDecodeError:
                    continue
        print(f"resuming: {len(out)} assets already done")

    def record(key: str, value: dict) -> None:
        out[key] = value
        with ledger.open("a") as handle:
            handle.write(json.dumps({key: value}) + "\n")
            handle.flush()

    glbs = [g for g in glbs if g.relative_to(root / "assets").as_posix() not in out]

    for i, glb in enumerate(glbs, 1):
        rel = glb.relative_to(root / "assets").as_posix()
        clear()
        try:
            bpy.ops.import_scene.gltf(filepath=str(glb))
        except Exception as exc:  # noqa: BLE001
            record(rel, {"error": str(exc)})
            continue
        meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
        if not meshes:
            continue
        pts = []
        centroids = []
        for o in meshes:
            m = o.matrix_world
            co = [m @ v.co for v in o.data.vertices]
            pts.extend([(v.x, v.y, v.z) for v in co])
            if co:
                c = sum(co, Vector()) / len(co)
                centroids.append((c.x, c.y, c.z))
        verts = np.array(pts, dtype=np.float64)
        if verts.shape[0] < 8:
            continue
        span = verts.max(axis=0) - verts.min(axis=0)
        axis = int(np.argmax(span))

        entry = {"axis": "xyz"[axis], "span_m": [round(float(s), 4) for s in span], "parts": len(meshes)}
        entry.update(analyse(verts, axis))
        if len(centroids) >= 4:
            entry["part_centroids"] = analyse(np.array(centroids, dtype=np.float64), axis)
        record(rel, entry)
        if i % 40 == 0:
            print(f"  {i}/{len(glbs)}", flush=True)

    (outdir / "detail_distribution.json").write_text(json.dumps(out, indent=2, sort_keys=True))
    flagged = [(k, v) for k, v in out.items() if v.get("verdict") == "ONE-SIDED"]
    flagged.sort(key=lambda kv: -kv[1].get("concentration_R", 0))
    print(f"\n{len(flagged)} of {len(out)} assets flagged ONE-SIDED\n")
    for k, v in flagged[:40]:
        print(f"  R={v['concentration_R']:.2f} sectors={v['sectors_with_detail']:2d}/12  {k}")


if __name__ == "__main__":
    main()
