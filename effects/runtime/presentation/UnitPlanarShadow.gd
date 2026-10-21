class_name UnitPlanarShadow
extends RefCounted
## 战斗单位的投影剪影影子（shaders/unit_planar_shadow.gdshader）。
##
## 挂法：把影子材质接到模型每个表面材质 next_pass 链的最后，而不是另加一个影子
## MeshInstance3D。原因是四星光环、亡灵光环、死亡发光都会给角色下所有 ArrayMesh
## 网格挂 material_overlay，另加的影子网格也会被挂上，变成一层没压扁的重影。
##
## 角色材质是 .tres 共享资源（备战、预览、头像渲染都在用），这里一律先复制再接：
## 同一个原材质只复制一次、全局缓存，同种单位共用一份带影子的副本，磁盘上的资源不动。
##
## 画质：LOW 不挂（保留现状圆形影）；MEDIUM / HIGH 挂投影，脚底圆缩成小核心。

const SHADER := preload("res://shaders/unit_planar_shadow.gdshader")
# 影子落向屏幕右下方（世界 +x、+z），用户 2026-10-21 定的「可读方向」。
const SHADOW_DIRECTION := Vector3(0.42, -0.78, 0.46)
# 挂了投影后，脚底圆缩到原尺寸的这个比例，只负责「踩住」。
const CORE_SCALE := 0.55
# 影子比地面高一点点，免得和 2D 底图 / 地面网格抢深度。脚底圆在 +0.012，影子要在它下面。
const GROUND_LIFT := 0.004
# 临时真机对照开关：user:// 下有这个文件、内容为 on / off 时强制开关，忽略画质档。
# 只为同一个 APK 在同一台手机上对比开/关，测完连同 force_mode() 一起删掉。
const TEST_SWITCH_PATH := "user://planar_shadow_test.txt"

static var _material: ShaderMaterial
static var _chained: Dictionary = {}       # 原材质 instance_id -> 带影子的副本
static var _copies: Dictionary = {}        # 副本 instance_id -> true，防重复接
static var _forced := ""
static var _forced_read := false


static func enabled_for_tier(tier: int) -> bool:
	var forced := force_mode()
	if forced == "on":
		return true
	if forced == "off":
		return false
	return tier != VFXQualityBudget.Tier.LOW


static func force_mode() -> String:
	if not _forced_read:
		_forced_read = true
		if FileAccess.file_exists(TEST_SWITCH_PATH):
			_forced = FileAccess.get_file_as_string(TEST_SWITCH_PATH).strip_edges().to_lower()
			if _forced not in ["on", "off"]:
				_forced = ""
	return _forced


static func shared_material() -> ShaderMaterial:
	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = SHADER
		# 先于脚底小圆和队伍光圈（都在 0）画，光圈压在影子上面。
		_material.render_priority = -2
		_material.set_shader_parameter("shadow_direction", SHADOW_DIRECTION)
	return _material


## 模型 ready 之后再接：DarkRefinement 在宿主 ready 时才换身体材质，
## 人族 Refined.gd 在 _ready 里才加装备网格。deferred 保证排在它们后面。
## ground_y：单位脚底所在的世界高度。战斗单位不站在 y = 0，而是站在
## BattleUI.battle_unit_y_offset（默认 1.0）上；压到 0 会让影子整片错位到单位前方。
static func attach(model: Node3D, ground_y: float) -> void:
	if model == null:
		return
	shared_material().set_shader_parameter("ground_y", ground_y + GROUND_LIFT)
	if model.is_node_ready():
		_apply.call_deferred(model)
	else:
		model.ready.connect(func() -> void: _apply.call_deferred(model), CONNECT_ONE_SHOT)


static func _apply(model: Node3D) -> void:
	if not is_instance_valid(model):
		return
	var stack: Array[Node] = [model]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		stack.append_array(node.get_children())
		if not node is MeshInstance3D:
			continue
		var mesh_instance := node as MeshInstance3D
		# 只给导入的角色网格：脚底圆、光圈、状态图标这些是 PrimitiveMesh，不投影。
		if not mesh_instance.mesh is ArrayMesh:
			continue
		if mesh_instance.material_override != null:
			mesh_instance.material_override = chained(mesh_instance.material_override)
			continue
		for surface in mesh_instance.mesh.get_surface_count():
			var material := mesh_instance.get_active_material(surface)
			if material != null:
				mesh_instance.set_surface_override_material(surface, chained(material))


## 返回「原材质 + 投影影子」的副本；传入已经是副本时原样返回。
static func chained(material: Material) -> Material:
	if _copies.has(material.get_instance_id()):
		return material
	var key := material.get_instance_id()
	if _chained.has(key):
		return _chained[key]
	var copy := material.duplicate() as Material
	var tail := copy
	while tail.next_pass != null:
		tail.next_pass = tail.next_pass.duplicate()
		tail = tail.next_pass
	tail.next_pass = shared_material()
	_chained[key] = copy
	_copies[copy.get_instance_id()] = true
	return copy


## 这个模型是否已经挂上了投影（供检查脚本用）。
static func is_attached(model: Node) -> bool:
	var stack: Array[Node] = [model]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		stack.append_array(node.get_children())
		if node is MeshInstance3D and (node as MeshInstance3D).mesh is ArrayMesh:
			var mesh_instance := node as MeshInstance3D
			var material := mesh_instance.material_override
			if material == null and mesh_instance.mesh.get_surface_count() > 0:
				material = mesh_instance.get_active_material(0)
			while material != null:
				if material == _material:
					return true
				material = material.next_pass
	return false
