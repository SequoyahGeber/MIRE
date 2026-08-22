extends SceneTree

## F-410 — inspect one imported GLB's actual Godot material assignments.
##
## The Blender palette and the GLB JSON can both be correct while Godot is still
## rendering a stale or mismatched imported material.  This intentionally takes
## one asset per invocation so the reported evidence is unambiguous:
##
##   F410_ASSET=res://assets/environment/exports/tree_pine_a.glb \
##     .agent/bin/agent godot --script tools/f410_asset_material_probe.gd
##
## Authority: none (docs/ARCHITECTURE.md section 2.2). Read-only inspection.


func _init() -> void:
	var path: String = OS.get_environment("F410_ASSET")
	if path.is_empty():
		push_error("F410_ASSET must name one res:// GLB")
		quit(1)
		return
	var packed: PackedScene = load(path) as PackedScene
	if packed == null:
		push_error("could not load %s" % path)
		quit(1)
		return
	var instance: Node = packed.instantiate()
	if instance == null:
		push_error("could not instantiate %s" % path)
		quit(1)
		return
	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(instance, meshes)
	print("F410_ASSET %s meshes=%d" % [path, meshes.size()])
	for mesh_instance: MeshInstance3D in meshes:
		var mesh: Mesh = mesh_instance.mesh
		if mesh == null:
			continue
		for surface: int in mesh.get_surface_count():
			var material: Material = mesh.surface_get_material(surface)
			var albedo := Color.TRANSPARENT
			if material is BaseMaterial3D:
				albedo = (material as BaseMaterial3D).albedo_color
			print("  %s[%d] material=%s class=%s albedo=%s" % [
				mesh_instance.name,
				surface,
				"<none>" if material == null else material.resource_name,
				"<none>" if material == null else material.get_class(),
				albedo,
			])
	instance.free()
	quit()


func _collect_meshes(node: Node, into: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		into.append(node as MeshInstance3D)
	for child: Node in node.get_children():
		_collect_meshes(child, into)
