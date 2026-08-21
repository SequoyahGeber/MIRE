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

// The vertex colours arrive in sRGB, which is where they were authored and where eight bits per
// channel are worth most (see ChunkMesher.GroundPalette). Decode in the VERTEX stage, not the
// fragment one: the value is constant across a facet, so a per-fragment pow() would be three
// transcendentals per pixel of ground on a machine we are trying not to spend anything on.
varying vec3 ground_albedo;

void vertex() {
	vec3 srgb = COLOR.rgb;
	// The exact sRGB EOTF rather than pow(c, 2.2): the approximation is worst in the darks, and the
	// forest floor (#474338) is exactly there.
	ground_albedo = mix(
		srgb / 12.92,
		pow((srgb + vec3(0.055)) / 1.055, vec3(2.4)),
		step(vec3(0.04045), srgb)
	);
}

void fragment() {
	ALBEDO = ground_albedo * albedo_color;
	ROUGHNESS = 1.0;
	// dFdy x dFdx (not the other order): VERTEX is view-space, and this order faces the normal
	// toward the camera the way Godot's own flat-shade examples do.
	NORMAL = normalize(cross(dFdy(VERTEX), dFdx(VERTEX)));
}
