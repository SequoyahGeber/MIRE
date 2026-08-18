#!/usr/bin/env python3
"""Render MIRE's sound effects from recipes. Deterministic (fixed seeds).

    python3 tools/audio/render_sfx.py [--sfx-dir DIR] [--build-dir DIR]

Writes mono 16-bit 44.1 kHz WAVs to --sfx-dir (default assets/audio/sfx/) —
mono on purpose: AudioStreamPlayer3D spatialises mono sources correctly.
Also writes sfx_preview_reel.{wav,mp3} to --build-dir for humans to audition
(every effect in file order, 0.8 s apart). The reel is not a game asset.

Recipe style: every effect is layered from the same three ingredients —
a transient (click/burst), a body (Karplus-Strong wood/string or a pitched
sine drop), and a texture (filtered noise) — then gets a short outdoor-ish
reverb send. Repetitive effects (axe, pick, footsteps) ship 3 seeded
variants; play them round-robin with +-4% pitch scatter at the player.

Named-note choices are deliberate: pickup/chest sparkles sit in D (the day
track's Dorian home), so rewards always sound in key with the world.
"""

from __future__ import annotations

import argparse
import os
import sys
import tempfile

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mire_audio as ma  # noqa: E402


def silence(dur_s: float) -> np.ndarray:
    return np.zeros(ma.samples(dur_s))


def place(buf: np.ndarray, sig: np.ndarray, at_s: float, gain: float = 1.0) -> None:
    start = ma.samples(at_s)
    end = min(start + sig.shape[0], buf.shape[0])
    if start < end:
        buf[start:end] += sig[: end - start] * gain


def click(rng: np.random.Generator, dur_s: float = 0.003, fc_low: float = 1500.0) -> np.ndarray:
    return ma.fade_edges(ma.fft_filter(ma.white(ma.samples(dur_s), rng), fc_low=fc_low), 0.0005)


def thump(f0: float, f1: float, dur_s: float) -> np.ndarray:
    n = ma.samples(dur_s)
    return ma.sine_glide(f0, f1, dur_s) * ma.exp_decay(n, dur_s * 0.4)


# ---------------------------------------------------------------------------
# recipes — each returns a mono float signal
# ---------------------------------------------------------------------------

def axe_hit_wood(rng: np.random.Generator) -> np.ndarray:
    buf = silence(0.42)
    f = rng.uniform(78.0, 94.0)
    place(buf, click(rng), 0.0, 0.7)
    place(buf, ma.ks_pluck(f, 0.32, rng, damp=0.93, bright=0.4), 0.001, 1.0)
    place(buf, thump(f * 1.15, f * 0.62, 0.07), 0.0, 0.85)
    debris = ma.fft_filter(ma.pink(ma.samples(0.14), rng), fc_high=1800.0)
    place(buf, debris * ma.exp_decay(ma.samples(0.14), 0.05), 0.008, 0.25)
    return buf


def pick_hit_stone(rng: np.random.Generator) -> np.ndarray:
    buf = silence(0.30)
    place(buf, click(rng, 0.002, 2200.0), 0.0, 0.95)
    detune = rng.uniform(0.96, 1.04)
    for f, tau, amp in ((2314.0, 0.040, 0.40), (3571.0, 0.028, 0.28), (5123.0, 0.018, 0.16)):
        ring = ma.sine(f * detune, 0.22) * ma.exp_decay(ma.samples(0.22), tau)
        place(buf, ring, 0.0015, amp)
    chip = ma.fft_filter(ma.white(ma.samples(0.05), rng), fc_low=3800.0)
    place(buf, chip * ma.exp_decay(ma.samples(0.05), 0.02), 0.002, 0.3)
    place(buf, thump(135.0, 72.0, 0.05), 0.0, 0.5)
    return buf


def tree_break(rng: np.random.Generator) -> np.ndarray:
    buf = silence(1.75)
    # rising stick-slip creak, then the crack, then debris
    creak = ma.burst_train(0.55, 14.0, 70.0, rng)
    creak = ma.swept_bandpass(creak, np.linspace(300.0, 950.0, creak.shape[0]),
                              octaves=0.8, block=1024)
    place(buf, creak * np.linspace(0.25, 1.0, creak.shape[0]), 0.0, 0.55)
    place(buf, click(rng, 0.009, 700.0), 0.56, 1.0)
    for f, amp in ((64.0, 0.9), (97.0, 0.7), (131.0, 0.5)):
        place(buf, ma.ks_pluck(f * rng.uniform(0.97, 1.03), 0.6, rng, damp=0.965, bright=0.5),
              0.56, amp)
    place(buf, thump(115.0, 42.0, 0.16), 0.56, 0.9)
    n_deb = ma.samples(0.95)
    debris = ma.swept_bandpass(ma.pink(n_deb, rng), np.linspace(2400.0, 550.0, n_deb),
                               octaves=1.4, block=1024)
    place(buf, debris * ma.exp_decay(n_deb, 0.3), 0.62, 0.4)
    for _ in range(5):  # falling twig ticks
        at = rng.uniform(0.7, 1.4)
        place(buf, ma.ks_pluck(rng.uniform(190.0, 520.0), 0.09, rng, damp=0.88, bright=0.7),
              at, rng.uniform(0.08, 0.18))
    return buf


def stone_break(rng: np.random.Generator) -> np.ndarray:
    buf = silence(1.35)
    place(buf, thump(105.0, 36.0, 0.22), 0.0, 0.95)
    n_crunch = ma.samples(0.5)
    crunch = ma.fft_filter(ma.pink(n_crunch, rng), fc_low=250.0, fc_high=2100.0)
    bursts = 0.4 + 0.6 * np.abs(ma.slow_noise(n_crunch, 22.0, rng))
    place(buf, crunch * bursts * ma.exp_decay(n_crunch, 0.22), 0.01, 0.6)
    for _ in range(8):  # rubble scatter
        at = rng.uniform(0.12, 1.0)
        dur = rng.uniform(0.008, 0.02)
        tap = ma.fft_filter(ma.white(ma.samples(dur), rng),
                            fc_low=300.0, fc_high=rng.uniform(1200.0, 3500.0))
        place(buf, ma.fade_edges(tap, 0.002), at, rng.uniform(0.12, 0.3))
    return buf


def melee_whoosh(rng: np.random.Generator) -> np.ndarray:
    n = ma.samples(0.26)
    centers = np.interp(np.linspace(0, 1, n), [0.0, 0.55, 1.0], [350.0, 1650.0, 480.0])
    sig = ma.swept_bandpass(ma.white(n, rng), centers, octaves=1.0, block=1024)
    arch = np.sin(np.pi * np.linspace(0, 1, n)) ** 1.6
    return sig * arch


def melee_hit(rng: np.random.Generator) -> np.ndarray:
    buf = silence(0.18)
    place(buf, thump(92.0, 48.0, 0.08), 0.0, 1.0)
    place(buf, click(rng, 0.002, 900.0), 0.0, 0.5)
    smack = ma.fft_filter(ma.pink(ma.samples(0.09), rng), fc_high=950.0)
    place(buf, smack * ma.exp_decay(ma.samples(0.09), 0.035), 0.001, 0.45)
    return buf


def footstep_mud(rng: np.random.Generator) -> np.ndarray:
    buf = silence(0.24)
    n = ma.samples(0.15)
    centers = np.interp(np.linspace(0, 1, n), [0, 1], [2600.0, 320.0])
    squelch = ma.swept_bandpass(ma.white(n, rng), centers, octaves=1.3, block=512)
    squelch *= 0.5 + 0.5 * np.abs(ma.slow_noise(n, 28.0, rng))
    place(buf, squelch * ma.env_asr(n, 0.004, 0.06), 0.004, 0.5)
    place(buf, thump(88.0, 55.0, 0.045), 0.0, 0.4)
    for _ in range(4):  # wet ticks
        at = rng.uniform(0.01, 0.11)
        tick = click(rng, rng.uniform(0.001, 0.003), 3200.0)
        place(buf, tick, at, rng.uniform(0.1, 0.22))
    return buf


def item_pickup(rng: np.random.Generator) -> np.ndarray:
    buf = silence(0.5)
    place(buf, ma.ks_pluck(ma.note_hz("D5"), 0.35, rng, damp=0.997, bright=0.8), 0.0, 0.55)
    place(buf, ma.ks_pluck(ma.note_hz("A5"), 0.38, rng, damp=0.997, bright=0.8), 0.07, 0.5)
    place(buf, ma.fm_bell(ma.note_hz("A6"), 0.4, rng), 0.07, 0.12)
    return buf


def chest_open(rng: np.random.Generator) -> np.ndarray:
    buf = silence(1.15)
    creak = ma.burst_train(0.45, 11.0, 48.0, rng)
    creak = ma.swept_bandpass(creak, np.linspace(480.0, 1350.0, creak.shape[0]),
                              octaves=0.7, block=1024)
    place(buf, creak * np.linspace(0.3, 0.8, creak.shape[0]), 0.0, 0.5)
    place(buf, click(rng, 0.004, 1100.0), 0.5, 0.65)
    place(buf, ma.ks_pluck(240.0, 0.12, rng, damp=0.9, bright=0.6), 0.5, 0.5)
    # the jackpot sparkle — Dorian arp, a little over the top on purpose
    for i, note in enumerate(("D6", "E6", "A6", "B6")):
        place(buf, ma.fm_bell(ma.note_hz(note), 0.6, rng), 0.56 + 0.065 * i,
              0.32 - 0.05 * i)
    glow = (ma.sine(ma.note_hz("D5"), 0.5) + ma.sine(ma.note_hz("A5"), 0.5)) * 0.5
    place(buf, glow * ma.env_asr(ma.samples(0.5), 0.12, 0.3), 0.56, 0.12)
    return buf


def ui_click(rng: np.random.Generator) -> np.ndarray:
    buf = silence(0.07)
    ping = ma.sine(1380.0, 0.03) * ma.exp_decay(ma.samples(0.03), 0.008)
    place(buf, ping, 0.0, 0.4)
    place(buf, click(rng, 0.0015, 2800.0), 0.0, 0.3)
    return buf


def build_place(rng: np.random.Generator) -> np.ndarray:
    buf = silence(0.45)
    place(buf, ma.ks_pluck(140.0, 0.3, rng, damp=0.95, bright=0.5), 0.0, 0.8)
    place(buf, thump(85.0, 58.0, 0.06), 0.0, 0.6)
    place(buf, click(rng), 0.0, 0.4)
    pip = ma.sine(ma.note_hz("A4"), 0.07) * ma.env_asr(ma.samples(0.07), 0.01, 0.04)
    place(buf, pip, 0.13, 0.18)
    return buf


# name -> (recipe, n_variants, reverb send linear, peak_db)
RECIPES: dict[str, tuple] = {
    "axe_hit_wood": (axe_hit_wood, 3, 0.10, -3.0),
    "pick_hit_stone": (pick_hit_stone, 3, 0.10, -3.0),
    "tree_break": (tree_break, 1, 0.16, -2.5),
    "stone_break": (stone_break, 1, 0.14, -2.5),
    "melee_whoosh": (melee_whoosh, 2, 0.05, -4.0),
    "melee_hit": (melee_hit, 2, 0.08, -3.0),
    "footstep_mud": (footstep_mud, 3, 0.05, -6.0),
    "item_pickup": (item_pickup, 1, 0.12, -5.0),
    "chest_open": (chest_open, 1, 0.15, -3.5),
    "ui_click": (ui_click, 1, 0.0, -8.0),
    "build_place": (build_place, 1, 0.10, -4.0),
}

SEED_BASE = 118000


def main() -> None:
    repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    parser = argparse.ArgumentParser()
    parser.add_argument("--sfx-dir", default=os.path.join(repo, "assets", "audio", "sfx"))
    parser.add_argument("--build-dir", default=os.path.join(tempfile.gettempdir(), "mire_audio_build"))
    args = parser.parse_args()
    os.makedirs(args.sfx_dir, exist_ok=True)
    os.makedirs(args.build_dir, exist_ok=True)

    ir_rng = np.random.default_rng(5)
    ir = ma.make_ir(0.5, ir_rng, tau_s=0.09, predelay_s=0.012, hf_ratio=0.5, stereo=False)[0]
    dither_rng = np.random.default_rng(11)

    reel: list[np.ndarray] = []
    reel_names: list[str] = []
    for idx, (name, (fn, variants, wet, peak_db)) in enumerate(RECIPES.items()):
        for v in range(variants):
            rng = np.random.default_rng(SEED_BASE + idx * 17 + v)
            sig = fn(rng)
            if wet > 0:
                verb = ma.convolve_fft(sig, ir)[: sig.shape[0] + ir.shape[0]]
                mixed = np.zeros(verb.shape[0])
                mixed[: sig.shape[0]] = sig
                sig = mixed + wet * verb
            sig = sig - np.mean(sig)
            peak = np.max(np.abs(sig))
            if peak > 0:
                sig *= ma.db(peak_db) / peak
            sig = ma.fade_edges(sig, 0.003)
            fname = f"{name}_{v + 1:02d}.wav" if variants > 1 else f"{name}.wav"
            ma.write_wav(os.path.join(args.sfx_dir, fname), sig, dither_rng)
            print(f"{fname}: {sig.shape[0] / ma.SR:.2f}s  peak {peak_db:.1f} dBFS  "
                  f"rms {ma.rms_db(sig):.1f} dBFS")
            reel.append(sig)
            reel_names.append(fname)

    gap = np.zeros(ma.samples(0.8))
    reel_sig = np.concatenate([np.concatenate([s, gap]) for s in reel])
    reel_wav = os.path.join(args.build_dir, "sfx_preview_reel.wav")
    ma.write_wav(reel_wav, reel_sig, dither_rng)
    import subprocess
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", reel_wav,
                    "-c:a", "libmp3lame", "-q:a", "2",
                    os.path.join(args.build_dir, "sfx_preview_reel.mp3")], check=True)
    print("reel order:", ", ".join(reel_names))


if __name__ == "__main__":
    main()
