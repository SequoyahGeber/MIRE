#!/usr/bin/env python3
"""Render MIRE's ambient music from score data. Deterministic (fixed seeds).

    python3 tools/audio/render_music.py [--build-dir DIR] [--ogg-dir DIR]

Writes master WAVs + listening MP3s to --build-dir (default: a temp dir),
and the game assets (OGG Vorbis, loop-seamless) to --ogg-dir
(default: assets/audio/music/). Requires ffmpeg on PATH for ogg/mp3.

== Musical intent (why the scores look like this) ==

Both tracks are one palette — same pad/pluck/bell voices — so day and night
read as one place. Everything sits over a fixed pedal tone (drone), so the
harmony moves as *color above a still surface*: that is the sound of standing
water. No percussion; MIRE's ambience should never impose a tempo on a
procedurally-paced world.

DAY — "Hollowmere Daylight", D Dorian, 8 sections x 28 s = 3:44 loop.
Dorian is minor with a bright 6th — damp but hopeful, sun through mist.
The pad voicings are hand-set so the top line sings a slow arc:
E - E - F - G - C5(peak) - A - G - F, resolving to E at the loop seam.
Section 5 (Em+C over the D pedal) is the one shadowed moment; F major
warmth answers it. A Karplus-Strong pluck carries a pentatonic-plus-B
motif; rare FM bells glint like light off water.

BOSS STINGER — task 5.5, a non-looping one-shot, not a bed: a low FM groan
rises for under a second, lands on a sub thump the instant a fifth below
NIGHT's own A-minor home (D1), with a dissonant pair of detuned FM bells
struck a beat apart over it — same palette as NIGHT (the FM bell/groan
voices, the one shared reverb IR shape), just compressed into an impact
instead of held over 3:44. The impact itself lands inside the first
~1.1 s; `dur_s` (3.2) plus `tail_s` (4.0) is the full ~7.2 s rendered
file, left to ring out rather than folded back like the looped tracks
(there is nothing to fold a one-shot's tail ONTO). `BossMusicDirector`
(task 5.5) plays this on `EventBus.boss_engaged`/`boss_phase_changed`/
`boss_defeated` — see its own header for why one cue covers all three
rather than three assets.

NIGHT — "Hollowmere Dark", A Aeolian leaning Phrygian, 7 x 32 s = 3:44 loop.
Same voices an octave lower and darker (harmonic rolloff). Sub-root swells
under each section. Section 5 is Bb major over the A pedal — the bII dread
chord, the night's one cold stare — and the bells over it strike the #11.
Sparse low plucks instead of a melody; three far-off FM groans that swell
and never quite arrive. Ends back on Am, seam merges into the head.
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

# tools/audio/render_music.py -> tools/audio -> tools -> repo root -> tools/blender.
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "blender"))
from godot_import_lock import import_cache_guard  # noqa: E402

# ---------------------------------------------------------------------------
# scores
# ---------------------------------------------------------------------------

DAY = {
    "name": "ambient_day",
    "seed": 20260818,
    "section_s": 28.0,
    "sections": [  # pad voicings; common tones merge into held voices
        ["F3", "A3", "C4", "E4"],   # Dm9        sop E
        ["G3", "B3", "D4", "E4"],   # G6 (IV)    sop E
        ["F3", "A3", "C4", "F4"],   # Fmaj7      sop F
        ["F3", "A3", "D4", "G4"],   # Dm add11   sop G
        ["G3", "B3", "E4", "C5"],   # Em+C shade sop C5 (peak)
        ["A3", "C4", "E4", "A4"],   # Am7        sop A
        ["G3", "C4", "D4", "G4"],   # Csus2 air  sop G
        ["F3", "G3", "C4", "F4"],   # Fsus2      sop F -> loops to E
    ],
    "drone": [("D2", -15.0), ("A2", -21.0)],
    "pad": {"gain": -18.0, "send": -25.0, "darkness": 0.12},
    "beat_s": 2.15,
    "phrases": [  # (section_idx, offset_s, gain_db, [(note|None, beats)])
        (1, 6.0, -14.0, [("D5", 1.5), ("C5", 1.0), ("A4", 1.0), ("G4", 1.5), ("E4", 3.0)]),
        (3, 4.0, -15.0, [("G4", 1.0), ("A4", 1.0), ("C5", 1.5), ("D5", 2.5), (None, 1.0),
                         ("C5", 1.0), ("A4", 3.0)]),
        (4, 9.0, -16.0, [("E5", 1.5), ("D5", 1.0), ("C5", 1.5), ("B4", 2.0), ("A4", 3.5)]),
        (6, 5.0, -15.0, [("D5", 1.0), ("E5", 1.5), ("C5", 1.0), ("A4", 2.0), ("G4", 3.0)]),
        (7, 10.0, -16.0, [("A4", 1.0), ("G4", 1.5), ("F4", 1.0), ("E4", 4.0)]),
    ],
    "bells": [  # (section_idx, offset_s, note)
        (1, 2.0, "E6"), (2, 14.0, "A5"), (4, 3.0, "C6"),
        (5, 18.0, "E6"), (6, 2.0, "G5"), (7, 20.0, "D6"),
    ],
    "bell_gain": -27.0,
    "subs": [],
    "groans": [],
    "wind": {"center": 380.0, "spread": 160.0, "octaves": 1.6, "gain": -28.0},
    "water": {"fc": 2800.0, "gain": -38.0},
    "ir": {"dur": 7.0, "tau": 1.05, "hf": 0.4},
    "wet": -7.0,
    "rms_target": -19.0,
}

NIGHT = {
    "name": "ambient_night",
    "seed": 20260819,
    "section_s": 32.0,
    "sections": [
        ["C3", "E3", "G3", "B3"],    # Am add9    sop B3
        ["C3", "F3", "A3", "C4"],    # Fmaj7      sop C4
        ["B2", "D3", "G3", "B3"],    # Em7 murk   sop B3
        ["C3", "E3", "A3", "D4"],    # Am add11   sop D4
        ["Bb2", "D3", "F3", "D4"],   # Bbmaj7 — the bII dread chord
        ["D3", "F3", "A3", "E4"],    # Dm9        sop E4 (peak, then falls)
        ["C3", "E3", "A3", "C4"],    # Am         sop C4 -> loops to B3
    ],
    "drone": [("A2", -16.0), ("E3", -24.0)],
    "pad": {"gain": -17.5, "send": -24.0, "darkness": 0.38},
    "beat_s": 2.6,
    "phrases": [
        (2, 10.0, -17.0, [("E3", 2.0), ("G3", 1.5), ("A3", 4.0)]),
        (5, 12.0, -16.0, [("D4", 1.5), ("C4", 1.0), ("A3", 2.0), ("E3", 4.0)]),
    ],
    "bells": [  # firefly pairs; over section 5 they strike the #11 (E over Bb)
        (1, 6.0, "E6"), (1, 6.8, "B5"), (3, 20.0, "A5"),
        (4, 9.0, "C6"), (4, 9.7, "E6"), (5, 15.0, "A5"),
    ],
    "bell_gain": -29.0,
    "subs": [  # (section_idx, root) — one slow swell per section
        (0, "A1"), (1, "F1"), (2, "E1"), (3, "A1"), (4, "Bb1"), (5, "D1"), (6, "A1"),
    ],
    "sub_gain": -22.0,
    "groans": [  # (section_idx, offset_s, f0, f1)
        (2, 18.0, 52.0, 39.0), (4, 20.0, 58.0, 41.0), (6, 8.0, 47.0, 36.0),
    ],
    "wind": {"center": 170.0, "spread": 60.0, "octaves": 1.2, "gain": -29.0},
    "water": None,
    "rumble": {"fc": 65.0, "gain": -33.0},
    "ir": {"dur": 9.0, "tau": 1.6, "hf": 0.25},
    "wet": -6.0,
    "rms_target": -21.0,
}

BOSS_STINGER = {
    "name": "boss_stinger",
    "seed": 20260819,
    "dur_s": 3.2,
    "tail_s": 4.0,
    "root": "D1",       # a fifth under NIGHT's A-minor home — lands lower than the ambience ever does
    "bell": "A5",
    "hit_at_s": 0.9,
    "rms_target": -14.0,
}

EDGE_S = 8.0  # beds/drone render loop+EDGE with EDGE-long cos edges; wrap_loop folds them


# ---------------------------------------------------------------------------
# engine
# ---------------------------------------------------------------------------

def pad_note_spans(sections: list[list[str]], section_s: float) -> list[tuple[float, float, str]]:
    """Merge common tones across adjacent sections into single held voices —
    real voice-leading, so only the notes that change actually move.

    Iterates newly-wanted notes in sorted order rather than the raw `set`'s
    order: Python randomizes a `set`'s string iteration order per process
    (PYTHONHASHSEED), and `render_track()` draws from a shared seeded `rng`
    once per span in the order `pad_note_spans` returns them — so an
    unsorted `set` here silently made every render's jitter/gain/pan
    non-reproducible despite the fixed seed (F-176)."""
    spans: list[tuple[float, float, str]] = []
    active: dict[str, float] = {}
    t = 0.0
    for notes in sections:
        wanted = set(notes)
        for note in [k for k in active if k not in wanted]:
            spans.append((active.pop(note), t, note))
        for note in sorted(wanted):
            active.setdefault(note, t)
        t += section_s
    for note, start in active.items():
        spans.append((start, t, note))
    return spans


def render_track(cfg: dict) -> np.ndarray:
    rng = np.random.default_rng(cfg["seed"])
    section_s = cfg["section_s"]
    loop_s = section_s * len(cfg["sections"])
    ir = ma.make_ir(cfg["ir"]["dur"], rng, tau_s=cfg["ir"]["tau"], hf_ratio=cfg["ir"]["hf"])
    tail_s = cfg["ir"]["dur"] + 4.0
    mix = ma.Mix(loop_s + EDGE_S, tail_s)

    # -- drone: pedal tone(s), the still surface everything sits over
    n_bed = ma.samples(loop_s + EDGE_S)
    for note, gain in cfg["drone"]:
        tone = ma.additive_pad(ma.note_hz(note), loop_s + EDGE_S, rng,
                               detune_cents=2.5, shimmer=0.2, darkness=0.3)
        tone *= 1.0 + 0.22 * ma.slow_noise(n_bed, 0.07, rng)
        tone *= ma.env_asr(n_bed, EDGE_S, EDGE_S)
        mix.add(tone, 0.0, gain_db=gain, pan=0.0, send_db=gain - 12.0)

    # -- pads: merged voice spans with long crossfading edges
    pad = cfg["pad"]
    for start, end, note in pad_note_spans(cfg["sections"], section_s):
        attack, release = 4.0, 5.5
        dur = (end - start) + release
        sig = ma.additive_pad(ma.note_hz(note), dur, rng, darkness=pad["darkness"])
        sig *= ma.env_asr(ma.samples(dur), attack, release)
        at = start + rng.uniform(-0.4, 0.4) if start > 0 else 0.0
        pan = rng.uniform(-0.35, 0.35)
        mix.add(sig, at, gain_db=pad["gain"] + rng.uniform(-1.0, 1.0),
                pan=pan, send_db=pad["send"])

    # -- motif plucks, quasi-rubato
    for section_idx, offset, gain, notes in cfg["phrases"]:
        t = section_idx * section_s + offset
        pan_side = 1.0 if rng.uniform() > 0.5 else -1.0
        for note, beats in notes:
            dur_beats = beats * cfg["beat_s"] * rng.uniform(0.9, 1.12)
            if note is not None:
                sig = ma.ks_pluck(ma.note_hz(note), min(dur_beats * 2.2, 7.0), rng,
                                  damp=0.9968, bright=0.55)
                mix.add(sig, t + rng.uniform(-0.12, 0.12),
                        gain_db=gain + rng.uniform(-2.0, 1.0),
                        pan=pan_side * rng.uniform(0.1, 0.3), send_db=gain - 4.0)
            t += dur_beats

    # -- bells
    for section_idx, offset, note in cfg["bells"]:
        sig = ma.fm_bell(ma.note_hz(note), 5.0, rng)
        mix.add(sig, section_idx * section_s + offset + rng.uniform(-0.5, 0.5),
                gain_db=cfg["bell_gain"] + rng.uniform(-2.0, 2.0),
                pan=rng.uniform(-0.5, 0.5), send_db=cfg["bell_gain"] - 2.0)

    # -- sub swells (night)
    for section_idx, root in cfg.get("subs", []):
        dur = 14.0
        sig = ma.sine(ma.note_hz(root), dur) * ma.env_asr(ma.samples(dur), 5.0, 7.0)
        mix.add(sig, section_idx * section_s + rng.uniform(0.0, 2.0),
                gain_db=cfg["sub_gain"], pan=0.0)

    # -- groans (night)
    for section_idx, offset, f0, f1 in cfg.get("groans", []):
        sig = ma.fm_groan(f0, f1, 7.0, rng)
        mix.add(sig, section_idx * section_s + offset,
                gain_db=-24.0, pan=rng.uniform(-0.3, 0.3), send_db=-26.0)

    # -- beds
    wind = cfg["wind"]
    centers = wind["center"] * 2.0 ** (ma.slow_noise(n_bed, 0.05, rng)
                                       * wind["spread"] / wind["center"])
    bed = ma.swept_bandpass(ma.pink(n_bed, rng), centers, octaves=wind["octaves"], block=4096)
    bed *= 1.0 + 0.45 * ma.slow_noise(n_bed, 0.06, rng)
    bed *= ma.env_asr(n_bed, EDGE_S, EDGE_S)
    mix.add(bed, 0.0, gain_db=wind["gain"], pan=0.0, send_db=wind["gain"] - 10.0)

    if cfg.get("water"):
        w = cfg["water"]
        ripple = 0.55 + 0.45 * ma.slow_noise(n_bed, 7.0, rng)
        water = ma.fft_filter(ma.white(n_bed, rng), fc_low=w["fc"]) * ripple
        water *= ma.env_asr(n_bed, EDGE_S, EDGE_S)
        mix.add(water, 0.0, gain_db=w["gain"], pan=0.15)

    if cfg.get("rumble"):
        r = cfg["rumble"]
        rum = ma.fft_filter(ma.pink(n_bed, rng), fc_high=r["fc"], order=3)
        rum *= 1.0 + 0.5 * ma.slow_noise(n_bed, 0.04, rng)
        rum *= ma.env_asr(n_bed, EDGE_S, EDGE_S)
        mix.add(rum, 0.0, gain_db=r["gain"], pan=0.0)

    # -- render, fold the seam, master to target loudness
    out = mix.render(ir, wet_db=cfg["wet"])
    looped = ma.wrap_loop(out, loop_s)
    mastered = ma.master(looped, peak_db=-1.5)
    rms = ma.rms_db(mastered)
    if rms > cfg["rms_target"]:
        mastered *= ma.db(cfg["rms_target"] - rms)
    print(f"{cfg['name']}: {loop_s:.0f}s loop, peak {20*np.log10(np.max(np.abs(mastered))):.1f} dBFS, "
          f"rms {ma.rms_db(mastered):.1f} dBFS")
    return mastered


def render_stinger(cfg: dict) -> np.ndarray:
    """One dramatic hit for a boss encounter (task 5.5) — not a bed: no EDGE fold, no wrap_loop,
    just a Mix rendered once with its own reverb tail and mastered louder than the ambience (a
    stinger needs to read as a foreground event, not a texture)."""
    rng = np.random.default_rng(cfg["seed"])
    dur_s = cfg["dur_s"]
    ir = ma.make_ir(4.0, rng, tau_s=1.4, hf_ratio=0.3)
    mix = ma.Mix(dur_s, tail_s=cfg["tail_s"])
    hit_t = cfg["hit_at_s"]

    # the rise into the hit
    groan = ma.fm_groan(50.0, 72.0, hit_t + 0.1, rng, ratio=1.6, index=3.0)
    mix.add(groan, 0.0, gain_db=-9.0, pan=0.0, send_db=-13.0)

    # the hit itself: a sub thump under a dissonant pair of FM bells, one beat apart
    sub_dur = 1.6
    sub = ma.sine(ma.note_hz(cfg["root"]), sub_dur) * ma.exp_decay(ma.samples(sub_dur), 0.35)
    mix.add(sub, hit_t, gain_db=-3.0, pan=0.0, send_db=-9.0)

    bell_hz = ma.note_hz(cfg["bell"])
    bell = ma.fm_bell(bell_hz, 2.2, rng, ratio=1.41, index=3.4)
    mix.add(bell, hit_t, gain_db=-5.0, pan=0.0, send_db=-7.0)
    # a second bell, detuned a minor 7th up and struck slightly later — unresolved, on purpose
    bell2 = ma.fm_bell(bell_hz * 2.0 ** (10.0 / 12.0), 1.8, rng, ratio=1.41, index=3.0)
    mix.add(bell2, hit_t + 0.16, gain_db=-8.0, pan=0.22, send_db=-8.0)

    out = mix.render(ir, wet_db=-3.0)
    mastered = ma.master(out, peak_db=-1.2)
    rms = ma.rms_db(mastered)
    if rms > cfg["rms_target"]:
        mastered *= ma.db(cfg["rms_target"] - rms)
    print(f"{cfg['name']}: {dur_s:.1f}s one-shot, peak {20*np.log10(np.max(np.abs(mastered))):.1f} dBFS, "
          f"rms {ma.rms_db(mastered):.1f} dBFS")
    return mastered


def encode(wav_path: str, out_path: str, codec_args: list[str]) -> None:
    if out_path.endswith(".ogg"):
        # the brew ffmpeg here lacks libvorbis; libsndfile (via soundfile) has
        # it, but a single ~10M-frame write segfaults its vorbis path — stream
        # the file in 1-second blocks instead
        import soundfile as sf
        sig, sr = ma.read_wav(wav_path)
        frames = np.ascontiguousarray(sig.T, dtype=np.float32)
        with sf.SoundFile(out_path, "w", samplerate=sr, channels=frames.shape[1],
                          format="OGG", subtype="VORBIS") as f:
            for i in range(0, frames.shape[0], sr):
                f.write(frames[i:i + sr])
        return
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", wav_path,
                    *codec_args, out_path], check=True)


def main() -> None:
    repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    parser = argparse.ArgumentParser()
    parser.add_argument("--build-dir", default=os.path.join(tempfile.gettempdir(), "mire_audio_build"))
    parser.add_argument("--ogg-dir", default=os.path.join(repo, "assets", "audio", "music"))
    args = parser.parse_args()
    os.makedirs(args.build_dir, exist_ok=True)
    os.makedirs(args.ogg_dir, exist_ok=True)

    dither_rng = np.random.default_rng(7)
    for cfg in (DAY, NIGHT):
        sig = render_track(cfg)
        wav = os.path.join(args.build_dir, cfg["name"] + ".wav")
        ma.write_wav(wav, sig, dither_rng)
        encode(wav, os.path.join(args.ogg_dir, cfg["name"] + ".ogg"),
               ["-c:a", "libvorbis", "-q:a", "5"])
        encode(wav, os.path.join(args.build_dir, cfg["name"] + ".mp3"),
               ["-c:a", "libmp3lame", "-q:a", "2"])

    sig = render_stinger(BOSS_STINGER)
    wav = os.path.join(args.build_dir, BOSS_STINGER["name"] + ".wav")
    ma.write_wav(wav, sig, dither_rng)
    encode(wav, os.path.join(args.ogg_dir, BOSS_STINGER["name"] + ".ogg"),
           ["-c:a", "libvorbis", "-q:a", "5"])
    encode(wav, os.path.join(args.build_dir, BOSS_STINGER["name"] + ".mp3"),
           ["-c:a", "libmp3lame", "-q:a", "2"])

    print("done:", args.build_dir, "->", args.ogg_dir)


if __name__ == "__main__":
    with import_cache_guard(os.path.basename(__file__)):
        main()
