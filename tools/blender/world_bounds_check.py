"""Regression guard for F-094: `mire_art.world_bounds()` must measure actual
mesh vertices through `matrix_world`, not the object's local-space
`bound_box`.

Run:
    /Applications/Blender.app/Contents/MacOS/Blender --background --python \
        tools/blender/world_bounds_check.py

The bug this guards: `world_bounds` used to transform the eight corners of
each object's `bound_box`. That box is axis-aligned in the object's LOCAL
space, so for any rotated object -- every `cylinder_between`/`tapered_between`
cone MIRE builds is one -- the transformed corners enclose a volume strictly
larger than the geometry inside it. `ground_and_centre` then sat that
inflated box on z=0 and left the real mesh floating above it: up to 76 mm on
the flora kit, and it would have shipped calling itself grounded, because the
only check available was made with the same wrong ruler. The finding also
reports `bound_box` staying stale immediately after `bpy.ops.object.join()`
on the Blender version that found it, even through a depsgraph update --
that variant put a willow at 6.97 m tall and 800 mm underground; section 4
below checks that codepath directly, though Blender 5.2.0 (this repo's
pinned version) was not observed to reproduce the staleness itself.

This does not just re-run the fixed implementation and check it returns
*something* -- that would pass whether or not the fix is present. It rebuilds
the pre-fix bound_box-corners measurement inline (never imported from
mire_art, which no longer has it) so it can assert the fixed world_bounds()
actually beats the old ruler on identical geometry, then checks
ground_and_centre() and the object.join() case against known ground truth.
"""

import pathlib
import sys

sys.path.append(str(pathlib.Path(__file__).resolve().parent))

import bpy  # noqa: E402  (Blender's module; only importable once the interpreter is Blender's)
from mathutils import Euler, Vector  # noqa: E402

from mire_art import (  # noqa: E402
    ground_and_centre,
    mat,
    reset_materials,
    tapered_between,
    world_bounds,
)

failures: list[str] = []


def check(label: str, condition: bool) -> None:
    if not condition:
        failures.append(label)


def bound_box_bounds(objects: list[bpy.types.Object]) -> tuple[Vector, Vector]:
    """The pre-fix measurement: transform local `bound_box` corners through
    `matrix_world` instead of measuring vertices. Kept here, not in
    mire_art.py, purely to give this check the old wrong ruler to compare
    the fix against."""
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for obj in objects:
        if obj.type != "MESH":
            continue
        for corner in obj.bound_box:
            world = obj.matrix_world @ Vector(corner)
            lo = Vector((min(lo[i], world[i]) for i in range(3)))
            hi = Vector((max(hi[i], world[i]) for i in range(3)))
    return lo, hi


# Fresh scene: strip Blender's default cube/camera/light and any leftover
# materials so measurements below are exact, not "plus whatever was already
# there."
reset_materials()
for obj in list(bpy.data.objects):
    bpy.data.objects.remove(obj, do_unlink=True)
for stale in list(bpy.data.materials):
    bpy.data.materials.remove(stale)

wood = mat("wood_bark")

# 1. A cone rotated diagonally off every axis -- the shape every
#    cylinder_between()/tapered_between() produces, and the one that hid the
#    bug (a boxy asset built from box() alone never rotates its local axes,
#    so it never showed the gap). Its local bound_box is a tight box around
#    the UNROTATED cone; rotating those eight corners through matrix_world
#    traces a box strictly larger than the rotated geometry actually is.
branch = tapered_between(
    "Branch", (0.0, 0.0, 0.0), (1.0, 1.0, 1.0), 0.2, 0.05, wood, vertices=8,
)
bpy.context.view_layer.update()

fixed_lo, fixed_hi = world_bounds([branch])
buggy_lo, buggy_hi = bound_box_bounds([branch])
fixed_size = fixed_hi - fixed_lo
buggy_size = buggy_hi - buggy_lo
check(
    "a diagonally rotated cone: the old bound_box-corner ruler measures a strictly larger box than "
    f"vertex measurement does (fixed size {tuple(round(v, 4) for v in fixed_size)}, "
    f"buggy size {tuple(round(v, 4) for v in buggy_size)})",
    buggy_size.length > fixed_size.length + 1e-4,
)

# 2. world_bounds() must exactly match the true extent of the mesh's own
#    vertices in world space -- not merely "smaller than the buggy box".
true_lo = Vector((1e9, 1e9, 1e9))
true_hi = Vector((-1e9, -1e9, -1e9))
matrix = branch.matrix_world
for vertex in branch.data.vertices:
    world = matrix @ vertex.co
    true_lo = Vector((min(true_lo[i], world[i]) for i in range(3)))
    true_hi = Vector((max(true_hi[i], world[i]) for i in range(3)))
check("world_bounds() matches the true vertex extent exactly (low corner)", (fixed_lo - true_lo).length < 1e-6)
check("world_bounds() matches the true vertex extent exactly (high corner)", (fixed_hi - true_hi).length < 1e-6)

# 3. ground_and_centre() must seat the ACTUAL lowest vertex at z=0, not the
#    inflated box's lowest corner -- this is what "76 mm of air" was. A single
#    cone rotated straight off the world origin happens not to show this on
#    its z-axis (to_track_quat("Z", "Y") keeps that cone's local X exactly
#    horizontal, so the corner-inflation cancels out on z alone) -- exactly
#    the kind of case-specific escape that let this ship once. Composing a
#    second, independent rotation on top -- the way fork()'s branches compose
#    rotations down a parent chain -- is what actually reproduces the float:
#    two arbitrary rotations stacked breaks that cancellation and inflates
#    all three axes, the shape a real flora asset's hierarchy has. (ground_and_
#    centre() only moves objects with no parent, so the second rotation is
#    composed directly onto this object's own quaternion rather than via an
#    actual parent, or ground_and_centre would skip it entirely.)
loose = tapered_between(
    "Loose", (0.0, 0.0, 2.0), (0.6, 0.19, 3.0), 0.25, 0.08, wood, vertices=8,
)
loose.rotation_quaternion = Euler((0.6, 0.9, 0.3), "XYZ").to_quaternion() @ loose.rotation_quaternion
bpy.context.view_layer.update()
ground_and_centre([loose])
bpy.context.view_layer.update()
lowest_z = min((loose.matrix_world @ v.co).z for v in loose.data.vertices)
check(
    f"ground_and_centre() seats the real mesh at z=0, not floating above it (lowest vertex z={lowest_z:.6f})",
    abs(lowest_z) < 1e-4,
)

# 4. The finding also reports bound_box staying stale immediately after
#    bpy.ops.object.join(), even through a depsgraph update, on the Blender
#    version that found it -- that variant put a willow at 6.97 m tall and
#    800 mm underground. Blender 5.2.0 (this repo's pinned version) was
#    checked directly and does not reproduce that staleness -- bound_box
#    already reads the merged geometry correctly immediately after join, with
#    no update call needed -- so this assertion cannot regress against a
#    second wrong-ruler bug the way sections 1-3 do. It stays as a direct
#    ground-truth check of the documented failure shape: world_bounds()
#    measures vertices, which join() writes straight into the surviving
#    object's mesh data, so there is nothing in this codepath left to go
#    stale even if a future Blender version's bound_box regresses.
part_a = tapered_between("JoinA", (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 0.2, 0.2, wood, vertices=8)
part_b = tapered_between("JoinB", (0.0, 0.0, 1.0), (0.0, 0.0, 5.0), 0.2, 0.05, wood, vertices=8)
bpy.context.view_layer.update()
bpy.ops.object.select_all(action="DESELECT")
part_a.select_set(True)
part_b.select_set(True)
bpy.context.view_layer.objects.active = part_a
bpy.ops.object.join()

joined_lo, joined_hi = world_bounds([part_a])
check(
    f"world_bounds() reads the joined mesh's real top immediately after join (top z={joined_hi.z:.4f}, expected ~5.0)",
    abs(joined_hi.z - 5.0) < 0.05,
)
check(
    f"world_bounds() reads the joined mesh's real base immediately after join (base z={joined_lo.z:.4f}, expected ~0.0)",
    abs(joined_lo.z - 0.0) < 0.05,
)

verdict = "PASS" if not failures else f"FAIL ({len(failures)})"
print(f"WORLD_BOUNDS_CHECK {verdict}")
for failure in failures:
    print(f"  - {failure}")

sys.exit(1 if failures else 0)
