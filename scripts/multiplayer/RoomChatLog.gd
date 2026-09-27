extends RefCounted

# 房间 / 对局的聊天记录（docs/聊天系统设计.md 第六节「翻回记录」，2026-09-27）。
#
# 战斗服务器只转发、不存（第八节第 5 条），所以「翻回去看」只能靠这台手机自己记。
# 挂在 NetworkService 上，因为只有它活得比界面久：大厅进对局就被销毁，摆放界面每回合重建，
# 看战斗那段根本没有聊天界面 —— 那段时间收到的消息以前没人接，直接丢了。
# 一份记录从进房间记到离开房间 / 对局结束（NetworkService.reset() 清掉），大厅和对局连成一份，
# 按回合分段（2026-09-27 定）。
#
# 🔴 说话人的名字、是不是对方，都**按收到那一刻记下来**，不在显示时按座位现查。
# 有人换座位、离开后被 AI 接管，按座位现查会把旧消息算到新坐进来的人头上。
#
# 只存内存（2026-09-27 定，第一版接受）：闪退 / 被系统杀掉之后重连回来，之前的记录就没了；
# 断线那几秒别人说的也收不到。要补就得让战斗服务器存、重连时补发 —— 加 RPC、顶协议号、
# 所有人同时换包。

const ChatPhrases := preload("res://scripts/multiplayer/ChatPhrases.gd")

signal entry_added(entry: Dictionary)

# 一局六个人（战斗服务器每人 10 秒最多放行 3 条）正常聊不到这么多；超了从最老的丢。
const MAX_ENTRIES := 100
# 与 Team3v3Lobby.SLOT_LABELS 一致：没有名字的座位（AI、测试座位）用座位号顶着。
const SEAT_LABELS := ["A", "B", "C", "1", "2", "3"]
# 范围标记只标例外：对局里的队友频道是默认，不加；大厅只有「全部」，也不加。
# tools/chat_check 读这两个常量算「最长一条放不放得下」，改字要跟着跑一次。
const TAG_ALL := "【全部】"      # 自己人发到全部：这条对面也看得到
const TAG_ENEMY := "【对方】"    # 对面的人发的（他们只能发到全部）
const TAG_ALL_EN := "[All] "
const TAG_ENEMY_EN := "[Enemy] "

var room_id := 0
var _entries: Array[Dictionary] = []
var _next_seq := 1


# 收到一条就记一条。room 变了（进了另一个房间）先清掉上一间的。
func add(current_room_id: int, entry: Dictionary) -> void:
	if entry.is_empty():
		return
	if current_room_id != room_id:
		clear()
		room_id = current_room_id
	entry["seq"] = _next_seq
	entry["seen"] = false
	_next_seq += 1
	_entries.append(entry)
	while _entries.size() > MAX_ENTRIES:
		_entries.pop_front()
	entry_added.emit(entry)


func clear() -> void:
	room_id = 0
	_entries.clear()


# 当前房间的记录（旧到新）。房间号对不上时是空的 —— 记录属于上一间。
# 返回的是新数组、同一批字典：界面改 seen 标记会落回记录里。
func entries_for(current_room_id: int) -> Array[Dictionary]:
	if current_room_id != room_id:
		return []
	return _entries.duplicate()


# 「看过」按条记，不用一个游标：摆放界面飘出来的新消息不能顺带把看战斗时收到、
# 还没人看过的那几条也算成看过。
# 看过 = 在界面上出现过（大厅的框、摆放界面飘出来的那几条、翻开的记录）。
func mark_entry_seen(entry: Dictionary) -> void:
	entry["seen"] = true


func mark_all_seen() -> void:
	for entry in _entries:
		entry["seen"] = true


# 没出现在任何界面上的条数（看战斗那段收到的）。回到摆放界面时据此给聊天按钮挂小点。
func unseen_count(current_room_id: int) -> int:
	var count := 0
	for entry in entries_for(current_room_id):
		if not bool(entry.get("seen", false)):
			count += 1
	return count


# 把一条收到的聊天做成记录。纯函数（不碰任何 autoload），tools/chat_check 直接调。
#   phrase_id > 0 是快捷短语，否则是 text；短语 id 不合法时返回空字典（不记）。
#   match_round：0 = 还在大厅（开局前），≥ 1 = 对局第几回合。
static func make_entry(slot: int, phrase_id: int, text: String, team_only: bool, local_slot: int,
		profiles: Dictionary, self_profile: Dictionary, match_round: int, en: bool) -> Dictionary:
	if phrase_id > 0 and ChatPhrases.text(phrase_id).is_empty():
		# ChatPhrases.text() 对非法 id 刻意返回空串（见那边的注释），这里同样不记。
		return {}
	if phrase_id <= 0 and text.is_empty():
		return {}
	return {
		"slot": slot,
		"name": speaker_name(slot, local_slot, profiles, self_profile, en),
		"mine": slot == local_slot,
		"enemy": local_slot >= 0 and slot >= 0
			and GameConstants.team_of_slot(slot) != GameConstants.team_of_slot(local_slot),
		"team_only": team_only,
		"phrase_id": maxi(phrase_id, 0),
		"text": text if phrase_id <= 0 else "",
		"round": maxi(match_round, 0),
	}


static func speaker_name(slot: int, local_slot: int, profiles: Dictionary, self_profile: Dictionary,
		en: bool) -> String:
	var who := ""
	if slot == local_slot:
		# 自己的资料不在 team_seat_profiles 里（那张表是别人广播过来的）。
		who = str(self_profile.get("player_name", "")).strip_edges()
	else:
		var identity: Dictionary = profiles.get(slot, profiles.get(str(slot), {}))
		who = str(identity.get("player_name", "")).strip_edges()
	if not who.is_empty():
		return who
	# 空名字会让这条消息看起来像是没有人说的。
	var seat: String = SEAT_LABELS[slot] if slot >= 0 and slot < SEAT_LABELS.size() else "?"
	return ("Seat " + seat) if en else ("席位" + seat)


# 界面上显示的那一行：「【对方】小林：稳住」。短语按**显示时**的语言查表，名字用记下来的。
static func line_text(entry: Dictionary, en: bool) -> String:
	var body := str(entry.get("text", ""))
	var phrase_id := int(entry.get("phrase_id", 0))
	if phrase_id > 0:
		body = ChatPhrases.text(phrase_id)
	var tag := ""
	# 大厅（round 0）只有「全部」一个范围、队伍也没定，不标。
	if int(entry.get("round", 0)) > 0 and not bool(entry.get("team_only", false)):
		if bool(entry.get("enemy", false)):
			tag = TAG_ENEMY_EN if en else TAG_ENEMY
		else:
			tag = TAG_ALL_EN if en else TAG_ALL
	return "%s%s：%s" % [tag, str(entry.get("name", "")), body]


# 记录里的回合分隔线。
static func round_label(match_round: int, en: bool) -> String:
	if match_round <= 0:
		return "Room" if en else "房间"
	return ("Round %d" % match_round) if en else ("第 %d 回合" % match_round)
