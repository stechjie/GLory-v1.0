class_name SaveSchema
extends RefCounted

# 局内存档（run save）的版本。下面那串 history 讲的是 profile，不是它 ——
# 两者各有各的版本号，别混。
const VERSION := 2

# Account-level profile (user://profile.json) is versioned separately from the run
# save: it survives across runs and is the only place collection progress lives.
#
# Profile version history:
#   1 - account profile had no version field at all
#   2 - profile gains codex_seen; pet_duck renamed to pet_rabbit
#   3 - profile gains the persistent BoardReadabilityLayer visibility setting
#   4 - profile gains persisted locale and an explicit onboarding lifecycle
#   5 - profile gains player_id（账号系统第 0 步，见 docs/账号系统RFC.md）
#   6 - 宠物归属上云：owned_pets / active_pet / needs_starter_pick 从本机**删除**
#       （docs/商城系统设计.md 第八节）。归属的唯一真相在服务端 player_entitlements，
#       本机留着只会变成「改一行文件就白嫖」的入口，也会变成下一个人误以为还在用的地雷。
#   7 - 出战种族上云：selected_races 从本机**删除**（docs/商城系统设计.md 第五节）。
#       对局用的是账号服务器签的出战名片，本机那份只会和它对不上。
#
# ⚠️ **4 曾经被两条分支各发过一次，内容不同。** 账号线当时也把版本号写成 4
# （装的是 player_id），onboarding 线写的 4 装的是 locale/onboarding。合并时把
# 账号那份让到 5，并把下面 onboarding 的迁移条件从 `from < 4` 放宽到 `from < 5`
# —— 否则"版本写着 4、但只有 player_id 没有 locale"的档案会整块被跳过。
# 那个块里每个字段都有 has() 守卫，放宽只补齐、不覆盖。
#
# 注：3 之后加的六个演出开关（screen_shake / flash_effects / hit_stop /
# reduced_motion / ui_sound / haptics）没有升版本号，因为它们每一个都有安全默认值，
# 读侧 `data.get(key, default)` 就够了。player_id 不是这种字段 —— 见下。
const PROFILE_VERSION := 7

# 玩家的永久身份。RFC 4122 版本 4 的 UUID，小写带连字符。
#
# 这个 id 在设备上**第一次**读档时签发，之后永不改变。它不是 Supabase / Google /
# Steam 的账号 id，也不是 SessionContext.session_token（那是一局一换的重连凭证）。
# 接账号时，各家 Auth 的 id 只是映射到它的一行 player_identities：
#
#   player_id      provider   provider_user_id
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
			if not out.has("codex_seen"):
				out["codex_seen"] = []
		# v6：宠物归属上云，本机这三个键作废。
		#
		# **主动 erase 并回写，不是读的时候忽略。** 留着就是地雷：下一个人
		# （或下一个 AI）grep 到 owned_pets 还在存档里，完全可能当成还在用的东西继续改。
		#
		# 不做「把本机的宠物同步给服务器」：拍板是**不认本机**（存档是文本文件，
		# 改一行就白嫖），所有人重走一次三选一。
		for dead_key in ["owned_pets", "active_pet", "needs_starter_pick"]:
			out.erase(dead_key)
		# v7：出战种族上云，同样 erase。也不把本机那份传上去：今天只有四族、
		# 必须选四个，唯一合法的选法就是默认那份 —— 删了什么都没丢。
		out.erase("selected_races")
		if from < 3 and not out.has("board_readability_enabled"):
			out["board_readability_enabled"] = true
		# 条件是 `< 5` 而不是 `< 4`：见顶部关于"两个版本 4"的说明。
		if from < 5:
			# Never guess that an old account completed onboarding from gold, pets or run
			# state. Those are not proof. Legacy accounts keep the old behaviour (show
			# language, then resume/start tutorial) once, and become explicit thereafter.
			if not out.has("locale"):
				out["locale"] = "zh"
			if not out.has("language_selected"):
				out["language_selected"] = false
			if not out.has("onboarding_version"):
				out["onboarding_version"] = 1
			if not out.has("onboarding_status"):
				out["onboarding_status"] = "legacy_unknown"

	# player_id 故意**不**放进上面的版本分支。它是不变量，不是一次性的迁移步骤：
	# 版本号已经是最新、但档案里缺 id 或 id 被写坏，同样必须补发。放进版本分支
	# 就会漏掉这种档案，而漏掉的后果是每次冷启动重签一个新 id ——
	# 接账号之后那等于玩家每次开游戏都丢失全部进度，且不报错、不崩溃。
	#
	# 这次合并顺带印证了这个设计：两条分支各自改了版本号的含义，而这一行
	# 因为不依赖版本号，完全不受影响。
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


