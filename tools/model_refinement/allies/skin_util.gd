extends RefCounted
# CPU skinning helper: posed bounds of visible skinned meshes.

static func posed_bounds(node: Node3D, step: int = 5) -> AABB:
	var pts := posed_points(node, step)
	if pts.is_empty():
		return AABB()
	var ab := AABB(pts[0], Vector3.ZERO)
	for q in pts:
		ab = ab.expand(q)
	return ab

static func posed_points(node: Node3D, step: int = 5) -> PackedVector3Array:
	var pts := PackedVector3Array()
	# CPU skinning on a vertex subsample of the visible meshes: the real posed
	# silhouette (stored skinned AABBs are rest-pose and unreliable).
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if not (n is MeshInstance3D) or not (n as MeshInstance3D).is_visible_in_tree():
			continue
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		var skel := mi.get_node_or_null(mi.skeleton) as Skeleton3D
		var skin := mi.skin
		for s in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(s)
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var bones = arr[Mesh.ARRAY_BONES]
			var weights = arr[Mesh.ARRAY_WEIGHTS]
			var mats: Array[Transform3D] = []
			var skinned: bool = skel != null and skin != null and bones != null and bones.size() > 0
			if skinned:
				for i in skin.get_bind_count():
					var bone := skin.get_bind_bone(i)
					if bone < 0:
						bone = skel.find_bone(skin.get_bind_name(i))
					mats.append(skel.global_transform * skel.get_bone_global_pose(maxi(bone, 0)) * skin.get_bind_pose(i))
			var per: int = 4 if not skinned else bones.size() / maxi(verts.size(), 1)
			for vi in range(0, verts.size(), step):
				var v := verts[vi]
				var p := Vector3.ZERO
				if skinned:
					var wsum := 0.0
					for k in per:
						var w: float = weights[vi * per + k]
						if w <= 0.0:
							continue
						var bi: int = bones[vi * per + k]
						if bi < mats.size():
							p += (mats[bi] * v) * w
							wsum += w
					if wsum <= 0.0:
						p = mi.global_transform * v
					else:
						p /= wsum
				else:
					p = mi.global_transform * v
				pts.append(p)
	return pts

