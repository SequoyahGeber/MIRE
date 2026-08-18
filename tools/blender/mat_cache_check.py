"""Regression guard for F-092: `mire_art.mat()`'s per-token material cache.

Run:
    /Applications/Blender.app/Contents/MacOS/Blender --background --python \
        tools/blender/mat_cache_check.py

The bug this guards: the cache guard used to read
`if cached is not None and key in bpy.data.materials`. `key` is a palette
token such as ``"wood_bark"``; the datablock it created is named
``"MIRE_WoodBark"``. The membership test was therefore always False, the
cache never hit, and calling `mat(token)` from inside a loop — the natural
way to write a generator, and the shape none of the four originally migrated
kits happened to use — minted a fresh near-identical material every call.
`bracken_a` exported 22 of them for one token.

This exercises exactly that shape (call the same token repeatedly inside a
loop, not hoisted into a dict) so a regression here reproduces the same
failure the finding measured, not just a narrower unit check.
"""

import pathlib
import sys

sys.path.append(str(pathlib.Path(__file__).resolve().parent))

import bpy  # noqa: E402  (Blender's module; only importable once the interpreter is Blender's)

from mire_art import mat, reset_materials  # noqa: E402

failures: list[str] = []


def check(label: str, condition: bool) -> None:
    if not condition:
        failures.append(label)


# Fresh state: drop the cache dict and every material left over from Blender's
# own default scene, so material counts below are exact, not "plus whatever
# was already there."
reset_materials()
for stale in list(bpy.data.materials):
    bpy.data.materials.remove(stale)

# 1. The bug's exact repro shape: mat(token) called repeatedly inside a loop,
#    as bracken_a's leaf-building loop did, rather than hoisted into a
#    `mats = {...}` dict once per build (the shape that hid the bug in the
#    four originally migrated kits). Before the fix this minted 22 materials;
#    it must now mint exactly one, and every call must return that same
#    datablock.
token = "wood_bark"
before = len(bpy.data.materials)
first = None
for _ in range(22):
    m = mat(token)
    if first is None:
        first = m
    check(f"mat({token!r}) inside a loop returns the same datablock every call", m is first)
minted = len(bpy.data.materials) - before
check(f"22 loop calls to mat({token!r}) minted exactly one material (minted {minted})", minted == 1)

# 2. A different token is not folded into the same cache entry.
other_token = "leaf"
mat(other_token)
check("a second distinct token mints its own material", len(bpy.data.materials) == before + 2)

# 3. `suffix` produces an independent, itself-cached, entry.
suffixed = mat(token, suffix="_alt")
check("a suffix variant is a distinct datablock from the base token", suffixed is not first)
check("a suffix variant is cached on repeat calls", mat(token, suffix="_alt") is suffixed)

# 4. A cache entry orphaned by a scene wipe (the datablock removed out from
#    under `_MATERIAL_CACHE` without going through `reset_materials()`) is
#    detected via the documented `ReferenceError` guard and rebuilt, not
#    returned as a dangling reference and not raised.
wipe_token = "stone"
built = mat(wipe_token)
bpy.data.materials.remove(built)
try:
    rebuilt = mat(wipe_token)
except ReferenceError:
    rebuilt = None
    failures.append(f"mat({wipe_token!r}) raised ReferenceError after its datablock was removed, instead of rebuilding")
if rebuilt is not None:
    check("an orphaned cache entry is rebuilt rather than returned dangling", rebuilt is not built)
    check("the rebuild is itself cached on the next call", mat(wipe_token) is rebuilt)

verdict = "PASS" if not failures else f"FAIL ({len(failures)})"
print(f"MAT_CACHE_CHECK {verdict}")
for failure in failures:
    print(f"  - {failure}")

sys.exit(1 if failures else 0)
