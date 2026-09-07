extends Node

# 账号系统第 0 步的验收：player_id 的签发与不变性。
#
# 为什么值得单开一个检查场景，而不是塞进 board_readability_check：
# 这里守的不是某个设置项的默认值，而是一条**违反了就静默丢数据**的不变量 ——
#
#     没有合法 id 就签发一次；已经有了就绝对不许再签。
#
# 签重了不会报错、不会崩溃、日志里什么都没有。接上账号之后，它的表现是玩家每次
# 冷启动都变成一个新玩家，金币英雄全部消失。这类 bug 只能靠断言挡在上线之前，
# 靠人工测试是发现不了的（本机跑一次永远是「有 id、能进游戏」）。
#
# 主体用例打在 SaveSchema.migrate_profile() 这个纯函数上 —— 没有 autoload、
# 不碰真实存档，可以把各种畸形档案直接构造出来喂进去。最后两条才去看 autoload
# 的接线，那两条是只读的。
#
# 运行：
#   Godot_v4.7-stable_win64_console.exe --headless --path . tools/player_identity_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")

const CHECK_NAME := "player_identity"

# 一个固定的合法 id，用来断言「原样保留」。写死而不是现签，是为了让失败信息里
# 能直接看出期望值。
const KNOWN_ID := "52c7027a-3f81-4a1e-9c2d-8b7e4f0a1234"

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_case_fresh_profile_gets_id()
	_case_migration_is_idempotent()
	_case_existing_id_survives_upgrade()
	_case_current_version_missing_id()
	_case_malformed_id_reissued()
	_case_ids_are_unique()
	_case_id_format()
	_case_autoload_wired()
	_case_disk_round_trip()
	_case_reissue_is_explicit_and_persists()
	_h.finish(get_tree())


# --- 用例 ---------------------------------------------------------------------

# 全新档案（连 version 都没有）必须拿到一个合法 id，并升到当前版本。
func _case_fresh_profile_gets_id() -> void:
	var out := SaveSchema.migrate_profile({})
	_h.expect(SaveSchema.is_valid_player_id(str(out.get("player_id", ""))),
		"fresh_no_id", "全新档案迁移后必须带合法 player_id，实得：%s" % str(out.get("player_id", "")))
	_h.expect(int(out.get("version", 0)) == SaveSchema.PROFILE_VERSION,
		"fresh_version", "全新档案必须升到 PROFILE_VERSION=%d，实得 %d" % [
			SaveSchema.PROFILE_VERSION, int(out.get("version", 0))])


# 本检查的核心：同一份档案反复迁移，id 不能变。
# 这条挂了就等于玩家每次读档换一个身份。
func _case_migration_is_idempotent() -> void:
	var first := SaveSchema.migrate_profile({})
	var id := str(first.get("player_id", ""))
	var current := first
	for i in 5:
		current = SaveSchema.migrate_profile(current)
		if not _h.expect(str(current.get("player_id", "")) == id,
			"reissued_on_remigrate",
			"第 %d 次重复迁移后 player_id 变了：%s → %s" % [
				i + 1, id, str(current.get("player_id", ""))]):
			return


# 老档案升级时，已有的 id 必须原样带过去 —— 升级不能顺手把玩家换掉。
func _case_existing_id_survives_upgrade() -> void:
	var old := {
		"version": 1,
		"player_id": KNOWN_ID,
		"owned_pets": ["pet_duck"],
		"active_pet": "pet_duck",
	}
	var out := SaveSchema.migrate_profile(old)
	_h.expect(str(out.get("player_id", "")) == KNOWN_ID,
		"id_lost_on_upgrade",
		"v1→v%d 升级后 player_id 必须不变，期望 %s，实得 %s" % [
			SaveSchema.PROFILE_VERSION, KNOWN_ID, str(out.get("player_id", ""))])
	# 顺带确认这一路上原有的迁移没被这次改动弄坏。
	_h.expect(out.get("active_pet", "") == "pet_rabbit",
		"rename_regressed", "v1 档案的宠物改名迁移不能因为加 player_id 而失效")


# 版本号已经是最新、但档案里没有 id —— migrate_profile 早年的写法会在这里直接
# early return，什么都不补。这一条就是钉住那个洞。
func _case_current_version_missing_id() -> void:
	var out := SaveSchema.migrate_profile({"version": SaveSchema.PROFILE_VERSION})
	_h.expect(SaveSchema.is_valid_player_id(str(out.get("player_id", ""))),
		"current_version_no_id",
		"版本已最新但缺 player_id 的档案也必须补发，实得：%s" % str(out.get("player_id", "")))


# 写坏的 id 要重签，而且重签出来的必须合法。
func _case_malformed_id_reissued() -> void:
	var bad := [
		"",                                          # 空
		"not-a-uuid",                                # 完全不是
		"52c7027a3f814a1e9c2d8b7e4f0a1234",          # 少了连字符
		"52c7027a-3f81-1a1e-9c2d-8b7e4f0a1234",      # 版本位不是 4
		"52c7027a-3f81-4a1e-1c2d-8b7e4f0a1234",      # 变体位不在 [89ab]
		"52C7027A-3F81-4A1E-9C2D-8B7E4F0A1234",      # 大写：签发一律小写，不接受
		"52c7027a-3f81-4a1e-9c2d-8b7e4f0a123",       # 短一位
	]
	for raw in bad:
		var out := SaveSchema.migrate_profile({"version": SaveSchema.PROFILE_VERSION, "player_id": raw})
		var got := str(out.get("player_id", ""))
		_h.expect(SaveSchema.is_valid_player_id(got),
			"malformed_not_fixed", "非法 id %s 重签后仍不合法：%s" % [JSON.stringify(raw), got])
		_h.expect(got != raw,
			"malformed_kept", "非法 id 必须被替换，但原样留下了：%s" % raw)


# 撞号检查。数量不大，够挡住「随机源根本没随机」这类问题（比如误用了
# 确定性的 RngService，那会让所有设备签出同一个 id）。
func _case_ids_are_unique() -> void:
	var seen := {}
	for i in 512:
		var id := SaveSchema.new_player_id()
		if not _h.expect(not seen.has(id), "duplicate_id", "第 %d 次签发撞号：%s" % [i, id]):
			return
		seen[id] = true


# 格式细节单独验一遍，免得 is_valid_player_id 和 new_player_id 一起写错、
# 互相「验证」通过。
func _case_id_format() -> void:
	for i in 32:
		var id := SaveSchema.new_player_id()
		_h.expect(id.length() == 36, "bad_length", "UUID 长度应为 36：%s" % id)
		_h.expect(id == id.to_lower(), "not_lowercase", "签发的 id 必须全小写：%s" % id)
		if not _h.expect(id.length() == 36, "bad_length_guard", "长度不对，跳过位判定：%s" % id):
			continue
		_h.expect(id[14] == "4", "bad_version_nibble", "RFC 4122 版本位应为 4：%s" % id)
		_h.expect("89ab".contains(id[19]), "bad_variant_nibble", "RFC 4122 变体位应为 [89ab]：%s" % id)


# --- autoload 接线（只读，不改任何东西）----------------------------------------

func _case_autoload_wired() -> void:
	var profile := get_node_or_null("/root/PlayerProfile")
	if not _h.expect(profile != null, "autoload_missing", "PlayerProfile autoload 没挂上"):
		return
	var id := str(profile.get("player_id"))
	_h.expect(SaveSchema.is_valid_player_id(id),
		"autoload_id_invalid", "PlayerProfile.player_id 不是合法 UUID：%s" % id)


# autoload 读完档之后，磁盘上的 profile.json 必须写着同一个 id。
# 这一条覆盖的是 save_profile() 有没有真的把 player_id 落进 payload ——
# 只在内存里对、没写盘，下次启动照样重签。
func _case_disk_round_trip() -> void:
	var profile := get_node_or_null("/root/PlayerProfile")
	if profile == null:
		return  # 上一条已经记过失败了
	# 常量不是属性，profile.get("PROFILE_PATH") 拿不到；走脚本的常量表，
	# 这样路径改了检查会跟着改，不用在两处各写一份字面量。
	var path := str(profile.get_script().get_script_constant_map().get("PROFILE_PATH", ""))
	if not _h.expect(not path.is_empty(), "profile_path_missing", "取不到 PlayerProfile.PROFILE_PATH"):
		return
	if not _h.expect(FileAccess.file_exists(path),
		"profile_not_written", "读档后 %s 应当存在" % path):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not _h.expect(parsed is Dictionary, "profile_unreadable", "%s 不是合法 JSON" % path):
		return
	var on_disk := str((parsed as Dictionary).get("player_id", ""))
	_h.expect(on_disk == str(profile.get("player_id")),
		"disk_id_mismatch", "磁盘上的 player_id 与内存不一致：盘 %s / 内存 %s" % [
			on_disk, str(profile.get("player_id"))])
	_h.expect(int((parsed as Dictionary).get("version", 0)) == SaveSchema.PROFILE_VERSION,
		"disk_version_stale", "落盘的 profile 版本应为 %d，实得 %d" % [
			SaveSchema.PROFILE_VERSION, int((parsed as Dictionary).get("version", 0))])


# reissue_player_id() 是**唯一**允许改变已有 id 的入口，只在服务器回 409 时调用。
# 它与本文件其余部分守的不变量方向相反，所以单独验：调了就必须真的换一个、
# 而且必须落盘 —— 换了不落盘，下次启动又变回旧的，等于没换。
#
# 这个用例会动真实档案，所以结束前把原来的 id 还原回去（内存与磁盘一起），
# 否则跑一次检查就把开发者的账号身份换掉了。
func _case_reissue_is_explicit_and_persists() -> void:
	var profile := get_node_or_null("/root/PlayerProfile")
	if profile == null:
		return  # 前面的用例已经记过失败
	if not _h.expect(profile.has_method("reissue_player_id"),
		"reissue_missing", "PlayerProfile 缺少 reissue_player_id()"):
		return

	var path := str(profile.get_script().get_script_constant_map().get("PROFILE_PATH", ""))
	var original := str(profile.get("player_id"))

	profile.call("reissue_player_id")
	var reissued := str(profile.get("player_id"))
	_h.expect(reissued != original, "reissue_did_nothing", "重新签发后 id 必须变化")
	_h.expect(SaveSchema.is_valid_player_id(reissued),
		"reissue_invalid", "重新签发出来的必须是合法 UUID：%s" % reissued)

	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if _h.expect(parsed is Dictionary, "reissue_disk_unreadable", "重签后档案读不出来"):
		_h.expect(str((parsed as Dictionary).get("player_id", "")) == reissued,
			"reissue_not_persisted",
			"重签后必须落盘 —— 没落盘的话下次启动又变回旧 id，等于没换")

	# 还原：内存与磁盘一起改回去。
	profile.set("player_id", original)
	profile.call("save_profile")
	var restored: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	_h.expect(restored is Dictionary and str((restored as Dictionary).get("player_id", "")) == original,
		"restore_failed", "用例结束后必须把原来的 player_id 还原回去")
