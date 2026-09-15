extends RefCounted

# 维护公告文件 /status.json 的解析（docs/公告系统设计.md「维护公告」）。
#
# 那个文件由 Caddy 直接给，**不经过账号服务器** —— 账号服务器停机维护时启动画面也读得到。
# 启动画面只在「登录失败 / 连不上服务器」时读它，读到就把「连不上」换成维护说明。
#
# 过期按**服务器**的钟判（HTTP 响应的 Date 头）：管理员维护完忘了删文件时，过了 expires_at 就不再显示 ——
# 否则一个自己网络不好的玩家会被告知「服务器在维护」。拿不到 Date 头时才退回手机时间。
#
# 文件长这样（expires_at 要带时区）：
#   {"maintenance": true,
#    "title_zh": "服务器维护中", "message_zh": "预计 18:00 恢复。",
#    "title_en": "Maintenance", "message_en": "Back around 18:00 (UTC+8).",
#    "expires_at": "2026-09-20 19:00+08:00"}

const PATH := "/status.json"
const MONTHS := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]


# 返回要显示的维护说明；不在维护、已过期、文件坏了都返回空字典。
static func parse(text: String, server_unix: int) -> Dictionary:
	var json := JSON.new()
	if json.parse(text) != OK or not (json.data is Dictionary):
		return {}
	var data: Dictionary = json.data
	# 只认 JSON 的 true。写成 "true" 字符串的不算 —— 宁可不显示，也不要把格式错当成在维护。
	if not (data.get("maintenance", false) is bool) or data.get("maintenance", false) != true:
		return {}
	var expires := parse_iso_utc(str(data.get("expires_at", "")))
	if expires > 0 and server_unix >= expires:
		return {}
	return {
		"title_zh": str(data.get("title_zh", "")).strip_edges(),
		"message_zh": str(data.get("message_zh", "")).strip_edges(),
		"title_en": str(data.get("title_en", "")).strip_edges(),
		"message_en": str(data.get("message_en", "")).strip_edges(),
	}


# "2026-09-20T20:00:00+08:00" / "2026-09-20 20:00+08" / "...Z" -> Unix 秒。认不出返回 0。
# 不带时区按 UTC 算。不用 Time.get_unix_time_from_datetime_string：它不管时区后缀。
static func parse_iso_utc(text: String) -> int:
	var re := RegEx.create_from_string(
		"^(\\d{4})-(\\d{2})-(\\d{2})[T ](\\d{2}):(\\d{2})(?::(\\d{2}))?\\s*(Z|[+-]\\d{2}(?::?\\d{2})?)?$")
	var m := re.search(text.strip_edges())
	if m == null:
		return 0
	var unix := Time.get_unix_time_from_datetime_dict({
		"year": m.get_string(1).to_int(), "month": m.get_string(2).to_int(), "day": m.get_string(3).to_int(),
		"hour": m.get_string(4).to_int(), "minute": m.get_string(5).to_int(), "second": m.get_string(6).to_int(),
	})
	var zone := m.get_string(7)
	if zone.is_empty() or zone == "Z":
		return unix
	var direction := -1 if zone.begins_with("-") else 1
	var digits := zone.substr(1).replace(":", "")
	var offset := digits.substr(0, 2).to_int() * 3600 + digits.substr(2, 2).to_int() * 60
	return unix - direction * offset


# RFC 7231 的 Date 头："Sun, 20 Sep 2026 10:00:00 GMT" -> Unix 秒。认不出返回 0。
static func parse_http_date(value: String) -> int:
	var re := RegEx.create_from_string(
		"^[A-Za-z]{3}, (\\d{1,2}) ([A-Za-z]{3}) (\\d{4}) (\\d{2}):(\\d{2}):(\\d{2}) GMT$")
	var m := re.search(value.strip_edges())
	if m == null:
		return 0
	var month := MONTHS.find(m.get_string(2)) + 1
	if month <= 0:
		return 0
	return Time.get_unix_time_from_datetime_dict({
		"year": m.get_string(3).to_int(), "month": month, "day": m.get_string(1).to_int(),
		"hour": m.get_string(4).to_int(), "minute": m.get_string(5).to_int(), "second": m.get_string(6).to_int(),
	})


static func server_time_from_headers(headers: PackedStringArray) -> int:
	for line in headers:
		if line.to_lower().begins_with("date:"):
			return parse_http_date(line.substr(5))
	return 0
