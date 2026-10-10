extends Control
## 黑龙 / 母灵 / 神王 技能特效循环预览（离线美术验收用）。
##
## 打开 res://effects/preview/HeroSkillVFXPreview.tscn 后按 F6 运行。每个用例都走
## 正式分发器 BossProceduralVFX3D.play(effect_id, ...)，与战斗中 BattleVfx 的落点相同；
## 「原版」开关回放改动前的同名路由（只在改动前的工程里有意义，改动后由备份对照）。
## 正式事件链（模拟器 → 回放 → BattleVfx）由 tools/hero_skill_vfx_contract_check.gd 另行验证。
##
## 命令行（可选）：-- --case N  --low | --high  --close  --bg snow|jungle
##                    --capture-dir <目录>（逐用例截图后退出）  --interval <秒>  --tag <前缀>

const BUDGET := preload("res://effects/vfx3d/core/VFXQualityBudget.gd")
const ROUTE_PATH := "res://effects/BossProceduralVFX3D.gd"
const UNIT_ACTOR_PATH := "res://effects/runtime/presentation/UnitActor3D.gd"
const SOUL_BADGE_PATH := "res://scenes/battle/MotherSoulBadge.gd"
const BACKGROUNDS := {
	"snow": "res://assets/board/2_5d/battlefield_snow_pvp.png",
	"jungle": "res://assets/board/2_5d/battlefield_jungle_pve.png",
}
const UNITS := {
	"dark_dragon": {"name": "黑龙", "model": "res://assets/models/units/dark_refined/dark_dragon/dark_dragon_refined.tscn", "scale": 1.0, "tier": 3, "ranged": false},
	"undead_mother": {"name": "母灵", "model": "res://assets/models/units/undead_refined/undead_mother/undead_mother_refined.tscn", "scale": 1.0, "tier": 3, "ranged": true},
	"god_king": {"name": "神王", "model": "res://assets/models/units/god_king_refined/god_king_refined.tscn", "scale": 1.0, "tier": 3, "ranged": false},
	"crimson": {"name": "赤卫", "model": "res://assets/models/units/crimson_refined/crimson/crimson_refined.tscn", "scale": 1.09, "tier": 1, "ranged": false},
	"hunter": {"name": "血猎者", "model": "res://assets/models/units/crimson_refined/hunter/hunter_refined.tscn", "scale": 1.19, "tier": 2, "ranged": true},
	"armbreaker": {"name": "破甲者", "model": "res://assets/models/units/crimson_refined/armbreaker/armbreaker_refined.tscn", "scale": 1.14, "tier": 2, "ranged": false},
	"drumer": {"name": "战鼓使", "model": "res://assets/models/units/crimson_refined/drumer/drumer_refined.tscn", "scale": 1.19, "tier": 2, "ranged": false},
}
# 黑龙数据：吸附半径 220 模拟像素；与 BattleVfx._guardian_taunt_world_radius 同一映射。
const BLACK_HOLE_SIM_RADIUS := 220.0
const SIM_TO_WORLD := Vector2(14.5 * 0.88 / 1000.0, 10.0 * 0.88 / 520.0)
const CASES := [
	{"caster": "dark_dragon", "title": "黑龙 · 黑洞：头顶奇点 + 粒子漏斗，拉近 3 人并眩晕（第 4 人在圈外）", "foes": 4, "seconds": 4.6},
	{"caster": "undead_mother", "title": "母灵 · 击杀计数 1→5 → 翻书、光波收人", "foes": 3, "seconds": 6.6},
	{"caster": "undead_mother", "title": "母灵 · Boss 重击 / 无目标空翻书", "foes": 1, "seconds": 5.2},
	{"caster": "god_king", "title": "神王 · 神威：头顶能量团环绕 → 光弹落到每个目标 + 后续 4 次脉冲", "foes": 4, "seconds": 4.6},
]
const CASE_SECONDS := 4.2

var _viewport: SubViewport
var _world: Node3D
var _actors: Node3D
var _effects: Node3D
var _camera: Camera3D
var _background: TextureRect
var _route: Node3D
var _title: Label
var _detail: Label
var _status: Label
var _badge_layer: Control
var _badge: Control
var _case_index := 0
var _clock := 0.0
var _fired := {}
var _paused := false
var _old := false
var _bg := "snow"
var _tag := ""
var _capture_dir := ""
var _capture_interval := 0.0
var _captured := {}
var _caster: Node3D
var _foes: Array[Node3D] = []
var _pull_from: Array = []
var _pull_to: Array = []
var _pull_at := -1.0


func _ready() -> void:
	BUDGET.tier = 1
	_build_stage()
	_build_ui()
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		match args[i]:
			"--case":
				if i + 1 < args.size():
					_case_index = clampi(int(args[i + 1]), 0, CASES.size() - 1)
			"--old":
				_old = true
			"--low":
				BUDGET.tier = 0
			"--high":
				BUDGET.tier = 2
			"--close":
				_camera.size = 4.6
			"--bg":
				if i + 1 < args.size() and BACKGROUNDS.has(args[i + 1]):
					_bg = args[i + 1]
			"--tag":
				if i + 1 < args.size():
					_tag = args[i + 1]
			"--capture-dir":
				if i + 1 < args.size():
					_capture_dir = args[i + 1]
			"--interval":
				if i + 1 < args.size():
					_capture_interval = maxf(0.05, float(args[i + 1]))
	if not _capture_dir.is_empty():
		DirAccess.make_dir_recursive_absolute(_capture_dir)
	_apply_background()
	_route = (load(ROUTE_PATH) as Script).new() as Node3D
	_route.name = "HeroPreviewRoute"
	_effects.add_child(_route)
	_restart()
	print("HERO_PREVIEW_READY renderer=%s" % RenderingServer.get_current_rendering_method())


func _build_stage() -> void:
	var back := ColorRect.new()
	back.color = Color("131d1b")
	back.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(back)
	_background = TextureRect.new()
	_background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_background.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_background)
	var container := SubViewportContainer.new()
	container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	container.stretch = true
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(container)
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(960, 540)
	_viewport.transparent_bg = true
	_viewport.own_world_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	container.add_child(_viewport)
	_world = Node3D.new()
	_viewport.add_child(_world)
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.34, 0.42, 0.34)
	env.ambient_light_energy = 0.42
	env_node.environment = env
	_world.add_child(env_node)
	var light := DirectionalLight3D.new()
	light.light_color = Color(1.0, 0.84, 0.62)
	light.light_energy = 1.55
	light.rotation_degrees = Vector3(-55, 35, 0)
	_world.add_child(light)
	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = 7.6
	_world.add_child(_camera)
	_camera.look_at_from_position(Vector3(0, 7.4, 7), Vector3.ZERO, Vector3.UP)
	_camera.current = true
	_actors = Node3D.new()
	_world.add_child(_actors)
	_effects = Node3D.new()
	_world.add_child(_effects)
	# 母灵计数徽章是 2D HUD（与正式战斗相同：挂在单位 2D 根节点、血条上方）。
	_badge_layer = Control.new()
	_badge_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_badge_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_badge_layer)


func _apply_background() -> void:
	var path := str(BACKGROUNDS.get(_bg, ""))
	_background.texture = load(path) as Texture2D if ResourceLoader.exists(path) else null


func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(column)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 26)
	_title.add_theme_color_override("font_outline_color", Color.BLACK)
	_title.add_theme_constant_override("outline_size", 6)
	column.add_child(_title)
	_detail = Label.new()
	_detail.add_theme_font_size_override("font_size", 17)
	_detail.add_theme_color_override("font_outline_color", Color.BLACK)
	_detail.add_theme_constant_override("outline_size", 5)
	column.add_child(_detail)
	var space := Control.new()
	space.size_flags_vertical = Control.SIZE_EXPAND_FILL
	space.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(space)
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 19)
	_status.add_theme_color_override("font_outline_color", Color.BLACK)
	_status.add_theme_constant_override("outline_size", 5)
	column.add_child(_status)
	var bar := HFlowContainer.new()
	bar.add_theme_constant_override("h_separation", 10)
	bar.add_theme_constant_override("v_separation", 10)
	column.add_child(bar)
	_button(bar, "上一个", func(): _case_index = posmod(_case_index - 1, CASES.size()); _restart())
	_button(bar, "下一个", func(): _case_index = (_case_index + 1) % CASES.size(); _restart())
	_button(bar, "重播", func(): _restart())
	_button(bar, "暂停 / 继续", func():
		_paused = not _paused
		_world.process_mode = Node.PROCESS_MODE_DISABLED if _paused else Node.PROCESS_MODE_INHERIT)
	_button(bar, "战斗 / 近景", func(): _camera.size = 4.6 if _camera.size > 5.0 else 7.6)
	_button(bar, "低 / 中 / 高", func(): BUDGET.tier = (BUDGET.tier + 1) % 3; _restart())
	_button(bar, "雪地 / 丛林", func():
		_bg = "jungle" if _bg == "snow" else "snow"
		_apply_background())


func _button(parent: Node, text: String, action: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(112, 44)
	button.add_theme_font_size_override("font_size", 17)
	button.pressed.connect(action)
	parent.add_child(button)


# ── 单位 ─────────────────────────────────────────────────────────────────

func _spawn_unit(unit_id: String, at: Vector3, face: Vector3) -> Node3D:
	var info: Dictionary = UNITS.get(unit_id, UNITS["crimson"])
	var height := 0.98 * float(info["scale"]) * (1.2 if int(info["tier"]) == 3 else 1.0)
	var actor: Node3D
	if ResourceLoader.exists(UNIT_ACTOR_PATH):
		actor = (load(UNIT_ACTOR_PATH) as Script).new() as Node3D
		actor.call("configure_contract", height, "ranged" if bool(info["ranged"]) else "melee")
	else:
		actor = Node3D.new()
		for anchor in [["FootAnchor", 0.05], ["HitAnchor", 0.55], ["CastAnchor", 0.72 if bool(info["ranged"]) else 0.60], ["HeadAnchor", 1.02]]:
			var node := Node3D.new()
			node.name = anchor[0]
			node.position.y = height * float(anchor[1])
			actor.add_child(node)
	actor.name = unit_id
	actor.set_meta("unit_id", unit_id)
	actor.set_meta("height", height)
	_actors.add_child(actor)
	actor.global_position = at
	var path := str(info["model"])
	if ResourceLoader.exists(path):
		var model := (load(path) as PackedScene).instantiate() as Node3D
		model.scale = Vector3.ONE * float(info["scale"]) * 0.42 * (1.2 if int(info["tier"]) == 3 else 1.0)
		if actor.has_method("attach_model"):
			actor.call("attach_model", model)
		else:
			actor.add_child(model)
		var bounds := _bounds(model, Transform3D.IDENTITY)
		model.position -= Vector3(bounds.get_center().x, bounds.position.y, bounds.get_center().z)
		_play_anim(model, "idle", true)
	var flat := Vector3(face.x, 0.0, face.z)
	if flat.length_squared() > 0.0001:
		actor.rotation.y = atan2(flat.x, flat.z)
	return actor


func _play_anim(model: Node, anim: String, loop: bool) -> void:
	var player := _find_player(model)
	if player == null or not player.has_animation(anim):
		return
	player.get_animation(anim).loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE
	player.play(anim)
	if not loop:
		player.queue("idle")


func _find_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var found := _find_player(child)
		if found != null:
			return found
	return null


func _bounds(node: Node3D, parent: Transform3D) -> AABB:
	var xform := parent * node.transform
	var result := AABB()
	if node is MeshInstance3D:
		result = xform * (node as MeshInstance3D).get_aabb()
	for child in node.get_children():
		if child is Node3D:
			var child_bounds := _bounds(child, xform)
			if child_bounds.size != Vector3.ZERO:
				result = child_bounds if result.size == Vector3.ZERO else result.merge(child_bounds)
	return result


func _anchor(actor: Node3D, name: String) -> Vector3:
	var node := actor.get_node_or_null(name) as Node3D
	return node.global_position if node != null else actor.global_position


func _anchor_node(actor: Node3D, name: String) -> Node3D:
	var node := actor.get_node_or_null(name) as Node3D
	return node if node != null else actor


# ── 用例 ─────────────────────────────────────────────────────────────────

func _restart() -> void:
	for child in _actors.get_children():
		child.free()
	for child in _route.get_children():
		for effect in child.get_children():
			effect.queue_free()
	if _badge != null and is_instance_valid(_badge):
		_badge.free()
	_badge = null
	_foes.clear()
	_pull_from.clear()
	_pull_to.clear()
	_pull_at = -1.0
	_fired.clear()
	_captured.clear()
	_clock = 0.0
	_viewport.msaa_3d = Viewport.MSAA_2X if BUDGET.tier == 2 else Viewport.MSAA_DISABLED
	var spec: Dictionary = CASES[_case_index]
	var caster_id := str(spec["caster"])
	var origin := Vector3(-1.7, 0.0, 0.9)
	_caster = _spawn_unit(caster_id, origin, Vector3(1, 0, -0.7))
	var foe_ids := ["armbreaker", "crimson", "drumer", "hunter"]
	var layout: Array = []
	match caster_id:
		"dark_dragon":
			# 三人在 220 半径内（世界椭圆约 2.8 × 3.7），第四人放在圈外。
			layout = [Vector3(0.4, 0, 0.1), Vector3(-0.2, 0, -1.3), Vector3(0.9, 0, 1.6), Vector3(2.9, 0, -1.4)]
		"god_king":
			layout = [Vector3(0.6, 0, 0.2), Vector3(1.6, 0, -0.6), Vector3(0.3, 0, -1.4), Vector3(2.2, 0, 0.8)]
		_:
			layout = [Vector3(1.1, 0, -0.3), Vector3(2.0, 0, 0.4), Vector3(1.7, 0, -1.3)]
	for i in int(spec.get("foes", 1)):
		_foes.append(_spawn_unit(foe_ids[i % foe_ids.size()], layout[i % layout.size()], Vector3(-1, 0, 0.7)))
	if caster_id == "undead_mother" and ResourceLoader.exists(SOUL_BADGE_PATH):
		_badge = (load(SOUL_BADGE_PATH) as Script).new() as Control
		_badge_layer.add_child(_badge)
		_badge.call("set_counter", 0, 5)
	_title.text = "%s   /   %s" % [str(spec["title"]), "原版路由" if _old else "新版"]
	_detail.text = "%s画质 · 背景 %s · BossProceduralVFX3D 正式分发 · 只改表现，不改伤害/冷却/选人/随机数" % [["低", "中", "高"][BUDGET.tier], _bg]


func _process(delta: float) -> void:
	if _paused or _caster == null:
		return
	_clock += delta
	var spec: Dictionary = CASES[_case_index]
	_run_case(str(spec["caster"]))
	_update_pull()
	_place_badge()
	_status.text = "%.1fs  ·  用例 %d/%d" % [_clock, _case_index + 1, CASES.size()]
	var seconds := float(spec.get("seconds", CASE_SECONDS))
	if not _capture_dir.is_empty():
		var points: Array = []
		var t := 0.30
		var step := _capture_interval if _capture_interval > 0.0 else 0.35
		while t < seconds - 0.3:
			points.append(snappedf(t, 0.01))
			t += step
		for point in points:
			if _clock >= point and not _captured.has(point):
				_captured[point] = true
				_save_frame("%s%02d-%s-%.2fs.png" % [_tag, _case_index, str(spec["caster"]), point])
		if _clock >= seconds - 0.2:
			if _case_index + 1 < CASES.size() and not OS.get_cmdline_user_args().has("--case"):
				_case_index += 1
				_restart()
			else:
				get_tree().quit()
			return
	if _clock >= seconds:
		_restart()


func _once(key: String, at: float) -> bool:
	if _clock < at or _fired.has(key):
		return false
	_fired[key] = true
	return true


func _run_case(caster_id: String) -> void:
	match caster_id:
		"dark_dragon":
			if _once("cast", 0.45):
				_cast_black_hole()
		"undead_mother":
			if CASES[_case_index]["foes"] > 1:
				# 每 0.55 秒「队友击杀」一次 → 计数 1..4；第 5 次击杀时计数归零并翻书处决。
				for k in 4:
					if _once("kill%d" % k, 0.45 + 0.55 * float(k)):
						_set_count(k + 1, 5)
				if _once("trigger", 2.75):
					_set_count(0, 5)
					_book(_foes[0], false)
				if _once("victim_gone", 3.55) and _foes.size() > 0:
					_foes[0].visible = false
			else:
				if _once("boss", 0.5):
					_set_count(0, 5)
					_book(_foes[0], true)
				if _once("empty", 2.9):
					_book(null, false)
		"god_king":
			if _once("cast", 0.45):
				_cast_divine()
			for k in range(1, 5):
				if not _old and _once("pulse%d" % k, 0.45 + 0.5 * float(k)):
					for foe in _foes:
						_dispatch("global_divine_blast_pulse", _anchor(_caster, "CastAnchor"), _anchor(foe, "HitAnchor"), _context(_caster, foe, {"pulse_index": k}))


func _set_count(count: int, threshold: int) -> void:
	if _badge != null and is_instance_valid(_badge):
		_badge.call("set_counter", count, threshold)


func _cast_black_hole() -> void:
	var model := _caster.get_node_or_null("ActorRoot")
	_play_anim(model if model != null else _caster, "attack", false)
	var center := _anchor(_caster, "FootAnchor")
	var radius := BLACK_HOLE_SIM_RADIUS * SIM_TO_WORLD
	var targets: Array = []
	var from_positions: Array = []
	var nodes: Array = []
	for foe in _foes:
		var foot := _anchor(foe, "FootAnchor")
		var rel := Vector2((foot.x - center.x) / radius.x, (foot.z - center.z) / radius.y)
		if rel.length() > 1.0:
			continue
		# 与模拟器一致：位置向施法者插值 45%。
		var to := foe.global_position.lerp(_caster.global_position, 0.45)
		_pull_from.append([foe, foe.global_position])
		_pull_to.append(to)
		from_positions.append(foot)
		targets.append(Vector3(to.x, foot.y, to.z))
		nodes.append(_anchor_node(foe, "FootAnchor"))
	_pull_at = _clock
	_dispatch("black_hole", _anchor(_caster, "CastAnchor"), center, _context(_caster, null, {
		"origin_foot": center,
		"world_radius": radius,
		"targets": targets,
		"from_positions": from_positions,
		"target_nodes": nodes,
		"stun_duration": 1.0,
	}))


func _update_pull() -> void:
	if _pull_at < 0.0:
		return
	# 战斗里模型是平滑追上新位置的；这里用 0.18 秒补间模拟。
	var x := clampf((_clock - _pull_at) / 0.18, 0.0, 1.0)
	for i in _pull_from.size():
		var foe: Node3D = _pull_from[i][0]
		var from: Vector3 = _pull_from[i][1]
		foe.global_position = from.lerp(_pull_to[i], 1.0 - pow(1.0 - x, 2.0))


func _book(victim: Node3D, heavy: bool) -> void:
	var head := _anchor(_caster, "HeadAnchor")
	var extra := {"heavy": heavy, "has_victim": victim != null}
	var target_at := _anchor(victim, "FootAnchor") if victim != null else _anchor(_caster, "FootAnchor")
	_dispatch("unique_death_execute", head, target_at, _context(_caster, victim, extra))


func _cast_divine() -> void:
	var model := _caster.get_node_or_null("ActorRoot")
	_play_anim(model if model != null else _caster, "attack", false)
	_dispatch("global_divine_blast", _anchor(_caster, "CastAnchor"), _anchor(_foes[0], "HitAnchor"), _context(_caster, _foes[0], {
		"targets": _feet(_foes),
		"target_nodes": _hit_nodes(_foes),
	}))


func _feet(actors: Array[Node3D]) -> Array:
	var out: Array = []
	for actor in actors:
		out.append(_anchor(actor, "FootAnchor"))
	return out


func _hit_nodes(actors: Array[Node3D]) -> Array:
	var out: Array = []
	for actor in actors:
		out.append(_anchor_node(actor, "HitAnchor"))
	return out


func _context(source: Node3D, target: Node3D, extra: Dictionary = {}) -> Dictionary:
	var context := extra.duplicate(false)
	context["source_unit_id"] = str(source.get_meta("unit_id", ""))
	context["origin_node"] = _anchor_node(source, "CastAnchor")
	context["origin_height"] = float(source.get_meta("height", 0.98))
	context["origin_foot"] = context.get("origin_foot", _anchor(source, "FootAnchor"))
	context["origin_head_node"] = _anchor_node(source, "HeadAnchor")
	if target != null:
		context["target_unit_id"] = str(target.get_meta("unit_id", ""))
		context["target_node"] = _anchor_node(target, "HitAnchor")
		context["target_height"] = float(target.get_meta("height", 0.98))
		context["target_foot"] = _anchor(target, "FootAnchor")
	return context


func _dispatch(effect_id: String, origin: Vector3, target: Vector3, context: Dictionary) -> void:
	_route.call("play", effect_id, origin, target, context)


func _place_badge() -> void:
	if _badge == null or not is_instance_valid(_badge) or _caster == null:
		return
	var head := _anchor(_caster, "HeadAnchor")
	var screen := _camera.unproject_position(head) * (size / Vector2(_viewport.size))
	# 正式战斗里徽章挂在单位 2D 根节点（血条在 y=8）。这里把血条大致放在头顶上方。
	_badge.position = screen + Vector2(-36, -34) + Vector2(5, -14)


func _save_frame(filename: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_capture_dir.path_join(filename))
