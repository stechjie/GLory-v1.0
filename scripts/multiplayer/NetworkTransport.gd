extends RefCounted

# D1 目标结构里的 NetworkTransport：**ENet / RPC / 通道**。
#
# 搬进来的是"这条连接该不该建立、包走哪条通道"的**判定**；
# 留在门面的是 SceneMultiplayer 的调用本身（send_auth / complete_auth /
# create_client / create_server / multiplayer_peer 赋值）—— 本类是 RefCounted，
# 够不着 multiplayer，也不该够得着。
#
# 为什么握手判定值得单独拿出来：它是**唯一在建立信任之前跑的代码**，输入完全由
# 未经验证的对端控制。而它此前只有一条 happy path 被驱动过 —— tools/handshake_check
# 有 ok/bad/silent 三个用例，但仓库里没有任何东西驱动后两个，改坏拒绝原因也照样
# 退出 0（2026-08-20 实测，见 tools/multiplayer_regression.sh 顶部）。
#
# 三条判定规则，每条背后都有具体后果：
#   payload 超限   -> 不设限等于让对端决定服务器为一次握手分配多少内存
#   协议号不匹配   -> 放行会让两个版本的客户端进同一房间，症状是各种诡异的状态错乱
#   拒绝原因要可读 -> 客户端要把它摆到 UI 上；只回 false 玩家只会看到"连不上"
#
# 服务端**故意不主动断开**被拒的连接，靠 auth_timeout 兜底：那样"发拒绝"和
# "断连接"之间没有竞态，客户端一定能读到原因。
#
# 不用 class_name：make_server_zip.ps1 会打包 .godot/global_script_class_cache.cfg，
# 新增全局类若未先重建缓存就打包，服务器会在解析阶段直接挂（见 docs/CHECKS.md）。

const NetError := preload("res://scripts/multiplayer/NetError.gd")
const NetworkConfig := preload("res://scripts/multiplayer/NetworkConfig.gd")

const AUTH_TIMEOUT_SEC := 8.0
# 握手包的上限。认证阶段的数据来自未经验证的对端，不设限等于让它决定
# 服务器要为一次握手分配多少内存。
const AUTH_MAX_PAYLOAD_BYTES := 512
# 同时在握手中的连接数上限。没有它，一个不完成握手的客户端可以无限开连接。
const AUTH_MAX_PENDING := 64

var _log_fn: Callable = Callable()


func configure(log_fn: Callable) -> void:
	_log_fn = log_fn


func _log(message: String) -> void:
	if _log_fn.is_valid():
		_log_fn.call(message)


# --- 握手编解码 ---------------------------------------------------------------

# 客户端问候：只带协议号。多带一个字段就多一个未经验证的输入面。
static func client_hello_bytes() -> PackedByteArray:
	return var_to_bytes({"protocol": NetworkConfig.NETWORK_PROTOCOL_VERSION})


static func auth_reject_bytes(code: String) -> PackedByteArray:
	return var_to_bytes({"ok": false, "code": code, "class": NetError.class_name_of(code)})


static func auth_accept_bytes() -> PackedByteArray:
	return var_to_bytes({"ok": true})


# 用 bytes_to_var（非 _with_objects）：认证阶段的数据来自未经验证的对端，
# 后者能从字节流里构造对象，等于在建立信任之前就给了对方一个执行面。
static func decode_auth(data: PackedByteArray) -> Dictionary:
	if data.is_empty() or data.size() > AUTH_MAX_PAYLOAD_BYTES:
		return {}
	var value = bytes_to_var(data)
	return value if typeof(value) == TYPE_DICTIONARY else {}


# --- 服务端裁决 ---------------------------------------------------------------

# 返回 {"accept": bool, "code": String, "log": String}。
# 只做判断，不发包 —— 发包要 SceneMultiplayer，那在门面。
func server_verdict(data: PackedByteArray, peer_id: int) -> Dictionary:
	if data.size() > AUTH_MAX_PAYLOAD_BYTES:
		var msg := "auth rejected peer=%d reason=payload_too_large bytes=%d" % [peer_id, data.size()]
		_log(msg)
		return {"accept": false, "code": "protocol_mismatch", "log": msg}
	var hello := decode_auth(data)
	var client_protocol := int(hello.get("protocol", -1))
	if client_protocol != NetworkConfig.NETWORK_PROTOCOL_VERSION:
		var msg2 := "auth rejected peer=%d reason=protocol_mismatch client=%d server=%d" % [
			peer_id, client_protocol, NetworkConfig.NETWORK_PROTOCOL_VERSION]
		_log(msg2)
		return {"accept": false, "code": "protocol_mismatch", "log": msg2}
	return {"accept": true, "code": "", "log": ""}


# --- 客户端裁决 ---------------------------------------------------------------

# 返回 {"accept": bool, "code": String}。被拒时 code 一定非空：
# 客户端要把它摆到 UI 上，只回 false 的话玩家只会看到"连不上"。
func client_verdict(data: PackedByteArray) -> Dictionary:
	var verdict := decode_auth(data)
	if bool(verdict.get("ok", false)):
		return {"accept": true, "code": ""}
	var code := str(verdict.get("code", "protocol_mismatch"))
	if code.is_empty():
		code = "protocol_mismatch"
	_log("handshake rejected by server: %s (%s)" % [code, NetError.class_name_of(code)])
	return {"accept": false, "code": code}


# --- 通道 ---------------------------------------------------------------------
#
# 通道常量**不搬**。它们已经在 scripts/multiplayer/NetworkConfig.gd 里（CH_CONTROL=0、
# CH_BULK=1），那就是唯一真相源；在这里再定义一份就是给自己造第二个真相。
#
# 我第一版真的照着"应该长什么样"重写了一遍，写成 CH_CONTROL=1、CH_BULK=2 —— 和实际
# 差了一位。通道号写错的后果不是抛错，而是**包被静默丢弃**，这种错误正是
# tools/channel_check 存在的理由。凭印象重写常量是最容易制造它的方式。
