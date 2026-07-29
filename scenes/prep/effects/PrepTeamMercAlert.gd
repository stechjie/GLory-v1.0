extends Control

const FRAME_SIZE := Vector2(256.0, 256.0)
const FRAME_COUNT := 6
const FRAME_TIME := 0.08
const FLASH_DURATION := FRAME_COUNT * FRAME_TIME

var _button: BaseButton
var _atlas_texture: Texture2D
var _swords: TextureRect
var _frame_texture: AtlasTexture
var _unread_dot: Panel
var _elapsed := FLASH_DURATION


func setup(button: BaseButton, atlas_texture: Texture2D) -> void:
	_button = button
	_atlas_texture = atlas_texture
	name = "TeamMercSummonAlert"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	z_index = 30

	_frame_texture = AtlasTexture.new()
	_frame_texture.atlas = _atlas_texture
	_frame_texture.region = Rect2(Vector2.ZERO, FRAME_SIZE)

	_swords = TextureRect.new()
	_swords.name = "CrossedSwords"
	_swords.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_swords.texture = _frame_texture
	_swords.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_swords.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	# Deliberately exceed the magnifier silhouette so the summon notice reads
	# as an event overlay instead of another small symbol inside the button.
	_swords.anchor_left = -0.13
	_swords.anchor_top = -0.16
	_swords.anchor_right = 1.13
	_swords.anchor_bottom = 1.10
	_swords.visible = false
	add_child(_swords)

	_unread_dot = Panel.new()
	_unread_dot.name = "UnreadDot"
	_unread_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_unread_dot.anchor_left = 1.0
	_unread_dot.anchor_top = 0.0
	_unread_dot.anchor_right = 1.0
	_unread_dot.anchor_bottom = 0.0
	_unread_dot.offset_left = -27.0
	_unread_dot.offset_top = 14.0
	_unread_dot.offset_right = -11.0
	_unread_dot.offset_bottom = 30.0
	var dot_style := StyleBoxFlat.new()
	dot_style.bg_color = Color(0.96, 0.05, 0.025, 1.0)
	dot_style.border_color = Color(1.0, 0.60, 0.10, 1.0)
	dot_style.set_border_width_all(2)
	dot_style.set_corner_radius_all(8)
	dot_style.shadow_color = Color(1.0, 0.03, 0.01, 0.72)
	dot_style.shadow_size = 5
	_unread_dot.add_theme_stylebox_override("panel", dot_style)
	_unread_dot.visible = false
	add_child(_unread_dot)

	set_process(false)
	call_deferred("_prepare_button_pivot")


func notify_summon() -> void:
	if _button == null or _swords == null:
		return
	_unread_dot.visible = true
	_elapsed = 0.0
	_swords.visible = true
	_swords.modulate = Color.WHITE
	_set_frame(0)
	_prepare_button_pivot()
	set_process(true)


func mark_seen() -> void:
	if _unread_dot != null:
		_unread_dot.visible = false


func has_unread() -> bool:
	return _unread_dot != null and _unread_dot.visible


func is_flashing() -> bool:
	return _elapsed < FLASH_DURATION


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed >= FLASH_DURATION:
		_finish_flash()
		return

	var frame := mini(int(_elapsed / FRAME_TIME), FRAME_COUNT - 1)
	_set_frame(frame)

	# Two compact pulses over 0.48 seconds. Scale and glow always return to neutral.
	var pulse := maxf(0.0, sin(_elapsed / FLASH_DURATION * TAU * 2.0))
	_button.scale = Vector2.ONE * (1.0 + 0.08 * pulse)
	_swords.modulate = Color(1.0, 0.72 + 0.28 * pulse, 0.66 + 0.34 * pulse, 0.86 + 0.14 * pulse)


func _set_frame(frame: int) -> void:
	var column := frame % 3
	var row := frame / 3
	_frame_texture.region = Rect2(Vector2(column, row) * FRAME_SIZE, FRAME_SIZE)


func _prepare_button_pivot() -> void:
	if _button != null:
		_button.pivot_offset = _button.size * 0.5


func _finish_flash() -> void:
	_elapsed = FLASH_DURATION
	set_process(false)
	if _button != null:
		_button.scale = Vector2.ONE
	if _swords != null:
		_swords.visible = false
		_swords.modulate = Color.WHITE
