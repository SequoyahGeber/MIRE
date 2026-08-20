extends RefCounted

## The authored biome table, for a check or bench that has to build the SAME terrain the game builds.
##
## F-274 made `biome_defs` a required argument of `ChunkMesher.build_mesh()` and the input every
## surface sample resolves its amplitudes from. A tool that passes `[]` gets the biome-blind
## 1.0/1.0 surface — a real surface, but not the shipped one, and the whole of F-274 was a tool
## rendering terrain the game never builds. So every tool that asserts something about the surface
## sources its table here, and the ones that deliberately want the blind surface say `[]` in the
## call and say why.
##
## Preloaded, never named bare, and `extends RefCounted` with no `class_name`: a script new to this
## session is not in `.godot/global_script_class_cache.cfg` yet (F-016).

const BIOMES_PATH: String = "res://content/biomes"
const BIOME_DEF := preload("res://world/gen/biome_def.gd")


## The Registry autoload's table when there is one — the exact Array `ProceduralWorld` hands the
## streamer — and a direct scan of `content/biomes/` when there is not.
##
## Both paths exist because both are real: `agent godot --script tools/x.gd` boots autoloads, so a
## SceneTree check normally gets the Registry, but the compile pass runs before autoloads exist
## (F-011) and some harnesses never build one. The fallback loads the same files off the same path
## constant `autoload/registry.gd` uses, so the two cannot describe different content.
static func load_defs(tree: SceneTree = null) -> Array:
	if tree != null:
		var registry: Node = tree.root.get_node_or_null(^"Registry")
		if registry != null:
			var table: Variant = registry.get(&"biomes")
			if table is Dictionary and not (table as Dictionary).is_empty():
				return (table as Dictionary).values()
	return load_from_disk()


## Every valid `BiomeDef` under `content/biomes/`, sorted by `id`. Sorted for the same reason
## `BiomeMap.make_terrain_table()` sorts: a directory scan is not alphabetical on every platform
## (D-079), and a check whose input order wanders is a check that fails on someone else's machine.
static func load_from_disk() -> Array:
	var out: Array = []
	var dir := DirAccess.open(BIOMES_PATH)
	if dir == null:
		return out
	for file: String in dir.get_files():
		# .tres is imported to .remap in an exported build; strip either and load the source path.
		var name: String = file.trim_suffix(".remap")
		if not name.ends_with(".tres"):
			continue
		var def: Resource = load(BIOMES_PATH + "/" + name)
		if def != null and def.get_script() == BIOME_DEF:
			out.append(def)
	out.sort_custom(
		func(a: Resource, b: Resource) -> bool: return String(a.get(&"id")) < String(b.get(&"id"))
	)
	return out
