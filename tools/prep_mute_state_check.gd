extends Node

# 备战页「静音 / 已静音」键的口径门禁（9.17 第二批追加）。
#
# ## 要证明的那句话
#
# 「在大厅设置里关掉背景音乐之后，进对局时这个键显示『已静音』」——
# 而且**按一下真的能把声音打开**：不是个写着「已静音」、按下去反而更静的坏键。
#
# ## 为什么要单独立门禁
#
# 反馈原文：「大厅设置里如果设置了背景音乐关闭，在对局里应该相应的也是已静音，
# 而不是在对局里显示的是静音。」
#
# 根因是按钮状态**只读 Master 总线**，而「背景音乐」是另一条闸门
# （`PresentationSettings.music_allowed()`，由 MusicService 执行）——
# 两处状态各说各话：设置里关了音乐，键上却还写着「静音」。
#
# ## 钉住五件事
#
# 1. **基线**：开关全开、总线没静音 → 「静音」。这是正对照 —— 少了它，
#    下面「已静音」的断言在一个恒返回「已静音」的实现上也会绿。
# 2. **主断言**：把「背景音乐」关掉（= 大厅设置那一步），**再进**备战页 → 「已静音」。
#    「关掉之后再实例化」是关键：文案在 `_build_top_actions()` 里算一次，
#    真实路径就是先关设置、再进对局。
# 3. **按一下 = 声音回来**：音乐开关回 true、总线不静音、文案变「静音」。
#    挡的是「显示与点击方向分叉」——那种实现第一下是在关一个本来就没静音的总线。
# 4. **再按一下只掐总线**：不动玩家的音乐偏好（那是设置页的事），文案回「已静音」。
# 5. **范围**：只关「界面音效」不算已静音（BGM 还响着，说成静音是假话）。
#    这条把「要不要把 ui_sound 并进判据」变成一个显式决定 —— 将来改口径得改断言，
#    不能顺手漂移。
#
# ## 怎么观测
#
# 不起 stub、不进音频栈：直接读**真按钮的真文案**（`PrepUI._mute_button.text`），
# 配合 PlayerProfile 的开关与 Master 总线的静音位。点击走 `pressed.emit()`，
# 让 `make_menu_button` 里那条真实连接也过一遍。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const Presentation := preload("res://effects/runtime/presentation/PresentationSettings.gd")
const SfxService := preload("res://ui/services/SfxService.gd")
const MusicService := preload("res://ui/services/MusicService.gd")
# 用 preload 常量做类型标注，下面对 PrepScreen 的调用才是**静态**调用
# （按方法名派发会给 dynamic_call 的棘轮添丁 —— 检查工具本身不该是那个来源）。
const PrepScript := preload("res://scenes/prep/PrepScreen.gd")

const CHECK_NAME := "prep_mute_state"
const PREP_SCENE := "res://scenes/prep/PrepScreen.tscn"

# 等待按钮建出来的上限帧数。`PrepScreen._ready()` 里是 `await _build(...)`，
# 实例化之后要几帧 UI 才落地 —— 比死等固定帧数稳。
const BUILD_WAIT_FRAMES := 120

var _h: CheckHarness

var _music_before := true
var _ui_sound_before := true
var _master_mute_before := false


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	GameState.reset_run()
	await get_tree().process_frame

	# 前置：落盘设置是跨启动持久化的，**上一跑的收尾状态就是这一跑的初值** ——
	# 9.17 首版已在这一点上空过一次，这里先存后置。
	_music_before = _pref("music")
	_ui_sound_before = _pref("ui_sound")
	_master_mute_before = _bus_muted()

	if not _h.expect(AudioServer.get_bus_index("Master") >= 0, "master_bus_missing",
			"没有 Master 总线，静音位无处可读 —— 后面的断言无从谈起"):
		_h.finish(get_tree())
		return
	if not _h.expect(not GameState.tutorial_mode, "tutorial_mode_on",
			"教程模式下备战页走另一条分支，本门禁的观测点会错位"):
		_restore()
		_h.finish(get_tree())
		return

	# 播放器池只用于「让 PrepScreen 的 _ready 有一条正常的音频路径」，本门禁
	# 不断言发声。装不上不算失败，但要在日志里看得见。
	SfxService.install()
	await get_tree().process_frame
	await get_tree().process_frame

	await _case_baseline_reads_unmuted()
	await _case_music_off_reads_muted()
	await _case_press_opens_sound()
	await _case_press_mutes_without_touching_preference()
	await _case_ui_sound_only_is_not_muted()

	_restore()
	SfxService.shutdown()
	MusicService.shutdown()
	_h.finish(get_tree())


# --- 1. 基线：开关全开 → 「静音」（正对照）-----------------------------------

func _case_baseline_reads_unmuted() -> void:
	_apply_prefs(true, true, false)
	var prep := await _new_prep()
	if prep == null:
		return
	_h.expect(_label(prep) == "静音", "baseline_not_muted",
		"开关全开、总线没静音，键上写的却是「%s」（应为「静音」）—— 少了这条正对照，"
			% _label(prep)
			+ "下面所有「已静音」的断言都可能只是恒真")
	await _free_prep(prep)


# --- 2. 主断言：大厅关了背景音乐 → 进对局显示「已静音」-----------------------

func _case_music_off_reads_muted() -> void:
	# 按真实路径来：先在「设置页」关掉背景音乐（写进落盘偏好），**然后**才进备战页。
	_apply_prefs(false, true, false)
	var prep := await _new_prep()
	if prep == null:
		return
	_h.expect(not Presentation.music_allowed(), "music_off_precondition_failed",
		"夹具把『背景音乐』关掉了，music_allowed() 却是 true —— 下面的断言无从谈起")
	_h.expect(_label(prep) == "已静音", "music_off_shows_unmuted",
		"大厅设置里已关闭背景音乐，进对局键上写的还是「%s」—— 两处状态各说各话"
			% _label(prep))
	await _free_prep(prep)


# --- 3. 按一下 = 声音回来（挡「按了没反应」）---------------------------------

func _case_press_opens_sound() -> void:
	_apply_prefs(false, true, false)
	var prep := await _new_prep()
	if prep == null:
		return
	if not _h.expect(_label(prep) == "已静音", "press_case_precondition_failed",
			"按之前键上写的不是「已静音」（实际「%s」），这一条测不到要测的东西"
				% _label(prep)):
		await _free_prep(prep)
		return

	_tap(prep)
	_h.expect(Presentation.music_allowed(), "press_did_not_reopen_music",
		"键上写着「已静音」时按下去，『背景音乐』开关仍然是关的 —— "
			+ "9.17 反馈第 5 条要的正是这条路径能把音乐重新打开")
	_h.expect(not _bus_muted(), "press_left_bus_muted",
		"按下去之后 Master 总线仍处于静音")
	_h.expect(_label(prep) == "静音", "press_label_did_not_flip",
		"按了一下之后键上写的还是「%s」（应为「静音」）—— 按了像没反应"
			% _label(prep))
	await _free_prep(prep)


# --- 4. 再按一下：只掐总线，不动玩家偏好 ------------------------------------

func _case_press_mutes_without_touching_preference() -> void:
	_apply_prefs(true, true, false)
	var prep := await _new_prep()
	if prep == null:
		return

	_tap(prep)
	_h.expect(_bus_muted(), "press_did_not_mute",
		"开关全开时按一下静音键，Master 总线没有静音")
	_h.expect(_label(prep) == "已静音", "muted_label_wrong",
		"总线已静音，键上写的却是「%s」（应为「已静音」）" % _label(prep))
	_h.expect(Presentation.music_allowed(), "muting_touched_music_preference",
		"按『静音』把玩家的『背景音乐』偏好也关掉了 —— 那是设置页的事，"
			+ "这个键只该掐总线（关偏好会让下次进对局凭空少一首 BGM）")

	# 再按一下回到有声：一次按键翻一次状态，没有「要按两下」的中间态。
	_tap(prep)
	_h.expect(not _bus_muted(), "second_press_did_not_unmute",
		"再按一下没有解除 Master 总线静音")
	_h.expect(_label(prep) == "静音", "unmuted_label_wrong",
		"解除静音后键上写的是「%s」（应为「静音」）" % _label(prep))
	await _free_prep(prep)


# --- 5. 范围：只关「界面音效」不算已静音 ------------------------------------

func _case_ui_sound_only_is_not_muted() -> void:
	# 界面音效只掐 SFX，BGM 照样响 —— 说成「已静音」是假话。
	_apply_prefs(true, false, false)
	var prep := await _new_prep()
	if prep == null:
		return
	_h.expect(not Presentation.ui_sound_allowed(), "ui_sound_off_precondition_failed",
		"夹具把『界面音效』关掉了，ui_sound_allowed() 却是 true")
	_h.expect(_label(prep) == "静音", "ui_sound_off_shown_as_muted",
		"只关了『界面音效』（BGM 还在响），键上却写「%s」—— "
			% _label(prep)
			+ "『已静音』指的是整个听不到声音，不是单掐音效")
	await _free_prep(prep)


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
	if not await _await_mute_button(prep):
		_h.expect(false, "mute_button_never_built",
			"等了 %d 帧，备战页右上角的静音键始终没建出来（_build_top_actions 没跑到？）"
				% BUILD_WAIT_FRAMES)
		return prep
	return prep


func _await_mute_button(prep: PrepScript) -> bool:
	for _i in BUILD_WAIT_FRAMES:
		if prep._mute_button != null:
			return true
		await get_tree().process_frame
	return false


# 读真按钮的真文案，不复制一份判据过来 —— 复制过来的判据只能证明它跟自己对得上。
func _label(prep: PrepScript) -> String:
	if prep._mute_button == null:
		return "<没有静音键>"
	return prep._mute_button.text


# 走真实连接（make_menu_button 里 btn.pressed.connect(on_press)），
# 不是直接调 _toggle_mute() —— 接线断了也要能被抓到。
func _tap(prep: PrepScript) -> void:
	if prep._mute_button == null:
		_h.expect(false, "mute_button_missing", "备战页右上角没有静音键，点击路径无从观测")
		return
	prep._mute_button.pressed.emit()


func _free_prep(prep: PrepScript) -> void:
	prep.queue_free()
	await _settle(3)


func _bus_muted() -> bool:
	var master := AudioServer.get_bus_index("Master")
	return AudioServer.is_bus_mute(master) if master >= 0 else false


# PlayerProfile 是 autoload 实例，调用点集中在这两处就够（dynamic_call 的棘轮计数
# 是按**调用点**算的，散开写等于徒增棘轮）。
func _pref(key: String) -> bool:
	return bool(PlayerProfile.get_presentation_toggle(key))


func _set_pref(key: String, value: bool) -> void:
	PlayerProfile.set_presentation_toggle(key, value)


func _apply_prefs(music_on: bool, ui_sound_on: bool, bus_muted: bool) -> void:
	_set_pref("music", music_on)
	_set_pref("ui_sound", ui_sound_on)
	var master := AudioServer.get_bus_index("Master")
	if master >= 0:
		AudioServer.set_bus_mute(master, bus_muted)


func _restore() -> void:
	_set_pref("music", _music_before)
	_set_pref("ui_sound", _ui_sound_before)
	var master := AudioServer.get_bus_index("Master")
	if master >= 0:
		AudioServer.set_bus_mute(master, _master_mute_before)


func _settle(frames: int = 4) -> void:
	for _i in frames:
		await get_tree().process_frame
