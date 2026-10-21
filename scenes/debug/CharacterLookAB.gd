extends Control
## 角色外观 A/B 试验场景。只是试验，生产代码不引用这里的任何东西；
## 删掉本文件、shaders/experimental/ 和 assets/experimental/art_ab 即回退。
##
## 左 A 永远是生产现状：现有材质 + 现有脚底圆形影（UnitContactShadow）。
## 右 B 是候选，两组变量：
##   侧光（只对民兵）：B 换 character_toon_b，多一组背光侧冷光。暗族自带的
##       race_body 已经有不依赖灯的种族色边缘光，所以暗族两侧材质相同。
##   影子：circle 现状圆 / ellipse 方向椭圆 / planar 投影剪影 / realtime 引擎实时阴影。
##
## 和战斗保持一致的部分：960x540 透明 SubViewport 叠在真实 2D 战场图上、
## BattleUI 的正交相机（位置 / size）、单位缩放 0.42、低中档无 MSAA / 高档 2x。
##
## A、B 两边各一套灯，用 VisualInstance 层 + light_cull_mask 隔开：
## 实时阴影只开在 B 那盏灯上，A 不投影也不受影，左右仍是公平对照。
##
## 命令行（-- 之后）：
##   --capture-dir <绝对路径> [--suite side|shadow]   按固定矩阵截图后退出（需要图形窗口）
##   --perf a|b   单边性能：只摆 A 或只摆 B，跑完写 JSON 后退出
##   --unit militia|dark_suc|dark_dragon  --shadow circle|ellipse|planar|realtime
##   --count 1|6|12  --seconds N  --warmup N  --side off|procedural|matcap  --out <绝对路径>
## Android：把同样字段写进 user://art_ab_request.json（{"perf":"b","count":12,...}），
## 启动本场景后结果写到 user://art_ab_perf.json。

const UNITS := {
	"militia": {"title": "民兵", "path": "res://assets/models/units/human_refined/human_militia/human_militia_refined.tscn", "scale": 1.0},
	"dark_suc": {"title": "魅魔", "path": "res://assets/models/units/dark_refined/dark_suc/dark_suc_refined.tscn", "scale": 1.0},
	"dark_dragon": {"title": "暗龙", "path": "res://assets/models/units/dark_refined/dark_dragon/dark_dragon_refined.tscn", "scale": 1.0},
}
const BODY_A := preload("res://assets/models/units/human_refined/human_militia/body.tres")
const BODY_B := preload("res://assets/experimental/art_ab/militia_body_b.tres")
const OUTLINE_SHADER := preload("res://shaders/character_outline.gdshader")
const PLANAR_SHADOW_SHADER := preload("res://shaders/experimental/planar_shadow.gdshader")
const ELLIPSE_SHADOW_SHADER := preload("res://shaders/experimental/contact_shadow_directional.gdshader")
const UnitContactShadowScript := preload("res://effects/runtime/presentation/UnitContactShadow.gd")
# 人族单位描边墨色 / 宽度，取自 human_archer 等现有材质。民兵精修版当前没有描边，
# 这里只为对照「加上会怎样」，不代表要改生产材质。
const HUMAN_OUTLINE_COLOR := Color(0.012, 0.01, 0.014, 1)
const HUMAN_OUTLINE_WIDTH := 0.032
const HUMAN_OUTLINE_MAX_PX := 1.25

const BACKGROUNDS := {
	"jungle": "res://assets/board/2_5d/battlefield_jungle_pve.png",
	"snow": "res://assets/board/2_5d/battlefield_snow_pvp.png",
	"final": "res://assets/board/2_5d/battlefield_final_round.png",
}
# 与 scenes/battle/BattleUI.gd 保持一致。
const BATTLE_CAMERA_SIZE := 7.2
const BATTLE_CAMERA_POS := Vector3(0.0, 7.4, 7.0)
const UNIT_SCALE := 0.42
const CLOSE_CAMERA_SIZE := 2.0
const FREEZE_TIME := 0.8
const SIDE_MODES := ["off", "procedural", "matcap"]
const SHADOW_MODES := ["circle", "ellipse", "planar", "realtime"]
const SHADOW_TITLES := {"circle": "现状圆", "ellipse": "方向椭圆", "planar": "投影剪影", "realtime": "实时阴影"}
# 影子方向（ellipse / planar）：
#   follow   跟主光走。战斗主光从镜头这一侧照过去，影子落在角色身后，大半被身体挡住。
#   readable 单独给一个方向，影子斜落向镜头右下方，看得见；和身上明暗不严格一致，
#            自走棋类游戏常见的取舍。实时阴影没法分开，永远跟灯。
const SHADOW_DIRECTIONS := ["readable", "follow"]
const READABLE_SHADOW_TRAVEL := Vector3(0.42, -0.78, 0.46)
# 战斗里 GroundShadow3D 的尺寸（BattleRenderer：0.62 * footprint_scale）。
const CIRCLE_FOOTPRINT := 0.62
const LAYER_B := 1
const LAYER_A := 2

var _background_rect: TextureRect
var _viewport: SubViewport
var _world: Node3D
var _actors: Node3D
var _camera: Camera3D
var _environment: Environment
# [key, fill]，A、B 各一套，参数相同，只靠 cull mask 分别照两边。
var _lights_a: Array[DirectionalLight3D] = []
var _lights_b: Array[DirectionalLight3D] = []
var _shadow_catcher: MeshInstance3D
var _occluder: MeshInstance3D
var _status: Label
var _heads: Array[Label] = []
var _strength_label: Label
var _material_a: ShaderMaterial
var _material_b: ShaderMaterial
var _planar_material: ShaderMaterial
var _ellipse_material: ShaderMaterial
var _chained: Dictionary = {}
var _models: Array[Node3D] = []

var _unit := "militia"
var _shadow := "circle"
var _shadow_dir := "readable"
var _rig := "battle"          # battle | prep | backlight
var _background := "jungle"
var _close := true
var _side_mode := "procedural"
var _side_strength := 0.35
var _outline := false
var _occlusion := false
var _high_quality := false
var _frozen := true
var _layout := "compare"      # compare | a | b
var _count := 1
var _facing_front := false

var _perf_variant := ""
var _perf_seconds := 20.0
var _perf_warmup := 3.0
var _perf_out := ""
var _perf_clock := 0.0
var _perf_samples: Array[float] = []
var _perf_peak_draws := 0
var _capture_dir := ""
var _suite := "shadow"


func _ready() -> void:
	var problem := _parse_options()
	if not problem.is_empty():
		push_error("ART_AB_ERROR " + problem)
		get_tree().quit(2)
		return
	_material_a = BODY_A.duplicate() as ShaderMaterial
	_material_b = BODY_B.duplicate() as ShaderMaterial
	_planar_material = ShaderMaterial.new()
	_planar_material.shader = PLANAR_SHADOW_SHADER
	_planar_material.render_priority = -2
	_ellipse_material = ShaderMaterial.new()
	_ellipse_material.shader = ELLIPSE_SHADOW_SHADER
	_build_stage()
	if _perf_variant.is_empty() and _capture_dir.is_empty():
		_build_ui()
	_rebuild_models()
	_apply_all()
	print("ART_AB_READY renderer=%s os=%s unit=%s shadow=%s layout=%s count=%d side=%s" % [
		RenderingServer.get_current_rendering_method(), OS.get_name(), _unit, _shadow, _layout, _count, _side_mode])
	if not _capture_dir.is_empty():
		_run_captures.call_deferred()


func _parse_options() -> String:
	var options: Dictionary = {}
	if FileAccess.file_exists("user://art_ab_request.json"):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("user://art_ab_request.json"))
		DirAccess.remove_absolute("user://art_ab_request.json")
		if not parsed is Dictionary:
			return "request must be a JSON object"
		options = parsed
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		var key := args[i]
		if key.begins_with("--") and i + 1 < args.size() and not args[i + 1].begins_with("--"):
			options[key.substr(2).replace("-", "_")] = args[i + 1]
	_capture_dir = str(options.get("capture_dir", ""))
	_suite = str(options.get("suite", "shadow"))
	_perf_variant = str(options.get("perf", ""))
	_unit = str(options.get("unit", _unit))
	_shadow = str(options.get("shadow", _shadow))
	_shadow_dir = str(options.get("shadow_dir", _shadow_dir))
	_count = int(options.get("count", 1))
	_perf_seconds = float(options.get("seconds", 20.0))
	_perf_warmup = float(options.get("warmup", 3.0))
	_side_mode = str(options.get("side", _side_mode))
	_perf_out = str(options.get("out", "user://art_ab_perf.json"))
	_high_quality = str(options.get("quality", "medium")) == "high"
	if _perf_variant not in ["", "a", "b"]:
		return "--perf must be a or b"
	if not UNITS.has(_unit):
		return "--unit must be one of " + ", ".join(PackedStringArray(UNITS.keys()))
	if _shadow not in SHADOW_MODES:
		return "--shadow must be circle, ellipse, planar or realtime"
	if _shadow_dir not in SHADOW_DIRECTIONS:
		return "--shadow-dir must be readable or follow"
	if _suite not in ["side", "shadow"]:
		return "--suite must be side or shadow"
	if _count not in [1, 6, 12]:
		return "--count must be 1, 6 or 12"
	if _side_mode not in SIDE_MODES:
		return "--side must be off, procedural or matcap"
	if not _perf_variant.is_empty():
		_layout = _perf_variant
		_close = false
		_frozen = false
		print("ART_AB_PERF_START variant=%s unit=%s shadow=%s count=%d seconds=%.1f warmup=%.1f" % [
			_perf_variant, _unit, _shadow, _count, _perf_seconds, _perf_warmup])
	if not _capture_dir.is_empty():
		if DisplayServer.get_name() == "headless":
			return "captures need a graphics display"
		if DirAccess.make_dir_recursive_absolute(_capture_dir) != OK:
			return "cannot create capture dir"
	return ""


func _build_stage() -> void:
	_background_rect = TextureRect.new()
	_background_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_background_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_background_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_background_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_background_rect)

	var container := SubViewportContainer.new()
	container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	container.stretch = true
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(container)
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.size = Vector2i(960, 540)
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	container.add_child(_viewport)

	_world = Node3D.new()
	_viewport.add_child(_world)
	_environment = Environment.new()
	_environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	var environment_node := WorldEnvironment.new()
	environment_node.environment = _environment
	_world.add_child(environment_node)
	for entry in [[_lights_a, LAYER_A], [_lights_b, LAYER_B]]:
		for i in 2:
			var light := DirectionalLight3D.new()
			light.shadow_enabled = false
			light.light_cull_mask = 1 << (int(entry[1]) - 1)
			light.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
			light.directional_shadow_max_distance = 14.0
			_world.add_child(light)
			(entry[0] as Array).append(light)

	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.current = true
	_viewport.add_child(_camera)

	_actors = Node3D.new()
	_world.add_child(_actors)

	# 实时阴影的接收面：只铺在 B 半边，shadow_to_opacity 让受光处透明、影子处显暗，
	# 底下的 2D 战场图照常透出来。只在 realtime 档显示。
	_shadow_catcher = MeshInstance3D.new()
	var catcher_plane := PlaneMesh.new()
	catcher_plane.size = Vector2(12.0, 12.0)
	_shadow_catcher.mesh = catcher_plane
	_shadow_catcher.position = Vector3(6.0, 0.002, 0.0)
	_shadow_catcher.layers = 1 << (LAYER_B - 1)
	_shadow_catcher.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var catcher_shader := Shader.new()
	catcher_shader.code = """shader_type spatial;
render_mode shadow_to_opacity, blend_mix, depth_draw_never, cull_back, ambient_light_disabled;
uniform vec3 shadow_color : source_color = vec3(0.03, 0.03, 0.06);
void fragment() { ALBEDO = shadow_color; }
"""
	var catcher_material := ShaderMaterial.new()
	catcher_material.shader = catcher_shader
	_shadow_catcher.material_override = catcher_material
	_world.add_child(_shadow_catcher)

	# 技能遮挡：一块加法混合的半透明暖色片斜挡在单位前面，
	# 看侧光 / 影子在透明特效后面会不会变脏 / 过亮。
	_occluder = MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(1.6, 0.9)
	_occluder.mesh = quad
	var occluder_material := StandardMaterial3D.new()
	occluder_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	occluder_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	occluder_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	occluder_material.albedo_color = Color(1.0, 0.55, 0.18, 0.55)
	occluder_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_occluder.material_override = occluder_material
	_occluder.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_occluder.layers = (1 << (LAYER_A - 1)) | (1 << (LAYER_B - 1))
	_world.add_child(_occluder)


func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(margin)
	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(column)
	var heads := HBoxContainer.new()
	heads.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(heads)
	for i in 2:
		var head := Label.new()
		head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		head.add_theme_font_size_override("font_size", 22)
		head.add_theme_color_override("font_outline_color", Color.BLACK)
		head.add_theme_constant_override("outline_size", 6)
		heads.add_child(head)
		_heads.append(head)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(spacer)
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 15)
	_status.add_theme_color_override("font_outline_color", Color.BLACK)
	_status.add_theme_constant_override("outline_size", 5)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_status)
	var bar := HFlowContainer.new()
	bar.add_theme_constant_override("h_separation", 6)
	bar.add_theme_constant_override("v_separation", 6)
	column.add_child(bar)
	var unit_ids: Array = UNITS.keys()
	_button(bar, "单位：民兵/魅魔/暗龙", func(): _unit = unit_ids[(unit_ids.find(_unit) + 1) % unit_ids.size()], true)
	_button(bar, "影子：圆/椭圆/投影/实时", func(): _shadow = SHADOW_MODES[(SHADOW_MODES.find(_shadow) + 1) % SHADOW_MODES.size()], true)
	_button(bar, "影子方向：可读/跟灯", func(): _shadow_dir = "follow" if _shadow_dir == "readable" else "readable")
	_button(bar, "侧光：关/程序/贴图", func(): _side_mode = SIDE_MODES[(SIDE_MODES.find(_side_mode) + 1) % SIDE_MODES.size()])
	_button(bar, "灯：战斗/备战/背光", func(): _rig = {"battle": "prep", "prep": "backlight", "backlight": "battle"}[_rig])
	_button(bar, "地：丛林/雪地/决赛", func(): _background = {"jungle": "snow", "snow": "final", "final": "jungle"}[_background])
	_button(bar, "近景 / 战斗尺寸", func(): _close = not _close)
	_button(bar, "描边(民兵)", func(): _outline = not _outline)
	_button(bar, "技能遮挡", func(): _occlusion = not _occlusion)
	_button(bar, "画质 中/高", func(): _high_quality = not _high_quality)
	_button(bar, "定格 / 播放", func(): _frozen = not _frozen)
	_button(bar, "朝向 我方/敌方", func(): _facing_front = not _facing_front, true)
	_button(bar, "1 / 6 / 12 人", func(): _count = {1: 6, 6: 12, 12: 1}[_count], true)
	var slider_row := HBoxContainer.new()
	column.add_child(slider_row)
	_strength_label = Label.new()
	_strength_label.custom_minimum_size = Vector2(150, 0)
	slider_row.add_child(_strength_label)
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.2
	slider.step = 0.01
	slider.value = _side_strength
	slider.custom_minimum_size = Vector2(320, 36)
	slider.value_changed.connect(func(value: float): _side_strength = value; _apply_all())
	slider_row.add_child(slider)


func _button(parent: Node, text: String, action: Callable, rebuild := false) -> void:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0, 40)
	button.add_theme_font_size_override("font_size", 15)
	button.pressed.connect(func():
		action.call()
		if rebuild:
			_rebuild_models()
		_apply_all())
	parent.add_child(button)


func _apply_all() -> void:
	_apply_rig()
	_apply_background()
	_apply_camera()
	_apply_materials()
	_apply_shadow_params()
	_apply_extras()
	_apply_freeze()
	_viewport.msaa_3d = Viewport.MSAA_2X if _high_quality else Viewport.MSAA_DISABLED
	if _strength_label != null:
		_strength_label.text = "侧光强度 %.2f" % _side_strength
	if not _heads.is_empty():
		_heads[0].text = "A 现状（%s · 圆形影）" % UNITS[_unit].title
		var b_side := ("侧光 " + _side_mode + " · ") if _unit == "militia" else ""
		var dir_text := "" if _shadow in ["circle", "realtime"] else ("·可读方向" if _shadow_dir == "readable" else "·跟灯方向")
		_heads[1].text = "B 候选（%s%s%s）" % [b_side, SHADOW_TITLES[_shadow], dir_text]
	if _status != null:
		_status.text = "单位=%s  影子=%s  侧光=%s  灯=%s  地=%s  %s  描边=%s  遮挡=%s  画质=%s  人数=%d  %s  渲染=%s" % [
			UNITS[_unit].title, SHADOW_TITLES[_shadow], _side_mode if _unit == "militia" else "暗族自带",
			_rig, _background, "近景" if _close else "战斗尺寸", _on(_outline), _on(_occlusion),
			"高(2xMSAA)" if _high_quality else "中", _count, "敌方朝向" if _facing_front else "我方朝向",
			RenderingServer.get_current_rendering_method()]


func _on(value: bool) -> String:
	return "开" if value else "关"


func _apply_rig() -> void:
	for lights in [_lights_a, _lights_b]:
		var key := lights[0] as DirectionalLight3D
		var fill := lights[1] as DirectionalLight3D
		match _rig:
			"battle", "backlight":
				# BattleArena._setup_battle_3d_view 的单盏暖光。
				key.light_color = Color(1.0, 0.84, 0.62)
				key.light_energy = 1.55
				key.rotation_degrees = Vector3(-55, 35, 0) if _rig == "battle" else Vector3(-30, 200, 0)
				fill.visible = false
			"prep":
				# PrepBoardModels 的暖主光 + 冷补光（相机仍用战斗相机，只比光）。
				key.light_color = Color(1.0, 0.92, 0.76)
				key.light_energy = 0.64
				key.rotation_degrees = Vector3(-52.0, -28.0, 0.0)
				fill.visible = true
				fill.light_color = Color(0.48, 0.68, 0.82)
				fill.light_energy = 0.18
				fill.rotation_degrees = Vector3(-38.0, 142.0, 0.0)
	# 实时阴影只开在 B 的主光上。
	_lights_b[0].shadow_enabled = _shadow == "realtime"
	_shadow_catcher.visible = _shadow == "realtime"
	_environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC if _rig == "prep" else Environment.TONE_MAPPER_LINEAR
	if _rig == "prep":
		_environment.ambient_light_color = Color(0.58, 0.68, 0.61)
		_environment.ambient_light_energy = 0.40
	else:
		_environment.ambient_light_color = Color(0.34, 0.42, 0.34)
		_environment.ambient_light_energy = 0.42


func _apply_background() -> void:
	_background_rect.texture = load(BACKGROUNDS[_background]) as Texture2D


func _apply_camera() -> void:
	_camera.size = CLOSE_CAMERA_SIZE if _close else BATTLE_CAMERA_SIZE
	var target := Vector3(0.0, 0.18, 0.0) if _close else Vector3.ZERO
	_camera.look_at_from_position(target + BATTLE_CAMERA_POS, target, Vector3.UP)
	_camera.near = 0.05
	_camera.far = 40.0


func _apply_materials() -> void:
	_material_b.set_shader_parameter("side_light_strength", 0.0 if _side_mode == "off" else _side_strength)
	_material_b.set_shader_parameter("use_side_matcap", _side_mode == "matcap")
	_material_b.set_shader_parameter("side_light_direction", _side_direction_from_key())
	for material in [_material_a, _material_b]:
		material.next_pass = _make_outline() if _outline else null
	# 民兵 B 的材质链改了（描边开关），投影影子要重新接到链尾。
	if _unit == "militia" and _shadow == "planar":
		_rebuild_models()


## 光「行进」的世界方向：DirectionalLight 沿自身 -Z 照射。
func _light_travel_direction() -> Vector3:
	return -_lights_b[0].global_transform.basis.z.normalized()


## 侧光默认补在主光的对面。把主光方向投到相机空间取反，作为屏幕上的侧光来向，
## 这样战斗（光从右上）和备战（光从左上）都补在背光那半边。
## 生产里如果采用，需要场景把这个值写进全局 uniform，而不是写死在材质里。
func _side_direction_from_key() -> Vector2:
	var toward_light := -_light_travel_direction()
	var in_view := _camera.global_transform.basis.inverse() * toward_light
	var dir := -Vector2(in_view.x, in_view.y)
	if dir.length() < 0.05:
		return Vector2(-0.75, 0.45)
	return dir.normalized()


func _shadow_travel_direction() -> Vector3:
	return READABLE_SHADOW_TRAVEL.normalized() if _shadow_dir == "readable" else _light_travel_direction()


func _apply_shadow_params() -> void:
	var travel := _shadow_travel_direction()
	_planar_material.set_shader_parameter("light_direction", travel)
	# 椭圆尾巴朝光线在地面上的走向伸出去；PlaneMesh 的 UV u 对应 +x、v 对应 +z。
	var ground := Vector2(travel.x, travel.z)
	_ellipse_material.set_shader_parameter("shadow_direction", ground.normalized() if ground.length() > 0.01 else Vector2(0.0, 1.0))
	# 光越低尾巴越长：按光线仰角把尾巴拉长，限制在平面内。
	var elevation := clampf(-travel.y, 0.2, 1.0)
	var stretch := clampf(sqrt(1.0 - elevation * elevation) / elevation, 0.3, 1.6)
	_ellipse_material.set_shader_parameter("tail_offset", 0.18 + 0.2 * stretch)
	_ellipse_material.set_shader_parameter("tail_length", 0.3 + 0.3 * stretch)


func _make_outline() -> ShaderMaterial:
	var outline := ShaderMaterial.new()
	outline.shader = OUTLINE_SHADER
	outline.render_priority = -1
	outline.set_shader_parameter("outline_color", HUMAN_OUTLINE_COLOR)
	outline.set_shader_parameter("outline_width", HUMAN_OUTLINE_WIDTH)
	outline.set_shader_parameter("outline_max_pixels", HUMAN_OUTLINE_MAX_PX)
	return outline


func _apply_extras() -> void:
	_occluder.visible = _occlusion
	_occluder.position = Vector3(0.0, 0.32, 0.55)
	_occluder.rotation_degrees = Vector3(-30, 0, 0)


func _rebuild_models() -> void:
	for child in _actors.get_children():
		_actors.remove_child(child)
		child.queue_free()
	_models.clear()
	_chained.clear()
	var unit: Dictionary = UNITS[_unit]
	var scene := load(str(unit.path)) as PackedScene
	var groups: Array = []
	match _layout:
		"compare": groups = [["a", -0.55], ["b", 0.55]]
		"a": groups = [["a", 0.0]]
		"b": groups = [["b", 0.0]]
	for group in groups:
		var variant := str(group[0])
		var layer := LAYER_B if variant == "b" else LAYER_A
		var shadow_mode := _shadow if variant == "b" else "circle"
		for i in _count:
			var pivot := Node3D.new()
			pivot.position = _slot(i, float(group[1]))
			_actors.add_child(pivot)
			var model := scene.instantiate() as Node3D
			model.scale = Vector3.ONE * UNIT_SCALE * float(unit.scale)
			# race_units.json 这几个单位 model_base_yaw 都是 180：我方 = 180（背朝镜头、
			# 面向敌阵），敌方再转 180 成正面。
			model.rotation_degrees.y = 0.0 if _facing_front else 180.0
			pivot.add_child(model)
			if _unit == "militia":
				_swap_body(model, BODY_A, _material_b if variant == "b" else _material_a)
			_add_ground_shadow(pivot, model, shadow_mode)
			_set_layers(pivot, layer, shadow_mode == "realtime")
			_models.append(model)


func _add_ground_shadow(pivot: Node3D, model: Node3D, mode: String) -> void:
	match mode:
		"circle":
			pivot.add_child(UnitContactShadowScript.create("GroundShadow3D", Vector2.ONE * CIRCLE_FOOTPRINT))
		"ellipse":
			# 平面比原来大一倍多，尾巴才伸得出去；核心半径相应缩小，脚底那块大小不变。
			var plane := UnitContactShadowScript.create("GroundShadow3D", Vector2.ONE * CIRCLE_FOOTPRINT * 2.2)
			(plane.mesh as PlaneMesh).material = _ellipse_material
			pivot.add_child(plane)
		"planar":
			# 剪影负责方向和形状，脚底再留一块缩小的现状圆，负责「踩住」。
			pivot.add_child(UnitContactShadowScript.create("GroundShadow3D", Vector2.ONE * CIRCLE_FOOTPRINT * 0.55))
			_append_planar_pass(model)
		"realtime":
			pass


## 把投影影子接到模型每个表面材质的 next_pass 链尾。材质是共享资源，
## 先复制再改，同一原材质只复制一次，不碰磁盘上的 .tres。
func _append_planar_pass(model: Node3D) -> void:
	var stack: Array[Node] = [model]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		stack.append_array(node.get_children())
		if not node is MeshInstance3D:
			continue
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh == null:
			continue
		if mesh_instance.material_override != null:
			mesh_instance.material_override = _with_planar(mesh_instance.material_override)
			continue
		for i in mesh_instance.mesh.get_surface_count():
			var material := mesh_instance.get_active_material(i)
			if material != null:
				mesh_instance.set_surface_override_material(i, _with_planar(material))


func _with_planar(material: Material) -> Material:
	if _chained.has(material):
		return _chained[material]
	var copy := material.duplicate() as Material
	var tail := copy
	while tail.next_pass != null:
		tail.next_pass = tail.next_pass.duplicate()
		tail = tail.next_pass
	tail.next_pass = _planar_material
	_chained[material] = copy
	return copy


func _set_layers(root: Node, layer: int, cast_realtime: bool) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		stack.append_array(node.get_children())
		if node is VisualInstance3D:
			(node as VisualInstance3D).layers = 1 << (layer - 1)
		if node is GeometryInstance3D and node.name != "GroundShadow3D":
			(node as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON \
					if cast_realtime else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _slot(index: int, center_x: float) -> Vector3:
	if _count == 1:
		return Vector3(center_x, 0.0, 0.0)
	var columns := 3
	var spacing := 0.42 if _layout == "compare" else 0.9
	var col := index % columns
	var row := index / columns
	return Vector3(center_x + (col - 1) * spacing, 0.0, (row - (_count / columns - 1) * 0.5) * 0.7)


## Refined.gd 在 _ready 里把 body.tres 刷到每个动作模型上，所以替换要等模型 ready 之后。
## 只换引用 body.tres 的表面；装备（gear.tres）两边保持同一份。
func _swap_body(model: Node3D, original: Material, replacement: Material) -> void:
	var stack: Array[Node] = [model]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D:
			var mesh_instance := node as MeshInstance3D
			var surfaces := 1 if mesh_instance.mesh == null else maxi(1, mesh_instance.mesh.get_surface_count())
			for i in surfaces:
				if mesh_instance.get_surface_override_material(i) == original:
					mesh_instance.set_surface_override_material(i, replacement)
		stack.append_array(node.get_children())


## 定格：所有模型停在 idle 的同一时刻，A/B 对比不受动画相位干扰。
## speed_scale = 0 而不是 pause()，因为动作脚本的 _process 发现播放器停了会重新 play。
func _apply_freeze() -> void:
	for model in _models:
		var players: Variant = model.get("action_players")
		if not players is Dictionary:
			continue
		var player := (players as Dictionary).get("idle") as AnimationPlayer
		if player == null:
			continue
		if _frozen:
			player.speed_scale = 0.0
			if player.is_playing():
				player.seek(FREEZE_TIME, true)
		else:
			player.speed_scale = 1.0


func _process(delta: float) -> void:
	if _perf_variant.is_empty():
		return
	_perf_clock += delta
	if _perf_clock < _perf_warmup:
		return
	_perf_samples.append(delta * 1000.0)
	_perf_peak_draws = maxi(_perf_peak_draws, int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)))
	if _perf_clock >= _perf_warmup + _perf_seconds:
		_finish_perf()


func _finish_perf() -> void:
	var sorted := _perf_samples.duplicate()
	sorted.sort()
	var result := {
		"variant": _perf_variant, "unit": _unit, "shadow": _shadow if _perf_variant == "b" else "circle",
		"shadow_dir": _shadow_dir,
		"side": _side_mode, "count": _count,
		"seconds": _perf_seconds, "warmup": _perf_warmup, "frames": sorted.size(),
		"p50_ms": _percentile(sorted, 0.5), "p95_ms": _percentile(sorted, 0.95),
		"max_ms": sorted.back() if not sorted.is_empty() else 0.0,
		"peak_draw_calls": _perf_peak_draws,
		"video_mem_mb": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		"texture_mem_mb": Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0,
		"static_mem_mb": Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
		"renderer": RenderingServer.get_current_rendering_method(),
		"adapter": RenderingServer.get_video_adapter_name(),
		"os": OS.get_name(), "model": OS.get_model_name(),
		"msaa": "2x" if _high_quality else "off",
		"viewport": [_viewport.size.x, _viewport.size.y],
		"window": [get_viewport_rect().size.x, get_viewport_rect().size.y],
	}
	var file := FileAccess.open(_perf_out, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(result, "  "))
		file.close()
	print("ART_AB_PERF_RESULT " + JSON.stringify(result))
	_perf_variant = ""
	get_tree().quit(0)


func _percentile(sorted: Array, q: float) -> float:
	if sorted.is_empty():
		return 0.0
	return float(sorted[clampi(int(round(q * (sorted.size() - 1))), 0, sorted.size() - 1)])


func _capture(file_name: String) -> bool:
	for i in 6:
		await RenderingServer.frame_post_draw
	return get_viewport().get_texture().get_image().save_png(_capture_dir.path_join(file_name)) == OK


func _run_captures() -> void:
	var saved := 0
	if _suite == "side":
		saved = await _capture_side_suite()
	else:
		saved = await _capture_shadow_suite()
	print("ART_AB_CAPTURES suite=%s saved=%d dir=%s" % [_suite, saved, _capture_dir])
	get_tree().quit(0 if saved > 0 else 1)


const SHADOW_VARIANTS := [["ellipse", "readable"], ["ellipse", "follow"], ["planar", "readable"], ["planar", "follow"], ["realtime", "follow"]]


func _variant_name(variant: Array) -> String:
	return str(variant[0]) if variant[0] == "realtime" else "%s_%s" % [variant[0], variant[1]]


## 影子矩阵：3 个单位 × 3 种条件 × 5 种候选影子（左 A 永远是现状圆），
## 外加技能遮挡、6 人站位（看影子互相压到）、自检。
func _capture_shadow_suite() -> int:
	var saved := 0
	_side_mode = "off"   # 民兵也只比影子，侧光关掉
	_close = true
	_facing_front = true
	var conditions := [
		{"name": "light_board", "rig": "battle", "background": "snow"},
		{"name": "dark_board", "rig": "battle", "background": "jungle"},
		{"name": "backlight", "rig": "backlight", "background": "jungle"},
	]
	for unit in UNITS.keys():
		_unit = unit
		for condition in conditions:
			_rig = condition.rig
			_background = condition.background
			for variant in SHADOW_VARIANTS:
				_shadow = variant[0]
				_shadow_dir = variant[1]
				_rebuild_models()
				_apply_all()
				if await _capture("shadow_%s_%s_%s.png" % [unit, condition.name, _variant_name(variant)]):
					saved += 1
	# 技能遮挡 + 6 人（战斗尺寸，我方朝向），只看暗族。
	_rig = "battle"
	_background = "jungle"
	for unit in ["dark_suc", "dark_dragon"]:
		_unit = unit
		for variant in SHADOW_VARIANTS:
			_shadow = variant[0]
			_shadow_dir = variant[1]
			var shadow := _variant_name(variant)
			_occlusion = true
			_count = 1
			_close = true
			_rebuild_models()
			_apply_all()
			if await _capture("shadow_%s_occlusion_%s.png" % [unit, shadow]):
				saved += 1
			_occlusion = false
			_count = 6
			_close = false
			_facing_front = false
			_rebuild_models()
			_apply_all()
			if await _capture("shadow_%s_group6_%s.png" % [unit, shadow]):
				saved += 1
			_facing_front = true
	# 自检：B 选「现状圆」时应与 A 逐像素一致。
	_count = 1
	_close = true
	_unit = "dark_suc"
	_shadow = "circle"
	_shadow_dir = "readable"
	for variant in ["a", "b"]:
		_layout = variant
		_rebuild_models()
		_apply_all()
		if await _capture("equal_shadow_%s.png" % variant):
			saved += 1
	_layout = "compare"
	return saved


## 侧光矩阵（第一轮）：民兵，五种条件 × 三种侧光，外加 A / B（侧光关）逐像素自检。
func _capture_side_suite() -> int:
	var saved := 0
	_unit = "militia"
	_shadow = "circle"
	var conditions := [
		{"name": "light_board", "rig": "battle", "background": "snow", "occlusion": false},
		{"name": "dark_board", "rig": "battle", "background": "jungle", "occlusion": false},
		{"name": "backlight", "rig": "backlight", "background": "jungle", "occlusion": false},
		{"name": "skill_occlusion", "rig": "battle", "background": "jungle", "occlusion": true},
		{"name": "prep_rig", "rig": "prep", "background": "jungle", "occlusion": false},
	]
	for close in [true, false]:
		_facing_front = close
		_rebuild_models()
		for condition in conditions:
			for side in SIDE_MODES:
				_close = close
				_rig = condition.rig
				_background = condition.background
				_occlusion = condition.occlusion
				_side_mode = side
				_apply_all()
				if await _capture("%s_%s_%s.png" % ["close" if close else "battle", condition.name, side]):
					saved += 1
	_close = true
	_rig = "battle"
	_background = "jungle"
	_occlusion = false
	_side_mode = "off"
	for variant in ["a", "b"]:
		_layout = variant
		_rebuild_models()
		_apply_all()
		if await _capture("equal_%s.png" % variant):
			saved += 1
	_layout = "compare"
	return saved
