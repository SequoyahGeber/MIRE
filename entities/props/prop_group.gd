extends Node3D

## An authored cluster of kit props — a camp, a stone circle — placed as ONE scene by a
## [PoiDef.scene_path]. F-402.
##
## ## Why this script exists at all
##
## `PoiDef.scene_path` names a single file, so before F-402 a "camp" was literally one
## `station_workbench_primitive.glb` dropped on open ground and every other multi-prop POI was
## impossible to express. Grouping the props into a `.tscn` fixes that on its own — this script adds
## the two things a hand-written scene file cannot say for itself:
##
## 1. **Draw distance.** F-369 gave every scattered prop a `DrawPolicy`, sized from the prop's own
##    mesh, and measured why it matters: an instance out of range costs zero draw calls INCLUDING its
##    four shadow-cascade copies. POI scenes were never in that path — `procedural_world.gd`
##    instantiates the packed scene and adds it, full stop — so a camp's twenty-six props would each
##    submit a shadow copy from anywhere on a 295 m island. A `.tscn` cannot express
##    `visibility_range_end` on nodes it does not own (they live inside an instanced GLB), and the
##    sizing has to come from the mesh anyway, so it has to be code.
## 2. **`GraphicsQuality` follow-up.** `DrawPolicy.apply()` puts the instance in the `draw_policy`
##    group, which is what lets a preset change re-scale ranges later without the level's help.
##
## ## Network authority
##
## None (docs/ARCHITECTURE.md §2.2, "VFX, audio, camera, UI"). Everything here is presentation and
## static collision derived from content that is identical on every peer: the POI layout comes from
## the shared world seed, and this scene is the same file everywhere. Nothing is sent over the wire.
##
## Colliders stay authored in the `.tscn` where a human can see and move them; only the parts that
## must be measured from the meshes are done here.

const DrawPolicyScript = preload("res://world/environment/draw_policy.gd")

## Set false on a group whose props are all small clutter inside a bigger silhouette — the ranges
## would only ever fight the parent's. Nothing ships with it off yet; it is here so a future group
## does not have to fork the script to say so.
@export var apply_draw_policy: bool = true

## Props that took a policy, for the checks. Read by `tools/poi_check.gd`.
var policy_count: int = 0


func _ready() -> void:
	if not apply_draw_policy:
		return
	policy_count = _apply_to(self)


## Depth-first over the whole subtree, because a GLB instantiates as a root node with one
## `MeshInstance3D` per material — the meshes are grandchildren, not children.
func _apply_to(node: Node) -> int:
	var applied: int = 0
	for child: Node in node.get_children():
		var instance := child as GeometryInstance3D
		if instance is VisualInstance3D and instance != null:
			# Local bounds, and the node's own scale: a prop placed at 1.2x is drawn at 1.2x, and
			# `DrawPolicy` decides tall-vs-small from metres, not from mesh units.
			var mesh_instance := instance as MeshInstance3D
			if mesh_instance != null and mesh_instance.mesh != null:
				DrawPolicyScript.apply(
					instance, mesh_instance.mesh.get_aabb(),
					maxf(instance.global_basis.get_scale().y, 0.001)
				)
				applied += 1
		applied += _apply_to(child)
	return applied
