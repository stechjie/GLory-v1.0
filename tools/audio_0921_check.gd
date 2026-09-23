extends Node

# 9.21 新增音效的接线探针。
#
# ## 要证明的三句话（用户口径逐条对应）
#
#   ① 「开始游戏成功 → 所有人播放、播完才进游戏」：所有客户端都汇合到
#      `Main._on_team3v3_start()`，且 `_show_prep()` 被推迟 `cue_length` 秒。
#   ② 「开始游戏失败 → 只有房主听得到」：失败分支挂在本就只有房主能按到的
#      `Team3v3Lobby._on_start()` 的 reason 分支上。
#   ③ 「最终回合 pvp 开局音播完，再起 pvp 战斗 bgm」：BattleUI 的
#      `_pending_intro_cue()` 在 final 回合返回开局音、`_resolve_pending_battle_music()`
#      等它的**素材真实长度**再 `_start_battle_music()`。
#
# ## 为什么不是「跑一遍真场景看听到没有」
#
# 战斗/开局场景是重型 3D 场景，headless 下 instantiate 会挂死（见项目约定）。
# 所以本探针走两条不会挂死的路：
#   * **源级契约**：关键调用点与顺序在源码里存在，且**顺序正确**（不是「有就行」）。
#   * **运行级行为**：SfxService 的计数缝（reset_counters_for_check / play_count）
#     真的证明那几条 cue 播得出去、播得对。
#
# 只做「源码里有没有这个字符串」是不够的 —— 那正是本仓反复踩过的假绿陷阱。
# 所以顺序类断言全部用 index 比较，不用 contains。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const SfxService := preload("res://ui/services/SfxService.gd")

const CHECK_NAME := "audio_0921"


func _ready() -> void:
	var h := CheckHarness.new(CHECK_NAME)

	_check_cues_registered(h)
	_check_asset_files_on_disc(h)
	_check_start_success_funnel(h)
	_check_start_fail_host_only(h)
	_check_final_round_intro_order(h)
	_check_merc_and_militia_dispatch(h)
	await _check_runtime_playback(h)

	SfxService.shutdown()
	h.finish(get_tree())


func _src(path: String) -> String:
	return FileAccess.get_file_as_string(path)


# --- ① cue 表登记 ---------------------------------------------------------------

func _check_cues_registered(h) -> void:
	var sfx := _src("res://ui/services/SfxService.gd")
	for cue in [
		"star4_militia_skill", "merc_aquarius_time_skill",
		"merc_taurus_charge_skill", "merc_capricorn_steel_skill",
		"final_round_pvp_intro", "start_game_success", "start_game_fail",
	]:
		h.expect(sfx.contains('"%s"' % cue), "cue_not_registered_%s" % cue,
			"cue id %s 没有登记进 SfxService（既没有常量也没有 CUES 条目）" % cue)
	# 三条佣兵 + 民兵必须在派发表里，否则「表里有 cue、永远不响」。
	h.expect(sfx.contains('"merc_aquarius_time":'), "merc_table_missing_aquarius",
		"merc_aquarius_time 不在 MERC_SKILL_CUES 里")
	h.expect(sfx.contains('"merc_taurus_charge":'), "merc_table_missing_taurus",
		"merc_taurus_charge 不在 MERC_SKILL_CUES 里")
	h.expect(sfx.contains('"merc_capricorn_steel":'), "merc_table_missing_steel",
		"merc_capricorn_steel 不在 MERC_SKILL_CUES 里")
	h.expect(sfx.contains('"attack_interrupt": CUE_STAR4_MILITIA_SKILL'),
		"militia_proc_table_missing",
		"四星民兵没有进 STAR4_PROC_SKILL_CUES（它的技能是概率触发的 attack_interrupt）")
	# 民兵**不能**在攻击节拍表里 —— 放那里会被 _attack_skill_vfx_ready() 判假，
	# 成为一条永远不响的音（这是本批最容易写错的一处）。
	h.expect(not sfx.contains('"human_militia": CUE_STAR4_MILITIA_SKILL'),
		"militia_in_wrong_table",
		"四星民兵被放进了攻击节拍表 —— 它的技能不是「每第 N 次普攻」，永远不会响")


func _check_asset_files_on_disc(h) -> void:
	for path in [
		"res://assets/audio/sfx/battle/star4_militia_skill.mp3",
		"res://assets/audio/sfx/battle/merc_aquarius_time_skill.wav",
		"res://assets/audio/sfx/battle/merc_taurus_charge_skill.wav",
		"res://assets/audio/sfx/battle/merc_capricorn_steel_skill.mp3",
		"res://assets/audio/sfx/battle/final_round_pvp_intro.mp3",
		"res://assets/audio/sfx/ui/start_game_success.mp3",
		"res://assets/audio/sfx/ui/start_game_fail.wav",
	]:
		h.expect(ResourceLoader.exists(path), "asset_missing_%s" % path.get_file(),
			"素材不在工程里：%s" % path)


# --- ② 开始游戏成功：所有人 + 播完才进 -------------------------------------------

func _check_start_success_funnel(h) -> void:
	var main := _src("res://scenes/main/Main.gd")
	var lobby := _src("res://scenes/menu/Team3v3Lobby.gd")
	var net := _src("res://scripts/autoload/NetworkService.gd")

	h.expect(main.contains("CUE_START_GAME_SUCCESS"), "start_success_cue_unused",
		"Main 里没有任何地方播「开始游戏成功」")

	# 「所有人」的关键：客机与房主都经 team_start_requested 汇合到 Main 的同一个函数。
	h.expect(net.contains("team_start_requested.emit()"), "net_signal_not_emitted",
		"NetworkService 没有 emit team_start_requested —— 客机那一半进不来")
	h.expect(lobby.contains("NetworkService.team_start_requested.connect(_on_team_start_requested)"),
		"lobby_not_listening", "Team3v3Lobby 没有连 team_start_requested")
	h.expect(main.contains("lobby.start_requested.connect(_on_team3v3_start)"),
		"main_not_listening", "Main 没有连 lobby.start_requested —— 房主那一半进不来")

	# 「播完才进游戏」：_show_prep() 必须在等待之后，不能还在 _on_team3v3_start 里就调掉。
	var fn_at := main.find("func _on_team3v3_start() -> void:")
	h.expect(fn_at >= 0, "start_fn_missing", "找不到 Main._on_team3v3_start()")
	var fn_end := main.find("\nfunc ", fn_at + 10)
	var fn := main.substr(fn_at, (fn_end - fn_at) if fn_end > 0 else 4000)
	h.expect(fn.contains("await _play_start_game_success_then_prep()"),
		"start_success_not_awaited",
		"Main._on_team3v3_start() 没有 await 那条「播完再进」的调用")
	h.expect(not fn.contains("\n\t_show_prep()"), "start_prep_not_deferred",
		"Main._on_team3v3_start() 里还直接调 _show_prep() —— 进场没有被推迟，音效会跟场景重叠")
	var helper_at := main.find("func _play_start_game_success_then_prep() -> void:")
	h.expect(helper_at >= 0, "start_helper_missing", "找不到 _play_start_game_success_then_prep()")
	var helper_end := main.find("\nfunc ", helper_at + 10)
	var helper := main.substr(helper_at, (helper_end - helper_at) if helper_end > 0 else 3000)
	h.expect(helper.contains("SfxService.cue_length("), "start_helper_no_cue_length",
		"推迟时长没有用 cue_length() 读素材真实长度（写死常数换素材就对不上）")
	h.expect(helper.contains("_show_prep()"), "start_helper_no_prep",
		"推迟函数结尾没有调 _show_prep() —— 游戏永远进不去")
	var wait_at := helper.find("create_timer")
	var prep_at := helper.find("_show_prep()")
	h.expect(wait_at >= 0 and prep_at > wait_at, "start_helper_order_wrong",
		"_show_prep() 没有被放在等待**之后**（顺序反了等于没延迟）")


# --- ③ 开始游戏失败：只有房主 --------------------------------------------------

func _check_start_fail_host_only(h) -> void:
	var lobby := _src("res://scenes/menu/Team3v3Lobby.gd")
	h.expect(lobby.contains("CUE_START_GAME_FAIL"), "start_fail_cue_unused",
		"没有任何地方播「开始游戏失败」")
	var fn_at := lobby.find("func _on_start() -> void:")
	h.expect(fn_at >= 0, "lobby_start_missing", "找不到 Team3v3Lobby._on_start()")
	var fn_end := lobby.find("\nfunc ", fn_at + 10)
	var fn := lobby.substr(fn_at, (fn_end - fn_at) if fn_end > 0 else 3000)
	var reason_at := fn.find("_start_block_reason(true)")
	var fail_at := fn.find("CUE_START_GAME_FAIL")
	h.expect(reason_at >= 0 and fail_at > reason_at, "start_fail_not_in_reason_branch",
		"失败音不在 _start_block_reason 失败分支里")
	# 房主独占的论证：非房主按的是「准备」而不是「开始」（_refresh 里 _start_lbl 分支），
	# 所以这条分支天然只有房主能走到。这里钉住那个前提仍然成立。
	h.expect(lobby.contains("lobby_ready_done") and lobby.contains("lobby_ready"),
		"non_host_ready_labels_missing",
		"非房主的按钮文案分支（lobby_ready / lobby_ready_done）不见了 —— 「失败只房主能听到」的前提被破坏")


# --- ④ 最终回合 pvp 开局音 → 再起 BGM -----------------------------------------

func _check_final_round_intro_order(h) -> void:
	var ui := _src("res://scenes/battle/BattleUI.gd")
	var screen := _src("res://scenes/battle/BattleScreen.gd")

	h.expect(ui.contains("func _begin_final_round_intro()"), "final_intro_fn_missing",
		"BattleUI 里没有 _begin_final_round_intro()")
	h.expect(ui.contains("CUE_FINAL_ROUND_PVP_INTRO"), "final_intro_cue_unused",
		"BattleUI 没有任何地方播最终回合 pvp 开局音")

	# pending 判据必须**同时**覆盖 boss 与 final，否则 final 回合 BGM 会立刻起、
	# 盖在开局音上（正是用户要修的那个症状）。
	var pending_fn_at := ui.find("func _pending_intro_cue() -> String:")
	h.expect(pending_fn_at >= 0, "pending_cue_fn_missing", "找不到 _pending_intro_cue()")
	var pending_end := ui.find("\nfunc ", pending_fn_at + 10)
	var pending := ui.substr(pending_fn_at, (pending_end - pending_fn_at) if pending_end > 0 else 2000)
	h.expect(pending.contains("CUE_BOSS_APPEAR"), "pending_cue_no_boss",
		"_pending_intro_cue() 没覆盖 boss 登场音")
	h.expect(pending.contains("CUE_FINAL_ROUND_PVP_INTRO"), "pending_cue_no_final",
		"_pending_intro_cue() 没覆盖最终回合开局音")
	h.expect(pending.contains('"final"'), "pending_cue_no_final_kind",
		"_pending_intro_cue() 没有 final 这个 kind 分支")

	# 顺序：先响开局音、等素材长度、再起 BGM。
	var begin_at := ui.find("func _begin_final_round_intro() -> void:")
	h.expect(begin_at >= 0, "begin_final_fn_missing", "找不到 _begin_final_round_intro()")
	var begin_end := ui.find("\nfunc ", begin_at + 10)
	var begin := ui.substr(begin_at, (begin_end - begin_at) if begin_end > 0 else 2000)
	h.expect(begin.contains("MusicService.stop()"), "begin_final_no_stop",
		"_begin_final_round_intro() 没有先停掉上一页的 BGM（用户要求「响起开局音时备战 bgm 停止」）")
	var stop_at := begin.find("MusicService.stop()")
	var play_at := begin.find("SfxService.play(SfxService.CUE_FINAL_ROUND_PVP_INTRO)")
	h.expect(stop_at >= 0 and play_at > stop_at, "begin_final_order_wrong",
		"顺序反了：应当先 MusicService.stop() 再响开局音")

	# 场景里的调用点 + 判据
	h.expect(screen.contains("_begin_final_round_intro()"), "screen_no_final_intro",
		"BattleScreen 没有调 _begin_final_round_intro()")
	var eff_at := screen.find('if _effective_kind() == "final":')
	h.expect(eff_at >= 0, "screen_final_kind_branch_missing",
		"BattleScreen 里没有 final 分支来触发开局音")

	# 收口：BGM 必须等素材长度
	var resolve_at := ui.find("func _resolve_pending_battle_music() -> void:")
	h.expect(resolve_at >= 0, "resolve_fn_missing", "找不到 _resolve_pending_battle_music()")
	var resolve_end := ui.find("\nfunc ", resolve_at + 10)
	var resolve := ui.substr(resolve_at, (resolve_end - resolve_at) if resolve_end > 0 else 2500)
	h.expect(resolve.contains("_pending_intro_cue()"), "resolve_no_pending_cue",
		"_resolve_pending_battle_music() 没有问 _pending_intro_cue() 该等哪条素材")
	h.expect(resolve.contains("SfxService.cue_length(cue)"), "resolve_no_cue_length",
		"_resolve_pending_battle_music() 没有等 cue 的真实长度")


# --- ⑤ 佣兵 / 民兵派发点 -------------------------------------------------------

func _check_merc_and_militia_dispatch(h) -> void:
	var vfx := _src("res://scenes/battle/BattleVfx.gd")
	h.expect(vfx.contains("SfxService.merc_skill_cue_for(uid)"), "vfx_merc_entry_missing",
		"BattleVfx 里没有 merc_skill_cue_for 的调用点 —— 佣兵技能音永远不响")
	h.expect(vfx.contains("SfxService.proc_skill_cue_for(skill_id)"), "vfx_proc_entry_missing",
		"BattleVfx 里没有 proc_skill_cue_for 的调用点 —— 四星民兵技能音永远不响")

	# ★ 取到 cue 还不够 —— 必须**真的播出去**。
	# 变异测试实测过这个差别：把 `SfxService.play(proc_cue)` 那行删掉，
	# 只判「有没有 proc_skill_cue_for」的实现照旧全绿，而产品里一声不响。
	h.expect(vfx.contains("SfxService.play(proc_cue)"), "vfx_proc_play_missing",
		"BattleVfx 取到 proc_cue 之后没有 play() —— 一条永远不会响的音")
	h.expect(vfx.contains("SfxService.play(merc_cue)"), "vfx_merc_play_missing",
		"BattleVfx 取到 merc_cue 之后没有 play() —— 一条永远不会响的音")

	# 民兵那条必须在 unit_skill_proc 分支里（真正触发的那一刻），不是普攻节拍分支。
	#
	# 9.22 修正：原判据是「第一个 `proc_skill_cue_for` 出现在 `unit_skill_proc` 之后」，
	# 这依赖**文件里的定义顺序**。本轮新增的事件类型 `sfx_proc`（四星刺灵/毒灵/飞灵/
	# 巨甲灵那四条普攻附状态音）走的也是 `proc_skill_cue_for`，而它的派发实现
	# （BattleVfx._maybe_play_sfx_proc）按文件顺序排在 `_play_visual_events` **之前**
	# —— 原判据会把这段新代码误判成「民兵的音挂错了分支」。
	#
	# 现在改成**区间判定**：cue 的取值与播放都必须落在 `unit_skill_proc` 那个分支里
	# （区间 = 分支标签 → 下一个事件类型分支）。意图完全不变 ——
	# 「在真正触发的那一刻取值并播出去」—— 只是不再被文件的定义顺序左右。
	var proc_at := vfx.find('== "unit_skill_proc"')
	var proc_branch_end := vfx.find('== "sfx_proc"', proc_at + 1)
	h.expect(proc_at >= 0 and proc_branch_end > proc_at, "vfx_proc_branch_bounds",
		"定位不到 unit_skill_proc 分支的边界（BattleVfx 结构变了，下面的断言无从谈起）")
	var lookup_at := vfx.find("SfxService.proc_skill_cue_for(skill_id)", proc_at)
	var play_at := vfx.find("SfxService.play(proc_cue)", maxi(lookup_at, 0))
	h.expect(lookup_at > proc_at and lookup_at < proc_branch_end, "vfx_proc_wrong_branch",
		"proc_skill_cue_for 不在 unit_skill_proc 分支里（民兵的音不会真的触发）")
	h.expect(play_at > lookup_at and play_at < proc_branch_end, "vfx_proc_play_order",
		"play(proc_cue) 没跟在取值之后（或跑到别的分支里了）")

	# 门控：民兵是四星才响，且只算自身 + 友军。少了这两条，敌方或低星也会响。
	var branch_at := vfx.find("var proc_cue := SfxService.proc_skill_cue_for(skill_id)")
	var branch_end := vfx.find("\t\t\tif not skill_id.is_empty()", branch_at)
	h.expect(branch_at >= 0 and branch_end > branch_at, "vfx_proc_branch_not_found",
		"找不到 proc_cue 那段分支（结构变了，下面的门控断言无从谈起）")
	if branch_at >= 0 and branch_end > branch_at:
		var branch := vfx.substr(branch_at, branch_end - branch_at)
		h.expect(branch.contains("_is_own_or_ally_unit(proc_uid)"), "vfx_proc_no_owner_gate",
			"民兵技能音没有「自身 + 友军」门控 —— 敌方释放时也会响（用户口径是只算自己这边）")
		h.expect(branch.contains("_is_star4(proc_uid)"), "vfx_proc_no_star_gate",
			"民兵技能音没有四星门控 —— 低星民兵打断时也会响")


# --- ⑥ 运行级：这几条 cue 真的播得出去 -------------------------------------------

func _check_runtime_playback(h) -> void:
	SfxService.install()
	# 等播放器池**真的挂进树**。判据必须是 voices_ready()，不是 is_installed() ——
	# 后者只是「装过没有」（_watching），在播放器还没挂上时也会是 true，
	# 于是 play() 只记数不出声而断言照样绿（见 SfxService 那段冷启动说明）。
	var waited := 0
	while not SfxService.voices_ready() and waited < 60:
		await get_tree().process_frame
		waited += 1
	h.expect(SfxService.voices_ready(), "sfx_voices_not_ready",
		"等了 %d 帧，8 个播放器仍没全部挂进场景树 —— 后面所有播放断言都不成立" % waited)
	if not SfxService.voices_ready():
		return
	# 再给一帧，让 bus / 静音状态稳定。
	await get_tree().process_frame

	for cue in [
		SfxService.CUE_START_GAME_SUCCESS,
		SfxService.CUE_START_GAME_FAIL,
		SfxService.CUE_FINAL_ROUND_PVP_INTRO,
		SfxService.CUE_STAR4_MILITIA_SKILL,
		SfxService.CUE_MERC_AQUARIUS_TIME_SKILL,
		SfxService.CUE_MERC_TAURUS_CHARGE_SKILL,
		SfxService.CUE_MERC_CAPRICORN_STEEL_SKILL,
	]:
		# 每次测量前 reset：它连重触发保护一起清掉，「该响」的断言才是真的严格。
		SfxService.reset_counters_for_check()
		var ok := SfxService.play(cue)
		h.expect(ok, "cue_play_refused_%s" % cue, "play(%s) 被拒（文件缺失 / 未登记）" % cue)
		h.expect(SfxService.play_count(cue) == 1, "cue_not_counted_%s" % cue,
			"play(%s) 没有真的计数 —— 播放器池没就绪" % cue)

	# 时长必须读得出来：「播完再进游戏」与「播完再起 BGM」都靠它。
	for cue in [
		SfxService.CUE_START_GAME_SUCCESS,
		SfxService.CUE_FINAL_ROUND_PVP_INTRO,
	]:
		var ln := SfxService.cue_length(cue)
		h.expect(ln > 0.0, "cue_length_zero_%s" % cue,
			"cue_length(%s) = %s —— 读不到时长会让延迟退化成 0，音效与场景重叠" % [cue, ln])

	# 派发表真的能取到值（不是空串）。
	h.expect(SfxService.merc_skill_cue_for("merc_aquarius_time") == SfxService.CUE_MERC_AQUARIUS_TIME_SKILL,
		"merc_cue_lookup_wrong", "merc_skill_cue_for(merc_aquarius_time) 取值不对")
	h.expect(SfxService.merc_skill_cue_for("merc_taurus_charge") == SfxService.CUE_MERC_TAURUS_CHARGE_SKILL,
		"merc_cue_lookup_wrong_taurus", "merc_skill_cue_for(merc_taurus_charge) 取值不对")
	h.expect(SfxService.merc_skill_cue_for("merc_capricorn_steel") == SfxService.CUE_MERC_CAPRICORN_STEEL_SKILL,
		"merc_cue_lookup_wrong_steel", "merc_skill_cue_for(merc_capricorn_steel) 取值不对")
	h.expect(SfxService.proc_skill_cue_for("attack_interrupt") == SfxService.CUE_STAR4_MILITIA_SKILL,
		"proc_cue_lookup_wrong", "proc_skill_cue_for(attack_interrupt) 取值不对")
	# 没登记的 id 必须回空串，调用方据此跳过（不能退回默认音）。
	h.expect(SfxService.merc_skill_cue_for("merc_not_a_thing").is_empty(),
		"merc_cue_fallback_leak", "没登记的佣兵 id 返回了非空 cue —— 会让没素材的棋手也响")
