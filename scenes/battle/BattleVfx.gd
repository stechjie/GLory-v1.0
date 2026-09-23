extends "res://scenes/battle/BattleRenderer.gd"

const RANGED_ATTACK_MIN_RANGE_PX := 135.0
const _SkillVFXConfig := preload("res://effects/SkillVFXConfig.gd")
# 9.19：人王奖励判定要读 `max_stacks` 上限，必须经 `apply_star_stats` 取
# （star4 覆写：1~3 星 5 层 / 4 星 8 层），与 Main._grow_human_king 同一条路。
# 本仓惯例是 preload 常量而不是裸全局类名。
const _UnitFactoryRef := preload("res://scripts/units/UnitFactory.gd")

var _vfx_prev_units: Dictionary = {}
var _vfx_seeded: bool = false
var _vfx_visual_event_index := 0
var _persistent_unit_vfx: Dictionary = {}
# 9.19：四星末日守卫（skill_id = shared_hp_link 血契连线）的技能音**只在开始释放时播一次**。
#
# 该技能是一次性的（命中后 `_skill_shared_hp_link` 置 `shared_link_spent` 后直接 return），
# 但模拟器每轮仍会执行 `caster.skill_ready = state.elapsed + 1.0`
# （BattleSimulator.gd:896-898，shared_hp_link 分支固定 +1.0）——
# 于是 `_play_skill_cast_vfx` 的「skill_ready 上升沿」判定**每秒都会再满足一次**，
# 音效跟着每一秒重响一声（即用户说的「后续链接效果也在播」）。
# 这里按 sim_uid 记「这一只已经响过」，后续链接/续期不再播。
# 每局开始由 BattleScreen._start_replay() 清空。
var _doom_skill_sfx_played: Dictionary = {}
# 9.20 第三批：寄生灵的分身（uid 形如 `player_parasite_3`）**只在它首次活着出现**
# 的那一帧报一次。不能只判「新 uid」—— 回放的 roster 会把战斗中段才出生的分身
# 提前塞进 `_state`（alive=false），于是「进演示的第一帧」会被误判成召唤时刻
# （用户实测：寄生灵的音在开局就响）。每局开始由 BattleScreen 清空。
var _parasite_spawn_announced: Dictionary = {}
# D4: bodies of slice units whose death cue has been enqueued but not played yet.
# The renderer prunes a dead model on the next refresh, which is faster than the
# death cue can be reached when the victim was mid-swing (checklist 4.3 keeps the
# in-flight action). Claiming the actor at enqueue time is what gives the death
# animation something to play on.
var _cue_corpses: Dictionary = {}
# Actors that already entered the fade. They are tracked separately so skip,
# seek, restart and scene shutdown can release both queued and playing deaths.
# Instance id is the key because summons may reuse a uid before the old body has
# finished fading.
var _active_death_actors: Dictionary = {}
# A queued claim normally becomes an active death within one short action beat.
# If its cue is rejected or cancelled, this watchdog is the final ownership
# handoff: no claimed body or 2D bar may remain on the battlefield forever.
const DEATH_CLAIM_WATCHDOG_SEC := 2.0
var _death_claim_serial := 0
var _pending_death_claim_tokens: Dictionary = {}

# Floating damage/heal/shield numbers. A fixed pool of Labels is recycled round-
# robin so fast fights never churn the scene tree (see vfx-mobile-pass).
const _HIT_NUMBER_POOL_SIZE := 32
var _hit_number_layer: Control = null
var _hit_number_pool: Array[Label] = []
var _hit_number_cursor := 0
# 快照双缓冲：帧间 diff 需要 prev 和 current 两份，所以用两个缓冲区乒乓切换、
# 原地改写字典键值，避免每帧每单位新建 34 键字典（20 个单位就是每帧 ~700 条堆分配）。
# 安全前提：没有任何地方跨帧持有单帧的单位字典（已核实：apocalypse 走 duplicate，
# death/damage 事件只拷字段）。
var _vfx_snap_a: Dictionary = {}
var _vfx_snap_b: Dictionary = {}
var _vfx_snap_use_b := false
var _vfx_seen_ids: Dictionary = {}

func _refresh_visuals() -> void:
	super._refresh_visuals()
	_refresh_battle_vfx(_state)

func _update_vfx_camera_shake() -> void:
	pass

func _refresh_battle_vfx(state_snapshot: Dictionary) -> void:
	var current := _collect_vfx_units(state_snapshot)
	_sync_persistent_unit_vfx(current)
	_play_visual_events(state_snapshot,current)
	if not _vfx_seeded:
		_play_opening_unit_vfx(current)
		_vfx_prev_units = current
		_vfx_seeded = true
		return

	var damage_events: Array[Dictionary] = []
	var death_events: Array[Dictionary] = []
	var apocalypse_ended: Array[Dictionary] = []

	for id: String in current.keys():
		var now: Dictionary = current[id]
		var prev: Dictionary = _vfx_prev_units.get(id, {})
		# 9.20：寄生灵的分身在**它首次活着出现**的那一帧报一次。
		# 放在 `prev.is_empty()` 判断**之外**：回放的 roster 会把分身提前放进
		# `_state`（alive=false），所以它「真正出生」那一帧的 prev 并不为空，
		# 按「新 uid」判会漏；反过来按这个判则不会被「进演示第一帧」骗到。
		if id.contains("_parasite_"):
			_announce_parasite_clone(id, now)
		if prev.is_empty():
			if _vfx_seeded and str(now.get("skill_id", "")) == "twin_revive":
				_play_boss_procedural("twin_revive", now.get("world_foot", Vector3.ZERO), now.get("world_foot", Vector3.ZERO))
			if _vfx_seeded and id.contains("_mirror_"):
				_play_boss_procedural("mirror_spawn", now.get("world_foot", Vector3.ZERO), now.get("world_foot", Vector3.ZERO))
			continue
		var hp_delta := int(now.get("hp", 0)) - int(prev.get("hp", 0))
		var shield_delta := int(now.get("shield", 0)) - int(prev.get("shield", 0))
		var stack_delta := int(now.get("skill_stacks", 0)) - int(prev.get("skill_stacks", 0))
		var sid_now := str(now.get("skill_id", ""))
		if hp_delta < 0:
			var critical := -hp_delta >= maxi(35, int(round(float(maxi(1, int(now.get("max_hp", 1)))) * 0.24)))
			damage_events.append({
				"id": id,
				"pos": now.get("hit_pos", Vector2.ZERO),
				"hit_pos": now.get("hit_pos", Vector2.ZERO),
				"head_pos": now.get("head_pos", Vector2.ZERO),
				"foot_pos": now.get("foot_pos", Vector2.ZERO),
				"world_hit": now.get("world_hit", Vector3.ZERO),
				"world_head": now.get("world_head", Vector3.ZERO),
				"world_foot": now.get("world_foot", Vector3.ZERO),
				"model_node": now.get("model_node"),
				"team": str(now.get("team", "")),
				"lane": int(now.get("lane", -1)),
				"critical": critical,
			})
		elif hp_delta > 0:
			if sid_now == "blood_rage" and bool(now.get("blood_rage_active", false)):
				var blood_source := _nearest_enemy_target(now, damage_events, current)
				_play_boss_procedural("blood_lifesteal", now.get("world_foot", Vector3.ZERO), blood_source.get("world_hit", now.get("world_foot", Vector3.ZERO)), _boss_target_context(blood_source))
			else:
				# Healing is rendered by the 3D unit composer. Do not layer the
				# legacy 2D HOLY_HEAL ring on top of it.
				pass
		if shield_delta > 0:
			# The legacy 2D HOLY_SHIELD overlay is retired. Shield presentation is
			# owned by the new-material status/skill routes, so the old blue disc
			# can never be layered over them.
			# Shield gain is unambiguous from the HP-diff (shield only rises on grant),
			# so its number comes straight off the delta rather than a sim event.
			_spawn_hit_number(now.get("head_pos", Vector2.ZERO), shield_delta, "shield", false, false)
		if stack_delta > 0 and sid_now in ["rage_stack", "same_target_damage_stack"]:
			if sid_now == "rage_stack":
				var rage_stacks := int(now.get("skill_stacks", 0))
				var rage_target := _nearest_enemy_target(now, damage_events, current)
				if rage_stacks > 0 and rage_stacks % 5 == 0:
					_play_boss_procedural("rage_milestone", now.get("world_foot", Vector3.ZERO), rage_target.get("world_foot", now.get("world_foot", Vector3.ZERO)), _boss_target_context(rage_target, {"stacks": rage_stacks}))
				else:
					_play_boss_procedural("rage_stack", now.get("world_foot", Vector3.ZERO), now.get("world_foot", Vector3.ZERO), {"stacks": rage_stacks})
			else:
				_spawn_vfx("GROWTH_AURA", now.get("foot_pos", Vector2.ZERO))
				var linked_uid := str(now.get("linked_target_uid", ""))
				var linked_target:Dictionary = current.get(linked_uid, now) if not linked_uid.is_empty() else now
				# The queen's stacks are real data (skill_stacks); the visuals use
				# them to pick the fissure tier and the fourth-stack rupture.
				_play_unit_procedural("same_target_damage_stack", now.get("world_foot", Vector3.ZERO), linked_target.get("world_hit", linked_target.get("world_foot", now.get("world_foot", Vector3.ZERO))), _unit_target_context(now, linked_target, {"stacks": int(now.get("skill_stacks", 0))}))
		if stack_delta > 0 and sid_now == "poison_reflect_armor_stack":
			_play_unit_procedural("poison_reflect_armor_stack", now.get("world_foot", Vector3.ZERO), now.get("world_foot", Vector3.ZERO), _unit_target_context(now, now))
		if sid_now == "overload_counter" and stack_delta > 0:
			_play_boss_procedural("overload_stack", now.get("world_cast", Vector3.ZERO), now.get("world_foot", Vector3.ZERO))
		elif sid_now == "overload_counter" and stack_delta < 0:
			var overload_target := _nearest_enemy_target(now, damage_events, current)
			var overload_world: Vector3 = overload_target.get("world_foot", now.get("world_foot", Vector3.ZERO))
			_play_boss_procedural("overload_counter", now.get("world_cast", Vector3.ZERO), overload_world, _boss_target_context(overload_target))
			# 9.23 第五批：雷怒核心的技能音 —— 用户口径「**触发技能造成伤害时**播放音效，
			# 而不是开局播放」。
			#
			# 判据就是这一格：层数（`skill_stacks`）由 8 落回 0。`_apply_defender_reaction`
			# 里那条反击是**唯一**会把层数清零的地方（见 BattleSimTreasures.gd 的
			# `target.skill_stacks = 0`，紧跟着 `apply_damage(attacker, skill_damage)`），
			# 所以「落回 0」≡「反击真的打出去了」。
			#
			# ★ 为什么这一条不走模拟器的 `sfx_proc` 事件：层数本来就会过回放边界
			#   （`_replay_capture_frame` 的第 9 列 = skill_stacks），这一格已经是
			#   精确时刻，再补一条事件是重复信息。
			# ★ 事件沿用 `_maybe_play_boss_skill_proc()` 这一个消费口（而不是在这里直接
			#   查表 / 直接 play），免得「boss 真事件音」出现第二个派发点。
			_maybe_play_boss_skill_proc({
				"type": "sfx_proc", "skill_id": "overload_counter",
				"source_uid": str(now.get("sim_uid", "")),
			})
		var prev_ratio := float(prev.get("hp", 0)) / float(maxi(1, int(prev.get("max_hp", 1))))
		var now_ratio := float(now.get("hp", 0)) / float(maxi(1, int(now.get("max_hp", 1))))
		if sid_now == "blood_rage" and prev_ratio > 0.35 and now_ratio <= 0.35:
			_play_boss_procedural("blood_rage", now.get("world_foot", Vector3.ZERO), now.get("world_foot", Vector3.ZERO))
		if sid_now == "twin_revive" and not bool(prev.get("alive", true)) and bool(now.get("alive", false)):
			_play_boss_procedural("twin_revive", now.get("world_foot", Vector3.ZERO), now.get("world_foot", Vector3.ZERO))
			# 9.23 第五批：双生守门人**复活**那一帧的音（用户没点名，但它是同一类
			# 「登记了素材、却挂在一个不存在的边沿上」的死音：`twin_revive` 同样不在
			# `_tick_skills` 的 match 里，所以 9.22 那条施法边沿派发对它也从没生效过）。
			# 触发点与上面那行演出**同一格**（`alive` 由假转真），`alive` 过回放边界。
			_maybe_play_boss_skill_proc({
				"type": "sfx_proc", "skill_id": "twin_revive",
				"source_uid": str(now.get("sim_uid", "")),
			})
		var prev_apocalypse := bool(prev.get("apocalypse_charging", false))
		var now_apocalypse := bool(now.get("apocalypse_charging", false))
		if sid_now == "apocalypse_charge" and not prev_apocalypse and now_apocalypse:
			_play_boss_procedural("apocalypse_charge", now.get("world_foot", Vector3.ZERO), now.get("world_foot", Vector3.ZERO))
			# 9.23 第五批：**音效搬走了**。整段 apocalypse 判据（含下面那个收口）
			# 依赖 `apocalypse_charging`，而它 = `f.has("apocalypse_due")` ——
			# `apocalypse_due` **不过回放边界**（`_replay_capture_frame` 只打包 13 个
			# 数值列，`_load_replay_roster` 也只建固定那一组键），所以整段在真实
			# 3v3 路径（回放播放）上是**死代码**：9.22 那三条音一次都没响过，
			# 用户报的「灭世裁决者技能音效未生效」正是这一条。
			# 蓄力/完成/打断三拍现在由模拟器在 `_process_boss_charges` /
			# `_tick_skills` 里补 `sfx_proc` 事件（skill_id = apocalypse_charge /
			# apocalypse_impact / apocalypse_stop），过回放边界，由
			# `_maybe_play_boss_skill_proc()` 消费。
			# ★ 这里**只留演出**，不要再往这一格加 play/stop —— 那会变成第二条派发路径。
			#   （演出本身在回放路径上也是死的，属另一个待办，见 docs 记录。）
		elif sid_now == "apocalypse_charge" and prev_apocalypse and not now_apocalypse:
			var apocalypse_result := now.duplicate(true)
			apocalypse_result["charge_completed"] = float(state_snapshot.get("elapsed", 0.0)) + 0.05 >= float(prev.get("apocalypse_due", INF))
			apocalypse_ended.append(apocalypse_result)
		var prev_skill_ready := float(prev.get("skill_ready", 0.0))
		var now_skill_ready := float(now.get("skill_ready", 0.0))
		if now_skill_ready > prev_skill_ready + 0.1:
			_play_skill_cast_vfx(now, prev, damage_events, current)
		if bool(prev.get("alive", true)) and not bool(now.get("alive", true)):
			death_events.append({"pos": now.get("foot_pos", Vector2.ZERO), "world_foot": now.get("world_foot", Vector3.ZERO), "world_hit": now.get("world_hit", Vector3.ZERO), "killer_team": _opposite_team(str(now.get("team", ""))), "killer_uid": str(now.get("killer_uid", "")), "mother_execute_kill": bool(now.get("mother_execute_kill", false)), "model_node": now.get("model_node"), "victim_id": id})
			if sid_now == "twin_revive":
				var partner := _living_twin_partner(now, current)
				if not partner.is_empty():
					_play_boss_procedural("twin_timer", now.get("world_foot", Vector3.ZERO), partner.get("world_foot", now.get("world_foot", Vector3.ZERO)), _boss_target_context(partner))
			_spawn_vfx("DEATH_EXPLOSION", now.get("foot_pos", Vector2.ZERO))
			if sid_now == "death_poison_explosion":
				_play_unit_procedural("death_poison_explosion", now.get("world_foot", Vector3.ZERO), now.get("world_foot", Vector3.ZERO), _unit_target_context(now, now))
				# 9.20：自爆灵（`undead_bomb`）的四星技能音 —— 用户口径
				# 「死亡爆炸时」响，所以挂在这条死亡爆炸分支里（它的技能就是这一爆，
				# 模拟器里没有 skill_ready 边沿可挂）。归属与星级门控在这里判：
				# `id` 是这只自爆灵自己的 sim uid，此刻它还在 `current` 里，
				# 所以 `_is_own_or_ally_unit` 的快照一路能查到它的 owner_slot。
				_maybe_play_bomb_skill_sfx(id)

	for id: String in _vfx_prev_units.keys():
		if current.has(id):
			continue
		var prev_missing: Dictionary = _vfx_prev_units[id]
		_spawn_vfx("DEATH_EXPLOSION", prev_missing.get("foot_pos", Vector2.ZERO))
		if bool(prev_missing.get("mother_execute_kill", false)):
			death_events.append({"pos": prev_missing.get("foot_pos", Vector2.ZERO), "world_foot": prev_missing.get("world_foot", Vector3.ZERO), "world_hit": prev_missing.get("world_hit", Vector3.ZERO), "killer_uid": str(prev_missing.get("killer_uid", "")), "mother_execute_kill": true, "model_node": prev_missing.get("model_node"), "victim_id": id})

	for apocalypse: Dictionary in apocalypse_ended:
		var affected := _boss_damage_events_for_lane(apocalypse, damage_events)
		# 9.23 第五批：这里原本有 `stop_cue(蓄力音)` + 「完成」那一支的 play。
		# 三条音全部搬到 `sfx_proc` 事件通道了（理由见上面蓄力那一格的注释）：
		# 收口在 `BOSS_EVENT_ACTIONS["apocalypse_stop"] / ["apocalypse_impact"]` 的
		# `stop` 字段里表达，比这里「放在两个 if 之前」的位置约定更结实 ——
		# 那条约定的目的是「蓄力完成了但没打到人」那一档也要收口，
		# 而模拟器现在分得清「打了人」（apocalypse_impact）与「没打到人」
		# （apocalypse_stop），两档都带 `stop`，不再依赖 if 的排列。
		if not bool(apocalypse.get("charge_completed", false)):
			_play_boss_procedural("apocalypse_interrupt", apocalypse.get("world_foot", Vector3.ZERO), apocalypse.get("world_foot", Vector3.ZERO))
		elif not affected.is_empty():
			var impact_positions: Array = []
			for event: Dictionary in affected:
				impact_positions.append(event.get("world_foot", Vector3.ZERO))
			_play_boss_procedural("apocalypse_complete", apocalypse.get("world_foot", Vector3.ZERO), impact_positions[0], {"targets": impact_positions})
	if not death_events.is_empty():
		for id: String in current.keys():
			var boss_now: Dictionary = current[id]
			if str(boss_now.get("skill_id", "")) == "soul_devour" and bool(boss_now.get("alive", false)):
				for death_event: Dictionary in death_events:
					if str(death_event.get("killer_uid", "")) == str(boss_now.get("sim_uid", "")):
						_play_boss_procedural("soul_devour", boss_now.get("world_foot", Vector3.ZERO), death_event.get("world_hit", boss_now.get("world_foot", Vector3.ZERO)))
	# 母灵的书统一由 mother_execute 视觉事件驱动（见 _play_visual_events），
	# 不再走这条依赖 mother_execute_kill 的死亡分支——那个标记在 team/回放模式
	# 里不会被记录，导致回放时书永远不播。事件路径单人和回放都能工作。
	#
	# D6: 普攻的起手/投射物/命中/伤害数字/死亡已全部由 BattlePresentationDirector
	# 的 cue 驱动，原先在这里按 attack_count 增量重建攻击的两条 diff 路径已删除。
	# 保留在本函数里的仍是尚未迁移的部分：护盾、层数、治疗、Boss 与种族技能演出。
	_vfx_prev_units = current

func _vfx_hit_stop_active() -> bool:
	# VFXManager is an autoload: reference it directly. The old has_node/get_node
	# pair resolved a node path twice every frame from _process.
	return VFXManager.is_hitstop_active()

func _collect_vfx_units(state_snapshot: Dictionary) -> Dictionary:
	# 取"当前不是上一帧快照"的那个缓冲区来填。prev 恒指向另一个缓冲区，
	# 所以覆盖本缓冲区时绝不会动到 prev。
	var result: Dictionary = _vfx_snap_b if _vfx_snap_use_b else _vfx_snap_a
	_vfx_snap_use_b = not _vfx_snap_use_b
	_vfx_seen_ids.clear()
	for side in ["player", "enemy"]:
		for f in state_snapshot.get(side, []):
			if typeof(f) != TYPE_DICTIONARY:
				continue
			var id := _visual_id(f)
			var sim_pos := _visual_sim_pos_for_fighter(f)
			var base_pos := _sim_to_arena(sim_pos)
			var unit_node := _unit_node_for_id(id)
			var model_node: Node3D = _unit_actor_registry.get_actor(id)
			_vfx_seen_ids[id] = true
			# 取回该 id 的字典原地改写；首见才建一次，之后帧一直复用同一个字典对象。
			# 不用 result.get(id, {})——那个默认 {} 每次调用都会构造一个丢弃的空字典，
			# 等于每帧每单位又白分配一次。
			var u: Dictionary
			if result.has(id):
				u = result[id]
			else:
				u = {}
				result[id] = u
			u["id"] = id
			u["hp"] = int(f.get("hp", 0))
			u["max_hp"] = int(f.get("max_hp", 1))
			u["shield"] = int(f.get("shield", 0))
			u["alive"] = bool(f.get("alive", true))
			u["pos"] = base_pos
			u["sim_pos"] = sim_pos
			u["foot_pos"] = _unit_anchor_global_position(unit_node, "FootAnchor", base_pos)
			u["cast_pos"] = _unit_anchor_global_position(unit_node, "CastAnchor", base_pos)
			u["hit_pos"] = _unit_anchor_global_position(unit_node, "HitAnchor", base_pos)
			u["head_pos"] = _unit_anchor_global_position(unit_node, "HeadAnchor", base_pos)
			u["world_foot"] = _unit_vfx_position(id, "FootAnchor", sim_pos, 0.08)
			u["world_cast"] = _unit_vfx_position(id, "CastAnchor", sim_pos, 0.82)
			u["world_hit"] = _unit_vfx_position(id, "HitAnchor", sim_pos, 0.72)
			u["world_head"] = _unit_vfx_position(id, "HeadAnchor", sim_pos, 1.45)
			u["model_node"] = model_node
			u["team"] = str(f.get("team", ""))
			u["owner_slot"] = int(f.get("owner_slot", -1))
			u["attack_count"] = int(f.get("attack_count", 0))
			u["range_px"] = float(f.get("range_px", 0.0))
			u["skill_ready"] = float(f.get("skill_ready", 0.0))
			u["skill_id"] = str(f.get("def", {}).get("skill_id", ""))
			u["skill_every"] = int(f.get("def", {}).get("every", 0))
			u["unit_id"] = str(f.get("id", ""))
			u["skill_stacks"] = int(f.get("skill_stacks", 0))
			u["sim_uid"] = str(f.get("uid", ""))
			u["killer_uid"] = str(f.get("killer_uid", ""))
			u["mother_execute_kill"] = bool(f.get("mother_execute_kill", false))
			u["attack_target_uid"] = str(f.get("vfx_attack_target_uid", ""))
			u["skill_target_uid"] = str(f.get("vfx_skill_target_uid", ""))
			u["lane"] = int(f.get("lane", -1))
			u["blood_rage_active"] = bool(f.get("blood_rage_active", false))
			u["apocalypse_charging"] = f.has("apocalypse_due")
			u["apocalypse_due"] = float(f.get("apocalypse_due", -1.0))
			u["twin_group_id"] = str(f.get("twin_group_id", ""))
			u["twin_member_index"] = int(f.get("twin_member_index", -1))
	# 剪掉本帧没出现的（已离场/被移除）单位的陈旧字典，否则 diff 会把它们当成还在。
	if result.size() != _vfx_seen_ids.size():
		for id in result.keys():
			if not _vfx_seen_ids.has(id):
				result.erase(id)
	return result

func _unit_vfx_position(id: String, anchor_name: String, sim_pos: Vector2, fallback_y: float) -> Vector3:
	var model_node: Node3D = _unit_actor_registry.get_actor(id)
	if model_node != null and is_instance_valid(model_node):
		var anchor := _unit_actor_registry.get_anchor(id, anchor_name)
		if anchor is Node3D:
			var anchor_global := (anchor as Node3D).global_position
			if _battle_3d_vfx_root != null and is_instance_valid(_battle_3d_vfx_root):
				return _battle_3d_vfx_root.to_local(anchor_global)
			return anchor_global
		var model_global := model_node.global_position
		if _battle_3d_vfx_root != null and is_instance_valid(_battle_3d_vfx_root):
			model_global = _battle_3d_vfx_root.to_local(model_global)
		model_global.y += fallback_y
		return model_global
	var fallback := _sim_to_world_pos(sim_pos)
	fallback.y = fallback_y
	return fallback

func _fighter_sim_pos(f: Dictionary) -> Vector2:
	var raw = f.get("pos", Vector2.ZERO)
	if raw is Vector2:
		return raw
	if typeof(raw) == TYPE_DICTIONARY:
		return Vector2(float(raw.get("x", 0.0)), float(raw.get("y", 0.0)))
	return Vector2.ZERO

func _race_from_unit_id(unit_id:String)->String:
	for race in ["god","human","dark","undead"]:
		if unit_id.begins_with(race+"_"):
			return race
	return ""

func _visual_race_from_unit_id(unit_id:String)->String:
	var race:=_race_from_unit_id(unit_id)
	if not race.is_empty():
		return race
	var key:=unit_id.to_lower()
	if key.contains("dark") or key.contains("shadow") or key.contains("demon"):
		return "dark"
	if key.contains("undead") or key.contains("wisp") or key.contains("poison") or key.contains("death"):
		return "undead"
	if key.contains("god") or key.contains("angel") or key.contains("divine"):
		return "god"
	# Mercenaries and unclassified neutral units use the restrained human
	# projectile/strike palette instead of the legacy 2D hit effects.
	return "human"

func _play_race_basic_attack(attack:Dictionary,target:Dictionary,mode:String,race:String,current:Dictionary)->void:
	var origin:Vector3=attack.get("world_cast",Vector3.ZERO)
	var target_world:Vector3=target.get("world_hit",target.get("world_foot",Vector3.ZERO))
	var source:Dictionary=current.get(str(attack.get("id","")),{})
	# The attack event is authoritative for the firing unit.  The live-unit
	# snapshot can be keyed by a different simulation id, so preserve the
	# event's unit_id here or authored per-unit projectiles silently fall back
	# to the generic race bolt.
	var context:=_unit_target_context(source,target)
	var attack_unit_id:=str(attack.get("unit_id",""))
	if not attack_unit_id.is_empty():
		context["source_unit_id"] = attack_unit_id
	_play_unit_procedural("basic_attack_%s_%s"%[mode,race],origin,target_world,context)

func _nearest_enemy_damage_event(attack: Dictionary, damage_events: Array[Dictionary]) -> Dictionary:
	var best: Dictionary = {}
	var best_dist := INF
	var attack_team := str(attack.get("team", ""))
	var attack_pos: Vector2 = attack.get("pos", Vector2.ZERO)
	for event: Dictionary in damage_events:
		if str(event.get("team", "")) == attack_team:
			continue
		var target_pos: Vector2 = event.get("pos", Vector2.ZERO)
		var dist := attack_pos.distance_squared_to(target_pos)
		if dist < best_dist:
			best_dist = dist
			best = event
	return best

func _nearest_enemy_target(source: Dictionary, damage_events: Array[Dictionary], current: Dictionary) -> Dictionary:
	for target_key in ["target_uid", "skill_target_uid", "attack_target_uid"]:
		var exact_uid := str(source.get(target_key, ""))
		if exact_uid.is_empty() or not current.has(exact_uid):
			continue
		var exact: Dictionary = current[exact_uid]
		if str(exact.get("team", "")) != str(source.get("team", "")):
			return exact
	var damaged := _nearest_enemy_damage_event(source, damage_events)
	if not damaged.is_empty():
		return damaged
	var best: Dictionary = {}
	var best_dist := INF
	var source_team := str(source.get("team", ""))
	var source_pos: Vector2 = source.get("pos", Vector2.ZERO)
	for id: String in current.keys():
		var target: Dictionary = current[id]
		if not bool(target.get("alive", true)) or str(target.get("team", "")) == source_team:
			continue
		var target_pos: Vector2 = target.get("hit_pos", target.get("pos", Vector2.ZERO))
		var dist := source_pos.distance_squared_to(target_pos)
		if dist < best_dist:
			best_dist = dist
			best = {
				"id": id,
				"pos": target_pos,
				"hit_pos": target.get("hit_pos", target_pos),
				"head_pos": target.get("head_pos", target_pos),
				"foot_pos": target.get("foot_pos", target_pos),
				"world_hit": target.get("world_hit", Vector3.ZERO),
				"world_head": target.get("world_head", Vector3.ZERO),
				"world_foot": target.get("world_foot", Vector3.ZERO),
				"model_node": target.get("model_node"),
				"team": str(target.get("team", "")),
			}
	return best

func _floor_target_for(source: Dictionary) -> Dictionary:
	var from_pos: Vector2 = source.get("pos", Vector2.ZERO)
	var dir := -1.0 if str(source.get("team", "")) == "player" else 1.0
	var floor_pos := from_pos + Vector2(0.0, 150.0 * dir)
	return {
		"id": "",
		"pos": floor_pos,
		"hit_pos": floor_pos,
		"head_pos": floor_pos,
		"foot_pos": floor_pos,
		"team": _opposite_team(str(source.get("team", ""))),
	}

func _play_skill_cast_vfx(unit: Dictionary, previous: Dictionary, damage_events: Array[Dictionary], current: Dictionary) -> void:
	var sid := str(unit.get("skill_id", ""))
	var uid := str(unit.get("unit_id", ""))
	# 9.18：四星单位施放专属技能时的音效。
	#
	# ★ 9.20 口径变更：此前是**仅自身棋子（不含队友）**才响，用户要求放宽到
	#   **自身 + 友军**。判定入口由 `_is_local_owned_unit`（owner_slot == local_slot）
	#   换成 `_is_own_or_ally_unit`（owner 与 local_slot 同队），再叠加 `star == 4`
	#   防止低星单位的普攻上升沿误触发。
	var _sim_uid := str(unit.get("sim_uid", ""))
	var _owned := _is_own_or_ally_unit(_sim_uid)
	if _owned and _is_star4(_sim_uid):
		# 9.19：末日守卫（`dark_doom`）的技能只响**一次**——它的 `shared_hp_link`
		# 是一次性技能，`_skill_shared_hp_link()` 命中 `shared_link_spent` 会直接
		# return，但模拟器末尾仍把 `caster.skill_ready` 推到 `elapsed + 1.0`
		# （BattleSimulator.gd:896-898），于是每秒都产生一次上升沿 → 连线持续期间
		# 音效被反复重播。这里按棋子记一次播放标记，后续上升沿全部跳过。
		# 判据同时认 uid 与 skill_id：uid 保证「末日守卫」本体，skill_id 保证将来
		# 若有别的单位复用该机制也不会重复响（数据里 `shared_hp_link` 目前只有它一家）。
		var once_only := uid == "dark_doom" or sid == "shared_hp_link"
		if not once_only or not _doom_skill_sfx_played.has(_sim_uid):
			if once_only:
				_doom_skill_sfx_played[_sim_uid] = true
			SfxService.play(SfxService.star4_cue_for(uid, true))
	elif _owned:
		# 9.19 第二批：佣兵专属技能音（星轨猎人 / 泡沫术士 / 圣愈修女）。
		# **佣兵升不到四星**（`EconomyLedger._use_upgrade_stone` 会拒），所以
		# 它们不能并进上面那条 `_is_star4` 门 —— 并进去就是一条永远不响的音。
		# 9.20 起门控与上面同一口径：自身 + 友军（敌方天然被排除）。
		var merc_cue := SfxService.merc_skill_cue_for(uid)
		if not merc_cue.is_empty():
			SfxService.play(merc_cue)
	# 9.22：boss 技能音 —— **只剩施法边沿这一条通道**。
	#
	# ★ **不做归属门控。** 用户口径：「boss 技能音效播放，我方队友都能听见」。
	#   boss 在 3v3 里固定在场上、不属于任何玩家的 owner_slot，所以这一条独立于
	#   上面的 `_owned`（`_is_own_or_ally_unit`）与 `_is_star4` 两个分支 ——
	#   套上它们只会让它变成「永远不响」，而不是「更精确」。
	#
	# ★★ 9.23 第五批：这里改成 `boss_cast_edge_cue_for()`，**只有两只** boss 走这条路
	#   （圣愈祭司 / 天罚投星者：它们的技能确实产生 `skill_ready` 上升沿，且「施法这一下」
	#   就是用户要的那一声）。
	#
	#   其余 6 只**不能**挂在这里，9.22 的写法对它们全是错的：
	#     · 雷怒核心（overload_counter）—— 用户要的是「触发反击造成伤害时」（下面
	#       `stack_delta < 0` 那一格）；而且它不在 `_tick_skills` 的 match 里，没有上升沿；
	#     · 镜像魔君（mirror_clone）—— 要的是「召唤分身时」；它的
	#       `skill_ready = elapsed + 1.0`，挂这里就是**每秒重响一次**（用户原话「一直播放」）；
	#     · 噬魂领主（soul_devour）—— 要的是「击杀单位后」；没有上升沿；
	#     · 血怒魔王（blood_rage）—— 要的是「进入暴走那一次」；没有上升沿；
	#     · 双生守门人（twin_revive）—— 要的是「复活那一帧」（下面 alive 上升沿那条）；没有上升沿；
	#     · 灭世裁决者（apocalypse_charge）—— 蓄力/完成/打断三拍，走模拟器事件。
	#   这 6 只的音效在 SfxService.BOSS_EVENT_ACTIONS 里，由模拟器补 `sfx_proc` 事件、
	#   本文件的 `_maybe_play_boss_skill_proc()` 消费（理由见那张表上面的注释）。
	var boss_cue := SfxService.boss_cast_edge_cue_for(uid)
	if not boss_cue.is_empty():
		SfxService.play(boss_cue)
	var texture_pos: Vector2 = unit.get("cast_pos", Vector2.ZERO)
	var should_play_texture := true
	var procedural_played := false
	_play_race_unit_skill_procedural(sid, unit, previous, damage_events, current)
	match sid:
		"apocalypse_charge", "element_meteor", "mirror_clone", "holy_purify", "overload_counter", "twin_revive", "blood_rage", "soul_devour", "rage_stack":
			should_play_texture = false
			if sid == "element_meteor":
				var meteor_target := _nearest_enemy_target(unit, damage_events, current)
				var meteor_world: Vector3 = meteor_target.get("world_foot", unit.get("world_foot", Vector3.ZERO))
				_play_boss_procedural("element_meteor", unit.get("world_cast", Vector3.ZERO), meteor_world, _boss_target_context(meteor_target))
				procedural_played = true
			elif sid == "holy_purify":
				var ally_positions: Array = []
				for ally_id: String in current.keys():
					var ally: Dictionary = current[ally_id]
					if bool(ally.get("alive", false)) and str(ally.get("team", "")) == str(unit.get("team", "")):
						ally_positions.append(ally.get("world_foot", unit.get("world_foot", Vector3.ZERO)))
				_play_boss_procedural("holy_purify", unit.get("world_foot", Vector3.ZERO), unit.get("world_foot", Vector3.ZERO), {"targets": ally_positions})
				procedural_played = true
		"random_attribute_bolt", "silence_bolt":
			should_play_texture = false
			if sid == "random_attribute_bolt":
				var target_bolt := _nearest_enemy_target(unit, damage_events, current)
				if target_bolt.is_empty():
					target_bolt = _floor_target_for(unit)
				texture_pos = target_bolt.get("hit_pos", target_bolt.get("pos", texture_pos))
				_spawn_skill_textures_for_role(uid, "cast", unit.get("cast_pos", Vector2.ZERO))
				_spawn_skill_textures_for_role(uid, "hit", texture_pos)
			# The composer's four authored layers (gather / spike / seal / wrap)
			# are the whole silence presentation now; the old
			# dark_mage_magic_bolt and silence_mark plates no longer stack on top.
		"bubble_dream", "balance_judge", "gold_charge", "twin_strike", "arrow_rain", "blood_rampage", "steel_order", "time_slow", "death_hunt":
			should_play_texture = false
		"king_aura":
			# Visual-only procedural aura; never spawn the obsolete legacy PNG layer.
			should_play_texture = false
		"judgement_strike":
			should_play_texture = false
			var target_judgement := _nearest_enemy_target(unit, damage_events, current)
			if not target_judgement.is_empty():
				_spawn_skill_roles_at_target(uid, unit, target_judgement, true)
		"global_divine_blast":
			should_play_texture = false
			for event: Dictionary in _enemy_damage_events(unit, damage_events):
				_spawn_skill_roles_at_target(uid, unit, event)
		"front_cone_stun":
			should_play_texture = false
			var target_control := _nearest_enemy_target(unit, damage_events, current)
			if not target_control.is_empty():
				# The swordsman uses only the two authored, compact slash masks
				# at the confirmed hit target; no caster/ground fallback layers.
				_spawn_skill_textures_for_role(uid, "hit", target_control.get("hit_pos", target_control.get("pos", texture_pos)))
		"fear", "stun", "blink_low_def_backline":
			# Fear Demon, Succubus and Ambusher moved to authored layers; the
			# composer owns them and no legacy plate is added.
			should_play_texture = false
		"black_hole":
			should_play_texture = false
		"lowest_ally_heal", "nearby_ally_heal_buff", "holy_song", "holy_purify":
			should_play_texture = false
			# The 3D composer owns the heal presentation; the legacy 2D
			# HOLY_HEAL effect is intentionally disabled.
		"random_ally_damage_reduction":
			# Angel's Guard is now fully owned by VFXAngelGuard3D.  The legacy
			# HOLY_SHIELD 2D scene must not be layered over the new-material route.
			should_play_texture = false
		"shell_guard", "apocalypse_charge":
			should_play_texture = false
			# Do not fall back to the retired HOLY_SHIELD overlay. These skills keep
			# their own 3D composer presentation only.
		"shared_hp_link":
			should_play_texture = false
		_:
			pass
	# 叠加贴图特效（与程序效果同时显示）
	if should_play_texture:
		_play_skill_texture_vfx(unit, texture_pos)
	elif procedural_played:
		# The procedural sample owns its full staged animation; do not place a static Boss PNG on top.
		pass

func _play_boss_procedural(effect_id: String, origin_value: Variant, target_value: Variant, context: Dictionary = {}) -> Node3D:
	if _battle_3d_vfx_root == null or not is_instance_valid(_battle_3d_vfx_root):
		return null
	if not _battle_3d_vfx_root.has_method("play"):
		return null
	var world_context := context.duplicate(false)
	if world_context.has("targets"):
		var world_targets: Array = []
		for value in world_context["targets"]:
			world_targets.append(_boss_world_position(value))
		world_context["targets"] = world_targets
	return _battle_3d_vfx_root.call("play", effect_id, _boss_world_position(origin_value), _boss_world_position(target_value), world_context)

func _play_unit_procedural(effect_id:String,origin:Vector3,target:Vector3,context:Dictionary={})->Node3D:
	return _play_boss_procedural(effect_id,origin,target,context)

func _sync_persistent_unit_vfx(current:Dictionary)->void:
	for id:String in _persistent_unit_vfx.keys().duplicate():
		var unit:Dictionary=current.get(id,{})
		var record:Dictionary=_persistent_unit_vfx.get(id,{})
		var node:Variant=record.get("node")
		var uid:=str(unit.get("skill_target_uid",""))
		var active:=not unit.is_empty() and bool(unit.get("alive",false)) and str(unit.get("skill_id",""))=="shared_hp_link" and not uid.is_empty()
		if active and uid==str(record.get("target_uid","")):
			continue
		if is_instance_valid(node) and node is Node3D and node.has_method("release_link"):
			node.release_link()
		_persistent_unit_vfx.erase(id)

func _play_race_unit_skill_procedural(sid:String,unit:Dictionary,previous:Dictionary,damage_events:Array[Dictionary],current:Dictionary)->void:
	const ACTIVE_UNIT_SKILLS := [
		"lowest_ally_heal", "nearest_ally_bless", "nearby_ally_heal_buff",
		"random_attribute_bolt", "judgement_strike", "random_ally_damage_reduction",
		"global_divine_blast", "silence_bolt", "fear", "stun", "black_hole",
		"blink_low_def_backline", "shared_hp_link", "front_cone_stun",
		"bubble_dream", "shell_guard", "balance_judge", "gold_charge", "holy_song",
		"twin_strike", "king_aura", "arrow_rain", "blood_rampage", "steel_order",
		"time_slow", "death_hunt",
		# PVE 怪物与阵型盟友的主动技（都带 skill_cd，走 skill_ready 这条路）。
		# 这批以前不在名单里，所以施法时连 composer 都不会被调用到。
		"chain_lightning", "dive_backline", "heal_allies", "holy_shield_burst",
		"wind_bleed", "slow_aura", "stun_impact", "entangle", "burrow_ambush",
		"lava_burst", "nature_heal", "earth_slam", "backstab", "curse",
		"counter_slash", "burn_claw", "soul_chain", "devour_bite",
		"hell_burst", "eternal_night",
	]
	if not sid in ACTIVE_UNIT_SKILLS:
		return
	var origin:Vector3=unit.get("world_cast",unit.get("world_foot",Vector3.ZERO))
	if sid=="blink_low_def_backline":
		origin=previous.get("world_cast",previous.get("world_foot",origin))
	var exact:=_exact_skill_target(unit,current)
	var target:=exact
	if target.is_empty() and sid not in ["nearby_ally_heal_buff","global_divine_blast","black_hole"]:
		target=_nearest_enemy_target(unit,damage_events,current)
	var target_world:Vector3=target.get("world_hit",target.get("world_foot",unit.get("world_foot",Vector3.ZERO)))
	var context:=_unit_target_context(unit,target)
	if sid=="black_hole" and str(unit.get("unit_id",""))!="dark_dragon":
		return
	if sid=="shared_hp_link":
		var now_uid:=str(unit.get("skill_target_uid",""))
		if now_uid.is_empty() or now_uid==str(previous.get("skill_target_uid","")):
			return
		var old_link:Dictionary=_persistent_unit_vfx.get(str(unit.get("id","")),{})
		var old_node:Variant=old_link.get("node")
		if is_instance_valid(old_node) and old_node is Node3D and old_node.has_method("release_link"):
			old_node.release_link()
		context["persistent"]=true
	if sid=="nearby_ally_heal_buff":
		context["targets"]=_living_team_world_positions(unit,current)
		target_world=unit.get("world_foot",Vector3.ZERO)
	elif sid=="global_divine_blast":
		var enemy_targets:Array=[]
		for event in _enemy_damage_events(unit,damage_events):enemy_targets.append(event.get("world_foot",Vector3.ZERO))
		if enemy_targets.is_empty():
			for candidate_id:String in current.keys():
				var candidate:Dictionary=current[candidate_id]
				if bool(candidate.get("alive",false)) and str(candidate.get("team",""))!=str(unit.get("team","")):
					enemy_targets.append(candidate.get("world_foot",Vector3.ZERO))
		context["targets"]=enemy_targets
	elif sid=="black_hole":
		target_world=unit.get("world_foot",Vector3.ZERO)
		# Each pulled target needs a smear pointing at the centre (bible 8), so
		# hand the visuals the positions of the enemies actually affected.
		var pulled_positions:Array=[]
		for event:Dictionary in _enemy_damage_events(unit,damage_events):
			pulled_positions.append(event.get("world_foot",Vector3.ZERO))
		context["targets"]=pulled_positions
	elif sid=="random_ally_damage_reduction":
		# The presentation follows the simulator's real remaining status time, so
		# 1-3 star (6s) and 4-star (8s) guards do not share a fake visual duration.
		var statuses:Dictionary=target.get("statuses",{})
		var reduction:Dictionary=statuses.get("damage_reduction",{})
		context["status_duration"]=maxf(0.9,float(reduction.get("remaining",6.0)))
	elif sid=="bubble_dream":
		var heal_target:=_lowest_living_team_target(unit,current)
		context["heal_target"]=heal_target.get("world_foot",unit.get("world_foot",Vector3.ZERO))
	elif sid=="holy_song":
		context["targets"]=_living_team_world_positions(unit,current)
		target_world=unit.get("world_foot",Vector3.ZERO)
	elif sid=="king_aura":
		context["targets"]=_living_team_world_positions(unit,current)
		target_world=unit.get("world_foot",Vector3.ZERO)
	elif sid=="arrow_rain":
		var rain_targets:=_enemy_damage_events(unit,damage_events)
		var rain_positions:Array=[]
		for event:Dictionary in rain_targets:rain_positions.append(event.get("world_foot",Vector3.ZERO))
		context["targets"]=rain_positions
		target_world=unit.get("world_foot",Vector3.ZERO)
	elif sid=="steel_order":
		context["targets"]=_nearest_living_team_positions(unit,current,3)
		target_world=unit.get("world_foot",Vector3.ZERO)
	elif sid=="time_slow":
		context["targets"]=_living_enemy_world_positions(unit,current)
		target_world=unit.get("world_foot",Vector3.ZERO)
	# PVE 怪物与阵型盟友里的群体技，目标集合的取法和上面同类技能一致。
	elif sid in ["heal_allies","nature_heal"]:
		context["targets"]=_living_team_world_positions(unit,current)
		target_world=unit.get("world_foot",Vector3.ZERO)
	elif sid=="holy_shield_burst":
		target_world=unit.get("world_foot",Vector3.ZERO)
	# 焰爪魔灵的主动技是纯自保（回血 + 加盾都作用在自己身上），落点必须回到施法者
	# 脚下。以前它跟着默认分支指向最近的敌人，于是一个自保技把特效放在了敌人身上。
	elif sid=="burn_claw":
		target_world=unit.get("world_foot",Vector3.ZERO)
	elif sid in ["slow_aura","eternal_night"]:
		context["targets"]=_living_enemy_world_positions(unit,current)
		target_world=unit.get("world_foot",Vector3.ZERO)
	# 法阵友军的全场技（锁魂/噬兽/焚界者）：命中集合按"当场活着的敌人"取，不能走
	# damage_events。这三个当帧要么只挂状态（眩晕/沉默），要么只挂 DoT（灼烧首跳在
	# 下一 tick 才结算），施法当帧一个伤害事件都不产生——用 damage_events 会拿到空数组，
	# 逐目标的特效直接不出。origin 保持在施法者脚下，落点仍指向最近的敌人。
	elif sid in ["soul_chain","devour_bite","hell_burst"]:
		context["targets"]=_living_enemy_world_positions(unit,current)
	elif sid=="chain_lightning":
		var struck:Array=[]
		for event:Dictionary in _enemy_damage_events(unit,damage_events):
			struck.append(event.get("world_foot",Vector3.ZERO))
		context["targets"]=struck
	var spawned:=_play_unit_procedural(sid,origin,target_world,context)
	if sid=="shared_hp_link" and spawned!=null:
		_persistent_unit_vfx[str(unit.get("id",""))]={"node":spawned,"target_uid":str(unit.get("skill_target_uid",""))}

func _exact_skill_target(unit:Dictionary,current:Dictionary)->Dictionary:
	var uid:=str(unit.get("skill_target_uid",""))
	if not uid.is_empty() and current.has(uid):
		return current[uid]
	return {}

func _living_team_world_positions(unit:Dictionary,current:Dictionary)->Array:
	var result:Array=[]
	for id:String in current.keys():
		var candidate:Dictionary=current[id]
		if bool(candidate.get("alive",false)) and str(candidate.get("team",""))==str(unit.get("team","")):
			result.append(candidate.get("world_foot",Vector3.ZERO))
	return result

func _living_enemy_world_positions(unit:Dictionary,current:Dictionary)->Array:
	var result:Array=[]
	for id:String in current.keys():
		var candidate:Dictionary=current[id]
		if bool(candidate.get("alive",false)) and str(candidate.get("team",""))!=str(unit.get("team","")):
			result.append(candidate.get("world_foot",Vector3.ZERO))
	return result

func _lowest_living_team_target(unit:Dictionary,current:Dictionary)->Dictionary:
	var best:Dictionary={};var best_ratio:=INF
	for id:String in current.keys():
		var candidate:Dictionary=current[id]
		if not bool(candidate.get("alive",false)) or str(candidate.get("team",""))!=str(unit.get("team","")):continue
		var ratio:=float(candidate.get("hp",0))/float(maxi(1,int(candidate.get("max_hp",1))))
		if ratio<best_ratio:best_ratio=ratio;best=candidate
	return best

func _nearest_living_team_positions(unit:Dictionary,current:Dictionary,count:int)->Array:
	var candidates:Array=[];var source:Vector3=unit.get("world_foot",Vector3.ZERO)
	for id:String in current.keys():
		var candidate:Dictionary=current[id]
		if bool(candidate.get("alive",false)) and str(candidate.get("team",""))==str(unit.get("team","")):
			candidates.append({"distance":source.distance_squared_to(candidate.get("world_foot",source)),"position":candidate.get("world_foot",source)})
	candidates.sort_custom(func(a:Dictionary,b:Dictionary)->bool:return float(a["distance"])<float(b["distance"]))
	var result:Array=[]
	for entry in candidates.slice(0,mini(count,candidates.size())):result.append(entry["position"])
	return result

func _unit_target_context(source:Dictionary,target:Dictionary,extra:Dictionary={})->Dictionary:
	var context:=extra.duplicate(false)
	context["source_unit_id"] = str(source.get("unit_id", source.get("id", "")))
	context["target_unit_id"] = str(target.get("unit_id", target.get("id", "")))
	if source.has("stun_sec"):
		context["status_duration"] = float(source.get("stun_sec",1.18))
	var source_node=source.get("model_node")
	if is_instance_valid(source_node) and source_node is Node3D:
		var cast_anchor:Variant=source_node.get_node_or_null("CastAnchor")
		context["origin_node"]=cast_anchor if cast_anchor is Node3D else source_node
		context["origin_height"]=_model_height_of(source_node)
	var target_node=target.get("model_node")
	if is_instance_valid(target_node) and target_node is Node3D:
		var hit_anchor:Variant=target_node.get_node_or_null("HitAnchor")
		context["target_node"]=hit_anchor if hit_anchor is Node3D else target_node
		context["target_height"]=_model_height_of(target_node)
	return context

# Rendered height of a unit, stashed on the model pivot by BattleRenderer.
# The composer places layers at a fraction of it, so a 0.30 tall sprite and a
# 0.93 tall one both get their feet, chest and head in the right places.
func _model_height_of(node:Variant)->float:
	if not (is_instance_valid(node) and node is Node3D):
		return 0.0
	var current:Node=node
	while current!=null:
		if current.has_meta("model_height"):
			return float(current.get_meta("model_height"))
		current=current.get_parent()
	return 0.0

func _play_opening_unit_vfx(current:Dictionary)->void:
	for id:String in current.keys():
		var unit:Dictionary=current[id]
		# 寄生分身如果在这「播种帧」已经活着（播种帧可能落在回放中途 ——
		# 新实例的头几次 `_refresh_visuals()` 发生在 `_prepare_battle_models()` 的
		# 分帧等待里，那时回放已经推进过若干帧），补报一次。
		# 播种帧在下面提前 return，进不到 `_refresh_battle_vfx` 的逐单位循环。
		if id.contains("_parasite_"):
			_announce_parasite_clone(id, unit)
			continue
		if not bool(unit.get("alive",false)):continue
		var sid:=str(unit.get("skill_id",""))
		if sid=="guardian_shield_taunt":
			_play_unit_procedural(sid,unit.get("world_foot",Vector3.ZERO),unit.get("world_foot",Vector3.ZERO),_unit_target_context(unit,unit))
		elif sid=="left_neighbor_sacrifice":
			var target:=_exact_skill_target(unit,current)
			if not target.is_empty():
				_play_unit_procedural(sid,unit.get("world_foot",Vector3.ZERO),target.get("world_foot",Vector3.ZERO),_unit_target_context(unit,target))
				# 9.20：死侍（`human_death_servant`）「左邻替死」的**绑定音**。
				# 用户口径：在**开始绑定棋子时**响，**没绑到人就不响** —— 所以挂在
				# 这条「目标已解析出来」的分支里，而不是无条件播。
				# 绑定发生在开战首帧之前（`BattleSimulator._apply_opening_unit_skills`），
				# 而首帧是「播种帧」、正常 diff 被整段跳过，所以只能在这里补。
				_maybe_play_death_servant_bind_sfx(str(unit.get("id","")))
		elif sid=="shared_hp_link":
			# 血契连线在开战首帧就建立（dark_doom 一上来就转化并绑定一个敌人），
			# 而首帧是"播种帧"、正常 diff 被跳过，所以连线特效要在这里补建，
			# 否则实时和回放都看不到。持久节点记入 _persistent_unit_vfx 由后续帧维护。
			var link_target:=_exact_skill_target(unit,current)
			if not link_target.is_empty():
				var context:=_unit_target_context(unit,link_target)
				context["persistent"]=true
				var spawned:=_play_unit_procedural(sid,unit.get("world_cast",unit.get("world_foot",Vector3.ZERO)),link_target.get("world_hit",link_target.get("world_foot",Vector3.ZERO)),context)
				if spawned!=null:
					_persistent_unit_vfx[str(unit.get("id",""))]={"node":spawned,"target_uid":str(unit.get("skill_target_uid",""))}

func _boss_world_position(value: Variant) -> Vector3:
	if value is Vector3:
		return value
	if value is Vector2:
		# Legacy fallback only. Formal Boss effects now pass model/world anchors.
		return _sim_to_world_pos(value)
	return Vector3.ZERO

func _boss_target_context(target: Dictionary, extra: Dictionary = {}) -> Dictionary:
	var context := extra.duplicate(false)
	var model_node = target.get("model_node")
	if is_instance_valid(model_node) and model_node is Node3D:
		var hit_anchor:Variant=model_node.get_node_or_null("HitAnchor")
		context["target_node"] = hit_anchor if hit_anchor is Node3D else model_node
	return context

func _living_twin_partner(unit: Dictionary, current: Dictionary) -> Dictionary:
	var group_id := str(unit.get("twin_group_id", ""))
	var member_index := int(unit.get("twin_member_index", -1))
	if group_id.is_empty() or member_index < 0:
		return {}
	for id: String in current.keys():
		var candidate: Dictionary = current[id]
		if bool(candidate.get("alive", false)) and str(candidate.get("team", "")) == str(unit.get("team", "")) and str(candidate.get("twin_group_id", "")) == group_id and int(candidate.get("twin_member_index", -1)) != member_index:
			return candidate
	return {}

func _boss_damage_events_for_lane(unit: Dictionary, damage_events: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var team := str(unit.get("team", ""))
	var lane := int(unit.get("lane", -1))
	for event: Dictionary in damage_events:
		if str(event.get("team", "")) == team:
			continue
		if lane >= 0 and int(event.get("lane", -1)) >= 0 and int(event.get("lane", -1)) != lane:
			continue
		result.append(event)
	return result

func _play_skill_texture_vfx(unit: Dictionary, pos: Vector2) -> void:
	var uid := str(unit.get("unit_id", ""))
	_spawn_skill_texture_for_unit_id(uid, pos)

func _spawn_skill_texture_for_unit_id(uid: String, pos: Vector2) -> void:
	if uid.is_empty():
		return
	var tex_configs := SkillVFXConfig.get_textures(uid)
	if tex_configs.is_empty():
		return
	_spawn_vfx("SKILL_TEXTURE", pos, {"textures": tex_configs})

func _spawn_boss_texture_variant(uid: String, variant: String, pos: Vector2) -> void:
	var configs := SkillVFXConfig.get_textures(uid)
	var selected: Array[Dictionary] = []
	for cfg: Dictionary in configs:
		if str(cfg.get("path", "")).to_lower().contains(variant.to_lower()):
			selected.append(cfg)
	if not selected.is_empty():
		_spawn_vfx("SKILL_TEXTURE", pos, {"textures": selected})

func _spawn_skill_hit_texture_for_unit_id(uid: String, pos: Vector2) -> void:
	var tex_configs := _textures_for_role(uid, "hit")
	if tex_configs.is_empty():
		return
	_spawn_vfx("SKILL_TEXTURE", pos, {"textures": tex_configs})

func _spawn_skill_textures_for_role(uid: String, role: String, pos: Vector2) -> void:
	var tex_configs := _textures_for_role(uid, role)
	if tex_configs.is_empty():
		return
	_spawn_vfx("SKILL_TEXTURE", pos, {"textures": tex_configs})

func _spawn_skill_projectile_or_default(uid: String, vfx_id: String, start_pos: Vector2, target_node: Node, target_pos: Vector2) -> void:
	var tex_configs := _textures_for_role(uid, "projectile")
	var config := {"impact_id": ""}
	if not tex_configs.is_empty():
		config["texture_path"] = str(tex_configs[0].get("path", ""))
		config["texture_scale"] = float(tex_configs[0].get("scale", 0.5))
	config["impact_textures"] = _textures_for_role(uid, "hit")
	config["head_textures"] = _textures_for_role(uid, "head")
	config["foot_textures"] = _textures_for_role(uid, "foot")
	_apply_projectile_race_color(uid, config)
	_spawn_projectile(vfx_id, start_pos, target_node, target_pos, config)

func _apply_projectile_race_color(uid: String, config: Dictionary) -> void:
	if uid.begins_with("human_"):
		config["color"] = Color(0.24, 0.68, 1.0, 1.0)
	elif uid.begins_with("undead_") or uid.begins_with("spirit_"):
		config["color"] = Color(0.24, 0.95, 0.30, 1.0)
	elif uid.begins_with("dark_"):
		config["color"] = Color(0.035, 0.025, 0.055, 1.0)

func _textures_for_role(uid: String, role: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for tex: Dictionary in SkillVFXConfig.get_textures(uid):
		if str(tex.get("role", "")) == role:
			result.append(tex)
	return result

func _spawn_skill_roles_at_target(uid: String, unit: Dictionary, target: Dictionary, head_on_caster := false) -> void:
	var hit_pos: Vector2 = target.get("hit_pos", target.get("pos", Vector2.ZERO))
	_spawn_skill_textures_for_role(uid, "cast", unit.get("cast_pos", Vector2.ZERO))
	_spawn_skill_textures_for_role(uid, "hit", hit_pos)
	_spawn_skill_textures_for_role(uid, "foot", target.get("foot_pos", hit_pos))
	var head_pos: Vector2 = unit.get("head_pos", hit_pos) if head_on_caster else target.get("head_pos", hit_pos)
	_spawn_skill_textures_for_role(uid, "head", head_pos)

func _enemy_damage_events(unit: Dictionary, damage_events: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var team := str(unit.get("team", ""))
	for event: Dictionary in damage_events:
		if str(event.get("team", "")) != team:
			result.append(event)
	return result

func _play_attack_skill_texture(attack: Dictionary, target: Dictionary, spawn_projectile := false) -> void:
	if not _attack_skill_vfx_ready(attack):
		return
	var uid := str(attack.get("unit_id", ""))
	var target_pos: Vector2 = target.get("hit_pos", target.get("pos", Vector2.ZERO))
	if spawn_projectile and not _textures_for_role(uid, "projectile").is_empty():
		var target_node := _unit_anchor_node_for_id(str(target.get("id", "")), "HitAnchor")
		_spawn_skill_projectile_or_default(uid, "PROJECTILE_MAGIC", attack.get("pos", Vector2.ZERO), target_node, target_pos)
		return
	_spawn_skill_hit_texture_for_unit_id(uid, target_pos)
	_spawn_skill_textures_for_role(uid, "head", target.get("head_pos", target_pos))
	_spawn_skill_textures_for_role(uid, "foot", target.get("foot_pos", target_pos))

func _attack_skill_vfx_ready(attack: Dictionary) -> bool:
	var sid := str(attack.get("skill_id", ""))
	if str(attack.get("unit_id", attack.get("source_id", ""))) == "human_king":
		return true
	if sid == "every_fourth_combo":
		var every := maxi(1, int(attack.get("skill_every", 4)))
		return int(attack.get("attack_count", 0)) % every == 0
	if sid == "same_target_damage_stack":
		return int(attack.get("attack_count", 0)) % 2 == 0
	if sid == "every_fifth_group_heal":
		var every_heal:=maxi(1,int(attack.get("skill_every",5)))
		return int(attack.get("attack_count",0))%every_heal==0
	return sid in ["true_damage_attack", "curse_attack", "poison_attack", "defense_down_attack"]

func _play_attack_unit_procedural(attack:Dictionary,target:Dictionary,current:Dictionary)->void:
	if not _attack_skill_vfx_ready(attack):return
	# 9.19：走到这里就说明**这一次普攻真的触发了技能**（上面那一步判的就是
	# `attack_count % every`），所以技能音挂在这里，而不是每一次普攻都响。
	_maybe_play_attack_skill_sfx(attack)
	var sid:=str(attack.get("skill_id",""))
	var origin:Vector3=attack.get("world_cast",Vector3.ZERO)
	var target_world:Vector3=target.get("world_hit",target.get("world_foot",Vector3.ZERO))
	var source:Dictionary=current.get(str(attack.get("id","")),{})
	var context:=_unit_target_context(source,target)
	if sid=="every_fifth_group_heal":
		context["targets"]=_living_team_world_positions(source,current)
		target_world=origin
	# Human King's actual attack uses the target-bound vertical heaven sword.
	# This is visual-only and leaves damage, timing and target selection untouched.
	if str(attack.get("unit_id", attack.get("source_id", ""))) == "human_king":
		_play_unit_procedural("unique_king_growth", origin, target_world, context)
		return
	_play_unit_procedural(sid,origin,target_world,context)

# 9.19：「攻击触发型」四星技能音（弓箭手额外伤害 / 牧师治疗 / 极光射手真伤）。
#
# 只在**自身或友军**且**四星**时响 —— 与 `_play_skill_cast_vfx` 里那条四星音同一
# 套门控口径（9.20 起由 `_is_own_or_ally_unit` 判定：owner 与 local_slot 同队，
# 敌方天然排除）。
# 「这次有没有触发」由调用方保证（已经过了 `_attack_skill_vfx_ready()`），
# 所以这里不再重复判模。
#
# 判据用 `def.id` 而不是名字：名字会被 `DataRegistry.canonicalize_unit_display_names()`
# 按本地化覆写，id 永远稳定。
func _maybe_play_attack_skill_sfx(attack: Dictionary) -> void:
	var unit_id := str(attack.get("unit_id", attack.get("source_id", "")))
	var cue := SfxService.attack_skill_cue_for(unit_id)
	if cue.is_empty():
		return
	var sim_uid := str(attack.get("id", ""))
	if not _is_own_or_ally_unit(sim_uid) or not _is_star4(sim_uid):
		return
	SfxService.play(cue)


# --- 9.22：四星「普攻附状态」型 + 佣兵「普攻增伤」型的技能音 -------------------
#
# 触发点在模拟器：`BattleSimulator._apply_attack_statuses` 的四个分支
# （破防 / 中毒 / 减速 / 反弹）与 `_perform_attack` 的增伤分支，各自补一条
# `sfx_proc` 事件；这里按 skill_id 取 cue。
#
# 门控口径：
#   * 四星那四条（刺灵 / 毒灵·飞灵 / 魔童 / 巨甲灵）—— 自身 + 友军 **且四星**，
#     与其它四星技能音完全同一口径；
#   * 审判剑士（`balance_judge`）—— 只判自身 + 友军。它是**佣兵**，永远到不了
#     四星，叠 `_is_star4` 就是一条永远不响的音（同 MERC_PROC_SKILL_CUES 的注释）。
#
# `source_uid` 恒为「触发技能的那只棋子」：巨甲灵那条填的是巨甲灵自己
# （反弹是它的技能，不是打它的那只攻击者的），这样归属门控才判得对。
func _maybe_play_sfx_proc(event: Dictionary) -> void:
	var skill_id := str(event.get("skill_id", ""))
	var source_uid := str(event.get("source_uid", ""))
	if skill_id.is_empty() or source_uid.is_empty():
		return
	if not _is_own_or_ally_unit(source_uid):
		return
	var cue := SfxService.proc_skill_cue_for(skill_id)
	if not cue.is_empty():
		if _is_star4(source_uid):
			SfxService.play(cue)
		return
	var merc_cue := SfxService.merc_proc_cue_for(skill_id)
	if not merc_cue.is_empty():
		SfxService.play(merc_cue)


# --- 9.23 第五批：boss 技能音的**真事件**通道（消费端）--------------------------
#
# 用户逐条点名的触发时刻，一张动作表在 SfxService.BOSS_EVENT_ACTIONS：
#   雷怒核心   = 触发反击造成伤害那一帧（本文件 diff：层数由 8 落回 0）
#   镜像魔君   = 真的召唤出分身那一帧（模拟器 `_skill_mirror_clone` 返回 > 0）
#   噬魂领主   = 击杀单位后（模拟器 `_on_unit_killed`）
#   血怒魔王   = 进入暴走那一次（模拟器 `_apply_boss_attacker_passives`）
#   双生守门人 = 复活那一帧（本文件 diff：`alive` 由假转真）
#   灭世裁决者 = 蓄力开始 / 蓄力完成 / 蓄力被收口（模拟器 `_tick_skills` 与 `_process_boss_charges`）
#
# 事件统一是 `sfx_proc`（只出声，不带特效），由模拟器经
# `BattleSimShared._emit_sfx_proc` 补进 `state.visual_events`，再经
# `frame_events` 过回放边界 —— 这正是「skill 音的判据必须跟着事件走、
# 不能依赖回放帧里不存在的那几个字段」的落点。
#
# ★ **不做归属门控**（与施法边沿那条同口径）：boss 固定是敌方单位、不属于任何
#   owner_slot，用户口径是「boss 技能音效播放，我方队友都能听见」。
#   所以这一支**不能**并进 `_maybe_play_sfx_proc` —— 那一条开头就是
#   `_is_own_or_ally_unit(source_uid)`，boss 永远过不了，并进去就是用户报的
#   「音效未生效」。
#
# 返回值 = 这条事件是不是 boss 真事件。调用方据此决定要不要继续走
# 四星 / 佣兵那两条普攻触发型分支 —— 一条事件只该响一声。
func _maybe_play_boss_skill_proc(event: Dictionary) -> bool:
	var skill_id := str(event.get("skill_id", ""))
	var action: Dictionary = SfxService.boss_event_action_for(skill_id)
	if action.is_empty():
		return false
	# 「先收口、再放音」的顺序由表里的 `stop` / `cue` 两个字段表达：
	# 灭世裁决者的完成那一档要先把 2 秒的蓄力音掐掉，否则两声会叠在一起。
	var stop_cue := str(action.get("stop", ""))
	if not stop_cue.is_empty():
		SfxService.stop_cue(stop_cue)
	var cue := str(action.get("cue", ""))
	if not cue.is_empty():
		SfxService.play(cue)
	return true


# --- 9.20：三条「非施法型」四星技能音的触发点 --------------------------------
#
# 这三家的技能在模拟器里**不产生 `skill_ready` 上升沿**，所以不能走
# `_play_skill_cast_vfx` 那条统一派发路径，各自挂在自己的真事件上。
# 触发时刻是用户逐条指定的：
#   * 寄生灵 → 「召唤敌人分身的时候」；
#   * 自爆灵 → 「死亡爆炸时」；
#   * 死侍   → 「开始绑定棋子时（无绑定就不播放）」。
#
# 归属与星级门控与施法型完全一致（自身 + 友军，且四星），取值入口也同一个
# （`star4_cue_for(uid, true)`），只是调用点不同 —— 所以 7 条新 cue 在
# `audio_sfx_check` 的豁免名单里是同一组。

# 寄生分身的「出生」登记：同一个 uid 只报一次，且必须**真的活着**。
#
# 判据从「新 uid」改成「首次 alive」是 9.20 第三批的修正 —— 回放的 roster 会在
# 第 0 帧就把分身放进 `_state`（alive=false），
#   * 旧判据：进演示的第一帧 = 「新 uid」→ 开局就响（用户实测）；
#   * 真实 3v3 路径：播种帧已把分身记进 `prev`（即使它还是死的）→ 等它真的出生时
#     又不再是「新 uid」→ **一次都不响**。
# 两个方向都由这一条判据收口。
func _announce_parasite_clone(uid: String, unit: Dictionary) -> void:
	if not bool(unit.get("alive", false)) or _parasite_spawn_announced.has(uid):
		return
	_parasite_spawn_announced[uid] = true
	_maybe_play_parasite_skill_sfx(unit)


# 寄生灵：击杀敌人后生成寄生分身的那一刻。
#
# ★ **不能拿分身自己判归属与星级。** 分身是死者的 `duplicate(true)`
#   （`_maybe_spawn_parasite_clone`），它的 `id` / `owner_slot` / `star` 全都还是
#   **死者的**（`id` 甚至是死者的单位 id，不是 `undead_parasite`）—— 只有 `team`
#   被改写成击杀者那一方。所以这里按「分身所在的那一方」回头找**本体**：
#   扫 `_state` 里 `team` 相同、`id == "undead_parasite"` 且还活着的棋子。
#
# 找不到就什么都不播（宁可少响一声，也不要把它算到别人头上）。
func _maybe_play_parasite_skill_sfx(clone: Dictionary) -> void:
	var team := str(clone.get("team", ""))
	if team.is_empty():
		return
	for side in ["player", "enemy"]:
		for raw in _state.get(side, []):
			if typeof(raw) != TYPE_DICTIONARY:
				continue
			var f: Dictionary = raw
			if str(f.get("team", "")) != team:
				continue
			if str(f.get("id", "")) != "undead_parasite" or not bool(f.get("alive", false)):
				continue
			var sim_uid := str(f.get("uid", ""))
			if not _is_own_or_ally_unit(sim_uid) or not _is_star4(sim_uid):
				continue
			SfxService.play(SfxService.star4_cue_for("undead_parasite", true))
			return


# 自爆灵：死亡毒爆那一刻。挂在 `_refresh_battle_vfx` 的死亡分支里，
# `sim_uid` 就是这只自爆灵自己的 uid。
func _maybe_play_bomb_skill_sfx(sim_uid: String) -> void:
	if not _is_own_or_ally_unit(sim_uid) or not _is_star4(sim_uid):
		return
	SfxService.play(SfxService.star4_cue_for("undead_bomb", true))


# 死侍：绑定生效那一下。调用点已经保证了「绑到了人才走到这里」，
# 所以这里只做归属与星级门控（星级的判据见 `_is_star4`）。
func _maybe_play_death_servant_bind_sfx(sim_uid: String) -> void:
	if not _is_own_or_ally_unit(sim_uid) or not _is_star4(sim_uid):
		return
	SfxService.play(SfxService.star4_cue_for("human_death_servant", true))

func _play_visual_events(state_snapshot: Dictionary,current:Dictionary) -> void:
	var events: Array = state_snapshot.get("visual_events", [])
	if _vfx_visual_event_index > events.size():
		_vfx_visual_event_index = events.size()
	while _vfx_visual_event_index < events.size():
		var event = events[_vfx_visual_event_index]
		_vfx_visual_event_index += 1
		if typeof(event) != TYPE_DICTIONARY:
			continue
		if str(event.get("type", "")) == "skill_shake":
			_screen_shake(float(event.get("strength", 6.5)), float(event.get("duration", 0.2)))
		elif str(event.get("type",""))=="mother_execute":
			# 书本挂在母灵头上，不依赖目标死活。母灵还能定位就一定放书。
			# 目标能解析就顺带把吸魂流指向它，解析不到（已死/清光/Boss）就只放书。
			var mother:=_vfx_unit_by_sim_uid(current,str(event.get("source_uid","")))
			if mother.is_empty():
				mother=_vfx_unit_by_sim_uid(_vfx_prev_units,str(event.get("source_uid","")))
			if not mother.is_empty():
				# 9.18：母灵（undead_mother）四星专属技「死亡执行」音效。
				# 9.20 起门控放宽为「自身 + 友军」（原为仅自身）。
				var _msim := str(event.get("source_uid", ""))
				if _is_own_or_ally_unit(_msim) and _is_star4(_msim):
					SfxService.play(SfxService.star4_cue_for("undead_mother", true))
				var victim:=_vfx_unit_by_sim_uid(current,str(event.get("target_uid","")))
				var has_victim:=not victim.is_empty()
				var book_target:Vector3=victim.get("world_foot",mother.get("world_foot",Vector3.ZERO)) if has_victim else mother.get("world_foot",Vector3.ZERO)
				var book_context:Dictionary=_unit_target_context(mother,victim) if has_victim else _unit_target_context(mother,mother)
				_play_unit_procedural("unique_death_execute",mother.get("world_head",mother.get("world_cast",Vector3.ZERO)),book_target,book_context)
		elif str(event.get("type", "")) == "unit_skill_proc":
			var source := _vfx_unit_by_sim_uid(current, str(event.get("source_uid", "")))
			var target := _vfx_unit_by_sim_uid(current, str(event.get("target_uid", "")))
			var skill_id := str(event.get("skill_id", ""))
			# 9.21：四星民兵（「概率触发型」技能音）。`attack_interrupt` 是
			# `randf() < interrupt_chance` 触发的，模拟器只在**真的打断成功**时
			# 才补这条 unit_skill_proc 事件 —— 所以挂在这里就等于「响了 = 打成了」，
			# 不需要另外判模。门控与其它四星技能音同口径（自身 + 友军 + 四星）。
			var proc_cue := SfxService.proc_skill_cue_for(skill_id)
			if not proc_cue.is_empty():
				var proc_uid := str(event.get("source_uid", ""))
				if _is_own_or_ally_unit(proc_uid) and _is_star4(proc_uid):
					SfxService.play(proc_cue)
			if not skill_id.is_empty() and not source.is_empty() and not target.is_empty():
				_play_unit_procedural(skill_id, source.get("world_cast", Vector3.ZERO), target.get("world_hit", target.get("world_foot", Vector3.ZERO)), _unit_target_context(source, target))
		elif str(event.get("type", "")) == "sfx_proc":
			# 9.22：**只出声、不出特效**的普攻触发型技能音。
			#
			# 为什么不复用上面那条 `unit_skill_proc`：那一条在派发完音效后还会顺带调
			# `_play_unit_procedural(skill_id, ...)` 去放程序化特效，而
			# poison_attack / defense_down_attack / curse_attack / balance_judge
			# 这几个 skill_id 原本**没有**对应的程序化演出 —— 走那条路等于给它们
			# 凭空叠一层特效，把「加音效」做成了「加演出」。
			# 9.23 第五批：boss 技能音走的是**同一条事件通道**（`sfx_proc` + skill_id），
			# 但它的门控口径完全不同（不做归属门控，见 `_maybe_play_boss_skill_proc`
			# 的说明），所以先问 boss 那一支；它接了就结束，免得同一条事件被
			# 四星 / 佣兵那两支按 skill_id 再判一遍。
			if not _maybe_play_boss_skill_proc(event):
				_maybe_play_sfx_proc(event)
		# D6: hit_number is drawn by the Director's adapter, on its timing. The old
		# branch here would have been a second, untimed copy of the same number.

# --- Director cue entry points ------------------------------------------------
# Every basic attack, damage number and death is drawn through these, driven by
# BattlePresentationDirector cues. The snapshot-diff versions they replaced were
# deleted in D6. _vfx_prev_units is reused deliberately: it already holds the most
# recent snapshot after each refresh, and the ping-pong buffer comment above
# forbids a second cross-frame holder of the same dictionaries.

func cue_play_basic_attack(source_uid: String, target_uid: String, ranged: bool) -> bool:
	var source: Dictionary = _cue_unit_snapshot(source_uid)
	if source.is_empty():
		return false
	var attack := {
		"id": source_uid,
		"pos": source.get("cast_pos", Vector2.ZERO),
		"world_cast": source.get("world_cast", Vector3.ZERO),
		"team": str(source.get("team", "")),
		"unit_id": str(source.get("unit_id", "")),
		"skill_id": str(source.get("skill_id", "")),
		"target_uid": target_uid,
		# 9.19：「第 N 次普攻触发」类技能（弓箭手额外伤害 / 牧师治疗）靠
		# `attack_count % every == 0` 判断**这一次**要不要出技能演出与技能音。
		# 这两个字段原先只存在于 D6 删掉的 snapshot-diff 路径上，cue 这条路漏了
		# 它们 —— `_attack_skill_vfx_ready()` 于是永远读到缺省值（`0 % every == 0`），
		# 把每一次普攻都当成触发。补回来之后 VFX 与 9.19 新接的技能音才都只落在
		# 真正的第 N 击上。（`_collect_vfx_units` 一直在写这两个字段，只是没人读。）
		"attack_count": int(source.get("attack_count", 0)),
	}
	# `every` 用快照里的真实值：四星会改它（弓箭手 4→3、牧师 5→4）。为 0 表示
	# 这只棋子的 def 里没有 `every`（技能不是这一类），**不写这个键**，
	# 让 `_attack_skill_vfx_ready()` 走它原本的缺省，行为与改动前一致。
	var source_every := int(source.get("skill_every", 0))
	if source_every > 0:
		attack["skill_every"] = source_every
	# The event carries the simulator's real target, so unlike the diff path this
	# never has to guess the victim from nearby damaged units.
	var target: Dictionary = _cue_unit_snapshot(target_uid)
	if target.is_empty():
		target = _floor_target_for(attack)
	var unit_id := str(attack.get("unit_id", ""))
	# The two special cases the batched diff helpers carry must be mirrored here
	# exactly, or a migrated unit would gain an extra swing the legacy path
	# deliberately omits.
	if unit_id == "human_king":
		_play_attack_unit_procedural(attack, target, _vfx_prev_units)
		return true
	if not ranged and (str(attack.get("skill_id", "")) == "mirror_clone" or source_uid.contains("_mirror_")):
		_play_boss_procedural("mirror_slash", attack.get("world_cast", Vector3.ZERO),
			target.get("world_foot", Vector3.ZERO), _boss_target_context(target))
		return true
	var race := _visual_race_from_unit_id(unit_id)
	_play_race_basic_attack(attack, target, "ranged" if ranged else "melee", race, _vfx_prev_units)
	_play_attack_unit_procedural(attack, target, _vfx_prev_units)
	return true


func cue_spawn_hit_number(target_uid: String, amount: int, kind: String, crit: bool, is_skill: bool, race: String) -> bool:
	var target: Dictionary = _cue_unit_snapshot(target_uid)
	if target.is_empty():
		return false
	_spawn_hit_number(target.get("head_pos", Vector2.ZERO), amount, kind, crit, is_skill, race)
	return true


# Death had no visual at all before D4: the renderer simply freed the model on the
# next refresh. Taking ownership of the actor lets it sink and fade instead of
# blinking out (checklist section 6: never just disappear).
# --- V2 P1-05 第 1 条：普攻的前冲/后坐 + 命中的单次小屏震 ----------------------
#
# 位移打在 **ActorRoot** 上而不是 actor 本身：_position_3d_model_node() 每帧都会
# 用模拟位置重写 actor.position，动它一定会被覆盖掉。ActorRoot 是它的子节点，
# 没有别的地方写，所以前冲能活过每帧重定位。
const ATTACK_LUNGE_DISTANCE := 0.085
const ATTACK_LUNGE_OUT_SEC := 0.07
const ATTACK_LUNGE_BACK_SEC := 0.13
# 远程是后坐不是前冲：出手方向相反、幅度更小。
const RANGED_RECOIL_FACTOR := -0.55

# 命中的小屏震。"小"是认真的：一场战斗里普攻的数量远多于技能，
# 这个值和 skill_shake 默认的 6.5 差一个量级。
const IMPACT_SHAKE_STRENGTH := 1.6
const IMPACT_SHAKE_SEC := 0.09

# V2 原话："暴击只放大 20%-35%，不堆全屏闪白"。
# 所以暴击的强调就是把同一套演出乘上这个系数，而不是另加一层全屏效果。
const CRIT_EMPHASIS_SCALE := 1.28


func cue_play_attack_lunge(source_uid: String, target_uid: String, ranged: bool) -> bool:
	var actor_value = _battle_3d_models.get(source_uid)
	if not (actor_value is Node3D) or not is_instance_valid(actor_value):
		return false
	var actor := actor_value as Node3D
	var root := actor.get_node_or_null("ActorRoot") as Node3D
	if root == null:
		return false
	var direction := _lunge_direction(actor, target_uid)
	if direction == Vector3.ZERO:
		return false
	var distance := ATTACK_LUNGE_DISTANCE * (RANGED_RECOIL_FACTOR if ranged else 1.0)

	# 连续攻击时上一发还没收回来就再来一发，会把 ActorRoot 越推越远。
	# 每次开始前先杀掉上一条，并从原点重新起步。
	#
	# 必须先 has_meta 再 get_meta，不能用 get_meta(key, default) 的两参数形式：
	# Godot 4.7 里那个形式**照样会为缺失 key 打一条引擎 ERROR**（默认值确实返回了，
	# 但错误也确实打了）。第一次攻击时这个 key 根本没设过，于是每个单位的第一拳都
	# 刷一条 —— 2026-08-30 的真机 logcat 里 135 次，本地 round 1 一场 18 次。
	#
	# 这条当初能溜过桌面全套门禁，是因为它是普通的 `ERROR:` 而不是 `SCRIPT ERROR:`，
	# 而 run_check.ps1 的 EngineErrorPatterns 里没有这个模式。
	if actor.has_meta("lunge_tween"):
		var previous = actor.get_meta("lunge_tween")
		if previous is Tween and (previous as Tween).is_valid():
			(previous as Tween).kill()
	root.position = Vector3.ZERO

	var tween := create_tween()
	tween.tween_property(root, "position", direction * distance, ATTACK_LUNGE_OUT_SEC) 		.set_ease(Tween.EASE_OUT)
	tween.tween_property(root, "position", Vector3.ZERO, ATTACK_LUNGE_BACK_SEC) 		.set_ease(Tween.EASE_IN_OUT)
	actor.set_meta("lunge_tween", tween)
	return true


# 攻击者指向目标的水平方向。取不到目标就返回零向量，让调用方跳过这次前冲 ——
# 猜一个方向会让单位朝着空处冲。
func _lunge_direction(actor: Node3D, target_uid: String) -> Vector3:
	var target_value = _battle_3d_models.get(target_uid)
	if not (target_value is Node3D) or not is_instance_valid(target_value):
		return Vector3.ZERO
	var delta: Vector3 = (target_value as Node3D).global_position - actor.global_position
	delta.y = 0.0
	if delta.length() < 0.001:
		return Vector3.ZERO
	return delta.normalized()


# 命中反馈：一次小屏震。暴击不另加东西，只把同一次震动乘 CRIT_EMPHASIS_SCALE。
#
# 不需要在这里做"只震一次"的去重：VFXManager.play_screen_shake 用 maxf 取强度，
# 同一帧里多个命中不会叠加成一次大震。
func cue_play_impact_feedback(_target_uid: String, crit: bool) -> void:
	var strength := IMPACT_SHAKE_STRENGTH * (CRIT_EMPHASIS_SCALE if crit else 1.0)
	_screen_shake(strength, IMPACT_SHAKE_SEC)


func cue_claim_corpses(events: Array) -> void:
	for event_value in events:
		if not (event_value is Dictionary):
			continue
		var event: Dictionary = event_value
		if str(event.get("type", "")) != "death":
			continue
		var uid := str(event.get("source_uid", ""))
		if uid.is_empty() or _cue_corpses.has(uid):
			continue
		var claimed: Node3D = detach_actor_for_death(uid)
		if claimed != null:
			_cue_corpses[uid] = claimed
		# 2D 层（名字 + 血条）也要在这里扣下来，理由和身体完全一样：
		# 从入队到 cue_play_death 真正开播之间会经过 _refresh_visuals()，
		# 那一趟剪枝会把血条当场释放，于是尸体还在淡、血条已经没了。
		var claimed_unit_node := claim_unit_node_for_death(uid)
		if claimed != null or claimed_unit_node != null:
			_arm_death_claim_watchdog(uid)


func cue_release_corpses() -> void:
	for uid in _cue_corpses.keys():
		var actor = _cue_corpses[uid]
		if actor != null and is_instance_valid(actor):
			release_death_actor(str(uid), actor as Node3D)
	_cue_corpses.clear()
	for entry_value in _active_death_actors.values():
		if not (entry_value is Dictionary):
			continue
		var entry: Dictionary = entry_value
		var tween_value = entry.get("tween")
		if tween_value is Tween and is_instance_valid(tween_value):
			(tween_value as Tween).kill()
		var actor_value = entry.get("actor")
		if actor_value is Node3D and is_instance_valid(actor_value):
			release_death_actor(str(entry.get("uid", "")), actor_value as Node3D)
	_active_death_actors.clear()
	_pending_death_claim_tokens.clear()
	release_dying_unit_nodes()


func cue_play_death(victim_uid: String, duration_sec: float = 0.35) -> bool:
	_maybe_play_human_king_death_sfx(victim_uid)
	_pending_death_claim_tokens.erase(victim_uid)
	var actor: Node3D = _cue_corpses.get(victim_uid)
	_cue_corpses.erase(victim_uid)
	if actor == null or not is_instance_valid(actor):
		actor = detach_actor_for_death(victim_uid)
	if actor == null or not is_instance_valid(actor):
		_release_dying_unit_node(victim_uid)
		return false
	# The profile owns the length so a low quality tier can shorten the fade
	# without ever removing it (checklist 6: death must never just disappear).
	var fade := maxf(0.08, duration_sec * 0.92)
	var tween := create_tween()
	_active_death_actors[actor.get_instance_id()] = {
		"uid": victim_uid,
		"actor": actor,
		"tween": tween,
	}
	tween.set_parallel(true)
	var sink := actor.position + Vector3(0.0, -0.35, 0.0)
	tween.tween_property(actor, "position", sink, fade).set_ease(Tween.EASE_IN)
	tween.tween_property(actor, "scale", actor.scale * 0.72, fade).set_ease(Tween.EASE_IN)
	# V2 P1-05：淡出必须**真的**淡出。
	#
	# 改前这里只遍历 actor.get_children()，而 actor 的直接子节点是 ActorRoot 和
	# 六个锚点 —— 一个 GeometryInstance3D 都没有（模型是 attach_model() 挂到
	# actor_root 下面的）。也就是说这个循环一次都不匹配，死亡只有下沉和缩小、
	# 没有淡出。改成遍历整棵子树。
	for geometry in _death_fade_targets(actor):
		tween.tween_property(geometry, "transparency", 1.0, fade * 0.94)
	# 2D 的血条/名字层必须**跟着一起淡**，不能在尸体还在的时候就消失。
	# V2 第 2 条原话："血条和状态图标同步，不突然消失"。
	_play_unit_node_death_fade(victim_uid, fade)
	tween.chain().tween_callback(func() -> void: _finish_death_actor(victim_uid, actor))
	return true


func _finish_death_actor(uid: String, actor: Node3D) -> void:
	if actor != null:
		_active_death_actors.erase(actor.get_instance_id())
	release_death_actor(uid, actor)


func _arm_death_claim_watchdog(uid: String) -> void:
	_death_claim_serial += 1
	var token := _death_claim_serial
	_pending_death_claim_tokens[uid] = token
	var tree := get_tree()
	if tree == null:
		return
	var timer := tree.create_timer(DEATH_CLAIM_WATCHDOG_SEC)
	timer.timeout.connect(_release_stale_death_claim.bind(uid, token))


func _release_stale_death_claim(uid: String, token: int) -> void:
	if int(_pending_death_claim_tokens.get(uid, -1)) != token:
		return
	_pending_death_claim_tokens.erase(uid)
	var actor = _cue_corpses.get(uid)
	_cue_corpses.erase(uid)
	if actor is Node3D and is_instance_valid(actor):
		release_death_actor(uid, actor as Node3D)
	_release_dying_unit_node(uid)


# 整棵子树里所有能调 transparency 的节点。
#
# 状态图标（Sprite3D）也在里面：它们挂在 HeadAnchor/BodyAnchor 下面，是 actor 的
# 孙节点。detach_actor_for_death() 已经把 StatusVFXController 停掉了，所以这里
# 改 transparency 不会被它的 _process 每帧覆写回去。
func _death_fade_targets(root: Node) -> Array[GeometryInstance3D]:
	var out: Array[GeometryInstance3D] = []
	var pending: Array[Node] = [root]
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		if node is GeometryInstance3D:
			out.append(node as GeometryInstance3D)
		for child in node.get_children():
			pending.append(child)
	return out


func _cue_unit_snapshot(sim_uid: String) -> Dictionary:
	if sim_uid.is_empty():
		return {}
	var snapshot: Dictionary = _vfx_prev_units.get(sim_uid, {})
	return snapshot


# --- 9.17 人王阵亡音 ---------------------------------------------------------

# 已经响过的 uid。**去重是必须的，不是保险**：DamageService.apply_damage 对一个
# 已经 hp == 0 的目标再打一次时 `died_now` 会再次为 true（`hp = maxi(0, 0 - remaining)`
# 仍然是 0），所以同一个 uid 的 death 可能被重复投递。BattlePresentationDirector
# 那层虽然有 _seen_event_keys 去重，但它只覆盖 replay 那条路。
#
# 按 uid 去重；仅本座位的人王通过下面的归属检查，队友及敌方不播放。
#
# ★ 9.20 明确：人王这一类**不参与**「放宽到友军」那次改动（见 `_is_own_or_ally_unit`）。
#   用户原话是「包括人王升级时的特效表现也能被友军看见」，但在追问后改口：
#   拿不到队友人王的成长层数，无法判断它是否还该升级 ——「那就改为人王的音效和
#   特效都不被友军看见」。所以本函数与 `_local_living_human_king` 一律继续用
#   `_is_local_owned_unit`（仅自身）。
var _human_king_death_sfx_uids: Dictionary = {}


func _maybe_play_human_king_death_sfx(victim_uid: String) -> void:
	if victim_uid.is_empty() or _human_king_death_sfx_uids.has(victim_uid):
		return
	if not _is_unit_id(victim_uid, "human_king") or not _is_local_owned_unit(victim_uid):
		return
	_human_king_death_sfx_uids[victim_uid] = true
	SfxService.play(SfxService.CUE_HUMAN_KING_DEATH)


# --- 9.19 人王「战斗结束未阵亡 · 奖励属性」音 + 升级闪光 ----------------------

# 每场只播一次。`battle_finished` 前后有两条收尾路径（本地模拟走
# BattleResult._emit_finished，replay 走 BattleScreen._finish_replay），
# 都用 `_return_emitted` 保证只走一次；这个标记是第二道保险。
# 每局开始由 BattleScreen._start_replay() 清空。
var _human_king_reward_played := false


# 战斗结束那一刻调用。
#
# 用户给的两个硬条件**缺一不可**：
#   ① 本次战斗**自身人王未阵亡** —— 人王的唯一技是「参战且战后仍存活才成长」
#      （Main._apply_post_battle_unit_outcomes 按 result.player_survivor_slots 判），
#      阵亡的人王下一回合直接被移出棋盘，成长无从谈起；
#   ② 本次**还有成长空间**（`king_growth_stacks < max_stacks`）—— 已经到上限
#      就没有属性加成了，这时响奖励音是在骗玩家。
#
# 用户口径：**不要在战后结算面板里响，要在战斗结束那一刻响**，并且要在
# 自身人王身上出一个只给自己看的闪光升级特效。所以这条挂在收尾路径的
# 「水晶演出之前」——赢了的那一方棋子随后会被水晶演出逐一出场带走，
# 挂在那之后就没人王可以闪光了。
func _play_human_king_reward() -> void:
	if _human_king_reward_played:
		return
	var king := _local_living_human_king()
	if king.is_empty():
		return
	if not _human_king_can_grow():
		return
	_human_king_reward_played = true
	# 升级金光：专用特效 `HUMAN_KING_REWARD`（金色扩散环 + 地面金色光晕 +
	# 金色迸发 + 上升金粒子），落在**人王本体**脚下 —— 用户要的是「在自身人王
	# 身上」，不是队伍中心。归属判定在 `_local_living_human_king()` 里做掉了，
	# 队友 / 敌方的人王根本走不到这里。
	#
	# ★ 这里**不再调 `_play_unit_procedural()`**。那是 3D 技能入口，只认
	#   `BossProceduralVFX3D.UNIT_SKILLS` 与 3D composer 里的技能 id；早先传的是
	#   2D 特效 id（`GROWTH_AURA`），会一路落到 composer 的默认分支 → **静默无
	#   表现**，等于白写一行。要加 3D 层的金光，得先在 `BossSkillVFXComposer3D`
	#   里加一条分支（还没做）。
	_spawn_vfx("HUMAN_KING_REWARD", king.get("foot_pos", Vector2.ZERO))
	SfxService.play(SfxService.CUE_HUMAN_KING_REWARD)


# 本座位还活着的人王。归属一律走 `_is_local_owned_unit`（owner_slot == local_slot）。
#
# ★ 9.20：**刻意不用 `_is_own_or_ally_unit`。** 用户先要求「人王升级时的特效
#   友军也能看见」，追问后改口「人王的音效和特效都不被友军看见」——原因是本地
#   拿不到队友人王的成长层数（`NetProtocol._minimal_slots` 的棋盘提交载荷里
#   没有 `king_growth_stacks`），判不出它是否已封顶，宁可不播也不误播。
#   所以人王这一路（阵亡音 / 奖励音 / 升级金光）全部保持**仅自身**。
# 用数据表 id（human_king）判定而不是名字：名字会被本地化覆写，id 永远稳定。
func _local_living_human_king() -> Dictionary:
	for side in ["player", "enemy"]:
		for raw in _state.get(side, []):
			if typeof(raw) != TYPE_DICTIONARY:
				continue
			var sim_uid := str(raw.get("uid", ""))
			if str(raw.get("id", "")) != "human_king" or not bool(raw.get("alive", false)):
				continue
			if not _is_local_owned_unit(sim_uid):
				continue
			var snap := _cue_unit_snapshot(sim_uid)
			if not snap.is_empty():
				return snap
			# 收尾帧快照可能已经把它剪掉，用手头的位置字段拼一个够用的锚点。
			var sim_pos := _fighter_sim_pos(raw)
			return {
				"foot_pos": _sim_to_arena(sim_pos),
				"world_foot": _sim_to_world_pos(sim_pos),
			}
	return {}


# 本座位人王这一局结束**还能不能**拿到成长。false = 已到上限，或棋盘上没有人王。
#
# cap 走 `UnitFactory.apply_star_stats`，与 Main._grow_human_king 同源：
# `max_stacks` 在 star4 里被覆写（1~3 星 5 层 / 4 星 8 层），而 `cell.def` 是
# 未做星级缩放的原始表项 —— 直接读它会把 4 星的上限读成 5 层，于是人王明明
# 已经封顶了还在响奖励音。
func _human_king_can_grow() -> bool:
	for i in GameState.board_slots.size():
		var cell = GameState.board_slots[i]
		if cell == null or str(cell.get("def", {}).get("skill_id", "")) != "unique_king_growth":
			continue
		var d: Dictionary = cell.get("def", {})
		var effective := _UnitFactoryRef.apply_star_stats(d, int(cell.get("star", 1)))
		var cap := int(effective.get("max_stacks", 0))
		if cap <= 0:
			return true
		return int(cell.get("king_growth_stacks", 0)) < cap
	return false


# 这个 uid 是不是指定的数据表棋子。两条路都试：
#
#   1. `_vfx_prev_units[uid].unit_id` —— 快照里已经存了（_collect_vfx_units 写的），
#      最省事，但快照是按「本帧还在不在」剪枝的，某个时序下可能已经没了；
#   2. 直接扫 `_state` 的双方单位表 —— cue 到得比快照清理晚时的兜底。
#
# **用数据表 id（human_king）判定，不用名字**：名字会随本地化变，
# 而 data/units/race_units.json 里的 id 永远稳定。两条路都查不到就返回 false ——
# 宁可少响一声，也不要把别人的阵亡音播给人王。
func _is_local_owned_unit(sim_uid: String) -> bool:
	var unit := _state_unit_for(sim_uid)
	if unit.is_empty():
		return false
	if NetworkService.team_active or GameState.team_mode:
		var local_slot := NetworkService.team_local_slot if NetworkService.team_active else 0
		return local_slot >= 0 and int(unit.get("owner_slot", -1)) == local_slot
	return str(unit.get("team", "")) == "player" and int(unit.get("owner_slot", -1)) <= 0


# sim_uid -> `_state` 里那份原始棋子字典。
#
# 两条路都试：`_cue_unit_snapshot` 那份快照最省事，但它按「本帧还在不在」剪枝，
# 某个时序下可能已经没了；再直接扫 `_state` 的双方单位表兜底。
#
# 抽出来是因为 9.20 起有三个判据（自身 / 自身+友军 / 星级）共用同一套查找 ——
# 原来这段在三处各抄了一遍。
func _state_unit_for(sim_uid: String) -> Dictionary:
	var unit: Dictionary = _cue_unit_snapshot(sim_uid)
	for side in ["player", "enemy"]:
		for raw in _state.get(side, []):
			if raw is Dictionary and str(raw.get("uid", "")) == sim_uid:
				unit = raw
	return unit


# 9.20：归属判据的**放宽版** —— 「自身 + 友军」。
#
# 用户口径：战场上的音效此前只能听见**自己**的棋子，现在要能听见**自己和友军**的。
# 3v3 里队友是**另外两个 owner_slot**（`GameConstants.TEAM_SIDE_SIZE` = 3，
# 红队 0-2 / 蓝队 3-5），所以判据从 `owner == local_slot` 变成
# 「owner 与 local_slot 同队」。
#
# **单机下的行为不变**：离线单人局里 `team_mode` 为真、local_slot 恒为 0，
# 而自己那一队只有 0 号位是真人棋盘，1/2 号位是空位或自己加的假想敌 ——
# 也就是说单机没有「友军」可言，放宽前后等价。
#
# ★ 人王相关的三处（阵亡音、战后奖励音、升级金光）**刻意不用本函数**：
#   用户明确要求人王的音效与特效都保持只给自己看，见 `_local_living_human_king`。
func _is_own_or_ally_unit(sim_uid: String) -> bool:
	var unit := _state_unit_for(sim_uid)
	if unit.is_empty():
		return false
	if NetworkService.team_active or GameState.team_mode:
		var local_slot := NetworkService.team_local_slot if NetworkService.team_active else 0
		var owner := int(unit.get("owner_slot", -1))
		if local_slot < 0 or owner < 0:
			return false
		return GameConstants.team_of_slot(owner) == GameConstants.team_of_slot(local_slot)
	return _is_local_owned_unit(sim_uid)


# 9.18：该 sim_uid 对应单位是否四星。快照不存 star，所以直接扫 `_state` 双方表
# （与 `_is_local_owned_unit` 同款兜底）。`GameConstants.MAX_STAR` 即 4。
# 只用于四星技能音效门控 —— 宁可少响，也不在普攻上升沿误触。
func _is_star4(sim_uid: String) -> bool:
	for side in ["player", "enemy"]:
		for raw in _state.get(side, []):
			if raw is Dictionary and str(raw.get("uid", "")) == sim_uid:
				return int(raw.get("star", 1)) == GameConstants.MAX_STAR
	return false

func _is_unit_id(sim_uid: String, unit_id: String) -> bool:
	if str(_cue_unit_snapshot(sim_uid).get("unit_id", "")) == unit_id:
		return true
	for side in ["player", "enemy"]:
		for f in (_state.get(side, []) as Array):
			if typeof(f) != TYPE_DICTIONARY:
				continue
			var fighter: Dictionary = f
			if str(fighter.get("uid", "")) == sim_uid:
				return str(fighter.get("id", "")) == unit_id
	return false


func _vfx_unit_by_sim_uid(current:Dictionary,sim_uid:String)->Dictionary:
	for id:String in current.keys():
		var unit:Dictionary=current[id]
		if str(unit.get("sim_uid",""))==sim_uid:return unit
	return {}

func _ensure_hit_number_layer() -> void:
	if _hit_number_layer != null and is_instance_valid(_hit_number_layer):
		return
	if _arena == null:
		return
	_hit_number_layer = Control.new()
	_hit_number_layer.name = "HitNumbers"
	_hit_number_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hit_number_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Unit nodes use a position-based z_index (int(round(mapped.y)), up to ~arena
	# height, i.e. ~1000+), so the numbers must sit near the top of the z range or
	# they render behind the units. z_index max is 4096.
	_hit_number_layer.z_index = 4096
	_arena.add_child(_hit_number_layer)
	_hit_number_pool.clear()
	for _i in _HIT_NUMBER_POOL_SIZE:
		var lbl := Label.new()
		lbl.visible = false
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lbl.add_theme_constant_override("outline_size", 5)
		lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.95))
		_hit_number_layer.add_child(lbl)
		_hit_number_pool.append(lbl)

# god / dark / undead / human get distinct normal-attack number colors so you can
# read a unit's race off its hits. Unlisted races fall back to near-white.
const _RACE_NUMBER_COLORS := {
	"god": Color(1.0, 1.0, 1.0),      # 神 = white
	"dark": Color(0.07, 0.07, 0.09),  # 暗 = black (uses a light outline below)
	"undead": Color(0.30, 1.0, 0.90), # 灵 = cyan
	"human": Color(0.36, 0.62, 1.0),  # 人 = blue
}

# Spawns one floating number at a screen-space head anchor. kind is
# "dmg" | "heal" | "shield"; crit/skill only tweak the damage styling. race colors
# the normal-attack tier only.
func _spawn_hit_number(head_pos: Vector2, amount: int, kind: String, crit: bool, is_skill: bool, race: String = "") -> void:
	if amount <= 0:
		return
	_ensure_hit_number_layer()
	if _hit_number_pool.is_empty():
		return
	var lbl: Label = _hit_number_pool[_hit_number_cursor]
	_hit_number_cursor = (_hit_number_cursor + 1) % _hit_number_pool.size()
	if not is_instance_valid(lbl):
		return
	if lbl.has_meta("hit_tween"):
		var prev_tween: Variant = lbl.get_meta("hit_tween")
		if prev_tween is Tween and (prev_tween as Tween).is_valid():
			(prev_tween as Tween).kill()

	var color: Color
	var font_size: int
	var text: String
	# Per-tier motion/opacity. Normal basics are deliberately the quietest layer:
	# small, faint and short-lived so they read as background chatter while crits
	# and skills pop above them.
	var base_alpha := 1.0
	var rise := 46.0
	var dur := 0.8
	var pop := true
	match kind:
		"heal":
			color = Color(0.36, 1.0, 0.46)
			text = "+%d" % amount
			font_size = 20
		"shield":
			color = Color(0.46, 0.82, 1.0)
			text = "+%d" % amount
			font_size = 18
		_:
			if crit:
				color = Color(1.0, 0.56, 0.16)
				text = "%d!" % amount
				font_size = 30
				rise = 60.0
				dur = 0.72
			elif is_skill:
				color = Color(1.0, 0.98, 0.66)
				text = str(amount)
				font_size = 24
				dur = 0.7
			else:
				# Normal attack: the quiet background layer, but still clearly legible.
				# Color by attacker race so hits are readable at a glance.
				color = _RACE_NUMBER_COLORS.get(race, Color(0.94, 0.96, 1.0))
				text = str(amount)
				font_size = 18
				base_alpha = 0.88
				rise = 34.0
				dur = 0.5
				pop = false
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", color)
	# Dark race numbers are near-black, so give them a light outline to stay legible;
	# everything else keeps the default black outline.
	lbl.add_theme_color_override("font_outline_color", Color(0.92, 0.94, 1.0, 0.95) if race == "dark" and kind == "dmg" and not crit and not is_skill else Color(0, 0, 0, 0.95))
	lbl.text = text
	lbl.reset_size()
	var sz := lbl.get_minimum_size()
	lbl.size = sz
	lbl.pivot_offset = sz * 0.5
	lbl.modulate = Color(1, 1, 1, base_alpha)
	lbl.scale = Vector2.ONE
	lbl.visible = true
	# Small horizontal jitter so numbers stacking on one target don't perfectly overlap.
	var jitter := randf_range(-16.0, 16.0)
	lbl.global_position = head_pos + Vector2(jitter - sz.x * 0.5, -sz.y * 0.5)
	var start := lbl.position

	var tw := lbl.create_tween()
	lbl.set_meta("hit_tween", tw)
	tw.set_parallel(true)
	tw.tween_property(lbl, "position", start + Vector2(0, -rise), dur).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(lbl, "modulate:a", 0.0, dur * 0.55).set_delay(dur * 0.45)
	if pop:
		lbl.scale = Vector2(0.55, 0.55)
		tw.tween_property(lbl, "scale", Vector2.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.set_parallel(false)
	tw.tween_callback(lbl.hide)

func _spawn_vfx(vfx_id: String, pos: Vector2, config: Dictionary = {}) -> void:
	VFXManager.spawn_vfx(vfx_id, pos, config)

func _spawn_projectile(vfx_id: String, start_pos: Vector2, target_node: Node, target_pos: Vector2, config: Dictionary = {}) -> void:
	config["target_position"] = target_pos
	VFXManager.spawn_projectile_vfx(vfx_id, start_pos, target_node, config)

func _hitstop(duration: float) -> void:
	VFXManager.play_hitstop(duration)

func _screen_shake(strength: float, duration: float) -> void:
	VFXManager.play_screen_shake(strength, duration)

func _unit_node_for_id(id: String) -> Node:
	if _unit_nodes.has(id):
		return _unit_nodes[id]
	return null

func _unit_anchor_node_for_id(id: String, anchor_name: String) -> Node:
	var unit_node := _unit_node_for_id(id)
	if unit_node == null or not is_instance_valid(unit_node):
		return null
	return unit_node.get_node_or_null(anchor_name)

func _unit_anchor_global_position(unit_node: Node, anchor_name: String, fallback: Vector2) -> Vector2:
	if unit_node == null or not is_instance_valid(unit_node):
		return fallback
	var anchor := unit_node.get_node_or_null(anchor_name)
	if anchor is Node2D:
		return (anchor as Node2D).global_position
	if anchor is Control:
		var c := anchor as Control
		return c.global_position + c.size * 0.5
	return fallback

func _opposite_team(team: String) -> String:
	return "enemy" if team == "player" else "player"
