"""MIRE extended voice library — instruments the ambience never needed.

`mire_audio` covers the ambient palette: pads, Karplus-Strong plucks, FM bells,
groans, noise beds. A *theme* needs more than a texture — it needs a melody
instrument that can sing a line, something to carry weight underneath it, and
(for the menu, where ambience's no-percussion rule does not apply) a pulse.
This module adds those on top of `mire_audio`, same contract: pure numpy, every
stochastic voice takes an explicit `numpy.random.Generator`, so renders stay
bit-for-bit reproducible from a fixed seed (F-176).

It also adds the two primitives the v1 SFX recipes were missing:
`modal_bank` (a bank of exponentially-decaying partials — the physical model
behind every struck stone, bell, and hollow log) and `grain_scatter` (debris,
rubble, rattles), which is what lets the SFX option sets sound like genuinely
different design takes rather than reseeds of one recipe.

Nothing here aliases: every oscillator is sine-built and harmonic loops stop
below Nyquist, exactly as in `mire_audio`.
"""

from __future__ import annotations

import numpy as np

import mire_audio as ma

SR = ma.SR
NYQ = SR * 0.45


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def _norm(sig: np.ndarray) -> np.ndarray:
    peak = float(np.max(np.abs(sig)))
    return sig / peak if peak > 0 else sig


def phase_of(freq_curve: np.ndarray) -> np.ndarray:
    """Per-sample frequency curve -> continuous phase. The only correct way to
    build vibrato/glide: modulating a fixed-phase sine's argument instead would
    modulate *position*, not pitch, and click on every zero crossing."""
    return 2 * np.pi * np.cumsum(freq_curve) / SR


def vibrato_curve(freq_hz: float, n: int, rng: np.random.Generator,
                  rate_hz: float = 5.1, cents: float = 11.0,
                  delay_s: float = 0.30, drift_cents: float = 5.0) -> np.ndarray:
    """Human-ish pitch curve: vibrato that fades in after the note has spoken,
    over a slow random drift so repeated notes are never identical."""
    t = ma.time_vector(n)
    onset = np.clip((t - delay_s) / 0.45, 0.0, 1.0)
    lfo = np.sin(2 * np.pi * rate_hz * t + rng.uniform(0, 2 * np.pi))
    drift = drift_cents * ma.slow_noise(n, 1.3, rng)
    return freq_hz * 2.0 ** ((cents * onset * lfo + drift) / 1200.0)


def formant_filter(sig: np.ndarray, formants, floor: float = 0.03) -> np.ndarray:
    """Shape a harmonic-rich source with resonant peaks. `formants` is a list of
    (center_hz, bandwidth_hz, gain_db). The floor keeps a little of everything
    else so vowels sound sung rather than vocoded."""
    n = sig.shape[-1]
    spec = np.fft.rfft(sig)
    f = np.fft.rfftfreq(n, 1.0 / SR)
    h = np.full_like(f, floor)
    for fc, bw, gain_db in formants:
        h += ma.db(gain_db) * np.exp(-0.5 * ((f - fc) / max(bw * 0.6, 1.0)) ** 2)
    return np.fft.irfft(spec * h, n)


VOWELS = {
    "ah": [(730.0, 130.0, 0.0), (1090.0, 170.0, -6.0), (2440.0, 250.0, -14.0)],
    "oh": [(570.0, 110.0, 0.0), (840.0, 150.0, -7.0), (2410.0, 260.0, -18.0)],
    "oo": [(300.0, 90.0, 0.0), (870.0, 140.0, -12.0), (2240.0, 260.0, -22.0)],
    "mm": [(280.0, 80.0, 0.0), (1100.0, 180.0, -20.0), (2200.0, 300.0, -28.0)],
}


def tape_warble(sig: np.ndarray, rng: np.random.Generator,
                cents: float = 7.0, rate_hz: float = 0.8) -> np.ndarray:
    """Slow pitch wobble by resampling — the sound of an old mechanism, or of
    tape. Applied to a whole stem it glues the stem together the way a shared
    room does."""
    if sig.ndim == 2:
        wob = ma.slow_noise(sig.shape[-1], rate_hz, rng)
        return np.stack([_warp(ch, wob, cents) for ch in sig])
    return _warp(sig, ma.slow_noise(sig.shape[-1], rate_hz, rng), cents)


def _warp(mono: np.ndarray, wob: np.ndarray, cents: float) -> np.ndarray:
    n = mono.shape[-1]
    step = 2.0 ** (cents * wob / 1200.0)
    idx = np.cumsum(step)
    idx *= (n - 1) / idx[-1]
    return np.interp(idx, np.arange(n), mono)


def echo(sig: np.ndarray, time_s: float, feedback: float = 0.35,
         taps: int = 4, damp_hz: float | None = 4000.0) -> np.ndarray:
    """Simple feedback delay, darkening on each repeat. Cheap depth for a
    melody instrument that would otherwise sit flat against the pads."""
    n = sig.shape[-1]
    out = sig.astype(np.float64).copy()
    step = ma.samples(time_s)
    tap = sig.astype(np.float64)
    gain = 1.0
    for _ in range(taps):
        gain *= feedback
        if damp_hz is not None:
            tap = ma.fft_filter(tap, fc_high=damp_hz, order=1)
        shifted = np.zeros_like(out)
        k = step * (_ + 1)
        if k >= n:
            break
        shifted[..., k:] = tap[..., : n - k]
        out += shifted * gain
    return out


# ---------------------------------------------------------------------------
# sustained voices — things that can carry a melody
# ---------------------------------------------------------------------------

def bowed(freq_hz: float, dur_s: float, rng: np.random.Generator,
          bright: float = 1.0, attack_s: float = 0.14, release_s: float = 0.35,
          vib_cents: float = 11.0, harmonics: int = 30,
          bow_noise: float = 0.05) -> np.ndarray:
    """Bowed string (viol/fiddle family). Harmonics ride one shared phase so
    vibrato moves the whole note in tune; a breath of bandpassed noise on top
    is the rosin. This is MIRE's lead singing voice."""
    n = ma.samples(dur_s)
    freq = vibrato_curve(freq_hz, n, rng, cents=vib_cents)
    ph = phase_of(freq)
    out = np.zeros(n)
    for h in range(1, harmonics + 1):
        if freq_hz * h > NYQ:
            break
        amp = (1.0 / h ** 1.1) * np.exp(-(h - 1) / (7.0 * max(bright, 0.15)))
        if amp < 2e-4:
            break
        out += amp * np.sin(h * ph + rng.uniform(0, 2 * np.pi))
    out = _norm(out)
    if bow_noise > 0:
        rosin = ma.fft_filter(ma.white(n, rng), fc_low=freq_hz * 1.6,
                              fc_high=min(freq_hz * 9.0, NYQ), order=2)
        out += bow_noise * _norm(rosin)
    swell = 1.0 + 0.09 * ma.slow_noise(n, 2.4, rng)
    return ma.fade_edges(_norm(out * swell) * ma.env_asr(n, attack_s, release_s), 0.006)


def choir(freq_hz: float, dur_s: float, rng: np.random.Generator,
          vowel: str = "ah", voices: int = 3, spread_cents: float = 14.0,
          attack_s: float = 0.55, release_s: float = 0.9,
          harmonics: int = 26) -> np.ndarray:
    """Massed voices on one vowel. Several detuned singers, each with its own
    vibrato phase, then formant-shaped — the detune spread is what makes it a
    section instead of a synth."""
    n = ma.samples(dur_s)
    out = np.zeros(n)
    for v in range(voices):
        cents = spread_cents * (v - (voices - 1) / 2.0) / max(voices - 1, 1)
        f0 = freq_hz * 2.0 ** (cents / 1200.0)
        freq = vibrato_curve(f0, n, rng, rate_hz=rng.uniform(4.4, 5.8),
                             cents=rng.uniform(8.0, 16.0), delay_s=rng.uniform(0.4, 0.8))
        ph = phase_of(freq)
        voice = np.zeros(n)
        for h in range(1, harmonics + 1):
            if f0 * h > NYQ:
                break
            voice += (1.0 / h ** 0.95) * np.sin(h * ph + rng.uniform(0, 2 * np.pi))
        out += _norm(voice)
    out = formant_filter(_norm(out), VOWELS.get(vowel, VOWELS["ah"]))
    breath = ma.fft_filter(ma.white(n, rng), fc_low=1400.0, fc_high=5200.0, order=2)
    out = _norm(out) + 0.035 * _norm(breath)
    return ma.fade_edges(_norm(out) * ma.env_asr(n, attack_s, release_s), 0.008)


def horn(freq_hz: float, dur_s: float, rng: np.random.Generator,
         index: float = 3.2, attack_s: float = 0.10, release_s: float = 0.45,
         growl: float = 0.0) -> np.ndarray:
    """Brass. FM at ratio 1 with the modulation index tied to the amplitude
    envelope, which is what brass actually does: it gets brighter as it gets
    louder, so a swell reads as effort rather than a volume fader."""
    n = ma.samples(dur_s)
    freq = vibrato_curve(freq_hz, n, rng, rate_hz=4.7, cents=7.0, delay_s=0.45)
    ph = phase_of(freq)
    env = ma.env_asr(n, attack_s, release_s)
    idx = index * (0.35 + 0.65 * env)
    if growl > 0:
        idx = idx * (1.0 + growl * ma.slow_noise(n, 9.0, rng))
    sig = np.sin(ph + idx * np.sin(ph + rng.uniform(0, 2 * np.pi)))
    sig += 0.30 * np.sin(0.5 * ph + rng.uniform(0, 2 * np.pi))  # a fifth-below body
    air = ma.fft_filter(ma.white(n, rng), fc_low=600.0, fc_high=3000.0, order=2)
    sig = _norm(sig) + 0.03 * _norm(air)
    return ma.fade_edges(_norm(sig) * env, 0.006)


def flute(freq_hz: float, dur_s: float, rng: np.random.Generator,
          breath: float = 0.22, attack_s: float = 0.08,
          release_s: float = 0.25) -> np.ndarray:
    """Bone/reed whistle: near-sine with a weak octave, and a lot of breath
    noise tracking the note. Reads as hand-made, which the mire wants."""
    n = ma.samples(dur_s)
    freq = vibrato_curve(freq_hz, n, rng, rate_hz=5.6, cents=14.0, delay_s=0.22)
    ph = phase_of(freq)
    sig = np.sin(ph) + 0.20 * np.sin(2 * ph + rng.uniform(0, 6.28)) \
        + 0.06 * np.sin(3 * ph + rng.uniform(0, 6.28))
    wind = ma.fft_filter(ma.white(n, rng), fc_low=freq_hz * 0.9,
                         fc_high=min(freq_hz * 4.5, NYQ), order=2)
    chiff = np.zeros(n)
    c = min(ma.samples(0.06), n)
    chiff[:c] = _norm(ma.fft_filter(ma.white(c, rng), fc_low=2000.0))[:c] * ma.exp_decay(c, 0.02)
    out = _norm(sig) + breath * _norm(wind) + 0.35 * chiff
    return ma.fade_edges(_norm(out) * ma.env_asr(n, attack_s, release_s), 0.006)


def glass_pad(freq_hz: float, dur_s: float, rng: np.random.Generator,
              partials: int = 7, attack_s: float = 1.6,
              release_s: float = 2.4) -> np.ndarray:
    """Slightly inharmonic bowed-glass pad: stretched partials (like a struck
    bar left to ring) held instead of decaying. Colder than `additive_pad`."""
    n = ma.samples(dur_s)
    out = np.zeros(n)
    for k in range(partials):
        stretch = 1.0 + 0.0009 * k * k
        f = freq_hz * (k + 1) * stretch
        if f > NYQ:
            break
        amp = 1.0 / (k + 1) ** 1.25
        drift = 1.0 + 0.03 * ma.slow_noise(n, 0.19, rng)
        out += amp * drift * np.sin(2 * np.pi * f * ma.time_vector(n) + rng.uniform(0, 6.28))
    return ma.fade_edges(_norm(out) * ma.env_asr(n, attack_s, release_s), 0.01)


def music_box(freq_hz: float, dur_s: float, rng: np.random.Generator,
              index: float = 1.3) -> np.ndarray:
    """Comb-tine music box: a bright short-decay FM tone plus the mechanical
    tick of the pin releasing. Innocence, slightly wrong — the eerie option."""
    n = ma.samples(dur_s)
    t = ma.time_vector(n)
    tau = min(max(260.0 / freq_hz, 0.35), 1.6)
    mod = index * np.exp(-t / (tau * 0.22)) * np.sin(2 * np.pi * freq_hz * 3.47 * t
                                                     + rng.uniform(0, 6.28))
    tone = np.sin(2 * np.pi * freq_hz * t + mod) * np.exp(-t / tau)
    tick = np.zeros(n)
    c = min(ma.samples(0.004), n)
    tick[:c] = _norm(ma.fft_filter(ma.white(c, rng), fc_low=2600.0)) * ma.exp_decay(c, 0.0015)
    return ma.fade_edges(_norm(tone + 0.22 * tick), 0.003)


def dulcimer(freq_hz: float, dur_s: float, rng: np.random.Generator,
             courses: int = 2, spread_cents: float = 7.0,
             damp: float = 0.9975, bright: float = 0.75) -> np.ndarray:
    """Hammered dulcimer / lute: two or three strings per note, slightly out of
    tune with each other and struck a few milliseconds apart. That smear is the
    whole character — a single Karplus-Strong string sounds like a synth."""
    n = ma.samples(dur_s)
    out = np.zeros(n)
    for c in range(courses):
        cents = spread_cents * (c - (courses - 1) / 2.0) / max(courses - 1, 1)
        f = freq_hz * 2.0 ** (cents / 1200.0)
        s = ma.ks_pluck(f, dur_s, rng, damp=damp, bright=bright)
        offset = ma.samples(rng.uniform(0.0, 0.006))
        if offset > 0:
            s = np.concatenate([np.zeros(offset), s[:-offset]])
        out += s * rng.uniform(0.8, 1.0)
    return ma.fade_edges(_norm(out), 0.003)


# ---------------------------------------------------------------------------
# percussion — menu themes only; ambience stays tempo-free (D-066 palette rule)
# ---------------------------------------------------------------------------

def membrane(f0: float, f1: float, dur_s: float, rng: np.random.Generator,
             skin: float = 0.35, modes: float = 0.5, fc: float = 2200.0,
             tau_ratio: float = 0.32) -> np.ndarray:
    """Struck drumhead: a pitch-dropping fundamental, the circular membrane's
    inharmonic mode ratios above it, and a noise slap for the stick."""
    n = ma.samples(dur_s)
    body = ma.sine_glide(f0, f1, dur_s, curve=0.35) * ma.exp_decay(n, dur_s * tau_ratio)
    ring = np.zeros(n)
    for ratio, amp in ((1.593, 0.34), (2.135, 0.22), (2.295, 0.15), (2.917, 0.09)):
        if f0 * ratio > NYQ:
            continue
        ring += amp * ma.sine(f0 * ratio, dur_s, phase=rng.uniform(0, 6.28)) \
            * ma.exp_decay(n, dur_s * tau_ratio * 0.42)
    slap = ma.fft_filter(ma.white(n, rng), fc_high=fc, order=2) * ma.exp_decay(n, 0.018)
    out = body + modes * ring + skin * _norm(slap)
    return ma.fade_edges(_norm(out), 0.002)


def log_drum(freq_hz: float, dur_s: float, rng: np.random.Generator) -> np.ndarray:
    """Hollow struck wood — a slit drum. Woody because the partials are a
    stretched-octave pair, not a harmonic series."""
    n = ma.samples(dur_s)
    out = np.zeros(n)
    for ratio, amp, tau in ((1.0, 1.0, dur_s * 0.5), (2.04, 0.45, dur_s * 0.25),
                            (3.31, 0.18, dur_s * 0.12)):
        if freq_hz * ratio > NYQ:
            continue
        out += amp * ma.sine(freq_hz * ratio, dur_s, phase=rng.uniform(0, 6.28)) \
            * ma.exp_decay(n, tau)
    knock = ma.fft_filter(ma.white(n, rng), fc_low=900.0, fc_high=4200.0, order=2) \
        * ma.exp_decay(n, 0.006)
    return ma.fade_edges(_norm(out + 0.5 * _norm(knock)), 0.002)


def shaker(dur_s: float, rng: np.random.Generator, fc_low: float = 4200.0,
           fc_high: float = 11000.0, sharp: float = 0.022) -> np.ndarray:
    """One shake: a rush of small collisions, bandpassed high."""
    n = ma.samples(dur_s)
    grains = ma.fft_filter(ma.white(n, rng), fc_low=fc_low, fc_high=fc_high, order=2)
    grains *= 0.35 + 0.65 * np.abs(ma.slow_noise(n, 260.0, rng))
    env = np.exp(-ma.time_vector(n) / sharp) * (1.0 - np.exp(-ma.time_vector(n) / 0.003))
    return ma.fade_edges(_norm(grains * env), 0.001)


def grain_scatter(dur_s: float, rng: np.random.Generator, count: int = 24,
                  fc_low: float = 600.0, fc_high: float = 5000.0,
                  grain_s: tuple = (0.004, 0.018), density_curve: float = 2.0,
                  spread: tuple = (0.0, 1.0)) -> np.ndarray:
    """Scattered small impacts — rubble, twigs, chitin, coins, rattling bones.
    Grain times are front-loaded by `density_curve` so a scatter thins out the
    way a real one does instead of sounding like a metronome of clicks."""
    n = ma.samples(dur_s)
    out = np.zeros(n)
    for _ in range(count):
        frac = rng.uniform(0.0, 1.0) ** density_curve
        at = ma.samples(spread[0] + (spread[1] - spread[0]) * frac * dur_s)
        g = ma.samples(rng.uniform(*grain_s))
        if at >= n or g < 4:
            continue
        grain = ma.fft_filter(ma.white(g, rng), fc_low=fc_low,
                              fc_high=rng.uniform(fc_high * 0.5, fc_high), order=2)
        grain = ma.fade_edges(grain * ma.exp_decay(g, rng.uniform(0.001, 0.006)), 0.0008)
        end = min(at + g, n)
        out[at:end] += grain[: end - at] * rng.uniform(0.25, 1.0) * (1.0 - 0.6 * frac)
    return _norm(out)


# ---------------------------------------------------------------------------
# impact modelling — the primitive the v1 SFX recipes lacked
# ---------------------------------------------------------------------------

def modal_bank(modes, dur_s: float, rng: np.random.Generator,
               jitter_cents: float = 0.0) -> np.ndarray:
    """Bank of exponentially-decaying partials: `modes` is [(hz, tau_s, amp)].

    This is the physical model behind every struck object. Material lives
    almost entirely in the *ratios* and the *relative decay times*: stone is
    dense inharmonic partials that die in tens of milliseconds, wood is a few
    stretched partials with a fast top and a slow bottom, metal is near-integer
    ratios that ring for seconds. Choosing those numbers is sound design; the
    synthesis is this six-line loop.
    """
    n = ma.samples(dur_s)
    out = np.zeros(n)
    for hz, tau, amp in modes:
        f = hz * 2.0 ** (jitter_cents * rng.uniform(-1.0, 1.0) / 1200.0)
        if f > NYQ or amp <= 0:
            continue
        out += amp * ma.sine(f, dur_s, phase=rng.uniform(0, 6.28)) * ma.exp_decay(n, tau)
    return ma.fade_edges(_norm(out), 0.002)


def noise_impact(dur_s: float, rng: np.random.Generator, fc_start: float,
                 fc_end: float, octaves: float = 1.2, tau_s: float = 0.05,
                 block: int = 512) -> np.ndarray:
    """A filtered noise burst whose band sweeps as it decays — the texture half
    of an impact (the dust, the splinters, the water leaving)."""
    n = ma.samples(dur_s)
    centers = np.geomspace(max(fc_start, 20.0), max(fc_end, 20.0), n)
    sig = ma.swept_bandpass(ma.white(n, rng), centers, octaves=octaves, block=block)
    return _norm(sig * ma.exp_decay(n, tau_s))


def body_drop(f0: float, f1: float, dur_s: float, curve: float = 0.5,
              tau_ratio: float = 0.35) -> np.ndarray:
    """Pitched sine drop — the weight under an impact."""
    n = ma.samples(dur_s)
    return ma.sine_glide(f0, f1, dur_s, curve=curve) * ma.exp_decay(n, dur_s * tau_ratio)


def transient(rng: np.random.Generator, dur_s: float = 0.003,
              fc_low: float = 1500.0, fc_high: float | None = None) -> np.ndarray:
    """The first two milliseconds — what the ear actually uses to name a
    material before any of the resonance arrives."""
    n = ma.samples(dur_s)
    return ma.fade_edges(ma.fft_filter(ma.white(n, rng), fc_low=fc_low,
                                       fc_high=fc_high, order=2), 0.0005)
