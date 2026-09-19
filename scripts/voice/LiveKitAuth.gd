extends RefCounted

# LiveKit 钥匙（JWT）与战斗服务器上的语音配置（docs/语音LiveKit方案.md 3.2 / 3.3）。
#
# 🔴 只在战斗服务器上用：API secret 能给任何房间签钥匙，绝不能进客户端。
#    客户端只拿战斗服务器签好的那一张（只能进本队的语音房间）。
#
# 不用 class_name：make_server_zip.ps1 会把全局类缓存一起打包，新增的全局类没先重建缓存就打包，
# 服务器会在解析阶段挂住（同 RateLimitService 的说明）。一律 preload。

# 配置文件放在战斗服务器用户的 Godot 目录里（同出战名片公钥），由 deploy/livekit/install_livekit.sh 写：
#   {"client_url": "wss://语音域名", "admin_url": "http://127.0.0.1:7880", "api_key": "…", "api_secret": "…"}
const DEFAULT_CONFIG_PATH := "user://livekit_voice.json"
const CONFIG_ARG := "--voice-key="

# 进房钥匙的有效期。LiveKit 只在**首次进房**时看过期，进去以后服务器会自动给在线的人续
# （官方文档「Access tokens & grants」）—— 所以这个值只管「拿到钥匙多久内要连上」。
const JOIN_TTL_SEC := 600
# 战斗服务器调管理接口（踢人、删房间）用的钥匙，一次一签。
const ADMIN_TTL_SEC := 60
# secret 太短等于没有；短了宁可不开语音。安装脚本生成的是 48 个字符。
const MIN_SECRET_CHARS := 32


static func config_path() -> String:
	# 两个来源都要查：`--` 之后的参数只出现在 get_cmdline_user_args()（同 BattleCard.server_key_path）。
	for source in [OS.get_cmdline_args(), OS.get_cmdline_user_args()]:
		for arg in source:
			if str(arg).begins_with(CONFIG_ARG):
				var v := str(arg).substr(CONFIG_ARG.length()).strip_edges()
				if not v.is_empty():
					return v
	return DEFAULT_CONFIG_PATH


# 读配置。返回 {"ok": bool, "error": String} 加四个字段。
# 读不到不是故障：语音不是必需的，战斗服务器照常开，钥匙请求回 voice_not_configured。
# path 为空 = 按命令行 / 默认路径（专服就是这么调的）；门禁传自己的测试文件。
static func load_config(path: String = "") -> Dictionary:
	if path.is_empty():
		path = config_path()
	if not FileAccess.file_exists(path):
		return {"ok": false, "error": "没有语音配置 %s（见 deploy/livekit/README.md），或用 %s 指定" % [path, CONFIG_ARG]}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		return {"ok": false, "error": "%s 不是合法的 JSON" % path}
	var cfg: Dictionary = parsed
	var client_url := str(cfg.get("client_url", "")).strip_edges()
	var admin_url := str(cfg.get("admin_url", "")).strip_edges().trim_suffix("/")
	var api_key := str(cfg.get("api_key", "")).strip_edges()
	var api_secret := str(cfg.get("api_secret", "")).strip_edges()
	# ws:// 只给本机测试用；线上手机和苹果都不许明文连接。
	if not (client_url.begins_with("wss://") or client_url.begins_with("ws://")):
		return {"ok": false, "error": "%s 的 client_url 必须是 wss://（本机测试可以 ws://）" % path}
	if not (admin_url.begins_with("http://") or admin_url.begins_with("https://")):
		return {"ok": false, "error": "%s 的 admin_url 必须是 http(s)://" % path}
	if api_key.is_empty() or api_secret.length() < MIN_SECRET_CHARS:
		return {"ok": false, "error": "%s 的 api_key 为空，或 api_secret 短于 %d 个字符" % [path, MIN_SECRET_CHARS]}
	return {"ok": true, "error": "", "client_url": client_url, "admin_url": admin_url,
		"api_key": api_key, "api_secret": api_secret}


# 语音房间名：一个对局房间、一个队伍一个。salt 在建房时生成并随房间存盘（RoomService.new_room），
# 房间号会被重用，有了它上一局的旧钥匙就进不了这一局。
static func room_name(room_id: int, salt: String, team: int) -> String:
	return "g%d-%s-t%d" % [room_id, salt, team]


# 进房钥匙。identity = 座位名片里的好友码（没有名片的测试座位用 seat<N>），客户端用它把声音对回座位。
static func join_token(cfg: Dictionary, identity: String, display_name: String, room: String, now: int) -> String:
	var payload := {
		"iss": str(cfg.get("api_key", "")),
		"sub": identity,
		"nbf": now,
		"exp": now + JOIN_TTL_SEC,
		"name": display_name,
		"video": {
			"roomJoin": true,
			"room": room,
			"canSubscribe": true,
			"canPublish": true,
			# 只准发麦克风：不准发摄像头、屏幕，也不准发数据消息。
			"canPublishSources": ["microphone"],
			"canPublishData": false,
		},
	}
	return sign_hs256(payload, str(cfg.get("api_secret", "")))


# 管理钥匙：踢人要 roomAdmin（只限这一个房间），删房间要 roomCreate（LiveKit 的删房权限挂在它上面）。
static func admin_token(cfg: Dictionary, room: String, now: int, can_delete: bool) -> String:
	var video: Dictionary = {"roomCreate": true} if can_delete else {"roomAdmin": true, "room": room}
	var payload := {
		"iss": str(cfg.get("api_key", "")),
		"nbf": now,
		"exp": now + ADMIN_TTL_SEC,
		"video": video,
	}
	return sign_hs256(payload, str(cfg.get("api_secret", "")))


# JWT（HS256）。键按写入顺序输出（sort_keys = false）—— 门禁拿 jwt.io 的标准样例逐字节对账。
static func sign_hs256(payload: Dictionary, secret: String) -> String:
	var header := {"alg": "HS256", "typ": "JWT"}
	var signing_input := "%s.%s" % [
		base64url(JSON.stringify(header, "", false).to_utf8_buffer()),
		base64url(JSON.stringify(payload, "", false).to_utf8_buffer())]
	var ctx := HMACContext.new()
	ctx.start(HashingContext.HASH_SHA256, secret.to_utf8_buffer())
	ctx.update(signing_input.to_utf8_buffer())
	return "%s.%s" % [signing_input, base64url(ctx.finish())]


static func base64url(bytes: PackedByteArray) -> String:
	return Marshalls.raw_to_base64(bytes).replace("+", "-").replace("/", "_").rstrip("=")


# 解出钥匙的内容（**不验签**）。只给门禁用。
static func decode_payload(token: String) -> Dictionary:
	var parts := token.split(".")
	if parts.size() != 3:
		return {}
	var b64 := parts[1].replace("-", "+").replace("_", "/")
	while b64.length() % 4 != 0:
		b64 += "="
	var parsed: Variant = JSON.parse_string(Marshalls.base64_to_utf8(b64))
	return parsed if parsed is Dictionary else {}
