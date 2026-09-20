extends Node

# 门禁：设置页的语言切换必须**当场生效**。
#
# 9.20 bug 文档第 1 条：「设置里改成英文时，未实时同步变成英文……而不是重新打开才
# 显示英文。」根因是 `SettingsScreen._build()` 里用 `tr(key)` 取到的是**已翻译后的
# 字符串**（翻译键丢了），Godot 的自动翻译再也查不回去；而 `_on_locale_changed()`
# 当时只刷了语言按钮，没重建页面 —— 于是只有重开设置页（`Main._show_settings()` 会
# 重新 instantiate）才会变英文。
#
# 本门禁直接驱动真场景：切 en → 扫全子树文本，断言**一个中文都不剩**（语言按钮上的
# 「中文」除外，那是语言名，本来就该留）；再切回 zh → 断言中文回来。
#
# 同时兜住「翻译键漏配」：漏配时 `tr()` 会原样返回键名，页面上就会冒出 `settings_xxx`。
const SettingsScene := preload("res://scenes/menu/SettingsScreen.tscn")

# 语言按钮上的「中文」是语言名，不是界面文案，切到英文时它就该保持中文。
const LOCALE_NAME_TEXTS := ["中文", "English", "✓ 中文", "✓ English"]

var _fail := 0
var _checks := 0
var _saved_locale := "zh"


func _ready() -> void:
	_saved_locale = LocaleManager.get_locale()
	LocaleManager.set_locale("zh")
	await _settle()

	var screen := SettingsScene.instantiate()
	add_child(screen)
	await _settle()

	var zh_texts := _cjk_texts(screen)
	print("zh 页文本 %d 条，含中文 %d 条" % [_all_texts(screen).size(), zh_texts.size()])
	_expect(zh_texts.size() > 0, true, "中文态下页面应有中文")

	# --- 中 -> 英：必须当场变英文 ---
	LocaleManager.set_locale("en")
	await _settle()
	var left := _cjk_texts(screen)
	_expect(left.size(), 0, "切到英文后设置页不应残留中文")
	if not left.is_empty():
		print("     残留：%s" % str(left))

	var keys := _untranslated_keys(screen)
	_expect(keys.size(), 0, "英文态不应出现未翻译的键名")
	if not keys.is_empty():
		print("     漏配键：%s" % str(keys))

	# --- 英 -> 中：切回来也要立刻生效 ---
	LocaleManager.set_locale("zh")
	await _settle()
	_expect(_cjk_texts(screen).size() > 0, true, "切回中文后设置页应立刻显示中文")

	LocaleManager.set_locale(_saved_locale)
	if _fail == 0:
		print("CHECK_RESULT status=PASS checked=%d failures=0" % _checks)
	else:
		print("CHECK_RESULT status=FAIL checked=%d failures=%d" % [_checks, _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _settle() -> void:
	# 重建走的是 remove_child + queue_free，要跨两帧才彻底；多等一帧稳妥。
	for i in 4:
		await get_tree().process_frame


func _all_texts(root: Node) -> Array:
	var out: Array = []
	_walk(root, func(t: String): out.append(t))
	return out


func _cjk_texts(root: Node) -> Array:
	var out: Array = []
	_walk(root, func(t: String):
		if _has_cjk(t) and not LOCALE_NAME_TEXTS.has(t):
			out.append(t))
	return out


func _untranslated_keys(root: Node) -> Array:
	var out: Array = []
	_walk(root, func(t: String):
		if t.begins_with("settings_") or t.begins_with("menu_"):
			out.append(t))
	return out


func _walk(root: Node, visit: Callable) -> void:
	for child in root.get_children():
		var text := ""
		if child is Label:
			text = (child as Label).text
		elif child is Button:
			text = (child as Button).text
		if not text.is_empty():
			visit.call(text)
		_walk(child, visit)


func _has_cjk(s: String) -> bool:
	for i in s.length():
		var c := s.unicode_at(i)
		if c >= 0x4E00 and c <= 0x9FFF:
			return true
	return false


func _expect(got, want, label: String) -> void:
	_checks += 1
	var ok: bool = got == want
	if not ok:
		_fail += 1
	print("  %s %-42s got=%s want=%s" % ["PASS" if ok else "FAIL", label, str(got), str(want)])
