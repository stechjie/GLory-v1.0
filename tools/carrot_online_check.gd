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
const PINNED_PROTOCOL := 17
const PINNED_CONTRACT := "ktVdNBGq99RKff1h"

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_case_flag_default()
	_case_server_contract_pinned()
	_case_room_state_carries_carrots()
	_case_harvest_tech_online()
	_case_draw_stone_online()
	_case_four_star_online()
	await _case_client_panel_online()
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
			"last_harvest_round", "stone_draw_used_round", "team_upgrade_stones"]:
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


# --- 3. 采集科技升级（客机 -> 服务端 -> 回执）------------------------------------
# 客机点「采集 Lv.N」走 request_economy("upgrade_harvest_tech", {"gold": 本地金币})。
# 服务端在 carrot-only 阶段用 room.slot_gold 做防伪：**只接受不高于**已结算余额的自报值。
# 这条判据的边界必须守住 —— 松了能凭空造钱，紧了玩家点了没反应。
func _case_harvest_tech_online() -> void:
	var price := CarrotEconomy.tech_price(0)
	var room := _make_prep_room(2)
	var slot_gold: Array = room.get("slot_gold", [])
	slot_gold[MY_SLOT] = price + 50
	room["slot_gold"] = slot_gold

	# 3a. 正常：自报金币等于服务端已结算余额
	var receipt: Dictionary = NetworkService._room_apply_economy(
		room, MY_SLOT, "upgrade_harvest_tech", {"gold": price + 50})
	receipt["action"] = "upgrade_harvest_tech"
	if not _h.expect(bool(receipt.get("ok", false)), "tech_upgrade_rejected",
			"金币够、在备战阶段，采集科技升级仍被服务端拒绝：%s" % str(receipt.get("error", "?"))):
		return
	var result: Dictionary = receipt.get("result", {})
	_h.expect(int(result.get("harvest_tech_level", 0)) == 1, "tech_level_not_raised",
		"服务端受理了升级，但回执里的 harvest_tech_level 是 %d，应为 1"
			% int(result.get("harvest_tech_level", 0)))

	# 3b. 回执必须真的写回 GameState —— 否则玩家扣了钱、界面纹丝不动
	GameState.reset_run()
	GameState.gold = price + 50
	NetworkService._apply_carrot_receipt(receipt)
	_h.expect(GameState.harvest_tech_level == 1, "receipt_not_applied",
		"回执 ok 但客户端 harvest_tech_level 仍是 %d —— 按钮点了没东西"
			% GameState.harvest_tech_level)
	_h.expect(GameState.gold == int(receipt.get("gold_after", -1)), "receipt_gold_not_applied",
		"回执 ok 但客户端金币是 %d，回执里是 %d" % [GameState.gold, int(receipt.get("gold_after", -1))])

	# 3c. 自报金币**高于**已结算余额 = 伪造，必须拒
	var forged: Dictionary = NetworkService._room_apply_economy(
		room, MY_SLOT, "upgrade_harvest_tech", {"gold": 999999})
	_h.expect(not bool(forged.get("ok", false)), "forged_gold_accepted",
		"客户端自报 999999 金币被服务端接受了 —— 改个内存就能白嫖采集科技")

	# 3d. 备战期卖棋子会让本地金币**高于**服务端已结算余额。
	# 这一步是玩家最容易撞上的：卖一个再点升级，按钮就永久失灵到本回合结束。
	var room_sold := _make_prep_room(2)
	var sold_gold: Array = room_sold.get("slot_gold", [])
	sold_gold[MY_SLOT] = price          # 服务端结算时的余额
	room_sold["slot_gold"] = sold_gold
	var after_sell: Dictionary = NetworkService._room_apply_economy(
		room_sold, MY_SLOT, "upgrade_harvest_tech", {"gold": price + 20})   # 卖掉一个棋子退了 20
	_h.expect(bool(after_sell.get("ok", false)), "sell_then_upgrade_blocked",
		"备战期卖棋子涨了金币之后，采集科技升级被判 %s —— 玩家点按钮没有任何反应，"
			% str(after_sell.get("error", "?"))
		+ "而卖棋子在 carrot-only 阶段是纯客户端行为，服务端的 slot_gold 不会跟着涨")

	# 3e. 战斗/结算阶段不许改经济
	var battle_room := _make_prep_room(2)
	battle_room["state"] = NetworkService.ROOM_BATTLE
	var in_battle: Dictionary = NetworkService._room_apply_economy(
		battle_room, MY_SLOT, "upgrade_harvest_tech", {"gold": 100})
	_h.expect(not bool(in_battle.get("ok", false)), "economy_in_battle",
		"战斗阶段还能升采集科技")


# --- 4. 抽升级石（客机 -> 服务端 -> 回执）---------------------------------------
func _case_draw_stone_online() -> void:
	var room := _make_prep_room(3)
	var prep: Dictionary = NetworkService._room_prep(room, MY_SLOT)
	# 攒够钱、把萝卜田顶到能存下 50 萝卜的那一级
	var need_spent := 0
	for level in CarrotEconomy.FARM_THRESHOLDS.size():
		if int(CarrotEconomy.FARM_CAPACITIES[level]) >= CarrotEconomy.STONE_COST:
			need_spent = int(CarrotEconomy.FARM_THRESHOLDS[level])
			break
	prep["merc_carrots_spent_total"] = need_spent
	prep["carrots"] = CarrotEconomy.STONE_COST

	var receipt: Dictionary = NetworkService._room_apply_economy(
		room, MY_SLOT, "draw_upgrade_stone", {})
	receipt["action"] = "draw_upgrade_stone"
	if not _h.expect(bool(receipt.get("ok", false)), "draw_rejected",
			"萝卜够 %d、田到 Lv%d，抽升级石仍被拒：%s" % [
				CarrotEconomy.STONE_COST,
				CarrotEconomy.farm_level_for_spent(need_spent) + 1,
				str(receipt.get("error", "?")),
			]):
		return
	var result: Dictionary = receipt.get("result", {})
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

	# 每回合一次
	prep["carrots"] = CarrotEconomy.STONE_COST
	var again: Dictionary = NetworkService._room_apply_economy(room, MY_SLOT, "draw_upgrade_stone", {})
	_h.expect(not bool(again.get("ok", false)), "draw_twice_in_one_round",
		"同一回合抽了第二次升级石")


# --- 5. 四星升级在联机里有没有服务端路径 ----------------------------------------
# 升四星要消耗**队伍共享**仓库里的一颗石头，而那个仓库在联机里是服务端的
# room.team_upgrade_stones。客户端只要没有对应的意图动作，这一步就只能改本地副本，
# 下一个 room_state 一到 _apply_carrot_state() 就会把仓库整个覆盖回去。
func _case_four_star_online() -> void:
	_h.expect(NetworkService.ECONOMY_ACTIONS.has("four_star_upgrade"),
		"four_star_no_server_action",
		"ECONOMY_ACTIONS 里没有四星升级 —— 联机时客机升四星只改本地，"
		+ "石头会被下一个 room_state 覆盖回来，棋子星级也没进服务端账本")

	# 直接演一遍：客户端花掉一颗石头，然后服务端下发一份 room_state。
	var room := _make_prep_room(4)
	var warehouse: Dictionary = NetworkService._room_team_stones(room, MY_SLOT)
	for stone in CarrotEconomy.STONE_TYPES:
		warehouse[stone] = 1
	var state: Dictionary = NetworkService._build_economy_state(room, MY_SLOT)
	GameState.reset_run()
	NetworkService._apply_carrot_state(state)

	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	var target: Dictionary = {}
	for row in units:
		var d: Dictionary = row
		if CarrotEconomy.STONE_TYPES.has(str(d.get("element", ""))):
			target = d
			break
	if not _h.expect(not target.is_empty(), "no_elemental_unit", "找不到带天/地/人属性的棋子"):
		return
	var element := str(target.get("element", ""))
	var cell := {"id": str(target.get("id", "")), "star": GameState.MAX_MERGE_STAR, "def": target}
	var upgraded := GameState.upgrade_cell_to_four_star(cell)
	if not _h.expect(bool(upgraded.get("ok", false)), "four_star_local_denied",
			"本地升四星被拒：%s" % str(upgraded.get("error", "?"))):
		return
	_h.expect(int(GameState.team_upgrade_stones.get(element, 0)) == 0, "four_star_no_local_spend",
		"本地升四星之后 %s 石还剩 %d 颗" % [element, int(GameState.team_upgrade_stones.get(element, 0))])

	# 服务端并不知道刚才那一下，于是下一包 room_state 把石头还了回来
	NetworkService._apply_carrot_state(NetworkService._build_economy_state(room, MY_SLOT))
	_h.expect(int(GameState.team_upgrade_stones.get(element, 0)) == 0, "four_star_stone_restored",
		"升四星消耗的 %s 石在下一个 room_state 之后又变回 %d 颗 —— 石头能反复用，"
			% [element, int(GameState.team_upgrade_stones.get(element, 0))]
		+ "而服务端仓库从头到尾没减过")


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
