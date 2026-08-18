shader_type spatial;
render_mode cull_disabled, diffuse_burley;

// Wind for asset-bound foliage (F-097). One material per (asset, surface); every instance of that
// asset in the world shares it, whether it is drawn as a MeshInstance3D or as one copy inside a
// MultiMesh. Nothing here knows what level it is in.
//
// The per-instance parameters this shader used to take as `instance uniform` are gone on purpose:
// instance uniforms are per MeshInstance3D and do not reach individual MultiMesh copies, which is
// most of the world. Everything that varies per copy is now derived from the copy's own transform,
// which MultiMesh does provide through MODEL_MATRIX.

uniform vec4 albedo_color : source_color = vec4(0.24, 0.42, 0.16, 1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.9;
uniform bool use_vertex_color = false;

// Shared weather. EnvironmentVfx pushes the same values to every foliage material, so a gust
// crosses the whole map as one front rather than each asset weathering privately.
uniform vec2 wind_direction = vec2(0.82, 0.57);
uniform float wind_speed_scale : hint_range(0.0, 4.0) = 1.0;
uniform float wind_gain : hint_range(0.0, 3.0) = 1.0;
uniform float gust_strength : hint_range(0.0, 1.0) = 0.32;

// Per-asset, from AssetVfxLibrary.SWAY_PROFILES.
uniform float sway_strength : hint_range(0.0, 0.5) = 0.105;
uniform float sway_speed : hint_range(0.0, 5.0) = 1.35;
uniform float bob_strength : hint_range(0.0, 0.3) = 0.0;
uniform float mask_power : hint_range(0.0, 6.0) = 1.0;
uniform float vertex_phase : hint_range(0.0, 1.0) = 1.0;
uniform float wind_root_y = 0.0;
uniform float wind_inv_height = 1.0;

void vertex() {
	// Height mask in MODEL space, so it stays valid wherever in the world the copy stands — a
	// world-space mask would saturate for anything growing on the plateau.
	float height_mask = clamp((VERTEX.y - wind_root_y) * wind_inv_height, 0.0, 1.0);
	height_mask = height_mask * height_mask * (3.0 - 2.0 * height_mask);
	// mask_power == 0 means "move the whole asset as one piece" — lily pads, which float rather
	// than bend. Branching on a uniform is coherent across the draw and effectively free.
	if (mask_power > 0.0) {
		height_mask = pow(height_mask, mask_power);
	} else {
		height_mask = 1.0;
	}

	vec3 instance_origin = MODEL_MATRIX[3].xyz;
	vec3 world_vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// vertex_phase = 1 takes the wave's phase from where the vertex actually stands, so the field
	// keeps rippling per-plant even if the instances are later merged into one static chunk mesh
	// (F-098). vertex_phase = 0 takes it from the object origin, which a tree needs: a phase that
	// varies across an 8 m crown shears the crown instead of leaning it.
	vec2 phase_position = mix(instance_origin.xz, world_vertex.xz, vertex_phase);
	float position_phase = dot(phase_position, vec2(0.173, 0.119));

	float t = TIME * sway_speed * wind_speed_scale;
	float breeze = sin(t + position_phase);
	float gust = sin(t * 0.37 + position_phase * 0.43);
	gust = smoothstep(0.15, 1.0, gust) * gust_strength;

	// Wind blows in a world direction, but VERTEX is model space and every prop is placed with its
	// own yaw. Rotating the direction into model space is what stops each plant leaning its own
	// way. The generators build Basis(UP, yaw) with uniform scale, so normalising two basis columns
	// recovers an orthonormal frame and a dot product is the whole inverse rotation.
	vec3 wind_world = vec3(wind_direction.x, 0.0, wind_direction.y);
	wind_world = normalize(wind_world);
	vec3 basis_x = normalize(MODEL_MATRIX[0].xyz);
	vec3 basis_z = normalize(MODEL_MATRIX[2].xyz);
	vec2 wind_local = vec2(dot(wind_world, basis_x), dot(wind_world, basis_z));

	VERTEX.xz += wind_local * ((breeze + gust) * sway_strength * wind_gain) * height_mask;
	VERTEX.y += sin(t * 0.8 + position_phase * 1.7) * bob_strength;
}

void fragment() {
	vec3 base = albedo_color.rgb;
	if (use_vertex_color) {
		base *= COLOR.rgb;
	}
	ALBEDO = base;
	ROUGHNESS = roughness;
}
