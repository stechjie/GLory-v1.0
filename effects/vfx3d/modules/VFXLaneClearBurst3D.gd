extends VFXBlockRoot
## One ground quad clips the entire shockwave to the actual local lane.
## Bounds use VFX-root X/Z coordinates, including the arena's replay flip.
##
## 10.31 清场加强（用户批准的方案 2、4）：
##   * 地面光波保留；
##   * 两道竖直光幕从击杀点沿本路向两端推开（雪地上贴地光波几乎看不见，竖起来才读得出）；
##   * 击杀点一根短光柱；
##   * 我方本路存活棋子脚下各亮一圈金环（小跳在 BattleVfx 里做，这里只出光）。
## 整个块 0.9 秒内自行释放（coin_damage_check 的 wave_released 等 1.05 秒）。
const PRESENTATION := preload("res://effects/runtime/presentation/PresentationSettings.gd")
const CURTAIN_SHADER := preload("res://shaders/lane_clear_curtain.gdshader")

const TOTAL_SEC := 0.9
# 单位实测只有 0.28–0.93 高（见 vfx-world-scale），光幕 / 光柱按这个量级取。
# 相机俯角约 46°，竖直面在屏幕上被压扁；0.62 时只剩一条细线（10.31 截帧），抬到 1.05。
const CURTAIN_HEIGHT := 1.05
const CURTAIN_SWEEP_SEC := 0.52
const PILLAR_SIZE := Vector2(0.34, 1.7)
const PILLAR_SEC := 0.62
const CHEER_RING_SIZE := 0.62
const CHEER_RING_SEC := 0.55


func play_clear(origin: Vector3, bounds: Rect2, cheer_points: Array = []) -> void:
	begin()
	var plane := MeshInstance3D.new()
	plane.name = "LaneClippedWave"
	plane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var quad := QuadMesh.new()
	quad.size = bounds.size
	plane.mesh = quad
	plane.rotation.x = -PI * 0.5
	plane.position = Vector3(bounds.get_center().x, origin.y + 0.035, bounds.get_center().y)
	var material := ShaderMaterial.new()
	material.shader = preload("res://shaders/lane_clear_wave.gdshader")
	material.set_shader_parameter("progress", 0.0)
	material.set_shader_parameter("world_size", bounds.size)
	var uv := (Vector2(origin.x, origin.z) - bounds.position) / bounds.size
	material.set_shader_parameter("origin_uv", uv.clamp(Vector2.ZERO, Vector2.ONE))
	material.set_shader_parameter("opacity", 1.0 if PRESENTATION.flash_allowed() else 0.35)
	material.set_shader_parameter("detail", PRESENTATION.QUALITY.tier != PRESENTATION.QUALITY.Tier.LOW)
	plane.material_override = material
	add_child(plane)
	var tween := track_tween(create_tween())
	tween.tween_property(material, "shader_parameter/progress", 1.0, 0.68)
	var strength := 1.0 if PRESENTATION.flash_allowed() else 0.45
	_spawn_curtains(origin, bounds, strength)
	_spawn_pillar(origin, strength)
	for point in cheer_points:
		if point is Vector3:
			_spawn_cheer_ring(point, strength)
	var done := track_tween(create_tween())
	done.tween_interval(TOTAL_SEC)
	done.tween_callback(finish)


# 两道光幕：宽度 = 本路宽，从击杀点所在的 z 分别推向本路两端，边推边淡。
func _spawn_curtains(origin: Vector3, bounds: Rect2, strength: float) -> void:
	var z0 := clampf(origin.z, bounds.position.y, bounds.end.y)
	var index := 0
	for target_z in [bounds.position.y, bounds.end.y]:
		if absf(target_z - z0) < 0.2:
			continue
		var curtain := _quad_node("LaneClearCurtain%d" % index, Vector2(bounds.size.x, CURTAIN_HEIGHT), 0, strength)
		curtain.position = Vector3(bounds.get_center().x, origin.y + CURTAIN_HEIGHT * 0.5, z0)
		add_child(curtain)
		var mat := curtain.material_override as ShaderMaterial
		var tween := track_tween(create_tween().set_parallel(true))
		tween.tween_property(curtain, "position:z", target_z, CURTAIN_SWEEP_SEC) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tween.tween_property(curtain, "scale:y", 0.35, CURTAIN_SWEEP_SEC) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tween.tween_property(mat, "shader_parameter/fade", 0.0, CURTAIN_SWEEP_SEC * 0.55) \
			.set_delay(CURTAIN_SWEEP_SEC * 0.45)
		index += 1


func _spawn_pillar(origin: Vector3, strength: float) -> void:
	var pillar := _quad_node("LaneClearPillar", PILLAR_SIZE, 1, strength)
	pillar.position = Vector3(origin.x, origin.y + PILLAR_SIZE.y * 0.5, origin.z)
	pillar.scale = Vector3(0.4, 0.2, 1.0)
	add_child(pillar)
	var mat := pillar.material_override as ShaderMaterial
	var tween := track_tween(create_tween())
	tween.tween_property(pillar, "scale", Vector3(1.0, 1.0, 1.0), 0.12) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.chain().set_parallel(true)
	tween.tween_property(pillar, "scale:x", 0.15, PILLAR_SEC - 0.12).set_ease(Tween.EASE_IN)
	tween.tween_property(mat, "shader_parameter/fade", 0.0, PILLAR_SEC - 0.12).set_ease(Tween.EASE_IN)


func _spawn_cheer_ring(foot: Vector3, strength: float) -> void:
	var ring := _quad_node("LaneClearCheerRing", Vector2.ONE * CHEER_RING_SIZE, 2, strength)
	ring.rotation.x = -PI * 0.5
	ring.position = foot + Vector3(0.0, 0.03, 0.0)
	ring.scale = Vector3.ONE * 0.45
	add_child(ring)
	var mat := ring.material_override as ShaderMaterial
	var tween := track_tween(create_tween().set_parallel(true))
	tween.tween_property(ring, "scale", Vector3.ONE * 1.15, CHEER_RING_SEC) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(mat, "shader_parameter/fade", 0.0, CHEER_RING_SEC * 0.6).set_delay(CHEER_RING_SEC * 0.4)


func _quad_node(node_name: String, size: Vector2, shape: int, strength: float) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var quad := QuadMesh.new()
	quad.size = size
	node.mesh = quad
	var mat := ShaderMaterial.new()
	mat.shader = CURTAIN_SHADER
	mat.set_shader_parameter("shape", shape)
	mat.set_shader_parameter("fade", strength)
	node.material_override = mat
	return node
