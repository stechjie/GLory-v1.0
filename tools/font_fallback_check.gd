extends SceneTree

const FallbackScript = preload("res://ui/fonts/UIFontFallback.gd")
const LocaleScript = preload("res://scripts/autoload/LocaleManager.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var font := ThemeDB.fallback_font
	var cjk: FontFile = FallbackScript.chinese_font()
	# Prove that the bundled chain works even on a device with no system CJK font.
	font.allow_system_fallback = false
	cjk.allow_system_fallback = false
	var saved_chain: Array[Font] = font.fallbacks
	font.fallbacks = []
	var latin_before := font.get_string_size("Player 89,450 English", HORIZONTAL_ALIGNMENT_LEFT, -1, 24)
	var missing_without_bundle := not font.has_char("中".unicode_at(0))
	font.fallbacks = saved_chain
	var installer := FallbackScript.new()
	installer.install()
	installer.install() # Re-entry must not grow or cycle the fallback chain.
	var failures: Array[String] = []
	if not missing_without_bundle:
		failures.append("baseline did not reproduce the missing Chinese glyph")
	if font.fallbacks.count(cjk) != 1:
		failures.append("fallback installation is not idempotent")
	var latin_unchanged := font.get_string_size("Player 89,450 English", HORIZONTAL_ALIGNMENT_LEFT, -1, 24) == latin_before
	if not latin_unchanged:
		failures.append("Latin text metrics changed")
	var locale := LocaleScript.new()
	var characters := {}
	for value in locale._zh_strings().values():
		for character in str(value):
			var code := character.unicode_at(0)
			if code >= 0x2E80 and code <= 0xFFFF:
				characters[code] = true
	for character in "背包邮件设置好友聊天商店公告新闻备战休闲匹配自定义图鉴离线自测中文开始游戏":
		characters[character.unicode_at(0)] = true
	var theme := ThemeDB.get_default_theme()
	for type in ["Label", "Button", "LineEdit", "RichTextLabel", "Tree", "ItemList", "PopupMenu"]:
		for item in theme.get_font_list(type):
			var themed_font := theme.get_font(item, type)
			for code in characters:
				if not themed_font.has_char(code):
					failures.append("%s.%s missing U+%04X" % [type, item, code])
	var label := Label.new()
	root.add_child(label)
	if not label.get_theme_font("font").has_char("中".unicode_at(0)):
		failures.append("a real Label did not inherit the bundled fallback")
	print("GLORY_FONT_CHECK ", JSON.stringify({
		"passed": failures.is_empty(), "system_fallback_disabled": true,
		"chinese_characters": characters.size(), "latin_metrics_unchanged": latin_unchanged,
		"font_family": cjk.get_font_name(), "failures": failures,
	}))
	label.free()
	locale.free()
	installer.free()
	quit(0 if failures.is_empty() else 1)
