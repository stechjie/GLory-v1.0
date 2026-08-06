extends SceneTree
# 技能特效截帧驱动。
#
# 配合 Godot 的 Movie Maker 模式使用，按引擎固定步长逐帧输出 PNG：
#
#   godot --path . --script tools/vfx_capture.gd \
#         --write-movie <out>/frame.png --fixed-fps 12 --quit-after <N>
#
# 关键是 --fixed-fps：每帧 delta 恒为 1/fps，与机器负载无关，
# 所以同一份代码跑两次逐帧一致，可以直接做像素 diff 做回归。
# （现有的 Phase3ModuleCapture.gd 用的是墙上时钟 + save_png，截到第几帧取决于
# 当时机器多忙，没法前后对比。）
#
# 技能清单从 data/ 里的 JSON 现读，不硬编码，所以加了新单位不会漏截。
# 用 --skills a,b,c 可以只截指定技能。

const VFX_ROOT := preload("res://effects/BossProceduralVFX3D.gd")

# 与 BattleUI.gd 保持一致，让截图的取景和真实战斗一样。
const CAMERA_SIZE := 7.2
const CAMERA_POS := Vector3(0.0, 7.4, 7.0)
const GROUND_Y := -0.14
# Stand-in height, matching BattleRenderer.NOMINAL_UNIT_HEIGHT. Measured off
# rendered silhouettes across ten units (0.71-1.08, median ~0.95); mesh AABBs
# are not usable for this - they underestimate by 1.15x-3.5x per model.
const MARKER_HEIGHT := 0.98
# Mirrors BattleUI.battle_unit_visual_scale, used when standing real models in.
const BATTLE_UNIT_VISUAL_SCALE := 0.42

# 每个技能分配的帧数。固定步长下这就是确定的时长（24 帧 @12fps = 2 秒），
# 足够覆盖大部分技能的起手/峰值/消散三段。
const FRAMES_PER_SKILL := 24
# 开头留几帧给场景搭建和着色器预热，不参与比对。
const WARMUP_FRAMES := 6
# 末尾留几帧，避免最后一个技能的收尾被 --quit-after 截断。
const TAIL_FRAMES := 4

# 固定站位：施法者在近端，目标在远端，和战斗里前后排的相对关系一致。
const ORIGIN_POS := Vector3(0.0, 0.0, 1.7)
const TARGET_POS := Vector3(0.0, 0.0, -1.7)
# 群体技的固定目标点，数量取 4 是为了在 LOW 档（上限 4）也不被截断，
# 保证不同画质档位截出来的基线可比。
const GROUP_POS: Array[Vector3] = [
	Vector3(-1.9, 0.0, -1.7), Vector3(-0.6, 0.0, -2.1),
	Vector3(0.7, 0.0, -1.4), Vector3(2.0, 0.0, -1.9),
]

# 固定随机种子。换这个值等于换一组"随机"表现，基线要一起重截。
const RANDOM_SEED := 20260723

var _vfx_root: Node3D
var _origin_unit: Node3D
var _target_unit: Node3D
var _skills: Array[String] = []
# skill_id -> 拥有它的单位 id。有些特效会按 source_unit_id 分支
# （god_guard 拿全尺寸金盾、merc_cancer_shell 拿青色甲壳、undead_fly 换毒羽），
# 传一个假 id 会让这些技能全部按退化分支渲染，量出来的结果不是玩家看到的。
var _skill_owner: Dictionary = {}
var _output_dir := "user://vfx_capture"
# Real models stood in for the capsules. Empty = keep the capsules.
var _origin_unit_id := ""
var _target_unit_id := ""
var _unit_defs: Dictionary = {}
var _origin_height := MARKER_HEIGHT
var _target_height := MARKER_HEIGHT
# Skinned meshes report a usable AABB only after a frame in the tree, so model
# stand-ins are measured and anchored during warm-up, not at build time.
var _pending_models: Array = []
var _camera: Camera3D = null
# Screen-space ruler for each stand-in, written into the manifest so the analysis
# can express "where did this effect land" as a percentage of the unit's height
# instead of a guess off a screenshot.
var _rulers: Dictionary = {}
var _frame := 0
var _current_skill := ""

func _initialize() -> void:
	# 特效模块里有 randf_range（火花方向、翻页速度等）。不定死种子的话
	# 两次截帧的画面就不一样，像素 diff 会全线飘红，回归比对就没意义了。
	seed(RANDOM_SEED)
	_parse_arguments()
	if root.get_node_or_null("VFXManager") == null:
		push_error("VFXManager autoload missing — run with --path pointing at the project root.")
		quit(1)
		return
	_build_stage()
	_skills = _collect_skills()
	if _skills.is_empty():
		push_error("No skills to capture.")
		quit(1)
		return
	_write_manifest()
	print("vfx_capture: %d skills, %d frames each, %d frames total" % [
		_skills.size(), FRAMES_PER_SKILL, total_frames()])

# 供 runner 计算 --quit-after 用。
func total_frames() -> int:
	return WARMUP_FRAMES + _skills.size() * FRAMES_PER_SKILL + TAIL_FRAMES

func _process(_delta: float) -> bool:
	_frame += 1
	if _frame == 2:
		_finalise_model_stand_ins()
	if _frame <= WARMUP_FRAMES:
		return false
	var elapsed := _frame - WARMUP_FRAMES - 1
	var index := elapsed / FRAMES_PER_SKILL
	if index >= _skills.size():
		# 尾巴跑完再退出，让最后一个技能的收尾也进到序列里。
		return elapsed >= _skills.size() * FRAMES_PER_SKILL + TAIL_FRAMES
	# 每个窗口的第一帧只做清场。queue_free() 是延迟到帧末执行的，
	# 如果在同一帧就放下一个技能，上一个技能的块还活着，会污染画面
	# 甚至挤占并发额度。空出一帧让释放真正落地。
	var phase := elapsed % FRAMES_PER_SKILL
	if phase == 0:
		_clear_previous()
	elif phase == 1:
		_play(_skills[index])
	return false

func _play(skill_id: String) -> void:
	_current_skill = skill_id
	# 并发计数应当在每个技能开播前回到 0。回不去说明有块没被释放，
	# 上限会越收越紧，最后把后面的技能全部饿死 —— 这条日志就是用来盯这个的。
	print("  [%04d] active=%d %s" % [_frame, VFXBlockRoot.active_block_count(), skill_id])
	# BattleVfx hands the composer BODY anchors (world_cast / world_hit), not foot
	# positions. Feed the same thing here or the capture lies about placement.
	var origin_base := ORIGIN_POS + Vector3(0.0, GROUND_Y + _origin_height * 0.55, 0.0)
	var target_base := TARGET_POS + Vector3(0.0, GROUND_Y + _target_height * 0.55, 0.0)
	_vfx_root.call("play", skill_id, origin_base, target_base, _context())

# 上一个技能的残留必须清干净，否则前一个技能的时长会污染下一个的基线。
func _clear_previous() -> void:
	for composer in _vfx_root.get_children():
		for block in composer.get_children():
			block.queue_free()
	for child in _vfx_root.get_children():
		if not (child is Node3D) or child.get_script() != null:
			continue
		child.queue_free()

func _context() -> Dictionary:
	return {
		"targets": GROUP_POS.duplicate(),
		"origin_node": _origin_unit.get_node("CastAnchor"),
		"target_node": _target_unit.get_node("HitAnchor"),
		"source_unit_id": str(_skill_owner.get(_current_skill, "capture_source")),
		"target_unit_id": "capture_target",
		"stacks": 5,
		"heal_target": ORIGIN_POS,
		"target_height": _target_height,
		"origin_height": _origin_height,
	}

func _build_stage() -> void:
	var world := Node3D.new()
	world.name = "CaptureStage"
	root.add_child(world)

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(14.0, 14.0)
	ground.mesh = plane
	ground.position.y = GROUND_Y
	var ground_material := StandardMaterial3D.new()
	ground_material.albedo_color = Color(0.19, 0.21, 0.18)
	ground_material.roughness = 1.0
	ground.material_override = ground_material
	world.add_child(ground)

	var light := DirectionalLight3D.new()
	light.light_color = Color(1.0, 0.84, 0.62)
	light.light_energy = 1.55
	light.rotation_degrees = Vector3(-55, 35, 0)
	world.add_child(light)

	var environment_node := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.05, 0.06, 0.07)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.34, 0.42, 0.34)
	environment.ambient_light_energy = 0.42
	environment_node.environment = environment
	world.add_child(environment_node)

	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = CAMERA_SIZE
	camera.look_at_from_position(CAMERA_POS, Vector3.ZERO, Vector3.UP)
	camera.current = true
	world.add_child(camera)
	_camera = camera

	_unit_defs = _collect_unit_defs()
	_origin_unit = _make_stand_in("OriginUnit", ORIGIN_POS, Color(0.26, 0.44, 0.72), _origin_unit_id, true)
	_target_unit = _make_stand_in("TargetUnit", TARGET_POS, Color(0.66, 0.28, 0.28), _target_unit_id, false)
	world.add_child(_origin_unit)
	world.add_child(_target_unit)

	_vfx_root = VFX_ROOT.new()
	_vfx_root.name = "BossProceduralVFX3D"
	world.add_child(_vfx_root)

# Build the stand-in for one side. With a unit id it loads that unit's real
# battle model (same scale chain as BattleRenderer: model_visual_scale *
# battle_unit_visual_scale, x1.2 for T3, feet centred at y=0); without one it
# falls back to the capsule.
func _make_stand_in(node_name: String, at: Vector3, tint: Color, unit_id: String, is_origin: bool) -> Node3D:
	var marker: Node3D = null
	if not unit_id.is_empty() and _unit_defs.has(unit_id):
		marker = _make_model_marker(node_name, at, unit_id)
	if marker == null:
		marker = _make_marker(node_name, at, tint, MARKER_HEIGHT)
		if is_origin:
			_origin_height = MARKER_HEIGHT
		else:
			_target_height = MARKER_HEIGHT
	return marker

# Measure, foot-centre and anchor the real models once they have been in the
# tree for a frame. Same chain as BattleRenderer: feet at y=0, anchors at
# 1.02 / 0.55 / 0.05 of the measured height.
func _finalise_model_stand_ins() -> void:
	for entry: Dictionary in _pending_models:
		var marker: Node3D = entry["marker"]
		var model: Node3D = entry["model"]
		if not (is_instance_valid(marker) and is_instance_valid(model)):
			continue
		var bounds := _model_bounds(model)
		if bounds.size != Vector3.ZERO:
			var center := bounds.get_center()
			model.position -= Vector3(center.x, bounds.position.y, center.z)
		# Nominal height, same as the battle renderer: the AABB is unreliable here.
		var height := MARKER_HEIGHT
		marker.set_meta("model_height", height)
		for anchor_name in ["HitAnchor", "CastAnchor", "HeadAnchor", "FeetAnchor", "BodyAnchor"]:
			var anchor := marker.get_node_or_null(anchor_name) as Node3D
			if anchor == null:
				continue
			match anchor_name:
				"FeetAnchor": anchor.position.y = height * 0.05
				"HeadAnchor": anchor.position.y = height * 1.02
				_: anchor.position.y = height * 0.55
		# Freeze the model. An idle animation makes every frame differ from the
		# reference, which swamps the pixel diff with the model's own motion and
		# breaks both the regression compare and the placement measurement.
		_freeze_animations(model)
		if bool(entry["is_origin"]):
			_origin_height = height
		else:
			_target_height = height
		print("  stand-in measured %s height=%.3f" % [marker.name, height])
	_pending_models.clear()
	_measure_rulers()

# Project each stand-in's feet and crown to screen pixels. Ratios in the analysis
# are (effect_y - feet_y) / (feet_y - head_y), i.e. 0% = on the ground,
# 100% = at the crown, >100% = above the head.
func _measure_rulers() -> void:
	if _camera == null:
		return
	for entry in [{"name": "origin", "node": _origin_unit, "h": _origin_height},
			{"name": "target", "node": _target_unit, "h": _target_height}]:
		var node: Node3D = entry["node"]
		if not is_instance_valid(node):
			continue
		var feet: Vector3 = node.global_position
		var head: Vector3 = feet + Vector3(0.0, float(entry["h"]), 0.0)
		_rulers[entry["name"]] = {
			"feet_px": _camera.unproject_position(feet).y,
			"head_px": _camera.unproject_position(head).y,
			"x_px": _camera.unproject_position(feet).x,
			"height": float(entry["h"]),
		}
	var payload := JSON.stringify(_rulers)
	print("  rulers %s" % payload)
	# The manifest was written before the models could be measured; rewrite it now
	# that the rulers exist. Still well before the first skill plays.
	_write_manifest()

func _make_model_marker(node_name: String, at: Vector3, unit_id: String) -> Node3D:
	var unit_def: Dictionary = _unit_defs.get(unit_id, {})
	var path := str(unit_def.get("model", ""))
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	var scene := load(path) as PackedScene
	if scene == null:
		return null
	var model := scene.instantiate() as Node3D
	if model == null:
		return null
	var marker := Node3D.new()
	marker.name = node_name
	marker.position = at + Vector3(0.0, GROUND_Y, 0.0)
	marker.rotation_degrees.y = float(unit_def.get("model_base_yaw", 180.0))
	# BATTLE_UNIT_VISUAL_SCALE mirrors BattleUI.battle_unit_visual_scale.
	var visual_scale := float(unit_def.get("model_visual_scale", 1.0)) * BATTLE_UNIT_VISUAL_SCALE
	if int(unit_def.get("tier", 1)) == 3:
		visual_scale *= 1.2
	model.scale = Vector3(visual_scale, visual_scale, visual_scale)
	marker.add_child(model)
	for anchor_name in ["HitAnchor", "CastAnchor", "HeadAnchor", "FeetAnchor", "BodyAnchor"]:
		var anchor := Node3D.new()
		anchor.name = anchor_name
		marker.add_child(anchor)
	_pending_models.append({"marker": marker, "model": model, "is_origin": node_name == "OriginUnit"})
	return marker

func _freeze_animations(node: Node) -> void:
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var current: Node = stack.pop_back()
		if current is AnimationPlayer:
			(current as AnimationPlayer).stop()
			(current as AnimationPlayer).active = false
		if current is AnimationTree:
			(current as AnimationTree).active = false
		for child in current.get_children():
			stack.append(child)

func _model_bounds(node: Node3D) -> AABB:
	var result := AABB()
	var seen := false
	var stack: Array = [{"node": node, "xform": Transform3D.IDENTITY}]
	while not stack.is_empty():
		var entry: Dictionary = stack.pop_back()
		var current: Node = entry["node"]
		var xform: Transform3D = entry["xform"]
		if current is Node3D:
			xform = xform * (current as Node3D).transform
		if current is VisualInstance3D:
			var world := xform * (current as VisualInstance3D).get_aabb()
			result = world if not seen else result.merge(world)
			seen = true
		for child in current.get_children():
			stack.append({"node": child, "xform": xform})
	return result

func _collect_unit_defs() -> Dictionary:
	var defs := {}
	for path in [
		"res://data/units/race_units.json",
		"res://data/mercenary/mercenaries.json",
		"res://data/pve/pve_monsters.json",
		"res://data/formation/formation_allies.json",
		"res://data/boss/bosses.json",
	]:
		_harvest_unit_defs(_read_json(path), defs)
	return defs

func _harvest_unit_defs(value: Variant, defs: Dictionary) -> void:
	if value is Dictionary:
		var entry := value as Dictionary
		var id := str(entry.get("id", ""))
		if not id.is_empty() and entry.has("model"):
			defs[id] = entry
		for sub in entry.values():
			_harvest_unit_defs(sub, defs)
	elif value is Array:
		for sub in value as Array:
			_harvest_unit_defs(sub, defs)

# 替身单位：给贴地/追踪类特效一个可见的参照体和锚点。
# 特效模块只读锚点的 global_position，不关心替身长什么样。
func _make_marker(marker_name: String, at: Vector3, tint: Color, height: float) -> Node3D:
	var marker := Node3D.new()
	marker.name = marker_name
	marker.position = at
	var body := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = height * 0.30
	capsule.height = height
	body.mesh = capsule
	body.position.y = GROUND_Y + height * 0.5
	var body_material := StandardMaterial3D.new()
	body_material.albedo_color = tint
	body_material.roughness = 0.85
	body.material_override = body_material
	marker.add_child(body)
	# Anchor heights use the same ratios BattleRenderer now derives from the real
	# model bounds, so what the capture shows is what the battle shows.
	for anchor_name in ["HitAnchor", "CastAnchor", "HeadAnchor", "FeetAnchor", "BodyAnchor"]:
		var anchor := Node3D.new()
		anchor.name = anchor_name
		match anchor_name:
			"FeetAnchor": anchor.position.y = GROUND_Y + height * 0.05
			"HeadAnchor": anchor.position.y = GROUND_Y + height * 1.02
			_: anchor.position.y = GROUND_Y + height * 0.55
		marker.add_child(anchor)
	return marker

# 技能清单直接从 data/ 里现读，避免和 Phase3ModuleCapture 一样把清单
# 硬编码成下标、过两周就对不上。
func _collect_skills() -> Array[String]:
	var found := {}
	for path in [
		"res://data/units/race_units.json",
		"res://data/mercenary/mercenaries.json",
		"res://data/pve/pve_monsters.json",
		"res://data/formation/formation_allies.json",
		"res://data/boss/bosses.json",
	]:
		_harvest_skill_ids(_read_json(path), found)
	# --skills 也要先扫过一遍 data/，否则 _skill_owner 是空的，
	# 按 source_unit_id 分支的技能又会退回到假 id。
	# Basic attacks (basic_attack_*) are not any JSON's skill_id, so the data/
	# sweep cannot find their owner - yet the basic attack is exactly what picks
	# its bolt prototype and melee trail off source_unit_id.
	# --owners skill=unit,skill=unit fills that in; capture tooling only.
	var owners := _argument_value("--owners")
	if not owners.is_empty():
		for pair in owners.split(",", false):
			var kv := pair.strip_edges().split("=", false)
			if kv.size() == 2:
				_skill_owner[kv[0].strip_edges()] = kv[1].strip_edges()
	var explicit := _argument_value("--skills")
	if not explicit.is_empty():
		var chosen: Array[String] = []
		for part in explicit.split(",", false):
			var trimmed := part.strip_edges()
			if not trimmed.is_empty():
				chosen.append(trimmed)
		return chosen
	var ids: Array[String] = []
	for key in found:
		ids.append(str(key))
	ids.sort()
	return ids

func _harvest_skill_ids(value: Variant, found: Dictionary) -> void:
	if value is Dictionary:
		var skill_id := str((value as Dictionary).get("skill_id", ""))
		# post_battle_gold_by_star 是战后结算的经济技，本来就没有战斗表现。
		if not skill_id.is_empty() and skill_id != "none" and skill_id != "post_battle_gold_by_star":
			found[skill_id] = true
			var owner_id := str((value as Dictionary).get("id", ""))
			if not owner_id.is_empty() and not _skill_owner.has(skill_id):
				_skill_owner[skill_id] = owner_id
		for sub in (value as Dictionary).values():
			_harvest_skill_ids(sub, found)
	elif value is Array:
		for sub in value as Array:
			_harvest_skill_ids(sub, found)

func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		push_warning("vfx_capture: missing data file %s" % path)
		return null
	var text := FileAccess.get_file_as_string(path)
	var parsed = JSON.parse_string(text)
	if parsed == null:
		push_warning("vfx_capture: could not parse %s" % path)
	return parsed

# 帧号 → 技能名的对照表，给 tools/vfx_diff.py 切片用。
func _write_manifest() -> void:
	DirAccess.make_dir_recursive_absolute(_output_dir)
	# Movie Maker 的帧文件从 frame00000000.png 开始编号，所以帧号是 0 基的：
	# 第 i 个技能的第一帧就是 WARMUP_FRAMES + i * FRAMES_PER_SKILL。
	var entries: Array = []
	for i in range(_skills.size()):
		entries.append({
			"skill_id": _skills[i],
			"first_frame": WARMUP_FRAMES + i * FRAMES_PER_SKILL + 1,
			"frame_count": FRAMES_PER_SKILL - 1,
		})
	var manifest := {
		"frames_per_skill": FRAMES_PER_SKILL,
		"warmup_frames": WARMUP_FRAMES,
		# 空场景参照帧：最后一帧预热，此时还没有任何技能开始播。
		"empty_frame": WARMUP_FRAMES - 1,
		"total_frames": total_frames(),
		"quality_tier": root.get_node("VFXManager").call("get_quality_tier"),
		"rulers": _rulers,
		"origin_unit": _origin_unit_id,
		"target_unit": _target_unit_id,
		"skills": entries,
	}
	var file := FileAccess.open(_output_dir.path_join("manifest.json"), FileAccess.WRITE)
	if file == null:
		push_error("vfx_capture: cannot write manifest to %s" % _output_dir)
		return
	file.store_string(JSON.stringify(manifest, "\t"))
	file.close()

func _parse_arguments() -> void:
	var out := _argument_value("--out")
	if not out.is_empty():
		_output_dir = out
	# --unit / --target-unit put the real battle models on the stage instead of
	# the capsules, built exactly the way BattleRenderer builds them.
	_origin_unit_id = _argument_value("--unit")
	_target_unit_id = _argument_value("--target-unit")
	var tier := _argument_value("--tier")
	if not tier.is_empty():
		# 压档跑一遍就能看到低端机上会被并发上限砍掉哪些特效。
		var names := {"low": 0, "medium": 1, "high": 2}
		if names.has(tier.to_lower()):
			root.get_node("VFXManager").call("set_quality_tier", int(names[tier.to_lower()]))

func _argument_value(flag: String) -> String:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size()):
		if args[i] == flag and i + 1 < args.size():
			return args[i + 1]
		if args[i].begins_with(flag + "="):
			return args[i].substr(flag.length() + 1)
	return ""
