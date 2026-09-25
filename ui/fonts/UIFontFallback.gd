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

static var _font: FontFile


static func chinese_font() -> FontFile:
	if _font == null:
		_font = load(FONT_PATH) as FontFile
	return _font


func _enter_tree() -> void:
	var args := OS.get_cmdline_args()
	if "--server" in args or "--dedicated-server" in args:
		return
	install()


func install() -> void:
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
