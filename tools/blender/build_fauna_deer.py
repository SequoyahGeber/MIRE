"""Build the red deer — FAUNA.md §2 #3, the bow's reason to exist (F-596).

Run with:
  Blender --background --python tools/blender/build_fauna_deer.py

Outputs `assets/fauna/exports/deer.glb` with the four clips D-218 fixes for the
batch. Shared machinery in `fauna_common.py`; read that module's docstring first,
especially the note about scale being measured against the player.

## The real animal

*Cervus elaphus*, a mature stag. FAUNA.md gives this species one job — it is what
makes a bow worth carrying — so what matters is that it reads as **big, alert and
about to leave**, from far enough away that a bow is the only answer.

**Proportion is what makes a deer, and it is nearly all legs.** A red deer stag
stands 1.15 m at the shoulder and is 2.0 m long, but the belly line sits at a bit
over half the shoulder height: the body is a relatively shallow barrel slung high
on very long, very thin legs. That leggy silhouette is the single most important
thing here. A deer drawn with a deep body and short legs is a goat.

**The neck is long, thick on a stag, and carried at roughly 45 degrees**, not
horizontally — the head is high because the animal is watching. A rutting stag's
neck is visibly maned; that mane is what separates a stag from a hind at
distance, and it is modelled as a distinct thicker sleeve here.

**The rump is higher than the shoulder in a young animal and level in a mature
one.** The back is close to flat with a slight rise over the hips, and the tail is
short with a pale rump patch around it — that patch is what you see when it turns
and runs, and it is the reason `flee` is legible from behind.

**Antlers sweep back and up, then the tines come forward.** They are not a
symmetrical shrub. Beam sweeps back from the brow, brow tine forward and low over
the face, then two upper tines. At 1.78 m to the tips they reach the player's eye
line — which is the point.

**A fleeing red deer bounds rather than gallops** over short distances: all four
legs gather under the body and it launches, head thrown up and back. That is a
different motion from a horse's gallop and it is what a player who has spooked one
actually sees. `flee_pose()` is a bound, not a run cycle.

## How far the poses may be pushed

Rigid one-bone-per-part skinning. The legs are the risk here: they are thin and
long, so a hip or shoulder past about 30 degrees pulls the thigh out of the body.
Each thigh is sunk 0.06 m into the barrel to buy that range. The neck is sunk
0.08 m into the chest for the same reason, and `flee` uses most of it.
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


SPECIES = "deer"

## Metres, off the real animal. The leggy proportion is the load-bearing number:
## SHOULDER_Z is the top of the barrel and BELLY_Z is its underside, so the gap
## between BELLY_Z and the ground is pure leg — 0.62 m of it, more than half the
## shoulder height. Shorten that and the animal stops being a deer.
SHOULDER_Z = 1.15
BELLY_Z = 0.62
BODY_LENGTH = 1.30
BODY_DEPTH = 0.46
BODY_WIDTH = 0.34
NECK_TOP_Z = 1.44
HEAD_Z = 1.50
ANTLER_TIP_Z = 1.78


BONES = [
    ("root", (0.0, 0.0, 0.0), (0.0, 0.0, 0.2), None),
    ("body", (0.0, 0.0, SHOULDER_Z - 0.16), (0.0, -0.4, SHOULDER_Z - 0.16), "root"),
    ("neck", (0.0, 0.48, SHOULDER_Z - 0.02), (0.0, 0.62, NECK_TOP_Z), "body"),
    ("head", (0.0, 0.62, NECK_TOP_Z), (0.0, 0.80, 1.44), "neck"),
    ("antler_l", (0.06, 0.64, HEAD_Z + 0.04), (0.14, 0.58, ANTLER_TIP_Z), "head"),
    ("antler_r", (-0.06, 0.64, HEAD_Z + 0.04), (-0.14, 0.58, ANTLER_TIP_Z), "head"),
    ("tail", (0.0, -0.70, SHOULDER_Z - 0.06), (0.0, -0.78, SHOULDER_Z - 0.18), "body"),
    ("fore_l", (0.13, 0.40, BELLY_Z), (0.13, 0.40, 0.0), "body"),
    ("fore_r", (-0.13, 0.40, BELLY_Z), (-0.13, 0.40, 0.0), "body"),
    ("hind_l", (0.14, -0.46, BELLY_Z), (0.14, -0.46, 0.0), "body"),
    ("hind_r", (-0.14, -0.46, BELLY_Z), (-0.14, -0.46, 0.0), "body"),
]


def build_parts() -> list[tuple[bpy.types.Object, str]]:
    coat = mat("leather")
    coat_dark = mat("leather_dark")
    pale = mat("cloth")
    antler = mat("bone")

    parts: list[tuple[bpy.types.Object, str]] = []

    def add(obj: bpy.types.Object, bone: str) -> None:
        parts.append((obj, bone))

    barrel_z = (SHOULDER_Z + BELLY_Z) * 0.5
    # The barrel: shallow relative to its length, and slung high. Slight nose-down
    # pitch so the withers sit a touch above the hips rather than the back reading
    # dead level, which looks like a table.
    add(fc.ico("Deer_Body", (0.0, -0.06, barrel_z),
               (BODY_WIDTH, BODY_LENGTH, BODY_DEPTH), coat, rotation=(-3.0, 0.0, 0.0)), "body")
    # Chest, deeper and forward — a stag carries mass at the front.
    add(fc.ico("Deer_Chest", (0.0, 0.44, barrel_z + 0.02),
               (BODY_WIDTH - 0.01, 0.50, BODY_DEPTH + 0.02), coat), "body")
    # Haunch, the powerhouse. Broader than the barrel and set low and back.
    add(fc.ico("Deer_Haunch", (0.0, -0.52, barrel_z - 0.02),
               (BODY_WIDTH + 0.05, 0.50, BODY_DEPTH + 0.04), coat), "body")
    # The pale rump patch — what you see when it turns and runs.
    add(fc.ico("Deer_Rump_Patch", (0.0, -0.72, barrel_z + 0.06),
               (0.20, 0.10, 0.22), pale), "body")

    # Neck at ~45 degrees, sunk 0.08 m into the chest. The mane sleeve is what
    # separates a stag from a hind at distance.
    add(fc.ico("Deer_Neck", (0.0, 0.55, (SHOULDER_Z + NECK_TOP_Z) * 0.5 - 0.02),
               (0.20, 0.22, 0.48), coat, rotation=(38.0, 0.0, 0.0)), "neck")
    add(fc.ico("Deer_Mane", (0.0, 0.52, (SHOULDER_Z + NECK_TOP_Z) * 0.5 - 0.06),
               (0.26, 0.26, 0.40), coat_dark, rotation=(38.0, 0.0, 0.0)), "neck")

    # Head: long and wedge-shaped, tapering to a narrow muzzle. A round head is a
    # cow's; a deer's face is a wedge.
    add(fc.ico("Deer_Head", (0.0, 0.69, HEAD_Z), (0.15, 0.30, 0.17), coat), "head")
    add(fc.ico("Deer_Muzzle", (0.0, 0.84, HEAD_Z - 0.04), (0.09, 0.16, 0.10), coat_dark), "head")
    for side, sign in (("L", 1.0), ("R", -1.0)):
        add(fc.ico(f"Deer_Ear_{side}", (sign * 0.11, 0.61, HEAD_Z + 0.08),
                   (0.04, 0.10, 0.14), coat, rotation=(0.0, sign * 26.0, 0.0)), "head")

    # Antlers: beam sweeps BACK and up, tines come forward. Built as a chain of
    # tapered cones rather than one shape, because the branching is the read.
    for side, sign in (("L", 1.0), ("R", -1.0)):
        bone = f"antler_{side.lower()}"
        add(fc.cone(f"Deer_Antler_Beam_{side}", (sign * 0.10, 0.56, HEAD_Z + 0.17),
                    0.022, 0.012, 0.34, antler,
                    rotation=(-24.0, sign * 16.0, 0.0), vertices=6), bone)
        # Brow tine, forward and low over the face.
        add(fc.cone(f"Deer_Antler_Brow_{side}", (sign * 0.10, 0.70, HEAD_Z + 0.10),
                    0.014, 0.004, 0.18, antler,
                    rotation=(64.0, sign * 10.0, 0.0), vertices=5), bone)
        # Two upper tines off the top of the beam, swept forward.
        add(fc.cone(f"Deer_Antler_Tine_A_{side}", (sign * 0.15, 0.54, HEAD_Z + 0.25),
                    0.012, 0.003, 0.20, antler,
                    rotation=(26.0, sign * 22.0, 0.0), vertices=5), bone)
        add(fc.cone(f"Deer_Antler_Tine_B_{side}", (sign * 0.17, 0.46, HEAD_Z + 0.24),
                    0.011, 0.003, 0.17, antler,
                    rotation=(-6.0, sign * 30.0, 0.0), vertices=5), bone)

    add(fc.ico("Deer_Tail", (0.0, -0.76, barrel_z + 0.02), (0.06, 0.06, 0.14), pale), "tail")

    # Legs. Long and thin — the silhouette. Upper leg sunk 0.06 m into the barrel
    # so hip rotation has room before the thigh pulls free.
    for name, y, sign_pairs in (("fore", 0.40, ("L", "R")), ("hind", -0.46, ("L", "R"))):
        for side in sign_pairs:
            sign = 1.0 if side == "L" else -1.0
            bone = f"{name}_{side.lower()}"
            x = sign * (0.13 if name == "fore" else 0.14)
            add(fc.ico(f"Deer_{name.title()}_Upper_{side}", (x, y, BELLY_Z - 0.02),
                       (0.13, 0.19, 0.42), coat), bone)
            add(fc.box(f"Deer_{name.title()}_Cannon_{side}", (x, y + 0.01, 0.22),
                       (0.055, 0.06, 0.40), coat_dark), bone)
            add(fc.box(f"Deer_{name.title()}_Hoof_{side}", (x, y + 0.02, 0.03),
                       (0.06, 0.09, 0.06), antler), bone)

    return parts


# ── Poses ─────────────────────────────────────────────────────────────────────


def idle_pose(phase: float) -> tuple[fc.Pose, dict]:
    """Alert and grazing by turns — the two states a deer is ever in.

    Weighted toward ALERT, because that is what the player will nearly always see:
    by the time you are close enough to watch one graze it has usually gone. The
    graze occupies less than a third of the cycle and the head comes up fast out
    of it, which is the motion that tells you it has heard you.
    """
    breathe = math.sin(phase * math.tau) * 1.6
    graze = 0.0
    if 0.30 < phase < 0.58:
        graze = math.sin((phase - 0.30) / 0.28 * math.pi)
    return (
        {
            "body": (breathe * 0.4, 0.0, 0.0),
            # Down to the grass and back up. The neck does most of it; the head
            # adds the last of the reach so the muzzle finishes level with ground.
            "neck": (-graze * 30.0 + breathe * 0.6, 0.0, 0.0),
            "head": (-graze * 26.0, 0.0, 0.0),
            # Ears flick independently while the head is down — a grazing deer is
            # still listening, and it is the only thing moving in that stretch.
            "tail": (breathe * 3.0, 0.0, math.sin(phase * math.tau * 3.0) * 5.0),
        },
        {},
    )


def walk_pose(phase: float) -> tuple[fc.Pose, dict]:
    """A four-beat walk, diagonal pairs offset — the gait a deer actually uses.

    Diagonal pairs move together (fore-left with hind-right), quarter-cycle apart
    rather than in phase, so three feet are down at any moment. Legs in lateral
    pairs is a camel; legs all in phase is a rocking horse.
    """
    fore_l = math.sin(phase * math.tau)
    hind_r = math.sin((phase + 0.06) * math.tau)
    fore_r = math.sin((phase + 0.5) * math.tau)
    hind_l = math.sin((phase + 0.56) * math.tau)
    return (
        {
            "body": (0.0, 0.0, math.sin(phase * math.tau * 2.0) * 1.6),
            # The head nods gently with the stride — far subtler than the
            # chicken's, and driven by the shoulder rather than by gaze holding.
            "neck": (math.sin(phase * math.tau * 2.0) * 3.0, 0.0, 0.0),
            "head": (-math.sin(phase * math.tau * 2.0) * 2.0, 0.0, 0.0),
            "fore_l": (fore_l * 22.0, 0.0, 0.0),
            "fore_r": (fore_r * 22.0, 0.0, 0.0),
            "hind_l": (hind_l * 20.0, 0.0, 0.0),
            "hind_r": (hind_r * 20.0, 0.0, 0.0),
            "tail": (math.sin(phase * math.tau) * 6.0, 0.0, 0.0),
        },
        {"body": (0.0, 0.0, abs(math.sin(phase * math.tau * 2.0)) * 0.02)},
    )


def flee_pose(phase: float) -> tuple[fc.Pose, dict]:
    """A BOUND, not a gallop.

    Over short distances a red deer gathers all four legs under itself and
    launches, head thrown up and back, then lands fore-first and gathers again.
    That is what someone who has just spooked one sees, and it is a different
    motion from a horse's four-beat gallop — which is what you get if you simply
    run the walk cycle faster, and it is why this is authored as its own arc
    rather than as a speed multiplier.

    One bound per cycle: gather (0.0-0.3), extend and launch (0.3-0.6), stretch
    at apex (0.6-0.8), land fore-first (0.8-1.0).
    """
    if phase < 0.3:
        stage = phase / 0.3          # gathering
        gather, extend, land = stage, 0.0, 0.0
    elif phase < 0.6:
        stage = (phase - 0.3) / 0.3  # launching
        gather, extend, land = 1.0 - stage, stage, 0.0
    elif phase < 0.8:
        stage = (phase - 0.6) / 0.2  # airborne, stretched
        gather, extend, land = 0.0, 1.0 - stage * 0.3, 0.0
    else:
        stage = (phase - 0.8) / 0.2  # landing fore-first
        gather, extend, land = 0.0, 0.7 - stage * 0.7, stage

    lift = math.sin(min(1.0, max(0.0, (phase - 0.25) / 0.55)) * math.pi)
    return (
        {
            # Pitches up through the launch and down into the landing.
            "body": (extend * 12.0 - land * 16.0, 0.0, 0.0),
            # Head thrown UP and back — the opposite of the chicken's flattened
            # run, and correct for the animal: a bounding deer looks skyward.
            "neck": (extend * 20.0 + gather * 6.0, 0.0, 0.0),
            "head": (extend * 10.0, 0.0, 0.0),
            # Hind legs fold hard under the body to gather, then drive back.
            "hind_l": (gather * 40.0 - extend * 34.0, 0.0, 0.0),
            "hind_r": (gather * 40.0 - extend * 34.0, 0.0, 0.0),
            # Forelegs tuck at gather, reach forward to land.
            "fore_l": (-gather * 34.0 + land * 30.0 - extend * 8.0, 0.0, 0.0),
            "fore_r": (-gather * 34.0 + land * 30.0 - extend * 8.0, 0.0, 0.0),
            # Tail up: the pale rump patch is the flag, and this is what makes the
            # flee readable from directly behind, which is the usual view of it.
            "tail": (58.0, 0.0, 0.0),
        },
        {"body": (0.0, 0.0, lift * 0.28)},
    )


def death_keys() -> list[tuple[int, fc.Pose, dict]]:
    """The forelegs buckle first, then the animal goes down on its side.

    A shot deer does not sit down. The front end collapses while the hindquarters
    are still standing, and the mass tips forward and over. Uneven key spacing:
    the buckle is fast, the roll is slower, the settle is slowest.
    """
    return [
        (1, {"neck": (6.0, 0.0, 0.0)}, {}),
        # Forelegs buckle, head still up — the moment before it knows.
        (
            7,
            {"body": (-14.0, 0.0, 0.0), "neck": (16.0, 0.0, 0.0), "head": (-8.0, 0.0, 0.0),
             "fore_l": (44.0, 0.0, 0.0), "fore_r": (40.0, 0.0, 0.0),
             "hind_l": (-6.0, 0.0, 0.0), "hind_r": (-6.0, 0.0, 0.0)},
            {"body": (0.0, 0.0, -0.16)},
        ),
        # Hindquarters follow, the whole mass tips onto its side.
        (
            19,
            {"body": (-6.0, 66.0, 0.0), "neck": (-22.0, 0.0, 14.0), "head": (-16.0, 0.0, 0.0),
             "fore_l": (66.0, 0.0, 16.0), "fore_r": (58.0, 0.0, -10.0),
             "hind_l": (48.0, 0.0, 14.0), "hind_r": (42.0, 0.0, -12.0), "tail": (-14.0, 0.0, 0.0)},
            {"body": (0.0, 0.0, -SHOULDER_Z + 0.36)},
        ),
        (
            1 + fc.DEATH_FRAMES,
            {"body": (-4.0, 82.0, 0.0), "neck": (-30.0, 0.0, 20.0), "head": (-20.0, 0.0, 0.0),
             "fore_l": (72.0, 0.0, 18.0), "fore_r": (62.0, 0.0, -12.0),
             "hind_l": (54.0, 0.0, 16.0), "hind_r": (46.0, 0.0, -14.0), "tail": (-18.0, 0.0, 0.0)},
            {"body": (0.0, 0.0, -SHOULDER_Z + 0.30)},
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
                "Red deer stag. Shallow barrel slung high on long thin legs — the leggy "
                "proportion is the whole silhouette. Neck at 45 degrees with a stag's mane, "
                "wedge head, antlers sweeping back then tines forward to the player's eye line. "
                "Flee is a bound, not a gallop, with the pale rump patch flagged.",
            )
        ])
        fc.SOURCE_DIR.mkdir(parents=True, exist_ok=True)
        bpy.ops.wm.save_as_mainfile(filepath=str(fc.SOURCE_DIR / f"fauna_{SPECIES}.blend"))
        print(f"FAUNA_BUILD {SPECIES} ok")


if __name__ == "__main__":
    main()
