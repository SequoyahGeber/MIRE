shader_type canvas_item;

// F-349: the screen-edge tint that tells a player they are standing in Blight.
//
// Blight drains hp whenever MireGrid.corruption_at(player_position) crosses
// PlayerHealth.BLIGHT_CORRUPTION_THRESHOLD, and until this shader existed NOTHING on screen said so.
// The health bar just fell. It was reported as a bug twice, by the same player, because from the
// inside it is indistinguishable from one.
//
// Deliberately an EDGE effect, not a full-screen wash: the middle of the screen is where the
// crosshair and whatever is trying to kill you both are, and a wash over it would trade one
// unreadable situation for another. The same reasoning `vitals_hud.gd` gives its banner placement.

// 0 = clean ground, 1 = fully corrupted. Drives radius and opacity together, so faint really is
// faint rather than a thin ring at full strength.
uniform float intensity : hint_range(0.0, 1.0) = 0.0;
uniform vec3 tint : source_color = vec3(0.42, 0.62, 0.20);
// How far in from the edge the vignette reaches at intensity 1. 0.5 would reach the centre.
uniform float max_reach : hint_range(0.05, 0.5) = 0.34;
// A slow breath so the effect reads as alive rather than as a static overlay artefact. Amplitude is
// tiny on purpose — this must never look like a flicker, which is the failure mode F-377 is about.
uniform float pulse_hz : hint_range(0.0, 2.0) = 0.35;
uniform float pulse_depth : hint_range(0.0, 0.5) = 0.12;

void fragment() {
	if (intensity <= 0.001) {
		COLOR = vec4(0.0);
	} else {
		// Distance from centre in a square-corrected space, so the band is even on wide viewports
		// instead of hugging the left and right edges.
		vec2 centred = (UV - vec2(0.5)) * vec2(2.0);
		float d = length(centred * vec2(1.0, 0.72));

		float reach = max_reach * intensity;
		float inner = 1.0 - reach;
		float band = smoothstep(inner, 1.0, d);

		float pulse = 1.0 + sin(TIME * pulse_hz * 6.2831853) * pulse_depth;
		float alpha = band * intensity * 0.85 * pulse;

		COLOR = vec4(tint, clamp(alpha, 0.0, 0.92));
	}
}
