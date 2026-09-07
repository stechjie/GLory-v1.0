extends Node
# 账号级持久档（跨局保留，绝不进 GameState.reset_run）。
# 目前只承载宠物系统的归属数据：拥有的宠物 + 当前出战宠物。
# 首次进游戏时不直接发放，而是标记 needs_starter_pick，由备战界面弹「三选一」。

const PROFILE_PATH := "user://profile.json"
# 解析失败的档案在被覆盖前先挪到这里。见 _preserve_corrupt_profile。
const CORRUPT_PROFILE_PATH := "user://profile.corrupt.json"

signal pets_changed()
signal codex_changed()
signal presentation_settings_changed()

# 玩家的永久身份，本机第一次读档时签发，之后永不改变。
# 语义、随机源、以及"为什么不能等接账号时再加"都在 SaveSchema.PLAYER_ID_PATTERN
# 那一段和 docs/账号系统RFC.md 里。
#
# 这里只存不用：第 0 步不联网、不注册、不登录，也没有任何一张表挂在它下面。
# 先把 id 固定下来，是为了让将来那些表**一开始就**挂对地方。
var player_id := ""
var owned_pets: Array[String] = []
var active_pet := ""
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
# 与 GloryTokens.REDUCED_MOTION_SETTING 必须一致。这里不 preload 那个类：
# autoload 反过来依赖 UI 层会把依赖方向倒过来。门禁断言两边字面相同。
const REDUCED_MOTION_SETTING := "glory/ui/reduced_motion"

func _ready() -> void:
	load_profile()

func load_profile() -> void:
	if not FileAccess.file_exists(PROFILE_PATH):
		# 全新账号：等待玩家三选一，先不发放任何宠物。
		_reset_to_defaults()
		player_id = SaveSchema.new_player_id()
		save_profile()
		return
	# 不叫 raw：下面读 codex_seen 的循环已经用了这个名字，同作用域会直接编译失败。
	var raw_text := FileAccess.get_file_as_string(PROFILE_PATH)
	var parsed = JSON.parse_string(raw_text)
	if typeof(parsed) != TYPE_DICTIONARY:
		# 坏档：这条路径原本只重置内存、不落盘。现在必须落盘 —— 新签的 player_id
		# 不写回去，下次冷启动就会再签一个，正是本次要防的那种静默身份漂移。
		# 既然要覆盖，原始字节先另存一份，别让「存档打不开」变成「存档没了」。
		_preserve_corrupt_profile(raw_text)
		_reset_to_defaults()
		player_id = SaveSchema.new_player_id()
		save_profile()
		return
	# Migrate before reading: older profiles carry renamed pet ids and no codex.
	var data: Dictionary = SaveSchema.migrate_profile(parsed as Dictionary)
	# migrate_profile 保证这里一定拿得到一个合法 id：档案里有就原样带出来，
	# 没有或写坏了才现签一个。不要在这里加 `if player_id.is_empty()` 之类的兜底 ——
	# 签发只能有一处，两处就迟早会各签各的。
	player_id = str(data.get("player_id", ""))
	owned_pets.clear()
	for pid in data.get("owned_pets", []):
		var id := str(pid)
		if not id.is_empty() and not owned_pets.has(id):
			owned_pets.append(id)
	active_pet = str(data.get("active_pet", ""))
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
	_apply_reduced_motion()
	needs_starter_pick = bool(data.get("needs_starter_pick", owned_pets.is_empty()))
	# 出战宠物必须是已拥有的；否则回落到第一只（或空）。
	if not active_pet.is_empty() and not owned_pets.has(active_pet):
		active_pet = owned_pets[0] if not owned_pets.is_empty() else ""
	# Persist the migrated shape so the upgrade only ever runs once.
	#
	# player_id 要单独判一次：档案版本号已经是最新、但 id 缺失或被写坏时，
	# migrate_profile 会现签一个，而上面那个版本条件是 false —— 只看版本号就会漏掉
	# 这份档案，新 id 不落盘，下次启动再签一个。必须两个条件都看。
	if int(parsed.get("version", 1)) < SaveSchema.PROFILE_VERSION \
			or str(parsed.get("player_id", "")) != player_id:
		save_profile()

# **唯一允许改变已有 player_id 的入口，而且只有一个合法理由：**
# 账号服务器回了 409，说这个 id 已经属于别人（见 AccountManager.login）。
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


# 全新档案与坏档共用的重置。原来这两段是逐字段抄的两份，加 player_id 时
# 正好合并 —— 两份默认值各改各的迟早会漂。
func _reset_to_defaults() -> void:
	owned_pets.clear()
	active_pet = ""
	codex_seen.clear()
	board_readability_enabled = true
	screen_shake_enabled = true
	flash_effects_enabled = true
	hit_stop_enabled = true
	reduced_motion_enabled = false
	ui_sound_enabled = true
	haptics_enabled = true
	_apply_reduced_motion()
	needs_starter_pick = true

# 覆盖坏档之前留一份原始字节，方便事后人工捞。只留最近一次：更早的那份已经
# 是「上一次也坏了」，价值不大，不值得为它做轮转。
func _preserve_corrupt_profile(raw: String) -> void:
	var f := FileAccess.open(CORRUPT_PROFILE_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("[PROFILE] profile.json 解析失败，且原始内容备份不出去（%s 打不开）" % CORRUPT_PROFILE_PATH)
		return
	f.store_string(raw)
	push_warning("[PROFILE] profile.json 解析失败，原始内容已另存到 %s" % CORRUPT_PROFILE_PATH)

func save_profile() -> void:
	var payload := {
		"version": SaveSchema.PROFILE_VERSION,
		"player_id": player_id,
		"owned_pets": owned_pets,
		"active_pet": active_pet,
		"needs_starter_pick": needs_starter_pick,
		"codex_seen": codex_seen,
		"board_readability_enabled": board_readability_enabled,
		"screen_shake_enabled": screen_shake_enabled,
		"flash_effects_enabled": flash_effects_enabled,
		"hit_stop_enabled": hit_stop_enabled,
		"reduced_motion_enabled": reduced_motion_enabled,
		"ui_sound_enabled": ui_sound_enabled,
		"haptics_enabled": haptics_enabled,
	}
	var f := FileAccess.open(PROFILE_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(payload))

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

func grant(pet_id: String) -> void:
	if pet_id.is_empty() or owned_pets.has(pet_id):
		return
	if PetService.pet_by_id(pet_id).is_empty():
		return
	owned_pets.append(pet_id)
	if active_pet.is_empty():
		active_pet = pet_id
	save_profile()
	pets_changed.emit()

func set_active(pet_id: String) -> void:
	if not owned_pets.has(pet_id) or active_pet == pet_id:
		return
	active_pet = pet_id
	save_profile()
	pets_changed.emit()

# 首次三选一：发放选中的宠物、设为出战、清除待选标记。
func pick_starter(pet_id: String) -> bool:
	if not needs_starter_pick:
		return false
	if not PetService.is_starter(pet_id):
		return false
	owned_pets.append(pet_id)
	active_pet = pet_id
	needs_starter_pick = false
	save_profile()
	pets_changed.emit()
	return true
