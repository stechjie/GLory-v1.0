extends RefCounted

# 麦克风 / 扬声器四张按钮图。11.15 第三轮：用户要「和原来的 logo 一样、画风跟游戏一样」，
# 用 ChatGPT 照旧图标 + 备战界面截图重画（羊皮纸底、金木框、两角叶子），符号和开关含义不变。
# 每张 256px，按钮几乎撑满画布（约 98%）。队友 / 全队两张（scope_team / scope_all）在同一目录，由 VoiceControls 直接 load。
# 运行时 load()：战斗服务器包不带导入过的贴图，不能 preload。
# 原图和切图脚本在 reports/art_unify_20261115/round3/voice_gpt/（cut_sheet.py）。旧的金属图集还在 assets/ui/voice/。
const ART_DIR := "res://ui/voice_buttons/"
const KEYS := ["mic_on", "mic_off", "speaker_on", "speaker_off"]
static var _icons := {}

static func texture_for(key: String) -> Texture2D:
	if _icons.has(key):
		return _icons[key]
	if not KEYS.has(key):
		return null
	var texture := load(ART_DIR + key + ".png") as Texture2D
	if texture != null:
		_icons[key] = texture
	return texture

static func use_art_as_button_background(button: Button) -> void:
	# The art already has its own frame; keep the Button's original hit region.
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		button.add_theme_stylebox_override(state, StyleBoxEmpty.new())
