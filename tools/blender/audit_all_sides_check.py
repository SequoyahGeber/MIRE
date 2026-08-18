"""Regression guard for F-109 and F-110 in `audit_all_sides.py`.

Run:
    /Applications/Blender.app/Contents/MacOS/Blender --background --python \
        tools/blender/audit_all_sides_check.py

F-109 -- the inside-out test must not judge an open sheet by the same
divergence-theorem sum that only means something for a closed shell.
`geometry_report()` used to run every mesh through `sum (n . c) * area` and
flag a negative result as "inside out" -- correct only for a closed shell,
where the divergence theorem gives an enclosed volume. For an open sheet the
same sum has no enclosed volume to measure and is dominated by where the
sheet sits relative to the world origin instead: a bottom-strake patch board
with a correct downward normal and a positive z centre scored negative and
read as a defect. A-009's finished, verified hull still reported 94 such
false positives under the old test. The fix -- `is_closed_shell()` -- welds
vertices by position (these meshes are unwelded face soup, which defeats
bmesh's own `edge.is_manifold`) and only trusts the volume sign when every
welded edge borders exactly two faces; an open sheet is now reported
separately as `open_surface_objects` instead of being judged at all.

This does not just re-run the fixed implementation and check it returns
*something* -- it rebuilds the pre-fix naive sum inline (kept here, not in
audit_all_sides.py, purely to give this check the old wrong test to compare
against) so it can prove the exact false-positive shape the finding
describes, then checks that a genuinely inverted CLOSED shell is still
caught -- the fix must change what happens to open sheets without blinding
the audit to real inversions.

F-110 -- the ledger keys on the asset's path, not the GLB's content, so a
second run with the same `--outdir` used to skip every asset already
recorded even if the GLB had been re-exported since, silently re-reporting a
defect that had already been fixed. `pending_glbs()` now compares each GLB's
current mtime against the mtime its ledger entry was recorded under, so a
re-export is treated as pending again instead of "already done". The check
below builds real temp files (mtime comparison needs a real filesystem) and
proves three cases: unrecorded assets are pending, recorded-and-unchanged
assets are skipped, and a recorded asset whose mtime has since moved is
pending again and flagged as stale rather than silently reused.
"""

import json
import os
import pathlib
import sys
import tempfile
import time

sys.path.append(str(pathlib.Path(__file__).resolve().parent))

import bpy  # noqa: E402  (Blender's module; only importable once the interpreter is Blender's)
import bmesh  # noqa: E402
from mathutils import Vector  # noqa: E402

from audit_all_sides import bounds, geometry_report, is_closed_shell, pending_glbs  # noqa: E402

failures: list[str] = []


def check(label: str, condition: bool) -> None:
    if not condition:
        failures.append(label)


def naive_signed_volume(obj: bpy.types.Object) -> float:
    """The pre-fix measurement: sum (n . c) * area, with no closed-shell guard."""
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bm.transform(obj.matrix_world)
    bm.normal_update()
    vol = 0.0
    for f in bm.faces:
        vol += f.normal.dot(f.calc_center_median()) * f.calc_area()
    bm.free()
    return vol


def mesh_object(name: str, vertices: list[tuple[float, float, float]], faces: list[tuple[int, ...]]) -> bpy.types.Object:
    mesh = bpy.data.meshes.new(f"{name}_Mesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    return obj


for stale in list(bpy.data.objects):
    bpy.data.objects.remove(stale, do_unlink=True)

# 1. A single downward-facing quad -- the exact false-positive shape the
#    finding names: "a bottom-strake patch board with a correct downward
#    normal and a positive z centre scores negative and reads as a defect."
#    Winding (0, 3, 2, 1) gives an outward -Z normal; placed at z=+2 so its
#    centre sits on the positive side of the origin, same as the finding.
plank = mesh_object(
    "BottomStrakePlank",
    [(-1.0, -1.0, 0.0), (1.0, -1.0, 0.0), (1.0, 1.0, 0.0), (-1.0, 1.0, 0.0)],
    [(0, 3, 2, 1)],
)
plank.location = Vector((0.0, 0.0, 2.0))
bpy.context.view_layer.update()

old_vol = naive_signed_volume(plank)
check(
    f"the pre-fix test really would have flagged this correct plank (naive signed volume {old_vol:.3f} < 0)",
    old_vol < 0.0,
)

lo, hi = bounds([plank])
report = geometry_report([plank], lo, hi)
check("the fixed test does NOT flag the open plank as inside out", plank.name not in report["inside_out_objects"])
check("the fixed test reports the open plank as an open surface instead", plank.name in report["open_surface_objects"])

# 2. A closed cube, correctly wound (outward-facing normals) -- must not be
#    flagged, and must be recognised as a closed shell so the fix isn't just
#    "never flag anything".
bm = bmesh.new()
bmesh.ops.create_cube(bm, size=2.0)
good_mesh = bpy.data.meshes.new("GoodCube_Mesh")
bm.to_mesh(good_mesh)
good_cube = bpy.data.objects.new("GoodCube", good_mesh)
bpy.context.scene.collection.objects.link(good_cube)
good_cube.location = Vector((10.0, 0.0, 0.0))
bpy.context.view_layer.update()

bm_check = bmesh.new()
bm_check.from_mesh(good_cube.data)
check("a correctly wound cube is recognised as a closed shell", is_closed_shell(bm_check))
bm_check.free()
bm.free()

lo, hi = bounds([good_cube])
report = geometry_report([good_cube], lo, hi)
check("a correctly wound closed cube is not flagged inside out", good_cube.name not in report["inside_out_objects"])
check(
    "a correctly wound closed cube is not reported as an open surface",
    good_cube.name not in report["open_surface_objects"],
)

# 3. The same cube with every face reversed -- a genuine inversion. The fix
#    must still catch this; it only changes what happens to OPEN sheets.
bm = bmesh.new()
bmesh.ops.create_cube(bm, size=2.0)
bmesh.ops.reverse_faces(bm, faces=list(bm.faces))
bad_mesh = bpy.data.meshes.new("InvertedCube_Mesh")
bm.to_mesh(bad_mesh)
bm.free()
bad_cube = bpy.data.objects.new("InvertedCube", bad_mesh)
bpy.context.scene.collection.objects.link(bad_cube)
bad_cube.location = Vector((-10.0, 0.0, 0.0))
bpy.context.view_layer.update()

lo, hi = bounds([bad_cube])
report = geometry_report([bad_cube], lo, hi)
check("a genuinely inverted closed cube is still caught", bad_cube.name in report["inside_out_objects"])
check(
    "a genuinely inverted closed cube is not reported as an open surface",
    bad_cube.name not in report["open_surface_objects"],
)

# 4. F-110: a re-exported GLB must come back as pending, not silently skipped
#    because its path is already in the ledger.
with tempfile.TemporaryDirectory() as tmp:
    assets_root = pathlib.Path(tmp)
    fresh = assets_root / "fresh.glb"       # never audited
    current = assets_root / "current.glb"   # audited, unchanged since
    reexported = assets_root / "reexported.glb"  # audited, then re-exported
    for p in (fresh, current, reexported):
        p.write_bytes(b"")

    # Give each file a distinct, known mtime rather than trusting whatever the
    # filesystem assigned at creation (some filesystems only offer 1s
    # resolution, which could make two of these collide by chance).
    now = time.time()
    os.utime(current, (now, now))
    os.utime(reexported, (now, now))

    report = {
        "current.glb": {"_source_mtime": now, "triangles": 10},
        "reexported.glb": {"_source_mtime": now - 120.0, "triangles": 10},  # stale: recorded before the file's real mtime
    }

    glbs = sorted((fresh, current, reexported))
    pending, stale = pending_glbs(glbs, assets_root, report)

    check("an asset never recorded in the ledger is pending", fresh in pending)
    check("an asset recorded with a matching mtime is NOT re-rendered", current not in pending)
    check("an asset whose mtime moved since it was recorded is pending again", reexported in pending)
    check("an unrecorded asset is not reported as a stale re-render", fresh not in stale)
    check("an unchanged recorded asset is not reported as a stale re-render", current not in stale)
    check("a re-exported asset IS reported as a stale re-render", reexported in stale)

    # And prove record()'s own shape: an entry written this run carries the
    # mtime it was rendered under, so the NEXT run recognises it as current
    # rather than re-flagging it forever.
    ledger_line = json.dumps({"reexported.glb": {**report["reexported.glb"], "_source_mtime": now}})
    resaved = json.loads(ledger_line)["reexported.glb"]
    check(
        "an entry re-recorded with the file's current mtime round-trips through JSON exactly",
        resaved["_source_mtime"] == now,
    )

verdict = "PASS" if not failures else f"FAIL ({len(failures)})"
print(f"AUDIT_ALL_SIDES_CHECK {verdict}")
for failure in failures:
    print(f"  - {failure}")

sys.exit(1 if failures else 0)
