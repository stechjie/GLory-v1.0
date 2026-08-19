extends SceneTree

# Read-only audit for every FBX under assets/models.
# Output priority: GLORY_FBX_AUDIT_PATH, --output, then user://fbx_audit.csv.
# Example:
#   Godot.exe --headless --path <project> --script res://tools/audit_fbx.gd -- --output user://fbx_audit.csv

const ROOT := "res://assets/models"
const DEFAULT_OUTPUT := "user://fbx_audit.csv"
const EPS_POS := 0.0005
const EPS_ROT := 0.0015
const EPS_SCALE := 0.0005

const CSV_HEADER := [
	"dir", "file", "meshes", "surfaces", "vertices", "indices", "triangles",
	"materials", "bones", "skel_path", "anim_player_path", "anim_count", "anims",
	"anim_len", "first_motion_s", "track_prefix", "embedded_tex", "embedded_tex_px",
	"lights", "cameras", "source_bytes", "import_cache_files", "import_cache_bytes",
	"load_error",
]

var _output_path := DEFAULT_OUTPUT
var _load_errors := 0


func _init() -> void:
	_output_path = _resolve_output_path()
	var fbx_paths := _collect_fbx(ROOT)
	fbx_paths.sort()
	print("FBX_AUDIT_START files=%d output=%s" % [fbx_paths.size(), _display_path(_output_path)])
	if fbx_paths.is_empty():
		printerr("FBX_AUDIT_RESULT status=FAIL reason=no_fbx_found root=%s" % ROOT)
		quit(1)
		return

	var rows: Array[String] = []
	rows.append(",".join(CSV_HEADER))
	for index in range(fbx_paths.size()):
		if (index + 1) % 20 == 0:
			print("  %d/%d" % [index + 1, fbx_paths.size()])
		rows.append(_audit_one(fbx_paths[index]))

	var absolute_output := ProjectSettings.globalize_path(_output_path)
	var parent_dir := absolute_output.get_base_dir()
	if not parent_dir.is_empty():
		var mkdir_error := DirAccess.make_dir_recursive_absolute(parent_dir)
		if mkdir_error != OK:
			printerr("FBX_AUDIT_RESULT status=FAIL reason=mkdir_failed error=%d output=%s" % [mkdir_error, absolute_output])
			quit(1)
			return

	var file := FileAccess.open(_output_path, FileAccess.WRITE)
	if file == null:
		printerr("FBX_AUDIT_RESULT status=FAIL reason=write_failed error=%d output=%s" % [FileAccess.get_open_error(), absolute_output])
		quit(1)
		return
	file.store_string("\n".join(rows) + "\n")
	file.close()

	var status := "PASS" if _load_errors == 0 else "FAIL"
	print("FBX_AUDIT_RESULT status=%s rows=%d load_errors=%d output=%s" % [status, rows.size() - 1, _load_errors, absolute_output])
	quit(0 if _load_errors == 0 else 1)


func _resolve_output_path() -> String:
	var env_path := OS.get_environment("GLORY_FBX_AUDIT_PATH").strip_edges()
	if not env_path.is_empty():
		return env_path
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		# Also support launchers that forward custom arguments without a `--` separator.
		args = OS.get_cmdline_args()
	for index in range(args.size()):
		var arg := str(args[index])
		if arg == "--output" and index + 1 < args.size():
			return str(args[index + 1])
		if arg.begins_with("--output="):
			return arg.trim_prefix("--output=")
	return DEFAULT_OUTPUT


func _display_path(path: String) -> String:
	return ProjectSettings.globalize_path(path) if path.begins_with("res://") or path.begins_with("user://") else path


func _collect_fbx(dir_path: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var full := dir_path.path_join(name)
		if dir.current_is_dir():
			out.append_array(_collect_fbx(full))
		elif name.to_lower().ends_with(".fbx"):
			out.append(full)
		name = dir.get_next()
	dir.list_dir_end()
	return out


func _audit_one(path: String) -> String:
	var dir_name := path.get_base_dir().replace(ROOT + "/", "")
	var file_name := path.get_file()
	var source_bytes := _file_size(path)
	var cache_stats := _imported_cache_stats(path)
	var scene := ResourceLoader.load(path) as PackedScene
	if scene == null:
		_load_errors += 1
		return _error_row(dir_name, file_name, source_bytes, cache_stats, "LOAD_FAILED")
	var root := scene.instantiate()
	if root == null:
		_load_errors += 1
		return _error_row(dir_name, file_name, source_bytes, cache_stats, "INSTANTIATE_FAILED")

	var nodes: Array[Node] = []
	_flatten(root, nodes)
	var meshes := 0
	var surfaces := 0
	var vertices := 0
	var indices := 0
	var triangles := 0
	var lights := 0
	var cameras := 0
	var materials: Dictionary = {}
	var embedded_tex: Dictionary = {}
	var skel: Skeleton3D = null
	var anim_player: AnimationPlayer = null

	for node in nodes:
		if node is Light3D:
			lights += 1
		elif node is Camera3D:
			cameras += 1
		elif node is Skeleton3D and skel == null:
			skel = node as Skeleton3D
		elif node is AnimationPlayer and anim_player == null:
			anim_player = node as AnimationPlayer
		elif node is MeshInstance3D:
			var mesh_instance := node as MeshInstance3D
			if mesh_instance.mesh == null:
				continue
			meshes += 1
			var surface_count := mesh_instance.mesh.get_surface_count()
			surfaces += surface_count
			for surface_index in range(surface_count):
				var arrays := mesh_instance.mesh.surface_get_arrays(surface_index)
				var surface_vertices := 0
				var surface_indices := 0
				if arrays.size() > Mesh.ARRAY_VERTEX and arrays[Mesh.ARRAY_VERTEX] != null:
					surface_vertices = arrays[Mesh.ARRAY_VERTEX].size()
				if arrays.size() > Mesh.ARRAY_INDEX and arrays[Mesh.ARRAY_INDEX] != null:
					surface_indices = arrays[Mesh.ARRAY_INDEX].size()
				vertices += surface_vertices
				indices += surface_indices
				triangles += int((surface_indices if surface_indices > 0 else surface_vertices) / 3)
				var material := mesh_instance.get_surface_override_material(surface_index)
				if material == null:
					material = mesh_instance.mesh.surface_get_material(surface_index)
				_collect_material(material, materials)
				_collect_textures(material, embedded_tex)

	var bones := skel.get_bone_count() if skel != null else 0
	var skel_path := String(root.get_path_to(skel)) if skel != null else ""
	var anim_names: Array[String] = []
	var anim_len := 0.0
	var first_motion := -1.0
	var track_prefix := ""
	var anim_player_path := ""
	if anim_player != null:
		anim_player_path = String(root.get_path_to(anim_player))
		for anim_name in anim_player.get_animation_list():
			if String(anim_name).to_lower() != "reset":
				anim_names.append(String(anim_name))
		if not anim_names.is_empty():
			var main_name := anim_names[0]
			for anim_name in anim_names:
				var candidate := anim_player.get_animation(anim_name)
				if candidate != null and candidate.length > anim_len:
					anim_len = candidate.length
					main_name = anim_name
			var animation := anim_player.get_animation(main_name)
			if animation != null:
				first_motion = _first_motion_time(animation)
				track_prefix = _track_prefix(animation)
	root.free()

	var texture_sizes: Array[String] = []
	for key in embedded_tex.keys():
		texture_sizes.append(str(embedded_tex[key]))
	texture_sizes.sort()
	return _csv([
		dir_name, file_name, meshes, surfaces, vertices, indices, triangles,
		materials.size(), bones, skel_path, anim_player_path, anim_names.size(),
		"|".join(anim_names), "%.3f" % anim_len, "%.3f" % first_motion, track_prefix,
		embedded_tex.size(), "|".join(texture_sizes), lights, cameras, source_bytes,
		int(cache_stats.files), int(cache_stats.bytes), "OK",
	])


func _error_row(dir_name: String, file_name: String, source_bytes: int, cache_stats: Dictionary, error: String) -> String:
	return _csv([
		dir_name, file_name, "", "", "", "", "", "", "", "", "", "", "",
		"", "", "", "", "", "", "", source_bytes, int(cache_stats.files),
		int(cache_stats.bytes), error,
	])


func _flatten(node: Node, out: Array[Node]) -> void:
	out.append(node)
	for child in node.get_children():
		_flatten(child, out)


func _collect_material(material: Material, out: Dictionary) -> void:
	if material == null:
		return
	var key := material.resource_path
	if key.is_empty():
		key = str(material.get_instance_id())
	out[key] = true


func _collect_textures(material: Material, out: Dictionary) -> void:
	var base := material as BaseMaterial3D
	if base == null:
		return
	for slot in [BaseMaterial3D.TEXTURE_ALBEDO, BaseMaterial3D.TEXTURE_NORMAL,
		BaseMaterial3D.TEXTURE_EMISSION, BaseMaterial3D.TEXTURE_ORM,
		BaseMaterial3D.TEXTURE_METALLIC, BaseMaterial3D.TEXTURE_ROUGHNESS]:
		var texture := base.get_texture(slot)
		if texture == null:
			continue
		var key := texture.resource_path
		if key.is_empty():
			key = str(texture.get_instance_id())
		out[key] = "%dx%d" % [texture.get_width(), texture.get_height()]


func _imported_cache_stats(source_path: String) -> Dictionary:
	var result := {"files": 0, "bytes": 0}
	var sidecar_path := source_path + ".import"
	if not FileAccess.file_exists(sidecar_path):
		return result
	var regex := RegEx.new()
	if regex.compile("res://\\.godot/imported/[^\\\"\\r\\n]+") != OK:
		return result
	var seen: Dictionary = {}
	for match_result in regex.search_all(FileAccess.get_file_as_string(sidecar_path)):
		var imported_path := match_result.get_string()
		if seen.has(imported_path):
			continue
		seen[imported_path] = true
		if FileAccess.file_exists(imported_path):
			result.files += 1
			result.bytes += _file_size(imported_path)
	return result


func _file_size(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return 0
	var size := file.get_length()
	file.close()
	return size


func _first_motion_time(animation: Animation) -> float:
	var earliest := -1.0
	for track_index in animation.get_track_count():
		var track_type := animation.track_get_type(track_index)
		if track_type != Animation.TYPE_POSITION_3D and track_type != Animation.TYPE_ROTATION_3D and track_type != Animation.TYPE_SCALE_3D:
			continue
		var key_count := animation.track_get_key_count(track_index)
		if key_count < 2:
			continue
		var base_value = animation.track_get_key_value(track_index, 0)
		for key_index in range(1, key_count):
			if not _value_differs(track_type, base_value, animation.track_get_key_value(track_index, key_index)):
				continue
			var time := animation.track_get_key_time(track_index, key_index)
			if earliest < 0.0 or time < earliest:
				earliest = time
			break
	return earliest


func _value_differs(track_type: int, a, b) -> bool:
	match track_type:
		Animation.TYPE_POSITION_3D:
			return (a as Vector3).distance_to(b as Vector3) > EPS_POS
		Animation.TYPE_ROTATION_3D:
			return absf((a as Quaternion).angle_to(b as Quaternion)) > EPS_ROT
		Animation.TYPE_SCALE_3D:
			return (a as Vector3).distance_to(b as Vector3) > EPS_SCALE
	return false


func _track_prefix(animation: Animation) -> String:
	for track_index in animation.get_track_count():
		var path := String(animation.track_get_path(track_index))
		var colon := path.find(":")
		return path.substr(0, colon) if colon >= 0 else path
	return ""


func _csv(fields: Array) -> String:
	var out: Array[String] = []
	for value in fields:
		var text := str(value)
		if text.contains(",") or text.contains("\"") or text.contains("\n"):
			text = "\"%s\"" % text.replace("\"", "\"\"")
		out.append(text)
	return ",".join(out)
