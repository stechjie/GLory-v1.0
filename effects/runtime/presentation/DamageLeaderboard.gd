extends Control
## PvP 战斗左边的「伤害前三」。6 个座位不分队一起排，前三名各一块木牌（DamageRankCard）。
## 第一名原尺寸，第二、三名缩到 RANK_SCALE。超车时木牌滑到新位置并亮一下。
## 本地玩家不在前三时，下面多一块小木牌「你 · 第 N 名」，保证随时看得到自己的数。
##
## 火只烧在第一名身上，大小按第一名的伤害档位（用户 11-18 定）。
## 打怪 / Boss 局右边的清路榜是另一套（LaneClearBoard），不共用。
##
## 这里只管显示。名次和奖励的真相在战斗服务器（结算按同一份按座位数据、不带滞回），
## 战斗结束时调用方要用 exact=true 刷一次，让屏幕上的名次和到账的金币对得上。

const Card := preload("res://effects/runtime/presentation/DamageRankCard.gd")
const Feedback := preload("res://effects/runtime/presentation/BattleCombatFeedback.gd")
const Presentation := preload("res://effects/runtime/presentation/PresentationSettings.gd")
const Tokens := preload("res://ui/theme/GloryTokens.gd")

const SHOWN := 3
const RANK_SCALE := [1.0, 0.78, 0.78]
const RANK_GAP := 6.0
## 「你 · 第 N 名」那块小牌的缩放。
const ME_SCALE := 0.66
## 战斗中要领先对方这么多才换位，避免两人咬得很近时木牌来回跳。结束时不看这个。
const OVERTAKE_MARGIN := 0.03
const SLIDE_SEC := 0.35
const MAX_LEVEL := 6.0
const ME_CAPTION_COLOR := Color("ffe7a8")

## 前三名的奖励金币。
var rewards: Array = [150, 100, 50]

var _cards: Dictionary = {}          # slot -> DamageRankCard
var _order: Array = []               # 当前显示用的名次（含不在前三的人）
var _rank_of: Dictionary = {}        # slot -> 上次的名次，判断谁超车了
var _leader := -1
var _leader_tier := 0
var _me_card: Control


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	_me_card = Card.new()
	_me_card.scale = Vector2.ONE * ME_SCALE
	_me_card.hide()
	add_child(_me_card)


static func _rank_y(rank: int) -> float:
	var y := 0.0
	for i in range(mini(rank, SHOWN)):
		y += Card.CARD_SIZE.y * float(RANK_SCALE[i]) + RANK_GAP
	return y


## entries：{slot, name, avatar, frame, team, damage}，6 个座位都给（没伤害的给 0）。
## exact=true：严格排（战斗结束 / 跳到结尾时用），不看换位门槛。
func update_entries(entries: Array, local_slot: int, round_index: int, animate := true, exact := false) -> void:
	var by_slot: Dictionary = {}
	for e in entries:
		by_slot[int((e as Dictionary).get("slot", -1))] = e
	_order = _rank(by_slot, exact)
	var visible_slots: Array = []
	for s in _order:
		if visible_slots.size() >= SHOWN:
			break
		if _damage_of(by_slot[s]) > 0:
			visible_slots.append(s)
	# 掉出前三的牌淡出后释放。
	for s in _cards.keys():
		if not visible_slots.has(s):
			_retire(_cards[s], animate)
			_cards.erase(s)
	for rank in visible_slots.size():
		var s: int = visible_slots[rank]
		var e: Dictionary = by_slot[s]
		var card: Control = _cards.get(s)
		var fresh := card == null
		if fresh:
			card = Card.new()
			add_child(card)
			_cards[s] = card
			# 新上榜：从第三名下面一点淡入滑上来。
			var start_scale := float(RANK_SCALE[SHOWN - 1]) if animate else float(RANK_SCALE[rank])
			card.position = Vector2(0, _rank_y(SHOWN) + 12 if animate else _rank_y(rank))
			card.scale = Vector2.ONE * start_scale
			card.modulate.a = 0.0 if animate else 1.0
		card.set_player(s, str(e.get("name", "")), str(e.get("avatar", "")), str(e.get("frame", "")), int(e.get("team", 0)))
		card.set_reward(int(rewards[rank]) if rank < rewards.size() else 0)
		var damage := _damage_of(e)
		card.set_damage(damage, _accent(Feedback.damage_tier(damage, round_index), round_index), animate)
		card.z_index = SHOWN - rank
		var moved_up: bool = _rank_of.has(s) and rank < int(_rank_of[s]) and not fresh
		_place(card, rank, animate)
		if moved_up and animate:
			card.flash_overtake()
	_refresh_flame(by_slot, visible_slots, round_index, animate)
	_rank_of.clear()
	for rank in visible_slots.size():
		_rank_of[visible_slots[rank]] = rank
	_refresh_me(by_slot, local_slot, visible_slots, round_index)


## 这个座位的木牌在屏幕上的位置（数字牌中间），前三名奖励金币从这里飞进钱袋。不在榜上返回 null。
func anchor_global(slot: int) -> Variant:
	var card: Control = _cards.get(slot)
	if card == null:
		return null
	var local := Vector2(Card.PAD_LEFT + Card.PLATE_SIZE.x * 0.55, Card.PLATE_SIZE.y * 0.6)
	return card.get_global_transform() * local


func reset() -> void:
	for s in _cards:
		(_cards[s] as Control).queue_free()
	_cards.clear()
	_order.clear()
	_rank_of.clear()
	_leader = -1
	_leader_tier = 0
	if _me_card != null:
		_me_card.hide()


func _damage_of(e: Dictionary) -> int:
	return maxi(0, int(e.get("damage", 0)))


## 战斗中后面的人要多出 OVERTAKE_MARGIN 才换上去。
func _overtakes(back: Dictionary, front: Dictionary) -> bool:
	var b := _damage_of(back)
	return b > 0 and float(b) > float(_damage_of(front)) * (1.0 + OVERTAKE_MARGIN)


func _rank(by_slot: Dictionary, exact: bool) -> Array:
	var order: Array = []
	for s in _order:
		if by_slot.has(s):
			order.append(s)
	var newcomers: Array = []
	for s in by_slot:
		if not order.has(s):
			newcomers.append(s)
	newcomers.sort()
	order.append_array(newcomers)
	if exact:
		# 同分保持原来的先后（先到的在前）；没有先后的按座位号。
		var previous := order.duplicate()
		order.sort_custom(func(a, b) -> bool:
			var sa := _damage_of(by_slot[a])
			var sb := _damage_of(by_slot[b])
			if sa != sb:
				return sa > sb
			return previous.find(a) < previous.find(b))
		return order
	# 带门槛的冒泡。
	var swapped := true
	var guard := 0
	while swapped and guard < 64:
		swapped = false
		guard += 1
		for i in range(order.size() - 1):
			if _overtakes(by_slot[order[i + 1]], by_slot[order[i]]):
				var tmp = order[i]
				order[i] = order[i + 1]
				order[i + 1] = tmp
				swapped = true
	return order


func _accent(tier: int, round_index: int) -> Color:
	var early := round_index >= 1 and round_index <= 10
	return Feedback.EARLY_DAMAGE_COLORS[tier] if early else Feedback.DAMAGE_COLORS[tier]


# 火跟着第一名走；火的大小按第一名的伤害档位（用户 11-18 定）。
func _refresh_flame(by_slot: Dictionary, visible_slots: Array, round_index: int, animate: bool) -> void:
	var leader: int = visible_slots[0] if not visible_slots.is_empty() else -1
	var leader_tier := 0
	if leader >= 0:
		leader_tier = Feedback.damage_tier(_damage_of(by_slot[leader]), round_index)
	var early := round_index >= 1 and round_index <= 10
	var promoted := leader_tier > 0 and (leader_tier > _leader_tier or leader != _leader)
	for s in _cards:
		var card: Control = _cards[s]
		if s == leader and leader_tier > 0:
			var level := minf(float(leader_tier) * (1.5 if early else 1.0), MAX_LEVEL)
			card.set_flame(level, float(leader_tier) * (1.5 if early else 1.0), _accent(leader_tier, round_index), promoted and animate)
		else:
			card.set_flame(0.0, 0.0, Color.WHITE, false)
	_leader = leader
	_leader_tier = leader_tier


func _place(card: Control, rank: int, animate: bool) -> void:
	var target_scale := Vector2.ONE * float(RANK_SCALE[rank])
	var target_pos := Vector2(0, _rank_y(rank))
	var tween_key := "_slide_tween"
	var old: Tween = card.get_meta(tween_key) if card.has_meta(tween_key) else null
	if card.position.is_equal_approx(target_pos) and card.scale.is_equal_approx(target_scale) and card.modulate.a >= 1.0:
		return
	if old != null and old.is_valid():
		old.kill()
	if not animate or not _motion_allowed():
		card.position = target_pos
		card.scale = target_scale
		card.modulate.a = 1.0
		return
	var tween := card.create_tween().set_parallel(true)
	tween.tween_property(card, "position", target_pos, SLIDE_SEC).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(card, "scale", target_scale, SLIDE_SEC).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(card, "modulate:a", 1.0, SLIDE_SEC * 0.6)
	card.set_meta(tween_key, tween)


func _retire(card: Control, animate: bool) -> void:
	if not animate or not _motion_allowed():
		card.queue_free()
		return
	card.z_index = 0
	var tween := card.create_tween().set_parallel(true)
	tween.tween_property(card, "modulate:a", 0.0, 0.25)
	tween.tween_property(card, "position:y", card.position.y + 16.0, 0.25)
	tween.chain().tween_callback(card.queue_free)


# 自己不在前三：前三下面挂一块小木牌，标题牌写「你 · 第 N 名」，数字牌照常显示自己的数。
func _refresh_me(by_slot: Dictionary, local_slot: int, visible_slots: Array, round_index: int) -> void:
	if local_slot < 0 or visible_slots.has(local_slot) or not by_slot.has(local_slot):
		_me_card.hide()
		return
	var e: Dictionary = by_slot[local_slot]
	var rank := _order.find(local_slot) + 1
	_me_card.set_player(local_slot, "", str(e.get("avatar", "")), str(e.get("frame", "")), int(e.get("team", 0)))
	var english := LocaleManager.get_locale().begins_with("en")
	# 小牌整块缩到 ME_SCALE，标题字放大一点抵掉，保证手机上看得清。
	_me_card.set_caption(("You · #%d" if english else "你 · 第%d名") % rank, ME_CAPTION_COLOR, 19)
	_me_card.set_reward(0)
	var damage := _damage_of(e)
	_me_card.set_damage(damage, _accent(Feedback.damage_tier(damage, round_index), round_index), false)
	_me_card.position = Vector2(0, _rank_y(visible_slots.size()) + 2.0)
	_me_card.show()


func _motion_allowed() -> bool:
	return not Presentation._toggle("reduced_motion") and not Tokens.reduced_motion()
