#!/usr/bin/env python3
"""F-176: proves render_music.py's fixed-seed renders are actually
reproducible, rather than trusting the claim in docs/AUDIO.md.

    python3 tools/audio/repro_check.py

Runs render_music.py twice into two throwaway dirs (never touching
assets/audio/music/) and checks:
  wav  : the two runs' master WAVs are byte-identical (proves the PCM
         synthesis itself is deterministic — this is the level AUDIO.md's
         "bit-for-bit" claim actually holds at)
  ogg  : the two runs' OGGs need not be byte-identical — libsndfile's OGG
         writer stamps each encode with a random per-stream serial number
         (OGG container spec, not a MIRE bug), so raw bytes drift a little
         every time even given identical input. What must match is the
         *decoded* audio: read both OGGs back to PCM and require exact
         equality, proving that drift is header/CRC noise, not a content
         difference.

Exits non-zero on any failure, prints PASS/FAIL per rule like the other
tools/audio/*_check.py scripts.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile

import numpy as np
import soundfile as sf

failures = 0


def check(cond: bool, msg: str) -> None:
    global failures
    if cond:
        print(f"PASS: {msg}")
    else:
        failures += 1
        print(f"FAIL: {msg}")


def main() -> None:
    repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    script = os.path.join(repo, "tools", "audio", "render_music.py")
    tracks = ("ambient_day", "ambient_night", "boss_stinger")

    with tempfile.TemporaryDirectory(prefix="mire_audio_repro_") as tmp:
        runs = []
        for i in (1, 2):
            build_dir = os.path.join(tmp, f"run{i}")
            ogg_dir = os.path.join(tmp, f"run{i}_ogg")
            subprocess.run([sys.executable, script,
                            "--build-dir", build_dir, "--ogg-dir", ogg_dir],
                           check=True, capture_output=True, text=True)
            runs.append((build_dir, ogg_dir))

        (build1, ogg1), (build2, ogg2) = runs
        for track in tracks:
            wav1 = os.path.join(build1, track + ".wav")
            wav2 = os.path.join(build2, track + ".wav")
            with open(wav1, "rb") as f:
                data1 = f.read()
            with open(wav2, "rb") as f:
                data2 = f.read()
            check(data1 == data2, f"{track}.wav: byte-identical across two re-renders")

            pcm1, sr1 = sf.read(os.path.join(ogg1, track + ".ogg"))
            pcm2, sr2 = sf.read(os.path.join(ogg2, track + ".ogg"))
            check(sr1 == sr2 and np.array_equal(pcm1, pcm2),
                  f"{track}.ogg: decoded PCM identical across two re-renders "
                  "(raw bytes may still differ — OGG's per-encode serial number)")

    print(f"\nREPRO_CHECK failures={failures}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
