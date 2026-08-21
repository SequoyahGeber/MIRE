extends Node

## Local presentation controller for the level's sky, sun, fog, star field, and light shafts.
## The optional clock is deliberately disabled by default and must stay that way — DayNight (the
## host-authoritative autoload) calls set_time_of_day() on every peer instead. Leaving
## cycle_enabled true would free-run a separate local clock per peer, which is the trap
## docs/SPECS.md 2.11 and systems/environment/day_night.gd both warn about.
##
## F-065 lived here: the clock arrived correctly and nothing downstream of it made night look like
## night. The cloud deck is an UNSHADED material, so dimming the sun could never darken it, and
## there was no star layer at all. apply_atmosphere() now drives both, plus the night ends of the
## sky material, on the same daylight curve everything else already used.
##
## F-378 is the same shape of bug one level up: the clock and the grade were both right, and the sky
## still had no SUN in it — only a haze where one should be — and no moon at all, because the level
## contained exactly one light. Both are owned here now (see the SUN_* and moon blocks below), which
## also settles F-356: night is dark because nothing is lit at night, and the fix for that is a
## second light, not a higher ambient floor.
##
## Everything in this file is client-local presentation (docs/ARCHITECTURE.md §2.2, "VFX, audio,
## camera, UI" row). It reads a replicated number and touches no gameplay state, so nothing here
## bumps the protocol version. That covers the moon too: it is derived from the same replicated
## `time_of_day` every peer already has, so every peer builds an identical one and none of it
## crosses the wire.

const STAR_FIELD_SCRIPT := preload("res://world/environment/star_field.gd")
const GROUND_FOG_SCRIPT := preload("res://world/environment/ground_fog.gd")

## Sun elevation, in degrees, across which the stars come out: fully out below the first, gone above
## the second. A window rather than a threshold, so dusk is a fade and not a light switch.
##
## The width is not cosmetic. Elevation moves fastest exactly at the horizon (~24 deg per game hour
## here), so a narrow window is crossed in a couple of real seconds and reads as a switch — the
## first version of this used -9..+3 and tools/atmosphere_night_check.gd caught it snapping. Ending
## at -1 also keeps the physics honest: no stars while the sun is still up.
const STARS_FULL_ELEVATION: float = -16.0
const STARS_GONE_ELEVATION: float = -1.0
## Sun elevation window over which the SKY MATERIAL itself turns to its night colours. Deliberately
## later than `daylight`: at elevation 0 the sun is on the horizon, which is when the sky and the
## cloud deck should be at their warmest, not already grey. Driving the sky's mie/rayleigh colours
## off `daylight` (which is ~0.3 by then) washed the sunset out entirely — the first night render
## showed a grey 18:00 with pale clouds, which is F-065 again, just an hour earlier.
const SKY_NIGHT_FULL_ELEVATION: float = -14.0
const SKY_NIGHT_START_ELEVATION: float = -1.0
## Half-width, in degrees of elevation, of the golden hour either side of the horizon.
const GOLDEN_HALF_WIDTH: float = 18.0
## F-090: DayNight advances time every physics tick, and a sun transform that dirties every
## tick keeps the PhysicalSky radiance perpetually regenerating for ~0.001° of motion no eye
## can see. The applied hour is stepped instead: at the default 900 s day this moves the sun
## about five times a second in ~0.1° increments — under the sun's own 1.1 shadow blur.
const SUN_STEP_HOURS: float = 0.005
## Night ends of the sky-material lerps. Their day ends are read off the authored resource in
## _ready() rather than written here, so noon renders exactly as the scene author tuned it and this
## fix can only change how dusk and night look.
const NIGHT_RAYLEIGH_COLOR := Color(0.07, 0.11, 0.29)
const NIGHT_MIE_COLOR := Color(0.14, 0.18, 0.31)
const NIGHT_GROUND_COLOR := Color(0.017, 0.022, 0.036)
## The 26% of ambient that does not come from the sky (see the level's
## ambient_light_sky_contribution). With the night sky now genuinely dark, this is the floor that
## keeps a night you can still fight in — night should be dangerous, not unreadable.
const NIGHT_AMBIENT_COLOR := Color(0.34, 0.42, 0.62)

## ── The sun's disc (F-378) ────────────────────────────────────────────────────────────────────
## Sequoyah, from play: "the sun doesnt have a clear circle form in the sky its more of a faded haze
## thats way to wide."
##
## MEASURED FIRST, because the obvious answer was wrong. `tools/_tmp_sun_halo_probe.gd` (throwaway,
## not committed) rendered the same sunward frame under nine variants in one run and reported how far
## out the frame is still pure white. The result that decided everything below: with the sun's disc
## turned OFF ENTIRELY (`light_angular_distance = 0`), the white region did not shrink by a single
## pixel — 6.22 deg either way. Disabling `glow` did not move it either. **The blob was never the
## disc and never the bloom; it was the SKY, blown past the white point across 6 degrees of solid
## angle, with the disc invisible inside it because both sides of its edge tonemapped to 1.0.**
##
## So the fix is not to draw a bigger sun, it is to stop the sky around it clipping — and then the
## disc's own hard edge (the sky shader's `smoothstep` is razor-sharp) has something to be an edge
## AGAINST. Three numbers, in the order they matter:
##
##   · SKY ENERGY. `energy_multiplier` scales the whole sky, disc and halo alike, and at the 0.9 it
##     ran at, everything within 6 deg of the sun was over 1.0. At 0.45 the white region is 3.5 deg
##     and the rest of the sky comes back as a deeper blue instead of the pale wash it was — the
##     same washed-out sky F-357 is still open about, improved as a side effect rather than by
##     chasing it.
##   · MIE. `mie_coefficient` sets the peak of the forward-scattering lobe and `mie_eccentricity`
##     its width. Raising eccentricity alone is a trap and this file fell in it once: the
##     Henyey-Greenstein peak scales as roughly 1/(1-g)^2, so going 0.74 -> 0.86 narrowed the lobe
##     from a 13 deg half-width to 6.6 deg while making it 3.7x BRIGHTER, and the blown region did
##     not move. The coefficient comes down by the same factor the peak went up.
##   · THE DISC. Now that the sky's white stops at ~3.5 deg, the disc has to be bigger than that or
##     it is still inside it — measured, 6.8 deg apparent is where a circle with a visible edge
##     appears. That is thirteen times the real sun, and it is the number the frame asked for.
##
## The two angular knobs stay split, which is what makes a 6.8 deg sun affordable at all.
## `light_angular_distance` is ALSO the shadow penumbra — a 6.8 deg light would blur every shadow on
## the map into a smear — while `sun_disk_scale` is sky-shader-only and costs nothing anywhere else.
## So the light keeps a near-real 0.85 deg and the sky does all of the exaggerating.
##
## Written here rather than read off the level: this is one look decision for the whole game, the
## same standing `turbidity` already had, and a level that authors its own is a level whose sun is a
## different size for no reason anyone chose.
const SUN_ANGULAR_DIAMETER_DEG: float = 0.85
const SUN_DISK_SCALE: float = 8.0
const MIE_ECCENTRICITY: float = 0.86
const MIE_COEFFICIENT: float = 0.0013
## Day end of the sky's own `energy_multiplier`. The night end stays where F-065 put it.
const DAY_SKY_ENERGY: float = 0.45
const NIGHT_SKY_ENERGY: float = 0.055
## `turbidity` multiplies the mie term outright, and it used to be lerped UP to 10.0 at night — so
## the haze was thickest exactly across dusk and dawn, the two hours a player is most likely to be
## looking straight at the sun, and the hours the verdict came from.
const DAY_TURBIDITY: float = 4.6
const NIGHT_TURBIDITY: float = 3.4

## ── The moon (F-378, and the answer to F-356) ─────────────────────────────────────────────────
## Sequoyah, same session: "night time could be slightly less dark but only because of moonlight so
## we need to add a moon in that cast cool white light dimmly over the map."
##
## Until this there was exactly one DirectionalLight3D in the level, named `Sun`, and night was that
## light dimmed to 0.04 and tinted blue. That is why F-356 measured a night whose ground luminance
## median was 0.000: nothing was LIT, so there was nothing for the grade to bring back. The fix is a
## second light and specifically NOT a higher ambient floor — ambient with no key flattens the
## flat-shaded facets (D-184) that are the only thing giving the ground form, so a raised floor
## would have bought a visible night by deleting the terrain's shape.
##
## Built in code, like the star field and the ground mist above it, for the same reason: release
## worlds are procedurally generated and have no level author to remember to place one.
##
## It rides the sun's own clock, rotated exactly opposite, so it rises as the sun sets. Its energy
## follows `starlight` — the same window the stars fade in across — and the sun's shadows are
## switched off for as long as the moon's are on, so the map never pays for two shadow-casting
## directional lights at once and exactly one of the two is meaningfully lit at any hour.
const MOONLIGHT_COLOR := Color(0.66, 0.76, 1.0)
## Roughly a seventh of the day sun. Moonlight has to read as "you can just make out the ground",
## never as a blue midday: the whole point of night is that it is dangerous.
const MOON_ENERGY: float = 0.55
## Tighter than the sun's, because the moon's shadows are the ones most likely to look wrong — a
## soft-edged shadow at this energy is a smudge rather than a shape.
const MOON_ANGULAR_DIAMETER_DEG: float = 0.6
## Moonlight is a rim light, not a key. At full opacity its shadows read as a second midday's, which
## is the tell that a "moon" is really just a blue sun.
const MOON_SHADOW_OPACITY: float = 0.55
## One split, and only as far as anything is legible at night anyway — this is the "shadows on but
## cheap" half of the trade that lets the sun's own shadows switch off at the same time.
const MOON_SHADOW_DISTANCE_M: float = 48.0

## ── The daytime varnish (F-353) ────────────────────────────────────────────────────────────────
## Sequoyah, on the shipped island: "it looks super washed out and looks like it needs a coat of
## varnish to make everything clear and saturated." Measured, the frame lived in a 0.48-0.71
## luminance band with nothing black, nothing white, and a saturation median of 0.24.
##
## Every constant below is the DAY end of a lerp whose NIGHT end is the value the scene author
## already set, so this is a daytime change and only a daytime change — at `daylight` 0 the grade
## comes back byte-identical to what shipped, which is what keeps a separately-broken night (F-356)
## out of this fix's blast radius. They are hard-coded ends rather than captured exports for the
## same reason `ambient_light_energy` and `tonemap_exposure` already were: this block is a tuned
## curve, and reading half of it off the resource would hide half the tuning.
##
## What each one was doing to the frame:
##
##   · WHITE POINT. ACES normalises by the tonemapped white, so `tonemap_white = 3.0` mapped the
##     scene's real 0..1 range into the toe of the curve — blacks lifted, highlights never
##     arrived. 1.0 gives the range back.
##   · GLOW BLOOM. `glow_bloom` applies glow to the whole frame BELOW the HDR threshold; at 0.14 it
##     is a milk pass over every pixel regardless of brightness. Dropping it took the darkest pixel
##     in the frame from 0.164 to 0.070 — that is where the blacks had gone. The threshold goes to
##     1.0 and the intensity down with it so the sun disk stops smearing across a quarter of the sky.
##   · AMBIENT FILL. D-184's terrain is flat-shaded with no texture and no normal map, so
##     facet-to-facet radiance difference is the ONLY thing that gives the ground form. At 0.62 a
##     facet turned 30 deg off the sun read the same as one facing it: two ground samples 150 px
##     apart measured one 1/255 step apart. The sky contribution stays at the authored 0.68, so what
##     is left of the fill is blue — warm light against cool shadow is most of the perceived chroma.
##   · SATURATION AND CONTRAST. The grade's own last word, once the three above stopped fighting it.
const DAY_TONEMAP_WHITE: float = 1.0
const DAY_TONEMAP_EXPOSURE: float = 0.95
## F-378 raised this from F-353's 0.30, and it is NOT a walk-back of that fix — it is what keeps it.
## 68% of the ambient term is the sky (the level's own `ambient_light_sky_contribution`), and F-378
## halved the sky's radiance to stop it blowing out around the sun. That silently halved the fill
## F-353 tuned, and the first render after it showed exactly what F-353's own note predicts: with
## the blue sky bounce gone, warm sunlight was the only thing left on the ground and a khaki forest
## floor came back reading as desert. This puts most of that fill back — "warm light against cool
## shadow is most of the perceived chroma" is the sentence being preserved here, not overruled.
##
## PARTIAL, not a full restoration, and the difference was rendered rather than reasoned. A full
## compensation is about 0.45, and at 0.45 the ground came back BRIGHTER and FLATTER instead of
## cooler: only 68% of the fill is the sky, the other 32% is `ambient_light_color` at whatever the
## level authored (white, on both shipped levels), so scaling the whole term to make up a halved sky
## overshoots on the half that never changed — and washing out the flat-shaded facets is precisely
## what F-353 lowered this number to stop.
const DAY_AMBIENT_ENERGY: float = 0.36
const DAY_ADJUSTMENT_CONTRAST: float = 1.14
const DAY_ADJUSTMENT_SATURATION: float = 1.30
const DAY_GLOW_BLOOM: float = 0.0
const DAY_GLOW_HDR_THRESHOLD: float = 1.0
const DAY_GLOW_INTENSITY: float = 0.70
const DAY_SUN_ENERGY: float = 1.55
## Night ends — the values `levels/procedural_island.tscn` and `levels/hollowmere.tscn` author, kept
## here so the lerp is readable in one place. A scene that authors different ones is not wrong, it
## just stops being the night end of this particular curve; nothing downstream depends on the match.
const NIGHT_TONEMAP_WHITE: float = 3.0
const NIGHT_TONEMAP_EXPOSURE: float = 0.85
const NIGHT_AMBIENT_ENERGY: float = 0.22
const NIGHT_ADJUSTMENT_CONTRAST: float = 1.03
const NIGHT_ADJUSTMENT_SATURATION: float = 1.14
const NIGHT_GLOW_BLOOM: float = 0.14
const NIGHT_GLOW_HDR_THRESHOLD: float = 0.92
const NIGHT_GLOW_INTENSITY: float = 1.05
## Exponential DISTANCE fog, restored. F-115 zeroed this to kill a uniform grey blanket, and that
## was right, but zero left the level's `fog_height_density` as the only fog the Environment
## applied — and the height term is `max`ed in independently of this one, so it kept blending grey
## into everything below y=6 AT EVERY DISTANCE, the player's own feet included. The heights are off
## in the scenes now and this puts the haze back where it belongs: 1.6% at 10 m, 15% at 100 m,
## nothing you can see up close and real aerial perspective on a far shore.
const DAY_FOG_DENSITY: float = 0.0016

## ── Ground mist (F-115) ───────────────────────────────────────────────────────────────────────
## Mist is a dawn and dusk thing. It burns off through the morning, is thinnest at noon, and comes
## back as the ground gives up its heat — which is also exactly when the low sun is raking through
## it, so the two effects pay for each other. `daylight` is 0 at night and 1 at noon, so the curve
## below is "thick at both ends, thin in the middle" rather than a straight lerp.
const FOG_NIGHT_SCALE: float = 1.35
const FOG_DAWN_SCALE: float = 1.75
const FOG_NOON_SCALE: float = 0.55
## What the mist is made of, at noon and at midnight. Warm grey by day so a sunbeam through it
## reads as light rather than as smoke; cold and dim by night so it hides things.
const FOG_DAY_ALBEDO := Color(0.80, 0.80, 0.76)
const FOG_NIGHT_ALBEDO := Color(0.36, 0.42, 0.55)
## A little self-lit warmth at golden hour, so mist in shadow still catches the hour's colour
## instead of going flat grey the moment the sun is behind a ridge.
const FOG_GOLDEN_EMISSION := Color(1.0, 0.62, 0.34)

@export_range(0.0, 24.0, 0.05) var time_of_day: float = 8.35
@export var cycle_enabled: bool = false
@export_range(60.0, 3600.0, 1.0) var day_length_seconds: float = 900.0
@export_range(0.25, 2.0, 0.01) var haze_strength: float = 1.0
## How hard the sun writes into the volumetric medium. Raised well above 1 for F-115's second half:
## with the uniform haze gone, the medium a shaft travels through is thin, and the shaft has to be
## driven harder to read at all. This is the knob for "more Valheim", and it costs nothing —
## `DirectionalLight3D.light_volumetric_fog_energy` is a multiply in a pass that already runs.
@export_range(0.0, 6.0, 0.01) var god_ray_strength: float = 2.4

@onready var world_environment := get_node(^"../WorldEnvironment") as WorldEnvironment
@onready var sun := get_node(^"../Sun") as DirectionalLight3D

var _environment: Environment
var _sky_material: PhysicalSkyMaterial
var _local_fog_materials: Array[FogMaterial] = []
var _local_fog_densities: Array[float] = [0.24, 0.07, 0.09]
var _cloud_deck: Node = null
var _star_field: Node3D = null
var _ground_fog: FogVolume = null
var _moon: DirectionalLight3D = null
# Authored day ends, captured once so the night lerps cannot drift the tuned daytime look.
var _day_rayleigh_color := Color(0.2, 0.4, 0.9)
var _day_mie_color := Color(0.94, 0.7, 0.48)
var _day_ground_color := Color(0.06, 0.085, 0.07)
var _day_ambient_color := Color(1.0, 1.0, 1.0)
# The driver values the last full apply ran with — empty forces the first apply through. F-090:
# DayNight re-applies ~60x/s, and outside dawn/dusk every driver below is a saturated constant,
# so the sky/environment/fog writes were identical rewrites that still dirtied the sky's
# radiance. Comparing the drivers is the cheap way to skip them; any input change (time,
# haze_strength, god_ray_strength) lands in the vector, so explicit setters need no special
# invalidation.
var _applied_drivers := PackedFloat64Array()
# The stepped hour the sun/star transforms were last written at. NAN so the first apply always
# writes. Rewriting an identical rotation still dirties the Node3D and the light behind it,
# which is exactly the per-tick radiance invalidation this file is trying to stop.
var _applied_sun_hour: float = NAN


func _ready() -> void:
	if world_environment == null or world_environment.environment == null or sun == null:
		push_error("PlaytestAtmosphere requires sibling WorldEnvironment and Sun nodes")
		set_process(false)
		return
	_environment = world_environment.environment
	_day_ambient_color = _environment.ambient_light_color
	if _environment.sky != null:
		_sky_material = _environment.sky.sky_material as PhysicalSkyMaterial
	if _sky_material != null:
		_day_rayleigh_color = _sky_material.rayleigh_color
		_day_mie_color = _sky_material.mie_color
		_day_ground_color = _sky_material.ground_color
		# F-378: the disc's size and the halo's WIDTH are standing look decisions, not per-hour
		# ones, so they are written once here rather than re-lerped 60 times a second. See the
		# SUN_* block for why the two angular knobs are separate.
		_sky_material.sun_disk_scale = SUN_DISK_SCALE
		_sky_material.mie_eccentricity = MIE_ECCENTRICITY
		_sky_material.mie_coefficient = MIE_COEFFICIENT
	# F-378: the sun's angular size was never set from here, so how big the game's sun is depended on
	# which level you were standing in. It is a light property rather than a sky one because it is
	# also the shadow penumbra, which is exactly why it is kept tight and `sun_disk_scale` above does
	# the exaggerating.
	sun.light_angular_distance = SUN_ANGULAR_DIAMETER_DEG
	# The sky shader only ever reads LIGHT0, and the moon below sets SKY_MODE_LIGHT_ONLY so it can
	# never become that light. Stating the sun's own mode explicitly is the other half of that
	# guarantee: if the moon ever took LIGHT0, the sun's disc would be drawn wherever the MOON is.
	sun.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_AND_SKY
	_moon = _resolve_moon()
	for fog_path: NodePath in [^"../MireGroundFog", ^"../ForestMist", ^"../RuinsMist"]:
		var fog_volume := get_node_or_null(fog_path) as FogVolume
		if fog_volume != null and fog_volume.material is FogMaterial:
			_local_fog_materials.append(fog_volume.material as FogMaterial)
	_cloud_deck = _resolve_cloud_deck()
	_star_field = _resolve_star_field()
	_ground_fog = _resolve_ground_fog()
	apply_atmosphere()
	set_process(cycle_enabled)


## The cloud deck is a sibling, but it is named differently in different levels ("CloudDeck" today),
## so match on the seam rather than the name. A level with no clouds is a silent no-op.
func _resolve_cloud_deck() -> Node:
	var parent: Node = get_parent()
	if parent == null:
		return null
	for child: Node in parent.get_children():
		if child != self and child.has_method(&"set_sky_light"):
			return child
	return null


## Built here rather than added to each level scene: it is pure presentation with no authored
## values, and every level with an Atmosphere node should have a night sky without anyone
## remembering to place one. Reuses an authored StarField child if a level ever adds one.
func _resolve_star_field() -> Node3D:
	var existing := get_node_or_null(^"StarField") as Node3D
	if existing != null:
		return existing
	var created: Node3D = STAR_FIELD_SCRIPT.new()
	created.name = "StarField"
	add_child(created)
	return created


## Same reasoning as the star field above, and the same fix for the same bug: every level with an
## Atmosphere node should have ground mist without a level author remembering to place one, because
## release worlds have no level author. This is what F-115 actually was — the controller drove three
## FogVolumes by name and the shipped map contained none of them, so the only fog left was the
## uniform `volumetric_fog_density` blanket. A level that authors its own `GroundFog` child keeps it.
func _resolve_ground_fog() -> FogVolume:
	var existing := get_node_or_null(^"GroundFog") as FogVolume
	if existing != null:
		return existing
	var created: FogVolume = GROUND_FOG_SCRIPT.new()
	created.name = "GroundFog"
	add_child(created)
	return created


## The moon (F-378). Same build-it-here reasoning as the star field and the ground mist, and the
## same escape hatch: a level that places its own `Moon` beside its `Sun` keeps it, so an authored
## map can pose a moon by hand without this file fighting it. `apply_atmosphere()` still drives
## whatever it finds, because the clock is not the level's to own (docs/SPECS.md 2.11).
##
## Everything configured here is the part that never changes with the hour. The three things that DO
## — rotation, energy, and whether it casts shadows at all — are written by `apply_atmosphere()`.
func _resolve_moon() -> DirectionalLight3D:
	var authored := get_node_or_null(^"../Moon") as DirectionalLight3D
	if authored != null:
		return authored
	var existing := get_node_or_null(^"Moon") as DirectionalLight3D
	if existing != null:
		return existing
	var created := DirectionalLight3D.new()
	created.name = "Moon"
	created.light_color = MOONLIGHT_COLOR
	created.light_energy = 0.0
	created.light_angular_distance = MOON_ANGULAR_DIAMETER_DEG
	# LIGHT_ONLY, and this is load-bearing rather than tidy: `PhysicalSkyMaterial` draws its sun disc
	# for LIGHT0, Godot picks LIGHT0 from the directional lights that contribute to the sky, and a
	# moon that qualified could take that slot — which would paint the sun's disc on the moon and
	# leave the real sun blank. The moon's own disc is geometry in `star_field.gd` instead.
	created.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	# Shadows on, but the cheapest kind: one split, and only across the distance anything is legible
	# at night. The sun's shadows go off while these are on (see apply_atmosphere), so the map never
	# renders two directional shadow maps at once and this costs nothing net.
	created.shadow_enabled = true
	created.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	created.directional_shadow_max_distance = MOON_SHADOW_DISTANCE_M
	created.shadow_opacity = MOON_SHADOW_OPACITY
	created.shadow_bias = 0.05
	created.shadow_normal_bias = 1.6
	# `shadow_enabled` above is the standing capability; whether it is actually ON at a given hour is
	# apply_atmosphere()'s call, and so are energy, colour, rotation and volumetric contribution.
	# Starting hidden matters on its own: a level that boots at noon must never pay a frame for a
	# light that is about to be switched off anyway.
	created.visible = false
	add_child(created)
	return created


func _process(delta: float) -> void:
	if not cycle_enabled:
		return
	time_of_day = fmod(time_of_day + delta * 24.0 / day_length_seconds, 24.0)
	apply_atmosphere()


func set_time_of_day(value: float) -> void:
	time_of_day = fposmod(value, 24.0)
	apply_atmosphere()


func set_weather_haze(value: float) -> void:
	haze_strength = clampf(value, 0.25, 2.0)
	apply_atmosphere()


func set_cycle_enabled(value: bool) -> void:
	cycle_enabled = value
	set_process(cycle_enabled)


func apply_atmosphere() -> void:
	if _environment == null or sun == null:
		return
	var hour := snappedf(time_of_day, SUN_STEP_HOURS)
	var solar_phase := (hour - 6.0) / 24.0 * TAU
	var elevation := sin(solar_phase) * 90.0
	var daylight := smoothstep(-7.0, 12.0, elevation)
	var warm_horizon := 1.0 - smoothstep(10.0, 42.0, elevation)
	var starlight := 1.0 - smoothstep(STARS_FULL_ELEVATION, STARS_GONE_ELEVATION, elevation)
	var sky_night := 1.0 - smoothstep(
		SKY_NIGHT_FULL_ELEVATION, SKY_NIGHT_START_ELEVATION, elevation
	)
	var golden := 1.0 - smoothstep(0.0, GOLDEN_HALF_WIDTH, absf(elevation))
	var azimuth := -118.0 + (hour / 24.0) * 236.0

	# The sun's angle and the wheeling star dome move on the stepped hour — once per step, never
	# a rewrite of the same value (see _applied_sun_hour).
	if hour != _applied_sun_hour:
		_applied_sun_hour = hour
		sun.rotation_degrees = Vector3(-elevation, azimuth, 0.0)
		# F-378: the moon is the sun's antipode on the same clock — negate the elevation, add half a
		# turn of azimuth. At midnight (elevation -90) that puts it directly overhead, and at the
		# moment of sunset it is exactly rising, which is the only arrangement where "one of the two
		# is lit" is true by construction rather than by tuning.
		if _moon != null:
			_moon.rotation_degrees = Vector3(elevation, azimuth + 180.0, 0.0)
		if _star_field != null and starlight > 0.001:
			_star_field.call(&"set_sky_rotation", hour / 24.0 * TAU)
			# The dome carries the star wheel's own rotation, so the moon's direction is handed over
			# in WORLD space and the star field puts it into the dome's frame itself — otherwise the
			# moon would wheel with the stars instead of tracking the clock it is actually on.
			if _moon != null:
				_star_field.call(&"set_moon_direction", _moon.global_basis.z)

	# Everything below only responds to these drivers, so while they hold — which is every tick
	# outside the dawn/dusk windows — the writes are identical and skipping them is invisible.
	var drivers := PackedFloat64Array([
		daylight, warm_horizon, starlight, sky_night, golden, haze_strength, god_ray_strength
	])
	if drivers == _applied_drivers:
		return
	_applied_drivers = drivers

	# Warmer than neutral daylight even at noon, and holding the sunrise tint further up the sky
	# (0.58 rather than 0.72 of it burned off) — the difference between "correctly lit" and the
	# warm hour Sequoyah asked for. Colour is the cheapest half of that look; the other half is the
	# shafts below.
	var daylight_color := Color(1.0, 0.94, 0.815)
	var sunrise_color := Color(1.0, 0.55, 0.27)
	var horizon_mix := sunrise_color.lerp(daylight_color, 1.0 - warm_horizon * 0.58)
	# F-378: the sun stays the sun all the way down. It used to lerp toward MOONLIGHT_COLOR as the
	# stars came out, which was this file pretending to be a moon it did not have — and the give-away
	# was that the "moonlight" came from wherever the sun had set. There is a real moon now, so the
	# sun keeps its sunset warmth and simply goes out.
	sun.light_color = horizon_mix
	# To zero, not to 0.04. A key light at 0.04 against a 0.06-linear albedo lands under what the
	# tonemapper resolves at all (F-356 measured the result at luminance median 0.000), so all it
	# ever bought was the illusion that night was lit. The moon below is what lights night now.
	sun.light_energy = DAY_SUN_ENERGY * daylight
	# Shafts peak at GOLDEN HOUR, not at noon. A sun overhead lights the mist from above and there
	# is nothing to rake through; a sun on the horizon fires the length of the valley through every
	# trunk in it, which is the shot this is for. `golden` is the extra 60% either side of dawn.
	sun.light_volumetric_fog_energy = (
		god_ray_strength * lerpf(0.25, 1.0, daylight) * (1.0 + golden * 0.6)
	)
	sun.shadow_opacity = lerpf(0.4, 0.88, daylight)
	# F-378: a light at zero energy still renders a shadow map. Once the sun is down that is a full
	# directional shadow pass for a light contributing nothing, and it is exactly the budget the
	# moon's own shadows need — so the two hand it back and forth rather than both holding one.
	sun.shadow_enabled = daylight > 0.004
	if _moon != null:
		var moonlight := starlight
		_moon.visible = moonlight > 0.002
		_moon.light_color = MOONLIGHT_COLOR
		_moon.light_energy = MOON_ENERGY * moonlight
		# Off below the point where the moon is too dim to cast anything you could identify — which
		# is also the dusk window where the sun's shadows are still on, so the handover never leaves
		# both enabled for longer than the fade itself.
		_moon.shadow_enabled = moonlight > 0.25
		# Moonlight through mist is a lot of what makes a night READ as a night rather than as a
		# dark day, but at a quarter of the sun's rate: a shaft you can follow the length of a
		# valley at midnight is a searchlight, not a moon.
		_moon.light_volumetric_fog_energy = god_ray_strength * 0.25 * moonlight

	_environment.background_energy_multiplier = lerpf(0.12, 0.9, daylight)
	# The day end is the floor under everything the sun is NOT hitting, and F-353 took it from 0.62
	# down to DAY_AMBIENT_ENERGY. The old value's own comment worried that 0.5 "crushed a hillside
	# facing away from a low sun to pure black" — but it was measured under `tonemap_white = 3.0`,
	# which lifted the blacks that were doing the crushing, and the fill it chose to compensate is
	# what erased the flat-shaded facets. With the white point back at 1.0 the curve is different and
	# the shadow is dark AND coloured, which is what that comment actually wanted. The colour half of
	# it is unchanged: ambient stays 68% sky (the level's own ambient_light_sky_contribution), so the
	# fill that remains is blue and reads as sky bouncing into shade rather than as grey.
	_environment.ambient_light_energy = lerpf(NIGHT_AMBIENT_ENERGY, DAY_AMBIENT_ENERGY, daylight)
	_environment.ambient_light_color = NIGHT_AMBIENT_COLOR.lerp(_day_ambient_color, daylight)
	_environment.tonemap_exposure = lerpf(NIGHT_TONEMAP_EXPOSURE, DAY_TONEMAP_EXPOSURE, daylight)
	# F-353's four remaining knobs, all on the same `daylight` curve as everything above so night
	# lands on the authored values and this stays a daytime change. See the DAY_* block's header for
	# what each was doing to the frame.
	_environment.tonemap_white = lerpf(NIGHT_TONEMAP_WHITE, DAY_TONEMAP_WHITE, daylight)
	_environment.glow_bloom = lerpf(NIGHT_GLOW_BLOOM, DAY_GLOW_BLOOM, daylight)
	_environment.glow_hdr_threshold = lerpf(
		NIGHT_GLOW_HDR_THRESHOLD, DAY_GLOW_HDR_THRESHOLD, daylight
	)
	_environment.glow_intensity = lerpf(NIGHT_GLOW_INTENSITY, DAY_GLOW_INTENSITY, daylight)
	_environment.adjustment_contrast = lerpf(
		NIGHT_ADJUSTMENT_CONTRAST, DAY_ADJUSTMENT_CONTRAST, daylight
	)
	_environment.adjustment_saturation = lerpf(
		NIGHT_ADJUSTMENT_SATURATION, DAY_ADJUSTMENT_SATURATION, daylight
	)
	_environment.fog_light_color = Color(0.19, 0.22, 0.3).lerp(
		Color(0.62, 0.67, 0.72), daylight
	)
	# Aerial perspective, not a blanket: FogVolume nodes still define every mist pocket you actually
	# look at, and this is only the depth cue that makes a far shore sit behind a near one. Scaled by
	# `haze_strength` like the rest of the weather knobs. See DAY_FOG_DENSITY for why zero was worse.
	_environment.fog_density = DAY_FOG_DENSITY * haze_strength
	# F-115: this used to be the ONLY fog on the shipped map, at a density that greyed out
	# everything evenly. It is now just the thin medium a sunbeam needs in order to be visible at
	# all — an eighth of what it was — and `GroundFog` carries every bit of fog you actually look
	# at. Turning it off entirely would take the god rays with it, which is the opposite mistake.
	_environment.volumetric_fog_density = 0.00006 * haze_strength
	# Ambient injection is what washes a volumetric medium out into milk. Low by day so shafts keep
	# their contrast against the air around them; higher at night, where the alternative is fog you
	# cannot see at all.
	_environment.volumetric_fog_ambient_inject = lerpf(0.34, 0.16, daylight)
	var local_density_scale := haze_strength * lerpf(1.18, 0.92, daylight)
	for index: int in mini(_local_fog_materials.size(), _local_fog_densities.size()):
		_local_fog_materials[index].density = _local_fog_densities[index] * local_density_scale
	if _ground_fog != null:
		# Thick at dawn and dusk, thinnest at noon — see the FOG_* constants. `golden` peaks either
		# side of the horizon, which is the only time the mist is lit warmly enough to say so.
		var noon_amount := smoothstep(0.0, 1.0, daylight)
		var mist_scale := lerpf(FOG_NIGHT_SCALE, FOG_NOON_SCALE, noon_amount)
		mist_scale = lerpf(mist_scale, FOG_DAWN_SCALE, golden * 0.85)
		_ground_fog.call(
			&"apply_look",
			mist_scale * haze_strength,
			FOG_NIGHT_ALBEDO.lerp(FOG_DAY_ALBEDO, daylight),
			FOG_GOLDEN_EMISSION,
			golden * 0.22 * daylight
		)
	if _sky_material != null:
		# PhysicalSkyMaterial already dims itself as LIGHT0 drops, so let it do that work while the
		# sun is up and only force the night colours once the sun is actually below the horizon.
		# F-378: the day end came down from 0.9. That single number is what was blowing six degrees
		# of sky past the white point around the sun, and lowering it is what lets the disc's edge be
		# seen at all — see the SUN_* block for the measurement.
		_sky_material.energy_multiplier = lerpf(NIGHT_SKY_ENERGY, DAY_SKY_ENERGY, 1.0 - sky_night)
		# F-378: this used to run to 10.0 at night. Turbidity multiplies the mie term outright, so
		# the haze around the sun was at its thickest across dusk and dawn — the two hours a player
		# is most likely to be looking straight at it, and the hours the "faded haze thats way to
		# wide" verdict came from. Both ends are down, and the night end further than the day one.
		_sky_material.turbidity = lerpf(NIGHT_TURBIDITY, DAY_TURBIDITY, daylight)
		_sky_material.rayleigh_color = _day_rayleigh_color.lerp(NIGHT_RAYLEIGH_COLOR, sky_night)
		_sky_material.mie_color = _day_mie_color.lerp(NIGHT_MIE_COLOR, sky_night)
		_sky_material.ground_color = _day_ground_color.lerp(NIGHT_GROUND_COLOR, sky_night)
	if _cloud_deck != null:
		_cloud_deck.call(&"set_sky_light", daylight, golden)
	if _star_field != null:
		# The wheel itself (set_sky_rotation) turns above the gate, every tick of the night.
		_star_field.call(&"set_night_amount", starlight)
