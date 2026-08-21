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

// ---------------------------------------------------------------------------------------------
// F-435 · THE MIRE'S OWN FOG.
//
// Sequoyah, from play: "the tainted ground that starts damaging you has no indication that it's
// different... I feel like there should be low yellowy green fog and a purple hue to the ground."
// This is the fog half. `world/chunk/terrain_flat.gdshader` is the purple half, and both sample the
// SAME texture — `MireGrid.corruption_field_texture()` — so the two cues cannot drift apart about
// where the Mire actually is.
//
// It rides in this shader rather than in a second FogVolume for one reason: two overlapping
// FogVolumes are two full froxel evaluations of the same space, and the low-end target
// (docs/PERFORMANCE.md) does not have the second one to spare. One extra texture fetch does.
//
// THREE THINGS IT DELIBERATELY DOES NOT DO:
//
//   * It does not scale with `density_scale`. That is the daylight curve — mist at dawn, clear at
//     noon. The Mire is not weather; ground that drains your health has to look like it at noon
//     too, or the cue is missing exactly when players are out furthest from camp.
//   * It does not respect `patch_floor`'s clearings. The whole point of that term is to leave
//     honest gaps in the mist, and a gap in a WARNING is a lie. The bank noise still modulates the
//     blight fog, but between `BLIGHT_CHURN_FLOOR` and 1.0, so it churns without ever clearing.
//   * It does not sit only in hollows. This is the one that needed real machinery. The mist above
//     hangs off `base_height`, a SINGLE world Y measured off the level once, which is honest for
//     "mist pools in the valley" and useless here: `base_height` on a streamed island is pinned
//     just above the waterline (the seabed is in the terrain's AABB), so a blight layer 4.5 m thick
//     hung off it sits under the sea while the corruption it is meant to mark is thirty metres up
//     on the plateau. The first cut did exactly that and photographed as no fog at all.
//     `terrain_height_field` fixes it: a coarse height map of the level, so the blight layer hugs
//     whatever ground is actually below each froxel. A thin halo reaches `BLIGHT_REACH_M` above
//     that, so a corrupted hillside is still visible from the valley floor.
//
// It IS lost wholesale on the `low` graphics preset, which disables volumetric fog and makes every
// FogVolume a no-op. That is why the purple ground is the primary cue and this is the reinforcement,
// and not the other way around.

uniform sampler2D mire_field : hint_default_black, filter_linear, repeat_disable;
uniform float mire_field_half_extent = 118.0;
// Ground height in world Y, over [-terrain_field_half_extent, +terrain_field_half_extent] on both
// axes. Coarse on purpose — a fog layer metres thick does not care about metre-scale relief, and
// `ground_fog.gd` pays for every texel of this in `height_at()` calls at level load.
// `terrain_field_ready` is 0 until that map exists, and at 0 every use of it below falls back to
// `base_height`, which is the pre-F-435 behaviour and the right answer for a level with no
// queryable terrain.
uniform sampler2D terrain_height_field : hint_default_black, filter_linear, repeat_disable;
uniform float terrain_field_half_extent = 118.0;
uniform float terrain_field_ready = 0.0;
// Kept identical to the terrain shader's own three, and to
// `PlayerHealth.BLIGHT_CORRUPTION_THRESHOLD` in the middle. If one moves they all move.
const float BLIGHT_SEEN_AT = 0.03;
const float BLIGHT_HURTS_AT = 0.15;
const float BLIGHT_DEEP_AT = 0.55;
const float BLIGHT_HURTS_WEIGHT = 0.45;
// How far the dense, ground-hugging layer reaches, and how far the thin halo above it does.
//
// LOW is the whole brief — "low yellowy green fog" — and the number that makes it low is 2 m, not
// the 4.5 m the first cut used. A standing eye is at 1.7 m, so a layer taller than that puts the
// camera INSIDE the medium and every pixel of the frame, sky included, comes back through it: the
// photograph of that version reads as a green filter over the whole view rather than as mist lying
// on the ground ahead of you. At 2 m the quadratic falloff has the density at eye level down to a
// few percent of its value underfoot, which is the difference between looking AT fog and looking
// THROUGH it. Anything that raises this has to answer for that frame.
const float BLIGHT_LAYER_M = 3.0;
const float BLIGHT_REACH_M = 14.0;
const float BLIGHT_HALO_GAIN = 0.06;
// Least the drifting bank noise is ever allowed to thin the blight fog to. Never 0 — see above.
// Lower than it looks it should be: with the layer this shallow the churn is most of what stops the
// sheet from reading as a flat painted decal.
const float BLIGHT_CHURN_FLOOR = 0.35;
// Higher than the first cut BECAUSE the layer is shallower — this is density per unit, and a 2 m
// layer has less than half the path length of the 4.5 m one to accumulate in.
uniform float blight_density = 0.44;
// Yellow-green, low chroma. Fog albedo is what the sun and sky tint THROUGH, so a saturated green
// here comes out neon; this is the dull sulphur-on-moss it needs to read as by daylight.
uniform vec3 blight_fog_albedo : source_color = vec3(0.50, 0.57, 0.22);
// Self-light, and it carries more of this effect than it looks like it should. The level's
// `volumetric_fog_anisotropy` is 0.92 — very strongly forward-scattering — so a purely scattering
// medium is nearly invisible unless you happen to be looking toward the sun, and the Mire has to
// read from every heading and at night. Emission does not care which way the light came from. It is
// also what makes this a SICKLY glow rather than grey mist, which is the half of "yellowy green"
// that albedo alone cannot say.
uniform float blight_emission_energy = 0.75;
uniform float blight_strength : hint_range(0.0, 2.0) = 1.0;

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

	float mist = max(base_density * density_scale * vertical * bank, 0.0);

	// F-435. Same mapping as `MireGridSim.world_to_cell()` and the terrain shader's `mire_uv`.
	vec2 mire_uv = (world.xz + vec2(mire_field_half_extent))
		/ max(mire_field_half_extent * 2.0, 0.001);
	float corruption = texture(mire_field, mire_uv).r;
	// Two ramps, weighted so most of the change has landed by the time corruption reaches the value
	// that starts draining health — see the terrain shader for why that split exists.
	float blight = smoothstep(BLIGHT_SEEN_AT, BLIGHT_HURTS_AT, corruption) * BLIGHT_HURTS_WEIGHT
		+ smoothstep(BLIGHT_HURTS_AT, BLIGHT_DEEP_AT, corruption) * (1.0 - BLIGHT_HURTS_WEIGHT);
	blight = clamp(blight * blight_strength, 0.0, 1.0);

	// Vertical shape, measured from the GROUND under this froxel rather than from the level's one
	// datum — see the third bullet in the header. Below the surface `hug` simply saturates, which is
	// what fills a corrupted gorge to its rim without a separate pooling term.
	vec2 terrain_uv = (world.xz + vec2(terrain_field_half_extent))
		/ max(terrain_field_half_extent * 2.0, 0.001);
	float ground_y = mix(
		base_height, texture(terrain_height_field, terrain_uv).r, terrain_field_ready);
	float above_ground = world.y - ground_y;
	// CUBED, not squared. What is being controlled is the residual at eye height: whatever density
	// survives at 1.7 m is multiplied by the whole hundred-metre depth of the view and comes back as
	// a wash over the frame. A square leaves ~5% of peak up there, a cube leaves ~1%, and that one
	// order of magnitude is the difference between mist lying on the ground and a green filter.
	float hug = clamp(1.0 - above_ground / BLIGHT_LAYER_M, 0.0, 1.0);
	hug = hug * hug * hug;
	float halo = clamp(1.0 - above_ground / BLIGHT_REACH_M, 0.0, 1.0) * BLIGHT_HALO_GAIN;
	float blight_vertical = hug + halo;
	// `fast` rather than `bank`: the blight fog breathes on the quicker of the two layers, which
	// separates it from the mist it is sitting inside of instead of moving in lockstep with it.
	float churn = mix(BLIGHT_CHURN_FLOOR, 1.0, fast);
	float blight_fog = max(blight_density * blight * blight_vertical * churn, 0.0);

	DENSITY = mist + blight_fog;
	// Weighted by how much of the density each side actually contributed, so a bank of ordinary
	// mist drifting over clean ground stays grey and the same bank over the Mire goes sour.
	float blight_share = blight_fog / max(mist + blight_fog, 0.0001);
	ALBEDO = mix(fog_albedo, blight_fog_albedo, blight_share);
	EMISSION = fog_emission * emission_energy
		+ blight_fog_albedo * blight_emission_energy * blight_share * blight;
}
