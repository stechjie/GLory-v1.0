extends Node

# 9.25 追加订正门禁：商店刷新「教学免费 = 无限次」的判定必须**同源**。
#
# 事故形态（用户 2026-09-25 回执：教程里刷新刷几次就点不动了）：
#   刷新费用被算了三遍 ——
#     * ShopPanel.refresh()                         ← 画按钮、写「免费」标签
#     * PrepBoardController._on_refresh_shop()      ← 真正扣钱
#     * PrepUI._on_refresh_shop_control_pressed()   ← 决定放不放燃烧动画
#   第三处只抄了 `TreasureService.has_set("money")`，漏掉 `GameState.tutorial_mode`。
#   于是：按钮由**正确**判定置成「免费、可点」，点下去却被**错误**判定按递增价拦住
#   （`if GameState.gold < refresh_cost: return`），既不播动画也不刷新 ——
#   用户看到的就是「写着免费、点不动」。
#   TutorialMode.shop_refresh_all_free() 的注释当时已写明「判定必须只在这一处」，
#   但它只点名了两处，第三处漏了。
#
# 判据分三层：
#   A 行为：EconomyService.shop_refresh_cost 的档位语义（纯函数，期望值独立算）。
#   B 行为：教程模式下 all_free 为真 ⇒ 刷到大次数仍为 0（「免费」即「无限次」）。
#   C 结构：**每一处** `EconomyService.shop_refresh_cost(` 调用点所在的函数体内，
#      都要出现 `TutorialMode.shop_refresh_all_free()`，且不得再出现手抄的
#      `all_free := TreasureService.has_set("money")`。
#      —— C 是唯一能抓住本次事故的判据：A / B 都不管三处是否同源。
#
# ★ C 扫**全目录**而不是固定三个文件名：本轮的错恰恰是「第三处没人想到」。
#   写死清单等于把下一次同类错误提前豁免。文件集合为空时由 call_site_count 兜底报红。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const EconomyServiceScript := preload("res://scripts/economy/EconomyService.gd")

const CHECK_NAME := "shop_refresh_free_source"

# 调用点所在函数体**必须**出现的判定源（字面上同一个函数）。
const REQUIRED_SOURCE := "TutorialMode.shop_refresh_all_free()"
# 旧的、手抄的 all_free 写法：不允许再出现在 shop_refresh_cost 所在函数里。
const FORBIDDEN_ALLOFREE := "all_free := TreasureService.has_set(\"money\")"
const CALL_TOKEN := "EconomyService.shop_refresh_cost("

# 只扫**客户端层**。服务端账本 `scripts/multiplayer/EconomyLedger.gd::_shop_refresh`
# 刻意不在范围内：它按 payload 里的 owned_treasures 判 free（权威对账），而且教学是
# 纯本地流程、根本不走服务端。那份分层由 `_check_server_layer` 单独钉住，
# 免得有人「顺手」把客户端教学状态塞进服务端。
# ★ 不写死三个文件名：本轮的错恰恰是「第三处没人想到」，写死清单等于提前豁免下一次。
const SCAN_ROOTS: Array[String] = ["res://scenes"]

# 服务端权威账本：由 _check_server_layer 单独钉分层（不用同一份 all_free 判定）。
const SERVER_LEDGER_PATH := "res://scripts/multiplayer/EconomyLedger.gd"


func _ready() -> void:
	var harness := CheckHarness.new(CHECK_NAME)
	_check_cost_tiers(harness)
	_check_tutorial_all_free(harness)
	_check_call_sites_same_source(harness)
	_check_server_layer(harness)
	harness.finish(get_tree())


# --- A 行为：费用档位 -----------------------------------------------------------

func _check_cost_tiers(harness: RefCounted) -> void:
	# 期望值独立给，不借助被测：0 次免费是既有设计；1 次起收费是递增价的目标行为；
	# all_free 恒 0 是「永久免费」的实现面。
	harness.expect(EconomyServiceScript.shop_refresh_cost(0, false) == 0,
		"cost_first_free",
		"shop_refresh_cost(uses=0, all_free=false) 应为 0（首次免费是既有设计）")
	harness.expect(EconomyServiceScript.shop_refresh_cost(1, false) > 0,
		"cost_escalates",
		"shop_refresh_cost(uses=1, all_free=false) 应 > 0 —— 漏抄 all_free 时就会走到这里收费")
	harness.expect(EconomyServiceScript.shop_refresh_cost(12, false) > 0,
		"cost_escalates_large",
		"shop_refresh_cost(uses=12, all_free=false) 应 > 0")
	harness.expect(EconomyServiceScript.shop_refresh_cost(1, true) == 0,
		"cost_all_free_zero",
		"shop_refresh_cost(uses=1, all_free=true) 应为 0")
	harness.expect(EconomyServiceScript.shop_refresh_cost(999, true) == 0,
		"cost_all_free_zero_large",
		"shop_refresh_cost(uses=999, all_free=true) 应为 0 —— 免费即无限次")
	# 递增必须是严格递增，否则「大次数仍免费」这条在本判据上没有区分力。
	var c1 := EconomyServiceScript.shop_refresh_cost(1, false)
	var c2 := EconomyServiceScript.shop_refresh_cost(8, false)
	harness.expect(c2 > c1, "cost_strictly_rising",
		"shop_refresh_cost 应随次数严格递增（uses=1 -> %d，uses=8 -> %d）" % [c1, c2])


# --- B 行为：教程恒免费 ---------------------------------------------------------

func _check_tutorial_all_free(harness: RefCounted) -> void:
	# 改前先存，改后整块还原 —— 门禁不许给后续判据留状态。
	var saved := GameState.tutorial_mode
	GameState.tutorial_mode = true
	# 走 autoload（= 生产的调用路径），不另造实例，免得探针里的调法和线上不是同一条。
	var all_free: bool = TutorialMode.shop_refresh_all_free()
	var cost: int = EconomyServiceScript.shop_refresh_cost(999, all_free)
	GameState.tutorial_mode = saved

	harness.expect(all_free, "tutorial_all_free_true",
		"教程模式下 TutorialMode.shop_refresh_all_free() 必须为真")
	harness.expect(cost == 0, "tutorial_refresh_always_free",
		"教程模式 all_free 为真时，刷 999 次费用仍必须为 0（实际 %d）" % cost)


# --- C 结构：所有调用点同源 -----------------------------------------------------

func _check_call_sites_same_source(harness: RefCounted) -> void:
	var files: Array[String] = []
	for root in SCAN_ROOTS:
		_collect_gd(root, files)
	files.sort()

	var sites := 0
	for path in files:
		var text := FileAccess.get_file_as_string(path)
		if text.is_empty() or not text.contains(CALL_TOKEN):
			continue
		var lines := text.split("\n")
		for i in lines.size():
			if _is_comment(lines[i]) or not lines[i].contains(CALL_TOKEN):
				continue
			sites += 1
			var start := _func_start(lines, i)
			var end := _func_end(lines, i)
			var body := "\n".join(lines.slice(start, end))
			var owner := lines[start].strip_edges()

			# 注释感知：函数体里"提到"判定源不算数，必须是活代码。
			harness.expect(_has_live_line(body, REQUIRED_SOURCE),
				"call_site_missing_same_source",
				"%s:%d 所在的 `%s` 里没有 %s —— 刷新费用判定与商店按钮/扣费不同源，教学会「写着免费却点不动」"
					% [path, i + 1, owner, REQUIRED_SOURCE])
			# 反向哨兵：旧的手抄写法不许回潮。
			harness.expect(not _has_live_line(body, FORBIDDEN_ALLOFREE),
				"call_site_stale_all_free",
				"%s:%d 所在的 `%s` 里还在用手抄的 `%s` —— 应改为 %s"
					% [path, i + 1, owner, FORBIDDEN_ALLOFREE, REQUIRED_SOURCE])

	# 一个调用点都没扫到 = 什么都没验证。扫描根或过滤条件写错时靠这条硬报红。
	harness.expect(sites >= 3, "call_site_count",
		"应至少扫到 3 处 shop_refresh_cost 调用点（PrepUI / PrepBoardController / ShopPanel），实际 %d —— 扫描根目录或过滤条件可能写错了" % sites)


# --- D 结构：服务端分层（反向哨兵） ---------------------------------------------
#
# 服务端权威账本**不能**吃客户端教学状态：教学是纯本地流程，不走服务端网络。
# 它判 free 的数据源只能是 payload 里的 owned_treasures（客户端随意图上报、
# 服务端自行判定）。这条钉的是「别顺手往服务端塞 GameState.tutorial_mode」——
# 那会让权威层反过来依赖客户端状态。
func _check_server_layer(harness: RefCounted) -> void:
	var text := FileAccess.get_file_as_string(SERVER_LEDGER_PATH)
	if not harness.expect(not text.is_empty(), "server_ledger_readable",
			"读不到 %s" % SERVER_LEDGER_PATH):
		return
	var lines := text.split("\n")
	var found := false
	for i in lines.size():
		if _is_comment(lines[i]) or not lines[i].contains(CALL_TOKEN):
			continue
		found = true
		var body := "\n".join(lines.slice(_func_start(lines, i), _func_end(lines, i)))
		var owner := lines[_func_start(lines, i)].strip_edges()
		harness.expect(_has_live_line(body, "TreasureService.has_set_in("),
			"server_free_from_payload",
			"%s:%d 所在的 `%s`：服务端 free 必须来自 payload（TreasureService.has_set_in）"
				% [SERVER_LEDGER_PATH, i + 1, owner])
		harness.expect(not _has_live_line(body, "GameState.tutorial_mode"),
			"server_must_not_read_tutorial",
			"%s:%d 所在的 `%s`：服务端账本读了 GameState.tutorial_mode —— 权威层不得依赖客户端教学状态"
				% [SERVER_LEDGER_PATH, i + 1, owner])
	harness.expect(found, "server_call_site_found",
		"%s 里应能找到 shop_refresh_cost 调用点（找不到说明账本结构变了，这条判据已失效）" % SERVER_LEDGER_PATH)


func _collect_gd(root: String, out: Array[String]) -> void:
	var dir := DirAccess.open(root)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not entry.begins_with("."):
			var p := root.path_join(entry)
			if dir.current_is_dir():
				_collect_gd(p, out)
			elif entry.ends_with(".gd"):
				out.append(p)
		entry = dir.get_next()
	dir.list_dir_end()


func _func_start(lines: PackedStringArray, idx: int) -> int:
	var i := idx
	while i > 0:
		if _is_func_line(lines[i]):
			return i
		i -= 1
	return 0


func _func_end(lines: PackedStringArray, idx: int) -> int:
	var i := idx + 1
	while i < lines.size():
		if _is_func_line(lines[i]):
			return i
		i += 1
	return lines.size()


# ★ 必须连 `static func` 一起认。第一版只认 `func `，而 EconomyLedger.gd 全篇是
#   `static func` —— 回溯找不到任何函数头，`_func_start` 直接返回到文件首行的
#   `class_name EconomyLedger`，报出来的"所在函数"是假的（排查时被这条误导过）。
func _is_func_line(line: String) -> bool:
	var s := line.strip_edges()
	return s.begins_with("func ") or s.begins_with("static func ")


func _is_comment(line: String) -> bool:
	return line.strip_edges().begins_with("#")


# 只在非注释行里找 token —— 把调用点整行注释掉时，"文本还在"证明不了"逻辑还在"。
func _has_live_line(body: String, token: String) -> bool:
	for raw in body.split("\n"):
		if _is_comment(raw):
			continue
		if raw.contains(token):
			return true
	return false
