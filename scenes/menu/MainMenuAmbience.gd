extends Control

const REF_SIZE := Vector2(1672.0, 941.0)
const TEX_BACKGROUND := preload("res://assets/ui/main_menu_live/background.png")
const TEX_RIVER_MASK := preload("res://assets/ui/main_menu_live/river_mask.png")
const TEX_WATERFALL_MASK := preload("res://assets/ui/main_menu_live/waterfall_mask.png")
const TEX_FOAM_MASK := preload("res://assets/ui/main_menu_live/foam_mask.png")
const TEX_NOISE := preload("res://assets/ui/main_menu_live/water_noise.png")
const TEX_BLUE_GLOW := preload("res://assets/ui/main_menu_live/glow_blue.png")
const TEX_WARM_GLOW := preload("res://assets/ui/main_menu_live/glow_warm.png")
const TEX_GOLD_PARTICLE := preload("res://assets/ui/main_menu_live/particle_gold.png")
const TEX_BLUE_PARTICLE := preload("res://assets/ui/main_menu_live/particle_blue.png")
const WATER_SHADER := preload("res://shaders/main_menu_water.gdshader")

var _glows: Array[Dictionary] = []
var _particles: Array[Dictionary] = []
var _elapsed := 0.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_water_layer("RiverSurface", TEX_RIVER_MASK, Vector2(1.0, 0.08), 0.055, 0.0026, 0.17, 0.54)
	_build_water_layer("WaterfallFlow", TEX_WATERFALL_MASK, Vector2(0.04, 1.0), 0.24, 0.0055, 0.36, 0.80)
	_build_water_layer("WaterfallFoam", TEX_FOAM_MASK, Vector2(0.25, 1.0), 0.15, 0.007, 0.44, 0.45)
	_add_glow("CrystalLeft", TEX_BLUE_GLOW, Vector2(343, 157), Vector2(128, 128), 0.23, 3.2, 0.0)
	_add_glow("CrystalBottomA", TEX_BLUE_GLOW, Vector2(744, 787), Vector2(72, 72), 0.18, 3.8, 1.1)
	_add_glow("CrystalBottomB", TEX_BLUE_GLOW, Vector2(1234, 790), Vector2(66, 66), 0.16, 3.5, 2.0)
	_add_glow("HouseWindows", TEX_WARM_GLOW, Vector2(1415, 151), Vector2(170, 150), 0.16, 4.6, 0.8)
	_add_glow("LampTop", TEX_WARM_GLOW, Vector2(1284, 150), Vector2(74, 74), 0.18, 3.7, 2.4)
	_add_glow("LampLeft", TEX_WARM_GLOW, Vector2(247, 204), Vector2(70, 70), 0.17, 4.1, 1.5)
	_add_glow("LampBottom", TEX_WARM_GLOW, Vector2(234, 713), Vector2(72, 72), 0.18, 3.9, 0.2)
	_build_particles()
	get_viewport().size_changed.connect(_layout_effects)
	_layout_effects()

func _process(delta: float) -> void:
	_elapsed += delta
	for item in _glows:
		var node := item.node as TextureRect
		var pulse := 0.5 + 0.5 * sin((_elapsed + float(item.phase)) * TAU / float(item.period))
		node.modulate.a = float(item.alpha) * lerpf(0.72, 1.0, pulse)
		var pulse_scale := lerpf(0.96, 1.045, pulse)
		_apply_rect(node, item.center, item.size * pulse_scale)
	for item in _particles:
		var node := item.node as TextureRect
		var life := fmod(_elapsed * float(item.speed) + float(item.phase), 1.0)
		var drift := sin(life * TAU + float(item.phase) * 5.0) * float(item.drift)
		var pos := item.origin as Vector2
		pos += Vector2(drift, -life * float(item.rise))
		var fade := sin(life * PI)
		node.modulate.a = fade * float(item.alpha)
		_apply_rect(node, pos, item.size)

func _build_water_layer(node_name: String, mask: Texture2D, direction: Vector2, speed: float, distortion: float, highlight: float, opacity: float) -> void:
	var rect := TextureRect.new()
	rect.name = node_name
	rect.texture = TEX_BACKGROUND
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var material := ShaderMaterial.new()
	material.shader = WATER_SHADER
	material.set_shader_parameter("mask_texture", mask)
	material.set_shader_parameter("noise_texture", TEX_NOISE)
	material.set_shader_parameter("flow_direction", direction.normalized())
	material.set_shader_parameter("speed", speed)
	material.set_shader_parameter("distortion", distortion)
	material.set_shader_parameter("highlight_strength", highlight)
	material.set_shader_parameter("overlay_opacity", opacity)
	rect.material = material
	add_child(rect)

func _add_glow(node_name: String, texture: Texture2D, center: Vector2, size: Vector2, alpha: float, period: float, phase: float) -> void:
	var glow := TextureRect.new()
	glow.name = node_name
	glow.texture = texture
	glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glow.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glow.modulate = Color(1, 1, 1, alpha)
	glow.set_pivot_offset(size * 0.5)
	add_child(glow)
	_glows.append({"node": glow, "center": center, "size": size, "alpha": alpha, "period": period, "phase": phase})

func _build_particles() -> void:
	var specs := [
		[Vector2(410, 648), TEX_GOLD_PARTICLE, 0.32], [Vector2(530, 705), TEX_GOLD_PARTICLE, 0.25],
		[Vector2(1040, 525), TEX_GOLD_PARTICLE, 0.28], [Vector2(1170, 680), TEX_GOLD_PARTICLE, 0.23],
		[Vector2(555, 165), TEX_BLUE_PARTICLE, 0.20], [Vector2(940, 155), TEX_BLUE_PARTICLE, 0.20],
		[Vector2(355, 865), TEX_BLUE_PARTICLE, 0.20], [Vector2(1100, 865), TEX_BLUE_PARTICLE, 0.22],
	]
	for i in specs.size():
		var spec: Array = specs[i]
		var particle := TextureRect.new()
		particle.name = "AmbientParticle%d" % i
		particle.texture = spec[1] as Texture2D
		particle.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		particle.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(particle)
		_particles.append({
			"node": particle, "origin": spec[0], "size": Vector2(18, 18), "alpha": spec[2],
			"speed": 0.075 + i * 0.006, "phase": float(i) / float(specs.size()),
			"rise": 70.0 + (i % 3) * 18.0, "drift": 10.0 + (i % 4) * 4.0,
		})

func _layout_effects() -> void:
	for item in _glows:
		_apply_rect(item.node, item.center, item.size)
	for item in _particles:
		_apply_rect(item.node, item.origin, item.size)

func _apply_rect(node: Control, center: Vector2, ref_size: Vector2) -> void:
	var viewport_size := get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	var scale_factor := minf(viewport_size.x / REF_SIZE.x, viewport_size.y / REF_SIZE.y)
	var origin := (viewport_size - REF_SIZE * scale_factor) * 0.5
	var scaled_size := ref_size * scale_factor
	node.position = origin + center * scale_factor - scaled_size * 0.5
	node.size = scaled_size
