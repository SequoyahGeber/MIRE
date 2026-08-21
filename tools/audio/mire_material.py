"""Material-accurate impact and texture synthesis for MIRE's sound effects.

This module replaces the ad-hoc layering the v1 SFX recipes used. The v1 sounds
were built by ear from primitives — a click, a sine drop, a noise bed — with
every resonance and decay time hand-picked. Sequoyah's verdict on listening was
that most of them were "wildly inaccurate", and the research says why:

**Frequency-dependent decay rate, not spectral content, is the dominant cue for
material.** Klatzky, Pai & Krotkov (Presence 9(4), 2000) found that a
shape-invariant decay parameter determined perceived material far more strongly
than fundamental frequency did, and that it correlated with the physical
damping of the real material. Hand-picking one tau per partial destroys exactly
that cue: it makes every object sound like a different unnamed substance.

So decay is not authored here. It is DERIVED. A material is a **loss factor**
eta (equivalently Q = 1/eta), and every mode of every object made of it decays
at

    tau_i = 1 / (pi * f_i * eta)

which falls out of the standard viscoelastic model (amplitude ~ exp(-omega t /
2Q)). One consequence matters more than any other: high modes die faster than
low ones, at a rate set by the material and nothing else. That is what makes
wood sound like wood at any pitch and any size, and it is why a stone the size
of a fist and a boulder both read as stone.

The second half of a real impact is the **excitation**, and it is not a click.
A collision has a contact time T_c set by how hard and how pointed the striking
body is; the force pulse is roughly a half-sine of that duration, so its
spectrum rolls off above ~1/(2*T_c). A steel point on stone contacts for well
under a millisecond and excites everything; a padded mallet contacts for ten
milliseconds and can only excite the bottom two modes no matter how hard it
swings. `contact_gain()` applies that, which is why `hardness` here changes the
*timbre* of a hit rather than just its volume.

Mode ratios come from the real geometry (`MODE_SETS`) — a free-free bar is
1 : 2.756 : 5.404 (the xylophone series), a circular membrane is
1 : 1.593 : 2.135, and an irregular lump of rock has quasi-random modes, which
is itself the honest model rather than a cop-out.

Everything else in here — bubbles by the Minnaert model, granular debris,
friction, crackle, air arcs — follows the same rule: build the mechanism, do not
imitate the result.

Contract is identical to `mire_audio`/`mire_voices`: numpy only, every
stochastic voice takes an explicit `numpy.random.Generator`, renders are
bit-for-bit reproducible from a fixed seed (F-176).

Sources consulted: Klatzky/Pai/Krotkov on material from contact sounds; the
standard loss-factor tables (steel ~1e-3, aluminium ~6e-3, gypsum ~3e-2,
neoprene ~2e-1); Tsugi's GameSynth procedural-foley breakdowns for the layering
architecture (impact + modal resonators + narrow noise bands, layers offset
~30 ms so they do not mask each other); and standard foley practice for which
real object stands in for which sound (celery for bone, wet cloth for flesh,
cassette tape for dead leaves, rice on canvas for rain).
"""

from __future__ import annotations

import numpy as np

import mire_audio as ma

SR = ma.SR
NYQ = SR * 0.45


# ---------------------------------------------------------------------------
# materials
# ---------------------------------------------------------------------------

## Internal loss factor eta. Decay of every mode follows tau = 1/(pi*f*eta), so
## these numbers ARE the material as far as the ear is concerned. Anchored on
## published values where they exist (steel ~1e-3, aluminium ~6e-3, gypsum
## board ~3e-2, neoprene ~2e-1) and interpolated for the rest by where the
## substance sits between them.
LOSS: dict[str, float] = {
    "steel": 0.0009,      # a struck blade rings for seconds
    "iron": 0.0016,       # cast/wrought, dirtier than steel
    "bronze": 0.0011,
    "crystal": 0.0008,    # mire crystal: the longest ring in the game
    "glass": 0.0016,
    "granite": 0.012,     # dense rock barely rings — tens of ms, not seconds
    "stone": 0.018,
    "sandstone": 0.030,
    "bone": 0.011,        # the reason a bone crack reads as sharp
    "chitin": 0.028,      # hollow shell: rings, but briefly
    "wood_dry": 0.010,    # seasoned timber, a plank or a haft
    "wood_green": 0.032,  # a living tree — three times the damping
    "wood_rot": 0.075,    # waterlogged: almost no ring at all
    "clay": 0.045,
    "leather": 0.20,
    "flesh": 0.32,        # essentially a thud with a hint of pitch
    "mud": 0.55,          # no ring survives one cycle
}

## Modal frequency ratios by geometry. The first entry is always 1.0.
MODE_SETS: dict[str, tuple[float, ...]] = {
    # Transverse modes of a free-free beam — the xylophone/marimba series, and
    # what any struck bar, plank, haft or branch actually does.
    "bar_free": (1.0, 2.756, 5.404, 8.933, 13.344, 18.638),
    # Cantilever (one end fixed): a fence post, a stake driven into ground.
    "bar_clamped": (1.0, 6.267, 17.548, 34.387),
    # Circular membrane — a drumhead, a taut hide, a puddle surface.
    "membrane": (1.0, 1.593, 2.135, 2.295, 2.917, 3.598, 4.230),
    # Free circular plate: a shield, a lid, a flat slab of shale.
    "plate_free": (1.0, 1.730, 2.328, 4.140, 5.062, 7.000),
    # Clamped circular plate: a hide stretched on a frame, a fitted lid.
    "plate_clamped": (1.0, 2.080, 3.414, 3.892, 5.000, 5.954),
    # Open tube — a hollow log, a horn, a bone.
    "tube_open": (1.0, 2.0, 3.0, 4.0, 5.0, 6.0),
    # Closed tube (one end stopped): odd harmonics only. A jar, a shell.
    "tube_closed": (1.0, 3.0, 5.0, 7.0, 9.0),
}


def irregular_modes(count: int, rng: np.random.Generator,
                    spread: float = 1.0) -> tuple[float, ...]:
    """Quasi-random mode ratios for a shape with no analytic solution — a rock,
    a lump of ore, a broken piece of anything.

    This is not laziness standing in for physics: the modal density of an
    irregular solid genuinely grows with frequency and its ratios genuinely are
    incommensurate, which is precisely why such objects sound like a *clack*
    rather than a note. Ratios walk upward by a jittered factor so they never
    line up into a harmonic series by accident.
    """
    ratios = [1.0]
    for _ in range(max(count - 1, 0)):
        ratios.append(ratios[-1] * rng.uniform(1.28, 1.28 + 0.55 * spread))
    return tuple(ratios)


# ---------------------------------------------------------------------------
# excitation
# ---------------------------------------------------------------------------

def contact_time(hardness: float) -> float:
    """Seconds of contact for a strike, from `hardness` in 0..1.

    0.0 is a padded mallet or a bare palm (~12 ms); 1.0 is steel on stone
    (~0.15 ms). Logarithmic between, because that is how the physical range
    actually spans — the difference between 12 ms and 6 ms is one perceptual
    step, and so is the difference between 0.3 ms and 0.15 ms.
    """
    h = float(np.clip(hardness, 0.0, 1.0))
    return 0.012 * (0.15 / 12.0) ** h


def contact_gain(freqs: np.ndarray, contact_s: float) -> np.ndarray:
    """How much a strike of contact time `contact_s` excites each frequency.

    A collision force is close to a half-sine pulse of duration T_c, whose
    magnitude spectrum has its first null at 1/T_c and rolls off steeply above
    it. That single fact is why a soft mallet cannot make a bright sound however
    hard it is swung, and why the same object struck with a nail and with a
    thumb are recognisably the same object. Modelled here as a smooth
    second-order rolloff at 1/(2*T_c) rather than the literal
    |cos(pi f T)/(1-(2fT)^2)|, whose nulls would punch holes in individual
    modes and read as detuning rather than as damping.
    """
    fc = 1.0 / max(2.0 * contact_s, 1e-5)
    return 1.0 / np.sqrt(1.0 + (freqs / fc) ** 4)


def strike_amplitudes(ratios: np.ndarray, position: float,
                      rolloff: float = 1.0) -> np.ndarray:
    """Relative mode amplitudes for a bar struck at `position` along its length
    (0..1, 0.5 = the middle).

    A mode with a node at the strike point is not excited at all: hit a bar
    dead centre and every even mode vanishes, which is exactly why a centred
    strike sounds hollow and pure and an off-centre one sounds like a knock.
    That difference is free realism and costs one `sin`.
    """
    shape = np.abs(np.sin(np.pi * ratios * float(np.clip(position, 0.02, 0.98))))
    return shape / np.arange(1, ratios.shape[0] + 1) ** rolloff


# ---------------------------------------------------------------------------
# the impact voice
# ---------------------------------------------------------------------------

def struck(f0: float, material: str, dur_s: float, rng: np.random.Generator,
           geometry: str = "bar_free", hardness: float = 0.6,
           position: float = 0.28, modes: int = 6, rolloff: float = 0.85,
           detune_cents: float = 0.0, spread: float = 1.0,
           mounting: float = 0.02) -> np.ndarray:
    """One struck object. The core voice of nearly every SFX in the game.

    `f0` is the first mode in Hz, `material` keys `LOSS`, `geometry` keys
    `MODE_SETS` (or "irregular"). Everything about how it decays is derived from
    the material; everything about how bright it is comes from `hardness` via
    the contact time. Nothing here is hand-tuned per sound, which is the point —
    two objects of the same material sound related even when nothing about their
    recipes was copied.

    `mounting` is the loss the object's *situation* adds on top of the loss its
    substance has, and it matters as much as the material does. Published loss
    factors are for a specimen ringing freely; almost nothing in a game is
    ringing freely. A trunk is rooted in ground, a plank is nailed into a wall, a
    rock is lying on other rocks, a blade is gripped in a fist — and boundary
    damping at a contact dwarfs internal friction. Left at the material value
    alone, a struck dry plank rings for 0.7 s, which is a xylophone bar on a
    stand and not a plank in a palisade. Rough scale: 0.0 suspended on wire,
    0.02 resting loose, 0.08 held or seated, 0.3 buried, gripped, or waterlogged.
    """
    n = ma.samples(dur_s)
    if geometry == "irregular":
        ratios = np.array(irregular_modes(modes, rng, spread))
    else:
        base = MODE_SETS.get(geometry, MODE_SETS["bar_free"])
        ratios = np.array(base[:modes], dtype=np.float64)
        if ratios.shape[0] < modes:  # ran out of tabulated modes; extrapolate
            extra = irregular_modes(modes - ratios.shape[0] + 1, rng, spread)[1:]
            ratios = np.concatenate([ratios, ratios[-1] * np.array(extra)])

    freqs = f0 * ratios
    eta = LOSS.get(material, LOSS["wood_dry"]) + max(mounting, 0.0)
    amps = strike_amplitudes(ratios, position, rolloff)
    amps = amps * contact_gain(freqs, contact_time(hardness))

    out = np.zeros(n)
    for f, a in zip(freqs, amps):
        if f > NYQ or a < 1e-4:
            continue
        if detune_cents > 0.0:
            f *= 2.0 ** (detune_cents * rng.uniform(-1.0, 1.0) / 1200.0)
        tau = 1.0 / (np.pi * f * eta)
        out += a * np.sin(2 * np.pi * f * ma.time_vector(n) + rng.uniform(0, 6.28)) \
            * np.exp(-ma.time_vector(n) / tau)
    peak = float(np.max(np.abs(out)))
    return ma.fade_edges(out / peak, 0.0015) if peak > 0 else out


def strike_noise(dur_s: float, rng: np.random.Generator, material: str,
                 hardness: float = 0.6, brightness: float = 1.0) -> np.ndarray:
    """The non-resonant half of a hit: the crush, splinter and dust that is not
    any mode of anything. Band and decay both follow from the same contact time
    and loss factor as the modes, so it lands in the same material as them
    rather than sitting on top like a separate sample.
    """
    n = ma.samples(dur_s)
    fc = brightness / max(2.0 * contact_time(hardness), 1e-5)
    sig = ma.fft_filter(ma.white(n, rng), fc_low=fc * 0.10, fc_high=min(fc, NYQ), order=2)
    eta = LOSS.get(material, LOSS["wood_dry"])
    # Noise energy sits an octave or two above the fundamental, so decay it at
    # the rate the material would give a mode up there.
    tau = 1.0 / (np.pi * max(fc * 0.35, 60.0) * eta)
    sig *= np.exp(-ma.time_vector(n) / max(tau, 0.002))
    peak = float(np.max(np.abs(sig)))
    return sig / peak if peak > 0 else sig


def body(f0: float, dur_s: float, drop: float = 0.55, curve: float = 0.5,
         tau_ratio: float = 0.3) -> np.ndarray:
    """The low thump of mass being moved — the part of an impact that is the
    object's whole body accelerating, not any of its modes. Present in every
    real hit and the thing most synthetic impacts are missing."""
    n = ma.samples(dur_s)
    return ma.sine_glide(f0, f0 * drop, dur_s, curve=curve) * ma.exp_decay(n, dur_s * tau_ratio)


# ---------------------------------------------------------------------------
# fluids — the mire is mostly water
# ---------------------------------------------------------------------------

def bubble(radius_m: float, rng: np.random.Generator,
           rise: float = 2.2, damp: float = 0.6) -> np.ndarray:
    """One bubble, by the Minnaert model: a spherical bubble of radius r rings
    at f = 3.26/r Hz, and as it shrinks during collapse the pitch RISES.

    That rising chirp is the entire perceptual signature of water. A downward
    or flat blip sounds like a synth blip; the same envelope swept upward sounds
    like a drip, and a hundred of them sound like a stream. This is Farnell's
    водa model and it is the single highest-value thing in this module for a
    swamp game.
    """
    f0 = 3.26 / max(radius_m, 1e-4)
    if f0 > NYQ:
        return np.zeros(ma.samples(0.01))
    tau = damp * 0.0015 * (3.26 / f0) ** 0.5 * 1000.0
    tau = float(np.clip(tau, 0.004, 0.09))
    dur = min(tau * 5.0, 0.35)
    n = ma.samples(dur)
    t = ma.time_vector(n)
    freq = f0 * (1.0 + rise * t / max(dur, 1e-4))
    sig = np.sin(2 * np.pi * np.cumsum(freq) / SR + rng.uniform(0, 6.28))
    return ma.fade_edges(sig * np.exp(-t / tau), 0.0008)


def bubble_cloud(dur_s: float, rng: np.random.Generator, count: int = 30,
                 r_min: float = 0.0004, r_max: float = 0.006,
                 density_curve: float = 1.6) -> np.ndarray:
    """Many bubbles over a window — a splash's tail, a boot lifting out of bog,
    a stream. Radii are drawn log-uniform because real bubble size
    distributions are, which is what gives a splash its wide pitch spray."""
    n = ma.samples(dur_s)
    out = np.zeros(n)
    for _ in range(count):
        frac = rng.uniform(0.0, 1.0) ** density_curve
        at = ma.samples(frac * dur_s)
        r = float(np.exp(rng.uniform(np.log(r_min), np.log(r_max))))
        b = bubble(r, rng, rise=rng.uniform(1.4, 3.2), damp=rng.uniform(0.5, 1.0))
        end = min(at + b.shape[0], n)
        if at < end:
            out[at:end] += b[: end - at] * rng.uniform(0.3, 1.0) * (1.0 - 0.55 * frac)
    peak = float(np.max(np.abs(out)))
    return out / peak if peak > 0 else out


def splash(dur_s: float, rng: np.random.Generator, size: float = 0.5) -> np.ndarray:
    """Impact into water: a broadband crash of the surface breaking, then a
    cloud of bubbles as it closes. `size` 0..1 moves both the noise band and the
    bubble radii, so a boot and a falling tree splash differently for the right
    reason."""
    n = ma.samples(dur_s)
    hi = 9000.0 - 6000.0 * size
    crash = ma.swept_bandpass(ma.white(n, rng),
                              np.geomspace(hi, hi * 0.22, n), octaves=2.0, block=512)
    crash *= np.exp(-ma.time_vector(n) / (0.02 + 0.09 * size))
    cloud = bubble_cloud(dur_s, rng, count=int(18 + 60 * size),
                         r_min=0.0004 + 0.0010 * size, r_max=0.003 + 0.010 * size)
    out = crash + 0.55 * cloud
    peak = float(np.max(np.abs(out)))
    return ma.fade_edges(out / peak, 0.002) if peak > 0 else out


# ---------------------------------------------------------------------------
# textures
# ---------------------------------------------------------------------------

def granular(dur_s: float, rng: np.random.Generator, count: int,
             fc_low: float, fc_high: float, grain_s: tuple = (0.002, 0.012),
             density_curve: float = 2.0, decay: float = 1.0) -> np.ndarray:
    """Scattered micro-impacts: debris, rubble, grit, dry leaves, a rattle.

    Grain onsets are front-loaded by `density_curve` so a scatter thins out the
    way a real one does — a uniform distribution reads as a machine."""
    n = ma.samples(dur_s)
    out = np.zeros(n)
    for _ in range(count):
        frac = rng.uniform(0.0, 1.0) ** density_curve
        at = ma.samples(frac * dur_s)
        g = ma.samples(rng.uniform(*grain_s))
        if at >= n or g < 4:
            continue
        grain = ma.fft_filter(ma.white(g, rng), fc_low=fc_low,
                              fc_high=rng.uniform(fc_high * 0.45, fc_high), order=2)
        grain = ma.fade_edges(grain * ma.exp_decay(g, rng.uniform(0.0008, 0.005)), 0.0006)
        end = min(at + g, n)
        out[at:end] += grain[: end - at] * rng.uniform(0.25, 1.0) * (1.0 - decay * 0.6 * frac)
    peak = float(np.max(np.abs(out)))
    return out / peak if peak > 0 else out


def friction(dur_s: float, rng: np.random.Generator, material: str = "wood_dry",
             f_low: float = 400.0, f_high: float = 1600.0, rate: float = 90.0,
             roughness: float = 0.6) -> np.ndarray:
    """Sliding, scraping, sawing, rope pulling — surfaces dragging over each
    other. A friction sound is a dense train of micro-impacts whose rate tracks
    the sliding speed, filtered by the resonances of the two bodies; the ear
    reads the *rate* as speed and the *filter* as material."""
    n = ma.samples(dur_s)
    train = np.zeros(n)
    t = 0.0
    while t < dur_s:
        i = ma.samples(t)
        if i < n:
            train[i] += rng.uniform(0.4, 1.0) * (1.0 if rng.uniform() > 0.5 else -1.0)
        t += (1.0 / rate) * (1.0 + rng.uniform(-roughness, roughness))
    centers = np.geomspace(f_low, f_high, n)
    sig = ma.swept_bandpass(train, centers, octaves=1.3, block=512)
    eta = LOSS.get(material, 0.02)
    sig = ma.fft_filter(sig, fc_high=min(f_high * (3.0 if eta < 0.01 else 1.6), NYQ), order=1)
    peak = float(np.max(np.abs(sig)))
    return sig / peak if peak > 0 else sig


def crackle(dur_s: float, rng: np.random.Generator, rate: float = 55.0,
            f_low: float = 900.0, f_high: float = 7000.0) -> np.ndarray:
    """Fire: sparse sharp pops over a hiss. Each pop is a tiny steam explosion
    inside the wood, so they are bright, irregular, and unrelated to each
    other — regular spacing is what makes a synthetic fire sound like rain."""
    n = ma.samples(dur_s)
    out = np.zeros(n)
    t = 0.0
    while t < dur_s:
        at = ma.samples(t)
        g = ma.samples(rng.uniform(0.0015, 0.008))
        if at < n and g > 3:
            pop = ma.fft_filter(ma.white(g, rng), fc_low=f_low,
                                fc_high=rng.uniform(f_high * 0.4, f_high), order=2)
            pop = ma.fade_edges(pop * ma.exp_decay(g, 0.0012), 0.0005)
            end = min(at + g, n)
            out[at:end] += pop[: end - at] * rng.uniform(0.2, 1.0)
        t += (1.0 / rate) * (1.0 + rng.uniform(-0.85, 1.6))
    hiss = ma.fft_filter(ma.white(n, rng), fc_low=500.0, fc_high=5200.0, order=2)
    hiss *= 0.4 + 0.6 * np.abs(ma.slow_noise(n, 9.0, rng))
    out = out + 0.35 * hiss
    peak = float(np.max(np.abs(out)))
    return out / peak if peak > 0 else out


def air_arc(dur_s: float, rng: np.random.Generator, f_low: float = 320.0,
            f_high: float = 1800.0, width: float = 1.0, peak_at: float = 0.5,
            sharp: float = 1.6) -> np.ndarray:
    """Something swung through air. The band sweeps UP as the tip accelerates and
    back DOWN as it decelerates, and the amplitude peaks at the same moment —
    that coupling of pitch and loudness is what makes a whoosh read as an arc
    rather than as a filter sweep."""
    n = ma.samples(dur_s)
    x = np.linspace(0.0, 1.0, n)
    centers = np.interp(x, [0.0, peak_at, 1.0], [f_low, f_high, f_low * 1.25])
    sig = ma.swept_bandpass(ma.white(n, rng), centers, octaves=width, block=512)
    env = np.interp(x, [0.0, peak_at, 1.0], [0.0, 1.0, 0.0]) ** sharp
    peak = float(np.max(np.abs(sig)))
    return (sig / peak if peak > 0 else sig) * env


def cloth(dur_s: float, rng: np.random.Generator, weight: float = 0.5,
          rate: float = 220.0) -> np.ndarray:
    """Clothing, a pack, a strap, leather. Fibres releasing each other: a dense
    high-frequency granular rustle whose density falls with the weight of the
    fabric, over a soft body thud for heavy material."""
    n = ma.samples(dur_s)
    fibres = granular(dur_s, rng, count=int(rate * dur_s),
                      fc_low=1200.0 + 2600.0 * (1.0 - weight),
                      fc_high=7000.0 + 6000.0 * (1.0 - weight),
                      grain_s=(0.0008, 0.004), density_curve=1.0, decay=0.2)
    env = np.sin(np.pi * np.linspace(0, 1, n)) ** 1.2
    out = fibres * env
    if weight > 0.35:
        out = out + weight * 0.45 * ma.fft_filter(ma.white(n, rng), fc_high=420.0, order=2) * env
    peak = float(np.max(np.abs(out)))
    return ma.fade_edges(out / peak, 0.002) if peak > 0 else out
