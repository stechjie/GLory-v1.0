extends RefCounted

# 检查场景统一的结果汇总与退出码。
#
# 用法：各检查脚本顶部 const CheckHarness := preload("res://tools/CheckHarness.gd")。
# 不用 class_name 是因为新增的全局类要靠编辑器导入才进 global_script_class_cache，
# 直接 --headless 跑场景时可能解析不到。
#
# 为什么需要它：tools/ 下的检查场景原本一律以无参 get_tree().quit() 结束，
# 退出码恒为 0。断言失败、资源缺失、依赖查询失败全都只打印到日志里，
# CI 和人都会把它读成"通过" —— 这就是"假绿"。
#
# 退出码（README「A3 — 让检查真正失败」）：
#   0  全部通过
#   1  有未被豁免的失败，或本次一个对象都没检查到（SKIP）
#
# SKIP 同样返回 1 是刻意的：检查集为空意味着"什么都没验证"，
# 把它当成通过正是要消灭的那类假绿。资源被临时移走时 CI 必须红。
#
# 允许列表（tools/check_allowlist.json）：
#   已知且暂时不修的失败可以登记进去，但**必须带到期日**。
#   到期后条目自动失效，并额外产生一条 allowlist_expired 失败。
#   不在列表里的失败一律硬失败；列表为空 = 全部硬失败。

const ALLOWLIST_PATH := "res://tools/check_allowlist.json"

var check_name: String

var _checked := 0
var _failures: Array[Dictionary] = []
var _suppressed: Array[Dictionary] = []
var _notes: Array[String] = []
var _allow: Array = []
var _allow_hits: Dictionary = {}
var _today := ""


func _init(p_name: String) -> void:
	check_name = p_name
	_today = Time.get_date_string_from_system()
	_load_allowlist()


# --- 记录 ---------------------------------------------------------------------

# 记一个"已检查的对象"。循环里不走 expect() 时手动调用，
# 否则检查集会被误判成空而报 SKIP。
func item(count: int = 1) -> void:
	_checked += maxi(0, count)


# 条件为真则通过。返回值等于条件，方便 `if not h.expect(...): continue`。
func expect(condition: bool, code: String, message: String) -> bool:
	_checked += 1
	if not condition:
		_record(code, message)
	return condition


# 无条件记一条失败（已经知道错在哪、不需要再判断时用）。
func fail(code: String, message: String) -> void:
	_checked += 1
	_record(code, message)


# 只进日志，不影响退出码。
func note(message: String) -> void:
	_notes.append(message)
	print("[%s] note: %s" % [check_name, message])


func failure_count() -> int:
	return _failures.size()


func checked_count() -> int:
	return _checked


# --- 收尾 ---------------------------------------------------------------------

func finish(tree: SceneTree) -> void:
	var status := "PASS"
	if not _failures.is_empty():
		status = "FAIL"
	elif _checked == 0:
		status = "SKIP"
		print("[%s] SKIP: 本次没有检查到任何对象。空检查集不算通过 —— " % check_name
			+ "通常意味着数据表没读到、目录不存在或过滤条件写错了。")

	if not _failures.is_empty():
		print("[%s] ===== 失败 %d 条 =====" % [check_name, _failures.size()])
		for f in _failures:
			print("[%s]   FAIL [%s] %s" % [check_name, str(f.get("code", "")), str(f.get("message", ""))])

	if not _suppressed.is_empty():
		print("[%s] ===== 允许列表豁免 %d 条（到期后自动变红）=====" % [check_name, _suppressed.size()])
		for s in _suppressed:
			print("[%s]   ALLOWED [%s] %s (expires=%s)" % [
				check_name, str(s.get("code", "")), str(s.get("message", "")), str(s.get("expires", ""))])

	# 没命中过的条目说明问题可能已经修好了，留着会让允许列表烂掉。
	# 只判定明确指名本检查的条目：check="*" 的条目可能是给别的检查用的，
	# 单跑一个检查看不到它在别处的命中，据此报 stale 会是误报。
	var stale: Array[String] = []
	for i in _allow.size():
		var entry: Dictionary = _allow[i]
		if str(entry.get("check", "")) != check_name:
			continue
		if not _allow_hits.has(i):
			stale.append("%s / %s / %s" % [
				str(entry.get("code", "*")), str(entry.get("match", "")), str(entry.get("why", ""))])
	if not stale.is_empty():
		print("[%s] ===== 允许列表里 %d 条本次没命中，建议删除 =====" % [check_name, stale.size()])
		for s in stale:
			print("[%s]   STALE %s" % [check_name, s])

	print("CHECK_RESULT name=%s status=%s checked=%d failures=%d allowed=%d stale=%d" % [
		check_name, status, _checked, _failures.size(), _suppressed.size(), stale.size()])

	tree.quit(0 if status == "PASS" else 1)


# --- 内部 ---------------------------------------------------------------------

func _record(code: String, message: String) -> void:
	var idx := _match_allow(code, message)
	if idx < 0:
		_failures.append({"code": code, "message": message})
		return
	var entry: Dictionary = _allow[idx]
	_allow_hits[idx] = true
	_suppressed.append({"code": code, "message": message, "expires": str(entry.get("expires", ""))})


# 返回命中的允许列表下标；没命中返回 -1。
# 到期条目不再豁免，并额外记一条失败，避免"登记一次就永远绿"。
func _match_allow(code: String, message: String) -> int:
	for i in _allow.size():
		var entry: Dictionary = _allow[i]
		var want_check := str(entry.get("check", "*"))
		if want_check != "*" and want_check != check_name:
			continue
		var want_code := str(entry.get("code", "*"))
		if want_code != "*" and want_code != code:
			continue
		var want_match := str(entry.get("match", ""))
		if not want_match.is_empty() and not message.contains(want_match):
			continue
		var expires := str(entry.get("expires", ""))
		if expires.is_empty():
			_allow_hits[i] = true
			_failures.append({
				"code": "allowlist_no_expiry",
				"message": "允许列表条目缺 expires，不予豁免：%s / %s" % [want_code, want_match],
			})
			return -1
		# ISO 日期可直接字符串比较
		if expires < _today:
			_allow_hits[i] = true
			_failures.append({
				"code": "allowlist_expired",
				"message": "允许列表条目已于 %s 到期（今天 %s），不再豁免：%s" % [expires, _today, message],
			})
			return -1
		return i
	return -1


func _load_allowlist() -> void:
	if not FileAccess.file_exists(ALLOWLIST_PATH):
		return
	var text := FileAccess.get_file_as_string(ALLOWLIST_PATH)
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		# 允许列表本身坏掉时不能静默当空表跑 —— 那样等于悄悄放宽了判定。
		_failures.append({
			"code": "allowlist_parse_failed",
			"message": "%s 解析失败，无法确定豁免范围" % ALLOWLIST_PATH,
		})
		return
	var entries: Variant = (parsed as Dictionary).get("entries", [])
	if not (entries is Array):
		_failures.append({
			"code": "allowlist_parse_failed",
			"message": "%s 的 entries 不是数组" % ALLOWLIST_PATH,
		})
		return
	for e in (entries as Array):
		if e is Dictionary:
			_allow.append(e)
