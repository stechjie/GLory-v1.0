extends Node

# V2 P1-01 的门禁：最短可读演出时长只能改播放节奏，不能碰战斗。
#
# 背景：固定 seed 的两个 PVE 回合实测只有 46 帧和 35 帧（4.6 秒 / 3.5 秒），
# 技能起手、命中、死亡挤在一起看不清。修法是按帧数反推播放倍率，把短战拉进
# 可读窗口。回放是一个已经算完的帧数组，播放速度只决定走多快 —— 所以这件事
# 从原理上碰不到战斗结果。
#
# 但"原理上碰不到"不是证据。这里守两件事：
#   1. 倍率函数本身的边界正确（纯函数，喂合成输入）
#   2. 实现方式没有偷偷改到模拟：SIM_TICK_SEC 必须原样、不得出现加速
#
# final_state / replay / frame_events 三个哈希的不变性由
# tools/battle_presentation_baseline 的改前/改后对比覆盖，不在这里重复。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const BattleScreenScript := preload("res://scenes/battle/BattleScreen.gd")
const BattleUIScript := preload("res://scenes/battle/BattleUI.gd")
const CHECK_NAME := "battle_readable_pace"

var _h: RefCounted


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_check_speed_boundaries()
	_check_never_speeds_up()
	_check_stretch_is_bounded()
	_check_simulation_step_untouched()
	_check_real_round_lengths()
	_h.finish(get_tree())


func _speed(frames: int, is_boss: bool) -> float:
	return BattleScreenScript.readable_speed_for(frames, BattleUIScript.SIM_TICK_SEC, is_boss)


func _check_speed_boundaries() -> void:
	var tick: float = BattleUIScript.SIM_TICK_SEC
	var want: float = BattleScreenScript.READABLE_MIN_SEC
	var want_boss: float = BattleScreenScript.READABLE_MIN_SEC_BOSS

	# 退化输入不能把播放速度搞成 0 或负数 —— 那会让画面永远停住。
	_h.expect(is_equal_approx(_speed(0, false), 1.0),
		"zero_frames", "帧数为 0 时应返回 1.0，实际 %f" % _speed(0, false))
	_h.expect(is_equal_approx(_speed(-5, false), 1.0),
		"negative_frames", "帧数为负时应返回 1.0")
	_h.expect(BattleScreenScript.readable_speed_for(46, 0.0, false) == 1.0,
		"zero_tick", "tick_sec 为 0 时应返回 1.0，不能除零")

	# 刚好达到窗口下界：不拉伸。
	var exact := int(round(want / tick))
	_h.expect(is_equal_approx(_speed(exact, false), 1.0),
		"exact_window", "自然时长正好等于下界时不应拉伸，实际 %f" % _speed(exact, false))

	# 短战：拉伸后要么落到窗口下界，要么已经触底速度下限。
	#
	# 后一种情况是刻意的，不是没做到：V2 P1-01 自己写着"如果事件少，用开场编队、
	# 关键命中、死亡停顿和胜利收尾填充，**不用空等**"。一场 20 帧（2 秒）的战斗要拉到
	# 5 秒就得 0.4 倍速，那是慢动作，正是它要避免的"空等"。短到这个程度的战斗需要的是
	# 补演出内容（P1-05 的范围），不是把时间轴抻长。所以这里下限优先于窗口。
	var floor_speed: float = BattleScreenScript.READABLE_MIN_PLAYBACK_SPEED
	for frames in [20, 35, 46]:
		var speed := _speed(frames, false)
		var stretched := float(frames) * tick / speed
		var reached := stretched >= want - 0.01
		var at_floor := is_equal_approx(speed, floor_speed)
		_h.expect(reached or at_floor,
			"short_battle_not_stretched",
			"%d 帧拉伸后只有 %.2f 秒，既未达下界 %.1f 秒也没触底速度下限 %.2f"
				% [frames, stretched, want, floor_speed])
		if at_floor and not reached:
			_h.note("%d 帧触底速度下限：%.2f 秒 < 目标 %.1f 秒，需靠 P1-05 补演出内容而非继续拉长"
				% [frames, stretched, want])

	# Boss 用更长的窗口。同样帧数下 Boss 必须比普通战更慢。
	var normal := _speed(46, false)
	var boss := _speed(46, true)
	_h.expect(boss < normal,
		"boss_not_slower",
		"同为 46 帧，Boss 倍率 %f 未比普通战 %f 更慢" % [boss, normal])
	var boss_stretched := 46.0 * tick / boss
	_h.expect(boss_stretched >= want_boss - 0.01 or is_equal_approx(boss, BattleScreenScript.READABLE_MIN_PLAYBACK_SPEED),
		"boss_window",
		"Boss 46 帧拉伸后 %.2f 秒，未达 %.1f 秒（除非已触底速度下限）" % [boss_stretched, want_boss])


# 长战绝不能被压缩。玩家等着看的那种大场面，被加速播完是纯粹的损失。
func _check_never_speeds_up() -> void:
	for frames in [50, 80, 120, 300, 1000]:
		var speed := _speed(frames, false)
		_h.expect(speed <= 1.0 + 0.0001,
			"speeds_up",
			"%d 帧返回倍率 %f > 1.0 —— 演出被加速了" % [frames, speed])
		_h.expect(speed > 0.0, "non_positive_speed", "%d 帧返回了非正倍率" % frames)


# 拉伸要有底。一场 3 帧的战斗若无下限会被抻成 0.06 倍速的慢动作。
func _check_stretch_is_bounded() -> void:
	var floor_speed: float = BattleScreenScript.READABLE_MIN_PLAYBACK_SPEED
	for frames in [1, 3, 5, 10]:
		var speed := _speed(frames, true)
		_h.expect(speed >= floor_speed - 0.0001,
			"stretch_unbounded",
			"%d 帧返回倍率 %f，低于下限 %f —— 会变成慢动作" % [frames, speed, floor_speed])


# 最重要的一条：这项优化只准动播放，不准动模拟。
# SIM_TICK_SEC 是模拟步长，改它就是改战斗本身。
func _check_simulation_step_untouched() -> void:
	_h.expect(is_equal_approx(BattleUIScript.SIM_TICK_SEC, 0.1),
		"sim_tick_changed",
		"SIM_TICK_SEC 变成了 %f —— 那是模拟步长，动它等于改战斗，不是改演出"
			% BattleUIScript.SIM_TICK_SEC)

	var source := FileAccess.get_file_as_string("res://scenes/battle/BattleScreen.gd")
	if not _h.expect(not source.is_empty(), "source_unreadable", "读不到 BattleScreen.gd"):
		return
	# 倍率必须乘在累加器上（播放侧），而不是改 SIM_TICK_SEC 或 step_state 的调用次数。
	_h.expect(source.contains("PLAYBACK_SPEED * _readable_speed"),
		"speed_not_applied",
		"播放累加器没有乘上 _readable_speed —— 拉伸没有真正生效")
	_h.expect(not source.contains("SIM_TICK_SEC ="),
		"sim_tick_assigned", "BattleScreen 里出现了对 SIM_TICK_SEC 的赋值")


# 用真实回放长度验一次，避免门禁只在合成数字上成立。
# 46 / 35 是 2026-08-29 固定 seed 基线里 round 1 / round 2 的实测帧数。
func _check_real_round_lengths() -> void:
	var tick: float = BattleUIScript.SIM_TICK_SEC
	var cases := [
		{"frames": 46, "was": 4.6},
		{"frames": 35, "was": 3.5},
	]
	for case_value in cases:
		var case_dict: Dictionary = case_value
		var frames := int(case_dict["frames"])
		var speed := _speed(frames, false)
		var after := float(frames) * tick / speed
		_h.expect(after > float(case_dict["was"]) + 0.05,
			"real_round_not_improved",
			"实测 %d 帧的回合：改前 %.1f 秒，改后 %.2f 秒 —— 没有变长"
				% [frames, float(case_dict["was"]), after])
		_h.note("%d 帧：%.1f 秒 -> %.2f 秒（倍率 %.3f）"
			% [frames, float(case_dict["was"]), after, speed])
