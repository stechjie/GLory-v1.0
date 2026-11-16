extends RefCounted

# 账号请求的两件辅助事（2026-11-14，Steam 审核三次卡在 result=2 之后加的）：
#
# 1. **系统代理**：Godot 的 HTTPRequest 不读 Windows 的代理设置（浏览器、Steam 客户端会读）。
#    要求所有流量走代理的网络（公司、学校、部分测试机房）里，游戏直连会被防火墙挡下，
#    表现就是 result=2（RESULT_CANT_CONNECT）。这里读出系统代理，账号请求跟着走。
#    没设代理的电脑行为不变，照旧直连。
#    ⚠️ 只管 HTTP（账号请求、维护公告）。实时连接（WebSocket）和战斗（UDP）Godot 没有代理接口，
#    纯代理网络里它们照样连不上 —— 这里解决的是「登录这一步」和「日志说得清卡在哪」。
#
# 2. **失败诊断**：以前 result=2 只显示在界面上，godot.log 里什么都没有，审核员贴回来的日志
#    看不出卡在哪。现在失败时打一行：域名、result 名字、解析出的 IP、用没用代理。
#    🔴 只打公开信息：不打 URL 参数、请求体、令牌。
#
# 不用 class_name（理由同 AccountConfig.gd 顶部）。

const REG_KEY := "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings"

static var _proxy_loaded := false
static var _proxy: Dictionary = {}

const RESULT_NAMES := {
	HTTPRequest.RESULT_SUCCESS: "SUCCESS",
	HTTPRequest.RESULT_CHUNKED_BODY_SIZE_MISMATCH: "CHUNKED_BODY_SIZE_MISMATCH",
	HTTPRequest.RESULT_CANT_CONNECT: "CANT_CONNECT",
	HTTPRequest.RESULT_CANT_RESOLVE: "CANT_RESOLVE",
	HTTPRequest.RESULT_CONNECTION_ERROR: "CONNECTION_ERROR",
	HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR: "TLS_HANDSHAKE_ERROR",
	HTTPRequest.RESULT_NO_RESPONSE: "NO_RESPONSE",
	HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED: "BODY_SIZE_LIMIT_EXCEEDED",
	HTTPRequest.RESULT_BODY_DECOMPRESS_FAILED: "BODY_DECOMPRESS_FAILED",
	HTTPRequest.RESULT_REQUEST_FAILED: "REQUEST_FAILED",
	HTTPRequest.RESULT_DOWNLOAD_FILE_CANT_OPEN: "DOWNLOAD_FILE_CANT_OPEN",
	HTTPRequest.RESULT_DOWNLOAD_FILE_WRITE_ERROR: "DOWNLOAD_FILE_WRITE_ERROR",
	HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED: "REDIRECT_LIMIT_REACHED",
	HTTPRequest.RESULT_TIMEOUT: "TIMEOUT",
}


# 系统代理。{} = 没设（直连）。有值时：{"host", "port", "source", "bypass": PackedStringArray, "pac": String}
# 只在 Windows 电脑版读，读一次缓存住（reg.exe 几十毫秒，不该每个请求跑一遍）。
static func system_proxy() -> Dictionary:
	if _proxy_loaded:
		return _proxy
	_proxy_loaded = true
	_proxy = {}
	if not OS.has_feature("windows") or OS.has_feature("dedicated_server"):
		return _proxy
	# 先看环境变量（少数公司用它），再看系统设置里的「使用代理服务器」。
	for name in ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"]:
		var parsed := _parse_host_port(OS.get_environment(name))
		if not parsed.is_empty():
			parsed["source"] = "env:" + name
			parsed["bypass"] = PackedStringArray(OS.get_environment("NO_PROXY").split(",", false))
			parsed["pac"] = ""
			_proxy = parsed
			return _proxy
	var values := _read_registry()
	var pac := str(values.get("AutoConfigURL", ""))
	if str(values.get("ProxyEnable", "0x0")) not in ["0x1", "1"]:
		if not pac.is_empty():
			# 只有自动配置脚本（PAC）、没开固定代理：我们解析不了 PAC，照旧直连，但在日志里说出来。
			_proxy = {"host": "", "port": 0, "source": "pac_only", "bypass": PackedStringArray(), "pac": pac}
		return _proxy
	var parsed := _parse_server_list(str(values.get("ProxyServer", "")))
	if parsed.is_empty():
		return _proxy
	parsed["source"] = "registry"
	parsed["bypass"] = PackedStringArray(str(values.get("ProxyOverride", "")).split(";", false))
	parsed["pac"] = pac
	_proxy = parsed
	return _proxy


# 给这个请求挂上系统代理（目标在例外名单里就不挂）。返回实际用的代理描述，"" = 直连。
static func apply_proxy(http: HTTPRequest, url: String) -> String:
	var proxy := system_proxy()
	var host := str(proxy.get("host", ""))
	if host.is_empty():
		return ""
	var target := host_of(url)
	if _bypassed(target, proxy.get("bypass", PackedStringArray())):
		return ""
	var port := int(proxy.get("port", 80))
	if url.begins_with("https://"):
		http.set_https_proxy(host, port)
	else:
		http.set_http_proxy(host, port)
	return "%s:%d" % [host, port]


static func host_of(url: String) -> String:
	var rest := url.get_slice("://", 1) if url.contains("://") else url
	rest = rest.get_slice("/", 0)
	if rest.begins_with("["):
		return rest.get_slice("]", 0).trim_prefix("[")
	return rest.get_slice(":", 0)


static func result_name(result: int) -> String:
	return str(RESULT_NAMES.get(result, "RESULT_%d" % result))


# 失败时打进 godot.log 的那一行。只有公开信息：域名、路径、result、解析出的 IP、代理。
static func describe_failure(url: String, result: int, path: String, used_proxy: String) -> String:
	var host := host_of(url)
	var addresses := Array(IP.resolve_hostname_addresses(host, IP.TYPE_ANY))
	var proxy := system_proxy()
	return "[ACCOUNT_NET] 请求失败 host=%s path=%s result=%d(%s) resolved=%s proxy=%s proxy_source=%s pac=%s" % [
		host, path, result, result_name(result),
		JSON.stringify(addresses), used_proxy if not used_proxy.is_empty() else "direct",
		str(proxy.get("source", "none")), "yes" if not str(proxy.get("pac", "")).is_empty() else "no"]


# 一启动就打一行网络环境，审核员的日志里至少有这一行可看。
static func describe_environment(url: String) -> String:
	var proxy := system_proxy()
	return "[ACCOUNT_NET] 账号服务器=%s 系统代理=%s 来源=%s PAC=%s" % [
		host_of(url),
		"%s:%d" % [proxy.get("host"), int(proxy.get("port", 0))] if not str(proxy.get("host", "")).is_empty() else "无",
		str(proxy.get("source", "none")), "有" if not str(proxy.get("pac", "")).is_empty() else "无"]


static func _read_registry() -> Dictionary:
	var output: Array = []
	if OS.execute("reg", ["query", REG_KEY], output, true) != 0 or output.is_empty():
		return {}
	var values := {}
	for line: String in str(output[0]).split("\n"):
		var parts := line.strip_edges().split("    ", false)
		# 形如：ProxyEnable    REG_DWORD    0x1
		if parts.size() >= 3 and parts[1].strip_edges().begins_with("REG_"):
			values[parts[0].strip_edges()] = parts[2].strip_edges()
	return values


# ProxyServer 两种写法：「host:port」或「http=h:p;https=h:p;socks=h:p」。HTTPS 优先，其次 http，SOCKS 不支持。
static func _parse_server_list(value: String) -> Dictionary:
	value = value.strip_edges()
	if value.is_empty():
		return {}
	if not value.contains("="):
		return _parse_host_port(value)
	var by_scheme := {}
	for item in value.split(";", false):
		var kv := item.split("=", false)
		if kv.size() == 2:
			by_scheme[kv[0].strip_edges().to_lower()] = kv[1].strip_edges()
	for scheme in ["https", "http"]:
		if by_scheme.has(scheme):
			return _parse_host_port(str(by_scheme[scheme]))
	return {}


static func _parse_host_port(value: String) -> Dictionary:
	value = value.strip_edges()
	if value.is_empty():
		return {}
	if value.contains("://"):
		var scheme := value.get_slice("://", 0).to_lower()
		if scheme.begins_with("socks"):
			return {}
		value = value.get_slice("://", 1)
	if value.contains("@"):
		# 带账号密码的代理（user:pass@host）我们不支持，也绝不把账号密码打进日志。
		return {}
	value = value.get_slice("/", 0)
	var host := value
	var port := 80
	if value.contains(":"):
		host = value.get_slice(":", 0)
		var tail := value.get_slice(":", 1)
		if tail.is_valid_int():
			port = tail.to_int()
	if host.is_empty() or port <= 0 or port > 65535:
		return {}
	return {"host": host, "port": port}


static func _bypassed(host: String, patterns: PackedStringArray) -> bool:
	var lower := host.to_lower()
	for raw in patterns:
		var pattern := raw.strip_edges().to_lower()
		if pattern.is_empty():
			continue
		if pattern == "<local>":
			if not lower.contains("."):
				return true
			continue
		if lower == pattern or lower.match(pattern) or (pattern.begins_with(".") and lower.ends_with(pattern)):
			return true
	return false
