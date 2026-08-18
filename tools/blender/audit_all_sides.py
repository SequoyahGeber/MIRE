"""All-sides audit of MIRE's shipped GLBs.

Run with:
  Blender --background --python audit_all_sides.py -- [--only substring] [--size N] [--outdir DIR]

Why this exists
---------------
Every asset batch so far recorded a "two-preview visual inspection", and both of
those previews are a *single* camera angle. A-004R and A-021S were the only
batches that ever orbited an asset. So the back, the underside, and the far side
of most of MIRE's 224 exports have never been looked at by anybody. This script
is the missing instrument: it renders each GLB from eight azimuths plus a top and
a bottom view into one contact sheet, and it runs the numeric checks that catch
the same defect class without a human in the loop.

It is a camera and a tape measure, not a second art pass. It never edits source.
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

import bpy
import bmesh
import numpy as np
from mathutils import Vector


# --- view grid -------------------------------------------------------------
# Row 0: eight azimuths at gameplay-ish elevation, so a player-height sightline
# is what judges the silhouette. Row 1 ends with top and bottom, which are the
# two views that catch missing caps and geometry floating off the ground plane.
AZIMUTHS = [0.0, 45.0, 90.0, 135.0, 180.0, 225.0, 270.0, 315.0]
ELEVATION = 12.0
COLUMNS = 5
MARGIN = 1.16


def argv() -> list[str]:
    return sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []


def opt(name: str, default: str) -> str:
    a = argv()
    return a[a.index(name) + 1] if name in a else default


def clear_scene() -> None:
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for blocks in (bpy.data.meshes, bpy.data.materials, bpy.data.cameras,
                   bpy.data.lights, bpy.data.objects, bpy.data.armatures):
        for block in list(blocks):
            try:
                blocks.remove(block, do_unlink=True)
            except (RuntimeError, ReferenceError):
                pass


def eevee_name() -> str:
    items = bpy.types.RenderSettings.bl_rna.properties["engine"].enum_items.keys()
    for candidate in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE"):
        if candidate in items:
            return candidate
    return items[0]


def build_rig(size: int) -> tuple[bpy.types.Object, bpy.types.Object]:
    scene = bpy.context.scene
    scene.render.engine = eevee_name()
    scene.render.resolution_x = size
    scene.render.resolution_y = size
    scene.render.resolution_percentage = 100
    scene.render.film_transparent = False
    scene.view_settings.look = "AgX - Punchy"

    world = bpy.data.worlds.new("AuditWorld")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (0.16, 0.17, 0.18, 1.0)
    world.node_tree.nodes["Background"].inputs[1].default_value = 1.0
    scene.world = world

    cam_data = bpy.data.cameras.new("AuditCam")
    cam_data.type = "ORTHO"
    cam = bpy.data.objects.new("AuditCam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam

    # The key light is re-aimed with the camera on every view. A world-fixed rig
    # would leave the back of each asset in shadow, which is precisely the side
    # this audit exists to inspect.
    key_data = bpy.data.lights.new("AuditKey", type="SUN")
    key_data.energy = 3.2
    key = bpy.data.objects.new("AuditKey", key_data)
    scene.collection.objects.link(key)

    fill_data = bpy.data.lights.new("AuditFill", type="SUN")
    fill_data.energy = 1.1
    fill = bpy.data.objects.new("AuditFill", fill_data)
    fill.rotation_euler = (math.radians(115.0), 0.0, math.radians(35.0))
    scene.collection.objects.link(fill)
    return cam, key


def imported_meshes() -> list[bpy.types.Object]:
    return [o for o in bpy.context.scene.objects if o.type == "MESH"]


def vertex_key(co: Vector) -> tuple[int, int, int]:
    return (round(co.x * 1e5), round(co.y * 1e5), round(co.z * 1e5))


def is_closed_shell(bm: bmesh.types.BMesh) -> bool:
    """True when every welded edge borders exactly two faces (F-109).

    These meshes are unwelded face soup, so bmesh's own ``edge.is_manifold``
    is useless here — it reads every edge as non-manifold whether the surface
    is a closed shell or a flat sheet. Welding vertices by position first (the
    same key ``geometry_report`` uses for its duplicate-vertex count) recovers
    the real topology: a closed shell's every edge then borders exactly two
    faces, while an open sheet — a hull plank, a sail, a cap rail — has at
    least one edge that borders only one, its boundary.
    """
    edge_face_counts: dict[tuple, int] = {}
    for f in bm.faces:
        keys = [vertex_key(v.co) for v in f.verts]
        for i in range(len(keys)):
            a, b = keys[i], keys[(i + 1) % len(keys)]
            edge = (a, b) if a < b else (b, a)
            edge_face_counts[edge] = edge_face_counts.get(edge, 0) + 1
    return bool(edge_face_counts) and all(count == 2 for count in edge_face_counts.values())


def bounds(objs: list[bpy.types.Object]) -> tuple[Vector, Vector]:
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for o in objs:
        for corner in o.bound_box:
            w = o.matrix_world @ Vector(corner)
            lo = Vector((min(lo[i], w[i]) for i in range(3)))
            hi = Vector((max(hi[i], w[i]) for i in range(3)))
    return lo, hi


def aim(obj: bpy.types.Object, frm: Vector, to: Vector) -> None:
    d = (frm - to).normalized()
    obj.location = frm
    obj.rotation_euler = d.to_track_quat("Z", "Y").to_euler()


def render_to_array(size: int) -> np.ndarray:
    bpy.ops.render.render()
    img = bpy.data.images["Render Result"]
    # Render Result pixels are not directly readable; round-trip through a copy.
    tmp = Path(bpy.app.tempdir) / "audit_view.png"
    img.save_render(filepath=str(tmp))
    loaded = bpy.data.images.load(str(tmp))
    arr = np.array(loaded.pixels[:], dtype=np.float32).reshape(size, size, 4)
    bpy.data.images.remove(loaded)
    return arr[::-1]  # Blender rows run bottom-up


def geometry_report(objs: list[bpy.types.Object], lo: Vector, hi: Vector) -> dict:
    """Numeric checks for the defects a single front view cannot show."""
    tris = 0
    polys = 0
    inverted_objects: list[str] = []
    open_surface_objects: list[str] = []
    duplicate_verts = 0
    total_verts = 0
    non_manifold = 0
    degenerate = 0
    loose_verts = 0
    smooth_faces = 0
    ngons = 0
    unapplied = []
    materials: set[str] = set()

    for o in objs:
        s = o.matrix_world.to_scale()
        if any(abs(c - 1.0) > 1e-4 for c in s):
            unapplied.append(f"{o.name} scale={tuple(round(c,4) for c in s)}")
        for slot in o.material_slots:
            if slot.material:
                materials.add(slot.material.name)

        bm = bmesh.new()
        bm.from_mesh(o.data)
        bm.transform(o.matrix_world)
        bm.normal_update()

        polys += len(bm.faces)
        for f in bm.faces:
            n = len(f.verts)
            tris += max(n - 2, 0)
            if n > 4:
                ngons += 1
            if f.calc_area() < 1e-9:
                degenerate += 1
            if f.smooth:
                smooth_faces += 1
        non_manifold += sum(1 for e in bm.edges if not e.is_manifold)
        loose_verts += sum(1 for v in bm.verts if not v.link_faces)

        # Inverted normals, measured by signed volume rather than by
        # recalc_face_normals. These meshes are built as unwelded face soup, so
        # almost every edge reads as non-manifold and recalc has no connected
        # surface to reason about — it reports nonsense. The divergence theorem
        # does not care about welding: sum (n . c) * area over a closed shell is
        # positive when the shell faces outward, negative when it is inside out.
        #
        # That sum only means "inside out" for a CLOSED shell (F-109). For an
        # open sheet — a hull plank, a sail, a cap rail — it is dominated by
        # where the sheet sits relative to the world origin rather than by
        # which way it faces, so it false-positives on correct back/rim/
        # underside faces and can just as easily miss a real inversion on the
        # far side of the origin. `is_closed_shell` decides which test applies;
        # an open sheet's winding is judged by its generator instead
        # (`WINDING_LOG` in `build_extraction_ship_set.py` is the worked
        # example), never by this audit.
        if is_closed_shell(bm):
            vol = 0.0
            for f in bm.faces:
                vol += f.normal.dot(f.calc_center_median()) * f.calc_area()
            if vol < 0:
                inverted_objects.append(o.name)
        else:
            open_surface_objects.append(o.name)

        # Unwelded duplicates: how many vertices sit on top of another one.
        seen: set[tuple[int, int, int]] = set()
        dupes = 0
        for v in bm.verts:
            k = vertex_key(v.co)
            if k in seen:
                dupes += 1
            seen.add(k)
        duplicate_verts += dupes
        total_verts += len(bm.verts)
        bm.free()

    size = hi - lo
    return {
        "triangles": tris,
        "polygons": polys,
        "inside_out_objects": inverted_objects,
        "open_surface_objects": open_surface_objects,
        "duplicate_vertices": duplicate_verts,
        "vertices": total_verts,
        "non_manifold_edges": non_manifold,
        "degenerate_faces": degenerate,
        "loose_vertices": loose_verts,
        "smooth_shaded_faces": smooth_faces,
        "ngons": ngons,
        "unapplied_transforms": unapplied,
        "materials": sorted(materials),
        "dimensions_m": [round(c, 4) for c in size],
        "origin_offset_m": [round(lo.x + size.x / 2, 4), round(lo.y + size.y / 2, 4), round(lo.z, 4)],
        "min_z_m": round(lo.z, 4),
        "objects": len(objs),
    }


def pending_glbs(glbs: list[Path], assets_root: Path, report: dict[str, dict]) -> tuple[list[Path], list[Path]]:
    """Which GLBs need (re)rendering, and which of those are stale re-renders (F-110).

    The ledger keys on the asset's path, but "already in the ledger" and "still
    matches what's on disk" are not the same claim. An asset is pending if it
    has never been recorded, or if its current mtime disagrees with the mtime
    its ledger entry was recorded under -- a re-export into the same path (a
    fix, most often) must be re-rendered, not silently skipped and reported as
    if the old geometry were still current.
    """
    mtimes = {g: g.stat().st_mtime for g in glbs}
    pending = [g for g in glbs if report.get(g.relative_to(assets_root).as_posix(), {}).get("_source_mtime") != mtimes[g]]
    stale = [g for g in pending if g.relative_to(assets_root).as_posix() in report]
    return pending, stale


def main() -> None:
    root = Path(__file__).resolve().parents[2] if (Path(__file__).resolve().parents[2] / "assets").exists() \
        else Path("/Users/sequoyahgeber/Desktop/MIRE")
    outdir = Path(opt("--outdir", str(root / "assets" / "audit")))
    size = int(opt("--size", "240"))
    only = opt("--only", "")

    glbs = sorted(p for p in (root / "assets").rglob("*.glb") if "/audit/" not in str(p))
    if only:
        glbs = [p for p in glbs if only in str(p)]
    sheets = outdir / "sheets"
    sheets.mkdir(parents=True, exist_ok=True)

    # Checkpoint as we go. A 224-asset sweep takes minutes, and anything that
    # only writes its results at the end throws all of them away when it is
    # interrupted. Each asset is appended to a JSONL the moment it is finished,
    # and a re-run skips whatever is already in there — so stopping this script
    # costs at most the one asset in flight, and resuming costs nothing.
    ledger = outdir / "geometry_report.jsonl"
    report: dict[str, dict] = {}
    if ledger.exists():
        for line in ledger.read_text().splitlines():
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue  # a torn final line from a hard kill
            report.update(row)
        print(f"resuming: {len(report)} assets already done")

    pending, stale = pending_glbs(glbs, root / "assets", report)
    mtimes = {g: g.stat().st_mtime for g in glbs}
    if stale:
        print(f"{len(stale)} asset(s) changed since their last audit; re-rendering: "
              + ", ".join(g.relative_to(root / "assets").as_posix() for g in stale))
    if not pending:
        print("nothing to do; every asset is already in the ledger and unchanged")
    clear_scene()
    cam, key = build_rig(size)

    def record(key: str, value: dict, mtime: float) -> None:
        value["_source_mtime"] = mtime
        report[key] = value
        with ledger.open("a") as handle:
            handle.write(json.dumps({key: value}) + "\n")
            handle.flush()

    for index, glb in enumerate(pending, 1):
        rel = glb.relative_to(root / "assets").as_posix()
        mtime = mtimes[glb]
        for o in list(bpy.context.scene.objects):
            if o.type not in {"CAMERA", "LIGHT"}:
                bpy.data.objects.remove(o, do_unlink=True)
        try:
            bpy.ops.import_scene.gltf(filepath=str(glb))
        except Exception as exc:  # noqa: BLE001 - a broken export is a finding
            record(rel, {"error": f"import failed: {exc}"}, mtime)
            continue

        objs = imported_meshes()
        if not objs:
            record(rel, {"error": "no mesh objects in export"}, mtime)
            continue

        lo, hi = bounds(objs)
        centre = (lo + hi) * 0.5
        radius = max((hi - lo).length * 0.5, 1e-3)
        cam.data.ortho_scale = radius * 2.0 * MARGIN
        dist = radius * 4.0

        views = []
        for az in AZIMUTHS:
            a, e = math.radians(az), math.radians(ELEVATION)
            offset = Vector((math.cos(a) * math.cos(e), math.sin(a) * math.cos(e), math.sin(e))) * dist
            aim(cam, centre + offset, centre)
            key.rotation_euler = cam.rotation_euler
            views.append(render_to_array(size))
        for offset in (Vector((0, 0, dist)), Vector((0, 0, -dist))):
            aim(cam, centre + offset, centre)
            key.rotation_euler = cam.rotation_euler
            views.append(render_to_array(size))

        rows = math.ceil(len(views) / COLUMNS)
        sheet = np.zeros((rows * size, COLUMNS * size, 4), dtype=np.float32)
        sheet[..., 3] = 1.0
        for i, view in enumerate(views):
            r, c = divmod(i, COLUMNS)
            sheet[r * size:(r + 1) * size, c * size:(c + 1) * size] = view

        name = rel.replace("/", "__").removesuffix(".glb")
        out = bpy.data.images.new(name, width=sheet.shape[1], height=sheet.shape[0], alpha=True)
        out.pixels = sheet[::-1].ravel().tolist()
        out.filepath_raw = str(sheets / f"{name}.png")
        out.file_format = "PNG"
        out.save()
        bpy.data.images.remove(out)

        entry = geometry_report(objs, lo, hi)
        entry["sheet"] = f"sheets/{name}.png"
        record(rel, entry, mtime)
        print(f"[{index}/{len(pending)}] {rel}", flush=True)

    # The JSON is a convenience view of the ledger, rewritten from it each run.
    (outdir / "geometry_report.json").write_text(json.dumps(report, indent=2, sort_keys=True))
    print(f"\nWrote {len(report)} entries to {outdir/'geometry_report.json'}")
    print("View order: azimuth 0/45/90/135/180 (row 0), 225/270/315, top, bottom (row 1)")


if __name__ == "__main__":
    main()
