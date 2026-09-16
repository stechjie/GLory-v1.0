extends Node

# 联机 3v3 里的萝卜系统：从客机点下按钮，到服务端账本，再到回执落回 GameState。
#
# 为什么单独一条：tools/carrot_economy_check.tscn 守的是**规则**（数值表、采集公式、
# 客户端/服务端同式），它全绿并不代表联机时按钮真的有反应 —— 那条链路上还有
# 三段纯联机代码从来没被任何检查碰过：
#
#   1. 服务端 _room_apply_economy() 的准入判据（阶段、gold_desync、开关）
#   2. 回执 _apply_carrot_receipt() 有没有把结果写回 GameState
#   3. room_state 的 economy 字段（_build_economy_state）到底带不带萝卜
#
# 客机的萝卜**全部**由服务端发（carrot_economy_check 已断言客机不本地采集），
# 所以上面任何一段断掉，玩家看到的都是同一个现象：面板数字恒为 0、按钮点了没反应，
# 而且不报任何错。
#
# 运行：
#   Godot_v4.7-stable_win64_console.exe --headless --path . tools/carrot_online_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const CarrotEconomy := preload("res://scripts/economy/CarrotEconomy.gd")
const EconomyLedgerScript := preload("res://scripts/multiplayer/EconomyLedger.gd")

const CHECK_NAME := "carrot_online"
const MY_SLOT := 0

# 服务端经济契约的指纹，与 NETWORK_PROTOCOL_VERSION 绑在一起。
# 改契约（ECONOMY_ACTIONS 或 room_state.economy 的字段集）就必须同时升协议号并
# 重新钉这两个值 —— 理由见 _case_server_contract_pinned()。
# 2026-09-10 从 21 跟到 22（聊天批次 A 顶号，见 NetworkConfig 的 v22 注释）。
# 2026-09-11 跟到 23 的有两处：四星升阶（改了经济契约，指纹换成下面这个）与聊天批次 D
# （加 RPC、契约没变）。两边同一天都写了 23，合并后顶到 24（见 NetworkConfig 的 v24 注释）；
# 指纹用四星那次的新值 —— 批次 D 没动经济契约。
# 2026-09-13 跟到 25（组队语音加 RPC 与语音通道，经济契约没变，指纹不动）。
# 2026-09-14 跟到 26（四条聊天 RPC 各加 team_only 参数，经济契约没变，指纹不动）。
# 2026-09-14 跟到 27（排队：线格没变，只为挡住没有排队逻辑的旧包顶号，指纹不动）。
# 2026-09-15 跟到 28（出战种族：准备 / 开始两条 RPC 各加 races 参数，经济契约没变，指纹不动）。
# 2026-09-16 跟到 29（萝卜营地新增宠物上报 RPC 与公开采集展示字段，经济账本字段不变）。
# ⚠️ **这个值落后于协议号会让下面那条断言静默失效**：断言判的是
# 「契约变了但协议号没变」，而它一旦落后，`VERSION != PINNED_PROTOCOL` 就恒为真，
# 于是改契约不顶号也照样绿。协议号每次顶，这里必须跟。
const PINNED_PROTOCOL := 29
const PINNED_CONTRACT := "YOp1apnKGVUXgHng"

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_case_flag_default()
	_case_server_contract_pinned()
	_case_room_state_carries_carrots()
	_case_public_carrot_presentation()
	_case_harvest_tech_online()
	_case_sell_then_harvest_modes()
	_case_ledger_shadow_roundtrip()
	_case_draw_stone_online()
	_case_four_star_online()
	_case_forged_four_star_rejected()
	await _case_client_panel_online()
	await _case_client_ui_tracks_room_state()
	_h.finish(get_tree())


# 起一个已经进备战的 6 人房，并按服务端的做法给每个座位播种账本 + 首次采集。
# 与 NetworkService._room_start_authoritative() 的经济段逐行对应，但不发 RPC。
func _make_prep_room(round_index: int) -> Dictionary:
	var room: Dictionary = NetworkService._new_room()
	var states: Array = room.get("slot_states", [])
	for slot in NetworkService.TEAM_SLOTS:
		states[slot] = "player"
	room["slot_states"] = states
	room["state"] = NetworkService.ROOM_PREP
	room["round_index"] = round_index
	for slot in NetworkService.TEAM_SLOTS:
		var prep: Dictionary = NetworkService._room_prep(room, slot)
		EconomyLedgerScript.reset_round(prep)
		EconomyLedgerScript.harvest_for_round(prep, round_index)
		# 服务端在推进回合时还会给每个座位摇一份商店（_room_next_round 的经济段）。
		# 少了这一步，账本里 shop.offers 是空的、offer_id 是空串，任何买入意图都会
		# 被 _buy 判 bad_index / stale_offer —— 那是脚手架的洞，不是产品缺陷。
		var shop: Dictionary = prep.get("shop", {})
		# 真服务器在开局前已经从「准备」里收下了座位的出战种族；这里没有大厅，直接用默认四族。
		shop["offers"] = NetworkService._server_roll_shop_offers(
			GameState.SHOP_UNIT_SLOTS, round_index, NetworkService.RacePick.default_races())
		shop["offer_id"] = NetworkService._make_offer_id()
		var sold: Array = []
		sold.resize(GameState.SHOP_UNIT_SLOTS)
		sold.fill(false)
		shop["sold"] = sold
		prep["shop"] = shop
	return room


# --- 1. 开关默认值 -------------------------------------------------------------
# 萝卜是唯一默认开着的服务端权威经济。这个默认值一旦被改成 false，
# 客机的萝卜链路会整条静默失效：面板置灰、意图 RPC 被 _economy_action_enabled 丢掉。
func _case_flag_default() -> void:
	_h.expect(bool(ServerFlags.DEFAULTS.get("carrot_economy_enabled", false)),
		"carrot_flag_off_by_default",
		"ServerFlags.carrot_economy_enabled 默认不是 true —— 客机的萝卜会恒为 0，按钮全灰")
	_h.expect(NetworkService.carrot_economy_enabled(), "carrot_flag_off",
		"本机 carrot_economy_enabled() 为 false（user://server_flags.json 覆盖了？）")


# --- 2. room_state 必须带萝卜 ---------------------------------------------------
# 客机唯一的萝卜来源。少一个字段 = 面板那一格永远是 0，且没有任何报错。
func _case_room_state_carries_carrots() -> void:
	var room := _make_prep_room(1)
	var state: Dictionary = NetworkService._build_economy_state(room, MY_SLOT)
	if not _h.expect(not state.is_empty(), "economy_state_empty",
			"room_state 的 economy 段是空的 —— 客机拿不到任何萝卜数据"):
		return
	if not _h.expect(bool(state.get("carrot_authoritative", false)), "carrot_not_authoritative",
			"economy.carrot_authoritative=false —— 客户端 _apply_carrot_state() 会整段跳过"):
		return
	for key in ["carrots", "harvest_tech_level", "merc_carrots_spent_total",
			"last_harvest_round", "stone_draw_used_round", "stone_draw_count", "team_upgrade_stones"]:
		_h.expect(state.has(key), "economy_state_missing_field",
			"room_state.economy 缺字段 %s —— 客机面板的这一格会一直显示初始值" % key)
	_h.expect(int(state.get("carrots", -1)) > 0, "server_not_harvesting",
		"进备战后服务端账本里萝卜仍是 %d —— 客机不本地采集，这里是 0 就永远是 0"
			% int(state.get("carrots", -1)))

	# 回执之外还有一条路：整包 room_state。它必须真的能改写客户端。
	GameState.reset_run()
	NetworkService._apply_carrot_state(state)
	_h.expect(GameState.carrots == int(state.get("carrots", -1)), "carrot_state_not_applied",
		"_apply_carrot_state() 之后客户端萝卜是 %d，服务端是 %d"
			% [GameState.carrots, int(state.get("carrots", -1))])


# --- 2b. 萝卜营地只展示实际占位宠物 --------------------------------------------
# 空位绝不能被客户端补成起始宠物；否则玩家会误以为场上有六人。AI 由服务端分配并
# 存储一个宠物，采集数字则只公开「本回合 +N」，不泄漏他人的萝卜余额。
func _case_public_carrot_presentation() -> void:
	var starters: Array = PetService.starter_ids()
	if not _h.expect(not starters.is_empty(), "starter_pet_missing", "pets.json 没有可用的起始宠物"):
		return
	var room := _make_prep_room(1)
	room["slot_states"] = ["player", "dummy", "empty", "empty", "empty", "empty"]
	room["seat_pets"] = {0: str(starters[0])}
	var payload: Dictionary = NetworkService._build_room_state(room, MY_SLOT)
	var pets: Dictionary = payload.get("seat_pets", {})
	var gains: Dictionary = payload.get("carrot_harvest_gains", {})
	_h.expect(str(pets.get(0, "")) == str(starters[0]), "player_pet_not_public",
		"已占位玩家的当前宠物没有出现在 room_state.seat_pets")
	_h.expect(not str(pets.get(1, "")).is_empty(), "dummy_pet_not_assigned",
		"AI 座位没有获得服务端分配的宠物")
	_h.expect(not pets.has(2), "empty_seat_pet_visible",
		"空座位被补出了宠物 —— 萝卜营地会看起来像固定六只宠物")
	_h.expect(gains.has(0) and gains.has(1) and not gains.has(2), "harvest_gains_not_seat_scoped",
		"本回合采集提示没有严格按实际玩家 / AI 座位下发")


# --- 3. 采集科技升级（客机 -> 服务端 -> 回执）------------------------------------
# 账本影子期（economy_ledger_enabled）之后，服务端**完全不看**客户端自报的金币，
# 一律读 prep.gold（每回合从 room.slot_gold 重新锚定）。
#
# 这一段的历史：开关打开之前，服务端用「自报金币不得高于已结算余额」做防伪造，
# 而卖棋子在当时是纯客户端行为、服务端镜像不会跟着涨 —— 于是本回合卖过一次棋子，
# 采集科技就整回合升不了，客户端弹「萝卜交易失败：gold_desync」。
func _case_harvest_tech_online() -> void:
	var saved_flags := ServerFlags._values.duplicate(true)
	ServerFlags._values["economy_ledger_enabled"] = true
	ServerFlags._values["economy_ledger_authoritative"] = true
	var price := CarrotEconomy.tech_price(0)

	# 3a. 账本余额够 -> 受理
	var room := _make_prep_room(2)
	var prep: Dictionary = NetworkService._room_prep(room, MY_SLOT)
	prep["gold"] = price + 50
	var receipt: Dictionary = NetworkService._room_apply_economy(
		room, MY_SLOT, "upgrade_harvest_tech", {"gold": price + 50})
	receipt["action"] = "upgrade_harvest_tech"
	if not _h.expect(bool(receipt.get("ok", false)), "tech_upgrade_rejected",
			"账本里有 %d 金、在备战阶段，采集科技升级仍被拒：%s"
				% [price + 50, str(receipt.get("error", "?"))]):
		return
	var result: Dictionary = receipt.get("result", {})
	_h.expect(int(result.get("harvest_tech_level", 0)) == 1, "tech_level_not_raised",
		"服务端受理了升级，但回执里的 harvest_tech_level 是 %d，应为 1"
			% int(result.get("harvest_tech_level", 0)))
	_h.expect(int(receipt.get("gold_after", -1)) == 50, "tech_gold_wrong",
		"扣完 %d 应剩 50，回执给的是 %d" % [price, int(receipt.get("gold_after", -1))])

	# 3b. 回执必须真的写回 GameState —— 否则玩家扣了钱、界面纹丝不动
	GameState.reset_run()
	GameState.gold = price + 50
	NetworkService._apply_carrot_receipt(receipt)
	_h.expect(GameState.harvest_tech_level == 1, "receipt_not_applied",
		"回执 ok 但客户端 harvest_tech_level 仍是 %d —— 按钮点了没东西"
			% GameState.harvest_tech_level)
	_h.expect(GameState.gold == int(receipt.get("gold_after", -1)), "receipt_gold_not_applied",
		"回执 ok 但客户端金币是 %d，回执里是 %d" % [GameState.gold, int(receipt.get("gold_after", -1))])

	# 3c. 自报金币对结果**没有任何影响** —— 账本余额说了算。
	# ⚠️ 这条以前写成「自报 999999 会被拒」，账本一开就变成了假绿：那时候拒它的是
	# 「余额不足」而不是「识破伪造」。改成对照实验才测得到真正的性质。
	var poor_a := _make_prep_room(2)
	(NetworkService._room_prep(poor_a, MY_SLOT) as Dictionary)["gold"] = price - 1
	var forged: Dictionary = NetworkService._room_apply_economy(
		poor_a, MY_SLOT, "upgrade_harvest_tech", {"gold": 999999})
	_h.expect(not bool(forged.get("ok", false)), "forged_gold_accepted",
		"账本余额只有 %d，客户端自报 999999 就买到了采集科技" % (price - 1))

	var poor_b := _make_prep_room(2)
	(NetworkService._room_prep(poor_b, MY_SLOT) as Dictionary)["gold"] = price - 1
	var honest: Dictionary = NetworkService._room_apply_economy(
		poor_b, MY_SLOT, "upgrade_harvest_tech", {"gold": 0})
	_h.expect(str(honest.get("error", "")) == str(forged.get("error", "")),
		"reported_gold_still_matters",
		"自报 0 与自报 999999 的结果不一样（%s vs %s）—— 服务端还在看客户端报的钱"
			% [str(honest.get("error", "?")), str(forged.get("error", "?"))])

	# 3d. 备战期卖棋子会让本地金币高于服务端上次结算的余额。
	# 这就是原来的 gold_desync：账本上线前这一步整回合被封死。
	var room_sold := _make_prep_room(2)
	var sold_gold: Array = room_sold.get("slot_gold", [])
	sold_gold[MY_SLOT] = price          # 服务端结算时的余额
	room_sold["slot_gold"] = sold_gold
	(NetworkService._room_prep(room_sold, MY_SLOT) as Dictionary)["gold"] = price + 20
	var after_sell: Dictionary = NetworkService._room_apply_economy(
		room_sold, MY_SLOT, "upgrade_harvest_tech", {"gold": price + 20})   # 卖掉一个棋子退了 20
	_h.expect(bool(after_sell.get("ok", false)), "sell_then_upgrade_blocked",
		"备战期卖棋子涨了金币之后，采集科技升级被判 %s —— 玩家点按钮没有任何反应"
			% str(after_sell.get("error", "?")))

	# 3e. 战斗/结算阶段不许改经济
	var battle_room := _make_prep_room(2)
	battle_room["state"] = NetworkService.ROOM_BATTLE
	var in_battle: Dictionary = NetworkService._room_apply_economy(
		battle_room, MY_SLOT, "upgrade_harvest_tech", {"gold": 100})
	_h.expect(not bool(in_battle.get("ok", false)), "economy_in_battle",
		"战斗阶段还能升采集科技")
	ServerFlags._values = saved_flags

func _case_sell_then_harvest_modes() -> void:
	var saved_flags := ServerFlags._values.duplicate(true)
	for shadow in [false, true]:
		ServerFlags._values["economy_ledger_enabled"] = shadow
		ServerFlags._values["economy_ledger_authoritative"] = false
		var room := _make_prep_room(5)
		var prep: Dictionary = NetworkService._room_prep(room, MY_SLOT)
		prep["gold"] = 195
		prep["harvest_tech_level"] = 1
		room["slot_gold"][MY_SLOT] = 195
		var poor := NetworkService._room_apply_economy(room, MY_SLOT, "upgrade_harvest_tech", {"gold": 195})
		_h.expect(not poor.get("ok", false) and prep.gold == 195 and prep.harvest_tech_level == 1, "before_sale", "卖棋前195不足200，状态不变")
		var receipt := NetworkService._room_apply_economy(room, MY_SLOT, "upgrade_harvest_tech", {"gold": 210})
		_h.expect(receipt.get("ok", false) and prep.gold == 10 and prep.harvest_tech_level == 2, "sold_upgrade", "卖棋后210应能升级，剩余10；shadow=" + str(shadow))
		_h.expect(room.slot_gold[MY_SLOT] == 10, "sold_snapshot", "房间金币镜像更新为10")
		var saved := [GameState.gold, GameState.harvest_tech_level]
		GameState.gold = 210
		NetworkService._apply_carrot_receipt(receipt)
		_h.expect(GameState.gold == 10 and GameState.harvest_tech_level == 2, "sold_receipt", "升级回执应用到客户端")
		GameState.gold = saved[0]
		GameState.harvest_tech_level = saved[1]
		var before := prep.duplicate(true)
		room["round_index"] = 1
		var locked := NetworkService._room_apply_economy(room, MY_SLOT, "upgrade_harvest_tech", {"gold": 500})
		_h.expect(not locked.get("ok", false) and prep == before, "locked_unchanged", "首回合拒绝且不改变账本")
		room["round_index"] = 5
		for invalid in [{}, {"gold": -1}, {"gold": "210"}]:
			var rejected := NetworkService._room_apply_economy(room, MY_SLOT, "upgrade_harvest_tech", invalid)
			_h.expect(not rejected.get("ok", false) and prep == before, "invalid_balance", "非法余额不改变账本")
	ServerFlags._values = saved_flags


# --- 3f. 影子记账：客户端那一笔必须能被账本原样收下 --------------------------------
# 影子期的全部价值就是「两边算出来的钱一样」。对不上就永远翻不了 authoritative
# （NetworkService 里那条注释：影子期零差异是翻开关的唯一依据）。
#
# 这条守的是链路本身能通：客户端用**自己铸的 uid** 买入 -> 账本按同一个 uid 记进
# roster -> 卖掉时按同一个 uid 查得到。以前账本自己铸 "u1"、棋盘记的是别的，
# 卖出必然 unknown_uid，roster 永远对不上棋盘。
func _case_ledger_shadow_roundtrip() -> void:
	if not _h.expect(NetworkService.economy_enabled(), "ledger_disabled",
			"economy_ledger_enabled 是关的 —— 影子期没上线，账本收不到任何一笔"):
		return
	var room := _make_prep_room(2)
	var prep: Dictionary = NetworkService._room_prep(room, MY_SLOT)
	prep["gold"] = 500
	# 服务端摇好的商店：客户端就是照着这一份显示的（_adopt_server_shop）
	var shop: Dictionary = prep.get("shop", {})
	var offers: Array = shop.get("offers", [])
	if not _h.expect(not offers.is_empty(), "server_shop_empty",
			"服务端账本里这一轮没有商店 —— 客户端拿不到可买的货"):
		return
	var offer_id := str(shop.get("offer_id", ""))
	_h.expect(not offer_id.is_empty(), "server_shop_no_offer_id",
		"服务端商店没有 offer_id —— 买入意图会被 stale_offer 全拒")

	GameState.reset_run()
	var my_uid := GameState.mint_piece_uid()
	var buy: Dictionary = NetworkService._room_apply_economy(room, MY_SLOT, "buy",
		{"shop_index": 0, "offer_id": offer_id, "uid": my_uid})
	if not _h.expect(bool(buy.get("ok", false)), "shadow_buy_rejected",
			"照着服务端商店买第 0 格仍被拒：%s" % str(buy.get("error", "?"))):
		return
	_h.expect(str((buy.get("result", {}) as Dictionary).get("uid", "")) == my_uid,
		"ledger_minted_own_uid",
		"账本没有采用客户端的 uid（给的是 %s，客户端是 %s）—— roster 与棋盘对不上，"
			% [str((buy.get("result", {}) as Dictionary).get("uid", "")), my_uid]
		+ "卖出时会 unknown_uid")

	# Keep a second piece: selling the last unit is intentionally forbidden.
	prep.roster["fixture-companion"] = {"unit_id": str(offers[0].get("id", "")), "star": 1, "kind": "unit", "cost_basis": 10}
	var sell: Dictionary = NetworkService._room_apply_economy(room, MY_SLOT, "sell",
		{"uid": my_uid})
	_h.expect(bool(sell.get("ok", false)), "shadow_sell_rejected",
		"刚买的那一枚按同一个 uid 卖不掉：%s" % str(sell.get("error", "?")))


# --- 4. 抽升级石（客机 -> 服务端 -> 回执）---------------------------------------
func _case_draw_stone_online() -> void:
	var room := _make_prep_room(3)
	var prep: Dictionary = NetworkService._room_prep(room, MY_SLOT)
	# 攒够钱、把萝卜田顶到能存下 50 萝卜的那一级
	var need_spent := 0
	for level in CarrotEconomy.FARM_THRESHOLDS.size():
		if CarrotEconomy.farm_capacity_for_level(level) >= CarrotEconomy.STONE_FIRST_COST:
			need_spent = CarrotEconomy.farm_threshold_for_level(level)
			break
	prep["merc_carrots_spent_total"] = need_spent
	prep["carrots"] = CarrotEconomy.stone_cost_for_draw(0)

	var receipt: Dictionary = NetworkService._room_apply_economy(
		room, MY_SLOT, "draw_upgrade_stone", {})
	receipt["action"] = "draw_upgrade_stone"
	if not _h.expect(bool(receipt.get("ok", false)), "draw_rejected",
			"萝卜够 %d、田到 Lv%d，抽升级石仍被拒：%s" % [
				CarrotEconomy.stone_cost_for_draw(0),
				CarrotEconomy.farm_level_for_spent(need_spent) + 1,
				str(receipt.get("error", "?")),
			]):
		return
	var result: Dictionary = receipt.get("result", {})
	_h.expect(int(result.get("cost", -1)) == 50, "first_draw_price_wrong",
		"个人第一次抽石实际扣了 %d，应为 50" % int(result.get("cost", -1)))
	var stone_type := str(result.get("stone_type", ""))
	_h.expect(CarrotEconomy.STONE_TYPES.has(stone_type), "draw_bad_stone_type",
		"回执里的石头种类是 %s，不在 %s 里" % [stone_type, str(CarrotEconomy.STONE_TYPES)])

	# 石头进的是**本方队伍**仓库（0..2 一份、3..5 一份），不是全房共享
	var mine: Dictionary = NetworkService._room_team_stones(room, MY_SLOT)
	var theirs: Dictionary = NetworkService._room_team_stones(room, NetworkService.TEAM_SLOTS - 1)
	_h.expect(int(mine.get(stone_type, 0)) == 1, "stone_not_in_own_warehouse",
		"抽到的%s石没进本方仓库" % stone_type)
	_h.expect(int(theirs.get(stone_type, 0)) == 0, "stone_leaked_to_rival",
		"抽到的%s石同时出现在对方仓库里" % stone_type)

	# 回执必须写回客户端
	GameState.reset_run()
	NetworkService._apply_carrot_receipt(receipt)
	_h.expect(int(GameState.team_upgrade_stones.get(stone_type, 0)) == 1, "draw_receipt_not_applied",
		"回执 ok 但客户端仓库里 %s 石是 %d 颗 —— 抽了等于没抽"
			% [stone_type, int(GameState.team_upgrade_stones.get(stone_type, 0))])
	_h.expect(GameState.stone_draw_used_round == 3, "draw_round_not_applied",
		"回执 ok 但客户端 stone_draw_used_round 是 %d，应为 3" % GameState.stone_draw_used_round)
	_h.expect(GameState.stone_draw_count == 1, "draw_count_not_applied",
		"回执 ok 但客户端个人抽石计数是 %d，应为 1" % GameState.stone_draw_count)

	# 每回合一次
	prep["carrots"] = CarrotEconomy.stone_cost_for_draw(1)
	var again: Dictionary = NetworkService._room_apply_economy(room, MY_SLOT, "draw_upgrade_stone", {})
	_h.expect(not bool(again.get("ok", false)), "draw_twice_in_one_round",
		"同一回合抽了第二次升级石")

	# 下一回合同一位玩家再抽，价格应从50升到70；石头仍进入队伍共享仓库。
	room["round_index"] = 4
	EconomyLedgerScript.reset_round(prep)
	# 第一颗可在 Lv.4（容量60）抽到；第二颗70萝卜要求农田继续升到 Lv.5（容量90）。
	prep["merc_carrots_spent_total"] = CarrotEconomy.farm_threshold_for_level(4)
	prep["carrots"] = CarrotEconomy.stone_cost_for_draw(1)
	var second: Dictionary = NetworkService._room_apply_economy(room, MY_SLOT, "draw_upgrade_stone", {})
	_h.expect(bool(second.get("ok", false)), "second_draw_rejected",
		"下一回合个人第二次抽石被拒：%s" % str(second.get("error", "?")))
	var second_result: Dictionary = second.get("result", {})
	_h.expect(int(second_result.get("cost", -1)) == 70 and int(second_result.get("stone_draw_count", -1)) == 2,
		"second_draw_price_wrong", "第二次抽石的价格/计数应为70/2，实际为%d/%d"
			% [int(second_result.get("cost", -1)), int(second_result.get("stone_draw_count", -1))])


# --- 5. 四星升级：服务端权威 ------------------------------------------------------
# 四星要消耗**队伍共享**仓库里的一颗石头，那个仓库在联机里是服务端的
# room.team_upgrade_stones。这一段以前完全没有服务端动作：客机只改本地副本，
# 下一个 room_state 一到 _apply_carrot_state() 就整块覆盖回去 —— 表现是
# 「点了没东西」，而且同一颗石头能反复用。
#
# 动作名用 use_upgrade_stone，与设计文档
# 《萝卜采集与升级石系统设计实施方案》:241 一致（本用例第一版钉的是
# four_star_upgrade，以文档为准改过来了）。
func _case_four_star_online() -> void:
	if not _h.expect(NetworkService.ECONOMY_ACTIONS.has("use_upgrade_stone"),
			"four_star_no_server_action",
			"ECONOMY_ACTIONS 里没有 use_upgrade_stone —— 联机时客机升四星只改本地，"
			+ "石头会被下一个 room_state 覆盖回来，棋子星级也没进服务端账本"):
		return

	var target := _elemental_unit()
	if target.is_empty():
		return
	var element := str(target.get("element", ""))
	var unit_id := str(target.get("id", ""))

	# --- 5a. 正常一次：石头真的从服务端仓库里少一颗，回执把星级落到那枚棋子上 ---
	var room := _make_prep_room(4)
	var warehouse: Dictionary = NetworkService._room_team_stones(room, MY_SLOT)
	for stone in CarrotEconomy.STONE_TYPES:
		warehouse[stone] = 1
	GameState.reset_run()
	NetworkService._apply_carrot_state(NetworkService._build_economy_state(room, MY_SLOT))
	var uid := GameState.mint_piece_uid()
	GameState.board_slots[0] = {"id": unit_id, "uid": uid,
		"star": GameState.MAX_MERGE_STAR, "def": target}
	GameState.gold = 2000

	var receipt: Dictionary = NetworkService._room_apply_economy(
		room, MY_SLOT, "use_upgrade_stone", {"uid": uid, "unit_id": unit_id, "gold": 2000})
	receipt["action"] = "use_upgrade_stone"
	if not _h.expect(bool(receipt.get("ok", false)), "four_star_rejected",
			"仓库里有 %s 石、棋子是三星，服务端仍拒绝升四星：%s"
				% [element, str(receipt.get("error", "?"))]):
		return
	_h.expect(int(warehouse.get(element, 0)) == 0, "four_star_stone_not_spent",
		"服务端受理了升级，但队伍仓库里的 %s 石还剩 %d 颗 —— 石头没真扣"
			% [element, int(warehouse.get(element, 0))])

	NetworkService._apply_carrot_receipt(receipt)
	_h.expect(int((GameState.board_slots[0] as Dictionary).get("star", 1)) == GameState.MAX_UNIT_STAR,
		"four_star_receipt_not_applied",
		"回执 ok，但棋子星级仍是 %d —— 玩家点了按钮什么都没发生"
			% int((GameState.board_slots[0] as Dictionary).get("star", 1)))
	_h.expect(int(GameState.team_upgrade_stones.get(element, 0)) == 0,
		"four_star_client_stone_stale",
		"回执 ok，但客户端仓库里 %s 石还剩 %d 颗"
			% [element, int(GameState.team_upgrade_stones.get(element, 0))])

	# --- 5b. 下一份 room_state 不能把石头还回来（这是原缺陷的核心症状）---
	NetworkService._apply_carrot_state(NetworkService._build_economy_state(room, MY_SLOT))
	_h.expect(int(GameState.team_upgrade_stones.get(element, 0)) == 0, "four_star_stone_restored",
		"升四星消耗的 %s 石在下一个 room_state 之后又变回 %d 颗 —— 石头能反复用"
			% [element, int(GameState.team_upgrade_stones.get(element, 0))])

	# --- 5c. 同一枚棋子不能升第二次（幂等 + 不重复扣石）---
	warehouse[element] = 1
	var again: Dictionary = NetworkService._room_apply_economy(
		room, MY_SLOT, "use_upgrade_stone", {"uid": uid, "unit_id": unit_id, "gold": 2000})
	_h.expect(not bool(again.get("ok", false)), "four_star_double_spend",
		"同一个 uid 升了第二次四星")
	_h.expect(str(again.get("error", "")) == "already_four_star", "four_star_repeat_wrong_reason",
		"重复升级的拒绝理由是 %s，应为 already_four_star" % str(again.get("error", "?")))
	_h.expect(int(warehouse.get(element, 0)) == 1, "four_star_repeat_spent_stone",
		"重复升级被拒，却还是扣了一颗石头")

	# --- 5d. 没有石头就不许升 ---
	var poor := _make_prep_room(4)
	var empty_house: Dictionary = NetworkService._room_team_stones(poor, MY_SLOT)
	for stone in CarrotEconomy.STONE_TYPES:
		empty_house[stone] = 0
	var denied: Dictionary = NetworkService._room_apply_economy(
		poor, MY_SLOT, "use_upgrade_stone", {"uid": "x-1", "unit_id": unit_id, "gold": 2000})
	_h.expect(str(denied.get("error", "")) == "no_stone", "four_star_without_stone",
		"仓库空着还能升四星（error=%s）" % str(denied.get("error", "?")))

	# --- 5e. 属性必须对得上：服务端只认数据表里的 element，不认客户端自报 ---
	var wrong := _make_prep_room(4)
	var wrong_house: Dictionary = NetworkService._room_team_stones(wrong, MY_SLOT)
	for stone in CarrotEconomy.STONE_TYPES:
		wrong_house[stone] = 5 if stone != element else 0
	var mismatched: Dictionary = NetworkService._room_apply_economy(
		wrong, MY_SLOT, "use_upgrade_stone", {"uid": "y-1", "unit_id": unit_id, "gold": 2000})
	_h.expect(not bool(mismatched.get("ok", false)), "four_star_wrong_element",
		"手里只有别的属性的石头，%s 属性的棋子却升成功了 —— 属性门槛失效" % element)

	# --- 5f. 佣兵不能升四星（设计文档 §2.6）---
	var merc_room := _make_prep_room(4)
	var merc_house: Dictionary = NetworkService._room_team_stones(merc_room, MY_SLOT)
	for stone in CarrotEconomy.STONE_TYPES:
		merc_house[stone] = 5
	var mercs: Array = DataRegistry.get_table("mercenaries").get("mercenaries", [])
	if not mercs.is_empty():
		var merc_res: Dictionary = NetworkService._room_apply_economy(
			merc_room, MY_SLOT, "use_upgrade_stone",
			{"uid": "z-1", "unit_id": str((mercs[0] as Dictionary).get("id", "")), "gold": 2000})
		_h.expect(not bool(merc_res.get("ok", false)), "four_star_mercenary",
			"佣兵被升成了四星 —— 佣兵只存在一个回合，升星是白送")

	# --- 5g. 同队两人抢最后一颗石头，只能成一个（设计文档 :128 / :320）---
	var race := _make_prep_room(4)
	var shared: Dictionary = NetworkService._room_team_stones(race, MY_SLOT)
	for stone in CarrotEconomy.STONE_TYPES:
		shared[stone] = 0
	shared[element] = 1
	var teammate := _same_team_slot(MY_SLOT)
	var first: Dictionary = NetworkService._room_apply_economy(
		race, MY_SLOT, "use_upgrade_stone", {"uid": "race-a", "unit_id": unit_id, "gold": 2000})
	var second: Dictionary = NetworkService._room_apply_economy(
		race, teammate, "use_upgrade_stone", {"uid": "race-b", "unit_id": unit_id, "gold": 2000})
	var wins := int(bool(first.get("ok", false))) + int(bool(second.get("ok", false)))
	_h.expect(wins == 1, "stone_double_spend",
		"库存只有 1 颗 %s 石，同队两名队员各发一次意图，成功了 %d 次（应恰好 1 次）"
			% [element, wins])
	_h.expect(int(shared.get(element, 0)) == 0, "stone_negative",
		"抢完之后仓库里 %s 石是 %d 颗" % [element, int(shared.get(element, 0))])


# --- 5h. 血统核验：没走过意图就不许在棋盘里自报四星 ---------------------------------
# 设计文档 :246 点名的洞：「仅仅允许客户端在棋盘快照里上报 star = 4
# 会留下直接修改客户端制造四星的漏洞」。
func _case_forged_four_star_rejected() -> void:
	var target := _elemental_unit()
	if target.is_empty():
		return
	var unit_id := str(target.get("id", ""))
	var element := str(target.get("element", ""))
	var room := _make_prep_room(4)

	var forged := {
		"board": [{"slot": 0, "id": unit_id, "uid": "forged-1",
			"star": GameState.MAX_UNIT_STAR, "is_mercenary": false, "race_relations": {}}],
		"mercenaries": [],
	}
	var verdict: Dictionary = NetworkService._room_validate_provenance(room, MY_SLOT, forged)
	_h.expect(not bool(verdict.get("ok", true)), "forged_four_star_accepted",
		"没走过 use_upgrade_stone 的 star=4 棋盘被服务端接受了 —— 改客户端就能造四星")
	_h.expect(str(verdict.get("reason", "")).begins_with("forged_four_star"),
		"forged_four_star_wrong_reason",
		"拒绝理由是 %s，应以 forged_four_star 开头" % str(verdict.get("reason", "?")))

	# 三星及以下不受影响，否则整块棋盘都提交不上去
	var plain := {
		"board": [{"slot": 0, "id": unit_id, "uid": "",
			"star": GameState.MAX_MERGE_STAR, "is_mercenary": false, "race_relations": {}}],
		"mercenaries": [],
	}
	_h.expect(bool(NetworkService._room_validate_provenance(room, MY_SLOT, plain).get("ok", false)),
		"plain_board_rejected", "三星棋盘也被血统核验拒了 —— 所有人都提交不了")

	# 走过意图的那一枚必须放行，否则合法玩家会被自己的四星卡住整局
	var uid := "legit-1"
	var house: Dictionary = NetworkService._room_team_stones(room, MY_SLOT)
	house[element] = 1
	var ok_receipt: Dictionary = NetworkService._room_apply_economy(
		room, MY_SLOT, "use_upgrade_stone", {"uid": uid, "unit_id": unit_id, "gold": 2000})
	if _h.expect(bool(ok_receipt.get("ok", false)), "four_star_legit_rejected",
			"合法升级被拒：%s" % str(ok_receipt.get("error", "?"))):
		var legit := {
			"board": [{"slot": 0, "id": unit_id, "uid": uid,
				"star": GameState.MAX_UNIT_STAR, "is_mercenary": false, "race_relations": {}}],
			"mercenaries": [],
		}
		var pass_verdict: Dictionary = NetworkService._room_validate_provenance(room, MY_SLOT, legit)
		_h.expect(bool(pass_verdict.get("ok", false)), "legit_four_star_rejected",
			"走过 use_upgrade_stone 的四星仍被判伪造（%s）—— 合法玩家会被自己的四星卡住"
				% str(pass_verdict.get("reason", "?")))

	# 战斗阶段不许升四星
	room["state"] = NetworkService.ROOM_BATTLE
	house[element] = 1
	var in_battle: Dictionary = NetworkService._room_apply_economy(
		room, MY_SLOT, "use_upgrade_stone", {"uid": "battle-1", "unit_id": unit_id, "gold": 2000})
	_h.expect(not bool(in_battle.get("ok", false)), "four_star_in_battle",
		"战斗阶段还能升四星")


func _elemental_unit() -> Dictionary:
	for row in (DataRegistry.get_table("race_units").get("units", []) as Array):
		var d: Dictionary = row
		if CarrotEconomy.STONE_TYPES.has(str(d.get("element", ""))):
			return d
	_h.fail("no_elemental_unit", "找不到带天/地/人属性的棋子")
	return {}


func _same_team_slot(slot: int) -> int:
	for other in NetworkService.TEAM_SLOTS:
		if other != slot and GameConstants.team_of_slot(other) == GameConstants.team_of_slot(slot):
			return other
	return slot


# --- 6. 客机手上的面板到底是什么样 ----------------------------------------------
# 前面五条都在服务端和 GameState 层。这一条进真实的 PrepScreen，按客机的身份
# （team_active=true / is_host=false）把萝卜营地开出来，断言玩家看得见、按得动。
#
# "按钮按了没东西" 有两种完全不同的成因，这里分开断言：
#   a. 面板压根没弹出来（入口按钮的回调断了 / 节点没进树）
#   b. 面板弹出来了，但里面的按钮 disabled（数据没到 / 判据把客机挡了）
func _case_client_panel_online() -> void:
	var packed := load("res://scenes/prep/PrepScreen.tscn") as PackedScene
	if not _h.expect(packed != null, "scene_load_failed", "PrepScreen.tscn 无法加载"):
		return
	var was_active := NetworkService.team_active
	var was_host := NetworkService.is_host
	GameState.reset_run()
	NetworkService.team_active = true
	NetworkService.is_host = false
	var screen: Node = packed.instantiate()
	add_child(screen)
	await get_tree().process_frame

	var panel = screen.get("_carrot_panel")
	if not _h.expect(panel != null and is_instance_valid(panel), "panel_missing",
			"客机的备战界面里没有萝卜营地面板"):
		_teardown(screen, was_active, was_host)
		return
	_h.expect(panel.is_inside_tree(), "panel_not_in_tree",
		"萝卜营地面板没进场景树 —— 入口按钮把 visible 置 true 也不会显示任何东西")
	_h.expect(screen.get("_carrot_button") != null, "entry_button_missing",
		"右侧没有萝卜营地入口按钮")

	# a. 入口按钮：走真实回调
	screen.call("_toggle_carrot_camp")
	await get_tree().process_frame
	_h.expect(bool(panel.visible), "panel_did_not_open",
		"按下萝卜营地入口按钮之后面板仍然不可见")

	# b. 给一份服务端状态：钱够、萝卜够、田到能抽石头的那一级
	var need_spent := 0
	for level in CarrotEconomy.FARM_THRESHOLDS.size():
		if int(CarrotEconomy.FARM_CAPACITIES[level]) >= CarrotEconomy.STONE_COST:
			need_spent = int(CarrotEconomy.FARM_THRESHOLDS[level])
			break
	NetworkService._apply_carrot_state({
		"carrot_authoritative": true,
		"carrots": CarrotEconomy.STONE_COST,
		"harvest_tech_level": 0,
		"merc_carrots_spent_total": need_spent,
		"last_harvest_round": GameState.round_index,
		"last_harvest_gain": 3,
		"stone_draw_used_round": -1,
		"team_upgrade_stones": {"sky": 0, "land": 0, "ren": 0},
	})
	GameState.gold = CarrotEconomy.tech_price(0) + 50
	# 采集升级从第二回合解锁；本用例检查已解锁后的联机按钮。
	GameState.round_index = 2
	panel.call("refresh")
	await get_tree().process_frame

	var tech_button: Button = panel.get("_tech_button")
	var draw_button: Button = panel.get("_draw_button")
	if _h.expect(tech_button != null, "tech_button_missing", "面板里没有采集科技按钮"):
		_h.expect(not tech_button.disabled, "tech_button_disabled_online",
			"客机金币 %d、科技 Lv0（价 %d），采集科技按钮仍是禁用的 —— 点了没有任何反应"
				% [GameState.gold, CarrotEconomy.tech_price(0)])
	if _h.expect(draw_button != null, "draw_button_missing", "面板里没有抽升级石按钮"):
		_h.expect(not draw_button.disabled, "draw_button_disabled_online",
			"客机萝卜 %d/%d、本回合还没抽过，抽升级石按钮仍是禁用的 —— 点了没有任何反应"
				% [GameState.carrots, GameState.carrot_capacity()])

	# 数字有没有真的跟着服务端走
	var carrot_label: Label = panel.get("_carrot_balance")
	if carrot_label == null:
		carrot_label = panel.get("_carrot_value")
	if _h.expect(carrot_label != null, "carrot_label_missing", "面板里没有萝卜数字"):
		_h.expect(carrot_label.text.contains(str(GameState.carrots)), "carrot_label_stale",
			"面板显示 \"%s\"，服务端给的是 %d 萝卜" % [carrot_label.text, GameState.carrots])

	_teardown(screen, was_active, was_host)


func _teardown(screen: Node, was_active: bool, was_host: bool) -> void:
	screen.queue_free()
	NetworkService.team_active = was_active
	NetworkService.is_host = was_host


# --- 0. 服务端契约必须钉在协议号上 ----------------------------------------------
# 2026-09-09 实测到的现场：萝卜的服务端代码（ECONOMY_ACTIONS 加三个动作、
# room_state.economy 加六个萝卜字段）是在 4a10441 加进来的，而
# NETWORK_PROTOCOL_VERSION 从 8504846 起就没动过，两边都是 17。
#
# 后果：线上跑着的旧服务端与新客户端**握手通过**（NetProtocol 只比协议号），
# 玩家正常进 3v3 房间，但那份服务端根本不认识 upgrade_harvest_tech /
# draw_upgrade_stone / hire_merc_carrot —— _rpc_economy_intent 直接 return，
# 不发回执；room_state 里也没有 carrot_authoritative，客户端 _apply_carrot_state()
# 整段跳过。玩家看到的是：萝卜恒为 0、三个按钮全部点了没反应、一条报错都没有。
#
# 协议号存在的全部意义就是拦住这种「两边代码不一样却还能连上」。这条检查把
# 「改了服务端契约却忘了升协议号」从一个只能靠玩家反馈发现的线上故障，
# 变成一条本地就会红的断言。
func _case_server_contract_pinned() -> void:
	var actions: Array = NetworkService.ECONOMY_ACTIONS.duplicate()
	actions.sort()
	var room := _make_prep_room(1)
	var fields: Array = (NetworkService._build_economy_state(room, MY_SLOT) as Dictionary).keys()
	fields.sort()
	var fingerprint := ",".join(PackedStringArray(actions)) + "|" + ",".join(PackedStringArray(fields))
	var digest := Marshalls.raw_to_base64(fingerprint.sha256_buffer()).substr(0, 16)

	# 先保证萝卜三件套真的在契约里（服务端少一个，对应按钮就永远静默）
	for action in ["upgrade_harvest_tech", "hire_merc_carrot", "draw_upgrade_stone"]:
		_h.expect(actions.has(action), "carrot_action_missing",
			"ECONOMY_ACTIONS 里没有 %s —— 服务端会静默丢掉这个意图，客户端连回执都收不到" % action)

	if PINNED_CONTRACT.is_empty():
		_h.note("服务端经济契约指纹 = %s（协议号 %d）。把它填进 PINNED_CONTRACT 即可启用钉死断言。"
			% [digest, NetworkConfig.NETWORK_PROTOCOL_VERSION])
		_h.item()
		return
	if digest != PINNED_CONTRACT:
		_h.expect(NetworkConfig.NETWORK_PROTOCOL_VERSION != PINNED_PROTOCOL,
			"contract_changed_without_protocol_bump",
			"服务端经济契约变了（指纹 %s -> %s），但 NETWORK_PROTOCOL_VERSION 还是 %d。"
				% [PINNED_CONTRACT, digest, NetworkConfig.NETWORK_PROTOCOL_VERSION]
			+ "旧服务端与新客户端会照常握手成功，然后静默丢掉新动作 —— "
			+ "请升协议号，并把 PINNED_PROTOCOL / PINNED_CONTRACT 一起改成新值")
	else:
		_h.item()


# --- 7. 客机界面必须跟着 room_state 走 -------------------------------------------
# 客机的萝卜**全部**来自服务端，而 room_state 只写 GameState、不碰 UI。
# 这三条守的是「服务端发了、界面也确实动了」，三种失效模式当初各自独立存在：
#   a. 佣兵卡的增量刷新签名漏了 carrots -> 卡片价格/可买态冻在旧值
#   b. session_changed 没刷萝卜面板 -> 面板数字与按钮置灰态冻住
#   c. 采集反馈只在 _ready() 判一次，而客机那一刻权威采集还没到 -> 挖土动画永不播
func _case_client_ui_tracks_room_state() -> void:
	var packed := load("res://scenes/prep/PrepScreen.tscn") as PackedScene
	if not _h.expect(packed != null, "scene_load_failed", "PrepScreen.tscn 无法加载"):
		return
	var was_active := NetworkService.team_active
	var was_host := NetworkService.is_host
	GameState.reset_run()
	NetworkService.team_active = true
	NetworkService.is_host = false
	var screen: Node = packed.instantiate()
	add_child(screen)
	await get_tree().process_frame

	# --- a. 佣兵卡签名跟着萝卜走 ---
	screen.call("_toggle_merc_picker")
	await get_tree().process_frame
	screen.call("_refresh_mercenary_overlay")
	var sig_before := str(screen.get("_merc_overlay_signature"))
	_apply_server_carrots(screen, 40, 0, GameState.round_index, 0)
	screen.call("_refresh_mercenary_overlay")
	var sig_after := str(screen.get("_merc_overlay_signature"))
	_h.expect(sig_before != sig_after, "merc_card_stale_on_carrot_change",
		"萝卜从 0 变成 40，佣兵卡的刷新签名没变（%s）—— 12 张卡不会重建，"
			% sig_after
		+ "涨了的还挂着「萝卜不足」点不动，跌了的还显示可买、点下去静默 return")
	screen.call("_close_merc_picker")
	await get_tree().process_frame

	# --- b. session_changed 要刷新萝卜面板 ---
	var panel = screen.get("_carrot_panel")
	if _h.expect(panel != null and is_instance_valid(panel), "panel_missing", "没有萝卜营地面板"):
		screen.call("_toggle_carrot_camp")
		await get_tree().process_frame
		var label: Label = panel.get("_carrot_balance")
		if _h.expect(label != null, "carrot_label_missing", "面板里没有萝卜数字"):
			var before := label.text
			_apply_server_carrots(screen, 77, 0, GameState.round_index, 0)
			NetworkService.session_changed.emit()
			await get_tree().process_frame
			_h.expect(label.text != before and label.text.contains("77"),
				"panel_frozen_on_room_state",
				"服务端把萝卜发到 77，面板仍显示 \"%s\" —— 客机面板在两次本地操作之间是冻的"
					% label.text)

	# --- c. 权威采集到达时补播采集反馈 ---
	screen.set("_carrot_feedback_round", -1)
	_apply_server_carrots(screen, 80, 3, GameState.round_index, 3)
	NetworkService.session_changed.emit()
	await get_tree().process_frame
	_h.expect(int(screen.get("_carrot_feedback_round")) == GameState.round_index,
		"harvest_feedback_never_plays",
		"权威采集（本回合 +3）到达后没有播采集反馈 —— 客机进备战时服务端还没推进回合，"
		+ "_ready() 里那条 last_harvest_round == round_index 判据结构性不成立，"
		+ "不在这里补播就等于挖土动画和 +N 飘字对客机从来不存在")

	screen.queue_free()
	await get_tree().process_frame
	NetworkService.team_active = was_active
	NetworkService.is_host = was_host


func _apply_server_carrots(_screen: Node, carrots: int, gain: int, harvest_round: int, spent: int) -> void:
	NetworkService._apply_carrot_state({
		"carrot_authoritative": true,
		"carrots": carrots,
		"harvest_tech_level": 0,
		"merc_carrots_spent_total": spent,
		"last_harvest_round": harvest_round,
		"last_harvest_gain": gain,
		"stone_draw_used_round": -1,
		"team_upgrade_stones": {"sky": 0, "land": 0, "ren": 0},
	})
