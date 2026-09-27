extends Node

# 9.26 大厅宠物脚步声门禁。
#
# ## 这条门禁验什么
#
# **不验好不好听、也不验真机能听见**（headless 用 Dummy 音频驱动，烧坏了也听不出）。
# 它验的是「所有宠物独立播放、移动时发声、停下即静默」会被静默写错的那几件事：
#
#   1. cue 登记了 + 素材文件在 + 能被 load 成 AudioStream（否则运行时无声也无报错）；
#   2. 这条 cue 在生产代码里有调用点（MainMenuPet 引用 CUE_PET_FOOTSTEP 取路径），
#      否则它只是 SfxService 表里多一行、永远不响；
#   3. **脚步不走 SfxService 的共享播放器池** —— 源码里不得出现 `SfxService.play(`，
#      否则 5 只宠物同帧迈步会被 40ms 全局重触发保护 + 8 路上限吞掉，破坏独立性；
#   4. 每只宠物的播放器是**独立**的、且命名/挂法**不污染** audio_sfx_check 的
#      「播放器池 == 8」断言（名字不撞 GlorySfxVoice*，也不是 root 的子节点）；
#   5. 步频行为：行走时按 FOOTSTEP_INTERVAL 稳定发声、停下（state!=walk）一点都不响；
#   6. **独立性行为**：5 只宠物在同一个「帧」里同时跨过步频阈值，应当**各自**响一声
#      （这正是共享池做不到的，用纯静态 advance_footstep 直接驱动证明）；
#   7. 静音门：关掉「界面音效」时 _play_footstep 一声不响、也不记账。
#
# 运行：
#   Godot_v4.7.2-stable_win64_console.exe --headless --path . tools/pet_footstep_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const SfxService := preload("res://ui/services/SfxService.gd")
const MainMenuPet := preload("res://scenes/menu/MainMenuPet.gd")
const Presentation := preload("res://effects/runtime/presentation/PresentationSettings.gd")

const CHECK_NAME := "pet_footstep"

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_check_cue_and_file()
	_check_call_site()
	_check_independence_structure()
	_check_cadence()
	_check_simultaneous_independence()
	_check_mute_gate()
	_h.finish(get_tree())


# --- 1. cue 登记 + 素材文件 ---------------------------------------------------

func _check_cue_and_file() -> void:
	_h.expect(SfxService.cue_ids().has(SfxService.CUE_PET_FOOTSTEP),
		"cue_not_registered",
		"SfxService 里没有登记 CUE_PET_FOOTSTEP —— 脚步声根本找不到素材")
	var path := SfxService.cue_path(SfxService.CUE_PET_FOOTSTEP)
	_h.expect(not path.is_empty(), "cue_path_empty",
		"CUE_PET_FOOTSTEP 指向的路径为空")
	_h.expect(path.begins_with("res://assets/audio/sfx/"),
		"cue_path_outside_sfx_dir",
		"CUE_PET_FOOTSTEP 的路径不在 res://assets/audio/sfx/ 下：%s" % path)
	_h.expect(FileAccess.file_exists(path), "cue_file_missing",
		"脚步声素材文件不存在：%s" % path)
	var stream := load(path) as AudioStream
	_h.expect(stream != null, "cue_not_loadable",
		"脚步声素材读不出 AudioStream（没跑过 --import？）：%s" % path)
	# 整张 cue 表必须比上一轮多 1 条（75→76），防止「加 cue 忘了把计数同步到
	# audio_sfx_check」——那种情况下 audio_sfx_check 会红，但本门禁也该能自洽。
	_h.expect(SfxService.cue_ids().size() == 76, "cue_table_count_drift",
		"cue 表共 %d 条，预期 76（9.26 只新增了 1 条 pet_footstep）"
			% SfxService.cue_ids().size())


# --- 2. 生产调用点 ------------------------------------------------------------

# 与 audio_sfx_check 的「每条 cue 都要有人调」同源，这里专门钉 pet_footstep：
# MainMenuPet 必须真的引用 CUE_PET_FOOTSTEP（用它取路径），否则它就是死登记。
func _check_call_site() -> void:
	var src := _code_only(FileAccess.get_file_as_string(
		"res://scenes/menu/MainMenuPet.gd"))
	_h.expect(src.contains("SfxService.CUE_PET_FOOTSTEP"),
		"cue_without_call_site",
		"MainMenuPet.gd 里没有任何 SfxService.CUE_PET_FOOTSTEP 的引用 —— "
		+ "脚步声素材虽登记却永远不会被取用")
	# 脚步**必须**走各宠物独立播放器，不得经过 SfxService.play()。
	# 出现过就说明又接回了共享池，会破坏「所有宠物独立播放」。
	_h.expect(not src.contains("SfxService.play("),
		"footstep_routed_through_shared_pool",
		"MainMenuPet.gd 里出现了 SfxService.play( —— 脚步声若走共享池，"
		+ "多只宠物同帧迈步会被 40ms 重触发保护吞掉，破坏独立性")


# --- 3. 独立播放器的结构（不污染 audio_sfx_check 的播放器池断言）--------------

func _check_independence_structure() -> void:
	# 命名不撞 GlorySfxVoice*（audio_sfx_check 会数 root 下以它开头的节点并要求正好 8 个）。
	_h.expect(not MainMenuPet.FOOTSTEP_PLAYER_NAME.begins_with("GlorySfxVoice"),
		"player_name_collides_voice_pool",
		"%s 以 GlorySfxVoice 开头，会被 audio_sfx_check 数成第 9 个 voice"
			% MainMenuPet.FOOTSTEP_PLAYER_NAME)
	# 也不是那个唯一的循环播放器名。
	_h.expect(MainMenuPet.FOOTSTEP_PLAYER_NAME != str(SfxService.LOOP_PLAYER_NAME),
		"player_name_collides_loop_player",
		"%s 与循环播放器名 %s 撞名" % [MainMenuPet.FOOTSTEP_PLAYER_NAME,
			str(SfxService.LOOP_PLAYER_NAME)])
	var src := _code_only(FileAccess.get_file_as_string(
		"res://scenes/menu/MainMenuPet.gd"))
	# 播放器是 pet Node3D 的子节点（不是 root），这样它既不会进 voice 池计数，
	# 也会随宠物节点一起被释放。源码里必须有「node.add_child(footstep_player)」。
	_h.expect(src.contains("node.add_child(footstep_player)"),
		"player_not_child_of_pet_node",
		"脚步声播放器没有挂到 pet Node3D 下（node.add_child(footstep_player) 缺失）——"
		+ "若挂到 root 会污染 audio_sfx_check 的播放器池断言")
	_h.expect(src.contains("FOOTSTEP_PLAYER_NAME"),
		"player_name_not_parameterized",
		"脚步声播放器没有用 FOOTSTEP_PLAYER_NAME 命名，门禁无法静态核对命名")
	# 每宠物独立：源码里必须为 entry 字典写入 footstep_player（每只一个），
	# 而不是共享一个全局播放器。
	_h.expect(src.contains("\"footstep_player\": footstep_player"),
		"footstep_player_not_per_pet",
		"没有为每只宠物单独建一个脚步声播放器（entry 缺少 footstep_player 键）")


# --- 4. 步频行为：行走发声、停下静默 -----------------------------------------

func _check_cadence() -> void:
	var interval: float = MainMenuPet.FOOTSTEP_INTERVAL
	# 行走 3 个完整步频区间，应当响约 3 声（不是每帧都响，也不是不响）。
	# dt 取 interval/4：每 4 帧跨一个阈值，避开浮点累加在阈值上的 ±1 抖动。
	var walk := {"state": "walk", "footstep_accum": 0.0}
	var steps := 0
	var frames := 0
	var dt := interval / 4.0
	var total := 0.0
	while total < interval * 3.0:
		if MainMenuPet.advance_footstep(walk, dt):
			steps += 1
		total += dt
		frames += 1
	# 3 个区间预期约 3 声；范围放宽到 2~4 容忍浮点，但足以区分两种回归：
	# 永远不响（0，下限拦住）/ 每帧都响（==frames，上限 + 下面那条拦住）。
	_h.expect(steps >= 2 and steps <= 4, "walk_cadence_wrong",
		"行走 3 个步频区间只响了 %d 声（预期约 3，范围 2~4；共 %d 帧）" % [steps, frames])
	# 额外钉住「不是每帧都响」：触发次数必须远小于帧数，脚步声才有步频感。
	_h.expect(steps < frames, "footstep_every_frame",
		"行走 %d 帧里响了 %d 声 —— 几乎每帧都在响，脚步声没有步频限制" % [frames, steps])

	# 停下（state 不是 walk）无论喂多少 delta 都不该响一声。
	var idle := {"state": "idle", "footstep_accum": 0.0}
	var idle_steps := 0
	for _i in 200:
		if MainMenuPet.advance_footstep(idle, 0.1):
			idle_steps += 1
	_h.expect(idle_steps == 0, "idle_still_stepping",
		"状态为 idle 时响了 %d 声脚步 —— 停下时声音没消失" % idle_steps)
	# 停下一次后累计必须被清掉，下次起步不会立刻补一声"欠下的"。
	_h.expect(float(idle.footstep_accum) == 0.0, "idle_accum_not_reset",
		"idle 状态下 footstep_accum 没清零（=%s），下次起步会瞬间补一声"
			% str(idle.footstep_accum))


# --- 5. 独立性行为：多只同帧同时迈步，各自独立发声 -----------------------------

# 这是「所有宠物独立播放」最硬的一条判据：5 只宠物在**同一个帧**里同时跨过步频
# 阈值，应当各自响一声（5 声全响）。共享池（40ms 全局保护 + 8 路上限）下只会响 1 声。
func _check_simultaneous_independence() -> void:
	var pets: Array[Dictionary] = []
	for i in 5:
		# 故意让每只都停在「差一脚就跨过阈值」的位置，然后同一个 dt 一起跨过去。
		pets.append({"state": "walk",
			"footstep_accum": MainMenuPet.FOOTSTEP_INTERVAL - 0.01})
	var hits := 0
	for p in pets:
		if MainMenuPet.advance_footstep(p, 0.02):
			hits += 1
	_h.expect(hits == 5, "simultaneous_steps_not_independent",
		"5 只宠物同帧同时迈步只响了 %d 声（应为 5）—— 脚步没有各自独立播放，接入共享池就会是这个结果" % hits)


# --- 6. 静音门 ----------------------------------------------------------------

# 复刻 audio_sfx_check 的「摆好前置条件 + 收尾还原磁盘」做法：
# ui_sound 是落盘持久化的，门禁不能给下一跑留状态。
func _check_mute_gate() -> void:
	# 构造一个最小可播环境：Node3D 挂一个真实 AudioStreamPlayer，进树。
	var holder := Node3D.new()
	add_child(holder)
	var player := AudioStreamPlayer.new()
	player.name = MainMenuPet.FOOTSTEP_PLAYER_NAME
	player.bus = "SFX" if AudioServer.get_bus_index("SFX") >= 0 else "Master"
	player.stream = load(SfxService.cue_path(SfxService.CUE_PET_FOOTSTEP)) as AudioStream
	holder.add_child(player)

	# 需要一只 MainMenuPet 实例来调它的 _play_footstep（纯实例方法，不依赖 _ready）。
	var mm = MainMenuPet.new()
	var entry := {"footstep_player": player, "state": "walk", "footstep_accum": 0.0}

	var master := AudioServer.get_bus_index("Master")
	var mute_before: bool = AudioServer.is_bus_mute(master) if master >= 0 else false
	var disk_state := _snapshot_profile_file()

	# 前置：开关开 + Master 不静音。
	PlayerProfile.set_presentation_toggle("ui_sound", true)
	if master >= 0:
		AudioServer.set_bus_mute(master, false)
	_h.expect(Presentation.ui_sound_allowed(), "ui_sound_precondition_failed",
		"开关开着 + Master 没静音，ui_sound_allowed() 却是 false，下面无从断言")

	# 开关开着：应当真的播出来（player.playing 变 true）。
	player.stop()
	mm._play_footstep(entry)
	_h.expect(player.playing, "unmuted_footstep_not_played",
		"界面音效开着，_play_footstep 却没让播放器播起来（素材没导入？没进树？）")

	# 对照组：关掉开关，同一帧再调，一声都不该出。
	PlayerProfile.set_presentation_toggle("ui_sound", false)
	player.stop()
	mm._play_footstep(entry)
	_h.expect(not player.playing, "muted_footstep_still_played",
		"界面音效已关，_play_footstep 仍然让播放器响了起来")

	# 收尾：摆回「开」+ 还原磁盘（同 audio_sfx_check 的教训，否则下一跑自锁）。
	PlayerProfile.set_presentation_toggle("ui_sound", true)
	if master >= 0:
		AudioServer.set_bus_mute(master, mute_before)
	_h.expect(_restore_profile_file(disk_state), "profile_restore_failed",
		"收尾没能把 profile.json 还原成跑之前的字节 —— 下一跑前置条件不再可控")
	mm.free()
	holder.free()


# --- 工具 -------------------------------------------------------------------

func _code_only(source: String) -> String:
	var out: Array[String] = []
	for raw in source.split("\n"):
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


func _snapshot_profile_file() -> Dictionary:
	var path := _profile_path()
	if path.is_empty():
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var bytes := f.get_buffer(f.get_length())
	f.close()
	return {"path": path, "bytes": bytes}


func _restore_profile_file(snap: Dictionary) -> bool:
	if snap.is_empty():
		return true
	var path := str(snap.get("path", ""))
	if path.is_empty():
		return true
	var bytes: PackedByteArray = snap.get("bytes", PackedByteArray())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(bytes)
	f.close()
	return true


func _profile_path() -> String:
	return ProjectSettings.globalize_path(str(PlayerProfile.PROFILE_PATH))
