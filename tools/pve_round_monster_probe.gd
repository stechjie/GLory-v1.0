extends Node

# Read-only probe: which PVE monster does each round roll for a given seed?
# The pick is deterministic (hash of shared_seed + round + salt), so this answers
# which fixed round can serve as a vertical-slice sample without touching the
# already frozen round 1 / round 2 baselines.

const BattleSimShared := preload("res://scripts/battle/BattleSimShared.gd")
const DEFAULT_SEED := 20260807

const BOSS_ROUNDS := [5, 10, 15, 20]
const PVP_ROUNDS := [6, 12, 18, 21]


func _ready() -> void:
	var seed_value := DEFAULT_SEED
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if str(args[i]) == "--seed" and i + 1 < args.size():
			seed_value = int(args[i + 1])
	DataRegistry.load_all()
	NetworkService.shared_seed = seed_value
	var monsters: Array = DataRegistry.get_table("pve_monsters").get("monsters", [])
	print("[PROBE] seed=%d monsters=%d" % [seed_value, monsters.size()])
	for round_index in range(1, 22):
		if round_index in BOSS_ROUNDS or round_index in PVP_ROUNDS:
			continue
		var template: Dictionary = BattleSimShared._round_monster_template(round_index)
		print("[PROBE] round=%2d -> %-28s %s" % [
			round_index, str(template.get("id", "?")), str(template.get("name", ""))])
	_scan_for_target("pve_sky_thunder_spirit", seed_value)
	get_tree().quit(0)


# Finds seeds whose round 1 rolls the wanted monster, so a vertical-slice sample
# can be added without disturbing the already frozen seed/round pairs.
func _scan_for_target(wanted_id: String, base_seed: int) -> void:
	var hits := 0
	for offset in range(0, 2000):
		var candidate := base_seed + offset
		NetworkService.shared_seed = candidate
		var template: Dictionary = BattleSimShared._round_monster_template(1)
		if str(template.get("id", "")) != wanted_id:
			continue
		hits += 1
		var r2: Dictionary = BattleSimShared._round_monster_template(2)
		print("[PROBE] SEED %d -> round1=%s round2=%s (%s)" % [
			candidate, wanted_id, str(r2.get("id", "")), str(r2.get("name", ""))])
		if hits >= 5:
			break
	NetworkService.shared_seed = base_seed
	print("[PROBE] scan done hits=%d" % hits)
