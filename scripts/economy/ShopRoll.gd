extends RefCounted

# 商店档位曲线 —— 客户端与服务端**共用同一份**。
#
# 起因：这条规则原本只存在于客户端（`PrepBoardController._roll_shop_tier`），
# 服务端的 `NetworkService._server_roll_shop_offers()` 是**全表均匀随机**，
# 完全没有档位概念。两边摇出来的商店根本不是同一个分布：
#
#   回合      客户端 tier1/2/3        服务端（均匀，按 8/18/6 的表分布）
#   1–4       80% / 20% /  0%         25% / 56% / 19%
#   5–9       50% / 50% /  0%         25% / 56% / 19%
#   10–14     25% / 60% / 15%         25% / 56% / 19%
#   15+       15% / 60% / 25%         25% / 56% / 19%
#
# **第一回合就有 19% 概率刷出三档单位，而设计上那里应该是 0%。**
# 整条成长曲线在联机权威模式下会静默消失。
#
# 为什么之前没被发现：账本目前还锁在 `economy_ledger_*` 两个默认关闭的开关后面，
# 而计划中用来验收开关的「影子比对」**结构上抓不到这个问题** ——
# 它只比对金币（`_shadow_audit_economy`），刷新价两边都走
# `EconomyService.shop_refresh_cost`，一分钱不差。
# 换句话说：影子期会显示「零差异」，然后翻开关，然后商店曲线没了。
#
# 随机数**不在这里摇**：调用方各自提供 [0,1) 的值 ——
# 客户端用 `RandomNumberGenerator`，服务端必须用 `Crypto`
# （randf() 的种子可预测，而商店内容是钱能买到的东西）。
# 这里只负责「一个骰子点数 + 回合号 → 档位」这条**规则**。


# 档位阈值。读法：roll 落在哪个累积区间就出哪一档。
# 改这张表 = 改整个游戏的成长节奏，改之前先想清楚。
static func tier_for_roll(round_index: int, roll: float) -> int:
	if round_index >= 15:
		if roll < 0.15:
			return 1
		if roll < 0.75:
			return 2
		return 3
	if round_index >= 10:
		if roll < 0.25:
			return 1
		if roll < 0.85:
			return 2
		return 3
	if round_index >= 5:
		return 1 if roll < 0.50 else 2
	return 1 if roll < 0.80 else 2


# 摇一个商店位。
#   tier_roll  决定档位
#   pick_roll  决定该档里选哪个单位
# 该档没有任何单位时退回全表（与原客户端行为一致），否则会摇出空位。
static func pick_offer(units: Array, round_index: int, tier_roll: float, pick_roll: float) -> Dictionary:
	if units.is_empty():
		return {}
	var tier := tier_for_roll(round_index, tier_roll)
	var pool: Array = []
	for u in units:
		if int((u as Dictionary).get("tier", 1)) == tier:
			pool.append(u)
	if pool.is_empty():
		pool = units
	var idx := clampi(int(pick_roll * float(pool.size())), 0, pool.size() - 1)
	return (pool[idx] as Dictionary).duplicate(true)
