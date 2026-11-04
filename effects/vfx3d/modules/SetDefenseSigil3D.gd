extends MeshInstance3D
## 11.01 防卫套常驻盾纹（用户改主意：从「只要开局护罩」改成「要常驻盾纹」，开局护罩保留）。
## 刻意不继承 VFXBlockRoot：那边有同屏特效块的并发上限，常驻节点会一直占着名额，
## 把别的战斗特效挤掉。这里只是一个跟着单位走的贴地面片，BattleVfx 负责建和收。
const SIGIL_SHADER := preload("res://shaders/set_defense_sigil.gdshader")
const SPIN_RAD_PER_SEC := 0.5
const PULSE_PERIOD_SEC := 3.2
const FADE_IN_SEC := 0.3
const FADE_OUT_SEC := 0.2

var _follow: Node3D = null
var _strength := 1.0
var _material: ShaderMaterial
var _age := 0.0
var _stopping := false


func setup(follow: Node3D, radius: float, strength: float) -> void:
	name = "SetDefenseSigil"
	_follow = follow
	_strength = strength
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * radius * 2.0
	quad.orientation = PlaneMesh.FACE_Y
	mesh = quad
	_material = ShaderMaterial.new()
	_material.shader = SIGIL_SHADER
	_material.set_shader_parameter("fade", 0.0)
	# 透明物按中心距离排序，贴地小面片容易被别的半透明层盖掉（synergy-activation-fx 记的坑）。
	_material.render_priority = 6
	material_override = _material
	_snap()


# 11.04 备战界面五个套装共用这块面片（战斗里只有防卫套，不调这几个，外观不变）。
# style：{pattern:int, ring:Color, notch:Color, elem_b:Color, elem_c:Color}，缺的键保留默认。
func configure(style: Dictionary) -> void:
	if _material == null:
		return
	if style.has("pattern"):
		_material.set_shader_parameter("pattern", int(style["pattern"]))
	for key in ["ring", "notch", "elem_b", "elem_c"]:
		if style.has(key):
			var param: String = {"ring": "ring_color", "notch": "notch_color"}.get(key, key)
			_material.set_shader_parameter(param, style[key])


# 备战里棋子模型会被整个重建（星级 / 外观签名变了）：换跟随目标，不重建面片，免得再淡入一次。
func retarget(follow: Node3D) -> void:
	_follow = follow
	_snap()


# 常驻期间改亮度（金钱套随金币变）。淡入 / 淡出过程中也生效。
func set_strength(strength: float) -> void:
	_strength = strength


# 负的 age = 晚这么多秒才开始淡入（备战里同族一串从左到右依次亮）。
# skip_fade：模型被重建、盾纹跟着重建时直接满亮，不要再闪一次淡入。
func set_start(delay: float, skip_fade: bool) -> void:
	_age = FADE_IN_SEC if skip_fade else -maxf(0.0, delay)


func stop() -> void:
	if _stopping:
		return
	_stopping = true
	var tween := create_tween()
	tween.tween_method(func(v: float) -> void: _material.set_shader_parameter("fade", v),
		float(_material.get_shader_parameter("fade")), 0.0, FADE_OUT_SEC)
	tween.tween_callback(queue_free)


func _process(delta: float) -> void:
	if _follow == null or not is_instance_valid(_follow) or not _follow.is_inside_tree():
		queue_free()
		return
	_snap()
	_age += delta
	rotation.y += delta * SPIN_RAD_PER_SEC
	if _stopping:
		return
	var pulse := maxf(0.0, sin(maxf(_age, 0.0) * TAU / PULSE_PERIOD_SEC))
	_material.set_shader_parameter("pulse", pulse * pulse)
	_material.set_shader_parameter("fade", clampf(_age / FADE_IN_SEC, 0.0, 1.0) * _strength)


func _snap() -> void:
	if _follow != null and is_instance_valid(_follow) and _follow.is_inside_tree():
		global_position = _follow.global_position + Vector3(0.0, 0.025, 0.0)
