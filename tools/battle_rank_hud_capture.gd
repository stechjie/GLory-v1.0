extends SceneTree
## 实渲截图：真战斗界面里的伤害前三榜 / 清路前三 / 左下钱袋（11-18，scenes/battle/BattleRankHud.gd）。
## 固定阵容（FixedBattleFixture），PvP 第 6 回合、打怪第 3 回合各打一场，战斗中途和结算后各截一张。
## 用法：Godot --path . --resolution 1600x720 -s res://tools/battle_rank_hud_capture.gd -- <输出目录>

const SEAT_NAMES := ["阿文", "小静", "Leno", "KaiTheGreat", "月影", "Bot·狼"]
const SEAT_AVATARS := ["preset:avatar_003", "preset:avatar_007", "preset:avatar_012", "preset:avatar_005", "preset:avatar_009", "preset:avatar_002"]
const SEAT_FRAMES := ["preset:avatar_frame_shop_02", "preset:frame_default", "preset:avatar_frame_7day_01", "preset:avatar_frame_shop_04", "preset:avatar_frame_shop_05", "preset:frame_default"]


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var out := "res://reports/rank_hud"
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out = args[0]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out))
	for name in ["NetworkService", "RealtimeService", "AnalyticsService"]:
		root.get_node(name).set_process(false)
	root.multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	root.get_node("DataRegistry").load_all()
	root.get_node("LocaleManager").set_locale("zh")
	for round_index in [6, 3]:
		await _battle(round_index, out)
	print("RANK_HUD_CAPTURE PASS")
	quit()


func _battle(round_index: int, out: String) -> void:
	var fixture = load("res://scripts/qa/FixedBattleFixture.gd")
	fixture.setup_match_state(round_index, 20261118)
	var net := root.get_node("NetworkService")
	var profiles := {}
	for slot in 6:
		profiles[slot] = {"player_name": SEAT_NAMES[slot], "avatar": SEAT_AVATARS[slot], "avatar_frame": SEAT_FRAMES[slot]}
	net.team_seat_profiles = profiles
	var sim = load("res://scripts/battle/BattleSimulator.gd")
	var replay_a: Dictionary = sim.compute_team_replay(0, "rank-hud:a:%d" % round_index)
	var replay_b: Dictionary = sim.compute_team_replay(1, "rank-hud:b:%d" % round_index)
	net.team_replay_rival = replay_b
	# 本地是 0 号座位；离线播放（不连服务器），名片照上面那份。
	net.team_active = false
	root.get_node("GameState").set_pending_battle_package({"mode": "team_replay", "round_index": round_index, "replay": replay_a})
	var screen = load("res://scenes/battle/BattleScreen.tscn").instantiate()
	root.add_child(screen)
	while not screen.get("_battle_setup_ready"):
		await process_frame
	var frames: int = (replay_a.get("frames", []) as Array).size()
	var tag := "r%d_%s" % [round_index, str(replay_a.get("kind", ""))]
	while int(screen.get("_replay_frame")) < int(frames * 0.6):
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out.path_join(tag + "_mid.png"))
	while not bool(screen.get("_finished")):
		await process_frame
	await create_timer(1.2).timeout
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out.path_join(tag + "_end.png"))
	var rewards: Dictionary = load("res://scripts/economy/BattleRankRewards.gd").rewards_by_slot(str(replay_a.get("kind", "")), [replay_a, replay_b])
	print("RANK_HUD_CAPTURE %s frames=%d rewards=%s kill0=%d" % [tag, frames, str(rewards),
		int((replay_a.get("result", {}).get("kill_gold_by_slot", {}) as Dictionary).get(0, 0))])
	screen.queue_free()
	await process_frame
	await process_frame
