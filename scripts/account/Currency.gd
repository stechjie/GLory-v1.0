extends RefCounted

# 账号货币（钻石 / 金币）在界面上的样子：小图标与数字格式。
#
# 主菜单、商城、邮件三处显示的是同一个数。图标或千分位写成几份的话，
# 换图、改格式时迟早漏掉一处 —— 玩家会以为是两种钱。所以只有这一份。
#
# 不用 class_name：理由见 AccountConfig.gd 顶部（服务器打包的全局类缓存）。

const TEX_GOLD := preload("res://assets/ui/main_menu_live/gold.png")
const TEX_DIAMOND := preload("res://assets/ui/main_menu_live/diamond.png")

# gold.png(423×105) / diamond.png(418×105) 是**整条货币条**：左边圆图标 + 中间深色数字底板 +
# 右边绿色「+」充值键。主菜单是整个条按 220×55 画出来、再把数字压在底板上（MainMenu.gd）。
# 商城、邮件只要「图标 + 数字」，把 4:1 的整条塞进小方格会被 STRETCH_KEEP_ASPECT 压成一条亮片
# —— 测试反馈的「金币/钻石模型显示不正确」就是这个。所以按原图实测像素裁出图标那一段。
# 区域是在 423×105 / 418×105 原图上量的：金币圆心 (66,50)、钻石圆心 (70,50)，左右各留 2~3px 描边。
#
# 裁在代码里做，**不新增素材文件**：新增图要走 --import 重导 + manifest 登记，容易漏一环。
const GOLD_ICON_REGION := Rect2(26, 10, 80, 80)
const DIAMOND_ICON_REGION := Rect2(35, 10, 72, 80)

static var _gold_icon: AtlasTexture
static var _diamond_icon: AtlasTexture


# "diamond" 是钻石，其余都算金币（与服务端 data/shop.json 的 currency 口径一致）。
static func icon(currency: String) -> Texture2D:
	if currency == "diamond":
		if _diamond_icon == null:
			_diamond_icon = _crop(TEX_DIAMOND, DIAMOND_ICON_REGION)
		return _diamond_icon
	if _gold_icon == null:
		_gold_icon = _crop(TEX_GOLD, GOLD_ICON_REGION)
	return _gold_icon


static func _crop(tex: Texture2D, region: Rect2) -> AtlasTexture:
	var atlas := AtlasTexture.new()
	atlas.atlas = tex
	atlas.region = region
	# 裁切边界上的线性采样会把旁边那块暗底板吸进来，关掉它，免得图标带一圈脏边。
	atlas.filter_clip = true
	return atlas


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
