class_name UnitSceneBlend
extends RefCounted
## 让 3D 单位「融进手绘场景」的统一处理（2026-11-15 试样，目前只有备战棋盘在用）。
##
## 做两件事，都不动磁盘上的材质资源：
##   1. 描边统一成暖深棕（和 UI / 场景的线稿同色系）。原来各单位自带的描边是近黑的紫或墨色；
##      没有描边的单位（人族精修版等）补一层。
##   2. 在 next_pass 链上接一层 shaders/unit_scene_blend.gdshader：所有单位共用同一个光向的
##      明暗 + 暖色边缘光。
##
## 接法和 UnitPlanarShadow 一样：材质是共享资源，先复制再改，同一个原材质只复制一次。
## 必须在 UnitPlanarShadow.attach() 之前调用——影子会接在这里做出的副本后面。

const BLEND_SHADER := preload("res://shaders/unit_scene_blend.gdshader")
const OUTLINE_SHADER := preload("res://shaders/character_outline.gdshader")
# 暖深棕，带一点梅子色：压在暗族的紫、人族的蓝、神族的白上都不突兀。
const OUTLINE_COLOR := Color(0.075, 0.035, 0.04, 1.0)
const ADDED_OUTLINE_WIDTH := 0.030
const ADDED_OUTLINE_MAX_PX := 1.0

static var _blend_material: ShaderMaterial
static var _copies: Dictionary = {}     # 原材质 instance_id -> 处理过的副本
static var _made: Dictionary = {}       # 副本 instance_id -> true，防重复处理


static func blend_material() -> ShaderMaterial:
	if _blend_material == null:
		_blend_material = ShaderMaterial.new()
		_blend_material.shader = BLEND_SHADER
		# 在角色本体（不透明）之后、地面贴花和影子（5~9）之前画；有深度测试，只落在角色身上。
		_blend_material.render_priority = 1
	return _blend_material


## 战斗里用：等模型 ready 之后再接（DarkRefinement 在宿主 ready 时才换身体材质，人族 Refined.gd 在 _ready 里才加装备网格）。
## 和 UnitPlanarShadow.attach() 一样走 deferred，**必须先于它调用**：两边都排队，先排的先跑，影子才能接在这里的副本后面。
static func attach(model: Node3D) -> void:
	if model == null:
		return
	if model.is_node_ready():
		apply.call_deferred(model)
	else:
		model.ready.connect(func() -> void: apply.call_deferred(model), CONNECT_ONE_SHOT)


static func apply(model: Node3D) -> int:
	if model == null or not is_instance_valid(model):
		return 0
	if model == null:
		return 0
	var changed := 0
	var stack: Array[Node] = [model]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		stack.append_array(node.get_children())
		if not node is MeshInstance3D:
			continue
		var mesh_instance := node as MeshInstance3D
		# 只处理导入的角色网格；脚底圆、光圈、状态图标是 PrimitiveMesh。
		if not mesh_instance.mesh is ArrayMesh:
			continue
		if mesh_instance.material_override != null:
			mesh_instance.material_override = blended(mesh_instance.material_override)
			changed += 1
			continue
		for surface in mesh_instance.mesh.get_surface_count():
			var material := mesh_instance.get_active_material(surface)
			if material != null:
				mesh_instance.set_surface_override_material(surface, blended(material))
				changed += 1
	return changed


static func blended(material: Material) -> Material:
	if _made.has(material.get_instance_id()):
		return material
	var key := material.get_instance_id()
	if _copies.has(key):
		return _copies[key]
	var copy := material.duplicate() as Material
	var tail := copy
	var has_outline := false
	while tail.next_pass != null:
		tail.next_pass = tail.next_pass.duplicate()
		tail = tail.next_pass
		var pass_material := tail as ShaderMaterial
		if pass_material != null and pass_material.shader == OUTLINE_SHADER:
			pass_material.set_shader_parameter("outline_color", OUTLINE_COLOR)
			has_outline = true
	if not has_outline:
		var outline := ShaderMaterial.new()
		outline.shader = OUTLINE_SHADER
		outline.set_shader_parameter("outline_color", OUTLINE_COLOR)
		outline.set_shader_parameter("outline_width", ADDED_OUTLINE_WIDTH)
		outline.set_shader_parameter("outline_max_pixels", ADDED_OUTLINE_MAX_PX)
		tail.next_pass = outline
		tail = outline
	tail.next_pass = blend_material()
	_copies[key] = copy
	_made[copy.get_instance_id()] = true
	return copy
