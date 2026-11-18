extends RefCounted
## 战斗排名奖励（11-18 用户定）。战斗服务器结算发钱、客户端榜单 / 钱袋显示，都只认这里。
##
## PvP（不含第 21 回合）：按这一场每个座位打出的伤害排，前三名 150 / 100 / 50。
##   伤害 = 回放 frame_slot_damage 最后一帧（打怪溢出的部分本来就不算，见 DamageService）。
##   同伤害：先打到这个数的人在前；再一样按座位号。伤害为 0 的不上榜。6 个座位不分队，AI 座位也算。
## 打怪 / Boss：按清完自己那条路的先后排，前三名 50 / 30 / 10。没清完的不上榜。
##   帧号来自两队各自回放的 lane_clear_ticks（BattleSimulator._replay_track_lane_clears）；
##   两队的模拟同一个时钟，帧号可以直接比。同一帧清完按座位号。
## 第 21 回合是最后一回合，钱没处花，不发（也不显示钱袋）。
## 结算顺序：排名奖励加在利息**之后**，不生利息（EconomyService.settle_post_battle_breakdown 第 10 步）。

const PVP_REWARDS := [150, 100, 50]
const LANE_REWARDS := [50, 30, 10]
const SHOWN := 3
const SLOTS := 6


static func rewards_for_kind(kind: String) -> Array:
	match kind:
		"pvp":
			return PVP_REWARDS
		"pve", "boss":
			return LANE_REWARDS
	return []


## PvP 名次：[{slot, damage}]，最多三个，已按名次排好。
static func pvp_damage_ranking(frame_slot_damage: Array) -> Array:
	if frame_slot_damage.is_empty() or not (frame_slot_damage[-1] is Array):
		return []
	var final: Array = frame_slot_damage[-1]
	var rows: Array = []
	for slot in SLOTS:
		var damage := int(final[slot]) if slot < final.size() else 0
		if damage <= 0:
			continue
		# 先到者：第一次达到最终伤害的那一帧。
		var reached := frame_slot_damage.size() - 1
		for i in frame_slot_damage.size():
			var frame: Variant = frame_slot_damage[i]
			if frame is Array and slot < (frame as Array).size() and int(frame[slot]) >= damage:
				reached = i
				break
		rows.append([damage, reached, slot])
	rows.sort_custom(func(a, b) -> bool:
		if a[0] != b[0]:
			return a[0] > b[0]
		if a[1] != b[1]:
			return a[1] < b[1]
		return a[2] < b[2])
	var out: Array = []
	for row in rows.slice(0, SHOWN):
		out.append({"slot": int(row[2]), "damage": int(row[0])})
	return out


## 把两队回放的 lane_clear_ticks 合成一份 6 座位的帧号（没清完 = -1）。
static func merged_clear_ticks(replays: Array) -> Array:
	var out: Array = [-1, -1, -1, -1, -1, -1]
	for replay in replays:
		if not (replay is Dictionary):
			continue
		var ticks: Variant = (replay as Dictionary).get("lane_clear_ticks", [])
		if not (ticks is Array):
			continue
		for slot in mini(SLOTS, (ticks as Array).size()):
			var t := int(ticks[slot])
			if t >= 0:
				out[slot] = t
	return out


## 清路名次：[{slot, tick}]，最多三个。up_to_tick >= 0 时只算到那一帧为止已经清完的（战斗中播放用）。
static func lane_clear_ranking(clear_ticks: Array, up_to_tick := -1) -> Array:
	var rows: Array = []
	for slot in mini(SLOTS, clear_ticks.size()):
		var t := int(clear_ticks[slot])
		if t < 0 or (up_to_tick >= 0 and t > up_to_tick):
			continue
		rows.append([t, slot])
	rows.sort_custom(func(a, b) -> bool:
		if a[0] != b[0]:
			return a[0] < b[0]
		return a[1] < b[1])
	var out: Array = []
	for row in rows.slice(0, SHOWN):
		out.append({"slot": int(row[1]), "tick": int(row[0])})
	return out


## 这一回合每个座位拿多少排名奖励：{slot: gold}，没拿的不在里面。
## replays = [A 队回放, B 队回放]；PvP 两份是同一场，用哪份都一样。
static func rewards_by_slot(kind: String, replays: Array) -> Dictionary:
	var rewards := rewards_for_kind(kind)
	var ranking: Array = []
	match kind:
		"pvp":
			for replay in replays:
				if replay is Dictionary and not ((replay as Dictionary).get("frame_slot_damage", []) as Array).is_empty():
					ranking = pvp_damage_ranking((replay as Dictionary).get("frame_slot_damage", []))
					break
		"pve", "boss":
			ranking = lane_clear_ranking(merged_clear_ticks(replays))
	var out := {}
	for rank in mini(ranking.size(), rewards.size()):
		out[int(ranking[rank].slot)] = int(rewards[rank])
	return out


## 某个座位在名单里的名次（0 起），不在返回 -1。
static func rank_of(ranking: Array, slot: int) -> int:
	for i in ranking.size():
		if int(ranking[i].get("slot", -1)) == slot:
			return i
	return -1
