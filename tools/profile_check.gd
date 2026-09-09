extends Node

# 玩家资料系统客户端侧的验收。设计文档：docs/玩家资料系统设计.md。
#
# 这里守的几条都是**静默失效**类型 —— 违反了不报错、不崩溃，只是悄悄错着：
#
#   1. 头像清单指向不存在的图    → 玩家头像空白，且是一批人一起空
#   2. 头像 id 直接用了单位 id    → 美术改名那天所有人一起挂
#   3. 显示名少了好友码           → 改名冒充成立（player_name 不唯一）
#   4. 门面方法少一个             → 有人绕过 AccountManager 自己拼 HTTP
#   5. 生日日数不按月份卡          → 玩家能选出一个必然被后端拒绝的日子
#
# 运行：
#   Godot_v4.7.1-stable_win64_console.exe --headless --path . tools/profile_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const Catalog := preload("res://scripts/account/AvatarCatalog.gd")
const ProfileScreenScript := preload("res://scenes/menu/ProfileScreen.gd")
const AvatarPickerScript := preload("res://scenes/menu/AvatarPickerPanel.gd")

const CHECK_NAME := "profile"

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_case_catalog_shape()
	_case_catalog_sources_exist()
	_case_catalog_ids_decoupled()
	_case_thumbnails_generated()
	_case_display_name_always_carries_code()
	_case_facade_methods()
	_case_days_in_month_matches_migration()
	_case_screens_instantiate()
	_case_region_codes_are_iso()
	_case_nameplate_shows_avatar()
	_case_account_reset_keeps_device_state()
	_h.finish(get_tree())


# --- 头像清单 -----------------------------------------------------------------

func _case_catalog_shape() -> void:
	var avatars := Catalog.avatars()
	_h.expect(avatars.size() > 0, "catalog_empty",
		"data/avatars.json 里一个头像都没有")
	var ids: Array[String] = []
	for entry in avatars:
		var id := str((entry as Dictionary).get("id", ""))
		_h.expect(not ids.has(id), "catalog_duplicate_id", "头像 id 重复：%s" % id)
		ids.append(id)
	var fallback := Catalog.default_avatar()
	_h.expect(ids.has(Catalog.id_from_value(fallback)), "catalog_default_missing",
		"default_id 不在清单里：%s" % fallback)


func _case_catalog_sources_exist() -> void:
	# 清单指向不存在的图，是这套 id 映射唯一会坏的方式。
	for entry in Catalog.avatars():
		var row := entry as Dictionary
		var source := str(row.get("source", ""))
		_h.expect(ResourceLoader.exists(source), "catalog_source_missing",
			"%s 指向不存在的图：%s" % [row.get("id", "?"), source])


func _case_catalog_ids_decoupled() -> void:
	# 头像 id 必须是 avatar_NNN，**不能直接用单位 id**。
	# 用单位 id 的话，美术把 dark_dragon 重做改名成 dark_wyrm，
	# 所有选了这个头像的玩家会一起变空白 —— SaveSchema.PET_ID_RENAMES 里
	# 那条 pet_duck → pet_rabbit 就是同类事故留下的。
	var pattern := RegEx.new()
	pattern.compile("^avatar_[0-9]{3}$")
	for entry in Catalog.avatars():
		var row := entry as Dictionary
		var id := str(row.get("id", ""))
		_h.expect(pattern.search(id) != null, "catalog_id_shape",
			"头像 id 不符合 avatar_NNN：%s" % id)
		var stem := str(row.get("source", "")).get_file().get_basename()
		_h.expect(id != stem, "catalog_id_is_unit_id",
			"头像 id 不能等于单位 id：%s" % id)


func _case_thumbnails_generated() -> void:
	# 缩略图没生成时 texture_for 会回落到原图，画得出来但会卡 ——
	# 这属于「忘了跑 tools/make_avatar_thumbs.py」，该被门禁抓住而不是靠手感发现。
	for entry in Catalog.avatars():
		var id := str((entry as Dictionary).get("id", ""))
		_h.expect(ResourceLoader.exists(Catalog.thumb_path(id)), "thumb_missing",
			"缺缩略图（跑 tools/make_avatar_thumbs.py）：%s" % id)


# --- 冒充防线 -----------------------------------------------------------------

func _case_display_name_always_carries_code() -> void:
	# players.player_name **不唯一**（database/001 的设计）。
	# 你叫 Leno，别人改名成 Leno 就能冒充你 —— 只要 UI 里存在任何一处
	# 只显示昵称的地方，冒充就成立。所以显示名只能从这一个函数出。
	var mgr := get_node_or_null("/root/AccountManager")
	if not _h.expect(mgr != null, "autoload_missing", "AccountManager autoload 没挂上"):
		return
	var shown: String = mgr.call("display_name", "Leno", "7K2M9Q4B")
	_h.expect(shown.contains("Leno"), "display_name_drops_name", "显示名丢了昵称")
	_h.expect(shown.contains("7K2M9Q4B"), "display_name_drops_code",
		"显示名里没有好友码 —— 只显示昵称的地方就是冒充成立的地方")
	# 没有好友码时（还没登录）不能拼出一个空的 "#"。
	var bare: String = mgr.call("display_name", "Leno", "")
	_h.expect(not bare.contains("#"), "display_name_dangling_hash",
		"没有好友码时不该留一个孤零零的 #")


func _case_facade_methods() -> void:
	# 门面完整性：UI 只认这几个入口，少一个就会有人绕过去自己拼 HTTP
	# （docs/账号系统RFC.md 第三节的硬约束）。
	var mgr := get_node_or_null("/root/AccountManager")
	if mgr == null:
		return
	for method in [
		"fetch_my_profile", "update_profile", "update_bio",
		"fetch_public_profile", "display_name", "cached_display_name",
	]:
		_h.expect(mgr.has_method(method), "facade_method_missing",
			"AccountManager 缺少资料门面方法：%s" % method)
	# 登出必须把资料缓存一起清掉，否则下一个人登录后名牌会先画出上一个账号。
	_h.expect(typeof(mgr.get("profile")) == TYPE_DICTIONARY, "profile_cache_shape",
		"AccountManager.profile 应当是 Dictionary")


# --- 与迁移文件的一致性 -------------------------------------------------------

func _case_days_in_month_matches_migration() -> void:
	# 客户端的日数上限必须与 database/002 的 birth_day_in_month 约束一致，
	# 否则玩家能在下拉里选出一个必然被后端 400 掉的日子（例如 2/31）。
	# 2 月是 29 —— 闰日生日是真实存在的。
	var expected := [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
	var actual: Array = ProfileScreenScript.DAYS_IN_MONTH
	_h.expect(actual == expected, "days_in_month_drift",
		"ProfileScreen.DAYS_IN_MONTH 与 002 的 birth_day_in_month 对不上：%s" % str(actual))

	# 约束本体在 **002**（birth_day_in_month），不在 004 —— 004 只加列。
	# 第一版这里读错了文件，门禁当场就把它报出来了，这正是它该干的事。
	var sql := FileAccess.get_file_as_string("res://database/002_player_bio.sql")
	if _h.expect(not sql.is_empty(), "migration_unreadable",
			"读不到 002_player_bio.sql"):
		var literal := "array[%s]" % ", ".join(expected.map(func(n): return str(n)))
		_h.expect(sql.contains(literal), "migration_days_drift",
			"002 的 birth_day_in_month 与客户端的日数表对不上")


func _case_region_codes_are_iso() -> void:
	# database/002 的 region_format 是 ^[A-Z]{2}$。列表里混进一个小写或三位的
	# 会让那个选项永远保存失败，而且只有选到它的玩家会遇到。
	var pattern := RegEx.new()
	pattern.compile("^[A-Z]{2}$")
	for region in ProfileScreenScript.REGIONS:
		var code := str((region as Array)[0])
		_h.expect(pattern.search(code) != null, "region_code_shape",
			"地区代码不是两位大写：%s" % code)


# --- 能不能真的开起来 ---------------------------------------------------------

func _case_screens_instantiate() -> void:
	# 这一条替代不了人工过一遍界面，但它挡住「改了一行结果整页打不开」——
	# 资料页是运行时 load 的，解析错误在玩家点开之前不会有任何征兆。
	var scene := load("res://scenes/menu/ProfileScreen.tscn") as PackedScene
	if not _h.expect(scene != null, "profile_scene_missing",
			"ProfileScreen.tscn 加载失败"):
		return
	var screen := scene.instantiate() as Control
	if not _h.expect(screen != null, "profile_scene_shape",
			"ProfileScreen.tscn 的根节点不是 Control"):
		return
	for method in ["configure_self", "configure_public"]:
		_h.expect(screen.has_method(method), "profile_configure_missing",
			"ProfileScreen 缺少 %s —— Main.gd 靠它避开 preload 整张依赖图" % method)
	_h.expect(screen.has_signal("back_requested"), "profile_back_signal",
		"ProfileScreen 缺少 back_requested，返回键会走不通")
	screen.free()

	var picker := AvatarPickerScript.new() as Control
	_h.expect(picker != null, "picker_shape", "AvatarPickerPanel 不是 Control")
	if picker != null:
		_h.expect(picker.has_signal("picked"), "picker_signal", "选择器缺少 picked 信号")
		picker.free()

	# 主菜单必须把名牌接出来，否则那个按钮又变回「敬请期待」。
	var menu_scene := load("res://scenes/menu/MainMenu.tscn") as PackedScene
	if menu_scene == null:
		return
	var menu := menu_scene.instantiate() as Control
	_h.expect(menu.has_signal("profile_requested"), "menu_profile_signal",
		"MainMenu 缺少 profile_requested 信号")
	menu.free()


func _case_nameplate_shows_avatar() -> void:
	"""主菜单名牌要真的把头像画出来。

	这条挡的是一个不会报错的退化：profile_avatar.png 的圆心是**不透明**的，
	所以头像必须画在框之上并裁成圆形。哪天有人把它挪回框之前（照那条旧 TODO
	的写法），画面上就是一个空框 —— 没有任何错误，只是头像没了。
	"""
	var mgr := get_node_or_null("/root/AccountManager")
	var menu_scene := load("res://scenes/menu/MainMenu.tscn") as PackedScene
	if mgr == null or menu_scene == null:
		return
	var menu := menu_scene.instantiate() as Control
	# 名牌是在 _ready 里建的，要先进树。
	add_child(menu)

	var saved: Dictionary = mgr.get("profile")
	mgr.set("profile", {
		"friend_code": "7K2M9Q4B", "player_name": "Leno",
		"avatar": "preset:avatar_005", "days_since_created": 12,
	})
	menu.call("_refresh_profile_plate")
	var portrait := menu.get("_profile_portrait") as TextureRect
	_h.expect(portrait != null, "nameplate_portrait_missing",
		"MainMenu 名牌上没有头像节点")
	if portrait != null:
		_h.expect(portrait.texture != null, "nameplate_portrait_blank",
			"名牌头像是空的 —— 资料里有 avatar 却没画出来")

	# 没登录时**不该**先画一个默认头像再跳变。
	mgr.set("profile", {})
	menu.call("_refresh_profile_plate")
	if portrait != null:
		_h.expect(portrait.texture == null, "nameplate_portrait_placeholder",
			"还没拉到资料时名牌不该先画一个头像")

	mgr.set("profile", saved)
	remove_child(menu)
	menu.free()


# 注销之后本地要清成什么样。
#
# ⚠️ 这一条会**真的写** user://profile.json（reset_account_state 内部会落盘），
# 所以先备份再还原 —— 同 tools/account_check.gd 对凭证文件的做法。
# 额外在磁盘上留一份 profile.check_backup.json：万一进程中途挂了，
# 开发者的宠物和图鉴还能捞回来，而不是「跑了个检查，存档没了」。
const PROFILE_PATH := "user://profile.json"
const CHECK_BACKUP := "user://profile.check_backup.json"

func _case_account_reset_keeps_device_state() -> void:
	var backup := FileAccess.get_file_as_string(PROFILE_PATH)
	if not backup.is_empty():
		var f := FileAccess.open(CHECK_BACKUP, FileAccess.WRITE)
		if f != null:
			f.store_string(backup)
			f.close()

	var pp := get_node_or_null("/root/PlayerProfile")
	if not _h.expect(pp != null, "profile_autoload_missing", "PlayerProfile autoload 没挂上"):
		return
	_h.expect(pp.has_method("reset_account_state"), "reset_method_missing",
		"PlayerProfile 缺少 reset_account_state —— 注销之后本地清不掉")
	if not pp.has_method("reset_account_state"):
		return

	# 造一个「有进度、且设备态被玩家改过」的状态
	var old_id: String = pp.get("player_id")
	pp.set("owned_pets", ["pet_cat"] as Array[String])
	pp.set("active_pet", "pet_cat")
	pp.set("codex_seen", ["unit_human_king"] as Array[String])
	pp.set("needs_starter_pick", false)
	pp.set("screen_shake_enabled", false)
	pp.set("haptics_enabled", false)
	pp.set("locale", "en")
	pp.set("language_selected", true)

	pp.call("reset_account_state")

	# 账号态：清干净
	_h.expect((pp.get("owned_pets") as Array).is_empty(), "reset_kept_pets",
		"注销后还留着宠物")
	_h.expect(str(pp.get("active_pet")).is_empty(), "reset_kept_active_pet",
		"注销后还留着出战宠物")
	_h.expect((pp.get("codex_seen") as Array).is_empty(), "reset_kept_codex",
		"注销后还留着图鉴进度")
	_h.expect(bool(pp.get("needs_starter_pick")), "reset_skips_starter",
		"注销后应当重新走一遍三选一")
	# player_id 必须重签，否则下次匿名注册会把同一个 id 报上去，身份原地复活。
	_h.expect(str(pp.get("player_id")) != old_id, "reset_kept_player_id",
		"注销后没有重签 player_id —— 同一个身份会原地复活，等于没删")

	# 设备态：一个都不许动
	_h.expect(not bool(pp.get("screen_shake_enabled")), "reset_clobbered_device_state",
		"注销把屏震开关重置了 —— 设备态不属于账号")
	_h.expect(not bool(pp.get("haptics_enabled")), "reset_clobbered_device_state",
		"注销把触感开关重置了")
	_h.expect(str(pp.get("locale")) == "en", "reset_clobbered_locale",
		"注销把语言重置了 —— 重问一次语言不保护任何数据，只是摩擦")
	_h.expect(bool(pp.get("language_selected")), "reset_clobbered_locale",
		"注销后又要重选语言")

	# 门面完整性
	var mgr := get_node_or_null("/root/AccountManager")
	if mgr != null:
		_h.expect(mgr.has_method("delete_account"), "facade_method_missing",
			"AccountManager 缺少 delete_account")

	# 还原
	if not backup.is_empty():
		var out := FileAccess.open(PROFILE_PATH, FileAccess.WRITE)
		if out != null:
			out.store_string(backup)
			out.close()
		pp.call("load_profile")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CHECK_BACKUP))
