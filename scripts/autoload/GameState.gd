extends Node

const CarrotEconomyRules = preload("res://scripts/economy/CarrotEconomy.gd")

const START_FORMATION_HP := 50
const START_GOLD := 100
const MAX_NORMAL_UNITS := 7
const MAX_UNIT_STAR := GameConstants.MAX_STAR
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
	board_slots.resize(GameConstants.CELL_COUNT)
	board_slots.fill(null)
	bench_slots.resize(BENCH_SLOTS)
	bench_slots.fill(null)
	mercenary_slots.resize(MERCENARY_SLOTS)
	mercenary_slots.fill(null)
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
	return CarrotEconomyRules.production_for_tech(harvest_tech_level)

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

func star_stat_multiplier(star: int) -> float:
	match clampi(star, 1, MAX_UNIT_STAR):
		1:
			return 1.0
		2:
			return 1.5
		_:
			return 3.0

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
