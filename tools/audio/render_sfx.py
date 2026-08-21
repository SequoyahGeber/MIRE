#!/usr/bin/env python3
"""Render every MIRE sound effect from a physical recipe. Deterministic.

    python3 tools/audio/render_sfx.py [--only NAME ...] [--sfx-dir DIR] [--build-dir DIR]
    python3 tools/audio/render_sfx.py --list          # the catalogue, by system

Writes mono 16-bit 44.1 kHz WAVs straight to `assets/audio/sfx/` — mono because
`AudioStreamPlayer3D` only spatialises mono sources — plus per-system audition
reels to the build dir.

== v2: why every recipe was rewritten (2026-08-21) ==

The v1 recipes layered a click, a sine drop and a noise bed, with every
resonance and decay time picked by ear. Sequoyah's verdict on listening was that
most of them were "wildly inaccurate". They were, and the reason is documented
at the top of `mire_material.py`: **frequency-dependent decay rate is the
dominant perceptual cue for material** (Klatzky, Pai & Krotkov, Presence 9(4)),
and hand-picking one decay per partial is precisely what destroys it.

So v2 authors *objects*, not waveforms. Every impact names a material and a
geometry; `mire_material.struck()` derives each mode's decay from the material's
loss factor as `tau = 1/(pi*f*eta)`, adds the boundary damping of how the object
is held or seated, and shapes which modes get excited at all from the contact
time of the strike. A recipe therefore reads as "a rooted green trunk hit hard
with a steel edge" rather than as a list of frequencies, and two sounds made of
the same substance relate to each other without anything being copied between
them.

Layering follows the architecture in Tsugi's GameSynth foley breakdowns, which
is also what a foley stage does: a **body** (the mass moving), a **resonance**
(the object's modes), a **texture** (crush, splinter, grit, water), and where a
real one exists, a **mechanism** (a latch, a string, a bowstring). Layers are
offset a few milliseconds from each other rather than stacked on the same
sample, because coincident onsets mask one another and read as one thick click.

Foley practice decided several material choices outright: bone snaps are celery,
so `hit_bone` is a bright bar mode over a fibrous granular tear; wet flesh is a
sodden cloth, so `hit_flesh` is a heavily damped membrane and almost no ring;
dead leaves are unspooled cassette tape, so plant harvest is dense fine grains
rather than filtered noise. Water is the Minnaert bubble model throughout — a
bubble's pitch RISES as it collapses, and that rising chirp is the whole
signature of water. A swamp game gets that wrong at its peril.

== Variants ==

"One option per sound" means one *design*, not one file. Anything the player
triggers repeatedly ships several seeded variants of the same design, because
the alternative is an audible machine gun; play sites round-robin them with
+-4% `pitch_scale` scatter. Sounds that fire once per event ship one file.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
import zlib

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mire_audio as ma  # noqa: E402
import mire_material as mm  # noqa: E402
import mire_voices as mv  # noqa: E402

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "blender"))
from godot_import_lock import import_cache_guard  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def buf(dur_s: float) -> np.ndarray:
    return np.zeros(ma.samples(dur_s))


def put(dest: np.ndarray, sig: np.ndarray, at_s: float, gain: float = 1.0) -> None:
    """Place a layer at a time offset. Offsets of a few ms between layers are
    deliberate: coincident onsets mask each other into one thick click."""
    start = ma.samples(max(at_s, 0.0))
    end = min(start + sig.shape[0], dest.shape[0])
    if start < end:
        dest[start:end] += sig[: end - start] * gain


# ═══════════════════════════════════════════════════════════════════════════
# HARVESTING — tools meeting the eleven harvestable materials
# ═══════════════════════════════════════════════════════════════════════════

def axe_hit_wood(rng: np.random.Generator) -> np.ndarray:
    """Steel edge into a living trunk. The three things that make this read as a
    CHOP rather than a knock: the trunk is `wood_green` and rooted, so it barely
    rings; the edge is hard and narrow, so the contact is sub-millisecond and
    the splinter layer is bright; and the body thump is large and low, because
    an axe moves the whole tree a little."""
    out = buf(0.55)
    f0 = rng.uniform(88.0, 108.0)
    put(out, mm.body(f0 * 2.3, 0.16, drop=0.42, curve=0.45, tau_ratio=0.30), 0.0, 0.95)
    put(out, mm.struck(f0, "wood_green", 0.42, rng, geometry="bar_free",
                       hardness=0.88, position=0.31, modes=6, mounting=0.11), 0.002, 0.85)
    # the edge parting fibres — bright, short, and where the "bite" lives
    put(out, mm.strike_noise(0.13, rng, "wood_green", hardness=0.92, brightness=1.4),
        0.0006, 0.55)
    # splinters and bark thrown clear
    put(out, mm.granular(0.22, rng, count=9, fc_low=900.0, fc_high=6500.0,
                         grain_s=(0.0015, 0.007)), 0.012, 0.18)
    return out


def axe_hit_wood_dead(rng: np.random.Generator) -> np.ndarray:
    """The same swing into a fallen log or a stump — dead, waterlogged, sitting
    on wet ground. `wood_rot` at heavy mounting kills the ring almost entirely,
    so what is left is a dull crump and a lot of soft debris. Distinct enough
    from the living trunk that a player can hear which one they are cutting."""
    out = buf(0.5)
    f0 = rng.uniform(62.0, 78.0)
    put(out, mm.body(f0 * 2.0, 0.20, drop=0.40, curve=0.55, tau_ratio=0.34), 0.0, 1.0)
    put(out, mm.struck(f0, "wood_rot", 0.3, rng, geometry="bar_free",
                       hardness=0.6, position=0.4, modes=5, mounting=0.28), 0.003, 0.7)
    put(out, mm.strike_noise(0.18, rng, "wood_rot", hardness=0.55, brightness=0.8),
        0.001, 0.5)
    # sodden wood gives up water as it splits
    put(out, mm.bubble_cloud(0.28, rng, count=9, r_min=0.0008, r_max=0.004), 0.02, 0.16)
    put(out, mm.granular(0.3, rng, count=11, fc_low=400.0, fc_high=2600.0), 0.03, 0.2)
    return out


def pick_hit_stone(rng: np.random.Generator) -> np.ndarray:
    """Iron pick into granite. Dense rock does not ring — the published loss
    factor puts every mode under 40 ms — so the *character* has to come from the
    chip spray and the sub-millisecond contact, not from a tail. Modes are
    irregular because a boulder has no analytic geometry, and that
    incommensurate spread is what makes it a clack instead of a note."""
    out = buf(0.36)
    f0 = rng.uniform(690.0, 880.0)
    put(out, mm.body(190.0, 0.075, drop=0.42, curve=0.4), 0.0, 0.62)
    put(out, mm.struck(f0, "granite", 0.28, rng, geometry="irregular",
                       hardness=0.97, modes=7, mounting=0.05, spread=1.1), 0.0008, 0.9)
    put(out, mm.strike_noise(0.09, rng, "granite", hardness=0.97, brightness=1.6),
        0.0, 0.62)
    put(out, mm.granular(0.24, rng, count=13, fc_low=2200.0, fc_high=11000.0,
                         grain_s=(0.001, 0.005), density_curve=2.4), 0.006, 0.3)
    return out


def pick_hit_ore(rng: np.random.Generator) -> np.ndarray:
    """Pick into an iron node. Same rock body, but the metal inclusions ring —
    `iron` at low mounting gives a 100 ms tail no stone can produce, and that
    tail is the entire tell that this node is worth mining. The pitch is left
    unrelated to the day track's D on purpose: this is information, not reward."""
    out = buf(0.62)
    put(out, mm.body(210.0, 0.08, drop=0.45, curve=0.4), 0.0, 0.6)
    put(out, mm.struck(rng.uniform(760.0, 900.0), "granite", 0.24, rng,
                       geometry="irregular", hardness=0.95, modes=6, mounting=0.06), 0.001, 0.7)
    # the metal itself, struck a hair later because it is inside the rock
    put(out, mm.struck(rng.uniform(1180.0, 1420.0), "iron", 0.55, rng,
                       geometry="bar_free", hardness=0.9, position=0.22,
                       modes=5, mounting=0.035, detune_cents=25.0), 0.004, 0.45)
    put(out, mm.strike_noise(0.08, rng, "granite", hardness=0.95, brightness=1.5), 0.0, 0.5)
    put(out, mm.granular(0.22, rng, count=10, fc_low=2600.0, fc_high=10000.0,
                         grain_s=(0.001, 0.004)), 0.007, 0.24)
    return out


def pick_hit_crystal(rng: np.random.Generator) -> np.ndarray:
    """Pick into a mire crystal. `crystal` is the lowest loss factor in the
    table and the node is barely seated, so this is the longest-ringing impact
    in the game — a quarter second of clean tube modes. Tuned to D, unlike ore:
    the crystals are the world's magic and reward sounds live in the day track's
    home key."""
    out = buf(0.95)
    root = ma.note_hz("D6") * rng.uniform(0.985, 1.015)
    put(out, mm.body(260.0, 0.06, drop=0.5, curve=0.4), 0.0, 0.42)
    put(out, mm.struck(root, "crystal", 0.85, rng, geometry="tube_open",
                       hardness=0.93, position=0.19, modes=6, mounting=0.005), 0.001, 0.85)
    put(out, mm.struck(root * 1.4983, "crystal", 0.6, rng, geometry="tube_closed",
                       hardness=0.9, modes=4, mounting=0.008), 0.006, 0.3)
    put(out, mm.strike_noise(0.05, rng, "glass", hardness=0.98, brightness=1.8), 0.0, 0.4)
    put(out, mm.granular(0.3, rng, count=9, fc_low=4000.0, fc_high=13000.0,
                         grain_s=(0.001, 0.004)), 0.008, 0.2)
    return out


def harvest_plant(rng: np.random.Generator) -> np.ndarray:
    """Pulling a bush or a nettle out of wet ground. Foley makes dead vegetation
    from unspooled cassette tape dragged through the fingers — dense, fine, dry
    grains, not filtered noise — so that is what the top layer is. Under it: the
    root giving way, and the suck of it leaving the mud."""
    out = buf(0.55)
    put(out, mm.granular(0.30, rng, count=int(rng.uniform(46, 62)), fc_low=1600.0,
                         fc_high=9000.0, grain_s=(0.0008, 0.0035),
                         density_curve=1.1, decay=0.5), 0.0, 0.7)
    # the root tearing: a short fibrous friction burst
    put(out, mm.friction(0.13, rng, material="wood_green", f_low=500.0,
                         f_high=2200.0, rate=210.0, roughness=0.8)
        * ma.env_asr(ma.samples(0.13), 0.01, 0.08), 0.09, 0.5)
    put(out, mm.struck(rng.uniform(120.0, 170.0), "mud", 0.12, rng,
                       geometry="membrane", hardness=0.25, mounting=0.2), 0.10, 0.35)
    put(out, mm.bubble_cloud(0.22, rng, count=7, r_min=0.0006, r_max=0.0035), 0.13, 0.22)
    return out


def tree_fall(rng: np.random.Generator) -> np.ndarray:
    """The whole event, and the only sound in the game with real narrative shape:
    the trunk hinges and the remaining fibres tear one after another (an
    accelerating stick-slip train, which is what a creak physically IS), the
    hinge lets go, the mass swings through the air, and it lands.

    The landing is deliberately the loudest moment rather than the crack. At any
    distance a felled tree is recognised by the ground impact, and a player needs
    to know a tree came down without watching it."""
    out = buf(3.4)
    # 1. the hinge failing, fibre by fibre, accelerating
    creak = ma.burst_train(0.85, 9.0, 74.0, rng, jitter=0.35)
    creak = ma.swept_bandpass(creak, np.geomspace(190.0, 1250.0, creak.shape[0]),
                              octaves=0.85, block=1024)
    put(out, creak * np.linspace(0.12, 1.0, creak.shape[0]) ** 1.5, 0.0, 0.5)
    # 2. the break itself
    put(out, mm.strike_noise(0.28, rng, "wood_green", hardness=0.8, brightness=1.1), 0.86, 0.75)
    put(out, mm.struck(rng.uniform(52.0, 64.0), "wood_green", 1.1, rng,
                       geometry="bar_free", hardness=0.75, position=0.42,
                       modes=6, mounting=0.05), 0.862, 0.9)
    put(out, mm.body(150.0, 0.35, drop=0.28, curve=0.5, tau_ratio=0.3), 0.86, 0.8)
    # 3. it goes over — foliage dragging through the air, rising then falling
    put(out, mm.air_arc(1.05, rng, f_low=420.0, f_high=1500.0, width=2.0,
                        peak_at=0.62, sharp=1.2), 1.0, 0.3)
    put(out, mm.granular(1.0, rng, count=90, fc_low=2200.0, fc_high=11000.0,
                         grain_s=(0.0008, 0.003), density_curve=0.8, decay=0.1), 1.05, 0.22)
    # 4. the ground. This is the moment the sound is FOR.
    put(out, mm.body(96.0, 0.85, drop=0.26, curve=0.5, tau_ratio=0.22), 2.05, 1.0)
    put(out, mm.struck(rng.uniform(44.0, 55.0), "wood_green", 0.9, rng,
                       geometry="bar_free", hardness=0.45, position=0.5,
                       modes=5, mounting=0.3), 2.055, 0.7)
    put(out, mm.strike_noise(0.7, rng, "mud", hardness=0.3, brightness=0.9), 2.05, 0.55)
    put(out, mm.splash(0.9, rng, size=0.8), 2.07, 0.3)
    put(out, mm.granular(1.2, rng, count=40, fc_low=500.0, fc_high=5000.0,
                         density_curve=1.5), 2.10, 0.3)
    return out


def sapling_break(rng: np.random.Generator) -> np.ndarray:
    """A young stem snapping — thin, so the modes are high and the whole thing is
    over in a fifth of a second. Green wood, barely seated, struck hard."""
    out = buf(0.7)
    put(out, mm.strike_noise(0.06, rng, "wood_green", hardness=0.95, brightness=1.6), 0.0, 0.7)
    put(out, mm.struck(rng.uniform(230.0, 320.0), "wood_green", 0.34, rng,
                       geometry="bar_free", hardness=0.9, position=0.35,
                       modes=5, mounting=0.09), 0.002, 0.95)
    put(out, mm.body(230.0, 0.07, drop=0.4), 0.0, 0.4)
    put(out, mm.granular(0.42, rng, count=26, fc_low=1800.0, fc_high=10000.0,
                         grain_s=(0.0008, 0.003), density_curve=1.2), 0.02, 0.3)
    return out


def stone_break(rng: np.random.Generator) -> np.ndarray:
    """A boulder or stone node giving way. Rock does not explode: it fractures
    along a plane and the pieces then fall onto each other, which is why the
    scatter is longer and lower than the crack and why it must not be a single
    burst. Sub content under it because a boulder has real mass."""
    out = buf(1.9)
    put(out, mm.strike_noise(0.35, rng, "granite", hardness=0.85, brightness=1.3), 0.0, 0.75)
    put(out, mm.struck(rng.uniform(300.0, 400.0), "granite", 0.4, rng,
                       geometry="irregular", hardness=0.85, modes=8, mounting=0.03), 0.002, 0.85)
    put(out, mm.body(140.0, 0.55, drop=0.24, curve=0.45, tau_ratio=0.26), 0.0, 1.0)
    put(out, ma.sine(41.0, 0.6) * ma.exp_decay(ma.samples(0.6), 0.18), 0.004, 0.35)
    # the pieces landing on each other — each one is its own little granite hit
    for _ in range(7):
        at = rng.uniform(0.16, 1.15)
        put(out, mm.struck(rng.uniform(900.0, 2600.0), "granite", 0.16, rng,
                           geometry="irregular", hardness=0.8, modes=4, mounting=0.02),
            at, rng.uniform(0.10, 0.28))
    put(out, mm.granular(1.5, rng, count=48, fc_low=700.0, fc_high=7000.0,
                         grain_s=(0.002, 0.014), density_curve=1.5), 0.06, 0.4)
    return out


def ore_break(rng: np.random.Generator) -> np.ndarray:
    """An iron node breaking open. Same fracture as stone, but the pieces that
    fall are metal — short ringing taps rather than dry clacks, which is the
    payoff the mining sound has been promising."""
    out = buf(1.9)
    put(out, mm.strike_noise(0.3, rng, "granite", hardness=0.85, brightness=1.3), 0.0, 0.7)
    put(out, mm.struck(rng.uniform(330.0, 430.0), "granite", 0.35, rng,
                       geometry="irregular", hardness=0.85, modes=7, mounting=0.03), 0.002, 0.75)
    put(out, mm.body(150.0, 0.5, drop=0.26, curve=0.45, tau_ratio=0.26), 0.0, 0.9)
    for _ in range(6):
        at = rng.uniform(0.14, 1.05)
        put(out, mm.struck(rng.uniform(700.0, 2100.0), "iron", 0.4, rng,
                           geometry="bar_free", hardness=0.85, modes=4,
                           mounting=0.03, detune_cents=30.0), at, rng.uniform(0.10, 0.26))
    put(out, mm.granular(1.3, rng, count=38, fc_low=900.0, fc_high=8000.0,
                         density_curve=1.5), 0.05, 0.32)
    return out


def log_break(rng: np.random.Generator) -> np.ndarray:
    """A fallen log or stump finally coming apart. Rotten, sodden, resting on
    wet ground: no crack worth the name, just a heavy sodden collapse and a lot
    of soft fibrous debris."""
    out = buf(1.6)
    put(out, mm.strike_noise(0.42, rng, "wood_rot", hardness=0.45, brightness=0.75), 0.0, 0.7)
    put(out, mm.struck(rng.uniform(58.0, 74.0), "wood_rot", 0.4, rng,
                       geometry="bar_free", hardness=0.5, position=0.44,
                       modes=5, mounting=0.25), 0.003, 0.85)
    put(out, mm.body(110.0, 0.45, drop=0.3, curve=0.55, tau_ratio=0.3), 0.0, 0.95)
    put(out, mm.bubble_cloud(0.7, rng, count=22, r_min=0.0008, r_max=0.006), 0.03, 0.25)
    put(out, mm.granular(1.1, rng, count=30, fc_low=350.0, fc_high=3200.0,
                         grain_s=(0.003, 0.018), density_curve=1.4), 0.05, 0.34)
    return out


# ═══════════════════════════════════════════════════════════════════════════
# MOVEMENT — five ground materials, plus water entry and swimming
# ═══════════════════════════════════════════════════════════════════════════

def _step_body(rng: np.random.Generator, f0: float, gain: float,
               out: np.ndarray, at: float = 0.0) -> None:
    """The weight of a boot arriving. Every footstep has one; only the surface
    layered over it changes. Keeping it shared is what makes five surfaces sound
    like the same person walking."""
    put(out, mm.body(f0, 0.055, drop=0.62, curve=0.5, tau_ratio=0.3), at, gain)


def footstep_mud(rng: np.random.Generator) -> np.ndarray:
    """The default MIRE surface. A step into saturated ground is a *suction*
    event, not an impact: the band sweeps downward as the boot displaces water
    and closes the void, and the release a moment later is where the squelch
    actually lives. `mud` has the highest loss factor in the table, so nothing
    rings at all."""
    out = buf(0.34)
    _step_body(rng, rng.uniform(84.0, 100.0), 0.5, out)
    n = ma.samples(0.15)
    suck = ma.swept_bandpass(ma.white(n, rng), np.geomspace(2400.0, 260.0, n),
                             octaves=1.35, block=512)
    suck *= 0.45 + 0.55 * np.abs(ma.slow_noise(n, 32.0, rng))
    put(out, suck * ma.env_asr(n, 0.004, 0.075), 0.004, 0.55)
    put(out, mm.bubble_cloud(0.20, rng, count=int(rng.uniform(5, 10)),
                             r_min=0.0005, r_max=0.0032), 0.03, 0.3)
    put(out, mm.granular(0.10, rng, count=4, fc_low=2600.0, fc_high=9000.0,
                         grain_s=(0.001, 0.003)), 0.012, 0.16)
    return out


def footstep_water(rng: np.random.Generator) -> np.ndarray:
    """Standing water over a hard bottom. The splash breaks upward and bright,
    then the surface closes as a spray of bubbles, then a few droplets fall
    back — three stages, and skipping the third is what makes most game water
    sound like noise."""
    out = buf(0.44)
    _step_body(rng, rng.uniform(96.0, 116.0), 0.35, out)
    put(out, mm.splash(0.28, rng, size=rng.uniform(0.25, 0.45)), 0.002, 0.75)
    for _ in range(int(rng.uniform(3, 6))):
        put(out, mm.bubble(rng.uniform(0.0006, 0.0022), rng, rise=2.6),
            rng.uniform(0.16, 0.36), rng.uniform(0.08, 0.2))
    return out


def footstep_grass(rng: np.random.Generator) -> np.ndarray:
    """Dry blades folding under a boot. Fine dense grains and nothing else —
    the same cassette-tape texture foley uses for undergrowth — over a softer,
    quieter body than the other surfaces, because turf absorbs."""
    out = buf(0.26)
    _step_body(rng, rng.uniform(74.0, 88.0), 0.32, out)
    put(out, mm.granular(0.14, rng, count=int(rng.uniform(26, 40)), fc_low=2000.0,
                         fc_high=11000.0, grain_s=(0.0006, 0.0026),
                         density_curve=1.0, decay=0.6), 0.003, 0.55)
    put(out, ma.fft_filter(ma.white(ma.samples(0.07), rng), fc_low=900.0, fc_high=4200.0)
        * ma.exp_decay(ma.samples(0.07), 0.02), 0.005, 0.16)
    return out


def footstep_stone(rng: np.random.Generator) -> np.ndarray:
    """Boot on rock. The only surface where the GROUND rings, briefly — granite
    modes at high mounting, over grit dragged under the sole."""
    out = buf(0.24)
    _step_body(rng, rng.uniform(100.0, 122.0), 0.55, out)
    put(out, mm.struck(rng.uniform(1100.0, 1700.0), "granite", 0.13, rng,
                       geometry="irregular", hardness=0.55, modes=5, mounting=0.09),
        0.0015, 0.3)
    put(out, mm.strike_noise(0.05, rng, "granite", hardness=0.6, brightness=1.2), 0.0, 0.35)
    put(out, mm.granular(0.10, rng, count=6, fc_low=2500.0, fc_high=10000.0,
                         grain_s=(0.0008, 0.003)), 0.008, 0.18)
    return out


def footstep_wood(rng: np.random.Generator) -> np.ndarray:
    """A dock, a bridge, a built floor. Dry planks, mounted at their ends but
    free to drum in the middle, so this is the most tonal footstep — and the one
    that tells a player they have stepped onto something they built."""
    out = buf(0.32)
    _step_body(rng, rng.uniform(88.0, 104.0), 0.45, out)
    put(out, mm.struck(rng.uniform(160.0, 230.0), "wood_dry", 0.26, rng,
                       geometry="bar_free", hardness=0.45, position=rng.uniform(0.3, 0.6),
                       modes=5, mounting=0.10), 0.002, 0.6)
    put(out, mm.strike_noise(0.06, rng, "wood_dry", hardness=0.5, brightness=1.0), 0.0, 0.3)
    return out


def jump(rng: np.random.Generator) -> np.ndarray:
    """Effort, not impact: cloth and gear compressing as the body launches, plus
    the soft push-off from soaked ground."""
    out = buf(0.3)
    put(out, mm.cloth(0.18, rng, weight=0.55, rate=200.0), 0.0, 0.6)
    put(out, mm.body(72.0, 0.08, drop=0.7, curve=0.6), 0.005, 0.4)
    put(out, mm.granular(0.12, rng, count=8, fc_low=1200.0, fc_high=6000.0,
                         grain_s=(0.001, 0.004)), 0.01, 0.2)
    return out


def land_hard(rng: np.random.Generator) -> np.ndarray:
    """Coming down from height. Everything the footstep has, an octave lower and
    three times the mass, plus the gear taking the shock a beat after the boots
    do — that small offset is what makes it read as a loaded body rather than a
    dropped object."""
    out = buf(0.6)
    put(out, mm.body(62.0, 0.28, drop=0.34, curve=0.45, tau_ratio=0.28), 0.0, 1.0)
    n = ma.samples(0.22)
    slap = ma.swept_bandpass(ma.white(n, rng), np.geomspace(1900.0, 180.0, n),
                             octaves=1.5, block=512)
    put(out, slap * ma.exp_decay(n, 0.06), 0.002, 0.6)
    put(out, mm.splash(0.34, rng, size=0.5), 0.006, 0.35)
    put(out, mm.cloth(0.26, rng, weight=0.75, rate=260.0), 0.03, 0.45)
    put(out, mm.granular(0.4, rng, count=14, fc_low=500.0, fc_high=4000.0), 0.04, 0.22)
    return out


def water_enter(rng: np.random.Generator) -> np.ndarray:
    """A body entering deep water: a large surface break, then a long closing
    cloud of big bubbles, then the muffled quiet underneath."""
    out = buf(1.5)
    put(out, mm.splash(0.7, rng, size=0.95), 0.0, 1.0)
    put(out, mm.body(70.0, 0.3, drop=0.4, curve=0.5), 0.004, 0.5)
    put(out, mm.bubble_cloud(1.1, rng, count=70, r_min=0.001, r_max=0.014,
                             density_curve=1.2), 0.06, 0.55)
    return out


def swim_stroke(rng: np.random.Generator) -> np.ndarray:
    """An arm pulling through water. No impact at all — a broad low swell of
    displaced water and a fine bubble trail. The absence of a transient is the
    whole point; a stroke that clicks reads as a splash."""
    out = buf(0.75)
    n = ma.samples(0.5)
    pull = ma.swept_bandpass(ma.white(n, rng), np.geomspace(320.0, 1500.0, n),
                             octaves=2.0, block=1024)
    put(out, pull * (np.sin(np.pi * np.linspace(0, 1, n)) ** 1.4), 0.0, 0.6)
    put(out, mm.bubble_cloud(0.6, rng, count=34, r_min=0.0006, r_max=0.005,
                             density_curve=1.0), 0.05, 0.45)
    put(out, mm.body(58.0, 0.3, drop=0.7, curve=0.7, tau_ratio=0.5), 0.02, 0.2)
    return out


# ═══════════════════════════════════════════════════════════════════════════
# MELEE — three swing weights, six impact materials
# ═══════════════════════════════════════════════════════════════════════════

def swing_light(rng: np.random.Generator) -> np.ndarray:
    """A skewer or a dagger. Small surface, so the arc is quiet, fast and
    high — barely more than the sound of a hand moving."""
    return mm.air_arc(0.17, rng, f_low=700.0, f_high=3400.0, width=1.0,
                      peak_at=0.48, sharp=2.2) * rng.uniform(0.9, 1.0)


def swing_blade(rng: np.random.Generator) -> np.ndarray:
    """A sword or cleaver. A blade has an edge-on cross-section, which is why a
    real sword whoosh is NARROW-band and has a faint pitch to it — the edge
    sheds a coherent vortex. That thin tonal streak is the whole difference
    between a sword and a stick."""
    out = buf(0.28)
    put(out, mm.air_arc(0.22, rng, f_low=900.0, f_high=4600.0, width=0.55,
                        peak_at=0.5, sharp=2.0), 0.0, 1.0)
    n = ma.samples(0.22)
    edge = ma.sine_glide(1700.0, 3300.0, 0.22, curve=0.9)
    put(out, edge * (np.sin(np.pi * np.linspace(0, 1, n)) ** 3.0), 0.0, 0.10)
    return out


def swing_heavy(rng: np.random.Generator) -> np.ndarray:
    """An axe or a hammer. Two arcs an octave apart, the low one leading,
    because a big head moves a wide column of air and the pressure wave arrives
    before the turbulence does. Slower and later-peaking than the others."""
    out = buf(0.44)
    put(out, mm.air_arc(0.36, rng, f_low=150.0, f_high=680.0, width=1.7,
                        peak_at=0.58, sharp=1.5), 0.0, 0.9)
    put(out, mm.air_arc(0.32, rng, f_low=420.0, f_high=1700.0, width=1.1,
                        peak_at=0.56, sharp=1.7), 0.022, 0.55)
    n = ma.samples(0.3)
    put(out, ma.sine_glide(78.0, 44.0, 0.3) * (np.sin(np.pi * np.linspace(0, 1, n)) ** 2.2),
        0.02, 0.3)
    return out


def hit_flesh(rng: np.random.Generator) -> np.ndarray:
    """A body taking a blow. Foley makes this by hitting a wet chamois or a
    watermelon, and the physics agrees: `flesh` has the second-highest loss
    factor in the table, so the membrane modes are gone inside 40 ms and what
    remains is a low, wet slap. Anything that rings here reads as armour."""
    out = buf(0.3)
    put(out, mm.body(112.0, 0.13, drop=0.42, curve=0.5, tau_ratio=0.3), 0.0, 1.0)
    put(out, mm.struck(rng.uniform(105.0, 145.0), "flesh", 0.14, rng,
                       geometry="membrane", hardness=0.3, modes=5, mounting=0.06),
        0.0015, 0.6)
    n = ma.samples(0.12)
    wet = ma.fft_filter(ma.pink(n, rng), fc_low=140.0, fc_high=1250.0, order=2)
    put(out, wet * ma.exp_decay(n, 0.035), 0.001, 0.6)
    put(out, mm.bubble_cloud(0.14, rng, count=5, r_min=0.0004, r_max=0.0018), 0.01, 0.12)
    return out


def hit_bone(rng: np.random.Generator) -> np.ndarray:
    """A blow that breaks something. Foley snaps celery inside a chamois, and
    that is exactly a bright short-decay bar mode over a fibrous granular tear
    inside a wet slap — so that is how it is built, layer for layer."""
    out = buf(0.38)
    put(out, mm.body(120.0, 0.12, drop=0.45, curve=0.5), 0.0, 0.8)
    put(out, mm.struck(rng.uniform(950.0, 1350.0), "bone", 0.22, rng,
                       geometry="bar_free", hardness=0.9, position=0.36,
                       modes=5, mounting=0.09), 0.0025, 0.85)
    # the fibres letting go, one after another — the "snap" itself
    put(out, mm.friction(0.045, rng, material="bone", f_low=1400.0, f_high=5200.0,
                         rate=520.0, roughness=0.9)
        * ma.exp_decay(ma.samples(0.045), 0.012), 0.002, 0.55)
    n = ma.samples(0.11)
    put(out, ma.fft_filter(ma.pink(n, rng), fc_low=180.0, fc_high=1300.0)
        * ma.exp_decay(n, 0.03), 0.0, 0.5)
    return out


def hit_carapace(rng: np.random.Generator) -> np.ndarray:
    """A crawler's shell. Chitin is a closed tube at moderate damping: it rings,
    but only for about 40 ms, and the odd-harmonic series of a stopped tube is
    what gives it that hollow, slightly wrong quality. The mire's fauna should
    not sound like anything with bones."""
    out = buf(0.42)
    base = rng.uniform(470.0, 620.0)
    put(out, mm.body(150.0, 0.09, drop=0.5, curve=0.45), 0.0, 0.6)
    put(out, mm.struck(base, "chitin", 0.34, rng, geometry="tube_closed",
                       hardness=0.85, position=0.27, modes=5, mounting=0.045), 0.0015, 0.95)
    put(out, mm.strike_noise(0.07, rng, "chitin", hardness=0.85, brightness=1.3), 0.0, 0.4)
    put(out, mm.granular(0.18, rng, count=7, fc_low=1800.0, fc_high=8000.0,
                         grain_s=(0.001, 0.004)), 0.008, 0.16)
    return out


def hit_wood(rng: np.random.Generator) -> np.ndarray:
    """A weapon into a built structure or a trunk — the "you hit the wrong
    thing" sound. Dry mounted timber, moderate contact: a hard knock with a
    short tonal tail and no debris to speak of."""
    out = buf(0.34)
    put(out, mm.body(130.0, 0.09, drop=0.5, curve=0.45), 0.0, 0.6)
    put(out, mm.struck(rng.uniform(175.0, 245.0), "wood_dry", 0.28, rng,
                       geometry="bar_free", hardness=0.75, position=0.33,
                       modes=5, mounting=0.09), 0.002, 0.9)
    put(out, mm.strike_noise(0.06, rng, "wood_dry", hardness=0.78, brightness=1.1),
        0.0005, 0.4)
    return out


def hit_stone(rng: np.random.Generator) -> np.ndarray:
    """A weapon into rock. Bright, dead and unrewarding on purpose — the sound
    should tell a player they are wasting a swing."""
    out = buf(0.3)
    put(out, mm.body(175.0, 0.06, drop=0.45, curve=0.4), 0.0, 0.5)
    put(out, mm.struck(rng.uniform(820.0, 1150.0), "granite", 0.2, rng,
                       geometry="irregular", hardness=0.9, modes=6, mounting=0.06), 0.001, 0.8)
    put(out, mm.strike_noise(0.07, rng, "granite", hardness=0.9, brightness=1.5), 0.0, 0.55)
    put(out, mm.granular(0.16, rng, count=7, fc_low=2600.0, fc_high=10000.0,
                         grain_s=(0.001, 0.004)), 0.006, 0.2)
    return out


def hit_metal(rng: np.random.Generator) -> np.ndarray:
    """Steel meeting steel — a parry, or a blade off armour. The only impact in
    the game with a real tail: iron at a gripped mounting still rings for over a
    tenth of a second, and two slightly detuned bars beating against each other
    is what makes it sound like two objects rather than a bell."""
    out = buf(0.9)
    base = rng.uniform(1250.0, 1700.0)
    put(out, mm.struck(base, "iron", 0.8, rng, geometry="bar_free", hardness=0.98,
                       position=0.21, modes=6, mounting=0.028, detune_cents=15.0), 0.0, 1.0)
    put(out, mm.struck(base * rng.uniform(1.18, 1.34), "steel", 0.7, rng,
                       geometry="bar_free", hardness=0.98, position=0.29,
                       modes=5, mounting=0.03), 0.0035, 0.5)
    put(out, mm.strike_noise(0.03, rng, "steel", hardness=0.99, brightness=2.0), 0.0, 0.45)
    put(out, mm.body(210.0, 0.05, drop=0.5, curve=0.4), 0.0, 0.3)
    return out


def hit_crit(rng: np.random.Generator) -> np.ndarray:
    """A critical hit. Not a different material — the same flesh-and-bone blow,
    but slowed at the front by a hard leading transient and lifted at the back
    by a short tuned ring in D. The tuning is the tell, and it is the only part
    of the combat set that is deliberately musical."""
    out = buf(0.7)
    put(out, mm.body(96.0, 0.2, drop=0.36, curve=0.45, tau_ratio=0.32), 0.0, 1.0)
    put(out, hit_bone(rng), 0.004, 0.85)
    put(out, mm.struck(ma.note_hz("D6"), "crystal", 0.5, rng, geometry="tube_open",
                       hardness=0.95, modes=4, mounting=0.02), 0.02, 0.22)
    put(out, ma.sine(38.0, 0.4) * ma.exp_decay(ma.samples(0.4), 0.13), 0.002, 0.4)
    return out


# ═══════════════════════════════════════════════════════════════════════════
# RANGED — four weapons, and what their projectiles hit
# ═══════════════════════════════════════════════════════════════════════════

def bow_draw(rng: np.random.Generator) -> np.ndarray:
    """Drawing a longbow. Two mechanisms at once: the limbs bending (a slow
    creak — stick-slip in the wood, so an accelerating impulse train) and the
    string sliding over the arrow rest and the glove. Rising in both rate and
    brightness as the draw weight climbs, because that is what tells the player
    the shot is charged."""
    out = buf(0.95)
    creak = ma.burst_train(0.75, 13.0, 34.0, rng, jitter=0.4)
    creak = ma.swept_bandpass(creak, np.geomspace(240.0, 700.0, creak.shape[0]),
                              octaves=1.0, block=1024)
    put(out, creak * np.linspace(0.25, 1.0, creak.shape[0]) ** 1.3, 0.0, 0.6)
    put(out, mm.friction(0.7, rng, material="leather", f_low=1500.0, f_high=4200.0,
                         rate=150.0, roughness=0.7) * np.linspace(0.2, 1.0, ma.samples(0.7)),
        0.05, 0.28)
    put(out, mm.cloth(0.5, rng, weight=0.35, rate=90.0), 0.02, 0.22)
    return out


def bow_release(rng: np.random.Generator) -> np.ndarray:
    """The string returning. A bowstring is a stretched cord at very high
    tension — a `bar_free` series at a high fundamental and low damping, struck
    by its own release — over the limbs' low thump and the arrow leaving the
    rest. All of it is over in a tenth of a second."""
    out = buf(0.55)
    put(out, mm.struck(rng.uniform(300.0, 380.0), "wood_dry", 0.3, rng,
                       geometry="bar_free", hardness=0.6, position=0.5,
                       modes=4, mounting=0.13), 0.0, 0.7)
    put(out, mm.body(150.0, 0.09, drop=0.4, curve=0.45), 0.0, 0.75)
    # the string itself, high and brief
    put(out, mm.struck(rng.uniform(1300.0, 1750.0), "leather", 0.12, rng,
                       geometry="bar_free", hardness=0.85, modes=4, mounting=0.05),
        0.001, 0.45)
    put(out, mm.strike_noise(0.05, rng, "leather", hardness=0.8, brightness=1.4), 0.0, 0.3)
    put(out, mm.air_arc(0.1, rng, f_low=900.0, f_high=3000.0, width=1.4,
                        peak_at=0.3, sharp=1.4), 0.008, 0.25)
    return out


def crossbow_load(rng: np.random.Generator) -> np.ndarray:
    """Cranking and seating a crossbow. Ratchet teeth are the one genuinely
    periodic sound in the game — a real mechanism, so the impulse train is
    regular with only small jitter, unlike every organic creak here."""
    out = buf(1.0)
    t = 0.0
    while t < 0.62:
        put(out, mm.struck(rng.uniform(1500.0, 2100.0), "iron", 0.08, rng,
                           geometry="bar_free", hardness=0.95, modes=3, mounting=0.06),
            t, rng.uniform(0.4, 0.62))
        t += rng.uniform(0.070, 0.082)
    put(out, mm.friction(0.6, rng, material="iron", f_low=700.0, f_high=2400.0,
                         rate=70.0, roughness=0.35), 0.02, 0.16)
    # the bolt seating
    put(out, mm.struck(760.0, "wood_dry", 0.2, rng, geometry="bar_free",
                       hardness=0.8, modes=4, mounting=0.1), 0.70, 0.6)
    put(out, mm.struck(2400.0, "steel", 0.35, rng, geometry="bar_free",
                       hardness=0.98, modes=3, mounting=0.04), 0.705, 0.35)
    return out


def crossbow_release(rng: np.random.Generator) -> np.ndarray:
    """Harder and more metallic than a bow: a steel sear letting go, a
    prod slapping its stop, and far more energy in the first five
    milliseconds."""
    out = buf(0.6)
    put(out, mm.struck(2600.0, "steel", 0.3, rng, geometry="bar_free",
                       hardness=0.99, modes=4, mounting=0.05), 0.0, 0.55)
    put(out, mm.body(190.0, 0.1, drop=0.35, curve=0.4), 0.001, 0.9)
    put(out, mm.struck(rng.uniform(420.0, 520.0), "wood_dry", 0.25, rng,
                       geometry="bar_free", hardness=0.85, position=0.5,
                       modes=4, mounting=0.11), 0.003, 0.7)
    put(out, mm.strike_noise(0.04, rng, "steel", hardness=0.99, brightness=1.8), 0.0, 0.4)
    put(out, mm.air_arc(0.09, rng, f_low=1100.0, f_high=3600.0, width=1.2,
                        peak_at=0.3, sharp=1.5), 0.007, 0.22)
    return out


def sling_whirl(rng: np.random.Generator) -> np.ndarray:
    """A sling swung overhead. Two full rotations before the release: the same
    air arc three times over at rising speed, with a cord flutter riding it."""
    out = buf(1.15)
    for i, (at, lo, hi) in enumerate(((0.0, 220.0, 900.0), (0.34, 260.0, 1150.0),
                                      (0.63, 320.0, 1500.0), (0.88, 380.0, 1900.0))):
        put(out, mm.air_arc(0.30 - 0.03 * i, rng, f_low=lo, f_high=hi, width=1.6,
                            peak_at=0.5, sharp=1.4), at, 0.45 + 0.18 * i)
    put(out, mm.friction(1.0, rng, material="leather", f_low=600.0, f_high=2600.0,
                         rate=45.0, roughness=0.9), 0.0, 0.14)
    return out


def arrow_whizz(rng: np.random.Generator) -> np.ndarray:
    """An arrow passing. Fletching spins, so the sound is a narrow band with a
    fast amplitude flutter at the spin rate, and it Dopplers: the band rises as
    it approaches and falls as it goes by. Both cues together are what make it
    pass THROUGH the listener rather than at them."""
    n = ma.samples(0.45)
    x = np.linspace(0.0, 1.0, n)
    centers = np.interp(x, [0.0, 0.5, 1.0], [1500.0, 2400.0, 1150.0])
    sig = ma.swept_bandpass(ma.white(n, rng), centers, octaves=0.7, block=512)
    spin = 0.55 + 0.45 * np.sin(2 * np.pi * np.cumsum(np.linspace(70.0, 52.0, n)) / ma.SR)
    env = np.exp(-((x - 0.5) ** 2) / (2 * 0.16 ** 2))
    return sig * spin * env


def arrow_hit_flesh(rng: np.random.Generator) -> np.ndarray:
    """A broadhead arriving. Almost no impact — an arrow is light and sharp, so
    the contact is a fast wet puncture rather than a blow — followed by the
    shaft ringing briefly, which is the part that says "arrow"."""
    out = buf(0.5)
    n = ma.samples(0.07)
    punch = ma.swept_bandpass(ma.white(n, rng), np.geomspace(2600.0, 500.0, n),
                              octaves=1.6, block=512)
    put(out, punch * ma.exp_decay(n, 0.018), 0.0, 0.8)
    put(out, mm.body(140.0, 0.08, drop=0.5, curve=0.5), 0.001, 0.55)
    put(out, mm.struck(rng.uniform(115.0, 150.0), "flesh", 0.1, rng,
                       geometry="membrane", hardness=0.6, modes=4, mounting=0.07), 0.002, 0.45)
    # the shaft, still vibrating in the wound
    put(out, mm.struck(rng.uniform(340.0, 430.0), "wood_dry", 0.35, rng,
                       geometry="bar_clamped", hardness=0.7, modes=3, mounting=0.05),
        0.012, 0.3)
    put(out, mm.bubble_cloud(0.16, rng, count=5, r_min=0.0004, r_max=0.002), 0.015, 0.12)
    return out


def arrow_hit_wood(rng: np.random.Generator) -> np.ndarray:
    """Into a trunk or a palisade. A sharp bite, then the shaft's clamped-bar
    modes — a cantilever, because one end is now buried — which is the
    unmistakable *thock-oing* of an arrow that stuck."""
    out = buf(0.65)
    put(out, mm.strike_noise(0.05, rng, "wood_dry", hardness=0.95, brightness=1.6), 0.0, 0.65)
    put(out, mm.struck(rng.uniform(200.0, 280.0), "wood_dry", 0.3, rng,
                       geometry="bar_free", hardness=0.9, position=0.3,
                       modes=5, mounting=0.11), 0.0015, 0.8)
    put(out, mm.body(165.0, 0.08, drop=0.45, curve=0.4), 0.0, 0.6)
    put(out, mm.struck(rng.uniform(300.0, 400.0), "wood_dry", 0.5, rng,
                       geometry="bar_clamped", hardness=0.6, modes=3, mounting=0.035),
        0.010, 0.42)
    return out


def arrow_hit_stone(rng: np.random.Generator) -> np.ndarray:
    """A miss off rock. A hard sharp tick, a spark of grit, and the shaft
    clattering away — no penetration, so no clamped ring."""
    out = buf(0.7)
    put(out, mm.strike_noise(0.04, rng, "granite", hardness=0.99, brightness=1.9), 0.0, 0.8)
    put(out, mm.struck(rng.uniform(1600.0, 2300.0), "granite", 0.14, rng,
                       geometry="irregular", hardness=0.99, modes=5, mounting=0.05), 0.001, 0.7)
    put(out, mm.granular(0.14, rng, count=8, fc_low=3500.0, fc_high=13000.0,
                         grain_s=(0.0008, 0.003)), 0.004, 0.28)
    for i in range(3):  # the shaft bouncing away
        put(out, mm.struck(rng.uniform(280.0, 420.0), "wood_dry", 0.14, rng,
                           geometry="bar_free", hardness=0.7, modes=3, mounting=0.12),
            0.10 + i * rng.uniform(0.07, 0.13), rng.uniform(0.10, 0.22))
    return out


# ═══════════════════════════════════════════════════════════════════════════
# CREATURES — five species, built from one throat and different bodies
# ═══════════════════════════════════════════════════════════════════════════

def _throat(f0: float, dur_s: float, rng: np.random.Generator, growl: float = 0.5,
            vowel: str = "ah", rasp: float = 0.4) -> np.ndarray:
    """The shared vocal apparatus. A pulse train through a formant filter is how
    any real animal voice works; `growl` adds sub-harmonic irregularity (the
    vocal folds entering period-doubling, which is literally what a growl is)
    and `rasp` adds turbulent air. Every creature in the game is this with
    different numbers, so the fauna sounds related — one ecology, not five
    sound libraries."""
    n = ma.samples(dur_s)
    t = ma.time_vector(n)
    contour = f0 * (1.0 + 0.18 * ma.slow_noise(n, 6.0, rng))
    phase = 2 * np.pi * np.cumsum(contour) / ma.SR
    source = np.zeros(n)
    for h in range(1, 26):
        if f0 * h > NYQ_LIMIT:
            break
        source += (1.0 / h ** 1.05) * np.sin(h * phase + rng.uniform(0, 6.28))
    if growth := growl:
        # period doubling: a half-rate component beating against the fundamental
        source += growth * 0.55 * np.sin(0.5 * phase + rng.uniform(0, 6.28))
        source *= 1.0 + growth * 0.4 * ma.slow_noise(n, 38.0, rng)
    voiced = mv.formant_filter(source, mv.VOWELS.get(vowel, mv.VOWELS["ah"]))
    breath = ma.fft_filter(ma.white(n, rng), fc_low=900.0, fc_high=6000.0, order=2)
    peak = float(np.max(np.abs(voiced)))
    voiced = voiced / peak if peak > 0 else voiced
    return ma.fade_edges(voiced + rasp * 0.35 * breath, 0.004)


NYQ_LIMIT = ma.SR * 0.45


def creature_chitter(rng: np.random.Generator) -> np.ndarray:
    """A crawler idling. Not a voice at all — stridulation, the way an insect
    makes sound: a chitin plate scraped over a ridge, so it is a fast impulse
    train with a hard resonance, in irregular bursts."""
    out = buf(0.9)
    t = 0.0
    while t < 0.62:
        dur = rng.uniform(0.035, 0.085)
        rate = rng.uniform(220.0, 420.0)
        chirp = mm.friction(dur, rng, material="chitin", f_low=rng.uniform(1600.0, 2400.0),
                            f_high=rng.uniform(4500.0, 7500.0), rate=rate, roughness=0.25)
        put(out, chirp * ma.env_asr(ma.samples(dur), 0.004, 0.02), t, rng.uniform(0.5, 1.0))
        t += dur + rng.uniform(0.03, 0.13)
    return out


def creature_alert(rng: np.random.Generator) -> np.ndarray:
    """It has seen you. A rising hiss into a short bark — the pitch contour is
    the information, and it must go UP, because every alarm call in nature
    does."""
    out = buf(0.85)
    n = ma.samples(0.3)
    hiss = ma.swept_bandpass(ma.white(n, rng), np.geomspace(1400.0, 4200.0, n),
                             octaves=1.6, block=512)
    put(out, hiss * (np.linspace(0.1, 1.0, n) ** 1.6), 0.0, 0.55)
    put(out, _throat(rng.uniform(180.0, 250.0), 0.28, rng, growl=0.7, vowel="ah", rasp=0.7)
        * ma.env_asr(ma.samples(0.28), 0.012, 0.16), 0.28, 0.95)
    put(out, mm.struck(rng.uniform(520.0, 700.0), "chitin", 0.2, rng,
                       geometry="tube_closed", hardness=0.5, modes=4, mounting=0.06),
        0.30, 0.18)
    return out


def creature_attack(rng: np.random.Generator) -> np.ndarray:
    """The lunge. A short hard exhale over the body's own chitin knocking as it
    moves, and a snap of whatever it bites with at the end."""
    out = buf(0.75)
    put(out, _throat(rng.uniform(150.0, 210.0), 0.22, rng, growl=0.9, vowel="oh", rasp=0.9)
        * ma.env_asr(ma.samples(0.22), 0.006, 0.13), 0.0, 1.0)
    put(out, mm.air_arc(0.2, rng, f_low=300.0, f_high=1400.0, width=1.8,
                        peak_at=0.55, sharp=1.4), 0.03, 0.35)
    # the bite closing
    put(out, mm.struck(rng.uniform(700.0, 1000.0), "chitin", 0.16, rng,
                       geometry="tube_closed", hardness=0.95, modes=4, mounting=0.04),
        0.24, 0.6)
    put(out, mm.strike_noise(0.05, rng, "chitin", hardness=0.95, brightness=1.5), 0.24, 0.35)
    return out


def creature_hurt(rng: np.random.Generator) -> np.ndarray:
    """A hit landing on something alive. The throat clamps — pitch jumps up and
    then collapses, which is the involuntary contour of any animal in pain and
    the thing that separates it from an attack cry."""
    out = buf(0.6)
    n = ma.samples(0.26)
    f0 = rng.uniform(210.0, 300.0)
    voice = _throat(f0, 0.26, rng, growl=0.85, vowel="ah", rasp=0.8)
    bend = np.interp(np.linspace(0, 1, n), [0.0, 0.15, 1.0], [1.25, 1.35, 0.62])
    voice = np.interp(np.cumsum(bend) * (n - 1) / np.sum(bend), np.arange(n), voice)
    put(out, voice * ma.env_asr(n, 0.005, 0.17), 0.0, 1.0)
    put(out, mm.strike_noise(0.06, rng, "chitin", hardness=0.8, brightness=1.2), 0.0, 0.3)
    return out


def creature_death(rng: np.random.Generator) -> np.ndarray:
    """It stops. The voice falls away and loses its pitch entirely, the legs
    fold, and the shell settles onto the ground — three stages, and the last one
    is what makes it read as final rather than as another hurt."""
    out = buf(1.5)
    n = ma.samples(0.55)
    voice = _throat(rng.uniform(190.0, 240.0), 0.55, rng, growl=1.0, vowel="oh", rasp=1.0)
    fall = np.interp(np.linspace(0, 1, n), [0.0, 0.35, 1.0], [1.0, 0.78, 0.42])
    voice = np.interp(np.cumsum(fall) * (n - 1) / np.sum(fall), np.arange(n), voice)
    put(out, voice * ma.env_asr(n, 0.01, 0.4), 0.0, 1.0)
    for i in range(5):  # limbs giving way
        put(out, mm.struck(rng.uniform(600.0, 1300.0), "chitin", 0.18, rng,
                           geometry="tube_closed", hardness=0.6, modes=4, mounting=0.07),
            rng.uniform(0.35, 0.9), rng.uniform(0.10, 0.24))
    put(out, mm.body(88.0, 0.3, drop=0.45, curve=0.5), 0.80, 0.55)
    put(out, mm.strike_noise(0.3, rng, "mud", hardness=0.3, brightness=0.8), 0.80, 0.4)
    put(out, mm.bubble_cloud(0.4, rng, count=12, r_min=0.0006, r_max=0.005), 0.83, 0.2)
    return out


def tusker_snort(rng: np.random.Generator) -> np.ndarray:
    """The big one. Same throat an octave and a half down with heavy growl, plus
    the nasal blast that only a large air passage can make. Slow, and it should
    make a player stop walking."""
    out = buf(1.3)
    put(out, _throat(rng.uniform(62.0, 82.0), 0.75, rng, growl=1.0, vowel="oh", rasp=0.5)
        * ma.env_asr(ma.samples(0.75), 0.09, 0.42), 0.0, 1.0)
    n = ma.samples(0.32)
    blast = ma.swept_bandpass(ma.white(n, rng), np.geomspace(700.0, 210.0, n),
                              octaves=1.9, block=512)
    put(out, blast * ma.env_asr(n, 0.012, 0.2), 0.55, 0.55)
    put(out, mm.bubble_cloud(0.3, rng, count=14, r_min=0.001, r_max=0.007), 0.57, 0.22)
    put(out, ma.sine(41.0, 0.7) * ma.env_asr(ma.samples(0.7), 0.12, 0.45), 0.02, 0.3)
    return out


def broodcaller_call(rng: np.random.Generator) -> np.ndarray:
    """The summoning call. Two throats a tritone apart — the one interval the
    ambience reserves for dread — sounding not quite together, over a sub swell
    that arrives before either of them. Long, so it carries."""
    out = buf(2.6)
    base = rng.uniform(120.0, 150.0)
    put(out, ma.sine(base * 0.25, 1.6) * ma.env_asr(ma.samples(1.6), 0.5, 0.9), 0.0, 0.45)
    for i, (mult, at, gain) in enumerate(((1.0, 0.35, 1.0), (1.4142, 0.47, 0.6))):
        n = ma.samples(1.35)
        voice = _throat(base * mult, 1.35, rng, growl=0.75, vowel="oo", rasp=0.35)
        contour = np.interp(np.linspace(0, 1, n), [0.0, 0.3, 0.72, 1.0],
                            [0.82, 1.14, 1.10, 0.70])
        voice = np.interp(np.cumsum(contour) * (n - 1) / np.sum(contour), np.arange(n), voice)
        put(out, voice * ma.env_asr(n, 0.22, 0.75), at, gain)
    put(out, mv.choir(base * 4.0, 1.4, rng, vowel="mm", voices=3,
                      attack_s=0.4, release_s=0.9), 0.45, 0.12)
    return out


# ═══════════════════════════════════════════════════════════════════════════
# THE PLAYER — everything that happens to the person holding the controller
# ═══════════════════════════════════════════════════════════════════════════

def player_hurt(rng: np.random.Generator) -> np.ndarray:
    """A human grunt on impact — an involuntary exhale, not a shout: the air is
    driven out, so it starts at full volume with no attack and the pitch falls.
    Deliberately shorter and less voiced than the creature version, because the
    player's own hurt sound is heard hundreds of times and anything expressive
    becomes unbearable."""
    out = buf(0.5)
    n = ma.samples(0.22)
    voice = _throat(rng.uniform(125.0, 165.0), 0.22, rng, growl=0.25, vowel="oh", rasp=0.85)
    fall = np.interp(np.linspace(0, 1, n), [0.0, 1.0], [1.12, 0.80])
    voice = np.interp(np.cumsum(fall) * (n - 1) / np.sum(fall), np.arange(n), voice)
    put(out, voice * ma.env_asr(n, 0.004, 0.15), 0.0, 1.0)
    put(out, mm.cloth(0.18, rng, weight=0.6, rate=180.0), 0.01, 0.3)
    return out


def player_death(rng: np.random.Generator) -> np.ndarray:
    """The run ending. A long falling exhale that runs out of support, the gear
    hitting the ground, and then a low sub that keeps going after everything
    else has stopped — the only sound in the set allowed to outstay its
    event."""
    out = buf(2.6)
    n = ma.samples(1.0)
    voice = _throat(rng.uniform(115.0, 140.0), 1.0, rng, growl=0.45, vowel="oh", rasp=1.0)
    fall = np.interp(np.linspace(0, 1, n), [0.0, 0.4, 1.0], [1.0, 0.80, 0.5])
    voice = np.interp(np.cumsum(fall) * (n - 1) / np.sum(fall), np.arange(n), voice)
    put(out, voice * ma.env_asr(n, 0.02, 0.7), 0.0, 0.9)
    put(out, mm.cloth(0.45, rng, weight=0.85, rate=280.0), 0.5, 0.5)
    put(out, mm.body(58.0, 0.5, drop=0.4, curve=0.5, tau_ratio=0.3), 0.62, 0.7)
    put(out, mm.splash(0.5, rng, size=0.65), 0.63, 0.35)
    put(out, ma.sine(34.0, 1.8) * ma.env_asr(ma.samples(1.8), 0.35, 1.2), 0.6, 0.45)
    return out


def player_breath_low(rng: np.random.Generator) -> np.ndarray:
    """Near death. One ragged inhale — bright, unvoiced, and rising, which is
    the opposite contour of every other player sound and therefore reads as
    alarm without any musical cue at all."""
    out = buf(1.0)
    n = ma.samples(0.55)
    air = ma.swept_bandpass(ma.white(n, rng), np.geomspace(500.0, 2100.0, n),
                            octaves=1.7, block=512)
    air *= 0.5 + 0.5 * np.abs(ma.slow_noise(n, 24.0, rng))
    put(out, air * ma.env_asr(n, 0.14, 0.3), 0.0, 0.85)
    put(out, _throat(rng.uniform(140.0, 175.0), 0.35, rng, growl=0.5, vowel="ah", rasp=1.0)
        * ma.env_asr(ma.samples(0.35), 0.12, 0.2), 0.12, 0.2)
    return out


def player_heal(rng: np.random.Generator) -> np.ndarray:
    """Recovery. A rising airy swell resolving onto D — the day track's home —
    with an easy breath under it. Warm rather than sparkly: healing is relief,
    not a reward."""
    out = buf(1.3)
    n = ma.samples(0.7)
    swell = ma.swept_bandpass(ma.white(n, rng), np.geomspace(700.0, 4200.0, n),
                              octaves=1.2, block=512)
    put(out, swell * (np.linspace(0.0, 1.0, n) ** 1.8), 0.0, 0.35)
    for i, note in enumerate(("D5", "A5", "D6")):
        put(out, mm.struck(ma.note_hz(note), "crystal", 0.9, rng, geometry="tube_open",
                           hardness=0.55, modes=4, mounting=0.012), 0.34 + 0.075 * i,
            0.5 - 0.11 * i)
    glow = (ma.sine(ma.note_hz("D4"), 0.8) + 0.7 * ma.sine(ma.note_hz("A4"), 0.8))
    put(out, glow * ma.env_asr(ma.samples(0.8), 0.22, 0.45), 0.3, 0.18)
    return out


def player_eat(rng: np.random.Generator) -> np.ndarray:
    """Chewing something. Wet granular crushing in two or three bites, at a
    human rate — irregular, because nobody chews on a grid."""
    out = buf(1.1)
    t = 0.05
    for _ in range(3):
        dur = rng.uniform(0.12, 0.2)
        put(out, mm.granular(dur, rng, count=int(rng.uniform(22, 36)), fc_low=300.0,
                             fc_high=3400.0, grain_s=(0.002, 0.010),
                             density_curve=1.0, decay=0.3), t, rng.uniform(0.55, 0.9))
        put(out, mm.struck(rng.uniform(150.0, 220.0), "flesh", 0.1, rng,
                           geometry="membrane", hardness=0.25, mounting=0.1), t, 0.3)
        t += dur + rng.uniform(0.13, 0.24)
    return out


def player_drink(rng: np.random.Generator) -> np.ndarray:
    """Three swallows. Each is a bubble cluster with a rising throat resonance —
    which is exactly what a swallow physically is, and why a synthesized one
    that does not rise sounds like a drain."""
    out = buf(1.4)
    t = 0.06
    for i in range(3):
        put(out, mm.bubble_cloud(0.2, rng, count=12, r_min=0.0015, r_max=0.008,
                                 density_curve=1.0), t, 0.75)
        n = ma.samples(0.16)
        gulp = ma.swept_bandpass(ma.white(n, rng), np.geomspace(280.0, 900.0, n),
                                 octaves=1.1, block=512)
        put(out, gulp * ma.env_asr(n, 0.02, 0.09), t + 0.03, 0.45)
        t += rng.uniform(0.33, 0.42)
    return out


# ═══════════════════════════════════════════════════════════════════════════
# BUILDING — placing, removing, doors, and structures taking damage
# ═══════════════════════════════════════════════════════════════════════════

def build_place_wood(rng: np.random.Generator) -> np.ndarray:
    """A timber piece seated into place. Two contacts a few tens of ms apart —
    it lands, then it settles — because a single hit reads as dropping something
    rather than as fitting it."""
    out = buf(0.6)
    put(out, mm.body(105.0, 0.11, drop=0.5, curve=0.45), 0.0, 0.7)
    put(out, mm.struck(rng.uniform(140.0, 190.0), "wood_dry", 0.35, rng,
                       geometry="bar_free", hardness=0.7, position=0.32,
                       modes=5, mounting=0.10), 0.002, 0.9)
    put(out, mm.strike_noise(0.07, rng, "wood_dry", hardness=0.7, brightness=1.0), 0.0, 0.35)
    put(out, mm.struck(rng.uniform(200.0, 260.0), "wood_dry", 0.2, rng,
                       geometry="bar_free", hardness=0.5, modes=4, mounting=0.14), 0.055, 0.35)
    return out


def build_place_stone(rng: np.random.Generator) -> np.ndarray:
    """A stone piece set down. Heavier, deader, with grit grinding as it beds
    in — the grind is the part that says the piece is now load-bearing."""
    out = buf(0.7)
    put(out, mm.body(78.0, 0.2, drop=0.4, curve=0.5, tau_ratio=0.3), 0.0, 1.0)
    put(out, mm.struck(rng.uniform(420.0, 560.0), "granite", 0.22, rng,
                       geometry="irregular", hardness=0.7, modes=6, mounting=0.09), 0.002, 0.6)
    put(out, mm.strike_noise(0.12, rng, "granite", hardness=0.65, brightness=1.0), 0.0, 0.45)
    put(out, mm.friction(0.2, rng, material="granite", f_low=500.0, f_high=2600.0,
                         rate=140.0, roughness=0.8) * ma.env_asr(ma.samples(0.2), 0.01, 0.13),
        0.05, 0.3)
    put(out, mm.granular(0.35, rng, count=12, fc_low=900.0, fc_high=6000.0), 0.06, 0.2)
    return out


def build_remove(rng: np.random.Generator) -> np.ndarray:
    """Taking a piece back. The reverse gesture: a wrench of friction first, the
    release, then the piece coming free — so the transient is at the END, which
    is what distinguishes it from placement without any new material."""
    out = buf(0.55)
    put(out, mm.friction(0.16, rng, material="wood_dry", f_low=380.0, f_high=1900.0,
                         rate=120.0, roughness=0.85) * np.linspace(0.3, 1.0, ma.samples(0.16)),
        0.0, 0.55)
    put(out, mm.struck(rng.uniform(180.0, 250.0), "wood_dry", 0.28, rng,
                       geometry="bar_free", hardness=0.75, modes=5, mounting=0.12), 0.16, 0.8)
    put(out, mm.strike_noise(0.06, rng, "wood_dry", hardness=0.8, brightness=1.2), 0.16, 0.35)
    put(out, mm.granular(0.25, rng, count=9, fc_low=800.0, fc_high=5000.0), 0.18, 0.18)
    return out


def build_denied(rng: np.random.Generator) -> np.ndarray:
    """Placement refused. A dull unresonant knock — the sound of something that
    will not go in — with no pitch to it at all, so it never sounds like a
    reward and never becomes annoying at the tenth attempt."""
    out = buf(0.24)
    put(out, mm.body(150.0, 0.06, drop=0.6, curve=0.5, tau_ratio=0.25), 0.0, 0.7)
    put(out, mm.struck(rng.uniform(230.0, 290.0), "mud", 0.1, rng, geometry="membrane",
                       hardness=0.35, modes=4, mounting=0.15), 0.0015, 0.9)
    put(out, mm.strike_noise(0.045, rng, "clay", hardness=0.4, brightness=0.8), 0.0, 0.35)
    return out


def door_open(rng: np.random.Generator) -> np.ndarray:
    """A built door swinging. Latch, then the hinge under load — a real hinge
    creak is stick-slip, so the impulse rate falls as the door slows — then the
    leaf settling against its stop."""
    out = buf(1.4)
    put(out, mm.struck(1700.0, "iron", 0.22, rng, geometry="bar_free",
                       hardness=0.95, modes=3, mounting=0.06), 0.0, 0.55)
    hinge = ma.burst_train(0.62, 46.0, 15.0, rng, jitter=0.45)
    hinge = ma.swept_bandpass(hinge, np.geomspace(900.0, 380.0, hinge.shape[0]),
                              octaves=0.9, block=1024)
    put(out, hinge * np.interp(np.linspace(0, 1, hinge.shape[0]), [0, 0.3, 1], [0.5, 1.0, 0.3]),
        0.06, 0.5)
    put(out, mm.struck(rng.uniform(120.0, 165.0), "wood_dry", 0.35, rng,
                       geometry="bar_free", hardness=0.4, modes=5, mounting=0.12), 0.70, 0.5)
    put(out, mm.body(96.0, 0.14, drop=0.5, curve=0.5), 0.70, 0.4)
    return out


def door_close(rng: np.random.Generator) -> np.ndarray:
    """The same door shutting: hinge first and briefer, then a hard seat and the
    latch dropping — the latch LAST, which is the whole difference between a
    door closing and a door being hit."""
    out = buf(1.1)
    hinge = ma.burst_train(0.34, 18.0, 44.0, rng, jitter=0.45)
    hinge = ma.swept_bandpass(hinge, np.geomspace(420.0, 950.0, hinge.shape[0]),
                              octaves=0.9, block=1024)
    put(out, hinge * np.linspace(0.35, 1.0, hinge.shape[0]), 0.0, 0.45)
    put(out, mm.body(88.0, 0.2, drop=0.4, curve=0.45, tau_ratio=0.3), 0.35, 0.9)
    put(out, mm.struck(rng.uniform(115.0, 155.0), "wood_dry", 0.4, rng,
                       geometry="bar_free", hardness=0.7, position=0.4,
                       modes=5, mounting=0.13), 0.352, 0.8)
    put(out, mm.struck(1850.0, "iron", 0.25, rng, geometry="bar_free",
                       hardness=0.97, modes=3, mounting=0.05), 0.44, 0.5)
    return out


def structure_hit(rng: np.random.Generator) -> np.ndarray:
    """Something attacking a wall. A big mounted timber panel: low, boomy,
    barely tonal, with the whole structure's mass in the body layer. Must be
    audible from inside a base, which is why it is weighted low."""
    out = buf(0.75)
    put(out, mm.body(74.0, 0.26, drop=0.36, curve=0.45, tau_ratio=0.3), 0.0, 1.0)
    put(out, mm.struck(rng.uniform(95.0, 130.0), "wood_dry", 0.45, rng,
                       geometry="bar_free", hardness=0.55, position=0.44,
                       modes=6, mounting=0.14), 0.003, 0.8)
    put(out, mm.strike_noise(0.14, rng, "wood_dry", hardness=0.6, brightness=0.9), 0.0, 0.4)
    put(out, mm.granular(0.3, rng, count=10, fc_low=600.0, fc_high=4500.0), 0.03, 0.16)
    return out


def structure_destroy(rng: np.random.Generator) -> np.ndarray:
    """A built piece failing. Nails tearing out of wet timber, the piece
    dropping, and the debris — and unlike a tree, this one has iron in it, which
    is the tell that what just broke was something a player made."""
    out = buf(2.0)
    put(out, mm.strike_noise(0.3, rng, "wood_dry", hardness=0.8, brightness=1.2), 0.0, 0.7)
    put(out, mm.struck(rng.uniform(105.0, 145.0), "wood_dry", 0.55, rng,
                       geometry="bar_free", hardness=0.8, position=0.38,
                       modes=6, mounting=0.06), 0.003, 0.9)
    put(out, mm.body(88.0, 0.4, drop=0.32, curve=0.45, tau_ratio=0.28), 0.0, 0.95)
    for _ in range(4):  # nails and fittings
        put(out, mm.struck(rng.uniform(1400.0, 2900.0), "iron", 0.3, rng,
                           geometry="bar_free", hardness=0.9, modes=3, mounting=0.04),
            rng.uniform(0.05, 0.75), rng.uniform(0.08, 0.2))
    put(out, mm.body(70.0, 0.5, drop=0.3, curve=0.5, tau_ratio=0.25), 0.62, 0.7)
    put(out, mm.splash(0.5, rng, size=0.55), 0.63, 0.3)
    put(out, mm.granular(1.2, rng, count=34, fc_low=500.0, fc_high=5500.0,
                         density_curve=1.5), 0.68, 0.32)
    return out


# ═══════════════════════════════════════════════════════════════════════════
# CRAFTING & STATIONS — workbench, furnace, repair
# ═══════════════════════════════════════════════════════════════════════════

def craft_work(rng: np.random.Generator) -> np.ndarray:
    """Working at a bench. Three or four tool strokes at a human, uneven rate —
    a rasp, a knock, a rasp — because a regular rhythm reads as a machine and
    this is meant to sound like hands."""
    out = buf(1.5)
    t = 0.03
    for i in range(4):
        if rng.uniform() > 0.45:
            dur = rng.uniform(0.16, 0.26)
            put(out, mm.friction(dur, rng, material="wood_dry", f_low=600.0,
                                 f_high=3200.0, rate=rng.uniform(150.0, 240.0), roughness=0.5)
                * ma.env_asr(ma.samples(dur), 0.02, 0.09), t, rng.uniform(0.5, 0.75))
            t += dur + rng.uniform(0.06, 0.16)
        else:
            put(out, mm.struck(rng.uniform(190.0, 280.0), "wood_dry", 0.25, rng,
                               geometry="bar_free", hardness=0.8, modes=5, mounting=0.11),
                t, rng.uniform(0.5, 0.8))
            put(out, mm.body(140.0, 0.07, drop=0.5), t, 0.4)
            t += rng.uniform(0.17, 0.3)
    return out


def craft_complete(rng: np.random.Generator) -> np.ndarray:
    """A recipe finishing. One settling knock and a two-note rise in D — the
    smallest possible reward, because crafting happens constantly and anything
    fanfare-shaped would wear out in an hour."""
    out = buf(0.9)
    put(out, mm.struck(rng.uniform(165.0, 210.0), "wood_dry", 0.28, rng,
                       geometry="bar_free", hardness=0.7, modes=5, mounting=0.11), 0.0, 0.55)
    put(out, mm.body(120.0, 0.08, drop=0.5), 0.0, 0.35)
    for i, note in enumerate(("A5", "D6")):
        put(out, mm.struck(ma.note_hz(note), "crystal", 0.6, rng, geometry="tube_open",
                           hardness=0.6, modes=4, mounting=0.014), 0.10 + 0.09 * i,
            0.40 - 0.08 * i)
    return out


def craft_denied(rng: np.random.Generator) -> np.ndarray:
    """Missing an ingredient. Two dull unpitched taps — the universal "no" — kept
    well below every other sound so it never punishes."""
    out = buf(0.32)
    for i, at in enumerate((0.0, 0.085)):
        put(out, mm.struck(rng.uniform(300.0, 350.0) * (1.0 - 0.13 * i), "clay", 0.1, rng,
                           geometry="irregular", hardness=0.45, modes=3, mounting=0.2),
            at, 0.85 - 0.2 * i)
        put(out, mm.strike_noise(0.03, rng, "clay", hardness=0.5, brightness=0.9), at, 0.3)
    return out


def furnace_light(rng: np.random.Generator) -> np.ndarray:
    """A furnace catching. A striker, then the moment the fuel takes — a soft
    whump of expanding air — and the fire settling into its crackle. The whump
    is the part that makes it read as ignition and not as a match."""
    out = buf(2.2)
    put(out, mm.friction(0.10, rng, material="steel", f_low=2600.0, f_high=9000.0,
                         rate=400.0, roughness=0.5) * ma.exp_decay(ma.samples(0.10), 0.03),
        0.0, 0.5)
    put(out, mm.granular(0.12, rng, count=8, fc_low=4000.0, fc_high=14000.0,
                         grain_s=(0.0008, 0.003)), 0.01, 0.3)
    n = ma.samples(0.55)
    whump = ma.swept_bandpass(ma.white(n, rng), np.geomspace(600.0, 130.0, n),
                              octaves=2.2, block=1024)
    put(out, whump * np.interp(np.linspace(0, 1, n), [0, 0.12, 1], [0.0, 1.0, 0.0]) ** 1.3,
        0.14, 0.75)
    put(out, ma.sine_glide(70.0, 40.0, 0.4) * ma.exp_decay(ma.samples(0.4), 0.14), 0.15, 0.4)
    put(out, mm.crackle(1.5, rng, rate=48.0) * np.interp(
        np.linspace(0, 1, ma.samples(1.5)), [0, 0.15, 0.7, 1.0], [0.3, 1.0, 0.9, 0.55]),
        0.3, 0.5)
    return out


def furnace_loop(rng: np.random.Generator) -> np.ndarray:
    """A lit furnace, as a seamless loop for a station the player stands near.
    Rendered circularly so the tail folds onto the head — the same trick the
    music beds use, and the reason this can run for ten minutes without a seam.
    Fire is crackle over a low roar of draught; the roar is what makes it a
    furnace rather than a campfire."""
    loop_s = 4.0
    n_loop = ma.samples(loop_s)
    raw = np.zeros(ma.samples(loop_s + 1.5))
    put(raw, mm.crackle(loop_s + 1.5, rng, rate=52.0), 0.0, 0.7)
    n = raw.shape[0]
    roar = ma.fft_filter(ma.pink(n, rng), fc_low=45.0, fc_high=420.0, order=2)
    roar *= 1.0 + 0.5 * ma.slow_noise(n, 1.6, rng)
    raw += 0.75 * roar
    draught = ma.fft_filter(ma.white(n, rng), fc_low=700.0, fc_high=3600.0, order=2)
    raw += 0.16 * draught * (0.6 + 0.4 * ma.slow_noise(n, 0.9, rng))
    out = raw[:n_loop].copy()
    out[: n - n_loop] += raw[n_loop:]      # circular fold: no seam
    return out


def repair_hit(rng: np.random.Generator) -> np.ndarray:
    """The repair hammer. A hammer face on timber with a nail under it: a hard
    contact, a bright iron tick from the nail head, and the plank taking the
    blow. Three hits' worth of information in one, so it reads as work."""
    out = buf(0.5)
    put(out, mm.body(125.0, 0.1, drop=0.45, curve=0.45), 0.0, 0.75)
    put(out, mm.struck(rng.uniform(2100.0, 2800.0), "iron", 0.18, rng,
                       geometry="bar_free", hardness=0.99, modes=3, mounting=0.08), 0.0005, 0.4)
    put(out, mm.struck(rng.uniform(155.0, 205.0), "wood_dry", 0.3, rng,
                       geometry="bar_free", hardness=0.85, position=0.36,
                       modes=5, mounting=0.12), 0.002, 0.85)
    put(out, mm.strike_noise(0.05, rng, "wood_dry", hardness=0.9, brightness=1.3), 0.0, 0.35)
    return out


# ═══════════════════════════════════════════════════════════════════════════
# ITEMS, INVENTORY, LOOT
# ═══════════════════════════════════════════════════════════════════════════

def item_pickup(rng: np.random.Generator) -> np.ndarray:
    """Taking something. Deliberately diegetic and small: leather, a knock of
    the object into the pack, and one quiet pip in D so it still registers.
    A player picks up hundreds of things a run, and the arcade version of this
    sound is the fastest way to make a long run exhausting."""
    out = buf(0.45)
    put(out, mm.cloth(0.14, rng, weight=0.3, rate=240.0), 0.0, 0.55)
    put(out, mm.struck(rng.uniform(380.0, 500.0), "wood_dry", 0.16, rng,
                       geometry="irregular", hardness=0.7, modes=4, mounting=0.13), 0.028, 0.5)
    put(out, mm.granular(0.12, rng, count=4, fc_low=1000.0, fc_high=5000.0,
                         grain_s=(0.002, 0.008)), 0.04, 0.2)
    pip = ma.sine(ma.note_hz("D6"), 0.09) * ma.env_asr(ma.samples(0.09), 0.005, 0.075)
    put(out, pip, 0.075, 0.13)
    return out


def item_drop(rng: np.random.Generator) -> np.ndarray:
    """Putting something down. The same materials with the order reversed —
    cloth after the knock rather than before it, and no pip. That ordering is
    the entire difference, and it is enough."""
    out = buf(0.5)
    put(out, mm.body(120.0, 0.09, drop=0.5, curve=0.5), 0.0, 0.5)
    put(out, mm.struck(rng.uniform(300.0, 420.0), "wood_dry", 0.22, rng,
                       geometry="irregular", hardness=0.65, modes=4, mounting=0.14), 0.002, 0.7)
    put(out, mm.cloth(0.16, rng, weight=0.4, rate=200.0), 0.03, 0.35)
    put(out, mm.granular(0.18, rng, count=5, fc_low=700.0, fc_high=4000.0), 0.05, 0.2)
    return out


def inventory_move(rng: np.random.Generator) -> np.ndarray:
    """Moving a stack between slots. Almost nothing — a soft leather brush. It
    must be quieter than every other sound in the game because it fires more
    often than any of them."""
    out = buf(0.16)
    put(out, mm.cloth(0.09, rng, weight=0.2, rate=300.0), 0.0, 0.8)
    put(out, mm.struck(rng.uniform(600.0, 800.0), "leather", 0.07, rng,
                       geometry="irregular", hardness=0.5, modes=3, mounting=0.2), 0.01, 0.25)
    return out


def equip_blade(rng: np.random.Generator) -> np.ndarray:
    """Drawing steel. The scrape of the edge leaving a sheath — friction whose
    rate rises as the blade accelerates out — ending on the ring of the free
    blade. The ring must arrive AFTER the scrape stops, or it sounds like the
    sword is still inside."""
    out = buf(0.9)
    n = ma.samples(0.24)
    put(out, mm.friction(0.24, rng, material="leather", f_low=900.0, f_high=5200.0,
                         rate=260.0, roughness=0.4) * np.linspace(0.35, 1.0, n) ** 1.4,
        0.0, 0.7)
    put(out, mm.struck(rng.uniform(1450.0, 1900.0), "steel", 0.6, rng,
                       geometry="bar_free", hardness=0.9, position=0.24,
                       modes=5, mounting=0.03), 0.235, 0.55)
    put(out, mm.air_arc(0.14, rng, f_low=800.0, f_high=2600.0, width=1.0,
                        peak_at=0.4, sharp=1.6), 0.24, 0.2)
    return out


def equip_tool(rng: np.random.Generator) -> np.ndarray:
    """Taking up an axe or a pick. No steel ring — a haft slapping into a palm,
    a heavy head shifting, and the strap that was holding it."""
    out = buf(0.55)
    put(out, mm.cloth(0.13, rng, weight=0.6, rate=180.0), 0.0, 0.5)
    put(out, mm.struck(rng.uniform(210.0, 280.0), "wood_dry", 0.2, rng,
                       geometry="bar_free", hardness=0.55, modes=4, mounting=0.22), 0.02, 0.7)
    put(out, mm.body(105.0, 0.07, drop=0.55, curve=0.5), 0.02, 0.4)
    put(out, mm.struck(rng.uniform(1300.0, 1800.0), "iron", 0.22, rng,
                       geometry="bar_free", hardness=0.6, modes=3, mounting=0.10), 0.045, 0.18)
    return out


def equip_bow(rng: np.random.Generator) -> np.ndarray:
    """Bringing a bow up. Light wood, a string touched, cloth. The string tap is
    the identifying detail and it costs one layer."""
    out = buf(0.5)
    put(out, mm.cloth(0.12, rng, weight=0.35, rate=220.0), 0.0, 0.45)
    put(out, mm.struck(rng.uniform(330.0, 420.0), "wood_dry", 0.24, rng,
                       geometry="bar_free", hardness=0.5, modes=4, mounting=0.16), 0.022, 0.5)
    put(out, mm.struck(rng.uniform(1500.0, 1900.0), "leather", 0.1, rng,
                       geometry="bar_free", hardness=0.8, modes=3, mounting=0.06), 0.06, 0.3)
    return out


def chest_open(rng: np.random.Generator) -> np.ndarray:
    """A chest. Latch, hinge under load, the lid meeting its stop — the whole
    sound is a mechanism, with no magic in it at all. The reward is what is
    inside; spending a fanfare on the container leaves nothing for the rare
    drop, which is the sound that should actually stop a player."""
    out = buf(1.6)
    put(out, mm.struck(rng.uniform(1500.0, 1900.0), "iron", 0.25, rng,
                       geometry="bar_free", hardness=0.97, modes=3, mounting=0.055), 0.0, 0.6)
    put(out, mm.body(180.0, 0.07, drop=0.5, curve=0.4), 0.001, 0.4)
    hinge = ma.burst_train(0.55, 40.0, 12.0, rng, jitter=0.5)
    hinge = ma.swept_bandpass(hinge, np.geomspace(760.0, 300.0, hinge.shape[0]),
                              octaves=1.0, block=1024)
    put(out, hinge * np.interp(np.linspace(0, 1, hinge.shape[0]), [0, 0.25, 1],
                               [0.4, 1.0, 0.35]), 0.09, 0.55)
    put(out, mm.body(105.0, 0.24, drop=0.42, curve=0.45, tau_ratio=0.3), 0.70, 0.8)
    put(out, mm.struck(rng.uniform(125.0, 170.0), "wood_dry", 0.42, rng,
                       geometry="bar_free", hardness=0.6, position=0.42,
                       modes=6, mounting=0.13), 0.702, 0.7)
    put(out, mm.granular(0.4, rng, count=8, fc_low=800.0, fc_high=4500.0), 0.75, 0.14)
    return out


def loot_rare(rng: np.random.Generator) -> np.ndarray:
    """The one that changed the run. The only overtly magical sound in the SFX
    set, and it is spent here on purpose: a swell that arrives BEFORE the event,
    a full D-Dorian crystal cascade, and a choir bloom underneath. If chests
    should sometimes drop something absurd, this is what absurd sounds like."""
    out = buf(2.6)
    n = ma.samples(0.6)
    rise = ma.swept_bandpass(ma.white(n, rng), np.geomspace(500.0, 6000.0, n),
                             octaves=1.2, block=512)
    put(out, rise * (np.linspace(0.0, 1.0, n) ** 2.2), 0.0, 0.4)
    put(out, ma.sine_glide(ma.note_hz("D2"), ma.note_hz("D4"), 0.6, curve=1.8)
        * (np.linspace(0.0, 1.0, n) ** 2.4), 0.0, 0.35)
    put(out, mm.body(150.0, 0.3, drop=0.35, curve=0.45), 0.6, 0.6)
    for i, note in enumerate(("D5", "F5", "A5", "C6", "D6", "A6")):
        put(out, mm.struck(ma.note_hz(note), "crystal", 1.6, rng, geometry="tube_open",
                           hardness=0.85, modes=5, mounting=0.006),
            0.62 + 0.078 * i, 0.42 - 0.045 * i)
    for note in ("D4", "A4", "D5"):
        put(out, mv.choir(ma.note_hz(note), 1.6, rng, vowel="ah", voices=3,
                          attack_s=0.2, release_s=1.0), 0.64, 0.15)
    put(out, mm.granular(1.1, rng, count=18, fc_low=5000.0, fc_high=14000.0,
                         grain_s=(0.001, 0.004), density_curve=1.4), 0.7, 0.14)
    return out


def haul_lift(rng: np.random.Generator) -> np.ndarray:
    """Shouldering something heavy. The strain is in the ORDER: the object
    breaks free of the ground first, then the body takes the weight, then the
    grunt — a grunt on the first frame reads as being hit."""
    out = buf(1.1)
    put(out, mm.friction(0.22, rng, material="mud", f_low=250.0, f_high=1400.0,
                         rate=90.0, roughness=0.9) * np.linspace(0.3, 1.0, ma.samples(0.22)),
        0.0, 0.5)
    put(out, mm.bubble_cloud(0.3, rng, count=10, r_min=0.0008, r_max=0.005), 0.10, 0.25)
    put(out, mm.cloth(0.35, rng, weight=0.8, rate=210.0), 0.20, 0.55)
    put(out, _throat(rng.uniform(115.0, 145.0), 0.32, rng, growl=0.4, vowel="mm", rasp=0.9)
        * ma.env_asr(ma.samples(0.32), 0.06, 0.2), 0.30, 0.55)
    return out


def haul_drop(rng: np.random.Generator) -> np.ndarray:
    """Putting it down. Real mass arriving on wet ground, and an exhale after."""
    out = buf(1.2)
    put(out, mm.body(64.0, 0.4, drop=0.32, curve=0.45, tau_ratio=0.28), 0.0, 1.0)
    put(out, mm.strike_noise(0.3, rng, "mud", hardness=0.35, brightness=0.85), 0.0, 0.55)
    put(out, mm.splash(0.4, rng, size=0.6), 0.005, 0.35)
    put(out, mm.cloth(0.3, rng, weight=0.7, rate=190.0), 0.06, 0.35)
    n = ma.samples(0.4)
    put(out, ma.swept_bandpass(ma.white(n, rng), np.geomspace(1300.0, 500.0, n),
                               octaves=1.6, block=512) * ma.env_asr(n, 0.06, 0.26),
        0.28, 0.22)
    return out


# ═══════════════════════════════════════════════════════════════════════════
# UI — the sounds a player hears more than any others
# ═══════════════════════════════════════════════════════════════════════════
#
# The whole UI set is built from ONE object: a small piece of dry wood tapped
# with a fingernail. Only the pitch, the contact hardness and the count change.
# That is a deliberate constraint — a UI whose sounds come from four different
# materials never feels like one instrument, and these fire thousands of times
# per session, so unfatiguing matters more here than interesting.

def _ui_tap(rng: np.random.Generator, f0: float, hardness: float = 0.7,
            dur_s: float = 0.09, mounting: float = 0.16) -> np.ndarray:
    out = buf(dur_s)
    put(out, mm.struck(f0, "wood_dry", dur_s * 0.85, rng, geometry="bar_free",
                       hardness=hardness, position=0.3, modes=4, mounting=mounting), 0.0, 1.0)
    put(out, mm.strike_noise(min(dur_s * 0.3, 0.03), rng, "wood_dry",
                             hardness=hardness, brightness=1.2), 0.0, 0.3)
    return out


def ui_hover(rng: np.random.Generator) -> np.ndarray:
    """Moving the selection. The quietest and softest of the family — a
    fingertip, not a nail."""
    return _ui_tap(rng, 980.0, hardness=0.35, dur_s=0.055, mounting=0.3) * 0.55


def ui_click(rng: np.random.Generator) -> np.ndarray:
    """Pressing something. The reference tap."""
    return _ui_tap(rng, 760.0, hardness=0.7, dur_s=0.09)


def ui_confirm(rng: np.random.Generator) -> np.ndarray:
    """Accepting. Two taps a fourth apart, rising — the interval carries the
    meaning, so it needs no extra brightness or volume."""
    out = buf(0.24)
    put(out, _ui_tap(rng, 700.0, hardness=0.7), 0.0, 0.9)
    put(out, _ui_tap(rng, 933.0, hardness=0.7, dur_s=0.12), 0.062, 0.8)
    return out


def ui_back(rng: np.random.Generator) -> np.ndarray:
    """Leaving a screen. The same two taps, falling."""
    out = buf(0.24)
    put(out, _ui_tap(rng, 820.0, hardness=0.6), 0.0, 0.85)
    put(out, _ui_tap(rng, 615.0, hardness=0.6, dur_s=0.12), 0.06, 0.75)
    return out


def ui_deny(rng: np.random.Generator) -> np.ndarray:
    """Refused. One tap with the ring damped almost out — a dead knock. No
    descending minor second, no buzzer: a UI that scolds gets muted."""
    out = buf(0.18)
    put(out, mm.struck(430.0, "clay", 0.12, rng, geometry="irregular",
                       hardness=0.4, modes=3, mounting=0.24), 0.0, 1.0)
    put(out, mm.strike_noise(0.03, rng, "clay", hardness=0.45, brightness=0.9), 0.0, 0.35)
    return out


def ui_tab(rng: np.random.Generator) -> np.ndarray:
    """Changing tab or page. A single higher tap with a touch more body, so it
    reads as a bigger move than a hover but a smaller one than a confirm."""
    out = buf(0.14)
    put(out, _ui_tap(rng, 1150.0, hardness=0.75, dur_s=0.1), 0.0, 0.85)
    put(out, mm.body(320.0, 0.04, drop=0.6, curve=0.5), 0.0, 0.2)
    return out


def ui_open(rng: np.random.Generator) -> np.ndarray:
    """A panel appearing. A soft cloth sweep under a tap — a page turning rather
    than a window opening."""
    out = buf(0.4)
    put(out, mm.cloth(0.2, rng, weight=0.25, rate=260.0), 0.0, 0.5)
    put(out, _ui_tap(rng, 660.0, hardness=0.55, dur_s=0.12), 0.045, 0.7)
    return out


def ui_close(rng: np.random.Generator) -> np.ndarray:
    """A panel dismissed. The same cloth, the tap first."""
    out = buf(0.36)
    put(out, _ui_tap(rng, 560.0, hardness=0.55, dur_s=0.11), 0.0, 0.7)
    put(out, mm.cloth(0.18, rng, weight=0.25, rate=240.0), 0.03, 0.45)
    return out


# ═══════════════════════════════════════════════════════════════════════════
# PROGRESSION & WORLD EVENTS
# ═══════════════════════════════════════════════════════════════════════════

def powerup_pickup(rng: np.random.Generator) -> np.ndarray:
    """Taking a boon. A rising crystal figure in D — related to `loot_rare` but
    a third of the length and none of the choir, so the two sit in the same
    world without competing."""
    out = buf(1.1)
    n = ma.samples(0.28)
    put(out, ma.swept_bandpass(ma.white(n, rng), np.geomspace(900.0, 5000.0, n),
                               octaves=1.2, block=512) * (np.linspace(0, 1, n) ** 2.0),
        0.0, 0.3)
    for i, note in enumerate(("D5", "A5", "D6")):
        put(out, mm.struck(ma.note_hz(note), "crystal", 0.9, rng, geometry="tube_open",
                           hardness=0.8, modes=4, mounting=0.010), 0.26 + 0.07 * i,
            0.55 - 0.10 * i)
    glow = (ma.sine(ma.note_hz("D4"), 0.6) + 0.6 * ma.sine(ma.note_hz("A4"), 0.6))
    put(out, glow * ma.env_asr(ma.samples(0.6), 0.15, 0.35), 0.24, 0.16)
    return out


def powerup_curse(rng: np.random.Generator) -> np.ndarray:
    """A boon with a price — `pact_cut`, `grave_due`, `hollow_bargain`. The same
    crystal figure, but FALLING and landing on the flat second, which is the
    night track's dread interval. Same instrument, opposite meaning: the player
    learns the difference in one run without ever being told."""
    out = buf(1.5)
    for i, note in enumerate(("D6", "A5", "Eb5")):
        put(out, mm.struck(ma.note_hz(note), "crystal", 1.2, rng, geometry="tube_closed",
                           hardness=0.6, modes=5, mounting=0.008), 0.0 + 0.11 * i,
            0.42 + 0.06 * i)
    put(out, ma.sine(ma.note_hz("Eb2"), 1.1) * ma.env_asr(ma.samples(1.1), 0.25, 0.7),
        0.18, 0.45)
    put(out, ma.fm_groan(58.0, 41.0, 1.0, rng), 0.2, 0.3)
    return out


def attune_select(rng: np.random.Generator) -> np.ndarray:
    """Binding an attunement. A held chord rather than a figure — this is a
    commitment for the whole run, and the only SFX that sustains long enough to
    feel like one."""
    out = buf(2.2)
    for i, note in enumerate(("D4", "A4", "D5", "F5")):
        put(out, mm.struck(ma.note_hz(note), "crystal", 1.9, rng, geometry="tube_open",
                           hardness=0.55, modes=5, mounting=0.004), 0.02 * i, 0.45 - 0.06 * i)
    put(out, mv.choir(ma.note_hz("D4"), 1.7, rng, vowel="oo", voices=3,
                      attack_s=0.5, release_s=0.9), 0.1, 0.2)
    put(out, ma.sine(ma.note_hz("D2"), 1.6) * ma.env_asr(ma.samples(1.6), 0.4, 0.9), 0.0, 0.35)
    return out


def unlock_purchase(rng: np.random.Generator) -> np.ndarray:
    """Spending salvage between runs. Metal counted out, then a lock turning —
    physical and mercantile, not magical, because this is a shop."""
    out = buf(1.4)
    for i in range(5):
        put(out, mm.struck(rng.uniform(1900.0, 3400.0), "bronze", 0.35, rng,
                           geometry="plate_free", hardness=0.9, modes=4, mounting=0.05),
            i * rng.uniform(0.05, 0.09), rng.uniform(0.25, 0.45))
    put(out, mm.struck(rng.uniform(900.0, 1200.0), "iron", 0.4, rng, geometry="bar_free",
                       hardness=0.95, modes=4, mounting=0.045), 0.55, 0.6)
    put(out, mm.friction(0.18, rng, material="iron", f_low=500.0, f_high=2200.0,
                         rate=95.0, roughness=0.4), 0.58, 0.3)
    put(out, mm.struck(ma.note_hz("D5"), "crystal", 0.8, rng, geometry="tube_open",
                       hardness=0.6, modes=4, mounting=0.012), 0.72, 0.28)
    return out


def salvage_bank(rng: np.random.Generator) -> np.ndarray:
    """Banking salvage on extraction. A heavy load poured into a container, then
    the lid — the sound of the run's value being made permanent."""
    out = buf(2.0)
    put(out, mm.granular(0.85, rng, count=70, fc_low=700.0, fc_high=7000.0,
                         grain_s=(0.002, 0.011), density_curve=1.1, decay=0.4), 0.0, 0.7)
    for _ in range(9):
        put(out, mm.struck(rng.uniform(1200.0, 3000.0), "bronze", 0.3, rng,
                           geometry="plate_free", hardness=0.85, modes=4, mounting=0.05),
            rng.uniform(0.02, 0.8), rng.uniform(0.12, 0.3))
    put(out, mm.body(95.0, 0.3, drop=0.4, curve=0.45), 0.85, 0.6)
    put(out, mm.struck(rng.uniform(130.0, 175.0), "wood_dry", 0.4, rng,
                       geometry="bar_free", hardness=0.6, modes=5, mounting=0.13), 0.852, 0.55)
    put(out, mm.struck(1700.0, "iron", 0.25, rng, geometry="bar_free",
                       hardness=0.97, modes=3, mounting=0.05), 0.94, 0.4)
    return out


def wellspring_capture(rng: np.random.Generator) -> np.ndarray:
    """A wellspring cleansed. The corruption leaving as a falling groan, then
    water running clear, then the spring's own note — D, rising, held. The one
    unambiguously good thing that happens in a run."""
    out = buf(3.2)
    put(out, ma.fm_groan(62.0, 34.0, 1.3, rng), 0.0, 0.5)
    put(out, mm.bubble_cloud(1.6, rng, count=90, r_min=0.0004, r_max=0.006,
                             density_curve=0.9), 0.5, 0.45)
    n = ma.samples(1.4)
    put(out, ma.swept_bandpass(ma.white(n, rng), np.geomspace(1200.0, 5000.0, n),
                               octaves=1.6, block=1024) * (np.linspace(0, 1, n) ** 1.6),
        0.55, 0.22)
    for i, note in enumerate(("D4", "A4", "D5", "F5", "A5")):
        put(out, mm.struck(ma.note_hz(note), "crystal", 2.0, rng, geometry="tube_open",
                           hardness=0.6, modes=5, mounting=0.004), 1.15 + 0.10 * i,
            0.40 - 0.05 * i)
    put(out, mv.choir(ma.note_hz("D5"), 1.8, rng, vowel="ah", voices=4,
                      attack_s=0.6, release_s=1.0), 1.2, 0.16)
    return out


def wellspring_corrupt(rng: np.random.Generator) -> np.ndarray:
    """A wellspring falling back. The exact reverse: the clean note bends down
    and goes out, the water thickens, and the groan arrives last and stays."""
    out = buf(3.2)
    for i, note in enumerate(("A5", "F5", "D5")):
        put(out, mm.struck(ma.note_hz(note), "crystal", 1.0, rng, geometry="tube_closed",
                           hardness=0.5, modes=4, mounting=0.02), 0.0 + 0.09 * i, 0.35)
    n = ma.samples(1.3)
    put(out, ma.swept_bandpass(ma.white(n, rng), np.geomspace(4200.0, 320.0, n),
                               octaves=1.7, block=1024) * np.interp(
        np.linspace(0, 1, n), [0, 0.2, 1], [0.2, 1.0, 0.25]), 0.25, 0.4)
    put(out, mm.bubble_cloud(1.5, rng, count=40, r_min=0.002, r_max=0.016,
                             density_curve=1.0), 0.6, 0.4)
    put(out, ma.fm_groan(44.0, 58.0, 1.8, rng), 1.0, 0.75)
    put(out, ma.sine(ma.note_hz("Eb1"), 1.8) * ma.env_asr(ma.samples(1.8), 0.5, 1.0), 1.1, 0.4)
    return out


def cycle_advance(rng: np.random.Generator) -> np.ndarray:
    """The world escalating. Short, because `ThemeMusicDirector` also fires a
    two-minute cue on this event — this is the impact that starts it, not the
    statement. A sub hit under a low bell struck a tritone from itself."""
    out = buf(2.4)
    put(out, ma.sine_glide(ma.note_hz("D2"), ma.note_hz("D1"), 0.9, curve=0.6)
        * ma.exp_decay(ma.samples(0.9), 0.3), 0.0, 1.0)
    put(out, mm.struck(ma.note_hz("D4"), "bronze", 2.0, rng, geometry="plate_free",
                       hardness=0.9, modes=6, mounting=0.006), 0.0, 0.55)
    put(out, mm.struck(ma.note_hz("Ab4"), "bronze", 1.6, rng, geometry="plate_free",
                       hardness=0.85, modes=5, mounting=0.008), 0.09, 0.3)
    put(out, mm.strike_noise(0.2, rng, "bronze", hardness=0.85, brightness=1.1), 0.0, 0.3)
    return out


def enemy_spawn(rng: np.random.Generator) -> np.ndarray:
    """Something coming up out of the mire. Wet ground parting, a body breaking
    the surface, and the first breath — the breath last, so the player has half
    a second of warning before they know what it is."""
    out = buf(1.8)
    put(out, mm.friction(0.45, rng, material="mud", f_low=180.0, f_high=1100.0,
                         rate=70.0, roughness=0.9) * np.linspace(0.25, 1.0, ma.samples(0.45)),
        0.0, 0.55)
    put(out, mm.bubble_cloud(0.9, rng, count=45, r_min=0.001, r_max=0.012,
                             density_curve=0.9), 0.15, 0.5)
    put(out, mm.splash(0.55, rng, size=0.7), 0.45, 0.6)
    put(out, mm.body(72.0, 0.3, drop=0.45, curve=0.5), 0.46, 0.45)
    put(out, _throat(rng.uniform(160.0, 215.0), 0.4, rng, growl=0.85, vowel="ah", rasp=0.9)
        * ma.env_asr(ma.samples(0.4), 0.03, 0.24), 0.75, 0.7)
    return out


def boss_roar(rng: np.random.Generator) -> np.ndarray:
    """The boss announcing itself. Three throats at once — the fundamental, a
    fifth below, and a tritone above — which is a stack no single animal could
    produce and is exactly why it reads as wrong. Long, loud, and it should
    arrive before the boss is visible."""
    out = buf(3.6)
    base = rng.uniform(72.0, 92.0)
    put(out, ma.sine(base * 0.5, 2.4) * ma.env_asr(ma.samples(2.4), 0.35, 1.4), 0.0, 0.55)
    for mult, at, gain, vowel in ((1.0, 0.15, 1.0, "ah"), (0.667, 0.19, 0.62, "oh"),
                                  (1.4142, 0.27, 0.34, "ah")):
        n = ma.samples(1.9)
        voice = _throat(base * mult, 1.9, rng, growl=1.0, vowel=vowel, rasp=0.7)
        contour = np.interp(np.linspace(0, 1, n), [0.0, 0.18, 0.62, 1.0],
                            [0.75, 1.18, 1.05, 0.68])
        voice = np.interp(np.cumsum(contour) * (n - 1) / np.sum(contour), np.arange(n), voice)
        put(out, voice * ma.env_asr(n, 0.10, 0.85), at, gain)
    put(out, mm.granular(1.4, rng, count=26, fc_low=600.0, fc_high=5000.0,
                         density_curve=1.2), 0.4, 0.16)
    return out


def extraction_arrive(rng: np.random.Generator) -> np.ndarray:
    """The ship coming in. Timber working under load, rope and rigging, and
    water parting at the bow — a hull, not an engine."""
    out = buf(3.4)
    n = ma.samples(2.6)
    put(out, ma.swept_bandpass(ma.white(n, rng), np.geomspace(280.0, 800.0, n),
                               octaves=2.0, block=1024)
        * np.interp(np.linspace(0, 1, n), [0, 0.55, 1], [0.15, 1.0, 0.55]), 0.0, 0.5)
    for _ in range(7):
        at = rng.uniform(0.2, 2.4)
        creak = ma.burst_train(rng.uniform(0.25, 0.5), 10.0, 26.0, rng, jitter=0.5)
        creak = ma.swept_bandpass(creak, np.geomspace(200.0, 620.0, creak.shape[0]),
                                  octaves=1.0, block=1024)
        put(out, creak * ma.env_asr(creak.shape[0], 0.05, 0.15), at, rng.uniform(0.2, 0.45))
    put(out, mm.bubble_cloud(2.2, rng, count=60, r_min=0.001, r_max=0.010,
                             density_curve=0.8), 0.3, 0.3)
    put(out, mm.struck(rng.uniform(92.0, 120.0), "wood_dry", 0.8, rng, geometry="bar_free",
                       hardness=0.5, modes=6, mounting=0.09), 2.5, 0.5)
    put(out, mm.body(78.0, 0.4, drop=0.4, curve=0.5), 2.5, 0.5)
    return out


def extraction_launch(rng: np.random.Generator) -> np.ndarray:
    """Getting out alive. Rope running out, canvas taking wind, hull surging —
    and no music cue, because this one has to land on its own."""
    out = buf(3.6)
    put(out, mm.friction(1.0, rng, material="leather", f_low=350.0, f_high=2400.0,
                         rate=180.0, roughness=0.6) * np.interp(
        np.linspace(0, 1, ma.samples(1.0)), [0, 0.3, 1], [0.3, 1.0, 0.2]), 0.0, 0.5)
    n = ma.samples(1.8)
    put(out, ma.swept_bandpass(ma.white(n, rng), np.geomspace(700.0, 260.0, n),
                               octaves=2.2, block=1024)
        * np.interp(np.linspace(0, 1, n), [0, 0.2, 1], [0.0, 1.0, 0.45]), 0.55, 0.6)
    put(out, mm.struck(rng.uniform(86.0, 112.0), "wood_dry", 1.2, rng, geometry="bar_free",
                       hardness=0.45, modes=6, mounting=0.07), 0.9, 0.45)
    put(out, mm.bubble_cloud(2.0, rng, count=80, r_min=0.0008, r_max=0.009,
                             density_curve=0.7), 1.0, 0.4)
    for i, note in enumerate(("D4", "A4", "D5")):
        put(out, mm.struck(ma.note_hz(note), "crystal", 1.8, rng, geometry="tube_open",
                           hardness=0.5, modes=4, mounting=0.006), 1.5 + 0.14 * i, 0.26)
    return out


def ward_activate(rng: np.random.Generator) -> np.ndarray:
    """A ward coming online. A low charge building into a snap, then a held ring
    that sits just above hearing — a player should be able to tell a ward is
    live by standing near it."""
    out = buf(2.2)
    n = ma.samples(0.55)
    put(out, ma.sine_glide(70.0, 220.0, 0.55, curve=1.8) * (np.linspace(0, 1, n) ** 2.0),
        0.0, 0.45)
    put(out, ma.swept_bandpass(ma.white(n, rng), np.geomspace(600.0, 3600.0, n),
                               octaves=1.3, block=512) * (np.linspace(0, 1, n) ** 2.4),
        0.0, 0.3)
    put(out, mm.strike_noise(0.05, rng, "crystal", hardness=0.98, brightness=1.8), 0.55, 0.55)
    for i, note in enumerate(("D5", "A5")):
        put(out, mm.struck(ma.note_hz(note), "crystal", 1.5, rng, geometry="tube_open",
                           hardness=0.9, modes=5, mounting=0.004), 0.55 + 0.03 * i, 0.5 - 0.15 * i)
    put(out, ma.sine(ma.note_hz("D3"), 1.4) * ma.env_asr(ma.samples(1.4), 0.15, 0.9), 0.56, 0.3)
    return out


def player_downed(rng: np.random.Generator) -> np.ndarray:
    """Going down but not out. The body hitting wet ground, a long unvoiced
    exhale, and a sub that hangs — deliberately similar in shape to
    `player_death` but a fifth higher and half the length, so a teammate can
    tell the two apart across a swamp."""
    out = buf(2.0)
    put(out, mm.body(70.0, 0.35, drop=0.4, curve=0.45, tau_ratio=0.3), 0.0, 0.9)
    put(out, mm.splash(0.45, rng, size=0.55), 0.005, 0.4)
    put(out, mm.cloth(0.35, rng, weight=0.8, rate=250.0), 0.02, 0.45)
    n = ma.samples(0.7)
    breath = ma.swept_bandpass(ma.white(n, rng), np.geomspace(1400.0, 420.0, n),
                               octaves=1.7, block=512)
    put(out, breath * ma.env_asr(n, 0.05, 0.45), 0.10, 0.5)
    put(out, ma.sine(52.0, 1.4) * ma.env_asr(ma.samples(1.4), 0.3, 0.9), 0.1, 0.35)
    return out


def player_revive(rng: np.random.Generator) -> np.ndarray:
    """A teammate getting you up. A sharp inhale — the only rising breath in the
    player set besides `player_breath_low` — cloth as the body comes off the
    ground, and one warm note in D."""
    out = buf(1.6)
    n = ma.samples(0.5)
    put(out, ma.swept_bandpass(ma.white(n, rng), np.geomspace(400.0, 2400.0, n),
                               octaves=1.8, block=512) * ma.env_asr(n, 0.10, 0.24), 0.0, 0.7)
    put(out, mm.cloth(0.4, rng, weight=0.7, rate=220.0), 0.18, 0.45)
    put(out, mm.granular(0.35, rng, count=12, fc_low=600.0, fc_high=4200.0), 0.22, 0.22)
    for i, note in enumerate(("A4", "D5")):
        put(out, mm.struck(ma.note_hz(note), "crystal", 1.1, rng, geometry="tube_open",
                           hardness=0.5, modes=4, mounting=0.008), 0.42 + 0.10 * i, 0.32)
    return out


def stamina_empty(rng: np.random.Generator) -> np.ndarray:
    """Out of breath. A hard unvoiced exhale with no pitch at all — information,
    not drama, because it fires every time a player sprints too long."""
    out = buf(0.7)
    n = ma.samples(0.42)
    air = ma.swept_bandpass(ma.white(n, rng), np.geomspace(1800.0, 550.0, n),
                            octaves=1.9, block=512)
    air *= 0.55 + 0.45 * np.abs(ma.slow_noise(n, 28.0, rng))
    put(out, air * ma.env_asr(n, 0.02, 0.28), 0.0, 0.85)
    put(out, _throat(rng.uniform(120.0, 150.0), 0.2, rng, growl=0.3, vowel="ah", rasp=1.0)
        * ma.env_asr(ma.samples(0.2), 0.02, 0.14), 0.01, 0.16)
    return out


def dodge_roll(rng: np.random.Generator) -> np.ndarray:
    """A dodge. Cloth and gear first as the body commits, then the ground
    contact, then the recovery step — three beats in under half a second, which
    is what makes it read as athletic rather than as falling over."""
    out = buf(0.85)
    put(out, mm.cloth(0.22, rng, weight=0.6, rate=280.0), 0.0, 0.7)
    put(out, mm.body(78.0, 0.16, drop=0.5, curve=0.5), 0.11, 0.6)
    put(out, mm.strike_noise(0.16, rng, "mud", hardness=0.35, brightness=0.9), 0.11, 0.45)
    put(out, mm.splash(0.25, rng, size=0.4), 0.12, 0.3)
    put(out, mm.cloth(0.18, rng, weight=0.5, rate=240.0), 0.24, 0.4)
    put(out, footstep_mud(rng), 0.42, 0.55)
    return out


def peer_joined(rng: np.random.Generator) -> np.ndarray:
    """Someone joined the run. Two rising notes in D, quiet — a notification,
    not an event in the world."""
    out = buf(0.9)
    for i, note in enumerate(("A4", "D5")):
        put(out, mm.struck(ma.note_hz(note), "crystal", 0.8, rng, geometry="tube_open",
                           hardness=0.55, modes=4, mounting=0.012), 0.0 + 0.085 * i, 0.5 - 0.1 * i)
    return out


def peer_left(rng: np.random.Generator) -> np.ndarray:
    """Someone dropped. The same two notes, falling."""
    out = buf(0.9)
    for i, note in enumerate(("D5", "A4")):
        put(out, mm.struck(ma.note_hz(note), "crystal", 0.8, rng, geometry="tube_closed",
                           hardness=0.5, modes=4, mounting=0.014), 0.0 + 0.085 * i, 0.45 - 0.08 * i)
    return out


# ═══════════════════════════════════════════════════════════════════════════
# AMBIENT SPOT EFFECTS — the world making noise on its own
# ═══════════════════════════════════════════════════════════════════════════
#
# One-shots the world scatters at random, NOT the looping beds (those are
# render_music.py's ambient tracks). These are what stop a forest sounding like
# a wind machine: a bird somewhere off to the left, a frog, gas breaking the
# surface of the bog. Every one is quiet and none of them is musical, so a
# hundred of them over a run never competes with anything the player did.

def _whistle(f_points, dur_s: float, rng: np.random.Generator,
             breath: float = 0.06, harm: float = 0.18) -> np.ndarray:
    """A bird's syrinx: essentially a pure tone with a fast pitch contour. The
    CONTOUR is the species — amplitude and timbre barely matter — so calls here
    are written as pitch breakpoints and nothing else."""
    n = ma.samples(dur_s)
    x = np.linspace(0.0, 1.0, n)
    freq = np.interp(x, np.linspace(0.0, 1.0, len(f_points)), f_points)
    ph = 2 * np.pi * np.cumsum(freq) / ma.SR
    sig = np.sin(ph) + harm * np.sin(2 * ph + rng.uniform(0, 6.28)) \
        + harm * 0.3 * np.sin(3 * ph + rng.uniform(0, 6.28))
    air = ma.fft_filter(ma.white(n, rng), fc_low=float(np.min(freq)) * 0.8,
                        fc_high=min(float(np.max(freq)) * 3.0, ma.SR * 0.45), order=2)
    peak = float(np.max(np.abs(sig)))
    return ma.fade_edges((sig / peak if peak > 0 else sig) + breath * air, 0.004)


def bird_call(rng: np.random.Generator) -> np.ndarray:
    """A small bird, two or three notes. Contours are drawn per render, so the
    variants are genuinely different calls rather than the same call retuned."""
    out = buf(1.4)
    base = rng.uniform(2100.0, 3400.0)
    t = 0.0
    for i in range(int(rng.uniform(2, 5))):
        dur = rng.uniform(0.055, 0.13)
        shape = rng.uniform()
        if shape < 0.4:      # rising sweep
            pts = [base * rng.uniform(0.7, 0.9), base * rng.uniform(1.1, 1.5)]
        elif shape < 0.7:    # falling
            pts = [base * rng.uniform(1.1, 1.4), base * rng.uniform(0.7, 0.95)]
        else:                # arched
            pts = [base * 0.85, base * rng.uniform(1.2, 1.45), base * 0.9]
        call = _whistle(pts, dur, rng, breath=rng.uniform(0.03, 0.09))
        put(out, call * ma.env_asr(ma.samples(dur), 0.008, 0.03), t, rng.uniform(0.6, 1.0))
        t += dur + rng.uniform(0.04, 0.14)
        base *= rng.uniform(0.96, 1.05)
    return out


def night_bird(rng: np.random.Generator) -> np.ndarray:
    """Something calling after dark. Low, hooting, two long notes — the same
    whistle an octave and a half down with a soft attack and heavy breath, which
    is what turns a songbird into an owl."""
    out = buf(2.4)
    base = rng.uniform(430.0, 620.0)
    for i, at in enumerate((0.0, rng.uniform(0.55, 0.85))):
        dur = rng.uniform(0.28, 0.42)
        pts = [base * 0.97, base * 1.02, base * 0.9]
        put(out, _whistle(pts, dur, rng, breath=0.22, harm=0.06)
            * ma.env_asr(ma.samples(dur), 0.06, 0.18), at, 0.9 - 0.2 * i)
        base *= rng.uniform(0.97, 1.0)
    return out


def insect_chirp(rng: np.random.Generator) -> np.ndarray:
    """Stridulation — a leg drawn over a file. A regular impulse train through a
    high resonance, in short bursts. Regularity is correct here and nowhere else
    in this file: an insect really is a machine."""
    out = buf(1.6)
    rate = rng.uniform(320.0, 620.0)
    fc = rng.uniform(3800.0, 6800.0)
    t = 0.0
    while t < 1.15:
        dur = rng.uniform(0.05, 0.11)
        put(out, mm.friction(dur, rng, material="chitin", f_low=fc * 0.8, f_high=fc * 1.6,
                             rate=rate, roughness=0.12)
            * ma.env_asr(ma.samples(dur), 0.006, 0.02), t, rng.uniform(0.55, 0.9))
        t += dur + rng.uniform(0.07, 0.2)
    return out


def frog_croak(rng: np.random.Generator) -> np.ndarray:
    """A bog frog. A vocal sac is a resonant cavity driven by a very low pulse
    rate, so a croak is a buzz rather than a tone — the individual glottal
    pulses are slow enough to hear separately, which is exactly what makes it
    sound like a frog and not a duck."""
    out = buf(1.6)
    for i in range(int(rng.uniform(1, 4))):
        at = i * rng.uniform(0.28, 0.45)
        dur = rng.uniform(0.13, 0.22)
        n = ma.samples(dur)
        pulse = np.zeros(n)
        rate = rng.uniform(38.0, 72.0)
        t = 0.0
        while t < dur:
            j = ma.samples(t)
            if j < n:
                pulse[j] = 1.0
            t += (1.0 / rate) * (1.0 + rng.uniform(-0.12, 0.12))
        sac = mv.formant_filter(pulse, [(rng.uniform(380.0, 560.0), 120.0, 0.0),
                                        (rng.uniform(1100.0, 1500.0), 220.0, -9.0)])
        peak = float(np.max(np.abs(sac)))
        put(out, (sac / peak if peak > 0 else sac) * ma.env_asr(n, 0.012, 0.06),
            at, rng.uniform(0.6, 1.0))
    return out


def marsh_gas(rng: np.random.Generator) -> np.ndarray:
    """Gas breaking the surface of standing water. Pure Minnaert: a handful of
    large slow bubbles, which is the lowest-pitched water sound in the game and
    the one that most says *swamp*."""
    out = buf(1.5)
    for _ in range(int(rng.uniform(3, 8))):
        put(out, mm.bubble(rng.uniform(0.004, 0.016), rng, rise=rng.uniform(1.2, 2.4),
                           damp=rng.uniform(0.8, 1.4)),
            rng.uniform(0.0, 1.0), rng.uniform(0.35, 1.0))
    put(out, mm.bubble_cloud(0.5, rng, count=8, r_min=0.0008, r_max=0.004), 0.4, 0.2)
    return out


def water_lap(rng: np.random.Generator) -> np.ndarray:
    """Water against a shore or a hull. A slow swell of broadband noise that
    rises and falls, with a few small bubbles as it retreats — no transient at
    all, which is what separates lapping from a splash."""
    out = buf(1.8)
    n = ma.samples(1.2)
    swell = ma.swept_bandpass(ma.white(n, rng), np.geomspace(420.0, 1700.0, n),
                              octaves=2.1, block=1024)
    put(out, swell * (np.sin(np.pi * np.linspace(0, 1, n)) ** 1.5), 0.0, 0.8)
    put(out, mm.bubble_cloud(0.7, rng, count=14, r_min=0.0006, r_max=0.004,
                             density_curve=0.8), 0.55, 0.3)
    return out


def wind_gust(rng: np.random.Generator) -> np.ndarray:
    """A gust arriving and passing. The band opens as it strengthens — a strong
    wind carries higher frequencies because it drives smaller eddies — so
    brightness and level move together, and a gust that only changes volume
    reads as a fader."""
    out = buf(3.5)
    n = ma.samples(3.0)
    env = np.interp(np.linspace(0, 1, n), [0.0, 0.35, 0.6, 1.0], [0.0, 1.0, 0.75, 0.0]) ** 1.3
    centers = 260.0 * (1.0 + 1.9 * env)
    gust = ma.swept_bandpass(ma.pink(n, rng), centers, octaves=1.9, block=2048)
    put(out, gust * env, 0.0, 1.0)
    put(out, mm.granular(2.4, rng, count=50, fc_low=2500.0, fc_high=11000.0,
                         grain_s=(0.0006, 0.0025), density_curve=1.0, decay=0.0)
        * np.interp(np.linspace(0, 1, ma.samples(2.4)), [0, 0.4, 1], [0.1, 1.0, 0.2]),
        0.3, 0.22)
    return out


def leaf_rustle(rng: np.random.Generator) -> np.ndarray:
    """Foliage disturbed — by the player brushing past, or by something the
    player cannot see. Fine dense grains with a soft swell; the cassette-tape
    texture again, because it is simply correct for vegetation."""
    out = buf(1.1)
    dur = rng.uniform(0.4, 0.75)
    n = ma.samples(dur)
    put(out, mm.granular(dur, rng, count=int(rng.uniform(70, 130)), fc_low=1800.0,
                         fc_high=12000.0, grain_s=(0.0006, 0.0028),
                         density_curve=1.0, decay=0.0)
        * (np.sin(np.pi * np.linspace(0, 1, n)) ** 1.4), 0.0, 0.9)
    put(out, mm.struck(rng.uniform(180.0, 300.0), "wood_green", 0.2, rng,
                       geometry="bar_free", hardness=0.3, modes=4, mounting=0.2),
        dur * 0.4, 0.12)
    return out


def branch_creak(rng: np.random.Generator) -> np.ndarray:
    """A tree working in the wind. Slow stick-slip in living wood — the sound
    that makes a forest feel like it is under load rather than painted on."""
    out = buf(2.2)
    dur = rng.uniform(0.7, 1.4)
    creak = ma.burst_train(dur, rng.uniform(7.0, 13.0), rng.uniform(16.0, 30.0),
                           rng, jitter=0.55)
    creak = ma.swept_bandpass(creak, np.geomspace(rng.uniform(150.0, 240.0),
                                                  rng.uniform(500.0, 800.0),
                                                  creak.shape[0]), octaves=0.9, block=1024)
    put(out, creak * ma.env_asr(creak.shape[0], 0.15, 0.4), 0.0, 0.9)
    put(out, mm.struck(rng.uniform(70.0, 110.0), "wood_green", 0.5, rng,
                       geometry="bar_free", hardness=0.25, modes=4, mounting=0.16),
        dur * 0.85, 0.2)
    return out


def distant_call(rng: np.random.Generator) -> np.ndarray:
    """Something large, a long way off. The throat again, but lowpassed and
    reverb-heavy so it reads as distance — air absorbs high frequencies over
    range, and nothing else is needed to place a sound at 200 metres."""
    out = buf(3.0)
    n = ma.samples(1.5)
    voice = _throat(rng.uniform(85.0, 120.0), 1.5, rng, growl=0.8, vowel="oh", rasp=0.3)
    contour = np.interp(np.linspace(0, 1, n), [0.0, 0.28, 0.7, 1.0], [0.8, 1.12, 1.05, 0.72])
    voice = np.interp(np.cumsum(contour) * (n - 1) / np.sum(contour), np.arange(n), voice)
    voice = ma.fft_filter(voice, fc_high=900.0, order=2)   # distance = no highs
    put(out, voice * ma.env_asr(n, 0.25, 0.8), 0.0, 1.0)
    return out


# ═══════════════════════════════════════════════════════════════════════════
# CREATURE MOVEMENT — the most useful sound in a co-op survival game
# ═══════════════════════════════════════════════════════════════════════════
#
# Hearing something approach before seeing it is what makes a swamp dangerous
# rather than merely dark. These are driven the same way the player's footsteps
# are (distance travelled, not a timer), so a creature that is closing on you
# sounds like it is closing on you.


def creature_step(rng: np.random.Generator) -> np.ndarray:
    """An arthropod moving. The giveaway is that it has more than two legs: a
    single step is three or four tiny chitin taps a few milliseconds apart, not
    one. That stutter is the entire difference between something insectile and
    something upright, and it costs one loop."""
    out = buf(0.30)
    t = 0.0
    for i in range(int(rng.uniform(3, 6))):
        f0 = rng.uniform(1500.0, 3200.0)
        put(out, mm.struck(f0, "chitin", 0.08, rng, geometry="tube_closed",
                           hardness=0.85, modes=3, mounting=0.09),
            t, rng.uniform(0.45, 1.0) * (1.0 - 0.12 * i))
        put(out, mm.strike_noise(0.02, rng, "chitin", hardness=0.9, brightness=1.4),
            t, 0.3)
        t += rng.uniform(0.012, 0.035)
    put(out, mm.body(rng.uniform(120.0, 165.0), 0.05, drop=0.6, curve=0.5), 0.004, 0.3)
    # dragged through wet ground between steps
    put(out, mm.granular(0.10, rng, count=5, fc_low=1400.0, fc_high=7000.0,
                         grain_s=(0.001, 0.004)), 0.02, 0.16)
    return out


def creature_step_heavy(rng: np.random.Generator) -> np.ndarray:
    """A tusker. One large soft pad, real mass behind it, and the suck of wet
    ground releasing — closer to the player's own bog step than to the skitter,
    an octave down and twice the weight."""
    out = buf(0.5)
    put(out, mm.body(rng.uniform(52.0, 64.0), 0.20, drop=0.42, curve=0.5,
                     tau_ratio=0.3), 0.0, 1.0)
    n = ma.samples(0.20)
    squelch = ma.swept_bandpass(ma.white(n, rng), np.geomspace(1600.0, 200.0, n),
                                octaves=1.5, block=512)
    squelch *= 0.4 + 0.6 * np.abs(ma.slow_noise(n, 26.0, rng))
    put(out, squelch * ma.env_asr(n, 0.006, 0.1), 0.004, 0.5)
    put(out, mm.bubble_cloud(0.24, rng, count=7, r_min=0.0008, r_max=0.005), 0.03, 0.24)
    return out


# ═══════════════════════════════════════════════════════════════════════════
# BIOME AMBIENCE — seven places that should not sound alike
# ═══════════════════════════════════════════════════════════════════════════


def reed_rustle(rng: np.random.Generator) -> np.ndarray:
    """Marsh reeds. Longer and drier than forest leaves, and *tonal* — a hollow
    stem is a stopped tube, so a stand of them hisses at a pitch. That faint
    pitch is what separates marsh from forest with the eyes closed."""
    out = buf(1.6)
    dur = rng.uniform(0.7, 1.2)
    n = ma.samples(dur)
    put(out, mm.granular(dur, rng, count=int(rng.uniform(80, 140)), fc_low=2600.0,
                         fc_high=13000.0, grain_s=(0.0005, 0.0022),
                         density_curve=1.0, decay=0.0)
        * (np.sin(np.pi * np.linspace(0, 1, n)) ** 1.2), 0.0, 0.85)
    for _ in range(3):
        put(out, mm.struck(rng.uniform(320.0, 620.0), "wood_dry", 0.4, rng,
                           geometry="tube_closed", hardness=0.2, modes=3, mounting=0.18),
            rng.uniform(0.1, dur), rng.uniform(0.06, 0.16))
    return out


def gull_call(rng: np.random.Generator) -> np.ndarray:
    """A shore bird. Harsh and descending, with a rasp no songbird has — the
    contour is a long fall with a break in the middle, which is the shape the
    ear reads as *coast*."""
    out = buf(1.8)
    base = rng.uniform(900.0, 1400.0)
    t = 0.0
    for i in range(int(rng.uniform(2, 4))):
        dur = rng.uniform(0.22, 0.4)
        pts = [base * 1.25, base * 1.32, base * 0.95, base * 0.72]
        call = _whistle(pts, dur, rng, breath=0.30, harm=0.42)
        n = ma.samples(dur)
        # the rasp: amplitude broken up at a rate slow enough to hear
        call *= 0.55 + 0.45 * np.sin(2 * np.pi * rng.uniform(38.0, 58.0)
                                     * ma.time_vector(n))
        put(out, call * ma.env_asr(n, 0.02, 0.14), t, 0.95 - 0.18 * i)
        t += dur + rng.uniform(0.12, 0.3)
        base *= rng.uniform(0.94, 1.0)
    return out


def crow_call(rng: np.random.Generator) -> np.ndarray:
    """Heath and highland. Not a whistle at all — a corvid uses a noisy pulsed
    source, so this is the creature throat rather than the bird syrinx, kept
    short and repeated two or three times."""
    out = buf(1.8)
    base = rng.uniform(340.0, 470.0)
    t = 0.0
    for i in range(int(rng.uniform(2, 4))):
        dur = rng.uniform(0.14, 0.24)
        n = ma.samples(dur)
        voice = _throat(base, dur, rng, growl=0.9, vowel="ah", rasp=0.85)
        fall = np.interp(np.linspace(0, 1, n), [0.0, 0.25, 1.0], [1.1, 1.0, 0.82])
        voice = np.interp(np.cumsum(fall) * (n - 1) / np.sum(fall), np.arange(n), voice)
        put(out, voice * ma.env_asr(n, 0.008, 0.09), t, 0.95 - 0.15 * i)
        t += dur + rng.uniform(0.16, 0.34)
    return out


def woodpecker(rng: np.random.Generator) -> np.ndarray:
    """Deep forest and birchwood. A drum roll on a dead trunk: a fast, EVEN
    train of hard wood taps that slows very slightly as it ends. Nothing else in
    a forest is periodic, which is why one bird makes a whole biome."""
    out = buf(1.6)
    f0 = rng.uniform(240.0, 400.0)
    rate = rng.uniform(17.0, 24.0)
    t = 0.0
    count = int(rng.uniform(8, 16))
    for i in range(count):
        put(out, mm.struck(f0 * rng.uniform(0.97, 1.03), "wood_dry", 0.12, rng,
                           geometry="bar_free", hardness=0.95, position=0.3,
                           modes=4, mounting=0.10), t,
            (1.0 - 0.5 * (i / float(count)) ** 2))
        put(out, mm.strike_noise(0.02, rng, "wood_dry", hardness=0.95, brightness=1.5),
            t, 0.3)
        t += (1.0 / rate) * (1.0 + 0.35 * (i / float(count)))
    return out


def dry_grass(rng: np.random.Generator) -> np.ndarray:
    """Grassland and heath in wind. Finer and higher than leaves, with no
    stems knocking — the sound of a lot of very small things all moving at
    once, which is why the grain count is triple everything else here."""
    out = buf(2.6)
    dur = rng.uniform(1.2, 2.0)
    n = ma.samples(dur)
    put(out, mm.granular(dur, rng, count=int(rng.uniform(220, 340)), fc_low=3200.0,
                         fc_high=15000.0, grain_s=(0.0004, 0.0016),
                         density_curve=1.0, decay=0.0)
        * np.interp(np.linspace(0, 1, n), [0, 0.3, 0.65, 1.0], [0.15, 1.0, 0.8, 0.1]),
        0.0, 0.9)
    return out


def stone_settle(rng: np.random.Generator) -> np.ndarray:
    """Highland. Scree shifting somewhere out of sight — a few loose granite
    pieces finding a new rest. Sparse and unhurried, and the only ambient cue in
    the set with a real transient, which is what makes high ground feel exposed."""
    out = buf(2.0)
    for _ in range(int(rng.uniform(3, 7))):
        at = rng.uniform(0.0, 1.2)
        put(out, mm.struck(rng.uniform(700.0, 2400.0), "granite", 0.2, rng,
                           geometry="irregular", hardness=0.8, modes=4, mounting=0.04),
            at, rng.uniform(0.3, 1.0))
        put(out, mm.granular(0.2, rng, count=5, fc_low=1500.0, fc_high=8000.0,
                             grain_s=(0.001, 0.005)), at + 0.01, rng.uniform(0.1, 0.3))
    return out


def wind_high(rng: np.random.Generator) -> np.ndarray:
    """Wind with nothing to break it. Thinner and higher than the lowland gust —
    no canopy, so no low rumble and no leaf noise, just a narrow band that rises
    and thins further as it strengthens."""
    out = buf(4.0)
    n = ma.samples(3.4)
    env = np.interp(np.linspace(0, 1, n), [0.0, 0.4, 0.62, 1.0], [0.0, 1.0, 0.8, 0.0]) ** 1.2
    centers = 620.0 * (1.0 + 2.4 * env)
    gust = ma.swept_bandpass(ma.pink(n, rng), centers, octaves=1.2, block=2048)
    put(out, gust * env, 0.0, 1.0)
    # a faint tone: wind across an edge sheds a vortex, and high ground has edges
    put(out, ma.sine_glide(rng.uniform(700.0, 1100.0), rng.uniform(1300.0, 1800.0), 3.4)
        * (env ** 2.5), 0.0, 0.08)
    return out


# ═══════════════════════════════════════════════════════════════════════════
# LANDMARKS
# ═══════════════════════════════════════════════════════════════════════════


def gate_open(rng: np.random.Generator) -> np.ndarray:
    """A gate, not a door. Twice the mass, a heavier bar to lift, and a much
    lower panel — so the player can tell which one a teammate just opened from
    across a camp."""
    out = buf(2.0)
    put(out, mm.struck(rng.uniform(900.0, 1200.0), "iron", 0.4, rng, geometry="bar_free",
                       hardness=0.95, modes=4, mounting=0.05), 0.0, 0.6)
    put(out, mm.body(120.0, 0.14, drop=0.45, curve=0.45), 0.002, 0.6)
    hinge = ma.burst_train(0.9, 30.0, 9.0, rng, jitter=0.5)
    hinge = ma.swept_bandpass(hinge, np.geomspace(560.0, 210.0, hinge.shape[0]),
                              octaves=1.0, block=1024)
    put(out, hinge * np.interp(np.linspace(0, 1, hinge.shape[0]), [0, 0.3, 1],
                               [0.5, 1.0, 0.35]), 0.12, 0.6)
    put(out, mm.struck(rng.uniform(72.0, 98.0), "wood_dry", 0.6, rng, geometry="bar_free",
                       hardness=0.4, modes=6, mounting=0.11), 1.05, 0.6)
    put(out, mm.body(66.0, 0.3, drop=0.4, curve=0.5), 1.05, 0.55)
    return out


def gate_close(rng: np.random.Generator) -> np.ndarray:
    """The same gate shutting: hinge, a heavy seat, then the bar dropping into
    its brackets — iron LAST, which is what makes it read as secured rather
    than as struck."""
    out = buf(1.8)
    hinge = ma.burst_train(0.5, 12.0, 34.0, rng, jitter=0.5)
    hinge = ma.swept_bandpass(hinge, np.geomspace(240.0, 640.0, hinge.shape[0]),
                              octaves=1.0, block=1024)
    put(out, hinge * np.linspace(0.35, 1.0, hinge.shape[0]), 0.0, 0.5)
    put(out, mm.body(62.0, 0.34, drop=0.36, curve=0.45, tau_ratio=0.3), 0.52, 1.0)
    put(out, mm.struck(rng.uniform(70.0, 95.0), "wood_dry", 0.6, rng, geometry="bar_free",
                       hardness=0.7, position=0.42, modes=6, mounting=0.12), 0.522, 0.8)
    put(out, mm.struck(rng.uniform(820.0, 1100.0), "iron", 0.5, rng, geometry="bar_free",
                       hardness=0.97, modes=4, mounting=0.04), 0.72, 0.55)
    put(out, mm.body(150.0, 0.1, drop=0.45, curve=0.4), 0.72, 0.4)
    return out


def wellspring_loop(rng: np.random.Generator) -> np.ndarray:
    """A cleansed wellspring, as a seamless loop for standing near one. Water
    running over stone under a held crystal fifth in D — the only sustained
    tonal sound in the world, so a player can navigate to it by ear. Rendered
    circularly like the furnace, so it never seams."""
    loop_s = 6.0
    n_loop = ma.samples(loop_s)
    total = loop_s + 2.0
    n = ma.samples(total)
    raw = np.zeros(n)
    # running water: dense small bubbles over a filtered rush
    raw += 0.55 * mm.bubble_cloud(total, rng, count=460, r_min=0.0004, r_max=0.0035,
                                  density_curve=1.0)
    rush = ma.fft_filter(ma.white(n, rng), fc_low=900.0, fc_high=6500.0, order=2)
    raw += 0.30 * rush * (0.6 + 0.4 * ma.slow_noise(n, 3.0, rng))
    for note, gain in (("D3", 0.16), ("A3", 0.10), ("D4", 0.06)):
        tone = ma.additive_pad(ma.note_hz(note), total, rng, detune_cents=3.0,
                               shimmer=0.3, darkness=0.25)
        raw += gain * tone * (1.0 + 0.25 * ma.slow_noise(n, 0.2, rng))
    out = raw[:n_loop].copy()
    out[: n - n_loop] += raw[n_loop:]      # circular fold
    return out


# ═══════════════════════════════════════════════════════════════════════════
# THE CATALOGUE
# ═══════════════════════════════════════════════════════════════════════════
#
# name -> (recipe, variants, reverb send, target loudness dBFS, system)
#
# **The level column is the game's mix, and it is LOUDNESS, not peak.** v1
# peak-normalised everything into a -2.5..-8 dBFS band, which is wrong twice
# over. It put a footstep within 6 dB of a falling tree, so the loudest thing a
# player did all day was walk. And peak normalisation makes a *sparse* sound —
# three cricket chirps across two seconds — measure as loud as a continuous one
# while being inaudible, because one sample reaching the ceiling says nothing
# about what the ear integrates.
#
# So the number here is the 90th percentile of the 50 ms short-term RMS
# envelope: roughly "how loud does this feel while it is happening", ignoring
# the silence around it. A true-peak ceiling is applied afterwards so nothing
# clips. Levels are set by how OFTEN a sound fires and how much it MATTERS:
#
#   -13 .. -16   once-per-event world sounds: a tree falling, a boss, a rare drop
#   -17 .. -21   the player's own actions: chopping, hitting, building, looting
#   -22 .. -27   things that fire every second or two: swings, steps, ambience
#   -28 .. -34   things that fire constantly or sit behind everything: UI, insects
#
# Anything the player triggers in a tight loop lives in the bottom two bands.
# That is the single biggest audible difference between this pass and v1.

CATALOGUE: dict[str, tuple] = {
    # ── harvesting ──────────────────────────────────────────────────────────
    "axe_hit_wood":           (axe_hit_wood, 3, 0.10, -18, "harvest"),
    "axe_hit_wood_dead":      (axe_hit_wood_dead, 3, 0.10, -18.5, "harvest"),
    "pick_hit_stone":         (pick_hit_stone, 3, 0.11, -18, "harvest"),
    "pick_hit_ore":           (pick_hit_ore, 3, 0.11, -18, "harvest"),
    "pick_hit_crystal":       (pick_hit_crystal, 2, 0.14, -19, "harvest"),
    "harvest_plant":          (harvest_plant, 3, 0.06, -22, "harvest"),
    "tree_fall":              (tree_fall, 1, 0.18, -13, "harvest"),
    "sapling_break":          (sapling_break, 1, 0.12, -18, "harvest"),
    "stone_break":            (stone_break, 1, 0.15, -15, "harvest"),
    "ore_break":              (ore_break, 1, 0.15, -15, "harvest"),
    "log_break":              (log_break, 1, 0.13, -16, "harvest"),

    # ── movement ────────────────────────────────────────────────────────────
    "footstep_mud":           (footstep_mud, 4, 0.05, -27, "movement"),
    "footstep_water":         (footstep_water, 4, 0.06, -26.5, "movement"),
    "footstep_grass":         (footstep_grass, 4, 0.04, -27.5, "movement"),
    "footstep_stone":         (footstep_stone, 4, 0.07, -26.5, "movement"),
    "footstep_wood":          (footstep_wood, 4, 0.06, -26.5, "movement"),
    "jump":                   (jump, 2, 0.04, -26, "movement"),
    "land_hard":              (land_hard, 2, 0.08, -19, "movement"),
    "dodge_roll":             (dodge_roll, 2, 0.06, -23, "movement"),
    "water_enter":            (water_enter, 1, 0.10, -17, "movement"),
    "swim_stroke":            (swim_stroke, 3, 0.07, -25, "movement"),

    # ── melee ───────────────────────────────────────────────────────────────
    "swing_light":            (swing_light, 3, 0.03, -26, "melee"),
    "swing_blade":            (swing_blade, 3, 0.03, -25, "melee"),
    "swing_heavy":            (swing_heavy, 3, 0.04, -24, "melee"),
    "hit_flesh":              (hit_flesh, 3, 0.07, -18, "melee"),
    "hit_bone":               (hit_bone, 3, 0.08, -17.5, "melee"),
    "hit_carapace":           (hit_carapace, 3, 0.09, -18, "melee"),
    "hit_wood":               (hit_wood, 2, 0.09, -19, "melee"),
    "hit_stone":              (hit_stone, 2, 0.10, -19, "melee"),
    "hit_metal":              (hit_metal, 2, 0.10, -18, "melee"),
    "hit_crit":               (hit_crit, 1, 0.10, -15, "melee"),

    # ── ranged ──────────────────────────────────────────────────────────────
    "bow_draw":               (bow_draw, 2, 0.04, -25, "ranged"),
    "bow_release":            (bow_release, 2, 0.06, -20, "ranged"),
    "crossbow_load":          (crossbow_load, 1, 0.05, -24, "ranged"),
    "crossbow_release":       (crossbow_release, 2, 0.06, -19, "ranged"),
    "sling_whirl":            (sling_whirl, 1, 0.05, -24, "ranged"),
    "arrow_whizz":            (arrow_whizz, 3, 0.04, -24, "ranged"),
    "arrow_hit_flesh":        (arrow_hit_flesh, 2, 0.07, -19, "ranged"),
    "arrow_hit_wood":         (arrow_hit_wood, 2, 0.09, -19, "ranged"),
    "arrow_hit_stone":        (arrow_hit_stone, 2, 0.10, -19, "ranged"),

    # ── creatures ───────────────────────────────────────────────────────────
    "creature_chitter":       (creature_chitter, 3, 0.08, -26, "creature"),
    "creature_alert":         (creature_alert, 2, 0.09, -18, "creature"),
    "creature_attack":        (creature_attack, 3, 0.08, -18, "creature"),
    "creature_hurt":          (creature_hurt, 3, 0.08, -18, "creature"),
    "creature_death":         (creature_death, 2, 0.10, -17, "creature"),
    "tusker_snort":           (tusker_snort, 2, 0.11, -17, "creature"),
    "broodcaller_call":       (broodcaller_call, 1, 0.16, -15, "creature"),
    "enemy_spawn":            (enemy_spawn, 2, 0.12, -18, "creature"),
    "boss_roar":              (boss_roar, 1, 0.18, -13, "creature"),
    "creature_step":          (creature_step, 4, 0.06, -26, "creature"),
    "creature_step_heavy":    (creature_step_heavy, 3, 0.07, -22, "creature"),

    # ── the player ──────────────────────────────────────────────────────────
    "player_hurt":            (player_hurt, 3, 0.05, -19, "player"),
    "player_death":           (player_death, 1, 0.10, -15, "player"),
    "player_downed":          (player_downed, 1, 0.09, -17, "player"),
    "player_revive":          (player_revive, 1, 0.07, -19, "player"),
    "player_breath_low":      (player_breath_low, 2, 0.04, -23, "player"),
    "player_heal":            (player_heal, 1, 0.09, -20, "player"),
    "player_eat":             (player_eat, 2, 0.03, -24, "player"),
    "player_drink":           (player_drink, 2, 0.03, -24, "player"),
    "stamina_empty":          (stamina_empty, 2, 0.03, -24, "player"),

    # ── building ────────────────────────────────────────────────────────────
    "build_place_wood":       (build_place_wood, 3, 0.09, -19, "building"),
    "build_place_stone":      (build_place_stone, 3, 0.10, -19, "building"),
    "build_remove":           (build_remove, 2, 0.08, -21, "building"),
    "build_denied":           (build_denied, 1, 0.03, -26, "building"),
    "door_open":              (door_open, 2, 0.09, -21, "building"),
    "door_close":             (door_close, 2, 0.09, -20, "building"),
    "gate_open":              (gate_open, 2, 0.1, -20, "building"),
    "gate_close":             (gate_close, 2, 0.1, -19, "building"),
    "structure_hit":          (structure_hit, 3, 0.11, -17, "building"),
    "structure_destroy":      (structure_destroy, 1, 0.14, -15, "building"),

    # ── crafting ────────────────────────────────────────────────────────────
    "craft_work":             (craft_work, 3, 0.07, -22, "crafting"),
    "craft_complete":         (craft_complete, 1, 0.08, -20, "crafting"),
    "craft_denied":           (craft_denied, 1, 0.03, -26, "crafting"),
    "furnace_light":          (furnace_light, 1, 0.09, -18, "crafting"),
    "furnace_loop":           (furnace_loop, 1, 0.0, -30, "crafting"),
    "repair_hit":             (repair_hit, 3, 0.09, -20, "crafting"),

    # ── items and loot ──────────────────────────────────────────────────────
    "item_pickup":            (item_pickup, 3, 0.05, -23, "items"),
    "item_drop":              (item_drop, 2, 0.06, -23, "items"),
    "inventory_move":         (inventory_move, 3, 0.0, -30, "items"),
    "equip_blade":            (equip_blade, 2, 0.06, -21, "items"),
    "equip_tool":             (equip_tool, 2, 0.05, -22, "items"),
    "equip_bow":              (equip_bow, 2, 0.05, -22, "items"),
    "chest_open":             (chest_open, 1, 0.12, -18, "items"),
    "loot_rare":              (loot_rare, 1, 0.16, -15, "items"),
    "haul_lift":              (haul_lift, 2, 0.06, -21, "items"),
    "haul_drop":              (haul_drop, 2, 0.09, -18, "items"),

    # ── ui ──────────────────────────────────────────────────────────────────
    "ui_hover":               (ui_hover, 2, 0.0, -34, "ui"),
    "ui_click":               (ui_click, 1, 0.0, -30, "ui"),
    "ui_confirm":             (ui_confirm, 1, 0.0, -29, "ui"),
    "ui_back":                (ui_back, 1, 0.0, -30, "ui"),
    "ui_deny":                (ui_deny, 1, 0.0, -30, "ui"),
    "ui_tab":                 (ui_tab, 1, 0.0, -30, "ui"),
    "ui_open":                (ui_open, 1, 0.0, -29, "ui"),
    "ui_close":               (ui_close, 1, 0.0, -30, "ui"),

    # ── progression and world events ────────────────────────────────────────
    "powerup_pickup":         (powerup_pickup, 1, 0.10, -18, "progression"),
    "powerup_curse":          (powerup_curse, 1, 0.12, -18, "progression"),
    "attune_select":          (attune_select, 1, 0.13, -18, "progression"),
    "unlock_purchase":        (unlock_purchase, 1, 0.08, -19, "progression"),
    "salvage_bank":           (salvage_bank, 1, 0.09, -18, "progression"),
    "wellspring_capture":     (wellspring_capture, 1, 0.16, -16, "progression"),
    "wellspring_corrupt":     (wellspring_corrupt, 1, 0.16, -16, "progression"),
    "cycle_advance":          (cycle_advance, 1, 0.14, -15, "progression"),
    "extraction_arrive":      (extraction_arrive, 1, 0.14, -18, "progression"),
    "extraction_launch":      (extraction_launch, 1, 0.14, -17, "progression"),
    "ward_activate":          (ward_activate, 1, 0.12, -18, "progression"),
    "peer_joined":            (peer_joined, 1, 0.06, -24, "progression"),
    "peer_left":              (peer_left, 1, 0.06, -24, "progression"),

    # ── ambient spot effects ────────────────────────────────────────────────
    "bird_call":              (bird_call, 4, 0.13, -26, "ambient"),
    "night_bird":             (night_bird, 3, 0.16, -26, "ambient"),
    "insect_chirp":           (insect_chirp, 3, 0.06, -30, "ambient"),
    "frog_croak":             (frog_croak, 3, 0.10, -27, "ambient"),
    "marsh_gas":              (marsh_gas, 3, 0.08, -28, "ambient"),
    "water_lap":              (water_lap, 3, 0.07, -30, "ambient"),
    "wind_gust":              (wind_gust, 3, 0.05, -28, "ambient"),
    "leaf_rustle":            (leaf_rustle, 3, 0.06, -27, "ambient"),
    "branch_creak":           (branch_creak, 3, 0.12, -28, "ambient"),
    "distant_call":           (distant_call, 2, 0.20, -24, "ambient"),
    "reed_rustle":            (reed_rustle, 3, 0.06, -27, "ambient"),
    "gull_call":              (gull_call, 3, 0.14, -25, "ambient"),
    "crow_call":              (crow_call, 3, 0.15, -25, "ambient"),
    "woodpecker":             (woodpecker, 3, 0.14, -26, "ambient"),
    "dry_grass":              (dry_grass, 3, 0.05, -29, "ambient"),
    "stone_settle":           (stone_settle, 3, 0.13, -27, "ambient"),
    "wind_high":              (wind_high, 3, 0.06, -28, "ambient"),
    "wellspring_loop":        (wellspring_loop, 1, 0.0, -28, "progression"),
}

SYSTEMS = ("harvest", "movement", "melee", "ranged", "creature", "player",
           "building", "crafting", "items", "ui", "progression", "ambient")

SEED_BASE = 940000


def seed_for(name: str, variant: int) -> int:
    """Deterministic per-sound seed, derived from the NAME rather than from the
    sound's position in the catalogue.

    Position-derived seeds look fine until the catalogue grows: inserting one
    entry in the middle shifts every index after it, so every later sound
    re-renders as a different (equally valid, but different) variant and 200
    files churn in git for a one-line addition. `zlib.crc32` is used rather than
    `hash()` because Python salts string hashing per process — the F-176 trap,
    in a different disguise."""
    return SEED_BASE + (zlib.crc32(name.encode("utf-8")) & 0x7FFFFFF) + variant

## Sounds that must loop seamlessly are rendered circularly by their own recipe
## and must NOT get a reverb tail bolted onto the end, which would break the loop.
LOOPING = frozenset({"furnace_loop", "wellspring_loop"})


## True-peak ceiling. Every sound is normalised by loudness first; this only
## bites on sounds with a very high crest factor (a hard transient over near
## silence), which is exactly where clipping would otherwise appear.
PEAK_CEILING_DB: float = -1.2


def loudness(sig: np.ndarray, window_s: float = 0.1) -> float:
    """Peak short-term loudness: the loudest 100 ms of the sound, measured as
    RMS. "How loud is this at the moment it is loudest."

    Full-file RMS is wrong here — it would rate three cricket chirps across two
    seconds as near-silent and normalise them into a roar. A peak measurement is
    also wrong — it rates one sample as the whole sound, so the same chirps
    measure as loud as a gunshot and end up inaudible.

    A percentile of the short-term envelope was the first attempt and it fails
    on exactly the material this catalogue is full of: when a sound is one short
    transient inside a long file, most frames are tail, and the 90th percentile
    lands in the tail rather than in the hit. `build_place_wood`'s third variant
    came out 12 dB under its siblings for that reason alone. Taking the MAXIMUM
    of the envelope has no such dependence on how much silence surrounds the
    event, which is the property this needs: one number in the catalogue has to
    mean the same thing for a 90 ms UI tick and for a four-second falling tree."""
    n = sig.shape[0]
    w = min(ma.samples(window_s), n)
    if w < 2:
        return max(float(np.sqrt(np.mean(sig ** 2))), 1e-9)
    power = np.concatenate([[0.0], np.cumsum(sig ** 2)])
    frames = np.sqrt(np.maximum((power[w:] - power[:-w]) / w, 0.0))
    return max(float(np.max(frames)), 1e-9)


def trim_tail(sig: np.ndarray, floor_db: float = -72.0,
              keep_s: float = 0.06) -> np.ndarray:
    """Cut trailing near-silence. Recipes allocate a generous buffer and then a
    reverb tail is convolved on, so most files end with a stretch of nothing;
    across 227 assets that is real disk, real import time and real memory for
    no sound at all."""
    thr = float(np.max(np.abs(sig))) * ma.db(floor_db)
    loud = np.where(np.abs(sig) > thr)[0]
    if loud.size == 0:
        return sig
    end = min(int(loud[-1]) + ma.samples(keep_s), sig.shape[0])
    return sig[:end].copy()


def soft_limit(sig: np.ndarray, thresh_db: float = -7.0) -> np.ndarray:
    """Round off isolated transient spikes without touching the body of the
    sound. Everything below the threshold passes untouched; above it the curve
    is `t + (1-t)*tanh((|x|-t)/(1-t))`, which is continuous and has slope 1 at
    the knee, so there is no audible corner.

    This exists because a few recipes — anything built on `burst_train`, where a
    creak is literally a train of single-sample impulses — have a crest factor
    above 25 dB. Without limiting, the true-peak ceiling has to pull the whole
    file down by that much to fit one spike, and a branch creak authored at
    -28 dBFS lands at -40 and cannot be heard. Limiting first costs nothing
    audible and recovers the entire 12 dB."""
    t = ma.db(thresh_db)
    mag = np.abs(sig)
    over = mag > t
    if not np.any(over):
        return sig
    out = sig.copy()
    excess = (mag[over] - t) / (1.0 - t)
    out[over] = np.sign(sig[over]) * (t + (1.0 - t) * np.tanh(excess))
    return out


def render_one(name: str, rng: np.random.Generator, ir: np.ndarray) -> np.ndarray:
    fn, _variants, wet, level_db, _system = CATALOGUE[name]
    looping = name in LOOPING
    sig = fn(rng)
    if wet > 0 and not looping:
        verb = ma.convolve_fft(sig, ir)
        mixed = np.zeros(sig.shape[0] + ir.shape[0])
        mixed[: sig.shape[0]] = sig
        mixed[: verb.shape[0]] += wet * verb[: mixed.shape[0]]
        sig = mixed
    sig = sig - np.mean(sig)
    if not looping:
        sig = trim_tail(sig)
    # Normalise, tame the spikes, then re-normalise: limiting removes peak but
    # barely touches loudness, so one correction pass after it converges.
    sig = sig * (ma.db(level_db) / loudness(sig))
    sig = soft_limit(sig)
    sig = sig * (ma.db(level_db) / loudness(sig))
    peak = float(np.max(np.abs(sig)))
    ceiling = ma.db(PEAK_CEILING_DB)
    if peak > ceiling:
        sig = sig * (ceiling / peak)
    return sig if looping else ma.fade_edges(sig, 0.003)


def expected_files() -> set:
    """Every filename this catalogue claims."""
    out = set()
    for name, (_fn, variants, _wet, _level, _system) in CATALOGUE.items():
        if variants <= 1:
            out.add(f"{name}.wav")
        else:
            out.update(f"{name}_{v + 1:02d}.wav" for v in range(variants))
    return out


def prune_orphans(sfx_dir: str) -> list:
    """Delete anything in the asset dir the catalogue does not claim.

    Two things land here. Renames and removals leave the old file behind, which
    Godot keeps importing and shipping. And F-427: this machine's cloud sync
    resurrects deleted files as `<name> 2.wav` conflict copies, so a
    delete-then-rewrite of the directory reliably doubles it — 520 files for a
    260-file render, caught only because `tools/sfx_check.gd` compares the
    directory against the catalogue in both directions.

    Doing it here rather than by hand means the render is the fix: the invariant
    "this directory is exactly what the catalogue says" is restored on every run
    instead of depending on someone noticing."""
    keep = expected_files()
    removed = []
    for name in sorted(os.listdir(sfx_dir)):
        if not name.endswith(".wav") or name in keep:
            continue
        os.remove(os.path.join(sfx_dir, name))
        removed.append(name)
        sidecar = os.path.join(sfx_dir, name + ".import")
        if os.path.exists(sidecar):
            os.remove(sidecar)
    return removed


def write_catalogue_gd(path: str) -> None:
    """Emit the cue table `SfxDirector` reads, generated from this file.

    Generated rather than hand-maintained because the two halves would
    otherwise drift the moment a variant count changes here: the game would ask
    for `footstep_mud_04.wav`, get null, and play silence with no error — the
    same class of failure as F-373, one asset at a time and much harder to
    notice. `tools/sfx_check.gd` asserts every entry actually loads, so a stale
    table fails a check instead of quietly muting a sound.

    Directory scanning was rejected as the alternative: `DirAccess` over
    `res://` is not dependable in an exported build, and the failure would only
    appear after shipping."""
    lines = [
        "## GENERATED by tools/audio/render_sfx.py — do not edit by hand.",
        "##",
        "## The cue table `SfxDirector` plays from: cue name -> [variant count, system].",
        "## Regenerate with `python3 tools/audio/render_sfx.py`; `tools/sfx_check.gd`",
        "## asserts every file this names actually loads in-engine.",
        "",
        "const CUES: Dictionary[StringName, Array] = {",
    ]
    for name, (_fn, variants, _wet, _level, system) in CATALOGUE.items():
        lines.append(f'	&"{name}": [{variants}, &"{system}"],')
    lines.append("}")
    lines.append("")
    lines.append("const SYSTEMS: Array[StringName] = [")
    lines.append("	" + ", ".join(f'&"{s}"' for s in SYSTEMS) + ",")
    lines.append("]")
    lines.append("")
    with open(path, "w") as f:
        f.write("\n".join(lines))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sfx-dir", default=os.path.join(REPO, "assets", "audio", "sfx"))
    parser.add_argument("--build-dir",
                        default=os.path.join(tempfile.gettempdir(), "mire_audio_build", "sfx"))
    parser.add_argument("--only", nargs="*", default=None,
                        help="render just these names, or a whole system name")
    parser.add_argument("--list", action="store_true", help="print the catalogue and exit")
    parser.add_argument("--catalogue-gd",
                        default=os.path.join(REPO, "autoload", "sfx_catalogue.gd"),
                        help="where to write the generated GDScript cue table")
    args = parser.parse_args()

    if args.list:
        for system in SYSTEMS:
            names = [n for n, v in CATALOGUE.items() if v[4] == system]
            total = sum(CATALOGUE[n][1] for n in names)
            print(f"\n{system}  ({len(names)} sounds, {total} files)")
            for n in names:
                fn, variants, wet, level_db, _ = CATALOGUE[n]
                head = (fn.__doc__ or "").strip().split("\n")[0]
                print(f"  {n:<22} x{variants}  {level_db:6.1f} LUFS-ish  {head[:66]}")
        print(f"\ntotal: {len(CATALOGUE)} sounds, "
              f"{sum(v[1] for v in CATALOGUE.values())} files")
        return

    os.makedirs(args.sfx_dir, exist_ok=True)
    os.makedirs(args.build_dir, exist_ok=True)

    # One short outdoor IR shared by every effect, so they all sit in one place.
    ir_rng = np.random.default_rng(5)
    ir = ma.make_ir(0.6, ir_rng, tau_s=0.11, predelay_s=0.013, hf_ratio=0.5, stereo=False)[0]
    dither = np.random.default_rng(41)

    wanted = list(CATALOGUE)
    if args.only:
        wanted = []
        for token in args.only:
            if token in SYSTEMS:
                wanted += [n for n, v in CATALOGUE.items() if v[4] == token]
            elif token in CATALOGUE:
                wanted.append(token)
            else:
                raise SystemExit(f"unknown name or system {token!r}")

    reels: dict[str, list[np.ndarray]] = {s: [] for s in SYSTEMS}
    written = 0
    for idx, name in enumerate(wanted):
        fn, variants, wet, level_db, system = CATALOGUE[name]
        for v in range(variants):
            rng = np.random.default_rng(seed_for(name, v))
            sig = render_one(name, rng, ir)
            fname = f"{name}_{v + 1:02d}.wav" if variants > 1 else f"{name}.wav"
            ma.write_wav(os.path.join(args.sfx_dir, fname), sig, dither)
            written += 1
            reels[system].append(sig)
            reels[system].append(np.zeros(ma.samples(0.45)))
        print(f"  {name:<22} x{variants}  target {level_db:6.1f}  "
              f"got {20 * np.log10(loudness(sig)):6.1f}  "
              f"peak {20 * np.log10(max(np.max(np.abs(sig)), 1e-9)):5.1f}  "
              f"{sig.shape[0] / ma.SR:5.2f}s")

    for system, chunks in reels.items():
        if not chunks:
            continue
        reel = np.concatenate(chunks)
        wav = os.path.join(args.build_dir, f"reel_{system}.wav")
        ma.write_wav(wav, reel, dither)
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", wav,
                        "-c:a", "libmp3lame", "-q:a", "3",
                        os.path.join(args.build_dir, f"reel_{system}.mp3")], check=True)
        os.remove(wav)

    if not args.only:
        write_catalogue_gd(args.catalogue_gd)
        print(f"cue table -> {args.catalogue_gd}")
        removed = prune_orphans(args.sfx_dir)
        if removed:
            print(f"pruned {len(removed)} orphan file(s): {', '.join(removed[:6])}"
                  + (" …" if len(removed) > 6 else ""))

    print(f"\n{written} files -> {args.sfx_dir}")
    print(f"audition reels -> {args.build_dir}")


## Only the asset dir is under Godot's import cache, and this script always
## writes there — so unlike the theme renderer it always takes the F-196 lock.
if __name__ == "__main__":
    with import_cache_guard(os.path.basename(__file__)):
        main()
