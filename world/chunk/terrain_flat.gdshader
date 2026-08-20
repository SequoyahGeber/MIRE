shader_type spatial;

// 4.18/D-184 — the flat-shaded low-poly terrain look Sequoyah pointed at (the r/Unity3D
// "procedurally generated low poly terrain, without mountains" reference): every triangle lit as
// one facet.
//
// The facet normal comes from screen-space derivatives of the view-space position, so the mesh
// stays exactly what ChunkMesher builds — indexed, smooth-normal, one vertex per grid point. No
// duplicated vertices, no second surface, works identically at every LOD, and costs two
// derivative instructions per fragment. The alternative (non-indexed triangles with baked face
// normals) triples the vertex count on every resident chunk, which this game's low-end target
// (docs/PERFORMANCE.md) rules out.
//
// The mesh's own smooth normals are still what the skirt inherits and what
// SurfaceTool.generate_normals comparisons in the checks read — this shader only changes lighting.

uniform vec3 albedo_color : source_color = vec3(0.35, 0.45, 0.3);

void fragment() {
	ALBEDO = albedo_color;
	ROUGHNESS = 1.0;
	// dFdy x dFdx (not the other order): VERTEX is view-space, and this order faces the normal
	// toward the camera the way Godot's own flat-shade examples do.
	NORMAL = normalize(cross(dFdy(VERTEX), dFdx(VERTEX)));
}
