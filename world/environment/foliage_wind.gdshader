shader_type spatial;
render_mode cull_disabled, diffuse_burley;

uniform vec4 albedo_color : source_color = vec4(0.24, 0.42, 0.16, 1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.9;
uniform vec2 wind_direction = vec2(0.82, 0.57);
uniform float wind_strength : hint_range(0.0, 0.5) = 0.105;
uniform float wind_speed : hint_range(0.0, 5.0) = 1.35;
uniform float gust_strength : hint_range(0.0, 1.0) = 0.32;

instance uniform float wind_root_y = 0.0;
instance uniform float wind_inv_height = 1.0;
instance uniform float wind_phase = 0.0;

void vertex() {
	float height_mask = clamp((VERTEX.y - wind_root_y) * wind_inv_height, 0.0, 1.0);
	height_mask = height_mask * height_mask * (3.0 - 2.0 * height_mask);
	vec3 world_origin = MODEL_MATRIX[3].xyz;
	float position_phase = dot(world_origin.xz, vec2(0.173, 0.119));
	float breeze = sin(TIME * wind_speed + position_phase + wind_phase);
	float gust = sin(TIME * wind_speed * 0.37 + position_phase * 0.43);
	gust = smoothstep(0.15, 1.0, gust) * gust_strength;
	vec2 direction = normalize(wind_direction);
	VERTEX.xz += direction * (breeze * wind_strength + gust * wind_strength) * height_mask;
}

void fragment() {
	ALBEDO = albedo_color.rgb;
	ROUGHNESS = roughness;
}
