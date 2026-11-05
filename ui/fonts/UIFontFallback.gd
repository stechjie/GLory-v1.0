extends Node

# Bundle Chinese glyphs: system fallback differs between Android and iOS.
# Keep Godot's existing Latin font, sizes and theme styles; only missing glyphs
# use Noto Sans SC. This runs before LocaleManager and the first UI scene.
#
# load() rather than preload(): the dedicated-server package ships scripts only,
# never imported resources (make_server_zip.ps1), so a preload made this autoload
# fail to parse on the server. The server draws no text and skips the install.
# Both export presets use all_resources, so the font still ships with the client.
const FONT_PATH := "res://ui/fonts/NotoSansSC-Regular.otf"

# 11.05 全游戏换字体（用户定）：英文 / 数字用 Knewave（卡通粗体，原来金币数字就是它），
# 中文用站酷快乐体（Knewave 没有中文字形，自动落到它）；快乐体缺的极少数字
# （冚 媽 屄 屌 幹 槃 熝，基本是脏话过滤词）再落到 Noto Sans SC。三者都是 SIL OFL 1.1，许可在同目录。
# 主菜单、备战、战斗、弹窗……凡是没单独指定字体的文字都走这一套。
const DISPLAY_LATIN_PATH := "res://ui/fonts/Knewave-Regular.ttf"
const DISPLAY_CJK_PATH := "res://ui/fonts/ZCOOLKuaiLe-Regular.ttf"

static var _font: FontFile
static var _display: FontVariation


static func chinese_font() -> FontFile:
	if _font == null:
		_font = load(FONT_PATH) as FontFile
	return _font


func _enter_tree() -> void:
	var args := OS.get_cmdline_args()
	if "--server" in args or "--dedicated-server" in args:
		return
	install()


# 全游戏默认字体：Knewave → 站酷快乐体 → Noto Sans SC。加载失败时返回 null（调用方退回老做法）。
static func display_font() -> Font:
	if _display != null:
		return _display
	var latin := load(DISPLAY_LATIN_PATH) as FontFile
	var kuaile := load(DISPLAY_CJK_PATH) as FontFile
	if latin == null or kuaile == null:
		return null
	var chain: Array[Font] = [kuaile]
	var noto := chinese_font()
	if noto != null:
		chain.append(noto)
	_display = FontVariation.new()
	_display.base_font = latin
	_display.fallbacks = chain
	return _display


func install() -> void:
	var display := display_font()
	if display != null:
		# 默认主题 + 引擎兜底字体都换成这一套：没单独指定字体的控件（含 RichTextLabel 的粗 / 斜体变体）全跟着变。
		var theme := ThemeDB.get_default_theme()
		theme.default_font = display
		ThemeDB.fallback_font = display
		# 默认主题里 RichTextLabel 的粗体 / 斜体 / 粗斜体是建在**引擎原字体**上的 FontVariation，
		# 不跟着 default_font 走 —— 不改的话 [b]中文[/b] 会全是缺字方块（font_fallback_check 抓到过）。
		# 把它们的底换成这一套，加粗 / 倾斜参数保留。
		for type in theme.get_font_type_list():
			for item in theme.get_font_list(type):
				var f := theme.get_font(item, type)
				if f is FontVariation and f != display and (f as FontVariation).base_font != display:
					(f as FontVariation).base_font = display
		return
	var cjk := chinese_font()
	if cjk == null:
		return
	_add_fallback(ThemeDB.fallback_font, cjk)
	_add_fallback(ThemeDB.get_default_theme().default_font, cjk)


func _add_fallback(font: Font, cjk: FontFile) -> void:
	if font == null or font == cjk:
		return
	var chain: Array[Font] = font.fallbacks.duplicate()
	if not chain.has(cjk):
		chain.append(cjk)
	font.fallbacks = chain


# ── 合成加粗（10.01 反馈第 7 条）──────────────────────────────────────────────
#
# 需求：「对局内里对话框的文字字体以及金币数值字体需要加粗，避免看不清」。
#
# 工程里**没有 Bold 字体资源** —— 中文字形只有 NotoSansSC-Regular.otf 一份，
# 其余走引擎默认字体。所以加粗只能靠字形合成：FontVariation.variation_embolden
# （把字形轮廓向外扩张，等价于排版软件里的 Fake Bold，不改字距也不换字体）。
#
# ★ 只在「小字号 + 压在木牌/水面这类花背景上」的少数几处用（对话框记录、金币）。
#   **不要去改 ThemeDB / GloryTheme 的默认字体** —— 那是一次性改动全工程所有
#   文字，已经调好的排版会跟着动，属于不可控改动。tools/font_fallback_check.gd
#   量的也正是默认主题那条链，动它会一起动到。
#
# 0.6 是实测选出来的：24px 下一句中英混排的**墨点像素**比不加粗多约 11%，
# 笔画明显变实又不失形。实测扫过 0.4 / 0.6 / 0.8 / 1.2 / 1.6 / 2.0 六档
# （+8% / +11% / +14% / +23% / +30% / +38%）：1.6 往上汉字开始并笔画，
# 2.0 已经糊成块。0.6 是"看得清"和"还认得出"之间那一档。
const BOLD_EMBOLDEN := 0.6

# 按 (基础字体实例, 加粗量) 缓存：refresh 路径上每帧 new 一个 FontVariation
# 是白白的垃圾；同一个 Label 反复 override 同一个对象也更稳。
static var _bold_cache: Dictionary = {}


# base 传 null 表示「就用这个控件本来会拿到的默认字体」（对话框是普通 Label，
# 没指定过字体族）；金币数字那种指定了 Knewave-Regular.ttf 的要把 base 传进来，
# 否则会把数字换成中文字体。
static func bold_font(base: Font = null, embolden: float = BOLD_EMBOLDEN) -> Font:
	var source: Font = base
	if source == null:
		source = ThemeDB.get_default_theme().default_font
	if source == null:
		source = ThemeDB.fallback_font
	if source == null:
		return null
	var key := "%d|%.2f" % [source.get_instance_id(), embolden]
	var cached: Font = _bold_cache.get(key)
	if cached != null:
		return cached
	var variation := FontVariation.new()
	variation.base_font = source
	variation.variation_embolden = embolden
	_bold_cache[key] = variation
	return variation
