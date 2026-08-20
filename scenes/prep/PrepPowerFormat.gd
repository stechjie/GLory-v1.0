extends RefCounted

# D2 第五步：把备战界面的「战力数字格式化」抽成纯工具。
#
# 为什么是它：对 7 层继承链做过一次统计 —— 有 86 个函数、1249 行**完全不碰任何
# 成员变量**且被 >=2 处调用。这些是真正能独立出来的部分，
# 而不是那 18 个商店函数（851 行里只有 1 个 4 行的函数不依赖宿主，
# 搬进面板只会变成处处回调宿主）。
#
# 本文件是这一类里最值得先守住的：纯数值 + 语言分支，容易写错，且**此前零覆盖**。
#
# 全静态、不持有状态。语言判定通过参数传入，不在这里读全局 ——
# 这样测试才能确定性地覆盖两种语言，不必去改 LocaleManager。

const WAN := 10000.0            # 万
const YI := 100000000.0         # 亿
const THOUSAND := 1000.0
const MILLION := 1000000.0
const BILLION := 1000000000.0


# 中文：>=1 亿用「亿」，>=1 万用「万」，否则原样。
# 英文：>=1B 用 B，>=1M 用 M，>=10K 用 K，否则原样。
#
# ⚠️ 英文分支的阈值与除数是这次抽取时**修正过**的，原实现是：
#     if rounded >= 100000000: return "%.2fB" % (rounded / 100000000.0)
#     if rounded >= 10000:     return "%.2fK" % (rounded / 1000.0)
# 也就是把 1 亿（100,000,000）显示成 "1.00B"。但 1B = 10 亿，
# 这个写法把英文战力**虚报了 10 倍**（它套用了中文「亿」的阈值却标成 B）。
# 中文分支一直是对的，所以只有英文玩家看到错误数字。
# 修正后 1 亿 -> "100.00M"，10 亿 -> "1.00B"。
static func format_power(value: float, is_en: bool) -> String:
	var rounded := int(round(value))
	if is_en:
		if rounded >= int(BILLION):
			return "%.2fB" % (float(rounded) / BILLION)
		if rounded >= int(MILLION):
			return "%.2fM" % (float(rounded) / MILLION)
		if rounded >= 10000:
			return "%.2fK" % (float(rounded) / THOUSAND)
		return str(rounded)
	if rounded >= int(YI):
		return "%.2f亿" % (float(rounded) / YI)
	if rounded >= int(WAN):
		return "%.2f万" % (float(rounded) / WAN)
	return str(rounded)
