extends Node
# 账号级持久档（跨局保留，绝不进 GameState.reset_run）。
# 目前只承载宠物系统的归属数据：拥有的宠物 + 当前出战宠物。
# 首次进游戏时不直接发放，而是标记 needs_starter_pick，由备战界面弹「三选一」。

const PROFILE_PATH := "user://profile.json"

signal pets_changed()
signal codex_changed()
signal presentation_settings_changed()

var owned_pets: Array[String] = []
var active_pet := ""
var needs_starter_pick := false
# Codex entries the player has encountered. Account-level and append-only: nothing
# a player has seen is ever taken away.
var codex_seen: Array[String] = []
var board_readability_enabled := true

func _ready() -> void:
	load_profile()

func load_profile() -> void:
	if not FileAccess.file_exists(PROFILE_PATH):
		# 全新账号：等待玩家三选一，先不发放任何宠物。
		owned_pets.clear()
		active_pet = ""
		codex_seen.clear()
		board_readability_enabled = true
		needs_starter_pick = true
		save_profile()
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(PROFILE_PATH))
	if typeof(parsed) != TYPE_DICTIONARY:
		owned_pets.clear()
		active_pet = ""
		codex_seen.clear()
		board_readability_enabled = true
		needs_starter_pick = true
		return
	# Migrate before reading: older profiles carry renamed pet ids and no codex.
	var data: Dictionary = SaveSchema.migrate_profile(parsed as Dictionary)
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
	needs_starter_pick = bool(data.get("needs_starter_pick", owned_pets.is_empty()))
	# 出战宠物必须是已拥有的；否则回落到第一只（或空）。
	if not active_pet.is_empty() and not owned_pets.has(active_pet):
		active_pet = owned_pets[0] if not owned_pets.is_empty() else ""
	# Persist the migrated shape so the upgrade only ever runs once.
	if int(parsed.get("version", 1)) < SaveSchema.PROFILE_VERSION:
		save_profile()

func save_profile() -> void:
	var payload := {
		"version": SaveSchema.PROFILE_VERSION,
		"owned_pets": owned_pets,
		"active_pet": active_pet,
		"needs_starter_pick": needs_starter_pick,
		"codex_seen": codex_seen,
		"board_readability_enabled": board_readability_enabled,
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
