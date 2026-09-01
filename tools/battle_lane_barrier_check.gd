extends Node

# V2 P1-02 的门禁：车道晶柱只作为边界提示，不得再当画面主体。
#
# 背景（2026-08-29 固定 seed round 1 中段截图实测）：晶柱此前**从不设置 modulate**，
# 也就是全亮度全不透明，于是成了画面里最亮、对比最强的物体，比角色还抢眼。
#
# 这里守的是**机械不变式**，不是"好不好看" —— 后者只能人看图定，也确实是由用户
# 看改前/改后截图定的。门禁的意义是把那次人工判断固化下来：
#   * 谁把 alpha 调回接近不透明 -> 红（重新压住画面）
#   * 谁**再把高度缩短** -> 红（第一版这么干过，用户否决："看不出那种隔开的感觉"）
# 而不是等下一次有人截图才发现。
#
# 刻意没有做 V2 原文那条"晶柱遮挡角色像素占比 >10% 失败"：实测晶柱本来就落在三条
# 车道的间隙里，横向不与角色重叠，那条断言会恒真通过 —— 一个证明不了任何事的绿灯。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const BarrierScript := preload("res://scenes/battle/BattleLaneBarrier2D.gd")
const CHECK_NAME := "battle_lane_barrier"

# 常态 alpha 的允许区间。
#
# **不是 V2 原文的 0.15-0.30。** 那个区间是在"同时把高度缩到 45%-60%"的前提下给的，
# 而那条已被用户实看否决（见 BattleLaneBarrier2D 文件头）。恢复铺满高度之后，
# 0.22 太淡、看不出隔开，用户实看后定为 0.45。前提没了，判据跟着失效。
#
# 记一句以免将来误会：这里放宽区间**不是为了让检查变绿**。绿是因为参数按用户
# 实看结果改对了；区间跟着改，是因为旧区间守的是一个已被推翻的设计。
const STEADY_ALPHA_MIN := 0.30
const STEADY_ALPHA_MAX := 0.55

# 晶柱 scale 赋值的唯一合法形态（空白归一后）。y 分量必须是"铺满战场可视高度"，
# 后面不得再乘任何东西。见 _check_height_is_not_reduced() 里为什么必须精确比对。
const EXPECTED_BARRIER_SCALE_STMT := \
	"barrier.scale = Vector2(0.42, maxf(0.1, (bot_y - top_y) / 512.0))"

var _h: RefCounted


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_check_alpha_contract()
	_check_height_is_not_reduced()
	_check_emphasis_settles(await _make_barrier())
	_check_low_quality_is_wired()
	_check_z_order_below_ui()
	_h.finish(get_tree())


func _make_barrier() -> Node2D:
	var barrier: Node2D = BarrierScript.new()
	barrier.name = "BarrierUnderTest"
	add_child(barrier)
	await get_tree().process_frame
	return barrier


# 常态必须很淡，强调必须明显更亮，否则"只在需要时被看见"就不成立。
func _check_alpha_contract() -> void:
	var steady: float = BarrierScript.STEADY_ALPHA
	var emphasis: float = BarrierScript.EMPHASIS_ALPHA
	var low: float = BarrierScript.LOW_QUALITY_ALPHA

	_h.expect(steady >= STEADY_ALPHA_MIN and steady <= STEADY_ALPHA_MAX,
		"steady_alpha_out_of_range",
		"常态 alpha %.3f 不在 %.2f-%.2f —— 太高会重新压住画面，太低会看不出隔开"
			% [steady, STEADY_ALPHA_MIN, STEADY_ALPHA_MAX])
	_h.expect(emphasis > steady,
		"emphasis_not_brighter",
		"强调 alpha %.3f 不比常态 %.3f 亮，开场提示等于没有" % [emphasis, steady])
	_h.expect(low <= steady,
		"low_quality_not_dimmer",
		"低画质 alpha %.3f 不比常态 %.3f 更淡" % [low, steady])
	_h.expect(BarrierScript.EMPHASIS_HOLD_SEC > 0.0 and BarrierScript.EMPHASIS_HOLD_SEC <= 1.0,
		"emphasis_hold_unreasonable",
		"强调保持 %.2f 秒不合理（V2 要求开场约 0.4 秒）" % BarrierScript.EMPHASIS_HOLD_SEC)


# 反向断言：晶柱**必须铺满**战场可视高度，不得被任何系数缩减。
#
# 这条是用户反馈直接转化成的回归护栏。第一版按 V2 原文把高度缩到 0.55，用户实看后
# 否决：「你把那个晶体缩短了，看不出那种隔开的感觉，不能弄短」。高度是"隔开"的载体，
# 缩短它等于把分隔线降级成装饰。V2 那条判据已作废，谁再照原文缩一次，这里立刻红。
func _check_height_is_not_reduced() -> void:
	var source := FileAccess.get_file_as_string("res://scenes/battle/BattleArena.gd")
	if not _h.expect(not source.is_empty(), "arena_unreadable", "读不到 BattleArena.gd"):
		return
	# 取包含该赋值的整行。别试图靠数括号找语句结尾 —— 表达式里嵌了三层括号，
	# 第一版按 ")" 截断，切在 "(bot_y - top_y)" 后面就停了，于是把正确的写法误报成
	# "高度公式被改了"。
	var stmt := ""
	for raw_line in source.split("\n"):
		var line := str(raw_line)
		if line.contains("barrier.scale = Vector2("):
			stmt = line
			break
	if not _h.expect(not stmt.is_empty(), "barrier_scale_missing", "找不到晶柱的 scale 赋值"):
		return

	# **整行精确比对**，不是"包含某个片段"。
	#
	# 第一版写成 `contains("(bot_y - top_y) / 512.0")` 加 `not contains("HEIGHT_FACTOR")`，
	# 变异测试当场证明它没用：把系数写成字面量 `* 0.55` 而不是命名常量，两条断言全通过，
	# 门禁照样绿。只要允许"包含即可"，任何后缀乘法都能溜过去。
	#
	# 精确比对对格式改动敏感，但那正是想要的：这一行已经被改错过一次，
	# 任何改动都应该逼一个人重新看一眼，而不是自动放行。
	var normalized := " ".join(stmt.strip_edges().split(" ", false))
	_h.expect(normalized == EXPECTED_BARRIER_SCALE_STMT,
		"barrier_height_changed",
		"晶柱 scale 赋值被改动了。期望：\n  %s\n实际：\n  %s\n缩短高度会让它看不出隔开，已被用户实看否决；如果这次改动是别的目的，请一并更新本断言。"
			% [EXPECTED_BARRIER_SCALE_STMT, normalized])


# 这条是本项的核心行为：开场亮一下，然后**必须自己落回常态**。
# 落不回去就等于什么都没改。
func _check_emphasis_settles(barrier: Node2D) -> void:
	if not _h.expect(barrier != null, "barrier_null", "晶柱实例化失败"):
		return
	barrier.play_loop()
	_h.expect(is_equal_approx(barrier.modulate.a, BarrierScript.EMPHASIS_ALPHA),
		"no_emphasis_on_start",
		"play_loop() 之后 alpha 是 %.3f，不是强调值 %.3f —— 开场提示没出现"
			% [barrier.modulate.a, BarrierScript.EMPHASIS_ALPHA])

	# 等过 保持 + 淡出 + 余量，强调必须已经退掉。
	var wait_sec := BarrierScript.EMPHASIS_HOLD_SEC + BarrierScript.EMPHASIS_FADE_SEC + 0.25
	await get_tree().create_timer(wait_sec).timeout
	_h.expect(is_equal_approx(barrier.modulate.a, barrier.steady_alpha()),
		"emphasis_never_settles",
		"等待 %.2f 秒后 alpha 仍是 %.3f，没有落回常态 %.3f —— 晶柱会一直保持高亮"
			% [wait_sec, barrier.modulate.a, barrier.steady_alpha()])

	# 车道清空是一次性事件，应当重新被看见。
	barrier.play_release()
	_h.expect(is_equal_approx(barrier.modulate.a, BarrierScript.EMPHASIS_ALPHA),
		"release_not_visible",
		"play_release() 时 alpha 是 %.3f，消失动画会看不见" % barrier.modulate.a)

	barrier.queue_free()


func _check_low_quality_is_wired() -> void:
	var barrier: Node2D = BarrierScript.new()
	add_child(barrier)
	barrier.set_low_quality(true)
	_h.expect(is_equal_approx(barrier.steady_alpha(), BarrierScript.LOW_QUALITY_ALPHA),
		"low_quality_alpha_ignored",
		"set_low_quality(true) 之后常态 alpha 仍是 %.3f" % barrier.steady_alpha())
	barrier.set_low_quality(false)
	_h.expect(is_equal_approx(barrier.steady_alpha(), BarrierScript.STEADY_ALPHA),
		"low_quality_not_reversible", "set_low_quality(false) 没有恢复常态 alpha")
	barrier.queue_free()

	# 接口存在还不够，BattleArena 必须真的按画质档调它。
	var source := FileAccess.get_file_as_string("res://scenes/battle/BattleArena.gd")
	_h.expect(source.contains("barrier.set_low_quality("),
		"low_quality_not_called",
		"BattleArena 没有按画质档调 barrier.set_low_quality()，低画质分支是死代码")


# 晶柱是背景元素。它不该被抬到 UI 之上：Top ATK 是 90、Skip 100、结果覆盖层 200。
func _check_z_order_below_ui() -> void:
	var source := FileAccess.get_file_as_string("res://scenes/battle/BattleArena.gd")
	if source.is_empty():
		return
	var at := source.find("Battle3v3LaneBarrier%d")
	if not _h.expect(at >= 0, "barrier_creation_missing", "找不到晶柱创建处"):
		return
	var block := source.substr(maxi(0, at - 200), 400)
	_h.expect(block.contains("z_index = 40"),
		"barrier_z_changed",
		"晶柱 z_index 不再是 40 —— 高于 Top ATK(90)/Skip(100)/结果(200) 会盖住 UI")
