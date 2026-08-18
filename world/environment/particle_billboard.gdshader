shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform int particle_shape = 0;

void vertex() {
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0],
		INV_VIEW_MATRIX[1],
		INV_VIEW_MATRIX[2],
		MODEL_MATRIX[3]
	);
}

void fragment() {
	vec2 centred = UV * 2.0 - 1.0;
	float alpha_mask;
	// Tint and emission are decided alongside the mask rather than after it, because the leaf
	// shape wants neither of the defaults: it is not self-lit, and it has a darker midrib.
	vec3 tint = COLOR.rgb;
	float emission_scale = particle_shape < 2 ? 1.4 : 0.0;
	if (particle_shape == 0) {
		// Broad at the base, narrow and ragged at the tip: a low-poly flame tongue.
		float vertical = 1.0 - UV.y;
		float half_width = mix(0.08, 0.78, pow(vertical, 0.72));
		float side = 1.0 - smoothstep(half_width * 0.72, half_width, abs(centred.x));
		float base = smoothstep(0.0, 0.16, vertical);
		float tip = smoothstep(0.0, 0.12, UV.y);
		alpha_mask = side * base * tip;
	} else if (particle_shape == 1) {
		float radius = length(centred);
		alpha_mask = 1.0 - smoothstep(0.28, 0.95, radius);
	} else if (particle_shape == 2) {
		float radius = length(centred * vec2(0.82, 1.0));
		alpha_mask = 1.0 - smoothstep(0.18, 1.0, radius);
		alpha_mask *= 0.42;
	} else {
		// A leaf: a pointed ellipse, narrower at both ends than in the middle, with a darker
		// midrib down it so a tumbling leaf reads as a leaf and not as a floating pill.
		float taper = 1.0 - pow(abs(centred.y), 1.7);
		float half_width = taper * 0.82;
		alpha_mask = 1.0 - smoothstep(half_width * 0.55, half_width, abs(centred.x));
		alpha_mask *= smoothstep(0.0, 0.12, taper);
		float midrib = 1.0 - smoothstep(0.0, 0.07, abs(centred.x));
		tint = COLOR.rgb * mix(1.0, 0.62, midrib * taper);
		emission_scale = 0.0;
	}
	ALBEDO = tint;
	EMISSION = tint * emission_scale;
	ALPHA = COLOR.a * alpha_mask;
}
