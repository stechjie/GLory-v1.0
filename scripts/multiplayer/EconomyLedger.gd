class_name EconomyLedger
extends RefCounted

const CarrotEconomy := preload("res://scripts/economy/CarrotEconomy.gd")

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
# 与 NetProtocol.MAX_ID_LENGTH 同值：来路是网络，长度必须在常数级步数内被拒。
const MAX_UID_LENGTH := 64
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
		"carrots": 0,
		"harvest_tech_level": 0,
		"merc_carrots_spent_total": 0,
		"last_harvest_round": -1,
		"last_harvest_gain": 0,
		"stone_draw_used_round": -1,
		"four_star_uids": {},   # uid -> {unit_id, round}：四星血统，见 _use_upgrade_stone
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
	# Mercenaries last for one battle. Clear only their roster records; the
	# cumulative carrot spend remains and continues to drive farm progression.
	var roster: Dictionary = prep.get("roster", {})
	for uid in roster.keys():
		var owned: Dictionary = roster[uid]
		if str(owned.get("kind", "")) == "merc":
			roster.erase(uid)
	prep["roster"] = roster

static func harvest_for_round(prep: Dictionary, round_index: int) -> Dictionary:
	var last_round := int(prep.get("last_harvest_round", -1))
	if round_index < 1 or last_round >= round_index:
		return {"ok": false, "already_harvested": true, "gain": 0,
			"carrots": int(prep.get("carrots", 0))}
	var spent := int(prep.get("merc_carrots_spent_total", 0))
	var tech := int(prep.get("harvest_tech_level", 0))
	var result := CarrotEconomy.harvest(int(prep.get("carrots", 0)), spent, tech)
	prep["carrots"] = int(result.after)
	prep["last_harvest_round"] = round_index
	prep["last_harvest_gain"] = int(result.gain)
	prep["revision"] = int(prep.get("revision", 0)) + 1
	return {"ok": true, "already_harvested": false, "gain": int(result.gain),
		"overflow": int(result.overflow), "carrots": int(prep["carrots"]),
		"capacity": int(result.capacity), "production": int(result.production)}

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

# 按星级的出售返还倍率（乘在**棋子自身售价**上，见 base_unit_cost）。
#
# 1~3 星沿用旧公式 `售价 × 星级 × 0.5`，逐字等价：0.5 / 1.0 / 1.5。
# 4 星**不能**照这个公式外推（那会得到 ×2）：4 星要 6 份材料（270 金@cost30）
# 外加一颗升级石，退 ×2 太少；但更关键的是**定额或过高的返还会被小灵撬出套利** ——
# 小灵 cost 10 是次便宜单位的一半，任何"每颗多给 N 金"的写法都会让
# 「买 9 份 → 升四星 → 卖掉」变成正收益，直接撞穿 sell_refund_check 的
# `sell_for_profit` 硬断言。改用比例制 ×3：全表在三种折扣状态下都仍是净亏。
#
# 客户端 `PrepBoardController._sell_refund_for_cell()` 读同一个函数 ——
# 不在两边各写一份，那正是这个文件里已经修过一次的坑。
const STAR_REFUND_MULTIPLIER := [0.5, 1.0, 1.5, 3.0]

static func star_sell_refund(price: int, star: int) -> int:
	var idx := clampi(star, 1, GameConstants.MAX_STAR) - 1
	return int(floor(float(maxi(0, price)) * float(STAR_REFUND_MULTIPLIER[idx])))

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
		"upgrade_harvest_tech": out = _upgrade_harvest_tech(prep, payload, ctx)
		"hire_merc_carrot": out = _hire_merc_carrot(prep, payload, ctx)
		"draw_upgrade_stone": out = _draw_upgrade_stone(prep, payload, ctx)
		"use_upgrade_stone": out = _use_upgrade_stone(prep, payload, ctx)
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
	var uid := _add_unit(prep, str((unit_def as Dictionary).get("id", "")), 1, cost, "unit",
		str(payload.get("uid", "")))
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

static func _upgrade_harvest_tech(prep: Dictionary, _payload: Dictionary, _ctx: Dictionary) -> Dictionary:
	if int(_ctx.get("round_index", 1)) < 2:
		return {"ok": false, "error": "harvest_locked_first_round"}
	var level := int(prep.get("harvest_tech_level", 0))
	var price := CarrotEconomy.tech_price(level)
	if price < 0:
		return {"ok": false, "error": "max_level"}
	if int(prep.get("gold", 0)) < price:
		return {"ok": false, "error": "not_enough_gold"}
	prep["gold"] = int(prep["gold"]) - price
	prep["harvest_tech_level"] = level + 1
	return {"ok": true, "result": {
		"price": price,
		"harvest_tech_level": level + 1,
		"production": CarrotEconomy.total_production(
			level + 1, int(prep.get("merc_carrots_spent_total", 0))),
	}}

static func _hire_merc_carrot(prep: Dictionary, payload: Dictionary, ctx: Dictionary) -> Dictionary:
	var mercs: Array = ctx.get("merc_table", [])
	var merc_id := str(payload.get("merc_id", ""))
	var selected: Dictionary = {}
	for row_value in mercs:
		var row: Dictionary = row_value
		if str(row.get("id", "")) == merc_id:
			selected = row
			break
	if selected.is_empty():
		return {"ok": false, "error": "bad_mercenary"}
	var cost := int(selected.get("carrot_cost", -1))
	if cost < 0:
		return {"ok": false, "error": "missing_carrot_cost"}
	var merc_slot := int(payload.get("merc_slot", -1))
	var merc_cap := int(ctx.get("merc_cap", 8))
	if merc_slot < 0 or merc_slot >= merc_cap:
		return {"ok": false, "error": "bad_merc_slot"}
	var roster: Dictionary = prep.get("roster", {})
	var merc_count := 0
	for uid in roster.keys():
		var owned: Dictionary = roster[uid]
		if str(owned.get("kind", "")) == "merc":
			merc_count += 1
			if int(owned.get("merc_slot", -1)) == merc_slot:
				return {"ok": false, "error": "merc_slot_occupied"}
	if merc_count >= int(ctx.get("merc_cap", 8)):
		return {"ok": false, "error": "merc_slots_full"}
	var carrots := int(prep.get("carrots", 0))
	if carrots < cost:
		return {"ok": false, "error": "not_enough_carrots"}
	prep["carrots"] = carrots - cost
	prep["merc_carrots_spent_total"] = int(prep.get("merc_carrots_spent_total", 0)) + cost
	var uid := _add_unit(prep, merc_id, 1, 0, "merc")
	roster = prep.get("roster", {})
	var added_unit: Dictionary = roster[uid]
	added_unit["merc_slot"] = merc_slot
	roster[uid] = added_unit
	prep["roster"] = roster
	var spent := int(prep["merc_carrots_spent_total"])
	return {"ok": true, "result": {
		"uid": uid,
		"unit_id": merc_id,
		"merc_slot": merc_slot,
		"carrot_cost": cost,
		"carrots": int(prep["carrots"]),
		"merc_carrots_spent_total": spent,
		"farm_level": CarrotEconomy.farm_level_for_spent(spent),
		"capacity": CarrotEconomy.capacity_for_spent(spent),
		"camp_income": CarrotEconomy.income_for_spent(spent),
	}}

static func _draw_upgrade_stone(prep: Dictionary, _payload: Dictionary, ctx: Dictionary) -> Dictionary:
	var round_index := int(ctx.get("round_index", 0))
	if int(prep.get("stone_draw_used_round", -1)) == round_index:
		return {"ok": false, "error": "already_used"}
	var carrots := int(prep.get("carrots", 0))
	if carrots < CarrotEconomy.STONE_COST:
		return {"ok": false, "error": "not_enough_carrots"}
	var capacity := CarrotEconomy.capacity_for_spent(int(prep.get("merc_carrots_spent_total", 0)))
	if capacity < CarrotEconomy.STONE_COST:
		return {"ok": false, "error": "capacity_too_low"}
	var team_stones: Dictionary = ctx.get("team_stones", {})
	if team_stones.is_empty():
		return {"ok": false, "error": "team_stones_unavailable"}
	var roll := float(ctx.get("stone_roll", -1.0))
	if roll < 0.0 or roll >= 1.0:
		return {"ok": false, "error": "no_roll"}
	var stone_type := CarrotEconomy.draw_type_from_roll(roll)
	prep["carrots"] = carrots - CarrotEconomy.STONE_COST
	prep["stone_draw_used_round"] = round_index
	team_stones[stone_type] = int(team_stones.get(stone_type, 0)) + 1
	return {"ok": true, "result": {
		"stone_type": stone_type,
		"carrots": int(prep["carrots"]),
		"stone_draw_used_round": round_index,
		"team_upgrade_stones": team_stones.duplicate(true),
	}}

# 用一颗同属性的**队伍**升级石把三星升为四星。
#
# 这是四星唯一的来源（同名合成封顶在 MAX_MERGE_STAR，见 _merge）。石头在队伍仓库里，
# 三个人共用一份，所以「查库存 -> 扣石 -> 记血统」必须是一笔原子交易：设计文档
# 《萝卜采集与升级石系统设计实施方案》:128 要求同一颗石头被两名队友同时点时只能成一次。
# 服务端是同步主循环、本函数内不 await，这个原子性天然成立。
#
# 记的是 uid 而不是「第几格」：格子会被拖动、合成会吞掉棋子，只有 uid 跟着棋子走。
# prep["four_star_uids"] 就是 _room_validate_provenance() 判「这枚 star=4 是不是真的」
# 的唯一依据 —— 只凭客户端在棋盘快照里自报 star=4 是认不出伪造的（设计文档 :246）。
#
# ⚠️ 双实现登记：账本开关打开（economy_ledger_enabled）之后，prep["roster"] 会记录
# 每一枚棋子，届时血统应当收敛成 roster[uid].star == 4，**four_star_uids 要删掉**。
# 在那之前 roster 是空的（buy/merge/hire 三个动作还没有客户端调用点），只能用这份。
static func _use_upgrade_stone(prep: Dictionary, payload: Dictionary, ctx: Dictionary) -> Dictionary:
	var uid := str(payload.get("uid", ""))
	if uid.is_empty() or uid.length() > MAX_UID_LENGTH:
		return {"ok": false, "error": "bad_uid"}
	var granted: Dictionary = prep.get("four_star_uids", {})
	if granted.has(uid):
		return {"ok": false, "error": "already_four_star"}
	var unit_id := str(payload.get("unit_id", ""))
	var def := _unit_def_from(ctx, unit_id)
	if def.is_empty():
		return {"ok": false, "error": "unknown_unit"}
	if bool(def.get("is_mercenary", false)):
		return {"ok": false, "error": "mercenary"}
	var element := str(def.get("element", ""))
	if not CarrotEconomy.valid_stone_type(element):
		return {"ok": false, "error": "bad_element"}
	var team_stones: Dictionary = ctx.get("team_stones", {})
	if team_stones.is_empty():
		return {"ok": false, "error": "team_stones_unavailable"}
	if int(team_stones.get(element, 0)) <= 0:
		return {"ok": false, "error": "no_stone"}
	# 账本上线之后 roster 才有内容；有内容时必须核对星级与单位，防止拿一枚
	# 一星棋子的 uid 来换四星。
	var roster: Dictionary = prep.get("roster", {})
	if roster.has(uid):
		var owned: Dictionary = roster[uid]
		if str(owned.get("unit_id", "")) != unit_id:
			return {"ok": false, "error": "unit_mismatch"}
		if int(owned.get("star", 1)) != GameConstants.MAX_MERGE_STAR:
			return {"ok": false, "error": "not_three_star"}

	# 判据全部通过，开始改状态。
	team_stones[element] = int(team_stones[element]) - 1
	granted[uid] = {"unit_id": unit_id, "round": int(ctx.get("round_index", 0))}
	prep["four_star_uids"] = granted
	if roster.has(uid):
		var upgraded: Dictionary = roster[uid]
		upgraded["star"] = GameConstants.MAX_STAR
		roster[uid] = upgraded
		prep["roster"] = roster
	return {"ok": true, "result": {
		"uid": uid,
		"unit_id": unit_id,
		"stone_type": element,
		"team_upgrade_stones": team_stones.duplicate(true),
	}}


static func _unit_def_from(ctx: Dictionary, unit_id: String) -> Dictionary:
	if unit_id.is_empty():
		return {}
	for row in (ctx.get("unit_table", []) as Array):
		if typeof(row) == TYPE_DICTIONARY and str((row as Dictionary).get("id", "")) == unit_id:
			return row
	return {}


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
	# 合成封顶。读 MAX_MERGE_STAR 而不是 MAX_STAR：四星存在，但**只能靠升级石**，
	# 不能靠同名合成。两者共用一个常量时，把上限提到 4 就等于免费开放
	# 「3 个三星合成四星」，升级石系统被整个绕过。
	if star >= GameConstants.MAX_MERGE_STAR:
		return {"ok": false, "error": "star_capped"}
	if uids.size() != GameConstants.copies_to_upgrade(star):
		return {"ok": false, "error": "bad_merge_count"}
	# 客户端合成是「keeper 原地升星、被吞的置空」，keeper 的 uid 存活。
	# 账本这边以前是「全 erase + 铸一个新的」，两边 uid 语义分叉：合成之后
	# roster 里那一枚在棋盘上根本不存在。keeper_uid 由调用方指明，对齐两边。
	var keeper_uid := str(payload.get("keeper_uid", ""))
	if not keeper_uid.is_empty() and not seen.has(keeper_uid):
		return {"ok": false, "error": "keeper_not_in_merge"}
	for raw in uids:
		roster.erase(str(raw))
	prep["roster"] = roster
	var uid_new := _add_unit(prep, str(first.get("unit_id", "")), star + 1, basis, "unit", keeper_uid)
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

# preferred_uid：客户端已经给这枚棋子铸好了 uid（GameState.mint_piece_uid），
# 传进来就用它。两边用同一个标识，roster 才能和棋盘对上 —— 否则账本记 "u3"、
# 棋盘记 "9f2a1c04-7"，出售时 _sell 按 uid 查 roster 必然 unknown_uid，
# 而四星血统（four_star_uids）也永远收敛不到 roster 上。
static func _add_unit(prep: Dictionary, unit_id: String, star: int, cost_basis: int, kind: String,
		preferred_uid: String = "") -> String:
	var uid := preferred_uid
	if uid.is_empty() or (prep.get("roster", {}) as Dictionary).has(uid):
		uid = "u%d" % int(prep.get("next_uid", 1))
	prep["next_uid"] = int(prep.get("next_uid", 1)) + 1
	var roster: Dictionary = prep.get("roster", {})
	roster[uid] = {"unit_id": unit_id, "star": star, "cost_basis": cost_basis, "kind": kind}
	prep["roster"] = roster
	return uid
