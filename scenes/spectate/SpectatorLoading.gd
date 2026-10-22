extends Control

# 观战：第 1 回合备战期的等待画面（2026-10-22 定）。
#
# 第 1 回合还没有「上一回合」可看（延迟一回合），观战者看这页：背景 + 宠物跑进度条。
# 进度跟服务器的备战倒计时走（第 1 回合最多 35 秒）；选手都提早准备的话服务器提早开战，
# Main 收到下一份观战状态就切走这页 —— 进度条不会走满才放人。
#
# 宠物和进度条与战斗读条同一套（BattleScreen._attach_prepare_pet）：观战者自己的出战宠物。

const PetPreview := preload("res://scripts/pets/PetPreview.gd")
const Tokens := preload("res://ui/theme/GloryTokens.gd")
const TEX_BACKGROUND := preload("res://assets/ui/room_v2/background.png")

const BAR_WIDTH := 560.0
const BAR_HEIGHT := 14.0
const PET_SIZE := Vector2(72, 72)

var _bar: ProgressBar
var _pet: Control
var _deadline := -1.0   # 本机时钟上的倒计时终点
var _total := 35.0


func _ready() -> void:
	var bg := TextureRect.new()
	bg.texture = TEX_BACKGROUND
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.modulate = Color(0.55, 0.55, 0.6)
	add_child(bg)
	var title := Label.new()
	title.text = _t("选手正在备战，对局即将开始…", "Players are preparing — the match is about to start…")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	title.offset_left = -400
	title.offset_right = 400
	title.offset_top = -80
	title.offset_bottom = -40
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", Tokens.GOLD_HOVER)
	title.add_theme_color_override("font_outline_color", Tokens.INK_PANEL)
	title.add_theme_constant_override("outline_size", 3)
	add_child(title)
	_bar = ProgressBar.new()
	_bar.name = "SpectatorLoadingBar"
	_bar.show_percentage = false
	_bar.min_value = 0.0
	_bar.max_value = 100.0
	_bar.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_bar.offset_left = -BAR_WIDTH * 0.5
	_bar.offset_right = BAR_WIDTH * 0.5
	_bar.offset_top = 40.0
	_bar.offset_bottom = 40.0 + BAR_HEIGHT
	var back := StyleBoxFlat.new()
	back.bg_color = Color(0.06, 0.16, 0.20, 1.0)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.20, 0.95, 0.92, 1.0)
	_bar.add_theme_stylebox_override("background", back)
	_bar.add_theme_stylebox_override("fill", fill)
	add_child(_bar)
	_pet = PetPreview.build_runner(PlayerProfile.get_active(), PET_SIZE)
	if _pet != null:
		_pet.name = "LoadingPet"
		_bar.add_child(_pet)
	sync_from_state(NetworkService.spectate_state)
	if not NetworkService.spectate_state_received.is_connected(sync_from_state):
		NetworkService.spectate_state_received.connect(sync_from_state)


func sync_from_state(state: Dictionary) -> void:
	var left := float(state.get("prep_seconds_left", -1.0))
	if str(state.get("phase", "")) != "prep" or left < 0.0:
		# 已经不在备战了（全员提早准备 → 服务器开战）：进度直接走满，Main 马上切走。
		_set_progress(1.0)
		_deadline = -1.0
		return
	var now := Time.get_ticks_msec() / 1000.0
	if _deadline < 0.0:
		_total = maxf(left, 1.0)
	_deadline = now + left


func _process(_delta: float) -> void:
	if _deadline < 0.0:
		return
	var left := maxf(0.0, _deadline - Time.get_ticks_msec() / 1000.0)
	_set_progress(1.0 - left / _total)


func _set_progress(ratio: float) -> void:
	_bar.value = maxf(_bar.value, clampf(ratio, 0.0, 1.0) * 100.0)
	if _pet != null:
		var r := _bar.value / 100.0
		_pet.position = Vector2(BAR_WIDTH * r - _pet.size.x * 0.5, BAR_HEIGHT * 0.5 - _pet.size.y + 5.0).round()


func progress() -> float:
	return _bar.value / 100.0


func _t(zh: String, en: String) -> String:
	return en if TranslationServer.get_locale().begins_with("en") else zh
