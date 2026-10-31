extends Node

# V2 P1-05 第 2 条的门禁：死亡要"先受击停顿，再溶解/倒下/淡出，血条和状态图标同步，
# 不突然消失"。
#
# 实测把 V2 的描述修正掉一半：**身体本来就不是瞬间消失的**。
# cue_claim_corpses() 会在剪枝前把 actor 扣下来，cue_play_death() 让它下沉 0.35、
# 缩到 0.72，走完才 release。所以"倒下"这件事早就有了。
#
# 但实测也找出了三个真缺口，这个门禁守的就是这三条：
#
# 1. **淡出根本没生效。** 改前那段 transparency tween 只遍历 actor.get_children()，
#    而 actor 的直接子节点是 ActorRoot 加六个锚点 —— 一个 GeometryInstance3D 都没有
#    （模型是 attach_model() 挂到 actor_root 底下的）。循环一次都不匹配，
#    于是死亡只有下沉和缩小，没有任何淡出。
#
# 2. **2D 的名字/血条层是当场释放的。** _sync_unit_nodes() 每帧剪枝，单位一离开
#    存活集合就 queue_free()。尸体要淡 0.35 秒，血条却在第一帧就没了。
#
# 3. **状态图标同理，而且更隐蔽。** detach_actor_for_death() 之前 queue_free() 掉
#    StatusVFXController，但图标的 Sprite3D 挂在**锚点**下（锚点是 actor 的子节点，
#    不是控制器的），所以释放控制器压根收不掉图标 —— 它们会以满不透明度骑在
#    正在淡出的尸体上。
#
# 这里不测"好不好看"，只测这三条机械不变式。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const BattleVfxScript := preload("res://scenes/battle/BattleVfx.gd")
const UnitActor3DScript := preload("res://effects/runtime/presentation/UnitActor3D.gd")
const StatusVFXScript := preload("res://scenes/battle/StatusVFXController.gd")
const CHECK_NAME := "battle_death_exit"

const DEATH_SEC := 0.35

var _h: RefCounted


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_check_fade_targets_reach_the_mesh()
	_check_status_icons_are_reachable()
	_check_dead_unit_nodes_are_not_recreated()
	await _check_claim_zeroes_hp_and_watchdog_releases()
	await _check_release_cleans_playing_death()
	_check_source_contract()
	_h.finish(get_tree())


# 第 1 条：淡出必须够得到真正的网格。
#
# 按战斗里的真实结构搭一个 actor：模型挂在 actor_root 下、状态图标挂在锚点下。
# 只看直接子节点的写法在这个结构上一个目标都找不到 —— 这正是改前的 bug。
func _check_fade_targets_reach_the_mesh() -> void:
	var actor: Node3D = UnitActor3DScript.new()
	add_child(actor)
	actor.configure_contract(0.98, "melee")

	# 模型：一个 MeshInstance3D，走 attach_model() 进 actor_root。
	var model := Node3D.new()
	model.name = "Model"
	var mesh := MeshInstance3D.new()
	mesh.name = "Body"
	mesh.mesh = BoxMesh.new()
	model.add_child(mesh)
	actor.attach_model(model)

	# 状态图标：走真实控制器，锚点由它自建。
	var status: Node3D = StatusVFXScript.new()
	actor.add_child(status)
	status.update_from_fighter({"shield": 12, "statuses": {"stun": {"remaining": 3.0}}})

	var vfx := BattleVfxScript.new()
	add_child(vfx)
	var targets: Array = vfx._death_fade_targets(actor)

	_h.expect(targets.has(mesh),
		"fade_misses_mesh",
		"淡出目标里没有模型网格 —— 模型挂在 actor_root 下，只遍历直接子节点是找不到的（改前就是这个 bug）")

	# 反向对照：直接子节点里确实一个 GeometryInstance3D 都没有。
	# 这条把"为什么改前的写法无效"钉死，防止有人又改回去。
	var direct := 0
	for child in actor.get_children():
		if child is GeometryInstance3D:
			direct += 1
	_h.expect(direct == 0,
		"actor_structure_changed",
		"actor 的直接子节点里出现了 %d 个 GeometryInstance3D —— 结构变了，本门禁的前提要重新确认"
			% direct)

	_h.expect(targets.size() >= 2,
		"fade_targets_too_few",
		"只找到 %d 个淡出目标；模型网格和状态图标都该在里面" % targets.size())
	for target in targets:
		_h.expect(target is GeometryInstance3D,
			"fade_target_not_geometry", "淡出目标里混进了非 GeometryInstance3D 的节点")

	vfx.queue_free()
	actor.queue_free()


# 第 3 条：状态图标必须落在淡出目标里。
#
# 它们是 actor 的**孙节点**（锚点 -> 图标），而且释放 StatusVFXController
# 收不掉它们 —— 这两点一起构成了"图标以满不透明度骑在尸体上"。
func _check_status_icons_are_reachable() -> void:
	var actor: Node3D = UnitActor3DScript.new()
	add_child(actor)
	actor.configure_contract(0.98, "melee")
	var status: Node3D = StatusVFXScript.new()
	actor.add_child(status)
	status.update_from_fighter({"shield": 9, "statuses": {"poison": {"remaining": 4.0}}})

	var sprites: Array[Sprite3D] = []
	for kind in ["shield", "poison"]:
		var sprite = status._sprites.get(kind)
		if sprite is Sprite3D:
			sprites.append(sprite as Sprite3D)
	if not _h.expect(sprites.size() == 2, "status_sprites_missing",
		"合成 fighter 没能产出护盾和中毒两个图标（拿到 %d 个）" % sprites.size()):
		actor.queue_free()
		return

	# 它们不是控制器的子节点 —— 这就是为什么 queue_free(控制器) 收不掉它们。
	for sprite in sprites:
		_h.expect(not status.is_ancestor_of(sprite),
			"status_sprite_owned_by_controller",
			"%s 变成了控制器的子节点。结构变了：释放控制器现在能收掉图标，"
				% sprite.name + "detach_actor_for_death() 里那段注释和做法要重新确认")
		_h.expect(actor.is_ancestor_of(sprite),
			"status_sprite_outside_actor",
			"%s 不在 actor 子树里，死亡淡出够不到它" % sprite.name)

	var vfx := BattleVfxScript.new()
	add_child(vfx)
	var targets: Array = vfx._death_fade_targets(actor)
	for sprite in sprites:
		_h.expect(targets.has(sprite),
			"status_icon_not_faded",
			"状态图标 %s 不在淡出目标里 —— 它会以满不透明度骑在正在淡出的尸体上" % sprite.name)

	# 控制器必须能被停掉：不停 _process，它每帧把 modulate.a 写回去，
	# 和淡出 tween 逐帧打架（和 P1-03 同一个约束）。
	status.set_process(false)
	_h.expect(not status.is_processing(),
		"status_controller_cannot_stop",
		"停不掉状态控制器的每帧刷新，淡出会被它逐帧覆写")

	vfx.queue_free()
	actor.queue_free()


# Round 20 keeps dead fighters in the replay state arrays. They must not be
# reconstructed every refresh after their UI nodes have been pruned. Inspect the
# arena child count immediately: queue_free() is deferred, so a create-then-prune
# implementation cannot fake a pass by ending with an empty active dictionary.
func _check_dead_unit_nodes_are_not_recreated() -> void:
	var renderer := BattleVfxScript.new()
	renderer.name = "RendererLifecycleProbe"
	add_child(renderer)
	var arena := Control.new()
	arena.name = "Arena"
	renderer.add_child(arena)
	renderer._arena = arena

	var fighters: Array = []
	for i in range(67):
		fighters.append({
			"uid": "dead_%02d" % i,
			"id": "dead_probe",
			"name": "Dead",
			"team": "enemy",
			"alive": false,
			"hp": 0,
			"max_hp": 100,
			"pos": Vector2(800.0, 360.0),
		})
	renderer._sync_unit_nodes(fighters, {})
	_h.expect(arena.get_child_count() == 0,
		"dead_nodes_recreated",
		"67 个死亡 fighter 产生了 %d 个待释放 2D 节点；它们会在每个渲染帧重复创建" % arena.get_child_count())

	var living := {
		"uid": "living_summon",
		"id": "living_probe",
		"name": "Living",
		"team": "player",
		"alive": true,
		"hp": 100,
		"max_hp": 100,
		"pos": Vector2(400.0, 360.0),
	}
	fighters.append(living)
	var living_ids := {"living_summon": true}
	renderer._sync_unit_nodes(fighters, living_ids)
	_h.expect(arena.get_child_count() == 1 and renderer._unit_nodes.size() == 1,
		"living_node_not_created_once",
		"存活召唤物应只创建 1 个节点；arena=%d active=%d"
			% [arena.get_child_count(), renderer._unit_nodes.size()])
	for _frame in range(120):
		renderer._sync_unit_nodes(fighters, living_ids)
	_h.expect(arena.get_child_count() == 1,
		"living_node_recreated",
		"同一存活单位连续刷新后 arena 节点数变成 %d（应保持 1）" % arena.get_child_count())

	renderer.queue_free()


func _death_claim_probe(vfx: Node, uid: String) -> Dictionary:
	var actor := Node3D.new()
	actor.name = "Actor_%s" % uid
	vfx.add_child(actor)
	vfx._battle_3d_models[uid] = actor
	var unit_node := Control.new()
	unit_node.name = "UnitNode_%s" % uid
	var hp_fill := ColorRect.new()
	hp_fill.name = "HpFill"
	hp_fill.scale.x = 0.08
	unit_node.add_child(hp_fill)
	vfx.add_child(unit_node)
	vfx._unit_nodes[uid] = unit_node
	vfx._hp_fill_by_id[uid] = hp_fill
	return {"actor": actor, "unit_node": unit_node, "hp_fill": hp_fill}


# Claim happens before the Director starts the cue. The bar must become empty at
# that boundary, and an unplayed/cancelled cue must eventually release ownership.
func _check_claim_zeroes_hp_and_watchdog_releases() -> void:
	var vfx := BattleVfxScript.new()
	add_child(vfx)
	var uid := "watchdog_probe"
	var probe := _death_claim_probe(vfx, uid)
	vfx.cue_claim_corpses([{"type": "death", "source_uid": uid}])
	_h.expect(is_zero_approx(float((probe.hp_fill as ColorRect).scale.x)),
		"claimed_hp_not_zero", "死亡接管后血条仍保留最后一小格")
	_h.expect(vfx._cue_corpses.has(uid) and vfx._dying_unit_nodes.has(uid),
		"death_claim_not_owned", "死亡模型或 2D 层没有进入待播放接管表")
	await get_tree().create_timer(vfx.DEATH_CLAIM_WATCHDOG_SEC + 0.1).timeout
	await get_tree().process_frame
	_h.expect(not vfx._cue_corpses.has(uid) and not vfx._dying_unit_nodes.has(uid)
		and not vfx._pending_death_claim_tokens.has(uid),
		"unplayed_claim_not_released", "未播放的死亡 cue 超时后仍占有模型或血条")
	_h.expect(not is_instance_valid(probe.actor) and not is_instance_valid(probe.unit_node),
		"unplayed_nodes_still_alive", "未播放死亡 cue 的场景节点没有被释放")
	vfx.queue_free()


# cue_release_corpses is used by skip/seek/restart. It must also own a death that
# has already left the pending table and entered its fade tween.
func _check_release_cleans_playing_death() -> void:
	var vfx := BattleVfxScript.new()
	add_child(vfx)
	var uid := "active_probe"
	var probe := _death_claim_probe(vfx, uid)
	vfx.cue_claim_corpses([{"type": "death", "source_uid": uid}])
	_h.expect(vfx.cue_play_death(uid, 3.0), "active_death_did_not_start",
		"合成死亡 cue 没有进入播放状态")
	_h.expect(vfx._active_death_actors.size() == 1,
		"active_death_not_tracked", "播放中的死亡模型没有进入活动回收表")
	vfx.cue_release_corpses()
	await get_tree().process_frame
	_h.expect(vfx._active_death_actors.is_empty() and vfx._dying_unit_nodes.is_empty(),
		"active_death_not_released", "跳过/重开清场后仍保留播放中的尸体或血条")
	_h.expect(not is_instance_valid(probe.actor) and not is_instance_valid(probe.unit_node),
		"active_nodes_still_alive", "跳过/重开没有释放播放中的死亡节点")
	vfx.queue_free()


# 第 2 条：2D 层必须和身体走同一条接管路径。
#
# 这条只能看源码：血条的接管发生在 BattleScreen 的回放循环里，
# headless 起不了完整战斗。断言的是"接管这件事被接上了"，
# 不是"淡出好不好看"——后者由截图定。
func _check_source_contract() -> void:
	var renderer := FileAccess.get_file_as_string("res://scenes/battle/BattleRenderer.gd")
	var vfx := FileAccess.get_file_as_string("res://scenes/battle/BattleVfx.gd")
	var screen := FileAccess.get_file_as_string("res://scenes/battle/BattleScreen.gd")
	if not _h.expect(not renderer.is_empty() and not vfx.is_empty() and not screen.is_empty(),
		"source_unreadable", "读不到 BattleRenderer.gd / BattleVfx.gd / BattleScreen.gd"):
		return

	# 接管必须和身体在同一处、同一时机发生，否则中间那趟剪枝照样会释放血条。
	_h.expect(vfx.contains("claim_unit_node_for_death(uid)"),
		"unit_node_not_claimed",
		"cue_claim_corpses() 没有把 2D 层一起扣下来 —— 血条会在尸体还在淡出时被剪枝释放")
	_h.expect(vfx.contains("_play_unit_node_death_fade(victim_uid, fade)"),
		"unit_node_fade_not_wired",
		"cue_play_death() 没有让 2D 层跟着淡 —— 血条会一直停在满不透明度直到被释放")
	_h.expect(vfx.contains("release_dying_unit_nodes()"),
		"dying_nodes_never_released",
		"cue_release_corpses() 没有收掉还在淡的 2D 层 —— seek/重开会漏节点")
	_h.expect(vfx.contains("_arm_death_claim_watchdog(uid)"),
		"unplayed_death_has_no_watchdog",
		"待播放的死亡 cue 没有兜底超时回收")
	var skip_at := screen.find("func _skip_animation")
	var skip_block := screen.substr(skip_at, 1000) if skip_at >= 0 else ""
	_h.expect(skip_block.contains("cue_release_corpses()"),
		"skip_does_not_release_corpses",
		"跳过战斗在应用末帧后没有释放已取消的死亡接管")

	# 用**同一个** fade 变量驱动两边，两个常量会各自漂移。
	_h.expect(renderer.contains("func _play_unit_node_death_fade(uid: String, seconds: float)"),
		"fade_duration_not_shared",
		"2D 淡出没有接收外部传入的时长，说明它自己另定了一个数")

	# 状态控制器只能停、不能在死亡时释放（释放收不掉图标）。
	var at := renderer.find("func detach_actor_for_death")
	if not _h.expect(at >= 0, "detach_missing", "找不到 detach_actor_for_death()"):
		return
	var block := renderer.substr(at, 1400)
	_h.expect(block.contains("(status_vfx as Node).set_process(false)"),
		"status_controller_not_stopped",
		"detach_actor_for_death() 没有停掉状态控制器的每帧刷新")
	_h.expect(not block.contains("(status_vfx as Node).queue_free()"),
		"status_controller_freed_on_death",
		"detach_actor_for_death() 又在死亡时释放状态控制器了 —— 那收不掉图标（图标挂在锚点下），"
			+ "只会让它们以满不透明度骑在尸体上")
