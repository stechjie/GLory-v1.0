extends VFXBlockRoot
class_name VFXSpriteFlipbook3D
const SHADER_CACHE := preload("res://effects/vfx3d/core/VFXShaderCache.gd")

const FLIPBOOK_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
uniform sampler2D atlas_texture : source_color;
uniform vec2 atlas_grid = vec2(4.0, 4.0);
uniform float frame = 0.0;
uniform vec4 tint : source_color = vec4(1.0);
uniform float opacity = 1.0;
uniform float billboard_enabled = 1.0;
void vertex() {
    if (billboard_enabled > 0.5) {
        MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
    }
}
void fragment() {
    float column = mod(frame, atlas_grid.x);
    float row = floor(frame / atlas_grid.x);
    vec2 atlas_uv = (UV + vec2(column, row)) / atlas_grid;
    vec4 tex = texture(atlas_texture, atlas_uv);
    vec2 p = abs(UV - vec2(0.5)) * 2.0;
    float card_fade = smoothstep(1.0, 0.72, max(p.x, p.y));
    float alpha = tex.a * card_fade * opacity;
    ALBEDO = tex.rgb * tint.rgb;
    EMISSION = ALBEDO * (1.5 + tex.a * 1.8);
    ALPHA = alpha * tint.a;
}
"""

var _material: ShaderMaterial
var _frame_count := 16
var _frame_rate := 18.0
var _elapsed := 0.0
var _loop := false
var _playing := false
var _duration := 0.9

func play_profile(profile: VFXProfile3D, context: Dictionary) -> void:
	var params: Dictionary = profile.parameters if profile != null else {}
	var texture: Texture2D
	var texture_path := str(params.get("texture_path", ""))
	if not texture_path.is_empty():
		texture = vfx_texture(texture_path)
	play_flipbook(
		context.get("target", Vector3.ZERO), texture,
		int(params.get("columns", 4)), int(params.get("rows", 4)), int(params.get("frame_count", 16)),
		bool(params.get("loop", false)), bool(params.get("random_start", true)),
		float(params.get("speed_min", 14.0)), float(params.get("speed_max", 21.0)),
		bool(params.get("billboard", true)), profile.duration if profile != null else 0.9,
		profile.main_color if profile != null else Color.WHITE, profile.size if profile != null else 1.0)

func play_flipbook(at: Vector3, texture: Texture2D, columns: int, rows: int, frame_count: int, loop: bool, random_start: bool, speed_min: float, speed_max: float, billboard: bool, duration: float, color: Color, size: float) -> void:
	begin()
	position = at + Vector3(0.0, 0.42, 0.0)
	_frame_count = maxi(1, mini(frame_count, columns * rows))
	_frame_rate = randf_range(speed_min, speed_max)
	_elapsed = randf_range(0.0, float(_frame_count) / _frame_rate) if random_start else 0.0
	_loop = loop
	_duration = maxf(duration, 0.05)
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	var node := MeshInstance3D.new()
	node.name = "FlipbookSprite"
	node.mesh = quad
	_material = ShaderMaterial.new()
	_material.shader = SHADER_CACHE.get_shader(FLIPBOOK_SHADER)
	_material.set_shader_parameter("atlas_texture", texture if texture != null else _make_test_atlas(columns, rows))
	_material.set_shader_parameter("atlas_grid", Vector2(columns, rows))
	_material.set_shader_parameter("frame", 0.0)
	_material.set_shader_parameter("tint", color)
	_material.set_shader_parameter("opacity", vfx_alpha)
	_material.set_shader_parameter("billboard_enabled", 1.0 if billboard else 0.0)
	node.material_override = _material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	_playing = true
	set_process(true)
	await get_tree().create_timer(_duration).timeout
	if not _loop:
		_playing = false
		finish()

func _process(delta: float) -> void:
	if not _playing or _material == null:
		return
	_elapsed += delta
	var frame_index := int(floor(_elapsed * _frame_rate))
	if _loop:
		frame_index %= _frame_count
	else:
		frame_index = mini(frame_index, _frame_count - 1)
	_material.set_shader_parameter("frame", float(frame_index))

func set_vfx_alpha(value: float) -> void:
	super.set_vfx_alpha(value)
	if _material != null:
		_material.set_shader_parameter("opacity", vfx_alpha)

func _make_test_atlas(columns: int, rows: int) -> ImageTexture:
	var cell := 32
	var image := Image.create(columns * cell, rows * cell, false, Image.FORMAT_RGBA8)
	for frame_index in range(columns * rows):
		var column := frame_index % columns
		var row := int(frame_index / columns)
		var phase := float(frame_index) / maxf(float(columns * rows - 1), 1.0)
		for y in cell:
			for x in cell:
				var p := Vector2(float(x) / float(cell - 1), float(y) / float(cell - 1)) * 2.0 - Vector2.ONE
				var radius := p.length()
				var wobble := sin(atan2(p.y, p.x) * 7.0 + phase * 9.0) * 0.12
				var alpha := smoothstep(1.0 + wobble, 0.34 + phase * 0.18, radius)
				var rgb := Color(0.35 + phase * 0.4, 0.72 + phase * 0.2, 1.0, alpha)
				image.set_pixel(column * cell + x, row * cell + y, rgb)
	return ImageTexture.create_from_image(image)
