extends Node

# V2 P1-06 gate: no internal identifier may reach the player through the tutorial.
#
# V2 R-09 recorded the symptom: players saw BUY_3, FORMATION_HP, START_BOSS and
# FILL_7 in the tutorial bubble. The cause was one line —
# `_step_key_label.text = step_key()` — printing the enum name straight into a
# Label with no build guard, so it shipped in release too.
#
# Fixing that line is cheap. Keeping it fixed is what this gate is for, because
# the failure mode is silent: adding a Step and forgetting its display name would
# fall through to whatever the fallback is, and if that fallback were the enum
# name nobody would notice until a player screenshot showed it.
#
# Three layers, deliberately overlapping:
#   1. contract  — every enum value, both locales, must yield a human name
#   2. fallback  — an unmapped step must still yield a human name, not "?" or a key
#   3. live scan — drive the real overlay through every step and read the actual
#                  Labels, which catches leaks this file never thought to look for
#
# Layer 3 is the one that matters. Layers 1 and 2 can only check what I remembered
# to check; layer 3 reads whatever is genuinely on screen.

const CheckHarness := preload("res://tools/CheckHarness.gd")
const TutorialScript := preload("res://scripts/tutorial/TutorialMode.gd")

const CHECK_NAME := "tutorial_text_leak"

const PREP_SCENE := "res://scenes/prep/PrepScreen.tscn"
const TUTORIAL_SOURCE := "res://scripts/tutorial/TutorialMode.gd"

# Anything shaped like SCREAMING_SNAKE is an internal identifier, not player copy.
const INTERNAL_TOKEN := "^[A-Z][A-Z0-9]*(_[A-Z0-9]+)+$"

var _h: CheckHarness
var _locale_before := ""


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_locale_before = LocaleManager.get_locale()

	_check_every_step_has_a_human_name()
	_check_fallback_is_human()
	_check_key_accessor_is_not_wired_to_a_label()
	await _check_live_overlay_shows_no_keys()

	LocaleManager.set_locale(_locale_before)
	_h.finish(get_tree())


func _step_keys() -> Array:
	return TutorialScript.Step.keys()


# --- 1. every enum value, both locales ------------------------------------------

func _check_every_step_has_a_human_name() -> void:
	# Typed with the preload constant, not Node: that makes every call below a
	# STATIC call. Dispatching by method name instead would behave identically at
	# runtime but adds 9 receivers the compiler cannot check, and dynamic_call
	# ratchets that number (191, lower-only). A checking tool must not be the
	# thing that raises the project's unchecked-call count.
	var probe: TutorialScript = TutorialScript.new()
	add_child(probe)

	var keys: Array = _step_keys()
	_h.expect(keys.size() >= 17, "step_enum_shrank",
		"Step 枚举只剩 %d 项，检查集可能已经失效" % keys.size())

	var internal := RegEx.create_from_string(INTERNAL_TOKEN)

	for locale in ["zh", "en"]:
		LocaleManager.set_locale(locale)
		var seen := {}
		for i in keys.size():
			probe.step = i
			var key := str(keys[i])
			var shown := probe.step_display_name()
			_h.item()

			_h.expect(not shown.strip_edges().is_empty(), "step_name_empty",
				"[%s] 步骤 %s 的显示名是空的" % [locale, key])
			_h.expect(shown != key, "step_name_is_enum_key",
				"[%s] 步骤 %s 的显示名就是枚举名本身 —— 这正是 V2 R-09 记的那个缺陷"
					% [locale, key])
			_h.expect(not shown.contains(key), "step_name_contains_enum_key",
				"[%s] 步骤 %s 的显示名里含有枚举名：%s" % [locale, key, shown])
			_h.expect(shown != "?", "step_name_is_placeholder",
				"[%s] 步骤 %s 的显示名是占位符 \"?\"" % [locale, key])

			# A name made of SCREAMING_SNAKE tokens is an identifier, whatever it says.
			for token in shown.split(" ", false):
				if internal.search(str(token)) != null:
					_h.fail("step_name_looks_internal",
						"[%s] 步骤 %s 的显示名里有内部标识形状的词 %s：%s"
							% [locale, key, str(token), shown])

			seen[key] = shown

		# Distinct names per locale: if two steps share one name the label stops
		# telling the player anything, which is the same failure with nicer words.
		var values := seen.values()
		var unique := {}
		for v in values:
			unique[v] = true
		_h.expect(unique.size() == values.size(), "step_names_not_distinct",
			"[%s] %d 个步骤只有 %d 个不同的显示名" % [locale, values.size(), unique.size()])

	# The two locales must actually differ, otherwise a missing translation is
	# invisible: an untranslated string reads as "translated to the same words".
	var zh_names: Array[String] = []
	var en_names: Array[String] = []
	LocaleManager.set_locale("zh")
	for i in keys.size():
		probe.step = i
		zh_names.append(probe.step_display_name())
	LocaleManager.set_locale("en")
	for i in keys.size():
		probe.step = i
		en_names.append(probe.step_display_name())
	var same := 0
	for i in keys.size():
		if zh_names[i] == en_names[i]:
			same += 1
			_h.fail("step_name_not_translated",
				"步骤 %s 的中英显示名相同（%s）—— 大概率是漏了译文"
					% [str(keys[i]), zh_names[i]])
	_h.expect(same == 0, "untranslated_step_names",
		"%d 个步骤的中英显示名相同" % same)

	probe.queue_free()


# --- 2. the fallback must be human too ------------------------------------------

func _check_fallback_is_human() -> void:
	var probe: TutorialScript = TutorialScript.new()
	add_child(probe)
	var keys: Array = _step_keys()

	# Out of range on both sides: this is what a newly added Step looks like
	# before somebody remembers to give it a name.
	for bad_step in [keys.size() + 5, -1]:
		for locale in ["zh", "en"]:
			LocaleManager.set_locale(locale)
			probe.step = bad_step
			var shown := probe.step_display_name()
			_h.item()
			_h.expect(not shown.strip_edges().is_empty(), "fallback_empty",
				"[%s] step=%d 的兜底显示名是空的" % [locale, bad_step])
			_h.expect(shown != "?", "fallback_is_placeholder",
				"[%s] step=%d 的兜底是 \"?\"，玩家读不懂" % [locale, bad_step])
			for key in keys:
				_h.expect(shown != str(key), "fallback_is_enum_key",
					"[%s] step=%d 的兜底返回了枚举名 %s" % [locale, bad_step, str(key)])

			# step_key() is allowed to answer "?" — it is the internal accessor.
			# The point is that the two must not be the same thing.
			var raw := probe.step_key()
			_h.expect(shown != raw, "fallback_mirrors_key_accessor",
				"[%s] step=%d 时显示名和 step_key() 返回了同一个值：%s"
					% [locale, bad_step, raw])

	probe.queue_free()


# --- 3. the internal accessor must not be wired to a Label ----------------------

func _check_key_accessor_is_not_wired_to_a_label() -> void:
	var src := FileAccess.get_file_as_string(TUTORIAL_SOURCE)
	if not _h.expect(not src.is_empty(), "tutorial_source_unreadable",
			"读不到 %s" % TUTORIAL_SOURCE):
		return

	# The exact defect shape: any `.text = ... step_key() ...` assignment.
	var wired := RegEx.create_from_string("\\.text\\s*=\\s*[^\\n]*step_key\\s*\\(")
	_h.expect(wired.search(src) == null, "step_key_assigned_to_label",
		("源码里有 `.text = ... step_key() ...` —— 内部步骤代号又被接到界面上了。"
		+ "玩家可见的名字要用 step_display_name()。"))

	_h.expect(src.contains("func step_display_name"), "display_name_removed",
		"step_display_name() 不见了")


# --- 4. the live overlay, which is what the player actually sees -----------------

func _check_live_overlay_shows_no_keys() -> void:
	GameState.reset_run()
	var packed := load(PREP_SCENE) as PackedScene
	if not _h.expect(packed != null, "prep_scene_load_failed",
			"%s 加载不出来" % PREP_SCENE):
		return
	var prep: Control = packed.instantiate() as Control
	add_child(prep)
	await get_tree().process_frame
	await get_tree().process_frame

	var tutorial: TutorialScript = TutorialScript.new()
	tutorial.name = "TutorialUnderTest"
	add_child(tutorial)
	tutorial.start()
	tutorial.attach(prep)
	await get_tree().process_frame

	var keys: Array = _step_keys()
	var scanned := 0
	for locale in ["zh", "en"]:
		LocaleManager.set_locale(locale)
		for i in keys.size():
			tutorial.step = i
			tutorial.update_overlay()
			await get_tree().process_frame

			# Scan PREP, not the TutorialMode node: _ensure_overlay() does
			# `_prep.add_child(_overlay)`, so the bubble, the progress header and
			# the step-name Label all live under the screen. Scanning the tutorial
			# node instead read zero strings and made every assertion below pass
			# vacuously — which is what overlay_scan_found_no_text caught.
			# Scanning prep is also strictly wider: it covers leaks into
			# PrepScreen's own labels, not just the overlay's.
			var texts: Array[String] = []
			_collect_text(prep, texts)
			scanned += texts.size()
			for text in texts:
				for key in keys:
					var k := str(key)
					_h.item()
					if text.contains(k):
						_h.fail("overlay_shows_enum_key",
							"[%s] 第 %s 步时，教学界面上出现了枚举名 %s：%s"
								% [locale, k, k, text])

	# An empty scan would make every assertion above vacuous.
	_h.expect(scanned > 0, "overlay_scan_found_no_text",
		"扫了整个教学界面一个字符串都没读到 —— 扫描逻辑失效了，上面的断言全是空过")

	tutorial.finish()
	tutorial.queue_free()
	prep.queue_free()
	await get_tree().process_frame


func _collect_text(node: Node, out: Array[String]) -> void:
	if node is Label:
		var t := str((node as Label).text)
		if not t.strip_edges().is_empty():
			out.append(t)
	elif node is Button:
		var t2 := str((node as Button).text)
		if not t2.strip_edges().is_empty():
			out.append(t2)
	elif node is RichTextLabel:
		var t3 := str((node as RichTextLabel).text)
		if not t3.strip_edges().is_empty():
			out.append(t3)
	for child in node.get_children():
		_collect_text(child, out)
