extends Control
## 赤律族特效循环预览（离线美术验收用）。
##
## 打开 res://effects/preview/CrimsonVFXPreview.tscn 后按 F6 运行。每个用例都走
## 正式分发器 BossProceduralVFX3D.play(effect_id, ...)，与战斗中 BattleVfx 的落点相同；
## 「原版」只回放改动前赤律族真实会命中的那条路（人族蓝色通用普攻，技能无表现）。
## 正式事件链（模拟器 → 回放 → Director → BattleVfx）由
## tools/crimson_vfx_contract_check.gd 与正式战斗截帧另行验证。
##
## 命令行（可选）：-- --case N  --old  --low | --high  --close  --bg snow|jungle
##                    --capture-dir <目录>（逐用例截图后退出）  --all（施法者站位后撤，便于看大范围技能）

const BUDGET := preload("res://effects/vfx3d/core/VFXQualityBudget.gd")
const ROUTE_PATH := "res://effects/BossProceduralVFX3D.gd"
const UNIT_ACTOR_PATH := "res://effects/runtime/presentation/UnitActor3D.gd"
const MODEL_ROOT := "res://assets/models/units/crimson_refined/%s/%s_refined.tscn"
const BACKGROUNDS := {
	"snow": "res://assets/board/2_5d/battlefield_snow_pvp.png",
	"jungle": "res://assets/board/2_5d/battlefield_jungle_pve.png",
}
# 与 race_units.json 一致：model_visual_scale、tier（T3 额外 ×1.2）、射程档。
const UNITS := {
	"crimson": {"name": "赤卫", "scale": 1.09, "tier": 1, "ranged": false},
	"dancer": {"name": "赤舞者", "scale": 1.17, "tier": 1, "ranged": true},
	"drumer": {"name": "战鼓使", "scale": 1.19, "tier": 2, "ranged": false},
	"hunter": {"name": "血猎者", "scale": 1.19, "tier": 2, "ranged": true},
	"armbreaker": {"name": "破甲者", "scale": 1.14, "tier": 2, "ranged": false},
	"Icey": {"name": "霜印使", "scale": 1.21, "tier": 2, "ranged": true},
	"skypierce": {"name": "穿云弩手", "scale": 1.20, "tier": 3, "ranged": true},
	"lattern": {"name": "赤灯使", "scale": 1.18, "tier": 3, "ranged": true},
}
const CASES := [
	{"caster": "dancer", "title": "赤舞者 · 绯刃普攻 + 手上红光、被增益者挂音符（3 秒）", "allies": 2, "foes": 1, "seconds": 5.2},
	{"caster": "hunter", "title": "血猎者 · 血猎箭 + 当前生命伤害 / 四星斩杀", "allies": 0, "foes": 1},
	{"caster": "Icey", "title": "霜印使 · 霜晶普攻 + 手上蓝光、命中短暂结冰（第 3 人不在范围）", "allies": 0, "foes": 3},
	{"caster": "skypierce", "title": "穿云弩手 · 掷出标枪 + 直线贯穿 3 人", "allies": 0, "foes": 4, "line": true},
	{"caster": "lattern", "title": "赤灯使 · 灯烬普攻 + 红光扩散、照到即沉默（第 3 人免控）", "allies": 0, "foes": 3},
	{"caster": "crimson", "title": "赤卫 · 格挡（近战 / 远程来袭）", "allies": 0, "foes": 2, "defender": true},
	{"caster": "drumer", "title": "战鼓使 · 出手时身上扩散红色音波（层数见头顶音符徽章）", "allies": 3, "foes": 1},
	{"caster": "armbreaker", "title": "破甲者 · 重锤普攻 + 破甲（层数递增）", "allies": 0, "foes": 1},
]
const CASE_SECONDS := 4.2

var _viewport: SubViewport
var _world: Node3D
var _actors: Node3D
var _effects: Node3D
var _camera: Camera3D
var _background: TextureRect
var _route: Node3D
var _route_mode := "formal"
var _title: Label
var _detail: Label
var _status: Label
var _case_index := 0
var _clock := 0.0
var _fired := {}
var _paused := false
var _old := false
var _all := false
var _bg := "snow"
var _capture_dir := ""
var _capture_interval := 0.0
var _captured := {}
var _units: Dictionary = {}
var _caster: Node3D
var _allies: Array[Node3D] = []
var _foes: Array[Node3D] = []


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
				_camera.size = 4.1
			"--all":
				_all = true
			"--bg":
				if i + 1 < args.size() and BACKGROUNDS.has(args[i + 1]):
					_bg = args[i + 1]
			"--capture-dir":
				if i + 1 < args.size():
					_capture_dir = args[i + 1]
			"--interval":
				if i + 1 < args.size():
					_capture_interval = maxf(0.05, float(args[i + 1]))
	if not _capture_dir.is_empty():
		DirAccess.make_dir_recursive_absolute(_capture_dir)
	_apply_background()
	_build_route()
	_restart()
	print("CRIMSON_PREVIEW_READY renderer=%s route=%s" % [RenderingServer.get_current_rendering_method(), _route_mode])


# ── 舞台：与 BattleArena 相同的透明 3D 视口叠在 2D 战场背景上 ────────────

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
	_camera.size = 7.2
	_world.add_child(_camera)
	_camera.look_at_from_position(Vector3(0, 7.4, 7), Vector3.ZERO, Vector3.UP)
	_camera.current = true
	_actors = Node3D.new()
	_world.add_child(_actors)
	_effects = Node3D.new()
	_world.add_child(_effects)


func _apply_background() -> void:
	var path := str(BACKGROUNDS.get(_bg, ""))
	_background.texture = load(path) as Texture2D if ResourceLoader.exists(path) else null


func _build_route() -> void:
	if ResourceLoader.exists(ROUTE_PATH):
		var script := load(ROUTE_PATH) as Script
		if script != null and script.can_instantiate():
			_route = script.new() as Node3D
	if _route == null:
		# 精简实验工程里没有正式分发器时，直接调用模块（标题会注明）。
		_route_mode = "direct"
		_route = Node3D.new()
	_route.name = "CrimsonPreviewRoute"
	_effects.add_child(_route)


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
	_button(bar, "新版 / 原版", func(): _old = not _old; _restart())
	_button(bar, "重播", func(): _restart())
	_button(bar, "暂停 / 继续", func():
		_paused = not _paused
		_world.process_mode = Node.PROCESS_MODE_DISABLED if _paused else Node.PROCESS_MODE_INHERIT)
	_button(bar, "战斗 / 近景", func(): _camera.size = 4.1 if _camera.size > 5.0 else 7.2)
	_button(bar, "低 / 中 / 高", func(): BUDGET.tier = (BUDGET.tier + 1) % 3; _restart())
	_button(bar, "雪地 / 丛林", func():
		_bg = "jungle" if _bg == "snow" else "snow"
		_apply_background())
	_button(bar, "单例 / 同屏", func(): _all = not _all; _restart())


func _button(parent: Node, text: String, action: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(112, 44)
	button.add_theme_font_size_override("font_size", 17)
	button.pressed.connect(action)
	parent.add_child(button)


# ── 单位 ─────────────────────────────────────────────────────────────────

func _spawn_unit(unit_id: String, at: Vector3, face: Vector3, player_side: bool) -> Node3D:
	var info: Dictionary = UNITS.get(unit_id, UNITS["crimson"])
	var height := 0.98 * float(info["scale"]) * (1.2 if int(info["tier"]) == 3 else 1.0)
	var actor: Node3D
	if ResourceLoader.exists(UNIT_ACTOR_PATH):
		actor = (load(UNIT_ACTOR_PATH) as Script).new() as Node3D
		actor.call("configure_contract", height, "ranged" if bool(info["ranged"]) else "melee")
	else:
		actor = Node3D.new()
		actor.set_meta("model_height", height)
		for anchor in [["FootAnchor", 0.05], ["HitAnchor", 0.55], ["CastAnchor", 0.72 if bool(info["ranged"]) else 0.60], ["HeadAnchor", 1.02]]:
			var node := Node3D.new()
			node.name = anchor[0]
			node.position.y = height * float(anchor[1])
			actor.add_child(node)
	actor.name = "%s_%s" % [unit_id, "p" if player_side else "e"]
	actor.set_meta("unit_id", unit_id)
	actor.set_meta("height", height)
	_actors.add_child(actor)
	actor.global_position = at
	var path := MODEL_ROOT % [unit_id, unit_id]
	if ResourceLoader.exists(path):
		var model := (load(path) as PackedScene).instantiate() as Node3D
		var visual := float(info["scale"]) * 0.42 * (1.2 if int(info["tier"]) == 3 else 1.0)
		model.scale = Vector3.ONE * visual
		if actor.has_method("attach_model"):
			actor.call("attach_model", model)
		else:
			actor.add_child(model)
		var bounds := _bounds(model, Transform3D.IDENTITY)
		# 与 BattleRenderer._center_model_for_full_body_view 同口径：脚底落在 FootAnchor 平面、水平居中。
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
	var animation := player.get_animation(anim)
	animation.loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE
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
	# 正式分发器的子节点是两个 composer（要保留），效果块挂在 composer 下面；
	# 直连模式下效果块直接挂在 _route 下。
	for child in _route.get_children():
		if _route_mode == "formal":
			for effect in child.get_children():
				effect.queue_free()
		else:
			child.queue_free()
	_allies.clear()
	_foes.clear()
	_fired.clear()
	_captured.clear()
	_clock = 0.0
	_viewport.msaa_3d = Viewport.MSAA_2X if BUDGET.tier == 2 else Viewport.MSAA_DISABLED
	var spec: Dictionary = CASES[_case_index]
	var origin := Vector3(-1.9, 0.0, 1.1)
	if _all:
		origin = Vector3(-2.6, 0.0, 1.5)
	_caster = _spawn_unit(str(spec["caster"]), origin, Vector3(1, 0, -0.7), true)
	for i in int(spec.get("allies", 0)):
		var ally_at := origin + Vector3(-0.9 + float(i) * 0.95, 0.0, 1.0 - float(i % 2) * 0.35)
		_allies.append(_spawn_unit(["crimson", "hunter", "armbreaker"][i % 3], ally_at, Vector3(1, 0, -0.7), true))
	var foe_ids := ["armbreaker", "crimson", "drumer", "hunter"]
	for i in int(spec.get("foes", 1)):
		var foe_at: Vector3
		if bool(spec.get("line", false)):
			foe_at = Vector3(0.3, 0.0, -0.05) + Vector3(1.0, 0.0, -0.62) * float(i) * 0.92
		elif str(spec["caster"]) == "Icey":
			foe_at = Vector3(1.3, 0.0, -0.5) + [Vector3.ZERO, Vector3(0.62, 0, 0.32), Vector3(-0.5, 0, -0.42)][i]
		else:
			foe_at = Vector3(1.2 + float(i) * 0.85, 0.0, -0.45 - float(i % 2) * 0.55)
		_foes.append(_spawn_unit(foe_ids[i % foe_ids.size()], foe_at, Vector3(-1, 0, 0.7), false))
	_title.text = "%s   /   %s" % [str(spec["title"]), "原版（改动前路由）" if _old else "新版"]
	_detail.text = "%s画质 · 背景 %s · 路由 %s · 只改表现，不改伤害/冷却/选人/随机数" % [["低", "中", "高"][BUDGET.tier], _bg, "BossProceduralVFX3D 正式分发" if _route_mode == "formal" else "模块直连（实验工程）"]


func _process(delta: float) -> void:
	if _paused or _caster == null:
		return
	_clock += delta
	var spec: Dictionary = CASES[_case_index]
	_run_case(str(spec["caster"]))
	_status.text = "%.1fs  ·  用例 %d/%d" % [_clock, _case_index + 1, CASES.size()]
	if not _capture_dir.is_empty():
		var points: Array = [0.55, 0.95, 1.55, 2.05, 2.55, 3.15]
		if _capture_interval > 0.0:
			points.clear()
			var t := 0.30
			while t < float(spec.get("seconds", CASE_SECONDS)) - 0.3:
				points.append(snappedf(t, 0.01))
				t += _capture_interval
		for point in points:
			if _clock >= point and not _captured.has(point):
				_captured[point] = true
				_save_frame("%s%02d-%s-%.2fs.png" % ["old-" if _old else "", _case_index, str(spec["caster"]), point])
		if _clock >= float(spec.get("seconds", CASE_SECONDS)) - 0.2:
			if _case_index + 1 < CASES.size() and not OS.get_cmdline_user_args().has("--case"):
				_case_index += 1
				_restart()
			else:
				get_tree().quit()
			return
	if _clock >= float(spec.get("seconds", CASE_SECONDS)):
		_restart()


func _once(key: String, at: float) -> bool:
	if _clock < at or _fired.has(key):
		return false
	_fired[key] = true
	return true


func _run_case(caster_id: String) -> void:
	var foe: Node3D = _foes[0] if not _foes.is_empty() else null
	match caster_id:
		"dancer":
			if _once("a1", 0.30): _basic(_caster, foe, true)
			if _once("s1", 1.10): _skill("random_ally_buff", _caster, null, {"targets": _feet(_allies), "target_nodes": _allies.duplicate(), "duration": 3.0})
			if _once("a2", 2.60): _basic(_caster, foe, true)
		"hunter":
			if _once("a1", 0.30): _basic(_caster, foe, true)
			if _once("p1", 0.30): _skill("current_hp_strike", _caster, foe, {"delay": 0.12 + _flight(_caster, foe)})
			if _once("a2", 1.80): _basic(_caster, foe, true)
			if _once("p2", 1.80): _skill("current_hp_strike", _caster, foe, {"delay": 0.12 + _flight(_caster, foe), "execute": true})
		"Icey":
			if _once("a1", 0.30): _basic(_caster, foe, true)
			if _once("s1", 1.30): _skill("frost_status", _caster, foe, {"world_radius": Vector2(144.0 * 14.5 * 0.88 / 1000.0, 144.0 * 10.0 * 0.88 / 520.0), "targets": _feet(_foes).slice(0, 2)})
		"skypierce":
			if _once("a1", 0.30): _basic(_caster, foe, true)
			if _once("p1", 0.30):
				var hits: Array = []
				for i in range(1, _foes.size()):
					hits.append(_anchor(_foes[i], "HitAnchor"))
				_skill("line_pierce", foe, _foes[1] if _foes.size() > 1 else foe, {"delay": 0.12 + _flight(_caster, foe), "targets": hits})
			if _once("a2", 1.90): _basic(_caster, foe, true)
		"lattern":
			if _once("a1", 0.30): _basic(_caster, foe, true)
			if _once("s1", 1.20): _skill("aoe_silence", _caster, foe, {"targets": _feet(_foes), "sealed": [true, true, false]})
		"crimson":
			if _foes.size() > 1:
				if _once("melee_hit", 0.40):
					_basic(_foes[0], _caster, false)
					_skill("block_guard", _caster, _foes[0], {"delay": 0.12})
				if _once("ranged_hit", 1.70):
					_basic(_foes[1], _caster, true)
					_skill("block_guard", _caster, _foes[1], {"delay": 0.12 + _flight(_foes[1], _caster)})
		"drumer":
			if _once("a1", 0.30): _basic(_caster, foe, false)
			if _once("a2", 1.40): _basic(_caster, foe, false)
			if _once("a3", 2.50): _basic(_caster, foe, false)
		"armbreaker":
			for k in 3:
				if _once("a%d" % k, 0.30 + float(k) * 1.1):
					_basic(_caster, foe, false)
					_skill("stacking_def_break", _caster, foe, {"delay": 0.12, "stacks": 2 * (k + 1) * (2 if k == 2 else 1)})


func _feet(actors: Array[Node3D]) -> Array:
	var out: Array = []
	for actor in actors:
		out.append(_anchor(actor, "FootAnchor"))
	return out


func _flight(from_actor: Node3D, to_actor: Node3D) -> float:
	var catalog := load("res://effects/vfx3d/units/CrimsonVFXCatalog.gd")
	var a := _anchor(from_actor, "CastAnchor")
	var b := _anchor(to_actor, "HitAnchor")
	return float(catalog.flight_time(Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z)), str(from_actor.get_meta("unit_id", ""))))


func _context(source: Node3D, target: Node3D, extra: Dictionary = {}) -> Dictionary:
	var context := extra.duplicate(false)
	context["source_unit_id"] = str(source.get_meta("unit_id", ""))
	context["origin_node"] = _anchor_node(source, "CastAnchor")
	context["origin_height"] = float(source.get_meta("height", 0.98))
	context["origin_foot"] = _anchor(source, "FootAnchor")
	if target != null:
		context["target_unit_id"] = str(target.get_meta("unit_id", ""))
		context["target_node"] = _anchor_node(target, "HitAnchor")
		context["target_height"] = float(target.get_meta("height", 0.98))
		context["target_foot"] = _anchor(target, "FootAnchor")
	return context


func _basic(source: Node3D, target: Node3D, ranged: bool) -> void:
	if source == null or target == null:
		return
	var model := source.get_node_or_null("ActorRoot")
	_play_anim(model if model != null else source, "attack", false)
	var race := "human" if _old else "crimson"
	var effect := "basic_attack_%s_%s" % ["ranged" if ranged else "melee", race]
	var context := _context(source, target)
	context["mode"] = "ranged" if ranged else "melee"
	_dispatch(effect, _anchor(source, "CastAnchor"), _anchor(target, "HitAnchor"), context)


func _skill(skill_id: String, source: Node3D, target: Node3D, extra: Dictionary) -> void:
	if _old:
		return  # 改动前：赤律族技能与被动在正式路由里没有任何表现。
	var target_point := _anchor(target, "HitAnchor") if target != null else _anchor(source, "HitAnchor")
	_dispatch(skill_id, _anchor(source, "CastAnchor"), target_point, _context(source, target, extra))


func _dispatch(effect_id: String, origin: Vector3, target: Vector3, context: Dictionary) -> void:
	if _route_mode == "formal":
		_route.call("play", effect_id, origin, target, context)
		return
	var script: Script
	if effect_id.begins_with("basic_attack_"):
		if effect_id.ends_with("_human"):
			return
		script = load("res://effects/vfx3d/units/VFXCrimsonAttack3D.gd")
		var attack := VFXBlockRoot.spawn_block(script, _route, true)
		if attack != null:
			attack.call("play_attack", origin, target, context)
		return
	script = load("res://effects/vfx3d/units/VFXCrimsonSkill3D.gd")
	var skill := VFXBlockRoot.spawn_block(script, _route, true)
	if skill != null:
		skill.call("play_crimson_skill", effect_id, origin, target, context)


func _save_frame(filename: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_capture_dir.path_join(filename))
