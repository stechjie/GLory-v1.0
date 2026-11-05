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
	# 11.05 起的合同：全游戏默认字体 = Knewave（英文 / 数字）→ 站酷快乐体（中文）→ Noto Sans SC（快乐体缺的极少数字）。
	# 以前这里验「Latin 字宽不变、Noto 挂在引擎默认字体后面」；用户要求全游戏换字体后那两条按设计不再成立，改验下面这些。
	var failures: Array[String] = []
	var installer := FallbackScript.new()
	installer.install()
	installer.install() # 重复安装不能让回退链变长或成环。
	var display := FallbackScript.display_font() as FontVariation
	var cjk: FontFile = FallbackScript.chinese_font()
	if display == null:
		failures.append("display font failed to load")
		print("GLORY_FONT_CHECK ", JSON.stringify({"passed": false, "failures": failures}))
		installer.free()
		quit(1)
		return
	var latin := display.base_font as FontFile
	var kuaile: FontFile = null
	if display.fallbacks.size() > 0:
		kuaile = display.fallbacks[0] as FontFile
	if latin == null or latin.resource_path != FallbackScript.DISPLAY_LATIN_PATH:
		failures.append("display base font is not Knewave")
	if kuaile == null or kuaile.resource_path != FallbackScript.DISPLAY_CJK_PATH:
		failures.append("first fallback is not ZCOOL KuaiLe")
	if display.fallbacks.size() != 2 or display.fallbacks.count(cjk) != 1:
		failures.append("fallback chain is not [KuaiLe, Noto] exactly once (install not idempotent?)")
	if ThemeDB.fallback_font != display or ThemeDB.get_default_theme().default_font != display:
		failures.append("default theme / engine fallback font is not the display font")
	# 证明打包进来的这条链自己就够：关掉系统字体回退（手机上系统字体各家不一样）。
	for f in [latin, kuaile, cjk]:
		if f != null:
			(f as FontFile).allow_system_fallback = false
	var missing_punctuation_without_bundle := 0
	if latin != null:
		missing_punctuation_without_bundle = _missing_shaped_glyphs("：（）｜", latin)
		if missing_punctuation_without_bundle == 0:
			failures.append("baseline did not reproduce missing fullwidth punctuation in Knewave alone")
	var latin_unchanged := false
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
	if label.get_theme_font("font") != display:
		failures.append("a real Label does not use the display font")
	print("GLORY_FONT_CHECK ", JSON.stringify({
		"passed": failures.is_empty(), "system_fallback_disabled": true,
		"chinese_characters": characters.size(), "latin_metrics_unchanged": latin_unchanged,
		"font_family": "%s + %s" % [latin.get_font_name() if latin else "?", kuaile.get_font_name() if kuaile else "?"],
		"failures": failures,
		"punctuation_missing_without_bundle": missing_punctuation_without_bundle,
		"mixed_text_shaped_runs": shaped_runs,
	}))
	label.free()
	locale.free()
	installer.free()
	quit(0 if failures.is_empty() else 1)
