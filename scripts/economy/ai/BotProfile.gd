extends RefCounted
## 五档 AI 难度的参数（2026-11-07）。数值在 data/ai/bot_profiles.json，这里只负责读和兜底。
##
## 档位从哪来（都在服务器上定，客户端改不了）：
##   * 匹配补位：账号服务器按这桌真人的平均段位定一档，签进名片的 ai 座位（ai_level）
##   * 掉线托管：handover_level（用户 11-07 定：普通档）
##   * 其它没写档位的（自定义房间的 AI、预览推演）：default_level
##
## 字段（每档一份）：
##   noise              决策打分的噪声（误判率），0 = 不犯错
##   synergy_knowledge  0 不懂羁绊 / 1 只认第一档 / 2 全部门槛
##   merge_weight       凑星潜力的权重（0 = 只看眼前）
##   owned_bonus        商店里出现已有同名棋子时估值再乘多少（沿用手上的阵容、优先升星）
##   impulse            冲动消费：看着顺眼就买（新手大、简单小、普通以上 0）
##   direction          主种族怎么定：random 开局随机不改 / owned 按手上最多 / eval 按估值、可转型
##   pivot_margin       eval 档转主种族要比现在好多少倍
##   reserve            留钱：none / flat（固定 flat_reserve）/ interest（吃利息）/ plan（按关键回合规划）
##   final_all_in       第 21 回合全花
##   max_refresh / refresh_margin  每回合最多刷新几次、刷新后至少还剩多少
##   tech_cap / tech_margin        采集科技最多买到几级、买完至少还剩多少
##   carrots            greedy 有萝卜就叫最贵的一个 / pack 凑最强的一组佣兵 / plan 攒石头和叫佣兵二选一 /
##                      plan_rounds 再按回合重要性择时
##   stone_draw         会不会抽升级石
##   four_star          none / greedy 有石有钱就升 / value 挑收益最大的目标
##   formation          basic 近战前远程后 / role 按坦克输出辅助
##   treasure           random / set 凑套装联动 / lineup 再看自己阵容
##   flip_on_loss       上一场 PvP 输了就左右翻转站位、换一种对位

const MIN_LEVEL := 1
const MAX_LEVEL := 5

# json 读不到时的兜底：等于普通档，保证 AI 不会因为配置缺失而失灵。
const FALLBACK := {
	"name": "normal", "noise": 0.1, "synergy_knowledge": 2, "merge_weight": 2.0, "owned_bonus": 1.6,
	"direction": "eval", "pivot_margin": 1.35, "reserve": "interest", "flat_reserve": 30,
	"final_all_in": true, "max_refresh": 8, "refresh_margin": 40, "buy_threshold": 0.0,
	"tech_cap": 3, "tech_margin": 80, "carrots": "plan_rounds", "stone_draw": true,
	"four_star": "value", "formation": "role", "treasure": "lineup", "flip_on_loss": true,
}


static func table() -> Dictionary:
	var raw: Variant = DataRegistry.get_table("bot_profiles")
	return raw if typeof(raw) == TYPE_DICTIONARY else {}


static func default_level() -> int:
	return clampi(int(table().get("default_level", 3)), MIN_LEVEL, MAX_LEVEL)


static func handover_level() -> int:
	return clampi(int(table().get("handover_level", 3)), MIN_LEVEL, MAX_LEVEL)


# 段位（0 初誓 … 4 荣耀之冠）→ 档位。
static func level_for_tier(tier: int) -> int:
	var levels: Array = table().get("tier_levels", [1, 2, 3, 4, 5])
	if levels.is_empty():
		return default_level()
	return clampi(int(levels[clampi(tier, 0, levels.size() - 1)]), MIN_LEVEL, MAX_LEVEL)


static func level_of(bot: Dictionary) -> int:
	var level := int(bot.get("ai_level", 0))
	return clampi(level, MIN_LEVEL, MAX_LEVEL) if level > 0 else default_level()


# 每档合并一次就缓存起来（站位、估值一回合要读几百次）。DataRegistry 重新加载后表换了对象，
# 缓存跟着作废。返回的字典只读，调用方不要改。
static var _cache: Dictionary = {}
static var _cache_source: Variant = null


static func for_level(level: int) -> Dictionary:
	var source := table()
	if not is_same(source, _cache_source):
		_cache.clear()
		_cache_source = source
	var key := clampi(level, MIN_LEVEL, MAX_LEVEL)
	if _cache.has(key):
		return _cache[key]
	var out := FALLBACK.duplicate()
	var levels: Dictionary = source.get("levels", {})
	var row: Variant = levels.get(str(key), {})
	if typeof(row) == TYPE_DICTIONARY:
		out.merge(row, true)
	out["level"] = key
	_cache[key] = out
	return out


static func for_bot(bot: Dictionary) -> Dictionary:
	return for_level(level_of(bot))
