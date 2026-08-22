"""Build the brown hare — FAUNA.md §2 #4 (F-596, D-220).

Run with:
  Blender --background --python tools/blender/build_fauna_hare.py

Outputs `assets/fauna/exports/hare.glb` with the batch's four clips. Shared
machinery in `fauna_common.py`.

## The real animal

*Lepus europaeus*, the brown hare — explicitly NOT a rabbit, and every difference
between the two matters here because "rabbit" is what a generator defaults to.

**The ears are the animal.** A hare's ears are 9-11 cm — roughly the length of its
own head — carried upright and tipped with black. A rabbit's are shorter and
rounder. If one thing survives being seen at distance in long grass it is a pair
of black-tipped ears above the seedheads, which is also the only part of a hare a
player will usually see before it moves.

**The hind legs are enormous and the animal sits with its rump HIGHER than its
shoulders.** That backward-tilted stance is the hare posture, and it is what makes
it look permanently about to leave. A rabbit sits level and compact; a hare is
coiled.

**It does not burrow**, so it has no rabbit's crouch — it rests in a shallow form
in the open, ears down and body flattened, and it holds that until you are close.
That flattening is the idle here, and the ears coming UP is the first thing that
happens when it notices you.

**The flee is not a run, it is a series of enormous bounds** with the hind legs
landing ahead of the forelegs, and a hare jinks sideways rather than running
straight — FAUNA.md's "very fast, erratic, short flee bursts", and the reason it is
the skill-shot target. The jink is authored into the clip as a yaw swing, because a
straight-line bound would make it the easiest target in the roster rather than the
hardest.

## Scale against the player

0.40 m to the ear tips sitting, 22% of the 1.8 m player capsule — the same order as
the chicken, and deliberately so: the two smallest ordinary animals should read as
the same "underfoot" class, and the difference between them should be shape, not
size.

## How far the poses may be pushed

Rigid one-bone-per-part skinning, and this is the most fragile rig in the batch
because the parts are small — 0.02 m of separation is visible on an animal 0.24 m
tall. The ears are the exception and are deliberately generous: they are separate
bones with a deep root inside the skull, because the ears have to move a long way
and are the animal's whole expression.
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


SPECIES = "hare"

## Metres. RUMP_Z above SHOULDER_Z is the hare stance and is not a typo — the
## animal sits tilted back, coiled over its hind legs.
SHOULDER_Z = 0.17
RUMP_Z = 0.22
BODY_LENGTH = 0.34
BODY_WIDTH = 0.15
HEAD_Z = 0.22
EAR_LENGTH = 0.15


BONES = [
    ("root", (0.0, 0.0, 0.0), (0.0, 0.0, 0.08), None),
    ("body", (0.0, -0.04, 0.16), (0.0, 0.14, 0.18), "root"),
    ("head", (0.0, 0.15, HEAD_Z - 0.02), (0.0, 0.26, HEAD_Z - 0.04), "body"),
    # Rooted deep inside the skull: these travel further than anything else in the
    # batch and a shallow root would tear the ear out of the head.
    ("ear_l", (0.035, 0.13, HEAD_Z + 0.01), (0.05, 0.10, HEAD_Z + EAR_LENGTH), "head"),
    ("ear_r", (-0.035, 0.13, HEAD_Z + 0.01), (-0.05, 0.10, HEAD_Z + EAR_LENGTH), "head"),
    ("tail", (0.0, -0.20, 0.19), (0.0, -0.25, 0.17), "body"),
    ("fore_l", (0.055, 0.07, 0.11), (0.055, 0.07, 0.0), "body"),
    ("fore_r", (-0.055, 0.07, 0.11), (-0.055, 0.07, 0.0), "body"),
    # The engine. Long, folded, and set well back under the raised rump.
    ("hind_l", (0.07, -0.13, 0.15), (0.07, -0.06, 0.0), "body"),
    ("hind_r", (-0.07, -0.13, 0.15), (-0.07, -0.06, 0.0), "body"),
]


def build_parts() -> list[tuple[bpy.types.Object, str]]:
    fur = mat("leather")
    fur_dark = mat("leather_dark")
    pale = mat("cloth")
    tip = mat("mire_black")

    parts: list[tuple[bpy.types.Object, str]] = []

    def add(obj: bpy.types.Object, bone: str) -> None:
        parts.append((obj, bone))

    # The body, tilted: rump high, shoulders low. Coiled rather than compact.
    add(fc.ico("Hare_Body", (0.0, -0.04, (SHOULDER_Z + RUMP_Z) * 0.5),
               (BODY_WIDTH, BODY_LENGTH, 0.17), fur, rotation=(-13.0, 0.0, 0.0)), "body")
    add(fc.ico("Hare_Rump", (0.0, -0.15, RUMP_Z - 0.01),
               (BODY_WIDTH + 0.01, 0.19, 0.17), fur), "body")
    # Pale underside — a hare's belly and throat are near-white, and it is what
    # flashes when it turns.
    add(fc.ico("Hare_Belly", (0.0, -0.03, SHOULDER_Z - 0.05),
               (BODY_WIDTH - 0.02, 0.26, 0.08), pale), "body")

    # Head: long and narrow, not the round skull of a rabbit.
    add(fc.ico("Hare_Head", (0.0, 0.19, HEAD_Z - 0.02), (0.085, 0.15, 0.095), fur), "head")
    add(fc.ico("Hare_Muzzle", (0.0, 0.27, HEAD_Z - 0.05), (0.05, 0.07, 0.05), fur_dark), "head")

    # The ears. Long, upright, black-tipped — the animal's whole read at distance.
    for side, sign in (("L", 1.0), ("R", -1.0)):
        bone = f"ear_{side.lower()}"
        add(fc.ico(f"Hare_Ear_{side}", (sign * 0.045, 0.115, HEAD_Z + EAR_LENGTH * 0.5),
                   (0.035, 0.05, EAR_LENGTH), fur, rotation=(-6.0, sign * 8.0, 0.0)), bone)
        add(fc.ico(f"Hare_Ear_Tip_{side}", (sign * 0.05, 0.105, HEAD_Z + EAR_LENGTH - 0.015),
                   (0.032, 0.045, 0.04), tip, rotation=(-6.0, sign * 8.0, 0.0)), bone)

    add(fc.ico("Hare_Tail", (0.0, -0.22, 0.19), (0.045, 0.05, 0.05), pale), "tail")

    # Forelegs: short, thin, tucked under the chest.
    for side, sign in (("L", 1.0), ("R", -1.0)):
        add(fc.box(f"Hare_Fore_{side}", (sign * 0.055, 0.07, 0.055),
                   (0.035, 0.04, 0.11), fur), f"fore_{side.lower()}")
    # Hind legs: the engine. A long thigh and a long foot, both far bigger than the
    # forelegs — the size difference IS the animal's speed, visible standing still.
    for side, sign in (("L", 1.0), ("R", -1.0)):
        bone = f"hind_{side.lower()}"
        add(fc.ico(f"Hare_Thigh_{side}", (sign * 0.07, -0.12, 0.14),
                   (0.07, 0.16, 0.15), fur), bone)
        add(fc.box(f"Hare_Foot_{side}", (sign * 0.07, -0.03, 0.025),
                   (0.045, 0.17, 0.05), fur_dark), bone)

    return parts


# ── Poses ─────────────────────────────────────────────────────────────────────


def idle_pose(phase: float) -> tuple[fc.Pose, dict]:
    """Sitting in its form: flattened, ears mostly down, occasionally listening.

    A hare that does not burrow survives by not being noticed, so its idle is
    stillness with the ears doing all the work. The ear flick is the only large
    motion, and it is asymmetric — one ear at a time, which is what the real animal
    does and what stops the clip reading as a metronome.
    """
    breathe = math.sin(phase * math.tau) * 1.6
    left_flick = 0.0
    right_flick = 0.0
    if 0.18 < phase < 0.34:
        left_flick = math.sin((phase - 0.18) / 0.16 * math.pi)
    if 0.56 < phase < 0.78:
        right_flick = math.sin((phase - 0.56) / 0.22 * math.pi)
    return (
        {
            "body": (breathe * 0.6, 0.0, 0.0),
            "head": (6.0 - left_flick * 4.0, 0.0, 0.0),
            # Resting angle is BACK along the body, not upright — that is the
            # flattened form posture. Flicking brings one forward and up.
            "ear_l": (34.0 - left_flick * 40.0, 0.0, -6.0),
            "ear_r": (34.0 - right_flick * 40.0, 0.0, 6.0),
            "tail": (breathe, 0.0, 0.0),
        },
        {},
    )


def walk_pose(phase: float) -> tuple[fc.Pose, dict]:
    """A hop, not a walk.

    A hare at low speed moves in small bounds: forelegs land together, hind legs
    swing THROUGH and past them, body rocks. Authoring this as a four-beat walk
    like the deer's would be the single most wrong thing here — a hare has no
    walking gait to speak of, and a hopping animal keyed as a walking one reads as
    a small dog.
    """
    hop = math.sin(phase * math.tau)
    lift = max(0.0, math.sin(phase * math.tau))
    return (
        {
            "body": (-hop * 9.0, 0.0, 0.0),
            "head": (4.0 + hop * 5.0, 0.0, 0.0),
            "ear_l": (18.0 - lift * 12.0, 0.0, -5.0),
            "ear_r": (18.0 - lift * 12.0, 0.0, 5.0),
            # Forelegs together, hinds together, opposed — the hop signature.
            "fore_l": (-hop * 26.0, 0.0, 0.0),
            "fore_r": (-hop * 26.0, 0.0, 0.0),
            "hind_l": (hop * 32.0, 0.0, 0.0),
            "hind_r": (hop * 32.0, 0.0, 0.0),
        },
        {"body": (0.0, 0.0, lift * 0.045)},
    )


def flee_pose(phase: float) -> tuple[fc.Pose, dict]:
    """Enormous bounds, and a JINK.

    FAUNA.md makes this the skill-shot target — "the thing you miss with a bow" —
    and a hare that bounds in a straight line is the easiest target in the roster,
    not the hardest. So the yaw swings hard across the cycle: the animal is
    changing direction, not just moving fast. Ears flat back, body stretched at
    full extension, hind feet landing ahead of the forefeet.

    The jink is in the CLIP rather than left to the AI on purpose. Behaviour can
    steer the body, but the visual language of a hare's evasion is that its whole
    axis snaps sideways mid-bound, and a straight clip on a curved path does not
    produce that — it produces a sliding animal.
    """
    stretch = math.sin(phase * math.tau)
    lift = max(0.0, math.sin(phase * math.tau))
    jink = math.sin(phase * math.tau * 1.0) * 26.0
    return (
        {
            "body": (-stretch * 20.0, 0.0, jink),
            "head": (8.0 + stretch * 8.0, 0.0, -jink * 0.4),
            # Flat back along the spine — a fleeing hare's ears are down, and this
            # is the clearest difference from every other clip it has.
            "ear_l": (76.0, 0.0, -4.0),
            "ear_r": (76.0, 0.0, 4.0),
            "fore_l": (-stretch * 44.0, 0.0, 0.0),
            "fore_r": (-stretch * 44.0, 0.0, 0.0),
            "hind_l": (stretch * 52.0, 0.0, 0.0),
            "hind_r": (stretch * 52.0, 0.0, 0.0),
            "tail": (-18.0, 0.0, 0.0),
        },
        {"body": (0.0, 0.0, lift * 0.12)},
    )


def death_keys() -> list[tuple[int, fc.Pose, dict]]:
    """Small and fast — a hare drops where it is.

    Deliberately the shortest-reading death in the batch even though it uses the
    same frame count: the large motion is over in the first third and the rest is
    the ears settling, which is the only thing left with any mass to move.
    """
    return [
        (1, {"ear_l": (10.0, 0.0, -4.0), "ear_r": (10.0, 0.0, 4.0)}, {}),
        (
            6,
            {"body": (14.0, 34.0, 0.0), "head": (-16.0, 0.0, 10.0),
             "ear_l": (28.0, 0.0, -24.0), "ear_r": (34.0, 0.0, 18.0),
             "hind_l": (-28.0, 0.0, 10.0), "hind_r": (-24.0, 0.0, -8.0),
             "fore_l": (24.0, 0.0, 0.0), "fore_r": (20.0, 0.0, 0.0)},
            {"body": (0.0, 0.0, -0.07)},
        ),
        (
            16,
            {"body": (6.0, 76.0, 0.0), "head": (-22.0, 0.0, 16.0),
             "ear_l": (52.0, 0.0, -34.0), "ear_r": (60.0, 0.0, 26.0),
             "hind_l": (-16.0, 0.0, 14.0), "hind_r": (-12.0, 0.0, -12.0),
             "fore_l": (32.0, 0.0, 0.0), "fore_r": (28.0, 0.0, 0.0), "tail": (-10.0, 0.0, 0.0)},
            {"body": (0.0, 0.0, -0.11)},
        ),
        (
            1 + fc.DEATH_FRAMES,
            {"body": (6.0, 84.0, 0.0), "head": (-24.0, 0.0, 18.0),
             "ear_l": (58.0, 0.0, -38.0), "ear_r": (66.0, 0.0, 30.0),
             "hind_l": (-14.0, 0.0, 15.0), "hind_r": (-10.0, 0.0, -13.0),
             "fore_l": (34.0, 0.0, 0.0), "fore_r": (30.0, 0.0, 0.0), "tail": (-12.0, 0.0, 0.0)},
            {"body": (0.0, 0.0, -0.12)},
        ),
    ]


def main() -> None:
    with import_cache_guard():
        bpy.ops.wm.read_factory_settings(use_empty=True)
        reset_materials()
        bpy.context.scene.render.fps = fc.FPS

        armature, mesh = fc.build_rig(SPECIES, build_parts(), BONES)

        fc.build_cycle(armature, SPECIES, fc.CLIP_IDLE, fc.IDLE_FRAMES, idle_pose, samples=14)
        fc.build_cycle(armature, SPECIES, fc.CLIP_WALK, fc.WALK_FRAMES, walk_pose, samples=10)
        fc.build_cycle(armature, SPECIES, fc.CLIP_FLEE, fc.FLEE_FRAMES, flee_pose, samples=10)
        fc.build_oneshot(armature, SPECIES, fc.CLIP_DEATH, death_keys())

        fc.export_species(SPECIES, [armature, mesh], armature)
        fc.merge_catalog([
            fc.catalog_row(
                SPECIES,
                [mesh],
                "Brown hare, not a rabbit. Long black-tipped ears carried upright are the read at "
                "distance; rump sits HIGHER than the shoulders, coiled over huge hind legs. Idle is "
                "a flattened form with asymmetric ear flicks; it hops rather than walks; and flee "
                "is enormous bounds with a jink authored into the clip, ears flat back.",
            )
        ])
        fc.SOURCE_DIR.mkdir(parents=True, exist_ok=True)
        bpy.ops.wm.save_as_mainfile(filepath=str(fc.SOURCE_DIR / f"fauna_{SPECIES}.blend"))
        print(f"FAUNA_BUILD {SPECIES} ok")


if __name__ == "__main__":
    main()
