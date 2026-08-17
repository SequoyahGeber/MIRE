shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

uniform vec3 cloud_color : source_color = vec3(0.94, 0.95, 0.96);
uniform vec3 cloud_shadow : source_color = vec3(0.42, 0.48, 0.56);
uniform vec2 wind_direction = vec2(0.82, 0.28);
uniform float speed : hint_range(0.0, 0.03) = 0.003;
uniform float cloud_scale : hint_range(1.0, 32.0) = 5.0;
uniform float coverage : hint_range(0.2, 0.8) = 0.52;
uniform float softness : hint_range(0.02, 0.3) = 0.12;
uniform float opacity : hint_range(0.0, 1.0) = 0.68;
uniform float layer_offset = 0.0;


float random_value(vec2 position) {
	return fract(sin(dot(position, vec2(127.1, 311.7))) * 43758.5453);
}


float value_noise(vec2 position) {
	vec2 cell = floor(position);
	vec2 local = fract(position);
	local = local * local * (3.0 - 2.0 * local);
	float a = random_value(cell);
	float b = random_value(cell + vec2(1.0, 0.0));
	float c = random_value(cell + vec2(0.0, 1.0));
	float d = random_value(cell + vec2(1.0, 1.0));
	return mix(mix(a, b, local.x), mix(c, d, local.x), local.y);
}


float cloud_noise(vec2 position) {
	float value = 0.0;
	float amplitude = 0.56;
	for (int octave = 0; octave < 5; octave++) {
		value += value_noise(position) * amplitude;
		position = position * 2.03 + vec2(13.1, 7.7);
		amplitude *= 0.48;
	}
	return value;
}


void fragment() {
	vec2 drift = wind_direction * TIME * speed;
	vec2 position = UV * cloud_scale + drift + vec2(layer_offset, layer_offset * 0.37);
	float broad = cloud_noise(position);
	float detail = cloud_noise(position * 2.21 + vec2(4.2, 9.7));
	float field = mix(broad, detail, 0.24);
	float mask = smoothstep(coverage, coverage + softness, field);
	float edge_distance = min(min(UV.x, 1.0 - UV.x), min(UV.y, 1.0 - UV.y));
	mask *= smoothstep(0.0, 0.08, edge_distance);
	float light_mix = smoothstep(coverage - 0.1, coverage + 0.2, broad);
	ALBEDO = mix(cloud_shadow, cloud_color, light_mix);
	ROUGHNESS = 1.0;
	ALPHA = mask * opacity;
}
