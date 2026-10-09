extends Node

# 10.10 第 10 条：凤凰涅槃「死灵气息」的**成片证据**（不是单测）。
#
# 为什么要单独做一次渲染取证：
#   门禁（tools/undead_necrotic_aura_check.gd）只能证明「结构上不可能遮挡模型」
#   （每个面片都是加色混合 + 边光 alpha 由法线/视线夹角驱动）。但用户这条需求的
#   另外两句是**纯美术判断** ——「风格与游戏一致」「光环不遮挡棋子样子」。
#   这两句只有图像能回答，代码再绿也证明不了。
#
# 做法：用生产函数造两块**同一个模型、同一个位置、同一动画相位**的 actor ——
#   一块普通棋子、一块凤凰涅槃复活体。逐帧只显示其中一块，各拍一张。
#   两张图除了「有没有死灵气息」以外一切相同 ⇒ 可以做像素差分，判据分两半：
#     · **模型自己的像素**（基线图里属于模型剪影的那些点）改动必须很小 ——
#       这才是「不遮挡棋子样子」的量化判据；
#     · **背景像素**必须有可见变化 —— 否则说明光环根本没画出来。
#   只按固定方框取「中心区」是不可靠的：模型在画面里的实际落点由
#   _center_model_for_full_body_view + base_yaw 决定，写死坐标会把地面圈算进身体。
#   ⇒ 所以按**基线图的亮度**自动分出「模型像素 / 背景像素」。
#
# 顺带扫一遍边光强度：material_overlay 的 Fresnel 边光在低面数模型上会把整块面
#   染绿，所以这里同时出 0 / 0.15 / 0.30 / 生产值 / 生产值+异族模型 几档供人眼定档；
#   门禁里锚死的 MAX_MODEL_DIFF 就是按这组片子定的。
#
# 运行（必须带渲染器，headless 是 dummy 驱动、拍不出东西）：
#   Godot --path . --rendering-method gl_compatibility --resolution 900x640 \
#     --always-on-top res://tools/undead_necrotic_aura_capture.tscn -- --out <绝对目录>

const Aura := preload("res://effects/vfx3d/modules/UndeadNecrosisAura3D.gd")
const VIEWPORT_SIZE := Vector2i(1000, 700)
# 模型像素的平均绝对差上限（0-255）。边光本质是「给模型上色」，
# 所以不可能为 0；超过这个数就属于「糊住了棋子样子」而不是「笼罩」。
const MAX_MODEL_DIFF := 30.0
# 背景必须真的有东西出现，否则等于没渲染。
const MIN_BACKGROUND_DIFF := 1.5
# 基线图里亮于此值的像素算「模型剪影」。
const SILHOUETTE_LUMA := 0.10

var _out := ""
var _vp: SubViewport = null
var _report: Dictionary = {}
var _failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	await get_tree().process_frame
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if i + 1 < args.size() and str(args[i]) == "--out":
			_out = ProjectSettings.globalize_path(str(args[i + 1]))
	if _out.is_empty():
		push_error("capture requires --out <absolute dir>")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	await get_tree().process_frame

	var battle_script: Script = load("res://scenes/battle/BattleVfx.gd")
	var battle: Control = battle_script.new()
	add_child(battle)
	var arena := Control.new()
	arena.size = Vector2(1000.0, 520.0)
	battle.add_child(arena)
	battle.set("_arena", arena)

	var vp := SubViewport.new()
	vp.size = VIEWPORT_SIZE
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.transparent_bg = false
	add_child(vp)
	_vp = vp
	var world := Node3D.new()
	world.name = "CaptureWorld"
	vp.add_child(world)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.07, 0.08, 0.11)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.62, 0.66, 0.78)
	e.ambient_light_energy = 0.85
	env.environment = e
	world.add_child(env)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-46.0, -38.0, 0.0)
	light.light_energy = 1.05
	world.add_child(light)
	var cam := Camera3D.new()
	# 与 BattleArena 的战斗镜头同向（0, 7.4, 7 看原点），只是拉近成单人特写。
	cam.look_at_from_position(Vector3(0.0, 1.30, 1.90), Vector3(0.0, 0.40, 0.0), Vector3.UP)
	cam.fov = 42.0
	world.add_child(cam)
	cam.current = true
	battle.set("_battle_3d_root", world)

	# rim = 边光强度覆盖值（-1 表示用生产值）。
	var cases: Array[Dictionary] = [
		{"label": "01_plain_swordsman", "unit": "human_swordsman", "phoenix": false, "rim": -1.0},
		{"label": "02_phoenix_rim000", "unit": "human_swordsman", "phoenix": true, "rim": 0.0},
		{"label": "03_phoenix_rim015", "unit": "human_swordsman", "phoenix": true, "rim": 0.15},
		{"label": "04_phoenix_rim030", "unit": "human_swordsman", "phoenix": true, "rim": 0.30},
		{"label": "05_phoenix_rim_production", "unit": "human_swordsman", "phoenix": true, "rim": -1.0},
		{"label": "06_phoenix_undead_titan", "unit": "undead_titan", "phoenix": true, "rim": -1.0},
	]
	var shots: Array[Dictionary] = []
	var diffs: Array[Dictionary] = []
	for case in cases:
		var shot: Dictionary = await _render_case(battle, world, str(case.unit), str(case.label),
			bool(case.phoenix), float(case.rim))
		shots.append(shot)
		if str(case.label).begins_with("01"):
			continue
		if str(case.unit) != "human_swordsman":
			continue
		var m := _diff(_out.path_join("01_plain_swordsman.png"), str(shot.get("file", "")))
		m["label"] = str(case.label)
		m["rim"] = float(case.rim)
		diffs.append(m)
		if str(case.label) == "05_phoenix_rim_production":
			_report["occlusion"] = m
			if float(m.get("model", 999.0)) > MAX_MODEL_DIFF:
				_failures.append("生产档边光把模型像素平均改了 %.1f/255（上限 %.1f）—— 属于糊住棋子不是笼罩" % [
					float(m.get("model", 0.0)), MAX_MODEL_DIFF])
			if float(m.get("background", 0.0)) < MIN_BACKGROUND_DIFF:
				_failures.append("背景几乎没变化（%.2f/255）—— 光环可能根本没渲染出来" % float(m.get("background", 0.0)))
	_report["screenshots"] = shots
	_report["diffs"] = diffs
	_report["last_case_aura"] = shots[shots.size() - 1].get("aura_state", {}) if not shots.is_empty() else {}
	_report["failures"] = _failures
	_report["status"] = "PASS" if _failures.is_empty() else "FAIL"
	_report["generated_utc"] = Time.get_datetime_string_from_system(true, false)
	_report["viewport"] = [VIEWPORT_SIZE.x, VIEWPORT_SIZE.y]
	_report["max_model_diff"] = MAX_MODEL_DIFF
	var f := FileAccess.open(_out.path_join("capture_report.json"), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_report, "  "))
		f.close()
	print("NECROSIS_CAPTURE_RESULT status=%s shots=%d %s" % [
		_report.status, shots.size(), JSON.stringify(_failures)])
	get_tree().quit(0 if _failures.is_empty() else 1)


func _render_case(battle: Control, world: Node3D, unit_id: String, label: String,
		phoenix: bool, rim_opacity: float) -> Dictionary:
	# 同一模型、同一位置、同一动画相位：两块 actor 同帧建出来，逐帧只显示一块。
	var def: Dictionary = DataRegistry.canonical_unit_def(unit_id)
	var uid_prefix := "cap_" + label
	var plain := _fighter(uid_prefix + "_plain", def, false)
	var revived := _fighter(uid_prefix + "_phoenix", def, true)
	var plain_actor: Node3D = battle.call("_make_shared_model_node", plain)
	var phoenix_actor: Node3D = battle.call("_make_shared_model_node", revived)
	if plain_actor == null or phoenix_actor == null:
		_failures.append("model build failed for " + unit_id)
		return {"label": label, "file": "", "error": "model_build_failed"}
	plain_actor.name = "CasePlain"
	phoenix_actor.name = "CasePhoenix"
	world.add_child(plain_actor)
	world.add_child(phoenix_actor)
	(battle.get("_battle_3d_models") as Dictionary)[str(plain.uid)] = plain_actor
	(battle.get("_battle_3d_models") as Dictionary)[str(revived.uid)] = phoenix_actor
	# 走生产接线：这一句才决定「有没有死灵气息」。
	battle.call("_sync_3d_model_nodes", [plain, revived], 0.0, false)
	# 两块都放到原点，正面朝镜头。
	for actor in [plain_actor, phoenix_actor]:
		actor.position = Vector3.ZERO
		actor.rotation_degrees = Vector3.ZERO
	var aura := phoenix_actor.get_node_or_null(Aura.NODE_NAME)
	var plain_aura := plain_actor.get_node_or_null(Aura.NODE_NAME)
	if phoenix and aura == null:
		_failures.append("%s：复活体上没有死灵气息节点" % label)
	if not phoenix and plain_aura != null:
		_failures.append("%s：普通棋子身上不该有死灵气息节点" % label)
	var aura_state: Dictionary = {}
	if aura != null:
		if rim_opacity >= 0.0:
			aura.get("rim_material").set_shader_parameter("opacity", rim_opacity)
		aura_state = aura.call("debug_state")
	plain_actor.visible = not phoenix
	phoenix_actor.visible = phoenix
	# 光环要「长出来」：粒子有 preprocess，但也给几帧让材质落地。
	for i in 8:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image: Image = _vp.get_texture().get_image()
	var file: String = _out.path_join(label + ".png")
	var err: int = image.save_png(file)
	if err != OK:
		_failures.append("save_png failed for " + label)
	plain_actor.queue_free()
	phoenix_actor.queue_free()
	await get_tree().process_frame
	# 清干净：_status_vfx_by_id 里存的是刚被 queue_free 的控制器，
	# 下一个用例若撞上同一个 id 会在 BattleRenderer 里炸「invalid previously freed instance」。
	(battle.get("_battle_3d_models") as Dictionary).clear()
	(battle.get("_status_vfx_by_id") as Dictionary).clear()
	return {"label": label, "file": file, "unit": unit_id, "phoenix": phoenix,
		"rim_opacity_override": rim_opacity, "aura_present": aura != null,
		"aura_state": aura_state, "save_error": err}


func _fighter(uid: String, def: Dictionary, phoenix: bool) -> Dictionary:
	var f := {"uid": uid, "id": str(def.get("id", "human_swordsman")), "name": str(def.get("name", "")),
		"team": "player", "lane": 0, "star": 1, "hp": 100, "max_hp": 100, "shield": 0, "alive": true,
		"pos": Vector2(500.0, 260.0), "def": def, "statuses": {}, "attack_count": 0}
	if phoenix:
		f["phoenix_used"] = true
	return f


# 按**基线图**自动分「模型像素 / 背景像素」，再各算平均绝对差。
# 比写死方框可靠：模型在画面里的落点随 _center_model_for_full_body_view、
# base_yaw、以及具体模型的高矮而变，写死坐标会把地面圈算进「身体」。
func _diff(plain_path: String, other_path: String) -> Dictionary:
	var a := Image.load_from_file(plain_path)
	var b := Image.load_from_file(other_path)
	if a == null or b == null or a.get_size() != b.get_size():
		return {"model": 999.0, "background": 0.0, "error": "image_load_failed"}
	var size := a.get_size()
	var model_total := 0.0
	var model_count := 0
	var bg_total := 0.0
	var bg_count := 0
	for y in size.y:
		for x in size.x:
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			var d := (absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)) / 3.0 * 255.0
			var luma := (ca.r + ca.g + ca.b) / 3.0
			if luma > SILHOUETTE_LUMA:
				model_total += d
				model_count += 1
			else:
				bg_total += d
				bg_count += 1
	return {
		"model": 0.0 if model_count == 0 else model_total / float(model_count),
		"background": 0.0 if bg_count == 0 else bg_total / float(bg_count),
		"model_pixels": model_count,
		"background_pixels": bg_count,
		"size": [size.x, size.y],
	}
