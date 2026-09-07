class_name SaveSchema
extends RefCounted

# 局内存档（run save）的版本。下面那串 history 讲的是 profile，不是它 —— 两者
# 各有各的版本号，别混。
const VERSION := 2

# Account-level profile (user://profile.json) is versioned separately from the run
# save: it survives across runs and is the only place collection progress lives.
#
# Profile version history:
#   1 - account profile had no version field at all
#   2 - profile gains codex_seen; pet_duck renamed to pet_rabbit
#   3 - profile gains the persistent BoardReadabilityLayer visibility setting
#   4 - profile gains player_id（账号系统第 0 步，见 docs/账号系统RFC.md）
#
# 注：3 之后加的六个演出开关（screen_shake / flash_effects / hit_stop /
# reduced_motion / ui_sound / haptics）没有升版本号，因为它们每一个都有安全默认值，
# 读侧 `data.get(key, default)` 就够了。player_id 不是这种字段 —— 见下。
const PROFILE_VERSION := 4

# Pets renamed after the art came in. Old profiles still hold the old id, so it is
# rewritten on load rather than orphaning a pet the player already owns.
const PET_ID_RENAMES := {
	"pet_duck": "pet_rabbit",
}

# 玩家的永久身份。RFC 4122 版本 4 的 UUID，小写带连字符。
#
# 这个 id 在设备上**第一次**读档时签发，之后永不改变。它不是 Supabase / Google /
# Steam 的账号 id，也不是 SessionContext.session_token（那是一局一换的重连凭证）。
# 将来接账号时，各家 Auth 的 id 只是映射到它的一行 player_identities：
#
#   player_id      provider   provider_user_id
#   52c7027a-...   local      ← 这里签发的这个
#   52c7027a-...   supabase   a91d3f...
#
# 游戏侧（金币 / 单位 / 宝物 / Rank / 战绩）永远只认 player_id，所以换登录方式、
# 甚至换掉整个后端，都不需要给任何一张表重新 key。见 docs/账号系统RFC.md。
const PLAYER_ID_PATTERN := "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"

static var _player_id_re: RegEx = null

# Applies every migration needed to bring a profile payload up to PROFILE_VERSION.
# Safe to call on an already-current payload.
static func migrate_profile(payload: Dictionary) -> Dictionary:
	var out := payload.duplicate(true)
	var from := int(out.get("version", 1))
	if from < PROFILE_VERSION:
		if from < 2:
			out["owned_pets"] = _rename_ids(out.get("owned_pets", []))
			out["active_pet"] = _rename_id(str(out.get("active_pet", "")))
			if not out.has("codex_seen"):
				out["codex_seen"] = []
		if from < 3 and not out.has("board_readability_enabled"):
			out["board_readability_enabled"] = true

	# player_id 故意**不**放进上面的版本分支。它是不变量，不是一次性的迁移步骤：
	# 版本号已经是最新、但档案里缺 id 或 id 被写坏，同样必须补发。放进 `from < 4`
	# 里就会漏掉这种档案，而漏掉的后果是每次冷启动重签一个新 id ——
	# 接账号之后那等于玩家每次开游戏都丢失全部进度，且不报错、不崩溃。
	_ensure_player_id(out)
	out["version"] = PROFILE_VERSION
	return out

# 签发一个新的 player_id。**只在没有合法 id 时调用。**
#
# 随机源必须是 Crypto，不能用 randi() 或 RngService —— RngService 是给回放确定性
# 用的，同一个种子在两台设备上会产生同一串数，拿它签 id 会直接撞号。
static func new_player_id() -> String:
	var bytes := Crypto.new().generate_random_bytes(16)
	# RFC 4122 §4.4：第 7 字节高四位固定为版本 4，第 9 字节高两位固定为变体 10。
	bytes[6] = (bytes[6] & 0x0f) | 0x40
	bytes[8] = (bytes[8] & 0x3f) | 0x80
	var hex := bytes.hex_encode()
	return "%s-%s-%s-%s-%s" % [
		hex.substr(0, 8), hex.substr(8, 4), hex.substr(12, 4), hex.substr(16, 4), hex.substr(20, 12),
	]

static func is_valid_player_id(id: String) -> bool:
	if _player_id_re == null:
		_player_id_re = RegEx.new()
		_player_id_re.compile(PLAYER_ID_PATTERN)
	return _player_id_re.search(id) != null

# 有合法 id 就原样留着 —— 这是本文件最重要的一条，改坏了玩家资料就没了。
static func _ensure_player_id(out: Dictionary) -> void:
	var existing := str(out.get("player_id", ""))
	if is_valid_player_id(existing):
		return
	if not existing.is_empty():
		# 不静默吞掉：id 存在但格式不对，说明档案被改过或写坏过，值得留痕。
		push_warning("[SAVE] profile.player_id 格式非法，已重新签发（原值：%s）" % existing)
	out["player_id"] = new_player_id()

static func _rename_id(id: String) -> String:
	return str(PET_ID_RENAMES.get(id, id))

static func _rename_ids(ids: Array) -> Array:
	var out: Array = []
	for raw in ids:
		var id := _rename_id(str(raw))
		if not id.is_empty() and not out.has(id):
			out.append(id)
	return out
