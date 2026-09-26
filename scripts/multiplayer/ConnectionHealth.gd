extends RefCounted

# D1 第 6 刀：从 NetworkService 抽出的连接健康判定。
#
# **为什么只抽判定，不抽整个 Transport。**
# 勘测：触碰传输变量的 20 个函数、669 行里，**525 行是编排** ——
# `_process` / `team_host` / `_on_peer_connected` / `_assign_peer_to_room` 这些的
# 本职就是操作 `multiplayer` 和 ENet peer。这符合预期：传输层的工作就是发包收包，
# 它没有多少"数据"可以搬。硬搬只会得到一个为每次发包回调门面的空壳。
#
# 三个 tick 函数（心跳超时 / 僵尸回收 / 空闲回收）的结构是一样的：
#   遍历 peer 映射 → 按时间判定谁该处理 → 执行断开/回收
# **判定是纯的，执行必须留在门面**（要碰 `multiplayer.multiplayer_peer`）。
# 本类只做判定。
#
# 覆盖现状（抽出来的动机）：`adversarial_client` 只覆盖了空闲回收的一个用例，
# **心跳超时与僵尸回收零覆盖**。而这几个阈值判错的后果都很实在：
#   * 超时判太松 → 掉线的人一直占着座位，别人进不来
#   * 判太紧 → 网络抖一下就把正常玩家踢下线
#   * 静默预警线 >= 超时线 → 预警永远不会触发，等于没有
#
# 不用 class_name：make_server_zip.ps1 会打包 .godot/global_script_class_cache.cfg，
# 新增全局类若未先重建缓存就打包，服务器会在解析阶段直接挂（见 docs/CHECKS.md）。

const HEARTBEAT_INTERVAL_SEC := 3.0    # 客户端 ping 间隔
const HEARTBEAT_TIMEOUT_SEC := 20.0    # 超过没消息判掉线（双端）
const PONG_GAP_WARN_SEC := 6.0         # 静默预警线：还没到超时，但网络已经不对劲
const PING_RTT_LOG_MS := 400           # 心跳往返超过这个值才记，正常网络不刷日志
const UNJOINED_PEER_TTL_SEC := 60.0    # 连上但一直不进房间的 peer 的存活上限
const RESUME_STALE_SEC := HEARTBEAT_INTERVAL_SEC * 3.0


# Only use after validating the reconnect credential for the occupied seat.
# A fresh holder remains protected; a half-open mobile connection must not
# delay its authenticated replacement until the full disconnect timeout.
func resume_holder_stale(last_ping: Dictionary, peer_id: int, now: float) -> bool:
	return last_ping.has(peer_id) and now - float(last_ping[peer_id]) >= RESUME_STALE_SEC


# 哪些 peer 已经心跳超时。只做判定，断开由门面执行。
func timed_out_peers(last_ping: Dictionary, now: float) -> Array:
	var out: Array = []
	for peer_id in last_ping.keys():
		if now - float(last_ping[peer_id]) > HEARTBEAT_TIMEOUT_SEC:
			out.append(int(peer_id))
	return out


# 连上但没进房间的 peer 怎么处理。返回两组，语义不同、不能混：
#   forget —— 已经进房间了，不再归本清道夫管（由座位/心跳/僵尸那套负责），
#             只需从 connected_at 里摘掉，**不能断开**
#   drop   —— 超过 TTL 仍没进房间，该断开
# 原实现把这两件事写在同一个循环里，混了就会把正常在房间里的人踢掉。
func partition_unjoined(connected_at: Dictionary, peer_room: Dictionary, now: float) -> Dictionary:
	var forget: Array = []
	var drop: Array = []
	for peer_key in connected_at.keys():
		var pid := int(peer_key)
		if peer_room.has(pid):
			forget.append(pid)
			continue
		if now - float(connected_at[peer_key]) < UNJOINED_PEER_TTL_SEC:
			continue
		drop.append(pid)
	return {"forget": forget, "drop": drop}


# 静默多久该预警。必须严格早于超时线，否则预警永远不会触发。
func should_warn_silence(silence_sec: float) -> bool:
	return silence_sec >= PONG_GAP_WARN_SEC


func should_log_rtt(rtt_ms: int) -> bool:
	return rtt_ms >= PING_RTT_LOG_MS


# 距上次 ping 已过 accum 秒，是否该再发一次。
func should_send_ping(accum_sec: float) -> bool:
	return accum_sec >= HEARTBEAT_INTERVAL_SEC


# This transport uses unreliable RPCs only for low-rate ping/pong. ENet's
# default adaptive unreliable throttle can discard several consecutive heartbeats
# after a reliable replay burst even while the socket is healthy. Keep those
# control packets eligible for sending; reliable windows, replay queue budgets
# and the application timeout continue to enforce backpressure and liveness.
func configure_peer(peer: ENetPacketPeer) -> void:
	if peer == null:
		return
	peer.set_timeout(64, 15000, 45000)
	peer.throttle_configure(1000, ENetPacketPeer.PACKET_THROTTLE_SCALE, 0)
