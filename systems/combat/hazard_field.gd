extends Node3D

## A patch of ground that hurts for a while. The primitive four Resonances needed and the project did
## not have (F-585): a spore cloud over a corpse, a Void rift where you blinked from, the shatter of
## a frozen enemy, the chained explosion of a burning one. `Enemy._burst()` is the closest existing
## thing and it is neither — it is instantaneous, and it only ever hits players.
##
## ## NETWORK AUTHORITY (docs/ARCHITECTURE.md §2.2, "Enemy AI, spawns, damage" row): HOST.
##
## A field is spawned in two halves. The host builds a **simulating** one (`simulate = true`), which
## is the only copy that ever deals damage or applies a status; every client builds a
## **presentation-only** one at the same place from `ResonanceService`'s broadcast. Both run the same
## visual from the same local clock, so they look identical without a synchroniser and without a
## `PROTOCOL_VERSION` bump — the same "everyone builds it, the host decides it" split
## `MireGrid`'s corruption already uses.
##
## Deliberately NOT an Area3D. The physics layers here are authored for bodies that collide, and a
## damage volume that has to be added to that scheme is a change to every enemy's mask. A radius test
## over the `enemies` group on a fixed tick is cheaper than a physics query at this scale (a handful
## of fields, tens of enemies) and it costs no layer.

const ENEMY_GROUP: StringName = &"enemies"

## Ticks per second are deliberately low. A field is an area denial, not a shredder: the number
## should land often enough to feel continuous and rarely enough that standing in one for half a
## second is survivable.
const TICK_SEC: float = 0.5
const FADE_SEC: float = 0.6

## Set before `add_child()`, exactly like `ItemDropService` sets a drop's payload.
var simulate: bool = false
var radius_m: float = 3.0
var seconds: float = 5.0
var damage_per_tick: int = 0
var source_peer_id: int = 0
## Optional status every tick applies to whatever it touches — this is what makes a spore cloud
## spread Fungal and a rift bite with Void rather than all four fields being the same grey damage.
var status_kind: StringName = &""
var status_seconds: float = 0.0
var status_potency: float = 0.0
var tint: Color = Color(0.55, 0.83, 0.42)

var _age: float = 0.0
var _tick_accum: float = 0.0
var _disc: MeshInstance3D
var _disc_material: StandardMaterial3D
var _particles: GPUParticles3D

## Host-side, once per target per tick. `ResonanceService` listens so Fungal's Greater Resonance can
## spread from whatever the cloud touched.
signal touched(target: Node)


func _ready() -> void:
	_build_visual()
	set_physics_process(true)


func _physics_process(delta: float) -> void:
	_age += delta
	_tick_visual()
	if _age >= seconds:
		if _age >= seconds + FADE_SEC:
			queue_free()
		return
	if not simulate:
		return
	_tick_accum += delta
	if _tick_accum < TICK_SEC:
		return
	_tick_accum -= TICK_SEC
	_bite()


## Everything alive inside the radius takes the tick. Horizontal distance only: a field is a patch of
## GROUND, and a creature standing on a rock half a metre up is still standing in it.
func _bite() -> void:
	var radius_squared: float = radius_m * radius_m
	var status: Node = get_node_or_null(^"/root/StatusService")
	for node: Node in get_tree().get_nodes_in_group(ENEMY_GROUP):
		var enemy := node as Node3D
		if enemy == null or not is_instance_valid(enemy):
			continue
		if enemy.has_method(&"is_alive") and not bool(enemy.call(&"is_alive")):
			continue
		var offset: Vector3 = enemy.global_position - global_position
		offset.y = 0.0
		if offset.length_squared() > radius_squared:
			continue
		if damage_per_tick > 0 and enemy.has_method(&"host_apply_damage"):
			# Through the enemy's own entry point, so a field kill pays its bounty to the player who
			# created the field rather than to nobody.
			enemy.call(&"host_apply_damage", damage_per_tick, source_peer_id)
		if status_kind != &"" and status != null and is_instance_valid(enemy):
			status.call(&"host_apply", enemy, status_kind, status_seconds, status_potency,
				source_peer_id)
		if is_instance_valid(enemy):
			touched.emit(enemy)


# ── Presentation ─────────────────────────────────────────────────────────────────────────────────


## A flat additive disc on the ground plus a slow column of motes. The disc is what makes the field's
## EXTENT readable — a player has to be able to see where the edge is to decide whether to step out
## of it, and a particle cloud alone never answers that.
func _build_visual() -> void:
	_disc_material = StandardMaterial3D.new()
	_disc_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_disc_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_disc_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_disc_material.albedo_color = Color(tint.r, tint.g, tint.b, 0.30)
	_disc_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Never writes depth: it lies flat on uneven terrain and would z-fight every blade of grass.
	_disc_material.no_depth_test = true

	var plane := PlaneMesh.new()
	plane.size = Vector2(radius_m * 2.0, radius_m * 2.0)
	_disc = MeshInstance3D.new()
	_disc.name = "HazardDisc"
	_disc.mesh = plane
	_disc.material_override = _disc_material
	_disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_disc.position.y = 0.06
	add_child(_disc)

	var material := ParticleProcessMaterial.new()
	material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE_SURFACE
	material.emission_sphere_radius = radius_m
	material.direction = Vector3(0.0, 1.0, 0.0)
	material.spread = 20.0
	material.initial_velocity_min = 0.2
	material.initial_velocity_max = 0.9
	material.gravity = Vector3(0.0, 0.25, 0.0)
	material.scale_min = 0.5
	material.scale_max = 1.6
	material.color = tint

	var quad := QuadMesh.new()
	quad.size = Vector2(0.18, 0.18)
	var mote := StandardMaterial3D.new()
	mote.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mote.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mote.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mote.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mote.vertex_color_use_as_albedo = true
	quad.material = mote

	_particles = GPUParticles3D.new()
	_particles.name = "HazardMotes"
	# Scaled to the area rather than fixed: a two-metre rift and a six-metre spore bank should read
	# as the same density of stuff, not the same count of it.
	_particles.amount = clampi(int(radius_m * radius_m * 4.0), 12, 90)
	_particles.lifetime = 1.4
	_particles.process_material = material
	_particles.draw_pass_1 = quad
	add_child(_particles)


func _tick_visual() -> void:
	if _disc_material == null:
		return
	var alpha: float = 0.30
	if _age > seconds:
		alpha *= clampf(1.0 - (_age - seconds) / FADE_SEC, 0.0, 1.0)
		if _particles != null:
			_particles.emitting = false
	# A slow pulse, so a field reads as alive rather than as a decal someone forgot to clean up.
	_disc_material.albedo_color.a = alpha * (0.75 + 0.25 * sin(_age * TAU * 0.8))
