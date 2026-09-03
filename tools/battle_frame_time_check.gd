extends Node

# V3 P2-02 门禁：帧时间固定字段与阈值判定。
#
# `scripts/qa/battle_presentation_baseline.gd` 只负责**产出**报告——它要真的开
# 渲染窗口跑一整场战斗，一轮就是几十秒到几分钟，不适合塞进这条跑几秒钟的
# headless 套件。这条门禁只负责**判定**：给它一份已经产出的 `performance` 字典，
# 按固定阈值出 PASS/FAIL，不重新渲染一遍。
#
# 判定逻辑与产出报告的脚本分开，也是为了不让「这条门禁转红」依赖一次真机/GPU
# 才能复现——判定用的是普通字典，反向变异可以直接改这份字典而不用跑渲染。
#
# ⚠️ 阈值是本次新加的默认值，不是既有产品决策的回收：
#   AVG_FPS_MIN / ONE_PCT_LOW_FPS_MIN / MAX_FRAME_TIME_MS_HARD 这三个数字仓库
#   里没有任何地方明确写过，是这一批按「移动端 3v3 自走棋，允许偶发卡顿但
#   不能整场糊」的常见口径估的。写进最终交接报告，等产品/主美回来确认或改。
#   审计已知的真实数据（2026-08-20 A4 设备采样，Round 20 平均 8.93 FPS、
#   1% low 6.84、P95 帧时 138ms）显然过不了这套阈值——那不是这条门禁定错了，
#   是那次采样真的很差，门禁应该为它转红，不该迁就它。
#
# 「平均 120 FPS 但出现 105ms 帧仍判失败」的原话意思是：单帧硬顶必须独立于
# 平均值判断，两者不能互相抵消。MAX_FRAME_TIME_MS_HARD 就是这条硬顶，
# 不因为 average_fps 好看就放行。
# 阈值统一应用到 PVE/Boss/PVP/最终战，不为任何 round 单独放宽——
# 这是清单原文明确禁止的「按 Round 20 特判」。

const CheckHarness := preload("res://tools/CheckHarness.gd")

const CHECK_NAME := "battle_frame_time"

const AVG_FPS_MIN := 30.0
const ONE_PCT_LOW_FPS_MIN := 20.0
const MAX_FRAME_TIME_MS_HARD := 100.0
# 100ms 硬顶之下再设一道「太多帧超过 50ms」的软预算——单次尖峰能容忍，
# 持续卡顿不行。
const FRAMES_OVER_50MS_RATIO_MAX := 0.02

# V3 P2-02 要求的固定字段。报告缺任何一个都算不合规——不是"门禁没测到"，
# 是报告本身没有按这次定的形状产出，需要重新生成。
const REQUIRED_FIELDS := ["average_fps", "one_percent_low_fps", "p95_frame_time_ms",
	"p99_frame_time_ms", "max_frame_time_ms", "frames_over_16_7ms", "frames_over_33ms",
	"frames_over_50ms", "frames_over_100ms", "memory_delta_mb", "sample_count"]

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_check_schema_contract_is_enforced()
	_check_hard_ceiling_overrides_good_average()
	_check_soft_budget_on_over_50ms_ratio()
	_check_uniform_thresholds_no_round_special_case()
	_check_real_captured_regression_is_caught()
	_h.finish(get_tree())


# 报告字段本身要齐——用「移动前的老报告缺新字段」这个真实案例当反例：
# A4 设备采样（2026-08-20）早于这批改动，天然没有 p99/frames_over_*/内存前后差，
# 用它来证明「缺字段」这条判据不是纸上谈兵。
func _check_schema_contract_is_enforced() -> void:
	var legacy := _load_fixture(
		"res://A4_device_battle_20260820/desktop/round_01/summary.json")
	if legacy.is_empty():
		_h.note("A4 历史夹具不在（可能已被清理），跳过缺字段这条用真实数据的验证")
		return
	var perf: Dictionary = legacy.get("performance", {})
	var verdict := judge_performance(perf)
	_h.expect(not bool(verdict.get("passed", true)), "legacy_report_incorrectly_passed",
		"2026-08-20 的旧报告缺新字段，理应判不合规，实际却判通过了")
	_h.expect(str(verdict.get("reasons", [])).contains("missing_field"),
		"missing_field_not_reported",
		"报告缺字段时判定结果里没有说明缺的是哪个字段")


# 核心不变式：单帧硬顶独立于平均值。构造一份「平均值好看但有一帧糊了」的
# 合成数据——这正是清单原文举的反例（120 FPS 均值 + 105ms 单帧）。
func _check_hard_ceiling_overrides_good_average() -> void:
	var perf := _synthetic_perf({
		"average_fps": 120.0,
		"one_percent_low_fps": 60.0,
		"max_frame_time_ms": 105.0,
		"frames_over_100ms": 1,
	})
	var verdict := judge_performance(perf)
	_h.expect(not bool(verdict.get("passed", true)), "good_average_masks_single_bad_frame",
		"平均 120 FPS 掩盖了一帧 105ms —— 单帧硬顶没有独立于平均值判断")
	_h.expect(str(verdict.get("reasons", [])).contains("max_frame_time"),
		"hard_ceiling_reason_missing", "判失败了但原因里没提到超过硬顶的那一帧")

	# 反过来：全部帧都在硬顶以内，即使平均值一般，也不该被这一条卡。
	var ok_perf := _synthetic_perf({
		"average_fps": 45.0,
		"one_percent_low_fps": 25.0,
		"max_frame_time_ms": 60.0,
		"frames_over_100ms": 0,
	})
	var ok_verdict := judge_performance(ok_perf)
	_h.expect(not str(ok_verdict.get("reasons", [])).contains("max_frame_time"),
		"hard_ceiling_false_positive", "没有任何一帧超过硬顶，却被硬顶那条判失败")


# 持续性卡顿（很多帧 30~50ms 之间，没有单帧到 100ms）也要抓——不能只盯着
# 最坏的那一帧，平均和最坏都正常但整场发闷同样是玩家能感知的问题。
func _check_soft_budget_on_over_50ms_ratio() -> void:
	var perf := _synthetic_perf({
		"average_fps": 40.0,
		"one_percent_low_fps": 22.0,
		"max_frame_time_ms": 55.0,
		"sample_count": 1000,
		"frames_over_50ms": 60,
		"frames_over_100ms": 0,
	})
	var verdict := judge_performance(perf)
	_h.expect(not bool(verdict.get("passed", true)), "sustained_jank_not_caught",
		"6% 的帧超过 50ms，没有单帧破百，这种「持续发闷」的场没被抓到")
	_h.expect(str(verdict.get("reasons", [])).contains("frames_over_50ms_ratio"),
		"soft_budget_reason_missing", "判失败了但原因里没提到超过 50ms 帧占比过高")


# 阈值必须是同一套常量，不接受"这是 Round 20 网开一面"式的参数。
# 用两份除 round 号外完全相同的数据核对：同样的坏数据，套同一份阈值，
# 结果必须一致——判定函数的签名里压根不该有 round 这个参数。
func _check_uniform_thresholds_no_round_special_case() -> void:
	var bad := _synthetic_perf({"average_fps": 10.0, "one_percent_low_fps": 5.0})
	var v1 := judge_performance(bad)
	var v2 := judge_performance(bad)
	_h.expect(bool(v1.get("passed", true)) == bool(v2.get("passed", true)),
		"threshold_not_deterministic",
		"同一份数据判两次结果不一样——判定函数里混进了跟调用次数/上下文有关的状态")
	# judge_performance() 的签名本身只接受 performance 字典，没有 round_index
	# 参数——这条断言在源码层面钉死「不能按 round 特判」这件事。
	#
	# 不能直接 src.find("func judge_performance(")：这条检查自己的源码里就写着
	# 这个字面量（上一行注释和这段代码本身），不锚定到真正的函数定义会先匹配到
	# 自己。按 "\n" 切成整行数组再逐行判断前缀，不受检查脚本自身文本的干扰。
	var src := FileAccess.get_file_as_string("res://tools/battle_frame_time_check.gd")
	var sig_line := ""
	for raw_line in src.split("\n"):
		if str(raw_line).begins_with("func judge_performance("):
			sig_line = str(raw_line)
			break
	if _h.expect(not sig_line.is_empty(), "judge_function_missing",
			"judge_performance() 不见了"):
		_h.expect(not sig_line.contains("round"), "judge_function_takes_round_index",
			"judge_performance() 的参数里出现了 round —— 这就是按回合特判的入口：%s"
				% sig_line)


# 拿真实历史采样（不是编出来的数字）核对一次「这套阈值真的会让已知的差结果
# 转红」。2026-08-20 A4 设备 Round 20：均 8.93 FPS、1% low 6.84、P95 帧时
# 138ms —— 早就知道这场很差，门禁必须对它说不，而不是被某种宽容悄悄放过。
func _check_real_captured_regression_is_caught() -> void:
	var device_round20 := _load_fixture(
		"res://A4_device_battle_20260820/cold_cache/device/round_20/summary.json")
	if device_round20.is_empty():
		_h.note("A4 设备 Round 20 历史夹具不在，跳过这条用真实回归数据的验证")
		return
	var perf: Dictionary = device_round20.get("performance", {})
	var verdict := judge_performance(perf)
	_h.expect(not bool(verdict.get("passed", true)), "known_bad_capture_passed",
		"2026-08-20 A4 设备 Round 20 的真实采样（8.93 FPS）被判通过了 —— "
			+ "阈值形同虚设")


# --- 判定本体 ---------------------------------------------------------------

# 只吃一个 performance 字典，不吃 round/kind 之类的上下文——阈值统一应用，
# 不按场次特判是这条门禁存在的意义。
func judge_performance(perf: Dictionary) -> Dictionary:
	var reasons: Array[String] = []

	for field in REQUIRED_FIELDS:
		if not perf.has(field):
			reasons.append("missing_field:%s" % field)
	if not reasons.is_empty():
		# 字段都不全，后面任何数值判断都没有意义——直接返回，不再往下比阈值。
		return {"passed": false, "reasons": reasons}

	var average_fps := float(perf.get("average_fps", 0.0))
	var one_pct_low := float(perf.get("one_percent_low_fps", 0.0))
	var max_frame := float(perf.get("max_frame_time_ms", 0.0))
	var sample_count := int(perf.get("sample_count", 0))
	var over_50 := int(perf.get("frames_over_50ms", 0))

	if average_fps < AVG_FPS_MIN:
		reasons.append("average_fps:%.2f<%.2f" % [average_fps, AVG_FPS_MIN])
	if one_pct_low < ONE_PCT_LOW_FPS_MIN:
		reasons.append("one_percent_low_fps:%.2f<%.2f" % [one_pct_low, ONE_PCT_LOW_FPS_MIN])
	# 单帧硬顶独立判断：不因为均值好看就放行,也不因为均值一般就误伤。
	if max_frame > MAX_FRAME_TIME_MS_HARD:
		reasons.append("max_frame_time:%.1fms>%.1fms" % [max_frame, MAX_FRAME_TIME_MS_HARD])
	if sample_count > 0:
		var ratio := float(over_50) / float(sample_count)
		if ratio > FRAMES_OVER_50MS_RATIO_MAX:
			reasons.append("frames_over_50ms_ratio:%.3f>%.3f" % [ratio, FRAMES_OVER_50MS_RATIO_MAX])

	return {"passed": reasons.is_empty(), "reasons": reasons}


# --- 夹具 --------------------------------------------------------------------

func _load_fixture(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


# 合成一份「字段齐全、数值健康」的 performance 字典，调用方按需覆盖要测的那几项。
# 这样每条用例只声明它关心的差异，不用每次都把十一个字段抄一遍。
func _synthetic_perf(overrides: Dictionary) -> Dictionary:
	var base := {
		"average_fps": 60.0,
		"one_percent_low_fps": 40.0,
		"p95_frame_time_ms": 20.0,
		"p99_frame_time_ms": 30.0,
		"max_frame_time_ms": 40.0,
		"frames_over_16_7ms": 0,
		"frames_over_33ms": 0,
		"frames_over_50ms": 0,
		"frames_over_100ms": 0,
		"memory_delta_mb": {"video_mb": 0.0, "texture_mb": 0.0, "static_mb": 0.0},
		"sample_count": 600,
	}
	for key in overrides.keys():
		base[key] = overrides[key]
	return base
