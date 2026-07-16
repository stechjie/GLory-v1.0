extends Node

const START_FORMATION_HP := 50
const START_GOLD := 100
const MAX_NORMAL_UNITS := 7
const MAX_UNIT_STAR := 3
# Copies of a unit at a given star required to fuse into the next star.
# 1-star fuses from 2 copies; 2-star fuses from 3. Single source of truth for
# both the prep-board merge/auto-combine and the tutorial's guidance/arrows.
const STAR_UPGRADE_COPIES := {1: 2, 2: 3}
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
var final_battle_complete := false
var battle_history: Array = []
var pending_battle_package: Dictionary = {}
# 3v3 team mode (prototype)
var team_mode := false
var team_slot_states: Array = []
var team_hp := START_FORMATION_HP
var enemy_team_hp := START_FORMATION_HP    # rival team's shared HP mirror (host-authoritative)
var team_run_won := false                 # result of the 3v3 run, for the game-over screen
var tutorial_mode := false

func _ready() -> void:
	reset_run()

func reset_run() -> void:
	tutorial_mode = false
	round_index = 1
	player_formation_hp = START_FORMATION_HP
	enemy_formation_hp = START_FORMATION_HP
	gold = START_GOLD
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
	final_battle_complete = false
	battle_history.clear()
	pending_battle_package.clear()

func normal_unit_cap() -> int:
	if not owned_treasures.has("atk_fury_roster"):
		return MAX_NORMAL_UNITS
	# Fury Roster: 7 -> 8. With Hu Pai Master active, +1 more (7 -> 9).
	return 9 if TreasureService.has_linkage("link_hu_pai_master") else 8

func copies_to_upgrade(star: int) -> int:
	return int(STAR_UPGRADE_COPIES.get(star, 3))

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
		if cell != null and not bool(cell.get("is_mercenary", false)):
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
	for i in board_slots.size():
		var cell = board_slots[i]
		if cell != null and bool(cell.get("is_mercenary", false)):
			board_slots[i] = null
	for i in bench_slots.size():
		var cell = bench_slots[i]
		if cell != null and bool(cell.get("is_mercenary", false)):
			bench_slots[i] = null
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