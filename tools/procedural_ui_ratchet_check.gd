extends Node

# V3 P1-08 棘轮：业务代码里自绘 UI 的数量只能下降。
#
# 背景：复审时全仓有几十处 `StyleBoxFlat.new()` 和 `Button.new()`，每处各自写死
# hex 和尺寸，于是同一个「确认框」在教学里和主菜单里长得不一样。迁移是分批的，
# 而分批迁移最常见的失败方式不是「没迁」，是**边迁边加** —— 这一批减了 3 处，
# 另一个页面又新写了 4 处，总数看着在动，观感一致性没有任何改善。
#
# 所以这条门禁盯的是**总数**，并且按文件记账：
#   * 总数只能下降。升高就红。
#   * 单个文件也只能下降。总数持平但从 A 文件搬到 B 文件，同样红 ——
#     那不是迁移，是换个地方藏。
#   * 基线降下来之后必须显式收紧（跑 --update-baseline），否则「只能下降」
#     会退化成「不能高于最初那个很松的数」。
#
# ⚠️ 这条门禁默认**只读**。`--update-baseline` 是唯一的写入路径 ——
# 普通运行自愈更新基线，等于让棘轮自己松开（同 asset_manifest 的合同）。
#
# 主题目录不算：`ui/theme/` 就是这些调用**应该**在的地方。把它算进来会逼着
# 迁移把 StyleBox 从主题里也删掉，而那正好是反的。

const CheckHarness := preload("res://tools/CheckHarness.gd")

const CHECK_NAME := "procedural_ui_ratchet"
const BASELINE_PATH := "res://data/qa/procedural_ui_baseline.json"

# 扫描范围：业务代码。theme 是这些调用的正当归属，debug/officetest 不进包。
const SCAN_ROOTS := ["res://scenes", "res://ui", "res://scripts"]
const EXCLUDED_PREFIXES := [
	"res://ui/theme/",
	"res://scenes/debug/",
]

const TRACKED := ["StyleBoxFlat.new()", "Button.new()"]

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	var counts := _scan()
	var args := OS.get_cmdline_user_args()
	if args.has("--update-baseline"):
		_write_baseline(counts)
		print("[%s] 基线已按当前实测收紧：%s" % [CHECK_NAME, JSON.stringify(_totals(counts))])
		_h.finish(get_tree())
		return
	_compare(counts)
	_h.finish(get_tree())


func _scan() -> Dictionary:
	var out := {}
	for root in SCAN_ROOTS:
		_scan_dir(root, out)
	return out


func _scan_dir(dir_path: String, out: Dictionary) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var full := "%s/%s" % [dir_path, entry]
		if dir.current_is_dir():
			if not entry.begins_with("."):
				_scan_dir(full, out)
		elif entry.ends_with(".gd") and not _is_excluded(full):
			var src := FileAccess.get_file_as_string(full)
			var per_file := {}
			for token in TRACKED:
				var n := _count_occurrences(src, token)
				if n > 0:
					per_file[token] = n
			if not per_file.is_empty():
				out[full] = per_file
		entry = dir.get_next()
	dir.list_dir_end()


func _is_excluded(path: String) -> bool:
	for prefix in EXCLUDED_PREFIXES:
		if path.begins_with(prefix):
			return true
	return false


# 只数**代码里**的调用。注释里提到 `Button.new()` 是常事 —— 本轮已经三次栽在
# 「整文件 contains 被自己写的注释满足」上，这里同一个坑换了个方向：
# 注释里的提及会把计数顶高，逼人去改注释而不是改代码。
func _count_occurrences(src: String, token: String) -> int:
	var n := 0
	for raw in src.split("\n"):
		var line := str(raw)
		var code := line
		var hash_at := code.find("#")
		if hash_at >= 0:
			code = code.substr(0, hash_at)
		if code.strip_edges().is_empty():
			continue
		var from := 0
		while true:
			var at := code.find(token, from)
			if at < 0:
				break
			n += 1
			from = at + token.length()
	return n


func _totals(counts: Dictionary) -> Dictionary:
	var totals := {}
	for token in TRACKED:
		totals[token] = 0
	for path in counts.keys():
		var per_file: Dictionary = counts[path]
		for token in per_file.keys():
			totals[token] = int(totals[token]) + int(per_file[token])
	return totals


func _compare(counts: Dictionary) -> void:
	var raw := FileAccess.get_file_as_string(BASELINE_PATH)
	if not _h.expect(not raw.is_empty(), "baseline_missing",
			"%s 不存在 —— 跑一次 --update-baseline 生成" % BASELINE_PATH):
		return
	var parsed = JSON.parse_string(raw)
	if not _h.expect(parsed is Dictionary, "baseline_unparsable",
			"%s 不是合法 JSON" % BASELINE_PATH):
		return
	var baseline: Dictionary = parsed
	var base_totals: Dictionary = baseline.get("totals", {})
	var base_files: Dictionary = baseline.get("files", {})
	var totals := _totals(counts)

	# 1. 总数只能下降。
	for token in TRACKED:
		var now := int(totals.get(token, 0))
		var was := int(base_totals.get(token, 0))
		_h.expect(now <= was, "procedural_ui_count_rose",
			"业务代码里的 %s 从 %d 涨到了 %d —— 迁移期间只能下降" % [token, was, now])

	# 2. 单文件也只能下降：总数持平但换个文件写，不是迁移，是换地方藏。
	var risen: Array[String] = []
	for path in counts.keys():
		var per_file: Dictionary = counts[path]
		var base_file: Dictionary = base_files.get(path, {})
		for token in per_file.keys():
			var now := int(per_file[token])
			var was := int(base_file.get(token, 0))
			if now > was:
				risen.append("%s %s %d->%d" % [path, token, was, now])
	_h.expect(risen.is_empty(), "procedural_ui_moved_not_removed",
		"这些文件的自绘调用变多了（总数没涨也不算迁移）：%s" % str(risen))

	# 3. 降下来之后必须收紧基线。不收紧的话，「只能下降」会退化成
	#    「不能高于最初那个很松的数」，之后随便加回去都不会红。
	var slack: Array[String] = []
	for token in TRACKED:
		var now := int(totals.get(token, 0))
		var was := int(base_totals.get(token, 0))
		if now < was:
			slack.append("%s 实测 %d < 基线 %d" % [token, now, was])
	_h.expect(slack.is_empty(), "baseline_not_tightened",
		("已经降下来了但基线还是旧值，棘轮没收紧："
			+ "%s —— 跑 `--update-baseline` 并提交") % str(slack))

	# 4. 守卫：扫不到东西时上面三条全都恒真。
	_h.expect(counts.size() >= 10, "scan_found_almost_nothing",
		"只扫到 %d 个文件有自绘调用 —— 扫描范围可能已经失效" % counts.size())


func _write_baseline(counts: Dictionary) -> void:
	var payload := {
		"schema": "glory.procedural_ui_ratchet.v1",
		"note": ("业务代码里自绘 UI 的调用计数。只能下降；降下来之后要跑"
			+ " --update-baseline 收紧，否则棘轮会松掉。ui/theme 与 scenes/debug 不计。"),
		"totals": _totals(counts),
		"files": counts,
	}
	var f := FileAccess.open(BASELINE_PATH, FileAccess.WRITE)
	if f == null:
		push_error("cannot write %s" % BASELINE_PATH)
		return
	f.store_string(JSON.stringify(payload, "\t", true))
	f.close()
