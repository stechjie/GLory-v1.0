class_name EconomyLedger
extends RefCounted

# P1 备战经济账本（服务端权威）。
#
# 为什么要有这个文件：此前**八条**改金币的路径全部是客户端自己算完直接写
# `GameState.gold`，服务端只在战后结算时看一眼 `room.slot_gold`。也就是说
# 备战期发生的一切（买、卖、合成、刷新、祭坛、赌博）服务端一无所知 ——
# 改一下存档或内存就能凭空造钱，而且没有任何一条日志能发现。
#
# 设计原则：
#
# 1. **纯函数、零全局**。不读 `GameState`、不读 `TreasureService.has_set()`
#    （那个函数内部读 GameState）。所有外部输入都从 `ctx` 显式传进来 ——
#    服务端一个进程要同时跑几百个房间，任何全局状态都会串房间。
# 2. **随机性不在这里**。`shop_refresh` 的新商品、`gamble` 的开奖结果都由调用方
#    预先摇好传进来。这样账本本身是确定的，对抗台可以逐条断言；
#    也保证"重放回执"绝不会重新开奖。
# 3. **要么全做、要么不做**。任何一步校验失败都返回 `ok=false` 且**不修改 prep**。
#    半执行的交易是账本类代码最经典的坑。
#
# `cost_basis` 是整个设计的关键字段：出售退款、合成成本、套利防护全靠它。
# 合成时新单位的 `cost_basis` = 被合成单位 `cost_basis` 之和。

const SELL_REFUND_RATE := 0.5
# 升星份数与星级上限都在 GameConstants —— 客户端读的是同一份。
# GameConstants 是纯常量脚本，没有任何可变状态，不违反上面「零全局」那条
# （那条防的是 GameState/TreasureService 这类带房间状态的单例）。
#
# 这里原本是 `const STAR_UPGRADE_COPIES := 2`，一个平坦的 2，
# 与客户端的 {1: 2, 2: 3} 对不上，而且完全没有星级上限。

# --- 座位账本的初始状态 -------------------------------------------------------
static func new_prep(start_gold: int) -> Dictionary:
	return {
		"gold": start_gold,
		"revision": 0,
		"shop": {"offer_id": "", "offers": [], "sold": [], "refresh_uses": 0},
		"roster": {},        # uid(String) -> {unit_id, star, cost_basis, kind}
		"next_uid": 1,
		"altar_uses": 0,
		"gamble_used": false,
	}

# 每回合重置的部分。金币和 roster **不重置** —— 那是跨回合累积的。
static func reset_round(prep: Dictionary) -> void:
	var shop: Dictionary = prep.get("shop", {})
	shop["refresh_uses"] = 0
	prep["shop"] = shop
	prep["altar_uses"] = 0
	prep["gamble_used"] = false

# --- 价格：从显式 owned 列表算，不碰 GameState -------------------------------
# 与 `PrepBoardController._shop_unit_cost` 必须逐字一致，否则客户端预览价和
# 服务端实扣价对不上，玩家会看到"钱少了一块"。
# 棋子**自身**的售价：定价表 cost 经过它自带的 shop_cost_multiplier，
# 但**不含**玩家身上的折扣宝物。
#
# 单独抽出来是因为出售退款也要用它。此前退款直接读 `def.cost`（打折前的原值），
# 而商店价是 `cost x shop_cost_multiplier` —— 当乘数正好是 0.5 时，
# 「退一半」的 x0.5 与乘数的 x0.5 互相抵消，退款 = 售价 = **全额退款**。
# 数据表里只有 undead_small 带这个字段（cost 10、乘数 0.5、实际售价 5），
# 于是它买 5 退 5 打平，配上折扣宝物就变成净赚。
# 让两边读同一个函数，以后再加带乘数的棋子也不会重新长出这个洞。
static func base_unit_cost(unit_def: Dictionary) -> int:
	var cost := int(unit_def.get("cost", 1))
	if unit_def.has("shop_cost_multiplier"):
		cost = maxi(1, int(ceil(float(cost) * float(unit_def.shop_cost_multiplier))))
	return maxi(1, cost)

static func unit_cost(unit_def: Dictionary, owned: Array) -> int:
	var cost := base_unit_cost(unit_def)
	if TreasureService.has_linkage_in(owned, "link_clearance_sale"):
		cost = maxi(1, int(ceil(float(cost) * 0.6)))
	elif owned.has("money_discount"):
		cost = maxi(1, int(ceil(float(cost) * 0.8)))
	return cost

# 出售退款 = **实付价**的一半（已确认的规则改动）。
#
# 旧规则是 `floor(定价表 cost × star × 0.5)` —— 按**定价表**算，不按你实际花了多少。
# 折扣宝物买入 3 金、退款按原价 5 金算一半 = 2… 低星时看不出来，合成之后就明显了：
# `clearance` 买两个 undead_small = 6 金 → 合成 2 星 → 旧规则退 10 金，净 +4。
# （2026-08-20：客户端那份也已改为读 base_unit_cost()，并把 undead_small 的
#  shop_cost_multiplier 删除、售价定为 10。这段举例保留为**历史成因**记录。）
# 换成实付基数之后，买贵买便宜退的都是自己那一份的一半，**折扣再叠也刷不出钱**。
static func sell_refund(cost_basis: int) -> int:
	return int(floor(float(maxi(0, cost_basis)) * SELL_REFUND_RATE))

# --- 主入口 -------------------------------------------------------------------
# 返回 receipt；`ok=false` 时 prep **一定没被改过**。
static func apply(prep: Dictionary, action: String, payload: Dictionary, ctx: Dictionary) -> Dictionary:
	var gold_before := int(prep.get("gold", 0))
	var out: Dictionary
	match action:
		"buy":            out = _buy(prep, payload, ctx)
		"merge":          out = _merge(prep, payload, ctx)
		"sell":           out = _sell(prep, payload, ctx)
		"hire_merc":      out = _hire_merc(prep, payload, ctx)
		"shop_refresh":   out = _shop_refresh(prep, payload, ctx)
		"treasure_refresh_cost": out = _treasure_refresh_cost(prep, payload, ctx)
		"altar_grant":    out = _altar_grant(prep, payload, ctx)
		"gamble":         out = _gamble(prep, payload, ctx)
		_:                out = {"ok": false, "error": "unknown_action"}
	if not bool(out.get("ok", false)):
		return {
			"ok": false, "error": str(out.get("error", "denied")),
			"gold_before": gold_before, "delta": 0, "gold_after": gold_before,
			"revision": int(prep.get("revision", 0)), "result": {},
		}
	prep["revision"] = int(prep.get("revision", 0)) + 1
	var gold_after := int(prep.get("gold", 0))
	return {
		"ok": true, "error": "",
		"gold_before": gold_before, "delta": gold_after - gold_before, "gold_after": gold_after,
		"revision": int(prep["revision"]), "result": out.get("result", {}),
	}

# --- 各动作 -------------------------------------------------------------------

static func _buy(prep: Dictionary, payload: Dictionary, ctx: Dictionary) -> Dictionary:
	var shop: Dictionary = prep.get("shop", {})
	var offers: Array = shop.get("offers", [])
	var sold: Array = shop.get("sold", [])
	var index := int(payload.get("shop_index", -1))
	if index < 0 or index >= offers.size():
		return {"ok": false, "error": "bad_index"}
	# offer_id 绑定这一轮商店：刷新之后旧的购买请求必须失效，
	# 否则"先看到便宜货、刷新、再补发购买"就能买到已经不存在的商品。
	if str(payload.get("offer_id", "")) != str(shop.get("offer_id", "")):
		return {"ok": false, "error": "stale_offer"}
	if index < sold.size() and bool(sold[index]):
		return {"ok": false, "error": "already_sold"}
	var unit_def = offers[index]
	if typeof(unit_def) != TYPE_DICTIONARY or (unit_def as Dictionary).is_empty():
		return {"ok": false, "error": "empty_offer"}
	var cost := unit_cost(unit_def, ctx.get("owned_treasures", []))
	if int(prep.get("gold", 0)) < cost:
		return {"ok": false, "error": "not_enough_gold"}
	if _roster_size(prep) >= int(ctx.get("roster_cap", 64)):
		return {"ok": false, "error": "roster_full"}
	prep["gold"] = int(prep["gold"]) - cost
	sold.resize(maxi(sold.size(), offers.size()))
	sold[index] = true
	shop["sold"] = sold
	prep["shop"] = shop
	var uid := _add_unit(prep, str((unit_def as Dictionary).get("id", "")), 1, cost, "unit")
	return {"ok": true, "result": {"uid": uid, "unit_id": str((unit_def as Dictionary).get("id", "")), "cost": cost}}

static func _hire_merc(prep: Dictionary, payload: Dictionary, ctx: Dictionary) -> Dictionary:
	var mercs: Array = ctx.get("merc_table", [])
	var index := int(payload.get("merc_index", -1))
	if index < 0 or index >= mercs.size():
		return {"ok": false, "error": "bad_index"}
	var m: Dictionary = mercs[index]
	# 佣兵不吃棋子折扣：现有客户端就是直接读 cost，这里保持一致。
	var cost := int(m.get("cost", 0))
	if int(prep.get("gold", 0)) < cost:
		return {"ok": false, "error": "not_enough_gold"}
	var owned_mercs := 0
	for uid in (prep.get("roster", {}) as Dictionary).keys():
		if str(((prep["roster"] as Dictionary)[uid] as Dictionary).get("kind", "")) == "merc":
			owned_mercs += 1
	if owned_mercs >= int(ctx.get("merc_cap", 8)):
		return {"ok": false, "error": "merc_slots_full"}
	prep["gold"] = int(prep["gold"]) - cost
	var uid := _add_unit(prep, str(m.get("id", "")), 1, cost, "merc")
	return {"ok": true, "result": {"uid": uid, "unit_id": str(m.get("id", "")), "cost": cost}}

# 合成：两个同名同星 -> 一个高一星，`cost_basis` 相加。
# 相加是这条规则的全部意义 —— 出售时退的就是"你为这一坨总共花了多少"的一半，
# 不管中间经过几次合成、用了几次折扣。
static func _merge(prep: Dictionary, payload: Dictionary, _ctx: Dictionary) -> Dictionary:
	var uids: Array = payload.get("uids", [])
	# 份数按**目标单位的星级**决定，所以要先看一眼再判 —— 不能像以前那样
	# 用一个写死的数字。空数组直接拒，否则下面 first 取不到东西。
	if uids.is_empty():
		return {"ok": false, "error": "bad_merge_count"}
	var roster: Dictionary = prep.get("roster", {})
	var seen := {}
	var first: Dictionary = {}
	var basis := 0
	for raw in uids:
		var uid := str(raw)
		if seen.has(uid):
			return {"ok": false, "error": "duplicate_uid"}   # 同一个单位不能自己合自己
		seen[uid] = true
		if not roster.has(uid):
			return {"ok": false, "error": "unknown_uid"}
		var u: Dictionary = roster[uid]
		if first.is_empty():
			first = u
		elif str(u.get("unit_id", "")) != str(first.get("unit_id", "")) \
				or int(u.get("star", 1)) != int(first.get("star", 1)):
			return {"ok": false, "error": "mismatched_units"}
		if str(u.get("kind", "")) != "unit":
			return {"ok": false, "error": "not_mergeable"}
		basis += int(u.get("cost_basis", 0))
	var star := int(first.get("star", 1))
	# 满星不能再合。不拦的话服务端能凭空造出四星、五星 ——
	# 客户端根本没有这个概念（_can_merge_cells 要求 star < MAX_UNIT_STAR）。
	if star >= GameConstants.MAX_STAR:
		return {"ok": false, "error": "star_capped"}
	if uids.size() != GameConstants.copies_to_upgrade(star):
		return {"ok": false, "error": "bad_merge_count"}
	for raw in uids:
		roster.erase(str(raw))
	prep["roster"] = roster
	var uid_new := _add_unit(prep, str(first.get("unit_id", "")), star + 1, basis, "unit")
	return {"ok": true, "result": {"uid": uid_new, "unit_id": str(first.get("unit_id", "")),
		"star": star + 1, "cost_basis": basis}}

static func _sell(prep: Dictionary, payload: Dictionary, _ctx: Dictionary) -> Dictionary:
	var uid := str(payload.get("uid", ""))
	var roster: Dictionary = prep.get("roster", {})
	if not roster.has(uid):
		return {"ok": false, "error": "unknown_uid"}
	var u: Dictionary = roster[uid]
	var refund := sell_refund(int(u.get("cost_basis", 0)))
	roster.erase(uid)
	prep["roster"] = roster
	prep["gold"] = int(prep.get("gold", 0)) + refund
	return {"ok": true, "result": {"uid": uid, "refund": refund}}

static func _shop_refresh(prep: Dictionary, _payload: Dictionary, ctx: Dictionary) -> Dictionary:
	var shop: Dictionary = prep.get("shop", {})
	var uses := int(shop.get("refresh_uses", 0))
	var free := TreasureService.has_set_in(ctx.get("owned_treasures", []), "money")
	var cost := EconomyService.shop_refresh_cost(uses, free)
	if int(prep.get("gold", 0)) < cost:
		return {"ok": false, "error": "not_enough_gold"}
	var rolled = ctx.get("rolled_offers", null)
	if typeof(rolled) != TYPE_ARRAY:
		return {"ok": false, "error": "no_roll"}   # 调用方没预先摇好，绝不在这里摇
	prep["gold"] = int(prep["gold"]) - cost
	shop["refresh_uses"] = uses + 1
	shop["offers"] = (rolled as Array).duplicate(true)
	shop["offer_id"] = str(ctx.get("offer_id", ""))
	var sold: Array = []
	sold.resize((rolled as Array).size())
	sold.fill(false)
	shop["sold"] = sold
	prep["shop"] = shop
	return {"ok": true, "result": {"cost": cost, "offer_id": shop["offer_id"],
		"offers": shop["offers"], "refresh_uses": uses + 1}}

# 宝物刷新只在账本里扣钱；重摇候选仍由 NetworkService 的宝物 intent 负责
# （那条链路已经有服务端权威的 offer 与 E4 幂等回执了）。
static func _treasure_refresh_cost(prep: Dictionary, payload: Dictionary, ctx: Dictionary) -> Dictionary:
	var index := int(payload.get("refresh_index", 0))
	var free := TreasureService.has_set_in(ctx.get("owned_treasures", []), "money")
	var cost := TreasureService.refresh_cost(index, free)
	if int(prep.get("gold", 0)) < cost:
		return {"ok": false, "error": "not_enough_gold"}
	prep["gold"] = int(prep["gold"]) - cost
	return {"ok": true, "result": {"cost": cost}}

static func _altar_grant(prep: Dictionary, _payload: Dictionary, ctx: Dictionary) -> Dictionary:
	# HP 的扣减与次数上限由 NetworkService 判（那是房间共享状态，不属于座位账本）。
	# 这里只负责把金币记上，并把次数同步进账本以便重连时对账。
	var gold := int(ctx.get("altar_gold", 0))
	prep["gold"] = int(prep.get("gold", 0)) + gold
	prep["altar_uses"] = int(prep.get("altar_uses", 0)) + 1
	return {"ok": true, "result": {"gold": gold, "uses": int(prep["altar_uses"])}}

# 慷慨命运：**服务端开奖**（已确认必须改）。
# `ctx.roll` 由调用方用 Crypto 预先摇好 —— 客户端断线重连只会重放同一份回执，
# 绝不会重新开奖，也就刷不出好结果。
static func _gamble(prep: Dictionary, _payload: Dictionary, ctx: Dictionary) -> Dictionary:
	# 持有权：赌博是「慷慨命运」的能力，没有这件宝物不能开奖。
	# 客户端一直有这道门；服务端必须自己再判一次，否则改客户端就能白嫖一次翻倍。
	if not bool(ctx.get("gamble_entitled", false)):
		return {"ok": false, "error": "not_entitled"}
	if bool(prep.get("gamble_used", false)):
		return {"ok": false, "error": "already_used"}
	var roll := float(ctx.get("roll", -1.0))
	if roll < 0.0 or roll >= 1.0:
		return {"ok": false, "error": "no_roll"}
	var linked := bool(ctx.get("gamble_linked", false))
	var win_chance := 0.6 if linked else 0.5
	var loss_keep := 0.5 if linked else 0.2
	var before := int(prep.get("gold", 0))
	var won := roll < win_chance
	prep["gold"] = before * 2 if won else maxi(0, int(floor(float(before) * loss_keep)))
	prep["gamble_used"] = true
	return {"ok": true, "result": {"won": won, "gold_before": before, "gold_after": int(prep["gold"])}}

# --- roster 小工具 ------------------------------------------------------------

static func _roster_size(prep: Dictionary) -> int:
	return (prep.get("roster", {}) as Dictionary).size()

static func _add_unit(prep: Dictionary, unit_id: String, star: int, cost_basis: int, kind: String) -> String:
	var uid := "u%d" % int(prep.get("next_uid", 1))
	prep["next_uid"] = int(prep.get("next_uid", 1)) + 1
	var roster: Dictionary = prep.get("roster", {})
	roster[uid] = {"unit_id": unit_id, "star": star, "cost_basis": cost_basis, "kind": kind}
	prep["roster"] = roster
	return uid
