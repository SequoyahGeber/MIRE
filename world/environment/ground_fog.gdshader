shader_type fog;

// Procedural ground mist (F-115).
//
// The map's fog used to be `Environment.volumetric_fog_density` applied uniformly across the whole
// 120 m froxel volume, which is by definition a flat full-screen haze: no height falloff, no
// variation, no motion. This replaces it with a density FUNCTION OF WORLD POSITION, which buys
// three things at once and costs one shader:
//
//   * it hugs the ground, because density falls off with height above `base_height`;
//   * it pools in low ground and over water, because it gets denser BELOW that height;
//   * it is patchy and it drifts, because the horizontal term is scrolling fbm.
//
// Density is evaluated in WORLD space, so the FogVolume this runs in is only a window saying
// "evaluate here". `world/environment/ground_fog.gd` slides that window along with the camera and
// the mist does not slide with it — which is the whole reason the pattern can be procedural and
// still feel like it belongs to the terrain rather than to the player.

// World Y the mist sits on. Above this it thins out over `layer_height`; below it thickens.
uniform float base_height = 4.0;
uniform float layer_height = 9.0;
// How far below `base_height` the mist keeps thickening before it stops. This is what fills the
// gorge and the mere without drowning the valley floor.
uniform float pool_depth = 14.0;
uniform float pool_gain = 1.6;
uniform float base_density = 0.055;
// Metres per noise unit. Smaller = larger, lazier banks.
uniform float patch_scale = 0.010;
// Below this the fbm is nothing; the gap between the two is the soft edge of a bank. Keeping the
// low end well above 0 is what makes CLEARINGS — without it every square metre has some mist and
// the result is the flat haze this shader exists to replace.
uniform float patch_floor = 0.42;
uniform float patch_ceiling = 0.78;
uniform vec2 drift = vec2(0.55, 0.22);
uniform vec3 fog_albedo : source_color = vec3(0.72, 0.76, 0.78);
uniform vec3 fog_emission : source_color = vec3(0.0, 0.0, 0.0);
uniform float emission_energy = 0.0;
uniform float density_scale = 1.0;

float hash21(vec2 p) {
	p = fract(p * vec2(233.34, 851.73));
	p += dot(p, p + 23.45);
	return fract(p.x * p.y);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	// Smoothstep the cell interpolation, or the banks come out as visible squares.
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Three octaves is enough: this is sampled per froxel, and a fourth octave is invisible through
// something as soft as fog while costing the same as the first three combined.
float fbm(vec2 p) {
	float total = 0.0;
	float amplitude = 0.5;
	for (int i = 0; i < 3; i++) {
		total += value_noise(p) * amplitude;
		p *= 2.07;
		amplitude *= 0.5;
	}
	return total;
}

void fog() {
	vec3 world = WORLD_POSITION;

	// Vertical shape. Squared falloff above the layer so the top edge is soft rather than a lid,
	// and a separate, gentler term below it so a hollow fills instead of clipping.
	float above = clamp(1.0 - (world.y - base_height) / max(layer_height, 0.01), 0.0, 1.0);
	above *= above;
	float below = clamp((base_height - world.y) / max(pool_depth, 0.01), 0.0, 1.0);
	float vertical = above + below * pool_gain;

	// Horizontal shape. Two scrolling layers at different rates so banks breathe and shear past
	// each other instead of sliding across the map as one rigid sheet.
	vec2 q = world.xz * patch_scale;
	float slow = fbm(q + drift * TIME * patch_scale);
	float fast = fbm(q * 2.3 - drift.yx * TIME * patch_scale * 2.6);
	float bank = smoothstep(patch_floor, patch_ceiling, slow * 0.68 + fast * 0.32);

	DENSITY = max(base_density * density_scale * vertical * bank, 0.0);
	ALBEDO = fog_albedo;
	EMISSION = fog_emission * emission_energy;
}
