extends Node

# 队伍召唤音效门禁（9.17 佣兵批次）。
#
# ## 要证明的那句话
#
# 「我方队伍里**任何人**召唤佣兵，全队都听到召唤音」——包括不是自己召的那一次。
#
# 这条需求落在两条互斥的学习路径上，各自只负责一半：
#   * **自己**召的：客机走服务端回执（PrepUI._on_carrot_economy_receipt 的
#     hire_merc_carrot 分支），房主/单机/教程走成交那行
#     （PrepBoardController._hire_mercenary_to_slot）。
#   * **队友**召的：`NetworkService.team_prep_mercs_changed` 到达时，
#     PrepUI._check_team_merc_alert() 按**座位佣兵数增量**补播。
#
# 于是本门禁真正盯的是三件容易写错、且错了以后**在开发机上完全看不出来**的事：
#
# 1. **房主双响**。`_team_merc_counts()` 把自己的座位也算进 current，而
#    `_refresh_all()` 结尾就会调到 _check_team_merc_alert()。队友那半若连自己那格
#    也播，房主一次雇佣会响两声 —— 单机看不出来，只有联机才现形。
# 2. **迟到同步误响**。首次观察（刚进备战页 / 中途重连）与换回合这两种时刻，
#    队友的列表是「一次到位」的整表，不是「刚多了一个」。这里必须一声不出。
# 3. **自己的雇佣完全不响**。`_hire_mercenary_to_slot` 此前一条音效都没有 ——
#    那种缺口在真机上听起来跟「音效没接上」一模一样，而 cue 的
#    `cue_without_call_site` 断言是绿的（它有客机那条调用点）。
#
# ## 怎么观测
#
# 用 SfxService 自己的缝：`reset_counters_for_check()` + `play_count(cue)`。
# **每次测量前都先 reset**，因为它连 `_last_play_msec` 一起清掉 ——
# 于是「不该响」的断言是真的严格：40 ms 重触发保护没有记忆，一旦多响一声就会被数到。
# 不 reset 的话，一个「重复触发」的坏实现会被那道保护盖住，断言空过。
#
# ## 怎么造出队友状态
#
# 直接写 `NetworkService.team_prep_mercs[slot]`：`_team_merc_counts()` 对别人的座位
# 读的就是 `team_prep_merc_ids(slot, round_index)`。只关心**条数**，所以 id 用假串，
# 不走 `_sanitize_prep_merc_ids`（那是网络入口的职责，不在本门禁的射程内）。
# 座位置成队伍态：本地 0 号（RED 队），队友 1 号，对手 3 号 —— 「该响 / 不该响」的对照组。
#
# 写完之后**同一帧内**立刻调 `_on_team_prep_mercs_changed()`：中间不 await，
# 免得备战页自己的 `_refresh_all()` 抢先把快照更新掉，把增量吃掉。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const SfxService := preload("res://ui/services/SfxService.gd")
const Presentation := preload("res://effects/runtime/presentation/PresentationSettings.gd")

const CHECK_NAME := "team_merc_summon_sfx"

const PREP_SCENE := "res://scenes/prep/PrepScreen.tscn"
# 用 preload 常量做类型标注，下面对 PrepScreen 的调用才是**静态**调用。
# 按方法名派发会给 dynamic_call 的棘轮添丁 —— 检查工具本身不该是让项目
# 未受编译器检查的调用变多的那个（同 modal_lifecycle_check 的写法）。
const PrepScript := preload("res://scenes/prep/PrepScreen.gd")

# GameConstants.TEAM_SIDE_SIZE == 3：RED = 0/1/2，BLUE = 3/4/5。
const MY_SLOT := 0
const TEAMMATE_SLOT := 1
const ENEMY_SLOT := 3

var _h: CheckHarness
var _prep: PrepScript

var _team_active_before := false
var _team_slot_before := -1
var _round_before := 1
var _sound_before := true
var _master_mute_before := false


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	GameState.reset_run()
	await get_tree().process_frame

	# 前置 1：播放器池预热，且**必须已经在树里**。
	# 「池建好了」≠「能发声」—— 延迟挂载那一帧里节点存在但发不出声，
	# 于是下面所有「没响」的断言在这种实现上都会空过（audio_sfx_check 踩过）。
	SfxService.install()
	await get_tree().process_frame
	await get_tree().process_frame
	if not _h.expect(SfxService.voices_ready(), "voice_pool_not_in_tree",
			"8 个播放器还没全进树 —— 「没响」的断言在这种实现上恒真"):
		SfxService.shutdown()
		_h.finish(get_tree())
		return

	# 前置 2：静音开关。`ui_sound` 是落盘持久化的（PlayerProfile.save_profile），
	# **上一跑的收尾状态就是这一跑的初值** —— 9.17 已在这一点上空过一次。
	_sound_before = PlayerProfile.get_presentation_toggle("ui_sound")
	var master := AudioServer.get_bus_index("Master")
	_master_mute_before = AudioServer.is_bus_mute(master) if master >= 0 else false
	PlayerProfile.set_presentation_toggle("ui_sound", true)
	if master >= 0:
		AudioServer.set_bus_mute(master, false)
	if not _h.expect(Presentation.ui_sound_allowed(), "ui_sound_precondition_failed",
			"开关开着、Master 没静音，ui_sound_allowed() 却是 false —— 后面的断言无从谈起"):
		_restore()
		SfxService.shutdown()
		_h.finish(get_tree())
		return
	_h.expect(not GameState.tutorial_mode, "tutorial_mode_on",
		"教程模式下 _check_team_merc_alert() 整条早退，本门禁会全部空过")

	# 前置 3：摆成队伍态。座位号与回合号都要还原（它们是全局会话状态，
	# 不还原会把后面同批跑的门禁带进「以为自己在联机」的现场）。
	_team_active_before = NetworkService.team_active
	_team_slot_before = NetworkService.team_local_slot
	_round_before = GameState.round_index
	NetworkService.team_active = true
	NetworkService.team_local_slot = MY_SLOT

	# 队友先有 1 个：让备战页初始化时的快照就是「1」，
	# 后面那个 +1 才是干净的增量（否则第一次观察会被守卫吃掉，测不到东西）。
	_seed_slot(TEAMMATE_SLOT, 1)
	# 对手也先塞一个：下面要证明它永远不进计数、也永远不响。
	_seed_slot(ENEMY_SLOT, 3)

	_prep = _new_prep()
	if _prep == null:
		_restore()
		SfxService.shutdown()
		_h.finish(get_tree())
		return
	await _settle(4)
	# 红点控件建不出来（缺贴图等）不影响本门禁的主结论 —— 音效刻意不跟它绑定。
	_h.note("红点控件 %s" % ("已建出" if _prep._team_merc_alert != null else "未建出（音效仍应生效）"))

	await _check_counts_scope()
	await _check_first_observation_silent()
	await _check_teammate_summon_plays_once()
	await _check_own_summon_does_not_double()
	await _check_decrease_is_silent()
	await _check_round_change_is_silent()
	await _check_enemy_slot_is_silent()
	await _check_mute_gate_blocks_team_summon()

	_prep.queue_free()
	await _settle(4)
	_restore()
	SfxService.shutdown()
	_h.finish(get_tree())


# --- 用例 -------------------------------------------------------------------

func _check_counts_scope() -> void:
	# 计数只该覆盖**我这一队**的座位。信号来了全队响，但对手的雇佣绝不能在
	# 我这儿响 —— 那已经不是音效问题，是信息泄漏。
	var keys: Array = _prep._team_merc_counts().keys()
	keys.sort()
	var want: Array = [MY_SLOT, TEAMMATE_SLOT, MY_SLOT + 2]
	_h.expect(keys == want, "counts_scope_wrong",
		"队伍佣兵计数的座位集合是 %s，应为 %s" % [keys, want])


func _check_first_observation_silent() -> void:
	# 中途重连 / 刚进备战页：队友的列表一次到位，不是「刚多了一个」。
	# 守卫靠的是快照未初始化 —— 这里把快照打回未初始化，就是那一帧的现场。
	_prep._team_merc_snapshot_initialized = false
	SfxService.reset_counters_for_check()
	_seed_slot(TEAMMATE_SLOT, 3)
	_prep._on_team_prep_mercs_changed()
	_h.expect(SfxService.play_count(SfxService.CUE_MERC_SUMMON) == 0,
		"first_observation_played",
		"首次观察队友（一次到位 3 个）就响了 %d 声 —— 迟到同步会凭空响"
			% SfxService.play_count(SfxService.CUE_MERC_SUMMON))


func _check_teammate_summon_plays_once() -> void:
	# 主断言：队友 +1 恰好响一声。
	SfxService.reset_counters_for_check()
	_seed_slot(TEAMMATE_SLOT, 4)
	_prep._on_team_prep_mercs_changed()
	var played := SfxService.play_count(SfxService.CUE_MERC_SUMMON)
	_h.expect(played == 1, "teammate_summon_not_played_once",
		"队友多雇了一个佣兵，召唤音发了 %d 次（应为 1 次）—— 全队广播这条就没成立" % played)
	# 正对照：证明这一跑真的能出声，上面「0 次」的几条不是恒 0。
	_h.expect(SfxService.total_play_count() == 1, "teammate_summon_extra_cues",
		"队友 +1 除了召唤音还发了别的音效（共 %d 次）" % SfxService.total_play_count())

	# 没有新变化就不再响。reset 清了 40 ms 保护，所以这里若重复触发会被数到。
	SfxService.reset_counters_for_check()
	_prep._on_team_prep_mercs_changed()
	_h.expect(SfxService.play_count(SfxService.CUE_MERC_SUMMON) == 0,
		"teammate_summon_replayed_on_idle_sync",
		"队友佣兵数没变，再收一次同步又响了 %d 声"
			% SfxService.play_count(SfxService.CUE_MERC_SUMMON))


func _check_own_summon_does_not_double() -> void:
	# 自己那格 +1 **不得**由这条路径发声：房主在成交处已经响过一次，
	# 同步回来再响就是双响（`_refresh_all()` 结尾就会走到本函数）。
	SfxService.reset_counters_for_check()
	_add_local_merc()
	_prep._on_team_prep_mercs_changed()
	var played := SfxService.play_count(SfxService.CUE_MERC_SUMMON)
	_h.expect(played == 0, "own_summon_double_played",
		"自己座位 +1 时队伍路径也响了 %d 声 —— 房主一次雇佣会响两下" % played)


func _check_decrease_is_silent() -> void:
	# 卖掉 / 换掉：条数变少不是召唤，不该响。
	SfxService.reset_counters_for_check()
	_seed_slot(TEAMMATE_SLOT, 2)
	_prep._on_team_prep_mercs_changed()
	_h.expect(SfxService.play_count(SfxService.CUE_MERC_SUMMON) == 0,
		"decrease_played",
		"队友佣兵数减少时响了 %d 声" % SfxService.play_count(SfxService.CUE_MERC_SUMMON))


func _check_round_change_is_silent() -> void:
	# 换回合：上一轮的列表全部失效，新回合的第一份数据是整表。
	SfxService.reset_counters_for_check()
	GameState.round_index = _round_before + 1
	_seed_slot(TEAMMATE_SLOT, 5)
	_prep._on_team_prep_mercs_changed()
	_h.expect(SfxService.play_count(SfxService.CUE_MERC_SUMMON) == 0,
		"round_change_played",
		"换回合后的第一份队友数据响了 %d 声 —— 每回合开局都会凭空响"
			% SfxService.play_count(SfxService.CUE_MERC_SUMMON))


func _check_enemy_slot_is_silent() -> void:
	# 对手雇佣不该在我这儿响（也不该进计数）。上面 _check_counts_scope 已验集合，
	# 这里验行为：真给对手座位加人，然后走一次同步。
	_seed_slot(TEAMMATE_SLOT, 1)
	_prep._on_team_prep_mercs_changed()
	await _settle(1)
	SfxService.reset_counters_for_check()
	_seed_slot(ENEMY_SLOT, 6)
	_prep._on_team_prep_mercs_changed()
	_h.expect(SfxService.play_count(SfxService.CUE_MERC_SUMMON) == 0,
		"enemy_slot_played",
		"对手座位的佣兵数变了，我方响了 %d 声"
			% SfxService.play_count(SfxService.CUE_MERC_SUMMON))


func _check_mute_gate_blocks_team_summon() -> void:
	# 统一静音门只有一处（SfxService.play 过 ui_sound_allowed）：关掉开关，
	# 队伍召唤音一样要闭嘴 —— 别在调用点自己判一遍、判漏了。
	PlayerProfile.set_presentation_toggle("ui_sound", false)
	SfxService.reset_counters_for_check()
	_seed_slot(TEAMMATE_SLOT, 6)
	_prep._on_team_prep_mercs_changed()
	_h.expect(SfxService.total_play_count() == 0, "muted_team_summon_played",
		"「界面音效」已关，队伍召唤还记了 %d 次播放" % SfxService.total_play_count())

	# 对照组：开关打回来，同一个增量必须重新出声 —— 否则上面那条只是证明了
	# 「这条路径从来不发声」。
	PlayerProfile.set_presentation_toggle("ui_sound", true)
	SfxService.reset_counters_for_check()
	_seed_slot(TEAMMATE_SLOT, 7)
	_prep._on_team_prep_mercs_changed()
	_h.expect(SfxService.play_count(SfxService.CUE_MERC_SUMMON) == 1,
		"unmuted_team_summon_lost",
		"开关打回来之后队友 +1 只发了 %d 声（应为 1 声）"
			% SfxService.play_count(SfxService.CUE_MERC_SUMMON))


# --- 夹具 -------------------------------------------------------------------

func _new_prep() -> PrepScript:
	var packed := load(PREP_SCENE) as PackedScene
	if not _h.expect(packed != null, "prep_scene_load_failed", "%s 加载不出来" % PREP_SCENE):
		return null
	var prep = packed.instantiate() as PrepScript
	if not _h.expect(prep != null, "prep_wrong_type",
			"PrepScreen.tscn 实例化出来的不是 PrepScreen 脚本类型"):
		return null
	add_child(prep)
	return prep


# 把某个座位的佣兵条数摆成 count 条。
#
# 只关心条数：`_team_merc_counts()` 读的是 `team_prep_merc_ids(slot, round).size()`。
# 不走 `_sanitize_prep_merc_ids`（网络入口才需要）—— 用假 id 反而能把
# 「凑巧有真实佣兵表」这种依赖排除掉。
func _seed_slot(slot: int, count: int) -> void:
	var ids: Array = []
	for i in count:
		ids.append("seed_%d_%d" % [slot, i])
	NetworkService.team_prep_mercs[slot] = {"round": GameState.round_index, "ids": ids}


# 本地多一个佣兵（自己那一格的口径 = GameState.mercenary_slots 的非空格数）。
# 直接写状态而不是走 _hire_mercenary_to_slot：本门禁要验的是「队伍路径别响」，
# 不是雇佣流程本身（那一路由其它门禁与真机覆盖）。
func _add_local_merc() -> void:
	for i in GameState.mercenary_slots.size():
		if GameState.mercenary_slots[i] == null:
			GameState.mercenary_slots[i] = {"id": "seed_local", "uid": "seed_local", "star": 1}
			return


func _restore() -> void:
	NetworkService.team_active = _team_active_before
	NetworkService.team_local_slot = _team_slot_before
	GameState.round_index = _round_before
	PlayerProfile.set_presentation_toggle("ui_sound", _sound_before)
	var master := AudioServer.get_bus_index("Master")
	if master >= 0:
		AudioServer.set_bus_mute(master, _master_mute_before)


func _settle(frames: int = 4) -> void:
	for _i in frames:
		await get_tree().process_frame
