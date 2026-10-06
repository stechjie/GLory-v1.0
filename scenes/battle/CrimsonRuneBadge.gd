extends Control
class_name CrimsonRuneBadge

# Presentation-only HUD for the current battle's nine War Rune stacks.
const LANTERN := preload("res://assets/ui/race_logos/crimson_lantern.png")
const LANTERN_SHADER := preload("res://shaders/crimson_rune_lantern.gdshader")
const FLAME_SHADER := preload("res://shaders/crimson_rune_flame.gdshader")
const MAX_STACKS := 9
const TEXT_RED := Color(1.0, 0.32, 0.24)
const REST_POSITION := Vector2(2.0, -5.0)
const FINAL_POSITION := Vector2(13.0, -5.0)

var _stacks := 0
var _icon_layer: Control
var _icon: TextureRect
var _count: Label
var _flame: ColorRect
var _icon_material: ShaderMaterial
var _glow_material: ShaderMaterial
var _flame_material: ShaderMaterial
var _pulse: Tween


func _ready() -> void:
	name = "CrimsonRuneBadge"
	position = Vector2(79, 0)
	size = Vector2(46, 32)
	z_index = 23
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false

	_icon_layer = Control.new()
	_icon_layer.name = "LanternLayer"
	_icon_layer.position = REST_POSITION
	_icon_layer.size = Vector2(25, 38)
	_icon_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_icon_layer)

	_flame = ColorRect.new()
	_flame.name = "FinalFlame"
	_flame.position = Vector2(-4, -3)
	_flame.size = Vector2(33, 44)
	_flame.color = Color.WHITE
	_flame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flame_material = ShaderMaterial.new()
	_flame_material.shader = FLAME_SHADER
	_flame_material.set_shader_parameter("phase", float(get_instance_id() % 37) * 0.19)
	_flame_material.set_shader_parameter("intensity", 0.0)
	_flame.material = _flame_material
	_flame.visible = false
	_icon_layer.add_child(_flame)

	var glow := TextureRect.new()
	glow.name = "LanternGlow"
	glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glow.stretch_mode = TextureRect.STRETCH_SCALE
	glow.texture = LANTERN
	glow.position = Vector2(0, 0)
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_glow_material = ShaderMaterial.new()
	_glow_material.shader = LANTERN_SHADER
	_glow_material.set_shader_parameter("glow_pass", true)
	_glow_material.set_shader_parameter("glow_strength", 0.0)
	glow.material = _glow_material
	_icon_layer.add_child(glow)
	glow.size = Vector2(25, 38)

	_icon = TextureRect.new()
	_icon.name = "Lantern"
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_SCALE
	_icon.texture = LANTERN
	_icon.position = Vector2(4, 3)
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon_material = ShaderMaterial.new()
	_icon_material.shader = LANTERN_SHADER
	_icon.material = _icon_material
	_icon_layer.add_child(_icon)
	_icon.size = Vector2(17, 32)

	_count = Label.new()
	_count.name = "Count"
	_count.position = Vector2(25, 7)
	_count.size = Vector2(22, 19)
	_count.add_theme_font_size_override("font_size", 12)
	_count.add_theme_color_override("font_color", TEXT_RED)
	_count.add_theme_color_override("font_outline_color", Color(0.16, 0.015, 0.015))
	_count.add_theme_constant_override("outline_size", 3)
	_count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_count)


func set_stacks(value: int) -> void:
	var next_stacks := clampi(value, 0, MAX_STACKS)
	if next_stacks == _stacks:
		return
	var gained := next_stacks > _stacks
	_stacks = next_stacks
	visible = _stacks > 0
	if _pulse != null and _pulse.is_running():
		_pulse.kill()
	_icon_layer.scale = Vector2.ONE
	_icon_layer.position = FINAL_POSITION if _stacks >= MAX_STACKS else REST_POSITION
	if _stacks == 0:
		return

	_count.visible = _stacks < MAX_STACKS
	_count.text = "×%d" % _stacks
	var tier := 0
	if _stacks >= 9:
		tier = 3
	elif _stacks >= 6:
		tier = 2
	elif _stacks >= 3:
		tier = 1
	_icon_material.set_shader_parameter("brightness", float(tier))
	_glow_material.set_shader_parameter("brightness", float(tier))
	_glow_material.set_shader_parameter("glow_strength", [0.0, 0.38, 0.69, 0.90][tier])
	_flame.visible = tier == 3
	_flame_material.set_shader_parameter("intensity", 1.0 if tier == 3 else 0.0)
	if not gained:
		return

	var breakthrough := _stacks in [3, 6, 9]
	_icon_layer.pivot_offset = Vector2(12.5, 19.0)
	_icon_layer.scale = Vector2.ONE * (1.22 if breakthrough else 1.10)
	_icon_material.set_shader_parameter("flash", 1.0 if breakthrough else 0.38)
	_pulse = create_tween().set_parallel(true)
	_pulse.tween_property(_icon_layer, "scale", Vector2.ONE, 0.32 if breakthrough else 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_pulse.tween_method(_set_flash, 1.0 if breakthrough else 0.38, 0.0, 0.35 if breakthrough else 0.19)


func _set_flash(amount: float) -> void:
	_icon_material.set_shader_parameter("flash", amount)
