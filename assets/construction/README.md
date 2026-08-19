# Practical construction kit (A-010)

Eighteen exports covering fourteen assets: the pieces a player walks through, climbs, crosses or
hides behind. A working wood door, a double gate, a ladder, a ramp, three bridges, two dock modules,
three palisade pieces and two barricades.

Built by `tools/blender/build_construction_set.py` (Blender 5.2.0 LTS, pinned — D-038).
Source: `assets/source/construction_set.blend`. Verified by
`.agent/bin/agent godot --script tools/construction_check.gd`.

## The module contract — read this before placing anything

Every number in the kit comes from four, so pieces mate plane to plane instead of nearly:

| | | |
|---|---|---|
| `MODULE` | **2.00 m** | run pitch and standard piece width. Matches `content/buildables/wall.tres` (`size.x = 2`, `snap_step = 1`) |
| `WALL_H` | **3.00 m** | that wall's height. Palisade, both gate frames, the door frame and the ladder all reach exactly it |
| `DECK_Z` | **1.00 m** | the walking surface of every bridge and dock piece |
| `RAMP_RISE` | **1.00 m** over a 2.00 m run | 26.57°, and exactly one deck. Three ramps stack to `WALL_H` |

So a boardwalk is `dock_straight` every 2 m, a bridge continues it at the same height, `ramp` gets
you onto it, and a ladder leans against a palisade and ends level with the points. Nothing needs a
fudge factor, and `tools/construction_check.gd` assembles a five-module walkway, a boardwalk corner
and a fence corner in the engine to prove it: **worst joint 0.0000 mm**.

Godot axes: the run axis is **+X**, the deck is at **y = 1.00**, and Blender's +y (a wall's inner
face) is Godot **−Z**.

## Origin rules, which differ by family on purpose

- **`ground_centred`** — fourteen exports. The usual portable rule: sits on y = 0, centred in x/z.
- **`corner_post`** — `palisade_corner` only. Its origin is the corner post's own axis at ground
  level, *not* its bounding-box centre, so both arms end exactly on the cell edges a straight section
  butts to. The catalog's `mates_m` says where the neighbours go: `[-2, 0, 0]`, and `[0, 2, 0]` for a
  section turned 90° (Blender +y, so Godot −z).
- **`hinge_axis`** — the four leaves. Origin on the hinge: the leaf's outer back corner, at ground
  level — offset a real `HINGE_CLEARANCE` (8 mm) in front of the geometry rather than flush with it
  (F-180: flush measured as exactly 0 mm meant the leaf's own edge and the frame's collision face
  landed on the identical float, which read as touching, not "in front of"). A scene hangs one and
  swings it, and that is the whole API:

```gdscript
var frame := load("res://assets/construction/exports/door_wood_frame.glb").instantiate()
var leaf := load("res://assets/construction/exports/door_wood_leaf.glb").instantiate()
add_child(frame)
add_child(leaf)
leaf.position = Vector3(-0.55, 0.0, 0.02)   # catalog: hinge.hinge_offset_m, Blender (x, y, z) -> (x, z, -y)
leaf.rotate_y(deg_to_rad(90.0))             # catalog: hinge.swing_deg
```

Nobody hunts for the pivot by eye (D-039). The catalog carries `hinge_offset_m`, `opens_toward` and
`swing_deg` for each leaf, and the check swings all four through their whole arc against their own
frame's triangles: no leaf touches its frame at any angle, and at full swing the doorway is clear.

**90° is the documented limit and it is a real one.** A square-edged plank leaf hung on the face of
its jamb clears completely at 90° and starts to catch the jamb corner past it — the same reason a
real door gets a stop or a bevelled edge. The opening is fully clear at 90°, so nothing wants more.

## What is hung on what

| Frame | Leaves | Opening |
|---|---|---|
| `door_wood_frame` | `door_wood_leaf` | 1.10 × 2.15 m |
| `gate_double_frame` | `gate_double_leaf_left` + `gate_double_leaf_right` | 2.50 × 2.60 m |
| `palisade_gate_frame` | `palisade_gate_leaf` | 1.36 × 2.55 m |

The two gate leaves are built by one function with a `side` parameter rather than by mirroring: a
negative scale flips face winding, and a gate whose far leaf is invisible from outside is the kind of
bug that only shows up after it is placed.

## The slope numbers are the player's, not taste

`entities/player/player.tscn` sets `floor_max_angle` to 46° and the controller implements no step-up
at all, so **any vertical lip is a wall**. That is why the ramp is 26.57°, why its toe feathers to
12 mm instead of starting with a step, and why the doorway has no threshold across it. The check
re-measures the slope against the engine's own limit rather than trusting the build.

## State pair

`bridge_straight` and `bridge_broken` are one module in two conditions, swapped in place when a span
gives way. The near trestle is built by the same call with the same numbers, so **state drift is
0.0000 mm** — measured in the engine, not asserted. One beam survives the full module on purpose:
the piece still mates into a run, and a player can still shimmy across, which is a better answer than
a hole.

## No authored collision

These are presentation meshes. Placement, damage and destruction stay host-authoritative
(`docs/ARCHITECTURE.md` §2.2); the task that wires a piece into `content/buildables/` adds its
collision under a D-031 exact claim.
