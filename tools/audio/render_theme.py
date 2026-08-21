#!/usr/bin/env python3
"""Render MIRE theme-song candidates. Deterministic (fixed seeds).

    python3 tools/audio/render_theme.py [--only NAME] [--build-dir DIR]
    python3 tools/audio/render_theme.py --ship menu_theme=hollowmere_hymn ...

Five candidates in five different styles, all built from the same synthesis
toolkit as the rest of MIRE's audio (D-066: the score IS the asset). They are
written to the build dir as WAV + MP3 for auditioning; nothing lands in
`assets/audio/music/` until `--ship <asset>=<candidate>` promotes one. Choosing
between them is a taste call, so the render step and the ship step are
deliberately separate — and a candidate is promoted under the ASSET name for
the role it won, not under its own working title, so the role mapping lives in
one place (`ThemeMusicDirector.CUE_PATHS`) rather than being implied by a
filename.

== What makes them one game, and what makes them different ==

All five sit in the same modal world as the ambience — D Dorian (the day
track's home) or A Aeolian (the night track's) — and all five reuse the
ambience's pad/pluck/bell voices somewhere, so whichever wins still sounds
like Hollowmere. What varies is the *instrument that carries the tune* and
whether there is a pulse at all:

  hollowmere_hymn   folk lament       bowed viol over a dulcimer ostinato
  the_long_sink     dark cinematic    low horns, sub swells, the bII dread chord
  mire_rites        percussive 6/8    frame drums, bone flute, chanted choir
  still_water       eerie minimal     music box through tape warble, no pulse
  wake_the_deep     heroic adventure  horns + strings + choir, full arrangement

`hollowmere_hymn` and `still_water` share a melody on purpose — the second is
the first heard through the wrong end of the mire — so picking either one
leaves the other available as its diegetic/late-game variant.

Percussion appears in three of these. That does not contradict AUDIO.md's
no-percussion rule: that rule is about *ambience*, which must not impose a
tempo on a procedurally-paced world. A menu theme has no world to pace.
"""

from __future__ import annotations

import argparse
import os
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


# ---------------------------------------------------------------------------
# score helpers
# ---------------------------------------------------------------------------

def line(notes, start_s: float, beat_s: float, legato: float = 1.0):
    """[(note|None, beats)] -> [(note, at_s, dur_s)] laid end to end.

    `legato` scales the sounding length against the rhythmic length: 1.0 is
    fully joined, 0.6 leaves air between notes. Rests are `None` and simply
    advance the clock."""
    out = []
    t = start_s
    for name, beats in notes:
        dur = beats * beat_s
        if name is not None:
            out.append((name, t, dur * legato))
        t += dur
    return out


def beats_of(notes) -> float:
    return sum(b for _, b in notes)


def pulse(start_s: float, bars: int, beat_s: float, beats_per_bar: float, hits):
    """Repeat a within-bar hit pattern over `bars` bars.
    `hits` is [(beat_offset, gain_db)] -> yields (at_s, gain_db)."""
    for bar in range(bars):
        bar_t = start_s + bar * beats_per_bar * beat_s
        for offset, gain in hits:
            yield bar_t + offset * beat_s, gain


def arp(pattern, start_s: float, bars: int, beat_s: float, step_beats: float):
    """Cycle a note pattern as a steady ostinato. -> [(note, at_s)]"""
    out = []
    t = start_s
    total = int(round(bars * (1.0 / step_beats) * 4))
    for i in range(total):
        name = pattern[i % len(pattern)]
        if name is not None:
            out.append((name, t))
        t += step_beats * beat_s
    return out


def finish(mix: ma.Mix, ir, wet_db: float, name: str, rms_target: float,
           peak_db: float = -1.4) -> np.ndarray:
    """Render, fold the seam, master.

    Themes loop. A menu is somewhere a player can sit for minutes, and a track
    that stops dead and restarts is worse than no track — so these are rendered
    circularly like the ambient beds (`wrap_loop`): everything past the composed
    length, which is entirely reverb and instrument decay, is added back onto
    the head. That is also why every theme resolves onto its tonic and opens
    sparse: the coda's decay becomes the intro's air, and the join disappears.
    """
    loop_s = mix.n / ma.SR
    looped = ma.wrap_loop(mix.render(ir, wet_db=wet_db), loop_s)
    out = ma.master(looped, peak_db=peak_db)
    rms = ma.rms_db(out)
    if rms > rms_target:
        out *= ma.db(rms_target - rms)
    seam = float(np.max(np.abs(out[:, 0] - out[:, -1])))
    print(f"  {name}: {out.shape[1] / ma.SR:6.1f}s loop, peak "
          f"{20 * np.log10(np.max(np.abs(out))):5.1f} dBFS  rms {ma.rms_db(out):5.1f} dBFS  "
          f"seam {seam:.4f}")
    return out


# ---------------------------------------------------------------------------
# the shared tune (hymn / still_water)
# ---------------------------------------------------------------------------

# D Dorian. The B natural in phrase 3 is the whole point — it is what stops
# this being D minor, and it is the same brightness the day ambience trades on.
HYMN_A = [("D4", 1), ("F4", 1), ("G4", 2), ("A4", 3), ("G4", 1),
          ("F4", 1), ("E4", 1), ("D4", 4), (None, 2)]
HYMN_B = [("A4", 1.5), ("C5", 1.5), ("D5", 3), ("C5", 1), ("A4", 1),
          ("G4", 1), ("F4", 1), ("E4", 4), (None, 2)]
HYMN_C = [("F4", 1), ("G4", 1), ("A4", 1), ("C5", 1), ("D5", 3), ("E5", 1),
          ("D5", 1), ("C5", 1), ("B4", 1), ("A4", 4), (None, 1)]
HYMN_D = [("D4", 1), ("F4", 1), ("A4", 2), ("C5", 2), ("A4", 2), ("G4", 1),
          ("F4", 1), ("E4", 1), ("D4", 4), (None, 1)]
HYMN = HYMN_A + HYMN_B + HYMN_C + HYMN_D  # 64 beats


def shift_octave(name: str, delta: int) -> str:
    """'Bb3' + 1 -> 'Bb4'. Note names here are always letter[+accidental]+octave."""
    return name[:-1] + str(int(name[-1]) + delta)


def up_octave(notes):
    return [(None if n is None else shift_octave(n, 1), b) for n, b in notes]


# ---------------------------------------------------------------------------
# 1. hollowmere_hymn — folk lament
# ---------------------------------------------------------------------------

def hollowmere_hymn() -> np.ndarray:
    """Bowed viol carries the tune over a hammered-dulcimer ostinato and a D
    pedal. A frame drum walks in for the second statement and leaves before the
    end — the only thing resembling a beat, and it never becomes a groove."""
    rng = np.random.default_rng(4210_001)
    beat = 0.62
    bar = 4 * beat
    intro_bars, stmt_beats = 4, beats_of(HYMN)
    stmt_s = stmt_beats * beat
    t_a = intro_bars * bar
    t_b = t_a + stmt_s
    total = t_b + stmt_s + 12.0
    ir = ma.make_ir(6.0, rng, tau_s=1.15, hf_ratio=0.42)
    mix = ma.Mix(total, tail_s=8.0)

    # -- D pedal, the still surface (same trick as the ambience)
    n_bed = ma.samples(total)
    for note, gain in (("D2", -17.0), ("A2", -24.0)):
        tone = ma.additive_pad(ma.note_hz(note), total, rng, detune_cents=2.5,
                               shimmer=0.2, darkness=0.35)
        tone *= 1.0 + 0.2 * ma.slow_noise(n_bed, 0.07, rng)
        mix.add(tone * ma.env_asr(n_bed, 3.0, 9.0), 0.0, gain_db=gain, send_db=gain - 12.0)

    # -- dulcimer ostinato: a rolling D-minor figure in eighths, all the way through
    ost = ["D3", "A3", "D4", "F4", "A3", "F4", "D4", "A3"]
    for name, at in arp(ost, 0.0, intro_bars + 2 * int(stmt_beats / 4) + 2, beat, 0.5):
        if at > total - 1.0:
            break
        # thin the ostinato out under the final statement so the tune wins
        gain = -22.0 if at < t_b else -26.0
        mix.add(mv.dulcimer(ma.note_hz(name), 1.4, rng, courses=2, spread_cents=6.0),
                at + rng.uniform(-0.012, 0.012), gain_db=gain + rng.uniform(-2.0, 1.5),
                pan=rng.uniform(-0.4, 0.4), send_db=gain - 6.0)

    # -- harmony pads, one chord per 4 bars: Dm - C - F - Dm, twice per statement
    chords = [["D3", "F3", "A3"], ["C3", "E3", "G3"], ["F3", "A3", "C4"], ["D3", "F3", "A3"],
              ["D3", "G3", "B3"], ["C3", "E3", "A3"], ["F3", "A3", "D4"], ["D3", "F3", "A3"]]
    for stmt_start in (t_a, t_b):
        for i, chord in enumerate(chords):
            at = stmt_start + i * 8 * beat
            for note in chord:
                sig = ma.additive_pad(ma.note_hz(note), 8 * beat + 4.0, rng, darkness=0.2)
                sig *= ma.env_asr(ma.samples(8 * beat + 4.0), 1.6, 3.2)
                mix.add(sig, at, gain_db=-25.0 + rng.uniform(-1.0, 1.0),
                        pan=rng.uniform(-0.3, 0.3), send_db=-30.0)

    # -- statement 1: solo viol, bare
    for name, at, dur in line(HYMN, t_a, beat, legato=0.94):
        mix.add(mv.bowed(ma.note_hz(name), dur + 0.5, rng, bright=0.85,
                         attack_s=min(0.13, dur * 0.3), release_s=0.45),
                at, gain_db=-13.0 + rng.uniform(-1.2, 0.8), pan=-0.12, send_db=-17.0)

    # -- statement 2: viol an octave up, choir underneath, frame drum walking
    for name, at, dur in line(up_octave(HYMN), t_b, beat, legato=0.92):
        mix.add(mv.bowed(ma.note_hz(name), dur + 0.5, rng, bright=0.7,
                         attack_s=min(0.16, dur * 0.3), release_s=0.5),
                at, gain_db=-15.0 + rng.uniform(-1.2, 0.8), pan=0.14, send_db=-18.0)
        mix.add(mv.bowed(ma.note_hz(shift_octave(name, -1)),
                         dur + 0.4, rng, bright=0.5, attack_s=0.18, release_s=0.45),
                at + 0.02, gain_db=-22.0, pan=-0.2, send_db=-26.0)

    for i, chord in enumerate(chords):
        at = t_b + i * 8 * beat
        for note in chord:
            mix.add(mv.choir(ma.note_hz(note), 8 * beat + 2.0, rng, vowel="oo", voices=3),
                    at, gain_db=-27.0, pan=rng.uniform(-0.35, 0.35), send_db=-29.0)

    # frame drum: heartbeat, in for the middle half of statement 2 only
    drum_bars = 12
    for at, gain in pulse(t_b + 4 * bar, drum_bars, beat, 4.0, [(0.0, -20.0), (2.5, -26.0)]):
        mix.add(mv.membrane(78.0, 52.0, 0.9, rng, skin=0.3, fc=1600.0),
                at + rng.uniform(-0.02, 0.02), gain_db=gain + rng.uniform(-1.5, 1.5),
                pan=rng.uniform(-0.15, 0.15), send_db=gain - 10.0)

    # -- outro: the first phrase again, alone, letting the pedal take it
    for name, at, dur in line(HYMN_A, t_b + stmt_s + 1.2, beat * 1.25, legato=0.9):
        mix.add(mv.bowed(ma.note_hz(name), dur + 0.7, rng, bright=0.6,
                         attack_s=0.2, release_s=0.7),
                at, gain_db=-17.0, pan=0.0, send_db=-19.0)
    for i, note in enumerate(("D6", "A5", "F5")):
        mix.add(ma.fm_bell(ma.note_hz(note), 5.0, rng),
                t_b + stmt_s + 5.0 + i * 2.3, gain_db=-28.0,
                pan=rng.uniform(-0.5, 0.5), send_db=-26.0)

    # -- wind bed, quiet, so the theme shares air with the world it opens onto
    centers = 340.0 * 2.0 ** (ma.slow_noise(n_bed, 0.05, rng) * 0.45)
    bed = ma.swept_bandpass(ma.pink(n_bed, rng), centers, octaves=1.6, block=4096)
    mix.add(bed * ma.env_asr(n_bed, 4.0, 8.0), 0.0, gain_db=-31.0, send_db=-38.0)

    return finish(mix, ir, -7.0, "hollowmere_hymn", -18.0)


# ---------------------------------------------------------------------------
# 2. the_long_sink — dark cinematic
# ---------------------------------------------------------------------------

def the_long_sink() -> np.ndarray:
    """A Aeolian with the night track's bII. Slow horn swells over sub, taiko
    at the structural joints only, and a choir that arrives once and leaves.
    No tune to hum — this is the trailer/act-title register, not the menu's."""
    rng = np.random.default_rng(4210_002)
    total = 104.0
    ir = ma.make_ir(9.0, rng, tau_s=1.9, hf_ratio=0.28)
    mix = ma.Mix(total, tail_s=11.0)
    n_bed = ma.samples(total)

    # -- A pedal + rumble
    for note, gain in (("A1", -19.0), ("A2", -23.0), ("E3", -30.0)):
        tone = ma.additive_pad(ma.note_hz(note), total, rng, detune_cents=2.0,
                               shimmer=0.15, darkness=0.55)
        tone *= 1.0 + 0.3 * ma.slow_noise(n_bed, 0.05, rng)
        mix.add(tone * ma.env_asr(n_bed, 6.0, 12.0), 0.0, gain_db=gain, send_db=gain - 10.0)
    rum = ma.fft_filter(ma.pink(n_bed, rng), fc_high=70.0, order=3)
    rum *= 1.0 + 0.6 * ma.slow_noise(n_bed, 0.04, rng)
    mix.add(rum * ma.env_asr(n_bed, 5.0, 10.0), 0.0, gain_db=-30.0)

    # -- four sections; section 3 is Bb major over the A pedal, the dread chord
    sections = [
        (0.0, ["A2", "C3", "E3"], "am"),
        (26.0, ["A2", "C3", "F3"], "f"),
        (52.0, ["Bb2", "D3", "F3"], "bb"),   # bII — the cold stare
        (78.0, ["A2", "C3", "E3"], "am"),
    ]
    for at, chord, tag in sections:
        for note in chord:
            dur = 26.0 + 6.0
            sig = mv.glass_pad(ma.note_hz(note), dur, rng, attack_s=5.0, release_s=7.0)
            mix.add(sig, at, gain_db=-26.0 + rng.uniform(-1.5, 1.5),
                    pan=rng.uniform(-0.4, 0.4), send_db=-27.0)
        # sub swell per section, rooted a fifth under the chord
        root = {"am": "A1", "f": "F1", "bb": "Bb1"}[tag]
        sub_dur = 16.0
        mix.add(ma.sine(ma.note_hz(root), sub_dur)
                * ma.env_asr(ma.samples(sub_dur), 5.5, 8.0), at + 1.5, gain_db=-20.0)

    # -- the motif: a four-note fall, on horns, once per section, lower each time
    motif = [("A3", 4), ("G3", 3), ("F3", 3), ("E3", 6)]
    for i, (at, _, _) in enumerate(sections):
        beat = 1.35
        oct_shift = 0 if i < 2 else -1
        for name, t, dur in line(motif, at + 8.0, beat, legato=0.95):
            hz = ma.note_hz(name) * (0.5 ** -oct_shift if oct_shift else 1.0)
            mix.add(mv.horn(hz, dur + 0.8, rng, index=2.6 + 0.5 * i,
                            attack_s=0.55, release_s=0.9, growl=0.05 * i),
                    t, gain_db=-17.0 + rng.uniform(-1.0, 1.0),
                    pan=rng.uniform(-0.2, 0.2), send_db=-19.0)
            # low string doubling a fifth under, so the fall has floor
            mix.add(mv.bowed(hz * 0.5, dur + 0.6, rng, bright=0.4,
                             attack_s=0.7, release_s=0.9, vib_cents=6.0),
                    t + 0.05, gain_db=-23.0, pan=-0.25, send_db=-27.0)

    # -- taiko at the joints only: entry, the bII, and the collapse
    for at, gain in ((25.4, -13.0), (51.4, -11.0), (52.0, -15.0),
                     (77.4, -12.0), (78.0, -16.0), (95.0, -18.0)):
        mix.add(mv.membrane(58.0, 34.0, 2.2, rng, skin=0.22, modes=0.35,
                            fc=900.0, tau_ratio=0.22),
                at, gain_db=gain, pan=rng.uniform(-0.1, 0.1), send_db=gain - 8.0)

    # -- choir arrives on the dread chord and nowhere else
    for note in ("Bb3", "D4", "F4"):
        mix.add(mv.choir(ma.note_hz(note), 22.0, rng, vowel="mm", voices=4,
                         attack_s=5.0, release_s=9.0),
                53.0, gain_db=-25.0, pan=rng.uniform(-0.4, 0.4), send_db=-25.0)
    # bells strike its #11 — same dissonance the night ambience uses
    for i, note in enumerate(("E6", "E5", "Bb5")):
        mix.add(ma.fm_bell(ma.note_hz(note), 6.0, rng, ratio=1.41, index=3.0),
                56.0 + i * 3.1, gain_db=-27.0, pan=rng.uniform(-0.5, 0.5), send_db=-24.0)

    # -- three groans crossing the whole piece
    for at, f0, f1 in ((18.0, 54.0, 38.0), (63.0, 61.0, 42.0), (88.0, 48.0, 33.0)):
        mix.add(ma.fm_groan(f0, f1, 9.0, rng), at, gain_db=-24.0,
                pan=rng.uniform(-0.35, 0.35), send_db=-26.0)

    # -- last 8 s: everything gone but sub and one bell
    mix.add(ma.sine(ma.note_hz("A1"), 12.0) * ma.env_asr(ma.samples(12.0), 3.0, 7.0),
            94.0, gain_db=-21.0)
    mix.add(ma.fm_bell(ma.note_hz("A5"), 7.0, rng), 97.0, gain_db=-25.0, send_db=-21.0)

    wind = ma.swept_bandpass(ma.pink(n_bed, rng),
                             165.0 * 2.0 ** (ma.slow_noise(n_bed, 0.04, rng) * 0.4),
                             octaves=1.2, block=4096)
    mix.add(wind * ma.env_asr(n_bed, 6.0, 10.0), 0.0, gain_db=-29.0, send_db=-36.0)

    return finish(mix, ir, -6.0, "the_long_sink", -20.0)


# ---------------------------------------------------------------------------
# 3. mire_rites — percussive 6/8
# ---------------------------------------------------------------------------

def mire_rites() -> np.ndarray:
    """Drums first, everything else earns its way in. 6/8 at a walking pulse,
    D Dorian, four eight-bar stages: drums / +ostinato / +flute / +choir, then
    a hard stop that leaves the room ringing. This is the run-start energy."""
    rng = np.random.default_rng(4210_003)
    beat = 0.34          # eighth note
    bar = 6 * beat       # 6/8
    stage = 8 * bar
    total = 4 * stage + 6.0
    ir = ma.make_ir(5.0, rng, tau_s=0.85, hf_ratio=0.45)
    mix = ma.Mix(total, tail_s=6.0)
    n_bed = ma.samples(total)

    # -- pedal, quiet, under everything
    for note, gain in (("D2", -22.0), ("A2", -28.0)):
        tone = ma.additive_pad(ma.note_hz(note), total, rng, detune_cents=2.0,
                               shimmer=0.15, darkness=0.4)
        mix.add(tone * ma.env_asr(n_bed, 2.0, 5.0), 0.0, gain_db=gain, send_db=gain - 12.0)

    # -- frame drum: the 6/8 spine, present from bar 1, all four stages
    frame_hits = [(0.0, -17.0), (1.0, -27.0), (2.0, -24.0),
                  (3.0, -19.0), (4.0, -27.0), (5.0, -24.0)]
    for at, gain in pulse(0.0, 32, beat, 6.0, frame_hits):
        f0 = 86.0 if gain < -22.0 else 74.0
        mix.add(mv.membrane(f0, f0 * 0.65, 0.55, rng, skin=0.4, fc=2400.0),
                at + rng.uniform(-0.012, 0.012), gain_db=gain + rng.uniform(-1.5, 1.5),
                pan=rng.uniform(-0.2, 0.2), send_db=gain - 12.0)

    # -- shaker sixteenths from stage 2, log drum accents from stage 3
    for at, gain in pulse(stage, 24, beat, 6.0, [(o / 2.0, -30.0) for o in range(12)]):
        mix.add(mv.shaker(0.07, rng, sharp=0.016),
                at + rng.uniform(-0.008, 0.008), gain_db=gain + rng.uniform(-3.0, 2.0),
                pan=rng.uniform(-0.5, 0.5))
    for at, gain in pulse(2 * stage, 16, beat, 6.0, [(1.5, -23.0), (4.5, -21.0)]):
        mix.add(mv.log_drum(rng.choice([196.0, 262.0, 294.0]), 0.35, rng),
                at + rng.uniform(-0.015, 0.015), gain_db=gain + rng.uniform(-2.0, 1.0),
                pan=rng.uniform(-0.45, 0.45), send_db=gain - 10.0)

    # -- dulcimer ostinato riff from stage 2: D A D F | E A C A, in eighths
    riff = ["D3", "A3", "D4", "F4", "E4", "A3", "C4", "A3",
            "D3", "A3", "D4", "A4", "G4", "F4", "E4", "D4"]
    t = stage
    i = 0
    while t < 4 * stage - bar:
        name = riff[i % len(riff)]
        gain = -24.0 if t < 2 * stage else -21.0
        mix.add(mv.dulcimer(ma.note_hz(name), 1.0, rng, courses=2, damp=0.994),
                t + rng.uniform(-0.01, 0.01), gain_db=gain + rng.uniform(-2.0, 1.5),
                pan=rng.uniform(-0.35, 0.35), send_db=gain - 8.0)
        t += beat
        i += 1

    # -- bone flute melody from stage 3 — a modal call, phrased across the bar line
    tune = [("D5", 3), ("F5", 2), ("E5", 1), ("D5", 3), ("C5", 3), (None, 2),
            ("A4", 2), ("C5", 2), ("D5", 4), ("E5", 2), ("D5", 4), (None, 2),
            ("F5", 2), ("E5", 1), ("D5", 3), ("C5", 2), ("A4", 4), (None, 2),
            ("A4", 1), ("C5", 1), ("D5", 4), ("E5", 4), ("D5", 6)]
    for name, at, dur in line(tune, 2 * stage + bar, beat, legato=0.9):
        mix.add(mv.flute(ma.note_hz(name), dur + 0.35, rng, breath=0.26,
                         attack_s=min(0.06, dur * 0.35), release_s=0.22),
                at, gain_db=-16.0 + rng.uniform(-1.5, 1.0),
                pan=rng.uniform(-0.15, 0.15), send_db=-19.0)

    # -- choir on the stage-4 downbeats: short, chanted, not sustained
    for b, chord in enumerate((("D4", "A4"), ("F4", "C5"), ("D4", "A4"), ("E4", "B4"),
                               ("D4", "A4"), ("F4", "C5"), ("G4", "D5"), ("D4", "A4"))):
        at = 3 * stage + b * bar
        for note in chord:
            mix.add(mv.choir(ma.note_hz(note), 1.15, rng, vowel="ah", voices=3,
                             attack_s=0.06, release_s=0.5),
                    at, gain_db=-22.0, pan=rng.uniform(-0.35, 0.35), send_db=-24.0)

    # -- the stop: one last full hit, then only the room
    end = 4 * stage
    mix.add(mv.membrane(62.0, 38.0, 2.0, rng, skin=0.3, fc=1400.0, tau_ratio=0.2),
            end, gain_db=-11.0, send_db=-16.0)
    for note in ("D3", "A3", "D4", "F4"):
        mix.add(mv.dulcimer(ma.note_hz(note), 3.0, rng, courses=3, damp=0.9985),
                end, gain_db=-19.0, pan=rng.uniform(-0.4, 0.4), send_db=-20.0)
    mix.add(ma.fm_bell(ma.note_hz("D6"), 5.0, rng), end + 0.1, gain_db=-25.0, send_db=-21.0)

    return finish(mix, ir, -9.0, "mire_rites", -17.0)


# ---------------------------------------------------------------------------
# 4. still_water — eerie minimal
# ---------------------------------------------------------------------------

def still_water() -> np.ndarray:
    """The hymn's tune on a music box, at half speed, through tape warble, with
    two thirds of the notes missing. No pulse, no melody instrument, nothing
    that sounds played by a person. The quietest of the five by design — a menu
    you can leave running."""
    rng = np.random.default_rng(4210_004)
    beat = 1.05
    total = 92.0
    ir = ma.make_ir(8.0, rng, tau_s=2.3, hf_ratio=0.3)
    mix = ma.Mix(total, tail_s=10.0)
    n_bed = ma.samples(total)

    # -- glass pad chords, very slow: Dm - Fmaj7 - Dm add11 - Bb(!) - Dm
    for at, chord in ((0.0, ("D3", "F3", "A3")),
                      (19.0, ("F3", "A3", "C4", "E4")),
                      (38.0, ("D3", "G3", "A3", "D4")),
                      (57.0, ("Bb2", "D3", "F3", "A3")),
                      (74.0, ("D3", "F3", "A3", "D4"))):
        for note in chord:
            dur = 22.0
            mix.add(mv.glass_pad(ma.note_hz(note), dur, rng, attack_s=4.5, release_s=8.0),
                    at + rng.uniform(-0.6, 0.6), gain_db=-28.0 + rng.uniform(-1.5, 1.5),
                    pan=rng.uniform(-0.5, 0.5), send_db=-26.0)

    # -- the tune, gapped: only phrases A and D, halved in density, on a music box
    def sparse(notes, keep_from: int):
        """Drop every other note after the first few — what is left still
        traces the melody, but the ear has to do the joining."""
        out = []
        for i, (name, b) in enumerate(notes):
            out.append((name if (i < keep_from or i % 2 == 0) else None, b))
        return out

    box_stem = np.zeros(ma.samples(total + 4.0))
    for start, notes in ((6.0, sparse(HYMN_A, 2)), (34.0, sparse(HYMN_D, 2)),
                         (62.0, sparse(HYMN_A, 1))):
        for name, at, dur in line(notes, start, beat, legato=1.0):
            hz = ma.note_hz(name) * 2.0  # a music box lives an octave up
            sig = mv.music_box(hz, min(dur + 1.6, 3.2), rng)
            s = ma.samples(at)
            e = min(s + sig.shape[0], box_stem.shape[0])
            box_stem[s:e] += sig[: e - s] * ma.db(-14.0 + rng.uniform(-2.5, 1.0))
    box_stem = mv.tape_warble(box_stem, rng, cents=9.0, rate_hz=0.55)
    mix.add(box_stem[: ma.samples(total)], 0.0, gain_db=-2.0, pan=-0.08, send_db=-9.0)

    # -- a second music box, a fifth up and a bar behind: the room answering
    echo_stem = np.zeros(ma.samples(total + 4.0))
    for start, notes in ((8.6, sparse(HYMN_A, 1)), (64.6, sparse(HYMN_A, 1))):
        for name, at, dur in line(notes, start, beat, legato=1.0):
            sig = mv.music_box(ma.note_hz(name) * 3.0, 2.4, rng, index=1.0)
            s = ma.samples(at)
            e = min(s + sig.shape[0], echo_stem.shape[0])
            echo_stem[s:e] += sig[: e - s] * ma.db(-22.0)
    echo_stem = mv.tape_warble(echo_stem, rng, cents=14.0, rate_hz=0.4)
    mix.add(echo_stem[: ma.samples(total)], 0.0, gain_db=-4.0, pan=0.34, send_db=-8.0)

    # -- sub breaths, and two groans that never arrive
    for at, root in ((2.0, "D1"), (30.0, "F1"), (56.0, "Bb1"), (76.0, "D1")):
        mix.add(ma.sine(ma.note_hz(root), 15.0) * ma.env_asr(ma.samples(15.0), 5.5, 8.0),
                at, gain_db=-24.0)
    for at, f0, f1 in ((22.0, 49.0, 36.0), (68.0, 55.0, 40.0)):
        mix.add(ma.fm_groan(f0, f1, 8.0, rng), at, gain_db=-27.0,
                pan=rng.uniform(-0.3, 0.3), send_db=-27.0)

    # -- water and a very quiet high wind: the only things that are "outside"
    # Band-limited on both sides and set low: with a mix this sparse an open
    # highpassed noise bed runs all the way to Nyquist and simply reads as hiss
    # (it dragged the measured spectral centroid to ~8 kHz on the first render).
    ripple = 0.55 + 0.45 * ma.slow_noise(n_bed, 6.0, rng)
    water = ma.fft_filter(ma.white(n_bed, rng), fc_low=2400.0, fc_high=7000.0,
                          order=2) * ripple
    mix.add(water * ma.env_asr(n_bed, 5.0, 9.0), 0.0, gain_db=-41.0, pan=0.18)
    wind = ma.swept_bandpass(ma.pink(n_bed, rng),
                             210.0 * 2.0 ** (ma.slow_noise(n_bed, 0.045, rng) * 0.5),
                             octaves=1.4, block=4096)
    mix.add(wind * ma.env_asr(n_bed, 6.0, 10.0), 0.0, gain_db=-33.0, send_db=-38.0)

    return finish(mix, ir, -5.0, "still_water", -23.0)


# ---------------------------------------------------------------------------
# 5. wake_the_deep — heroic adventure
# ---------------------------------------------------------------------------

def wake_the_deep() -> np.ndarray:
    """The big one: an A-B-A theme with horns on the tune, strings doubling,
    choir on the climb, and drums that actually commit. Still D Dorian, still
    minor-leaning — the mire never lets you have a major chord for free."""
    rng = np.random.default_rng(4210_005)
    beat = 0.68
    bar = 4 * beat
    ir = ma.make_ir(7.0, rng, tau_s=1.5, hf_ratio=0.35)

    A1 = [("A3", 1), ("D4", 3), ("E4", 2), ("F4", 2), ("E4", 2), ("D4", 4), (None, 2)]
    A2 = [("A3", 1), ("D4", 3), ("F4", 2), ("G4", 2), ("A4", 4), (None, 1),
          ("G4", 1), ("F4", 2)]
    B1 = [("C5", 2), ("A4", 2), ("G4", 2), ("F4", 2), ("E4", 2), ("D4", 2),
          ("C4", 2), ("D4", 2)]
    B2 = [("A3", 1), ("D4", 3), ("A4", 4), ("F4", 2), ("G4", 2), ("A4", 4)]
    THEME = A1 + A2 + B1 + B2                    # 64 beats
    theme_s = 64 * beat

    intro_s = 6 * bar
    t1 = intro_s                                  # statement 1: strings, medium
    t2 = t1 + theme_s                             # statement 2: full, horns lead
    total = t2 + theme_s + 14.0
    mix = ma.Mix(total, tail_s=9.0)
    n_bed = ma.samples(total)

    # -- pedal
    for note, gain in (("D2", -18.0), ("A2", -25.0), ("D3", -29.0)):
        tone = ma.additive_pad(ma.note_hz(note), total, rng, detune_cents=2.5,
                               shimmer=0.2, darkness=0.3)
        mix.add(tone * ma.env_asr(n_bed, 3.0, 10.0), 0.0, gain_db=gain, send_db=gain - 11.0)

    # -- chord plan, one per 2 bars, repeated for both statements
    plan = [["D3", "F3", "A3"], ["D3", "F3", "A3"], ["F3", "A3", "C4"], ["C3", "E3", "G3"],
            ["G3", "B3", "D4"], ["A3", "C4", "E4"], ["F3", "A3", "C4"], ["D3", "F3", "A3"]]

    def lay_chords(start: float, gain: float, with_choir: bool) -> None:
        for i, chord in enumerate(plan):
            at = start + i * 8 * beat
            dur = 8 * beat + 2.5
            for note in chord:
                sig = mv.bowed(ma.note_hz(note), dur, rng, bright=0.45,
                               attack_s=1.0, release_s=1.8, vib_cents=7.0)
                mix.add(sig, at, gain_db=gain + rng.uniform(-1.5, 1.0),
                        pan=rng.uniform(-0.45, 0.45), send_db=gain - 5.0)
            if with_choir:
                for note in chord:
                    mix.add(mv.choir(ma.note_hz(note) * 2.0, dur, rng, vowel="ah",
                                     voices=3, attack_s=0.9, release_s=2.0),
                            at, gain_db=gain - 6.0, pan=rng.uniform(-0.4, 0.4),
                            send_db=gain - 9.0)

    # -- intro: horn call alone, then drums answer it
    for name, at, dur in line([("D4", 4), (None, 2), ("A3", 2), ("D4", 6), (None, 2)],
                              beat, beat, legato=0.95):
        mix.add(mv.horn(ma.note_hz(name), dur + 0.9, rng, index=2.4,
                        attack_s=0.35, release_s=0.9),
                at, gain_db=-17.0, pan=0.0, send_db=-18.0)
    for at, gain in pulse(intro_s - 2 * bar, 2, beat, 4.0,
                          [(0.0, -16.0), (1.5, -24.0), (2.0, -20.0), (3.0, -22.0), (3.5, -19.0)]):
        mix.add(mv.membrane(70.0, 44.0, 0.8, rng, skin=0.35, fc=2000.0),
                at, gain_db=gain, pan=rng.uniform(-0.2, 0.2), send_db=gain - 10.0)

    # -- statement 1: strings carry it, drums keep a half-time floor
    lay_chords(t1, -26.0, with_choir=False)
    for name, at, dur in line(THEME, t1, beat, legato=0.94):
        mix.add(mv.bowed(ma.note_hz(name), dur + 0.6, rng, bright=0.9,
                         attack_s=min(0.12, dur * 0.3), release_s=0.5),
                at, gain_db=-15.0 + rng.uniform(-1.0, 0.8), pan=-0.1, send_db=-19.0)
    for at, gain in pulse(t1, 16, beat, 4.0, [(0.0, -20.0), (2.0, -25.0)]):
        mix.add(mv.membrane(72.0, 46.0, 1.0, rng, skin=0.3, fc=1700.0),
                at + rng.uniform(-0.015, 0.015), gain_db=gain, pan=0.0, send_db=gain - 11.0)

    # -- statement 2: horns take the tune, strings double an octave down,
    #    choir on the chords, drums commit to a full pattern
    lay_chords(t2, -24.0, with_choir=True)
    for name, at, dur in line(THEME, t2, beat, legato=0.94):
        hz = ma.note_hz(name)
        mix.add(mv.horn(hz, dur + 0.8, rng, index=3.4, attack_s=min(0.12, dur * 0.3),
                        release_s=0.6, growl=0.04),
                at, gain_db=-13.0 + rng.uniform(-1.0, 0.8), pan=0.05, send_db=-18.0)
        mix.add(mv.bowed(hz * 0.5, dur + 0.6, rng, bright=0.5, attack_s=0.14, release_s=0.6),
                at + 0.02, gain_db=-19.0, pan=-0.3, send_db=-24.0)
        mix.add(mv.bowed(hz * 2.0, dur + 0.5, rng, bright=1.0, attack_s=0.1, release_s=0.45),
                at + 0.01, gain_db=-25.0, pan=0.32, send_db=-27.0)
    drum_pattern = [(0.0, -16.0), (1.5, -25.0), (2.0, -20.0), (3.0, -23.0), (3.5, -21.0)]
    for at, gain in pulse(t2, 16, beat, 4.0, drum_pattern):
        f0 = 70.0 if gain > -22.0 else 92.0
        mix.add(mv.membrane(f0, f0 * 0.62, 0.85, rng, skin=0.35, fc=2200.0),
                at + rng.uniform(-0.012, 0.012), gain_db=gain + rng.uniform(-1.5, 1.0),
                pan=rng.uniform(-0.18, 0.18), send_db=gain - 11.0)
    for at, gain in pulse(t2 + 8 * bar, 8, beat, 4.0, [(o / 2.0, -31.0) for o in range(8)]):
        mix.add(mv.shaker(0.06, rng, sharp=0.014), at, gain_db=gain + rng.uniform(-3.0, 2.0),
                pan=rng.uniform(-0.5, 0.5))

    # -- coda: the last four bars held, then everything decays off a single chord
    coda = t2 + theme_s
    for note in ("D3", "A3", "D4", "F4", "A4"):
        mix.add(mv.bowed(ma.note_hz(note), 11.0, rng, bright=0.45,
                         attack_s=0.5, release_s=6.5, vib_cents=8.0),
                coda, gain_db=-22.0, pan=rng.uniform(-0.4, 0.4), send_db=-24.0)
        mix.add(mv.choir(ma.note_hz(note), 11.0, rng, vowel="ah", voices=3,
                         attack_s=1.2, release_s=6.0),
                coda, gain_db=-27.0, pan=rng.uniform(-0.4, 0.4), send_db=-26.0)
    mix.add(mv.membrane(58.0, 33.0, 2.4, rng, skin=0.25, fc=1200.0, tau_ratio=0.22),
            coda, gain_db=-13.0, send_db=-17.0)
    mix.add(mv.horn(ma.note_hz("D4"), 7.0, rng, index=2.2, attack_s=0.8, release_s=4.5),
            coda + 0.2, gain_db=-19.0, send_db=-21.0)
    for i, note in enumerate(("D6", "A5", "F5", "D5")):
        mix.add(ma.fm_bell(ma.note_hz(note), 6.0, rng),
                coda + 3.0 + i * 1.6, gain_db=-28.0,
                pan=rng.uniform(-0.5, 0.5), send_db=-25.0)

    return finish(mix, ir, -8.0, "wake_the_deep", -17.0)


THEMES = {
    "hollowmere_hymn": (hollowmere_hymn, "folk lament — bowed viol over dulcimer, D Dorian"),
    "the_long_sink": (the_long_sink, "dark cinematic — horns, sub, the bII dread chord"),
    "mire_rites": (mire_rites, "percussive 6/8 — frame drums, bone flute, chanted choir"),
    "still_water": (still_water, "eerie minimal — music box through tape warble, no pulse"),
    "wake_the_deep": (wake_the_deep, "heroic adventure — horns + strings + choir, full arrangement"),
}


# ---------------------------------------------------------------------------
# io
# ---------------------------------------------------------------------------

def encode_ogg(wav_path: str, out_path: str) -> None:
    """libsndfile via soundfile, chunked — see render_music.encode for why the
    brew ffmpeg cannot do this and why one big write segfaults."""
    import soundfile as sf
    sig, sr = ma.read_wav(wav_path)
    frames = np.ascontiguousarray(sig.T, dtype=np.float32)
    with sf.SoundFile(out_path, "w", samplerate=sr, channels=frames.shape[1],
                      format="OGG", subtype="VORBIS") as f:
        for i in range(0, frames.shape[0], sr):
            f.write(frames[i:i + sr])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--build-dir",
                        default=os.path.join(tempfile.gettempdir(), "mire_audio_build", "themes"))
    parser.add_argument("--only", default=None, help="render just one candidate")
    parser.add_argument("--ship", nargs="*", default=None,
                        help="promote picks: <asset>=<candidate> [...] into assets/audio/music/")
    args = parser.parse_args()
    os.makedirs(args.build_dir, exist_ok=True)

    if args.ship:
        for pick in args.ship:
            asset, _, candidate = pick.partition("=")
            if candidate not in THEMES:
                raise SystemExit(f"unknown candidate {candidate!r}; have {', '.join(THEMES)}")
            wav = os.path.join(args.build_dir, candidate + ".wav")
            if not os.path.exists(wav):
                raise SystemExit(f"{wav} missing — render first")
            out = os.path.join(REPO, "assets", "audio", "music", asset + ".ogg")
            encode_ogg(wav, out)
            print(f"  {asset}.ogg <- {candidate}")
        return

    dither = np.random.default_rng(23)
    names = [args.only] if args.only else list(THEMES)
    for name in names:
        fn, blurb = THEMES[name]
        print(f"{name} — {blurb}")
        sig = fn()
        wav = os.path.join(args.build_dir, name + ".wav")
        ma.write_wav(wav, sig, dither)
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", wav,
                        "-c:a", "libmp3lame", "-q:a", "2",
                        os.path.join(args.build_dir, name + ".mp3")], check=True)
    print("themes ->", args.build_dir)



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
