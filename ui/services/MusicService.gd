extends RefCounted

# 全局 BGM 服务（9.17 音效/BGM 接入批次 · 第二批）。
#
# ## 为什么必须有它
#
# 第一批的 BGM 是各页面自己建 AudioStreamPlayer（MainMenu / PrepScreen /
# BattleUI / Team3v3Lobby 各一份）。那套能响，但有一个结构性问题：
# `Main._clear()` 每次切页面都会 `remove_child + queue_free` 掉**整个页面子树**，
# 而播放器就挂在页面里 —— 于是「主菜单打开图鉴/聊天/朋友/设置，菜单 BGM 就断」。
# 9.17 反馈第 2 条要的正是「打开这些功能时不暂停 BGM」。
#
# 把它挪到 root 下（与 SfxService 同款：不做 autoload，`Main._ready()` 调一次
# `install()`，播放器延迟挂载）就自然解决了：BGM 不再属于任何一页。
#
# ## 顺带把「音乐开关」和「商城独立 BGM」收进同一处
#
# BGM 现在只有一个播放器、一个当前曲目，于是：
#   * 设置页的音乐开关只需要在这里落一次裁决（`Presentation.music_allowed()`），
#     不用去追四个页面各自的播放器；
#   * 商城要独立 BGM 就只是「进商城时 play(shop_music)，回主菜单时 play(menu_music)」，
#     不需要在 ShopScreen 里再搭一套播放器。
#
# ## 「同一首歌不重启」
#
# `play(path)` 在 `path == _path` 时直接返回。主菜单返回主菜单、子界面返回主菜单
# 都会再调一次 `play(menu_music)`，若不判等就会每次返回都从 0 秒重头播 ——
# 那是比「没有 BGM」更明显的一个 bug。
#
# ## 循环标志
#
# BGM 一律 `loop = true`（这一点与 SfxService 相反，那边一律关）。
# 改过的 AudioStream 实例不会回写资源缓存，所以 `_streams` 存一份。
# 照 MainMenu 原实现的先例：只对 AudioStreamMP3 设 loop。

const Presentation := preload("res://effects/runtime/presentation/PresentationSettings.gd")

const LifecyclePlayer := preload("res://ui/services/MusicPlayer.gd")

const PLAYER_NAME := "GloryMusicPlayer"

# ---------------------------------------------------------------------------
# BGM 曲目表（11.16 换新音乐）。所有页面都从这里取路径，不再各写各的常量。
#
# 「组」= 同一个界面的几首候选，进界面时随机挑一首（见 play_group）。
# 单曲的界面也写成只有一首的组，调用方式统一。
# 原中文文件名 → 英文名的对照见 docs/11.16背景音乐替换记录.md。
# ---------------------------------------------------------------------------
# 主菜单 / 大厅 / 排位组队房 / 自定义 3v3 房间 / 玩家资料等（主界面 1~3）
const MENU_GROUP: Array[String] = [
	"res://assets/audio/bgm/menu_1.mp3",
	"res://assets/audio/bgm/menu_2.mp3",
	"res://assets/audio/bgm/menu_3.mp3",
]
# 图鉴
const CODEX_MUSIC := "res://assets/audio/bgm/codex.mp3"
# 备战界面（主菜单「备战」按钮进入的 PetScreen）
const PREP_LOBBY_MUSIC := "res://assets/audio/bgm/prep_lobby.mp3"
# 商城
const SHOP_MUSIC := "res://assets/audio/bgm/shop.mp3"
# 摆放界面（对局内摆棋子），下一回合是 PvE（摆放界面 1~3）
const PLACEMENT_GROUP: Array[String] = [
	"res://assets/audio/bgm/placement_1.mp3",
	"res://assets/audio/bgm/placement_2.mp3",
	"res://assets/audio/bgm/placement_3.mp3",
]
# 摆放界面，下一回合是 PvP / 最终战
const PLACEMENT_PVP_MUSIC := "res://assets/audio/bgm/placement_pvp.mp3"
# 战斗 PvE / Boss（战斗演示 1~2）
const BATTLE_PVE_GROUP: Array[String] = [
	"res://assets/audio/bgm/battle_pve_1.mp3",
	"res://assets/audio/bgm/battle_pve_2.mp3",
]
# 战斗 PvP / 最终战
const BATTLE_PVP_MUSIC := "res://assets/audio/bgm/battle_pvp.mp3"
# 抽宠物 / 暗夜祈愿 / 樱花祈愿（盖在商城上的弹窗，关掉后接回商城那首）
const PET_DRAW_MUSIC := "res://assets/audio/bgm/pet_draw.mp3"
const WISH_DARK_MUSIC := "res://assets/audio/bgm/wish_dark.mp3"
const WISH_SAKURA_MUSIC := "res://assets/audio/bgm/wish_sakura.mp3"
# 整局最终结算的「详情页」（FinalSettlementPanel，只在对局刚结束时放；历史回看不放）
const RESULT_VICTORY_MUSIC := "res://assets/audio/bgm/result_victory.mp3"
const RESULT_DEFEAT_MUSIC := "res://assets/audio/bgm/result_defeat.mp3"

# path -> AudioStream（已把 loop 打开的那种）
static var _streams: Dictionary = {}
static var _player: AudioStreamPlayer
static var _path := ""
static var _installed := false
# BGM 的**基础电平**（线性）。默认 1.0 = 满。
#
# 10-21 加：用户实测「战斗时 BGM 太响，完全盖住普攻音」。根因是结构性的 ——
# 音频总线只有 Master + SFX 两条且**两条都是 0 dB**，而 BGM 落在 Master
# 也是 1.0 线性；普攻音 cue 配平 −3~−7 dB 再叠归属 −2~−6 dB，净下来比 BGM
# 低 7~9 dB（振幅 2~3 倍差）⇒ 短促的打击声必然被连续 BGM 盖住。
#
# 正解不是把音效一路往上顶（会整体过载），而是**在对局里把 BGM 压下来**：
# 战斗期间 `set_base_linear(0.5)`（−6 dB），离开战斗恢复 1.0。
#
# ⚠️ 与语音 duck **必须是乘法关系**（见 `_sync_voice_volume`），
#    否则两处各写各的 `volume_linear`，后写的那次会覆盖前者。
static var _base_linear := 1.0
# 「下一帧再同步一次」是否已经约过（见 _retry_sync_next_frame）。
static var _retry_queued := false
# 语音压低 BGM 的**额外判据源**（10.10）。对局 / 自定义房间的语音走 VoiceService
# （autoload），本服务本来就认；但**排位房**用的是 PartyLobby 自己的 PartyVoice 节点
# （自带 mode 与开关，从不写 VoiceService.mode）⇒ 排位房开麦时 BGM 一直不降。
# 由 PartyLobby 在 _ready 注册一个「现在是否在通话」的探针，离开页面时清掉。
static var _talk_probe: Callable = Callable()
static var _application_suspended := false
static var _resume_position := 0.0
static var _resume_path := ""
# 11.16：「回到同一首歌时接着放，不从头」。
# path -> 上次离开这首时放到的秒数。只在 play(path, true) 时才会被用上。
static var _positions: Dictionary = {}
# 组的第一条路径 -> 这个组上次挑中的那首（play_group(resume=true) 回到同一首用）。
static var _group_last: Dictionary = {}
# 下一次真正开播时从第几秒开始（play() 换曲时写，_sync() 开播时消费）。
static var _pending_start := 0.0
# 11.18：「整局固定一首」。begin_match() 起、end_match() 止算一局。
# 组的第一条路径 -> 本局挑中的那首（摆放界面组 / PvE 战斗组）。只存内存，闪退重连后重新挑。
static var _in_match := false
static var _match_picks: Dictionary = {}


# 由 Main._ready() 调一次，幂等。
#
# `play()` 在没装的情况下也会自己把播放器补上，所以「Main 忘了调」的最坏后果
# 是设置页音乐开关的即时生效少了自动重放，不是整条 BGM 静音。
static func install() -> void:
	_ensure_player()
	if not _installed:
		if is_instance_valid(PlayerProfile) \
				and not PlayerProfile.presentation_settings_changed.is_connected(_on_settings_changed):
			PlayerProfile.presentation_settings_changed.connect(_on_settings_changed)
		_installed = true
	_sync()


static func is_installed() -> bool:
	return _installed


# 播一首 BGM。**同一首重复调用是 no-op**（见文件头「同一首歌不重启」）。
#
# resume = true：这首以前放过的话，从上次离开时的位置接着放（11.16）。
# 默认 false = 从头放，与原行为一致。
static func play(path: String, resume := false) -> void:
	if path.is_empty():
		return
	_ensure_player()
	if _player == null:
		return
	if path == _path:
		# 曲目没变，只保证「该出声时在出声」（开关可能刚被打开）。
		_sync()
		return
	var stream := _stream_for(path)
	if stream == null:
		return
	_remember_position()
	_path = path
	_pending_start = _resume_offset(path, stream) if resume else 0.0
	# 先停再换：保证 _sync() 走「没在放 → play(起点)」那一支，起点才生效。
	if is_instance_valid(_player):
		_player.stop()
	_player.stream = stream
	_sync()


# 播一组里的某一首（11.16「有 1~3 首的界面随机播放」）。
#
# * 正在放的已经是这组里的一首 → 什么都不做，接着放（不换歌、不从头）。
#   这条保证「房间 → 主菜单 → 玩家资料」一路不断、不重来。
# * resume = true 且这组以前挑过一首 → 回到那一首、从离开的位置接着放
#   （从商城 / 备战 / 图鉴回主菜单）。
# * 否则随机挑一首，从头放。打完一局回来的那次走这里（begin_match 清掉了记录）。
static func play_group(paths: Array, resume := false) -> void:
	if paths.is_empty():
		return
	if _path in paths:
		_sync()
		return
	var key := str(paths[0])
	var pick := ""
	if resume and _group_last.has(key) and str(_group_last[key]) in paths:
		pick = str(_group_last[key])
	else:
		pick = str(paths[randi() % paths.size()])
		# 新挑的这首一律从头放，不吃以前留下的位置。
		_positions.erase(pick)
	_group_last[key] = pick
	play(pick, resume)


# 盖在页面上的弹窗（抽宠物 / 皮肤祈愿）开始放自己的歌。返回原来那首，关窗时还给 leave_overlay。
static func enter_overlay(path: String) -> String:
	var previous := _path
	play(path)
	return previous


# 弹窗关掉：如果还在放弹窗那首，就接回原来那首、从原来的位置接着放。
# 已经被别的页面换掉了（比如弹窗随整页一起被清掉、主菜单已经起了自己的歌）就不动。
static func leave_overlay(path: String, previous: String) -> void:
	if _path != path:
		return
	if previous.is_empty():
		stop()
		return
	play(previous, true)


# 播本局固定的那一首（11.18：摆放界面 / PvE 战斗「开局随机一次，整场同一首」）。
#
# * 本局第一次调这个组 → 随机挑一首记下；之后同一局一直是它。
# * 每次进来都**从头放**（用户要求）：摆放 ↔ 战斗交替换曲时，回到这首从 0 秒开始。
#   正在放的就是它（同一回合重建摆放页）→ 不打断。
static func play_match_group(paths: Array) -> void:
	if paths.is_empty():
		return
	var key := str(paths[0])
	var pick := str(_match_picks.get(key, ""))
	if not (pick in paths):
		pick = str(paths[randi() % paths.size()])
		_match_picks[key] = pick
	play(pick)


# 进入一局（摆放界面每回合都会调，只有本局第一次生效）：
# 清掉大厅那些「接着放」的记录和上一局的选曲。打完回大厅重新随机主菜单那首。
static func begin_match() -> void:
	if _in_match:
		return
	_in_match = true
	_positions.clear()
	_group_last.clear()
	_match_picks.clear()


# 回到大厅（主菜单 / 排位组队房 / 自定义 3v3 房间）= 这局结束。下一次 begin_match() 是新的一局。
# 正常打完、投降、掉线退回大厅都会走到这里。
static func end_match() -> void:
	_in_match = false
	_match_picks.clear()


# 停掉 BGM 并清掉当前曲目。下一次 play() 会从头开始（不是 resume）。
static func stop() -> void:
	_remember_position()
	_path = ""
	_pending_start = 0.0
	if _player != null and is_instance_valid(_player):
		_player.stop()


# 记下当前这首放到第几秒（换曲 / 停之前调）。
static func _remember_position() -> void:
	if _path.is_empty() or _player == null or not is_instance_valid(_player):
		return
	if _player.playing or _player.stream_paused:
		_positions[_path] = _player.get_playback_position()


static func _resume_offset(path: String, stream: AudioStream) -> float:
	var pos := float(_positions.get(path, 0.0))
	var length := stream.get_length()
	if length > 0.0:
		pos = fmod(pos, length)
	return maxf(pos, 0.0)


static func current_path() -> String:
	return _path


static func is_playing() -> bool:
	return _player != null and is_instance_valid(_player) and _player.playing


# 当前 BGM 是否应该出声。**只问这一处** —— 与 SfxService 的 ui_sound_allowed()
# 同款设计：裁决不散到各调用点，否则「关了但某个页面还在响」迟早出现。
static func _allowed() -> bool:
	return Presentation.music_allowed()


# --- 内部 -------------------------------------------------------------------

static func _on_application_suspended() -> void:
	if _application_suspended:
		return
	_application_suspended = true
	_resume_path = _path
	_resume_position = _player.get_playback_position() if is_playing() else 0.0
	if is_instance_valid(_player):
		_player.stream_paused = true


static func _on_application_resumed() -> void:
	if not _application_suspended:
		return
	_application_suspended = false
	if is_instance_valid(_player) and not _path.is_empty() and _allowed():
		# playing can remain true while the old platform playback is silent.
		# Recreate playback only on a real lifecycle transition, keeping position.
		_player.stream_paused = false
		_player.play(_resume_position if _resume_path == _path else 0.0)
	_sync()
	_sync_voice_volume()
	if OS.has_feature("ios") and is_instance_valid(_player):
		NetworkService._net_log("music resumed playing=%s paused=%s allowed=%s position=%.2f" % [
			str(_player.playing), str(_player.stream_paused), str(_allowed()), _player.get_playback_position()])


static func _on_settings_changed() -> void:
	_sync()
	_sync_voice_volume()


# 让播放状态追上开关：开着就播、关了就暂停。
#
# 用 `stream_paused` 而不是 `stop()`：关开关再打开要接着原来的位置播，
# 从 0 秒重来听感上是「切了一首歌」。没在播的时候设 stream_paused 是无害的。
static func _sync() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	if _path.is_empty():
		return
	# **「在树里」这一条不能省。**
	#
	# 播放器是延迟挂载的（见 _ensure_player），所以存在「节点已建好但还没进树」
	# 的一帧窗口。对没进树的播放器调 play() 会打印
	# "Playback can only happen when a node is inside the scene tree" 并**静默失败**
	# —— 也就是说调用方以为响了、其实没有。这里挡掉，并约下一帧再同步一次。
	if not _player.is_inside_tree():
		_retry_sync_next_frame()
		return
	# Apply user gain before starting/restarting playback, including a saved 0%.
	_sync_voice_volume()
	var want := _allowed() and not _application_suspended
	_player.stream_paused = not want
	if want and not _player.playing:
		_player.play(_pending_start)
		_pending_start = 0.0


# 下一帧再 _sync() 一次（一次性连接，不会积压）。
#
# 这条路径在门禁里会真的走到：`tools/prep_tree_snapshot` 直接实例化 PrepScreen，
# 而它 `_ready()` 里的 `MusicService.play()` 与 `_ensure_player()` 的
# `add_child.call_deferred()` 在同一帧 —— 不补这一下，日志里就会留下
# "Playback can only happen when a node is inside the scene tree"，且 BGM 不响。
static func _retry_sync_next_frame() -> void:
	if _retry_queued:
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return
	_retry_queued = true
	tree.process_frame.connect(_on_retry_sync, CONNECT_ONE_SHOT)


static func _on_retry_sync() -> void:
	_retry_queued = false
	_sync()


static func _stream_for(path: String) -> AudioStream:
	if _streams.has(path):
		return _streams[path]
	var stream := load(path) as AudioStream
	if stream == null:
		push_warning("MusicService: BGM 读取失败 %s" % path)
		return null
	# 与各页面原实现一致：只对 AudioStreamMP3 打开 loop。
	# 显式打开而不是依赖导入预设 —— 关了 loop 的 BGM 播一遍就静了。
	if stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = true
	_streams[path] = stream
	return stream


# 注册 / 注销「额外语音判据」。探针返回 true 表示当前正在通话（应压低 BGM）。
# 只允许一个来源注册一次：排位房页面进树时注册、出树时清除。
static func set_talk_probe(probe: Callable) -> void:
	_talk_probe = probe


static func clear_talk_probe() -> void:
	_talk_probe = Callable()


# 对局 / 自定义房间的语音判据：VoiceService 处于通话态、已连上、麦克风在录。
static func _voice_service_talking() -> bool:
	var voice := VoiceService.status()
	return VoiceService.mode == VoiceService.Mode.TALK \
		and str(voice.get("state", "")) == "connected" and bool(voice.get("mic_on", false))


# Only the music player is attenuated; never the Master bus or remote voices.
# Native status confirms capture actually started (permission/publish may fail).
#
# ★ 两个因素**相乘**，不互相覆盖：基础电平（战斗压低）× 语音 duck。
static func _sync_voice_volume() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	var talking := _voice_service_talking()
	if not talking and _talk_probe.is_valid():
		talking = bool(_talk_probe.call())
	var duck := (1.0 / 6.0) if talking else 1.0
	_player.volume_linear = _base_linear * duck * Presentation.music_volume()


# BGM 基础电平（线性）。战斗里传 0.5，退出战斗传 1.0。
#
# **只影响 BGM 自己**，不动 Master 也不动 SFX 总线 —— 语音 duck 仍然叠在上面。
# 传 0 会静音（留给将来「BGM 音量滑杆」用），负数按 0 夹。
static func set_base_linear(value: float) -> void:
	_base_linear = clampf(value, 0.0, 2.0)
	_sync_voice_volume()


# 当前基础电平。给门禁与排障用（能断言「进战斗确实压了、退战斗确实还原」）。
static func base_linear() -> float:
	return _base_linear


# 建播放器。**挂载一律走 `add_child.call_deferred`** —— 同 SfxService：
# `install()` 的时机正撞在 root 装配子节点的窗口里，同步 add_child 会静默失败。
static func _ensure_player() -> bool:
	var voice_tree := Engine.get_main_loop() as SceneTree
	if voice_tree != null and not voice_tree.process_frame.is_connected(_sync_voice_volume):
		voice_tree.process_frame.connect(_sync_voice_volume)
	if _player != null and is_instance_valid(_player):
		# Reuse a player whose deferred add_child has not run yet. Multiple
		# scene requests in one frame must not create competing BGM players.
		return _player.is_inside_tree()
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return false
	var existing := tree.root.get_node_or_null(PLAYER_NAME) as AudioStreamPlayer
	if existing != null and is_instance_valid(existing):
		_player = existing
		return true
	var player := LifecyclePlayer.new()
	player.application_suspended.connect(_on_application_suspended)
	player.application_resumed.connect(_on_application_resumed)
	player.name = PLAYER_NAME
	# 与四个页面原实现同款：有 Music 总线就走它，没有就落 Master。
	# **本批不新增 Music 总线**（`ui_feedback_check.music_bus_added_silently` 钉着）。
	player.bus = "Music" if AudioServer.get_bus_index("Music") >= 0 else "Master"
	# 页面切换、暂停都不该把 BGM 掐断（同 SfxService 的播放器）。
	player.process_mode = Node.PROCESS_MODE_ALWAYS
	tree.root.add_child.call_deferred(player)
	_player = player
	return true


# --- 门禁接缝 ---------------------------------------------------------------

# 收尾用：只给 headless 检查。产品运行时不调（服务是常驻的）。
static func shutdown() -> void:
	if _installed and is_instance_valid(PlayerProfile) \
			and PlayerProfile.presentation_settings_changed.is_connected(_on_settings_changed):
		PlayerProfile.presentation_settings_changed.disconnect(_on_settings_changed)
	_installed = false
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null and tree.process_frame.is_connected(_on_retry_sync):
		tree.process_frame.disconnect(_on_retry_sync)
	_retry_queued = false
	if tree != null and tree.process_frame.is_connected(_sync_voice_volume):
		tree.process_frame.disconnect(_sync_voice_volume)
	if _player != null and is_instance_valid(_player):
		_player.stop()
		_player.free()
	_player = null
	_path = ""
	_application_suspended = false
	_resume_position = 0.0
	_resume_path = ""
	_positions.clear()
	_group_last.clear()
	_pending_start = 0.0
	_in_match = false
	_match_picks.clear()
	_streams.clear()


# 播放器是不是已经挂进树了。门禁必须先等到这里为 true 再断言，
# 否则测的是一个还没落地的播放器（同 SfxService.voices_ready 的理由）。
static func player_ready() -> bool:
	if not _ensure_player():
		return false
	return _player != null and is_instance_valid(_player) and _player.is_inside_tree()
