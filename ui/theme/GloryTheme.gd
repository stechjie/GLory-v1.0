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

const REQUIRED_BUTTON_STATES := ["normal", "hover", "pressed", "focus", "disabled"]

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

	_build_label(theme)
	_build_panel(theme)
	_build_progress(theme)
	_build_line_edit(theme)
	_build_check_button(theme)
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
	theme.set_stylebox("focus", "LineEdit", Tokens.button_box(Tokens.BG_DEEP, Tokens.CYAN))
	theme.set_color("font_color", "LineEdit", Tokens.TEXT_PRIMARY)
	theme.set_color("font_placeholder_color", "LineEdit", Tokens.TEXT_DISABLED)
	theme.set_color("caret_color", "LineEdit", Tokens.GOLD)
	theme.set_font_size("font_size", "LineEdit", Tokens.FONT_BODY)


static func _build_check_button(theme: Theme) -> void:
	theme.set_color("font_color", "CheckButton", Tokens.TEXT_PRIMARY)
	theme.set_color("font_pressed_color", "CheckButton", Tokens.GOLD)
	theme.set_color("font_disabled_color", "CheckButton", Tokens.TEXT_DISABLED)
	theme.set_font_size("font_size", "CheckButton", Tokens.FONT_BODY)


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
