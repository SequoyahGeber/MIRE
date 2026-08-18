# Extraction ship set (A-009)

Fifteen models for the wreck a run **cashes out** on — `docs/DESIGN.md` §5.2. From Cycle 3 the hull
can be repaired with mid-tier resources, and boarding it ends the run successfully, banking the full
Salvage. It is the object the "leave now, or push one more Cycle" bet is made in front of, so it is
built as one hero landmark: 10.4 m long, 3.8 m to the stem head, standing on a timber cradle.

Built by `tools/blender/build_extraction_ship_set.py` (Blender 5.2.0 LTS, pinned — D-038).
Source: `assets/source/extraction_ship_set.blend`. Verified by
`.agent/bin/agent godot --script tools/ship_check.gd`.

## The ship frame — read this before placing anything

**Eleven of the fifteen exports are NOT individually ground-centred.** The mast, both sails, the
rudder, the boarding ramp and the cargo hatch are authored in the hull's own coordinate frame and
exported with the hull's origin, so a scene assembles the whole ship by adding every part as a
sibling at `Transform3D.IDENTITY`:

```gdscript
for part in ["ship_hull_repaired", "ship_mast", "ship_sail_raised",
             "ship_rudder", "ship_boarding_ramp", "ship_cargo_hatch"]:
    add_child(load("res://assets/ships/exports/%s.glb" % part).instantiate())
```

That is the whole API. Nothing needs positioning by hand, which is the point (D-039): grounding each
part on its own bounds would have put the mast's origin at its heel and the sail's at its foot and
left a human to find seven offsets by eye.

The consequence is that a ship-framed export legitimately sits above the ground plane — the raised
sail's lowest vertex is 1.8 m up, because that is where a sail is. `tools/ship_check.gd` enforces the
right rule per family: ship-framed parts must not go below z=0, the four hull states must sit exactly
on it, and the four standalone props must be ground-centred the usual way.

In the frame: **+X is the bow**, z=0 is the ground under the cradle, the deck is at **y = 1.78 m**
(Godot axes; Blender's z), and the mast steps at **x = +1.15**. The port side is Godot **+Z**, and
that is the side the gangway and the boarding ramp are on.

## The four hull states

`ship_hull_wrecked` → `ship_hull_repair_1` → `ship_hull_repair_2` → `ship_hull_repaired` are one
builder with a different hole set, strake palette and deck coverage — not four models. Swap the mesh
in place; **state drift is 0.0000 mm**, measured in the engine across all four, because nothing is
re-centred rather than because the re-centring happens to agree.

The repair reads as colour before it reads as geometry: the strakes run weathered grey deadwood →
patched → worked timber, and algae thins from 42% coverage to none. That matters because colour
survives fog distance and a missing plank does not.

Pair the states with the rig: `ship_mast_broken` with the wrecked and first-repair hulls,
`ship_mast` + `ship_sail_furled` from the second, `ship_sail_raised` when she is ready to leave.

## Contents

| Export | Family | W × D × H (m) | Triangles | Materials | Origin |
|---|---|---|---:|---:|---|
| `ship_hull_wrecked` | hull | 10.685 × 4.143 × 3.626 | 1896 | 7 | ship_frame |
| `ship_hull_repair_1` | hull | 10.685 × 4.143 × 3.626 | 1726 | 8 | ship_frame |
| `ship_hull_repair_2` | hull | 10.685 × 4.143 × 3.626 | 1556 | 8 | ship_frame |
| `ship_hull_repaired` | hull | 10.905 × 4.143 × 3.818 | 1706 | 8 | ship_frame |
| `ship_mast` | fitted | 10.375 × 3.092 × 7.69 | 192 | 4 | ship_frame |
| `ship_mast_broken` | fitted | 5.153 × 5.125 × 4.435 | 264 | 4 | ship_frame |
| `ship_sail_furled` | fitted | 4.466 × 0.514 × 2.869 | 512 | 3 | ship_frame |
| `ship_sail_raised` | fitted | 4.426 × 0.532 × 6.071 | 384 | 4 | ship_frame |
| `ship_rudder` | fitted | 2.39 × 0.26 × 2.389 | 116 | 3 | ship_frame |
| `ship_boarding_ramp` | fitted | 1.343 × 3.065 × 2.477 | 268 | 3 | ship_frame |
| `ship_cargo_hatch` | fitted | 2.068 × 1.2 × 1.576 | 380 | 6 | ship_frame |
| `ship_anchor` | prop | 1.59 × 1.836 × 0.538 | 380 | 4 | ground_centred |
| `ship_donation_crate` | prop | 1.039 × 0.862 × 0.908 | 360 | 6 | ground_centred |
| `ship_departure_bell` | prop | 0.62 × 1.29 × 2.022 | 248 | 6 | ground_centred |
| `ship_debris_cluster` | prop | 1.967 × 2.539 × 0.31 | 468 | 6 | ground_centred |

10456 triangles across the set. Palette tokens only — no generator-local colours.

## What this set does NOT contain

No collision, no interaction volumes, no gameplay scripts, and no repair-progress authority. The
extraction system owns which state is shown and when; these are presentation meshes (ASSET_TRACKER's
art and export contract). The donation crate, departure bell and boarding ramp are the three that
will want interaction volumes when that system is built.
