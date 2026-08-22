"""Build the songbird — FAUNA.md §2 #6 (F-596, D-220).

Run with:
  Blender --background --python tools/blender/build_fauna_songbird.py

Outputs `assets/fauna/exports/songbird.glb` with the batch's four clips. Shared
machinery in `fauna_common.py`.

## What this species is FOR, because it changes every decision below

FAUNA.md: *"Flocking, flush when approached, never land near the player. None
[drops]. Pure atmosphere. Their silence is a tell."* This is the only one of the
six that a player never interacts with and never kills. It exists so that its
ABSENCE means something — birds stop where the Mire has been, and a quiet wood is
information.

Two consequences that would otherwise look like corners cut:

**The flock is the silhouette, not the bird.** At 0.14 m nothing about an
individual is legible past a few metres, so the model is built to read as a shape
in motion against the sky rather than as a bird you inspect. Detail that would
never be seen is detail that costs frame time on the low-end machines this project
targets, and there will be many of these on screen at once.

**`death` exists but is not a kill animation.** Nothing drops and nothing hunts
these. The clip is what plays when a bird is despawned near corruption — it flies
UP and out rather than falling, because the fiction is that the flock leaves. A
songbird dropping dead out of the sky would say something the design does not mean.

## The real animal

A small passerine of the thrush/finch build — the generic European songbird
silhouette rather than a named species, because the flock reads as "birds" and a
specific plumage would be invisible at the size it is seen.

**A perched songbird is a rounded body with almost no visible neck**, tilted
slightly nose-up, with the tail as a long flat rectangle behind and the head set
directly on the shoulders. The eye is large relative to the head.

**In flight the wings sweep BACK, not straight out.** A small bird's flapping
flight has the wings folding back on the upstroke and the body bobbing along a
shallow undulating path — the bounding flight of finches, which is why a flock
looks like it is skipping rather than gliding. That undulation is in `flee` here.

**Wing beats are fast and the downstroke is the powered half.** The clip is
authored asymmetrically for that reason: the downstroke covers more of the cycle
than the recovery, which is what stops it reading as a metronome flapping.

## Scale against the player

0.14 m, 8% of the 1.8 m player capsule. Comfortably the smallest thing in the
batch, and it should be — the hare and the chicken are "underfoot", this is
"overhead and elsewhere".

## How far the poses may be pushed

Rigid one-bone-per-part skinning on a very small mesh, so tolerances are tight in
absolute terms — 0.01 m of separation is visible here. The wings are the only
parts that travel far and they are rooted inside the body by half their own root
width. Nothing else moves more than a few degrees.
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


SPECIES = "songbird"

## Metres. Small enough that every number here is within a centimetre or two of
## another, which is why the parts overlap deliberately rather than merely
## touching. The first build came out 0.08 m — a real perched songbird of this
## build is 0.14 m, so the whole bird was scaled up by about 1.4x rather than the
## authored figure being lowered to match what had been modelled. The catalog
## number describes the animal; the mesh follows it, never the other way round.
BODY_Z = 0.082
BODY_LENGTH = 0.105
BODY_HEIGHT = 0.098
WING_SPAN_HALF = 0.105


BONES = [
    ("root", (0.0, 0.0, 0.0), (0.0, 0.0, 0.04), None),
    ("body", (0.0, 0.0, BODY_Z), (0.0, -0.04, BODY_Z), "root"),
    ("head", (0.0, 0.035, BODY_Z + 0.025), (0.0, 0.06, BODY_Z + 0.03), "body"),
    ("wing_l", (0.014, 0.005, BODY_Z + 0.01), (WING_SPAN_HALF, -0.01, BODY_Z + 0.02), "body"),
    ("wing_r", (-0.014, 0.005, BODY_Z + 0.01), (-WING_SPAN_HALF, -0.01, BODY_Z + 0.02), "body"),
    ("tail", (0.0, -0.04, BODY_Z), (0.0, -0.10, BODY_Z - 0.005), "body"),
]


def build_parts() -> list[tuple[bpy.types.Object, str]]:
    plume = mat("leather_dark")
    plume_light = mat("cloth")
    beak = mat("bone")
    eye = mat("mire_black")

    parts: list[tuple[bpy.types.Object, str]] = []

    def add(obj: bpy.types.Object, bone: str) -> None:
        parts.append((obj, bone))

    # Rounded body, tilted nose-up — the perched posture.
    add(fc.ico("Songbird_Body", (0.0, 0.0, BODY_Z),
               (0.066, BODY_LENGTH, BODY_HEIGHT), plume, rotation=(-14.0, 0.0, 0.0)), "body")
    # Pale breast. At this size it is the only colour break that survives distance,
    # which is why it is here and a wingbar is not.
    add(fc.ico("Songbird_Breast", (0.0, 0.030, BODY_Z - 0.016),
               (0.056, 0.066, 0.054), plume_light), "body")

    # Head straight onto the shoulders — no visible neck on a perched songbird.
    add(fc.ico("Songbird_Head", (0.0, 0.058, BODY_Z + 0.058),
               (0.052, 0.055, 0.055), plume), "head")
    add(fc.cone("Songbird_Beak", (0.0, 0.094, BODY_Z + 0.052), 0.011, 0.001, 0.028,
                beak, rotation=(90.0, 0.0, 0.0), vertices=5), "head")
    # Large relative to the head, as on the real bird. Two small spheres rather
    # than a texture, because there is no texture budget at this size.
    for sign in (1.0, -1.0):
        add(fc.ico(f"Songbird_Eye_{'L' if sign > 0 else 'R'}",
                   (sign * 0.022, 0.072, BODY_Z + 0.063), (0.013, 0.013, 0.013),
                   eye, subdivisions=1), "head")

    # Wings, swept BACK at rest rather than straight out — folded along the flanks.
    for side, sign in (("L", 1.0), ("R", -1.0)):
        add(fc.ico(f"Songbird_Wing_{side}", (sign * 0.056, -0.007, BODY_Z + 0.017),
                   (0.098, 0.087, 0.020), plume,
                   rotation=(0.0, 0.0, sign * -18.0)), f"wing_{side.lower()}")

    # Tail: a long flat rectangle. On a small bird it is a third of total length
    # and it is most of what makes the perched silhouette read as a bird at all.
    add(fc.box("Songbird_Tail", (0.0, -0.100, BODY_Z - 0.006),
               (0.042, 0.098, 0.010), plume), "tail")

    return parts


# ── Poses ─────────────────────────────────────────────────────────────────────


def idle_pose(phase: float) -> tuple[fc.Pose, dict]:
    """Perched: tiny, constant, twitchy adjustments.

    A small bird is never still and never smooth — it holds a pose then snaps to
    another. So the head motion here is stepped rather than sinusoidal: three
    discrete looks per cycle with fast transitions, which is what reads as a bird
    rather than as a bobbing ornament.
    """
    step = int(phase * 3.0) % 3
    look = [0.0, 26.0, -22.0][step]
    # A short fast blend into each new look rather than a slow drift between them.
    blend = min(1.0, (phase * 3.0 - float(int(phase * 3.0))) * 5.0)
    previous = [0.0, 26.0, -22.0][(step + 2) % 3]
    yaw = previous + (look - previous) * blend
    breathe = math.sin(phase * math.tau * 4.0) * 1.2
    return (
        {
            "body": (breathe * 0.5, 0.0, 0.0),
            "head": (breathe, 0.0, yaw),
            "tail": (math.sin(phase * math.tau * 2.0) * 4.0, 0.0, 0.0),
            "wing_l": (0.0, 0.0, 0.0),
            "wing_r": (0.0, 0.0, 0.0),
        },
        {},
    )


def walk_pose(phase: float) -> tuple[fc.Pose, dict]:
    """A hop along a branch.

    Songbirds of this build hop with both feet together rather than walking. Kept
    small: this clip will mostly be seen from several metres away, and a large
    motion at that distance reads as a glitch rather than as a hop.
    """
    hop = max(0.0, math.sin(phase * math.tau))
    return (
        {
            "body": (-hop * 12.0, 0.0, 0.0),
            "head": (hop * 6.0, 0.0, 0.0),
            "tail": (hop * 14.0, 0.0, 0.0),
            "wing_l": (0.0, 0.0, -hop * 10.0),
            "wing_r": (0.0, 0.0, hop * 10.0),
        },
        {"body": (0.0, 0.0, hop * 0.022)},
    )


def flee_pose(phase: float) -> tuple[fc.Pose, dict]:
    """The flush: fast asymmetric wingbeats and a bounding, undulating path.

    Two things make this read as a small bird rather than as a flapping shape.
    The downstroke is the POWERED half and takes more of the cycle than the
    recovery, so the beat is uneven — an even flap is a butterfly. And the body
    rises and falls along a shallow undulation, the bounding flight of finches,
    which is why a flock of them looks like it is skipping across the sky.

    Ends where it begins so the cycle closes: `_ends_match()` in the art check
    holds every `-loop` clip to that, and a flight cycle that drifts a few degrees
    per loop is a bird slowly rolling onto its back.
    """
    beat = phase * math.tau
    # Asymmetric: sin biased so the downstroke occupies more of the cycle.
    stroke = math.sin(beat) - 0.35 * math.sin(beat * 2.0)
    undulate = math.sin(beat)
    return (
        {
            "body": (-undulate * 9.0, 0.0, 0.0),
            "head": (undulate * 4.0, 0.0, 0.0),
            # Sweep back on the recovery, drive down and forward on the power half.
            "wing_l": (0.0, -stroke * 12.0, -stroke * 58.0),
            "wing_r": (0.0, stroke * 12.0, stroke * 58.0),
            "tail": (undulate * 10.0, 0.0, 0.0),
        },
        {"body": (0.0, 0.0, undulate * 0.05)},
    )


def death_keys() -> list[tuple[int, fc.Pose, dict]]:
    """NOT a kill animation — the flock leaving.

    Nothing hunts these and they drop nothing (FAUNA.md). This clip plays when a
    bird despawns near corruption, and the design's whole point is that their
    ABSENCE is a tell. So it climbs away hard rather than falling: three fast
    beats, body pitched up, gaining height across the clip. A songbird dropping
    dead out of the sky would say something the design does not mean — that the
    Mire kills birds, rather than that birds leave before it arrives.
    """
    return [
        (1, {"body": (0.0, 0.0, 0.0)}, {}),
        (
            8,
            {"body": (-26.0, 0.0, 8.0), "head": (-10.0, 0.0, 0.0),
             "wing_l": (0.0, -14.0, -62.0), "wing_r": (0.0, 14.0, 62.0),
             "tail": (18.0, 0.0, 0.0)},
            {"body": (0.0, 0.0, 0.16)},
        ),
        (
            20,
            {"body": (-34.0, 0.0, -14.0), "head": (-12.0, 0.0, -8.0),
             "wing_l": (0.0, -18.0, -48.0), "wing_r": (0.0, 18.0, 48.0),
             "tail": (22.0, 0.0, -6.0)},
            {"body": (0.0, 0.0, 0.52)},
        ),
        (
            1 + fc.DEATH_FRAMES,
            {"body": (-38.0, 0.0, -22.0), "head": (-12.0, 0.0, -12.0),
             "wing_l": (0.0, -20.0, -56.0), "wing_r": (0.0, 20.0, 56.0),
             "tail": (24.0, 0.0, -9.0)},
            {"body": (0.0, 0.0, 0.95)},
        ),
    ]


def main() -> None:
    with import_cache_guard():
        bpy.ops.wm.read_factory_settings(use_empty=True)
        reset_materials()
        bpy.context.scene.render.fps = fc.FPS

        armature, mesh = fc.build_rig(SPECIES, build_parts(), BONES)

        fc.build_cycle(armature, SPECIES, fc.CLIP_IDLE, fc.IDLE_FRAMES, idle_pose, samples=18)
        fc.build_cycle(armature, SPECIES, fc.CLIP_WALK, fc.WALK_FRAMES, walk_pose, samples=10)
        fc.build_cycle(armature, SPECIES, fc.CLIP_FLEE, fc.FLEE_FRAMES, flee_pose, samples=12)
        fc.build_oneshot(armature, SPECIES, fc.CLIP_DEATH, death_keys())

        fc.export_species(SPECIES, [armature, mesh], armature)
        fc.merge_catalog([
            fc.catalog_row(
                SPECIES,
                [mesh],
                "Small passerine, built to read as a flock rather than as an individual — nothing "
                "at 0.14 m is legible past a few metres and there will be many on screen. Perched "
                "silhouette is a rounded body with no visible neck and a long flat tail. Flee is "
                "bounding flight with an asymmetric powered downstroke. Its death clip is the flock "
                "LEAVING, climbing away — they go before the Mire arrives, they are not killed by it.",
            )
        ])
        fc.SOURCE_DIR.mkdir(parents=True, exist_ok=True)
        bpy.ops.wm.save_as_mainfile(filepath=str(fc.SOURCE_DIR / f"fauna_{SPECIES}.blend"))
        print(f"FAUNA_BUILD {SPECIES} ok")


if __name__ == "__main__":
    main()
