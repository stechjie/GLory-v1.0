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

const PLAYER_NAME := "GloryMusicPlayer"

# path -> AudioStream（已把 loop 打开的那种）
static var _streams: Dictionary = {}
static var _player: AudioStreamPlayer
static var _path := ""
static var _installed := false
# 「下一帧再同步一次」是否已经约过（见 _retry_sync_next_frame）。
static var _retry_queued := false


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
static func play(path: String) -> void:
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
	_path = path
	_player.stream = stream
	_sync()


# 停掉 BGM 并清掉当前曲目。下一次 play() 会从头开始（不是 resume）。
static func stop() -> void:
	_path = ""
	if _player != null and is_instance_valid(_player):
		_player.stop()


static func current_path() -> String:
	return _path


static func is_playing() -> bool:
	return _player != null and is_instance_valid(_player) and _player.playing


# 当前 BGM 是否应该出声。**只问这一处** —— 与 SfxService 的 ui_sound_allowed()
# 同款设计：裁决不散到各调用点，否则「关了但某个页面还在响」迟早出现。
static func _allowed() -> bool:
	return Presentation.music_allowed()


# --- 内部 -------------------------------------------------------------------

static func _on_settings_changed() -> void:
	_sync()


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
	var want := _allowed()
	_player.stream_paused = not want
	if want and not _player.playing:
		_player.play()


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


# 建播放器。**挂载一律走 `add_child.call_deferred`** —— 同 SfxService：
# `install()` 的时机正撞在 root 装配子节点的窗口里，同步 add_child 会静默失败。
static func _ensure_player() -> bool:
	if _player != null and is_instance_valid(_player) and _player.is_inside_tree():
		return true
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return false
	var existing := tree.root.get_node_or_null(PLAYER_NAME) as AudioStreamPlayer
	if existing != null and is_instance_valid(existing):
		_player = existing
		return true
	var player := AudioStreamPlayer.new()
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
	if _player != null and is_instance_valid(_player):
		_player.stop()
		_player.free()
	_player = null
	_path = ""
	_streams.clear()


# 播放器是不是已经挂进树了。门禁必须先等到这里为 true 再断言，
# 否则测的是一个还没落地的播放器（同 SfxService.voices_ready 的理由）。
static func player_ready() -> bool:
	if not _ensure_player():
		return false
	return _player != null and is_instance_valid(_player) and _player.is_inside_tree()
