#!/usr/bin/env python3
"""Render three competing design takes for every MIRE sound effect.

    python3 tools/audio/render_sfx_options.py [--only FAMILY] [--build-dir DIR]
    python3 tools/audio/render_sfx_options.py --ship axe_hit_wood=B melee_hit=C ...

This is the pick-one step of the audio overhaul. `render_sfx.py` holds the v1
recipes — one take per sound. Here every family gets **A / B / C**: not three
seeds of one recipe (that is what the per-sound *variants* already are), but
three different answers to "what is this thing made of and how hard did you hit
it". Each take still ships its full variant count, so a chosen take drops
straight into `assets/audio/sfx/` with the round-robin play sites unchanged.

Auditioning: each family gets `<family>_options.mp3` in the build dir, laid out
A, B, C with all variants of a take played together. Takes are announced by
**pips** — one high pip before A, two before B, three before C — because
without them a listener two minutes into a reel has no way to know which take
they are hearing, and that is exactly when the decision gets made.

`--ship family=TAKE ...` writes the winners into `assets/audio/sfx/` under the
canonical names (`axe_hit_wood_01.wav`, …) and prints the take table to paste
into AUDIO.md. Nothing is written to the asset dir until then.

What changed against v1, technically: these takes are built on `modal_bank`
(a bank of decaying partials — the physical model behind any struck object)
and `grain_scatter` from `mire_voices`. v1 approximated struck material with
fixed sine triples and pink-noise beds, which is why several of its impacts
read as "click plus noise" rather than as wood, stone, or bone.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mire_audio as ma  # noqa: E402
import mire_voices as mv  # noqa: E402

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "blender"))
from godot_import_lock import import_cache_guard  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def silence(dur_s: float) -> np.ndarray:
    return np.zeros(ma.samples(dur_s))


def place(buf: np.ndarray, sig: np.ndarray, at_s: float, gain: float = 1.0) -> None:
    start = ma.samples(at_s)
    end = min(start + sig.shape[0], buf.shape[0])
    if start < end:
        buf[start:end] += sig[: end - start] * gain


# ---------------------------------------------------------------------------
# axe on wood — a chop is: bite (transient), body (low modes), splinter (noise)
# ---------------------------------------------------------------------------

def axe_dry(rng):
    """A — dry split. Close, tight, seasoned timber: hard bite, short modes,
    almost no tail. Reads as *precise*; best if chopping is fast and frequent."""
    buf = silence(0.34)
    f = rng.uniform(96.0, 116.0)
    place(buf, mv.transient(rng, 0.0025, fc_low=1800.0), 0.0, 0.9)
    place(buf, mv.modal_bank([(f, 0.075, 1.0), (f * 2.71, 0.045, 0.42),
                              (f * 4.9, 0.026, 0.20), (f * 7.6, 0.014, 0.10)],
                             0.30, rng, jitter_cents=25.0), 0.001, 0.85)
    place(buf, mv.body_drop(f * 1.5, f * 0.75, 0.055, curve=0.4), 0.0, 0.7)
    place(buf, mv.noise_impact(0.10, rng, 4200.0, 900.0, octaves=1.5, tau_s=0.022), 0.004, 0.35)
    place(buf, mv.grain_scatter(0.16, rng, count=7, fc_low=1200.0, fc_high=6000.0), 0.02, 0.12)
    return buf


def axe_deep(rng):
    """B — deep bite. A heavier head, a wetter trunk: real low weight under the
    hit and modes that hang for a third of a second. Reads as *effort*."""
    buf = silence(0.55)
    f = rng.uniform(62.0, 76.0)
    place(buf, mv.transient(rng, 0.004, fc_low=700.0, fc_high=6000.0), 0.0, 0.75)
    place(buf, mv.body_drop(f * 2.1, f * 0.72, 0.13, curve=0.55, tau_ratio=0.4), 0.0, 1.0)
    place(buf, mv.modal_bank([(f, 0.26, 1.0), (f * 1.94, 0.16, 0.45),
                              (f * 3.42, 0.09, 0.24), (f * 6.1, 0.04, 0.10)],
                             0.48, rng, jitter_cents=35.0), 0.002, 0.8)
    place(buf, ma.ks_pluck(f * 2.0, 0.35, rng, damp=0.955, bright=0.35), 0.003, 0.45)
    place(buf, mv.noise_impact(0.22, rng, 2600.0, 380.0, octaves=1.8, tau_s=0.07), 0.006, 0.4)
    place(buf, mv.grain_scatter(0.30, rng, count=11, fc_low=500.0, fc_high=3600.0), 0.03, 0.18)
    return buf


def axe_wet(rng):
    """C — wet timber. Mire-soaked wood: the fundamental sags, the high modes
    are damped almost out, and a suck of water leaves the cut. Least 'game-y',
    most *place*. Pairs with the mud footsteps."""
    buf = silence(0.48)
    f = rng.uniform(70.0, 84.0)
    place(buf, mv.transient(rng, 0.005, fc_low=300.0, fc_high=2400.0), 0.0, 0.6)
    place(buf, mv.modal_bank([(f, 0.13, 1.0), (f * 1.78, 0.07, 0.35), (f * 3.1, 0.03, 0.12)],
                             0.34, rng, jitter_cents=45.0), 0.002, 0.9)
    place(buf, mv.body_drop(f * 1.7, f * 0.68, 0.10, curve=0.6), 0.0, 0.85)
    n = ma.samples(0.20)
    suck = ma.swept_bandpass(ma.white(n, rng), np.geomspace(1800.0, 260.0, n),
                             octaves=1.3, block=512)
    suck *= 0.4 + 0.6 * np.abs(ma.slow_noise(n, 34.0, rng))
    place(buf, suck * ma.env_asr(n, 0.006, 0.11), 0.012, 0.45)
    place(buf, mv.grain_scatter(0.22, rng, count=6, fc_low=900.0, fc_high=3000.0,
                                grain_s=(0.002, 0.008)), 0.05, 0.14)
    return buf


# ---------------------------------------------------------------------------
# pick on stone
# ---------------------------------------------------------------------------

def pick_sharp(rng):
    """A — sharp chip. Bright dense inharmonic modes that die in 40 ms, a spray
    of grit. The clearest 'I hit the right thing' read of the three."""
    buf = silence(0.30)
    place(buf, mv.transient(rng, 0.0018, fc_low=2600.0), 0.0, 1.0)
    base = rng.uniform(2150.0, 2480.0)
    place(buf, mv.modal_bank([(base, 0.040, 1.0), (base * 1.54, 0.030, 0.62),
                              (base * 2.21, 0.021, 0.38), (base * 3.07, 0.014, 0.22),
                              (base * 4.4, 0.009, 0.12)], 0.22, rng, jitter_cents=60.0),
          0.0012, 0.55)
    place(buf, mv.body_drop(150.0, 74.0, 0.05), 0.0, 0.5)
    place(buf, mv.noise_impact(0.06, rng, 9000.0, 3000.0, octaves=1.6, tau_s=0.015), 0.001, 0.4)
    place(buf, mv.grain_scatter(0.18, rng, count=9, fc_low=2500.0, fc_high=9000.0,
                                grain_s=(0.002, 0.007)), 0.012, 0.22)
    return buf


def pick_granite(rng):
    """B — granite thud. Dense rock barely rings: most of the energy is low and
    gone in 60 ms. Heaviest, least fatiguing over a long mining session."""
    buf = silence(0.34)
    place(buf, mv.transient(rng, 0.003, fc_low=900.0, fc_high=7000.0), 0.0, 0.8)
    place(buf, mv.body_drop(240.0, 88.0, 0.09, curve=0.45), 0.0, 1.0)
    base = rng.uniform(760.0, 940.0)
    place(buf, mv.modal_bank([(base, 0.045, 1.0), (base * 1.71, 0.028, 0.5),
                              (base * 2.63, 0.017, 0.26), (base * 4.9, 0.008, 0.12)],
                             0.24, rng, jitter_cents=70.0), 0.0015, 0.6)
    place(buf, mv.noise_impact(0.12, rng, 3200.0, 700.0, octaves=1.7, tau_s=0.035), 0.002, 0.5)
    place(buf, mv.grain_scatter(0.24, rng, count=12, fc_low=700.0, fc_high=4200.0), 0.02, 0.24)
    return buf


def pick_crystal(rng):
    """C — crystalline. For a world that grows mire crystals: near-integer
    partials that ring on past the hit, tuned so the ring lands in D. Riskiest
    of the three — it makes every rock sound faintly magical."""
    buf = silence(0.60)
    place(buf, mv.transient(rng, 0.0015, fc_low=3400.0), 0.0, 0.9)
    root = ma.note_hz("D6") * rng.uniform(0.98, 1.02)
    place(buf, mv.modal_bank([(root, 0.30, 1.0), (root * 2.01, 0.20, 0.5),
                              (root * 3.02, 0.12, 0.28), (root * 4.06, 0.07, 0.14),
                              (root * 1.497, 0.16, 0.3)], 0.55, rng, jitter_cents=12.0),
          0.0015, 0.45)
    place(buf, ma.fm_bell(root * 0.5, 0.5, rng, ratio=2.01, index=1.4), 0.002, 0.30)
    place(buf, mv.body_drop(180.0, 80.0, 0.055), 0.0, 0.55)
    place(buf, mv.noise_impact(0.07, rng, 11000.0, 4000.0, octaves=1.4, tau_s=0.016), 0.001, 0.35)
    place(buf, mv.grain_scatter(0.22, rng, count=7, fc_low=3500.0, fc_high=11000.0,
                                grain_s=(0.002, 0.006)), 0.015, 0.16)
    return buf


# ---------------------------------------------------------------------------
# tree break
# ---------------------------------------------------------------------------

def tree_groan(rng):
    """A — long groan. The cinematic one: 0.7 s of rising stick-slip fibre
    before the crack, then a long settling scatter. Sells scale."""
    buf = silence(2.3)
    creak = ma.burst_train(0.72, 11.0, 62.0, rng)
    creak = ma.swept_bandpass(creak, np.geomspace(240.0, 1050.0, creak.shape[0]),
                              octaves=0.75, block=1024)
    place(buf, creak * np.linspace(0.18, 1.0, creak.shape[0]) ** 1.4, 0.0, 0.55)
    place(buf, mv.transient(rng, 0.012, fc_low=450.0), 0.73, 1.0)
    place(buf, mv.modal_bank([(58.0, 0.9, 1.0), (94.0, 0.55, 0.65), (147.0, 0.3, 0.4),
                              (233.0, 0.16, 0.2)], 1.3, rng, jitter_cents=40.0), 0.73, 0.85)
    place(buf, mv.body_drop(120.0, 38.0, 0.28, curve=0.5), 0.73, 0.9)
    place(buf, mv.noise_impact(1.0, rng, 3000.0, 420.0, octaves=1.6, tau_s=0.34, block=1024),
          0.79, 0.4)
    place(buf, mv.grain_scatter(1.3, rng, count=26, fc_low=600.0, fc_high=5000.0,
                                density_curve=1.6), 0.85, 0.28)
    return buf


def tree_snap(rng):
    """B — snap and fall. Short warning, violent break, then the trunk actually
    *goes*: a whoosh of falling and a ground impact. The most readable at range
    and the only one that tells you a tree landed."""
    buf = silence(2.4)
    creak = ma.burst_train(0.28, 20.0, 90.0, rng)
    creak = ma.swept_bandpass(creak, np.geomspace(400.0, 1400.0, creak.shape[0]),
                              octaves=0.7, block=512)
    place(buf, creak * np.linspace(0.3, 1.0, creak.shape[0]), 0.0, 0.5)
    place(buf, mv.transient(rng, 0.008, fc_low=800.0), 0.29, 1.0)
    place(buf, mv.modal_bank([(76.0, 0.35, 1.0), (139.0, 0.2, 0.6), (218.0, 0.11, 0.35)],
                             0.6, rng, jitter_cents=45.0), 0.29, 0.9)
    place(buf, mv.body_drop(170.0, 52.0, 0.16, curve=0.4), 0.29, 0.95)
    # the fall: a long airy arc
    n = ma.samples(0.85)
    fall = ma.swept_bandpass(ma.white(n, rng), np.geomspace(700.0, 260.0, n),
                             octaves=1.7, block=1024)
    place(buf, fall * (np.sin(np.pi * np.linspace(0, 1, n)) ** 1.3), 0.45, 0.28)
    # the landing
    place(buf, mv.body_drop(90.0, 30.0, 0.5, curve=0.5, tau_ratio=0.3), 1.3, 1.0)
    place(buf, mv.noise_impact(0.7, rng, 1800.0, 260.0, octaves=1.8, tau_s=0.2, block=1024),
          1.3, 0.45)
    place(buf, mv.grain_scatter(0.9, rng, count=22, fc_low=500.0, fc_high=4500.0), 1.34, 0.3)
    return buf


def tree_rot(rng):
    """C — wet rot. Nothing in this swamp is seasoned: a fibrous tearing rip
    instead of a crack, a sodden thud instead of a boom. Distinctive, but it
    gives up the satisfying *snap*."""
    buf = silence(2.0)
    n_rip = ma.samples(0.75)
    rip = ma.burst_train(0.75, 40.0, 150.0, rng)
    rip = ma.swept_bandpass(rip, np.geomspace(700.0, 300.0, rip.shape[0]),
                            octaves=1.6, block=512)
    rip *= 0.35 + 0.65 * np.abs(ma.slow_noise(n_rip, 18.0, rng))
    place(buf, rip * np.linspace(0.25, 1.0, n_rip) ** 1.2, 0.0, 0.6)
    place(buf, mv.transient(rng, 0.02, fc_low=200.0, fc_high=1600.0), 0.74, 0.8)
    place(buf, mv.modal_bank([(48.0, 0.5, 1.0), (79.0, 0.25, 0.5), (126.0, 0.1, 0.2)],
                             0.8, rng, jitter_cents=60.0), 0.75, 0.9)
    place(buf, mv.body_drop(95.0, 31.0, 0.42, curve=0.6, tau_ratio=0.35), 0.76, 1.0)
    n_sq = ma.samples(0.55)
    squelch = ma.swept_bandpass(ma.white(n_sq, rng), np.geomspace(2200.0, 220.0, n_sq),
                                octaves=1.4, block=512)
    squelch *= 0.4 + 0.6 * np.abs(ma.slow_noise(n_sq, 26.0, rng))
    place(buf, squelch * ma.exp_decay(n_sq, 0.18), 0.80, 0.5)
    place(buf, mv.grain_scatter(1.0, rng, count=16, fc_low=400.0, fc_high=2600.0), 0.95, 0.2)
    return buf


# ---------------------------------------------------------------------------
# stone break
# ---------------------------------------------------------------------------

def stone_shatter(rng):
    """A — shatter. A hard crack that immediately becomes many small pieces."""
    buf = silence(1.5)
    place(buf, mv.transient(rng, 0.004, fc_low=1200.0), 0.0, 1.0)
    place(buf, mv.body_drop(180.0, 44.0, 0.24, curve=0.45), 0.0, 0.9)
    place(buf, mv.modal_bank([(620.0, 0.09, 1.0), (1010.0, 0.06, 0.55), (1580.0, 0.035, 0.3),
                              (2420.0, 0.02, 0.16)], 0.4, rng, jitter_cents=80.0), 0.001, 0.5)
    place(buf, mv.noise_impact(0.45, rng, 6000.0, 900.0, octaves=1.8, tau_s=0.12), 0.003, 0.55)
    place(buf, mv.grain_scatter(1.2, rng, count=34, fc_low=900.0, fc_high=7000.0,
                                density_curve=2.2), 0.05, 0.4)
    return buf


def stone_crumble(rng):
    """B — crumble. Low, dusty, grinding: the rock gives way rather than
    exploding. Long tail, no sharp edge — kindest at high harvest rates."""
    buf = silence(1.6)
    place(buf, mv.body_drop(120.0, 32.0, 0.35, curve=0.6, tau_ratio=0.4), 0.0, 1.0)
    n = ma.samples(0.85)
    grind = ma.fft_filter(ma.pink(n, rng), fc_low=180.0, fc_high=1700.0, order=2)
    grind *= 0.3 + 0.7 * np.abs(ma.slow_noise(n, 16.0, rng))
    place(buf, grind * ma.exp_decay(n, 0.34), 0.008, 0.7)
    place(buf, mv.modal_bank([(310.0, 0.12, 1.0), (505.0, 0.07, 0.45), (790.0, 0.04, 0.22)],
                             0.35, rng, jitter_cents=90.0), 0.004, 0.35)
    place(buf, mv.grain_scatter(1.35, rng, count=40, fc_low=400.0, fc_high=3200.0,
                                density_curve=1.4, grain_s=(0.005, 0.026)), 0.06, 0.35)
    return buf


def stone_burst(rng):
    """C — burst. The loud one: sub drop under a wide bright transient and a
    fast wide scatter. Overtly game-feel; pairs with `loot jackpot` moments."""
    buf = silence(1.5)
    place(buf, mv.transient(rng, 0.006, fc_low=600.0), 0.0, 1.0)
    place(buf, mv.body_drop(210.0, 28.0, 0.55, curve=0.35, tau_ratio=0.28), 0.0, 1.0)
    place(buf, ma.sine(38.0, 0.5) * ma.exp_decay(ma.samples(0.5), 0.16), 0.002, 0.5)
    place(buf, mv.noise_impact(0.35, rng, 11000.0, 1400.0, octaves=2.2, tau_s=0.07), 0.0, 0.6)
    place(buf, mv.modal_bank([(430.0, 0.11, 1.0), (700.0, 0.07, 0.5), (1180.0, 0.04, 0.3),
                              (1970.0, 0.02, 0.16)], 0.4, rng, jitter_cents=70.0), 0.002, 0.45)
    place(buf, mv.grain_scatter(1.1, rng, count=44, fc_low=700.0, fc_high=9000.0,
                                density_curve=2.6), 0.03, 0.42)
    return buf


# ---------------------------------------------------------------------------
# melee whoosh
# ---------------------------------------------------------------------------

def whoosh_air(rng):
    """A — air arc. One clean band sweeping up and back down: neutral, works on
    anything, never tires."""
    n = ma.samples(0.26)
    centers = np.interp(np.linspace(0, 1, n), [0.0, 0.5, 1.0], [340.0, 1750.0, 460.0])
    sig = ma.swept_bandpass(ma.white(n, rng), centers, octaves=1.0, block=1024)
    return sig * (np.sin(np.pi * np.linspace(0, 1, n)) ** 1.7)


def whoosh_heavy(rng):
    """B — heavy swing. Two arcs a few milliseconds apart and an octave apart,
    plus a low pressure wave: a big weapon moving a lot of air."""
    buf = silence(0.42)
    for lag, lo, hi, oct_w, gain in ((0.0, 140.0, 620.0, 1.5, 0.9),
                                     (0.018, 380.0, 1500.0, 1.1, 0.6)):
        n = ma.samples(0.34)
        centers = np.interp(np.linspace(0, 1, n), [0.0, 0.55, 1.0], [lo, hi, lo * 1.2])
        sig = ma.swept_bandpass(ma.white(n, rng), centers, octaves=oct_w, block=1024)
        place(buf, sig * (np.sin(np.pi * np.linspace(0, 1, n)) ** 1.5), lag, gain)
    n = ma.samples(0.30)
    place(buf, ma.sine_glide(70.0, 40.0, 0.30) * (np.sin(np.pi * np.linspace(0, 1, n)) ** 2.0),
          0.02, 0.35)
    return buf


def whoosh_blade(rng):
    """C — blade cut. Fast, thin, high, with a faint tonal edge from a narrow
    band — the sound of something *sharp* rather than something heavy."""
    n = ma.samples(0.19)
    centers = np.interp(np.linspace(0, 1, n), [0.0, 0.45, 1.0], [900.0, 4600.0, 1500.0])
    sig = ma.swept_bandpass(ma.white(n, rng), centers, octaves=0.55, block=512)
    tone = ma.sine_glide(2100.0, 3600.0, 0.19) * 0.12
    arch = np.sin(np.pi * np.linspace(0, 1, n)) ** 2.4
    return (sig + tone) * arch


# ---------------------------------------------------------------------------
# melee hit
# ---------------------------------------------------------------------------

def hit_flesh(rng):
    """A — flesh thud. Low body, wet slap, no ring. The most 'meat' of the
    three; reads as damage without implying a material."""
    buf = silence(0.22)
    place(buf, mv.body_drop(105.0, 46.0, 0.10, curve=0.5), 0.0, 1.0)
    place(buf, mv.transient(rng, 0.002, fc_low=500.0, fc_high=3000.0), 0.0, 0.45)
    n = ma.samples(0.11)
    slap = ma.fft_filter(ma.pink(n, rng), fc_low=120.0, fc_high=1100.0, order=2)
    place(buf, slap * ma.exp_decay(n, 0.035), 0.001, 0.55)
    return buf


def hit_bone(rng):
    """B — bone crack. A hard modal snap over the thud. Best hit-confirmation
    of the three, and the most tiring if the player swings constantly."""
    buf = silence(0.28)
    place(buf, mv.transient(rng, 0.0018, fc_low=2200.0), 0.0, 0.8)
    place(buf, mv.body_drop(120.0, 52.0, 0.09, curve=0.5), 0.0, 0.9)
    place(buf, mv.modal_bank([(1180.0, 0.035, 1.0), (1930.0, 0.022, 0.55),
                              (2870.0, 0.013, 0.3)], 0.16, rng, jitter_cents=60.0), 0.0015, 0.5)
    n = ma.samples(0.09)
    place(buf, ma.fft_filter(ma.pink(n, rng), fc_low=200.0, fc_high=1400.0)
          * ma.exp_decay(n, 0.03), 0.001, 0.4)
    place(buf, mv.grain_scatter(0.14, rng, count=5, fc_low=1500.0, fc_high=6000.0,
                                grain_s=(0.002, 0.006)), 0.01, 0.15)
    return buf


def hit_chitin(rng):
    """C — chitin. Hollow shell: a bright inharmonic ring that keeps going a
    little too long. Fits mire fauna better than either of the others, at the
    cost of sounding wrong on anything soft."""
    buf = silence(0.35)
    place(buf, mv.transient(rng, 0.0022, fc_low=1600.0), 0.0, 0.85)
    base = rng.uniform(520.0, 610.0)
    place(buf, mv.modal_bank([(base, 0.13, 1.0), (base * 1.87, 0.08, 0.6),
                              (base * 3.14, 0.045, 0.32), (base * 5.2, 0.02, 0.15)],
                             0.30, rng, jitter_cents=45.0), 0.0012, 0.7)
    place(buf, mv.body_drop(140.0, 62.0, 0.07, curve=0.45), 0.0, 0.7)
    place(buf, mv.noise_impact(0.09, rng, 5200.0, 1200.0, octaves=1.5, tau_s=0.02), 0.001, 0.3)
    return buf


# ---------------------------------------------------------------------------
# footsteps in mud
# ---------------------------------------------------------------------------

def step_squelch(rng):
    """A — squelch. Suction sweep down plus a soft body: the compromise step,
    quiet enough to hear a thousand times."""
    buf = silence(0.26)
    n = ma.samples(0.16)
    centers = np.geomspace(2800.0, 300.0, n)
    sq = ma.swept_bandpass(ma.white(n, rng), centers, octaves=1.3, block=512)
    sq *= 0.5 + 0.5 * np.abs(ma.slow_noise(n, 30.0, rng))
    place(buf, sq * ma.env_asr(n, 0.004, 0.07), 0.004, 0.55)
    place(buf, mv.body_drop(92.0, 56.0, 0.05, curve=0.5), 0.0, 0.4)
    place(buf, mv.grain_scatter(0.12, rng, count=5, fc_low=2200.0, fc_high=7000.0,
                                grain_s=(0.001, 0.004)), 0.01, 0.18)
    return buf


def step_shallow(rng):
    """B — shallow water. A step into standing water: a splash on impact and
    droplets on the lift. Brightest of the three, and the most *place*."""
    buf = silence(0.34)
    n = ma.samples(0.13)
    splash = ma.swept_bandpass(ma.white(n, rng), np.geomspace(5200.0, 1400.0, n),
                               octaves=1.9, block=512)
    place(buf, splash * ma.exp_decay(n, 0.045), 0.002, 0.7)
    place(buf, mv.body_drop(110.0, 62.0, 0.045, curve=0.5), 0.0, 0.35)
    n2 = ma.samples(0.12)
    lift = ma.swept_bandpass(ma.white(n2, rng), np.geomspace(900.0, 2600.0, n2),
                             octaves=1.2, block=512)
    place(buf, lift * ma.env_asr(n2, 0.02, 0.07), 0.13, 0.3)
    for _ in range(5):  # droplets falling back
        at = rng.uniform(0.15, 0.30)
        f = rng.uniform(1400.0, 3400.0)
        d = ma.sine_glide(f, f * 1.9, 0.012) * ma.exp_decay(ma.samples(0.012), 0.004)
        place(buf, ma.fade_edges(d, 0.001), at, rng.uniform(0.06, 0.16))
    return buf


def step_bog(rng):
    """C — deep bog. Slow: the foot goes in, then comes out with a pop. Longest
    of the three (~0.4 s) — it will fight a fast walk cycle, so it only works if
    movement in deep mire is genuinely slowed."""
    buf = silence(0.46)
    n = ma.samples(0.22)
    sink = ma.swept_bandpass(ma.white(n, rng), np.geomspace(1600.0, 180.0, n),
                             octaves=1.5, block=512)
    sink *= 0.35 + 0.65 * np.abs(ma.slow_noise(n, 20.0, rng))
    place(buf, sink * ma.env_asr(n, 0.012, 0.1), 0.0, 0.6)
    place(buf, mv.body_drop(70.0, 40.0, 0.10, curve=0.6), 0.0, 0.55)
    # the release pop: a short upward pitch blip, the sound of the seal breaking
    n2 = ma.samples(0.09)
    pop = ma.sine_glide(120.0, 480.0, 0.09, curve=1.6) * ma.exp_decay(n2, 0.025)
    place(buf, pop, 0.24, 0.4)
    suck = ma.swept_bandpass(ma.white(n2, rng), np.geomspace(400.0, 2200.0, n2),
                             octaves=1.4, block=512)
    place(buf, suck * ma.env_asr(n2, 0.01, 0.05), 0.24, 0.35)
    return buf


# ---------------------------------------------------------------------------
# item pickup — all three stay in D, the day track's home (palette rule)
# ---------------------------------------------------------------------------

def pickup_chime(rng):
    """A — chime. Two plucked notes a fifth apart with a bell on top. Clear,
    unmistakable, slightly arcade."""
    buf = silence(0.55)
    place(buf, mv.dulcimer(ma.note_hz("D5"), 0.4, rng, courses=2, damp=0.9975), 0.0, 0.6)
    place(buf, mv.dulcimer(ma.note_hz("A5"), 0.42, rng, courses=2, damp=0.9975), 0.065, 0.5)
    place(buf, ma.fm_bell(ma.note_hz("D6"), 0.45, rng, ratio=2.01, index=1.6), 0.065, 0.16)
    return buf


def pickup_glimmer(rng):
    """B — soft glimmer. No attack to speak of: a rising airy shimmer that
    resolves onto D. Gentlest; disappears under combat, which may be the point."""
    buf = silence(0.65)
    n = ma.samples(0.4)
    shimmer = ma.swept_bandpass(ma.white(n, rng), np.geomspace(1800.0, 7000.0, n),
                                octaves=1.1, block=512)
    place(buf, shimmer * ma.env_asr(n, 0.10, 0.22), 0.0, 0.35)
    place(buf, ma.fm_bell(ma.note_hz("D6"), 0.55, rng, ratio=2.0, index=1.1), 0.14, 0.4)
    place(buf, ma.fm_bell(ma.note_hz("A6"), 0.45, rng, ratio=2.0, index=0.9), 0.20, 0.22)
    glow = (ma.sine(ma.note_hz("D5"), 0.45) + 0.6 * ma.sine(ma.note_hz("A5"), 0.45))
    place(buf, glow * ma.env_asr(ma.samples(0.45), 0.14, 0.25), 0.12, 0.16)
    return buf


def pickup_grab(rng):
    """C — grab. Diegetic: leather and cloth, a small object knocking into a
    pack, one quiet tuned pip so it still registers as a reward. The option
    that stops a 200-item run sounding like a slot machine."""
    buf = silence(0.4)
    n = ma.samples(0.14)
    cloth = ma.fft_filter(ma.white(n, rng), fc_low=1600.0, fc_high=6500.0, order=2)
    cloth *= 0.3 + 0.7 * np.abs(ma.slow_noise(n, 90.0, rng))
    place(buf, cloth * ma.env_asr(n, 0.01, 0.09), 0.0, 0.5)
    place(buf, mv.modal_bank([(430.0, 0.05, 1.0), (760.0, 0.03, 0.5)], 0.12, rng,
                             jitter_cents=50.0), 0.03, 0.35)
    place(buf, mv.grain_scatter(0.16, rng, count=4, fc_low=900.0, fc_high=4000.0,
                                grain_s=(0.003, 0.01)), 0.05, 0.25)
    pip = ma.sine(ma.note_hz("D6"), 0.10) * ma.env_asr(ma.samples(0.10), 0.006, 0.08)
    place(buf, pip, 0.09, 0.12)
    return buf


# ---------------------------------------------------------------------------
# chest open
# ---------------------------------------------------------------------------

def chest_creak(rng):
    """A — creak and sparkle. Hinge, lid, then a Dorian arpeggio. The familiar
    shape; safe."""
    buf = silence(1.3)
    creak = ma.burst_train(0.45, 11.0, 46.0, rng)
    creak = ma.swept_bandpass(creak, np.geomspace(460.0, 1400.0, creak.shape[0]),
                              octaves=0.7, block=1024)
    place(buf, creak * np.linspace(0.3, 0.85, creak.shape[0]), 0.0, 0.5)
    place(buf, mv.transient(rng, 0.004, fc_low=900.0), 0.5, 0.6)
    place(buf, mv.modal_bank([(210.0, 0.10, 1.0), (392.0, 0.06, 0.5)], 0.3, rng,
                             jitter_cents=40.0), 0.5, 0.5)
    for i, note in enumerate(("D6", "E6", "A6", "B6")):
        place(buf, ma.fm_bell(ma.note_hz(note), 0.6, rng), 0.56 + 0.062 * i, 0.30 - 0.05 * i)
    glow = (ma.sine(ma.note_hz("D5"), 0.55) + ma.sine(ma.note_hz("A5"), 0.55)) * 0.5
    place(buf, glow * ma.env_asr(ma.samples(0.55), 0.12, 0.3), 0.56, 0.14)
    return buf


def chest_iron(rng):
    """B — iron latch. Entirely physical: a latch clunk, a hinge groan under
    load, the lid meeting its stop. No magic at all — the loot itself carries
    the reward, and that keeps the sparkle available for rare drops."""
    buf = silence(1.45)
    place(buf, mv.transient(rng, 0.003, fc_low=1400.0), 0.0, 0.7)
    place(buf, mv.modal_bank([(1240.0, 0.09, 1.0), (2180.0, 0.05, 0.5), (3410.0, 0.03, 0.25)],
                             0.25, rng, jitter_cents=30.0), 0.002, 0.45)   # the latch
    place(buf, mv.body_drop(180.0, 90.0, 0.08, curve=0.5), 0.0, 0.5)
    groan = ma.burst_train(0.6, 7.0, 26.0, rng)
    groan = ma.swept_bandpass(groan, np.geomspace(180.0, 620.0, groan.shape[0]),
                              octaves=1.0, block=1024)
    place(buf, groan * np.linspace(0.4, 1.0, groan.shape[0]), 0.12, 0.55)
    place(buf, mv.body_drop(120.0, 58.0, 0.28, curve=0.45, tau_ratio=0.3), 0.78, 0.85)
    place(buf, mv.modal_bank([(96.0, 0.32, 1.0), (168.0, 0.18, 0.5), (287.0, 0.08, 0.25)],
                             0.6, rng, jitter_cents=45.0), 0.78, 0.6)
    place(buf, mv.grain_scatter(0.5, rng, count=9, fc_low=800.0, fc_high=4500.0), 0.84, 0.18)
    return buf


def chest_reliquary(rng):
    """C — reliquary. The jackpot read: a swell *before* the lid moves, a full
    D-Dorian bell cascade, and a choir-ish bloom under it. Deliberately over the
    top — a chest should sometimes feel like the run just changed."""
    buf = silence(2.0)
    n = ma.samples(0.55)
    rise = ma.swept_bandpass(ma.white(n, rng), np.geomspace(600.0, 5200.0, n),
                             octaves=1.2, block=512)
    place(buf, rise * (np.linspace(0.0, 1.0, n) ** 2.0), 0.0, 0.4)
    place(buf, ma.sine_glide(ma.note_hz("D3"), ma.note_hz("D4"), 0.55, curve=1.6)
          * (np.linspace(0.0, 1.0, n) ** 2.2), 0.0, 0.3)
    place(buf, mv.transient(rng, 0.005, fc_low=700.0), 0.55, 0.7)
    place(buf, mv.body_drop(150.0, 70.0, 0.2, curve=0.45), 0.55, 0.6)
    for i, note in enumerate(("D5", "F5", "A5", "D6", "E6", "A6")):
        place(buf, ma.fm_bell(ma.note_hz(note), 1.3, rng, ratio=2.01, index=1.8),
              0.58 + 0.075 * i, 0.34 - 0.04 * i)
    for note in ("D4", "A4", "D5"):
        place(buf, mv.choir(ma.note_hz(note), 1.3, rng, vowel="ah", voices=3,
                            attack_s=0.18, release_s=0.8), 0.6, 0.18)
    place(buf, mv.grain_scatter(0.9, rng, count=14, fc_low=4000.0, fc_high=12000.0,
                                grain_s=(0.002, 0.006), density_curve=1.5), 0.7, 0.16)
    return buf


# ---------------------------------------------------------------------------
# ui click
# ---------------------------------------------------------------------------

def ui_wood(rng):
    """A — soft tick. A tiny piece of wood tapped: warm, low, unfatiguing.
    Matches a UI made of the world's materials."""
    buf = silence(0.09)
    place(buf, mv.modal_bank([(720.0, 0.014, 1.0), (1480.0, 0.008, 0.4)], 0.06, rng,
                             jitter_cents=20.0), 0.0, 0.8)
    place(buf, mv.transient(rng, 0.0012, fc_low=1800.0, fc_high=8000.0), 0.0, 0.4)
    return buf


def ui_glass(rng):
    """B — glass pip. A tuned blip in D — every menu press lands in key with
    the world. Brightest; risks being precious."""
    buf = silence(0.10)
    place(buf, ma.fm_bell(ma.note_hz("D6"), 0.09, rng, ratio=2.01, index=1.0), 0.0, 0.7)
    place(buf, mv.transient(rng, 0.001, fc_low=3000.0), 0.0, 0.25)
    return buf


def ui_dry(rng):
    """C — dry click. Almost no pitch at all: a switch. The least intrusive
    option and the one that ages best over thousands of presses."""
    buf = silence(0.06)
    place(buf, mv.transient(rng, 0.004, fc_low=900.0, fc_high=9000.0), 0.0, 1.0)
    place(buf, mv.modal_bank([(2600.0, 0.009, 1.0), (4300.0, 0.005, 0.4)], 0.03, rng,
                             jitter_cents=15.0), 0.0005, 0.55)
    place(buf, mv.body_drop(320.0, 190.0, 0.02, curve=0.5), 0.0, 0.35)
    return buf


# ---------------------------------------------------------------------------
# build place
# ---------------------------------------------------------------------------

def build_wood(rng):
    """A — timber set. A beam dropped into place and settling: low knock, wood
    modes, one quiet confirming pip."""
    buf = silence(0.5)
    place(buf, mv.transient(rng, 0.003, fc_low=900.0), 0.0, 0.5)
    place(buf, mv.modal_bank([(132.0, 0.16, 1.0), (256.0, 0.09, 0.5), (410.0, 0.05, 0.25)],
                             0.4, rng, jitter_cents=35.0), 0.001, 0.85)
    place(buf, mv.body_drop(96.0, 58.0, 0.09, curve=0.5), 0.0, 0.6)
    pip = ma.sine(ma.note_hz("A4"), 0.08) * ma.env_asr(ma.samples(0.08), 0.008, 0.05)
    place(buf, pip, 0.14, 0.16)
    return buf


def build_stake(rng):
    """B — driven stake. A hammer blow, not a placement: hard, low, decisive.
    Best sense of *commitment* per piece; loudest of the three."""
    buf = silence(0.45)
    place(buf, mv.transient(rng, 0.0022, fc_low=1400.0), 0.0, 0.85)
    place(buf, mv.body_drop(150.0, 52.0, 0.14, curve=0.4), 0.0, 1.0)
    place(buf, mv.modal_bank([(178.0, 0.09, 1.0), (321.0, 0.05, 0.45), (540.0, 0.025, 0.2)],
                             0.28, rng, jitter_cents=40.0), 0.001, 0.6)
    place(buf, mv.noise_impact(0.12, rng, 3400.0, 700.0, octaves=1.6, tau_s=0.03), 0.002, 0.35)
    place(buf, mv.grain_scatter(0.2, rng, count=6, fc_low=600.0, fc_high=3500.0), 0.02, 0.15)
    return buf


def build_lash(rng):
    """C — lashed. Rope and timber: a creak of cordage pulling tight, then the
    piece settling. Quietest and most craft-like; weakest as a confirmation."""
    buf = silence(0.62)
    creak = ma.burst_train(0.22, 26.0, 70.0, rng)
    creak = ma.swept_bandpass(creak, np.geomspace(700.0, 1900.0, creak.shape[0]),
                              octaves=0.9, block=512)
    place(buf, creak * np.linspace(0.4, 1.0, creak.shape[0]), 0.0, 0.45)
    place(buf, mv.modal_bank([(118.0, 0.20, 1.0), (232.0, 0.10, 0.45)], 0.4, rng,
                             jitter_cents=35.0), 0.22, 0.7)
    place(buf, mv.body_drop(88.0, 54.0, 0.08, curve=0.5), 0.22, 0.5)
    n = ma.samples(0.14)
    fibre = ma.fft_filter(ma.white(n, rng), fc_low=2000.0, fc_high=7000.0, order=2)
    fibre *= 0.3 + 0.7 * np.abs(ma.slow_noise(n, 70.0, rng))
    place(buf, fibre * ma.env_asr(n, 0.01, 0.09), 0.24, 0.28)
    pip = ma.sine(ma.note_hz("D5"), 0.09) * ma.env_asr(ma.samples(0.09), 0.008, 0.06)
    place(buf, pip, 0.34, 0.12)
    return buf


# ---------------------------------------------------------------------------
# family -> take -> (label, recipe, variants, reverb send, peak dBFS)
# ---------------------------------------------------------------------------

OPTIONS = {
    "axe_hit_wood": {
        "A": ("dry split", axe_dry, 3, 0.09, -3.0),
        "B": ("deep bite", axe_deep, 3, 0.12, -3.0),
        "C": ("wet timber", axe_wet, 3, 0.10, -3.5),
    },
    "pick_hit_stone": {
        "A": ("sharp chip", pick_sharp, 3, 0.10, -3.0),
        "B": ("granite thud", pick_granite, 3, 0.11, -3.0),
        "C": ("crystalline", pick_crystal, 3, 0.13, -4.0),
    },
    "tree_break": {
        "A": ("long groan", tree_groan, 1, 0.17, -2.5),
        "B": ("snap and fall", tree_snap, 1, 0.15, -2.5),
        "C": ("wet rot", tree_rot, 1, 0.14, -3.0),
    },
    "stone_break": {
        "A": ("shatter", stone_shatter, 1, 0.14, -2.5),
        "B": ("crumble", stone_crumble, 1, 0.12, -3.0),
        "C": ("burst", stone_burst, 1, 0.16, -2.0),
    },
    "melee_whoosh": {
        "A": ("air arc", whoosh_air, 2, 0.05, -4.0),
        "B": ("heavy swing", whoosh_heavy, 2, 0.06, -4.0),
        "C": ("blade cut", whoosh_blade, 2, 0.04, -4.5),
    },
    "melee_hit": {
        "A": ("flesh thud", hit_flesh, 2, 0.08, -3.0),
        "B": ("bone crack", hit_bone, 2, 0.09, -3.0),
        "C": ("chitin shell", hit_chitin, 2, 0.10, -3.5),
    },
    "footstep_mud": {
        "A": ("squelch", step_squelch, 3, 0.05, -6.0),
        "B": ("shallow water", step_shallow, 3, 0.06, -6.0),
        "C": ("deep bog", step_bog, 3, 0.05, -6.5),
    },
    "item_pickup": {
        "A": ("chime", pickup_chime, 1, 0.12, -5.0),
        "B": ("soft glimmer", pickup_glimmer, 1, 0.14, -5.5),
        "C": ("grab", pickup_grab, 1, 0.08, -6.5),
    },
    "chest_open": {
        "A": ("creak and sparkle", chest_creak, 1, 0.15, -3.5),
        "B": ("iron latch", chest_iron, 1, 0.13, -3.5),
        "C": ("reliquary", chest_reliquary, 1, 0.17, -3.0),
    },
    "ui_click": {
        "A": ("soft tick", ui_wood, 1, 0.0, -8.0),
        "B": ("glass pip", ui_glass, 1, 0.0, -8.0),
        "C": ("dry click", ui_dry, 1, 0.0, -8.5),
    },
    "build_place": {
        "A": ("timber set", build_wood, 1, 0.10, -4.0),
        "B": ("driven stake", build_stake, 1, 0.11, -3.5),
        "C": ("lashed", build_lash, 1, 0.09, -4.5),
    },
}

TAKES = ("A", "B", "C")
SEED_BASE = 771000


def render_one(fn, variants: int, wet: float, peak_db: float, ir: np.ndarray,
               seed: int) -> list[np.ndarray]:
    out = []
    for v in range(variants):
        rng = np.random.default_rng(seed + v)
        sig = fn(rng)
        if wet > 0:
            verb = ma.convolve_fft(sig, ir)
            mixed = np.zeros(sig.shape[0] + ir.shape[0])
            mixed[: sig.shape[0]] = sig
            mixed[: verb.shape[0]] += wet * verb[: mixed.shape[0]]
            sig = mixed
        sig = sig - np.mean(sig)
        peak = np.max(np.abs(sig))
        if peak > 0:
            sig *= ma.db(peak_db) / peak
        out.append(ma.fade_edges(sig, 0.003))
    return out


def pips(count: int) -> np.ndarray:
    """`count` short high pips — the spoken slate we cannot synthesize. One for
    take A, two for B, three for C."""
    gap = np.zeros(ma.samples(0.10))
    one = ma.sine(2093.0, 0.06) * ma.env_asr(ma.samples(0.06), 0.005, 0.04) * ma.db(-20.0)
    return np.concatenate([np.concatenate([one, gap]) for _ in range(count)])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--build-dir",
                        default=os.path.join(tempfile.gettempdir(), "mire_audio_build", "sfx_options"))
    parser.add_argument("--only", default=None, help="one family only")
    parser.add_argument("--ship", nargs="*", default=None,
                        help="promote picks: family=TAKE [family=TAKE ...]")
    args = parser.parse_args()
    wav_dir = os.path.join(args.build_dir, "wav")
    os.makedirs(wav_dir, exist_ok=True)

    if args.ship:
        sfx_dir = os.path.join(REPO, "assets", "audio", "sfx")
        table = []
        for pick in args.ship:
            family, _, take = pick.partition("=")
            take = take.upper()
            if family not in OPTIONS or take not in TAKES:
                raise SystemExit(f"bad pick {pick!r}")
            label, _, variants, _, _ = OPTIONS[family][take]
            for v in range(variants):
                src = os.path.join(wav_dir, f"{family}__{take}__{v + 1:02d}.wav")
                if not os.path.exists(src):
                    raise SystemExit(f"{src} missing — render first")
                name = f"{family}_{v + 1:02d}.wav" if variants > 1 else f"{family}.wav"
                shutil.copyfile(src, os.path.join(sfx_dir, name))
                print(f"  {name} <- take {take} ({label})")
            table.append(f"| `{family}` | {take} | {label} |")
        print("\nAUDIO.md table rows:\n" + "\n".join(table))
        return

    ir_rng = np.random.default_rng(5)
    ir = ma.make_ir(0.5, ir_rng, tau_s=0.09, predelay_s=0.012, hf_ratio=0.5, stereo=False)[0]
    dither = np.random.default_rng(31)
    families = [args.only] if args.only else list(OPTIONS)

    for fi, family in enumerate(families):
        reel: list[np.ndarray] = []
        print(family)
        for ti, take in enumerate(TAKES):
            label, fn, variants, wet, peak_db = OPTIONS[family][take]
            sigs = render_one(fn, variants, wet, peak_db, ir, SEED_BASE + fi * 131 + ti * 17)
            for v, sig in enumerate(sigs):
                fname = f"{family}__{take}__{v + 1:02d}.wav"
                ma.write_wav(os.path.join(wav_dir, fname), sig, dither)
            print(f"  {take} {label:<18} {variants} var  "
                  f"{sigs[0].shape[0] / ma.SR:.2f}s  rms {ma.rms_db(sigs[0]):.1f} dBFS")
            reel.append(pips(ti + 1))
            reel.append(np.zeros(ma.samples(0.35)))
            for sig in sigs:
                reel.append(sig)
                reel.append(np.zeros(ma.samples(0.45)))
            # each take is played through twice — one pass is not enough to judge
            for sig in sigs:
                reel.append(sig)
                reel.append(np.zeros(ma.samples(0.45)))
            reel.append(np.zeros(ma.samples(0.7)))
        reel_sig = np.concatenate(reel)
        reel_wav = os.path.join(args.build_dir, f"{family}_options.wav")
        ma.write_wav(reel_wav, reel_sig, dither)
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", reel_wav,
                        "-c:a", "libmp3lame", "-q:a", "3",
                        os.path.join(args.build_dir, f"{family}_options.mp3")], check=True)
        os.remove(reel_wav)

    print("options ->", args.build_dir)



# The import-cache guard (F-196) boots Godot for a full re-import on release, which
# costs minutes. Renders here write only to the build dir, so they touch nothing Godot
# imports and must not pay it; only --ship writes into assets/ and needs the lock.

def _writes_into_assets() -> bool:
    return any(a == "--ship" or a.startswith("--ship=") for a in sys.argv[1:])


if __name__ == "__main__":
    if _writes_into_assets():
        with import_cache_guard(os.path.basename(__file__)):
            main()
    else:
        main()
