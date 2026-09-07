class_name UiFeedback
extends RefCounted

# V3 P1-04：按钮的确认音与触觉。
#
# **今天这条通道是静音的**，而且是故意的：仓里一个 UI 音效素材都没有
# （`assets/audio/` 只有 5 首 BGM 和一个从未被播放的 `ui/start_game.mp3`），
# 音频许可本身还是未闭环的 blocker（`third-party-license-ledger`）。
# 编一个音效放进去比没有更糟——它会让「音效已完成」这句话变成假的。
# 所以本批只搭管线：把 CONFIRM_SFX_PATH 填上一个真实文件就会响，不用改代码。
#
# 不做 autoload。冷启动 T3 实测 8730–8890 ms（预算 ≤3 s）是未闭环 blocker，
# 而 autoload 全部在第一个场景之前构造，条条都在那段关键路径上。这里的
# AudioStreamPlayer 是**首次真正要播的时候**才创建，挂到 get_tree().root——
# 挂在页面下会被 Main._clear() 中途释放，声音播一半没了。
#
# ## 一次点击只发一次，靠的是锚点，不是事后去重
#
# 确认音只接 AsyncActionController.action_resolved：那个信号每个 request_id
# 只发一次，而且它不是输入驱动的，天然与 mouse/touch 双路无关。
# **绝不能挂 _input() / _unhandled_input()**——PrepScreen._input() 就是现成的
# 反例：它用 if/elif 同时处理 InputEventMouseButton 与 InputEventScreenTouch
# 且没有去重。今天无害（关面板是幂等的），挂上音效立刻变成响两次，
# 而且**在 Windows 上看不出来**：桌面只会来鼠标那一路。
# 这条规则由门禁的源码合同守着，不靠人记。

const Presentation := preload("res://effects/runtime/presentation/PresentationSettings.gd")
const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Toast := preload("res://ui/components/GloryToast.gd")

# 播放器所在的总线。default_bus_layout.tres 里只有 Master 和 SFX 两条。
#
# **刻意没有加 Music 总线**：四处 BGM 代码都写着
# `bus = "Music" if get_bus_index("Music") >= 0 else "Master"`，那个分支今天
# 永远走 false。加一条 Music 总线会让这四处**同时**改走一条从没调过音量的
# 总线——在一个标题写着「按钮反馈」的提交里偷偷改掉线上 BGM 的路由。
# BGM 归并是独立的一件事，值得单独评估。
const SFX_BUS := "SFX"

# 确认音资源。空 = 静音。填一个真实文件进来即可生效。
const CONFIRM_SFX_PATH := ""

const PLAYER_NAME := "GloryUiSfx"

# 门禁用的计数。**在裁决通过之后才 +1**——可断言的是「该不该播」，
# 而不是「有没有人调用过」。
static var _confirm_requests := 0
static var _vibrate_calls := 0

# 轻触觉：确认用的一下极短的点触；拒绝用稍长一点，让它和确认区分得开。
const HAPTIC_CONFIRM_MS := 12
const HAPTIC_REJECT_MS := 26


# 接上 AsyncActionController。由 Main._ready() 调一次，幂等。
#
# 不做成 autoload 的代价就是要有人来调这一句；换来的是它不占冷启动的
# 关键路径（T3 实测 8730–8890 ms、预算 ≤3 s，是未闭环 blocker）。
# 「Main 确实调了」这半条由门禁的源码合同守着。
static func install() -> void:
	if AsyncActionController.action_resolved.is_connected(_on_action_resolved):
		return
	AsyncActionController.action_resolved.connect(_on_action_resolved)


static func _on_action_resolved(_action: String, _request_id: String, state: String,
		_snapshot: Dictionary) -> void:
	if state != AsyncActionController.STATE_SUCCEEDED:
		return
	play_confirm()


# 业务成功后的确认反馈。唯一的生产调用点是上面那个 _on_action_resolved，
# 不要在按钮上逐个挂 —— 逐个挂就等于把「只发一次」的保证交给每一个调用点。
static func play_confirm() -> void:
	if not Presentation.ui_sound_allowed():
		return
	_confirm_requests += 1
	_play(CONFIRM_SFX_PATH)
	vibrate(HAPTIC_CONFIRM_MS)


static func _play(path: String) -> void:
	if path.is_empty():
		return  # 今天到此为止：没有素材，说清楚比编一个好
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return
	var player := tree.root.get_node_or_null(PLAYER_NAME) as AudioStreamPlayer
	if player == null or not is_instance_valid(player):
		player = AudioStreamPlayer.new()
		player.name = PLAYER_NAME
		player.bus = SFX_BUS if AudioServer.get_bus_index(SFX_BUS) >= 0 else "Master"
		# 页面切换、暂停都不该把提示音掐断。
		player.process_mode = Node.PROCESS_MODE_ALWAYS
		tree.root.add_child(player)
	var stream := load(path) as AudioStream
	if stream == null:
		return
	player.stream = stream
	player.play()


# 触觉。桌面上 Input.vibrate_handheld() 本身就是 no-op，但明确挡在这里，
# 门禁才能断言「桌面一次都没调用」，而不是依赖引擎碰巧不做事。
static func vibrate(ms: int) -> void:
	if ms <= 0 or not Presentation.haptics_allowed():
		return
	_vibrate_calls += 1
	# 振幅交给系统默认：在一台没测过的设备上猜一个数值只会更糟。
	Input.vibrate_handheld(ms)


# --- 拒绝动作 ---------------------------------------------------------------

# 短促抖动的幅度（弧度）与时长。0.03 rad 在一个 56px 高的按钮上大约是
# 边缘位移 1.5px 左右——看得出来「它动了一下」，又不至于像坏掉。
const SHAKE_RAD := 0.03
const SHAKE_SEC := 0.24

# 正在抖的控件的原始变换，按 instance id 记账。
# 重入时**取回存下来的原值**，绝不拿抖到一半的当前值当原值——那会让控件
# 每被拒绝一次就歪一点，连点几次以后永久斜着。
static var _shake_originals := {}


# 拒绝一个动作：说明原因 + 抖一下 + 稍长一点的震动。
#
# **toast 和 shake 是两条独立通道，不能互相顶替。** 抖动是吸引注意力的，
# 关掉屏震（或开了 reduced motion）的玩家照样要看得见原因文字，
# 所以 toast 无条件出，shake 才受开关管。门禁钉着这一条。
static func reject(control: Control, reason: String) -> void:
	if not reason.is_empty():
		Toast.show_text(reason)
	shake(control)
	vibrate(HAPTIC_REJECT_MS)


# 抖 rotation，不抖 position。
#
# Container 每次重排都会重写子控件的 position 和 size（fit_child_in_rect），
# 却从不碰 rotation / pivot_offset。对容器里的按钮做 position 补间会和排版
# 打架：抖动期间来一次 re-sort，控件就停在一个错的偏移上。
#
# pivot_offset 也要一起改成居中：默认是左上角，绕左上角转看起来像挂在
# 合页上晃，不像抖。所以 rotation 和 pivot_offset **两个都要存、都要还原**。
static func shake(control: Control, base_rad := SHAKE_RAD) -> bool:
	if control == null or not is_instance_valid(control):
		return false
	var scale := Presentation.screen_shake_scale()
	if Tokens.reduced_motion():
		scale = 0.0
	if scale <= 0.0:
		return false

	var key := control.get_instance_id()
	var origin: Dictionary = {}
	if _shake_originals.has(key):
		# 重入：杀掉上一条 tween，原值取存下来的那份。
		origin = _shake_originals[key]
		var live: Variant = origin.get("tween")
		if live is Tween and (live as Tween).is_valid():
			(live as Tween).kill()
	else:
		origin = {
			"rotation": control.rotation,
			"pivot": control.pivot_offset,
		}
		_shake_originals[key] = origin

	control.pivot_offset = control.size * 0.5
	var base: float = float(origin["rotation"])
	var amp: float = base_rad * scale
	var step := Tokens.motion(SHAKE_SEC) / 4.0
	if step <= 0.0:
		# reduced motion 下 motion() 归零，上面已经拦住了；这里是双保险。
		_restore_shake(control, key)
		return false

	var tween := control.create_tween()
	tween.tween_property(control, "rotation", base + amp, step)
	tween.tween_property(control, "rotation", base - amp, step)
	tween.tween_property(control, "rotation", base + amp * 0.5, step)
	tween.tween_property(control, "rotation", base, step)
	tween.finished.connect(func(): _restore_shake(control, key))
	origin["tween"] = tween
	_shake_originals[key] = origin
	return true


# 还原到**存下来的原值**，不是归零：控件本来就可能带一个非零的变换，
# 把它设成 0 是把别人的状态抹掉。
static func _restore_shake(control: Control, key: int) -> void:
	var origin: Variant = _shake_originals.get(key)
	_shake_originals.erase(key)
	if control == null or not is_instance_valid(control):
		return
	if origin is Dictionary:
		control.rotation = float((origin as Dictionary)["rotation"])
		control.pivot_offset = (origin as Dictionary)["pivot"]


# 门禁接缝：还在记账里的控件数。抖完没清干净就会一直涨。
static func shake_tracked_count() -> int:
	return _shake_originals.size()


# --- 门禁接缝 ---------------------------------------------------------------

static func confirm_request_count() -> int:
	return _confirm_requests


static func vibrate_call_count() -> int:
	return _vibrate_calls


static func reset_counters_for_check() -> void:
	_confirm_requests = 0
	_vibrate_calls = 0
