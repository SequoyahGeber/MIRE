shader_type spatial;

// 4.18/D-184 — the ocean, in the SAME material language as the ground: `terrain_flat.gdshader`'s
// facet lighting (screen-space-derivative normals), full roughness, one flat colour — just blue,
// and bobbing. Sequoyah's direction after the first water pass: "make the water the same kinda
// material as the ground except make it blue" — the first version was glossy and semi-transparent,
// which read as a different rendering style sitting next to the matte island.
//
// The waves are geometry, not shading: two crossed sine displacements tilt the facets and the
// per-facet lighting does the rest, exactly how the ground gets its look from jittered vertices.
//
// No collision, on purpose: this mesh is paint. The walkable/standable world under the water is
// the seabed, which ChunkStreamer cooks colliders for like any other terrain.
//
// Client-local presentation only (ARCHITECTURE.md §2.2 "VFX" row): the wave phase runs on TIME,
// is never read by gameplay, and peers are free to disagree about it. The gameplay water level
// stays `water_surface_at()`'s flat 0 — these waves are ±0.18 m of paint, not a surface anything
// floats on. sin() here is fine: D-017's libm ban is about cross-peer WORLDGEN determinism, and
// nothing derives state from a rendered vertex.

// F-375: was vec3(0.30, 0.52, 0.72) — HSV 209 degrees / S 0.58 / V 0.72, a pale cyan-leaning blue.
// Nothing overrides it (`levels/procedural_island.tscn`'s WaterMaterial sets only `shader`), so this
// default IS the shipped sea, and in the 2026-08-20 play capture it read as a bright band around the
// island that pulled the eye straight off the land — brighter than the ground it borders
// (`chunk_streamer.gd`'s terrain albedo is Color(0.26, 0.40, 0.19), V 0.40). Sequoyah: "i want the
// water to be a darker blue".
//
// Now HSV 197.5 degrees / S 0.60 / V 0.40: value roughly halved so the sea sits a touch under the
// shoreline it meets instead of over it, hue pulled ~11 degrees toward cyan and saturation nudged up
// so what is left reads as deep water rather than as washed-out sky. Deliberately NOT taken further:
// F-356 already has night rendering too dark, and this mesh covers 1400 m square.
uniform vec3 albedo_color : source_color = vec3(0.16, 0.33, 0.40);
uniform float wave_height = 0.18;
uniform float wave_length = 14.0;
uniform float wave_speed = 0.8;

// Crest glint. The reference look is the standard low-poly-water trick: the base sheet stays one
// flat colour, and the facets that happen to sit on top of a wave AND happen to be tilted toward
// the sun get lightened toward white, so the sea reads as catching the sky instead of as a painted
// slab. Deliberately albedo, not a specular lobe — ROUGHNESS stays 1.0 and the material language
// stays the matte facet look the ground uses (D-184). A gloss highlight here is the exact thing the
// first water pass got wrong.
//
// It is gated three ways so that MOST of the water is still plain dark blue: only the top of a
// crest passes `crest_lo`, only facets tilted toward `sun_dir` pass the glint term, and a slow
// large-scale patch field mutes whole stretches of sea at a time. Without the patch field every
// crest on the grid lights up identically and the ocean turns into a striped tablecloth.
uniform vec3 glint_color : source_color = vec3(0.86, 0.92, 0.96);
uniform float glint_strength : hint_range(0.0, 1.0) = 0.75;
uniform float crest_lo : hint_range(0.0, 1.0) = 0.48;
uniform float crest_hi : hint_range(0.0, 1.0) = 0.98;
uniform vec3 sun_dir = vec3(0.45, 0.78, 0.44);

varying flat float crest;
varying flat float patch;
varying flat float facet_hash;
varying vec3 world_pos;

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float phase_a = (world.x * 0.9 + world.z * 0.45) * (TAU / wave_length) + TIME * wave_speed;
	float phase_b = (world.z * 0.8 - world.x * 0.35) * (TAU / (wave_length * 1.7))
		+ TIME * wave_speed * 1.3;
	float disp = sin(phase_a) * 0.6 + sin(phase_b) * 0.4;
	VERTEX.y += disp * wave_height;

	// -1..1 -> 0..1: how high this vertex sits within its own wave, independent of wave_height.
	crest = disp * 0.5 + 0.5;
	// Two very long, slowly drifting waves crossed at an angle — period ~200 m against the 14 m
	// wave length, so it reads as weather moving over the water rather than as a second wave.
	patch = sin(world.x * 0.031 + TIME * 0.11) * sin(world.z * 0.027 - TIME * 0.09) * 0.5 + 0.5;
	// A fixed 0..1 value per grid position. The waves are two clean sines on a regular grid, so
	// without this every crest in a row qualifies at the same instant and the sea renders as a
	// tiled sheet of identical white rectangles — which is exactly what the first version did.
	// Jittering the threshold and the patch gate per facet scatters the glints instead.
	facet_hash = fract(sin(dot(floor(world.xz), vec2(12.9898, 78.233))) * 43758.5453);
	world_pos = world;
}

void fragment() {
	// The facet normal twice: once in view space for lighting (VERTEX is view space here), once in
	// world space so the glint can be tested against a fixed sun direction that does not swing with
	// the camera. Same screen-space-derivative trick either way — the mesh carries no useful normals.
	NORMAL = normalize(cross(dFdy(VERTEX), dFdx(VERTEX)));
	vec3 facet_world = normalize(cross(dFdx(world_pos), dFdy(world_pos)));
	facet_world *= sign(facet_world.y);

	// The waves are only +/-0.18 m over ~8 m quads, so every facet normal is within a few degrees
	// of straight up and a normal-vs-sun dot is effectively constant. What DOES vary across a wave
	// is which way the facet leans horizontally, so the sun test is done in the ground plane: the
	// sunward face of a wave catches, the back of it does not.
	vec2 lean = facet_world.xz;
	float lit = dot(normalize(lean + vec2(1e-5)), normalize(sun_dir.xz));
	lit = smoothstep(-0.2, 0.9, lit) * smoothstep(0.002, 0.02, length(lean));

	float thresh = crest_lo + facet_hash * 0.30;
	float glint = smoothstep(thresh, min(thresh + 0.35, crest_hi), crest)
		* smoothstep(0.38, 0.88, patch * (0.55 + 0.45 * facet_hash))
		* mix(0.15, 1.0, lit);

	ALBEDO = mix(albedo_color, glint_color, glint * glint_strength);
	ROUGHNESS = 1.0;
}
