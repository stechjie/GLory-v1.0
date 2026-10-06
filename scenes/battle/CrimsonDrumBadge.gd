extends Control

# Compact HUD cue for the War Drum's paired attack and speed layers.
# It lives in the unit's 2D root, so it follows the HP bar and death fade.
const MAX_STACKS := 15
const RED := Color(1.0, 0.34, 0.27)
const NOTE_REST := Vector2(1, -2)

var _stacks := 0
var _note: Label
var _count: Label
var _shake: Tween


func _ready() -> void:
	name = "CrimsonDrumBadge"
	position = Vector2(-35, 2)
	size = Vector2(39, 20)
	z_index = 22
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_note = Label.new()
	_note.name = "Note"
	_note.position = NOTE_REST
	_note.size = Vector2(15, 22)
	_note.text = "♪"
	_note.add_theme_font_size_override("font_size", 17)
	_note.add_theme_color_override("font_color", RED)
	_note.add_theme_color_override("font_outline_color", Color(0.18, 0.025, 0.025, 1.0))
	_note.add_theme_constant_override("outline_size", 3)
	_note.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_note)

	_count = Label.new()
	_count.name = "Count"
	_count.position = Vector2(16, 0)
	_count.size = Vector2(23, 19)
	_count.text = "×0"
	_count.add_theme_font_size_override("font_size", 11)
	_count.add_theme_color_override("font_color", RED)
	_count.add_theme_color_override("font_outline_color", Color(0.12, 0.025, 0.02, 1.0))
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
	if _shake != null and _shake.is_running():
		_shake.kill()
	_note.position = NOTE_REST
	if _stacks == 0:
		return
	_count.text = "×%d" % _stacks
	if not gained:
		return
	# Only the note jolts; the number stays fixed so the new count remains legible.
	_note.position = NOTE_REST + Vector2(-2, 0)
	_shake = create_tween()
	_shake.tween_property(_note, "position", NOTE_REST + Vector2(2, -1), 0.045)
	_shake.tween_property(_note, "position", NOTE_REST + Vector2(-1, 1), 0.055)
	_shake.tween_property(_note, "position", NOTE_REST + Vector2(1, -1), 0.05)
	_shake.tween_property(_note, "position", NOTE_REST, 0.07)
