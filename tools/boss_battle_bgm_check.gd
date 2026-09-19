extends Node

# boss 回合「备战 BGM -> 登场音 -> pve 战斗 BGM」的交接门禁（9.17 第三轮）。
#
# ## 要证明的那句话
#
# 反馈原文：「boss 回合进入战斗场景时，备战 bgm 没停止，应该响起 boss 登场音效时，
# 备战 bgm 停止，音效结束后，pve 战斗 bgm 响起。」
#
# 也就是一条**三段式时间线**，三段都要在，缺一段就是错：
#   ① 进场景 -> 登场音开始之前：还是**备战那首**（读条期不该变哑）；
#   ② 登场音响起的那一瞬：备战 BGM **停**，登场音开始；
#   ③ 登场音结束之后：**pve 战斗 BGM** 起。
#
# 9.17 第二批只做对了 ③：`_start_battle_music()` 在 boss 回合会把战斗 BGM 推迟到
# 登场音之后，但**没有任何人叫停「上一页还在放的那首」**。MusicService 是一个播放器、
# 一首当前曲目，`play()` 只在路径不同时才换曲 —— 于是 ② 缺失，备战 BGM 一路盖到
# 登场音结束。本门禁钉的就是 ②，顺带把 ① 也钉住，免得「修 ②」的方式变成
# 「一进场景就把 BGM 停掉」（那会让读条期变哑，是另一种错）。
#
# ## 怎么观测
#
# 不起 stub：直接实例化真的 `BattleUI`。它是整条战斗继承链的根，而 `_ready()` 只
# 定义在 BattleScreen 上 —— 所以这里拿到的是一个没有棋盘、没有 3D 世界的控制节点，
# 正好够驱动真的 `_start_battle_music()` / `_begin_boss_intro()` /
# `_resolve_pending_battle_music()`。
#
# 判据落在 `MusicService.current_path()` 上（"当前曲目是哪一首"），**不是** `is_playing()`：
# headless 用的是 Dummy 音频驱动，「有没有声音」在这里验不了（那是 external，
# 写在交接里）。「当前曲目」是纯状态，Dummy 驱动下照样准。
#
# 运行：
#   Godot_v4.7.2-stable_win64_console.exe --headless --path . tools/boss_battle_bgm_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const SfxService := preload("res://ui/services/SfxService.gd")
const MusicService := preload("res://ui/services/MusicService.gd")
# 用 preload 常量做类型标注：下面对 BattleUI 的成员访问 / 方法调用才是**静态**的
# （按名字派发会给 dynamic_call 的棘轮添丁，检查工具本身不该是那个来源）。
const BattleUIScript := preload("res://scenes/battle/BattleUI.gd")

const CHECK_NAME := "boss_battle_bgm"

const PREP_MUSIC := "res://assets/audio/bgm/prep_music.mp3"
const PVE_BATTLE_MUSIC := "res://assets/audio/bgm/fighting_music.mp3"
const PVP_BATTLE_MUSIC := "res://assets/audio/bgm/pvp_battle_music.mp3"

const BATTLE_UI_SRC := "res://scenes/battle/BattleUI.gd"
const BATTLE_SCREEN_SRC := "res://scenes/battle/BattleScreen.gd"

# 等待播放器池（延迟挂载）落地的上限帧数。
const READY_WAIT_FRAMES := 12
# 等 `_resolve_pending_battle_music()` 走完「登场音时长」的上限秒数。
# 素材本身 15.09 s（实测能量包络到 14.5 s 才降到 3% 以下，不是尾部静音），
# 所以这里给足余量；超了就是「等」的逻辑塌了，要红。
const INTRO_WAIT_LIMIT_SEC := 30.0

var _h: CheckHarness
var _resolve_done := false
# 上一跑落盘的开关就是这一跑的初值 —— 先存后置，收尾还原。
var _music_before := true
var _ui_sound_before := true


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	GameState.reset_run()
	await get_tree().process_frame

	_music_before = _pref("music")
	_ui_sound_before = _pref("ui_sound")

	if not _h.expect(not GameState.tutorial_mode, "tutorial_mode_on",
			"教程模式下战斗页走另一条分支，本门禁的观测点会错位"):
		_abort()
		return
	if not _h.expect(GameState.round_index != GameState.FINAL_ROUND, "at_final_round",
			"当前回合就是决赛回合 —— `_effective_kind()` 会直接返回 final，"
				+ "本门禁的 boss 分支根本走不到"):
		_abort()
		return

	# 静音门全开：本门禁验的是「哪一首该响」，不是开关。开关关着时
	# `SfxService.play()` 直接返回 false，登场音那条断言就变成在验别的错。
	_apply_prefs(true, true)

	SfxService.install()
	MusicService.install()
	await _await_pool()

	await _case_non_boss_unaffected()
	await _case_boss_timeline()

	_check_source_contract()

	_teardown()
	_restore()
	_h.finish(get_tree())


# --- 1. 非 boss 回合：BGM 必须**当场**起来，不许被 boss 那套推迟逻辑波及 ----------

func _case_non_boss_unaffected() -> void:
	var ui := _new_battle_ui("pve")
	MusicService.play(PREP_MUSIC)
	_h.expect(MusicService.current_path() == PREP_MUSIC, "prep_music_not_current",
		"前置失败：play(prep_music) 之后 current_path() 是 %s" % MusicService.current_path())

	ui._start_battle_music()
	_h.expect(not ui._boss_intro_pending, "pve_deferred_music",
		"pve 回合也被推迟了战斗 BGM（_boss_intro_pending 被置起）—— "
			+ "只有 boss 回合才该等登场音")
	_h.expect(MusicService.current_path() == PVE_BATTLE_MUSIC, "pve_battle_music_not_started",
		"pve 回合 _start_battle_music() 之后当前曲目是 %s（应为 pve 战斗 BGM）—— "
			% MusicService.current_path() + "非 boss 回合不该有任何等待")
	_free_ui(ui)


# --- 2. boss 回合：① 读条期仍是备战那首 / ② 登场音一起就停 / ③ 音完起战斗 BGM ----

func _case_boss_timeline() -> void:
	var ui := _new_battle_ui("boss")
	_h.expect(ui._effective_kind() == "boss", "boss_kind_not_effective",
		"_state.kind=\"boss\" 时 _effective_kind() 是 %s" % ui._effective_kind())

	# 模拟真实顺序：备战页已经放着 prep_music，进战斗场景时它还在响
	# （MusicService 是常驻的，切页面不会掐断它 —— 这正是本 bug 的前提）。
	MusicService.play(PREP_MUSIC)
	ui._start_battle_music()

	# ① 进场景 -> 读条期：战斗 BGM 被挡住，但**备战那首还得响着**。
	_h.expect(ui._boss_intro_pending, "boss_music_not_deferred",
		"boss 回合 _start_battle_music() 没有记下 pending —— 战斗 BGM 会立刻盖掉登场音")
	_h.expect(MusicService.current_path() == PREP_MUSIC, "prep_music_stopped_too_early",
		"进 boss 战斗场景的那一刻备战 BGM 就被停了（当前曲目 %s）—— "
			% MusicService.current_path() + "读条期（分帧建模型）会变成一段纯静音；"
			+ "反馈要的是「登场音响起时」才停")

	# ② 登场音响起的那一瞬：备战 BGM 停、登场音发。
	#    这是本门禁的主断言 —— 9.17 第二批就是这里缺了一环。
	ui._begin_boss_intro()
	_h.expect(MusicService.current_path().is_empty(), "prep_music_not_stopped_on_intro",
		"登场音响起时当前曲目仍是 %s —— 备战 BGM 没停，它会一路盖到登场音结束"
			% MusicService.current_path())
	_h.expect(not MusicService.is_playing(), "prep_music_still_playing_on_intro",
		"登场音响起时 MusicService 还在播放中 —— stop() 没落到播放器上")
	_h.expect(SfxService.play_count(SfxService.CUE_BOSS_APPEAR) == 1, "boss_appear_not_played",
		"_begin_boss_intro() 之后登场音播放计数是 %d（应为 1）"
			% SfxService.play_count(SfxService.CUE_BOSS_APPEAR))
	_h.expect(ui._boss_intro_played, "boss_intro_not_marked",
		"_begin_boss_intro() 没有把 _boss_intro_played 置起 —— "
			+ "_start_battle_music() 会以为「还没登场」，BGM 永远起不来")

	# ② 与 ③ 之间：登场音还没放完，战斗 BGM **不许**已经响。
	_h.expect(MusicService.current_path().is_empty(), "battle_music_started_before_intro_end",
		"登场音还没结束，当前曲目已经是 %s —— "
			% MusicService.current_path() + "反馈要的是「音效结束后 pve 战斗 bgm 响起」")

	# ③ 等登场音素材的真实时长走完，战斗 BGM 起来。
	_resolve_done = false
	_start_resolve(ui)
	var waited := 0.0
	while not _resolve_done and waited < INTRO_WAIT_LIMIT_SEC:
		await get_tree().process_frame
		waited += get_process_delta_time()
	_h.expect(_resolve_done, "pending_never_resolved",
		"等了 %.1f 秒 _resolve_pending_battle_music() 都没收口 —— "
			% waited + "boss 回合整场没有战斗 BGM")
	_h.expect(MusicService.current_path() == PVE_BATTLE_MUSIC, "boss_battle_music_not_started",
		"登场音结束后当前曲目是 %s（应为 pve 战斗 BGM）—— "
			% MusicService.current_path() + "boss 回合同样要走 pve 那首")
	_h.expect(not ui._boss_intro_pending, "boss_pending_not_cleared",
		"_resolve_pending_battle_music() 走完之后 _boss_intro_pending 仍然是 true")

	# 路径选择若漂移（boss 回合被算成 pvp），上面那条会红在这里更直白。
	_h.expect(ui._battle_music_path() == PVE_BATTLE_MUSIC, "boss_uses_pvp_music",
		"boss 回合的 _battle_music_path() 是 %s，应该是 pve 那首 %s"
			% [ui._battle_music_path(), PVE_BATTLE_MUSIC])
	_h.expect(ui._battle_music_path() != PVP_BATTLE_MUSIC, "boss_music_path_collision",
		"boss 回合取到了 pvp 战斗 BGM —— 两首的判据分不开了")

	_free_ui(ui)


# `_resolve_pending_battle_music()` 是协程：这里把它推起来，然后由调用方轮询
# `_resolve_done`（有界等待，超时不会挂死），而不是无限 await 一个可能不收口的实现。
func _start_resolve(ui: BattleUIScript) -> void:
	await ui._resolve_pending_battle_music()
	_resolve_done = true


# --- 3. 源码合同：接线点在不在、顺序对不对 ---------------------------------------

# 行为断言证明了三个方法各自做对，但证明不了「BattleScreen 真的在那个位置调了
# `_begin_boss_intro()`」。这一段补上，并且**先剥注释再找** —— 否则一段
# 「写了但没做」的注释会让它变绿。
func _check_source_contract() -> void:
	var screen := _code_only(FileAccess.get_file_as_string(BATTLE_SCREEN_SRC))
	_h.expect(not screen.is_empty(), "battle_screen_unreadable",
		"读不到 %s" % BATTLE_SCREEN_SRC)
	var boss_branch := "if _effective_kind() == \"boss\":\n\t\t_begin_boss_intro()"
	_h.expect(screen.contains(boss_branch), "screen_does_not_call_boss_intro",
		"BattleScreen 的 boss 分支没有调 _begin_boss_intro()（找的是 `%s`）—— "
			% boss_branch.replace("\n", "\\n")
			+ "行为断言全绿也拦不住「接线点被删掉」")
	_h.expect(not screen.contains("SfxService.play(SfxService.CUE_BOSS_APPEAR)"),
		"screen_plays_boss_appear_itself",
		"BattleScreen 自己还在播登场音 —— 登场音必须和「停备战 BGM」同一时刻发生，"
			+ "分在两处迟早漂移；它应该只调 _begin_boss_intro()")

	var ui_src := _code_only(FileAccess.get_file_as_string(BATTLE_UI_SRC))
	_h.expect(not ui_src.is_empty(), "battle_ui_unreadable",
		"读不到 %s" % BATTLE_UI_SRC)
	# 只看 `_begin_boss_intro()` 自己的函数体 —— 全文件里 `MusicService.stop()` 还有
	# 一处（`_stop_battle_music()`），不圈定范围的话「顺序」这条会被那一处蒙对。
	var body := _function_body(ui_src, "_begin_boss_intro")
	_h.expect(not body.is_empty(), "boss_intro_body_unreadable",
		"在 BattleUI.gd 里找不到 _begin_boss_intro() 的函数体")
	var stop_at := body.find("MusicService.stop()")
	var play_at := body.find("SfxService.play(SfxService.CUE_BOSS_APPEAR)")
	_h.expect(stop_at >= 0 and play_at > stop_at, "boss_intro_order_wrong",
		"_begin_boss_intro() 里「停 BGM」没有排在「响登场音」之前 —— "
			+ "反过来的话登场音的头几毫秒会和备战 BGM 叠在一起")


# 取 `func <name>(` 到下一个顶层 `func ` 之间的正文（剥过注释的源码上做）。
func _function_body(source: String, name: String) -> String:
	var head := source.find("func %s(" % name)
	if head < 0:
		return ""
	var tail := source.find("\nfunc ", head + 1)
	return source.substr(head, (tail - head) if tail > head else -1)


# --- 工具 -----------------------------------------------------------------------

# 起一个干净的 BattleUI。它只是链根，`_ready()` 定义在 BattleScreen 上，
# 所以这里不会触发建棋盘/建 3D 世界，正好够驱动 BGM 那三个方法。
func _new_battle_ui(kind: String) -> BattleUIScript:
	var ui: BattleUIScript = BattleUIScript.new()
	ui._kind = kind
	ui._state = {"kind": kind}
	add_child(ui)
	return ui


func _free_ui(ui: BattleUIScript) -> void:
	if ui != null and is_instance_valid(ui):
		ui.queue_free()


func _await_pool() -> void:
	var waited := 0
	while not SfxService.voices_ready() and waited < READY_WAIT_FRAMES:
		await get_tree().process_frame
		waited += 1


func _abort() -> void:
	_restore()
	_h.finish(get_tree())


func _teardown() -> void:
	SfxService.stop_all()
	MusicService.stop()
	SfxService.shutdown()
	MusicService.shutdown()


func _pref(key: String) -> bool:
	return bool(PlayerProfile.get_presentation_toggle(key))


func _apply_prefs(music: bool, ui_sound: bool) -> void:
	PlayerProfile.set_presentation_toggle("music", music)
	PlayerProfile.set_presentation_toggle("ui_sound", ui_sound)


func _restore() -> void:
	_apply_prefs(_music_before, _ui_sound_before)


# 剥掉注释（同 audio_sfx_check 的做法）：源码合同必须看代码本身，
# 否则「注释里写了」就能骗过断言。顺带把 CRLF 归一成 LF，便于写多行字面量。
func _code_only(source: String) -> String:
	var out: Array[String] = []
	for raw in source.replace("\r\n", "\n").split("\n"):
		var line := str(raw)
		var quote := ""
		var cut := -1
		for i in line.length():
			var ch := line[i]
			if not quote.is_empty():
				if ch == quote and (i == 0 or line[i - 1] != "\\"):
					quote = ""
				continue
			if ch == "\"" or ch == "'":
				quote = ch
				continue
			if ch == "#":
				cut = i
				break
		out.append(line if cut < 0 else line.substr(0, cut))
	return "\n".join(out)
