extends Node

# 校验：compute_team_replay（同步）与 compute_team_replay_async（分帧）
# 在相同种子下必须产出逐位一致的回放。
#
# 验收范围有限，不要当成「确定性已验证」：本检查只覆盖同进程、同平台、4 种单位、
# 单一 seed，比的是两个实现而非两个平台；_replay_hash 用的是 32 位 String.hash()，
# 且不含 frame_events / roster。跨平台（Android ARM64 vs Linux x86_64）确定性另见
# docs/联机审计与整改方案.md 的准入门槛，需 SHA-256 + 多 seed + 全单位技能语料。

const BattleSim := preload("res://scripts/battle/BattleSimulator.gd")

func _ready() -> void:
	GameState.reset_run()
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	assert(not units.is_empty())
	for index in 8:
		var def: Dictionary = (units[index % mini(4, units.size())] as Dictionary).duplicate(true)
		GameState.board_slots[index] = {"id": def.get("id", "unit"), "star": 1, "def": def}
	GameState.team_mode = true
	GameState.round_index = 3
	NetworkService.team_active = true
	NetworkService.team_local_slot = 0
	NetworkService.shared_seed = 424242
	NetworkService.team_slot_states = ["player", "dummy", "dummy", "dummy", "dummy", "dummy"]
	NetworkService.team_boards = {0: NetProtocol.team_board_submission(GameState.board_slots, GameState.mercenary_slots)}

	var sync_1: Dictionary = BattleSim.compute_team_replay(0)
	var sync_2: Dictionary = BattleSim.compute_team_replay(0)
	var async_1: Dictionary = await BattleSim.compute_team_replay_async(0)
	var h_sync_1 := _replay_hash(sync_1)
	var h_sync_2 := _replay_hash(sync_2)
	var h_async := _replay_hash(async_1)
	var frames: Array = sync_1.get("frames", [])
	print("[DETCHECK] frames=%d sync1=%d sync2=%d async=%d" % [frames.size(), h_sync_1, h_sync_2, h_async])
	print("[DETCHECK] sync_repeatable=%s sync_vs_async=%s" % [str(h_sync_1 == h_sync_2), str(h_sync_1 == h_async)])
	get_tree().quit(0 if h_sync_1 == h_sync_2 and h_sync_1 == h_async else 1)

func _replay_hash(replay: Dictionary) -> int:
	return JSON.stringify([replay.get("frames", []), replay.get("result", {})]).hash()
