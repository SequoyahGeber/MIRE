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
	vec2 world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
	// 30 degrees of rotation baked into the two constant pairs (cos30, sin30 = 0.866, 0.5), so the
	// lattices of the two layers line up with neither the world axes nor each other.
	broad_detail = detail_noise(vec2(
		dot(world_xz, vec2(0.866, 0.5)), dot(world_xz, vec2(-0.5, 0.866))) * BROAD_SCALE);
	fine_detail_uv = vec2(
		dot(world_xz, vec2(0.454, -0.891)), dot(world_xz, vec2(0.891, 0.454))) * FINE_SCALE;
	// The provoking vertex's own world position, at a scale that keeps neighbouring vertices (>= 0.3
	// m apart after ChunkMesher's jitter) well separated in the hash's input range.
	facet_detail = detail_hash(world_xz * 0.37);
}

void fragment() {
	// F-399. Signed deviations, so `ground_detail_strength` scales them around exactly 1.0 and 0.0
	// restores the pre-F-399 look bit for bit.
	float value_field = mix(broad_detail, detail_noise(fine_detail_uv), FINE_MIX) - 0.5;
	float facet_field = facet_detail - 0.5;
	float value_dev = value_field * VALUE_AMP + facet_field * FACET_AMP;
	float hue_dev = (broad_detail - 0.5) * HUE_AMP + facet_field * FACET_HUE_AMP;
	vec3 detail = vec3(1.0) + (vec3(value_dev) + HUE_AXIS * hue_dev) * ground_detail_strength;

	ALBEDO = ground_albedo * albedo_color * detail;
	ROUGHNESS = 1.0;
	// dFdy x dFdx (not the other order): VERTEX is view-space, and this order faces the normal
	// toward the camera the way Godot's own flat-shade examples do.
	NORMAL = normalize(cross(dFdy(VERTEX), dFdx(VERTEX)));
}
