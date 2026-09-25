extends SceneTree

const FallbackScript = preload("res://ui/fonts/UIFontFallback.gd")
const LocaleScript = preload("res://scripts/autoload/LocaleManager.gd")
const LOBBY_SAMPLES := [
	"房间 ID：687182",
	"明 #8X8C9M6T（我）",
	"在线 ｜ 玩家2 AI0 ｜ 有玩家未准备",
	"，。！？；：（）【】《》、…—｜",
]


func _missing_shaped_glyphs(text: String, font: Font) -> int:
	var line := TextLine.new()
	line.add_string(text, font, 24, "zh_CN")
	var missing := 0
	for glyph in TextServerManager.get_primary_interface().shaped_text_get_glyphs(line.get_rid()):
		if not (glyph.font_rid as RID).is_valid():
			missing += 1
	return missing


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
	# A has_char-only check missed the fullwidth punctuation seen in the MuMu
	# screenshot. Exercise shaping of mixed Latin/CJK runs as well as coverage.
	var missing_punctuation_without_bundle := _missing_shaped_glyphs("：（）｜", font)
	font.fallbacks = saved_chain
	var installer := FallbackScript.new()
	installer.install()
	installer.install() # Re-entry must not grow or cycle the fallback chain.
	var failures: Array[String] = []
	if not missing_without_bundle:
		failures.append("baseline did not reproduce the missing Chinese glyph")
	if missing_punctuation_without_bundle == 0:
		failures.append("baseline did not reproduce missing fullwidth punctuation")
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
	for sample in LOBBY_SAMPLES:
		for character in sample:
			characters[character.unicode_at(0)] = true
	var shaped_runs := 0
	var theme := ThemeDB.get_default_theme()
	for type in ["Label", "Button", "LineEdit", "RichTextLabel", "Tree", "ItemList", "PopupMenu"]:
		for item in theme.get_font_list(type):
			var themed_font := theme.get_font(item, type)
			for sample in LOBBY_SAMPLES:
				shaped_runs += 1
				if _missing_shaped_glyphs(sample, themed_font) > 0:
					failures.append("%s.%s shaped missing glyphs: %s" % [type, item, sample])
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
		"punctuation_missing_without_bundle": missing_punctuation_without_bundle,
		"mixed_text_shaped_runs": shaped_runs,
	}))
	label.free()
	locale.free()
	installer.free()
	quit(0 if failures.is_empty() else 1)
