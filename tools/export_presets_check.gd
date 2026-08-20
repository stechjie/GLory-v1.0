extends Node

# Drift gate for export_presets.template.cfg.
#
# The template is a committed copy of a gitignored file, and a committed copy of a
# live file rots unless something checks it. This is that something: change a preset
# without regenerating the template and this check goes red, naming the fields that
# disagree.
#
# What it deliberately does NOT do: fail when export_presets.cfg is missing. That is
# the normal state of a fresh clone, and going red there would train people to ignore
# the check. Exporting without the file is already blocked by tools/android_smoke.sh,
# which refuses to export when exclude_filter is empty.

const CheckHarness := preload("res://tools/CheckHarness.gd")
const Template := preload("res://tools/ExportPresetsTemplate.gd")
const CHECK_NAME := "export_presets"

const GITIGNORE_PATH := "res://.gitignore"

var _h: RefCounted


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	var template_src := _read_template()
	if not template_src.is_empty():
		_check_template_is_useful(template_src)
		_check_template_carries_no_secrets(template_src)
		_check_no_drift(template_src)
	_check_live_file_stays_ignored()
	_h.finish(get_tree())


func _read_template() -> String:
	var src := FileAccess.get_file_as_string(Template.TEMPLATE_PATH)
	_h.expect(not src.is_empty(), "template_missing",
		"读不到 %s。它是同事新克隆时唯一能拿到 exclude_filter 的地方，跑 tools/export_presets_template.tscn 生成。"
			% Template.TEMPLATE_PATH)
	return src


# A template that ships an empty exclude_filter is worse than none: it looks like a
# solution while still letting backups/ into the APK. That filter is the entire
# reason this file is committed.
func _check_template_is_useful(template_src: String) -> void:
	var presets := 0
	var filtered := 0
	for raw_line in template_src.split("\n"):
		var line := str(raw_line)
		if line.begins_with("name="):
			presets += 1
		if line.begins_with("exclude_filter=") and line != "exclude_filter=\"\"":
			filtered += 1
	_h.expect(presets > 0, "template_has_no_presets", "%s 里一个预设都没有" % Template.TEMPLATE_PATH)
	_h.expect(filtered >= presets, "template_exclude_filter_empty",
		"%s 里有 %d 个预设但只有 %d 个带 exclude_filter —— 空过滤器会把 backups/ 打进包"
			% [Template.TEMPLATE_PATH, presets, filtered])


# The one thing that must never happen to this file: a keystore password reaching git.
func _check_template_carries_no_secrets(template_src: String) -> void:
	for raw_line in template_src.split("\n"):
		var line := str(raw_line)
		var key := Template.key_of(line)
		if key.is_empty() or not Template.SECRET_KEYS.has(key):
			continue
		_h.expect(line == "%s=\"\"" % key, "template_leaks_secret",
			"%s 的 %s 不是空值 —— 模板在 git 里，密钥不能进去" % [Template.TEMPLATE_PATH, key])


func _check_no_drift(template_src: String) -> void:
	if not FileAccess.file_exists(Template.LIVE_PATH):
		_h.note("本机没有 %s（新克隆的正常状态）。跳过漂移比对；拷贝模板即可开始出包。" % Template.LIVE_PATH)
		return
	var live_src := FileAccess.get_file_as_string(Template.LIVE_PATH)
	if not _h.expect(not live_src.is_empty(), "live_unreadable", "读不到 %s" % Template.LIVE_PATH):
		return

	var live := Template.normalize(live_src)
	var tpl := Template.normalize(template_src)
	if live == tpl:
		_h.item()
		_h.note("模板与本机 export_presets.cfg 一致（%d 行，密钥字段除外）" % live.size())
		return

	# Name the fields, not just "they differ" — the fix is to regenerate, and knowing
	# what moved is what tells you whether the regeneration is safe.
	var diffs := _differing_keys(live, tpl)
	if diffs.is_empty():
		diffs = _first_differing_line(live, tpl)
	_h.fail("template_drifted",
		"%s 与本机 export_presets.cfg 已漂移（%s）。跑 tools/export_presets_template.tscn 重新生成后一并提交。"
			% [Template.TEMPLATE_PATH, diffs])


func _differing_keys(live: PackedStringArray, tpl: PackedStringArray) -> String:
	var live_map := _to_map(live)
	var tpl_map := _to_map(tpl)
	var out: PackedStringArray = []
	for key in live_map.keys():
		if not tpl_map.has(key):
			out.append("模板缺 %s" % str(key))
		elif str(tpl_map[key]) != str(live_map[key]):
			out.append("%s 值不同" % str(key))
	for key in tpl_map.keys():
		if not live_map.has(key):
			out.append("本机缺 %s" % str(key))
	if out.is_empty():
		return ""
	if out.size() > 6:
		var head := out.slice(0, 6)
		return "%s 等 %d 处" % [", ".join(head), out.size()]
	return ", ".join(out)


# Every key matched but the files still differ, so the difference is structural:
# line order, section placement or stray blank lines. Point at the first one rather
# than leaving the reader to diff 300 lines by hand.
func _first_differing_line(live: PackedStringArray, tpl: PackedStringArray) -> String:
	var shared := mini(live.size(), tpl.size())
	for i in shared:
		if str(live[i]) != str(tpl[i]):
			return "第 %d 行起不同：本机 %s / 模板 %s" % [i + 1, _clip(str(live[i])), _clip(str(tpl[i]))]
	return "行数不同：本机 %d 行，模板 %d 行" % [live.size(), tpl.size()]


func _clip(line: String) -> String:
	if line.is_empty():
		return "<空行>"
	if line.length() <= 48:
		return "\"%s\"" % line
	return "\"%s…\"" % line.substr(0, 48)


# Keys are scoped by their [section] so two presets' identically named options do
# not collide and hide a real difference.
func _to_map(lines: PackedStringArray) -> Dictionary:
	var out := {}
	var section := ""
	for raw_line in lines:
		var line := str(raw_line)
		if line.begins_with("[") and line.ends_with("]"):
			section = line
			continue
		var key := Template.key_of(line)
		if key.is_empty():
			continue
		out["%s %s" % [section, key]] = line.substr(key.length() + 1)
	return out


# If someone ever un-ignores the live file, the next commit ships the keystore
# password. Cheap to assert, expensive to miss.
func _check_live_file_stays_ignored() -> void:
	var gitignore := FileAccess.get_file_as_string(GITIGNORE_PATH)
	if gitignore.is_empty():
		_h.note("读不到 %s，跳过忽略规则断言" % GITIGNORE_PATH)
		return
	var ignored := false
	for raw_line in gitignore.split("\n"):
		if str(raw_line).strip_edges() == "export_presets.cfg":
			ignored = true
			break
	_h.expect(ignored, "live_no_longer_ignored",
		".gitignore 里没有 export_presets.cfg 了 —— 一旦提交就会把 keystore 口令带进 git")
