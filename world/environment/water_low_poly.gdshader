shader_type spatial;
render_mode cull_disabled;

// 4.18/D-184 — the ocean. Low-poly water to match `terrain_flat.gdshader`'s faceted ground: a
// subdivided plane whose vertices bob on two crossed sine waves, lit one facet at a time by the
// same screen-space-derivative normal trick the terrain uses. The playtest that prompted this had
// NO water at all — the seabed used to sit at exactly y=0, so "the sea" rendered as more green
// land (see `IslandHeightmap.OCEAN_FLOOR_DEPTH`).
//
// Client-local presentation only (ARCHITECTURE.md §2.2 "VFX" row): the wave phase runs on TIME,
// is never read by gameplay, and peers are free to disagree about it. The gameplay water level
// stays `water_surface_at()`'s flat 0 — these waves are ±0.18 m of paint, not a surface anything
// floats on. sin() here is fine: D-017's libm ban is about cross-peer WORLDGEN determinism, and
// nothing derives state from a rendered vertex.

uniform vec3 shallow_color : source_color = vec3(0.35, 0.62, 0.62);
uniform vec3 deep_color : source_color = vec3(0.12, 0.32, 0.42);
uniform float opacity : hint_range(0.0, 1.0) = 0.78;
uniform float wave_height = 0.18;
uniform float wave_length = 14.0;
uniform float wave_speed = 0.8;

varying float wave_lift;

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float phase_a = (world.x * 0.9 + world.z * 0.45) * (TAU / wave_length) + TIME * wave_speed;
	float phase_b = (world.z * 0.8 - world.x * 0.35) * (TAU / (wave_length * 1.7))
		+ TIME * wave_speed * 1.3;
	wave_lift = sin(phase_a) * 0.6 + sin(phase_b) * 0.4;
	VERTEX.y += wave_lift * wave_height;
}

void fragment() {
	ALBEDO = mix(deep_color, shallow_color, clamp(wave_lift * 0.5 + 0.5, 0.0, 1.0));
	ALPHA = opacity;
	ROUGHNESS = 0.18;
	SPECULAR = 0.4;
	NORMAL = normalize(cross(dFdy(VERTEX), dFdx(VERTEX)));
}
