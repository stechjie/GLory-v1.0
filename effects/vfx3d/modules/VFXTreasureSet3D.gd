extends VFXBlockRoot
## 10.31 宝藏 4 件套的战斗表现（用户批准：所有人都看得到）。
##   攻击套：斩杀刀光 + 地面红环（play_execute）、斩杀后 5 秒攻速加成的红色速度光环（play_speed_aura）。
##   防卫套：开局六边形护罩亮一次（play_defense_shield）、闪避时的青色侧闪残光（play_dodge）。
## 块都挂在 VFX 根下；需要跟随单位的（光环 / 护罩）在 _process 里每帧对齐 follow 的位置，
## 不挂在 actor 下面 —— actor 的缩放 / 死亡接管会连带改特效尺寸和寿命。
const CURTAIN_SHADER := preload("res://shaders/lane_clear_curtain.gdshader")
const SLASH_SHADER := preload("res://shaders/set_execute_slash.gdshader")
const SHIELD_SHADER := preload("res://shaders/set_defense_shield.gdshader")

const EXECUTE_SEC := 0.66
const AURA_FADE_IN_SEC := 0.15
const AURA_FADE_OUT_SEC := 0.4
const AURA_STREAKS := 3
const SHIELD_SEC := 0.75
const DODGE_SEC := 0.32

var _follow: Node3D = null
var _follow_offset := Vector3.ZERO
var _aura_until_msec := 0
var _aura_strength := 1.0
var _aura_materials: Array[ShaderMaterial] = []
var _aura_streaks: Array[Node3D] = []
var _aura_radius := 0.3
var _aura_phase := 0.0


func _process(delta: float) -> void:
	if _follow != null:
		if not is_instance_valid(_follow) or not _follow.is_inside_tree():
			finish()
			return
		global_position = _follow.global_position + _follow_offset
	if _aura_streaks.is_empty():
		return
	_aura_phase += delta * 9.0
	for i in range(_aura_streaks.size()):
		var a := _aura_phase + TAU * float(i) / float(_aura_streaks.size())
		_aura_streaks[i].position = Vector3(cos(a) * _aura_radius, _aura_streaks[i].position.y, sin(a) * _aura_radius)
	var left := float(_aura_until_msec - Time.get_ticks_msec()) / 1000.0
	var alpha := clampf(left / AURA_FADE_OUT_SEC, 0.0, 1.0) * _aura_strength
	for mat in _aura_materials:
		mat.set_shader_parameter("fade", alpha)
	if left <= 0.0:
		finish()


# center：目标胸口（VFX 根本地坐标）；foot_y：脚底高度；size：目标身高。
func play_execute(center: Vector3, foot_y: float, size: float, strength: float) -> void:
	begin()
	var slash := MeshInstance3D.new()
	slash.name = "SetExecuteSlash"
	slash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var quad := QuadMesh.new()
	quad.size = Vector2(size * 3.0, size * 1.35)
	slash.mesh = quad
	var mat := ShaderMaterial.new()
	mat.shader = SLASH_SHADER
	mat.set_shader_parameter("reveal", 0.0)
	mat.set_shader_parameter("fade", strength)
	mat.render_priority = 10
	slash.material_override = mat
	# 竖在单位前面、朝相机，斜 32° 劈下。
	slash.position = center + vfx_toward_camera(0.25)
	slash.rotation = Vector3(-0.78, 0.0, deg_to_rad(-32.0))
	add_child(slash)
	var tween := track_tween(create_tween())
	tween.tween_property(mat, "shader_parameter/reveal", 1.0, 0.09).set_ease(Tween.EASE_OUT)
	tween.tween_interval(0.18)
	tween.chain().set_parallel(true)
	tween.tween_property(slash, "scale", Vector3(1.12, 0.6, 1.0), 0.24).set_ease(Tween.EASE_IN)
	tween.tween_property(mat, "shader_parameter/fade", 0.0, 0.24).set_ease(Tween.EASE_IN)
	var ring := _quad("SetExecuteRing", Vector2.ONE * size * 1.3, 2,
		Color(1.0, 0.92, 0.76), Color(1.0, 0.22, 0.08), Color(0.2, 0.02, 0.0), strength)
	ring.rotation.x = -PI * 0.5
	ring.position = Vector3(center.x, foot_y + 0.03, center.z)
	ring.scale = Vector3.ONE * 0.4
	add_child(ring)
	var ring_mat := ring.material_override as ShaderMaterial
	var ring_tween := track_tween(create_tween().set_parallel(true))
	ring_tween.tween_property(ring, "scale", Vector3.ONE * 1.1, 0.34).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	ring_tween.tween_property(ring_mat, "shader_parameter/fade", 0.0, 0.22).set_delay(0.12)
	var done := track_tween(create_tween())
	done.tween_interval(EXECUTE_SEC)
	done.tween_callback(finish)


# 攻速加成期间脚下一圈红色速度环 + 三道绕身红光。重复斩杀只延长时间，不叠第二个。
func play_speed_aura(follow: Node3D, duration: float, radius: float, strength: float) -> void:
	begin()
	_follow = follow
	_follow_offset = Vector3(0.0, 0.03, 0.0)
	_aura_radius = radius
	_aura_strength = strength
	_aura_until_msec = Time.get_ticks_msec() + int(duration * 1000.0)
	global_position = follow.global_position + _follow_offset
	var ring := _quad("SetSpeedRing", Vector2.ONE * radius * 2.4, 2,
		Color(1.0, 0.86, 0.70), Color(1.0, 0.30, 0.10), Color(0.24, 0.03, 0.0), 0.0)
	ring.rotation.x = -PI * 0.5
	add_child(ring)
	_aura_materials.append(ring.material_override as ShaderMaterial)
	for i in range(AURA_STREAKS):
		var streak := _quad("SetSpeedStreak%d" % i, Vector2(radius * 0.32, radius * 1.5), 1,
			Color(1.0, 0.90, 0.78), Color(1.0, 0.32, 0.10), Color(0.24, 0.03, 0.0), 0.0)
		streak.position.y = radius * 0.75
		add_child(streak)
		_aura_streaks.append(streak)
		_aura_materials.append(streak.material_override as ShaderMaterial)
	var tween := track_tween(create_tween().set_parallel(true))
	for mat in _aura_materials:
		tween.tween_property(mat, "shader_parameter/fade", strength, AURA_FADE_IN_SEC)


func refresh_speed_aura(duration: float) -> void:
	_aura_until_msec = Time.get_ticks_msec() + int(duration * 1000.0)


# 开局护罩：从 0.6 倍弹到原大，一道亮带从脚扫到头，然后淡出。height 是单位身高。
func play_defense_shield(follow: Node3D, height: float, strength: float) -> void:
	begin()
	_follow = follow
	_follow_offset = Vector3(0.0, height * 0.52, 0.0)
	global_position = follow.global_position + _follow_offset
	var shell := MeshInstance3D.new()
	shell.name = "SetDefenseShield"
	shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var sphere := SphereMesh.new()
	sphere.radius = height * 0.55
	sphere.height = height * 1.2
	sphere.radial_segments = 24
	sphere.rings = 12
	shell.mesh = sphere
	var mat := ShaderMaterial.new()
	mat.shader = SHIELD_SHADER
	mat.set_shader_parameter("fade", strength)
	mat.set_shader_parameter("sweep", -height * 0.6)
	shell.material_override = mat
	shell.scale = Vector3.ONE * 0.6
	add_child(shell)
	var tween := track_tween(create_tween().set_parallel(true))
	tween.tween_property(shell, "scale", Vector3.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(mat, "shader_parameter/sweep", height * 0.6, 0.45).set_delay(0.08)
	tween.tween_property(mat, "shader_parameter/fade", 0.0, 0.25).set_delay(SHIELD_SEC - 0.25)
	var done := track_tween(create_tween())
	done.tween_interval(SHIELD_SEC)
	done.tween_callback(finish)


# 闪避：原地留两道青色残光（原位 + 往侧闪方向一半），配合 BattleVfx 里的侧闪位移。
func play_dodge(foot: Vector3, side: Vector3, height: float, strength: float) -> void:
	begin()
	var index := 0
	for t in [0.0, 0.5]:
		var ghost := _quad("SetDodgeGhost%d" % index, Vector2(height * 0.45, height * 1.1), 1,
			Color(0.90, 1.0, 1.0), Color(0.30, 0.86, 1.0), Color(0.02, 0.12, 0.22), strength * (1.0 - t * 0.6))
		ghost.position = foot + side * (height * 0.25 * t) + Vector3(0.0, height * 0.55, 0.0)
		add_child(ghost)
		var mat := ghost.material_override as ShaderMaterial
		var tween := track_tween(create_tween().set_parallel(true))
		tween.tween_property(mat, "shader_parameter/fade", 0.0, DODGE_SEC).set_ease(Tween.EASE_IN)
		tween.tween_property(ghost, "scale:x", 0.3, DODGE_SEC)
		index += 1
	var done := track_tween(create_tween())
	done.tween_interval(DODGE_SEC + 0.02)
	done.tween_callback(finish)


func _quad(node_name: String, size: Vector2, shape: int, core: Color, glow: Color, edge: Color, fade: float) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var quad := QuadMesh.new()
	quad.size = size
	node.mesh = quad
	var mat := ShaderMaterial.new()
	mat.shader = CURTAIN_SHADER
	mat.set_shader_parameter("shape", shape)
	mat.set_shader_parameter("fade", fade)
	mat.set_shader_parameter("core_color", core)
	mat.set_shader_parameter("glow_color", glow)
	mat.set_shader_parameter("edge_color", edge)
	node.material_override = mat
	return node
