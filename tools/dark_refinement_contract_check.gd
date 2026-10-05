extends Node
## Race refinement contract (dark, undead, crimson; 8 units each). Headless:
##   Godot --headless --path <project> res://tools/dark_refinement_contract_check.tscn -- [--race dark|undead|crimson] [--out <report.json>] [--require-integrated]
##   ... -- --race <race> --write-baseline   (once per race, before refinement: hash every file the original wrappers load)
## Original/refined paths come from scenes/debug/DarkRaceRefinementPreview.gd (RACES), the same table the preview uses.
##
## Proves, per unit: the refined scene instances the UNCHANGED original wrapper; skeletons,
## bone rests, body meshes and every clip are identical to the original; every action body
## wears the unit's refined material; every action skeleton carries one rigidly skinned
## crafted-parts surface bound to its own bones (also in the prep screen's idle-only
## instancing); refined textures stay within budget.
## GLB races (crimson): the refined scene instances the refined GLB (crimson_refine.py) instead;
## skeletons, bone rests and every clip still equal the original's, every surface wears a race
## body material, the mesh stays within the vertex budget and its bounds stand upright on the
## ground (crimson_refine.py --audit proves the GLB-level identity of nodes/skins/animations).
## It does not judge looks: rendered captures do that.

const CheckHarness := preload("res://tools/CheckHarness.gd")
const Races := preload("res://scenes/debug/DarkRaceRefinementPreview.gd")
const UNIT_DATA := "res://data/units/race_units.json"
const BODY_SHADERS := ["res://assets/models/units/dark_refined/shared/dark_body.gdshader",
	"res://assets/models/units/dark_refined/shared/dark_body_two_sided.gdshader"]
const SHARED_SHADERS := ["res://shaders/character_toon.gdshader", "res://shaders/character_outline.gdshader"]
const MAX_TEXTURE_EDGE := 1024
# data/presentation/model_asset_budgets.json, unit tier: visible vertices hard 20000.
const MAX_GLB_VERTICES := 20000

var _h: CheckHarness
var _race := "dark"
var _report := {"units": {}}


func refined_path(unit_id: String) -> String:
	return Races.new_model_path(unit_id)


func originals() -> Dictionary:
	return Races.RACES[_race].old


func baseline_path() -> String:
	return "res://assets/models/units/%s_refined/original_runtime_assets.json" % _race


func refined_dir(unit_id: String) -> String:
	return "res://assets/models/units/%s_refined/%s" % [_race, unit_id]


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var race_index := args.find("--race")
	if race_index >= 0 and race_index + 1 < args.size():
		_race = args[race_index + 1]
	_h = CheckHarness.new("%s_refinement_contract" % _race)
	if not Races.RACES.has(_race):
		_h.fail("unknown_race", "未知种族：%s" % _race)
		_h.finish(get_tree())
		return
	_report["race"] = _race
	if "--write-baseline" in args:
		_write_baseline()
		_h.finish(get_tree())
		return
	await _check_shared()
	var defs := _unit_defs()
	for unit_id in originals():
		if Races.RACES[_race].get("glb", false):
			await _check_glb_unit(unit_id, defs.get(unit_id, {}), "--require-integrated" in args)
		else:
			await _check_unit(unit_id, defs.get(unit_id, {}), "--require-integrated" in args)
	var out_index := args.find("--out")
	if out_index >= 0 and out_index + 1 < args.size():
		var file := FileAccess.open(args[out_index + 1], FileAccess.WRITE)
		_report["checked"] = _h.checked_count()
		_report["failures"] = _h.failure_count()
		file.store_string(JSON.stringify(_report, "\t"))
		file.close()
	_h.finish(get_tree())


# ------------------------------------------------------------ baseline hashes
func _runtime_files(path: String, seen: Dictionary) -> void:
	if seen.has(path) or not FileAccess.file_exists(path):
		return
	seen[path] = true
	if FileAccess.file_exists(path + ".import"):
		seen[path + ".import"] = true
	for dep in ResourceLoader.get_dependencies(path):
		_runtime_files(str(dep).get_slice("::", 2) if str(dep).contains("::") else str(dep), seen)
	if path.get_extension() in ["gd", "tscn", "tres"]:
		var regex := RegEx.create_from_string("res://[A-Za-z0-9_./-]+\\.(?:fbx|glb|tres|tscn|png|gd|gdshader)")
		for found in regex.search_all(FileAccess.get_file_as_string(path)):
			_runtime_files(found.get_string(), seen)


func _write_baseline() -> void:
	var table := {}
	for unit_id in originals():
		var seen := {}
		_runtime_files(originals()[unit_id], seen)
		var rows := {}
		for path in seen.keys():
			rows[path] = FileAccess.get_sha256(path)
		table[unit_id] = rows
	for path in SHARED_SHADERS:
		table[path] = FileAccess.get_sha256(path)
	DirAccess.make_dir_recursive_absolute(baseline_path().get_base_dir())
	var file := FileAccess.open(baseline_path(), FileAccess.WRITE)
	file.store_string(JSON.stringify(table, "\t", true))
	file.close()
	_h.note("baseline written: %s" % baseline_path())


# ------------------------------------------------------------ checks
func _unit_defs() -> Dictionary:
	var defs := {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(UNIT_DATA))
	for unit in (parsed as Dictionary).get("units", []):
		if str(unit.get("race", "")) == _race:
			defs[str(unit.id)] = unit
	return defs


func _check_shared() -> void:
	var baseline: Variant = JSON.parse_string(FileAccess.get_file_as_string(baseline_path())) if FileAccess.file_exists(baseline_path()) else null
	_h.item()
	if not _h.expect(baseline is Dictionary, "baseline_missing", "缺少原资源哈希基线 %s（先 --write-baseline）" % baseline_path()):
		return
	for path in SHARED_SHADERS:
		_h.item()
		_h.expect(FileAccess.get_sha256(path) == str(baseline.get(path, "")), "shared_shader_changed", "共享 shader 被修改：%s" % path)
	await get_tree().process_frame


func _check_unit(unit_id: String, def: Dictionary, require_integrated: bool) -> void:
	var row := {"original": originals()[unit_id], "refined": refined_path(unit_id)}
	_report.units[unit_id] = row
	# Original runtime files untouched.
	var baseline: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(baseline_path())).get(unit_id, {})
	var changed: Array = []
	for path in baseline:
		if FileAccess.get_sha256(path) != str(baseline[path]):
			changed.append(path)
	_h.item()
	_h.expect(not baseline.is_empty() and changed.is_empty(), "original_changed", "%s 原资源被改动：%s" % [unit_id, changed])
	row["original_files_verified"] = baseline.size()
	# Formal mapping.
	_h.item()
	var mapped := str(def.get("model", ""))
	row["data_model"] = mapped
	if require_integrated:
		_h.expect(mapped == refined_path(unit_id), "not_integrated", "%s 正式 model 未指向精修场景：%s" % [unit_id, mapped])
	# Refined scene instances the original wrapper.
	var refined_text := FileAccess.get_file_as_string(refined_path(unit_id))
	_h.item()
	_h.expect(refined_text.contains('path="%s"' % originals()[unit_id]) and refined_text.contains("instance=ExtResource"),
		"not_inherited", "%s 精修场景没有实例化原包装器" % unit_id)
	var original := await _spawn(originals()[unit_id])
	var refined := await _spawn(refined_path(unit_id))
	_h.item()
	if not _h.expect(original != null and refined != null, "load_failed", "%s 场景加载失败" % unit_id):
		return
	_compare_rigs(unit_id, original, refined, row)
	_check_materials(unit_id, refined, row)
	_check_parts(unit_id, refined, row)
	original.queue_free()
	refined.queue_free()
	# PrepBoardModels instantiates the same model with load_idle_only (idle action only).
	var prep := await _spawn(refined_path(unit_id), true)
	var prep_row := {}
	_h.item()
	if _h.expect(prep != null and _skeletons(prep).size() == 1, "prep_idle_only", "%s 备战 idle-only 实例骨架数不是 1" % unit_id):
		_check_materials(unit_id, prep, prep_row)
		_check_parts(unit_id, prep, prep_row)
	row["prep_idle_only_parts"] = prep_row.get("parts_per_skeleton", [])
	if prep != null:
		prep.queue_free()
	await get_tree().process_frame


func _check_glb_unit(unit_id: String, def: Dictionary, require_integrated: bool) -> void:
	var row := {"original": originals()[unit_id], "refined": refined_path(unit_id)}
	_report.units[unit_id] = row
	var baseline: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(baseline_path())).get(unit_id, {})
	var changed: Array = []
	for path in baseline:
		if FileAccess.get_sha256(path) != str(baseline[path]):
			changed.append(path)
	_h.item()
	_h.expect(not baseline.is_empty() and changed.is_empty(), "original_changed", "%s 原资源被改动：%s" % [unit_id, changed])
	row["original_files_verified"] = baseline.size()
	_h.item()
	var mapped := str(def.get("model", ""))
	row["data_model"] = mapped
	if require_integrated:
		_h.expect(mapped == refined_path(unit_id), "not_integrated", "%s 正式 model 未指向精修场景：%s" % [unit_id, mapped])
	var glb := "%s/%s_refined.glb" % [refined_dir(unit_id), unit_id]
	_h.item()
	_h.expect(FileAccess.get_file_as_string(refined_path(unit_id)).contains('path="%s"' % glb), "not_inherited",
		"%s 精修场景没有实例化精修 GLB" % unit_id)
	var original := await _spawn(originals()[unit_id])
	var refined := await _spawn(refined_path(unit_id))
	_h.item()
	if not _h.expect(original != null and refined != null, "load_failed", "%s 场景加载失败" % unit_id):
		return
	var a := _skeletons(original)
	var b := _skeletons(refined)
	_h.item()
	_h.expect(a.size() == b.size() and a.size() > 0, "skeleton_count", "%s 骨架数 原%d 新%d" % [unit_id, a.size(), b.size()])
	for i in mini(a.size(), b.size()):
		var sa := a[i] as Skeleton3D
		var sb := b[i] as Skeleton3D
		_h.item()
		_h.expect(sa.get_bone_count() == sb.get_bone_count(), "skeleton_mismatch", "%s 骨数不同" % unit_id)
		var rest_delta := 0.0
		for bone in mini(sa.get_bone_count(), sb.get_bone_count()):
			rest_delta = maxf(rest_delta, (sa.get_bone_rest(bone).origin - sb.get_bone_rest(bone).origin).length())
		_h.item()
		_h.expect(rest_delta < 1e-6, "rest_changed", "%s 骨骼 rest 改变 %.6f" % [unit_id, rest_delta])
	var clips_a := _clips(original)
	var clips_b := _clips(refined)
	_h.item()
	_h.expect(clips_a.size() == clips_b.size() and not clips_a.is_empty() and _clip_signatures(clips_a) == _clip_signatures(clips_b),
		"clips_changed", "%s 动作片段（名/长/循环/轨道）不同" % unit_id)
	row["clips"] = clips_b.size()
	var vertices := 0
	var surfaces := 0
	for found in refined.find_children("*", "MeshInstance3D", true, false):
		var mesh_node := found as MeshInstance3D
		for s in mesh_node.mesh.get_surface_count():
			surfaces += 1
			vertices += mesh_node.mesh.surface_get_array_len(s)
			var material := mesh_node.get_active_material(s) as ShaderMaterial
			_h.item()
			if not _h.expect(material != null and material.shader.resource_path in BODY_SHADERS, "material_route",
					"%s %s surface %d 未使用种族 shader" % [unit_id, mesh_node.name, s]):
				continue
			var albedo := material.get_shader_parameter("albedo_texture") as Texture2D
			_h.item()
			_h.expect(albedo != null and albedo.resource_path.contains("/%s_refined/" % _race) and maxi(albedo.get_width(), albedo.get_height()) <= MAX_TEXTURE_EDGE,
				"texture_budget", "%s 精修贴图缺失或超过 %d" % [unit_id, MAX_TEXTURE_EDGE])
			if albedo != null:
				_h.item()
				_h.expect(albedo.get_image().get_format() in [Image.FORMAT_DXT1, Image.FORMAT_ETC2_RGB8, Image.FORMAT_ETC], "albedo_alpha",
					"%s 精修贴图仍带 alpha" % unit_id)
	row["vertices"] = vertices
	row["surfaces"] = surfaces
	_h.item()
	_h.expect(vertices > 0 and vertices <= MAX_GLB_VERTICES, "vertex_budget", "%s 顶点 %d 超过 %d" % [unit_id, vertices, MAX_GLB_VERTICES])
	# BattleRenderer centres on the pre-tree mesh AABB: it must stand upright on the ground.
	var bounds := _pretree_bounds(load(refined_path(unit_id)).instantiate())
	row["bounds"] = [bounds.position.y, bounds.size.y]
	_h.item()
	_h.expect(absf(bounds.position.y) < 0.05 and bounds.size.y > 1.5 and bounds.size.y < 3.0, "bounds_not_upright",
		"%s 包围盒不是站立在地面上：%s" % [unit_id, bounds])
	original.queue_free()
	refined.queue_free()
	await get_tree().process_frame


## Name, length, loop and track count; the player path differs (original vs refined root name).
func _clip_signatures(clips: Array) -> Array:
	var out: Array = []
	for clip in clips:
		out.append(str(clip).get_slice("|", 1) + "|" + "|".join(str(clip).split("|").slice(2)))
	out.sort()
	return out


func _pretree_bounds(root: Node3D) -> AABB:
	var bounds := AABB()
	var stack: Array = [[root, Transform3D.IDENTITY]]
	while not stack.is_empty():
		var item: Array = stack.pop_back()
		var node: Node = item[0]
		var xform: Transform3D = item[1]
		if node is MeshInstance3D:
			var box: AABB = xform * (node as MeshInstance3D).get_aabb()
			bounds = box if bounds.size == Vector3.ZERO else bounds.merge(box)
		for child in node.get_children():
			stack.append([child, xform * (child as Node3D).transform if child is Node3D else xform])
	root.free()
	return bounds


func _spawn(path: String, idle_only := false) -> Node3D:
	var packed := load(path) as PackedScene
	if packed == null:
		return null
	var node := packed.instantiate() as Node3D
	if idle_only:
		node.set_meta("load_idle_only", true)
	add_child(node)
	await get_tree().process_frame
	return node


func _skeletons(root: Node) -> Array:
	var out: Array = []
	for found in root.find_children("*", "Skeleton3D", true, false):
		out.append(found)
	return out


func _body(skeleton: Skeleton3D) -> MeshInstance3D:
	for found in skeleton.find_children("*", "MeshInstance3D", false, false):
		if (found as MeshInstance3D).skin != null:
			return found
	return null


func _compare_rigs(unit_id: String, original: Node3D, refined: Node3D, row: Dictionary) -> void:
	var a := _skeletons(original)
	var b := _skeletons(refined)
	_h.item()
	_h.expect(a.size() == b.size() and a.size() > 0, "skeleton_count", "%s 骨架数 原%d 新%d" % [unit_id, a.size(), b.size()])
	row["skeletons"] = b.size()
	var triangles := 0
	for i in mini(a.size(), b.size()):
		var sa := a[i] as Skeleton3D
		var sb := b[i] as Skeleton3D
		_h.item()
		_h.expect(original.get_path_to(sa) == refined.get_path_to(sb) and sa.get_bone_count() == sb.get_bone_count(),
			"skeleton_mismatch", "%s %s 骨架路径或骨数不同" % [unit_id, original.get_path_to(sa)])
		var rest_delta := 0.0
		for bone in sa.get_bone_count():
			rest_delta = maxf(rest_delta, (sa.get_bone_rest(bone).origin - sb.get_bone_rest(bone).origin).length())
		_h.item()
		_h.expect(rest_delta < 1e-6, "rest_changed", "%s 骨骼 rest 改变 %.6f" % [unit_id, rest_delta])
		var ba := _body(sa)
		var bb := _body(sb)
		_h.item()
		_h.expect(ba != null and bb != null and ba.mesh == bb.mesh and ba.skin == bb.skin, "body_mesh_changed",
			"%s %s 身体网格/蒙皮不是同一资源" % [unit_id, original.get_path_to(sa)])
		if bb != null:
			for s in bb.mesh.get_surface_count():
				triangles += bb.mesh.surface_get_array_index_len(s) / 3
	row["resident_body_triangles"] = triangles
	var clips_a := _clips(original)
	var clips_b := _clips(refined)
	_h.item()
	_h.expect(clips_a == clips_b and not clips_a.is_empty(), "clips_changed", "%s 动作片段（名/长/循环/轨道）不同" % unit_id)
	row["clips"] = clips_b.size()
	for method in ["play_idle", "play_attack", "play_run"]:
		_h.item()
		_h.expect(original.has_method(method) == refined.has_method(method), "interface_changed", "%s 包装接口 %s 不一致" % [unit_id, method])


func _clips(root: Node) -> Array:
	var out: Array = []
	for found in root.find_children("*", "AnimationPlayer", true, false):
		var player := found as AnimationPlayer
		for name in player.get_animation_list():
			var clip := player.get_animation(name)
			out.append("%s|%s|%.4f|%d|%d" % [root.get_path_to(player), name, clip.length, clip.loop_mode, clip.get_track_count()])
	out.sort()
	return out


func _check_materials(unit_id: String, refined: Node3D, row: Dictionary) -> void:
	var expected := "%s/%s_body.tres" % [refined_dir(unit_id), unit_id]
	var material := load(expected) as ShaderMaterial
	_h.item()
	if not _h.expect(material != null and material.shader.resource_path in BODY_SHADERS,
			"material_route", "%s 精修材质未使用暗族专属 shader" % unit_id):
		return
	for skeleton: Skeleton3D in _skeletons(refined):
		var body := _body(skeleton)
		for s in body.mesh.get_surface_count():
			_h.item()
			_h.expect(body.get_surface_override_material(s) == material, "material_not_applied",
				"%s %s surface %d 未使用精修材质" % [unit_id, refined.get_path_to(skeleton), s])
	var albedo := material.get_shader_parameter("albedo_texture") as Texture2D
	_h.item()
	_h.expect(albedo != null and albedo.resource_path.contains("/%s_refined/" % _race) and maxi(albedo.get_width(), albedo.get_height()) <= MAX_TEXTURE_EDGE,
		"texture_budget", "%s 精修贴图缺失或超过 %d" % [unit_id, MAX_TEXTURE_EDGE])
	if albedo != null:
		var format := albedo.get_image().get_format()
		row["albedo"] = {"path": albedo.resource_path, "size": albedo.get_width(), "format": format}
		_h.item()
		_h.expect(format in [Image.FORMAT_DXT1, Image.FORMAT_ETC2_RGB8, Image.FORMAT_ETC], "albedo_alpha",
			"%s 精修贴图仍带 alpha（format %d），显存翻倍" % [unit_id, format])


## Parts are one skinned surface per action skeleton, every vertex 100% on one bone
## with an identity bind (vertices are bone-local), so the engine's own skinning moves
## them exactly with that bone. Verify that structure on every skeleton.
func _check_parts(unit_id: String, refined: Node3D, row: Dictionary) -> void:
	var per_skeleton: Array = []
	var part_triangles := 0
	# Some units are refined by material only (undead small/fly): then no parts at all.
	var authored := FileAccess.file_exists("%s/%s_parts.glb" % [refined_dir(unit_id), unit_id])
	for skeleton: Skeleton3D in _skeletons(refined):
		var parts := skeleton.get_node_or_null("CraftedParts") as MeshInstance3D
		var where := "%s %s" % [unit_id, refined.get_path_to(skeleton)]
		_h.item()
		if not authored:
			_h.expect(parts == null, "parts_unexpected", "%s 没有零件资源却挂了部件" % where)
			per_skeleton.append(0)
			continue
		if not _h.expect(parts != null and parts.mesh != null and parts.skin != null, "parts_missing", "%s 没有精修部件或未蒙皮" % where):
			per_skeleton.append(0)
			continue
		_h.item()
		_h.expect(parts.get_node_or_null(parts.skeleton) == skeleton and parts.mesh.get_surface_count() == 1, "parts_rig",
			"%s 部件未绑定到本动作骨架或不是单一 surface" % where)
		var bones: Array[String] = []
		for b in parts.skin.get_bind_count():
			var name := str(parts.skin.get_bind_name(b))
			bones.append(name)
			_h.item()
			_h.expect(skeleton.find_bone(name) >= 0 and parts.skin.get_bind_pose(b).is_equal_approx(Transform3D.IDENTITY), "parts_bind",
				"%s 部件绑定 %s 不存在或不是单位绑定" % [where, name])
		var arrays := parts.mesh.surface_get_arrays(0)
		var weights := arrays[Mesh.ARRAY_WEIGHTS] as PackedFloat32Array
		var rigid := true
		for i in range(0, weights.size(), 4):
			rigid = rigid and is_equal_approx(weights[i], 1.0)
		_h.item()
		_h.expect(rigid and not weights.is_empty(), "parts_not_rigid", "%s 部件顶点不是 100%% 单骨权重" % where)
		part_triangles += parts.mesh.surface_get_array_index_len(0) / 3
		per_skeleton.append(bones)
	row["parts_per_skeleton"] = per_skeleton
	row["resident_part_triangles"] = part_triangles
