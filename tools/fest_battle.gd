extends "res://tools/promo_capture.gd"
# Steam 活动「决战」长镜头：第 21 回合（最终战）的 3v3，阵容固定，两边召唤不同的法阵守护者。
#
#   .\tools\fest_capture.ps1 -Shot battle
#
# 复用 promo_capture.gd 的整套真实对局录制（先算回放、再交给 BattleScreen 播），这里只换：
#   · 阵容：用户 11.13 选的 8 个角色当核心（红 = 暗 / 灵 / 赤，蓝 = 神 / 人）；
#   · 回合固定 21：最终战走自己的左右布局和开场演出；
#   · 法阵血量：守护者按各自剩余法阵血量发放（FormationAllyService.ally_id_for_hp），
#     两边设在不同档位，召唤出来的就是两只不同的守护者（用户要求「两边的法阵 boss 要不一样」）。

# 红方 25 血 → 深渊巨兽（21–30 档）；蓝方 50 血 → 永夜（41 以上）。体型和配色反差最大。
const RED_FORMATION_HP := 25
const BLUE_FORMATION_HP := 50

const FEST_LINEUP := {
	"a": [
		["dark_doom", "dark_suc", "dark_dragon", "dark_mage"],
		["undead_titan", "undead_mother", "undead_spike", "undead_poison"],
		["crimson", "lattern", "Icey", "skypierce"],
	],
	"b": [
		["god_guard", "god_aurora", "god_king", "god_priestess"],
		["human_swordsman", "human_king", "human_archer", "human_mage"],
		["god_arbiter", "god_archangel", "god_angel", "human_cleric"],
	],
}


# 站位（用户 11.14）：「下面的人飞出墙了」「把人放 2 排，一排前面一排后面」，并选了「只改宣传片」。
#
# 游戏本身的最终战布局（BattleSimulator._apply_final_round_left_right_layout）把每边 12 个人
# 排成一条竖线：三路中心固定在 FINAL_LANE_CENTERS_Y = 120 / 360 / 600（总高 720），
# 最下面一路压在下墙上；棋盘的行只转成约 30px 的左右差，前后排叠成一条线。
# 修它要改模拟、重新部署战斗服务器，不在这次范围。
#
# 录制时的做法：自己跑 compute_team_replay 那个循环，只在开打前（prepare_team_state 之后、
# 第一个 tick 之前）把棋子挪到下面的位置。之后完全是游戏的模拟 —— 打斗按新站位真实算出来，
# 回放格式与游戏一致，不会有「近战隔空砍」这种事后改坐标的错位。
#
# 每边两列：前排 = 每路棋盘第 1 行（每路列表前两个，近战），后排 = 其余（远程）。
# 三路从上到下，每路占两个纵向位；纵向范围取录制画面里实测的墙内安全区。
const FEST_FILL_ORDER: Array[int] = [1, 2, 13, 14]
const FINAL_SAFE_Y_TOP := 170.0
const FINAL_SAFE_Y_BOTTOM := 550.0
# 模拟坐标 x（场宽 1000）。原布局两边大约在 430 / 570；前后排拉开 95，约一个半身位。
const RED_FRONT_X := 425.0
const RED_BACK_X := 330.0
const BLUE_FRONT_X := 575.0
const BLUE_BACK_X := 670.0


func _board_from_ids(unit_ids: Array) -> Array:
	var board: Array = []
	board.resize(GameConstants.CELL_COUNT)
	var defs := _unit_defs()
	for i in mini(unit_ids.size(), FEST_FILL_ORDER.size()):
		var key := str(unit_ids[i])
		if not defs.has(key):
			push_warning("Unknown unit id '%s' - skipped." % key)
			continue
		board[FEST_FILL_ORDER[i]] = {
			"id": key,
			"star": _star,
			"def": (defs[key] as Dictionary).duplicate(true),
		}
	return board


# BattleSimulator.compute_team_replay 的同一个循环，中间插一步 _arrange_two_rows。
func _compute_replay() -> Dictionary:
	var sim := load("res://scripts/battle/BattleSimulator.gd")
	var state: Dictionary = sim.prepare_team_state(0)
	state["_presentation_battle_id"] = sim._presentation_battle_id(state, 0, "")
	_arrange_two_rows(state)
	sim.constrain_battle_positions(state)
	var roster: Dictionary = {}
	var frames: Array = []
	var frame_events: Array = []
	sim._replay_capture_roster(state, roster)
	var steps := 0
	while not bool(state.get("finished", false)) and steps < 4000:
		sim.step_state(state)
		steps += 1
		sim._replay_capture_roster(state, roster)
		sim._replay_capture_frame(state, frames, frame_events)
	return sim._team_replay_payload(state, roster, frames, frame_events)


func _arrange_two_rows(state: Dictionary) -> void:
	var step := (FINAL_SAFE_Y_BOTTOM - FINAL_SAFE_Y_TOP) / 5.0
	for side in [["player", RED_FRONT_X, RED_BACK_X], ["enemy", BLUE_FRONT_X, BLUE_BACK_X]]:
		# lane -> [前排, 后排]，各按棋盘格从左到右（列小的在上）。
		var by_lane := {0: [[], []], 1: [[], []], 2: [[], []]}
		for f in state.get(str(side[0]), []):
			if bool(f.get("is_formation_ally", false)) or not f.has("board_cell"):
				continue
			var lane := int(f.get("lane", -1))
			if not by_lane.has(lane):
				continue
			var row := int(f.get("board_cell", 0)) / GameConstants.BOARD_COLUMNS
			(by_lane[lane][0 if row == 0 else 1] as Array).append(f)
		for lane in 3:
			for r in 2:
				var group: Array = by_lane[lane][r]
				group.sort_custom(func(a, b): return int(a.get("board_cell", 0)) < int(b.get("board_cell", 0)))
				for i in group.size():
					var slot_y := FINAL_SAFE_Y_TOP + step * float(lane * 2 + mini(i, 1))
					(group[i] as Dictionary).pos = Vector2(float(side[1] if r == 0 else side[2]), slot_y)


func _initialize() -> void:
	_parse_arguments()
	# 父类会校验 --lineup 在它自己的 LINEUPS 里；这里用自己的阵容，绕过那条校验。
	_lineup = "fest_final"
	_round = 21


# 第一遍录制在第 553 帧「Battle sync failed」：BattleScreen 的开战准备（模型 + 特效预渲染）
# 有 30 秒预算（BATTLE_PREPARE_TIMEOUT_MSEC），而预渲染那段按墙钟换算截止时间
# （warmup_cutoff_msec）。Movie Maker 每帧比实时慢，预算先耗尽，整场战斗被判失败跳过。
# 录制时把这场的截止时间推远 —— 只动这个 BattleScreen 实例的字段，游戏代码不改。
# 同时藏掉调试版左上角的「FPS n」。
func _process(delta: float) -> bool:
	if _screen != null and is_instance_valid(_screen):
		# 片头从模型整体显示出来的那一帧算起（BattleScreen 建模期间把 3D 根藏着）。
		# 父类等 _battle_setup_ready 才记 start_frame，那是最终战开场演出（召唤守护者、
		# Ready / Go）**之后** —— 开场整段会被当成加载画面剪掉。
		var root3d = _screen.get("_battle_3d_root")
		# 3D 根在建模开始前也是显示的（那时还没有模型），所以要同时看模型表非空。
		var models = _screen.get("_battle_3d_models")
		if _start_frame < 0 and root3d is Node3D and (root3d as Node3D).visible \
				and models is Dictionary and not (models as Dictionary).is_empty():
			_start_frame = _frame
			_record_viewport_size()
			print("  fest_battle: models shown at frame %d (intro kept)" % _start_frame)
			_write_manifest()
		if int(_screen.get("_battle_prepare_deadline_msec")) < 1_000_000_000:
			_screen.set("_battle_prepare_deadline_msec", 2_000_000_000)
		var fps_label = _screen.get("_fps_label")
		if fps_label is Label and is_instance_valid(fps_label):
			(fps_label as Label).visible = false
	return super._process(delta)


func _setup_match_state() -> void:
	var start_hp: int = _gs_const.get("START_FORMATION_HP", 50)
	_game_state.call("reset_run")
	_game_state.set("team_mode", true)
	_game_state.set("round_index", _round)
	_game_state.set("team_hp", mini(RED_FORMATION_HP, start_hp))
	_game_state.set("enemy_team_hp", mini(BLUE_FORMATION_HP, start_hp))
	_network.set("team_active", true)
	_network.set("team_local_slot", 0)
	_network.set("shared_seed", _seed)
	_network.set("team_slot_states", ["player", "player", "player", "player", "player", "player"])
	var lanes_a: Array = FEST_LINEUP["a"]
	var lanes_b: Array = FEST_LINEUP["b"]
	_game_state.set("board_slots", _board_from_ids(lanes_a[0]))
	_game_state.set("mercenary_slots", _merc_slots())
	var boards: Dictionary = {}
	for lane in 3:
		boards[lane] = _submission_for(lanes_a[lane])
		boards[lane + 3] = _submission_for(lanes_b[lane])
	_network.set("team_boards", boards)
	print("fest_battle: round %d, formation hp red=%d blue=%d" % [
		_round, int(_game_state.get("team_hp")), int(_game_state.get("enemy_team_hp"))])
