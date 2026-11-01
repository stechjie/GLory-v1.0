extends RefCounted

# One lazy-loaded atlas keeps the existing dedicated-server resource contract.
# The four plates are offset within their atlas quadrants. Normalize their
# visible frames while keeping the original 627px canvas and button hit boxes.
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
	var origin: Vector2
	match key:
		"mic_on": origin = Vector2(84, 76)
		"mic_off": origin = Vector2(654, 76)
		"speaker_on": origin = Vector2(84, 654)
		"speaker_off": origin = Vector2(654, 654)
		_: return null
	var sprite := AtlasTexture.new()
	sprite.atlas = _atlas
	# Each 512px region contains the whole gold frame. Equal transparent margins
	# center it on the old 627px canvas without enlarging the visible button.
	sprite.region = Rect2(origin, Vector2(512, 512))
	sprite.margin = Rect2(Vector2(57.5, 57.5), Vector2(115, 115))
	sprite.filter_clip = true
	_icons[key] = sprite
	return sprite

static func use_art_as_button_background(button: Button) -> void:
	# The art already has its own frame; keep the Button's original hit region.
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		button.add_theme_stylebox_override(state, StyleBoxEmpty.new())
