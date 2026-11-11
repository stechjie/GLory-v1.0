extends PanelContainer

# 看队友棋盘时顶在画面上方的那一条（2026-11-07 用户要的「点头像去队友棋盘，要有回到自己的按钮」）。
#
#   正在看「名字」的棋盘          [ 回到我的棋盘 ]
#   暗 ×5 · 人 ×2 · 宝藏 3 件（没同步到时写「等队友的棋盘同步…」）
#
# 只显示，不做交易：棋盘下面有一层挡板（PrepUI.enter_teammate_view），这一条是唯一能点的东西。
# 按钮一律实例化 GloryActionButton.tscn、样式走 GloryTokens（procedural_ui_ratchet 盯着）。

signal back_requested

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")
const Theming := preload("res://ui/theme/GloryTheme.gd")

const RACE_NAMES := {
	"god": ["神", "God"], "dark": ["暗", "Dark"], "undead": ["灵", "Undead"],
	"human": ["人", "Human"], "crimson": ["赤律", "Crimson"],
}

var _title: Label
var _detail: Label


func _ready() -> void:
	theme = Theming.get_theme()
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_theme_stylebox_override("panel", Tokens.panel_box(Tokens.SURFACE, Tokens.GOLD_EDGE, Tokens.GAP_S))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.GAP_M)
	add_child(row)
	var texts := VBoxContainer.new()
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texts.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_child(texts)
	_title = Label.new()
	_title.name = "Title"
	_title.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	_title.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	texts.add_child(_title)
	_detail = Label.new()
	_detail.name = "Detail"
	_detail.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	_detail.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	texts.add_child(_detail)
	var back := ACTION_BUTTON.instantiate() as Button
	back.name = "Back"
	back.text = _text("回到我的棋盘", "Back to my board")
	back.theme_type_variation = Theming.VARIATION_PRIMARY
	back.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	back.pressed.connect(func() -> void: back_requested.emit())
	row.add_child(back)


# who：队友的显示名；board / treasures：同步到的那一份（空 = 还没同步到）。
func show_state(who: String, board: Array, treasures: Array, synced: bool) -> void:
	if _title == null:
		return
	_title.text = _text("正在看「%s」的棋盘" % who, "Viewing %s's board" % who)
	if not synced:
		_detail.text = _text("等队友的棋盘同步…", "Waiting for your teammate's board…")
		return
	var counts := {}
	for cell in board:
		if cell is Dictionary and not bool((cell as Dictionary).get("is_mercenary", false)):
			var race := str(((cell as Dictionary).get("def", {}) as Dictionary).get("race", ""))
			counts[race] = int(counts.get(race, 0)) + 1
	var parts: PackedStringArray = []
	var english := LocaleManager.get_locale().begins_with("en")
	for race in ["god", "dark", "undead", "human", "crimson"]:
		if int(counts.get(race, 0)) > 0:
			parts.append("%s ×%d" % [RACE_NAMES[race][1 if english else 0], int(counts[race])])
	parts.append(_text("宝藏 %d 件" % treasures.size(), "%d treasures" % treasures.size()))
	_detail.text = " · ".join(parts)


static func _text(zh: String, en: String) -> String:
	return en if LocaleManager.get_locale().begins_with("en") else zh
