extends RefCounted

# 出战名片 —— 战斗服务器一侧：验章、清洗。
#
# 签发在账号服务器（backend/app/loadout.py），设计见 docs/商城系统设计.md 第五节。
#
# ## 为什么需要它
#
# 战斗服务器不认识玩家，以前只能信手机报上来的：宠物跟着棋盘每回合报一次、
# 种族准备时报一次、名字头像则是把**登录令牌**交过来让这边回头去问账号服务器。
# 三样东西三种做法 —— 手机改了能用没买的，手机重开忘了就用不上买了的。
#
# 现在一条规则：**对局里用到的账号级东西，一律以账号服务器盖过章的名片为准。**
#
#   1. 玩家要**入座**（建房 / 加入房间）时，先向账号服务器领一张名片，
#      随请求一起交上来（不走握手包 —— 名片 700～1700 字节，握手包只有 512）
#   2. 这里用公钥验章，通过了整张记在**座位**上（NetworkService._room_seat_card）
#   3. 之后宠物、种族、名字头像一律从座位上的名片取，**手机再报什么都不当真**
#   4. 断线重连回到同一个座位，名片还在 —— 宠物、种族、头像都一样，效果都在。
#      所以重连**不需要**新名片，账号服务器一时连不上也照样能回来
#
# 以后加皮肤、加要解锁的种族：往名片里加一个字段，不再发明新做法。
#
# ## 分工
#
# 账号服务器管「你有没有资格用」—— 没资格的根本不会写进名片。
# 这里管「这个组合合不合规则」—— 例如种族必须正好 4 个（RacePick.sanitize），
# 以及名片本身合不合法（签名、过期、格式）。
#
# ## 线格式
#
#     <base64(名片 JSON 的原始字节)>.<base64(RSA 签名)>
#
# **先验签、再解析，绝不重新序列化** —— 签的是那串字节，验的也是那串字节。
# 签名是 RSA-2048 / PKCS#1 v1.5 / SHA-256。
# ⚠️ Crypto.verify() 收的是**摘要**，不是原文：传原文进去会一直返回 false 且不报错
# （2026-09-16 实测踩过，见设计文档第五节）。
#
# 全静态、不持状态。「这张名片用过没有」是有状态的，在 NetworkService 里。

# RacePick 没有全局类名，照 NetworkService 的写法 preload。
const RacePick := preload("res://scripts/units/RacePick.gd")

# --- 公钥放在哪 ---------------------------------------------------------------
#
# **公钥是战斗服务器上的一个文件，不打进包里。** 手机从不验章（只是把名片原样递过来），
# 所以 APK 里根本不需要它；放文件的好处是换钥匙**不用重发 APK**：
# 账号服务器换私钥 → 把新公钥放到这里 → 重启战斗服务器。
#
# 拿不到公钥 = 专服**拒绝启动**（NetworkService.team_host），和 DTLS 私钥一个脾气：
# 起来了但谁都入不了座，比起不来难查得多。
#
# 生成工具在账号服务器那边：deploy/make_battle_card_key.py，它会把公钥打印出来。
# 部署步骤见 deploy/BATTLE_SERVER_KEY.md 的「出战名片公钥」一节。
#
# ⚠️ 不要把任何名片私钥放进 tools/ —— make_server_zip.ps1 会把整个 tools/
# 打进战斗服务器包。测试用的钥匙一律在测试运行时现场生成。
const DEFAULT_KEY_PATH := "user://battle_card_public.pem"
const KEY_ARG := "--battle-card-key="

# 名片格式版本，与 backend/app/loadout.py 的 CARD_VERSION 一致。
const VERSION := 1

# 允许两台机器的钟差这么多。两边都走 NTP，正常差不到一秒；
# 留 30 秒是为了一台机器 NTP 短暂失灵时不至于所有名片都过期。
const CLOCK_LEEWAY_SEC := 30

# 名片字符串本身的上限，**在解码之前**就挡。这是不可信输入，不设限等于让对方决定
# 这边要为一次 base64 解码 + RSA 验签花多少内存和 CPU。
# 实测普通名片 705 字节，按数据库允许的上限造的最大名片 1673 字节
# （backend/tests/test_loadout.py 每次都量一遍，超过这个数会红）。
const MAX_CARD_CHARS := 2048

# RSA-2048 的签名固定 256 字节。
const SIGNATURE_BYTES := 256

# 各字段清洗后的长度上限。与账号服务器那边的数据库约束对齐或更宽 ——
# 这里是防御性截断，不是业务校验（业务校验在签发时已经做过）。
const MAX_TEXT := {
	"pid": 64, "code": 16, "name": 64, "avatar": 128, "frame": 128, "pet": 64, "jti": 64,
}
const MAX_RACES := 16
const MAX_RACE_ID := 32

static var _key_pem_cache := ""
static var _key_cache: CryptoKey = null


static func server_key_path() -> String:
	# **两个来源都要查。** `--` 之后的参数只出现在 get_cmdline_user_args()，
	# 不在 get_cmdline_args() 里 —— NetTLS.server_key_path 踩过同一个坑。
	for source in [OS.get_cmdline_args(), OS.get_cmdline_user_args()]:
		for arg in source:
			if str(arg).begins_with(KEY_ARG):
				var v := str(arg).substr(KEY_ARG.length()).strip_edges()
				if not v.is_empty():
					return v
	return DEFAULT_KEY_PATH


# 读公钥。返回 {"pem": String, "error": String}；读不到或不是合法公钥时 pem 为空。
# path 为空 = 按命令行 / 默认路径（专服就是这么调的）；门禁传自己的测试文件。
#
# 放进来的是**私钥**也算不合法：战斗服务器只该持有公钥，私钥在这台机器上
# 等于谁拿到这台机器谁就能给自己签名片。
static func load_server_key(path: String = "") -> Dictionary:
	if path.is_empty():
		path = server_key_path()
	if not FileAccess.file_exists(path):
		return {"pem": "", "error": "缺出战名片公钥 %s —— 见 deploy/BATTLE_SERVER_KEY.md「出战名片公钥」，或用 %s 指定" % [path, KEY_ARG]}
	var pem := FileAccess.get_file_as_string(path)
	if _load_key(pem) == null:
		return {"pem": "", "error": "%s 不是合法的公钥 PEM" % path}
	return {"pem": pem, "error": ""}


# 验一张名片。返回 {"ok": bool, "code": String, "card": Dictionary}。
#
# code 会原样回给客户端（建房 / 加入失败的原因），所以不许带任何内部细节。
# now 由调用方传（Time.get_unix_time_from_system()）—— 门禁要能造「过期」的场景。
# public_pem 由调用方传：专服传启动时读到的那把，门禁传自己现场生成的。
static func verify(card_text: String, now: int, public_pem: String) -> Dictionary:
	var key := _load_key(public_pem)
	if key == null:
		return _fail("card_key_missing")
	if card_text.is_empty():
		return _fail("card_required")
	if card_text.length() > MAX_CARD_CHARS:
		return _fail("card_malformed")
	var parts := card_text.split(".")
	if parts.size() != 2 or parts[0].is_empty() or parts[1].is_empty():
		return _fail("card_malformed")
	var body := Marshalls.base64_to_raw(parts[0])
	var signature := Marshalls.base64_to_raw(parts[1])
	if body.is_empty() or signature.size() != SIGNATURE_BYTES:
		return _fail("card_malformed")

	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(body)
	if not Crypto.new().verify(HashingContext.HASH_SHA256, ctx.finish(), signature, key):
		return _fail("card_bad_signature")

	# 签名对了才解析。顺序反过来等于让没签过名的数据先进 JSON 解析器。
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return _fail("card_malformed")
	var raw: Dictionary = parsed
	if int(raw.get("v", 0)) != VERSION:
		return _fail("card_version")
	var issued := int(raw.get("iat", 0))
	var expires := int(raw.get("exp", 0))
	if expires <= 0 or now > expires + CLOCK_LEEWAY_SEC:
		return _fail("card_expired")
	# 签发时间在很远的将来 = 两台机器的钟严重不齐。收下它的话，
	# 这张名片的实际有效期会比 60 秒长得多。
	if issued > now + CLOCK_LEEWAY_SEC:
		return _fail("card_expired")

	var card := _clean(raw)
	if str(card.get("pid", "")).is_empty() or str(card.get("jti", "")).is_empty():
		return _fail("card_malformed")
	return {"ok": true, "code": "", "card": card}


# 名片上的出战种族，按战斗服务器的规则清洗。不合规则（例如不是正好 4 个、
# 有这边不认识的族）就整份换成默认 —— 与 RacePick.resolve 的口径一致。
static func races_of(card: Dictionary) -> Array[String]:
	return RacePick.resolve(card.get("races", []))


# 名片上的出战宠物。宠物表里没有的（版本不一致）当作没带。
static func pet_of(card: Dictionary) -> String:
	var pet := str(card.get("pet", ""))
	if pet.is_empty() or PetService.model_path(pet).is_empty():
		return ""
	return pet


# 房间里给别人看的名片（名字、好友码、头像）。形状与原来 _rpc_lobby_identity
# 写进 seat_profiles 的一致，客户端不用改。
static func profile_of(card: Dictionary) -> Dictionary:
	return {
		"friend_code": str(card.get("code", "")),
		"player_name": str(card.get("name", "")),
		"avatar": str(card.get("avatar", "")),
	}


static func _clean(raw: Dictionary) -> Dictionary:
	var out := {}
	for field in MAX_TEXT:
		var value: Variant = raw.get(field, "")
		out[field] = (str(value) if typeof(value) == TYPE_STRING else "").left(int(MAX_TEXT[field]))
	var races: Array[String] = []
	var raw_races: Variant = raw.get("races", [])
	if typeof(raw_races) == TYPE_ARRAY:
		for value in raw_races:
			if typeof(value) != TYPE_STRING or races.size() >= MAX_RACES:
				continue
			races.append(str(value).left(MAX_RACE_ID))
	out["races"] = races
	out["exp"] = int(raw.get("exp", 0))
	return out


# 公钥解析一次就缓存。每个入座请求都要验，没必要每次都解析 PEM。
static func _load_key(public_pem: String) -> CryptoKey:
	var pem := public_pem.strip_edges()
	if pem.is_empty():
		return null
	if _key_cache != null and _key_pem_cache == pem:
		return _key_cache
	var key := CryptoKey.new()
	# 第二个参数 public_only = true：这边永远只该持有公钥。
	if key.load_from_string(pem, true) != OK:
		return null
	_key_cache = key
	_key_pem_cache = pem
	return key


static func _fail(code: String) -> Dictionary:
	return {"ok": false, "code": code, "card": {}}
