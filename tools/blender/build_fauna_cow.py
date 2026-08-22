"""Build the highland cow — FAUNA.md §2 #2 (F-596, D-220).

Run with:
  Blender --background --python tools/blender/build_fauna_cow.py

Outputs `assets/fauna/exports/cow.glb` with the four clips D-218 fixes for the
batch. Shared machinery in `fauna_common.py`.

D-220 settled the question this species was waiting on. Sequoyah: **"Real animal
designs"** — modelled from the real animal with real proportions, not restyled
toward the enemy roster. What stays MIRE's is the palette and the low-poly
treatment; what is realistic is the design.

## The real animal

A Highland, which is what FAUNA.md means by "highland-type, shaggy". It is a very
specific cow and almost nothing about it is the dairy silhouette people draw from
memory.

**It is a rectangle on short legs, not a barrel on long ones.** A Highland stands
about 1.2 m at the shoulder and is 2.4 m long — twice as long as it is tall, with
the belly line low and the legs largely buried in coat. The deer beside it in this
batch is the opposite animal: same shoulder height, half the mass, legs that are
most of its height. Getting that contrast right is most of the work, and it is why
these two are the pair worth checking against each other.

**The horns are the silhouette and they go OUT before they go up.** They emerge
sideways from the skull, sweep forward and level for most of their length, then
turn up at the tips. Span is 1.0-1.6 m — wider than the animal's own body. Horns
drawn as a curve straight up off the head is a dairy cow, or a bull.

**The fringe over the eyes is the second read.** A Highland's forelock hangs down
over its face far enough that the eyes are often not visible at all. It is not
decoration; it is the thing that makes the head recognisable from the front, and
it is modelled as its own slab here rather than implied by the head shape.

**The coat is long, doubled, and hangs.** It breaks the leg line completely — you
see a fringe skirt rather than four distinct legs — and the animal reads as heavier
and lower than its skeleton. The mesh reflects that: the legs are short columns
mostly inside the coat's silhouette rather than free-standing.

**The head is carried LOW**, at or below the line of the back, and swings while
grazing. A cow with its head up at deer height is alert, which a Highland almost
never is. FAUNA.md gives this animal "passive, ignores the player, slow" — the low
head is what communicates that from across a field, before any behaviour runs.

## Scale against the player

1.45 m to the top of the horns, 81% of the 1.8 m player capsule, with the back at
about 1.2 m — chest height on a person standing beside it. It should read as heavy
rather than tall: the deer is the tall one, at 102%.

## How far the poses may be pushed

Rigid one-bone-per-part skinning. This animal has the most forgiving rig in the
batch — the coat slabs overlap generously and the legs barely move — but the neck
is the exception: it is short and thick, and the graze in `idle` uses most of the
0.09 m it is sunk into the chest. Past about 35 degrees the neck pulls free.
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


SPECIES = "cow"

## Metres, off the real animal. LENGTH_TO_HEIGHT is the number that matters: a
## Highland is twice as long as it is tall, and the deer in this same batch is
## barely longer than it is tall. That contrast is the batch's proof that these
## are different animals rather than one shape at different scales.
SHOULDER_Z = 1.20
BELLY_Z = 0.62
BODY_LENGTH = 1.55
BODY_DEPTH = 0.62
BODY_WIDTH = 0.52
HEAD_Z = 0.92
HORN_SPAN = 1.25


BONES = [
    ("root", (0.0, 0.0, 0.0), (0.0, 0.0, 0.2), None),
    ("body", (0.0, 0.0, SHOULDER_Z - 0.28), (0.0, -0.5, SHOULDER_Z - 0.28), "root"),
    # Short and thick, and it slopes DOWN to the head rather than up.
    ("neck", (0.0, 0.62, SHOULDER_Z - 0.10), (0.0, 0.86, HEAD_Z + 0.06), "body"),
    ("head", (0.0, 0.86, HEAD_Z + 0.06), (0.0, 1.10, HEAD_Z), "neck"),
    ("horn_l", (0.10, 0.92, HEAD_Z + 0.16), (HORN_SPAN * 0.5, 0.98, HEAD_Z + 0.30), "head"),
    ("horn_r", (-0.10, 0.92, HEAD_Z + 0.16), (-HORN_SPAN * 0.5, 0.98, HEAD_Z + 0.30), "head"),
    ("tail", (0.0, -0.86, SHOULDER_Z - 0.06), (0.0, -0.94, 0.55), "body"),
    ("fore_l", (0.20, 0.44, BELLY_Z), (0.20, 0.44, 0.0), "body"),
    ("fore_r", (-0.20, 0.44, BELLY_Z), (-0.20, 0.44, 0.0), "body"),
    ("hind_l", (0.21, -0.52, BELLY_Z), (0.21, -0.52, 0.0), "body"),
    ("hind_r", (-0.21, -0.52, BELLY_Z), (-0.21, -0.52, 0.0), "body"),
]


def build_parts() -> list[tuple[bpy.types.Object, str]]:
    coat = mat("leather")
    coat_dark = mat("leather_dark")
    horn = mat("bone")
    muzzle_skin = mat("flesh_fat")

    parts: list[tuple[bpy.types.Object, str]] = []

    def add(obj: bpy.types.Object, bone: str) -> None:
        parts.append((obj, bone))

    barrel_z = (SHOULDER_Z + BELLY_Z) * 0.5 + 0.04

    # The rectangle. Deliberately boxier than the deer's ovoid — a Highland's back
    # is flat and its sides are slab-like, and rounding it turns it into a pony.
    add(fc.ico("Cow_Body", (0.0, -0.05, barrel_z),
               (BODY_WIDTH, BODY_LENGTH, BODY_DEPTH), coat, subdivisions=3), "body")
    add(fc.box("Cow_Back", (0.0, -0.05, SHOULDER_Z - 0.06),
               (BODY_WIDTH - 0.06, BODY_LENGTH - 0.12, 0.16), coat), "body")
    # Shoulder and haunch, both heavy. On a Highland these are barely narrower than
    # the barrel — there is no waist.
    add(fc.ico("Cow_Shoulder", (0.0, 0.50, barrel_z + 0.02),
               (BODY_WIDTH + 0.02, 0.52, BODY_DEPTH), coat), "body")
    add(fc.ico("Cow_Haunch", (0.0, -0.62, barrel_z),
               (BODY_WIDTH + 0.03, 0.54, BODY_DEPTH + 0.02), coat), "body")

    # The coat skirt. This is what makes it a Highland rather than a beef cow: a
    # hanging fringe that breaks the leg line, so you read a low heavy shape rather
    # than four legs. Slabs rather than a single ring so it does not look extruded.
    for offset in (0.42, 0.10, -0.24, -0.58):
        add(fc.box(f"Cow_Skirt_{str(offset).replace('.', 'p').replace('-', 'n')}",
                   (0.0, offset, BELLY_Z - 0.02),
                   (BODY_WIDTH + 0.04, 0.30, 0.26), coat_dark), "body")

    # Neck: short, thick, sloping DOWN to a low head.
    add(fc.ico("Cow_Neck", (0.0, 0.72, SHOULDER_Z - 0.20),
               (0.40, 0.42, 0.40), coat, rotation=(-26.0, 0.0, 0.0)), "neck")
    add(fc.ico("Cow_Head", (0.0, 0.96, HEAD_Z + 0.02), (0.26, 0.36, 0.28), coat), "head")
    add(fc.ico("Cow_Muzzle", (0.0, 1.14, HEAD_Z - 0.04), (0.19, 0.16, 0.15), muzzle_skin), "head")
    # The fringe — hangs over the eyes, and is the head's read from the front. Its
    # own slab, sitting proud of the skull rather than implied by the head shape.
    add(fc.box("Cow_Fringe", (0.0, 1.02, HEAD_Z + 0.16), (0.30, 0.16, 0.26), coat_dark), "head")
    for side, sign in (("L", 1.0), ("R", -1.0)):
        add(fc.ico(f"Cow_Ear_{side}", (sign * 0.20, 0.90, HEAD_Z + 0.08),
                   (0.06, 0.14, 0.09), coat, rotation=(0.0, sign * 20.0, 0.0)), "head")

    # Horns: OUT, then forward and level, then up at the tips. Three segments per
    # side because the direction changes twice and a single curve reads as a dairy
    # cow's or a bull's.
    for side, sign in (("L", 1.0), ("R", -1.0)):
        bone = f"horn_{side.lower()}"
        add(fc.cone(f"Cow_Horn_Base_{side}", (sign * 0.26, 0.94, HEAD_Z + 0.20),
                    0.055, 0.042, 0.30, horn,
                    rotation=(0.0, sign * 82.0, 0.0), vertices=7), bone)
        add(fc.cone(f"Cow_Horn_Mid_{side}", (sign * 0.50, 1.00, HEAD_Z + 0.20),
                    0.042, 0.026, 0.30, horn,
                    rotation=(-16.0, sign * 78.0, 0.0), vertices=7), bone)
        add(fc.cone(f"Cow_Horn_Tip_{side}", (sign * 0.62, 1.02, HEAD_Z + 0.34),
                    0.026, 0.005, 0.24, horn,
                    rotation=(-8.0, sign * 34.0, 0.0), vertices=6), bone)

    # Tail: long, thin, with a tuft. It swings, and it is the only thing on a
    # standing Highland that moves much.
    add(fc.box("Cow_Tail", (0.0, -0.88, BELLY_Z + 0.24), (0.06, 0.07, 0.52), coat), "tail")
    add(fc.ico("Cow_Tail_Tuft", (0.0, -0.90, BELLY_Z - 0.06), (0.09, 0.10, 0.16), coat_dark), "tail")

    # Legs: short columns, mostly inside the skirt. Thick — no visible joint
    # articulation, because on the real animal you cannot see one.
    for name, y in (("fore", 0.44), ("hind", -0.52)):
        for side in ("L", "R"):
            sign = 1.0 if side == "L" else -1.0
            bone = f"{name}_{side.lower()}"
            x = sign * (0.20 if name == "fore" else 0.21)
            add(fc.box(f"Cow_{name.title()}_Leg_{side}", (x, y, BELLY_Z * 0.5),
                       (0.17, 0.19, BELLY_Z), coat), bone)
            add(fc.box(f"Cow_{name.title()}_Hoof_{side}", (x, y + 0.01, 0.05),
                       (0.16, 0.18, 0.10), horn), bone)

    return parts


# ── Poses ─────────────────────────────────────────────────────────────────────


def idle_pose(phase: float) -> tuple[fc.Pose, dict]:
    """Grazing, mostly. FAUNA.md: passive, ignores the player, slow.

    Weighted the opposite way to the deer's idle, on purpose. A deer's idle is
    mostly alert with a brief graze; a Highland's is mostly graze with a brief
    look up, and it does not hurry either transition. Standing the two side by
    side, that difference reads before any behaviour code runs — which is the
    point of putting it in the animation rather than in an AI state.
    """
    breathe = math.sin(phase * math.tau) * 1.2
    # Head down for most of the cycle; a slow lift in the last third.
    if phase < 0.62:
        graze = 1.0
    else:
        graze = 1.0 - math.sin((phase - 0.62) / 0.38 * math.pi) * 0.85
    # The swing while grazing — a cow sweeps its head sideways through the grass
    # rather than pecking at one spot.
    sweep = math.sin(phase * math.tau * 2.0) * 9.0 * graze
    return (
        {
            "body": (breathe * 0.3, 0.0, 0.0),
            "neck": (graze * 22.0, 0.0, sweep * 0.5),
            "head": (graze * 16.0, 0.0, sweep),
            "tail": (0.0, 0.0, math.sin(phase * math.tau * 1.5) * 14.0),
            "horn_l": (0.0, 0.0, 0.0),
            "horn_r": (0.0, 0.0, 0.0),
        },
        {},
    )


def walk_pose(phase: float) -> tuple[fc.Pose, dict]:
    """A slow, heavy four-beat.

    Same diagonal-pair gait as the deer and deliberately half the amplitude, with
    a heavier vertical drop: mass, not speed. The head swings with the stride
    because a cow's head is a counterweight it does not bother to stabilise —
    which is the exact opposite of the chicken's head-hold, and the two clips are
    worth reading next to each other as the two ends of that idea.
    """
    fore_l = math.sin(phase * math.tau)
    hind_r = math.sin((phase + 0.06) * math.tau)
    fore_r = math.sin((phase + 0.5) * math.tau)
    hind_l = math.sin((phase + 0.56) * math.tau)
    return (
        {
            "body": (0.0, 0.0, math.sin(phase * math.tau * 2.0) * 1.2),
            "neck": (6.0 + math.sin(phase * math.tau) * 4.0, 0.0, 0.0),
            "head": (4.0 + math.sin(phase * math.tau) * 5.0, 0.0, 0.0),
            "fore_l": (fore_l * 13.0, 0.0, 0.0),
            "fore_r": (fore_r * 13.0, 0.0, 0.0),
            "hind_l": (hind_l * 12.0, 0.0, 0.0),
            "hind_r": (hind_r * 12.0, 0.0, 0.0),
            "tail": (0.0, 0.0, math.sin(phase * math.tau) * 10.0),
        },
        {"body": (0.0, 0.0, abs(math.sin(phase * math.tau * 2.0)) * 0.016)},
    )


def flee_pose(phase: float) -> tuple[fc.Pose, dict]:
    """A heavy trot, not a bound.

    This is the clip most at risk of being wrong, because "flee" suggests panic
    and a Highland does not do panic. A frightened cow trots a short distance and
    stops — it is a large animal with no natural predators to speak of, and it
    moves like one. So: the walk's gait at roughly double amplitude and double
    cadence, head UP (the one time this animal raises it), and no airborne phase
    at all. Giving it the deer's bound would be the single most obviously wrong
    thing in this batch.
    """
    fore_l = math.sin(phase * math.tau * 2.0)
    hind_r = math.sin((phase + 0.06) * math.tau * 2.0)
    fore_r = math.sin((phase + 0.5) * math.tau * 2.0)
    hind_l = math.sin((phase + 0.56) * math.tau * 2.0)
    return (
        {
            "body": (-3.0, 0.0, math.sin(phase * math.tau * 4.0) * 1.8),
            # Head up — the alarm read, and the only time it happens.
            "neck": (-16.0, 0.0, 0.0),
            "head": (-10.0, 0.0, 0.0),
            "fore_l": (fore_l * 26.0, 0.0, 0.0),
            "fore_r": (fore_r * 26.0, 0.0, 0.0),
            "hind_l": (hind_l * 24.0, 0.0, 0.0),
            "hind_r": (hind_r * 24.0, 0.0, 0.0),
            "tail": (-24.0, 0.0, math.sin(phase * math.tau * 3.0) * 16.0),
        },
        {"body": (0.0, 0.0, abs(math.sin(phase * math.tau * 4.0)) * 0.02)},
    )


def death_keys() -> list[tuple[int, fc.Pose, dict]]:
    """Front knees first, then the whole mass onto its side.

    A cow goes down front-first and it goes down HEAVY — the settle is the longest
    part of the clip, because a 600 kg animal does not bounce. Deliberately slower
    throughout than the deer's, which is a lighter animal collapsing.
    """
    return [
        (1, {"neck": (2.0, 0.0, 0.0)}, {}),
        (
            9,
            {"body": (-11.0, 0.0, 0.0), "neck": (14.0, 0.0, 0.0),
             "fore_l": (38.0, 0.0, 0.0), "fore_r": (34.0, 0.0, 0.0)},
            {"body": (0.0, 0.0, -0.16)},
        ),
        (
            22,
            {"body": (-4.0, 62.0, 0.0), "neck": (-14.0, 0.0, 16.0), "head": (-10.0, 0.0, 0.0),
             "fore_l": (58.0, 0.0, 14.0), "fore_r": (50.0, 0.0, -10.0),
             "hind_l": (40.0, 0.0, 12.0), "hind_r": (34.0, 0.0, -10.0), "tail": (-12.0, 0.0, 0.0)},
            {"body": (0.0, 0.0, -SHOULDER_Z + 0.42)},
        ),
        (
            1 + fc.DEATH_FRAMES,
            {"body": (-2.0, 78.0, 0.0), "neck": (-20.0, 0.0, 22.0), "head": (-14.0, 0.0, 0.0),
             "fore_l": (64.0, 0.0, 16.0), "fore_r": (54.0, 0.0, -12.0),
             "hind_l": (46.0, 0.0, 14.0), "hind_r": (38.0, 0.0, -12.0), "tail": (-16.0, 0.0, 0.0)},
            {"body": (0.0, 0.0, -SHOULDER_Z + 0.36)},
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
        fc.build_cycle(armature, SPECIES, fc.CLIP_FLEE, fc.FLEE_FRAMES, flee_pose, samples=12)
        fc.build_oneshot(armature, SPECIES, fc.CLIP_DEATH, death_keys())

        fc.export_species(SPECIES, [armature, mesh], armature)
        fc.merge_catalog([
            fc.catalog_row(
                SPECIES,
                [mesh],
                "Highland cow. A rectangle on short legs — twice as long as tall, the deliberate "
                "opposite of the deer beside it. Horns go OUT then forward then up, spanning wider "
                "than the body; the fringe hangs over the eyes; the coat skirt breaks the leg line "
                "so it reads heavy and low. Head carried low and grazing, raised only to flee.",
            )
        ])
        fc.SOURCE_DIR.mkdir(parents=True, exist_ok=True)
        bpy.ops.wm.save_as_mainfile(filepath=str(fc.SOURCE_DIR / f"fauna_{SPECIES}.blend"))
        print(f"FAUNA_BUILD {SPECIES} ok")


if __name__ == "__main__":
    main()
