extends Node

# MatchStateService 的独立门禁（D1 验收条款：每个子服务有独立 headless 测试）。
#
# 六个服务里这个最该有测试：它决定客户端**接受还是丢弃**一份房间状态。判错的症状
# 不是崩溃，而是"界面停在上一秒不动"或"状态莫名回退"，两种都极难从日志看出根因。
#
# 应用规则（状态信封 RFC 第六节）：
#   epoch 不同 -> 接受；seq 未前进 -> 丢弃；否则 -> 整份替换（不要求连号）
#
# 最后那条"不要求连号"是**刻意的**：全量快照跳号直接应用就是对的，这正是不做
# delta 换来的漏包自愈。它长得像 bug，所以这里专门有一条用例钉住它 ——
# 免得后来者"顺手修好"，把自愈能力改没了。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const MatchState := preload("res://scripts/multiplayer/MatchStateService.gd")
const CHECK_NAME := "match_state"

var _h: RefCounted
var _now := 1000.0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_check_bump_seq()
	_check_first_envelope()
	_check_stale_is_dropped()
	_check_gap_is_applied()
	_check_epoch_change_resets_comparison()
	_check_judgement_does_not_commit()
	_check_reset_applied()
	_check_receipt_roundtrip()
	_check_receipt_ring_is_bounded()
	_h.finish(get_tree())


func _make() -> RefCounted:
	var svc: RefCounted = MatchState.new()
	svc.configure(func() -> float: return _now)
	return svc


# --- 序号 ---------------------------------------------------------------------

func _check_bump_seq() -> void:
	var svc := _make()
	var room := {"state_seq": 0}
	_h.expect(int(svc.bump_seq(room)) == 1, "bump_first", "第一次递增应得到 1")
	_h.expect(int(room.get("state_seq", -1)) == 1, "bump_not_written", "递增结果必须写回房间")
	svc.bump_seq(room)
	_h.expect(int(room.get("state_seq", -1)) == 2, "bump_second", "第二次应得到 2")

	# 房间没有 state_seq 字段时按 0 起。恢复出来的旧快照可能缺这个字段。
	var bare := {}
	_h.expect(int(svc.bump_seq(bare)) == 1, "bump_missing_field", "缺字段时应按 0 起")


# --- 应用判定 -----------------------------------------------------------------

func _check_first_envelope() -> void:
	var svc := _make()
	_h.expect(svc.should_apply(7, 1), "first_rejected", "第一份信封必须接受")


func _check_stale_is_dropped() -> void:
	var svc := _make()
	svc.mark_applied(7, 5)
	_h.expect(not svc.should_apply(7, 5), "same_seq_applied",
		"同一代内 seq 未前进（相等）必须丢弃 —— 重复应用会把界面拽回上一秒")
	_h.expect(not svc.should_apply(7, 4), "older_seq_applied",
		"同一代内更旧的 seq 必须丢弃")
	_h.expect(svc.should_apply(7, 6), "next_seq_dropped", "同一代内前进一号应接受")


# 跳号必须直接应用。这条长得像 bug，其实是不做 delta 换来的漏包自愈：
# 全量快照本身就是完整的，缺了中间几份不影响正确性。
func _check_gap_is_applied() -> void:
	var svc := _make()
	svc.mark_applied(7, 5)
	_h.expect(svc.should_apply(7, 99), "gap_dropped",
		"跳号的全量快照必须直接应用 —— 要求连号会让一次漏包永久卡住状态")


# epoch 变了说明服务器重启过，seq 从新一轮重新计数，不能拿旧号去比。
func _check_epoch_change_resets_comparison() -> void:
	var svc := _make()
	svc.mark_applied(7, 500)
	_h.expect(svc.should_apply(8, 1), "new_epoch_dropped",
		"新 epoch 的第一份 seq 很小，但必须接受 —— 按旧号比会把重启后的状态全丢掉")
	_h.expect(svc.should_apply(6, 1), "older_epoch_dropped",
		"epoch 不同就接受，不比大小 —— epoch 只表示「换了一轮」，没有顺序语义")


# 判定与提交分开：判定为真但后续检查失败时，绝不能把 applied_seq 往前推，
# 否则真正该应用的那一份会被当成迟到包丢掉。
func _check_judgement_does_not_commit() -> void:
	var svc := _make()
	svc.mark_applied(7, 5)
	svc.should_apply(7, 9)
	_h.expect(int(svc.applied_seq) == 5,
		"judgement_committed", "should_apply 不得改变已应用的位置 —— 提交只能由 mark_applied 做")
	svc.mark_applied(7, 9)
	_h.expect(int(svc.applied_seq) == 9, "mark_not_applied", "mark_applied 应记录新位置")


func _check_reset_applied() -> void:
	var svc := _make()
	svc.mark_applied(9, 42)
	svc.reset_applied()
	_h.expect(int(svc.applied_epoch) == 0 and int(svc.applied_seq) == 0,
		"reset_incomplete", "重置后应回到未应用过任何一份的状态")
	_h.expect(svc.should_apply(9, 1), "reset_still_stale",
		"重置后新一轮的第一份必须能进来 —— 留着旧号会把它当迟到包")


# --- 交易幂等 -----------------------------------------------------------------

func _check_receipt_roundtrip() -> void:
	var svc := _make()
	var room := {"tx_log": {}}
	_h.expect((svc.find_receipt(room, 0, "rid-1") as Dictionary).is_empty(),
		"receipt_phantom", "没记过的 rid 应找不到")
	_h.expect((svc.find_receipt(room, 0, "") as Dictionary).is_empty(),
		"receipt_empty_rid", "空 rid 不该匹配到任何回执")

	svc.record_receipt(room, 0, "rid-1", "treasure", {"ok": true, "gold": 7})
	var found: Dictionary = svc.find_receipt(room, 0, "rid-1")
	_h.expect(not found.is_empty(), "receipt_lost", "记过的 rid 必须找得回来 —— 找不回就会重做副作用")
	_h.expect(str(found.get("kind", "")) == "treasure", "receipt_kind", "回执应保留 kind")
	_h.expect(bool((found.get("result", {}) as Dictionary).get("ok", false)),
		"receipt_result", "回执应保留上次的结果，重发时原样重放")

	_h.expect((svc.find_receipt(room, 1, "rid-1") as Dictionary).is_empty(),
		"receipt_cross_slot", "座位之间必须隔离 —— 串座位等于把别人的交易结果当成自己的")


# 定长环：超出就丢最旧的。这份日志要随房间快照持久化，不设上限会让快照越滚越大。
func _check_receipt_ring_is_bounded() -> void:
	var svc := _make()
	var room := {"tx_log": {}}
	var cap: int = MatchState.TX_LOG_PER_SLOT
	for i in cap + 5:
		svc.record_receipt(room, 2, "rid-%d" % i, "altar", {"n": i})
	var entries: Array = (room.get("tx_log", {}) as Dictionary).get(2, [])
	_h.expect(entries.size() == cap,
		"ring_unbounded", "每座位回执应封顶在 %d 条，实际 %d" % [cap, entries.size()])
	_h.expect((svc.find_receipt(room, 2, "rid-0") as Dictionary).is_empty(),
		"ring_kept_oldest", "超出上限时应丢最旧的")
	_h.expect(not (svc.find_receipt(room, 2, "rid-%d" % (cap + 4)) as Dictionary).is_empty(),
		"ring_dropped_newest", "最新的一条必须还在 —— 丢新的等于刚发的交易会被重做")
