extends RefCounted
class_name GloryTheme

# 由 GloryTokens 组装出的 Theme（V3 P1-01）。
#
# 刻意**不**设成 project.godot 的 gui/theme/custom：那会一次性改掉全部既有页面
# 的观感，而 V3 P1-08 要求分批迁移、每批留可回滚的记录。所以这里只把主题交给
# 主动 set_theme() 的组件，老页面维持原样，直到它们各自那一批迁移过来。
#
# 按钮用 Theme 类型变体区分意图，而不是让页面自己 override stylebox：
#   GloryPrimary  暖金实底 —— 确认、开始，一屏只应有一个
#   GloryDanger   暗红实底 —— 放弃教学、删档这类不可逆操作
#   GloryGhost    描边空底 —— 取消、次要操作
# 六个状态 normal/hover/pressed/focus/disabled/busy 都必须可区分（P1-04）；
# busy 不是 Godot 的原生状态，由 GloryBusyButton 用 disabled + 忙碌文案表达。

const Tokens := preload("res://ui/theme/GloryTokens.gd")

const VARIATION_PRIMARY := "GloryPrimary"
const VARIATION_DANGER := "GloryDanger"
const VARIATION_GHOST := "GloryGhost"
# busy 不是 disabled（V3 P1-01）。禁用态说的是「现在不能点」，忙碌态说的是
# 「你点到了，正在做」。两者共用一套外观时，玩家分不出「我按空了」和
# 「它在跑」—— 那正是连点的成因。
const VARIATION_BUSY := "GloryBusy"

const REQUIRED_BUTTON_STATES := ["normal", "hover", "pressed", "focus", "disabled"]

# 主题必须覆盖到的 (类型, 状态) 全表（V3 P1-01）。
#
# 做成表而不是散落在各 _build_* 里，是为了让门禁能逐条核对：漏一个状态就
# 会在那个状态下露出 Godot 默认外观 —— 深色界面里突然冒出一块浅灰。
# LineEdit 的「禁用」在 Godot 里叫 read_only，不是 disabled。
const REQUIRED_STYLEBOX_COVERAGE := {
	"LineEdit": ["normal", "hover", "focus", "read_only"],
	"CheckButton": ["normal", "hover", "pressed", "focus", "disabled"],
	"TabBar": ["tab_selected", "tab_unselected", "tab_hovered", "tab_disabled",
		"tab_focus"],
	"TabContainer": ["panel", "tab_selected", "tab_unselected", "tab_hovered",
		"tab_disabled"],
	"PanelContainer": ["panel"],
	"Panel": ["panel"],
	"ProgressBar": ["background", "fill"],
	"VScrollBar": ["scroll", "grabber", "grabber_highlight", "grabber_pressed"],
	"HScrollBar": ["scroll", "grabber", "grabber_highlight", "grabber_pressed"],
}

static var _cached: Theme = null


static func get_theme() -> Theme:
	if _cached == null:
		_cached = build()
	return _cached


static func build() -> Theme:
	var theme := Theme.new()
	theme.default_font_size = Tokens.FONT_BODY

	_build_base_button(theme)
	_build_button_variation(theme, VARIATION_PRIMARY,
		Tokens.GOLD, Tokens.GOLD_HOVER, Tokens.GOLD_PRESSED, Tokens.TEXT_ON_GOLD, true)
	_build_button_variation(theme, VARIATION_DANGER,
		Tokens.DANGER, Tokens.DANGER_HOVER, Tokens.DANGER_PRESSED, Tokens.TEXT_PRIMARY, true)
	_build_button_variation(theme, VARIATION_GHOST,
		Tokens.BORDER, Tokens.CYAN, Tokens.SURFACE_RAISED, Tokens.TEXT_PRIMARY, false)
	_build_busy_variation(theme)

	_build_label(theme)
	_build_panel(theme)
	_build_progress(theme)
	_build_line_edit(theme)
	_build_check_button(theme)
	_build_tabs(theme)
	_build_scrollbars(theme)
	return theme


# --- Button -------------------------------------------------------------------

static func _build_base_button(theme: Theme) -> void:
	theme.set_stylebox("normal", "Button", Tokens.button_box(Tokens.SURFACE_RAISED, Tokens.BORDER))
	theme.set_stylebox("hover", "Button", Tokens.button_box(Tokens.SURFACE_RAISED, Tokens.CYAN))
	theme.set_stylebox("pressed", "Button", Tokens.button_box(Tokens.SURFACE, Tokens.CYAN_HOVER))
	theme.set_stylebox("focus", "Button", Tokens.focus_box())
	var disabled := Tokens.button_box(Tokens.SURFACE, Tokens.BORDER)
	disabled.bg_color.a = 0.5
	theme.set_stylebox("disabled", "Button", disabled)

	theme.set_color("font_color", "Button", Tokens.TEXT_PRIMARY)
	theme.set_color("font_hover_color", "Button", Tokens.TEXT_PRIMARY)
	theme.set_color("font_pressed_color", "Button", Tokens.CYAN_HOVER)
	theme.set_color("font_focus_color", "Button", Tokens.TEXT_PRIMARY)
	theme.set_color("font_disabled_color", "Button", Tokens.TEXT_DISABLED)
	theme.set_font_size("font_size", "Button", Tokens.FONT_BUTTON)


static func _build_button_variation(
	theme: Theme,
	variation: String,
	base: Color,
	hover: Color,
	pressed: Color,
	text: Color,
	filled: bool
) -> void:
	theme.set_type_variation(variation, "Button")
	theme.set_stylebox("normal", variation, Tokens.button_box(base, base, filled))
	theme.set_stylebox("hover", variation, Tokens.button_box(hover, hover, filled))
	theme.set_stylebox("pressed", variation, Tokens.button_box(pressed, pressed, filled))
	theme.set_stylebox("focus", variation, Tokens.focus_box())
	# 禁用态压暗但保留形状：完全透明会让玩家以为按钮消失了，
	# 而完全不变会让人反复点一个不响应的东西（P1-04）。
	var disabled := Tokens.button_box(base.darkened(0.55), base.darkened(0.45), filled)
	disabled.bg_color.a = 0.55 if filled else 0.0
	theme.set_stylebox("disabled", variation, disabled)

	theme.set_color("font_color", variation, text)
	theme.set_color("font_hover_color", variation, text)
	theme.set_color("font_pressed_color", variation, text)
	theme.set_color("font_focus_color", variation, text)
	theme.set_color("font_disabled_color", variation, Tokens.TEXT_DISABLED)
	theme.set_font_size("font_size", variation, Tokens.FONT_BUTTON)


# 忙碌态：青色（= 信息/进行中，和加载层同一套语义），底色比 normal 更沉，
# 但描边更亮 —— 一眼能看出「它在动」，而不是「它死了」。
#
# 五个状态都给同一套外观：忙碌期间按钮不接受输入，hover/pressed 变化只会
# 让玩家以为还能点。这跟 normal/hover/pressed 必须互不相同不是一回事 ——
# 那条要求针对的是**可点**的按钮。
static func _build_busy_variation(theme: Theme) -> void:
	theme.set_type_variation(VARIATION_BUSY, "Button")
	var busy := Tokens.button_box(Tokens.SURFACE, Tokens.CYAN)
	for state in REQUIRED_BUTTON_STATES:
		if state == "focus":
			theme.set_stylebox(state, VARIATION_BUSY, Tokens.focus_box())
			continue
		theme.set_stylebox(state, VARIATION_BUSY, busy)
	theme.set_color("font_color", VARIATION_BUSY, Tokens.CYAN_HOVER)
	theme.set_color("font_hover_color", VARIATION_BUSY, Tokens.CYAN_HOVER)
	theme.set_color("font_pressed_color", VARIATION_BUSY, Tokens.CYAN_HOVER)
	theme.set_color("font_focus_color", VARIATION_BUSY, Tokens.CYAN_HOVER)
	theme.set_color("font_disabled_color", VARIATION_BUSY, Tokens.CYAN_HOVER)
	theme.set_font_size("font_size", VARIATION_BUSY, Tokens.FONT_BUTTON)


# --- 其余控件 ------------------------------------------------------------------

static func _build_label(theme: Theme) -> void:
	theme.set_color("font_color", "Label", Tokens.TEXT_PRIMARY)
	theme.set_font_size("font_size", "Label", Tokens.FONT_BODY)


static func _build_panel(theme: Theme) -> void:
	theme.set_stylebox("panel", "PanelContainer", Tokens.panel_box())
	theme.set_stylebox("panel", "Panel", Tokens.panel_box())


static func _build_progress(theme: Theme) -> void:
	var bg := StyleBoxFlat.new()
	bg.bg_color = Tokens.BG_DEEP
	bg.border_color = Tokens.BORDER
	bg.set_border_width_all(1)
	bg.set_corner_radius_all(Tokens.RADIUS_SMALL)
	theme.set_stylebox("background", "ProgressBar", bg)

	# 进度条用青色而不是金色：金色代表"可以点"，进度条不能点。
	var fill := StyleBoxFlat.new()
	fill.bg_color = Tokens.CYAN
	fill.set_corner_radius_all(Tokens.RADIUS_SMALL)
	theme.set_stylebox("fill", "ProgressBar", fill)
	theme.set_color("font_color", "ProgressBar", Tokens.TEXT_PRIMARY)
	theme.set_font_size("font_size", "ProgressBar", Tokens.FONT_CAPTION)


static func _build_line_edit(theme: Theme) -> void:
	var normal := Tokens.button_box(Tokens.BG_DEEP, Tokens.BORDER)
	theme.set_stylebox("normal", "LineEdit", normal)
	theme.set_stylebox("hover", "LineEdit", Tokens.button_box(Tokens.BG_DEEP, Tokens.BORDER.lightened(0.25)))
	theme.set_stylebox("focus", "LineEdit", Tokens.button_box(Tokens.BG_DEEP, Tokens.CYAN))
	# Godot 的输入框没有 disabled，只有 read_only。名字不同、语义相同：
	# 玩家需要一眼看出「这一格现在不能改」。
	var read_only := Tokens.button_box(Tokens.SURFACE, Tokens.BORDER)
	read_only.bg_color.a = 0.5
	theme.set_stylebox("read_only", "LineEdit", read_only)
	theme.set_color("font_color", "LineEdit", Tokens.TEXT_PRIMARY)
	theme.set_color("font_uneditable_color", "LineEdit", Tokens.TEXT_DISABLED)
	theme.set_color("font_selected_color", "LineEdit", Tokens.TEXT_ON_GOLD)
	theme.set_color("selection_color", "LineEdit", Tokens.GOLD)
	theme.set_color("font_placeholder_color", "LineEdit", Tokens.TEXT_DISABLED)
	theme.set_color("caret_color", "LineEdit", Tokens.GOLD)
	theme.set_font_size("font_size", "LineEdit", Tokens.FONT_BODY)


static func _build_check_button(theme: Theme) -> void:
	# 迁移前 CheckButton 只有字色，五个状态的底板全是 Godot 默认外观 ——
	# 深色界面里按下去会闪一块浅灰。
	theme.set_stylebox("normal", "CheckButton", Tokens.button_box(Tokens.SURFACE_RAISED, Tokens.BORDER))
	theme.set_stylebox("hover", "CheckButton", Tokens.button_box(Tokens.SURFACE_RAISED, Tokens.CYAN))
	theme.set_stylebox("pressed", "CheckButton", Tokens.button_box(Tokens.SURFACE, Tokens.CYAN_HOVER))
	theme.set_stylebox("focus", "CheckButton", Tokens.focus_box())
	var cb_disabled := Tokens.button_box(Tokens.SURFACE, Tokens.BORDER)
	cb_disabled.bg_color.a = 0.5
	theme.set_stylebox("disabled", "CheckButton", cb_disabled)
	theme.set_color("font_color", "CheckButton", Tokens.TEXT_PRIMARY)
	theme.set_color("font_hover_color", "CheckButton", Tokens.TEXT_PRIMARY)
	theme.set_color("font_focus_color", "CheckButton", Tokens.TEXT_PRIMARY)
	theme.set_color("font_pressed_color", "CheckButton", Tokens.GOLD)
	theme.set_color("font_disabled_color", "CheckButton", Tokens.TEXT_DISABLED)
	theme.set_font_size("font_size", "CheckButton", Tokens.FONT_BODY)


# 迁移前 TabBar / TabContainer 完全没进主题。设置页与图鉴用得到，
# 不覆盖就会在深色界面里露出一整条浅色标签栏。
static func _build_tabs(theme: Theme) -> void:
	var selected := Tokens.button_box(Tokens.SURFACE_RAISED, Tokens.GOLD)
	var unselected := Tokens.button_box(Tokens.SURFACE, Tokens.BORDER)
	var hovered := Tokens.button_box(Tokens.SURFACE_RAISED, Tokens.CYAN)
	var tab_disabled := Tokens.button_box(Tokens.SURFACE, Tokens.BORDER)
	tab_disabled.bg_color.a = 0.5
	for type_name in ["TabBar", "TabContainer"]:
		theme.set_stylebox("tab_selected", type_name, selected)
		theme.set_stylebox("tab_unselected", type_name, unselected)
		theme.set_stylebox("tab_hovered", type_name, hovered)
		theme.set_stylebox("tab_disabled", type_name, tab_disabled)
		theme.set_color("font_selected_color", type_name, Tokens.GOLD)
		theme.set_color("font_unselected_color", type_name, Tokens.TEXT_SECONDARY)
		theme.set_color("font_hovered_color", type_name, Tokens.TEXT_PRIMARY)
		theme.set_color("font_disabled_color", type_name, Tokens.TEXT_DISABLED)
		theme.set_font_size("font_size", type_name, Tokens.FONT_BODY)
	# 焦点框只有 TabBar 有；TabContainer 的标签焦点走它内部的 TabBar。
	theme.set_stylebox("tab_focus", "TabBar", Tokens.focus_box())
	theme.set_stylebox("panel", "TabContainer", Tokens.panel_box())


static func _build_scrollbars(theme: Theme) -> void:
	for type_name in ["VScrollBar", "HScrollBar"]:
		var bg := StyleBoxFlat.new()
		bg.bg_color = Color(Tokens.BG_DEEP.r, Tokens.BG_DEEP.g, Tokens.BG_DEEP.b, 0.6)
		bg.set_corner_radius_all(Tokens.RADIUS_SMALL)
		theme.set_stylebox("scroll", type_name, bg)

		var grabber := StyleBoxFlat.new()
		grabber.bg_color = Tokens.BORDER
		grabber.set_corner_radius_all(Tokens.RADIUS_SMALL)
		theme.set_stylebox("grabber", type_name, grabber)

		var grabber_hi := StyleBoxFlat.new()
		grabber_hi.bg_color = Tokens.CYAN
		grabber_hi.set_corner_radius_all(Tokens.RADIUS_SMALL)
		theme.set_stylebox("grabber_highlight", type_name, grabber_hi)
		theme.set_stylebox("grabber_pressed", type_name, grabber_hi)
