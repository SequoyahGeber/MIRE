shader_type spatial;

// 4.18/D-184 — the flat-shaded low-poly terrain look Sequoyah pointed at (the r/Unity3D
// "procedurally generated low poly terrain, without mountains" reference): every triangle lit as
// one facet.
//
// The facet normal comes from screen-space derivatives of the view-space position, so the mesh
// stays exactly what ChunkMesher builds — indexed, smooth-normal, one vertex per grid point. No
// duplicated vertices, no second surface, works identically at every LOD, and costs two
// derivative instructions per fragment. The alternative (non-indexed triangles with baked face
// normals) triples the vertex count on every resident chunk, which this game's low-end target
// (docs/PERFORMANCE.md) rules out.
//
// The mesh's own smooth normals are still what the skirt inherits and what
// SurfaceTool.generate_normals comparisons in the checks read — this shader only changes lighting.
//
// F-379 — WHERE THE GROUND'S COLOUR COMES FROM NOW. It used to be this uniform alone: one value,
// set once by ChunkStreamer, painted over every chunk on the island, so terrain, canopy and every
// lit prop sat in the same narrow yellow-green band and nothing separated from anything else.
// The colour is per-vertex now — ChunkMesher blends each biome's authored `ground_albedo` across
// the same contour that blends its roughness — and this uniform is what is left of the old one: a
// GLOBAL multiply over whatever the biomes decided, shipping at white so it changes nothing. It is
// kept rather than deleted because it is the only lever a weather state or a debug view has for
// tinting the whole ground at once, and re-adding it later would mean touching the mesh format.

uniform vec3 albedo_color : source_color = vec3(1.0);

// F-399 — GROUND DETAIL. Master multiplier on everything the detail block below contributes; at 0
// this shader is bit-for-bit the pre-F-399 one (the whole term collapses to vec3(1.0)), which is
// what `tools/terrain_texture_check.gd` renders its "before" frames through. Kept as a uniform for
// exactly two reasons — that A/B, and giving a future look pass one dial instead of a shader edit.
// The individual amplitudes are consts on purpose: they are a tuned SET, and a per-amplitude
// uniform is an invitation for three of them to drift apart in someone's debug session.
uniform float ground_detail_strength : hint_range(0.0, 2.0) = 1.0;

// The vertex colours arrive in sRGB, which is where they were authored and where eight bits per
// channel are worth most (see ChunkMesher.GroundPalette). Decode in the VERTEX stage, not the
// fragment one: the value is constant across a facet, so a per-fragment pow() would be three
// transcendentals per pixel of ground on a machine we are trying not to spend anything on.
varying vec3 ground_albedo;

// ---------------------------------------------------------------------------------------------
// F-399 · the ground is no longer one flat value per biome.
//
// Sequoyah, from play: "Maybe we can make a texture for the ground rather than just having it be
// one flat color, maybe subtle texture would be good for the ground." The constraint is the whole
// problem. The terrain is DELIBERATELY flat-shaded low-poly (D-184) and the facets are the look, so
// a tiled texture would fight them — and there is nothing to tile against anyway: ChunkMesher's UVs
// are chunk-local 0..1 (they exist so a chunk can be inspected, not so it can be textured), which
// would repeat the same image once per 32 m chunk with a hard seam at every chunk border.
//
// So the breakup is procedural, in WORLD space, at scales ABOVE the facet size. That ordering is
// the thing to preserve if any of this is retuned: a field finer than the ~1 m facet lands INSIDE
// each triangle and reads as noise sitting on the geometry — dithering — which is worse than the
// flat colour it replaced. Everything here is at 17 m or coarser, plus one per-facet constant.
//
// Three layers, cheapest first:
//
//   1. BROAD (58 m, per-vertex).  A single octave of value noise evaluated in the vertex stage and
//      interpolated. 58 m is ~30x the vertex spacing even at LOD2, so it is enormously oversampled
//      and reconstructs identically at every tier — which is the reason it is up there rather than
//      in the fragment stage. A fragment-stage field costs four hashes on every terrain pixel; a
//      vertex-stage one costs four hashes per 1,089-vertex chunk. The catch is that anything much
//      finer than ~4x the LOD2 spacing (16 m) would reconstruct DIFFERENTLY per tier and a chunk
//      would visibly change tint the instant it crossed a ring boundary, so this is the only layer
//      that can live there.
//   2. FINE (17 m, per-fragment).  Four hashes per pixel. Carries the variation you read while
//      walking, where the 58 m field is a single slow gradient.
//   3. FACET (per-triangle).  A `flat` varying: one hash of the provoking vertex's world position,
//      constant across the triangle, zero fragment cost. This is the layer that stops two
//      neighbouring facets from being the identical RGB, which is the specific thing that made a
//      hillside read as dead space. ChunkMesher._build_indices() rotates the second triangle of
//      each quad so that no two EDGE-ADJACENT triangles share a provoking vertex — without that,
//      half the facets on the island came in matched pairs and the jitter read as a rhombus grid,
//      i.e. exactly the "texture pattern" this is not allowed to be. See the winding note there.
//
// All of it is a MULTIPLIER on whatever base colour arrives, never an additive term or a fixed
// green — F-397 is re-authoring the biome palette concurrently and more biomes are coming (F-401),
// so this has to be neutral about hue and value. A multiply is also the perceptually even choice:
// a linear multiply of (1 + 2.4e) is an sRGB multiply of (1 + e), so a shore at sRGB 0.57 and a
// forest floor at sRGB 0.23 get the same RELATIVE variation, which is what the eye grades. The one
// thing it cannot do is lift a base colour authored at pure black, and that is correct — a biome
// that authors black ground wants black ground.
//
// Cost: ~4 hashes + ~15 ALU per terrain pixel, no texture fetch, no transcendental, no branch.
// ---------------------------------------------------------------------------------------------

// Wavelength of the per-vertex layer, in metres, as its reciprocal.
const float BROAD_SCALE = 1.0 / 58.0;
// Wavelength of the per-fragment layer. Above the ~1 m facet by a wide margin (see above), and
// deliberately not a clean multiple of BROAD's — the two beating at a fixed ratio is how procedural
// breakup starts to look periodic.
const float FINE_SCALE = 1.0 / 17.0;
// How much of the combined value field is the fine layer. Under half: the broad layer is what keeps
// a hillside from being one value, the fine layer only keeps the broad one from looking like a
// gradient.
const float FINE_MIX = 0.4;
// Peak brightness swing, as a fraction, over the full 0..1 range of the value field. Value noise
// clusters near its mean (sigma ~0.19 of range), so the typical swing underfoot is about a third of
// this and the stated number is the rare extreme.
const float VALUE_AMP = 0.48;
// Per-facet brightness jitter. Small on purpose — this is the layer that would read as dithering
// first, because its feature size IS the triangle.
const float FACET_AMP = 0.13;
// How far the broad layer drifts the hue, along HUE_AXIS.
const float HUE_AMP = 0.20;
// And per facet, at a quarter of that: enough that two neighbouring facets differ in colour and not
// only in brightness.
const float FACET_HUE_AMP = 0.055;
// The hue drift, as a relative per-channel multiply. Positive is warmer/drier (more red, a little
// more green, less blue); negative is cooler/damper. Chosen as a channel RATIO rather than an HSV
// rotation so it costs three multiply-adds instead of a conversion, and so it behaves sanely on any
// base hue: it tilts a green toward olive and a sand toward warm grey rather than rotating either
// into a colour nobody authored.
const vec3 HUE_AXIS = vec3(0.90, 0.12, -0.85);

// ---------------------------------------------------------------------------------------------
// F-435 · THE MIRE HAS TO BE VISIBLE ON THE GROUND.
//
// Sequoyah, from play: "the tainted ground that starts damaging you has no indication that it's
// different... I feel like there should be low yellowy green fog and a purple hue to the ground."
// This is the purple half; `world/environment/ground_fog.gdshader` is the fog half, and they read
// the SAME texture so the two can never disagree about where the Mire is.
//
// The field comes from `MireGrid.corruption_field_texture()` — the live 256x256 simulation grid,
// R8, mapped over the island in world XZ. `mire_field_half_extent` is the world X/Z the texture's
// edge lands on; it is pushed by `ChunkStreamer` from `MireGrid.corruption_field_half_extent()`
// rather than being a constant here, because the grid derives its own extent from
// `IslandHeightmap.ISLAND_RADIUS` and a hardcoded copy would silently slide off the terrain the
// next time the island is resized (F-368, one layer down, is the same coupling).
//
// hint_default_black is doing real work: unbound — no MireGrid, a check that loads this shader on
// its own, the frontend — the sample reads 0 and every line below collapses to the pre-F-435 look.
// There is no "is the Mire wired up" branch anywhere in this file.
//
// WHY TWO RAMPS. The damage threshold is a hard number (`PlayerHealth.BLIGHT_CORRUPTION_THRESHOLD`,
// 0.15) and a single smoothstep across the whole range puts nothing in particular at it — the
// ground would fade so gradually that the line where you start losing HP is unmarked, which is the
// finding all over again. So the first ramp runs from barely-there up TO that threshold and carries
// 45% of the effect: by the time you are standing on ground that drains you, the colour shift has
// already made its biggest single move. The second ramp carries the rest across the deep field, so
// the heart of a Mire still reads as worse than its edge. Retune the weights freely; keep
// BLIGHT_HURTS_AT equal to PlayerHealth's threshold.
const float BLIGHT_SEEN_AT = 0.03;
const float BLIGHT_HURTS_AT = 0.15;
const float BLIGHT_DEEP_AT = 0.55;
const float BLIGHT_HURTS_WEIGHT = 0.45;
// The field is 256 cells across ~236 m — about 0.92 m per cell, which is the same order as a facet.
// Sampled straight, its bilinear ramp would read as a smooth blob with a soft circular edge sitting
// under the faceted ground like a decal. Jittering the corruption VALUE by the terrain detail field
// that is already computed below breaks the boundary into the same scale of shapes the ground
// itself is made of, for two ALU and no extra fetch. Amplitude is in corruption units.
const float BLIGHT_EDGE_JITTER = 0.055;
// Toward grey first, then multiplied by the tint — so a yellow shore and a green forest floor both
// arrive at purple rather than at "slightly violet yellow" and "slightly violet green". A THIRD of
// the way, not most of it: the first cut sat at 0.55 and photographed as pale mauve dust, because
// killing the base's chroma before tinting leaves nothing for the tint to bruise. Enough of the
// biome's own colour has to survive for the result to read as ground that went wrong rather than as
// a flat swatch laid over it.
const float BLIGHT_DESATURATE = 0.35;
// The multiply. Green is pulled down hardest (it is what the ground mostly is), blue is barely
// touched and red sits between them, so the channel ORDER comes out B > R > G — which is what
// makes it violet rather than the neutral purple-grey that a tint with R and B equal produces. The
// blue multiplier is deliberately ABOVE one — a tint that only ever darkens cannot separate B from
// R on ground whose base is already low in blue, and the marsh floor (a brown-green) came out flat
// grey at every all-below-one tint tried.
// Sized so the ground also loses about 40% of its brightness: blighted ground reading brighter than
// the grass beside it would be a highlight, and a highlight is the wrong signal for something that
// drains you.
const vec3 BLIGHT_TINT = vec3(0.66, 0.24, 1.22);
// Blighted ground reads damp rather than dusty. Subtle — a full specular sheen on flat-shaded
// facets is a mirrored polygon, which is worse than no cue at all.
const float BLIGHT_ROUGHNESS = 0.76;

// ---------------------------------------------------------------------------------------------
// F-464 · BARE ROCK ON STEEP GROUND.
//
// Play, on a river cutting a hill: "it just drops from the top of the hill straight down to the
// river and leaves a straight vertical wall that is unnatural." `IslandHeightmap`'s CLIFFS block
// fixed the SHAPE — the drop ramps out over as much ground as its depth needs, and its face is
// benched into strata. This is the other half of that sentence: the face was also wearing the same
// grass as the meadow above it, and a green cliff reads as a wall no matter what angle it stands at.
//
// The mask arrives in COLOR.a, which the biome blend was leaving at a constant 1.0 —
// `ChunkMesher._rock_exposure()`, taken from the slope of the triangles the chunk actually emits.
// So it is not a river feature: a sea cliff on a lobe and a placed hill's scarp get the same
// treatment off the same property, which is the only way the island stays one place.
//
// Nothing is sampled for it. The strata come from the world height that is already interpolated
// across the facet, and the mottling reuses the detail fields F-399 computed above.
//
// The two stone colours are `tools/blender/mire_art.py`'s `stone` (#818E93) and `stone_dark`
// (#59656C) — literally the swatches A-016a's cliff modules are built from, in linear, so a
// `cliff_face` prop pushed into a carved face is the same rock as the ground it sits on rather
// than a slightly different grey stuck to it.
// Both are the swatch value scaled by 0.72. A prop is lit as one object with its own shading; a
// hillside is thousands of flat-shaded facets, of which the ones facing the sun all return the
// albedo nearly unattenuated, so the same number that reads as mid grey stone on a boulder reads as
// chalk across a whole face. The RATIO between the two is what the swatches actually decide, and
// that is untouched.
const vec3 ROCK_ALBEDO = vec3(0.1580, 0.1948, 0.2101);
const vec3 ROCK_ALBEDO_DARK = vec3(0.0719, 0.0937, 0.1080);
// Metres per bedding plane. The SAME rhythm as `IslandHeightmap.CLIFF_BENCH_HEIGHT`, deliberately:
// the geometry already steps the face at this interval, and shading it at any other interval would
// put two unrelated stripe patterns on one wall. If that constant moves, move this with it.
const float ROCK_STRATA_M = 1.35;
// How dark the underside of each band goes. This is what makes the benching legible at a distance —
// on flat-shaded low-poly geometry a tread and its riser can catch nearly the same light, and
// without a value break the whole face flattens out into one grey slab.
const float ROCK_STRATA_DEPTH = 0.62;
// Per-facet mottling on the rock, reusing F-399's fields. Stronger than the ground's, because that
// one is fighting to stay subtle under grass and this one is standing in for the grain of stone.
const float ROCK_MOTTLE = 0.30;
// How far the bedding planes drift in and out of phase along a face, in metres, driven by the broad
// 58 m detail field. Without it every band on the island is at the same absolute height and a long
// face reads as corduroy — a manufactured stripe rather than rock that bedded and then tilted. Kept
// well under one band: the point is that neighbouring stretches of the same face disagree slightly
// about where the course sits, not that the courses stop being roughly level.
const float ROCK_STRATA_DRIFT = 0.55;
// Rock is matte and slightly damp. Just under the ground's 1.0 so a face separates from the meadow
// in specular as well as in colour, and nowhere near low enough to make a facet a mirror.
const float ROCK_ROUGHNESS = 0.94;

uniform sampler2D mire_field : hint_default_black, filter_linear, repeat_disable;
uniform float mire_field_half_extent = 118.0;
// One dial for the whole effect, for an A/B and for a future look pass. At 0 this shader is
// bit-for-bit the pre-F-435 one.
uniform float blight_strength : hint_range(0.0, 2.0) = 1.0;

// The broad value field, 0..1, interpolated across the facet.
varying float broad_detail;
// World XZ, pre-rotated and pre-scaled for the fine layer so the fragment stage does neither. The
// rotation matters: a single octave of value noise on an axis-aligned lattice reads as soft squares
// lined up with world X/Z, and 30 degrees of skew is free here (it is folded into the constant
// below) while costing four ALU per pixel if done in the fragment stage.
varying vec2 fine_detail_uv;
// One hash per TRIANGLE — see layer 3 above. `flat` is what makes it per-facet: the value is taken
// from the provoking vertex and not interpolated.
varying flat float facet_detail;
// F-435. Corruption-field UV. Computed in the vertex stage because it is AFFINE in world position —
// interpolation reconstructs it exactly, at every LOD, so the sample is still full-resolution
// per-fragment. This is the opposite of `broad_detail`'s situation and the reason that one is
// restricted to wavelengths far above the vertex spacing while this one is not restricted at all.
varying vec2 mire_uv;
// F-464. How much of this vertex is bare rock, 0..1 — `ChunkMesher._rock_exposure()`, in the alpha
// the biome blend was not using.
varying float rock_exposure;
// World height, for the strata bands. Affine in the vertex position, so the interpolation across a
// facet is exact and the bands are genuinely horizontal planes rather than a per-vertex staircase.
varying float world_height;

// Hash without sine (integer-free, so it behaves the same on a GPU that flushes denormals and does
// not need a transcendental unit). Fed lattice coordinates in roughly +/-20 after the scales above,
// which is where its mixing is well conditioned — feeding it raw world metres would run the first
// fract() at 300+ and quantise the result to a few hundred distinct values.
float detail_hash(vec2 p) {
	vec3 p3 = fract(vec3(p.x, p.y, p.x) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

// Bilinear value noise with a smoothstep fade, 0..1. Four hashes; the cheapest field that has no
// visible lattice discontinuity.
float detail_noise(vec2 p) {
	vec2 cell = floor(p);
	vec2 f = p - cell;
	f = f * f * (3.0 - 2.0 * f);
	float a = detail_hash(cell);
	float b = detail_hash(cell + vec2(1.0, 0.0));
	float c = detail_hash(cell + vec2(0.0, 1.0));
	float d = detail_hash(cell + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void vertex() {
	vec3 srgb = COLOR.rgb;
	// The exact sRGB EOTF rather than pow(c, 2.2): the approximation is worst in the darks, and the
	// forest floor (#474338) is exactly there.
	ground_albedo = mix(
		srgb / 12.92,
		pow((srgb + vec3(0.055)) / 1.055, vec3(2.4)),
		step(vec3(0.04045), srgb)
	);

	// F-399. World space, not model space: chunk meshes are authored chunk-local (0..32) and placed
	// at their chunk origin, so anything computed from VERTEX alone would repeat every 32 m with a
	// seam at every chunk border — the exact failure the chunk-local UVs already have.
	vec3 world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 world_xz = world_position.xz;
	rock_exposure = COLOR.a;
	world_height = world_position.y;
	// 30 degrees of rotation baked into the two constant pairs (cos30, sin30 = 0.866, 0.5), so the
	// lattices of the two layers line up with neither the world axes nor each other.
	broad_detail = detail_noise(vec2(
		dot(world_xz, vec2(0.866, 0.5)), dot(world_xz, vec2(-0.5, 0.866))) * BROAD_SCALE);
	fine_detail_uv = vec2(
		dot(world_xz, vec2(0.454, -0.891)), dot(world_xz, vec2(0.891, 0.454))) * FINE_SCALE;
	// The provoking vertex's own world position, at a scale that keeps neighbouring vertices (>= 0.3
	// m apart after ChunkMesher's jitter) well separated in the hash's input range.
	facet_detail = detail_hash(world_xz * 0.37);

	// F-435. Same mapping as `MireGridSim.world_to_cell()`: the field spans
	// [-half_extent, +half_extent] on both axes.
	mire_uv = (world_xz + vec2(mire_field_half_extent))
		/ max(mire_field_half_extent * 2.0, 0.001);
}

void fragment() {
	// F-399. Signed deviations, so `ground_detail_strength` scales them around exactly 1.0 and 0.0
	// restores the pre-F-399 look bit for bit.
	float value_field = mix(broad_detail, detail_noise(fine_detail_uv), FINE_MIX) - 0.5;
	float facet_field = facet_detail - 0.5;
	float value_dev = value_field * VALUE_AMP + facet_field * FACET_AMP;
	float hue_dev = (broad_detail - 0.5) * HUE_AMP + facet_field * FACET_HUE_AMP;
	vec3 detail = vec3(1.0) + (vec3(value_dev) + HUE_AXIS * hue_dev) * ground_detail_strength;

	vec3 base = ground_albedo * albedo_color * detail;

	// F-464. Bedding planes: a sawtooth on world height, softened at the top of each band so the
	// dark edge sits UNDER the ledge the geometry already put there, the way a weathered bench
	// shadows the course below it.
	float band = fract((world_height + (broad_detail - 0.5) * ROCK_STRATA_DRIFT)
		/ ROCK_STRATA_M);
	float bedding = 1.0 - ROCK_STRATA_DEPTH * (1.0 - smoothstep(0.0, 0.55, band));
	vec3 rock = mix(ROCK_ALBEDO_DARK, ROCK_ALBEDO, bedding)
		* (1.0 + (value_field + facet_field) * ROCK_MOTTLE * ground_detail_strength);
	base = mix(base, rock, rock_exposure);

	// F-435. `value_field` and `facet_field` are the terrain's own detail noise, reused here so the
	// Mire's boundary is ragged at the scale of the ground rather than a clean bilinear circle.
	float corruption = texture(mire_field, mire_uv).r
		+ (value_field + facet_field * 0.5) * BLIGHT_EDGE_JITTER;
	float blight = smoothstep(BLIGHT_SEEN_AT, BLIGHT_HURTS_AT, corruption) * BLIGHT_HURTS_WEIGHT
		+ smoothstep(BLIGHT_HURTS_AT, BLIGHT_DEEP_AT, corruption) * (1.0 - BLIGHT_HURTS_WEIGHT);
	blight = clamp(blight * blight_strength, 0.0, 1.0);
	float grey = dot(base, vec3(0.2126, 0.7152, 0.0722));
	vec3 tainted = mix(base, vec3(grey), BLIGHT_DESATURATE) * BLIGHT_TINT;

	ALBEDO = mix(base, tainted, blight);
	ROUGHNESS = mix(mix(1.0, ROCK_ROUGHNESS, rock_exposure), BLIGHT_ROUGHNESS, blight);
	// dFdy x dFdx (not the other order): VERTEX is view-space, and this order faces the normal
	// toward the camera the way Godot's own flat-shade examples do.
	NORMAL = normalize(cross(dFdy(VERTEX), dFdx(VERTEX)));
}
