extends Control

const PULSE_DURATION := 1.20

var _material: ShaderMaterial
var _phase := 0.0


func setup(texture: Texture2D, glow_shader: Shader) -> void:
	name = "MoneyBagAttentionGlow"
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var glow_image := TextureRect.new()
	glow_image.name = "GoldenSilhouetteGlow"
	glow_image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glow_image.texture = texture
	glow_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glow_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	glow_image.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	glow_image.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_material = ShaderMaterial.new()
	_material.shader = glow_shader
	glow_image.material = _material
	add_child(glow_image)

	pivot_offset = size * 0.5
	resized.connect(_update_pivot)
	set_process(true)


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_phase = fmod(_phase + delta / PULSE_DURATION, 1.0)
	var breath := 0.5 + 0.5 * sin(_phase * TAU - PI * 0.5)
	var accent := pow(maxf(0.0, sin(_phase * TAU)), 8.0)
	var strength := 0.72 + breath * 0.48 + accent * 0.34
	_material.set_shader_parameter("glow_strength", strength)
	_material.set_shader_parameter("outer_radius", 4.2 + breath * 2.2)
	scale = Vector2.ONE * (0.98 + breath * 0.07)
	modulate.a = 0.82 + breath * 0.18


func _update_pivot() -> void:
	pivot_offset = size * 0.5
