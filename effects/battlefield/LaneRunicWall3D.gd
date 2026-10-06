@tool
extends Node3D
## Editable, texture-free lane ward. All dimensions are world units.
## Only presentation: no collision, targeting, replay or RNG state is changed.

signal release_finished

const BORDER_OVERLAP := 0.75 # Visual continuation into the arena border; simulation endpoints stay unchanged.
const VIEW_SHEAR := 7.0 / 7.4 # Fixed battle camera Z/Y: keep both visible ends square across the wall width.
const WARD_SHADER := preload("res://effects/battlefield/lane_ward.gdshader")
@export_range(1.0, 16.0) var length := 8.8:
	set(value):
		if is_equal_approx(length, value): return
		length = value
		if is_inside_tree(): rebuild()
@export_range(0.6, 1.8) var height := 1.25:
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
	var visual_length := length + BORDER_OVERLAP * 2.0
	_material = ShaderMaterial.new()
	_material.shader = WARD_SHADER
	_material.set_shader_parameter("low_quality", _low_quality)
	_material.set_shader_parameter("wall_length", visual_length)
	# A narrow, constant cross-section keeps both lane walls straight and parallel.
	# One continuous surface, no transparent box caps or overlapping glass layers.
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	const SPANS := 48
	const ARCH_STEPS := 8
	for i in SPANS:
		for j in ARCH_STEPS:
			for corner in [Vector2i(0,0), Vector2i(1,0), Vector2i(1,1), Vector2i(0,0), Vector2i(1,1), Vector2i(0,1)]:
				var u := float(i + corner.x) / SPANS
				var t := float(j + corner.y) / ARCH_STEPS
				var rise := sin(t * PI)
				var crest := height
				surface.set_uv(Vector2(u, rise))
				surface.add_vertex(Vector3((t - 0.5) * 0.30, 0.035 + rise * crest,
					(u - 0.5) * visual_length + rise * crest * VIEW_SHEAR))
	surface.generate_normals()
	var membrane := MeshInstance3D.new()
	membrane.name = "ContinuousMagicMembrane"
	membrane.mesh = surface.commit()
	membrane.material_override = _material
	membrane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_body.add_child(membrane)
	visible = not _released and not _preview_hidden

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
