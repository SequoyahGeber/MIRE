"""Build MIRE's paired world/viewmodel tool and weapon set (A-004, refreshed by A-004R, extended by A-021S).

Run with:
  Blender --background --python tools/blender/build_tool_weapon_set.py

Eleven shared designs produce 22 portable GLBs. World and viewmodel exports use
the same geometry and materials so their silhouettes cannot drift.

A-004R replaced the original flat-extrusion construction. Heads are now built as
ground profiles — a silhouette ring at the mid-plane with inset front and back
rings — so a blade actually tapers to its edge and a poll actually stays square.
Hafts are swept oval shafts with per-point radii instead of straight cylinders.
Overall dimensions stay within a few centimetres of A-004 so grip transforms
authored against the old exports still frame correctly.

A-021S added the iron sword and one new primitive with it. A ground profile insets
its walls *toward the profile's centroid*, which is right for a head that is about
as tall as it is long, and wrong for a blade a metre long: near the point the pull
is almost entirely downward, so the section there stays a square wall instead of
grinding to an edge. A sword is therefore lofted through explicit cross-sections
(`lofted`) rather than profiled.
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path
from typing import Callable, Sequence

import bpy

sys.path.append(str(Path(__file__).resolve().parent))
from mire_art import (  # noqa: E402
    assign, cone, cylinder_between, eevee_engine, ico, look_at, make_consistent, mat,
    mesh_object, move_to_collection, radial, around, reset_materials, tapered_between, world_bounds,
)
from godot_import_lock import import_cache_guard  # noqa: E402
from mathutils import Vector


def box(
    name: str,
    location: tuple[float, float, float],
    dimensions: tuple[float, float, float],
    mat: bpy.types.Material,
    rotation: tuple[float, float, float] = (0.0, 0.0, 0.0),
    bevel: float = 0.0,
) -> bpy.types.Object:
    """Bevel-free box, overriding ``mire_art.box`` on purpose (D-124).

    This family's tracker row claims a byte-identical rebuild; the bevel
    modifier changes float bytes between otherwise identical background
    exports on Apple Silicon (F-057). ``bevel`` is accepted and ignored so the
    one call site (``Cleaver_Bolster``) reads unchanged.
    """
    bpy.ops.mesh.primitive_cube_add(location=location, rotation=rotation)
    obj = bpy.context.object
    obj.name = name
    obj.scale = (dimensions[0] * 0.5, dimensions[1] * 0.5, dimensions[2] * 0.5)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return assign(obj, mat)


ROOT = Path(__file__).resolve().parents[2]
ASSET_DIR = ROOT / "assets" / "tools_weapons"
SOURCE_DIR = ROOT / "assets" / "source"
EXPORT_DIR = ASSET_DIR / "exports"
PREVIEW_DIR = ASSET_DIR / "preview"

DESIGNS = [
    "wooden_axe",
    "stone_axe",
    "wooden_pickaxe",
    "stone_pickaxe",
    "iron_axe",
    "iron_pickaxe",
    "bogsilver_axe",
    "bogsilver_pickaxe",
    "wellglass_axe",
    "wellglass_pickaxe",
    "cleaver",
    "skewer",
    "short_bow",
    "arrow",
    "repair_hammer",
    "iron_sword",
]
EXPECTED_NAMES = [f"{design}_{presentation}" for design in DESIGNS for presentation in ("world", "viewmodel")]
#: Preview grid. Sixteen designs across four rows of four reads better than six-wide, and keeps each
#: tier's axe and pickaxe adjacent instead of wrapping between rows.
PREVIEW_COLUMNS = 4
PREVIEW_COLUMN_SPACING = 2.75
PREVIEW_ROW_SPACING = 3.4


# ---------------------------------------------------------------------------
# Mesh primitives
# ---------------------------------------------------------------------------


def _fanned(value: float | Sequence[float], count: int) -> list[float]:
    if isinstance(value, (int, float)):
        return [float(value)] * count
    values = list(value)
    if len(values) != count:
        raise ValueError(f"expected {count} values, got {len(values)}")
    return [float(v) for v in values]


def ground_profile(
    name: str,
    points_xz: list[tuple[float, float]],
    half_thickness: float | Sequence[float],
    bevels: float | Sequence[float],
    mat: bpy.types.Material,
    y_offset: float = 0.0,
    center: tuple[float, float] | None = None,
) -> bpy.types.Object:
    """A silhouette outline with inset front and back faces.

    `bevels[i]` is how far, **in metres**, the front and back rings step back
    from the silhouette at that point: 0 leaves a square wall (a poll, a spine, a
    tang) and 0.05–0.09 grinds the section down to an edge. Metres rather than a
    fraction of the way to the centre, because a fractional pull scales with how
    far a point happens to sit from the centroid, which rounds off exactly the
    corners — poll, spine, heel — that give a head its silhouette.
    """
    count = len(points_xz)
    if center is None:
        center_x = sum(x for x, _ in points_xz) / count
        center_z = sum(z for _, z in points_xz) / count
    else:
        center_x, center_z = center
    thicknesses = _fanned(half_thickness, count)
    bevel_values = _fanned(bevels, count)

    silhouette: list[tuple[float, float, float]] = []
    back: list[tuple[float, float, float]] = []
    front: list[tuple[float, float, float]] = []
    for index, (x, z) in enumerate(points_xz):
        toward = Vector((center_x - x, center_z - z))
        span = toward.length
        step = min(bevel_values[index], span * 0.85)
        direction = toward.normalized() if span > 1e-6 else Vector((0.0, 0.0))
        inner_x = x + direction.x * step
        inner_z = z + direction.y * step
        silhouette.append((x, y_offset, z))
        back.append((inner_x, y_offset - thicknesses[index], inner_z))
        front.append((inner_x, y_offset + thicknesses[index], inner_z))

    vertices = silhouette + back + front
    faces: list[tuple[int, ...]] = [
        tuple(range(count, count * 2)),
        tuple(range(count * 3 - 1, count * 2 - 1, -1)),
    ]
    for index in range(count):
        following = (index + 1) % count
        faces.append((index, following, count + following, count + index))
        faces.append((following, index, count * 2 + index, count * 2 + following))
    return mesh_object(name, vertices, faces, mat)


def _path_frames(path: list[Vector]) -> list:
    frames = []
    for index, point in enumerate(path):
        if index == 0:
            tangent = path[1] - path[0]
        elif index == len(path) - 1:
            tangent = path[-1] - path[-2]
        else:
            tangent = path[index + 1] - path[index - 1]
        frames.append(tangent.normalized().to_track_quat("Z", "Y"))
    return frames


def swept_shaft(
    name: str,
    path: list[tuple[float, float, float]],
    radii: float | Sequence[float],
    mat: bpy.types.Material,
    sides: int = 8,
    squash: float = 1.0,
    capped: bool = True,
) -> bpy.types.Object:
    """A tube swept along a polyline with a radius per path point.

    `squash` scales the local Y axis, giving hafts an oval section that reads as
    a grip you could actually hold rather than a dowel.
    """
    points = [Vector(p) for p in path]
    count = len(points)
    values = _fanned(radii, count)
    frames = _path_frames(points)

    vertices: list[tuple[float, float, float]] = []
    for index, point in enumerate(points):
        radius = values[index]
        for side in range(sides):
            angle = math.tau * side / sides
            local = Vector((math.cos(angle) * radius, math.sin(angle) * radius * squash, 0.0))
            vertices.append(tuple(point + frames[index] @ local))

    faces: list[tuple[int, ...]] = []
    for index in range(count - 1):
        for side in range(sides):
            following = (side + 1) % sides
            faces.append(
                (
                    index * sides + side,
                    index * sides + following,
                    (index + 1) * sides + following,
                    (index + 1) * sides + side,
                )
            )
    if capped:
        faces.append(tuple(range(sides - 1, -1, -1)))
        faces.append(tuple(range((count - 1) * sides, count * sides)))
    return mesh_object(name, vertices, faces, mat)


def lofted(
    name: str,
    rings: list[list[tuple[float, float, float]]],
    mat: bpy.types.Material,
    apex: tuple[float, float, float] | None = None,
    cap_start: bool = True,
) -> bpy.types.Object:
    """A solid lofted through explicit cross-sections, optionally closing on a point.

    `swept_shaft` sweeps one circular section along a path; a blade needs a
    *changing* section — broad and thin at the shoulder, narrow and stiff near the
    point, with a fuller channel down the middle — so the sections are given
    outright. `apex` fans the last ring into a single vertex, which is what makes a
    point a point rather than a small flat.
    """
    sides = len(rings[0])
    vertices: list[tuple[float, float, float]] = []
    for ring in rings:
        if len(ring) != sides:
            raise ValueError(f"{name}: every ring needs {sides} points, got {len(ring)}")
        vertices.extend(ring)

    faces: list[tuple[int, ...]] = []
    for index in range(len(rings) - 1):
        for side in range(sides):
            following = (side + 1) % sides
            faces.append(
                (
                    index * sides + side,
                    index * sides + following,
                    (index + 1) * sides + following,
                    (index + 1) * sides + side,
                )
            )
    if cap_start:
        faces.append(tuple(range(sides - 1, -1, -1)))
    last = (len(rings) - 1) * sides
    if apex is None:
        faces.append(tuple(range(last, last + sides)))
    else:
        vertices.append(apex)
        tip = len(vertices) - 1
        for side in range(sides):
            faces.append((last + side, last + (side + 1) % sides, tip))
    return mesh_object(name, vertices, faces, mat)


def _path_lengths(path: list[Vector]) -> list[float]:
    lengths = [0.0]
    for index in range(1, len(path)):
        lengths.append(lengths[-1] + (path[index] - path[index - 1]).length)
    return lengths


def sample_path(path: list[tuple[float, float, float]], t: float) -> tuple[Vector, Vector, int]:
    points = [Vector(p) for p in path]
    lengths = _path_lengths(points)
    target = lengths[-1] * min(max(t, 0.0), 1.0)
    for index in range(1, len(points)):
        if target <= lengths[index] or index == len(points) - 1:
            span = lengths[index] - lengths[index - 1]
            local = 0.0 if span == 0.0 else (target - lengths[index - 1]) / span
            position = points[index - 1].lerp(points[index], local)
            tangent = (points[index] - points[index - 1]).normalized()
            return position, tangent, index
    raise RuntimeError("unreachable")


def path_radius(path: list[tuple[float, float, float]], radii: Sequence[float], t: float) -> float:
    points = [Vector(p) for p in path]
    lengths = _path_lengths(points)
    target = lengths[-1] * min(max(t, 0.0), 1.0)
    for index in range(1, len(points)):
        if target <= lengths[index] or index == len(points) - 1:
            span = lengths[index] - lengths[index - 1]
            local = 0.0 if span == 0.0 else (target - lengths[index - 1]) / span
            return radii[index - 1] + (radii[index] - radii[index - 1]) * local
    raise RuntimeError("unreachable")


def wrap_band(
    name: str,
    path: list[tuple[float, float, float]],
    radii: Sequence[float],
    t: float,
    height: float,
    mat: bpy.types.Material,
    swell: float = 1.16,
    squash: float = 1.0,
    sides: int = 8,
) -> bpy.types.Object:
    """One turn of cord or leather sitting proud of a swept shaft."""
    position, tangent, _ = sample_path(path, t)
    radius = path_radius(path, radii, t) * swell
    start = position - tangent * (height * 0.5)
    end = position + tangent * (height * 0.5)
    return swept_shaft(
        name,
        [tuple(start), tuple(position), tuple(end)],
        [radius * 0.88, radius, radius * 0.88],
        mat,
        sides,
        squash,
    )


# ---------------------------------------------------------------------------
# Shared sub-assemblies
# ---------------------------------------------------------------------------


def add_haft(
    mats: dict[str, bpy.types.Material],
    path: list[tuple[float, float, float]],
    radii: Sequence[float],
    wrap_range: tuple[float, float] = (0.06, 0.34),
    wrap_count: int = 6,
    squash: float = 0.80,
    sides: int = 9,
    wrap_key: str = "wrap",
    butt_key: str = "handle_dark",
) -> None:
    swept_shaft("Handle", path, radii, mats["handle"], sides, squash)
    start, tangent, _ = sample_path(path, 0.0)
    butt_radius = path_radius(path, radii, 0.0)
    swept_shaft(
        "Handle_Butt",
        [tuple(start - tangent * 0.055), tuple(start - tangent * 0.012), tuple(start + tangent * 0.03)],
        [butt_radius * 0.86, butt_radius * 1.30, butt_radius * 1.12],
        mats[butt_key],
        sides,
        squash,
    )
    low, high = wrap_range
    for index in range(wrap_count):
        t = low + (high - low) * index / max(wrap_count - 1, 1)
        wrap_band(
            f"Grip_Wrap_{index + 1}",
            path,
            radii,
            t,
            0.036,
            mats[wrap_key],
            1.17,
            squash,
            sides,
        )


def add_lashing(
    mats: dict[str, bpy.types.Material],
    path: list[tuple[float, float, float]],
    radii: Sequence[float],
    positions: Sequence[float],
    knot_at: float | None = None,
    squash: float = 0.80,
) -> None:
    """Cord binding a head to a haft: crossed turns plus a visible knot."""
    for index, t in enumerate(positions):
        position, tangent, _ = sample_path(path, t)
        radius = path_radius(path, radii, t) * 1.45
        lean = tangent.orthogonal().normalized() * 0.028 * (1 if index % 2 == 0 else -1)
        swept_shaft(
            f"Lashing_{index + 1}",
            [tuple(position - tangent * 0.026 + lean), tuple(position), tuple(position + tangent * 0.026 - lean)],
            [radius * 0.90, radius, radius * 0.90],
            mats["rope"],
            7,
            squash,
        )
    if knot_at is not None:
        position, tangent, _ = sample_path(path, knot_at)
        radius = path_radius(path, radii, knot_at)
        ico("Lashing_Knot", tuple(position + Vector((0.0, -radius * 1.45, 0.0))), (0.035, 0.030, 0.030), mats["rope"])


def add_rivets(
    mats: dict[str, bpy.types.Material],
    spots: Sequence[tuple[float, float]],
    half_thickness: float,
    mat_key: str = "iron_light",
    radius: float = 0.026,
) -> None:
    for index, (x, z) in enumerate(spots):
        for side_index, side in enumerate((-1.0, 1.0)):
            cone(
                f"Rivet_{index + 1}_{side_index + 1}",
                radius,
                radius * 0.72,
                0.022,
                (x, side * (half_thickness + 0.008), z),
                mats[mat_key],
                6,
                (math.radians(90), 0.0, 0.0),
            )


# ---------------------------------------------------------------------------
# Designs
# ---------------------------------------------------------------------------


AXE_HAFT = [(-0.075, 0.0, 0.03), (-0.045, 0.0, 0.36), (-0.005, 0.0, 0.70), (0.035, 0.0, 0.99), (0.055, 0.0, 1.24)]
AXE_RADII = [0.052, 0.047, 0.045, 0.050, 0.044]


def build_wooden_axe(mats: dict[str, bpy.types.Material]) -> None:
    add_haft(mats, AXE_HAFT, AXE_RADII, (0.05, 0.33), 6)
    # Short poll, narrow neck, bit flaring as it sweeps forward: the flare is the
    # whole silhouette, and a head of even height reads as a mallet from any angle.
    # Body and edge are two shapes butted along a seam rather than one shape with a
    # bright strip laid over it — an overlaid strip loses to the body's own
    # silhouette at exactly the rim where it is supposed to be visible.
    ground_profile(
        "Wooden_Axe_Head",
        [
            (-0.150, 1.080),
            (-0.090, 1.048),
            (0.060, 1.040),
            (0.190, 1.010),
            (0.330, 0.958),
            (0.430, 0.926),
            (0.470, 1.147),
            (0.428, 1.352),
            (0.325, 1.338),
            (0.185, 1.288),
            (0.060, 1.255),
            (-0.090, 1.248),
            (-0.155, 1.215),
        ],
        [0.088, 0.090, 0.082, 0.068, 0.052, 0.040, 0.032, 0.040, 0.052, 0.068, 0.082, 0.090, 0.088],
        [0.000, 0.000, 0.018, 0.034, 0.050, 0.060, 0.062, 0.060, 0.050, 0.034, 0.018, 0.000, 0.000],
        mats["wood_blade"],
        center=(0.080, 1.147),
    )
    ground_profile(
        "Wooden_Axe_Edge",
        [(0.430, 0.926), (0.548, 0.985), (0.580, 1.145), (0.548, 1.305), (0.428, 1.352), (0.470, 1.147)],
        [0.040, 0.026, 0.022, 0.026, 0.040, 0.032],
        [0.055, 0.070, 0.075, 0.070, 0.055, 0.050],
        mats["wood_cut"],
        center=(0.490, 1.147),
    )
    # A wedge driven into the eye, not side plates: flat plates laid on the cheeks
    # read as dark holes in the head from every three-quarter angle.
    ground_profile(
        "Wooden_Axe_Wedge",
        [(-0.055, 1.205), (0.048, 1.198), (0.052, 1.268), (-0.058, 1.272)],
        [0.052, 0.052, 0.044, 0.044],
        0.008,
        mats["hardwood_dark"],
    )
    add_lashing(mats, AXE_HAFT, AXE_RADII, (0.795, 0.845, 0.895), 0.845)


def build_stone_axe(mats: dict[str, bpy.types.Material]) -> None:
    add_haft(mats, AXE_HAFT, AXE_RADII, (0.05, 0.33), 6)
    # Knapped head: same flared bit, but heavier, blunter, and deliberately
    # asymmetric so it reads as a split cobble rather than a forged tool.
    ground_profile(
        "Stone_Axe_Head",
        [
            (-0.155, 1.090),
            (-0.085, 1.035),
            (0.070, 1.030),
            (0.200, 0.990),
            (0.340, 0.938),
            (0.440, 0.900),
            (0.485, 1.150),
            (0.420, 1.368),
            (0.315, 1.320),
            (0.170, 1.292),
            (0.045, 1.262),
            (-0.090, 1.262),
            (-0.165, 1.212),
        ],
        [0.100, 0.102, 0.094, 0.080, 0.062, 0.048, 0.038, 0.048, 0.062, 0.080, 0.094, 0.102, 0.100],
        [0.000, 0.000, 0.016, 0.030, 0.046, 0.056, 0.058, 0.056, 0.046, 0.030, 0.016, 0.000, 0.000],
        mats["stone"],
        center=(0.090, 1.150),
    )
    ground_profile(
        "Stone_Axe_Edge",
        [(0.440, 0.900), (0.568, 0.978), (0.602, 1.148), (0.560, 1.318), (0.420, 1.368), (0.485, 1.150)],
        [0.048, 0.028, 0.024, 0.028, 0.048, 0.038],
        [0.050, 0.068, 0.072, 0.068, 0.050, 0.046],
        mats["stone_edge"],
        center=(0.505, 1.148),
    )
    for index, (x, z, scale) in enumerate(((-0.095, 1.150, 0.048), (0.190, 1.245, 0.042), (0.115, 1.045, 0.038))):
        ico(f"Stone_Flake_{index + 1}", (x, 0.0, z), (scale, 0.100, scale * 1.15), mats["stone_edge"], (0.3, 0.0, 0.2))
    add_lashing(mats, AXE_HAFT, AXE_RADII, (0.780, 0.835, 0.890), 0.835)


#: Forged-axe tiers. The wooden and stone axes above are *knapped-and-lashed*: a wedge of material
#: tied to a stick. From iron up the construction changes, and the construction IS the tier read —
#: the haft passes THROUGH an eye, so there is no lashing, and the head grows a squared poll behind
#: that eye which no lashed head can have. Real felling-axe anatomy, in the order the profile below
#: walks it: poll (the flat back), eye (the hole, with a proud collar), cheek (the tapering side),
#: beard (the bit reaching back down toward the haft), then toe and heel at the ends of the edge.
#:
#: Thinner than stone at every station, because that is the actual advantage of the material and the
#: silhouette should say so. Bogsilver is thinner and longer again, and adds a forged rib down the
#: cheek — one raised line is the whole difference at a glance, and a glance in fog is the test.
FORGED_AXE_TIERS = {
    "iron": {
        "body": "iron",
        "edge": "iron_light",
        "socket": "iron_dark",
        "rivet": "iron_light",
        "reach": 0.268,
        "edge_reach": 0.548,
        "girth": 1.00,
        "rib": False,
    },
    "bogsilver": {
        "body": "bogsilver",
        "edge": "bogsilver_light",
        "socket": "bogsilver_dark",
        "rivet": "bogsilver_light",
        "reach": 0.286,
        "edge_reach": 0.604,
        "girth": 0.88,
        "rib": True,
    },
}


def build_forged_axe(mats: dict[str, bpy.types.Material], tier: str) -> None:
    spec = FORGED_AXE_TIERS[tier]
    add_haft(mats, AXE_HAFT, AXE_RADII, (0.05, 0.33), 6)
    body = mats[spec["body"]]
    reach = spec["reach"]
    girth = spec["girth"]

    # One loop: bottom edge back-to-front, the seam point the bit is butted onto, then the top edge
    # front-to-back. Same order the wooden and stone heads use, so the three read as one family.
    ground_profile(
        f"{tier.title()}_Axe_Head",
        [
            (-0.115, 1.052),
            (-0.010, 1.028),
            (0.130, 0.998),
            (reach, 0.958),
            (reach + 0.056, 1.128),
            (reach, 1.328),
            (0.130, 1.292),
            (-0.010, 1.270),
            (-0.115, 1.248),
        ],
        [
            0.068 * girth, 0.062 * girth, 0.050 * girth, 0.036 * girth,
            0.030 * girth, 0.036 * girth, 0.050 * girth, 0.062 * girth, 0.068 * girth,
        ],
        # Zero at the poll: a square wall is what makes a poll read as a hammer face rather than as
        # the blunt end of a wedge. It grinds away toward the bit.
        [0.000, 0.014, 0.032, 0.048, 0.052, 0.048, 0.032, 0.014, 0.000],
        body,
        center=(0.080, 1.128),
    )
    # The bit, butted along the seam rather than laid over the body — an overlaid bright strip loses
    # to the body's own silhouette at exactly the rim it exists to show (the A-004R lesson).
    ground_profile(
        f"{tier.title()}_Axe_Bit",
        [
            (reach, 0.958),
            (reach + 0.120, 0.888),
            (spec["edge_reach"] - 0.032, 0.972),
            (spec["edge_reach"], 1.128),
            (spec["edge_reach"] - 0.032, 1.284),
            (reach + 0.120, 1.366),
            (reach, 1.328),
            (reach + 0.056, 1.128),
        ],
        [
            0.036 * girth, 0.024 * girth, 0.015 * girth, 0.012 * girth,
            0.015 * girth, 0.024 * girth, 0.036 * girth, 0.030 * girth,
        ],
        [0.030, 0.050, 0.068, 0.072, 0.068, 0.050, 0.030, 0.026],
        mats[spec["edge"]],
        center=(reach + 0.075, 1.128),
    )
    # The eye's collar, proud of the cheeks on both faces. This is the piece that says the haft goes
    # THROUGH the head; without it a forged axe reads as a lashed one whose cord was forgotten.
    swept_shaft(
        f"{tier.title()}_Axe_Socket",
        [(0.030, 0.0, 1.036), (0.040, 0.0, 1.150), (0.048, 0.0, 1.266)],
        [0.076 * girth, 0.070 * girth, 0.065 * girth],
        mats[spec["socket"]],
        8,
        0.88,
    )
    if spec["rib"]:
        # A single forged rib down the cheek, on both faces. Stops at the bevel line so it never
        # crosses onto ground metal, where a raised line would read as a chip.
        for side_index, side in enumerate((-1.0, 1.0)):
            swept_shaft(
                f"{tier.title()}_Axe_Rib_{side_index + 1}",
                [
                    (-0.076, side * 0.056 * girth, 1.140),
                    (0.060, side * 0.048 * girth, 1.136),
                    (0.220, side * 0.034 * girth, 1.130),
                ],
                [0.030, 0.026, 0.015],
                mats[spec["edge"]],
                5,
                0.55,
            )
    add_rivets(mats, ((-0.072, 1.150),), 0.064 * girth, spec["rivet"], 0.022)


def _knapped_facets(
    name: str,
    mats: dict[str, bpy.types.Material],
    spots: Sequence[tuple[float, float, float]],
    half_thickness: float,
) -> None:
    """Conchoidal fracture scars, both faces.

    Volcanic glass does not break along planes the way a mineral does — it breaks in shallow curved
    dishes that ripple outward from the strike point. That is what makes a knapped edge sharper than
    anything forged, and it is the one visual fact that has to survive at flat-shaded low-poly, so
    each scar is a squashed ico standing a hair proud of the blade face rather than a flat decal.
    `spots` are (x, z, radius); every scar is mirrored onto both faces so the blade is never
    one-sided (task 2.1j — look at the back of the asset).
    """
    for index, (x, z, radius) in enumerate(spots):
        for side_index, side in enumerate((-1.0, 1.0)):
            # Shallow and ELONGATED. The first pass used near-spherical icos standing well proud of
            # the face and they rendered as white polka dots — a fracture scar is a dish a few
            # millimetres deep and several centimetres long, so depth is a fifth of the length and
            # the ripple direction is fanned per scar rather than shared.
            ico(
                f"{name}_{index + 1}_{side_index + 1}",
                (x, side * half_thickness * 0.72, z),
                (radius * 1.35, half_thickness * 0.30, radius * 0.72),
                mats["wellglass_light"],
                (0.30 + 0.22 * index, 0.0, 0.55 * (index - 1.5)),
            )


def build_wellglass_axe(mats: dict[str, bpy.types.Material]) -> None:
    """Tier 5. Deliberately NOT a forged head in a new colour.

    The ladder opens with a knapped stone wedge lashed to a stick and closes with a knapped GLASS
    wedge socketed in bogsilver — the two ends of the run rhyme, and the middle three tiers are the
    forged ones between them. It is also the honest construction: nobody forges glass, and real
    hafted obsidian is bedded in a socket and bound, which is exactly what is built here.
    """
    add_haft(mats, AXE_HAFT, AXE_RADII, (0.05, 0.33), 6)

    # Bogsilver hardware first: the socket the glass is bedded into, and the collar behind it.
    swept_shaft(
        "Wellglass_Axe_Socket",
        [(0.024, 0.0, 1.042), (0.036, 0.0, 1.150), (0.046, 0.0, 1.262)],
        [0.070, 0.064, 0.058],
        mats["bogsilver_dark"],
        8,
        0.88,
    )
    ground_profile(
        "Wellglass_Axe_Cradle",
        [
            (-0.088, 1.062),
            (0.108, 1.032),
            (0.166, 1.078),
            (0.166, 1.206),
            (0.108, 1.268),
            (-0.088, 1.242),
        ],
        [0.056, 0.052, 0.044, 0.044, 0.052, 0.056],
        [0.000, 0.014, 0.020, 0.020, 0.014, 0.000],
        mats["bogsilver"],
        center=(0.040, 1.150),
    )

    # The blade. Thicker at the bedded end and grinding to nothing at the edge, with the bit swept
    # slightly forward of the socket so the glass — not the metal — is what meets the wood.
    ground_profile(
        "Wellglass_Axe_Blade",
        [
            (0.150, 1.020),
            (0.320, 0.944),
            (0.452, 0.912),
            (0.512, 1.150),
            (0.452, 1.386),
            (0.320, 1.352),
            (0.150, 1.282),
        ],
        [0.046, 0.036, 0.026, 0.019, 0.026, 0.036, 0.046],
        [0.010, 0.038, 0.054, 0.060, 0.054, 0.038, 0.010],
        mats["wellglass_dark"],
        center=(0.300, 1.150),
    )
    # The edge itself: the fracture is fresh, so it is the brightest thing on the tool and the only
    # place `wellglass_light` covers area rather than dotting it.
    ground_profile(
        "Wellglass_Axe_Edge",
        [
            (0.452, 0.912),
            (0.548, 0.980),
            (0.580, 1.150),
            (0.548, 1.320),
            (0.452, 1.386),
            (0.512, 1.150),
        ],
        [0.024, 0.015, 0.012, 0.015, 0.024, 0.019],
        [0.048, 0.064, 0.070, 0.064, 0.048, 0.044],
        mats["wellglass_light"],
        center=(0.482, 1.150),
    )
    _knapped_facets(
        "Wellglass_Axe_Scar",
        mats,
        ((0.276, 1.078, 0.058), (0.358, 1.216, 0.048), (0.212, 1.198, 0.042), (0.392, 1.044, 0.038)),
        0.034,
    )
    # Sinew binding over the bedded end — glass in a socket is held by wrap and mastic, never by a
    # rivet, because a rivet hole in glass is a crack waiting for the first swing.
    add_lashing(mats, AXE_HAFT, AXE_RADII, (0.792, 0.848), 0.848)


PICK_HAFT = [(-0.065, 0.0, 0.03), (-0.035, 0.0, 0.34), (0.000, 0.0, 0.66), (0.025, 0.0, 0.95), (0.035, 0.0, 1.18)]
PICK_RADII = [0.052, 0.047, 0.045, 0.050, 0.043]


def build_pickaxe(mats: dict[str, bpy.types.Material], tier: str) -> None:
    add_haft(mats, PICK_HAFT, PICK_RADII, (0.05, 0.34), 6)
    if tier == "wooden":
        head_key, edge_key = "wood_blade", "wood_cut"
        left_reach, right_reach = 0.44, 0.50
        girth, sides = 0.085, 5
    elif tier == "stone":
        head_key, edge_key = "stone", "stone_edge"
        left_reach, right_reach = 0.50, 0.57
        girth, sides = 0.095, 5
    elif tier == "iron":
        head_key, edge_key = "iron", "iron_light"
        left_reach, right_reach = 0.60, 0.66
        girth, sides = 0.075, 4
    elif tier == "bogsilver":
        # Longer arms and a thinner section than iron: the same forged pick, made of better metal,
        # so it reaches further on less mass. That is the tier read at a glance in the hotbar.
        head_key, edge_key = "bogsilver", "bogsilver_light"
        left_reach, right_reach = 0.66, 0.74
        girth, sides = 0.066, 4
    else:
        # Wellglass. The arms stay bogsilver — glass in tension across a 0.7 m arm would shatter, and
        # a tool the player is told is the best in the game must not look structurally silly — but
        # both TIPS are knapped glass, bedded into the metal. Only the working ends are the new
        # material, which is also how every real composite tool has ever been made.
        head_key, edge_key = "bogsilver", "wellglass_light"
        left_reach, right_reach = 0.68, 0.76
        girth, sides = 0.064, 4

    head_mat = mats[head_key]
    # The eye: a collar the haft passes through, with cheeks flaring into each arm.
    ground_profile(
        "Pick_Eye",
        [(-0.135, 1.045), (0.000, 1.020), (0.135, 1.045), (0.150, 1.215), (0.000, 1.250), (-0.150, 1.215)],
        [0.105, 0.108, 0.105, 0.098, 0.100, 0.098],
        [0.000, 0.012, 0.000, 0.025, 0.030, 0.025],
        head_mat,
        center=(0.0, 1.13),
    )
    swept_shaft(
        "Pick_Arm_Left",
        [(-0.100, 0.0, 1.150), (-left_reach * 0.55, 0.0, 1.135), (-left_reach * 0.85, 0.0, 1.085), (-left_reach, 0.0, 1.040)],
        [girth, girth * 0.72, girth * 0.40, 0.010],
        head_mat,
        sides,
        0.90,
    )
    swept_shaft(
        "Pick_Arm_Right",
        [(0.100, 0.0, 1.150), (right_reach * 0.52, 0.0, 1.120), (right_reach * 0.84, 0.0, 1.045), (right_reach, 0.0, 0.975)],
        [girth, girth * 0.70, girth * 0.36, 0.008],
        head_mat,
        sides,
        0.90,
    )
    # Where the working point starts. On a forged pick that is a ground bevel over the last fifth of
    # the arm; on the wellglass one it is a knapped insert bedded over the last third, because a
    # glass point long enough to matter has to be seated in the metal well behind where it bites.
    tip_start = 0.66 if tier == "wellglass" else 0.80
    tip_girth = 0.78 if tier == "wellglass" else 0.40
    swept_shaft(
        "Pick_Tip_Right",
        [(right_reach * tip_start, 0.0, 1.055 + 0.030 * (1.0 - tip_start)), (right_reach, 0.0, 0.975)],
        [girth * tip_girth, 0.008],
        mats[edge_key],
        sides,
        0.90,
    )
    swept_shaft(
        "Pick_Tip_Left",
        [(-left_reach * (tip_start + 0.02), 0.0, 1.095 + 0.026 * (1.0 - tip_start)), (-left_reach, 0.0, 1.040)],
        [girth * (tip_girth + 0.02), 0.010],
        mats[edge_key],
        sides,
        0.90,
    )
    if tier == "stone":
        for index, (x, z) in enumerate(((-0.255, 1.135), (0.265, 1.115))):
            ico(f"Stone_Knuckle_{index + 1}", (x, 0.0, z), (0.075, 0.090, 0.070), head_mat, (0.2, -0.3, 0.1))
    if tier in ("iron", "bogsilver", "wellglass"):
        socket_key = "iron_dark" if tier == "iron" else "bogsilver_dark"
        rivet_key = "iron_light" if tier == "iron" else "bogsilver_light"
        swept_shaft(
            f"{tier.title()}_Socket" if tier != "iron" else "Iron_Socket",
            [(0.020, 0.0, 0.960), (0.028, 0.0, 1.030), (0.032, 0.0, 1.090)],
            [0.082, 0.072, 0.066],
            mats[socket_key],
            8,
            0.88,
        )
        add_rivets(mats, ((0.0, 1.075), (0.0, 1.185)), 0.100, rivet_key, 0.024)
    else:
        add_lashing(mats, PICK_HAFT, PICK_RADII, (0.800, 0.855, 0.910), 0.855)
    if tier == "wellglass":
        # Knapped glass tips bedded over the last stretch of each arm, with fracture scars on both
        # faces so the pick is never one-sided from the side a player actually mines from.
        # Scars sit ON the glass, not near it. The first pass sized them off the blade version and
        # placed them at the arm's outer stations, where the arm has already tapered below their own
        # radius — they rendered as flecks floating in the air beside the tool.
        _knapped_facets(
            "Wellglass_Pick_Scar_Right",
            mats,
            ((right_reach * 0.78, 1.032, 0.022), (right_reach * 0.90, 1.005, 0.015)),
            0.016,
        )
        _knapped_facets(
            "Wellglass_Pick_Scar_Left",
            mats,
            ((-left_reach * 0.80, 1.078, 0.021), (-left_reach * 0.92, 1.052, 0.014)),
            0.016,
        )


def build_cleaver(mats: dict[str, bpy.types.Material]) -> None:
    tang = [(0.000, 0.0, 0.030), (0.000, 0.0, 0.180), (0.000, 0.0, 0.330), (0.000, 0.0, 0.470)]
    tang_radii = [0.055, 0.062, 0.062, 0.056]
    swept_shaft("Cleaver_Tang", tang, tang_radii, mats["iron_dark"], 6, 0.55)
    # Full-tang grip: two riveted scales rather than a turned dowel.
    for side_index, side in enumerate((-1.0, 1.0)):
        ground_profile(
            f"Cleaver_Scale_{side_index + 1}",
            [(-0.062, 0.045), (0.062, 0.055), (0.070, 0.300), (0.052, 0.450), (-0.055, 0.445), (-0.072, 0.290)],
            [0.024, 0.024, 0.022, 0.020, 0.020, 0.024],
            0.012,
            mats["leather"],
            y_offset=side * 0.050,
        )
    add_rivets(mats, ((0.0, 0.115), (0.010, 0.290), (0.0, 0.415)), 0.072, "brass", 0.024)
    box("Cleaver_Bolster", (0.0, 0.0, 0.500), (0.235, 0.165, 0.075), mats["brass"], bevel=0.022)
    # Square spine, ground edge: a cleaver is a plate with one bevel, not a leaf.
    ground_profile(
        "Cleaver_Blade",
        [
            (-0.155, 0.520),
            (0.070, 0.528),
            (0.245, 0.560),
            (0.365, 0.700),
            (0.420, 0.905),
            (0.428, 1.095),
            (0.335, 1.148),
            (0.050, 1.152),
            (-0.145, 1.145),
            (-0.245, 1.098),
            (-0.250, 0.760),
        ],
        [0.044, 0.034, 0.018, 0.014, 0.013, 0.014, 0.024, 0.042, 0.048, 0.050, 0.050],
        [0.030, 0.050, 0.070, 0.075, 0.075, 0.070, 0.045, 0.012, 0.006, 0.000, 0.000],
        mats["iron"],
        center=(0.050, 0.840),
    )
    ground_profile(
        "Cleaver_Edge",
        [(0.245, 0.560), (0.365, 0.700), (0.420, 0.905), (0.428, 1.095), (0.360, 1.120), (0.352, 0.910), (0.300, 0.715), (0.195, 0.585)],
        [0.016, 0.012, 0.011, 0.012, 0.028, 0.030, 0.032, 0.034],
        [0.050, 0.055, 0.058, 0.055, 0.010, 0.008, 0.008, 0.010],
        mats["iron_light"],
        center=(0.320, 0.840),
    )
    swept_shaft(
        "Cleaver_Hole",
        [(-0.120, -0.060, 1.045), (-0.120, 0.060, 1.045)],
        [0.036, 0.036],
        mats["iron_dark"],
        8,
    )


def build_skewer(mats: dict[str, bpy.types.Material]) -> None:
    grip = [(0.0, 0.0, 0.030), (0.0, 0.0, 0.300), (0.0, 0.0, 0.620), (0.0, 0.0, 0.900), (0.0, 0.0, 1.075)]
    grip_radii = [0.044, 0.048, 0.047, 0.045, 0.040]
    add_haft(mats, grip, grip_radii, (0.10, 0.78), 9, 0.86, 8, "leather", "iron_dark")
    # Crossguard, then a twisted iron shank running into a long knapped point.
    ground_profile(
        "Skewer_Guard",
        [(-0.235, 1.100), (-0.075, 1.075), (0.075, 1.075), (0.235, 1.100), (0.205, 1.165), (0.0, 1.190), (-0.205, 1.165)],
        [0.038, 0.052, 0.052, 0.038, 0.034, 0.048, 0.034],
        [0.045, 0.008, 0.008, 0.045, 0.045, 0.012, 0.045],
        mats["iron_dark"],
        center=(0.0, 1.13),
    )
    swept_shaft(
        "Skewer_Shank",
        [(0.0, 0.0, 1.120), (0.0, 0.0, 1.300), (0.0, 0.0, 1.480), (0.0, 0.0, 1.640)],
        [0.032, 0.027, 0.028, 0.024],
        mats["iron"],
        6,
        1.0,
    )
    for index, height in enumerate((1.230, 1.360, 1.490)):
        cone(f"Skewer_Collar_{index + 1}", 0.040, 0.032, 0.030, (0.0, 0.0, height), mats["iron_dark"], 6)
    ground_profile(
        "Skewer_Point",
        [(-0.062, 1.610), (0.062, 1.610), (0.048, 1.790), (0.0, 1.945), (-0.048, 1.790)],
        [0.030, 0.030, 0.020, 0.006, 0.020],
        [0.018, 0.018, 0.035, 0.055, 0.035],
        mats["iron_light"],
        center=(0.0, 1.72),
    )
    for index, side in enumerate((-1.0, 1.0)):
        swept_shaft(
            f"Skewer_Barb_{index + 1}",
            [(side * 0.020, 0.0, 1.690), (side * 0.095, 0.0, 1.640), (side * 0.150, 0.0, 1.575)],
            [0.030, 0.018, 0.005],
            mats["iron_light"],
            5,
            0.8,
        )


def build_short_bow(mats: dict[str, bpy.types.Material]) -> None:
    # A recurve: limbs bend away from the archer, then the tips curve back.
    upper = [
        (0.0, 0.0, 0.845),
        (-0.085, 0.0, 1.000),
        (-0.215, 0.0, 1.180),
        (-0.275, 0.0, 1.375),
        (-0.215, 0.0, 1.520),
        (-0.115, 0.0, 1.585),
    ]
    lower = [
        (0.0, 0.0, 0.715),
        (-0.085, 0.0, 0.560),
        (-0.215, 0.0, 0.380),
        (-0.275, 0.0, 0.185),
        (-0.215, 0.0, 0.040),
        (-0.115, 0.0, -0.025),
    ]
    limb_radii = [0.047, 0.042, 0.036, 0.030, 0.024, 0.017]
    for prefix, points in (("Upper", upper), ("Lower", lower)):
        swept_shaft(f"Bow_Limb_{prefix}", points, limb_radii, mats["bow_wood"], 6, 0.52)
        swept_shaft(
            f"Bow_Nock_{prefix}",
            [points[-2], points[-1]],
            [0.024, 0.020],
            mats["handle_dark"],
            6,
            0.60,
        )
    riser = [(0.0, 0.0, 0.660), (0.0, 0.0, 0.780), (0.0, 0.0, 0.900)]
    riser_radii = [0.052, 0.062, 0.052]
    swept_shaft("Bow_Riser", riser, riser_radii, mats["handle_dark"], 8, 0.72)
    for index in range(5):
        wrap_band(f"Bow_Grip_Wrap_{index + 1}", riser, riser_radii, 0.18 + index * 0.16, 0.038, mats["leather"], 1.14, 0.72, 8)
    ground_profile(
        "Bow_Arrow_Shelf",
        [(0.020, 0.845), (0.115, 0.855), (0.115, 0.895), (0.020, 0.890)],
        0.030,
        0.010,
        mats["leather"],
    )
    string_top = (-0.115, 0.0, 1.585)
    string_bottom = (-0.115, 0.0, -0.025)
    swept_shaft("Bow_String", [string_top, (-0.117, 0.0, 0.780), string_bottom], [0.008, 0.009, 0.008], mats["string"], 5)
    swept_shaft(
        "Bow_String_Serving",
        [(-0.117, 0.0, 0.700), (-0.117, 0.0, 0.860)],
        [0.014, 0.014],
        mats["wrap"],
        5,
    )


def build_arrow(mats: dict[str, bpy.types.Material]) -> None:
    shaft = [(0.0, 0.0, 0.055), (0.0, 0.0, 0.500), (0.0, 0.0, 0.950), (0.0, 0.0, 1.215)]
    swept_shaft("Arrow_Shaft", shaft, [0.019, 0.021, 0.020, 0.018], mats["arrow_wood"], 6)
    # Knapped head with a visible haft socket and sinew binding.
    ground_profile(
        "Arrow_Head",
        [(-0.072, 1.195), (0.072, 1.195), (0.088, 1.290), (0.040, 1.410), (0.0, 1.485), (-0.040, 1.410), (-0.088, 1.290)],
        [0.022, 0.022, 0.016, 0.010, 0.004, 0.010, 0.016],
        [0.012, 0.012, 0.025, 0.035, 0.045, 0.035, 0.025],
        mats["stone_edge"],
        center=(0.0, 1.31),
    )
    for index, t in enumerate((0.05, 0.14)):
        position = Vector((0.0, 0.0, 1.185 + index * 0.045))
        swept_shaft(
            f"Arrow_Binding_{index + 1}",
            [tuple(position - Vector((0.0, 0.0, 0.016))), tuple(position + Vector((0.0, 0.0, 0.016)))],
            [0.026, 0.026],
            mats["rope"],
            6,
        )
    for index, rotation in enumerate((0.0, math.radians(120), math.radians(240))):
        vane = ground_profile(
            f"Fletching_{index + 1}",
            [(0.016, 0.112), (0.032, 0.150), (0.128, 0.238), (0.138, 0.332), (0.078, 0.378), (0.018, 0.352)],
            [0.006, 0.006, 0.005, 0.005, 0.005, 0.006],
            0.006,
            mats["fletching" if index % 2 == 0 else "fletching_light"],
        )
        vane.rotation_euler = (0.0, 0.0, rotation)
    swept_shaft("Arrow_Nock", [(0.0, 0.0, 0.020), (0.0, 0.0, 0.075), (0.0, 0.0, 0.115)], [0.020, 0.028, 0.024], mats["handle_dark"], 6)
    box("Arrow_Nock_Slot", (0.0, 0.0, 0.028), (0.010, 0.060, 0.038), mats["iron_dark"])


def build_repair_hammer(mats: dict[str, bpy.types.Material]) -> None:
    haft = [(0.0, 0.0, 0.030), (0.0, 0.0, 0.290), (0.0, 0.0, 0.570), (0.0, 0.0, 0.800), (0.0, 0.0, 0.985)]
    haft_radii = [0.050, 0.055, 0.052, 0.056, 0.048]
    add_haft(mats, haft, haft_radii, (0.08, 0.58), 8, 0.82, 9, "leather")
    # Cross-peen head: square striking face, drawn peen, brass eye band.
    ground_profile(
        "Hammer_Body",
        [
            (-0.235, 0.900),
            (-0.090, 0.870),
            (0.115, 0.870),
            (0.300, 0.885),
            (0.330, 1.075),
            (0.115, 1.100),
            (-0.090, 1.100),
            (-0.245, 1.065),
        ],
        [0.108, 0.118, 0.118, 0.098, 0.092, 0.115, 0.115, 0.100],
        [0.012, 0.000, 0.000, 0.018, 0.020, 0.000, 0.000, 0.014],
        mats["iron"],
        center=(0.03, 0.985),
    )
    ground_profile(
        "Hammer_Face",
        [(0.300, 0.870), (0.375, 0.895), (0.380, 1.065), (0.300, 1.085)],
        [0.098, 0.088, 0.086, 0.096],
        [0.008, 0.020, 0.020, 0.008],
        mats["iron_light"],
        center=(0.34, 0.98),
    )
    ground_profile(
        "Hammer_Peen",
        [(-0.235, 0.905), (-0.400, 0.945), (-0.505, 0.975), (-0.505, 1.010), (-0.400, 1.035), (-0.245, 1.060)],
        [0.100, 0.070, 0.042, 0.040, 0.068, 0.098],
        [0.010, 0.030, 0.050, 0.052, 0.030, 0.010],
        mats["iron_dark"],
        center=(-0.37, 0.99),
    )
    for side_index, side in enumerate((-1.0, 1.0)):
        ground_profile(
            f"Hammer_Eye_Band_{side_index + 1}",
            [(-0.095, 0.865), (0.120, 0.865), (0.120, 1.105), (-0.095, 1.105)],
            0.010,
            0.008,
            mats["brass"],
            y_offset=side * 0.122,
        )
    swept_shaft("Hammer_Wedge", [(0.010, 0.0, 1.075), (0.014, 0.0, 1.130)], [0.045, 0.038], mats["brass"], 6, 0.6)
    for index, t in enumerate((0.66, 0.74, 0.82)):
        wrap_band(f"Repair_Band_{index + 1}", haft, haft_radii, t, 0.034, mats["red"], 1.15, 0.82, 9)


SWORD_GRIP = [(0.0, 0.0, 0.115), (0.0, 0.0, 0.245), (0.0, 0.0, 0.395), (0.0, 0.0, 0.548)]
SWORD_GRIP_RADII = [0.048, 0.040, 0.040, 0.050]
#: One blade cross-section per row: (height, half width, half thickness, fuller depth).
#: The fuller is a fraction of the half thickness, so it shallows out toward the point
#: the way a real one stops short of it.
#:
#: The width barely moves over the first 60% and then all the taper happens at once.
#: A blade that narrows evenly from the guard is a leaf, and a leaf reads as a dagger
#: no matter how long it is — the first pass here was 0.10 m at the shoulder and
#: looked like a gladius beside the axes.
SWORD_STATIONS = [
    (0.600, 0.072, 0.028, 0.52),
    (0.720, 0.074, 0.027, 0.52),
    (0.920, 0.072, 0.026, 0.53),
    (1.110, 0.069, 0.024, 0.55),
    (1.290, 0.065, 0.022, 0.58),
    (1.430, 0.058, 0.019, 0.64),
    (1.540, 0.046, 0.016, 0.74),
    (1.618, 0.030, 0.013, 0.86),
    (1.664, 0.016, 0.010, 0.94),
]
SWORD_TIP = (0.0, 0.0, 1.716)
#: Share of the half width held by the dark body. The rest is the bright ground edge,
#: which is its own closed solid butted onto the body's ridge — see the axes.
SWORD_CORE = 0.74
#: Where the flat meets the edge bevel, and where the fuller wall starts, both as a
#: share of the core's half width.
SWORD_SHOULDER = 0.72
SWORD_FULLER = 0.40


def _blade_ring(z: float, half_width: float, half_thickness: float, fuller: float) -> list[tuple[float, float, float]]:
    """The blade's dark core: a flat either side of a fuller running down the middle."""
    core = half_width * SWORD_CORE
    shoulder = core * SWORD_SHOULDER
    wall = core * SWORD_FULLER
    channel = half_thickness * fuller
    return [
        (core, 0.0, z),
        (shoulder, half_thickness, z),
        (wall, channel, z),
        (-wall, channel, z),
        (-shoulder, half_thickness, z),
        (-core, 0.0, z),
        (-shoulder, -half_thickness, z),
        (-wall, -channel, z),
        (wall, -channel, z),
        (shoulder, -half_thickness, z),
    ]


def _blade_edge_ring(z: float, half_width: float, half_thickness: float, side: float) -> list[tuple[float, float, float]]:
    """One ground edge. Its inner faces sit exactly on the core's, so the two butt
    along a seam instead of the bright material being a strip laid over the body."""
    core = half_width * SWORD_CORE
    return [
        (side * core, 0.0, z),
        (side * core * SWORD_SHOULDER, half_thickness, z),
        (side * half_width, 0.0, z),
        (side * core * SWORD_SHOULDER, -half_thickness, z),
    ]


def build_iron_sword(mats: dict[str, bpy.types.Material]) -> None:
    lofted(
        "Sword_Blade",
        [_blade_ring(z, half_width, half_thickness, fuller) for z, half_width, half_thickness, fuller in SWORD_STATIONS],
        mats["iron"],
        apex=SWORD_TIP,
    )
    for index, side in enumerate((-1.0, 1.0)):
        lofted(
            f"Sword_Edge_{index + 1}",
            [_blade_edge_ring(z, half_width, half_thickness, side) for z, half_width, half_thickness, _ in SWORD_STATIONS],
            mats["iron_light"],
            apex=SWORD_TIP,
        )
    # Quillons sweeping up toward the blade and flaring at the tips. Kept to half a
    # metre tip to tip: a crossguard as wide as the axe head is wide reads as a
    # crucifix, and the cross is the only silhouette this weapon has.
    ground_profile(
        "Sword_Guard",
        [
            (-0.235, 0.596),
            (-0.180, 0.556),
            (-0.086, 0.540),
            (0.000, 0.536),
            (0.086, 0.540),
            (0.180, 0.556),
            (0.235, 0.596),
            (0.247, 0.642),
            (0.178, 0.624),
            (0.084, 0.606),
            (0.000, 0.602),
            (-0.084, 0.606),
            (-0.178, 0.624),
            (-0.247, 0.642),
        ],
        [0.020, 0.034, 0.044, 0.048, 0.044, 0.034, 0.020, 0.020, 0.034, 0.044, 0.048, 0.044, 0.034, 0.020],
        [0.026, 0.014, 0.008, 0.006, 0.008, 0.014, 0.026, 0.026, 0.014, 0.008, 0.006, 0.008, 0.014, 0.026],
        mats["iron"],
        center=(0.0, 0.588),
    )
    # Brass end caps on the quillons. These sat at the old guard's width on the first
    # pass and rendered as two nubs floating in space either side of it — a detail
    # placed by remembered numbers rather than by the numbers actually in the file.
    for index, side in enumerate((-1.0, 1.0)):
        cone(
            f"Sword_Quillon_Cap_{index + 1}",
            0.030,
            0.023,
            0.028,
            (side * 0.241, 0.0, 0.619),
            mats["brass"],
            6,
            (0.0, math.radians(90), 0.0),
        )
    # Écusson: the brass shield where the blade enters the guard. Proud of the blade
    # faces and narrower than it, so it covers the joint without eating the edges.
    ground_profile(
        "Sword_Escutcheon",
        [(-0.050, 0.575), (0.050, 0.575), (0.058, 0.630), (0.038, 0.692), (0.000, 0.712), (-0.038, 0.692), (-0.058, 0.630)],
        [0.036, 0.036, 0.040, 0.036, 0.032, 0.036, 0.040],
        [0.008, 0.008, 0.012, 0.014, 0.016, 0.014, 0.012],
        mats["brass"],
        center=(0.0, 0.632),
    )
    # Waisted grip, flattened across the blade's plane so it reads as something you
    # could index the edge from rather than a dowel.
    swept_shaft("Sword_Grip", SWORD_GRIP, SWORD_GRIP_RADII, mats["leather"], 10, 0.62)
    for index, (low, high, radius) in enumerate(((0.112, 0.158, 0.056), (0.508, 0.554, 0.058))):
        swept_shaft(
            f"Sword_Ferrule_{index + 1}",
            [(0.0, 0.0, low), (0.0, 0.0, (low + high) * 0.5), (0.0, 0.0, high)],
            [radius * 0.88, radius, radius * 0.88],
            mats["brass"],
            10,
            0.62,
        )
    for index in range(5):
        wrap_band(
            f"Sword_Riser_{index + 1}",
            SWORD_GRIP,
            SWORD_GRIP_RADII,
            0.20 + 0.60 * index / 4,
            0.030,
            mats["wrap"],
            1.13,
            0.62,
            8,
        )
    # Wheel pommel, faceted rather than smooth, with a brass boss on each cheek and
    # the peened tang end underneath — which is also what the sword stands on.
    ground_profile(
        "Sword_Pommel",
        [
            (math.cos(math.tau * index / 10) * 0.072, 0.084 + math.sin(math.tau * index / 10) * 0.072)
            for index in range(10)
        ],
        0.038,
        0.021,
        mats["iron_dark"],
        center=(0.0, 0.084),
    )
    add_rivets(mats, ((0.0, 0.084),), 0.038, "brass", 0.028)
    cone("Sword_Pommel_Button", 0.028, 0.022, 0.028, (0.0, 0.0, 0.006), mats["brass"], 6)


# ---------------------------------------------------------------------------
# Assembly, catalog, previews
# ---------------------------------------------------------------------------


def grid_position(design_index: int) -> tuple[float, float]:
    """Where a design stands in the preview grid, centred on the camera."""
    column = design_index % PREVIEW_COLUMNS
    row = design_index // PREVIEW_COLUMNS
    x = (column - (PREVIEW_COLUMNS - 1) * 0.5) * PREVIEW_COLUMN_SPACING
    return x, 1.8 - row * PREVIEW_ROW_SPACING


def create_asset(
    name: str,
    design: str,
    presentation: str,
    builder: Callable[[], None],
    display_location: tuple[float, float, float],
) -> dict:
    collection = bpy.data.collections.new(name)
    bpy.context.scene.collection.children.link(collection)
    root = bpy.data.objects.new(name, None)
    root.empty_display_type = "PLAIN_AXES"
    collection.objects.link(root)
    before = set(bpy.data.objects)
    builder()
    made = [obj for obj in bpy.data.objects if obj not in before]
    minimum, maximum = world_bounds(made)
    offset = Vector((-(minimum.x + maximum.x) * 0.5, -(minimum.y + maximum.y) * 0.5, -minimum.z))
    for obj in made:
        obj.location += offset
    move_to_collection(made, collection)
    for obj in made:
        obj.parent = root
    minimum, maximum = world_bounds(made)
    dimensions = maximum - minimum
    polygons = sum(len(obj.data.polygons) for obj in made if obj.type == "MESH")
    materials = sorted({mat.name for obj in made if obj.type == "MESH" for mat in obj.data.materials if mat})

    bpy.ops.object.select_all(action="DESELECT")
    for obj in collection.objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = root
    bpy.ops.export_scene.gltf(
        filepath=str(EXPORT_DIR / f"{name}.glb"),
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_yup=True,
    )
    root.location = display_location
    return {
        "name": name,
        "design": design,
        "presentation": presentation,
        "root": root,
        "width": dimensions.x,
        "depth": dimensions.y,
        "height": dimensions.z,
        "parts": sum(1 for obj in made if obj.type == "MESH"),
        "polygons": polygons,
        "materials": materials,
    }


def set_visible(record: dict, visible: bool) -> None:
    record["root"].hide_render = not visible
    for child in record["root"].children_recursive:
        child.hide_render = not visible


def setup_render(mats: dict[str, bpy.types.Material]) -> tuple[bpy.types.Scene, bpy.types.Object, bpy.types.Collection]:
    preview_collection = bpy.data.collections.new("PREVIEW_ONLY")
    bpy.context.scene.collection.children.link(preview_collection)
    bpy.ops.mesh.primitive_plane_add(size=70, location=(0.0, 0.0, -0.035))
    floor = bpy.context.object
    floor.name = "Preview_Ground"
    assign(floor, mats["ground"])
    move_to_collection([floor], preview_collection)
    bpy.ops.object.light_add(type="SUN", location=(0.0, 0.0, 20.0))
    sun = bpy.context.object
    sun.name = "Preview_Sun"
    sun.rotation_euler = (math.radians(34), math.radians(-22), math.radians(-28))
    sun.data.energy = 2.35
    sun.data.angle = math.radians(18)
    move_to_collection([sun], preview_collection)
    bpy.ops.object.light_add(type="AREA", location=(-9.0, -13.0, 12.0))
    fill = bpy.context.object
    fill.name = "Preview_Fill"
    fill.data.energy = 1450
    fill.data.color = (0.43, 0.28, 0.68)
    fill.data.shape = "DISK"
    fill.data.size = 10.0
    look_at(fill, (0.0, 0.0, 0.8))
    move_to_collection([fill], preview_collection)
    bpy.ops.object.camera_add(location=(0.0, -18.0, 10.0))
    camera = bpy.context.object
    camera.name = "Preview_Camera"
    camera.data.type = "ORTHO"
    bpy.context.scene.camera = camera
    move_to_collection([camera], preview_collection)
    scene = bpy.context.scene
    scene.render.engine = eevee_engine()
    scene.render.resolution_x = 1600
    scene.render.resolution_y = 780
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.film_transparent = False
    scene.world.color = (0.012, 0.016, 0.026)
    scene.view_settings.look = "AgX - Medium High Contrast"
    return scene, camera, preview_collection


def build_materials() -> dict[str, bpy.types.Material]:
    """Local names onto the shared palette, so a haft is the same oak as a bench."""
    return {
        "handle": mat("wood_timber"),
        "handle_dark": mat("wood_bark"),
        "wood_blade": mat("wood_timber_light"),
        "hardwood_dark": mat("wood_bark_light"),
        "wood_cut": mat("wood_cut"),
        "rope": mat("rope"),
        "wrap": mat("cloth_red"),
        "leather": mat("leather"),
        "stone": mat("stone"),
        "stone_edge": mat("stone_light"),
        "bogsilver": mat("bogsilver"),
        "bogsilver_light": mat("bogsilver_light"),
        "bogsilver_dark": mat("bogsilver_dark"),
        "wellglass": mat("wellglass"),
        "wellglass_light": mat("wellglass_light"),
        "wellglass_dark": mat("wellglass_dark"),
        "iron": mat("iron"),
        "iron_light": mat("iron_light"),
        "iron_dark": mat("iron_dark"),
        "brass": mat("brass"),
        "red": mat("cloth_red"),
        "bow_wood": mat("wood_timber_light"),
        "string": mat("fibre"),
        "arrow_wood": mat("wood_timber"),
        "fletching": mat("cloth_red"),
        "fletching_light": mat("cloth"),
        "ground": mat("preview_ground"),
        "scale": mat("reference_blue"),
    }


def main() -> None:
    EXPORT_DIR.mkdir(parents=True, exist_ok=True)
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    for expected in EXPECTED_NAMES:
        (EXPORT_DIR / f"{expected}.glb").unlink(missing_ok=True)
    reset_materials()
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for datablocks in (bpy.data.materials, bpy.data.curves, bpy.data.cameras, bpy.data.lights):
        for block in list(datablocks):
            datablocks.remove(block)

    mats = build_materials()
    builders: dict[str, Callable[[], None]] = {
        "wooden_axe": lambda: build_wooden_axe(mats),
        "stone_axe": lambda: build_stone_axe(mats),
        "wooden_pickaxe": lambda: build_pickaxe(mats, "wooden"),
        "stone_pickaxe": lambda: build_pickaxe(mats, "stone"),
        "iron_axe": lambda: build_forged_axe(mats, "iron"),
        "iron_pickaxe": lambda: build_pickaxe(mats, "iron"),
        "bogsilver_axe": lambda: build_forged_axe(mats, "bogsilver"),
        "bogsilver_pickaxe": lambda: build_pickaxe(mats, "bogsilver"),
        "wellglass_axe": lambda: build_wellglass_axe(mats),
        "wellglass_pickaxe": lambda: build_pickaxe(mats, "wellglass"),
        "cleaver": lambda: build_cleaver(mats),
        "skewer": lambda: build_skewer(mats),
        "short_bow": lambda: build_short_bow(mats),
        "arrow": lambda: build_arrow(mats),
        "repair_hammer": lambda: build_repair_hammer(mats),
        "iron_sword": lambda: build_iron_sword(mats),
    }
    records: list[dict] = []
    for design_index, design in enumerate(DESIGNS):
        for presentation in ("world", "viewmodel"):
            name = f"{design}_{presentation}"
            x, y = grid_position(design_index)
            location = (x, y, 0.0) if presentation == "world" else (x, y + 24.0, 0.0)
            records.append(create_asset(name, design, presentation, builders[design], location))
    if [record["name"] for record in records] != EXPECTED_NAMES:
        raise RuntimeError("tool/weapon specification and export order diverged")

    catalog = [
        {
            "name": record["name"],
            "design": record["design"],
            "presentation": record["presentation"],
            "width_m": round(record["width"], 3),
            "depth_m": round(record["depth"], 3),
            "height_m": round(record["height"], 3),
            "mesh_parts": record["parts"],
            "polygons": record["polygons"],
            "materials": record["materials"],
        }
        for record in records
    ]
    with (ASSET_DIR / "catalog.json").open("w", encoding="utf-8") as handle:
        json.dump(catalog, handle, indent=2)
        handle.write("\n")

    scene, camera, preview_collection = setup_render(mats)
    for record in records:
        set_visible(record, record["presentation"] == "world")
    camera.data.ortho_scale = 17.4
    camera.location = (0.0, -16.0, 6.6)
    look_at(camera, (0.0, 0.0, 0.85))
    scene.render.filepath = str(PREVIEW_DIR / "tools_weapons_world_preview.png")
    bpy.ops.render.render(write_still=True)

    original_transforms = {
        record["name"]: (record["root"].location.copy(), record["root"].rotation_euler.copy())
        for record in records
    }
    for record in records:
        set_visible(record, record["presentation"] == "viewmodel")
        if record["presentation"] == "viewmodel":
            x, y = grid_position(DESIGNS.index(record["design"]))
            record["root"].location = (x, y, 0.0)
            record["root"].rotation_euler = (math.radians(-12), math.radians(18), math.radians(-10))
    camera.data.ortho_scale = 17.4
    camera.location = (0.0, -16.0, 6.6)
    look_at(camera, (0.0, 0.0, 0.87))
    scene.render.filepath = str(PREVIEW_DIR / "tools_weapons_viewmodel_preview.png")
    bpy.ops.render.render(write_still=True)

    showcase_positions = {
        "stone_axe_world": (-3.0, 0.2, 0.0),
        "skewer_world": (-0.8, 0.2, 0.0),
        "short_bow_world": (1.6, 0.2, 0.0),
        "cleaver_world": (3.7, 0.2, 0.0),
        "iron_sword_world": (5.7, 0.2, 0.0),
    }
    for record in records:
        set_visible(record, record["name"] in showcase_positions)
        if record["name"] in showcase_positions:
            record["root"].location = showcase_positions[record["name"]]
            record["root"].rotation_euler = (0.0, 0.0, 0.0)
    scale_parts = [
        ico("Scale_Head", (-5.1, -0.6, 1.63), (0.16, 0.16, 0.18), mats["scale"]),
        cone("Scale_Body", 0.24, 0.17, 0.92, (-5.1, -0.6, 1.02), mats["scale"], 8),
        cylinder_between("Scale_Leg_L", (-5.20, -0.6, 0.60), (-5.22, -0.6, 0.02), 0.075, mats["scale"], 7),
        cylinder_between("Scale_Leg_R", (-5.00, -0.6, 0.60), (-4.98, -0.6, 0.02), 0.075, mats["scale"], 7),
        box("Scale_Metre", (-4.55, -0.6, 0.50), (0.10, 0.10, 1.0), mats["scale"]),
    ]
    move_to_collection(scale_parts, preview_collection)
    camera.data.ortho_scale = 13.8
    camera.location = (6.0, -16.0, 8.2)
    look_at(camera, (-0.2, 0.0, 0.85))
    scene.render.filepath = str(PREVIEW_DIR / "tools_weapons_scale_preview.png")
    bpy.ops.render.render(write_still=True)

    for record in records:
        location, rotation = original_transforms[record["name"]]
        record["root"].location = location
        record["root"].rotation_euler = rotation
        set_visible(record, True)
    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE_DIR / "tool_weapon_set.blend"))
    total_polygons = sum(record["polygons"] for record in records)
    print(f"Built {len(records)} A-004 exports from {len(DESIGNS)} shared designs ({total_polygons} polygons total)")


if __name__ == "__main__":
    with import_cache_guard(Path(__file__).name):
        main()
