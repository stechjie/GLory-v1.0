extends RefCounted

# 观战（2026-10-22 与设计逐条定稿，规则见下）。
#
# 这里只放**纯数据规则**：观战者表怎么增删、给观战者看什么、什么时候能看。
# 发消息（RPC）全部留在 NetworkService —— 同 RoomService 的分工，RefCounted 够不着 multiplayer。
#
# 不用 class_name：理由同 RoomService（make_server_zip.ps1 打包的全局类缓存）。
#
# 🔴 观战者**不占座位、不进 peer_slot、不进 _peer_room**。
# NetworkService 里 25 个处理函数都默认「在房间里 = 有座位」：买卖、提交棋盘、准备、
# 语音钥匙……观战者要是混进 peer_slot，每一个都得重新审一遍。分开放之后，这些入口
# 对观战者天然是「你不在任何房间里」，一行都不用改。
#
# 🔴 观战者**不影响房间本身**：
#   * 不算在线人数（room_online_count 只数 peer_slot）—— 只剩观战者的房间照常转 suspended；
#   * 不进结算确认（result_acks 只等座位）；
#   * 不落盘（DedicatedServerService.PERSISTED_ROOM_FIELDS 是白名单，这里的字段都不在里面）。
#
# 🔴 备战画面**延迟一回合**：观战者看到的永远是「已经打完的那一场」上场的阵容。
# 选手一点准备，本回合棋盘就已经进了 room.boards（10.18「准备即提交棋盘」），
# 所以绝不能从 room.boards / last_board 取 —— 只认战斗结果发布那一刻冻结下来的 spectator_view。

const MAX_SPECTATORS := 10

# 房间字典里的键。都不在持久化白名单里：服务器重启 = 观战者掉线，客户端自己重进。
const KEY_LIST := "spectators"           # sid(int) -> 观战者条目
const KEY_NEXT_SID := "next_spectator_sid"
const KEY_OPEN := "spectate_open"        # 房主可以关；默认开
const KEY_VIEW := "spectator_view"       # 冻结的上一回合阵容

# 观战者的公开编号。不用 peer_id：peer_id 是连接层的东西，没理由发给别的客户端。
# 房主踢人按这个号踢。


static func is_open(room: Dictionary) -> bool:
	return bool(room.get(KEY_OPEN, true))


static func list(room: Dictionary) -> Dictionary:
	return room.get(KEY_LIST, {})


static func count(room: Dictionary) -> int:
	return list(room).size()


static func peers(room: Dictionary) -> Array[int]:
	var out: Array[int] = []
	for entry in list(room).values():
		out.append(int((entry as Dictionary).get("peer", 0)))
	return out


static func sid_of_peer(room: Dictionary, peer_id: int) -> int:
	var spectators := list(room)
	for sid in spectators.keys():
		if int((spectators[sid] as Dictionary).get("peer", 0)) == peer_id:
			return int(sid)
	return -1


static func entry_of_peer(room: Dictionary, peer_id: int) -> Dictionary:
	var sid := sid_of_peer(room, peer_id)
	if sid < 0:
		return {}
	return list(room).get(sid, {})


# 加一个观战者。identity 是 NetworkService.public_seat_identity 洗过的公开身份；
# 空 = 游客（没有名片）：能看、不能发言 —— 没有账号就没有举报和封禁的抓手。
#
# 返回 {"ok": true, "sid": int} 或 {"ok": false, "reason": String}。
# reason 原样回给客户端（_rpc_team_action_failed），客户端按码翻译文案。
static func add(room: Dictionary, peer_id: int, identity: Dictionary, now: float) -> Dictionary:
	if room.is_empty():
		return {"ok": false, "reason": "room_not_found"}
	if not is_open(room):
		return {"ok": false, "reason": "spectate_closed"}
	var existing := sid_of_peer(room, peer_id)
	if existing >= 0:
		return {"ok": true, "sid": existing}
	if count(room) >= MAX_SPECTATORS:
		return {"ok": false, "reason": "spectate_full"}
	var sid := int(room.get(KEY_NEXT_SID, 1))
	room[KEY_NEXT_SID] = sid + 1
	var spectators := list(room)
	spectators[sid] = {
		"peer": peer_id,
		"identity": identity.duplicate(true),
		"guest": identity.is_empty(),
		"joined_at": now,
	}
	room[KEY_LIST] = spectators
	return {"ok": true, "sid": sid}


# 按连接移除；返回被移除的条目（不在表里返回空）。
static func remove_peer(room: Dictionary, peer_id: int) -> Dictionary:
	var sid := sid_of_peer(room, peer_id)
	if sid < 0:
		return {}
	var spectators := list(room)
	var entry: Dictionary = spectators.get(sid, {})
	spectators.erase(sid)
	room[KEY_LIST] = spectators
	return entry


# 按公开编号移除（房主踢人）；返回被移除者的 peer_id，没有返回 0。
static func remove_sid(room: Dictionary, sid: int) -> int:
	var spectators := list(room)
	if not spectators.has(sid):
		return 0
	var peer_id := int((spectators[sid] as Dictionary).get("peer", 0))
	spectators.erase(sid)
	room[KEY_LIST] = spectators
	return peer_id


static func can_chat(entry: Dictionary) -> bool:
	return not entry.is_empty() and not bool(entry.get("guest", true))


static func display_name(entry: Dictionary) -> String:
	return str((entry.get("identity", {}) as Dictionary).get("player_name", ""))


# 观战列表（大厅左侧那一栏）。选手和观战者看到的是同一份，只有公开字段。
static func public_list(room: Dictionary) -> Array:
	var out: Array = []
	var spectators := list(room)
	var sids := spectators.keys()
	sids.sort()
	for sid in sids:
		var entry: Dictionary = spectators[sid]
		out.append({
			"sid": int(sid),
			"guest": bool(entry.get("guest", true)),
			"identity": (entry.get("identity", {}) as Dictionary).duplicate(true),
		})
	return out


# --- 延迟一回合的阵容 ---------------------------------------------------------

# 一个座位上给观战者看的那部分：和选手自己的备战界面同一批字段，商店除外。
# loadout 是 BattleReplayJob._capture_battle_loadouts 抓的那份（真人 = 他交的棋盘快照，
# AI = 机器人当回合生成的阵容），正是这场战斗实际上场的东西。
static func seat_view(loadout: Dictionary) -> Dictionary:
	return {
		"board": (loadout.get("board", []) as Array).duplicate(true),
		"bench": (loadout.get("bench", []) as Array).duplicate(true),
		"mercenaries": (loadout.get("mercenaries", []) as Array).duplicate(true),
		"treasures": (loadout.get("treasures", []) as Array).duplicate(),
		"syn": (loadout.get("syn", {}) as Dictionary).duplicate(true),
		"gold": int(loadout.get("gold", -1)),   # AI 没有自报金币，-1 = 不显示
		"is_ai": bool(loadout.get("is_ai", false)),
	}


# 战斗结果发布时调用：把这一场上场的阵容冻结下来，直到下一场发布才换。
# 之后整个下一回合备战期，观战者看到的都是这一份 —— 这就是「延迟一回合」。
static func freeze_view(room: Dictionary, round_index: int, battle_id: String, loadouts: Dictionary) -> Dictionary:
	var seats := {}
	for slot in loadouts.keys():
		var loadout: Variant = loadouts[slot]
		if typeof(loadout) == TYPE_DICTIONARY:
			seats[int(slot)] = seat_view(loadout)
	var view := {"round": round_index, "battle_id": battle_id, "seats": seats}
	room[KEY_VIEW] = view
	return view


static func current_view(room: Dictionary) -> Dictionary:
	return room.get(KEY_VIEW, {})
