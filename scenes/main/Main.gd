extends Control
const CarrotEconomy := preload("res://scripts/economy/CarrotEconomy.gd")

signal public_token_request_check_requested(request_id: String)
signal room_list_request_check_requested(request_id: String)
signal create_room_request_check_requested(request_id: String)
signal create_room_navigation_check_requested(request_id: String)
signal join_room_request_check_requested(request_id: String, room_id: int, target_port: int)
signal join_room_navigation_check_requested(request_id: String)
signal short_code_resume_request_check_requested(request_id: String, token_id: String)
signal short_code_resume_result_check_requested(request_id: String, succeeded: bool)
signal reconnect_cancel_navigation_check_requested()

const VFX_WARMUP := preload("res://effects/vfx3d/VFXWarmup.gd")
const StartupResourceLoader := preload("res://scripts/assets/FrameResourceLoader.gd")
const PrepStartupAssets := preload("res://scripts/assets/PrepStartupAssets.gd")
const StartupLoadingOverlay := preload("res://ui/components/GloryLoadingOverlay.gd")
const PREP_STARTUP_PATH := "res://scenes/prep/PrepScreen.tscn"
const STARTUP_LOADING_MODAL_ID := "startup_preparation"
var _startup_transition_running := false
var _startup_transition_committing := false
var _startup_transition_serial := 0
var _startup_loader: StartupResourceLoader
var _startup_loading_overlay: StartupLoadingOverlay

# 用 preload 而不是全局类名 UiFeedback：headless 跑检查场景时不走导入，
# .godot/global_script_class_cache.cfg 里没有新登记的 class_name，
# 直接写全局名会「Identifier not declared」——实测踩过。
const UiFeedbackService := preload("res://ui/services/UiFeedback.gd")
# 同一条理由（9.17 音效接入）：SfxService 也刻意不声明 class_name。
const SfxService := preload("res://ui/services/SfxService.gd")
# 9.17 第二批：BGM 也收进一个常驻服务（同样不做 autoload）。
# 播放器挂 root，所以它不随任何一页被 Main._clear() 释放 —— 这正是
# 「打开图鉴/聊天/朋友/设置时菜单 BGM 不暂停」的实现方式。
const MusicService := preload("res://ui/services/MusicService.gd")

const AccountConfig := preload("res://scripts/account/AccountConfig.gd")
const BOOTSTRAP_SCENE := "res://scenes/bootstrap/Bootstrap.tscn"

# --- 连不上账号服务器 = 回启动页 ---------------------------------------------
#
# 规则只有一条：**连不上账号服务器就进不了游戏。** 启动页在放行前检查一次
# （Bootstrap.entry_view），但玩家进来以后服务器掉线，此前没有任何东西管 ——
# 玩家会停在一个「显示已登录、其实已经断了」的主菜单里，商城、好友、开局都是坏的。
#
# 这里补上后半段：不在对局里的时候，实时连接断开超过 AccountConfig.CONNECT_PATIENCE_SEC，
# 就送回启动页，由那边重走登录 / 连接 / 排队 / 维护提示（全部现成）。
#
# 三种情况**不送回**，各有各的去处：
#   · 对局中（含离线自测、教学对局） —— 战斗服务器有自己的断线重连，踢出去等于毁掉一局
#   · 教学中 —— 本地流程，不依赖账号服务器
#   · 被顶号 —— RealtimeService 明确禁止自动重连（两台设备会无限互踢），走现有提示
var _in_match_flow := false
var _account_offline_sec := 0.0
var _returning_to_login := false

const PUBLIC_TOKEN_ACTION := "team_public_token"
const PUBLIC_TOKEN_CONTROL_ID := "main_menu/public_token_generate"
const PUBLIC_TOKEN_TIMEOUT_MSEC := 15000
const ROOM_LIST_ACTION := "team_room_list"
const ROOM_LIST_CONTROL_ID := "main_menu/team_room_list"
const ROOM_LIST_TIMEOUT_MSEC := 15000
const CREATE_ROOM_ACTION := "team_create_room"
const CREATE_ROOM_CONTROL_ID := "main_menu/team_room_create"
const CREATE_ROOM_TIMEOUT_MSEC := 15000
const JOIN_ROOM_ACTION := "team_join_room"
const JOIN_ROOM_CONTROL_ID := "main_menu/team_room_join"
const JOIN_ROOM_TIMEOUT_MSEC := 15000
const SHORT_CODE_RESUME_ACTION := "team_short_code_resume"
const SHORT_CODE_RESUME_CONTROL_ID := "main_menu/public_token_resume"
const SHORT_CODE_RESUME_TIMEOUT_MSEC := 15000
# 第六个受控动作（V3 P0-05）。手动重连此前是 Main 里唯一没受控的联网动作：
# 没有 busy 态、连点会重复发起、凭证不全时静默返回。
const MANUAL_RECONNECT_ACTION := "team_manual_reconnect"
const MANUAL_RECONNECT_CONTROL_ID := "main_menu/team_reconnect"
const MANUAL_RECONNECT_TIMEOUT_MSEC := 15000

# V2 P1-08：返回键二次确认的窗口。PrepScreen 走 preload 常量做静态类型判断，
# 不用 has_method 动态派发 —— 那会给 dynamic_call 棘轮添丁。
const BACK_EXIT_CONFIRM_WINDOW_SEC := 2.0
# 提示自带的 CanvasLayer 层号。要压过备战页的所有 UI（商店按钮曾经把它盖住），
# 同时不去和 ModalStack 抢 —— 那套用的是自己的 priority，不是 CanvasLayer.layer。
const BACK_EXIT_HINT_LAYER := 250
const BACK_EXIT_HINT_BOTTOM_MARGIN := 46.0
const PrepScreenScript := preload("res://scenes/prep/PrepScreen.gd")

# 断线重连提示层的 ModalStack 合同（C-11 的 B1）。
# 90：高于战斗加载 80、低于确认框 100 —— 重连中弹出的确认框必须盖在它上面，
# 而它必须盖住战斗加载。
const RECONNECT_MODAL_ID := "reconnect_status"
const RECONNECT_MODAL_PRIORITY := 90
# 迁移前这 0.72 的黑是浮层自己那块 ColorRect；现在由 ModalStack 的 backdrop 承担，
# 数值逐字保持。
const RECONNECT_BACKDROP_COLOR := Color(0.0, 0.0, 0.0, 0.72)

var _menu: Control
var _prep: Control
var _battle: Control
# 迁移后这三个都是**瞬时**节点：ModalStack 每次开层现建、关层销毁。
# 根不再是自建的 CanvasLayer（layer=100），而是一块透明的全屏 Control；
# 层级与 0.72 变暗都交给 ModalStack。
var _reconnect_overlay: Control
var _reconnect_label: Label
var _reconnect_cancel_button: Button
var _reconnect_cancel_navigation_check_hook := Callable()
var _public_token_request_id := ""
var _public_token_waiting_for_session := false
var _public_token_request_check_hook := Callable()
var _room_list_request_id := ""
var _room_list_waiting_for_session := false
var _room_list_request_check_hook := Callable()
var _create_room_request_id := ""
var _create_room_waiting_for_session := false
var _create_room_request_dispatched := false
var _create_room_request_check_hook := Callable()
var _create_room_navigation_check_hook := Callable()
var _join_room_request_id := ""
var _join_room_id := 0
var _join_room_target_port := NetworkService.DEFAULT_PORT
var _join_room_waiting_for_session := false
var _join_room_request_dispatched := false
var _join_room_request_check_hook := Callable()
var _join_room_navigation_check_hook := Callable()
var _short_code_resume_request_id := ""
var _short_code_resume_token := ""
var _short_code_resume_waiting_for_session := false
var _short_code_resume_request_dispatched := false
var _short_code_resume_ignore_late_result := false
var _short_code_resume_request_check_hook := Callable()
var _short_code_resume_result_check_hook := Callable()
var _manual_reconnect_request_id := ""
var _manual_reconnect_request_check_hook := Callable()
# 会话是否真的进过重连流程。begin_resume_from_disk() 里的 reset() 会先发一次
# state=OFFLINE 的 session_changed，晚于它才置 RECONNECTING —— 不区分的话，
# 动作会在派发的同一帧被这声噪声结算掉。
var _manual_reconnect_saw_flight := false
# 离线自测·单位测试模式(officetest):进入前的 team_mode 快照,退出时还原。
var _selftest_prev_team_mode := false
var _back_exit_armed_until := 0.0
# 当前页面按返回键该去哪。每个有返回出口的 _show_* 在连 back_requested 的
# 同一处设它，_clear() 清掉。空 = 这一页没有页内出口（主菜单、战斗中、
# 初始宠物强制三选一），返回键继续往下走到二次确认退出。
var _page_back_route := Callable()

func _ready() -> void:
	# Idempotent on purpose: the DataRegistry autoload has already loaded by now, and
	# this used to be a second full synchronous re-read of all eight JSON files on
	# the way to the first frame. Kept as a call rather than deleted so the ordering
	# dependency stays visible if autoload order ever changes.
	DataRegistry.ensure_loaded()
	if not NetworkService.match_state_received.is_connected(_on_network_match_state_received):
		NetworkService.match_state_received.connect(_on_network_match_state_received)
	if not NetworkService.session_changed.is_connected(_on_global_session_changed):
		NetworkService.session_changed.connect(_on_global_session_changed)
	if not NetworkService.resume_completed.is_connected(_on_resume_completed):
		NetworkService.resume_completed.connect(_on_resume_completed)
	if not NetworkService.resume_failed.is_connected(_on_resume_failed):
		NetworkService.resume_failed.connect(_on_resume_failed)
	if not NetworkService.team_room_list_received.is_connected(_on_team_room_list_received):
		NetworkService.team_room_list_received.connect(_on_team_room_list_received)
	if not NetworkService.team_room_action_failed.is_connected(_on_team_room_action_failed):
		NetworkService.team_room_action_failed.connect(_on_team_room_action_failed)
	if not NetworkService.public_token_changed.is_connected(_on_public_token_changed):
		NetworkService.public_token_changed.connect(_on_public_token_changed)
	if not AsyncActionController.action_state_changed.is_connected(_on_async_action_state_changed):
		AsyncActionController.action_state_changed.connect(_on_async_action_state_changed)
	if not TutorialMode.skip_requested.is_connected(_on_tutorial_skip):
		TutorialMode.skip_requested.connect(_on_tutorial_skip)
	# 宠物归属到手 / 变化时补判三选一，见 _on_pets_changed。
	if not PlayerProfile.pets_changed.is_connected(_on_pets_changed):
		PlayerProfile.pets_changed.connect(_on_pets_changed)
	# V3 P1-04：接上确认音/触觉。挂在 action_resolved 上，不挂按钮、
	# 更不挂 _input —— 那个信号每个 request_id 只发一次，且不是输入驱动的，
	# 所以连点和 mouse+touch 双路都不会让它多发。
	UiFeedbackService.install()
	# 9.17：全局音效服务。同样不做 autoload（autoload 全在冷启动关键路径上），
	# 播放器与代币收支监视器都挂在 root 下按需创建。
	SfxService.install()
	# 9.17 第二批：BGM 服务。install() 里做的两件事——建常驻播放器、
	# 接上 PlayerProfile.presentation_settings_changed（设置页音乐开关即时生效）。
	MusicService.install()
	_install_presence_reporting()
	_install_realtime()
	_route_startup()
	# Full catalog shader warmup is diagnostic-only. Production loads the
	# current battle through PrepScreen's existing replay resource stage.
	if OS.is_debug_build() and OS.get_cmdline_user_args().has("--warmup-effects"):
		_start_vfx_warmup()
	StartupTrace.mark(StartupTrace.T2_MAIN_READY)

# Opt-in VFX diagnostics; catalog-wide compilation must not compete with the
# language page or the player's first tutorial actions.
func _start_vfx_warmup() -> void:
	if NetworkService.state != NetworkService.SessionState.OFFLINE:
		return
	var warm := VFX_WARMUP.new()
	warm.name = "VFXWarmup"
	# 挂在 root 而不是 Main：Main._clear() 每次切界面都会把自己的子节点全部
	# queue_free，而 _show_language_select() 第一行就是 _clear()。预热要跨越
	# 「语言选择 → 教程 → 宠物 → 主菜单」这几屏才跑得完，挂在 Main 下会立刻被杀。
	# 同 _show_reconnect_overlay 的做法。
	get_tree().root.add_child.call_deferred(warm)
	warm.finished.connect(func(_report: Dictionary): warm.queue_free())
	# 延后到入树之后再启动：start() 里要 add_child 建离屏视口。
	warm.start.call_deferred()

# --- 断线重连 UI 与恢复落地 --------------------------------------------------

func _on_global_session_changed() -> void:
	if NetworkService.state == NetworkService.SessionState.RECONNECTING:
		_show_reconnect_overlay()
	else:
		_hide_reconnect_overlay()

func _show_reconnect_overlay() -> void:
	# 迁移前这里自己建 CanvasLayer(layer=100) 挂到 root（C-11 的 B1 之前）。
	# 现在交给 ModalStack：去重由 has() 负责，层级由 CanvasLayer priority 负责。
	# 仍然不挂在 Main 下面 —— _clear() 每次切界面都会把 Main 的子节点全部 queue_free，
	# 而 ModalStack 的宿主层挂在 root，结构上就不会被误删。
	if ModalStack.has(RECONNECT_MODAL_ID):
		return
	if not ModalStack.modal_closed.is_connected(_on_reconnect_modal_closed):
		ModalStack.modal_closed.connect(_on_reconnect_modal_closed)
	var content := _create_reconnect_content()
	var modal_id := ModalStack.push(content, {
		"id": RECONNECT_MODAL_ID,
		"owner": self,
		"priority": RECONNECT_MODAL_PRIORITY,
		# 重连中点外面不能关：唯一的出口是那个「取消并返回主菜单」按钮。
		"dismiss_on_backdrop": false,
		"backdrop_color": RECONNECT_BACKDROP_COLOR,
	})
	if modal_id.is_empty():
		# 上面已用 has() 挡过重复；走到这里说明 push 真的失败了。
		# content 已被 push 收走，不能再 free，只清引用。
		_teardown_reconnect_refs()
		return
	_reconnect_overlay = content


# 每次开层现建一份 content。文案、字号、颜色、260×48、间距 18 与迁移前逐字一致。
# 两处差别：不再自带 0.72 的 dim（交给 backdrop，避免叠成两层黑），
# 不再依赖 layer=100。全链 IGNORE 到取消按钮为止 ——
# 全屏 STOP 只能有 backdrop 一块，而按钮之外的点击落到 backdrop 上被吃掉
# （dismiss_on_backdrop=false），既不穿透到底层界面、也不关层。
func _create_reconnect_content() -> Control:
	var root := Control.new()
	root.name = "ReconnectStatusOverlay"
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 18)
	center.add_child(box)
	_reconnect_label = Label.new()
	_reconnect_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_reconnect_label.text = "连接中断，正在重连…" if not LocaleManager.get_locale().begins_with("en") else "Connection lost, reconnecting..."
	_reconnect_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_reconnect_label.add_theme_font_size_override("font_size", 30)
	_reconnect_label.add_theme_color_override("font_color", Color(0.95, 0.92, 0.80))
	box.add_child(_reconnect_label)
	_reconnect_cancel_button = Button.new()
	_reconnect_cancel_button.text = "取消并返回主菜单" if not LocaleManager.get_locale().begins_with("en") else "Cancel and return to menu"
	_reconnect_cancel_button.custom_minimum_size = Vector2(260, 48)
	_reconnect_cancel_button.pressed.connect(_on_reconnect_cancel)
	box.add_child(_reconnect_cancel_button)
	return root


func _hide_reconnect_overlay() -> void:
	if ModalStack.has(RECONNECT_MODAL_ID):
		# 所有权在 push 时就交给 ModalStack 了，绝不能自己 queue_free content。
		ModalStack.pop(RECONNECT_MODAL_ID, ModalStack.REASON_PROGRAMMATIC)
	else:
		_teardown_reconnect_refs()


# 任何一条关闭路径（程序化 pop、close_all、Back、owner 释放）都会走到这里。
#
# ⚠️ 这里**绝不碰会话状态**：不调 cancel_reconnect()、不清凭证、不改 team_mode、
# 不导航。外部关掉这一层不等于玩家按了取消 —— 那样等于把玩家的重连凭证无声销毁。
func _on_reconnect_modal_closed(id: String, _reason: String) -> void:
	if id != RECONNECT_MODAL_ID:
		return
	_teardown_reconnect_refs()
	# ⚠️ 必须 deferred。ModalStack.close_all() 是 `while not _entries.is_empty()`，
	# 而 pop() 同步 emit modal_closed —— 在这里直接重新 push，_entries 永远不空，
	# 整个进程原地转死。deferred 回调在 close_all() 返回之后才跑。
	_restore_reconnect_if_still_needed.call_deferred()


# 强制层的自愈：只要还在重连，层就得回来。
# 不需要判断关闭原因 —— 取消 / 恢复成功 / 恢复失败时 state 都已经离开
# RECONNECTING，这里读到就什么都不做，不会把已经该消失的层又拉回来。
func _restore_reconnect_if_still_needed() -> void:
	if not is_instance_valid(self) or not is_inside_tree():
		return
	if NetworkService.state != NetworkService.SessionState.RECONNECTING:
		return
	if ModalStack.has(RECONNECT_MODAL_ID):
		return
	_show_reconnect_overlay()


# content 已由 ModalStack 销毁（或即将销毁），这里只清本页面持有的引用。
# 不 free 任何节点；取消按钮的 pressed 连接随按钮一起消失，不会累积。
func _teardown_reconnect_refs() -> void:
	_reconnect_overlay = null
	_reconnect_label = null
	_reconnect_cancel_button = null


func _on_reconnect_cancel() -> void:
	# 取消是一次性的。迁移前这里没有任何守卫：连点 N 次就调 N 次
	# cancel_reconnect()（每次都删一遍凭证、reset 一遍会话）并导航 N 次。
	# 守卫绑在「面板确实还在屏幕上」这个玩家可见事实上，而不是再加一份要同步的 bool。
	if not ModalStack.has(RECONNECT_MODAL_ID):
		return
	NetworkService.cancel_reconnect()
	GameState.team_mode = false
	_hide_reconnect_overlay()
	if OS.is_debug_build() and _reconnect_cancel_navigation_check_hook.is_valid():
		reconnect_cancel_navigation_check_requested.emit()
		return
	_show_menu()


func set_reconnect_cancel_navigation_check_hook(hook: Callable) -> bool:
	if not OS.is_debug_build():
		return false
	if _reconnect_cancel_navigation_check_hook.is_valid() \
			and reconnect_cancel_navigation_check_requested.is_connected(_reconnect_cancel_navigation_check_hook):
		reconnect_cancel_navigation_check_requested.disconnect(_reconnect_cancel_navigation_check_hook)
	_reconnect_cancel_navigation_check_hook = hook
	if _reconnect_cancel_navigation_check_hook.is_valid():
		reconnect_cancel_navigation_check_requested.connect(_reconnect_cancel_navigation_check_hook)
	return true

func _on_resume_completed(payload: Dictionary) -> void:
	if _short_code_resume_ignore_late_result:
		_short_code_resume_ignore_late_result = false
		return
	if not _short_code_resume_request_id.is_empty() \
			and AsyncActionController.is_current(_short_code_resume_request_id):
		var request_id := _short_code_resume_request_id
		if not AsyncActionController.succeed(request_id):
			return
		if OS.is_debug_build() and _short_code_resume_result_check_hook.is_valid():
			short_code_resume_result_check_requested.emit(request_id, true)
			return
	_hide_reconnect_overlay()
	GameState.team_mode = true
	# 只有内存里没有对局数据（app 重开导致 GameState 全新）才从磁盘恢复棋盘/备战席；
	# 活着的重连（网络抖动）内存就是最新状态，不能用可能过期的磁盘存档覆盖它。
	if _team_run_state_is_fresh():
		SaveManager.load_run()
	# 服务器权威数值覆盖本地
	# 键名跟着状态信封走（E2）：round_index -> round_id、enemy_team_hp -> rival_team_hp。
	# 快照现在还多带了连败与 PVE/Boss 计数（C5 缺的那几项）。
	GameState.round_index = int(payload.get("round_id", GameState.round_index))
	GameState.team_hp = int(payload.get("team_hp", GameState.team_hp))
	GameState.enemy_team_hp = int(payload.get("rival_team_hp", GameState.enemy_team_hp))
	# 金币同步：默认（经济账本未开启权威）配置下金币由客户端权威维护——备战阶段每一笔
	# 购买/出售都只改本地 GameState.gold，服务端 slot_gold 仅在战斗结算时更新一次，
	# 等于"购买前"的金币。重连若用这份陈旧快照覆盖本地正确金币，金币会回退到购买前
	# （BUG：商店购买阶段掉线重连后金币被重置）。因此未开启权威时保留本地金币不覆盖；
	# 仅在经济账本权威开启、快照携带权威金币时才以服务端为准。
	var _eco_state: Dictionary = payload.get("economy", {}) as Dictionary
	if not _eco_state.is_empty() and bool(_eco_state.get("authoritative", false)):
		GameState.gold = int(_eco_state.get("gold", GameState.gold))
	if not _eco_state.is_empty() and bool(_eco_state.get("carrot_authoritative", false)):
		NetworkService._apply_carrot_state(_eco_state)
	# else: 保留本地金币（GameState.gold 已是本回合真实值）
	GameState.loss_streak = int(payload.get("loss_streak", GameState.loss_streak))
	GameState.pve_completed = int(payload.get("pve_completed", GameState.pve_completed))
	GameState.boss_completed = int(payload.get("boss_completed", GameState.boss_completed))
	GameState.golden_altar_uses = int(payload.get("altar_uses", GameState.golden_altar_uses))
	# 宝物以服务端记录为准。磁盘存档可能落后一轮（app 被杀重开），而服务端的
	# owned_treasures 是 intent 授权出来的唯一真相；未领取的候选也一并接回来，
	# 否则重连玩家会永远丢掉这一轮的三选一。
	if payload.has("owned_treasures"):
		# 走同步 helper 而不是直接赋值：直接赋值会绕过图鉴 mark_seen 与联动解锁。
		TreasureService.sync_owned_from_server(payload.get("owned_treasures", []) as Array)
	var resumed_offer: Dictionary = payload.get("treasure_offer", {}) as Dictionary
	if resumed_offer.is_empty():
		# 服务端说没有待领取的候选 —— 必须**主动清掉**本地旧的三选一界面。
		# 只在有 offer 时才写，会让掉线前那次未领取的 UI 一直留在屏幕上：玩家点下去
		# 服务端已经 erase 过 offer，只会拿到 no_offer，表现为「点了没反应」。
		GameState.pending_treasure = {"active": false, "round": 0, "candidates": [], "refresh_index": 0}
	else:
		GameState.pending_treasure = {
			"active": true,
			"round": int(resumed_offer.get("round", 0)),
			"candidates": (resumed_offer.get("candidates", []) as Array).duplicate(),
			"refresh_index": int(resumed_offer.get("refresh_index", 0)),
		}
	# 商店：活着重连（内存里的对局数据还在）时，**保留**掉线前的商店，不要刷新 ——
	# 否则购买棋子阶段掉线重连后，商店会被重新摇一遍（BUG：商店购买阶段掉线重连后商店刷新）。
	# 本地 GameState.shop_offers 本就是商店的权威来源（摇店由客户端 _roll_shop() 完成，
	# 服务端快照不携带商店字段），重连时它仍保存着玩家掉线前正在看的棋子，直接保留即可。
	# 只有在确实没有任何商店数据时才清空，交给 PrepScreen._ready 自动 _roll_shop() 出一批新的
	# （冷启动 / 跨回合全新对局 / 大厅等场景）。
	if GameState.shop_offers.is_empty() or GameState.shop_offers[0].is_empty():
		GameState.clear_shop()
	# else：保留 GameState.shop_offers，PrepScreen._ready 检测到非空就不会再摇店。
	if str(payload.get("phase", "prep")) == NetworkService.ROOM_LOBBY:
		_show_team3v3_lobby()
		return
	# prep/battle/result 一律落回备战：battle 阶段等本回合 match_state 到达后
	# 由全局处理器直接推进（= 跳过战斗），result 阶段服务器已补发 match_state。
	_show_prep()

func _team_run_state_is_fresh() -> bool:
	for cell in GameState.board_slots:
		if cell != null:
			return false
	for cell in GameState.bench_slots:
		if cell != null:
			return false
	return true

func _on_resume_failed(reason: String) -> void:
	if _short_code_resume_ignore_late_result:
		_short_code_resume_ignore_late_result = false
		return
	if not _short_code_resume_request_id.is_empty() \
			and AsyncActionController.is_current(_short_code_resume_request_id):
		var request_id := _short_code_resume_request_id
		AsyncActionController.fail(request_id, "SHORT_CODE_RESUME_FAILED", true)
		if OS.is_debug_build() and _short_code_resume_result_check_hook.is_valid():
			short_code_resume_result_check_requested.emit(request_id, false)
			return
	_hide_reconnect_overlay()
	GameState.team_mode = false
	_show_menu()
	if is_instance_valid(_menu) and _menu.has_method("show_room_error"):
		_menu.show_room_error(reason)
	if is_instance_valid(_menu) and _menu.has_method("show_connection_error"):
		_menu.show_connection_error(reason)

func _on_tutorial_skip() -> void:
	# 跳过整段教学：结束教学态，回到主菜单让玩家自己选普通/组队。
	if not TutorialMode.active:
		return
	# 先落账户状态、再删断点。写盘失败时保留断点，下次启动仍有恢复点，
	# 绝不出现「状态没存到、断点却先删了」的双重丢失。
	var persisted := PlayerProfile.set_onboarding_status(PlayerProfile.ONBOARDING_SKIPPED)
	TutorialMode.finish(persisted)
	_show_menu()

# 界面场景一律运行时 load，不用 preload。
#
# 原因是实测出来的：GDScript 的 preload() **不管写在哪里都在脚本加载时解析**，包括永远
# 不会执行的函数体内。所以这几行原本写成 preload 时，加载 Main.gd 会连带把 MainMenu /
# Settings / Pet / Codex / Team3v3Lobby / PrepScreen / BattleScreen 的整张依赖图全拉进来 ——
# 而首屏语言选择页一个都不需要。更要命的是这发生在**第一个 autoload ready 之前**，
# 任何 GDScript 侧的优化都够不着它。
#
# 实测（--headless，同参数只改这一处，各跑多次）：t0_trace_ready
#   改前 3159 / 3177 / 3206 ms   改后 1651 / 1653 / 1658 / 1659 ms
# 约省 1.5 秒，引擎启动降 48%。作为对照，一个不引用这些界面的小场景是 974/980 ms ——
# 也就是说改完之后 Main 自身的预加载成本从 ~2.2 秒降到 ~0.7 秒。
#
# 代价是成本转移而非消失：每个界面**第一次**打开会变慢。这是刻意的取舍 —— 那些都发生在
# 玩家操作之后、可以配加载态，而 preload 是无条件压在启动路径上。
#
# 换成 load() 会丢掉 preload 的编译期路径校验，所以这里把 null 变成一条指名道姓的错误，
# 而不是让调用方在 null 上 .instantiate() 崩掉。全仓的 res:// 引用另有
# tools/asset_manifest_check 守着。
func _load_screen(path: String) -> PackedScene:
	var scene := load(path) as PackedScene
	if scene == null:
		push_error("界面场景加载失败：%s" % path)
	return scene


func _instantiate_screen(path: String) -> Control:
	var scene := _load_screen(path)
	if scene == null:
		return null
	return scene.instantiate() as Control


# 对局类界面（备战、战斗、结算、3v3 大厅、自测）在 _clear() 之后调一次。
# 标上之后「掉线回启动页」不会碰它 —— 对局有战斗服务器自己的断线重连。
func _enter_match_flow() -> void:
	_in_match_flow = true


func _process(delta: float) -> void:
	_watch_account_link(delta)


# 连不上账号服务器超过耐心值就回启动页。规则与例外见文件顶部那段。
func _watch_account_link(delta: float) -> void:
	if not _should_watch_account_link():
		_account_offline_sec = 0.0
		return
	if RealtimeService.is_online():
		_account_offline_sec = 0.0
		return
	_account_offline_sec += delta
	if _account_offline_sec >= AccountConfig.CONNECT_PATIENCE_SEC:
		_return_to_login()


func _should_watch_account_link() -> bool:
	# 开发时用 --no-account 跑：实时连接根本不会起，盯着它只会把人无限送回启动页。
	# 与 Bootstrap._entry_gate_required 同一个判据。
	if not AccountConfig.auto_login_enabled():
		return false
	if _returning_to_login or _in_match_flow:
		return false
	if NetworkService.team_active or TutorialMode.active:
		return false
	# 被顶号不归这里管，见文件顶部。
	if RealtimeService.is_kicked():
		return false
	return true


func _return_to_login() -> void:
	if _returning_to_login:
		return
	_returning_to_login = true
	push_warning("[MAIN] 账号服务器连不上已超过 %.0f 秒，回启动页" % AccountConfig.CONNECT_PATIENCE_SEC)
	# 启动页会重新 start()（它在连着时是空操作），并按现有流程显示
	# 「连接中 / 连不上 / 维护中」。这里不 stop()：留着自动重连，
	# 服务器一回来启动页就能直接放行，玩家不用多等一轮。
	_clear()
	get_tree().change_scene_to_file(BOOTSTRAP_SCENE)


func _clear() -> void:
	# 先清路由：下一页要么自己设一个，要么就该没有。留着上一页的会让返回键
	# 把玩家送回一个已经不在树上的界面。
	_page_back_route = Callable()
	# 同理：下一页是不是对局，由它自己说（_enter_match_flow）。默认不是 ——
	# 这样新加的菜单界面不用记得做任何事，就自动受「掉线回启动页」保护。
	_in_match_flow = false
	# Menu-owned async work must stop before its controls leave the tree. This also
	# makes a later public-token response stale instead of painting the next screen.
	if _menu != null and is_instance_valid(_menu):
		AsyncActionController.clear_for_owner(_menu, "menu_replaced")
	for child in get_children():
		remove_child(child)
		child.queue_free()

func _show_language_select() -> void:
	_clear()
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.06, 0.075)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	bg.z_index = -10

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := VBoxContainer.new()
	panel.custom_minimum_size = Vector2(420, 0)
	panel.add_theme_constant_override("separation", 18)
	center.add_child(panel)

	var title := Label.new()
	title.text = "Select Language / 选择语言"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", Color(0.96, 0.94, 0.82))
	panel.add_child(title)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 16)
	panel.add_child(row)

	var zh_btn := Button.new()
	zh_btn.text = "中文"
	zh_btn.custom_minimum_size = Vector2(150, 54)
	zh_btn.pressed.connect(_select_language.bind("zh"))
	row.add_child(zh_btn)

	var en_btn := Button.new()
	en_btn.text = "English"
	en_btn.custom_minimum_size = Vector2(150, 54)
	en_btn.pressed.connect(_select_language.bind("en"))
	row.add_child(en_btn)

	# Deferred by one frame on purpose: the buttons exist now, but T3 is meant to be
	# "the player could have pressed one", which is only true once this frame has
	# been laid out and drawn.
	StartupTrace.mark_input_ready.call_deferred("language_select")


func _route_startup() -> void:
	match PlayerProfile.startup_route():
		PlayerProfile.STARTUP_MENU:
			_show_menu()
		PlayerProfile.STARTUP_TUTORIAL:
			_enter_tutorial_from_startup()
		_:
			_show_language_select()


func _enter_tutorial_from_startup() -> void:
	if _startup_transition_running:
		return
	_startup_transition_running = true
	_startup_transition_committing = false
	_startup_transition_serial += 1
	var serial := _startup_transition_serial
	_startup_loading_overlay = StartupLoadingOverlay.new()
	_startup_loading_overlay.configure({
		"request_id": STARTUP_LOADING_MODAL_ID,
		"title": _startup_text("准备新手教程", "Preparing tutorial"),
		"stage_key": "resources",
		"stage_text": _startup_text("载入棋盘与当前棋子", "Loading board and current pieces"),
		"cancellable": true,
		"cancel_text": _startup_text("返回语言选择", "Back to language selection"),
	})
	_startup_loading_overlay.retry_requested.connect(_retry_startup_preparation)
	_startup_loading_overlay.cancel_requested.connect(_cancel_startup_preparation)
	ModalStack.push(_startup_loading_overlay, {
		"id": STARTUP_LOADING_MODAL_ID, "owner": self, "priority": 80,
		"dismiss_on_backdrop": false,
	})
	# Acknowledge the tap before profile/checkpoint I/O or any resource work.
	await _await_startup_frame()
	if serial != _startup_transition_serial:
		return
	StartupTrace.mark("tutorial_loading_visible")
	# Tutorials remain local even when an unfinished team session survives.
	if NetworkService.team_active:
		NetworkService.disconnect_session()
		if NetworkService.team_active:
			NetworkService.reset()
	if not TutorialMode.active:
		PlayerProfile.begin_tutorial()
		if not (TutorialMode.has_checkpoint() and TutorialMode.restore_checkpoint()):
			TutorialMode.start()
	var loader := StartupResourceLoader.new()
	_startup_loader = loader
	var paths: Array = [PREP_STARTUP_PATH]
	paths.append_array(PrepStartupAssets.paths())
	var loaded := await loader.load_paths(get_tree(), paths,
		_on_startup_resource_progress.bind(serial))
	if not is_inside_tree() or serial != _startup_transition_serial:
		return
	if not loaded:
		push_error("Tutorial resource loading failed: %s" % str(loader.failed_paths))
		_startup_loading_overlay.set_failed("PREP-RESOURCE-LOAD",
			_startup_text("部分资源未能载入，请重试。", "Some resources could not be loaded. Please retry."), true,
			_startup_text("载入失败", "Loading failed"),
			_startup_text("返回语言选择", "Back to language selection"))
		_startup_transition_running = false
		return
	var scene := loader.resources.get(PREP_STARTUP_PATH) as PackedScene
	if scene == null:
		_startup_loading_overlay.set_failed("PREP-SCENE-TYPE",
			_startup_text("棋盘资源无法打开，请重试。", "The board could not be opened. Please retry."), true,
			_startup_text("载入失败", "Loading failed"),
			_startup_text("返回语言选择", "Back to language selection"))
		_startup_transition_running = false
		return
	_startup_loader = null
	# Keep only current models and their actions/materials beyond this loader's
	# lifetime. The shop presents portraits; its 3D models are needed on purchase.
	for path in loader.resources:
		if str(path).begins_with("res://assets/models/"):
			BattleAssetService.retain_ready_resource(str(path), loader.resources[path],
				BattleAssetService.OWNER_PLAYER)
	StartupTrace.mark("tutorial_resources_ready", {"resources": loader.resources.size()})
	# Construction touches the scene tree; cancellation is only offered during
	# background I/O, then disabled for this short, frame-sliced commit.
	_startup_transition_committing = true
	_startup_loading_overlay.set_cancel_policy(false,
		_startup_text("正在完成棋盘布置", "Finishing the board"))
	_startup_loading_overlay.set_stage("build", _startup_text("布置棋盘", "Setting up the board"), "")
	await get_tree().process_frame
	_clear()
	_prep = scene.instantiate() as Control
	_prep.startup_staged = true
	_prep.battle_requested.connect(_on_battle_requested)
	add_child(_prep)
	await _prep.startup_ready
	await _await_startup_frame()
	StartupTrace.mark("tutorial_first_frame_ready")
	ModalStack.pop(STARTUP_LOADING_MODAL_ID, ModalStack.REASON_PROGRAMMATIC)
	_startup_loading_overlay = null
	_startup_transition_running = false
	_startup_transition_committing = false
	SaveManager.save_run()


func _await_startup_frame() -> void:
	if DisplayServer.get_name() == "headless":
		await get_tree().process_frame
	else:
		await RenderingServer.frame_post_draw


func _on_startup_resource_progress(done: int, total: int, serial: int) -> void:
	if serial == _startup_transition_serial and is_instance_valid(_startup_loading_overlay):
		# The wrapper's action list is discovered as it loads, so use truthful
		# counts without a percentage that could go backwards as the total grows.
		_startup_loading_overlay.set_progress(-1.0, "%d / %d" % [done, total])


func _cancel_startup_preparation(_request_id: String) -> void:
	if _startup_transition_committing:
		return
	_startup_transition_serial += 1
	if _startup_loader != null:
		_startup_loader.cancel()
		_startup_loader = null
	_startup_transition_running = false
	ModalStack.pop(STARTUP_LOADING_MODAL_ID, ModalStack.REASON_PROGRAMMATIC)
	_startup_loading_overlay = null
	TutorialMode.finish(false)
	_show_language_select()


func _retry_startup_preparation(_request_id: String) -> void:
	if _startup_transition_running:
		return
	ModalStack.pop(STARTUP_LOADING_MODAL_ID, ModalStack.REASON_PROGRAMMATIC)
	_startup_loading_overlay = null
	_enter_tutorial_from_startup()


func _startup_text(zh: String, en: String) -> String:
	return en if LocaleManager.get_locale().begins_with("en") else zh


func _select_language(locale: String) -> void:
	if _startup_transition_running:
		return
	PlayerProfile.select_language(locale)
	StartupTrace.mark_first_action("select_language", locale)
	_enter_tutorial_from_startup()


# --- V2 P1-08 / V3 P0-09：返回键与 ui_cancel ---------------------------------
#
# 优先级：最上层 modal → 当前页面自己的面板 → 二次确认退出。**不直接退桌面。**
#
# V3 P0-09：桌面 Esc（ui_cancel）与 Android Back 走**同一个**处理函数。
# 分成两套实现是这类需求最常见的坏法：两边会各自漂移，而 QA 通常只在一个
# 平台上点得到。所以这里只接输入、不复制逻辑。
#
# 全局 ScreenRouter 与 pending 动作询问那一套仍归后续批次。
#
# 优先级：最上层 modal → 当前页面自己的面板 → 二次确认退出。**不直接退桌面。**
# 全局 ScreenRouter 与 pending 动作询问那一套属于 V3 P0-09，本批不做。
func _notification(what: int) -> void:
	match what:
		NOTIFICATION_WM_GO_BACK_REQUEST:
			_on_back_requested()
		NOTIFICATION_APPLICATION_PAUSED:
			# 切后台：教程断点必须落盘。主存档由 SaveManager 自己的 _notification 负责。
			if TutorialMode.active:
				TutorialMode.save_checkpoint(true)


# 用 _unhandled_input 而不是 _input：LineEdit 这类控件要先有机会吃掉自己的
# Esc（取消编辑、关下拉），只有没人认领的才升级成「返回」。
func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return
	get_viewport().set_input_as_handled()
	_on_back_requested()


func _on_back_requested() -> void:
	# Back/Esc must follow the loading screen's cancel policy. Popping this
	# modal generically frees the UI while its resource coroutine still uses it.
	if ModalStack.top_id() == STARTUP_LOADING_MODAL_ID:
		if not _startup_transition_committing:
			_cancel_startup_preparation(STARTUP_LOADING_MODAL_ID)
		return
	# 1. 最上层 modal（重连提示、宝藏三选一、佣兵层、确认框都在这里）
	if ModalStack.handle_back_request():
		return
	# 2. 当前页面自己的面板（备战页的商店 / 佣兵 / 组队检阅台）
	if _prep != null and is_instance_valid(_prep) and _prep is PrepScreenScript:
		if (_prep as PrepScreenScript).handle_back_request():
			return
	# 3. 当前页面的返回出口（设置 / 宠物 / 图鉴 / 组队大厅 / 自测 → 上一层）
	#    走的是页面返回按钮同一个回调，不另写一套导航。
	if _page_back_route.is_valid():
		var route := _page_back_route
		# 先清再调：路由函数自己会 _clear()，但先清掉能保证即使某个路由
		# 将来不走 _clear() 也不会连按两次退两层。
		_page_back_route = Callable()
		route.call()
		return
	# 4. 退出前先把教程断点钉住，玩家回来还在同一步
	if TutorialMode.active:
		TutorialMode.save_checkpoint(true)
	var now := Time.get_ticks_msec() / 1000.0
	if now < _back_exit_armed_until:
		_back_exit_armed_until = 0.0
		get_tree().quit()
		return
	_back_exit_armed_until = now + BACK_EXIT_CONFIRM_WINDOW_SEC
	_show_back_exit_hint()


func _show_back_exit_hint() -> void:
	var existing := get_node_or_null("BackExitHint")
	if existing != null:
		existing.queue_free()
	# 必须自带 CanvasLayer。第一版把 Label 直接挂在 Main 上，真机实测被备战页的
	# 商店按钮压住，只露出「再按一次」半截字 —— 提示本身没被看见，等于没提示。
	var layer := CanvasLayer.new()
	layer.name = "BackExitHint"
	layer.layer = BACK_EXIT_HINT_LAYER
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.04, 0.06, 0.88)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(14)
	style.content_margin_left = 26.0
	style.content_margin_right = 26.0
	panel.add_theme_stylebox_override("panel", style)
	# 底板贴着底边居中。水面和地形都可能在下面，所以靠底板保对比度，
	# 不靠描边 —— 描边在浅色水面上一样糊。
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 1.0
	panel.anchor_bottom = 1.0
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	panel.offset_bottom = -BACK_EXIT_HINT_BOTTOM_MARGIN
	var hint := Label.new()
	hint.text = "再按一次返回键退出" if not LocaleManager.get_locale().begins_with("en") else "Press back again to exit"
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 22)
	hint.add_theme_color_override("font_color", Color(0.98, 0.96, 0.86))
	panel.add_child(hint)
	layer.add_child(panel)
	add_child(layer)
	# 计时器挂在提示自己身上：页面切换把提示删掉时计时器一起消失，
	# 回调不会落到已释放的节点上。
	var timer := Timer.new()
	timer.one_shot = true
	timer.wait_time = BACK_EXIT_CONFIRM_WINDOW_SEC
	layer.add_child(timer)
	timer.timeout.connect(layer.queue_free)
	timer.start()

func _show_menu() -> void:
	# 首次启动：进主菜单前强制选择初始宠物（三选一，选完才放行）。
	#
	# 🔴 **必须先 pets_loaded。** 归属上云之后，没拉到服务端答复时 owned_pets 是空的 ——
	# 只看 needs_starter_pick 的话，弱网下老玩家会被要求重选一遍三选一。
	# 拉到之后如果确实要选，由 _on_pets_changed 补一次。
	if PlayerProfile.pets_loaded and PlayerProfile.needs_starter_pick:
		_show_starter_pet_gate()
		return
	_clear()
	# 重连改为手动：主菜单的"游戏重连"按钮（有本地凭证才显示）才连回上一场，
	# 不再一进菜单就偷偷自动连（那会把玩家拽进夹生半状态、按不动开始）。
	_menu = _instantiate_screen("res://scenes/menu/MainMenu.tscn")
	_menu.team_host_requested.connect(_on_team_host_requested)
	_menu.team_join_requested.connect(_on_team_join_requested)
	_menu.team_room_create_requested.connect(_on_team_room_create_requested)
	_menu.team_room_join_requested.connect(_on_team_room_join_requested)
	_menu.team_room_list_requested.connect(_on_team_room_list_requested)
	_menu.public_token_generate_requested.connect(_on_public_token_generate_requested)
	_menu.public_token_resume_requested.connect(_on_public_token_resume_requested)
	if not _menu.team_offline_requested.is_connected(_on_team_offline_requested):
		_menu.team_offline_requested.connect(_on_team_offline_requested)
	if not _menu.team_reconnect_requested.is_connected(_on_team_reconnect_requested):
		_menu.team_reconnect_requested.connect(_on_team_reconnect_requested)
	_menu.settings_requested.connect(_show_settings)
	_menu.casual_requested.connect(_show_casual_queue)
	_menu.ranked_requested.connect(_show_ranked_queue)
	_menu.prep_requested.connect(_show_pet_screen)
	_menu.codex_requested.connect(_show_codex_screen)
	_menu.profile_requested.connect(_show_profile_screen)
	_menu.friends_requested.connect(_show_friends_screen)
	_menu.chat_requested.connect(_show_chat_screen)
	_menu.announcements_requested.connect(_show_announcements_screen)
	_menu.shop_requested.connect(_show_shop_screen)
	_menu.bag_requested.connect(_show_bag_screen)
	_menu.mail_requested.connect(_show_mail_screen)
	add_child(_menu)
	# 对局中被顶号时挂着的提示，回到主菜单这一刻才弹（设计文档第五节）。
	_show_kicked_notice_if_pending()
	# 公告：回主菜单时顺手刷新（有节流），有该弹的登录弹窗就弹（docs/公告系统设计.md）。
	AnnouncementService.refresh()
	_queue_announcement_popup()
	# 邮箱：回主菜单时顺手刷新（有节流），红点靠它（docs/邮件系统设计.md）。
	MailService.refresh()

# 手动重连：读本地凭证连回上一场，弹重连遮罩，成功落回备战/结果，失败清凭证回菜单。
#
# V3 P0-05 之前这里是 Main 里唯一没走 AsyncActionController 的联网动作。三个后果：
#   1. 按下到 NetworkService 报 RECONNECTING 之间没有任何反馈
#   2. 连点会重复调 begin_resume_from_disk()，每次都重置传输
#   3. 凭证不全时直接 return —— 而按钮的显隐判据是 `load_reconnect().is_empty()`，
#      一条只剩 port 字段的记录会让按钮可见但点了没反应
#
# 第 3 条现在按「先受理再失败」处理，而不是静默返回：玩家看得到原因，
# breadcrumb 里也留得下 action_failed，而不是一片空白。
func _on_team_reconnect_requested() -> void:
	AsyncActionController.record_input_received(
		MANUAL_RECONNECT_ACTION, MANUAL_RECONNECT_CONTROL_ID)
	var owner: Object = _menu if _menu != null and is_instance_valid(_menu) else self
	var request_id := AsyncActionController.begin(MANUAL_RECONNECT_ACTION, {
		"owner": owner,
		"control_id": MANUAL_RECONNECT_CONTROL_ID,
		"timeout_msec": MANUAL_RECONNECT_TIMEOUT_MSEC,
		"cancellable": true,
		"stage": "connect",
	})
	if request_id.is_empty():
		return
	# 连点：begin() 已经记了 action_rejected(duplicate_pending) 并把原 id 还回来。
	if request_id == _manual_reconnect_request_id and AsyncActionController.is_current(request_id):
		return
	_manual_reconnect_request_id = request_id
	_manual_reconnect_saw_flight = false
	# 新的手动恢复明确取代任何旧的组队请求；begin_resume_from_disk() 会重置传输，
	# 因此旧请求的迟到保护也不能误吞这次手动恢复的结果。
	_supersede_other_team_action(MANUAL_RECONNECT_ACTION)
	_short_code_resume_request_id = ""
	_short_code_resume_ignore_late_result = false

	var rc := SaveManager.load_resumable_reconnect()
	var rc_token := str(rc.get("token", ""))
	var rc_address := str(rc.get("address", ""))
	if rc_token.is_empty() or rc_address.is_empty():
		# 不可重试：再点一次读到的还是同一条残缺记录。
		AsyncActionController.fail(request_id, "RECONNECT_NO_CREDENTIAL", false)
		_manual_reconnect_request_id = ""
		if is_instance_valid(_menu):
			_menu.show_connection_error(_menu_reconnect_missing_text())
		return

	AsyncActionController.mark_pending(request_id)
	if is_instance_valid(_menu):
		_menu.show_connecting()
	if not NetworkService.session_changed.is_connected(_on_manual_reconnect_session_changed):
		NetworkService.session_changed.connect(_on_manual_reconnect_session_changed)
	if _manual_reconnect_request_check_hook.is_valid():
		_manual_reconnect_request_check_hook.call(request_id)
	GameState.team_mode = true
	# 端口必须用存下来的那个：座位 token 是进程内的，多进程下连错端口 = 凭证失效。
	# 老存档没有 port 字段，退化为默认端口（等价于单进程时的旧行为）。
	NetworkService.begin_resume_from_disk(rc_token, rc_address, int(rc.get("port", NetworkService.DEFAULT_PORT)))


func _menu_reconnect_missing_text() -> String:
	if LocaleManager.get_locale().begins_with("en"):
		return "Reconnect record is incomplete — start a new game instead."
	return "重连凭证不完整，请重新开始一局"


# 结算沿用 NetworkService 的会话状态，不另设超时判断 —— AsyncActionController
# 自己的 deadline 会兜底，两套超时会互相打架。
func _on_manual_reconnect_session_changed() -> void:
	var request_id := _manual_reconnect_request_id
	if request_id.is_empty() or not AsyncActionController.is_current(request_id):
		_disconnect_manual_reconnect_session_handler()
		return
	match NetworkService.state:
		NetworkService.SessionState.RECONNECTING, NetworkService.SessionState.JOINING:
			_manual_reconnect_saw_flight = true
		NetworkService.SessionState.READY:
			_disconnect_manual_reconnect_session_handler()
			AsyncActionController.succeed(request_id)
			_manual_reconnect_request_id = ""
		NetworkService.SessionState.FAILED:
			_disconnect_manual_reconnect_session_handler()
			AsyncActionController.fail(request_id, "RECONNECT_SESSION_FAILED", true)
			_manual_reconnect_request_id = ""
		NetworkService.SessionState.OFFLINE:
			# 只有在途过才算掉线。派发之前的 OFFLINE 是 reset() 的噪声，不是结论。
			if not _manual_reconnect_saw_flight:
				return
			_disconnect_manual_reconnect_session_handler()
			AsyncActionController.fail(request_id, "RECONNECT_SESSION_FAILED", true)
			_manual_reconnect_request_id = ""


func _disconnect_manual_reconnect_session_handler() -> void:
	if NetworkService.session_changed.is_connected(_on_manual_reconnect_session_changed):
		NetworkService.session_changed.disconnect(_on_manual_reconnect_session_changed)


func manual_reconnect_request_id_for_check() -> String:
	return _manual_reconnect_request_id if OS.is_debug_build() else ""


# 与其余五个受控动作同形的 debug 接缝：release 构建拒绝安装。
func set_manual_reconnect_request_check_hook(hook: Callable) -> bool:
	if not OS.is_debug_build():
		return false
	_manual_reconnect_request_check_hook = hook
	return true

func _on_team_offline_requested() -> void:
	# 纯离线自测：断开任何联机会话，team_active 保持 false，进大厅走本地槽位。
	# 开始后 BattleScreen 的 `not team_active` 分支会本地算回放，无需服务器。
	NetworkService.disconnect_session()
	_show_team3v3_lobby()

func _show_settings() -> void:
	_clear()
	var settings := _instantiate_screen("res://scenes/menu/SettingsScreen.tscn")
	settings.back_requested.connect(_show_menu)
	settings.replay_tutorial_requested.connect(_on_replay_tutorial_requested)
	_page_back_route = _show_menu
	add_child(settings)


func _on_replay_tutorial_requested() -> void:
	_enter_tutorial_from_startup()

# 备战界面（暂时只有宠物系统）。从主菜单「备战」按钮进入，返回回主菜单。
func _show_pet_screen() -> void:
	_clear()
	var pet_screen := _instantiate_screen("res://scenes/menu/PetScreen.tscn")
	pet_screen.back_requested.connect(_show_menu)
	_page_back_route = _show_menu
	add_child(pet_screen)

# 图鉴界面。从主菜单「图鉴」按钮进入，返回回主菜单。
func _show_codex_screen() -> void:
	_clear()
	var codex := _instantiate_screen("res://scenes/menu/CodexScreen.tscn")
	codex.back_requested.connect(_show_menu)
	_page_back_route = _show_menu
	add_child(codex)

# 玩家资料页。入口是主菜单左上角那个名牌（此前是「敬请期待」）。
#
# 用 configure_self() 而不是 configure(Mode.SELF)：传枚举就得 preload
# ProfileScreen.gd，那会把它的整张依赖图拉进 Main 的加载路径 —— 正是
# _load_screen 上面那段注释量过的 1.5 秒。看别人的资料走 configure_public(code)，
# 但今天还没有任何入口能拿到别人的好友码（好友/聊天都还没做）。
# 好友界面。入口是主菜单左侧那个「朋友」按钮（此前是「敬请期待」）。
#
# 用 configure() 而不是传枚举：传枚举就得 preload FriendsScreen.gd，
# 那会把它的整张依赖图拉进 Main 的加载路径 —— 同 _show_profile_screen 的理由。
# 商城（docs/商城系统设计.md）。返回主菜单时那边会重拉一次钱包 ——
# 玩家多半是刚买完东西回来的。
func _show_shop_screen() -> void:
	_clear()
	var screen := _instantiate_screen("res://scenes/menu/ShopScreen.tscn")
	if screen == null:
		_show_menu()
		return
	screen.back_requested.connect(_show_menu)
	_page_back_route = _show_menu
	add_child(screen)


func _show_bag_screen() -> void:
	_clear()
	var screen := _instantiate_screen("res://scenes/menu/BagScreen.tscn")
	if screen == null:
		_show_menu()
		return
	screen.back_requested.connect(_show_menu)
	# 头像换装在资料页，背包只展示（BagScreen 文件头写了为什么不在这儿再做一份）。
	screen.profile_requested.connect(_show_profile_screen)
	_page_back_route = _show_menu
	add_child(screen)


# 系统邮件（docs/邮件系统设计.md）。返回主菜单时那边会重拉一次钱包 —— 玩家多半刚领完附件。
func _show_mail_screen() -> void:
	_clear()
	var screen := _instantiate_screen("res://scenes/menu/MailScreen.tscn")
	if screen == null:
		_show_menu()
		return
	screen.back_requested.connect(_show_menu)
	_page_back_route = _show_menu
	add_child(screen)


func _show_friends_screen() -> void:
	_clear()
	var screen := _instantiate_screen("res://scenes/menu/FriendsScreen.tscn")
	if screen == null:
		_show_menu()
		return
	screen.back_requested.connect(_show_menu)
	# 点好友头像看资料 —— 这补上了 _show_profile_screen 上面那条注释说的
	# 「今天还没有任何入口能拿到别人的好友码」。
	screen.profile_requested.connect(_show_public_profile)
	# 一键加入好友所在的房间。走已有的加入流程，不新造路径。
	screen.join_room_requested.connect(_join_room_by_id)
	# 私聊。从好友列表进来的，返回回好友列表。
	screen.chat_requested.connect(func(code: String) -> void: _show_chat_screen(code, true))
	_page_back_route = _show_menu
	add_child(screen)


# 一键加入好友所在的房间。
#
# **先回主菜单再发起**，不是留在好友界面里连。理由是反馈：
# _start_join_room_action 的「连接中」遮罩与失败提示都挂在 _menu 上
# （show_connecting / show_connection_error），而切到好友界面时 _menu 已经被
# _clear() 释放了。留在原地的话，加入失败会**一点反馈都没有** ——
# 而房间满了 / 已开打 / 房间号已回收都是很常见的失败，
# 正是 docs/交友系统设计.md 第六节第 5 条点名要避免的。
#
# 代价是画面会跳回主菜单一下。第一版接受这个代价：复用一条验过的路径，
# 比为了不跳屏而复制一套连接中/错误 UI 划算。
func _join_room_by_id(room_id: int) -> void:
	if room_id <= 0:
		return
	_show_menu()
	_start_join_room_action(room_id)


# 私聊界面（docs/聊天系统设计.md 批次 C）。两个入口：主菜单「聊天」、好友列表每一行的「私聊」。
# 从好友列表进来的，返回回好友列表 —— 玩家是从那里进来的（同 _show_public_profile）。
func _show_chat_screen(focus_code: String = "", back_to_friends: bool = false) -> void:
	_clear()
	var screen := _instantiate_screen("res://scenes/menu/ChatScreen.tscn")
	if screen == null:
		_show_menu()
		return
	screen.call("configure", focus_code)
	var back: Callable = _show_friends_screen if back_to_friends else _show_menu
	screen.back_requested.connect(back)
	_page_back_route = back
	add_child(screen)


# --- 私聊的长连接（docs/聊天系统设计.md 批次 B 的接线）-------------------------
#
# **接线在这里**，理由同下面在线状态上报那一段：Main 是唯一同时知道账号、界面与
# 对局状态的地方。RealtimeService 只管连接，ChatService 只管状态；
# 谁弹框、什么时候弹由这里定。

# 被顶号的提示还没弹（对局中被顶号时先挂着，回到主菜单再弹）。
var _kicked_notice_pending := false


func _install_realtime() -> void:
	if AccountManager.is_logged_in():
		RealtimeService.start()
	if not AccountManager.login_succeeded.is_connected(_on_realtime_login):
		AccountManager.login_succeeded.connect(_on_realtime_login)
	if not AccountManager.logged_out.is_connected(_on_realtime_logout):
		AccountManager.logged_out.connect(_on_realtime_logout)
	if not RealtimeService.kicked_by_other_device.is_connected(_on_realtime_kicked):
		RealtimeService.kicked_by_other_device.connect(_on_realtime_kicked)


# ⚠️ RealtimeService.start() 只挂在「登录成功」上（那只发生在启动时）。
# **不要**把它挂到回主菜单、切前台这类会反复发生的事件上：被顶号之后它会被
# 自动拉起来，两台设备开始无限互踢。被顶号后再连只能是玩家亲手点
# （ChatService.reconnect_here）。
func _on_realtime_login(_player_id: String, _player_name: String) -> void:
	RealtimeService.start()


func _on_realtime_logout() -> void:
	RealtimeService.stop()
	ChatService.reset()
	AnnouncementService.reset()
	MailService.reset()
	_kicked_notice_pending = false


# 🔴 被顶号：**只在主菜单上弹**，对局中先挂着（设计文档第五节）。
# 弹窗会直接打断操作；而战斗连接本来就不受这套机制影响，回主菜单再说清楚不迟。
func _on_realtime_kicked() -> void:
	_kicked_notice_pending = true
	if _menu != null and is_instance_valid(_menu) and _menu.is_inside_tree():
		_show_kicked_notice_if_pending()


func _show_kicked_notice_if_pending() -> void:
	if not _kicked_notice_pending:
		return
	_kicked_notice_pending = false
	var en := LocaleManager.get_locale() == "en"
	# 必须手动点确认，不倒计时、不自动跳转；文案要说清楚是**什么事**，
	# 而不是「连接已断开」「登录已失效」这类什么都没说的话。
	# 今天没有登录界面可回（匿名账号），所以确认之后停在原地：聊天保持断开，
	# 在聊天界面里点「在本设备重新连接」才会再连。
	var body := "你的账号在另一台设备上登录了，这里的聊天已断开。可以在聊天界面里重新连接。"
	if en:
		body = "Your account signed in on another device, so chat here was disconnected. You can reconnect from the Chat screen."
	DialogService.info({
		"request_id": "realtime_kicked",
		"owner": self,
		"title": "Signed in elsewhere" if en else "账号在另一台设备登录",
		"body": body,
		"confirm_text": "Got it" if en else "知道了",
	})


# --- 公告（docs/公告系统设计.md）------------------------------------------------
#
# 状态在 AnnouncementService；**弹窗什么时候弹由这里定**（同上面被顶号那一段的理由）：
# 只在主菜单上、没有别的弹窗、新手教学走完之后。

const ANNOUNCEMENT_POPUP_MODAL_ID := "announcement_popup"
# 最低一档：被顶号提示（DialogService 100）、重连（90）、房间面板（40）都比它要紧。
const ANNOUNCEMENT_POPUP_PRIORITY := 20
# 运行时 load，不 preload：理由见 _load_screen 上面那段。
const ANNOUNCEMENT_POPUP_SCRIPT := "res://scenes/menu/AnnouncementPopup.gd"


func _show_announcements_screen(focus_id: int = 0) -> void:
	_clear()
	var screen = _instantiate_screen("res://scenes/menu/AnnouncementScreen.tscn")
	if screen == null:
		_show_menu()
		return
	screen.configure(focus_id)
	screen.back_requested.connect(_show_menu)
	screen.navigate_requested.connect(_on_announcement_navigate)
	_page_back_route = _show_menu
	add_child(screen)


# 正文里 [url=glory://…] 的跳转。与 AnnouncementText.ROUTES 一一对应（tools/announcement_check 钉着）。
func _on_announcement_navigate(route: String) -> void:
	match route:
		"prep":
			_show_pet_screen()
		"codex":
			_show_codex_screen()
		"friends":
			_show_friends_screen()
		"profile":
			_show_profile_screen()


func _queue_announcement_popup() -> void:
	if not AnnouncementService.changed.is_connected(_on_announcements_changed):
		AnnouncementService.changed.connect(_on_announcements_changed)
	if not ModalStack.modal_closed.is_connected(_on_modal_closed_for_announcements):
		ModalStack.modal_closed.connect(_on_modal_closed_for_announcements)
	_try_show_announcement_popup.call_deferred()


func _on_announcements_changed() -> void:
	_try_show_announcement_popup.call_deferred()


# ⚠️ 必须 deferred：ModalStack.close_all() 边关边同步发 modal_closed，
# 在这里直接 push 会让它原地转死（同 _on_reconnect_modal_closed 那条）。
# 也正是这条让多条弹窗排队：关掉一条，下一条接着出来（一次启动最多 3 条）。
func _on_modal_closed_for_announcements(_id: String, _reason: String) -> void:
	_try_show_announcement_popup.call_deferred()


func _try_show_announcement_popup() -> void:
	if not _can_show_announcement_popup():
		return
	var item := AnnouncementService.next_popup()
	if item.is_empty():
		return
	var popup_script := load(ANNOUNCEMENT_POPUP_SCRIPT) as GDScript
	if popup_script == null:
		push_error("公告弹窗脚本加载失败：%s" % ANNOUNCEMENT_POPUP_SCRIPT)
		return
	var popup = popup_script.new()
	var modal_id := ModalStack.push(popup, {
		"id": ANNOUNCEMENT_POPUP_MODAL_ID,
		"owner": _menu,
		"priority": ANNOUNCEMENT_POPUP_PRIORITY,
		# 纯提示，点外面就收起。
		"dismiss_on_backdrop": true,
	})
	if modal_id.is_empty():
		return
	# 弹出来那一刻就记下：图片还没下完玩家就切走了，也不该下次再弹同一条。
	AnnouncementService.mark_popped(item)
	popup.configure(item)
	popup.details_requested.connect(_on_announcement_popup_details)
	popup.dismissed.connect(_close_announcement_popup)


func _can_show_announcement_popup() -> bool:
	if _menu == null or not is_instance_valid(_menu) or not _menu.is_inside_tree():
		return false
	# 有别的弹窗（被顶号提示、房间面板……）就等它关掉：modal_closed 会再叫一次。
	if ModalStack.depth() > 0:
		return false
	# 新手教学没走完不弹：第一次进游戏就被公告糊一脸。
	if TutorialMode.active:
		return false
	return not (PlayerProfile.onboarding_status in
		[PlayerProfile.ONBOARDING_NOT_STARTED, PlayerProfile.ONBOARDING_IN_PROGRESS])


func _on_announcement_popup_details(id: int) -> void:
	ModalStack.pop(ANNOUNCEMENT_POPUP_MODAL_ID)
	_show_announcements_screen(id)


func _close_announcement_popup() -> void:
	ModalStack.pop(ANNOUNCEMENT_POPUP_MODAL_ID)


# --- 在线状态上报（docs/交友系统设计.md 第二节）--------------------------------
#
# **接线在这里，不在 AccountManager 里。** 账号门面（HTTPS）与战斗门面（ENet）
# 是两条链路，不该互相认识（docs/账号系统RFC.md 第三节），所以房间号是通过一个
# Callable 注入进去的，而这一处是唯一同时知道两边的地方。
#
# 上报的只有「我在线」和「我在哪个房间」。房间号是**客户端自报**的 ——
# 谎报只能让好友进错房间，而房间号本来就是任何人知道号就能进。
# ⚠️ 这条边界只对「说谎没收益」的数据成立，别拿它承载战绩/奖励。
var _presence_last_room := -1


func _install_presence_reporting() -> void:
	AccountManager.configure_presence(func() -> int: return NetworkService.team_room_id)
	AccountManager.start_presence()
	# 登录成功后补一次：_ready 跑在登录之前，第一次心跳会因为还没登录被跳过，
	# 不补的话好友要等满一个心跳周期才看见我上线。
	if not AccountManager.login_succeeded.is_connected(_on_presence_login):
		AccountManager.login_succeeded.connect(_on_presence_login)
	# 进出房间时立刻补一次。慢 60 秒的话「点进去发现人已经走了」会很常见。
	if not NetworkService.team_lobby_changed.is_connected(_on_presence_room_changed):
		NetworkService.team_lobby_changed.connect(_on_presence_room_changed)
	if not NetworkService.session_changed.is_connected(_on_presence_room_changed):
		NetworkService.session_changed.connect(_on_presence_room_changed)


func _on_presence_login(_player_id: String, _player_name: String) -> void:
	AccountManager.report_presence_now()


# 只在**房间号真的变了**时上报。这两个信号在一局里会发很多次，
# 无条件上报等于把「慢心跳」变成高频轮询。
func _on_presence_room_changed() -> void:
	var room := NetworkService.team_room_id
	if room == _presence_last_room:
		return
	_presence_last_room = room
	AccountManager.report_presence_now()


# 看别人的资料页。好友列表点头像进来。
func _show_public_profile(friend_code: String) -> void:
	_clear()
	var profile := _instantiate_screen("res://scenes/menu/ProfileScreen.tscn")
	if profile == null:
		_show_friends_screen()
		return
	profile.call("configure_public", friend_code)
	# 返回回好友列表，不是主菜单 —— 玩家是从那里进来的。
	profile.back_requested.connect(_show_friends_screen)
	_page_back_route = _show_friends_screen
	add_child(profile)


func _show_profile_screen() -> void:
	_clear()
	var profile := _instantiate_screen("res://scenes/menu/ProfileScreen.tscn")
	if profile == null:
		_show_menu()
		return
	profile.call("configure_self")
	profile.back_requested.connect(_show_menu)
	_page_back_route = _show_menu
	add_child(profile)

# 宠物归属到手之后补判一次三选一。
#
# 两条路会走到这里：① 冷启动时玩家已经进了主菜单，拉取才回来；
# ② 注销账号之后（reset_account_state 把 pets_loaded 清了，新身份没有任何宠物）。
# 不补这一下，这两种情况玩家会停在一个没有宠物的主菜单里，而且没有任何提示。
func _on_pets_changed() -> void:
	if not PlayerProfile.pets_loaded or not PlayerProfile.needs_starter_pick:
		return
	# 只在主菜单上拦。对局中、或已经在三选一页上时都不许打断。
	if _menu == null or not is_instance_valid(_menu) or not _menu.is_inside_tree():
		return
	_show_starter_pet_gate()


# 首次启动的初始宠物三选一关卡：无返回按钮，选完后再进主菜单。
func _show_starter_pet_gate() -> void:
	_clear()
	var pet_screen := _instantiate_screen("res://scenes/menu/PetScreen.tscn")
	pet_screen.starter_picked.connect(_show_menu)
	add_child(pet_screen)

# --- 匹配队列（协议 32，docs/排位系统设计.md 第五、九节）---------------------------
#
# 排队、确认框、状态机全在 MatchQueuePanel 身上；这里只管两件事：
# 把它推上 ModalStack，以及拿到 ready 之后去连战斗服务器。
#
# 连接流程照 _start_create_room_action 那条，但**不走 AsyncActionController** ——
# 面板自己在显示进度，而且它是模态的，玩家点不到第二次。
const MATCH_QUEUE_MODAL_ID := "main_menu_match_queue"
const MatchQueuePanel := preload("res://scenes/menu/MatchQueuePanel.gd")


func _show_casual_queue() -> void:
	_show_match_queue("casual")


# 排位。窗口 / 信誉分 / 禁赛的闸全在服务器（`ranked.queue_gate`）——
# 客户端改系统时区就能绕过本地判断，而排位是发分的。
# 这里照常开面板，面板把服务器给的原因显示出来。
func _show_ranked_queue() -> void:
	_show_match_queue("ranked")


func _show_match_queue(mode: String) -> void:
	if ModalStack.has(MATCH_QUEUE_MODAL_ID):
		return
	var panel := MatchQueuePanel.new() as Control
	panel.call("configure", mode)
	panel.connect("match_ready", _on_match_ready)
	panel.connect("dismissed", func() -> void: ModalStack.pop(MATCH_QUEUE_MODAL_ID))
	ModalStack.push(panel, {
		"id": MATCH_QUEUE_MODAL_ID,
		"owner": self,
		"priority": 40,
		# 🔴 **不许点背景关掉。** 确认框那 30 秒里误触一下背景就等于拒绝，
		# 而拒绝会把自己移出队列、还拆掉另外五个人那一桌。
		"dismiss_on_backdrop": false,
	})


func _on_match_ready() -> void:
	ModalStack.pop(MATCH_QUEUE_MODAL_ID)
	var target_port := NetworkService.DEFAULT_PORT
	if NetworkService.team_active and NetworkService.remote_port != target_port:
		NetworkService.disconnect_session()
	elif NetworkService.team_active 			and NetworkService.state == NetworkService.SessionState.READY 			and NetworkService.team_local_slot < 0:
		NetworkService.team_request_join_matched()
		_watch_matched_lobby()
		return
	if NetworkService.team_active and NetworkService.team_local_slot >= 0:
		NetworkService.disconnect_session()
	if not NetworkService.team_join(NetworkService.DEFAULT_HOST, target_port):
		if is_instance_valid(_menu):
			_menu.show_connection_error(NetworkService.last_error)
		return
	if not NetworkService.session_changed.is_connected(_on_matched_session_changed):
		NetworkService.session_changed.connect(_on_matched_session_changed)


func _on_matched_session_changed() -> void:
	match NetworkService.state:
		NetworkService.SessionState.READY:
			_disconnect_matched_handlers()
			NetworkService.team_request_join_matched()
			_watch_matched_lobby()
		NetworkService.SessionState.FAILED, NetworkService.SessionState.OFFLINE:
			_disconnect_matched_handlers()
			if is_instance_valid(_menu):
				var message := NetworkService.last_error if NetworkService.last_error != "" else tr("net_err_connect_generic")
				_menu.show_connection_error(message)


func _watch_matched_lobby() -> void:
	if not NetworkService.team_lobby_changed.is_connected(_on_matched_lobby_changed):
		NetworkService.team_lobby_changed.connect(_on_matched_lobby_changed)


func _on_matched_lobby_changed() -> void:
	if NetworkService.team_local_slot < 0:
		return
	_disconnect_matched_handlers()
	# 进 3v3 大厅。匹配对局没有「准备」按钮那一步 —— 六个人到齐服务器自己开打
	# （NetworkService._matched_try_start），玩家在这里只会看到座位一个个填满。
	_show_team3v3_lobby()


func _disconnect_matched_handlers() -> void:
	if NetworkService.session_changed.is_connected(_on_matched_session_changed):
		NetworkService.session_changed.disconnect(_on_matched_session_changed)
	if NetworkService.team_lobby_changed.is_connected(_on_matched_lobby_changed):
		NetworkService.team_lobby_changed.disconnect(_on_matched_lobby_changed)


func _show_team3v3_lobby() -> void:
	_clear()
	_enter_match_flow()
	var lobby := _instantiate_screen("res://scenes/menu/Team3v3Lobby.tscn")
	lobby.start_requested.connect(_on_team3v3_start)
	lobby.back_requested.connect(_on_lobby_back)
	_page_back_route = _on_lobby_back
	lobby.selftest_requested.connect(_show_selftest)
	add_child(lobby)

# 离线自测·单位测试模式(officetest):独立场景,不走备战/回合/存档,
# 返回时还原 team_mode,不在 GameState 留任何痕迹。
func _show_selftest() -> void:
	if not ResourceLoader.exists("res://officetest/OfficeTestScreen.tscn", "PackedScene"):
		push_warning("officetest scene unavailable; keeping current lobby")
		return
	_clear()
	_enter_match_flow()
	_selftest_prev_team_mode = GameState.team_mode
	GameState.team_mode = true
	# load() (not preload) so this optional officetest scene never becomes a
	# parse-time dependency of Main on a cold boot before its .import exists.
	#
	# V3 P1-07：officetest/ 不进 Release 包（见 export_presets.cfg 的
	# exclude_filter）。这条路唯一的生产入口（Team3v3Lobby 的自测按钮）已经
	# 按 OS.is_debug_build() 关掉了，这里再判一次空是防御性的 —— 万一以后
	# 多出第二个入口，不会重演对 null 调 instantiate() 崩溃。
	var packed := load("res://officetest/OfficeTestScreen.tscn") as PackedScene
	if packed == null:
		push_warning("officetest scene unavailable; returning to lobby")
		GameState.team_mode = _selftest_prev_team_mode
		_show_team3v3_lobby()
		return
	var screen: Node = packed.instantiate()
	screen.back_requested.connect(_on_selftest_back)
	_page_back_route = _on_selftest_back
	add_child(screen)

func _on_selftest_back() -> void:
	GameState.team_mode = _selftest_prev_team_mode
	_show_team3v3_lobby()

func _on_lobby_back() -> void:
	if _lobby_exit_requires_cancel():
		DialogService.info({"owner": self, "body": "Please cancel ready first" if LocaleManager.get_locale() == "en" else "请先取消准备"})
		return
	NetworkService.disconnect_session()
	_show_menu()

func _lobby_exit_requires_cancel() -> bool:
	if not NetworkService.team_active or NetworkService.can_control_room():
		return false
	var slot := NetworkService.team_local_slot
	var confirmed := slot >= 0 and slot < NetworkService.team_ready.size() and bool(NetworkService.team_ready[slot])
	# 准备请求尚在途也不能退出；取消准备须等待服务器确认后再离开。
	return confirmed or NetworkService.local_ready_intent()

func _show_prep() -> void:
	# 保底：对局已结束（最终局打完）就不再进备战，直接游戏结束界面。
	# 堵住任何"结束后又被导航回备战"的残留路径（配合服务器封顶/不再开回合）。
	if GameState.team_mode and GameState.final_round_played:
		_show_game_over()
		return
	_clear()
	_enter_match_flow()
	_prep = _instantiate_screen("res://scenes/prep/PrepScreen.tscn")
	_prep.battle_requested.connect(_on_battle_requested)
	add_child(_prep)
	SaveManager.save_run()

func _show_battle(battle_scene: PackedScene = null) -> void:
	_clear()
	_enter_match_flow()
	var scene := battle_scene if battle_scene != null else _load_screen("res://scenes/battle/BattleScreen.tscn")
	_battle = scene.instantiate()
	_battle.battle_finished.connect(_on_battle_finished)
	add_child(_battle)

func _show_game_over() -> void:
	# 对局结束：重连凭证作废，避免下次启动误恢复到已结束的房间
	SaveManager.clear_reconnect()
	_clear()
	_enter_match_flow()
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.06, 0.07)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	bg.z_index = -10

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := VBoxContainer.new()
	panel.custom_minimum_size = Vector2(420, 0)
	panel.add_theme_constant_override("separation", 12)
	center.add_child(panel)

	var title := Label.new()
	title.text = _game_over_title()
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color(0.96, 0.92, 0.78))
	panel.add_child(title)

	var body := Label.new()
	body.text = _game_over_body()
	body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size = Vector2(420, 90)
	body.add_theme_color_override("font_color", Color(0.86, 0.9, 0.9))
	panel.add_child(body)

	var menu_btn := Button.new()
	menu_btn.text = tr("gameover_back")
	menu_btn.custom_minimum_size = Vector2(180, 40)
	menu_btn.pressed.connect(_on_return_menu_requested)
	panel.add_child(menu_btn)

func _on_team_host_requested() -> void:
	# Debug-only local host. Production Android clients connect to the VPS.
	if NetworkService.team_host(NetworkService.DEFAULT_PORT):
		_show_team3v3_lobby()
	elif is_instance_valid(_menu) and _menu.has_method("show_connection_error"):
		_menu.show_connection_error(NetworkService.last_error)

func _on_team_join_requested(address: String = NetworkService.DEFAULT_HOST) -> void:
	if not await NetworkService.allow_new_match():
		return
	# Client-side production path: connect to the dedicated ENet server.
	# 开始新游戏 = 放弃上一场：清本地重连凭证，并让服务器把旧座位交给 AI
	# （若旧房间还有其他玩家；没人就靠超时自清）。之后从此连不回旧局。
	var rc := SaveManager.load_reconnect()
	var abandon_token := str(rc.get("token", ""))
	SaveManager.clear_reconnect()
	if not NetworkService.team_join(address, NetworkService.DEFAULT_PORT):
		if is_instance_valid(_menu) and _menu.has_method("show_connection_error"):
			_menu.show_connection_error(NetworkService.last_error)
		return
	if is_instance_valid(_menu) and _menu.has_method("show_connecting"):
		_menu.show_connecting()
	# 记下要放弃的旧座位 token，连上后由 NetworkService 发 abandon
	NetworkService.pending_abandon_token = abandon_token
	if not NetworkService.session_changed.is_connected(_on_pending_join_session_changed):
		NetworkService.session_changed.connect(_on_pending_join_session_changed)

func _on_pending_join_session_changed() -> void:
	match NetworkService.state:
		NetworkService.SessionState.READY:
			NetworkService.session_changed.disconnect(_on_pending_join_session_changed)
			_show_team3v3_lobby()
		NetworkService.SessionState.FAILED, NetworkService.SessionState.OFFLINE:
			NetworkService.session_changed.disconnect(_on_pending_join_session_changed)
			if is_instance_valid(_menu) and _menu.has_method("show_connection_error"):
				_menu.show_connection_error(NetworkService.last_error if NetworkService.last_error != "" else "连接失败")

func _on_team_room_list_requested() -> void:
	AsyncActionController.record_input_received(ROOM_LIST_ACTION, ROOM_LIST_CONTROL_ID)
	_start_room_list_action()

func _on_team_room_create_requested() -> void:
	AsyncActionController.record_input_received(CREATE_ROOM_ACTION, CREATE_ROOM_CONTROL_ID)
	_start_create_room_action()

func _on_team_room_join_requested(room_id: int) -> void:
	AsyncActionController.record_input_received(JOIN_ROOM_ACTION, JOIN_ROOM_CONTROL_ID)
	_start_join_room_action(room_id)

func _on_public_token_generate_requested() -> void:
	AsyncActionController.record_input_received(PUBLIC_TOKEN_ACTION, PUBLIC_TOKEN_CONTROL_ID)
	_start_public_token_action()

func _on_public_token_resume_requested(token_id: String) -> void:
	AsyncActionController.record_input_received(
		SHORT_CODE_RESUME_ACTION, SHORT_CODE_RESUME_CONTROL_ID)
	_start_short_code_resume_action(token_id)


# First C-10 migration: public-token generation owns a request identity instead
# of sharing the legacy string-valued pending slot with four unrelated actions.
# The wire protocol is unchanged; only client-side lifecycle/late-result handling
# moves under AsyncActionController.
func _start_public_token_action() -> void:
	_supersede_other_team_action(PUBLIC_TOKEN_ACTION)
	var owner: Object = _menu if _menu != null and is_instance_valid(_menu) else self
	var request_id := AsyncActionController.begin(PUBLIC_TOKEN_ACTION, {
		"owner": owner,
		"control_id": PUBLIC_TOKEN_CONTROL_ID,
		"timeout_msec": PUBLIC_TOKEN_TIMEOUT_MSEC,
		"cancellable": true,
		"stage": "connect",
	})
	if request_id.is_empty():
		return
	# begin() deliberately returns the current id for duplicate presses. Do not
	# turn that accepted action into another network request.
	if request_id == _public_token_request_id \
			and AsyncActionController.is_current(request_id):
		return
	_public_token_request_id = request_id
	_public_token_waiting_for_session = false
	_disconnect_public_token_session_handler()
	AsyncActionController.mark_pending(request_id)
	if is_instance_valid(_menu):
		_menu.show_connecting()

	var target_port := NetworkService.DEFAULT_PORT
	NetworkService._net_log("public token action request=%s port=%d active=%s state=%d slot=%d" % [
		request_id, target_port, str(NetworkService.team_active),
		int(NetworkService.state), int(NetworkService.team_local_slot)])
	if NetworkService.team_active and NetworkService.remote_port != target_port:
		NetworkService.disconnect_session()
	elif NetworkService.team_active \
			and NetworkService.state == NetworkService.SessionState.READY \
			and NetworkService.team_local_slot < 0:
		_dispatch_public_token_request(request_id)
		return
	if NetworkService.team_active and NetworkService.team_local_slot >= 0:
		NetworkService.disconnect_session()
	if not NetworkService.team_join(NetworkService.DEFAULT_HOST, target_port):
		AsyncActionController.fail(request_id, "TOKEN_CONNECT_START_FAILED", true)
		if is_instance_valid(_menu):
			_menu.show_connection_error(NetworkService.last_error)
		return
	_public_token_waiting_for_session = true
	if not NetworkService.session_changed.is_connected(_on_public_token_session_changed):
		NetworkService.session_changed.connect(_on_public_token_session_changed)


func _on_public_token_session_changed() -> void:
	var request_id := _public_token_request_id
	if request_id.is_empty() or not AsyncActionController.is_current(request_id):
		_disconnect_public_token_session_handler()
		return
	match NetworkService.state:
		NetworkService.SessionState.READY:
			_dispatch_public_token_request(request_id)
		NetworkService.SessionState.FAILED, NetworkService.SessionState.OFFLINE:
			_disconnect_public_token_session_handler()
			AsyncActionController.fail(request_id, "TOKEN_CONNECT_FAILED", true)
			if is_instance_valid(_menu):
				var message := NetworkService.last_error if NetworkService.last_error != "" else tr("net_err_connect_generic")
				_menu.show_connection_error(message)


func _dispatch_public_token_request(request_id: String) -> void:
	if request_id != _public_token_request_id \
			or not AsyncActionController.is_current(request_id):
		return
	_disconnect_public_token_session_handler()
	AsyncActionController.update_context(request_id, {"stage": "request_token"})
	if OS.is_debug_build() and _public_token_request_check_hook.is_valid():
		public_token_request_check_requested.emit(request_id)
		return
	NetworkService.team_request_public_token()


func _disconnect_public_token_session_handler() -> void:
	_public_token_waiting_for_session = false
	if NetworkService.session_changed.is_connected(_on_public_token_session_changed):
		NetworkService.session_changed.disconnect(_on_public_token_session_changed)


func _on_async_action_state_changed(
	action: String,
	request_id: String,
	state: String,
	_snapshot: Dictionary
) -> void:
	if action == SHORT_CODE_RESUME_ACTION:
		_on_short_code_resume_action_state_changed(request_id, state)
		return
	if action == JOIN_ROOM_ACTION:
		_on_join_room_action_state_changed(request_id, state)
		return
	if action == CREATE_ROOM_ACTION:
		_on_create_room_action_state_changed(request_id, state)
		return
	if action == ROOM_LIST_ACTION:
		_on_room_list_action_state_changed(request_id, state)
		return
	if action != PUBLIC_TOKEN_ACTION or request_id != _public_token_request_id:
		return
	match state:
		AsyncActionController.STATE_SUCCEEDED, AsyncActionController.STATE_FAILED:
			_disconnect_public_token_session_handler()
		AsyncActionController.STATE_TIMED_OUT:
			var was_connecting := _public_token_waiting_for_session
			_disconnect_public_token_session_handler()
			if was_connecting:
				NetworkService.disconnect_session()
			if is_instance_valid(_menu):
				_menu.show_connection_error(tr("net_err_timeout") % [
					NetworkService.DEFAULT_HOST, NetworkService.DEFAULT_PORT])
		AsyncActionController.STATE_CANCELLED:
			var was_connecting := _public_token_waiting_for_session
			_disconnect_public_token_session_handler()
			if was_connecting:
				NetworkService.disconnect_session()


# Debug-only seams let the production wiring gate drive all terminal paths
# without opening a socket or exposing a fake endpoint in release builds.
func set_public_token_request_check_hook(hook: Callable) -> bool:
	if not OS.is_debug_build():
		return false
	if _public_token_request_check_hook.is_valid() \
			and public_token_request_check_requested.is_connected(_public_token_request_check_hook):
		public_token_request_check_requested.disconnect(_public_token_request_check_hook)
	_public_token_request_check_hook = hook
	if _public_token_request_check_hook.is_valid():
		public_token_request_check_requested.connect(_public_token_request_check_hook)
	return true


func set_public_token_menu_for_check(menu: Control) -> bool:
	if not OS.is_debug_build():
		return false
	_menu = menu
	return true


func public_token_request_id_for_check() -> String:
	return _public_token_request_id if OS.is_debug_build() else ""


# Second C-10 migration. Room-list refresh has its own request identity so a
# closed/replaced menu cannot be updated by a late server list.
func _start_room_list_action() -> void:
	_supersede_other_team_action(ROOM_LIST_ACTION)
	var owner: Object = _menu if _menu != null and is_instance_valid(_menu) else self
	var request_id := AsyncActionController.begin(ROOM_LIST_ACTION, {
		"owner": owner,
		"control_id": ROOM_LIST_CONTROL_ID,
		"timeout_msec": ROOM_LIST_TIMEOUT_MSEC,
		"cancellable": true,
		"stage": "connect",
	})
	if request_id.is_empty():
		return
	if request_id == _room_list_request_id \
			and AsyncActionController.is_current(request_id):
		return
	_room_list_request_id = request_id
	_room_list_waiting_for_session = false
	_disconnect_room_list_session_handler()
	AsyncActionController.mark_pending(request_id)
	if is_instance_valid(_menu):
		_menu.show_connecting()

	var target_port := NetworkService.DEFAULT_PORT
	NetworkService._net_log("room list action request=%s port=%d active=%s state=%d slot=%d" % [
		request_id, target_port, str(NetworkService.team_active),
		int(NetworkService.state), int(NetworkService.team_local_slot)])
	if NetworkService.team_active and NetworkService.remote_port != target_port:
		NetworkService.disconnect_session()
	elif NetworkService.team_active \
			and NetworkService.state == NetworkService.SessionState.READY \
			and NetworkService.team_local_slot < 0:
		_dispatch_room_list_request(request_id)
		return
	if NetworkService.team_active and NetworkService.team_local_slot >= 0:
		NetworkService.disconnect_session()
	if not NetworkService.team_join(NetworkService.DEFAULT_HOST, target_port):
		AsyncActionController.fail(request_id, "ROOM_LIST_CONNECT_START_FAILED", true)
		if is_instance_valid(_menu):
			_menu.show_connection_error(NetworkService.last_error)
		return
	_room_list_waiting_for_session = true
	if not NetworkService.session_changed.is_connected(_on_room_list_session_changed):
		NetworkService.session_changed.connect(_on_room_list_session_changed)


func _on_room_list_session_changed() -> void:
	var request_id := _room_list_request_id
	if request_id.is_empty() or not AsyncActionController.is_current(request_id):
		_disconnect_room_list_session_handler()
		return
	match NetworkService.state:
		NetworkService.SessionState.READY:
			_dispatch_room_list_request(request_id)
		NetworkService.SessionState.FAILED, NetworkService.SessionState.OFFLINE:
			_disconnect_room_list_session_handler()
			AsyncActionController.fail(request_id, "ROOM_LIST_CONNECT_FAILED", true)
			if is_instance_valid(_menu):
				var message := NetworkService.last_error if NetworkService.last_error != "" else tr("net_err_connect_generic")
				_menu.show_connection_error(message)


func _dispatch_room_list_request(request_id: String) -> void:
	if request_id != _room_list_request_id \
			or not AsyncActionController.is_current(request_id):
		return
	_disconnect_room_list_session_handler()
	AsyncActionController.update_context(request_id, {"stage": "request_room_list"})
	if OS.is_debug_build() and _room_list_request_check_hook.is_valid():
		room_list_request_check_requested.emit(request_id)
		return
	NetworkService.team_request_room_list()


func _disconnect_room_list_session_handler() -> void:
	_room_list_waiting_for_session = false
	if NetworkService.session_changed.is_connected(_on_room_list_session_changed):
		NetworkService.session_changed.disconnect(_on_room_list_session_changed)


func _on_room_list_action_state_changed(request_id: String, state: String) -> void:
	if request_id != _room_list_request_id:
		return
	match state:
		AsyncActionController.STATE_SUCCEEDED, AsyncActionController.STATE_FAILED:
			_disconnect_room_list_session_handler()
		AsyncActionController.STATE_TIMED_OUT:
			var was_connecting := _room_list_waiting_for_session
			_disconnect_room_list_session_handler()
			if was_connecting:
				NetworkService.disconnect_session()
			if is_instance_valid(_menu):
				_menu.show_connection_error(tr("net_err_timeout") % [
					NetworkService.DEFAULT_HOST, NetworkService.DEFAULT_PORT])
		AsyncActionController.STATE_CANCELLED:
			var was_connecting := _room_list_waiting_for_session
			_disconnect_room_list_session_handler()
			if was_connecting:
				NetworkService.disconnect_session()


func set_room_list_request_check_hook(hook: Callable) -> bool:
	if not OS.is_debug_build():
		return false
	if _room_list_request_check_hook.is_valid() \
			and room_list_request_check_requested.is_connected(_room_list_request_check_hook):
		room_list_request_check_requested.disconnect(_room_list_request_check_hook)
	_room_list_request_check_hook = hook
	if _room_list_request_check_hook.is_valid():
		room_list_request_check_requested.connect(_room_list_request_check_hook)
	return true


func set_team_menu_for_check(menu: Control) -> bool:
	if not OS.is_debug_build():
		return false
	_menu = menu
	return true


func room_list_request_id_for_check() -> String:
	return _room_list_request_id if OS.is_debug_build() else ""


# Third C-10 migration. Creating a room is state-changing, so cancellation or a
# deadline also tears down the transport after dispatch; that prevents a late
# slot assignment from leaving the player inside a room after the UI abandoned
# the request. The server protocol and create-room RPC remain unchanged.
func _start_create_room_action() -> void:
	if not await NetworkService.allow_new_match():
		return
	_supersede_other_team_action(CREATE_ROOM_ACTION)
	var owner: Object = _menu if _menu != null and is_instance_valid(_menu) else self
	var request_id := AsyncActionController.begin(CREATE_ROOM_ACTION, {
		"owner": owner,
		"control_id": CREATE_ROOM_CONTROL_ID,
		"timeout_msec": CREATE_ROOM_TIMEOUT_MSEC,
		"cancellable": true,
		"stage": "connect",
	})
	if request_id.is_empty():
		return
	if request_id == _create_room_request_id \
			and AsyncActionController.is_current(request_id):
		return
	_create_room_request_id = request_id
	_create_room_waiting_for_session = false
	_create_room_request_dispatched = false
	_disconnect_create_room_handlers()
	AsyncActionController.mark_pending(request_id)
	if is_instance_valid(_menu):
		_menu.show_connecting()

	var target_port := NetworkService.DEFAULT_PORT
	NetworkService._net_log("create room action request=%s port=%d active=%s state=%d slot=%d" % [
		request_id, target_port, str(NetworkService.team_active),
		int(NetworkService.state), int(NetworkService.team_local_slot)])
	if NetworkService.team_active and NetworkService.remote_port != target_port:
		NetworkService.disconnect_session()
	elif NetworkService.team_active \
			and NetworkService.state == NetworkService.SessionState.READY \
			and NetworkService.team_local_slot < 0:
		_dispatch_create_room_request(request_id)
		return
	if NetworkService.team_active and NetworkService.team_local_slot >= 0:
		NetworkService.disconnect_session()
	if not NetworkService.team_join(NetworkService.DEFAULT_HOST, target_port):
		AsyncActionController.fail(request_id, "CREATE_ROOM_CONNECT_START_FAILED", true)
		if is_instance_valid(_menu):
			_menu.show_connection_error(NetworkService.last_error)
		return
	_create_room_waiting_for_session = true
	if not NetworkService.session_changed.is_connected(_on_create_room_session_changed):
		NetworkService.session_changed.connect(_on_create_room_session_changed)


func _on_create_room_session_changed() -> void:
	var request_id := _create_room_request_id
	if request_id.is_empty() or not AsyncActionController.is_current(request_id):
		_disconnect_create_room_handlers()
		return
	match NetworkService.state:
		NetworkService.SessionState.READY:
			_dispatch_create_room_request(request_id)
		NetworkService.SessionState.FAILED, NetworkService.SessionState.OFFLINE:
			_disconnect_create_room_handlers()
			AsyncActionController.fail(request_id, "CREATE_ROOM_CONNECT_FAILED", true)
			if is_instance_valid(_menu):
				var message := NetworkService.last_error if NetworkService.last_error != "" else tr("net_err_connect_generic")
				_menu.show_connection_error(message)


func _dispatch_create_room_request(request_id: String) -> void:
	if request_id != _create_room_request_id \
			or not AsyncActionController.is_current(request_id):
		return
	_disconnect_create_room_session_handler()
	_create_room_request_dispatched = true
	AsyncActionController.update_context(request_id, {"stage": "request_create_room"})
	if not NetworkService.team_lobby_changed.is_connected(_on_create_room_lobby_changed):
		NetworkService.team_lobby_changed.connect(_on_create_room_lobby_changed)
	if OS.is_debug_build() and _create_room_request_check_hook.is_valid():
		create_room_request_check_requested.emit(request_id)
		return
	NetworkService.team_request_create_room()


func _on_create_room_lobby_changed() -> void:
	if NetworkService.team_local_slot < 0:
		return
	var request_id := _create_room_request_id
	if request_id.is_empty() or not AsyncActionController.is_current(request_id):
		_disconnect_create_room_handlers()
		return
	if not AsyncActionController.succeed(request_id):
		return
	if OS.is_debug_build() and _create_room_navigation_check_hook.is_valid():
		create_room_navigation_check_requested.emit(request_id)
		return
	_show_team3v3_lobby()


func _disconnect_create_room_session_handler() -> void:
	_create_room_waiting_for_session = false
	if NetworkService.session_changed.is_connected(_on_create_room_session_changed):
		NetworkService.session_changed.disconnect(_on_create_room_session_changed)


func _disconnect_create_room_handlers() -> void:
	_disconnect_create_room_session_handler()
	if NetworkService.team_lobby_changed.is_connected(_on_create_room_lobby_changed):
		NetworkService.team_lobby_changed.disconnect(_on_create_room_lobby_changed)


func _on_create_room_action_state_changed(request_id: String, state: String) -> void:
	if request_id != _create_room_request_id:
		return
	match state:
		AsyncActionController.STATE_SUCCEEDED, AsyncActionController.STATE_FAILED:
			_disconnect_create_room_handlers()
			_create_room_request_dispatched = false
		AsyncActionController.STATE_TIMED_OUT:
			var must_disconnect := _create_room_waiting_for_session \
				or _create_room_request_dispatched
			_disconnect_create_room_handlers()
			_create_room_request_dispatched = false
			if must_disconnect:
				NetworkService.disconnect_session()
			if is_instance_valid(_menu):
				_menu.show_connection_error(tr("net_err_timeout") % [
					NetworkService.DEFAULT_HOST, NetworkService.DEFAULT_PORT])
		AsyncActionController.STATE_CANCELLED:
			var must_disconnect := _create_room_waiting_for_session \
				or _create_room_request_dispatched
			_disconnect_create_room_handlers()
			_create_room_request_dispatched = false
			if must_disconnect:
				NetworkService.disconnect_session()


func set_create_room_request_check_hook(hook: Callable) -> bool:
	if not OS.is_debug_build():
		return false
	if _create_room_request_check_hook.is_valid() \
			and create_room_request_check_requested.is_connected(_create_room_request_check_hook):
		create_room_request_check_requested.disconnect(_create_room_request_check_hook)
	_create_room_request_check_hook = hook
	if _create_room_request_check_hook.is_valid():
		create_room_request_check_requested.connect(_create_room_request_check_hook)
	return true


func set_create_room_navigation_check_hook(hook: Callable) -> bool:
	if not OS.is_debug_build():
		return false
	if _create_room_navigation_check_hook.is_valid() \
			and create_room_navigation_check_requested.is_connected(_create_room_navigation_check_hook):
		create_room_navigation_check_requested.disconnect(_create_room_navigation_check_hook)
	_create_room_navigation_check_hook = hook
	if _create_room_navigation_check_hook.is_valid():
		create_room_navigation_check_requested.connect(_create_room_navigation_check_hook)
	return true


func create_room_request_id_for_check() -> String:
	return _create_room_request_id if OS.is_debug_build() else ""


# Fourth C-10 migration. The room id determines the dedicated-server shard, so
# both id and port are snapshotted for the request instead of reading a mutable
# shared pending slot after an asynchronous connect.
func _start_join_room_action(room_id: int) -> void:
	if not await NetworkService.allow_new_match():
		return
	if room_id <= 0:
		return
	_supersede_other_team_action(JOIN_ROOM_ACTION)
	var owner: Object = _menu if _menu != null and is_instance_valid(_menu) else self
	var request_id := AsyncActionController.begin(JOIN_ROOM_ACTION, {
		"owner": owner,
		"control_id": JOIN_ROOM_CONTROL_ID,
		"timeout_msec": JOIN_ROOM_TIMEOUT_MSEC,
		"cancellable": true,
		"stage": "connect",
		"room_id": room_id,
		"target_port": NetworkConfig.port_of_room(room_id),
	})
	if request_id.is_empty():
		return
	if request_id == _join_room_request_id \
			and AsyncActionController.is_current(request_id):
		return
	_join_room_request_id = request_id
	_join_room_id = room_id
	_join_room_target_port = NetworkConfig.port_of_room(room_id)
	_join_room_waiting_for_session = false
	_join_room_request_dispatched = false
	_disconnect_join_room_handlers()
	AsyncActionController.mark_pending(request_id)
	if is_instance_valid(_menu):
		_menu.show_connecting()

	NetworkService._net_log("join room action request=%s room=%d port=%d active=%s state=%d slot=%d" % [
		request_id, _join_room_id, _join_room_target_port,
		str(NetworkService.team_active), int(NetworkService.state),
		int(NetworkService.team_local_slot)])
	if NetworkService.team_active and NetworkService.remote_port != _join_room_target_port:
		NetworkService.disconnect_session()
	elif NetworkService.team_active \
			and NetworkService.state == NetworkService.SessionState.READY \
			and NetworkService.team_local_slot < 0:
		_dispatch_join_room_request(request_id)
		return
	if NetworkService.team_active and NetworkService.team_local_slot >= 0:
		NetworkService.disconnect_session()
	if not NetworkService.team_join(NetworkService.DEFAULT_HOST, _join_room_target_port):
		AsyncActionController.fail(request_id, "JOIN_ROOM_CONNECT_START_FAILED", true)
		if is_instance_valid(_menu):
			_menu.show_connection_error(NetworkService.last_error)
		return
	_join_room_waiting_for_session = true
	if not NetworkService.session_changed.is_connected(_on_join_room_session_changed):
		NetworkService.session_changed.connect(_on_join_room_session_changed)


func _on_join_room_session_changed() -> void:
	var request_id := _join_room_request_id
	if request_id.is_empty() or not AsyncActionController.is_current(request_id):
		_disconnect_join_room_handlers()
		return
	match NetworkService.state:
		NetworkService.SessionState.READY:
			_dispatch_join_room_request(request_id)
		NetworkService.SessionState.FAILED, NetworkService.SessionState.OFFLINE:
			_disconnect_join_room_handlers()
			AsyncActionController.fail(request_id, "JOIN_ROOM_CONNECT_FAILED", true)
			if is_instance_valid(_menu):
				var message := NetworkService.last_error if NetworkService.last_error != "" else tr("net_err_connect_generic")
				_menu.show_connection_error(message)


func _dispatch_join_room_request(request_id: String) -> void:
	if request_id != _join_room_request_id \
			or not AsyncActionController.is_current(request_id):
		return
	_disconnect_join_room_session_handler()
	_join_room_request_dispatched = true
	AsyncActionController.update_context(request_id, {
		"stage": "request_join_room",
		"room_id": _join_room_id,
		"target_port": _join_room_target_port,
	})
	if not NetworkService.team_lobby_changed.is_connected(_on_join_room_lobby_changed):
		NetworkService.team_lobby_changed.connect(_on_join_room_lobby_changed)
	if OS.is_debug_build() and _join_room_request_check_hook.is_valid():
		join_room_request_check_requested.emit(
			request_id, _join_room_id, _join_room_target_port)
		return
	NetworkService.team_request_join_room(_join_room_id)


func _on_join_room_lobby_changed() -> void:
	if NetworkService.team_local_slot < 0:
		return
	var request_id := _join_room_request_id
	if request_id.is_empty() or not AsyncActionController.is_current(request_id):
		_disconnect_join_room_handlers()
		return
	if not AsyncActionController.succeed(request_id):
		return
	if OS.is_debug_build() and _join_room_navigation_check_hook.is_valid():
		join_room_navigation_check_requested.emit(request_id)
		return
	_show_team3v3_lobby()


func _disconnect_join_room_session_handler() -> void:
	_join_room_waiting_for_session = false
	if NetworkService.session_changed.is_connected(_on_join_room_session_changed):
		NetworkService.session_changed.disconnect(_on_join_room_session_changed)


func _disconnect_join_room_handlers() -> void:
	_disconnect_join_room_session_handler()
	if NetworkService.team_lobby_changed.is_connected(_on_join_room_lobby_changed):
		NetworkService.team_lobby_changed.disconnect(_on_join_room_lobby_changed)


func _on_join_room_action_state_changed(request_id: String, state: String) -> void:
	if request_id != _join_room_request_id:
		return
	match state:
		AsyncActionController.STATE_SUCCEEDED, AsyncActionController.STATE_FAILED:
			_disconnect_join_room_handlers()
			_join_room_request_dispatched = false
		AsyncActionController.STATE_TIMED_OUT:
			var must_disconnect := _join_room_waiting_for_session \
				or _join_room_request_dispatched
			_disconnect_join_room_handlers()
			_join_room_request_dispatched = false
			if must_disconnect:
				NetworkService.disconnect_session()
			if is_instance_valid(_menu):
				_menu.show_connection_error(tr("net_err_timeout") % [
					NetworkService.DEFAULT_HOST, _join_room_target_port])
		AsyncActionController.STATE_CANCELLED:
			var must_disconnect := _join_room_waiting_for_session \
				or _join_room_request_dispatched
			_disconnect_join_room_handlers()
			_join_room_request_dispatched = false
			if must_disconnect:
				NetworkService.disconnect_session()


func set_join_room_request_check_hook(hook: Callable) -> bool:
	if not OS.is_debug_build():
		return false
	if _join_room_request_check_hook.is_valid() \
			and join_room_request_check_requested.is_connected(_join_room_request_check_hook):
		join_room_request_check_requested.disconnect(_join_room_request_check_hook)
	_join_room_request_check_hook = hook
	if _join_room_request_check_hook.is_valid():
		join_room_request_check_requested.connect(_join_room_request_check_hook)
	return true


func set_join_room_navigation_check_hook(hook: Callable) -> bool:
	if not OS.is_debug_build():
		return false
	if _join_room_navigation_check_hook.is_valid() \
			and join_room_navigation_check_requested.is_connected(_join_room_navigation_check_hook):
		join_room_navigation_check_requested.disconnect(_join_room_navigation_check_hook)
	_join_room_navigation_check_hook = hook
	if _join_room_navigation_check_hook.is_valid():
		join_room_navigation_check_requested.connect(_join_room_navigation_check_hook)
	return true


func join_room_request_id_for_check() -> String:
	return _join_room_request_id if OS.is_debug_build() else ""


# Fifth C-10 migration. The player-visible short code is normalized once and
# kept only in this private request path; it is never placed in AsyncAction's
# public snapshot or diagnostic breadcrumbs.
func _start_short_code_resume_action(raw_token_id: String) -> void:
	var token_id := raw_token_id.strip_edges().to_upper()
	if token_id.is_empty():
		return
	_supersede_other_team_action(SHORT_CODE_RESUME_ACTION)
	var owner: Object = _menu if _menu != null and is_instance_valid(_menu) else self
	var request_id := AsyncActionController.begin(SHORT_CODE_RESUME_ACTION, {
		"owner": owner,
		"control_id": SHORT_CODE_RESUME_CONTROL_ID,
		"timeout_msec": SHORT_CODE_RESUME_TIMEOUT_MSEC,
		"cancellable": true,
		"stage": "connect",
	})
	if request_id.is_empty():
		return
	if request_id == _short_code_resume_request_id \
			and AsyncActionController.is_current(request_id):
		return
	_short_code_resume_request_id = request_id
	_short_code_resume_token = token_id
	_short_code_resume_waiting_for_session = false
	_short_code_resume_request_dispatched = false
	_short_code_resume_ignore_late_result = false
	_disconnect_short_code_resume_session_handler()
	AsyncActionController.mark_pending(request_id)
	if is_instance_valid(_menu):
		_menu.show_connecting()

	var target_port := NetworkService.DEFAULT_PORT
	NetworkService._net_log("short code resume action request=%s port=%d active=%s state=%d slot=%d" % [
		request_id, target_port, str(NetworkService.team_active),
		int(NetworkService.state), int(NetworkService.team_local_slot)])
	if NetworkService.team_active and NetworkService.remote_port != target_port:
		NetworkService.disconnect_session()
	elif NetworkService.team_active \
			and NetworkService.state == NetworkService.SessionState.READY \
			and NetworkService.team_local_slot < 0:
		_dispatch_short_code_resume_request(request_id)
		return
	if NetworkService.team_active and NetworkService.team_local_slot >= 0:
		NetworkService.disconnect_session()
	if not NetworkService.team_join(NetworkService.DEFAULT_HOST, target_port):
		AsyncActionController.fail(request_id, "SHORT_CODE_CONNECT_START_FAILED", true)
		if is_instance_valid(_menu):
			_menu.show_connection_error(NetworkService.last_error)
		return
	_short_code_resume_waiting_for_session = true
	if not NetworkService.session_changed.is_connected(_on_short_code_resume_session_changed):
		NetworkService.session_changed.connect(_on_short_code_resume_session_changed)


func _on_short_code_resume_session_changed() -> void:
	var request_id := _short_code_resume_request_id
	if request_id.is_empty() or not AsyncActionController.is_current(request_id):
		_disconnect_short_code_resume_session_handler()
		return
	match NetworkService.state:
		NetworkService.SessionState.READY:
			_dispatch_short_code_resume_request(request_id)
		NetworkService.SessionState.FAILED, NetworkService.SessionState.OFFLINE:
			_disconnect_short_code_resume_session_handler()
			AsyncActionController.fail(request_id, "SHORT_CODE_CONNECT_FAILED", true)
			if is_instance_valid(_menu):
				var message := NetworkService.last_error if NetworkService.last_error != "" else tr("net_err_connect_generic")
				_menu.show_connection_error(message)


func _dispatch_short_code_resume_request(request_id: String) -> void:
	if request_id != _short_code_resume_request_id \
			or not AsyncActionController.is_current(request_id):
		return
	_disconnect_short_code_resume_session_handler()
	_short_code_resume_request_dispatched = true
	AsyncActionController.update_context(request_id, {"stage": "request_short_code_resume"})
	if OS.is_debug_build() and _short_code_resume_request_check_hook.is_valid():
		short_code_resume_request_check_requested.emit(request_id, _short_code_resume_token)
		return
	NetworkService.team_request_public_resume(_short_code_resume_token)


func _disconnect_short_code_resume_session_handler() -> void:
	_short_code_resume_waiting_for_session = false
	if NetworkService.session_changed.is_connected(_on_short_code_resume_session_changed):
		NetworkService.session_changed.disconnect(_on_short_code_resume_session_changed)


func _on_short_code_resume_action_state_changed(request_id: String, state: String) -> void:
	if request_id != _short_code_resume_request_id:
		return
	match state:
		AsyncActionController.STATE_SUCCEEDED, AsyncActionController.STATE_FAILED:
			_disconnect_short_code_resume_session_handler()
			_short_code_resume_request_dispatched = false
			# The transport result has no request id. Ignore one duplicate/late copy
			# after settlement so it cannot fall through into the manual reconnect path.
			_short_code_resume_ignore_late_result = true
		AsyncActionController.STATE_TIMED_OUT:
			var must_disconnect := _short_code_resume_waiting_for_session \
				or _short_code_resume_request_dispatched
			_disconnect_short_code_resume_session_handler()
			_short_code_resume_request_dispatched = false
			_short_code_resume_ignore_late_result = true
			if must_disconnect:
				NetworkService.disconnect_session()
			if is_instance_valid(_menu):
				_menu.show_connection_error(tr("net_err_timeout") % [
					NetworkService.DEFAULT_HOST, NetworkService.DEFAULT_PORT])
		AsyncActionController.STATE_CANCELLED:
			var must_disconnect := _short_code_resume_waiting_for_session \
				or _short_code_resume_request_dispatched
			_disconnect_short_code_resume_session_handler()
			_short_code_resume_request_dispatched = false
			_short_code_resume_ignore_late_result = true
			if must_disconnect:
				NetworkService.disconnect_session()


func set_short_code_resume_request_check_hook(hook: Callable) -> bool:
	if not OS.is_debug_build():
		return false
	if _short_code_resume_request_check_hook.is_valid() \
			and short_code_resume_request_check_requested.is_connected(_short_code_resume_request_check_hook):
		short_code_resume_request_check_requested.disconnect(_short_code_resume_request_check_hook)
	_short_code_resume_request_check_hook = hook
	if _short_code_resume_request_check_hook.is_valid():
		short_code_resume_request_check_requested.connect(_short_code_resume_request_check_hook)
	return true


func set_short_code_resume_result_check_hook(hook: Callable) -> bool:
	if not OS.is_debug_build():
		return false
	if _short_code_resume_result_check_hook.is_valid() \
			and short_code_resume_result_check_requested.is_connected(_short_code_resume_result_check_hook):
		short_code_resume_result_check_requested.disconnect(_short_code_resume_result_check_hook)
	_short_code_resume_result_check_hook = hook
	if _short_code_resume_result_check_hook.is_valid():
		short_code_resume_result_check_requested.connect(_short_code_resume_result_check_hook)
	return true


func short_code_resume_request_id_for_check() -> String:
	return _short_code_resume_request_id if OS.is_debug_build() else ""


# The server's room-action failure signal has no request id. Keeping migrated
# actions active together would let one failure settle several requests, so all
# five Main-menu actions explicitly preserve latest-intent-wins behavior.
func _supersede_other_team_action(next_action: String) -> void:
	if next_action != PUBLIC_TOKEN_ACTION \
			and not _public_token_request_id.is_empty() \
			and AsyncActionController.is_current(_public_token_request_id):
		AsyncActionController.cancel(_public_token_request_id,
			"superseded_by_%s" % next_action)
	if next_action != ROOM_LIST_ACTION \
			and not _room_list_request_id.is_empty() \
			and AsyncActionController.is_current(_room_list_request_id):
		AsyncActionController.cancel(_room_list_request_id,
			"superseded_by_%s" % next_action)
	if next_action != CREATE_ROOM_ACTION \
			and not _create_room_request_id.is_empty() \
			and AsyncActionController.is_current(_create_room_request_id):
		AsyncActionController.cancel(_create_room_request_id,
			"superseded_by_%s" % next_action)
	if next_action != JOIN_ROOM_ACTION \
			and not _join_room_request_id.is_empty() \
			and AsyncActionController.is_current(_join_room_request_id):
		AsyncActionController.cancel(_join_room_request_id,
			"superseded_by_%s" % next_action)
	if next_action != SHORT_CODE_RESUME_ACTION \
			and not _short_code_resume_request_id.is_empty() \
			and AsyncActionController.is_current(_short_code_resume_request_id):
		AsyncActionController.cancel(_short_code_resume_request_id,
			"superseded_by_%s" % next_action)
	if next_action != MANUAL_RECONNECT_ACTION \
			and not _manual_reconnect_request_id.is_empty() \
			and AsyncActionController.is_current(_manual_reconnect_request_id):
		AsyncActionController.cancel(_manual_reconnect_request_id,
			"superseded_by_%s" % next_action)
		_disconnect_manual_reconnect_session_handler()
		_manual_reconnect_request_id = ""
func _on_team_room_list_received(rooms: Array) -> void:
	if not _room_list_request_id.is_empty() \
			and AsyncActionController.succeed(_room_list_request_id):
		if is_instance_valid(_menu):
			_menu.show_room_list(rooms)

func _on_team_room_action_failed(reason: String) -> void:
	if not _public_token_request_id.is_empty() \
			and AsyncActionController.is_current(_public_token_request_id):
		AsyncActionController.fail(_public_token_request_id, "TOKEN_REQUEST_FAILED", true)
	if not _room_list_request_id.is_empty() \
			and AsyncActionController.is_current(_room_list_request_id):
		AsyncActionController.fail(_room_list_request_id, "ROOM_LIST_REQUEST_FAILED", true)
	if not _create_room_request_id.is_empty() \
			and AsyncActionController.is_current(_create_room_request_id):
		AsyncActionController.fail(_create_room_request_id, "CREATE_ROOM_REQUEST_FAILED", true)
	if not _join_room_request_id.is_empty() \
			and AsyncActionController.is_current(_join_room_request_id):
		AsyncActionController.fail(_join_room_request_id, "JOIN_ROOM_REQUEST_FAILED", true)
	if is_instance_valid(_menu) and _menu.has_method("show_room_error"):
		_menu.show_room_error(reason)

func _on_public_token_changed(token_id: String) -> void:
	# succeed() is the stale-result gate: a timeout/cancelled generation request
	# cannot update the UI. Short-code resume settles through resume_completed.
	if not _public_token_request_id.is_empty():
		if AsyncActionController.succeed(_public_token_request_id):
			_show_public_token_in_menu(token_id)


func _show_public_token_in_menu(token_id: String) -> void:
	if is_instance_valid(_menu) and _menu.has_method("show_public_token"):
		_menu.show_public_token(token_id)

func _on_team3v3_start() -> void:
	SaveManager.new_run()
	# 出战种族在开局这一刻定下（GameState.run_races 的注释）。new_run() 刚清过它，所以放在后面。
	GameState.run_races = PlayerProfile.get_selected_races()
	SaveManager.save_run()
	GameState.team_mode = true
	GameState.team_hp = GameState.START_FORMATION_HP
	GameState.enemy_team_hp = GameState.START_FORMATION_HP
	if NetworkService.shared_seed == 0:
		NetworkService.shared_seed = randi()
	NetworkService.team_begin_round()
	# 9.21「开始游戏成功」音效：**所有人**都要听到，且**播完才进备战**。
	#
	# 为什么挂在这里而不是 Team3v3Lobby._on_start()：
	#   * 本函数是所有客户端进新局**唯一的汇合点** —— 房主走
	#     `Team3v3Lobby.start_requested` → 这里；客机走服务端 `_rpc_team_start`
	#     → `NetworkService.team_start_requested` → `_on_team_start_requested`
	#     → `start_requested` → 这里。挂在按按钮那一侧只有房主会响。
	#   * 「播完再进游戏」= 把 `_show_prep()` 推迟 cue_length 秒。用 cue_length()
	#     而不是写死常数：换素材时那个常数就对不上了，而且没人会发现
	#     （见 SfxService.cue_length 的注释，胜负 BGM 用的是同一套）。
	await _play_start_game_success_then_prep()

func _play_start_game_success_then_prep() -> void:
	var started := SfxService.play(SfxService.CUE_START_GAME_SUCCESS)
	var wait := SfxService.cue_length(SfxService.CUE_START_GAME_SUCCESS) if started else 0.0
	# 音效被静音 / 读不到时长 → wait 为 0，直接进场，不卡住开局。
	# `+ 0.05` 是留给播放器真正把缓冲吐完的一点余量：cue_length 给的是素材时长，
	# 恰好在末尾切场景会切掉最后几个采样。
	if wait > 0.0 and is_inside_tree():
		await get_tree().create_timer(wait + 0.05).timeout
	_show_prep()

func _on_team_battle_finished(result: Dictionary) -> void:
	if NetworkService.team_active and not NetworkService.is_host:
		await _finish_server_authoritative_team_battle(result)
		return
	var completed_round := GameState.round_index
	var kind := str(result.get("kind", "pve"))
	# PvP 是规范化棋局（A 队 = "player"）。本地在 B 队时结果要镜像。
	# 视角反转走 TeamOutcome（C16），与服务端结算、BattleUI 字幕共用同一实现。
	var local_team := TeamOutcome.TEAM_A
	if NetworkService.team_active and GameConstants.team_of_slot(NetworkService.team_local_slot) == GameConstants.TEAM_BLUE:
		local_team = TeamOutcome.TEAM_B
	var player_wins := TeamOutcome.viewer_wins_battle(result, kind, local_team)
	var surviving_enemies := int(result.get("enemy_alive", result.get("enemy_count", 1)))
	# 伤到本队的存活者在 B 队视角下是 A 队（"player" 侧）那批。
	if kind == "pvp" and local_team == TeamOutcome.TEAM_B:
		surviving_enemies = int(result.get("player_alive", 0))
	# Host stamps BOTH teams' damage this round into the replay result so every
	# client can drive its own team HP and the rival team HP deterministically.
	var self_dmg := int(result.get("team_damage_self", -1))
	var rival_dmg := int(result.get("team_damage_rival", -1))
	if self_dmg >= 0:
		GameState.team_hp = maxi(0, GameState.team_hp - self_dmg)
		GameState.enemy_team_hp = maxi(0, GameState.enemy_team_hp - maxi(0, rival_dmg))
		# Formation Heal (法阵回春): host-authoritative regen, after damage, only if
		# still alive, capped at the starting HP.
		var heal_self := int(result.get("team_heal_self", 0))
		var heal_rival := int(result.get("team_heal_rival", 0))
		if GameState.team_hp > 0 and heal_self > 0:
			GameState.team_hp = mini(GameState.START_FORMATION_HP, GameState.team_hp + heal_self)
		if GameState.enemy_team_hp > 0 and heal_rival > 0:
			GameState.enemy_team_hp = mini(GameState.START_FORMATION_HP, GameState.enemy_team_hp + heal_rival)
	elif not player_wins:
		# Legacy fallback: only my team's HP, damage = surviving enemy count.
		GameState.team_hp = maxi(0, GameState.team_hp - maxi(1, surviving_enemies))
	# Economy: 全套战后结算走 EconomyService.settle_post_battle_gold —— 与专用服务器
	# 的 NetworkService._server_gold_after_battle 共用同一份实现，两处不能再各写各的。
	# 连败计数在这里维护（此前全代码从未 +1 过，安慰金因此恒为 +2）：胜利清零、
	# 失败 +1，安慰金按结算后的连败数计算。
	if player_wins:
		GameState.loss_streak = 0
	else:
		GameState.loss_streak += 1
	GameState.gold = EconomyService.settle_post_battle_gold({
		"gold_before": GameState.gold,
		"kill_gold": _team_local_kill_gold(result),
		"bonus_gold": int(result.get("bonus_gold", 0)),
		"kind": kind,
		"player_wins": player_wins,
		"round_index": completed_round,
		"loss_streak_after": GameState.loss_streak,
		"boss_hp_current": int(result.get("enemy_hp_current", 0)),
		"boss_hp_max": maxi(1, int(result.get("enemy_hp_max", 1))),
		"merchant_gold": EconomyService.merchant_gold_from_board(GameState.board_slots),
		"treasures": GameState.owned_treasures,
		"pet_id": PlayerProfile.get_active(),
		"camp_income": GameState.carrot_camp_income(),
	})
	_apply_post_battle_unit_outcomes(result)
	GameState.battle_history.append(result)
	if kind == "pve":
		GameState.pve_completed += 1
	elif kind == "boss":
		GameState.boss_completed += 1
	GameState.round_index = mini(GameState.round_index + 1, GameState.FINAL_ROUND)
	GameState.reset_shop_refreshes()
	GameState.clear_shop()
	GameState.clear_mercenaries()
	# (2) End the run the moment either team's formation HP reaches 0 (or round 21).
	var run_over := GameState.team_hp <= 0 or GameState.enemy_team_hp <= 0 or completed_round >= GameState.FINAL_ROUND
	if run_over:
		if completed_round >= GameState.FINAL_ROUND:
			GameState.final_round_played = true
		# 整局归属走 TeamOutcome（C16）。此前这里落进 else 分支按剩余水晶生命判，
		# 而服务端第 21 回合按最终战结果判 —— 两条规则会给出不同答案。
		# TeamOutcome 的入参是 A/B 绝对视角，所以本地的 team_hp/player_wins
		# 要先换算回 A 队视角再传进去。
		var hp_a := GameState.team_hp if local_team == TeamOutcome.TEAM_A else GameState.enemy_team_hp
		var hp_b := GameState.enemy_team_hp if local_team == TeamOutcome.TEAM_A else GameState.team_hp
		var a_wins := player_wins if local_team == TeamOutcome.TEAM_A else not player_wins
		GameState.team_run_outcome = TeamOutcome.run_outcome({
			"completed_round": completed_round,
			"final_round": GameState.FINAL_ROUND,
			"hp_a": hp_a,
			"hp_b": hp_b,
			"kind": kind,
			"battle_a_wins": a_wins,
			"battle_is_draw": bool(result.get("is_draw", false)),
		})
		GameState.team_run_won = TeamOutcome.team_won_run(GameState.team_run_outcome, local_team)
		SaveManager.save_run()
		_show_game_over()
		return
	NetworkService.team_begin_round()
	_start_treasure_for_completed_round(completed_round)
	_show_prep()

func _finish_server_authoritative_team_battle(result: Dictionary) -> void:
	if result.has("error"):
		# **技术失败，不是玩家退出**（B8/E3）：replay 没等到、解包失败之类。
		# 此前这里调 disconnect_session()，等于清掉重连凭证 —— 而服务器那边
		# 座位还好好留着。现在进可恢复状态，让重连流程去接。
		var reason := str(result.get("error", "replay_timeout"))
		print("[NET] team battle failed reason=%s class=%s" % [reason, NetError.class_name_of(reason)])
		NetworkService.enter_recoverable_failure(reason)
		if NetworkService.state != NetworkService.SessionState.RECONNECTING:
			_show_menu()
		return
	var completed_round := GameState.round_index
	var waited := 0.0
	while not _has_team_match_state(completed_round) and waited < NetworkService.REPLAY_TIMEOUT_SEC:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	if not _has_team_match_state(completed_round):
		# 正在重连：不要拆会话回菜单，恢复流程会接管导航（resume 后落回备战）
		if NetworkService.state == NetworkService.SessionState.RECONNECTING:
			return
		# 同上：结算没等到是传输问题，不是"玩家要退出"。
		print("[NET] match_state timeout round=%d" % completed_round)
		NetworkService.enter_recoverable_failure("match_state_timeout")
		if NetworkService.state != NetworkService.SessionState.RECONNECTING:
			_show_menu()
		return
	var state_payload := NetworkService.latest_match_state.duplicate(true)
	# 本人看完/跳过仅确认回放结束；等全部在线玩家确认后才发放收益并进入备战。
	NetworkService.send_result_ack(str(state_payload.get("battle_id", "")))
	if not bool(state_payload.get("run_over", false)):
		if is_instance_valid(_battle):
			_battle.call("show_settlement_waiting")
		while not NetworkService.server_prep_confirmed(completed_round + 1):
			if not NetworkService.team_active or NetworkService.state == NetworkService.SessionState.RECONNECTING:
				return
			await get_tree().create_timer(0.1).timeout
	_apply_team_match_state_payload(state_payload, result)
	print("[NET] client applied match_state round=%d next=%d gold=%d hp=%d" % [completed_round, GameState.round_index, GameState.gold, GameState.team_hp])
	if bool(state_payload.get("run_over", false)):
		SaveManager.save_run()
		_show_game_over()
		return
	NetworkService.team_begin_round()
	_show_prep()

func _has_team_match_state(completed_round: int) -> bool:
	return not NetworkService.latest_match_state.is_empty() and int(NetworkService.latest_match_state.get("completed_round", -1)) == completed_round and int(NetworkService.latest_match_state.get("protocol", -1)) == NetworkConfig.NETWORK_PROTOCOL_VERSION

func _apply_team_match_state_payload(state_payload: Dictionary, result: Dictionary = {}) -> void:
	if state_payload.is_empty():
		return
	GameState.team_hp = int(state_payload.get("team_hp", GameState.team_hp))
	GameState.enemy_team_hp = int(state_payload.get("enemy_team_hp", GameState.enemy_team_hp))
	GameState.gold = int(state_payload.get("gold", GameState.gold))
	# 萝卜字段走 NetworkService._apply_carrot_state 这**唯一一份**实现（room_state、
	# 重连恢复、战后 match_state 三条路径共用），它自带 carrot_authoritative 判据。
	# 以前这里是逐字段抄的第二份，判据也不一样（只判 has("carrots")）—— 加字段时
	# 漏掉一处不会报错，只会让那个字段在某一条路径上永远不更新。
	# match_state 不带 last_harvest_gain 是对的：它在回合推进**之前**生成，
	# 带的会是上一回合已经播过的采集量。本回合的采集由随后的 room_state 送达。
	NetworkService._apply_carrot_state(state_payload)
	GameState.pve_completed = int(state_payload.get("pve_completed", GameState.pve_completed))
	GameState.boss_completed = int(state_payload.get("boss_completed", GameState.boss_completed))
	GameState.loss_streak = int(state_payload.get("loss_streak", GameState.loss_streak))
	GameState.final_round_played = bool(state_payload.get("final_round_played", GameState.final_round_played))
	# run_outcome 是权威的绝对归属（TEAM_A/TEAM_B/DRAW）；team_run_won 只是本座位
	# 视角的派生布尔，单看它分不出"输了"和"平局"。
	GameState.team_run_outcome = int(state_payload.get("run_outcome", GameState.team_run_outcome))
	GameState.team_run_won = bool(state_payload.get("team_run_won", GameState.team_run_won))
	if not result.is_empty():
		_apply_post_battle_unit_outcomes(result)
		GameState.battle_history.append(result)
	GameState.round_index = int(state_payload.get("round_index", GameState.round_index))
	GameState.pending_treasure = (state_payload.get("pending_treasure", {"active": false, "round": 0, "candidates": [], "refresh_index": 0}) as Dictionary).duplicate(true)
	# 结算已经落到本地状态上了，现在才回执（E3）。服务器要等所有在线真人都确认
	# 才推进下一轮 —— 此前任意一个人按准备就能把还在看回放的人一起拽走（C7）。
	NetworkService.send_result_ack(str(state_payload.get("battle_id", "")))
	GameState.reset_shop_refreshes()
	GameState.clear_shop()
	GameState.clear_mercenaries()
	SaveManager.save_run()

func _team_local_kill_gold(result: Dictionary) -> int:
	var slot := NetworkService.team_local_slot if NetworkService.team_active else 0
	return EconomyService.kill_gold_for_slot(result, maxi(0, slot))

func _on_battle_requested() -> void:
	var loaded_battle_scene: PackedScene = null
	if _prep != null and _prep.has_method("take_loaded_battle_scene"):
		loaded_battle_scene = _prep.call("take_loaded_battle_scene") as PackedScene
	if GameState.tutorial_mode:
		if TutorialMode.begin_battle():
			_show_battle(loaded_battle_scene)
		return
	# 3v3 gates on its own per-round ready sync (team_round_start); board
	# collection still happens in the battle screen.
	_show_battle(loaded_battle_scene)

func _on_return_menu_requested() -> void:
	SaveManager.save_run()
	NetworkService.disconnect_session()
	_show_menu()

func _on_battle_finished(result: Dictionary = {}) -> void:
	if GameState.tutorial_mode:
		TutorialMode.after_battle(result)
		if TutorialMode.step == TutorialMode.Step.DONE:
			var persisted := PlayerProfile.set_onboarding_status(
				PlayerProfile.ONBOARDING_COMPLETED)
			TutorialMode.finish(persisted)
			_show_game_over()
			return
		_show_prep()
		return
	if GameState.team_mode:
		_on_team_battle_finished(result)
		return

func _game_over_title() -> String:
	if GameState.team_mode:
		if TeamOutcome.is_draw(GameState.team_run_outcome):
			return tr("gameover_final_draw")
		return tr("gameover_final_win") if GameState.team_run_won else tr("gameover_final_lost")
	if GameState.player_formation_hp <= 0:
		return tr("gameover_lost")
	if GameState.enemy_formation_hp <= 0:
		return tr("gameover_win")
	if GameState.final_round_played:
		var last := _last_battle_result()
		if bool(last.get("player_wins", false)):
			return tr("gameover_final_win")
		return tr("gameover_final_lost")
	return tr("gameover_lost")

func _game_over_body() -> String:
	if GameState.team_mode:
		var team_result := tr("gameover_result_win") if GameState.team_run_won else tr("gameover_result_lose")
		if TeamOutcome.is_draw(GameState.team_run_outcome):
			team_result = tr("gameover_result_draw")
		return tr("gameover_team_body") % [GameState.round_index, team_result, GameState.team_hp]
	var last := _last_battle_result()
	var result_text := tr("gameover_result_win") if bool(last.get("player_wins", false)) else tr("gameover_result_lose")
	return tr("gameover_body") % [
		GameState.round_index,
		result_text,
		GameState.player_formation_hp,
		GameState.enemy_formation_hp,
	]

func _last_battle_result() -> Dictionary:
	if GameState.battle_history.is_empty():
		return {}
	var last = GameState.battle_history.back()
	if typeof(last) == TYPE_DICTIONARY:
		return last
	return {}

func _on_network_match_state_received(state_payload: Dictionary) -> void:
	if _battle != null and is_instance_valid(_battle):
		return
	# 内嵌服务器会在本回合刚就绪时立刻把战后 match_state 发回，此刻玩家可能还在
	# 备战界面异步打包战斗（战斗场景尚未创建）。这时绝不能提前应用——否则
	# round_index 会在进战斗前就 +1，既跳了回合，又让备战的
	# _wait_for_team_match_state 等待条件永远错配、卡住进不去战斗。payload 已存在
	# NetworkService.latest_match_state 里，战斗播完后 _finish_server_authoritative_team_battle
	# 会统一应用。
	if _prep != null and is_instance_valid(_prep) and _prep.has_method("is_committing_to_battle") and bool(_prep.call("is_committing_to_battle")):
		return
	if GameState.team_mode:
		_apply_team_match_state_payload(state_payload)
		if _prep != null and is_instance_valid(_prep):
			# 结算会清空商店（_apply_team_match_state_payload 内部 clear_shop），但本路径不像
			# _on_team_battle_finished 那样走 _show_prep() 重建备战界面，若不再摇一次商店，
			# 重连玩家看到的商店会是空的（BUG：战斗场景掉线重连后商店无商品）。与正常战斗
			# 结束路径保持一致，这里补一次摇店。
			if _prep.has_method("_roll_shop") and (GameState.shop_offers.is_empty() or GameState.shop_offers[0].is_empty()):
				_prep.call_deferred("_roll_shop")
			if _prep.has_method("_refresh_all"):
				_prep.call_deferred("_refresh_all")

func _apply_post_battle_unit_outcomes(result: Dictionary) -> void:
	if not result.has("player_survivor_slots"):
		return
	var survivor_slots := {}
	for slot in result.get("player_survivor_slots", []):
		survivor_slots[int(slot)] = true
	for i in GameState.board_slots.size():
		var cell = GameState.board_slots[i]
		if cell == null or str(cell.get("def", {}).get("skill_id", "")) != "unique_king_growth":
			continue
		if survivor_slots.has(i):
			_grow_human_king(cell)
		else:
			GameState.board_slots[i] = null

func _grow_human_king(cell: Dictionary) -> void:
	var d: Dictionary = cell.get("def", {})
	# The only compounding skill in the game, so the stack count must be capped.
	#
	# The cap lives at the top level of the unit def (3-star ceiling) and is
	# overridden in `star4` (4-star ceiling). Capping only the 4-star tier — which
	# is what an earlier pass did — inverts the tiers: an uncapped 3-star king
	# overtakes a capped 4-star one after ~10 surviving rounds.
	#
	# max_stacks may come from the `star4` block, and cell.def is the raw table
	# entry with no star scaling applied, so read it through the single parse
	# point (UnitFactory.apply_star_stats). The growth itself still mutates the
	# cell's own def, but both the ceiling **and** the multiplier come from there.
	#
	# 9.14 反馈补了后半句：当时只把 `cap` 改走 apply_star_stats，`mul` 仍读原始 d，
	# 于是 4★ 出现「上限是 4★ 的 8 层、倍率还是 1~3★ 的 ×1.2」这种半接线状态，
	# 与图鉴的 ×1.3 不符。同一个函数里两个数必须走同一条路。
	var effective := UnitFactory.apply_star_stats(d, int(cell.get("star", 1)))
	var cap := int(effective.get("max_stacks", 0))
	if cap > 0 and int(cell.get("king_growth_stacks", 0)) >= cap:
		return
	var mul := 1.0 + float(effective.get("post_battle_all_stat_growth", 0.20))
	# Growth is limited to HP / ATK / DEF, matching the star-scaling rule in
	# docs/四星技能与数值设计规格.md §1 ("仅 HP / 攻击 / 防御三项").
	#
	# This used to compound attack_speed / move_speed / crit / crit_dmg / range as
	# well. That is the exact trap §1 exists to prevent: attack speed and crit
	# damage both multiply DPS, so a "x5.96 stat growth" was really ~119x DPS,
	# and 16 surviving rounds reached ~22000x. crit_dmg and range are not clamped
	# anywhere; attack speed only saturates at the 2.5 ceiling in
	# BattleSimulator._tick_attacks.
	for key in ["hp", "atk", "def"]:
		if d.has(key):
			d[key] = maxi(1, int(round(float(d[key]) * mul)))
	cell.def = d
	cell.king_growth_stacks = int(cell.get("king_growth_stacks", 0)) + 1

func _start_treasure_for_completed_round(completed_round: int) -> void:
	if bool(GameState.pending_treasure.get("active", false)):
		return
	if completed_round in GameState.claimed_treasure_rounds:
		return
	if not RoundService.is_treasure_round(completed_round) or not TreasureService.can_draw():
		return
	var candidates := TreasureService.roll_candidates(3)
	if candidates.is_empty():
		return
	GameState.pending_treasure = {
		"active": true,
		"round": completed_round,
		"candidates": candidates,
		"refresh_index": 0,
	}
