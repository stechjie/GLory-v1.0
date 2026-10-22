extends Control
func _ready():
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg=TextureRect.new()
	bg.texture=load("res://assets/ui/room_v2/background.png")
	bg.expand_mode=TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.modulate=Color(.4,.4,.46)
	add_child(bg)
