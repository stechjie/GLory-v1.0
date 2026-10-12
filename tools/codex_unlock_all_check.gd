extends Node

# 一键解锁全部图鉴（2026-10-11 用户测试请求）。
#
# 用途：遍历 CodexService 的全部分类，把所有 collectible 条目 id 一次性
# mark_seen_many 进玩家档案，再逐分类断言 progress_for == (n, n)。
# 走游戏自己的序列化（mark_seen_many -> save_profile），不手改 profile.json，
# 存档格式漂移风险为零；重复执行是幂等的（mark_seen_many 内部去重）。
#
# ⚠️ 游戏本体运行时会持有内存档案并随时 save_profile 覆盖回磁盘 ——
# 必须先关掉游戏再跑本工具，否则解锁会被游戏进程的下次存档冲掉。
#
# 用法：
#   Godot_v4.7.2-stable_win64_console.exe --headless --path <工程根> \
#       res://tools/codex_unlock_all_check.tscn
#
# 退出码遵循 CheckHarness：0 = 全部分类已满；1 = 有分类未满（真失败）。

const H := preload("res://tools/CheckHarness.gd")

var h


func _ready() -> void:
	h = H.new("codex_unlock_all")

	# --- 收集：全分类 collectible id + 解锁前进度 -----------------------
	var all_ids: Array[String] = []
	var per_category := {}
	for meta in CodexService.CATEGORIES:
		var key := str(meta.get("key", ""))
		var list: Array[Dictionary] = CodexService.entries_for(key)
		var ids: Array[String] = []
		for e in list:
			if bool(e.get("collectible", true)):
				ids.append(str(e.get("id", "")))
		per_category[key] = {
			"total": ids.size(),
			"before": CodexService.progress_for(key).x,
		}
		all_ids.append_array(ids)

	h.expect(all_ids.size() > 0, "entries_found",
		"collectible 条目总数应 > 0，实际 %d" % all_ids.size())
	if all_ids.is_empty():
		h.finish(get_tree())
		return

	var before_total := 0
	for key in per_category:
		before_total += int(per_category[key]["before"])
	h.note("解锁前：%d / %d" % [before_total, all_ids.size()])

	# --- 执行：一次写入，内部只 save_profile 一次 -----------------------
	PlayerProfile.mark_seen_many(all_ids)

	# --- 验证：逐分类，collectible 条目必须全部 is_unlocked ---------------
	# 注意：状态 / 元素是参考物料（collectible=false，永远可读、不计收集进度），
	# 不能拿 progress_for 的绝对值跟条目总数比 —— 判据只看 collectible 条目。
	for meta in CodexService.CATEGORIES:
		var key := str(meta.get("key", ""))
		var list: Array[Dictionary] = CodexService.entries_for(key)
		var collectible := 0
		var unlocked := 0
		for e in list:
			if bool(e.get("collectible", true)):
				collectible += 1
				h.item()
				if CodexService.is_unlocked(e):
					unlocked += 1
				else:
					h.fail("entry_locked", "%s 分类还有未解锁条目：%s" % [key, str(e.get("id", ""))])
		# 状态 / 元素是参考分类，collectible=0 属正常，不做非空断言。
		h.note("  %-10s %d/%d（解锁前 %d）" % [
			key, unlocked, collectible, int(per_category[key]["before"])])

	# --- 落盘确认：档案里 codex_seen 至少要覆盖全部 id -------------------
	var saved: Array = []
	var parsed = JSON.parse_string(
		FileAccess.get_file_as_string("user://profile.json"))
	if typeof(parsed) == TYPE_DICTIONARY:
		saved = parsed.get("codex_seen", [])
	h.expect(saved.size() >= all_ids.size(), "profile_persisted",
		"profile.json codex_seen=%d，应 >= %d" % [saved.size(), all_ids.size()])

	var after_total := 0
	for meta in CodexService.CATEGORIES:
		after_total += CodexService.progress_for(str(meta.get("key", ""))).x
	h.note("解锁后：%d / %d（profile.json codex_seen=%d）" % [
		after_total, all_ids.size(), saved.size()])
	h.finish(get_tree())
