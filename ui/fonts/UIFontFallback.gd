extends Node

# Bundle Chinese glyphs: system fallback differs between Android and iOS.
# Keep Godot's existing Latin font, sizes and theme styles; only missing glyphs
# use Noto Sans SC. This runs before LocaleManager and the first UI scene.
const CHINESE_FONT: FontFile = preload("res://ui/fonts/NotoSansSC-Regular.otf")


func _enter_tree() -> void:
	install()


func install() -> void:
	_add_fallback(ThemeDB.fallback_font)
	_add_fallback(ThemeDB.get_default_theme().default_font)


func _add_fallback(font: Font) -> void:
	if font == null or font == CHINESE_FONT:
		return
	var chain: Array[Font] = font.fallbacks.duplicate()
	if not chain.has(CHINESE_FONT):
		chain.append(CHINESE_FONT)
		font.fallbacks = chain
