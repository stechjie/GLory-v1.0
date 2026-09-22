extends RefCounted

# 战报 —— 战斗服务器一侧：组装、签章。
#
# 验章在账号服务器（backend/app/battle_report.py），设计见 docs/排位系统设计.md 第七节。
#
# ## 它是出战名片反过来那一半
#
# 名片：账号服务器签 → 客户端原样转交 → 战斗服务器验（BattleCard.gd）
# 战报：**战斗服务器签 → 客户端原样转交 → 账号服务器验**
#
# 两边都是「签名 + 客户端转交」，所以两台服务器之间**一条网络通道都不用开** ——
# docs/账号系统RFC.md 第九节那个 9.2（③ → ② 用什么服务端凭证）可以继续不回答。
#
# ## 一份战报结算全场六个座位
#
# 战报里有全场六个人的结果，所以**六个人里只要有一个交上来就够**。
# 账号服务器按 match_uid 去重（database/013_match_history.sql 的主键）。
#
# 赢的那三个有动力交；输的不交也没用 —— 别人交的那一份里同样有他。
# 「输了就不交」这条路本来就不通，不需要额外防。
#
# ## 线格式（与名片同款）
#
#     <base64(战报 JSON 的原始字节)>.<base64(RSA 签名)>
#
# 签名是 RSA-2048 / PKCS#1 v1.5 / SHA-256。账号服务器**先验签、再解析，绝不重新序列化**
# —— 签的是那串字节，验的也是那串字节。
#
# ⚠️ Crypto.sign() 收的是**摘要**，不是原文（和 Crypto.verify() 同一个脾气，
# 名片那边 2026-09-16 踩过）。2026-09-22 已用一次性探针实测过这条链路：
# Godot 签出 256 字节，Python cryptography 用 PKCS1v15 + SHA256 验过，改一个字节正确拒绝。
#
# ## 钥匙放哪：和名片正好相反
#
# **私钥在战斗服务器上，公钥在账号服务器上。** 手机两边都不碰（它只转交）。
# 生成工具 deploy/make_battle_report_key.py 在**战斗服务器**那台跑，把公钥送去账号服务器。
#
# ⚠️ 不要把私钥放进 tools/ —— make_server_zip.ps1 会把整个 tools/ 打进战斗服务器包。
# 测试用的钥匙一律在测试运行时现场生成（tools/battle_report_check.gd 就是这么做的）。
#
# ## 🔴 没有钥匙不拒绝启动 —— 这一条和名片刻意不一样
#
# 名片公钥缺失 = 专服拒绝启动，因为那时候**谁都入不了座**，起来了比起不来更难查。
#
# 战报私钥缺失只意味着**历史记不下来**，对局本身照常打完。为一个记账功能让整台
# 战斗服务器起不来，是把故障面放大。而且上线顺序上它也说不通：
# 战斗服务器得先更新、再放钥匙，中间那段必然是「新代码 + 没钥匙」。
#
# 代价是它会**静默少记**，所以启动时打一条醒目的警告、每局结束再打一条 ——
# 不让它变成没人发现的沉默。
#
# 全静态、不持状态。

const GameConstantsRef := preload("res://scripts/core/GameConstants.gd")

# 战报格式版本，与 backend/app/battle_report.py 的 REPORT_VERSION 一致。
const VERSION := 1

const DEFAULT_KEY_PATH := "user://battle_report_key.pem"
const KEY_ARG := "--battle-report-key="

# 每个座位写进战报的条目上限。**故意按棋盘的真实尺寸封顶**，不按 NetProtocol
# 那个防御用的 MAX_SLOT_ENTRIES(64) —— 战报的大小要是可预测的：
# 6 座位 × (16 + 8 + 8) 条，实测量级见 tools/battle_report_check.gd。
const MAX_BOARD_ENTRIES := GameConstantsRef.CELL_COUNT   # 4×4 = 16
const MAX_MERC_ENTRIES := 8                              # GameState.MERCENARY_SLOTS
const MAX_TREASURE_ENTRIES := 8                          # TreasureService.MAX_OWNED 是 5，留余量
const MAX_ID_LEN := 64                                   # 同 NetProtocol.MAX_ID_LENGTH
const SEAT_COUNT := 6

# 合法的对局模式。第 1 步只有 custom；casual / ranked 是给后面几步留的。
# 与 database/013_match_history.sql 的 match_mode_known 约束一致。
const MODES := ["custom", "casual", "ranked"]

# 按 (路径, 修改时间) 缓存，照 backend/app/loadout.py 的 _private_key() 那条。
# **只按路径缓存是错的**：原地轮换密钥（同一个路径换内容）会一直拿到旧的那把，
# 而且要等下次重启才好 —— 签出来的战报全部验不过，且没有任何报错。
static var _key_cache: CryptoKey = null
static var _key_path_cache := ""
static var _key_mtime_cache := 0


# --- 钥匙 ---------------------------------------------------------------------

static func key_path() -> String:
	# **两个来源都要查。** `--` 之后的参数只出现在 get_cmdline_user_args()，
	# 不在 get_cmdline_args() 里 —— BattleCard.server_key_path 和 NetTLS 都踩过同一个坑。
	for source in [OS.get_cmdline_args(), OS.get_cmdline_user_args()]:
		for arg in source:
			if str(arg).begins_with(KEY_ARG):
				var v := str(arg).substr(KEY_ARG.length()).strip_edges()
				if not v.is_empty():
					return v
	return DEFAULT_KEY_PATH


# 读私钥。返回 {"key": CryptoKey, "error": String}；读不到时 key 为 null。
#
# path 为空 = 按命令行 / 默认路径（专服就是这么调的）；门禁传自己现场生成的文件。
static func load_signing_key(path: String = "") -> Dictionary:
	if path.is_empty():
		path = key_path()
	if not FileAccess.file_exists(path):
		return {"key": null, "error": "缺战报私钥 %s —— 见 deploy/BATTLE_SERVER_KEY.md「战报私钥」，或用 %s 指定（对局照常，只是不记历史）" % [path, KEY_ARG]}
	var mtime := int(FileAccess.get_modified_time(path))
	if _key_cache != null and _key_path_cache == path and _key_mtime_cache == mtime:
		return {"key": _key_cache, "error": ""}
	var pem := FileAccess.get_file_as_string(path)
	var key := CryptoKey.new()
	# public_only = false：这边要的是**私钥**。只放了公钥进来会在这一步失败，
	# 那正是想要的 —— 拿公钥签不出任何东西，早失败好过签出一堆验不过的战报。
	if key.load_from_string(pem, false) != OK:
		return {"key": null, "error": "%s 不是合法的私钥 PEM" % path}
	_key_cache = key
	_key_path_cache = path
	_key_mtime_cache = mtime
	return {"key": key, "error": ""}


# 本局的唯一标识。32 位十六进制，与 013 迁移的 match_uid_format 约束一致。
#
# **不能用房间号**：房间号是六位随机数、关房后会被回收重用
# （RoomService.new_room），拿它当历史主键早晚撞上，而且撞了是静默覆盖。
static func new_match_uid() -> String:
	return Crypto.new().generate_random_bytes(16).hex_encode()


# --- 组装 ---------------------------------------------------------------------

# ctx 由 NetworkService 在对局结束时填好。形状：
#
#   match_uid   String   本局唯一标识（room.match_uid）
#   mode        String   "custom" / "casual" / "ranked"
#   protocol    int      NetworkConfig.NETWORK_PROTOCOL_VERSION
#   server_epoch int
#   room_id     int
#   started_at  int      unix 秒（墙钟）
#   ended_at    int      unix 秒（墙钟）
#   rounds      int      打完到第几回合
#   outcome     String   "team_a" / "team_b" / "draw"
#   team_hp     Array    [hp_a, hp_b]
#   gold_authoritative   bool
#   carrot_authoritative bool
#   seats       Array    六个座位，每个 {pid, was_ai, online_at_end, ai_rounds,
#                                       gold, carrots, carrots_spent, board, mercenaries, treasures}
#
# 返回的字典就是要被签的那一份。**这里只做清洗与封顶，不做任何业务判断** ——
# 谁赢谁输是 TeamOutcome 算的，这里照抄。
static func build(ctx: Dictionary) -> Dictionary:
	var mode := str(ctx.get("mode", "custom"))
	if not MODES.has(mode):
		mode = "custom"
	var team_hp: Array = ctx.get("team_hp", [0, 0])
	var seats := []
	var raw_seats: Array = ctx.get("seats", [])
	for slot in SEAT_COUNT:
		var raw: Dictionary = raw_seats[slot] if slot < raw_seats.size() and typeof(raw_seats[slot]) == TYPE_DICTIONARY else {}
		seats.append({
			"slot": slot,
			"team": GameConstantsRef.team_of_slot(slot),
			# 空字符串 = 这个座位不是真人（房主加的 AI），或者入座时没带名片
			# （进程内门禁走的那条路）。账号服务器据此写 null。
			"pid": str(raw.get("pid", "")).left(MAX_ID_LEN),
			"ai": bool(raw.get("was_ai", false)),
			"online": bool(raw.get("online_at_end", false)),
			"ai_rounds": maxi(0, int(raw.get("ai_rounds", 0))),
			"gold": maxi(0, int(raw.get("gold", 0))),
			"carrots": maxi(0, int(raw.get("carrots", 0))),
			"spent": maxi(0, int(raw.get("carrots_spent", 0))),
			"board": _clean_units(raw.get("board", []), MAX_BOARD_ENTRIES, false)
					+ _clean_units(raw.get("mercenaries", []), MAX_MERC_ENTRIES, true),
			"treasures": _clean_ids(raw.get("treasures", []), MAX_TREASURE_ENTRIES),
		})
	return {
		"v": VERSION,
		"mid": str(ctx.get("match_uid", "")),
		"mode": mode,
		"proto": int(ctx.get("protocol", 0)),
		"epoch": int(ctx.get("server_epoch", 0)),
		"room": int(ctx.get("room_id", 0)),
		"start": int(ctx.get("started_at", 0)),
		"end": int(ctx.get("ended_at", 0)),
		"rounds": int(ctx.get("rounds", 0)),
		"out": str(ctx.get("outcome", "draw")),
		"hp": [int(team_hp[0]) if team_hp.size() > 0 else 0, int(team_hp[1]) if team_hp.size() > 1 else 0],
		"gold_auth": bool(ctx.get("gold_authoritative", false)),
		"carrot_auth": bool(ctx.get("carrot_authoritative", false)),
		"seats": seats,
	}


# 棋盘 / 佣兵位清洗成历史要的最小形状。
#
# **刻意丢掉 uid 和 race_relations**：uid 是一局之内的运行时编号，出了这一局没有意义；
# race_relations 从单位 id 就查得回来。两个都留会让战报大一倍以上，
# 而历史界面一个都用不上。
static func _clean_units(raw: Variant, limit: int, mercenary: bool) -> Array:
	var out := []
	if typeof(raw) != TYPE_ARRAY:
		return out
	for cell in (raw as Array):
		if out.size() >= limit:
			break
		if cell == null or typeof(cell) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = cell
		var id := str(d.get("id", "")).left(MAX_ID_LEN)
		if id.is_empty():
			continue
		out.append({
			"slot": maxi(0, int(d.get("slot", 0))),
			"id": id,
			"star": clampi(int(d.get("star", 1)), 1, GameConstantsRef.MAX_STAR),
			"merc": mercenary or bool(d.get("is_mercenary", false)),
		})
	return out


static func _clean_ids(raw: Variant, limit: int) -> Array:
	var out := []
	if typeof(raw) != TYPE_ARRAY:
		return out
	for value in (raw as Array):
		if out.size() >= limit:
			break
		if typeof(value) != TYPE_STRING:
			continue
		var id := str(value).left(MAX_ID_LEN)
		if not id.is_empty():
			out.append(id)
	return out


# --- 签章 ---------------------------------------------------------------------

# 返回线格式；key 为 null 或签失败时返回空串（调用方据此记日志并跳过）。
static func sign(payload: Dictionary, key: CryptoKey) -> String:
	if key == null:
		return ""
	# sort_keys 显式写死：默认值以后变了的话，签出来的字节会跟着变。
	# 账号服务器不重新序列化，所以这不影响验签，但会让日志里的战报对不上号。
	var body := JSON.stringify(payload, "", true, false).to_utf8_buffer()
	if body.is_empty():
		return ""
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(body)
	var signature := Crypto.new().sign(HashingContext.HASH_SHA256, ctx.finish(), key)
	if signature.is_empty():
		return ""
	return "%s.%s" % [Marshalls.raw_to_base64(body), Marshalls.raw_to_base64(signature)]
