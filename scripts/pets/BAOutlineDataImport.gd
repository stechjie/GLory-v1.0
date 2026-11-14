@tool
extends EditorScenePostImport
# 导入后处理：给模型补上 BA 式描边需要的两路顶点数据（只在编辑器导入时运行，不进游戏逻辑）。
#
# BA 实测（参考包 SHADER_FINDINGS 第 1 节）：描边 Pass 沿 TANGENT.xyz 外扩、外扩量乘顶点色 Alpha；
# 原作单独存了一份带专用切线的 OL 网格，不用普通切线。
#
# 这里的做法（为宠物做的设计选择）：
#  - TANGENT.xyz = 同一位置所有顶点的角度加权面法线之和（平滑法线）。UV/法线接缝处拆开的顶点
#    因此拿到同一个方向，描边在硬边、接缝处不会裂开。TANGENT 会跟骨骼一起蒙皮，动起来方向也对。
#    这些模型的材质不用法线贴图，覆盖导入时自动生成的切线没有副作用；需要法线贴图的模型不能挂这个脚本。
#  - COLOR = 白色，Alpha = 1（描边全宽、边缘光全开）。以后要让耳尖/尾尖变细，在 DCC 里刷顶点 Alpha 后
#    改成读取已有颜色即可（模型已有顶点色时这里保留原值，不覆盖）。
#  - 重新生成 LOD（ImporterMesh 重建网格会丢掉导入时的 LOD）。

const POSITION_EPSILON := 1.0e-6

func _post_import(scene: Node) -> Object:
	for found in scene.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := found as MeshInstance3D
		var source := mesh_instance.mesh as ArrayMesh
		if source == null or source.get_blend_shape_count() > 0:
			continue
		mesh_instance.mesh = _with_outline_data(source)
	return scene

func _with_outline_data(source: ArrayMesh) -> ArrayMesh:
	var importer := ImporterMesh.new()
	for surface in source.get_surface_count():
		var arrays := source.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var count := vertices.size()
		if indices.is_empty():
			indices.resize(count)
			for i in count:
				indices[i] = i

		# 角度加权面法线，按顶点累加
		var accum := PackedVector3Array()
		accum.resize(count)
		for t in range(0, indices.size() - 2, 3):
			var ia := indices[t]
			var ib := indices[t + 1]
			var ic := indices[t + 2]
			var pa := vertices[ia]
			var pb := vertices[ib]
			var pc := vertices[ic]
			# Godot 的正面是顺时针绕序，面法线 = (c-a)×(b-a)
			var face := (pc - pa).cross(pb - pa)
			if face.length_squared() <= 0.0:
				continue
			face = face.normalized()
			accum[ia] += face * (pb - pa).angle_to(pc - pa)
			accum[ib] += face * (pc - pb).angle_to(pa - pb)
			accum[ic] += face * (pa - pc).angle_to(pb - pc)

		# 同一位置的顶点合并
		var by_position := {}
		var keys: Array[Vector3i] = []
		keys.resize(count)
		for i in count:
			var key := Vector3i((vertices[i] / POSITION_EPSILON).round())
			keys[i] = key
			by_position[key] = by_position.get(key, Vector3.ZERO) + accum[i]

		var tangents := PackedFloat32Array()
		tangents.resize(count * 4)
		for i in count:
			var direction: Vector3 = by_position[keys[i]]
			if direction.length_squared() < 1.0e-12:
				direction = normals[i] if i < normals.size() else Vector3.UP
			direction = direction.normalized()
			tangents[i * 4] = direction.x
			tangents[i * 4 + 1] = direction.y
			tangents[i * 4 + 2] = direction.z
			tangents[i * 4 + 3] = 1.0
		arrays[Mesh.ARRAY_TANGENT] = tangents

		var colors = arrays[Mesh.ARRAY_COLOR]
		if colors == null or (colors as PackedColorArray).size() != count:
			var white := PackedColorArray()
			white.resize(count)
			white.fill(Color(1, 1, 1, 1))
			arrays[Mesh.ARRAY_COLOR] = white

		var flags := source.surface_get_format(surface) & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS
		importer.add_surface(source.surface_get_primitive_type(surface), arrays, [], {},
			source.surface_get_material(surface), source.surface_get_name(surface), flags)
	importer.generate_lods(25.0, 60.0, [])
	var result := importer.get_mesh()
	result.resource_name = source.resource_name
	return result
