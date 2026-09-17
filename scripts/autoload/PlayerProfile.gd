extends Node
# 账号级持久档（跨局保留，绝不进 GameState.reset_run）。
#
# ## 🔴 宠物归属与出战种族**不在这里持久化**（宠物 2026-09-16、种族 09-17 上云）
#
# owned_pets / active_pet / needs_starter_pick / selected_races 仍然是这个门面上的
# 同步字段 —— 二十来处调用点照旧同步读 —— 但它们是**服务端答复的内存缓存**：
# 不从 profile.json 读，也不写回去（SaveSchema v6 / v7 把这几个键从本机档案里删了）。
#
# 唯一真相在服务端（宠物在 player_entitlements，种族在 players.selected_races）。
# 联机对局用的也是账号服务器按这份真相签的出战名片（docs/商城系统设计.md 第五节）。
# 本机另存一份的话：宠物是「改一行文件就白嫖」；种族是「页面上选的这几族，
# 对局里用的却是另外几族」。
#
# 三条纪律：
#   1. **刷新失败时保留旧值，绝不清空。** 网络抖一下就把玩家的宠物抹掉，
#      表现是这一局没有加成 —— 而且不报错。
#   2. **needs_starter_pick 只在 pets_loaded 之后才当真。** 没拉到就一律 false，
#      否则弱网下新玩家被误弹、老玩家被要求重选。
#   3. 改出战宠物只有 set_active() 一条路、改出战种族只有 set_selected_races() 一条路
#      （都是异步、走服务端）。不许谁再直连 AccountManager —— 两条路各自维护缓存必然不一致。

const PROFILE_PATH := "user://profile.json"
# 解析失败的档案在被覆盖前先挪到这里。见 _preserve_corrupt_profile。
const CORRUPT_PROFILE_PATH := "user://profile.corrupt.json"
const TMP_SUFFIX := ".tmp"
const BAK_SUFFIX := ".bak"

const ONBOARDING_VERSION := 1
const ONBOARDING_NOT_STARTED := "not_started"
const ONBOARDING_IN_PROGRESS := "in_progress"
const ONBOARDING_COMPLETED := "completed"
const ONBOARDING_SKIPPED := "skipped"
const ONBOARDING_LEGACY_UNKNOWN := "legacy_unknown"
const STARTUP_LANGUAGE := "language"
const STARTUP_TUTORIAL := "tutorial"
const STARTUP_MENU := "menu"
const SUPPORTED_LOCALES: PackedStringArray = ["zh", "en"]

const RacePick := preload("res://scripts/units/RacePick.gd")

signal pets_changed()
signal races_changed()
signal codex_changed()
signal presentation_settings_changed()

# 玩家的永久身份，本机第一次读档时签发，之后永不改变。
# 语义、随机源、以及「为什么不能等接账号时再加」在 SaveSchema.PLAYER_ID_PATTERN
# 那一段和 docs/账号系统RFC.md 里。
var player_id := ""
# 服务端答复的缓存，不落盘。见文件头。
var owned_pets: Array[String] = []
var active_pet := ""
# 有没有成功拉到过一次。**没拉到之前不许把空当成「他没有宠物」。**
var pets_loaded := false
# 出战种族，服务端答复的缓存（空 = 从没选过，或者还没拉到）。
# 读的时候一律走 get_selected_races()：那里按当前棋子表校验，不合法就回落默认 ——
# 以后删掉 / 改名一族，不需要做任何迁移。
var selected_races: Array[String] = []
var needs_starter_pick := false
# Codex entries the player has encountered. Account-level and append-only: nothing
# a player has seen is ever taken away.
var codex_seen: Array[String] = []
var board_readability_enabled := true
# V2 P1-05 第 4 条：无障碍开关。三项都默认开启 —— 这是演出效果，不是辅助功能，
# 默认关掉会让绝大多数玩家看到一个更差的版本。需要的人自己去设置里关。
#
# 低画质档会**额外**压制它们（见 PresentationSettings），那一层不改这里的值：
# 玩家关掉的开关不该因为换了台手机就自己开回来。
var screen_shake_enabled := true
var flash_effects_enabled := true
var hit_stop_enabled := true
# V3 P1-09：降低动态效果。默认关闭 —— 它压掉的是所有过场与呼吸动画，
# 默认打开会让绝大多数玩家看到一个更静的版本。
#
# 与上面三个不同，它要同步进 ProjectSettings：GloryTokens.reduced_motion()
# 是 static 的，拿不到 autoload。让 profile 单向写入那一处，
# 读侧就只有一个入口，不会出现「设置页开了、动画还在跑」。
var reduced_motion_enabled := false
# V3 P1-04：UI 音效与触觉。默认开启 —— 与上面三个演出开关同理，默认关掉
# 会让绝大多数玩家看到（听到）一个更差的版本。
#
# 这两个不需要像 reduced_motion 那样同步进 ProjectSettings：读侧
# PresentationSettings 是 autoload 可达的，直接问 profile 就行。
var ui_sound_enabled := true
var haptics_enabled := true
# 9.17 反馈第 5 条：设置页的「背景音乐」开关。与 ui_sound_enabled 分开 ——
# 只想静音效 / 只想静 BGM 的人都得能单独做到。裁决在 PresentationSettings.music_allowed()，
# 实际掐的是 MusicService 那个常驻播放器（stream_paused，可续播）。
var music_enabled := true
var locale := "zh"
var language_selected := false
var onboarding_version := ONBOARDING_VERSION
var onboarding_status := ONBOARDING_NOT_STARTED
# 与 GloryTokens.REDUCED_MOTION_SETTING 必须一致。这里不 preload 那个类：
# autoload 反过来依赖 UI 层会把依赖方向倒过来。门禁断言两边字面相同。
const REDUCED_MOTION_SETTING := "glory/ui/reduced_motion"

func _ready() -> void:
	load_profile()

func load_profile() -> void:
	var profile_text := _read_with_fallback(PROFILE_PATH)
	if profile_text.is_empty():
		# 全新账号：等待玩家三选一，先不发放任何宠物。
		_reset_defaults()
		player_id = SaveSchema.new_player_id()
		save_profile()
		return
	var parsed = JSON.parse_string(profile_text)
	if typeof(parsed) != TYPE_DICTIONARY:
		# 坏档原本只重置内存、不落盘。现在必须落盘 —— 新签的 player_id 不写回去，
		# 下次冷启动就会再签一个，正是「签发一次、永不改变」要防的静默身份漂移。
		# 既然要覆盖，原始字节先另存一份，别让「存档打不开」变成「存档没了」。
		# 注意这里的 profile_text 可能已经是 _read_with_fallback 从 .bak 取回来的，
		# 也就是说主文件和兜底文件都坏了 —— 更值得留痕。
		_preserve_corrupt_profile(profile_text)
		_reset_defaults()
		player_id = SaveSchema.new_player_id()
		save_profile()
		return
	# Migrate before reading: older profiles carry renamed pet ids and no codex.
	var data: Dictionary = SaveSchema.migrate_profile(parsed as Dictionary)
	# migrate_profile 保证这里一定拿得到一个合法 id：档案里有就原样带出来，
	# 没有或写坏了才现签一个。不要在这里加 `if player_id.is_empty()` 之类的兜底 ——
	# 签发只能有一处，两处就迟早会各签各的。
	player_id = str(data.get("player_id", ""))
	# 宠物归属与出战种族不从档案里读了（SaveSchema v6 / v7 已经把这几个键 erase 掉）。
	# 它们由 refresh_pets() / refresh_races() 从服务端填，见文件头。
	codex_seen.clear()
	for raw in data.get("codex_seen", []):
		var entry := str(raw)
		if not entry.is_empty() and not codex_seen.has(entry):
			codex_seen.append(entry)
	board_readability_enabled = bool(data.get("board_readability_enabled", true))
	screen_shake_enabled = bool(data.get("screen_shake_enabled", true))
	flash_effects_enabled = bool(data.get("flash_effects_enabled", true))
	hit_stop_enabled = bool(data.get("hit_stop_enabled", true))
	reduced_motion_enabled = bool(data.get("reduced_motion_enabled", false))
	ui_sound_enabled = bool(data.get("ui_sound_enabled", true))
	haptics_enabled = bool(data.get("haptics_enabled", true))
	music_enabled = bool(data.get("music_enabled", true))
	locale = str(data.get("locale", "zh"))
	if not SUPPORTED_LOCALES.has(locale):
		locale = "zh"
	language_selected = bool(data.get("language_selected", false))
	onboarding_version = int(data.get("onboarding_version", ONBOARDING_VERSION))
	onboarding_status = _normalise_onboarding_status(
		str(data.get("onboarding_status", ONBOARDING_LEGACY_UNKNOWN)))
	_apply_reduced_motion()
	LocaleManager.set_locale(locale)
	# Persist the migrated shape so the upgrade only ever runs once.
	#
	# player_id 要单独判一次：档案版本号已经是最新、但 id 缺失或被写坏时，
	# migrate_profile 会现签一个，而上面那个版本条件是 false —— 只看版本号就会漏掉
	# 这份档案，新 id 不落盘，下次启动再签一个。必须两个条件都看。
	if int(parsed.get("version", 1)) < SaveSchema.PROFILE_VERSION 			or str(parsed.get("player_id", "")) != player_id:
		save_profile()

func save_profile() -> bool:
	var payload := {
		"version": SaveSchema.PROFILE_VERSION,
		"player_id": player_id,
		"codex_seen": codex_seen,
		"board_readability_enabled": board_readability_enabled,
		"screen_shake_enabled": screen_shake_enabled,
		"flash_effects_enabled": flash_effects_enabled,
		"hit_stop_enabled": hit_stop_enabled,
		"reduced_motion_enabled": reduced_motion_enabled,
		"ui_sound_enabled": ui_sound_enabled,
		"haptics_enabled": haptics_enabled,
		"music_enabled": music_enabled,
		"locale": locale,
		"language_selected": language_selected,
		"onboarding_version": onboarding_version,
		"onboarding_status": onboarding_status,
	}
	return _atomic_write(PROFILE_PATH, JSON.stringify(payload))


func _reset_defaults() -> void:
	owned_pets.clear()
	active_pet = ""
	# 归属缓存也清掉：下次 refresh_pets 之前不许把空当成「他没有宠物」。
	pets_loaded = false
	selected_races.clear()
	codex_seen.clear()
	board_readability_enabled = true
	screen_shake_enabled = true
	flash_effects_enabled = true
	hit_stop_enabled = true
	reduced_motion_enabled = false
	ui_sound_enabled = true
	haptics_enabled = true
	music_enabled = true
	locale = "zh"
	language_selected = false
	onboarding_version = ONBOARDING_VERSION
	onboarding_status = ONBOARDING_NOT_STARTED
	needs_starter_pick = true
	_apply_reduced_motion()
	LocaleManager.set_locale(locale)


# **唯一允许改变已有 player_id 的入口。合法理由只有两个：**
#
#   1. 账号服务器回了 409，说这个 id 已经属于别人（见 AccountManager.login）
#   2. 玩家注销了账号（见下面的 reset_account_state）
#
# 第 2 条是 2026-09-09 加的。不重签的话，注销之后下一次匿名注册会把**同一个
# player_id** 报上去，服务端看它空着就收下 —— 同一个身份原地复活，等于没删。
#
# 除此之外任何地方调用它都是 bug —— 它会让玩家变成另一个人，且不报错。
#
# 什么时候真会发生：UUIDv4 撞号的概率约等于零，但**同一份 profile.json 被复制
# 到两台设备**是现实的（手工备份、还原、拷贝存档目录）。那时第二台注册会撞上
# 第一台的 id，重签是正确处理 —— 它就该是一个新玩家。
#
# 自动路径（load_profile / migrate_profile）**绝不调用这里**：那条路上
# 「没有就签一次、已经有了就绝不再签」是硬不变量，由
# tools/player_identity_check.tscn 钉着。这个函数是显式的、有人主动调的例外。
func reissue_player_id() -> void:
	var previous := player_id
	player_id = SaveSchema.new_player_id()
	save_profile()
	push_warning("[PROFILE] player_id 已重新签发：%s -> %s" % [previous, player_id])


# 注销账号之后清理本地。**只清账号态，保留设备态。**
#
# 判据用 docs/账号系统RFC.md 第五节那张表现成的：
# 「换一台性能不同的手机，这个值应不应该跟过去？」——
# 不该跟过去的就是设备态，它不属于账号，不该被注销带走。
# 玩家在低端机上关掉的屏震、调过的画质、选好的语言，都不该因为删了资料而重来。
#
# ⚠️ **onboarding 与 locale 刻意保留**，尽管严格按上面那条判据它们算账号态。
# 理由：注销的目的是删除个人数据，不是重置游戏教学。让玩家重看一遍教学、
# 重选一次语言，既不保护任何数据，又是纯摩擦。needs_starter_pick 置回 true
# 已经让玩家重新走一遍「三选一」，那才是真正的「从头开始」。
func reset_account_state() -> void:
	owned_pets.clear()
	active_pet = ""
	# 归属缓存也清掉：下次 refresh_pets 之前不许把空当成「他没有宠物」。
	pets_loaded = false
	# 出战种族跟着账号走，不是设备态 —— 缓存一起清，回到默认。
	selected_races.clear()
	codex_seen.clear()
	needs_starter_pick = true
	# 放在最后：它内部会 save_profile()，上面几个字段要先改完。
	reissue_player_id()
	pets_changed.emit()
	races_changed.emit()
	codex_changed.emit()


# 覆盖坏档之前留一份原始字节，方便事后人工捞。只留最近一次：更早的那份已经
# 是「上一次也坏了」，价值不大，不值得为它做轮转。
func _preserve_corrupt_profile(raw: String) -> void:
	var f := FileAccess.open(CORRUPT_PROFILE_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("[PROFILE] profile.json 解析失败，且原始内容备份不出去（%s 打不开）" % CORRUPT_PROFILE_PATH)
		return
	f.store_string(raw)
	push_warning("[PROFILE] profile.json 解析失败，原始内容已另存到 %s" % CORRUPT_PROFILE_PATH)


func _normalise_onboarding_status(value: String) -> String:
	if value in [ONBOARDING_NOT_STARTED, ONBOARDING_IN_PROGRESS,
			ONBOARDING_COMPLETED, ONBOARDING_SKIPPED, ONBOARDING_LEGACY_UNKNOWN]:
		return value
	return ONBOARDING_LEGACY_UNKNOWN


# Account profile has to be safe before SaveManager enters the tree (autoload order
# intentionally loads PlayerProfile first), so this small atomic primitive lives here.
func _atomic_write(path: String, content: String) -> bool:
	var tmp := path + TMP_SUFFIX
	var bak := path + BAK_SUFFIX
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("[PROFILE] cannot open temp file: %s" % tmp)
		return false
	f.store_string(content)
	f.flush()
	f = null
	if FileAccess.get_file_as_string(tmp) != content:
		push_warning("[PROFILE] temp verify failed: %s" % path)
		DirAccess.remove_absolute(tmp)
		return false
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(bak)
		if DirAccess.rename_absolute(path, bak) != OK:
			push_warning("[PROFILE] cannot rotate previous file: %s" % path)
			DirAccess.remove_absolute(tmp)
			return false
	if DirAccess.rename_absolute(tmp, path) != OK:
		if FileAccess.file_exists(bak):
			DirAccess.rename_absolute(bak, path)
		push_warning("[PROFILE] atomic rename failed: %s" % path)
		return false
	return true


func _read_with_fallback(path: String) -> String:
	for candidate in [path, path + BAK_SUFFIX]:
		if not FileAccess.file_exists(candidate):
			continue
		var text := FileAccess.get_file_as_string(candidate)
		var parser := JSON.new()
		if not text.strip_edges().is_empty() and parser.parse(text) == OK \
				and parser.data is Dictionary:
			return text
	return ""


# --- startup / onboarding -------------------------------------------------

func startup_route() -> String:
	if not language_selected:
		return STARTUP_LANGUAGE
	if onboarding_status in [ONBOARDING_COMPLETED, ONBOARDING_SKIPPED]:
		return STARTUP_MENU
	return STARTUP_TUTORIAL


func select_language(value: String) -> bool:
	if not SUPPORTED_LOCALES.has(value):
		push_warning("[PROFILE] unsupported locale: %s" % value)
		return false
	locale = value
	language_selected = true
	LocaleManager.set_locale(locale)
	return save_profile()


func set_onboarding_status(value: String) -> bool:
	var normalised := _normalise_onboarding_status(value)
	if normalised == ONBOARDING_LEGACY_UNKNOWN and value != ONBOARDING_LEGACY_UNKNOWN:
		push_warning("[PROFILE] invalid onboarding status: %s" % value)
		return false
	onboarding_version = ONBOARDING_VERSION
	onboarding_status = normalised
	return save_profile()


func begin_tutorial() -> bool:
	return set_onboarding_status(ONBOARDING_IN_PROGRESS)

# --- presentation settings -----------------------------------------------

func set_board_readability_enabled(enabled: bool) -> void:
	if board_readability_enabled == enabled:
		return
	board_readability_enabled = enabled
	save_profile()
	presentation_settings_changed.emit()


# 三个无障碍开关共用一条写入路径：值没变就不落盘、不发信号。
func set_presentation_toggle(key: String, enabled: bool) -> void:
	match key:
		"screen_shake":
			if screen_shake_enabled == enabled:
				return
			screen_shake_enabled = enabled
		"flash_effects":
			if flash_effects_enabled == enabled:
				return
			flash_effects_enabled = enabled
		"hit_stop":
			if hit_stop_enabled == enabled:
				return
			hit_stop_enabled = enabled
		"reduced_motion":
			if reduced_motion_enabled == enabled:
				return
			reduced_motion_enabled = enabled
			_apply_reduced_motion()
		"ui_sound":
			if ui_sound_enabled == enabled:
				return
			ui_sound_enabled = enabled
		"haptics":
			if haptics_enabled == enabled:
				return
			haptics_enabled = enabled
		"music":
			if music_enabled == enabled:
				return
			music_enabled = enabled
		_:
			push_warning("[PROFILE] 未知的演出开关：%s" % key)
			return
	save_profile()
	presentation_settings_changed.emit()


func get_presentation_toggle(key: String) -> bool:
	match key:
		"screen_shake":
			return screen_shake_enabled
		"flash_effects":
			return flash_effects_enabled
		"hit_stop":
			return hit_stop_enabled
		"reduced_motion":
			return reduced_motion_enabled
		"ui_sound":
			return ui_sound_enabled
		"haptics":
			return haptics_enabled
		"music":
			return music_enabled
	return true


# 单向写进 ProjectSettings，给 GloryTokens.reduced_motion() 读。
# 命令行 --reduced-motion 仍然优先（真机上不改代码就能验），
# 所以这里只写设置、不去覆盖那条判断。
func _apply_reduced_motion() -> void:
	ProjectSettings.set_setting(REDUCED_MOTION_SETTING, reduced_motion_enabled)

# --- codex ---------------------------------------------------------------

func has_seen(entry_id: String) -> bool:
	return codex_seen.has(entry_id)

# Called from gameplay whenever an entry is encountered. Writes at most once per
# entry, so the common case is a cheap array lookup with no disk access.
func mark_seen(entry_id: String) -> void:
	if entry_id.is_empty() or codex_seen.has(entry_id):
		return
	codex_seen.append(entry_id)
	save_profile()
	codex_changed.emit()

func mark_seen_many(entry_ids: Array) -> void:
	var added := false
	for raw in entry_ids:
		var entry := str(raw)
		if entry.is_empty() or codex_seen.has(entry):
			continue
		codex_seen.append(entry)
		added = true
	if added:
		save_profile()
		codex_changed.emit()

func is_owned(pet_id: String) -> bool:
	return owned_pets.has(pet_id)

func get_active() -> String:
	return active_pet

# grant() 删掉了：发放是服务端的事（POST /v1/shop/orders 或 /v1/me/pets/starter），
# 客户端不许自己往拥有列表里塞东西。它此前也已经零调用方。


# 从服务端拉一次归属。返回有没有拉到。
#
# 🔴 **失败时一个字段都不动。** 清空的话，网络抖一下玩家的宠物就没了 ——
# 表现是这一局没有加成，而且不报错。没拉到 = 继续用上次拿到的。
func refresh_pets() -> bool:
	if not AccountManager.is_logged_in():
		return false
	var result: Dictionary = await AccountManager.fetch_pets()
	if int(result.get("code", 0)) / 100 != 2:
		return false
	_adopt_pets(result.get("body", {}))
	return true


# 把服务端的答复装进缓存。set_active / pick_starter 的回执与 refresh 共用它 ——
# 三条路各自解析一遍的话，迟早有一条漏掉某个字段。
func _adopt_pets(body: Dictionary) -> void:
	owned_pets.clear()
	for raw in body.get("owned", []):
		var id := str(raw)
		if not id.is_empty() and not owned_pets.has(id):
			owned_pets.append(id)
	active_pet = str(body.get("active", ""))
	needs_starter_pick = bool(body.get("needs_starter_pick", false))
	pets_loaded = true
	pets_changed.emit()


# 换出战宠物。**唯一入口** —— 商城、背包、备战页都走这里，
# 不许谁再直连 AccountManager（那样缓存就有两个主人了）。
func set_active(pet_id: String) -> bool:
	if not owned_pets.has(pet_id) or active_pet == pet_id:
		return false
	var result: Dictionary = await AccountManager.set_active_pet(pet_id)
	if int(result.get("code", 0)) / 100 != 2:
		return false
	_adopt_pets(result.get("body", {}))
	return true


# 首次三选一。走的是和购买**完全一样**的发货路径（同一张订单表、同一个幂等键），
# 只是价格 0 —— 见 docs/商城系统设计.md 第九节。
func pick_starter(pet_id: String) -> bool:
	if not needs_starter_pick:
		return false
	if not PetService.is_starter(pet_id):
		return false
	var order_id := AccountManager.new_client_order_id()
	var result: Dictionary = await AccountManager.pick_starter_pet(order_id, pet_id)
	if int(result.get("code", 0)) / 100 != 2:
		return false
	# 发货回执里没有完整的宠物状态，拉一次拿权威值。
	# 照着回执自己拼的话，「服务端到底给了哪只」就有两个说法了。
	return await refresh_pets()

# --- 出战种族（RacePick）---------------------------------------------------

# 该用的出战种族。永远返回一份合法选择：从没选过、还没拉到、或存的那份已经不合法时就是默认。
func get_selected_races() -> Array[String]:
	return RacePick.resolve(selected_races)


# 从服务端拉一次出战种族。返回有没有拉到。**失败时不动缓存**（同 refresh_pets）。
func refresh_races() -> bool:
	if not AccountManager.is_logged_in():
		return false
	var result: Dictionary = await AccountManager.fetch_races()
	if int(result.get("code", 0)) / 100 != 2:
		return false
	_adopt_races(result.get("body", {}))
	return true


# 只收一份完整、合法的选择；不合法返回 false，什么都不改（备战页只在凑满时才让保存）。
#
# 🔴 **存到服务端才算数。** 没存上就返回 false、缓存一个字都不动，备战页据此提示「没存上」。
# 只改本机缓存的话，页面上显示已保存，下一局出战名片上带的却还是服务端那份。
func set_selected_races(races: Array) -> bool:
	var clean := RacePick.sanitize(races)
	if clean.is_empty():
		return false
	if clean == selected_races:
		return true
	var result: Dictionary = await AccountManager.save_races(clean)
	if int(result.get("code", 0)) / 100 != 2:
		return false
	_adopt_races(result.get("body", {}))
	return true


# body = {"races": [...] | null}，null = 从没选过。拉取与保存的回执共用它。
# 服务端不管「必须几个」，所以这里按 RacePick 清洗：不合规则的清成空 = 用默认，
# 与战斗服务器对名片的口径一致（BattleCard.races_of）。
func _adopt_races(body: Dictionary) -> void:
	var next: Array[String] = []
	var raw: Variant = body.get("races", null)
	if typeof(raw) == TYPE_ARRAY:
		next = RacePick.sanitize(raw)
	if next == selected_races:
		return
	selected_races = next
	races_changed.emit()
