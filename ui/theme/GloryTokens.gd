extends RefCounted
class_name GloryTokens

# Glory UI 的唯一取色/取尺处（V3 P1-01）。
#
# 为什么需要它：复审时全仓有 34 处 StyleBoxFlat.new() 和 62 处 Button.new()，
# 每处各自写死 hex 和尺寸，于是同一个"确认框"在教程里和主菜单里长得不一样。
# 页面不再自己调色 —— 需要新颜色就在这里加一个 token，不要在页面里写 Color(...)。
#
# 取色依据：项目现有奇幻卡牌/背景的暖金 + 石板蓝黑。
#   金 = 主操作（确认、开始）
#   青 = 加载/信息（不代表可点）
#   红 = 危险操作（放弃、删档），只在 intent=DANGER 时出现
# 不要把红色用作"次要按钮"，玩家会读成"这一步会毁东西"。

# --- 底色 ---------------------------------------------------------------------
const BG_DEEP := Color(0.031, 0.039, 0.059)
const SURFACE := Color(0.071, 0.082, 0.110)
const SURFACE_RAISED := Color(0.105, 0.121, 0.161)
const BORDER := Color(0.220, 0.250, 0.320)

# --- 主操作（暖金）------------------------------------------------------------
const GOLD := Color(0.925, 0.757, 0.349)
const GOLD_HOVER := Color(1.000, 0.855, 0.478)
const GOLD_PRESSED := Color(0.776, 0.616, 0.251)
const GOLD_EDGE := Color(1.000, 0.859, 0.282)

# --- 信息/加载（青）------------------------------------------------------------
const CYAN := Color(0.420, 0.780, 0.850)
const CYAN_HOVER := Color(0.545, 0.870, 0.925)

# --- 危险（暗红）---------------------------------------------------------------
const DANGER := Color(0.639, 0.196, 0.212)
const DANGER_HOVER := Color(0.745, 0.259, 0.271)
const DANGER_PRESSED := Color(0.494, 0.145, 0.161)

# --- 文字 ---------------------------------------------------------------------
const TEXT_PRIMARY := Color(0.961, 0.941, 0.882)
const TEXT_SECONDARY := Color(0.722, 0.741, 0.800)
const TEXT_DISABLED := Color(0.451, 0.471, 0.522)
const TEXT_ON_GOLD := Color(0.055, 0.055, 0.071)

# 未读红点。刻意比 DANGER 亮：DANGER 是「这一步会毁东西」的按钮底色，
# 红点说的是「这里有新东西」—— 两者混用，玩家会把新消息读成警告。
const UNREAD_DOT := Color(1.0, 0.15, 0.12)

# --- 主菜单羊皮纸（V3 P1-08 迁移时从 MainMenu 抬上来的实测值）------------------
# 这几个值原本以字面量散在 MainMenu 的五处 StyleBoxFlat 里。抬上来是为了让别的
# 页面复用同一套，而不是各自再抄一遍 hex —— 逐字保持原值，这一批不动观感。
const PARCHMENT := Color(1.0, 0.96, 0.84, 0.96)
const PARCHMENT_SOFT := Color(1.0, 0.96, 0.82, 0.76)
const PARCHMENT_BUTTON := Color(1.0, 0.94, 0.76, 0.95)
const PARCHMENT_EDGE := Color(0.58, 0.40, 0.16)
const PARCHMENT_EDGE_SOFT := Color(0.57, 0.38, 0.13)
const INK_PANEL := Color(0.11, 0.075, 0.035, 0.95)
const INK_EDGE := Color(0.78, 0.56, 0.24)

# --- 遮罩 ---------------------------------------------------------------------
# V3 P1-02 要求 80–88%：太浅看不出模态，太深会把背景战场吃掉。
const BACKDROP := Color(0.008, 0.016, 0.031, 0.84)

# --- 尺寸 ---------------------------------------------------------------------
# TOUCH_MIN 是硬下限：任何可点控件的最短边都不得小于它，否则手指点不中。
const TOUCH_MIN := 48.0
const BUTTON_HEIGHT := 56.0
const BUTTON_MIN_WIDTH := 148.0
const DIALOG_WIDTH := 520.0
const DIALOG_MAX_BODY_HEIGHT := 320.0

const RADIUS := 10
const RADIUS_SMALL := 6
const BORDER_WIDTH := 2

const GAP_S := 8
# 可点控件的上下内边距。用 GAP_S(8) 时单行按钮实测只有 44 高，比 TOUCH_MIN 矮 4 ——
# 常量写着 48、手指还是点不中，是这条要求最常见的失败方式。
#
# 取值按**最矮**的那类控件校准：LineEdit / CheckButton 用 FONT_BODY(19)，比按钮的
# FONT_BUTTON(20) 再矮 1。按它们校准，按钮会略高于 48 —— 那是下限，超出无妨；
# 反过来按按钮校准就会把输入框卡在 47。
# 这个值由门禁实测校准；换字号后任何一类矮下去，control_below_touch_minimum 转红。
const BUTTON_PAD_V := 11
const GAP_M := 16
const GAP_L := 24
const PAD := 24

# --- 字号（1600×720 逻辑分辨率下经真机确认的可读下限是 14）---------------------
const FONT_TITLE := 26
const FONT_BODY := 19
const FONT_BUTTON := 20
const FONT_CAPTION := 14
const FONT_MIN_READABLE := 14

# --- 动效 ---------------------------------------------------------------------
const MOTION_DIALOG_IN := 0.16
const MOTION_PRESS := 0.08
const PRESS_SCALE := 0.97
const DIALOG_IN_SCALE := 0.94

# 降低动态效果。设置页接上之前，先认命令行与项目设置，
# 这样真机上不改代码就能验（V3 P1-09）。
const REDUCED_MOTION_FLAG := "--reduced-motion"
const REDUCED_MOTION_SETTING := "glory/ui/reduced_motion"


static func reduced_motion() -> bool:
	if REDUCED_MOTION_FLAG in OS.get_cmdline_args():
		return true
	if ProjectSettings.has_setting(REDUCED_MOTION_SETTING):
		return bool(ProjectSettings.get_setting(REDUCED_MOTION_SETTING))
	return false


# 动效时长的唯一出口：reduced motion 时归零，调用方不必各自判断。
static func motion(seconds: float) -> float:
	return 0.0 if reduced_motion() else seconds


# --- StyleBox 构造 -------------------------------------------------------------

static func panel_box(bg: Color = SURFACE, edge: Color = GOLD_EDGE, pad: int = PAD) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = bg
	box.border_color = edge
	box.set_border_width_all(BORDER_WIDTH)
	box.set_corner_radius_all(RADIUS)
	box.set_content_margin_all(pad)
	return box


# 通用扁平底板。业务页面不再自己 StyleBoxFlat.new() —— 那是 P1-08 棘轮盯的调用，
# 每处各自写死 hex 和圆角正是「同一个确认框在两处长得不一样」的来源。
#
# 参数照搬原来那几处逐个 set 的东西，所以迁移可以逐值透传、观感不变。
static func flat_box(
	bg: Color,
	edge: Color,
	border_width: int = BORDER_WIDTH,
	radius: int = RADIUS
) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = bg
	box.border_color = edge
	box.set_border_width_all(border_width)
	box.set_corner_radius_all(radius)
	return box


static func button_box(bg: Color, edge: Color, filled: bool = true) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = bg if filled else Color(bg.r, bg.g, bg.b, 0.0)
	box.border_color = edge
	box.set_border_width_all(BORDER_WIDTH)
	box.set_corner_radius_all(RADIUS_SMALL)
	box.content_margin_left = GAP_L
	box.content_margin_right = GAP_L
	box.content_margin_top = BUTTON_PAD_V
	box.content_margin_bottom = BUTTON_PAD_V
	return box


# 焦点框单独画，不靠改底色 —— 键盘/手柄用户需要在"已聚焦"和"已按下"之间分得清。
static func focus_box() -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0, 0, 0, 0)
	box.border_color = CYAN_HOVER
	box.set_border_width_all(BORDER_WIDTH)
	box.set_corner_radius_all(RADIUS_SMALL)
	return box
