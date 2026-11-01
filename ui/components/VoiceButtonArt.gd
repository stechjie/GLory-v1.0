extends RefCounted

# One lazy-loaded atlas keeps the existing dedicated-server resource contract.
# The source has four equally sized quadrants, ordered mic-on/off, speaker-on/off.
const ATLAS_PATH := "res://assets/ui/voice/voice_controls_lowpoly.png"
static var _atlas: Texture2D
static var _icons := {}

static func texture_for(key: String) -> Texture2D:
	if _icons.has(key):
		return _icons[key]
	if _atlas == null:
		_atlas = load("res://assets/ui/voice/voice_controls_lowpoly.png") as Texture2D
	if _atlas == null:
		return null
	var col := 0
	var row := 0
	match key:
		"mic_on": pass
		"mic_off": col = 1
		"speaker_on": row = 1
		"speaker_off":
			col = 1
			row = 1
		_: return null
	var cell := Vector2(_atlas.get_width(), _atlas.get_height()) * 0.5
	var sprite := AtlasTexture.new()
	sprite.atlas = _atlas
	sprite.region = Rect2(Vector2(col, row) * cell, cell)
	sprite.filter_clip = true
	_icons[key] = sprite
	return sprite

static func use_art_as_button_background(button: Button) -> void:
	# The art already has its own frame; keep the Button's original hit region.
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		button.add_theme_stylebox_override(state, StyleBoxEmpty.new())
