extends SceneTree
# Dump UV triangles of every mesh in an FBX/scene as float32 binary (u0 v0 u1 v1 u2 v2 per tri).
# args: <scene path> <out.bin>
func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var n := (load(args[0]) as PackedScene).instantiate()
	var out := PackedFloat32Array()
	for mi in n.find_children("*", "MeshInstance3D", true, false):
		var mesh := (mi as MeshInstance3D).mesh
		if mesh == null:
			continue
		for s in mesh.get_surface_count():
			var arr := mesh.surface_get_arrays(s)
			var uv: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			if idx.is_empty():
				for i in uv.size():
					idx.append(i)
			for i in idx.size():
				out.append(uv[idx[i]].x)
				out.append(uv[idx[i]].y)
	var f := FileAccess.open(args[1], FileAccess.WRITE)
	f.store_buffer(out.to_byte_array())
	f.close()
	print("UV_TRIS ", out.size() / 6)
	quit(0)
