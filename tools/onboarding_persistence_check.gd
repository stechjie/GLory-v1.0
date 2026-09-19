extends Node

# V12-03: language/onboarding must survive cold starts without guessing legacy
# completion, and profile writes must not destroy the previous valid generation.

const CheckHarness := preload("res://tools/CheckHarness.gd")
const CHECK_NAME := "onboarding_persistence"

var _h: CheckHarness
var _snapshot: Dictionary = {}
var _locale_before := "zh"


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_locale_before = LocaleManager.get_locale()
	_snapshot = _snapshot_files()
	_run_checks()
	_restore_files(_snapshot)
	LocaleManager.set_locale(_locale_before)
	_h.finish(get_tree())


func _run_checks() -> void:
	_clear_profile_files()
	var legacy := {
		"version": 3,
		"owned_pets": ["pet_rabbit"],
		"active_pet": "pet_rabbit",
		"needs_starter_pick": false,
		"codex_seen": ["human_militia"],
		"board_readability_enabled": false,
	}
	_write(PlayerProfile.PROFILE_PATH, JSON.stringify(legacy))
	PlayerProfile.load_profile()
	_h.expect(PlayerProfile.onboarding_status == PlayerProfile.ONBOARDING_LEGACY_UNKNOWN,
		"legacy_completion_was_guessed",
		"旧档被猜成已完成/已跳过；金币、宠物和局内状态都不是教学完成证明")
	_h.expect(not PlayerProfile.language_selected,
		"legacy_language_was_guessed", "旧档没有语言证据，却被当成已经选过语言")
	_h.expect(PlayerProfile.startup_route() == PlayerProfile.STARTUP_LANGUAGE,
		"legacy_startup_route_wrong", "旧档没有先回语言页完成一次显式迁移")
	_h.expect(PlayerProfile.codex_seen.has("human_militia")
			and not PlayerProfile.board_readability_enabled,
		"legacy_fields_lost", "新增 onboarding 字段时改坏了旧档原有内容")
	# 宠物**不在**上面那条里：归属 2026-09-16 上云之后，owned_pets / active_pet
	# 已经不从本机档案读了（SaveSchema v6 直接把这几个键 erase 掉）。
	# 这里反过来钉住新行为 —— 留着旧值才是 bug。
	_h.expect(PlayerProfile.active_pet.is_empty() and PlayerProfile.owned_pets.is_empty(),
		"legacy_pets_still_local",
		"旧档里的宠物归属还被读进内存了 —— 真相在服务端，本机不该有")
	for dead_key in ["owned_pets", "active_pet", "needs_starter_pick"]:
		_h.expect(not _read_json(PlayerProfile.PROFILE_PATH).has(dead_key),
			"legacy_pet_key_persisted",
			"迁移后本机档案还留着 %s" % dead_key)
	var migrated := _read_json(PlayerProfile.PROFILE_PATH)
	_h.expect(int(migrated.get("version", 0)) == SaveSchema.PROFILE_VERSION,
		"migration_not_persisted", "旧 profile 没有一次性迁移到当前 schema")

	_h.expect(PlayerProfile.select_language("en"), "language_save_failed", "语言选择没有原子落盘")
	_h.expect(PlayerProfile.language_selected and PlayerProfile.locale == "en"
			and LocaleManager.get_locale() == "en",
		"language_not_applied", "已保存语言与当前 TranslationServer 不一致")
	_h.expect(PlayerProfile.startup_route() == PlayerProfile.STARTUP_TUTORIAL,
		"selected_language_skips_onboarding", "只选语言就绕过了未完成教学")
	var selected := _read_json(PlayerProfile.PROFILE_PATH)
	_h.expect(bool(selected.get("language_selected", false))
			and str(selected.get("locale", "")) == "en",
		"language_not_persisted", "profile.json 没有保存明确语言选择")

	_h.expect(PlayerProfile.set_onboarding_status(PlayerProfile.ONBOARDING_COMPLETED),
		"completed_save_failed", "教学完成状态落盘失败")
	for cold_start in 3:
		PlayerProfile.load_profile()
		_h.expect(PlayerProfile.startup_route() == PlayerProfile.STARTUP_MENU,
			"completed_reentered_tutorial",
			"第 %d 次冷启动仍把已完成玩家送回语言/教学" % (cold_start + 1))
	_h.expect(PlayerProfile.set_onboarding_status(PlayerProfile.ONBOARDING_SKIPPED),
		"skipped_save_failed", "教学跳过状态落盘失败")
	PlayerProfile.load_profile()
	_h.expect(PlayerProfile.startup_route() == PlayerProfile.STARTUP_MENU,
		"skipped_reentered_tutorial", "明确跳过后冷启动又进入教学")

	_h.expect(PlayerProfile.begin_tutorial(), "replay_save_failed", "重播教学无法写入 in_progress")
	_h.expect(PlayerProfile.onboarding_status == PlayerProfile.ONBOARDING_IN_PROGRESS
			and PlayerProfile.startup_route() == PlayerProfile.STARTUP_TUTORIAL,
		"replay_does_not_route_tutorial", "设置页重播没有重新进入可恢复的教学状态")

	# A corrupt primary must fall back to the last valid generation.
	var valid := _read_json(PlayerProfile.PROFILE_PATH)
	_write(PlayerProfile.PROFILE_PATH + PlayerProfile.BAK_SUFFIX, JSON.stringify(valid))
	_write(PlayerProfile.PROFILE_PATH, "{broken")
	PlayerProfile.onboarding_status = PlayerProfile.ONBOARDING_COMPLETED
	PlayerProfile.load_profile()
	_h.expect(PlayerProfile.onboarding_status == PlayerProfile.ONBOARDING_IN_PROGRESS,
		"profile_backup_not_used", "profile.json 损坏时没有读取有效 .bak")

	var main_src := FileAccess.get_file_as_string("res://scenes/main/Main.gd")
	var status_pos := main_src.find("set_onboarding_status(PlayerProfile.ONBOARDING_SKIPPED)")
	var finish_pos := main_src.find("TutorialMode.finish(persisted)", status_pos)
	_h.expect(status_pos >= 0 and finish_pos > status_pos,
		"skip_clears_checkpoint_first", "跳过教学仍可能先清断点、后写账户状态")
	_h.expect(main_src.contains("replay_tutorial_requested.connect(_on_replay_tutorial_requested)"),
		"replay_setting_not_connected", "设置页的重播教学按钮没有接到 Main 路由")


func _profile_paths() -> PackedStringArray:
	return PackedStringArray([
		PlayerProfile.PROFILE_PATH,
		PlayerProfile.PROFILE_PATH + PlayerProfile.BAK_SUFFIX,
		PlayerProfile.PROFILE_PATH + PlayerProfile.TMP_SUFFIX,
	])


func _snapshot_files() -> Dictionary:
	var out := {}
	for path in _profile_paths():
		out[path] = FileAccess.get_file_as_bytes(path) if FileAccess.file_exists(path) else null
	return out


func _restore_files(snapshot: Dictionary) -> void:
	for path in _profile_paths():
		var wanted = snapshot.get(path)
		if wanted == null:
			if FileAccess.file_exists(path):
				DirAccess.remove_absolute(path)
		else:
			var f := FileAccess.open(path, FileAccess.WRITE)
			if f != null:
				f.store_buffer(wanted as PackedByteArray)
				f = null


func _clear_profile_files() -> void:
	for path in _profile_paths():
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


func _write(path: String, content: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(content)
		f = null


func _read_json(path: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed as Dictionary if parsed is Dictionary else {}
