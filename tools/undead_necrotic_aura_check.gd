extends Node

# 10.10 第 10 条门禁：凤凰涅槃复活体的「死灵气息」常驻光环。
#
# 为什么必须是行为判据而不是"函数存在"：
#   * 这条需求的三句原话全是**画面约束**（风格一致 / 不遮挡模型 / 避开他人特效），
#     而其中最容易做错、又最看不出来的一条是"不遮挡" —— 用一张竖着的半透明
#     面片盖在棋子身上，代码里看不出任何异常，只有玩家会发现"脸糊了"。
#     所以这里把它落成一条**结构不变量**：本模块自己生成的每一个面片都必须是
#     加色混合（BLEND_MODE_ADD）。加法只能提亮、永远不可能压暗或遮死模型。
#   * "避开四星光环"同样是结构性冲突：两者抢同一个 `material_overlay` 槽位，
#     写错了只会静默少一个光环。这里直接调 `_attach_rim()` 验它自己的合同
#     （外层 `configure()` 的同身高早退会先 return，只测外层等于没测）。
#
# 判据分三段：
#   A 生产接线：走真的 BattleRenderer._sync_3d_model_nodes，复活体必须有、普通棋子必须没有。
#   B 模块合同：落点/尺寸/加色不变量/让位/收放/幂等。
#   C 参数被消费：换身高必须等比换尺寸（证明身高不是写死的）。

const Harness := preload("res://tools/CheckHarness.gd")
const Aura := preload("res://effects/vfx3d/modules/UndeadNecrosisAura3D.gd")
const Budget := preload("res://effects/vfx3d/core/VFXQualityBudget.gd")
const RIM_SHADER_PATH := "res://effects/vfx3d/shaders/four_star_rim.gdshader"
const NOMINAL_HEIGHT := 0.98
# 与 BattleRenderer 的地面环排除名单一致；这些网格不参与边光。
const RIM_EXCLUDED := ["ContactShadow3D", "GroundShadow3D", "TeamGlow3D"]

var h := Harness.new("undead_necrotic_aura")


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var battle_script: Script = load("res://scenes/battle/BattleVfx.gd")
	var battle: Control = battle_script.new()
	add_child(battle)
	var arena := Control.new()
	arena.size = Vector2(1000.0, 520.0)
	battle.add_child(arena)
	battle.set("_arena", arena)
	var model_root := Node3D.new()
	model_root.name = "BattleModelRoot"
	battle.add_child(model_root)
	battle.set("_battle_3d_root", model_root)

	# 视觉位置换算在 3v3 team_mode 下要读分路边界；这条门禁只关心光环，把模式关掉
	# 让 _visual_sim_pos_for_fighter 走「不过滤」那条短路，测完还原。
	var was_team_mode: bool = GameState.team_mode
	var was_tier: int = Budget.tier
	GameState.team_mode = false
	Budget.tier = Budget.Tier.LOW
	await get_tree().process_frame

	# ─────────────────────────── A. 生产接线 ───────────────────────────
	var phoenix := _fighter("player_phoenix_9", true, 0)
	var actor := _make_actor("PhoenixActor", NOMINAL_HEIGHT, "melee")
	model_root.add_child(actor)
	(battle.get("_unit_actor_registry") as RefCounted).call("register_actor", str(phoenix.uid), actor)
	battle.call("_add_3d_unit_readability", actor, phoenix)
	(battle.get("_battle_3d_models") as Dictionary)[str(phoenix.uid)] = actor
	battle.call("_sync_3d_model_nodes", [phoenix], 0.0, false)
	await get_tree().process_frame

	var aura := actor.get_node_or_null(Aura.NODE_NAME) as Node3D
	if not h.expect(is_instance_valid(aura), "phoenix_aura_created",
			"凤凰涅槃复活体（phoenix_used）经过生产接线后必须自动获得 UndeadNecrosisAura"):
		_cleanup(battle, was_team_mode, was_tier)
		return
	var state: Dictionary = aura.call("debug_state")
	h.expect(bool(state.get("configured", false)) and bool(state.get("visible", false)),
		"phoenix_aura_active", "光环建出来后必须处于已配置且可见状态")
	h.expect(str(aura.name) == str(Aura.NODE_NAME), "aura_node_name",
		"节点名必须与 BattleRenderer.detach_actor_for_death 里取的那个名字一致（否则真死时收不掉）")

	# 落点：光环根必须踩在生产 FootAnchor 上（不是原点、不是头顶）。
	var foot := actor.get_node("FootAnchor") as Node3D
	h.expect(foot != null and is_equal_approx(aura.position.y, foot.position.y), "aura_at_foot_anchor",
		"光环根要落在 UnitActor3D 的 FootAnchor 高度上，地面纹章才会贴着脚而不是浮在腰上")
	h.expect(is_equal_approx(aura.scale.x, float(actor.get_meta("model_height", NOMINAL_HEIGHT))), "aura_scaled_by_height",
		"整层必须按实测身高缩放（不是写死世界尺寸），否则大体积单位会漏出光环")

	# 地面纹章必须收在队伍圈以内、且高于队伍圈，别抢四星光环的位置。
	var glow := actor.get_node_or_null("TeamGlow3D") as MeshInstance3D
	var sigil := aura.get_node_or_null("NecroticSigil") as MeshInstance3D
	h.expect(glow != null and glow.mesh is PlaneMesh, "team_ring_present",
		"生产 actor 上必须有队伍圈，否则「收在队伍圈以内」这条无从判定")
	if glow != null and glow.mesh is PlaneMesh:
		var team_radius := (glow.mesh as PlaneMesh).size.x * 0.5 * glow.global_basis.get_scale().x
		var sigil_radius: float = float(Aura.SIGIL_RADIUS) * aura.global_basis.get_scale().x
		h.expect(sigil_radius < team_radius, "sigil_inside_team_ring",
			"死灵纹章环半径(%s)必须小于队伍圈半径(%s)：大于就等于和四星光环抢同一条地面线" % [sigil_radius, team_radius])
		h.expect(sigil != null and sigil.mesh is PlaneMesh and sigil.position.y > 0.0
				and sigil.global_position.y > glow.global_position.y, "sigil_is_ground_plane",
			"纹章必须是地面上的水平面（PlaneMesh 且高于队伍圈），不能是一张竖着的卡片")

	# ── 结构不变量：模块自己生成的每个面片都必须是加色混合 ──
	var offenders: Array[String] = []
	for node in _aura_meshes(aura):
		var mat: Material = (node as MeshInstance3D).material_override
		if mat == null and (node as MeshInstance3D).mesh != null:
			mat = (node as MeshInstance3D).mesh.surface_get_material(0)
		if not (mat is BaseMaterial3D) or (mat as BaseMaterial3D).blend_mode != BaseMaterial3D.BLEND_MODE_ADD:
			offenders.append(str(node.name))
	h.expect(offenders.is_empty(), "all_aura_faces_additive",
		"光环自己的每个面片都必须是加色混合（不能有混色/不透明面片），否则可能盖住棋子：%s" % str(offenders))

	# 魂屑：从身体外圈升起、数量受档位封顶、绘制材质同样加色。
	var wisps := aura.get_node_or_null("RisingSoulWisps") as GPUParticles3D
	h.expect(wisps != null and wisps.emitting and int(state.get("wisp_amount", 0)) > 0, "wisps_emitting",
		"上浮魂屑必须存在并在发射（这是「气息」的主体，只剩一个地面圈读不出死灵味）")
	if wisps != null:
		h.expect(int(wisps.amount) <= Budget.max_particles_per_effect(), "wisps_bounded",
			"粒子数必须受 VFXQualityBudget 档位封顶（低档上限 %d，实际 %d）" % [Budget.max_particles_per_effect(), wisps.amount])
		var pm := wisps.process_material as ParticleProcessMaterial
		if h.expect(pm != null and pm.emission_shape == ParticleProcessMaterial.EMISSION_SHAPE_RING, "wisps_ring_emitter",
				"魂屑必须用环状发射器，才能绕开身体（点发射就是从体内往外喷）"):
			var outer: float = float(pm.emission_ring_radius)
			var inner: float = float(pm.emission_ring_inner_radius)
			h.expect(inner > 0.0 and outer > inner and outer <= float(Aura.WISP_RING_RADIUS) * 1.01, "wisps_outer_ring_band",
				"环带必须落在身体外圈（内径 %s > 0，外径 %s ≤ 魂屑环半径 %s）：贴着身体升起会挡住棋子" % [
					inner, outer, Aura.WISP_RING_RADIUS])
			# 环带外径还要收在**队伍圈**以内，否则会飘到隔壁格子上去。
			if glow != null and glow.mesh is PlaneMesh:
				var wr_team: float = (glow.mesh as PlaneMesh).size.x * 0.5 * glow.global_basis.get_scale().x
				h.expect(outer * aura.global_basis.get_scale().x < wr_team, "wisps_inside_team_ring",
					"魂屑环带外径（世界 %s）必须小于队伍圈半径（%s），否则会飘出本格" % [
						outer * aura.global_basis.get_scale().x, wr_team])
		var draw := wisps.draw_pass_1 as QuadMesh
		var dmat: Material = draw.material if draw != null else null
		h.expect(dmat is BaseMaterial3D and (dmat as BaseMaterial3D).blend_mode == BaseMaterial3D.BLEND_MODE_ADD, "wisps_additive",
			"魂屑的绘制材质也必须是加色混合，与面片不变量同口径")

	# ─────────────────────────── B. 模块合同 ───────────────────────────
	# B1 边光落在模型网格上，且只落在模型网格上（不能落到光环自己的面片上）。
	var claimed: Array = _meshes_with_overlay(actor)
	h.expect(claimed.size() >= 1 and claimed.size() == int(state.get("rim_meshes", -1)), "rim_overlay_on_model_only",
		"剪影边光必须挂到模型的网格上，且恰好是 debug_state 报的那一面数（挂到自己面片上会自发光）")
	if not claimed.is_empty():
		var overlay: Material = (claimed[0] as MeshInstance3D).material_overlay
		var overlay_is_rim_shader: bool = overlay is ShaderMaterial and (overlay as ShaderMaterial).shader != null \
				and (overlay as ShaderMaterial).shader.resource_path == RIM_SHADER_PATH
		h.expect(overlay_is_rim_shader, "rim_uses_fresnel_shader",
			"边光必须用 four_star_rim.gdshader（本仓既有的 Fresnel 边光），不要另造一套")
		# B1b 边光的 opacity 必须收得住。four_star_rim 的 ALPHA = (0.08 + edge*0.92)*opacity*pulse，
		# 低面数模型上朝下/朝外的面（腿、披风下摆）edge≈1 ⇒ 整片吃满 alpha。
		# 成片实测 0.62 会把小腿整段染成荧光绿（05 生产档的腿「没了」），据此定档 0.18。
		# 这条判据专门锁这个数值上界 —— 防「凭手感改大」后模型糊掉却没人发现（成片看着还行，真机全绿）。
		var rim_op: Variant = null
		if overlay_is_rim_shader:
			rim_op = (overlay as ShaderMaterial).get_shader_parameter("opacity")
		h.expect(rim_op != null and float(rim_op) > 0.0 and float(rim_op) <= 0.30, "rim_opacity_bounded",
			"边光 opacity 必须 >0 且 ≤0.30（实测 ≥0.62 会把低面数模型的小腿整段染绿，光环退化成荧光体）；实际 %s" % rim_op)
	# B2 该 shader 的 alpha 必须由「法线与视线夹角」决定 —— 正对镜头处 alpha≈0
	#    才是「不遮挡模型正面」的技术保证。读源码但先剥注释（注释会命中关键字造成假绿）。
	#
	# 只验「公式存在」是假绿：`edge` 算出来却没用进 ALPHA，一样能通过。
	# 所以正面钉住 ALPHA 那一条赋值语句本身必须引用 `edge`。
	var rim_src := _strip_comments(FileAccess.get_file_as_string(RIM_SHADER_PATH))
	var alpha_line := ""
	for line in rim_src.split("\n"):
		if str(line).strip_edges().begins_with("ALPHA"):
			alpha_line = str(line)
	h.expect(rim_src.contains("dot(normalize(NORMAL), normalize(VIEW))") and rim_src.contains("1.0 - clamp(")
			and not alpha_line.is_empty() and alpha_line.contains("edge"),
		"rim_alpha_is_edge_driven",
		"边光 alpha 必须真的由 dot(NORMAL, VIEW) 的补角（edge）驱动；若改成常数 alpha，模型正面就会被整片绿雾盖住。ALPHA 行=%s" % alpha_line)

	# B3 让位：四星光环在场时不许抢 material_overlay。
	var four_star := Node3D.new()
	four_star.name = "FourStarAuraV2"
	actor.add_child(four_star)
	aura.call("_attach_rim")
	h.expect(int(aura.call("debug_state").get("rim_meshes", -1)) == 0
			and _meshes_with_overlay(actor).is_empty(), "rim_yields_to_four_star",
		"四星光环也在场时必须让位（不抢 material_overlay），否则会静默顶掉玩家读了整局的四星标识")
	four_star.free()
	aura.call("_attach_rim")
	h.expect(int(aura.call("debug_state").get("rim_meshes", -1)) >= 1, "rim_restored_without_four_star",
		"四星光环消失后必须能重新贴回边光（让位不能是不可逆的一次性放弃）")

	# B4 幂等：同身高的重复 configure 不许重建、不许把边光清掉。
	# 判据用**面片的 instance id**：只看子节点数会被"先 remove_child 再 queue_free"
	# 骗过去（数量当帧不变），重建与不重建读起来一模一样。
	var sigil_before := sigil.get_instance_id()
	var child_before := aura.get_child_count()
	aura.call("configure", NOMINAL_HEIGHT)
	# 重建时旧面片是 remove_child + queue_free（当帧还活着），所以要重新按名字取，
	# 不能拿手里的旧引用比 instance id —— 那样重建与否读出来一样。
	var sigil_after := aura.get_node_or_null("NecroticSigil") as MeshInstance3D
	h.expect(sigil_after != null and sigil_after.get_instance_id() == sigil_before
			and aura.get_child_count() == child_before
			and int(aura.call("debug_state").get("rim_meshes", -1)) >= 1, "configure_idempotent",
		"同身高重复 configure 必须早退（不重建面片、不清掉已贴好的边光）—— 生产接线每帧都会调它")

	# B4b 幂等的第二重判据（专抓「只删早退、不做重建」那种更隐蔽的回退）：
	# 先把模型某个面的 overlay 换成**外来材质**，再重复 configure。
	#   · 早退（对）：那个面保留外来 overlay，rim_meshes 数量一个不少；
	#   · 每帧重贴（错）：_clear_rim 只清自己的材质（外来的不受影响），而紧接着的
	#     _attach_rim 会跳过带 overlay 的面 ⇒ rim_meshes 少一面，数量对不上。
	var probe: MeshInstance3D = null
	if not claimed.is_empty():
		probe = claimed[0] as MeshInstance3D
	if probe != null:
		var foreign := StandardMaterial3D.new()
		probe.material_overlay = foreign
		var rim_before := int(aura.call("debug_state").get("rim_meshes", -1))
		aura.call("configure", NOMINAL_HEIGHT)
		h.expect(int(aura.call("debug_state").get("rim_meshes", -1)) == rim_before, "configure_does_not_reattach_rim",
			"同身高重复 configure 不许再去动一遍 material_overlay（那等于每帧全模型 find_children + 重挂）")
		# 收尾：把探针还回去，后面的用例还要用这面边光。
		probe.material_overlay = null
		aura.call("_attach_rim")
		h.expect(int(aura.call("debug_state").get("rim_meshes", -1)) == rim_before, "rim_rebuilt_after_probe",
			"探针撤掉后必须能整组贴回（证明上面的让位/幂等都还是可逆的）")

	# B5 收放：deactivate 要连边光一起还回去，重新 sync 要能整层回来。
	Aura.sync(actor, false)
	var off: Dictionary = aura.call("debug_state")
	h.expect(not bool(off.get("visible", true)) and not bool(off.get("wisp_emitting", true)), "deactivate_stops_layers",
		"deactivate 必须同时停掉可见性与粒子发射")
	h.expect(_meshes_with_overlay(actor).is_empty(), "deactivate_releases_overlay",
		"deactivate 必须把 material_overlay 还给模型（否则尸体会一直带着死灵绿边光）")
	Aura.sync(actor, true, NOMINAL_HEIGHT)
	var on: Dictionary = aura.call("debug_state")
	h.expect(bool(on.get("visible", false)) and bool(on.get("wisp_emitting", false))
			and int(on.get("rim_meshes", 0)) >= 1, "resync_restores_layers",
		"重新 sync 必须把三层都恢复（复活体被复用同一 actor 的路径）")

	# B6 真死链路：BattleRenderer 必须能在死亡那一步收掉它。
	var detached := battle.call("detach_actor_for_death", str(phoenix.uid)) as Node3D
	h.expect(detached == actor and not bool(aura.call("debug_state").get("visible", true)), "death_releases_aura",
		"借来的命到点时 BattleRenderer.detach_actor_for_death 必须把死灵气息一起收掉")
	# 把 actor 塞回表里，后面的用例还要用它。
	(battle.get("_battle_3d_models") as Dictionary)[str(phoenix.uid)] = actor
	Aura.sync(actor, true, NOMINAL_HEIGHT)

	# B7 反向：普通棋子（没有 phoenix_used）身上不许出现光环。
	var plain := _fighter("player_plain_3", false, 1)
	plain.erase("phoenix_used")
	var plain_actor := _make_actor("PlainActor", NOMINAL_HEIGHT, "melee")
	model_root.add_child(plain_actor)
	(battle.get("_unit_actor_registry") as RefCounted).call("register_actor", str(plain.uid), plain_actor)
	(battle.get("_battle_3d_models") as Dictionary)[str(plain.uid)] = plain_actor
	battle.call("_sync_3d_model_nodes", [plain], 0.0, false)
	h.expect(plain_actor.get_node_or_null(Aura.NODE_NAME) == null, "no_aura_for_plain_unit",
		"普通棋子绝不允许出现死灵气息（判据取 phoenix_used，不是 uid 字面量，也不是「有没有连线」）")

	# ───────────────────── C. 身高是入参，不是写死的 ─────────────────────
	var boss := _fighter("enemy_phoenix_4", true, 0)
	var boss_actor := _make_actor("PhoenixBossActor", NOMINAL_HEIGHT * 2.0, "boss")
	model_root.add_child(boss_actor)
	(battle.get("_unit_actor_registry") as RefCounted).call("register_actor", str(boss.uid), boss_actor)
	battle.call("_add_3d_unit_readability", boss_actor, boss)
	(battle.get("_battle_3d_models") as Dictionary)[str(boss.uid)] = boss_actor
	battle.call("_sync_3d_model_nodes", [boss], 0.0, false)
	var boss_aura := boss_actor.get_node_or_null(Aura.NODE_NAME) as Node3D
	if h.expect(is_instance_valid(boss_aura), "boss_height_aura_created", "两倍身高的单位同样要拿到光环"):
		var boss_state: Dictionary = boss_aura.call("debug_state")
		h.expect(float(boss_state.get("height", 0.0)) > NOMINAL_HEIGHT * 1.9, "boss_height_consumed",
			"光环必须吃 actor 的 model_height（%s），不能按 Nominal 写死" % boss_state.get("height"))
		# 缩放是对的 → 纹章环仍收在该 actor 自己的队伍圈以内。
		var boss_glow := boss_actor.get_node_or_null("TeamGlow3D") as MeshInstance3D
		if boss_glow != null and boss_glow.mesh is PlaneMesh:
			var boss_team_radius := (boss_glow.mesh as PlaneMesh).size.x * 0.5 * boss_glow.global_basis.get_scale().x
			h.expect(float(boss_state.get("sigil_radius", 0.0)) < boss_team_radius, "boss_sigil_inside_team_ring",
				"换身高后纹章环仍要收在自己的队伍圈以内（证明是等比缩放而不是写死世界半径）")
		var boss_wisps := boss_aura.get_node_or_null("RisingSoulWisps") as GPUParticles3D
		h.expect(boss_wisps != null and int(boss_wisps.amount) <= Budget.max_particles_per_effect(), "boss_wisps_bounded",
			"大体积单位的魂屑数量同样要受档位封顶")

	# ───────────────────── D. 资源：只靠运行时生成，不落文件 ─────────────────────
	var sigil_tex := Aura._get_texture("sigil")
	var wisp_tex := Aura._get_texture("wisp")
	h.expect(sigil_tex != null and sigil_tex.get_width() > 0 and wisp_tex != null and wisp_tex.get_width() > 0,
		"textures_generated_at_runtime", "两张贴图必须在运行时生成（不新增美术资源文件，也就不会有 .import / 清单漂移）")
	h.expect(Aura._get_texture("sigil") == sigil_tex, "texture_cache_shared",
		"贴图要跨实例静态缓存：每只复活体各造一遍 96×96 是白给的开销")

	# ───────────── E. 回放边界：phoenix_used 必须经 roster 过边界 ─────────────
	# 真实对局播的是**回放**（BattleScreen._load_replay_roster 重建 fighter），
	# 而 frames 是 13 列冻结结构、没有这一列 —— 少了这段桥接，光环在实战里
	# 一次都不会出现（摆拍工具直接手填 phoenix_used 能过，实战过不了）。
	var sim: Script = load("res://scripts/battle/BattleSimulator.gd")
	var roster_state := {
		"kind": "pvp", "elapsed": 0.0, "unit_stats": {}, "visual_events": [],
		"player": [_replay_fighter("roster_phoenix_1", true), _replay_fighter("roster_plain_2", false)],
		"enemy": [],
	}
	var roster_out: Dictionary = {}
	sim.call("_replay_capture_roster", roster_state, roster_out)
	h.expect(bool((roster_out.get("roster_phoenix_1", {}) as Dictionary).get("phoenix_used", false)),
		"roster_carries_phoenix_used",
		"凤凰复活体的 phoenix_used 必须写进 roster —— 这是它唯一能过回放边界的通道（frames 13 列冻结、不能加列）")
	h.expect(not (roster_out.get("roster_plain_2", {}) as Dictionary).has("phoenix_used"),
		"roster_omits_key_for_plain",
		"普通棋子不许多出 phoenix_used 键（照 twin_group_id 的先例只在有键时带，没触发凤凰的对局回放字节不变）")
	# 判别力：把 roster 里的键擦掉后客户端必须拿不到 —— 否则上面两条恒绿、抓不到断链。
	var stripped: Dictionary = roster_out.duplicate(true)
	(stripped.get("roster_phoenix_1", {}) as Dictionary).erase("phoenix_used")
	var screen: Control = (load("res://scenes/battle/BattleScreen.gd") as Script).new()
	screen.call("_load_replay_roster", {"kind": "pvp", "roster": stripped, "frames": [], "result": {}})
	h.expect(not bool((screen.get("_replay_by_uid") as Dictionary).get("roster_phoenix_1", {})
			.get("phoenix_used", false)), "client_without_roster_key_has_no_flag",
		"roster 不带这个键时客户端 fighter 必须没有标记（否则 roster 通道的判据抓不到断链）")
	screen.call("_load_replay_roster", {"kind": "pvp", "roster": roster_out, "frames": [], "result": {}})
	var by_uid: Dictionary = screen.get("_replay_by_uid")
	h.expect(bool((by_uid.get("roster_phoenix_1", {}) as Dictionary).get("phoenix_used", false)),
		"client_restores_phoenix_used_from_roster",
		"客户端必须从 roster 把 phoenix_used 还原到 fighter 上（BattleRenderer 的光环判据读的就是它）")
	h.expect(not (by_uid.get("roster_plain_2", {}) as Dictionary).has("phoenix_used"),
		"client_plain_has_no_flag", "普通棋子的 fighter 同样不许有这个标记")
	screen.free()
	# 防冻：修法必须是「roster 加键」而不是「frames 加列」。
	var frames_probe: Array = []
	sim.call("_replay_capture_frame", roster_state, frames_probe)
	h.expect(frames_probe.size() == 1 and (frames_probe[0] as Array).size() == 2
			and ((frames_probe[0] as Array)[0] as Array).size() == 13, "replay_frame_still_13_columns",
		"回放帧必须仍是 13 列冻结结构（ReplayDigest.SIMULATION_TOP_FIELDS 含 frames，加列会改掉玩法身份哈希）")

	_cleanup(battle, was_team_mode, was_tier)


func _cleanup(battle: Control, team_mode: bool, tier: int) -> void:
	GameState.team_mode = team_mode
	Budget.tier = tier
	if is_instance_valid(battle):
		battle.free()
	h.finish(get_tree())


# ─────────────────────────── 工具 ───────────────────────────

func _fighter(uid: String, phoenix: bool, lane: int) -> Dictionary:
	var f := {
		"uid": uid, "id": "human_knight", "name": "人族骑士", "team": "player" if lane >= 0 else "enemy",
		"lane": lane, "hp": 100, "max_hp": 100, "shield": 0, "alive": true,
		"pos": Vector2(500.0, 260.0), "def": {}, "statuses": {},
	}
	if phoenix:
		f["phoenix_used"] = true
	return f


# E 段用的最小 fighter：字段名与 BattleSimulator._replay_capture_roster /
# BattleScreen._load_replay_roster 的取值键严格对齐，缺一个键就会读到默认值。
func _replay_fighter(uid: String, phoenix: bool) -> Dictionary:
	var f := {
		"uid": uid, "id": "human_knight", "name": "人族骑士", "name_en": "Knight",
		"team": "player", "lane": 0, "hp": 100, "max_hp": 100, "alive": true,
		"is_mercenary": false, "is_formation_ally": false, "star": 1,
		"footprint_cells": 1, "owner_slot": 0, "def": {}, "pos": Vector2(500.0, 260.0),
		"attack_count": 0, "skill_ready": 0.0, "shield": 0, "skill_stacks": 0, "statuses": {},
	}
	if phoenix:
		f["phoenix_used"] = true
	return f


func _make_actor(actor_name: String, height: float, archetype: String) -> Node3D:
	var actor_script: Script = load("res://effects/runtime/presentation/UnitActor3D.gd")
	var actor: Node3D = actor_script.new()
	actor.name = actor_name
	actor.call("configure_contract", height, archetype)
	# 真的挂一个网格当身体 —— 边光的合同就是「挂到模型的网格上」，
	# 没有网格的 actor 测不出这条。
	var body := MeshInstance3D.new()
	body.name = "TestBody"
	var box := BoxMesh.new()
	box.size = Vector3(height * 0.20, height * 0.60, height * 0.14)
	body.mesh = box
	body.position = Vector3(0.0, height * 0.40, 0.0)
	actor.call("attach_model", body)
	return actor


func _aura_meshes(aura: Node3D) -> Array:
	var out: Array = []
	var stack: Array = [aura]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D:
			out.append(node)
		for child in node.get_children():
			stack.append(child)
	return out


func _meshes_with_overlay(actor: Node3D) -> Array:
	var out: Array = []
	for node in actor.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if mesh != null and mesh.material_overlay != null:
			out.append(mesh)
	return out


# 代码断言必须先剥注释：注释里出现 dot(normalize(NORMAL), normalize(VIEW)) 就假绿。
func _strip_comments(source: String) -> String:
	var out := ""
	for line in source.split("\n"):
		var cut := str(line).find("//")
		out += (str(line).substr(0, cut) if cut >= 0 else str(line)) + "\n"
	return out
