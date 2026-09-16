extends Node

# 羁绊激活音门禁（9.17 音频批 + 同日追加修复）。
#
# ## 要证明的那句话
#
# 「某个羁绊刚跨过某一档时，响一声」—— 尤其是**同族 7 人**那一档。
#
# ## 为什么要专门为它立门禁
#
# 反馈：凑齐「同族 7 人」羁绊时没有声音，而面板已经写着「已解锁」。
# 根因不是差分写错，而是**判「跨档」的口径**：
#
# 原实现拿人数前后比（`was < 档位 <= now`），并且「`round_index` 变了就只记基线、
# 不比较」。那条守卫把「回合号变了」当成「棋盘是外面送来的」的代理判断，可是
# ③ 的服务端 state payload 把 round_id 与棋盘**一起**下发（Main.gd:337 / :2491），
# 于是「玩家把第 7 个神放上棋盘」与「回合号 +1」落在同一次 `_refresh_all()` 里：
# 跨档被整帧吃掉，而快照已经被写成 7，同一档整局不再补 —— 面板显示已解锁、一声不响。
#
# 现在比的是**已解锁档位集合**（`PrepUI._synergy_unlocked_tiers()`）。本门禁盯的四件事：
#
# 1. **换回合同帧跨档** —— 上面那个真实场景，必须响（本轮的主回归面）。
# 2. **进场不为既有战果发声** —— 刚进备战页第一帧棋盘就已经 7 神（继承 / 读档 /
#    服务端下发），那是旧成果，不该响。这一条同时挡「把 `_synergy_sampled` 去掉、
#    改成无条件比较」这种会让每次进备战页都响一声的实现。
# 3. **人数在档位之间波动不算事件** —— 7 -> 8 -> 7 一声不响。用集合而不是人数，
#    就是为了这个；也挡「同一状态被反复采样逐帧补播」。
# 4. **一次采样最多一声** —— 一次操作同时跨两档（god 与人族都过 7）时只响一声。
#
# ## 怎么观测
#
# 用 SfxService 自己的缝：`reset_counters_for_check()` + `play_count(cue)`。
# **每次测量前都 reset**，它连 `_last_play_msec` 一起清，所以 40 ms 重触发保护
# 没有记忆 —— 「不该响」的断言才是真的严格。
#
# ## 夹具为什么直接写 board_slots
#
# 音效只关心「人数 -> 档位 -> 有没有新解锁」，与棋子是怎么上来的无关。
# 直接写状态可以用最少的状态把每一档的边界摆准；真实操作路径（备战席 -> 棋盘）
# 另有一条独立探针验过（tools/_probe_synergy_realpath 已归档，见本轮记录）。
# 但**必须**顺手断言「写进去的人数真的被 SynergyService 数到了」——
# 否则放置失败会让所有「没响」的断言恒真、悄悄空过（见 `board_counts_mismatch`）。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const SfxService := preload("res://ui/services/SfxService.gd")
const Presentation := preload("res://effects/runtime/presentation/PresentationSettings.gd")
const SynergyService := preload("res://scripts/units/SynergyService.gd")
# 用 preload 常量做类型标注，下面对 PrepScreen 的调用才是**静态**调用
# （按方法名派发会给 dynamic_call 的棘轮添丁 —— 检查工具本身不该是那个来源）。
const PrepScript := preload("res://scenes/prep/PrepScreen.gd")

const CHECK_NAME := "synergy_activation_sfx"

const PREP_SCENE := "res://scenes/prep/PrepScreen.tscn"

# 8 个同族棋子，全用不同 id —— 避免 _auto_combine_all() 把它们合成掉，
# 那会让「人数」与夹具期望不一致（真出现时 board_counts_mismatch 会报）。
const GOD_IDS := [
	"god_priest", "god_priestess", "god_guard", "god_aurora",
	"god_angel", "god_arbiter", "god_archangel", "god_king",
]
const HUMAN_IDS := [
	"human_militia", "human_merchant", "human_archer", "human_swordsman",
	"human_mage", "human_cleric", "human_death_servant", "human_king",
]

var _h: CheckHarness
var _prep: PrepScript

var _round_before := 1
var _sound_before := true
var _master_mute_before := false


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	GameState.reset_run()
	await get_tree().process_frame

	# 前置 1：播放器池预热，且**必须已经在树里**。
	# 「池建好了」≠「能发声」—— 延迟挂载那一帧里节点存在但发不出声，
	# 于是所有「没响」的断言在这种实现上都会空过（audio_sfx_check 踩过）。
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
		"教程模式下 _refresh_all() 走另一条分支，本门禁的采样点会错位")

	_round_before = GameState.round_index

	await _case_entry_does_not_announce()
	await _case_cross_tiers()
	await _case_round_change_crosses()
	await _case_mute_gate()

	# 收尾：把这一跑留下的局面收干净（棋盘/回合号是全局会话状态）。
	_clear_board()
	_restore()
	SfxService.shutdown()
	_h.finish(get_tree())


# --- 1. 进场不为既有战果发声 --------------------------------------------------

func _case_entry_does_not_announce() -> void:
	# 棋盘必须**在实例化之前**就摆成 7 神 —— 进场那一帧是 PrepScreen._ready() 里的
	# _refresh_all()，它才是「第一帧采样」。等实例建好再摆，测到的是「进场之后的跨档」
	# 而不是「进场不为既有战果发声」（第一版夹具就这么错过一次）。
	SfxService.reset_counters_for_check()
	_set_board(7, 0)
	var prep := _new_prep()
	if prep == null:
		return
	await _settle(5)
	_h.expect(_count() == 0, "entry_announced",
		"刚进备战页就为棋盘上已有的 7 神响了 %d 声 —— 那是上一回合留下的战果"
			% _count())
	_expect_prep_ready(7, 0)

	# 正对照：进场没有把神7 永久标记成「已播报」—— 掉档后重新跨回来仍要响。
	# 少了这一条，上面那个「0 声」在「整条路径从不发声」的实现上也会绿。
	_set_board(6, 0)
	prep._refresh_all()
	await _settle(1)
	_expect_prep_ready(6, 0)
	SfxService.reset_counters_for_check()
	_set_board(7, 0)
	prep._refresh_all()
	await _settle(1)
	_h.expect(_count() == 1, "entry_then_cross_lost",
		"进场即 7 神之后，掉到 6 再补回 7 只发了 %d 声（应为 1 声）" % _count())

	prep.queue_free()
	await _settle(3)

func _case_cross_tiers() -> void:
	var prep := _new_prep()
	if prep == null:
		return
	await _settle(4)

	# 基线 6 神：只解锁 1 / 3 两档。
	_set_board(6, 0)
	prep._refresh_all()
	await _settle(1)
	_expect_prep_ready(6, 0)

	# 主断言：6 -> 7 恰好一声。
	SfxService.reset_counters_for_check()
	_set_board(7, 0)
	prep._refresh_all()
	await _settle(1)
	_h.expect(_count() == 1, "cross_7_not_played_once",
		"6 神补到 7 神（跨过神7 档）响了 %d 次（应为 1 次）" % _count())
	# 正对照：证明这一跑真的能出声，前面几条「0 次」不是恒 0。
	_h.expect(SfxService.total_play_count() == 1, "cross_7_extra_cues",
		"跨 7 档除了羁绊音还发了别的音效（共 %d 次）" % SfxService.total_play_count())

	# 同一状态再采样一次：不许重放（快照必须在判断之后无条件更新）。
	SfxService.reset_counters_for_check()
	prep._refresh_all()
	await _settle(1)
	_h.expect(_count() == 0, "idle_resample_replayed",
		"棋盘没变，再采样一次又响了 %d 声" % _count())

	# 档位之内的人数波动不是事件：7 -> 8 -> 7 都还在 7 档之上。
	SfxService.reset_counters_for_check()
	_set_board(8, 0)
	prep._refresh_all()
	await _settle(1)
	_set_board(7, 0)
	prep._refresh_all()
	await _settle(1)
	_h.expect(_count() == 0, "wiggle_above_tier_played",
		"人数在 7 档之上来回（7 -> 8 -> 7）响了 %d 声 —— 档位没有变化就不是事件"
			% _count())

	# 掉档后再跨回来：玩家又做了一次这个操作，该响。
	_set_board(6, 0)
	prep._refresh_all()
	await _settle(1)
	_expect_prep_ready(6, 0)
	SfxService.reset_counters_for_check()
	_set_board(7, 0)
	prep._refresh_all()
	await _settle(1)
	_h.expect(_count() == 1, "requited_not_played",
		"掉到 6 神再补回 7 神响了 %d 次（应为 1 次）" % _count())

	# 一次操作同时跨两档：只许一声。
	_set_board(6, 6)
	prep._refresh_all()
	await _settle(1)
	_expect_prep_ready(6, 6)
	SfxService.reset_counters_for_check()
	_set_board(8, 8)
	prep._refresh_all()
	await _settle(1)
	_h.expect(_count() == 1, "multi_tier_multi_sound",
		"一次采样同时跨了神7 与人7 两档，响了 %d 声（应为 1 声，连响像卡带）"
			% _count())

	prep.queue_free()
	await _settle(3)


# --- 3. 换回合同帧跨档（本轮修复的主回归面）-----------------------------------

func _case_round_change_crosses() -> void:
	var prep := _new_prep()
	if prep == null:
		return
	await _settle(4)

	_set_board(6, 0)
	prep._refresh_all()
	await _settle(1)
	_expect_prep_ready(6, 0)

	# 现场还原：③ 的 state payload 把 round_id 与棋盘一起下发，
	# 于是「回合号 +1」与「第 7 个神上棋盘」落在同一次 _refresh_all() 里。
	# 原实现在这一帧只记基线不比较 —— 跨档被吃掉，且面板已经显示「已解锁」。
	SfxService.reset_counters_for_check()
	GameState.round_index = _round_before + 1
	_set_board(7, 0)
	prep._refresh_all()
	await _settle(1)
	_h.expect(_count() == 1, "round_change_swallowed_cross",
		("换回合同帧从 6 神跨到 7 神响了 %d 次（应为 1 次）——"
			+ " 面板会显示神7 已解锁而一声不响，正是这条守卫吃掉的那一帧")
			% _count())
	_expect_prep_ready(7, 0)

	# 换回合本身不该凭空响：回合号变了但棋盘没变。
	SfxService.reset_counters_for_check()
	GameState.round_index = _round_before + 2
	prep._refresh_all()
	await _settle(1)
	_h.expect(_count() == 0, "round_change_phantom_played",
		"只换回合（棋盘没变）却响了 %d 声" % _count())

	prep.queue_free()
	await _settle(3)


# --- 4. 统一静音门 ------------------------------------------------------------

func _case_mute_gate() -> void:
	# 静音门只有一处（SfxService.play 里过 ui_sound_allowed）：关掉开关，
	# 羁绊音一样要闭嘴 —— 别在调用点自己判一遍、判漏了。
	var prep := _new_prep()
	if prep == null:
		return
	await _settle(4)

	_set_board(6, 0)
	prep._refresh_all()
	await _settle(1)
	_expect_prep_ready(6, 0)

	PlayerProfile.set_presentation_toggle("ui_sound", false)
	SfxService.reset_counters_for_check()
	_set_board(7, 0)
	prep._refresh_all()
	await _settle(1)
	_h.expect(_count() == 0, "muted_cross_played",
		"开关关着，跨 7 档还看见 %d 次发声" % _count())

	# 对照组：开关打回来，同一个增量必须重新出声 —— 否则上面那条只是证明了
	# 「这条路径从来不发声」。
	PlayerProfile.set_presentation_toggle("ui_sound", true)
	_set_board(6, 0)
	prep._refresh_all()
	await _settle(1)
	SfxService.reset_counters_for_check()
	_set_board(7, 0)
	prep._refresh_all()
	await _settle(1)
	_h.expect(_count() == 1, "unmuted_cross_lost",
		"开关打回来之后跨 7 档只发了 %d 声（应为 1 声）" % _count())

	prep.queue_free()
	await _settle(3)


# --- 夹具 ---------------------------------------------------------------------

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


func _count() -> int:
	return SfxService.play_count(SfxService.CUE_SYNERGY_ACTIVATE)


func _clear_board() -> void:
	GameState.board_slots.resize(GameConstants.CELL_COUNT)
	for i in GameConstants.CELL_COUNT:
		GameState.board_slots[i] = null


# 棋盘摆 god_count 个神 + human_count 个人（都取不同 id，避免自动合成）。
func _set_board(god_count: int, human_count: int) -> void:
	_clear_board()
	var idx := 0
	for i in mini(god_count, GOD_IDS.size()):
		GameState.board_slots[idx] = _cell(r"race_units", GOD_IDS[i], "g%d" % i)
		idx += 1
	for i in mini(human_count, HUMAN_IDS.size()):
		GameState.board_slots[idx] = _cell(r"race_units", HUMAN_IDS[i], "h%d" % i)
		idx += 1


var _defs: Dictionary = {}


func _cell(table: String, unit_id: String, uid: String) -> Dictionary:
	if not _defs.has(table):
		_defs[table] = DataRegistry.get_table(table).get("units", [])
	for cand in _defs[table]:
		if str((cand as Dictionary).get("id", "")) == unit_id:
			return {"id": unit_id, "uid": uid, "star": 3,
				"def": (cand as Dictionary).duplicate(true), "is_mercenary": false}
	_h.expect(false, "fixture_unit_missing", "数据表里找不到棋子 %s" % unit_id)
	return {}


# 夹具自检：**这一条不能省**。写进来的棋子若没被数到（数据表字段改名、
# board_slots 形状变了……），后面所有「没响」的断言都会恒真、悄悄空过。
func _expect_prep_ready(god_count: int, human_count: int) -> void:
	var counts := SynergyService.count_races_from_board()
	_h.expect(int(counts.get("god", -1)) == god_count, "board_counts_mismatch",
		"夹具摆了 %d 个神，SynergyService 数到 %d 个 —— 「没响」的断言会因此空过"
			% [god_count, int(counts.get("god", -1))])
	_h.expect(int(counts.get("human", -1)) == human_count, "board_counts_mismatch",
		"夹具摆了 %d 个人，SynergyService 数到 %d 个"
			% [human_count, int(counts.get("human", -1))])


func _restore() -> void:
	GameState.round_index = _round_before
	PlayerProfile.set_presentation_toggle("ui_sound", _sound_before)
	var master := AudioServer.get_bus_index("Master")
	if master >= 0:
		AudioServer.set_bus_mute(master, _master_mute_before)


func _settle(frames: int = 4) -> void:
	for _i in frames:
		await get_tree().process_frame
