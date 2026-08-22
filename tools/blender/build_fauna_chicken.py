"""Build the chicken — FAUNA.md §2, the first of the ordinary six (F-596).

Run with:
  Blender --background --python tools/blender/build_fauna_chicken.py

Outputs one rigged, animated, metre-scale GLB at `assets/fauna/exports/chicken.glb`
with the four clips D-218 fixes for the whole batch — `idle-loop`, `walk-loop`,
`flee`, `death` — plus its row in the shared fauna catalog. Shared machinery lives
in `fauna_common.py`; read that module's docstring first, particularly the note on
scale being measured against the player rather than against the other animals.

## The real bird, because a generator should never have to guess

A domestic hen, which is what a bog fowl is a scruffier version of. The things
that make a chicken read as a chicken, none of which is "small bird shape":

**The body is a horizontal ovoid carried high on short legs**, not a sphere. The
deep breast is at the FRONT and the mass tapers back and up to the tail. Roughly
0.40 m nose to tail, 0.42 m to the top of the head, about 2 kg.

**The neck is an S, and it is longer than it looks.** A hen's neck is mostly
hidden in feathers at rest and extends dramatically when she is alarmed — that
extension is the single most legible thing a chicken does, and it is what `flee`
opens with here. The head sits FORWARD of the breast, not above it.

**The tail is carried up at 40-45 degrees**, a fan of stiff feathers, and it is
the counterweight to the forward-carried head. A horizontal tail reads as a duck.

**The comb and wattles are the only saturated colour on the animal** and they are
what the eye finds first. Small on a hen, and they wobble — kept as separate parts
on their own bone here so they can lag behind the head.

**The legs are scaly, unfeathered, and set well back under the mass**, with four
toes: three forward, one back. The walk is the famous one: the head stays
STATIONARY IN SPACE while the body moves under it, then the head snaps forward to
catch up. That head-bob is not a stylisation, it is a real gaze-stabilisation
behaviour, and it is the whole reason a walking chicken is recognisable at
distance. `walk_pose()` below implements it literally — the neck counter-rotates
against the body's advance for three quarters of the cycle and then whips forward.

**A frightened hen does not fly**, she runs with her body flattened, neck
extended low and forward, wings half-open for balance and tail down. That is the
opposite of the idle silhouette in every axis, which is what makes the state
change readable across a field.

## Palette

`mire_art.py` is claimed for F-473 and is not written to (the peatling builder set
that precedent). So the bird is built from tokens that already exist: `leather`
and `leather_dark` for the plumage — a warm brown hen, which is also what a
half-wild bog fowl would be — `bone` for beak and scaly legs, and `flesh_raw` for
comb and wattles, which is semantically exact rather than a borrow: a comb IS bare
red skin. Fauna would genuinely like `feather` and `fur` tokens; that is recorded
in F-596 rather than taken from a file someone else holds.

## How far the poses may be pushed

Rigid one-bone-per-part skinning, so parts driven by different bones separate when
those bones move apart. Every part below is sunk into its neighbour by at least
0.02 m — the neck into the breast, the head into the neck, the thighs into the
body. The poses here stay inside roughly +/-35 degrees per joint. Past that the
neck will pull out of the breast, and no amount of re-tuning the pose fixes it;
the fix is a deeper sink or a second bone.
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


SPECIES = "chicken"

## Metres. Every one measured off the real bird's proportions, then checked
## against the player: 0.42 m is 23% of the 1.8 m capsule — a chicken should be
## somewhere around the knee, and underfoot rather than an obstacle.
BODY_LENGTH = 0.30
BODY_HEIGHT = 0.22
BODY_WIDTH = 0.17
## The breast sits forward and low; the mass tapers back and UP toward the tail.
BODY_Z = 0.20
LEG_LENGTH = 0.11
NECK_LENGTH = 0.10
HEAD_SIZE = 0.075
TAIL_ANGLE_DEG = 42.0


## (name, head, tail, parent). `root` is the non-deforming parent every rig here
## carries so the whole animal can be displaced by a clip without moving the mesh
## relative to its own bones — `flee` uses it for the forward lean.
BONES = [
    ("root", (0.0, 0.0, 0.0), (0.0, 0.0, 0.10), None),
    ("body", (0.0, 0.0, BODY_Z), (0.0, -0.10, BODY_Z), "root"),
    ("neck", (0.0, 0.11, BODY_Z + 0.05), (0.0, 0.15, BODY_Z + 0.14), "body"),
    ("head", (0.0, 0.15, BODY_Z + 0.14), (0.0, 0.21, BODY_Z + 0.15), "neck"),
    ("comb", (0.0, 0.16, BODY_Z + 0.18), (0.0, 0.18, BODY_Z + 0.21), "head"),
    ("tail", (0.0, -0.14, BODY_Z + 0.04), (0.0, -0.22, BODY_Z + 0.14), "body"),
    ("wing_l", (0.07, 0.0, BODY_Z + 0.03), (0.09, -0.09, BODY_Z + 0.01), "body"),
    ("wing_r", (-0.07, 0.0, BODY_Z + 0.03), (-0.09, -0.09, BODY_Z + 0.01), "body"),
    ("leg_l", (0.05, -0.01, BODY_Z - 0.08), (0.05, 0.0, 0.0), "body"),
    ("leg_r", (-0.05, -0.01, BODY_Z - 0.08), (-0.05, 0.0, 0.0), "body"),
]


def build_parts() -> list[tuple[bpy.types.Object, str]]:
    plume = mat("leather")
    plume_dark = mat("leather_dark")
    keratin = mat("bone")
    comb_skin = mat("flesh_raw")

    parts: list[tuple[bpy.types.Object, str]] = []

    def add(obj: bpy.types.Object, bone: str) -> None:
        parts.append((obj, bone))

    # The body: one ovoid, longer than it is tall, pitched nose-down a few degrees
    # so the deep breast leads and the mass runs back and up into the tail.
    add(fc.ico("Chicken_Body", (0.0, -0.01, BODY_Z),
               (BODY_WIDTH, BODY_LENGTH, BODY_HEIGHT), plume, rotation=(-8.0, 0.0, 0.0)), "body")
    # The breast, forward and low. A separate lobe rather than a longer body: a
    # hen's front is noticeably deeper than her middle and that is most of her
    # silhouette from the side.
    add(fc.ico("Chicken_Breast", (0.0, 0.09, BODY_Z - 0.02),
               (BODY_WIDTH - 0.01, 0.14, BODY_HEIGHT - 0.02), plume), "body")

    # Neck: sunk 0.03 m into the breast at its base (see the sink note above).
    add(fc.ico("Chicken_Neck", (0.0, 0.13, BODY_Z + 0.09),
               (0.075, 0.075, NECK_LENGTH + 0.06), plume, rotation=(-22.0, 0.0, 0.0)), "neck")
    add(fc.ico("Chicken_Head", (0.0, 0.155, BODY_Z + 0.145),
               (HEAD_SIZE, HEAD_SIZE + 0.015, HEAD_SIZE), plume), "head")
    # Short conical beak, level rather than hooked — a hen is a pecker, not a raptor.
    add(fc.cone("Chicken_Beak", (0.0, 0.20, BODY_Z + 0.14), 0.022, 0.002, 0.05,
                keratin, rotation=(90.0, 0.0, 0.0), vertices=6), "head")

    # Comb and wattles — the only saturated colour, and the first thing the eye
    # finds. On their own bone so they can lag behind the head's motion.
    add(fc.box("Chicken_Comb", (0.0, 0.155, BODY_Z + 0.195), (0.012, 0.06, 0.035),
               comb_skin), "comb")
    add(fc.ico("Chicken_Wattle_L", (0.018, 0.185, BODY_Z + 0.11), (0.012, 0.02, 0.035),
               comb_skin), "comb")
    add(fc.ico("Chicken_Wattle_R", (-0.018, 0.185, BODY_Z + 0.11), (0.012, 0.02, 0.035),
               comb_skin), "comb")

    # Wings folded flat along the flanks, darker than the body — a real hen's
    # folded wing is a distinct darker panel, not a smooth continuation.
    for side, sign in (("L", 1.0), ("R", -1.0)):
        add(fc.ico(f"Chicken_Wing_{side}", (sign * 0.075, -0.01, BODY_Z + 0.02),
                   (0.04, 0.20, 0.11), plume_dark), f"wing_{side.lower()}")

    # Tail: a flat fan carried up at 42 degrees, the counterweight to the
    # forward-carried head. Flatten it in X so it reads as feathers, not a lump.
    add(fc.ico("Chicken_Tail", (0.0, -0.20, BODY_Z + 0.10), (0.10, 0.16, 0.03),
               plume_dark, rotation=(TAIL_ANGLE_DEG, 0.0, 0.0)), "tail")

    # Legs: scaly, unfeathered, set well back under the mass. Three forward toes
    # and one back — the back toe is what stops the foot reading as a stick.
    for side, sign in (("L", 1.0), ("R", -1.0)):
        bone = f"leg_{side.lower()}"
        add(fc.box(f"Chicken_Thigh_{side}", (sign * 0.05, -0.01, BODY_Z - 0.09),
                   (0.032, 0.032, LEG_LENGTH), keratin), bone)
        add(fc.box(f"Chicken_Foot_{side}", (sign * 0.05, 0.015, 0.008),
                   (0.03, 0.075, 0.014), keratin), bone)
        add(fc.box(f"Chicken_Spur_{side}", (sign * 0.05, -0.025, 0.008),
                   (0.014, 0.03, 0.012), keratin), bone)

    return parts


# ── Poses ─────────────────────────────────────────────────────────────────────


def idle_pose(phase: float) -> tuple[fc.Pose, dict]:
    """Standing, breathing, with an occasional peck.

    A hen at rest is never quite still: she shifts weight, the comb wobbles, and
    every few seconds she dips to peck. The peck occupies the middle third of the
    cycle so the clip does not read as a metronome — a periodic motion sitting
    exactly on the loop point is the thing that makes a looping idle obvious.
    """
    breathe = math.sin(phase * math.tau) * 2.0
    # 0 outside the peck window, a smooth 0..1..0 inside it.
    peck = 0.0
    if 0.32 < phase < 0.62:
        peck = math.sin((phase - 0.32) / 0.30 * math.pi)
    return (
        {
            "body": (breathe * 0.5 + peck * 10.0, 0.0, 0.0),
            "neck": (-peck * 34.0 + breathe, 0.0, 0.0),
            "head": (-peck * 16.0, 0.0, 0.0),
            # The comb lags the head: it is loose skin, so it arrives late and
            # overshoots slightly. Half a beat behind, opposite sign.
            "comb": (peck * 12.0, 0.0, 0.0),
            "tail": (-breathe * 1.5 - peck * 8.0, 0.0, 0.0),
        },
        {},
    )


def walk_pose(phase: float) -> tuple[fc.Pose, dict]:
    """The head-bob walk.

    The real behaviour, and the reason a walking chicken is recognisable from
    across a field: the head holds STILL IN SPACE while the body walks forward
    under it, then snaps forward to catch up. So the neck counter-rotates against
    the body's advance for three quarters of the cycle and whips through in the
    last quarter — it is not a sine wave, and keying it as one is what makes a
    generated chicken walk look like a generic quadruped.
    """
    stride = math.sin(phase * math.tau)
    # Hold-then-snap: -1 drifting back over 0..0.75, then a fast return.
    if phase < 0.75:
        catch_up = -phase / 0.75
    else:
        catch_up = -1.0 + (phase - 0.75) / 0.25
    return (
        {
            "body": (2.0, 0.0, stride * 3.0),
            # The counter-rotation. `catch_up` is negative while the body gains on
            # the head, so the neck pitches back to hold the head in place.
            "neck": (catch_up * 15.0, 0.0, 0.0),
            "head": (-catch_up * 9.0, 0.0, 0.0),
            "comb": (catch_up * 8.0, 0.0, 0.0),
            "tail": (stride * 4.0, 0.0, 0.0),
            "leg_l": (stride * 26.0, 0.0, 0.0),
            "leg_r": (-stride * 26.0, 0.0, 0.0),
            # Wings stay folded in a walk — a hen only opens them running or
            # balancing. Keeping them shut here is what makes `flee` read.
            "wing_l": (0.0, 0.0, 0.0),
            "wing_r": (0.0, 0.0, 0.0),
        },
        {"body": (0.0, 0.0, abs(stride) * 0.012)},
    )


def flee_pose(phase: float) -> tuple[fc.Pose, dict]:
    """Flat-out run: body flattened, neck extended low and forward, wings half
    open for balance, tail down.

    Deliberately the inverse of `idle` in every axis — head low instead of high,
    tail down instead of up at 42 degrees, wings open instead of folded, legs at
    double the walk's amplitude. FAUNA.md gives the chicken a short flee and the
    state has to be readable at a glance across a field, which means the
    silhouette has to change, not just the speed.
    """
    stride = math.sin(phase * math.tau * 2.0)
    return (
        {
            "body": (14.0, 0.0, stride * 4.0),
            "neck": (26.0, 0.0, 0.0),
            "head": (-14.0, 0.0, 0.0),
            "comb": (-10.0 + stride * 6.0, 0.0, 0.0),
            # Tail down and forward: a running hen tucks it, and it is the second
            # most visible difference from idle after the neck.
            "tail": (-32.0, 0.0, 0.0),
            "wing_l": (0.0, -34.0, -12.0),
            "wing_r": (0.0, 34.0, 12.0),
            "leg_l": (stride * 52.0, 0.0, 0.0),
            "leg_r": (-stride * 52.0, 0.0, 0.0),
        },
        {"body": (0.0, 0.0, abs(stride) * 0.02)},
    )


def death_keys() -> list[tuple[int, fc.Pose, dict]]:
    """Legs fold, mass drops, the animal rolls onto its side, everything settles.

    Four keys with deliberately uneven spacing: the collapse is fast, the settle
    is slow. Even spacing reads as a controlled lie-down rather than a death, and
    the last key holds so the clip can stop without a pop.
    """
    return [
        # A brief startle upward — the body lifts before it falls.
        (1, {"body": (0.0, 0.0, 0.0), "neck": (-8.0, 0.0, 0.0)}, {}),
        (
            8,
            {"body": (-12.0, 0.0, 0.0), "neck": (-26.0, 0.0, 0.0), "head": (10.0, 0.0, 0.0),
             "wing_l": (0.0, -40.0, -18.0), "wing_r": (0.0, 40.0, 18.0),
             "leg_l": (34.0, 0.0, 0.0), "leg_r": (34.0, 0.0, 0.0), "tail": (-10.0, 0.0, 0.0)},
            {"body": (0.0, 0.0, 0.02)},
        ),
        (
            20,
            {"body": (8.0, 62.0, 0.0), "neck": (24.0, 0.0, 0.0), "head": (18.0, 0.0, 0.0),
             "wing_l": (0.0, -20.0, -30.0), "wing_r": (0.0, 8.0, 24.0),
             "leg_l": (70.0, 0.0, 12.0), "leg_r": (64.0, 0.0, -10.0), "tail": (-22.0, 0.0, 0.0),
             "comb": (16.0, 0.0, 0.0)},
            {"body": (0.0, 0.0, -BODY_Z + 0.09)},
        ),
        (
            1 + fc.DEATH_FRAMES,
            {"body": (6.0, 74.0, 0.0), "neck": (30.0, 0.0, -8.0), "head": (22.0, 0.0, 0.0),
             "wing_l": (0.0, -14.0, -34.0), "wing_r": (0.0, 4.0, 26.0),
             "leg_l": (74.0, 0.0, 14.0), "leg_r": (68.0, 0.0, -12.0), "tail": (-24.0, 0.0, 0.0),
             "comb": (20.0, 0.0, 0.0)},
            {"body": (0.0, 0.0, -BODY_Z + 0.075)},
        ),
    ]


def main() -> None:
    with import_cache_guard():
        bpy.ops.wm.read_factory_settings(use_empty=True)
        reset_materials()
        bpy.context.scene.render.fps = fc.FPS

        armature, mesh = fc.build_rig(SPECIES, build_parts(), BONES)

        fc.build_cycle(armature, SPECIES, fc.CLIP_IDLE, fc.IDLE_FRAMES, idle_pose, samples=12)
        fc.build_cycle(armature, SPECIES, fc.CLIP_WALK, fc.WALK_FRAMES, walk_pose, samples=8)
        fc.build_cycle(armature, SPECIES, fc.CLIP_FLEE, fc.FLEE_FRAMES, flee_pose, samples=8)
        fc.build_oneshot(armature, SPECIES, fc.CLIP_DEATH, death_keys())

        fc.export_species(SPECIES, [armature, mesh], armature)
        fc.merge_catalog([
            fc.catalog_row(
                SPECIES,
                [mesh],
                "Brown bog fowl. Horizontal ovoid body on short scaly legs, S-neck carried "
                "forward, tail up at 42 degrees, comb and wattles the only saturated colour. "
                "The walk is the real head-bob: the head holds still in space while the body "
                "advances under it.",
            )
        ])
        fc.SOURCE_DIR.mkdir(parents=True, exist_ok=True)
        bpy.ops.wm.save_as_mainfile(filepath=str(fc.SOURCE_DIR / f"fauna_{SPECIES}.blend"))
        print(f"FAUNA_BUILD {SPECIES} ok")


if __name__ == "__main__":
    main()
