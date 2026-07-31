extends SceneTree

# 只读审计：扫描 assets/models 下全部 FBX，导出一张 CSV。
# 用途：为「合并动作 FBX / 丢弃内嵌贴图」两项改动划出「可批处理」与「需人工」的边界。
# 跑法（不会写任何项目文件，只写 out_path 指定的 CSV）：
#   Godot_v4.7-stable_win64_console.exe --headless --path <项目根> --script res://tools/audit_fbx.gd
#
# 关注的四件事：
#   1. mesh/顶点/骨骼规模 —— 手机预算
#   2. AnimationPlayer 到 Skeleton3D 的相对路径 + 骨骼名集合
#      —— 同一角色三个 FBX 必须完全一致，否则动画库挂上去会「播了但不动」
#   3. 内嵌贴图 —— 被 body_material.tres 盖掉却仍占显存的那部分
#   4. 起手静止时长 —— 合并后做混合过渡，这段 T-pose 引导必须先裁掉

const ROOT := "res://assets/models"
const EPS_POS := 0.0005
const EPS_ROT := 0.0015
const EPS_SCALE := 0.0005

var out_path := "C:/Users/Leno/AppData/Local/Temp/claude/C--Users-Leno-Desktop-Github-GLory-v1-0/4a85dd4f-385e-4007-a281-3e9c274fc692/scratchpad/fbx_audit.csv"

func _init() -> void:
	var fbx_paths := _collect_fbx(ROOT)
	fbx_paths.sort()
	print("found %d fbx" % fbx_paths.size())

	var rows: Array[String] = []
	rows.append("dir,file,meshes,surfaces,vertices,bones,skel_path,anim_player_path,anims,anim_len,first_motion_s,track_prefix,embedded_tex,embedded_tex_px,lights,cameras,load_error")

	var index := 0
	for path in fbx_paths:
		index += 1
		if index % 20 == 0:
			print("  %d/%d" % [index, fbx_paths.size()])
		rows.append(_audit_one(path))

	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		printerr("cannot write %s (err %d)" % [out_path, FileAccess.get_open_error()])
		quit(1)
		return
	f.store_string("\n".join(rows))
	f.close()
	print("wrote %s (%d rows)" % [out_path, rows.size() - 1])
	quit(0)

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

	var scene := ResourceLoader.load(path) as PackedScene
	if scene == null:
		return _csv([dir_name, file_name, "", "", "", "", "", "", "", "", "", "", "", "", "", "", "LOAD_FAILED"])
	var root := scene.instantiate()
	if root == null:
		return _csv([dir_name, file_name, "", "", "", "", "", "", "", "", "", "", "", "", "", "", "INSTANTIATE_FAILED"])

	var nodes: Array[Node] = []
	_flatten(root, nodes)

	var meshes := 0
	var surfaces := 0
	var vertices := 0
	var lights := 0
	var cameras := 0
	var embedded_tex := {}          # texture resource_path -> "WxH"
	var skel: Skeleton3D = null
	var anim_player: AnimationPlayer = null

	for n in nodes:
		if n is Light3D:
			lights += 1
		elif n is Camera3D:
			cameras += 1
		elif n is Skeleton3D and skel == null:
			skel = n as Skeleton3D
		elif n is AnimationPlayer and anim_player == null:
			anim_player = n as AnimationPlayer
		elif n is MeshInstance3D:
			var mi := n as MeshInstance3D
			if mi.mesh == null:
				continue
			meshes += 1
			var sc := mi.mesh.get_surface_count()
			surfaces += sc
			for i in sc:
				var arrays := mi.mesh.surface_get_arrays(i)
				if arrays.size() > Mesh.ARRAY_VERTEX and arrays[Mesh.ARRAY_VERTEX] != null:
					vertices += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
				_collect_textures(mi.mesh.surface_get_material(i), embedded_tex)

	var bones := skel.get_bone_count() if skel != null else 0
	var skel_path := ""
	if skel != null:
		skel_path = String(root.get_path_to(skel))

	var anim_names: Array[String] = []
	var anim_len := 0.0
	var first_motion := -1.0
	var track_prefix := ""
	var ap_path := ""
	if anim_player != null:
		ap_path = String(root.get_path_to(anim_player))
		for a in anim_player.get_animation_list():
			if String(a).to_lower() == "reset":
				continue
			anim_names.append(String(a))
		if not anim_names.is_empty():
			# 取最长的一条当主动作
			var main_name := anim_names[0]
			for a in anim_names:
				var cand := anim_player.get_animation(a)
				if cand != null and cand.length > anim_len:
					anim_len = cand.length
					main_name = a
			var anim := anim_player.get_animation(main_name)
			if anim != null:
				first_motion = _first_motion_time(anim)
				track_prefix = _track_prefix(anim)

	root.free()

	var tex_px: Array[String] = []
	for k in embedded_tex.keys():
		tex_px.append(str(embedded_tex[k]))

	return _csv([
		dir_name, file_name,
		str(meshes), str(surfaces), str(vertices), str(bones),
		skel_path, ap_path,
		"|".join(anim_names), "%.3f" % anim_len,
		"%.3f" % first_motion, track_prefix,
		str(embedded_tex.size()), "|".join(tex_px),
		str(lights), str(cameras), "OK",
	])

func _flatten(node: Node, out: Array[Node]) -> void:
	out.append(node)
	for c in node.get_children():
		_flatten(c, out)

func _collect_textures(mat: Material, out: Dictionary) -> void:
	if mat == null:
		return
	var base := mat as BaseMaterial3D
	if base == null:
		return
	for slot in [
		BaseMaterial3D.TEXTURE_ALBEDO,
		BaseMaterial3D.TEXTURE_NORMAL,
		BaseMaterial3D.TEXTURE_EMISSION,
		BaseMaterial3D.TEXTURE_ORM,
		BaseMaterial3D.TEXTURE_METALLIC,
		BaseMaterial3D.TEXTURE_ROUGHNESS,
	]:
		var tex := base.get_texture(slot)
		if tex == null:
			continue
		var key := tex.resource_path
		if key.is_empty():
			key = str(tex.get_instance_id())
		out[key] = "%dx%d" % [tex.get_width(), tex.get_height()]

# 动画开头有多久是完全静止的。合并后做 xfade，这段（通常是 T-pose 引导）会被混进
# 过渡区，必须先裁掉，所以要逐个量出来。返回 -1 表示整条动画都没动。
func _first_motion_time(anim: Animation) -> float:
	var earliest := -1.0
	for t in anim.get_track_count():
		var ttype := anim.track_get_type(t)
		if ttype != Animation.TYPE_POSITION_3D and ttype != Animation.TYPE_ROTATION_3D and ttype != Animation.TYPE_SCALE_3D:
			continue
		var key_count := anim.track_get_key_count(t)
		if key_count < 2:
			continue
		var base_value = anim.track_get_key_value(t, 0)
		for k in range(1, key_count):
			if not _value_differs(ttype, base_value, anim.track_get_key_value(t, k)):
				continue
			var time := anim.track_get_key_time(t, k)
			if earliest < 0.0 or time < earliest:
				earliest = time
			break
	return earliest

func _value_differs(ttype: int, a, b) -> bool:
	match ttype:
		Animation.TYPE_POSITION_3D:
			return (a as Vector3).distance_to(b as Vector3) > EPS_POS
		Animation.TYPE_ROTATION_3D:
			return absf((a as Quaternion).angle_to(b as Quaternion)) > EPS_ROT
		Animation.TYPE_SCALE_3D:
			return (a as Vector3).distance_to(b as Vector3) > EPS_SCALE
	return false

# 轨道路径的公共前缀。三个 FBX 若前缀不同，动画库互换后轨道解析不到。
func _track_prefix(anim: Animation) -> String:
	for t in anim.get_track_count():
		var p := String(anim.track_get_path(t))
		var colon := p.find(":")
		return p.substr(0, colon) if colon >= 0 else p
	return ""

func _csv(fields: Array) -> String:
	var out: Array[String] = []
	for v in fields:
		var s := str(v)
		if s.contains(",") or s.contains("\""):
			s = "\"%s\"" % s.replace("\"", "\"\"")
		out.append(s)
	return ",".join(out)
