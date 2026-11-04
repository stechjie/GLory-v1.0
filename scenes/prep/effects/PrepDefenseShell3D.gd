extends Node3D

# 防卫套在备战棋子**身上**的常驻护盾（11.04 返工）。
#
# Leno 11.04：「4 防卫在身上的盾你也要显示出来」—— 就是战斗开局那个六边形护罩
# （VFXTreasureSet3D.play_defense_shield，shaders/set_defense_shield.gdshader），
# 战斗里只亮 1 秒，备战里改成一直罩着：
#   · 同一个 shader、同一套青金配色，备战看到的就是开战那一下的护罩；
#   · 常驻亮度压到 BASE_FADE，否则半透明壳整个盖在棋子上，看不清是谁；
#   · 每 SWEEP_PERIOD 秒一道亮带从脚扫到头，让它「活着」，不是一层静止的贴膜；
#   · 刚挂上时和战斗一样从 0.6 倍弹到原大。
#
# 挂在棋子模型的父节点下、每帧跟随（理由同 SetDefenseSigil3D：模型根带缩放，升星还会压扁回弹）。
# 尺寸 = 备战棋子的统一渲染身高（宿主传入，见 _rebuild_mesh 上的说明）。

const SHIELD_SHADER := preload("res://shaders/set_defense_shield.gdshader")
const BASE_FADE := 0.55
const SWEEP_PERIOD := 2.6
const SWEEP_SEC := 0.7
const POP_SEC := 0.22
const FADE_OUT_SEC := 0.25

var _follow: Node3D
var _height := 0.1
var _center_offset := Vector3(0.0, 0.05, 0.0)
var _strength := 1.0
var _age := 0.0
var _stopping := false
var _stop_age := 0.0
var _shell: MeshInstance3D
var _material: ShaderMaterial


func setup(follow: Node3D, strength: float, height: float) -> void:
	name = "PrepDefenseShell"
	_height = height
	_center_offset = Vector3(0.0, height * 0.5, 0.0)
	_follow = follow
	_strength = strength
	_material = ShaderMaterial.new()
	_material.shader = SHIELD_SHADER
	_material.set_shader_parameter("fade", 0.0)
	_material.render_priority = 22
	_shell = MeshInstance3D.new()
	_shell.name = "Shell"
	_shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_shell.material_override = _material
	add_child(_shell)
	_rebuild_mesh()
	_snap()


func retarget(follow: Node3D) -> void:
	_follow = follow
	_rebuild_mesh()
	_snap()


func set_strength(strength: float) -> void:
	_strength = strength


func set_start(delay: float, skip_pop: bool) -> void:
	_age = POP_SEC if skip_pop else -maxf(0.0, delay)


func stop() -> void:
	if _stopping:
		return
	_stopping = true
	_stop_age = _age


# 身高由宿主给（UNIT_HEIGHT 0.32 × 实测格距换算，和四星光环 / 升星特效同一口径）。
# 试过两种自己量的办法都不行，别再走回头路：
#   · 模型上记的 relation_waist_height：各模型原点 / 子节点偏移不同，罩子有的盖过头、有的只到脚；
#   · 网格 get_aabb()：棋子是骨骼蒙皮模型，aabb 是没摆姿势的原始包围盒，不含骨骼旋转，
#     实测 Swordsman 只量到 0.044（实际约 0.1）。
func _rebuild_mesh() -> void:
	if _shell.mesh != null:
		return
	var sphere := SphereMesh.new()
	# 与战斗护罩同比例（半径 0.55 身高、高 1.2 身高），略收窄一点：备战棋子站得密，
	# 战斗比例的壳会顶到隔壁格。
	sphere.radius = _height * 0.50
	sphere.height = _height * 1.15
	sphere.radial_segments = 24
	sphere.rings = 12
	_shell.mesh = sphere


func _process(delta: float) -> void:
	if _follow == null or not is_instance_valid(_follow) or not _follow.is_inside_tree():
		queue_free()
		return
	_age += delta
	_snap()
	var t := maxf(_age, 0.0)
	var pop := clampf(t / POP_SEC, 0.0, 1.0)
	# ease-out-back（= Tween TRANS_BACK + EASE_OUT）：先冲过 1 再落回，和战斗护罩弹出一致
	var x := pop - 1.0
	var back := 1.0 + 2.70158 * x * x * x + 1.70158 * x * x
	_shell.scale = Vector3.ONE * (0.6 + 0.4 * back)
	var fade := BASE_FADE * pop
	if _stopping:
		fade *= 1.0 - clampf((_age - _stop_age) / FADE_OUT_SEC, 0.0, 1.0)
		if _age - _stop_age >= FADE_OUT_SEC:
			queue_free()
			return
	# 亮带：每个周期开头从脚扫到头，其余时间停在头顶外（看不见）。
	var k := fposmod(t, SWEEP_PERIOD)
	var half := _height * 0.6
	var sweep := lerpf(-half, half, clampf(k / SWEEP_SEC, 0.0, 1.0)) if k < SWEEP_SEC else half * 3.0
	_material.set_shader_parameter("sweep", sweep)
	_material.set_shader_parameter("fade", fade * _strength)


func _snap() -> void:
	if _follow != null and is_instance_valid(_follow) and _follow.is_inside_tree():
		position = _follow.position + _center_offset
