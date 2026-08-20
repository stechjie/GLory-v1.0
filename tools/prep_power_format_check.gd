extends Node

# D2 第五步的验收：scenes/prep/PrepPowerFormat.gd。
#
# 抽出来之前这块**零覆盖** —— tools/ 下搜不到一处 _format_power 用例。
# 而它是纯数值 + 语言分支，正好是"读代码看不出、跑起来也不容易发现"的那类：
# 战力显示错了没人会崩，只会觉得"这数字怎么怪怪的"。
#
# 运行：
#   Godot_v4.7-stable_win64_console.exe --headless --path . tools/prep_power_format_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const PrepPowerFormat := preload("res://scenes/prep/PrepPowerFormat.gd")

const CHECK_NAME := "prep_power_format"

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_case_cn_thresholds()
	_case_en_thresholds()
	_case_en_billion_not_confused_with_yi()
	_case_boundaries()
	_case_rounding()
	_case_zero_and_negative()
	_h.finish(get_tree())


func _expect_fmt(value: float, is_en: bool, want: String, code: String) -> void:
	var got := PrepPowerFormat.format_power(value, is_en)
	_h.expect(got == want, code,
		"format_power(%s, is_en=%s) 应为 %s，实际 %s" % [str(value), str(is_en), want, got])


func _case_cn_thresholds() -> void:
	_expect_fmt(0.0, false, "0", "cn_zero")
	_expect_fmt(999.0, false, "999", "cn_plain")
	_expect_fmt(9999.0, false, "9999", "cn_below_wan")
	_expect_fmt(10000.0, false, "1.00万", "cn_wan")
	_expect_fmt(12345.0, false, "1.23万", "cn_wan_frac")
	# 99,999,999 ÷ 10000 = 9999.9999，%.2f 进位成 10000.00万。
	# 读起来别扭（更像"1.00亿"），但它确实还没到 1 亿的阈值，属于显示取整的边角，
	# 不是 bug。写在这里是为了下次有人看到"10000.00万"时不用再查一遍。
	_expect_fmt(99999999.0, false, "10000.00万", "cn_below_yi")
	_expect_fmt(100000000.0, false, "1.00亿", "cn_yi")


func _case_en_thresholds() -> void:
	_expect_fmt(999.0, true, "999", "en_plain")
	_expect_fmt(9999.0, true, "9999", "en_below_k")
	_expect_fmt(10000.0, true, "10.00K", "en_k")
	_expect_fmt(1000000.0, true, "1.00M", "en_m")
	_expect_fmt(1000000000.0, true, "1.00B", "en_b")


# 这一条是这次抽取的**主要动机**。
# 原实现英文分支用的是中文「亿」的阈值（1e8）却标成 B：
#     if rounded >= 100000000: return "%.2fB" % (rounded / 100000000.0)
# 于是 1 亿被显示成 "1.00B"。但 1B = 10 亿 —— 英文玩家看到的战力**虚报 10 倍**。
# 中文分支一直是对的，所以这个 bug 只影响英文。
func _case_en_billion_not_confused_with_yi() -> void:
	_expect_fmt(100000000.0, true, "100.00M", "en_yi_mislabeled_as_billion")
	_expect_fmt(500000000.0, true, "500.00M", "en_half_billion")
	# 反过来也要守：真正的 10 亿必须是 1.00B，不能因为修阈值把 B 分支写没了
	_expect_fmt(1000000000.0, true, "1.00B", "en_real_billion_lost")
	_expect_fmt(2500000000.0, true, "2.50B", "en_multi_billion")


# 阈值边界：差 1 必须落在不同分支。
func _case_boundaries() -> void:
	_expect_fmt(9999.0, false, "9999", "cn_wan_boundary_low")
	_expect_fmt(10000.0, false, "1.00万", "cn_wan_boundary_high")
	_expect_fmt(99999999.0, true, "100.00M", "en_m_boundary_low")
	_expect_fmt(999999999.0, true, "1000.00M", "en_b_boundary_low")
	_expect_fmt(1000000000.0, true, "1.00B", "en_b_boundary_high")


# 传入的是 float，先四舍五入再判分支；否则 9999.6 会被当成 9999 落进"原样"分支，
# 显示成 "9999" 而不是 "1.00万"。
func _case_rounding() -> void:
	_expect_fmt(9999.6, false, "1.00万", "cn_round_up_into_wan")
	_expect_fmt(9999.4, false, "9999", "cn_round_down_stays")


# 0 与负数（理论上不该出现，但战力差值一类的地方可能传进来）不能炸。
func _case_zero_and_negative() -> void:
	_expect_fmt(0.0, true, "0", "en_zero")
	_expect_fmt(-5.0, false, "-5", "cn_negative")
	_expect_fmt(-5.0, true, "-5", "en_negative")
