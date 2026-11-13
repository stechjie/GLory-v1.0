extends SceneTree

# Boss 战特效契约检查（11.12；11.13 和 lenoliew 同日的改法合并后更新）。
# Run with: Godot --headless --path . --script res://tools/boss_battle_vfx_check.gd
#
# 起因：Boss 战里技能特效「有时候被吃掉看不到」。实测技能全都触发了，丢在「画」这一步 ——
# 3D 特效的同屏名额全场共用一个数，普攻弹道、挂在棋子身上的常驻状态、特效内部的子块全算在
# 里面，Boss 的招牌技能和棋子技能排不上（三路每路 7 个棋子：中画质 56%~63% 的棋子特效层、
# 41%~76% 的 Boss 技能层被拦）。这里钉住修好之后的行为，全部走生产入口
# （VFXBlockRoot.spawn_block / BossProceduralVFX3D.play / BattleVfx._refresh_battle_vfx /
# BattleVfx.cue_play_basic_attack）。
#
# 11.12 lenoliew 同一天用另一种办法修了同一个问题：棋子和 Boss 的技能「默认强制生成、不占名额」，
# 只有普攻 / 兜底闪光 / 神王小脉冲受限。11.13 合并时以他的为底，叠上这边的「小特效」名额
# （普攻和每刀附带的小装饰只和彼此抢，画面太满先省它们）和四处表现修正：
#
#   1. 名额分开算：普攻占满不影响技能；常驻块 / 子块 / 强制块不占名额；用完会还。
#   2. 一招整进整出：第一层放行，后面的层跟着放行；第一层被拦，后面的层也不画。技能本身强制生成，名额满了照样整招出。
#   3. Boss 招牌技能在名额占满时照样出（含延迟出的那几层），只有四个高频小提示会被省。
#   4. 棋子普攻走「小特效」名额，满了先省它；人王天剑、第 N 击技能强制生成、不占任何名额。
#   5. 血怒暴走跟模拟器的事件走，不再按血量自己猜；狂暴兽跳层也不漏里程碑。
#   6. 治疗光效只画模拟真正治疗到的人；表现层抄的半径和模拟对得上。
#   7. Boss 技能屏震认得出真实数据里的 Boss（Boss 数据表里没有 is_boss 字段，靠 id 前缀）。
#
# 画面好不好看不在这里判。

const Harness := preload("res://tools/CheckHarness.gd")

const SIGNATURE_EFFECTS := ["element_meteor", "overload_counter", "mirror_spawn", "holy_purify", "rage_milestone",
	"blood_rage", "blood_qi", "soul_devour", "twin_timer", "twin_revive", "apocalypse_charge",
	"apocalypse_complete", "apocalypse_interrupt"]
const LIGHT_EFFECTS := ["overload_stack", "rage_stack", "blood_lifesteal", "mirror_slash"]

var h := Harness.new("boss_battle_vfx")
var _factory: Script
var _block_script: Script
var _fillers: Array = []
var _filler_parent: Node3D


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	for service_name in ["NetworkService", "RealtimeService", "AnalyticsService", "ChatService", "AnnouncementService", "MailService"]:
		var service := root.get_node_or_null(service_name)
		if service != null:
			service.set_process(false)
	root.get_node("DataRegistry").call("load_all")
	_factory = load("res://scripts/units/UnitFactory.gd")
	_block_script = load("res://effects/vfx3d/VFXBlockRoot.gd")
	var previous_tier: int = VFXQualityBudget.tier
	VFXQualityBudget.tier = VFXQualityBudget.Tier.MEDIUM
	_filler_parent = Node3D.new()
	root.add_child(_filler_parent)
	await _check_budget_classes()
	await _check_effect_ticket()
	await _check_boss_effects_under_saturation()
	await _check_attack_classes()
	await _check_decoration_light()
	await _check_blood_rage_event()
	await _check_rage_milestone_crossing()
	await _check_heal_targets()
	_check_sim_radius_pins()
	_check_shake_policy()
	VFXQualityBudget.tier = previous_tier
	h.finish(self)


# ── 1. 名额分开算 ─────────────────────────────────────────────────────────

func _check_budget_classes() -> void:
	var light := VFXBlockRoot.BudgetClass.LIGHT
	var skill := VFXBlockRoot.BudgetClass.SKILL
	var light_cap := VFXQualityBudget.max_simultaneous_effects_for("ambient")
	var skill_cap := VFXQualityBudget.max_simultaneous_effects_for("important")
	h.expect(_gated(light) == 0 and _gated(skill) == 0, "budget_starts_empty",
		"开始时不该有占着名额的特效（轻量 %d / 技能 %d）" % [_gated(light), _gated(skill)])
	var light_added := _fill(light)
	h.expect(light_added == light_cap, "light_cap_enforced",
		"轻量名额应该正好是 %d 个，实际放行了 %d 个" % [light_cap, light_added])
	h.expect(VFXBlockRoot.can_spawn_block(), "skill_survives_full_light",
		"普攻把轻量名额占满之后，技能必须还能生成 —— 这正是「技能被吃掉」的成因")
	var skill_added := _fill(skill)
	h.expect(skill_added == skill_cap, "skill_cap_enforced",
		"技能名额应该正好是 %d 个，实际放行了 %d 个" % [skill_cap, skill_added])
	h.expect(VFXBlockRoot.spawn_block(_block_script, _filler_parent) == null, "skill_denied_when_full",
		"技能名额占满后，普通技能层应该被拦")
	var forced := VFXBlockRoot.spawn_block(_block_script, _filler_parent, true)
	h.expect(forced != null, "forced_bypasses", "force=true 的招牌 / 常驻块不受名额限制")
	# 直接 new 出来的块（挂在棋子身上的状态、特效内部的子块）只进总数，不占名额。
	var total_before := VFXBlockRoot.active_block_count()
	var loose: Node3D = _block_script.new()
	_filler_parent.add_child(loose)
	h.expect(VFXBlockRoot.active_block_count() == total_before + 1 and _gated(skill) == skill_cap and _gated(light) == light_cap,
		"unmanaged_not_counted", "没过闸门的块（常驻状态 / 子块 / 强制块）不该占名额（轻量 %d / 技能 %d）" % [_gated(light), _gated(skill)])
	_fillers.append(forced)
	_fillers.append(loose)
	await _release_fillers()
	h.expect(_gated(light) == 0 and _gated(skill) == 0, "budget_released",
		"特效释放后名额要还回来（轻量 %d / 技能 %d）" % [_gated(light), _gated(skill)])


# ── 2. 一招整进整出 ───────────────────────────────────────────────────────

func _check_effect_ticket() -> void:
	_fill(VFXBlockRoot.BudgetClass.SKILL)
	# 腾出正好一个位置。
	var last: Node = _fillers.pop_back()
	last.queue_free()
	await process_frame
	await process_frame
	VFXBlockRoot.begin_effect()
	var admitted := 0
	for i in 3:
		var layer := VFXBlockRoot.spawn_block(_block_script, _filler_parent)
		if layer != null:
			admitted += 1
			_fillers.append(layer)
	VFXBlockRoot.end_effect()
	h.expect(admitted == 3, "effect_admitted_whole",
		"第一层放行后，同一招的后两层必须跟着放行（放行了 %d / 3 层）—— 否则就是半截特效" % admitted)
	VFXBlockRoot.begin_effect()
	var late := 0
	for i in 3:
		var layer := VFXBlockRoot.spawn_block(_block_script, _filler_parent)
		if layer != null:
			late += 1
			_fillers.append(layer)
	VFXBlockRoot.end_effect()
	h.expect(late == 0, "effect_denied_whole", "第一层被拦后，同一招的其余层也不该画（画了 %d 层）" % late)
	h.expect(VFXBlockRoot.spawn_block(_block_script, _filler_parent, true) != null, "forced_outside_ticket",
		"整招被拦不影响强制块")
	await _release_fillers()
	for child in _filler_parent.get_children():
		child.queue_free()
	await process_frame
	# 生产入口：人王天剑（一招 6 层）是技能，强制生成 —— 只剩一个名额时 6 层都出，名额占满时也照样整招出，
	# 一层都不该被拦（11.12 以前它和普攻挤一个名额，实测 4 次里有 3 次没出）。
	var route: Node3D = (load("res://effects/BossProceduralVFX3D.gd") as Script).new()
	root.add_child(route)
	var composer := route.get_node("UnitSkillVFXComposer3D")
	_fill(VFXBlockRoot.BudgetClass.SKILL)
	var spare: Node = _fillers.pop_back()
	spare.queue_free()
	await process_frame
	await process_frame
	var before := composer.get_child_count()
	var denials := VFXBlockRoot.cap_denial_count()
	route.call("play", "unique_king_growth", Vector3(0.0, 0.5, 1.0), Vector3(0.0, 0.5, -1.0), {})
	var layers := composer.get_child_count() - before
	h.expect(layers >= 2 and VFXBlockRoot.cap_denial_count() == denials, "play_admits_whole_effect",
		"只剩一个名额时，一招多层的技能要整招放行（出了 %d 层，被拦 %d 层）" % [layers, VFXBlockRoot.cap_denial_count() - denials])
	before = composer.get_child_count()
	route.call("play", "unique_king_growth", Vector3(0.0, 0.5, 1.0), Vector3(0.0, 0.5, -1.0), {})
	layers = composer.get_child_count() - before
	h.expect(layers >= 2 and VFXBlockRoot.cap_denial_count() == denials, "play_skill_ignores_full_budget",
		"名额占满时技能照样整招出（出了 %d 层，被拦 %d 层）" % [layers, VFXBlockRoot.cap_denial_count() - denials])
	await _release_fillers()
	route.queue_free()
	await process_frame
	await process_frame


# ── 3. Boss 招牌技能在名额占满时照样出 ─────────────────────────────────────

func _check_boss_effects_under_saturation() -> void:
	var route: Node3D = (load("res://effects/BossProceduralVFX3D.gd") as Script).new()
	root.add_child(route)
	var composer := route.get_node("BossSkillVFXComposer3D")
	_fill(VFXBlockRoot.BudgetClass.LIGHT)
	_fill(VFXBlockRoot.BudgetClass.SKILL)
	var origin := Vector3(0.0, 0.0, -1.5)
	var target := Vector3(0.4, 0.0, 1.2)
	var context := {"targets": [target, target + Vector3(0.6, 0.0, 0.0)], "lane_targets": [target], "stacks": 5}
	var denials := VFXBlockRoot.cap_denial_count()
	var late_layers := [0]
	composer.child_entered_tree.connect(func(_node: Node) -> void: late_layers[0] += 1)
	for effect: String in SIGNATURE_EFFECTS:
		var before := composer.get_child_count()
		var looping: Node3D = route.call("play", effect, origin, target, context)
		h.expect(composer.get_child_count() > before, "signature_" + effect,
			"名额占满时，Boss 招牌技能 %s 仍然必须生成" % effect)
		if looping != null:
			looping.queue_free()
	h.expect(VFXBlockRoot.cap_denial_count() == denials, "signature_never_denied",
		"Boss 招牌技能没有任何一层该被名额拦掉（被拦 %d 层）" % (VFXBlockRoot.cap_denial_count() - denials))
	# 延迟出的层：陨石 0.68 秒后的爆炸 / 地裂 / 火星、雷球 0.38 秒后的落雷 / 电场。
	late_layers[0] = 0
	await create_timer(0.85).timeout
	h.expect(late_layers[0] >= 6 and VFXBlockRoot.cap_denial_count() == denials, "signature_late_layers",
		"招牌技能延迟出的层（陨石爆炸、落雷）在名额占满时也必须生成（生成 %d 层，被拦 %d 层）" % [
			late_layers[0], VFXBlockRoot.cap_denial_count() - denials])
	for effect: String in LIGHT_EFFECTS:
		var before := composer.get_child_count()
		route.call("play", effect, origin, target, context)
		h.expect(composer.get_child_count() == before, "light_dropped_" + effect,
			"高频小提示 %s 在轻量名额占满时应该被省掉" % effect)
	await _release_fillers()
	for effect: String in LIGHT_EFFECTS:
		var before := composer.get_child_count()
		route.call("play", effect, origin, target, context)
		h.expect(composer.get_child_count() > before, "light_plays_" + effect,
			"轻量名额有空时，%s 应该正常生成" % effect)
	route.queue_free()
	await process_frame
	await process_frame


# ── 4. 普攻走「小特效」名额，人王天剑 / 第 N 击技能强制生成 ─────────────────────

func _check_attack_classes() -> void:
	var light := VFXBlockRoot.BudgetClass.LIGHT
	var skill := VFXBlockRoot.BudgetClass.SKILL
	var setup := _battle()
	var battle: Control = setup.battle
	# 技能强制生成、不占名额，计数不会动 —— 有没有画出来，看 composer 底下多没多节点。
	var composer: Node = (setup.route as Node).get_node("UnitSkillVFXComposer3D")
	var archer := _fighter("p_archer", _unit_def("human_archer", 1), "player", Vector2(300.0, 320.0))
	archer["attack_count"] = 1
	var king := _fighter("p_king", _unit_def("human_king", 1), "player", Vector2(360.0, 320.0))
	var foe := _fighter("e_foe", _unit_def("human_swordsman", 1), "enemy", Vector2(340.0, 200.0))
	var state := {"player": [archer, king], "enemy": [foe], "visual_events": []}
	_seed(battle, state)
	var light_before := _gated(light)
	var skill_before := _gated(skill)
	battle.call("cue_play_basic_attack", "p_archer", "e_foe", true)
	h.expect(_gated(light) > light_before and _gated(skill) == skill_before, "basic_attack_is_light",
		"普通一箭应该只占轻量名额（轻量 %d→%d，技能 %d→%d）" % [light_before, _gated(light), skill_before, _gated(skill)])
	light_before = _gated(light)
	skill_before = _gated(skill)
	var spawned_before := composer.get_child_count()
	battle.call("cue_play_basic_attack", "p_king", "e_foe", false)
	h.expect(composer.get_child_count() > spawned_before and _gated(skill) == skill_before and _gated(light) == light_before,
		"king_sword_forced", "人王的天剑是技能：一定生成、不占任何名额（节点 %d→%d，轻量 %d→%d，技能 %d→%d）" % [
			spawned_before, composer.get_child_count(), light_before, _gated(light), skill_before, _gated(skill)])
	# 第 4 箭是技能：强化箭强制生成。
	archer["attack_count"] = 4
	battle.call("_refresh_battle_vfx", state)
	light_before = _gated(light)
	skill_before = _gated(skill)
	spawned_before = composer.get_child_count()
	battle.call("cue_play_basic_attack", "p_archer", "e_foe", true)
	h.expect(composer.get_child_count() > spawned_before and _gated(skill) == skill_before and _gated(light) == light_before,
		"nth_attack_forced", "第 4 箭的强化箭是技能：一定生成、不占任何名额（节点 %d→%d，轻量 %d→%d，技能 %d→%d）" % [
			spawned_before, composer.get_child_count(), light_before, _gated(light), skill_before, _gated(skill)])
	# 「小特效」名额占满：普通一箭被省，人王的剑照出。
	archer["attack_count"] = 5
	battle.call("_refresh_battle_vfx", state)
	_fill(light)
	light_before = _gated(light)
	skill_before = _gated(skill)
	battle.call("cue_play_basic_attack", "p_archer", "e_foe", true)
	h.expect(_gated(light) == light_before and _gated(skill) == skill_before, "basic_attack_respects_light_cap",
		"「小特效」名额占满时普通一箭应该被省掉，而且不能去占技能名额")
	spawned_before = composer.get_child_count()
	battle.call("cue_play_basic_attack", "p_king", "e_foe", false)
	h.expect(composer.get_child_count() > spawned_before, "king_sword_survives_full_light",
		"普攻把「小特效」名额占满时，人王的天剑仍然要出")
	await _release_fillers()
	battle.queue_free()
	await process_frame
	await process_frame


# 每刀附带的小装饰（这里拿中毒）在「小特效」名额里受限；名额外（技能时刻）照样强制生成。
# 钉的是 UnitSkillVFXComposer3D._block 在 11.13 合并时加的那一句：lenoliew 的版本里它一律强制。
func _check_decoration_light() -> void:
	var light := VFXBlockRoot.BudgetClass.LIGHT
	var route: Node3D = (load("res://effects/BossProceduralVFX3D.gd") as Script).new()
	root.add_child(route)
	var composer := route.get_node("UnitSkillVFXComposer3D")
	var origin := Vector3(0.0, 0.5, 1.0)
	var target := Vector3(0.0, 0.5, -1.0)
	var light_before := _gated(light)
	var before := composer.get_child_count()
	VFXBlockRoot.begin_budget_class(light)
	route.call("play", "poison_attack", origin, target, {})
	VFXBlockRoot.end_budget_class()
	h.expect(composer.get_child_count() > before and _gated(light) > light_before, "decoration_counts_light",
		"小装饰（中毒）在「小特效」名额有空时要正常生成，并且占「小特效」名额（节点 %d→%d，小特效 %d→%d）" % [
			before, composer.get_child_count(), light_before, _gated(light)])
	_fill(light)
	before = composer.get_child_count()
	VFXBlockRoot.begin_budget_class(light)
	route.call("play", "poison_attack", origin, target, {})
	VFXBlockRoot.end_budget_class()
	h.expect(composer.get_child_count() == before, "decoration_dropped_when_light_full",
		"「小特效」名额占满时，小装饰（中毒）应该被省掉（多了 %d 个节点）" % (composer.get_child_count() - before))
	before = composer.get_child_count()
	route.call("play", "poison_attack", origin, target, {})
	h.expect(composer.get_child_count() > before, "decoration_outside_light_forced",
		"不在「小特效」名额里时照样强制生成（和 lenoliew 11.12 的默认一致）")
	await _release_fillers()
	route.queue_free()
	await process_frame
	await process_frame


# ── 5. 血怒暴走跟事件走 / 狂暴里程碑不漏 ───────────────────────────────────

func _check_blood_rage_event() -> void:
	var setup := _battle()
	var battle: Control = setup.battle
	var composer: Node = (setup.route as Node).get_node("BossSkillVFXComposer3D")
	var demon := _boss_fighter("enemy_L0_boss", "boss_blood_demon", Vector2(500.0, 200.0))
	var foe := _fighter("p_foe", _unit_def("human_swordsman", 1), "player", Vector2(500.0, 320.0))
	demon["hp"] = 600
	var state := {"player": [foe], "enemy": [demon], "visual_events": []}
	_seed(battle, state)
	var snapshot: Dictionary = battle.get("_vfx_prev_units")
	h.expect(bool((snapshot.get("enemy_L0_boss", {}) as Dictionary).get("is_boss", false)), "real_boss_flagged",
		"真实 Boss 数据（没有 is_boss 字段）在表现快照里必须被认成 Boss")
	# 血量跌破 35%，但模拟器没有发暴走事件：不许自己猜。
	demon["hp"] = 300
	battle.call("_refresh_battle_vfx", state)
	h.expect(_named(composer, "BossBloodRage") == 0, "rage_not_guessed_from_hp",
		"没有暴走事件时，不能因为血量跌破某条线就播暴走特效")
	# 模拟器在 50% 触发：事件到了就播，哪怕血量还在 35% 以上。
	demon["hp"] = 480
	(state.visual_events as Array).append({"type": "sfx_proc", "skill_id": "blood_rage",
		"source_uid": "enemy_L0_boss", "target_uid": "enemy_L0_boss", "time": 3.0})
	battle.call("_refresh_battle_vfx", state)
	h.expect(_named(composer, "BossBloodRage") == 1, "rage_follows_event",
		"暴走事件到达的那一帧必须播暴走特效（播了 %d 次）" % _named(composer, "BossBloodRage"))
	battle.call("_refresh_battle_vfx", state)
	h.expect(_named(composer, "BossExtraBloodQi") == 1, "rage_qi_started", "暴走后要挂上常驻的红色粒子气")
	# 吸血把血量拉回 35% 以上再跌下去：不重复播。
	for hp_value: int in [300, 480, 300, 420, 250]:
		demon["hp"] = hp_value
		battle.call("_refresh_battle_vfx", state)
	h.expect(_named(composer, "BossBloodRage") == 1, "rage_plays_once",
		"暴走只进一次，血量来回跨线不该重复播（播了 %d 次）" % _named(composer, "BossBloodRage"))
	battle.queue_free()
	await process_frame
	await process_frame


func _check_rage_milestone_crossing() -> void:
	var setup := _battle()
	var battle: Control = setup.battle
	var composer: Node = (setup.route as Node).get_node("BossSkillVFXComposer3D")
	var beast := _boss_fighter("enemy_L0_boss", "boss_rage_beast", Vector2(500.0, 200.0))
	var foe := _fighter("p_foe", _unit_def("human_swordsman", 1), "player", Vector2(500.0, 320.0))
	beast["skill_stacks"] = 4
	var state := {"player": [foe], "enemy": [beast], "visual_events": []}
	_seed(battle, state)
	# 卡顿时一次补两个 tick：层数从 4 直接到 6，跳过了 5。
	beast["skill_stacks"] = 6
	battle.call("_refresh_battle_vfx", state)
	h.expect(_named(composer, "BossRageAura") == 1, "rage_milestone_not_skipped",
		"层数一帧里跨过 5 的倍数时，里程碑咆哮不能漏（播了 %d 次）" % _named(composer, "BossRageAura"))
	beast["skill_stacks"] = 7
	battle.call("_refresh_battle_vfx", state)
	h.expect(_named(composer, "BossRageAura") == 1 and _named(composer, "BossRageStack") == 1, "rage_plain_stack",
		"没跨过 5 的倍数时只播普通叠层")
	battle.queue_free()
	await process_frame
	await process_frame


# ── 6. 治疗光效只画真正治疗到的人 ──────────────────────────────────────────

func _check_heal_targets() -> void:
	var setup := _battle()
	var battle: Control = setup.battle
	var composer: Node = (setup.route as Node).get_node("BossSkillVFXComposer3D")
	var priest := _boss_fighter("enemy_L0_boss", "boss_holy_priest", Vector2(500.0, 200.0))
	var near := _fighter("enemy_near", _unit_def("human_swordsman", 1), "enemy", Vector2(600.0, 200.0))
	var far := _fighter("enemy_far", _unit_def("human_swordsman", 1), "enemy", Vector2(900.0, 200.0))
	var cleric := _fighter("p_cleric", _unit_def("human_cleric", 1), "player", Vector2(500.0, 320.0))
	var ally_near := _fighter("p_near", _unit_def("human_swordsman", 1), "player", Vector2(600.0, 320.0))
	var ally_far := _fighter("p_far", _unit_def("human_swordsman", 1), "player", Vector2(100.0, 320.0))
	var state := {"player": [cleric, ally_near, ally_far], "enemy": [priest, near, far], "visual_events": []}
	_seed(battle, state)
	priest["skill_ready"] = 5.0
	battle.call("_refresh_battle_vfx", state)
	# lenoliew 11.12：三路祭司常同一拍净化，治疗层改成每个目标晚一帧建（出现时刻不变），等它们建完再数。
	await create_timer(0.1).timeout
	h.expect(_named(composer, "BossHolyHeal") == 2, "purify_only_nearby",
		"圣愈祭司的治疗光效只该画在自己和身边的友军身上，远处那只没被治疗（画了 %d 个）" % _named(composer, "BossHolyHeal"))
	var snapshot: Dictionary = battle.get("_vfx_prev_units")
	var radius := float(battle.get_script().get_script_constant_map().get("GROUP_HEAL_SIM_RADIUS", -1.0))
	var healed: Array = battle.call("_nearby_team_world_positions", snapshot.get("p_cleric", {}), snapshot, radius)
	h.expect(healed.size() == 2, "group_heal_only_nearby",
		"牧师 / 天使的群体治疗光效只该画在施法者和身边的友军身上（取到 %d 个）" % healed.size())
	battle.queue_free()
	await process_frame
	await process_frame


# 表现层抄了模拟里的两个半径。这里直接跑模拟函数，把「抄的数」和「真的数」钉在一起。
# 模拟脚本运行期 load：--script 的主脚本在解析期还认不到 autoload（GameState / RngService），
# 直接写类名会让整族模拟脚本编译失败。
func _check_sim_radius_pins() -> void:
	var shared: Script = load("res://scripts/battle/BattleSimShared.gd")
	var skills: Script = load("res://scripts/battle/BattleSimSkills.gd")
	var radius := float((load("res://scenes/battle/BattleVfx.gd") as Script).get_script_constant_map().get("GROUP_HEAL_SIM_RADIUS", -1.0))
	var caster := _sim_unit("c", Vector2.ZERO)
	var edge := _sim_unit("edge", Vector2(radius, 0.0))
	var beyond := _sim_unit("beyond", Vector2(radius + 1.0, 0.0))
	shared.call("_group_heal", caster, [caster, edge, beyond], 0.05)
	h.expect(int(edge.hp) > 100 and int(beyond.hp) == 100, "group_heal_radius_pin",
		"牧师群体治疗的模拟半径和表现层抄的 %.0f 对不上（边上 hp=%d，外面 hp=%d）" % [radius, int(edge.hp), int(beyond.hp)])
	var angel := _sim_unit("angel", Vector2.ZERO)
	var angel_edge := _sim_unit("angel_edge", Vector2(radius, 0.0))
	var angel_beyond := _sim_unit("angel_beyond", Vector2(radius + 1.0, 0.0))
	skills.call("_skill_nearby_ally_heal_buff", angel, [angel, angel_edge, angel_beyond], {})
	h.expect(int(angel_edge.hp) > 100 and int(angel_beyond.hp) == 100, "heal_buff_radius_pin",
		"天使治疗的模拟半径和表现层抄的 %.0f 对不上（边上 hp=%d，外面 hp=%d）" % [radius, int(angel_edge.hp), int(angel_beyond.hp)])
	var purify_radius := float(skills.get_script_constant_map().get("HOLY_PURIFY_RADIUS", -1.0))
	var priest := _sim_unit("priest", Vector2.ZERO)
	var purify_edge := _sim_unit("purify_edge", Vector2(purify_radius, 0.0))
	var purify_beyond := _sim_unit("purify_beyond", Vector2(purify_radius + 1.0, 0.0))
	skills.call("_skill_holy_purify", priest, [priest, purify_edge, purify_beyond], {})
	h.expect(int(purify_edge.hp) > 100 and int(purify_beyond.hp) == 100, "purify_radius_pin",
		"圣愈祭司净化的模拟半径不再是 HOLY_PURIFY_RADIUS（边上 hp=%d，外面 hp=%d）" % [int(purify_edge.hp), int(purify_beyond.hp)])


# ── 7. Boss 技能屏震 ───────────────────────────────────────────────────────

func _check_shake_policy() -> void:
	var policy_script: Script = load("res://scripts/battle/BattleCameraShakePolicy.gd")
	var bosses: Array = root.get_node("DataRegistry").call("get_table", "bosses").get("bosses", [])
	h.expect(not bosses.is_empty(), "boss_table_loaded", "Boss 数据表没读到")
	for boss_value in bosses:
		var boss: Dictionary = boss_value
		var boss_id := str(boss.get("id", ""))
		var source := {"uid": "enemy_L0_boss", "id": boss_id, "def": boss, "star": 1}
		var policy = policy_script.new()
		var damage := {"type": "hit_number", "kind": "dmg", "skill": true, "amount": 240,
			"skill_id": str(boss.get("skill_id", "")), "source_uid": "enemy_L0_boss", "time": 6.0}
		h.expect(bool(policy.call("accepts", damage, source, false)), "boss_skill_shakes_" + boss_id,
			"%s 的技能打出伤害时应该震屏（Boss 数据表里没有 is_boss 字段，要靠 id 前缀认）" % boss_id)
		h.expect(not bool(policy.call("accepts", damage, source, false)), "boss_shake_once_" + boss_id,
			"同一次技能伤害只震一下")
	var demon_def: Dictionary = {}
	for boss_value in bosses:
		if str((boss_value as Dictionary).get("id", "")) == "boss_blood_demon":
			demon_def = boss_value
	var rage := {"type": "sfx_proc", "skill_id": "blood_rage", "source_uid": "enemy_L0_boss", "time": 4.0}
	h.expect(bool(policy_script.new().call("accepts", rage, {"uid": "enemy_L0_boss", "id": "boss_blood_demon", "def": demon_def, "star": 1}, false)),
		"blood_rage_shakes", "血怒魔王进入暴走那一下应该震屏")
	var swordsman := _unit_def("human_swordsman", 1)
	var plain := {"type": "hit_number", "kind": "dmg", "skill": true, "amount": 99,
		"skill_id": str(swordsman.get("skill_id", "")), "source_uid": "p0", "time": 1.0}
	h.expect(not bool(policy_script.new().call("accepts", plain, {"uid": "p0", "id": "human_swordsman", "def": swordsman, "star": 1}, true)),
		"plain_unit_no_shake", "普通棋子的技能伤害不该震屏")


# ── 工具 ─────────────────────────────────────────────────────────────────

func _gated(budget_class: int) -> int:
	return VFXBlockRoot.gated_block_count(budget_class)


# 用生产闸门把某一类名额占满，返回占了多少个。
func _fill(budget_class: int) -> int:
	var added := 0
	VFXBlockRoot.begin_budget_class(budget_class)
	while added < 400:
		var filler := VFXBlockRoot.spawn_block(_block_script, _filler_parent)
		if filler == null:
			break
		_fillers.append(filler)
		added += 1
	VFXBlockRoot.end_budget_class()
	return added


func _release_fillers() -> void:
	for filler in _fillers:
		if is_instance_valid(filler):
			(filler as Node).queue_free()
	_fillers.clear()
	await process_frame
	await process_frame


# 名字里带 token 的子节点个数。同名兄弟会被引擎改成「名字2」，所以按包含判。
func _named(parent: Node, token: String) -> int:
	var count := 0
	for child in parent.get_children():
		if String(child.name).contains(token):
			count += 1
	return count


func _battle() -> Dictionary:
	var battle: Control = (load("res://scenes/battle/BattleVfx.gd") as Script).new()
	root.add_child(battle)
	var arena := Control.new()
	arena.size = Vector2(1000.0, 520.0)
	battle.add_child(arena)
	battle.set("_arena", arena)
	var route: Node3D = (load("res://effects/BossProceduralVFX3D.gd") as Script).new()
	battle.add_child(route)
	battle.set("_battle_3d_vfx_root", route)
	return {"battle": battle, "route": route}


func _seed(battle: Control, state: Dictionary) -> void:
	battle.set("_state", state)
	battle.call("_refresh_battle_vfx", state)
	battle.call("_refresh_battle_vfx", state)


func _unit_def(unit_id: String, star: int) -> Dictionary:
	var parsed: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/units/race_units.json"))
	for definition: Dictionary in parsed.get("units", []):
		if str(definition.get("id", "")) == unit_id:
			return _factory.call("apply_star_stats", definition, star)
	return {"id": unit_id}


func _fighter(uid: String, definition: Dictionary, team: String, pos: Vector2) -> Dictionary:
	return {"uid": uid, "id": str(definition.get("id", "")), "name": str(definition.get("name", "")), "team": team, "lane": 0,
		"hp": 1000, "max_hp": 1000, "shield": 0, "alive": true, "pos": pos, "def": definition, "statuses": {},
		"range_px": 32.0 + maxf(0.0, float(definition.get("range", 1)) - 1.0) * 72.0, "skill_ready": 0.0,
		"attack_count": 0, "star": int(definition.get("star", 1)), "vfx_attack_target_uid": "", "vfx_skill_target_uid": ""}


# 真实 Boss 数据原样拿来（不补 is_boss —— 生产数据里就没有这个字段）。
func _boss_fighter(uid: String, boss_id: String, pos: Vector2) -> Dictionary:
	for boss_value in root.get_node("DataRegistry").call("get_table", "bosses").get("bosses", []):
		if str((boss_value as Dictionary).get("id", "")) == boss_id:
			return _fighter(uid, (boss_value as Dictionary).duplicate(true), "enemy", pos)
	h.fail("boss_missing_" + boss_id, "Boss 数据表里没有 %s" % boss_id)
	return _fighter(uid, {"id": boss_id}, "enemy", pos)


func _sim_unit(uid: String, pos: Vector2) -> Dictionary:
	return {"uid": uid, "id": "human_swordsman", "team": "player", "alive": true, "pos": pos, "hp": 100, "max_hp": 1000,
		"atk": 50, "defense": 5, "shield": 0, "statuses": {}}
