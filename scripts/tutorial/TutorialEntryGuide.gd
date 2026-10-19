extends Control

# Local first-match prompts. The whole overlay passes input through to the
# real menu/lobby buttons; only the highlighted control handles the tap.
const FocusShader := preload("res://shaders/tutorial_focus_mask.gdshader")
const GuideLight := preload("res://scripts/tutorial/TutorialGuideLight.gd")
const DogWelcome := preload("res://assets/ui/tutorial/dog_welcome.png")
const DogGuide := preload("res://assets/ui/tutorial/dog_guide.png")
const DogExplain := preload("res://assets/ui/tutorial/dog_explain.png")

var _target: Control
var _phase := "menu"
var _dim: ColorRect
var _light
var _dog: TextureRect
var _bubble: PanelContainer
var _label: Label


func configure(target: Control, phase: String) -> void:
	_target = target
	_phase = phase
	if is_inside_tree():
		_update_phase()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim = ColorRect.new()
	_dim.color = Color.WHITE
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var material := ShaderMaterial.new()
	material.shader = FocusShader
	material.set_shader_parameter("dim_color", Color(0.015, 0.02, 0.025, 0.72))
	_dim.material = material
	add_child(_dim)
	_light = GuideLight.new()
	_light.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_light)
	_dog = TextureRect.new()
	_dog.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_dog.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_dog.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_dog)
	_bubble = PanelContainer.new()
	_bubble.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var plate := StyleBoxFlat.new()
	plate.bg_color = Color(0.045, 0.065, 0.07, 0.95)
	plate.border_color = Color(0.96, 0.75, 0.29)
	plate.set_border_width_all(2)
	plate.set_corner_radius_all(14)
	plate.set_content_margin_all(16)
	_bubble.add_theme_stylebox_override("panel", plate)
	add_child(_bubble)
	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.custom_minimum_size = Vector2(315, 0)
	_label.add_theme_font_size_override("font_size", 20)
	_label.add_theme_color_override("font_color", Color("fff1d0"))
	_bubble.add_child(_label)
	_update_phase()


func _process(_delta: float) -> void:
	if _target == null or not is_instance_valid(_target) or not _target.is_visible_in_tree():
		visible = false
		return
	visible = true
	var overlay_rect := get_global_rect()
	var target := _target.get_global_rect()
	target.position -= overlay_rect.position
	var extent := Vector2(maxf(1.0, size.x), maxf(1.0, size.y))
	var focus := target.grow(10.0)
	(_dim.material as ShaderMaterial).set_shader_parameter("hole", Vector4(
		focus.position.x / extent.x, focus.position.y / extent.y,
		focus.size.x / extent.x, focus.size.y / extent.y))
	(_dim.material as ShaderMaterial).set_shader_parameter("hole_on", 1.0)
	_bubble.size = Vector2(347, 112)
	var safe := SafeArea.rect()
	safe.position -= overlay_rect.position
	safe = safe.intersection(Rect2(Vector2.ZERO, size)).grow(-20.0)
	if safe.size.x < _bubble.size.x or safe.size.y < _bubble.size.y:
		safe = Rect2(Vector2(20, 20), size - Vector2(40, 40))
	var above := target.position.y > size.y * 0.48
	var y := target.position.y - _bubble.size.y - 36 if above else target.end.y + 36
	var x := target.get_center().x - _bubble.size.x * 0.5
	_bubble.position = Vector2(clampf(x, safe.position.x, safe.end.x - _bubble.size.x),
		clampf(y, safe.position.y, safe.end.y - _bubble.size.y))
	var side := clampf(size.y * 0.18, 95.0, 145.0)
	_dog.size = Vector2.ONE * side
	var dog_x: float = _bubble.position.x + _bubble.size.x + 8.0
	if dog_x + side > safe.end.x:
		dog_x = _bubble.position.x - side - 8.0
	_dog.position = Vector2(clampf(dog_x, safe.position.x, safe.end.x - side),
		clampf(_bubble.position.y + _bubble.size.y - side, safe.position.y, safe.end.y - side))
	_light.aim(_dog.position + _dog.size * Vector2(0.65, 0.68), target,
		PlayerProfile.reduced_motion_enabled)


func _update_phase() -> void:
	if _label == null:
		return
	var english := LocaleManager.get_locale().begins_with("en")
	match _phase:
		"result_menu":
			_label.text = "Woof! You're Lv2 now. Return to the lobby and tap your portrait for your first Divine piece." if english else \
				"汪！你升到 Lv2 啦！回大厅点头像，看看第一枚神族棋子。"
			_dog.texture = DogWelcome
		"reward_avatar":
			_label.text = "Woof! Your first match brought you to Lv2. Tap your portrait to see the reward." if english else \
				"汪！第一场打完升到 Lv2 啦，点头像去看看奖励！"
			_dog.texture = DogWelcome
		"reward_reveal":
			_label.text = "Tap to reveal your first Divine piece!" if english else \
				"点一下，让第一枚神族棋子闪亮登场！"
			_dog.texture = DogGuide
		"reward_claim":
			_label.text = "You have 1 of 8 Divine pieces. Collect all 8 to use this race." if english else \
				"神族已收集 1/8。集齐 8 枚，才能带神族出战。先收下奖励吧！"
			_dog.texture = DogExplain
		"reward_prep":
			_label.text = "Divine is 1/8. Collect all 8 to use it. Now visit Prep to choose a pet and view your pieces." if english else \
				"神族已收集 1/8，集齐 8 枚才能使用。现在点击备战，去选宠物、查看种族棋子！"
			_dog.texture = DogGuide
		"starter_pet":
			_label.text = "Pick the pet you like. It will join your next match." if english else \
				"先挑一只喜欢的宠物，它会陪你参加下一场。"
			_dog.texture = DogWelcome
		"race_tab":
			_label.text = "Pet chosen! Open Races to see your pieces." if english else \
				"宠物选好啦！点「种族」看看你收集的棋子。"
			_dog.texture = DogGuide
		"god_progress":
			_label.text = "Human is ready. Divine is 1/8; collect the other 7 before selecting it for a match." if english else \
				"人族已经能用。神族现在是 1/8，集齐剩下 7 枚后才能选择出战。"
			_dog.texture = DogExplain
		"lobby_mode":
			_label.text = "Woof! Choose Seedling for your first 13-round match." if english else \
				"汪！先点「青苗」，用 13 回合认识棋盘。"
			_dog.texture = DogGuide
		"lobby_start":
			_label.text = "Great! Match with AI to start your first lesson." if english else \
				"选好了！点击「匹配 AI」，我们一起开始教学。"
			_dog.texture = DogWelcome
		_:
			_label.text = "Woof! Tap Casual. I'll guide your first match." if english else \
				"汪！先点「休闲」，我陪你打第一场。"
			_dog.texture = DogWelcome
