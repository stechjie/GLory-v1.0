extends SceneTree
var rows: Array = []
func _init() -> void:
	call_deferred("_run")
func _run() -> void:
	var files: Array[String] = []
	_scan("res://assets/models", files)
	for path in files:
		var packed := load(path) as PackedScene
		if packed == null:
			rows.append({"path":path,"error":"load failed"})
			continue
		var node := packed.instantiate()
		var row := {"path":path,"meshes":[],"triangles":0,"vertices":0,"skeletons":0}
		var stack: Array[Node] = [node]
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			for c in n.get_children(): stack.append(c)
			if n is Skeleton3D: row.skeletons += 1
			if not n is MeshInstance3D: continue
			if n.mesh == null: continue
			var m := {"name":str(node.get_path_to(n)),"surfaces":n.mesh.get_surface_count(),"aabb":str(n.mesh.get_aabb()),"triangles":0,"vertices":0,"zero_normals":0,"flat_faces":0,"materials":[]}
			for s in range(n.mesh.get_surface_count()):
				var arrays: Array = n.mesh.surface_get_arrays(s)
				var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
				var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
				m.vertices += vertices.size()
				m.triangles += indices.size()/3 if indices.size() > 0 else vertices.size()/3
				for nn in normals:
					if nn.length_squared() < 0.1: m.zero_normals += 1
				for ii in range(0, indices.size() - 2, 3):
					if normals.size() == vertices.size() and normals[indices[ii]].is_equal_approx(normals[indices[ii+1]]) and normals[indices[ii]].is_equal_approx(normals[indices[ii+2]]): m.flat_faces += 1
				var mat: Material = n.mesh.surface_get_material(s)
				m.materials.append({"name":mat.resource_name if mat != null else "null","class":mat.get_class() if mat!= null else "null"})
			row.triangles += m.triangles
			row.vertices += m.vertices
			row.meshes.append(m)
		rows.append(row)
		node.free()
	var f := FileAccess.open("user://model_geometry_audit.json",FileAccess.WRITE)
	f.store_string(JSON.stringify(rows,"\t"))
	print("AUDIT_COMPLETE ", rows.size())
	quit()
func _scan(path: String, files: Array[String]) -> void:
	for name in DirAccess.get_directories_at(path): _scan(path.path_join(name),files)
	for name in DirAccess.get_files_at(path):
		if name.get_extension().to_lower() in ["fbx","glb","gltf"]: files.append(path.path_join(name))
