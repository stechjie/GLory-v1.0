extends Node

# NetworkTransport 的独立门禁（D1 验收条款：每个子服务有独立 headless 测试）。
#
# 覆盖原始 README 给这个服务定的范围里**可纯逻辑判定的那部分**：握手的编解码与
# 服务端/客户端裁决。ENet 连接建立本身（create_client / create_server /
# multiplayer_peer）留在门面，由 tools/handshake_check 与 tools/channel_check
# 过真实网络验证 —— 那两件事只有真的跑一遍 ENet 才算数。
#
# 握手判定是**唯一在建立信任之前跑的代码**，输入完全由未经验证的对端控制。
# 而它此前只有 happy path 被驱动过：handshake_check 有 ok/bad/silent 三个用例，
# 但仓库里没有任何东西驱动后两个，改坏拒绝原因也照样退出 0（2026-08-20 实测）。
# 现在 multiplayer_regression.sh 驱动全部三个，这里再补上不必起网络就能测的边界。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const Transport := preload("res://scripts/multiplayer/NetworkTransport.gd")
const NetworkConfig := preload("res://scripts/multiplayer/NetworkConfig.gd")
const CHECK_NAME := "network_transport"

var _h: RefCounted
var _logs: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_check_hello_round_trip()
	_check_server_accepts_matching_protocol()
	_check_server_rejects_mismatched_protocol()
	_check_server_rejects_oversized()
	_check_server_rejects_garbage()
	_check_client_verdict()
	_check_reject_is_readable()
	_check_no_object_construction()
	_check_channel_constants_not_duplicated()
	_check_reject_closes_after_callback()
	_h.finish(get_tree())


func _make() -> RefCounted:
	var svc: RefCounted = Transport.new()
	svc.configure(func(msg: String) -> void: _logs.append(msg))
	return svc


# --- 编解码 -------------------------------------------------------------------

func _check_hello_round_trip() -> void:
	var hello := Transport.client_hello_bytes()
	var back := Transport.decode_auth(hello)
	_h.expect(int(back.get("protocol", -1)) == NetworkConfig.NETWORK_PROTOCOL_VERSION,
		"hello_protocol", "问候包应带当前协议号")
	_h.expect(back.size() == 1,
		"hello_extra_fields", "问候包只应带协议号 —— 多一个字段就多一个未经验证的输入面")


# --- 服务端裁决 ---------------------------------------------------------------

func _check_server_accepts_matching_protocol() -> void:
	var svc := _make()
	var v: Dictionary = svc.server_verdict(Transport.client_hello_bytes(), 42)
	_h.expect(bool(v.get("accept", false)), "server_rejects_valid", "协议号一致的握手应放行")


# 放行版本不匹配的客户端，会让两个版本进同一房间，症状是各种诡异的状态错乱 ——
# 那种问题从日志里几乎看不出根因。
func _check_server_rejects_mismatched_protocol() -> void:
	var svc := _make()
	for wrong in [NetworkConfig.NETWORK_PROTOCOL_VERSION + 1, NetworkConfig.NETWORK_PROTOCOL_VERSION - 1, 0, -7]:
		var payload := var_to_bytes({"protocol": wrong})
		var v: Dictionary = svc.server_verdict(payload, 7)
		_h.expect(not bool(v.get("accept", true)),
			"server_accepted_wrong_protocol", "协议号 %d 与服务端不一致，必须拒收" % wrong)
		_h.expect(str(v.get("code", "")) == "protocol_mismatch",
			"server_reject_code", "拒收原因应为 protocol_mismatch，实际 '%s'" % str(v.get("code", "")))

	# 完全没有 protocol 字段：等同于不匹配，不能因为"读不到就当默认"而放行。
	var v2: Dictionary = svc.server_verdict(var_to_bytes({"hello": "hi"}), 7)
	_h.expect(not bool(v2.get("accept", true)),
		"server_accepted_missing_protocol", "缺少 protocol 字段必须拒收，不得按默认值放行")


# 不设上限等于让对端决定服务器为一次握手分配多少内存。
func _check_server_rejects_oversized() -> void:
	var svc := _make()
	var big := PackedByteArray()
	big.resize(Transport.AUTH_MAX_PAYLOAD_BYTES + 1)
	_logs.clear()
	var v: Dictionary = svc.server_verdict(big, 9)
	_h.expect(not bool(v.get("accept", true)),
		"server_accepted_oversized", "超过 %d 字节的握手包必须拒收" % Transport.AUTH_MAX_PAYLOAD_BYTES)
	var logged := false
	for line in _logs:
		if line.contains("payload_too_large"):
			logged = true
	_h.expect(logged, "oversized_not_logged", "拒收超大包应留日志并注明原因")


func _check_server_rejects_garbage() -> void:
	var svc := _make()
	for junk in [PackedByteArray(), PackedByteArray([0]), PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8])]:
		var v: Dictionary = svc.server_verdict(junk, 3)
		_h.expect(not bool(v.get("accept", true)),
			"server_accepted_garbage", "非法字节流必须拒收（%d 字节）" % junk.size())


# --- 客户端裁决 ---------------------------------------------------------------

func _check_client_verdict() -> void:
	var svc := _make()
	var ok: Dictionary = svc.client_verdict(Transport.auth_accept_bytes())
	_h.expect(bool(ok.get("accept", false)), "client_rejects_accept", "服务端放行时客户端应接受")

	var no: Dictionary = svc.client_verdict(Transport.auth_reject_bytes("protocol_mismatch"))
	_h.expect(not bool(no.get("accept", true)), "client_accepts_reject", "服务端拒绝时客户端不得当成成功")
	_h.expect(str(no.get("code", "")) == "protocol_mismatch",
		"client_reject_code", "客户端应拿到可读的拒绝原因")

	# 垃圾/空裁决也必须当成被拒，并且带一个非空原因：
	# 只回 false 的话玩家在 UI 上只会看到"连不上"。
	# 最后一个是关键：code **存在但为空**。前几个走的是 get("code", 默认值) 那条路，
	# 默认值本身非空，所以它们测不到"空 code 要兜底"这条规则 —— 证伪时把兜底删掉
	# 却没变红，才发现少了这个用例。
	for junk in [PackedByteArray(), var_to_bytes({"garbage": 1}), var_to_bytes({"ok": false}),
			var_to_bytes({"ok": false, "code": ""})]:
		var v: Dictionary = svc.client_verdict(junk)
		_h.expect(not bool(v.get("accept", true)), "client_accepted_junk", "非法裁决必须当成被拒")
		_h.expect(not str(v.get("code", "")).is_empty(),
			"client_empty_code", "被拒时原因不得为空 —— 客户端要把它摆到 UI 上")


func _check_reject_is_readable() -> void:
	var bytes := Transport.auth_reject_bytes("protocol_mismatch")
	var decoded := Transport.decode_auth(bytes)
	_h.expect(not bool(decoded.get("ok", true)), "reject_ok_flag", "拒绝包的 ok 应为 false")
	_h.expect(str(decoded.get("code", "")) == "protocol_mismatch", "reject_code", "拒绝包应带原因码")
	_h.expect(not str(decoded.get("class", "")).is_empty(),
		"reject_class", "拒绝包应带错误分类，供客户端决定要不要重试")


# 认证阶段的数据来自未经验证的对端。bytes_to_var_with_objects 能从字节流构造对象，
# 等于在建立信任**之前**就给了对方一个执行面。
#
# 逐行判并跳过注释：直接 contains 会命中解释这个决定的注释本身。
# 这个坑在 room_service_check 与 replay_transfer_check 各踩过一次。
func _check_no_object_construction() -> void:
	var source := FileAccess.get_file_as_string("res://scripts/multiplayer/NetworkTransport.gd")
	_h.expect(not source.is_empty(), "source_read", "读不到 NetworkTransport.gd 源码")
	var offending := false
	for raw_line in source.split("\n"):
		var line := str(raw_line).strip_edges()
		if line.begins_with("#"):
			continue
		if line.contains("bytes_to_var_with_objects"):
			offending = true
	_h.expect(not offending, "auth_with_objects",
		"握手解码必须用 bytes_to_var；with_objects 等于在建立信任前给对方执行面")


# 通道常量的唯一真相源必须只有 NetworkConfig 一处。
#
# 抽 NetworkTransport 时我第一版凭印象在新文件里又写了一份，写成 CH_CONTROL=1、
# CH_BULK=2，而实际是 0 和 1 —— 差一位。通道号写错的后果不是抛错，而是包被静默
# 丢弃，正是 tools/channel_check 存在的理由。这条断言就是防止它被重新引入。
func _check_channel_constants_not_duplicated() -> void:
	var source := FileAccess.get_file_as_string("res://scripts/multiplayer/NetworkTransport.gd")
	var offending := false
	for raw_line in source.split("\n"):
		var line := str(raw_line).strip_edges()
		if line.begins_with("#"):
			continue
		if line.begins_with("const CH_"):
			offending = true
	_h.expect(not offending, "channel_const_duplicated",
		"通道常量只能定义在 NetworkConfig 里；再写一份就是给自己造第二个真相源")
	_h.expect(NetworkConfig.CH_CONTROL == 0 and NetworkConfig.CH_BULK == 1,
		"channel_values_changed", "通道号变了（CH_CONTROL=%d CH_BULK=%d）—— 改它等于改线上协议，两端必须同时更新"
			% [NetworkConfig.CH_CONTROL, NetworkConfig.CH_BULK])


# 🔴 客户端被拒时不能在认证回调里直接关 peer：回调跑在 SceneMultiplayer.poll() 里面，
# 当场关 Godot 4.7.1 会崩（signal 11）。2026-09-19 用独立小工程复现过：同步关必崩，推迟关不崩。
# 每次顶协议号，还没更新的旧包连新服务器都走这条路 —— 该看到「版本不对」，不是闪退。
# handshake_check 的客户端是它自己的 SceneMultiplayer，走不到 NetworkService 这段，所以这里按源码钉。
func _check_reject_closes_after_callback() -> void:
	var source := FileAccess.get_file_as_string("res://scripts/autoload/NetworkService.gd")
	var header := "func _on_auth_payload(id: int, data: PackedByteArray) -> void:"
	var start := source.find(header)
	var stop := source.find("
func ", start + header.length())
	var body := source.substr(start, stop - start) if start >= 0 and stop > start else ""
	var code_lines := PackedStringArray()
	for raw_line in body.split("
"):
		var line := str(raw_line).strip_edges()
		if not line.begins_with("#"):
			code_lines.append(line)
	var code := "
".join(code_lines)
	_h.item()
	_h.expect(not body.is_empty(), "auth_callback_missing", "NetworkService 里找不到 %s" % header)
	_h.expect(code.contains("_close_rejected_peer.call_deferred(multiplayer.multiplayer_peer)")
			and not code.contains("reset_peer_only()") and not code.contains(".close()")
			and not code.contains("multiplayer_peer = null"),
		"reject_closes_inside_callback",
		"客户端被拒时必须推迟到认证回调之后再关连接（_close_rejected_peer.call_deferred），当场关引擎会崩")
