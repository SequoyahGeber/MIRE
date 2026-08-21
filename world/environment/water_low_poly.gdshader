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

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float phase_a = (world.x * 0.9 + world.z * 0.45) * (TAU / wave_length) + TIME * wave_speed;
	float phase_b = (world.z * 0.8 - world.x * 0.35) * (TAU / (wave_length * 1.7))
		+ TIME * wave_speed * 1.3;
	VERTEX.y += (sin(phase_a) * 0.6 + sin(phase_b) * 0.4) * wave_height;
}

void fragment() {
	ALBEDO = albedo_color;
	ROUGHNESS = 1.0;
	NORMAL = normalize(cross(dFdy(VERTEX), dFdx(VERTEX)));
}
