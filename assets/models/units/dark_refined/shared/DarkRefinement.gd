extends Node
## Child of a refined dark-race scene that instances the ORIGINAL wrapper.
## After the wrapper has built its action models (one skeleton per action, or a
## single baked skeleton), every skinned body gets the unit's race material and
## one skinned "CraftedParts" mesh is added per skeleton.
##
## Parts come from a GLB whose MeshInstance3D nodes carry glTF extras
## {"bone": name, "bind": [12 floats]}: vertices are local to that bone. A part
## joins a skeleton only when that skeleton's skin has the same bind pose for
## the bone, so action files with different rigs (succubus run, doom run) each
## get the part set authored for them and a changed rig fails loudly.
## All matched parts become ONE surface, rigidly weighted to their bones with
## identity binds (vertices are already bone-local): one draw per action, and
## identical rigs share the same mesh and skin.

@export var body_material: Material
@export var parts: PackedScene
@export var parts_material: Material

const BIND_TOLERANCE := 0.002
const PARTS_NODE := "CraftedParts"

static var _cache := {}


func _ready() -> void:
	var host := get_parent()
	if host.is_node_ready():
		_apply(host)
	else:
		host.ready.connect(_apply.bind(host), CONNECT_ONE_SHOT)


func _apply(host: Node) -> void:
	var part_rows := _part_rows()
	for found in host.find_children("*", "Skeleton3D", true, false):
		var skeleton := found as Skeleton3D
		var body := _skinned_body(skeleton)
		if body == null:
			continue
		if body_material != null:
			for surface in body.mesh.get_surface_count():
				body.set_surface_override_material(surface, body_material)
		if part_rows.is_empty():
			continue
		var matched: Array[Dictionary] = []
		for row in part_rows:
			if skeleton.find_bone(str(row.bone)) >= 0 and _bind_matches(skeleton, body.skin, row):
				matched.append(row)
		if matched.is_empty():
			push_error("DarkRefinement: no crafted part matches the rig of %s; re-export parts for this action." % host.get_path_to(skeleton))
			continue
		var built := _combined(matched)
		var mesh_instance := MeshInstance3D.new()
		mesh_instance.name = PARTS_NODE
		mesh_instance.mesh = built.mesh
		mesh_instance.skin = built.skin
		mesh_instance.material_override = parts_material
		skeleton.add_child(mesh_instance)
		mesh_instance.skeleton = mesh_instance.get_path_to(skeleton)


func _skinned_body(skeleton: Skeleton3D) -> MeshInstance3D:
	for found in skeleton.find_children("*", "MeshInstance3D", false, false):
		var mesh_instance := found as MeshInstance3D
		if mesh_instance.mesh != null and mesh_instance.skin != null and str(mesh_instance.name) != PARTS_NODE:
			return mesh_instance
	return null


func _part_rows() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	if parts == null:
		return rows
	var source := parts.instantiate()
	for found in source.find_children("*", "MeshInstance3D", true, false):
		var extras: Dictionary = found.get_meta("extras", {})
		var bind: Array = extras.get("bind", [])
		if not extras.has("bone") or bind.size() != 12:
			push_error("DarkRefinement: part %s lacks bone/bind extras." % found.name)
			continue
		rows.append({"key": "%s|%s" % [parts.resource_path, found.name], "bone": str(extras.bone), "mesh": (found as MeshInstance3D).mesh,
			"bind": Transform3D(Basis(Vector3(bind[0], bind[1], bind[2]), Vector3(bind[3], bind[4], bind[5]), Vector3(bind[6], bind[7], bind[8])),
				Vector3(bind[9], bind[10], bind[11]))})
	source.free()
	return rows


func _bind_matches(skeleton: Skeleton3D, skin: Skin, row: Dictionary) -> bool:
	var bone := skeleton.find_bone(str(row.bone))
	for b in skin.get_bind_count():
		if skin.get_bind_bone(b) == bone or str(skin.get_bind_name(b)) == str(row.bone):
			return _same(skin.get_bind_pose(b), row.bind)
	return false


func _same(a: Transform3D, b: Transform3D) -> bool:
	# Relative tolerance: some rigs bind in centimetres (basis and origin ~100).
	var scale := maxf(1.0, maxf(a.origin.length(), maxf(a.basis.x.length(), a.basis.y.length())))
	var tolerance := BIND_TOLERANCE * scale
	return a.basis.x.distance_to(b.basis.x) < tolerance and a.basis.y.distance_to(b.basis.y) < tolerance \
		and a.basis.z.distance_to(b.basis.z) < tolerance and a.origin.distance_to(b.origin) < tolerance


## One surface for every matched part, each vertex 100% on its bone.
func _combined(rows: Array[Dictionary]) -> Dictionary:
	var keys: Array[String] = []
	for row in rows:
		keys.append(str(row.key))
	var cache_key := ";".join(keys)
	if _cache.has(cache_key):
		return _cache[cache_key]
	var skin := Skin.new()
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var bones := PackedInt32Array()
	var weights := PackedFloat32Array()
	var indices := PackedInt32Array()
	for row in rows:
		var bind_index := skin.get_bind_count()
		skin.add_named_bind(str(row.bone), Transform3D.IDENTITY)
		var mesh: Mesh = row.mesh
		for s in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(s)
			var base := verts.size()
			var v := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
			verts.append_array(v)
			normals.append_array(arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array)
			var c: Variant = arrays[Mesh.ARRAY_COLOR]
			if c == null:
				for i in v.size():
					colors.append(Color(0.1, 0.05, 0.15, 0.0))
			else:
				colors.append_array(c as PackedColorArray)
			for i in v.size():
				bones.append_array([bind_index, 0, 0, 0])
				weights.append_array([1.0, 0.0, 0.0, 0.0])
			var index: Variant = arrays[Mesh.ARRAY_INDEX]
			if index == null:
				for i in v.size():
					indices.append(base + i)
			else:
				for i in (index as PackedInt32Array):
					indices.append(base + i)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_BONES] = bones
	arrays[Mesh.ARRAY_WEIGHTS] = weights
	arrays[Mesh.ARRAY_INDEX] = indices
	var combined := ArrayMesh.new()
	combined.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var built := {"mesh": combined, "skin": skin}
	_cache[cache_key] = built
	return built
