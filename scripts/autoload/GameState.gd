extends Node

const CarrotEconomyRules = preload("res://scripts/economy/CarrotEconomy.gd")

const START_FORMATION_HP := 50
const START_GOLD := 100
const MAX_NORMAL_UNITS := 7
const MAX_UNIT_STAR := GameConstants.MAX_STAR
# 合成只能到 3 星；4 星只能靠升级石。见 GameConstants 的说明。
const MAX_MERGE_STAR := GameConstants.MAX_MERGE_STAR
# 4 星属性 = 3 星 × 本值。棋子可用数据表字段 `star4_multiplier` 覆写它 ——
# 小灵是全表唯一没有技能的单位，用 1.50 的纯属性补偿。
const STAR4_DEFAULT_MULTIPLIER := 1.15
# Copies of a unit at a given star required to fuse into the next star.
# 1-star fuses from 2 copies; 2-star fuses from 3.
#
# 真正的定义在 GameConstants —— 服务端账本（EconomyLedger）也要读同一份，
# 而它按设计不能读 GameState。这里保留同名常量只是为了不动那些调用点。
const STAR_UPGRADE_COPIES := GameConstants.STAR_UPGRADE_COPIES
const FINAL_ROUND := 21
const BATTLE_DECAY_START_SEC := 10.0
const BATTLE_DECAY_INTERVAL_SEC := 6.0
const BATTLE_HARD_TIMEOUT_SEC := 180.0
const SHOP_UNIT_SLOTS := 4
const BENCH_SLOTS := 8
const MERCENARY_SLOTS := 8

var round_index := 1
var player_formation_hp := START_FORMATION_HP
var enemy_formation_hp := START_FORMATION_HP
var gold := START_GOLD
## Per-run carrot economy. These are player-owned values; derived farm values
## come from CarrotEconomyRules so saves do not carry duplicate truths.
var carrots := 0
var harvest_tech_level := 0
var merc_carrots_spent_total := 0
var last_harvest_round := -1
var stone_draw_used_round := -1

# --- 棋子唯一标识（P3 血统）---------------------------------------------------
# 每一枚玩家棋子从买入那一刻起带一个本局唯一的 uid，合成时由存活的那一枚继承，
# 出售时随格子消失。服务端用它认「这枚四星是不是由一次成功的升级石交易产生的」——
# 只凭棋盘快照里自报的 star=4 是认不出伪造的（设计文档 §5）。
#
# run_nonce 前缀不是装饰：没有它，「读旧档 -> 计数器回到 1」会和存档里已有的
# u3 撞号，而撞号在服务端表现为「别人的四星血统被我复用」。
var run_nonce := ""
var next_piece_uid := 1

func mint_piece_uid() -> String:
	if run_nonce.is_empty():
		new_run_nonce()
	var uid := "%s-%d" % [run_nonce, next_piece_uid]
	next_piece_uid += 1
	return uid

func new_run_nonce() -> void:
	run_nonce = Crypto.new().generate_random_bytes(4).hex_encode()
	next_piece_uid = 1
var team_upgrade_stones: Dictionary = CarrotEconomyRules.empty_stones()
var board_slots: Array = []
var bench_slots: Array = []
var mercenary_slots: Array = []
var shop_offers: Array = []
var shop_sold: Array = []
var owned_treasures: Array[String] = []
var claimed_treasure_rounds: Array[int] = []
var pending_treasure := {
	"active": false,
	"round": 0,
	"candidates": [],
	"refresh_index": 0,
}
var pve_completed := 0
var boss_completed := 0
var loss_streak := 0
# 本轮商店的服务端标识。联机客机的商店由服务端摇（NetworkService.server_shop），
# 买入意图必须带着它 —— EconomyLedger._buy 用它判「你看到的还是不是这一轮的货」。
# 单机/房主自己摇，这里留空。
var shop_offer_id := ""
var shop_refresh_uses_this_round := 0
var golden_altar_uses := 0
var gamble_used := false
var final_round_played := false
var battle_history: Array = []
var pending_battle_package: Dictionary = {}
# 3v3 team mode (prototype)
var team_mode := false
var team_slot_states: Array = []
var team_hp := START_FORMATION_HP
var enemy_team_hp := START_FORMATION_HP    # rival team's shared HP mirror (host-authoritative)
var team_run_won := false                 # 本队是否赢下整局（平局时为 false）
# 整局归属的权威值：TeamOutcome.TEAM_A / TEAM_B / DRAW。
# team_run_won 是它在本队视角下的派生布尔 —— 单独看那个布尔分不出"输了"和"平局"。
var team_run_outcome: int = TeamOutcome.TEAM_A
var tutorial_mode := false
# 这一局的出战种族（RacePick）。开局那一刻从 PlayerProfile 抄过来，整局只看这份 ——
# 中途回主菜单改了选择，也不该让本局下一回合的商店跟着变。
# 本机摇商店读它；联机时商店由战斗服务器按「准备」时收到的那份摇，这里只是同一份的本机记录。
# 空数组 = 没定（老存档 / 教学关），RacePick.resolve 会回落到默认。
var run_races: Array[String] = []

func _ready() -> void:
	reset_run()

func reset_run() -> void:
	tutorial_mode = false
	round_index = 1
	player_formation_hp = START_FORMATION_HP
	enemy_formation_hp = START_FORMATION_HP
	gold = START_GOLD
	carrots = 0
	harvest_tech_level = 0
	merc_carrots_spent_total = 0
	last_harvest_round = -1
	stone_draw_used_round = -1
	team_upgrade_stones = CarrotEconomyRules.empty_stones()
	new_run_nonce()
	board_slots.resize(GameConstants.CELL_COUNT)
	board_slots.fill(null)
	bench_slots.resize(BENCH_SLOTS)
	bench_slots.fill(null)
	mercenary_slots.resize(MERCENARY_SLOTS)
	mercenary_slots.fill(null)
	shop_offer_id = ""
	clear_shop()
	owned_treasures.clear()
	claimed_treasure_rounds.clear()
	pending_treasure = {"active": false, "round": 0, "candidates": [], "refresh_index": 0}
	pve_completed = 0
	boss_completed = 0
	loss_streak = 0
	shop_refresh_uses_this_round = 0
	golden_altar_uses = 0
	gamble_used = false
	final_round_played = false
	battle_history.clear()
	pending_battle_package.clear()
	run_races.clear()

func normal_unit_cap() -> int:
	if not owned_treasures.has("atk_fury_roster"):
		return MAX_NORMAL_UNITS
	# Fury Roster: 7 -> 8. With Hu Pai Master active, +1 more (7 -> 9).
	return 9 if TreasureService.has_linkage("link_hu_pai_master") else 8

func copies_to_upgrade(star: int) -> int:
	return GameConstants.copies_to_upgrade(star)

func carrot_capacity() -> int:
	return CarrotEconomyRules.capacity_for_spent(merc_carrots_spent_total)

func carrot_production() -> int:
	return CarrotEconomyRules.total_production(harvest_tech_level, merc_carrots_spent_total)

func carrot_farm_level() -> int:
	return CarrotEconomyRules.farm_level_for_spent(merc_carrots_spent_total)

func carrot_camp_income() -> int:
	return CarrotEconomyRules.income_for_spent(merc_carrots_spent_total)

func carrot_next_threshold() -> int:
	return CarrotEconomyRules.next_threshold_for_spent(merc_carrots_spent_total)

## Idempotent per-round harvest. The caller may safely invoke this whenever the
## prep scene is entered; only the first call for a round can change state.
func harvest_carrots_for_round(round_number: int) -> Dictionary:
	if round_number < 1 or last_harvest_round >= round_number:
		return {"ok": false, "already_harvested": true, "gain": 0, "overflow": 0,
			"after": carrots, "capacity": carrot_capacity(), "production": carrot_production()}
	var result := CarrotEconomyRules.harvest(carrots, merc_carrots_spent_total, harvest_tech_level)
	carrots = int(result.after)
	last_harvest_round = round_number
	return {"ok": true, "already_harvested": false, "gain": int(result.gain),
		"overflow": int(result.overflow), "after": carrots,
		"capacity": int(result.capacity), "production": int(result.production)}

func upgrade_harvest_tech() -> Dictionary:
	if round_index < 2:
		return {"ok": false, "error": "harvest_locked_first_round"}
	var price := CarrotEconomyRules.tech_price(harvest_tech_level)
	if price < 0:
		return {"ok": false, "error": "max_level", "price": -1}
	if gold < price:
		return {"ok": false, "error": "not_enough_gold", "price": price}
	gold -= price
	harvest_tech_level += 1
	return {"ok": true, "price": price, "level": harvest_tech_level,
		"production": carrot_production()}

func record_merc_carrot_spend(amount: int) -> void:
	merc_carrots_spent_total += maxi(0, amount)

func can_draw_upgrade_stone(round_number: int) -> bool:
	return stone_draw_used_round != round_number

func apply_team_stone(stone_type: String) -> void:
	if not CarrotEconomyRules.valid_stone_type(stone_type):
		return
	team_upgrade_stones[stone_type] = int(team_upgrade_stones.get(stone_type, 0)) + 1


# --- 四星升级 -----------------------------------------------------------------
# 四星**只能**由升级石获得，不能靠同名合成（合成封顶在 MAX_MERGE_STAR）。
# 条件：满星三星的普通棋子 + 一颗**同属性**的队伍升级石。
#
# 判定与执行分开：面板要能在不消耗石头的前提下问"这只能不能升"，
# 好把按钮置灰并说明原因。两者读同一份条件，不会出现"按钮亮着但点了没反应"。

## 这只棋子当前能否升四星。返回 {ok: bool, error: String, stone: String}。
func four_star_check(cell: Variant) -> Dictionary:
	if typeof(cell) != TYPE_DICTIONARY:
		return {"ok": false, "error": "empty_cell", "stone": ""}
	var c: Dictionary = cell
	if bool(c.get("is_mercenary", false)):
		return {"ok": false, "error": "mercenary", "stone": ""}
	var star := int(c.get("star", 1))
	if star >= MAX_UNIT_STAR:
		return {"ok": false, "error": "already_max", "stone": ""}
	if star < MAX_MERGE_STAR:
		return {"ok": false, "error": "need_three_star", "stone": ""}
	var stone := str((c.get("def", {}) as Dictionary).get("element", ""))
	if not CarrotEconomyRules.valid_stone_type(stone):
		return {"ok": false, "error": "bad_element", "stone": stone}
	if int(team_upgrade_stones.get(stone, 0)) <= 0:
		return {"ok": false, "error": "no_stone", "stone": stone}
	var cost := CarrotEconomyRules.four_star_gold(int((c.get("def", {}) as Dictionary).get("tier", 0)))
	if cost < 0:
		return {"ok": false, "error": "bad_tier", "stone": stone}
	if gold < cost:
		return {"ok": false, "error": "not_enough_gold", "stone": stone, "cost": cost}
	return {"ok": true, "error": "", "stone": stone, "cost": cost}

## 消耗一颗同属性升级石，把这只三星升为四星。
## cell 是 board_slots / bench_slots 里的那个字典本身——就地改 star，
## 与 _merge_copies_into_cell 的做法一致（那里也是直接 target.star = star + 1）。
func upgrade_cell_to_four_star(cell: Variant) -> Dictionary:
	var check := four_star_check(cell)
	if not bool(check.get("ok", false)):
		return check
	var stone := str(check.get("stone", ""))
	gold -= int(check["cost"])
	team_upgrade_stones[stone] = int(team_upgrade_stones.get(stone, 0)) - 1
	(cell as Dictionary)["star"] = MAX_UNIT_STAR
	return {"ok": true, "error": "", "stone": stone}

## 星级属性系数。unit_def 只在 4 星时才被读到（取 `star4_multiplier` 覆写）——
## 传空字典就是默认曲线，老调用点不用改。
func star_stat_multiplier(star: int, unit_def: Dictionary = {}) -> float:
	match clampi(star, 1, MAX_UNIT_STAR):
		1:
			return 1.0
		2:
			return 1.5
		3:
			return 3.0
		_:
			# 4 星只提 15%：它的价值主要在技能，属性只是点缀。
			# **只作用于 HP / 攻击 / 防御三项**，不含攻速——攻速直接乘 DPS，
			# 一起涨的话实际战力增幅是 1.15³ ≈ 1.52，而不是预期的 1.15。
			return 3.0 * maxf(1.0, float(unit_def.get("star4_multiplier", STAR4_DEFAULT_MULTIPLIER)))

func normal_unit_count() -> int:
	var n := 0
	for cell in board_slots:
		if cell != null:
			n += 1
	return n

func reset_shop_refreshes() -> void:
	shop_refresh_uses_this_round = 0
	golden_altar_uses = 0
	gamble_used = false

func clear_shop() -> void:
	shop_offers.resize(SHOP_UNIT_SLOTS)
	shop_sold.resize(SHOP_UNIT_SLOTS)
	for i in SHOP_UNIT_SLOTS:
		shop_offers[i] = {}
		shop_sold[i] = false

func clear_mercenaries() -> void:
	for i in mercenary_slots.size():
		mercenary_slots[i] = null

func set_pending_battle_package(package: Dictionary) -> void:
	pending_battle_package = package.duplicate(true)

func take_pending_battle_package() -> Dictionary:
	var package := pending_battle_package.duplicate(true)
	pending_battle_package.clear()
	return package

func clear_pending_battle_package() -> void:
	pending_battle_package.clear()
