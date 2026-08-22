"""Build the wild boar — FAUNA.md §2 #5 (F-596, D-220).

Run with:
  Blender --background --python tools/blender/build_fauna_boar.py

Outputs `assets/fauna/exports/boar.glb` with the batch's four clips. Shared
machinery in `fauna_common.py`.

## The real animal

*Sus scrofa*, a mature male. FAUNA.md gives it the job of bridging animal and
enemy — "neutral until provoked, then charges" — so it has to look like it might
turn on you while the cow beside it plainly will not.

**Everything about a boar is front-heavy, and that is the whole silhouette.** The
shoulder hump is the tallest point of the animal, the head is enormous relative to
the body and carried LOW and forward, and the line of the back falls away from the
shoulder to a much lower rump. A pig drawn with a level back and a big rear is a
domestic sow; a boar is a wedge with the point at the front. That falling backline
is the single most legible thing here, and it is why the barrel is pitched rather
than the parts merely being different sizes.

**There is almost no neck.** The head attaches directly to the shoulder mass, and
the animal turns by turning its whole body. That is what makes a boar look like a
battering ram rather than a quadruped with a head on it — and it is why `flee` and
the charge read as the same motion from the front.

**The legs are short and thin under a heavy body**, which is what makes them
disconcertingly fast. Boars are much quicker than they look, and the short thin
legs are the visual reason it surprises you.

**Tusks curve UP and OUT from the lower jaw**, small — 6-12 cm of visible ivory on
a mature male, not the sabres of a cartoon. Oversized tusks read as a monster and
this animal's whole point is that it is an ordinary animal that fights back.

**The coat is bristled**, with a stiff dorsal crest along the spine that raises
when the animal is roused. That crest is modelled as its own strip on the body
bone so `flee` can lift it — the visible tell that this one has decided.

## Scale against the player

0.95 m at the shoulder hump, 53% of the 1.8 m player capsule, 1.5 m long. Waist
height on a person, which is the right read: not big enough to be a monster, big
enough that you would not want it to hit you.

## How far the poses may be pushed

Rigid one-bone-per-part skinning. The risk here is the head, because it is huge
and sunk only 0.07 m into the shoulder — there is no neck to hide a seam in. The
poses keep the head inside 25 degrees of rest for that reason, and the animal
expresses itself by pitching the whole BODY instead, which is also what the real
animal does.
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

import bpy

sys.path.append(str(Path(__file__).resolve().parent))
from mire_art import mat, reset_materials  # noqa: E402
from godot_import_lock import import_cache_guard  # noqa: E402
import fauna_common as fc  # noqa: E402


SPECIES = "boar"

## Metres. SHOULDER_Z and RUMP_Z are the load-bearing pair: the difference between
## them IS the wedge, and if they converge this stops being a boar.
SHOULDER_Z = 0.82
RUMP_Z = 0.62
BELLY_Z = 0.40
BODY_LENGTH = 0.92
BODY_WIDTH = 0.36
HEAD_Z = 0.60


BONES = [
    ("root", (0.0, 0.0, 0.0), (0.0, 0.0, 0.2), None),
    ("body", (0.0, 0.0, SHOULDER_Z - 0.18), (0.0, -0.4, RUMP_Z - 0.18), "root"),
    # A stub, not a neck. The head is effectively welded to the shoulder.
    ("head", (0.0, 0.40, HEAD_Z + 0.10), (0.0, 0.72, HEAD_Z - 0.02), "body"),
    ("tusk_l", (0.06, 0.72, HEAD_Z - 0.08), (0.10, 0.80, HEAD_Z + 0.02), "head"),
    ("tusk_r", (-0.06, 0.72, HEAD_Z - 0.08), (-0.10, 0.80, HEAD_Z + 0.02), "head"),
    ("crest", (0.0, 0.20, SHOULDER_Z + 0.02), (0.0, -0.20, SHOULDER_Z), "body"),
    ("tail", (0.0, -0.52, RUMP_Z - 0.02), (0.0, -0.60, RUMP_Z - 0.14), "body"),
    ("fore_l", (0.13, 0.24, BELLY_Z), (0.13, 0.24, 0.0), "body"),
    ("fore_r", (-0.13, 0.24, BELLY_Z), (-0.13, 0.24, 0.0), "body"),
    ("hind_l", (0.13, -0.32, BELLY_Z - 0.04), (0.13, -0.32, 0.0), "body"),
    ("hind_r", (-0.13, -0.32, BELLY_Z - 0.04), (-0.13, -0.32, 0.0), "body"),
]


def build_parts() -> list[tuple[bpy.types.Object, str]]:
    hide = mat("leather_dark")
    hide_light = mat("leather")
    tusk = mat("bone")
    snout = mat("flesh_fat")

    parts: list[tuple[bpy.types.Object, str]] = []

    def add(obj: bpy.types.Object, bone: str) -> None:
        parts.append((obj, bone))

    # The wedge. Pitched nose-UP along its length so the back genuinely falls away
    # from the shoulder — the shape is in the rotation, not only in the sizes.
    add(fc.ico("Boar_Body", (0.0, -0.06, (SHOULDER_Z + BELLY_Z) * 0.5 - 0.02),
               (BODY_WIDTH, BODY_LENGTH, 0.44), hide, rotation=(9.0, 0.0, 0.0)), "body")
    # The hump: the tallest point of the animal, and forward of centre.
    add(fc.ico("Boar_Hump", (0.0, 0.16, SHOULDER_Z - 0.10),
               (BODY_WIDTH + 0.02, 0.44, 0.36), hide), "body")
    # The rump, deliberately smaller and lower than the shoulder.
    add(fc.ico("Boar_Rump", (0.0, -0.40, RUMP_Z - 0.12),
               (BODY_WIDTH - 0.05, 0.34, 0.32), hide), "body")

    # The dorsal crest — bristles along the spine. Its own bone so `flee` can raise
    # it: the visible tell that this one has decided to come at you.
    add(fc.box("Boar_Crest", (0.0, 0.02, SHOULDER_Z + 0.02), (0.05, 0.52, 0.10),
               hide_light), "crest")

    # The head: huge, low, forward. Nearly a third of the animal's length.
    add(fc.ico("Boar_Head", (0.0, 0.50, HEAD_Z + 0.04), (0.26, 0.36, 0.30), hide), "head")
    add(fc.ico("Boar_Snout", (0.0, 0.74, HEAD_Z - 0.06), (0.15, 0.20, 0.15), hide), "head")
    add(fc.ico("Boar_Nose", (0.0, 0.85, HEAD_Z - 0.07), (0.11, 0.05, 0.10), snout), "head")
    for side, sign in (("L", 1.0), ("R", -1.0)):
        add(fc.ico(f"Boar_Ear_{side}", (sign * 0.17, 0.42, HEAD_Z + 0.20),
                   (0.05, 0.10, 0.13), hide, rotation=(-14.0, sign * 22.0, 0.0)), "head")

    # Tusks: UP and OUT of the lower jaw, small. Oversized ones read as a monster,
    # and this animal's whole point is that it is ordinary and fights back.
    for side, sign in (("L", 1.0), ("R", -1.0)):
        add(fc.cone(f"Boar_Tusk_{side}", (sign * 0.09, 0.78, HEAD_Z - 0.04),
                    0.020, 0.003, 0.13, tusk,
                    rotation=(-48.0, sign * 26.0, 0.0), vertices=6), f"tusk_{side.lower()}")

    add(fc.box("Boar_Tail", (0.0, -0.55, RUMP_Z - 0.10), (0.03, 0.04, 0.20), hide), "tail")

    # Legs: short and thin under a heavy body — the reason it is faster than it
    # looks. Hind slightly lower, following the falling backline.
    for name, y, top in (("fore", 0.24, BELLY_Z), ("hind", -0.32, BELLY_Z - 0.04)):
        for side in ("L", "R"):
            sign = 1.0 if side == "L" else -1.0
            bone = f"{name}_{side.lower()}"
            add(fc.box(f"Boar_{name.title()}_Leg_{side}", (sign * 0.13, y, top * 0.5),
                       (0.085, 0.10, top), hide), bone)
            add(fc.box(f"Boar_{name.title()}_Hoof_{side}", (sign * 0.13, y + 0.01, 0.035),
                       (0.08, 0.10, 0.07), tusk), bone)

    return parts


# ── Poses ─────────────────────────────────────────────────────────────────────


def idle_pose(phase: float) -> tuple[fc.Pose, dict]:
    """Rooting. A boar at rest has its nose in the ground and is unbothered.

    FAUNA.md says neutral until provoked, and rooting is what neutral looks like:
    busy, head down, not watching you. The crest lies flat — that is the whole
    contrast `flee` trades against, so it has to be visibly down here.
    """
    root_dig = math.sin(phase * math.tau * 2.0)
    breathe = math.sin(phase * math.tau) * 1.4
    return (
        {
            "body": (breathe * 0.4 + 2.0, 0.0, root_dig * 1.5),
            # Small amplitude: the head is huge and has no neck to hide a seam in.
            "head": (8.0 + root_dig * 7.0, 0.0, root_dig * 5.0),
            "crest": (0.0, 0.0, 0.0),
            "tail": (0.0, 0.0, math.sin(phase * math.tau * 3.0) * 11.0),
        },
        {},
    )


def walk_pose(phase: float) -> tuple[fc.Pose, dict]:
    """A busy, short-strided four-beat.

    Short legs mean high cadence and low amplitude — a boar covers ground with
    many small steps rather than a few long ones, which is a different rhythm from
    both the deer and the cow at the same speed. The head stays down: it is walking
    somewhere to root, not looking around.
    """
    fore_l = math.sin(phase * math.tau)
    hind_r = math.sin((phase + 0.06) * math.tau)
    fore_r = math.sin((phase + 0.5) * math.tau)
    hind_l = math.sin((phase + 0.56) * math.tau)
    return (
        {
            "body": (2.0, 0.0, math.sin(phase * math.tau * 2.0) * 2.0),
            "head": (6.0 + math.sin(phase * math.tau * 2.0) * 3.0, 0.0, 0.0),
            "crest": (0.0, 0.0, 0.0),
            "fore_l": (fore_l * 19.0, 0.0, 0.0),
            "fore_r": (fore_r * 19.0, 0.0, 0.0),
            "hind_l": (hind_l * 18.0, 0.0, 0.0),
            "hind_r": (hind_r * 18.0, 0.0, 0.0),
            "tail": (0.0, 0.0, math.sin(phase * math.tau * 2.0) * 8.0),
        },
        {"body": (0.0, 0.0, abs(math.sin(phase * math.tau * 2.0)) * 0.012)},
    )


def flee_pose(phase: float) -> tuple[fc.Pose, dict]:
    """The charge.

    Named `flee` because D-218 fixes one clip vocabulary across the batch, but on
    this species the "fast" state is a CHARGE and it is authored as one. FAUNA.md
    is explicit that the boar exists to teach that not everything runs away, so a
    clip of it scurrying off would undo the animal's entire reason for being in
    the roster.

    Three things say charge rather than run, and all three are the real animal:
    the body levels out and drives forward instead of bounding; the crest goes UP,
    which is the tell that it has decided; and the head drops slightly, aiming the
    tusks. High cadence, almost no vertical — a boar charges FLAT.
    """
    stride = math.sin(phase * math.tau * 2.0)
    return (
        {
            # Levelled and driving. Note the small vertical: no bound, no gallop.
            "body": (-2.0, 0.0, stride * 2.0),
            # Head down, tusks forward.
            "head": (12.0, 0.0, 0.0),
            # The tell. Up and held — this is the frame a player should read.
            "crest": (-26.0, 0.0, 0.0),
            "fore_l": (stride * 34.0, 0.0, 0.0),
            "fore_r": (-stride * 34.0, 0.0, 0.0),
            "hind_l": (-stride * 32.0, 0.0, 0.0),
            "hind_r": (stride * 32.0, 0.0, 0.0),
            "tail": (-30.0, 0.0, 0.0),
        },
        {"body": (0.0, 0.0, abs(stride) * 0.014)},
    )


def death_keys() -> list[tuple[int, fc.Pose, dict]]:
    """Momentum first: it is moving when it dies, so it goes down forward and
    slides, rather than folding in place like the cow.

    The crest drops in the second key and that is the readable moment — the tell
    going away is how a player knows it is over.
    """
    return [
        (1, {"crest": (-20.0, 0.0, 0.0), "head": (10.0, 0.0, 0.0)}, {}),
        (
            7,
            {"body": (-16.0, 0.0, 6.0), "head": (20.0, 0.0, 0.0), "crest": (-6.0, 0.0, 0.0),
             "fore_l": (44.0, 0.0, 0.0), "fore_r": (38.0, 0.0, 0.0)},
            {"body": (0.0, 0.0, -0.10)},
        ),
        (
            18,
            {"body": (-6.0, 70.0, 0.0), "head": (-14.0, 0.0, 12.0), "crest": (0.0, 0.0, 0.0),
             "fore_l": (60.0, 0.0, 14.0), "fore_r": (52.0, 0.0, -10.0),
             "hind_l": (46.0, 0.0, 12.0), "hind_r": (40.0, 0.0, -10.0), "tail": (-14.0, 0.0, 0.0)},
            {"body": (0.0, 0.0, -SHOULDER_Z + 0.28)},
        ),
        (
            1 + fc.DEATH_FRAMES,
            {"body": (-4.0, 84.0, 0.0), "head": (-18.0, 0.0, 16.0), "crest": (0.0, 0.0, 0.0),
             "fore_l": (66.0, 0.0, 16.0), "fore_r": (56.0, 0.0, -12.0),
             "hind_l": (50.0, 0.0, 14.0), "hind_r": (42.0, 0.0, -12.0), "tail": (-18.0, 0.0, 0.0)},
            {"body": (0.0, 0.0, -SHOULDER_Z + 0.24)},
        ),
    ]


def main() -> None:
    with import_cache_guard():
        bpy.ops.wm.read_factory_settings(use_empty=True)
        reset_materials()
        bpy.context.scene.render.fps = fc.FPS

        armature, mesh = fc.build_rig(SPECIES, build_parts(), BONES)

        fc.build_cycle(armature, SPECIES, fc.CLIP_IDLE, fc.IDLE_FRAMES, idle_pose, samples=12)
        fc.build_cycle(armature, SPECIES, fc.CLIP_WALK, fc.WALK_FRAMES, walk_pose, samples=12)
        fc.build_cycle(armature, SPECIES, fc.CLIP_FLEE, fc.FLEE_FRAMES, flee_pose, samples=10)
        fc.build_oneshot(armature, SPECIES, fc.CLIP_DEATH, death_keys())

        fc.export_species(SPECIES, [armature, mesh], armature)
        fc.merge_catalog([
            fc.catalog_row(
                SPECIES,
                [mesh],
                "Wild boar. A front-heavy wedge: shoulder hump is the tallest point, backline falls "
                "away to a lower rump, head huge and low with effectively no neck. Short thin legs "
                "under a heavy body, small up-and-out tusks. Its fast clip is a CHARGE, not a run — "
                "flat, driving, with the dorsal crest raised as the tell.",
            )
        ])
        fc.SOURCE_DIR.mkdir(parents=True, exist_ok=True)
        bpy.ops.wm.save_as_mainfile(filepath=str(fc.SOURCE_DIR / f"fauna_{SPECIES}.blend"))
        print(f"FAUNA_BUILD {SPECIES} ok")


if __name__ == "__main__":
    main()
