extends RefCounted

# 账号货币（钻石 / 金币）在界面上的样子：小图标与数字格式。
#
# 主菜单、商城、邮件三处显示的是同一个数。图标或千分位写成几份的话，
# 换图、改格式时迟早漏掉一处 —— 玩家会以为是两种钱。所以只有这一份。
#
# 不用 class_name：理由见 AccountConfig.gd 顶部（服务器打包的全局类缓存）。

const TEX_GOLD := preload("res://assets/ui/currency/gold.png")
const TEX_DIAMOND := preload("res://assets/ui/currency/diamond.png")

# 使用完整的透明独立图标，不再从货币条截取，避免边框与底板残留。
# 纹理由 ResourceLoader 缓存；所有货币入口共享同一素材。
static func icon(currency: String) -> Texture2D:
	return TEX_DIAMOND if currency == "diamond" else TEX_GOLD

# 千分位：89450 -> "89,450"。
static func comma(value: int) -> String:
	var digits := str(absi(value))
	var out := ""
	var count := 0
	for i in range(digits.length() - 1, -1, -1):
		out = digits[i] + out
		count += 1
		if count % 3 == 0 and i > 0:
			out = "," + out
	return ("-" if value < 0 else "") + out
