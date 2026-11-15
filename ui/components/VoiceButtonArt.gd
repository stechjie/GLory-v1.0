extends RefCounted

# 麦克风 / 扬声器四张按钮图（11.15 换成羊皮纸小方框 + 实心深棕图标，原来是亮金金属图集）。
# 每张 240px 画布，板子占中间 504/627（沿用旧图集的约定：调用方按这个比例把图往外撑到「板子 = 按钮大小」）。
# 运行时 load()：战斗服务器包不带导入过的贴图，不能 preload。
# 生成脚本和画法见 reports/art_unify_20261115/voice_icons.py。
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
