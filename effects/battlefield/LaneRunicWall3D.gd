@tool
extends Node3D
## Editable, texture-free lane ward. All dimensions are world units.
## Only presentation: no collision, targeting, replay or RNG state is changed.

signal release_finished

const WARD_SHADER := preload("res://effects/battlefield/lane_ward.gdshader")
@export_range(1.0, 16.0) var length := 8.8:
	set(value):
		if is_equal_approx(length, value): return
		length = value
		if is_inside_tree(): rebuild()
@export_range(0.2, 1.2) var height := 0.65:
	set(value):
		height = value
		if is_inside_tree(): rebuild()

var _released := false
var _low_quality := false
# ★ 加载过场按住用（见 set_preview_hidden）。默认 false ⇒ 不改变任何原有行为。
var _preview_hidden := false
var _age := 0.0
var _material: ShaderMaterial
var _body: Node3D

func _ready() -> void:
	rebuild()

func rebuild() -> void:
	if _body != null:
		remove_child(_body)
		_body.queue_free()
	_body = Node3D.new()
	_body.name = "EditableWardGeometry"
	add_child(_body)
	_material = ShaderMaterial.new()
	_material.shader = WARD_SHADER
	_material.set_shader_parameter("low_quality", _low_quality)
	_material.set_shader_parameter("half_height", height * 0.415)
	var stone := StandardMaterial3D.new()
	stone.vertex_color_use_as_albedo = true
	stone.roughness = 0.9
	var stone_surface := SurfaceTool.new()
	stone_surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Continuous low plinth with chamfered silhouette, not a pile of crystals.
	_prism(stone_surface, Vector3(0, 0.018, 0), Vector3(0.085, 0.035, length), Color("58655c"))
	for z in [-length * 0.5, length * 0.5]:
		_prism(stone_surface, Vector3(0, 0.09, z), Vector3(0.40, 0.14, 0.34), Color("47534d"))
		_prism(stone_surface, Vector3(0, height * 0.47, z), Vector3(0.25, height * 0.82, 0.22), Color("778274"))
		_prism(stone_surface, Vector3(0, height * 0.90, z), Vector3(0.32, 0.075, 0.28), Color("8d947e"))
		_prism(stone_surface, Vector3(0, height * 0.96, z), Vector3(0.22, 0.035, 0.20), Color("ae9b68"))
	stone_surface.generate_normals()
	var solid := MeshInstance3D.new()
	solid.name = "ChamferedStoneAnchors"
	solid.mesh = stone_surface.commit()
	solid.material_override = stone
	solid.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_body.add_child(solid)
	# A shallow volume remains readable from the fixed, nearly edge-on camera.
	var core := BoxMesh.new()
	core.size = Vector3(0.26, height * 0.83, length)
	var membrane := MeshInstance3D.new()
	membrane.name = "ContinuousMagicMembrane"
	membrane.mesh = core
	membrane.position.y = height * 0.5 + 0.05
	membrane.material_override = _material
	membrane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_body.add_child(membrane)
	# The gold inlay and cyan rune cores share one merged unshaded surface.
	var inlay_surface := SurfaceTool.new()
	inlay_surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for x in [-0.07, 0.07]:
		_prism(inlay_surface, Vector3(x, 0.035, 0), Vector3(0.013, 0.012, length), Color("b7b67d"))
	for z in [-length * 0.5, length * 0.5]:
		_crystal(inlay_surface, Vector3(0, height + 0.07, z))
	inlay_surface.generate_normals()
	var inlay := MeshInstance3D.new()
	inlay.name = "RuneInlay"
	inlay.mesh = inlay_surface.commit()
	var inlay_material := StandardMaterial3D.new()
	inlay_material.vertex_color_use_as_albedo = true
	inlay_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	inlay.material_override = inlay_material
	inlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_body.add_child(inlay)
	visible = not _released and not _preview_hidden

func _prism(surface: SurfaceTool, center: Vector3, size: Vector3, color: Color) -> void:
	# Eight-sided chamfered box, flat normals preserve the battlefield's faceting.
	var ring: Array[Vector2] = []
	var x := size.x * 0.5
	var z := size.z * 0.5
	var bevel := minf(x, z) * 0.32
	ring.assign([Vector2(-x+bevel,-z), Vector2(x-bevel,-z), Vector2(x,-z+bevel), Vector2(x,z-bevel), Vector2(x-bevel,z), Vector2(-x+bevel,z), Vector2(-x,z-bevel), Vector2(-x,-z+bevel)])
	for i in 8:
		var a := Vector3(ring[i].x, -size.y*0.5, ring[i].y) + center
		var b := Vector3(ring[(i+1)%8].x, -size.y*0.5, ring[(i+1)%8].y) + center
		var c := b + Vector3.UP*size.y
		var d := a + Vector3.UP*size.y
		surface.set_color(color)
		for point in [a,b,c,a,c,d,center+Vector3.UP*size.y*0.5,d,c,center-Vector3.UP*size.y*0.5,b,a]:
			surface.add_vertex(point)

func _crystal(surface: SurfaceTool, center: Vector3) -> void:
	var colors := [Color("79cdbd"), Color("b0ecda"), Color("4a9f9c"), Color("d2f1d5")]
	for i in 4:
		var angle := float(i) * PI * 0.5
		var a := center + Vector3(cos(angle), 0, sin(angle)) * 0.065
		var b := center + Vector3(cos(angle + PI*0.5), 0, sin(angle + PI*0.5)) * 0.065
		surface.set_color(colors[i])
		for point in [center+Vector3.UP*0.14, b, a, center-Vector3.UP*0.055, a, b]:
			surface.add_vertex(point)

func fit_between(a: Vector3, b: Vector3) -> void:
	position = (a + b) * 0.5
	length = absf(b.z - a.z)

func set_low_quality(enabled: bool) -> void:
	_low_quality = enabled
	if _material: _material.set_shader_parameter("low_quality", enabled)

## ★ 加载过场按住：读条期这道墙还没被 BattleArena._update_3v3_dividers() 摆位，
## 停在原点会叠成画面正中的一道墙。true ⇒ 强制不显示（连 rebuild()/play_loop()
## 都过这个标志，否则会被它们的 visible=true 盖掉）。撤销由 BattleArena 在摆位
## 那一帧调 set_preview_hidden(false) 完成。默认 false ⇒ 不改变任何原有行为。
func set_preview_hidden(enabled: bool) -> void:
	_preview_hidden = enabled
	visible = not _released and not enabled

func play_loop(_start_frame := 0) -> void:
	_released = false
	_age = 0.0
	# ★ 加载过场按住期间不许在这里点亮，否则会在 play_loop() 里把墙重新放出来。
	visible = not _preview_hidden
	if _body: _body.scale = Vector3.ONE
	if _material: _material.set_shader_parameter("dissolve", 0.0)
	set_process(true)

func play_release() -> void:
	if _released: return
	_released = true
	# Traversal opens on this replay frame: no lingering sheet, posts or floor
	# stripe may still read as a closed wall while a unit starts crossing.
	visible = false
	set_process(false)
	release_finished.emit()

func is_released() -> bool:
	return _released

func _process(delta: float) -> void:
	if Engine.is_editor_hint(): return
	_age += delta
	if _material:
		_material.set_shader_parameter("emphasis", 1.0 - smoothstep(0.4, 0.85, _age))
	if _age >= 0.85:
		set_process(false)
