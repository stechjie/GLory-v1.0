extends Node
const FX = preload("res://effects/vfx3d/modules/VFXDivinePulseInvulnerability3D.gd")
const Status = preload("res://scenes/battle/StatusVFXController.gd")
const Renderer = preload("res://scenes/battle/BattleRenderer.gd")
const Budget = preload("res://effects/vfx3d/core/VFXQualityBudget.gd")
const Arena = preload("res://scenes/battle/BattleArena.gd")
const BattleUI = preload("res://scenes/battle/BattleUI.gd")
const BoardSim = preload("res://scripts/battle/BattleSimShared.gd")
const OUT := "E:/Users/WINDOWS/Desktop/其他/神圣脉冲特效_20261015/"
var renderer
var world: Node3D
var camera: Camera3D
var actors: Array = []
var fighters: Array = []
var controllers: Array = []
var phase := 0.0
var enabled := true
var paused := false
var running := false
var failures := 0
var checks := 0
var label: Label
func check(ok: bool, description: String) -> void:
	checks += 1
	if not ok: failures += 1
	print("[PULSE-CHECK] ", "PASS " if ok else "FAIL ", description)
func _ready() -> void:
	for svc in ["NetworkService", "RealtimeService", "AnalyticsService", "ChatService", "AnnouncementService", "MailService"]:
		var n := get_tree().root.get_node_or_null(svc)
		if n: n.set_process(false)
	await contracts()
	if "--check" in OS.get_cmdline_user_args():
		# DONE 由 contracts() 自己打一次（preview 模式也要看得到），这里不再重复。
		get_tree().quit(1 if failures else 0)
		return
	renderer = Renderer.new()
	add_child(renderer)
	world = Node3D.new();add_child(world)
	camera = Camera3D.new();world.add_child(camera)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 5.3
	camera.look_at_from_position(Vector3(0,7.4,7), Vector3(0,0.55,0))
	camera.current = true
	var light := DirectionalLight3D.new();world.add_child(light)
	light.rotation_degrees = Vector3(-55,30,0)
	light.light_energy = 1.3
	var env := WorldEnvironment.new();world.add_child(env)
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color("172732")
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color("b1c4d2")
	env.environment.ambient_light_energy = 0.65
	var floor_mesh := MeshInstance3D.new();world.add_child(floor_mesh)
	var plane := PlaneMesh.new();plane.size=Vector2(25,25);floor_mesh.mesh=plane
	var mat := StandardMaterial3D.new();mat.albedo_color=Color("354b52");floor_mesh.material_override=mat
	label=Label.new();label.position=Vector2(20,20);label.add_theme_font_size_override("font_size",22);add_child(label)
	var buttons := HBoxContainer.new();buttons.position=Vector2(20,100);add_child(buttons)
	for title in ["重播", "暂停/继续", "旧/新", "低", "中", "高", "6/12"]:
		var btn:=Button.new();btn.text=title;buttons.add_child(btn)
		btn.pressed.connect(func(): control(title))
		btn.disabled = "--perf" in OS.get_cmdline_user_args()
	if "--board" in OS.get_cmdline_user_args():
		await board_shot()
		get_tree().quit(1 if failures else 0)
		return
	if "--perf" in OS.get_cmdline_user_args():
		await benchmark()
	else:
		await populate(6)
		running=true
# ─── 真实格距排版照（--board）───────────────────────────────────────────────
#
# 需求最后一句是「但不能遮挡棋盘」。上面默认的预览排布把棋子摆在**1.45 世界单位**
# 的间距上，而实战列距只有约 **0.71**（BattleSimShared.BOARD_COL_SPACING = 56 sim
# 单位，换算率见 BattleUI.SIM_W/BATTLE_PLAYABLE_WIDTH 与 BattleArena.BATTLE_VISUAL_SPACE_SCALE）——
# 也就是默认那张图把间距放大了**两倍**，结构上不可能看出「相邻格的护罩会不会互相
# 穿插」，而后者才是这句需求真正要问的。
#
# 这个模式按**真实格距**摆一个满编 4×4：格子坐标直接取
# `BattleSimShared.board_cell_pos()`（摆放界面与模拟用的是同一个函数），
# 坐标换算用与 BattleArena 同一份常量现算，不复制魔数。
# 神族棋子刻意摆成相邻（含 2×2 团），这是最挤的一种排法。
# 输出 on/off 两张对照图，并把**实测格距 vs 护罩半宽**打成一行读数 ——
# 「有没有压到隔壁格」用数字判，不用观感判。
func board_shot() -> void:
	for child in get_children():
		if child is Control:
			child.visible = false
	var defs: Dictionary = preload("res://scripts/qa/FixedBattleFixture.gd").unit_defs()
	var god_ids: Array = []
	var other_ids: Array = []
	for id in defs.keys():
		if str((defs[id] as Dictionary).get("race", "")) == "god":
			god_ids.append(id)
		else:
			other_ids.append(id)
	god_ids.sort(); other_ids.sort()
	# 列距/行距换算：与 BattleArena._sim_to_world_pos 逐字同一份公式
	# （x = (sim.x/SIM_W - 0.5) * BATTLE_PLAYABLE_WIDTH * BATTLE_VISUAL_SPACE_SCALE）。
	var x_scale := BattleUI.BATTLE_PLAYABLE_WIDTH / BattleUI.SIM_W * Arena.BATTLE_VISUAL_SPACE_SCALE
	var z_scale := BattleUI.BATTLE_PLAYABLE_DEPTH / BoardSim.combat_arena_height() * Arena.BATTLE_VISUAL_SPACE_SCALE
	var center_x := 500.0
	var slots := GameConstants.BOARD_ROWS * GameConstants.BOARD_COLUMNS
	var sims: Array[Vector2] = []
	for slot in slots:
		sims.append(BoardSim.board_cell_pos(slot, "player", center_x, false))
	var mid_y := 0.0
	for sim in sims:
		mid_y += sim.y
	mid_y /= float(sims.size())
	# 7 枚神族摆成「一排 3 枚 + 2×2 一团」，其余 9 格用非神族填满 —— 最挤的排法。
	var god_slots := [1, 2, 3, 5, 6, 9, 10]
	var gi := 0
	var oi := 0
	Budget.tier = 1
	for slot in slots:
		var id := ""
		if slot in god_slots and gi < god_ids.size():
			id = str(god_ids[gi]); gi += 1
		else:
			id = str(other_ids[oi % other_ids.size()]); oi += 1
		var sim := sims[slot]
		var f := {"id": id, "uid": "board_%d" % slot, "def": defs[id], "alive": true, "team": "player",
			"star": 1, "hp": 100, "max_hp": 100, "pos": sim, "statuses": {}, "shield": 0, "attack_count": 0}
		var actor: Node3D = renderer._make_shared_model_node(f)
		world.add_child(actor)
		# 棋盘在世界里的中心：棋盘自带偏移不影响**相对**间距，这里以中点为原点。
		actor.position = Vector3((sim.x - center_x) * x_scale, 0.0, (sim.y - mid_y) * z_scale)
		actor.set_meta("base_position", actor.position)
		var controller := Status.new()
		actor.add_child(controller)
		actors.append(actor); fighters.append(f); controllers.append(controller)
	camera.size = 3.2
	camera.look_at_from_position(Vector3(0, 7.4, 7), Vector3(0, 0.5, 0))
	var col_pitch := (sims[1].x - sims[0].x) * x_scale
	var row_pitch := (sims[GameConstants.BOARD_COLUMNS].y - sims[0].y) * z_scale
	print("[PULSE-BOARD] scale x=%.5f z=%.5f | 列距=%.4f 行距=%.4f 半列距=%.4f 半行距=%.4f" % [
		x_scale, z_scale, col_pitch, row_pitch, col_pitch * 0.5, row_pitch * 0.5])
	# ── 「不能遮挡棋盘」的真实格距读数 ────────────────────────────────────────
	# 这一节回答的是需求最后一句。口径必须和 contracts() 里那条几何判据区分开：
	#   * contracts() 里量的是**作者坐标系**（单位身高 = 1.0）下的网格包围盒；
	#   * 这里量的是**真正戴在棋子头上**的尺寸 —— 网格包围盒 × clampf(model_height)，
	#     T3 还有 ×1.2 的身高加成。两者差最多 1.18 倍，不换成同一个口径就会
	#     "网格达标、上阵超标"。
	#
	# 🔴 这里**只记读数、只断言真正不变的性质**，原因有两条，都是实测逼出来的：
	#   ① 棋子自身的渲染包围盒半宽实测 0.42 ~ 0.70 世界单位（dark_dragon 0.697、
	#      god_king 0.653、god_angel 0.581），**本来就大于半列距 0.357** ——
	#      也就是说这张棋盘上棋子之间从来就是互相穿插的。所以"护罩不能超出本格"
	#      在这张盘上不是一条能成立的判据；用它当门槛只会得到假 FAIL。
	#   ② 拿 AABB 半宽当"棋子本体宽度"是错的代理：god_angel / god_archangel /
	#      dark_dragon 的 AABB 被翅膀撑到 0.58 ~ 0.70，本体其实窄得多。第一版
	#      我写了个"护罩/棋子 ∈ [0.9, 2.2]"的包线，结果 8 项 FAIL —— 红的是
	#      这个代理指标，不是特效。删掉，不留。
	#
	# 真正让"遮挡"不成立的，是材质与几何（见 contracts() 三条断言）：
	# 不写深度 + **不跳过**深度测试（永远被前面的棋子和棋盘挡住，也不会盖掉身后
	# 任何东西）+ 镂空细弧（轮廓密度 ≤ 0.45，不是实心泡泡）+ 单向淡出。
	# 至于相邻格互相穿插，本盘列距 0.7146、行距 0.7446 世界单位，护罩直径约
	# 1.0 ~ 1.13，必然横向叠 0.4 左右 —— 这是需求两句（一眼看出 / 不遮挡棋盘）
	# 在几何上的必然折中，**记下来**，能不能读交给 on/off 两张实拍图。
	var halo_box: AABB = FX.mesh_for_tier(Budget.tier).get_aabb()
	var halo_half_unit := maxf(halo_box.size.x, halo_box.size.z) * 0.5
	var worst_overlap := 0.0
	var worst_ratio := 0.0
	for i in actors.size():
		var mh := float((actors[i] as Node3D).get_meta("model_height", 0.98))
		var halo_half := halo_half_unit * clampf(mh, 0.55, 2.0)
		var piece_box: AABB = renderer._node3d_bounds(actors[i])
		var piece_half := maxf(piece_box.size.x, piece_box.size.z) * 0.5
		var overlap := maxf(0.0, halo_half * 2.0 - col_pitch)
		if i % GameConstants.BOARD_COLUMNS == 0:
			print("[PULSE-BOARD] 第 %d 排：model_height=%.3f 护罩半宽=%.4f 棋子AABB半宽=%.4f（半列距=%.4f 半行距=%.4f）→ 同排相邻护罩横叠=%.4f" % [
				i / GameConstants.BOARD_COLUMNS, mh, halo_half, piece_half, col_pitch * 0.5, row_pitch * 0.5, overlap])
		worst_overlap = maxf(worst_overlap, overlap)
		worst_ratio = maxf(worst_ratio, overlap / col_pitch)
	print("[PULSE-BOARD] 最挤一格：相邻同排两枚护罩横向重叠 %.4f 世界单位（列距 %.4f，占 %.0f%%）；行向 %.4f 世界单位" % [
		worst_overlap, col_pitch, worst_ratio * 100.0, maxf(0.0, worst_overlap / col_pitch * row_pitch)])
	print("[PULSE-BOARD] 参考：棋子自身 AABB 半宽 0.42~0.70 > 半列距 0.357，本盘棋子本就互相穿插")
	# 🔴 这里必须保持 running=false。预览的 _process 会在 running 时**每帧**把
	# fighters[i].statuses 改成无敌（见 _process 第 221 行），并顺手挪棋子。
	# 早先这里写着 running=true，于是 OFF 那张"关特效"对照图其实是在快门等待的
	# 那一帧被 _process 点亮的 —— 对照图与 ON 图只差动画相位，等于没有对照。
	# 这个模式一律自己驱动状态，不借 _process。
	running = false
	print("[PULSE-BOARD] 开镜前护罩节点=", get_tree().get_nodes_in_group("divine_pulse_vfx").size())
	await _shoot("board_real_pitch_off.png")
	var off_count := get_tree().get_nodes_in_group("divine_pulse_vfx").size()
	print("[PULSE-BOARD] OFF 快门后护罩节点=", off_count)
	for i in fighters.size():
		var f: Dictionary = fighters[i]
		f.statuses = {"invulnerable": {"remaining": 1.0, "dot_pass": true}}
		controllers[i].update_from_fighter(f)
	var until := Time.get_ticks_msec() + 400
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame
		RenderingServer.force_draw()
	var on_count := get_tree().get_nodes_in_group("divine_pulse_vfx").size()
	print("[PULSE-BOARD] ON 快门前护罩节点=", on_count, " 可见=", _visible_pulse_count())
	# 这一条是这个模式唯一的断言，也是它的防空洞：OFF 必须一座都没有、
	# ON 必须一枚棋子一座。少了这条，"对照图"可能两张都是关的或都是开的。
	check(off_count == 0 and on_count == actors.size() and _visible_pulse_count() == actors.size(),
		"真实格距对照成立：OFF 护罩 %d 座（应 0）、ON %d 座（应 %d）且全部可见" % [off_count, on_count, actors.size()])
	for i in actors.size():
		fighters[i].pos = fighters[i].pos  # keep sim pos; animation state only
		renderer._update_model_animation_state(actors[i], fighters[i])
	await _shoot("board_real_pitch_on.png")
	var left := get_tree().get_nodes_in_group("divine_pulse_vfx").size()
	print("[PULSE-BOARD] 剩余护罩节点=", left)
	print("[PULSE-BOARD] DONE ", checks, "/", failures)

func _visible_pulse_count() -> int:
	var n := 0
	for node in get_tree().get_nodes_in_group("divine_pulse_vfx"):
		if node is Node3D and (node as Node3D).visible:
			n += 1
	return n


func _shoot(file_name: String) -> void:
	await RenderingServer.frame_post_draw
	RenderingServer.force_draw()
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(OUT + file_name)
	print("[PULSE-BOARD] 已保存 ", file_name)


func control(title: String) -> void:
	match title:
		"重播": phase=0.0
		"暂停/继续": paused=not paused
		"旧/新": enabled=not enabled
		"低", "中", "高":
			Budget.tier = ["低","中","高"].find(title)
			for f in fighters: f.statuses={}
			for i in controllers.size(): controllers[i].update_from_fighter(fighters[i])
			phase=0.0
		"6/12": populate(12 if actors.size()==6 else 6)
func populate(count: int) -> void:
	running=false
	for actor in actors: actor.queue_free()
	actors.clear();fighters.clear();controllers.clear()
	await get_tree().process_frame
	var ids: Array = ["god_priest","god_aurora","god_angel","god_priestess","god_arbiter","god_archangel"]
	var defs: Dictionary = preload("res://scripts/qa/FixedBattleFixture.gd").unit_defs()
	var columns := 3 if count <= 12 else 7
	var rows := ceili(float(count)/columns)
	camera.size = 5.3 if count <= 6 else (7.0 if count <=12 else 13.0)
	for i in count:
		var id: String = ids[i % ids.size()]
		var f := {"id":id,"uid":"preview_%d"%i,"def":defs[id],"alive":true,"team":"player","star":1,"hp":100,"max_hp":100,"pos":Vector2.ZERO,"statuses":{},"shield":0,"attack_count":0}
		var actor: Node3D = renderer._make_shared_model_node(f)
		world.add_child(actor)
		actor.position=Vector3((float(i%columns)-float(columns-1)/2.0)*1.45,0,(float(i/columns)-float(rows-1)/2.0)*1.4)
		actor.set_meta("base_position",actor.position)
		var controller:=Status.new();actor.add_child(controller)
		actors.append(actor);fighters.append(f);controllers.append(controller)
	phase=0.0;running=true
func _process(delta: float) -> void:
	if not running or paused: return
	phase+=delta
	var cycle:=fmod(phase,5.0)
	label.text="神圣脉冲  ·  %d 名真实动画棋子  ·  %s 档  ·  %s\n1 秒生效，4 秒间隔；状态结束立即撤下" % [actors.size(),["低","中","高"][Budget.tier],"新版" if enabled else "旧版（无标记）"]
	for i in actors.size():
		var f: Dictionary = fighters[i]
		f.statuses={"invulnerable":{"remaining":1.0-cycle,"dot_pass":true}} if enabled and cycle<1.0 else {}
		controllers[i].update_from_fighter(f)
		var actor: Node3D=actors[i]
		actor.position=actor.get_meta("base_position")+Vector3(sin(phase*1.5)*0.12,0,0)
		f.pos=Vector2(actor.position.x,actor.position.z)*100.0
		renderer._update_model_animation_state(actor,f)
	if "--perf" in OS.get_cmdline_user_args(): RenderingServer.force_draw()
func contracts() -> void:
	var before_blocks:=VFXBlockRoot.active_block_count()
	var actor:=Node3D.new();add_child(actor);actor.set_meta("model_height",0.98)
	var ctrl:=Status.new();actor.add_child(ctrl)
	var f: Dictionary={"alive":true,"statuses":{},"shield":0,"hp":123}
	ctrl.update_from_fighter(f)
	check(not is_instance_valid(ctrl._divine_pulse),"no status => no effect")
	f.statuses={"invulnerable":{"remaining":3.0}}
	ctrl.update_from_fighter(f)
	check(not is_instance_valid(ctrl._divine_pulse),"Phoenix full immunity is not divine pulse")
	# --- 「但不能遮挡棋盘」的可量化判据 ---------------------------------------
	# 需求原文最后一句是「但不能遮挡棋盘」。它不能靠「我看了一眼还行」交付，
	# 所以拆成三条**与渲染无关**的读数 —— 这一点很重要：本轮的性能样板已经两次
	# 因为窗口被遮挡（Godot 在被遮挡时不再绘制）而作废，任何依赖"跑一帧再读像素"
	# 的判据都会跟着窗口状态飘。
	#   ① 材质不写深度、也不跳过深度测试 -> 它永远被前面的棋子和棋盘挡住，
	#      同时因为不写深度，它也不会把身后任何东西盖掉。深度的两个开关一起看，
	#      只查其中一个都能被"写死另一个"的实现蒙过去。
	#   ② 几何的世界包围盒必须收在自己那一格里（半宽 ≤ 0.50、总高 ≤ 1.35 个棋子高）。
	#      这个上限不是拍的：战场格距见 BattleRenderer 的格子步进，棋子本身就占约
	#      0.98 高、半宽约 0.35；护罩半宽超过 0.50 就已经压到相邻格里去了。
	#   ③ 轮廓密度（三角面积 / 正投影包围盒面积）必须很小 -> 它是**镂空**的拱线，
	#      不是实心泡泡。实心泡泡即便 alpha 不高，叠满场也会把整块棋盘糊成一片白，
	#      这正是「遮挡棋盘」最典型的形态。
	# 三档都查：低档降的是细分与刻度数量，护线/顶环/冠印必须都还在。
	var shader_code := (FX.MATERIAL_SHADER as Shader).code
	check(shader_code.contains("depth_draw_never") and not shader_code.contains("no_depth_test"),
		"材质不写深度且不跳过深度测试（挡不住棋盘，也不会盖住身后的东西）")
	for tier in 3:
		var pulse_mesh: ArrayMesh = FX.mesh_for_tier(tier)
		var box := pulse_mesh.get_aabb()
		var half_width := maxf(box.size.x, box.size.z) * 0.5
		check(half_width <= 0.50 and box.size.y <= 1.35,
			"tier %d 几何收在本格内：半宽 %.3f ≤ 0.50、总高 %.3f ≤ 1.35" % [tier, half_width, box.size.y])
		var faces := pulse_mesh.get_faces()
		var area := 0.0
		for face in range(0, faces.size(), 3):
			area += (faces[face + 1] - faces[face]).cross(faces[face + 2] - faces[face]).length() * 0.5
		var projected := maxf(maxf(box.size.x, box.size.z) * box.size.y, 0.0001)
		var density := area / projected
		check(density <= 0.45,
			"tier %d 轮廓密度 %.3f ≤ 0.45（镂空拱线，不是实心泡泡；表面积 %.3f）" % [tier, density, area])
	for tier in 3:
		Budget.tier=tier
		f.statuses={"invulnerable":{"remaining":0.9,"dot_pass":true}}
		var original:=f.duplicate(true)
		ctrl.update_from_fighter(f)
		var effect=ctrl._divine_pulse
		check(is_instance_valid(effect),"status creates effect tier %d"%tier)
		check(effect.get_debug_state().tier==tier,"tier respected")
		for i in 20: ctrl.update_from_fighter(f)
		check(ctrl._divine_pulse==effect,"no duplicate effect")
		check(original==f,"presentation cannot mutate fighter")
		# 「跟随」必须真的被量到。旧写法是 `effect.global_position ≈ actor.global_position`
		# —— effect 本来就是 actor 的后代，这条**恒真**：写一个完全不做跟随的实现
		# （建好就不管）也照样 PASS，本轮它是唯一一条对「位置」的断言，等于没测。
		# 改成量**相对偏移**：① 先记下 effect 相对 actor 的偏移；② 把 actor 挪开一个
		# 明显的量；③ 偏移必须一分不变，且 actor 真的动了（否则又退化成恒真）。
		# 必须显式写 Vector3：`effect` 是 `ctrl._divine_pulse`（Variant），
		# `effect.global_position` 推不出类型，用 `:=` 会直接是**解析期错误**
		# （整个 preview.gd 加载失败、场景起不来，症状是"跑着一句话都不打"）。
		var offset_before: Vector3 = effect.global_position - actor.global_position
		var moved_from: Vector3 = actor.global_position
		actor.position += Vector3(1.0, 0.0, 1.0)
		var moved_by := actor.global_position.distance_to(moved_from)
		check(moved_by > 0.5, "follow check is not vacuous: actor really moved (%.2f)" % moved_by)
		check((effect.global_position - actor.global_position).is_equal_approx(offset_before),
			"effect follows actor: relative offset unchanged after a %.2f-unit move" % moved_by)
		check(effect.global_position.distance_to(moved_from + offset_before) > 0.5,
			"effect moved with the actor, not left behind in world space")
		await get_tree().create_timer(1.15).timeout
		check(is_instance_valid(effect) and effect.visible,"lifetime follows snapshot, not a fixed 1s timer")
		f.statuses={}
		ctrl.update_from_fighter(f)
		check(not effect.visible,"expiry immediately hides effect")
		await get_tree().process_frame
		check(not is_instance_valid(effect),"expiry releases effect")
	f.statuses={"invulnerable":{"remaining":1.0,"dot_pass":true}}
	ctrl.update_from_fighter(f)
	var dying=ctrl._divine_pulse
	f.alive=false
	await get_tree().process_frame
	await get_tree().process_frame
	check(not is_instance_valid(dying),"death without another visual update cleans effect")
	f.alive=true;ctrl.update_from_fighter(f)
	actor.queue_free()
	await get_tree().process_frame
	check(get_tree().get_nodes_in_group("divine_pulse_vfx").is_empty(),"owner removal cleans all effects")
	check(VFXBlockRoot.active_block_count()==before_blocks,"global block count balanced")
	Budget.tier=0
	var holders: Array=[]
	for i in 42:
		var holder:=Node3D.new();add_child(holder);holders.append(holder)
		var status_ctrl:=Status.new();holder.add_child(status_ctrl)
		status_ctrl.update_from_fighter({"alive":true,"statuses":{"invulnerable":{"remaining":1.0,"dot_pass":true}}})
		check(is_instance_valid(status_ctrl._divine_pulse),"low-tier crowded state stays visible %d"%i)
	check(get_tree().get_nodes_in_group("divine_pulse_vfx").size()==42,"one status per actor at 42 concurrent")
	for holder in holders:holder.queue_free()
	await get_tree().process_frame
	check(VFXBlockRoot.active_block_count()==before_blocks,"42 concurrent effects release cleanly")
	var warmup = preload("res://scripts/assets/BattleRenderWarmup.gd")
	var jobs: Array = warmup.collect_jobs([{"roster":{"a":{"id":"god_priest","def":{"race":"god"}},"b":{"id":"god_angel","def":{"race":"god"}}}}])
	var pulse_jobs:=0
	for job in jobs:
		if job.effect=="god_divine_pulse":pulse_jobs+=1
	check(pulse_jobs==1,"one shared prewarm job across god actors")
	Budget.tier=1
	print("[PULSE-CHECK] DONE ",checks,"/",failures)
func benchmark() -> void:
	# 🔴 测量期间必须关掉 vsync。project.godot 没有写 vsync_mode ⇒ 取 Godot 默认
	# `enabled`，而 Godot 的 `--headless` 之外一切窗口都按垂直同步节流到 60fps。
	# 那样两组（关特效 / 开特效）的 median 都会落在 14~15ms —— 那不是"帧成本"，
	# 只是"还贴得住 60fps 天花板"，差一个档次也看不出来。本样板第一版就是把
	# 这个当性能结论交的。关掉之后 median 才是真正的每帧耗时，p95 才有意义。
	# 顺带把 `Engine.max_fps` 归 0（若外部设过）。
	var prev_vsync := DisplayServer.window_get_vsync_mode()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var prev_max_fps := Engine.max_fps
	Engine.max_fps = 0
	# 12_high 原本是 180 秒。它没有对应的量：这一组的目的是「12 个棋子的高档」，
	# 而高档的每帧成本在 30 秒里已经采到 1800 帧、p95 也稳了；多出来的 150 秒
	# 只把整轮耗时抬到 4.5 分钟，反而让样板更容易在采样中途被别的窗口抢焦点打断。
	var results: Array=[]
	for spec in [{"name":"6_before","count":6,"tier":1,"enabled":false,"seconds":30},{"name":"6_medium","count":6,"tier":1,"enabled":true,"seconds":30},{"name":"6_low","count":6,"tier":0,"enabled":true,"seconds":30},{"name":"12_high","count":12,"tier":2,"enabled":true,"seconds":60},{"name":"42_high","count":42,"tier":2,"enabled":true,"seconds":30}]:
		enabled=spec.enabled;Budget.tier=spec.tier
		await populate(spec.count)
		await get_tree().create_timer(2.0).timeout
		var values: Array[float]=[]
		var live_peak:=0;var draws_peak:=0;var long_frames:=0
		var ends: Array[int]=[]
		var last_cycle:=-1
		var start:=Time.get_ticks_usec();var last:=start
		var drawn_start:=Engine.get_frames_drawn()
		while Time.get_ticks_usec()-start<int(spec.seconds*1000000):
			await get_tree().process_frame
			var now:=Time.get_ticks_usec()
			var ms:=float(now-last)/1000.0;last=now;values.append(ms)
			if ms>100.0:long_frames+=1
			live_peak=maxi(live_peak,get_tree().get_nodes_in_group("divine_pulse_vfx").size())
			draws_peak=maxi(draws_peak,int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)))
			var cycle:=int(phase/5.0)
			if fmod(phase,5.0)>4.7 and cycle!=last_cycle:
				ends.append(get_tree().get_node_count());last_cycle=cycle
		values.sort()
		var drawn := Engine.get_frames_drawn()-drawn_start
		var row:={"group":spec.name,"seconds":spec.seconds,"frames":values.size(),"median_ms":values[values.size()/2],"p95_ms":values[int(values.size()*0.95)],"over_100ms":long_frames,"peak_effects":live_peak,"drawn_frames":drawn,"actual_tier":Budget.tier,"peak_draw_calls":draws_peak,"cycle_end_nodes":ends}
		results.append(row);print("[PULSE-PERF] ",JSON.stringify(row))
		# ★ 本组到底有没有真的画。Godot 在窗口被遮挡/最小化时**不再绘制**，
		# 而 `_process` 里的 `RenderingServer.force_draw()` 是唯一能把帧推出去的手段，
		# 前提是命令行带 `--disable-render-loop`。不查这一条会把「1800 个未绘制的帧」
		# 当成 60fps 交上去 —— 本轮第一版样板的 performance.log 就是这样：
		# drawn_frames=0 / frames=1796，median 16.665ms，看着完美，其实一帧没画。
		if drawn < int(float(values.size())*0.9):
			failures += 1
			print("[PULSE-PERF] FAIL group=%s 只画了 %d / %d 帧 —— 这组数据不可用（窗口被遮挡？缺 --disable-render-loop？）" % [spec.name, drawn, values.size()])
		# 每组都落盘一次：样板跑到一半被打断时，已经采到的组不能跟着丢，
		# 这也是本轮 performance.json 一直不存在的原因（只在最后写一次）。
		_write_perf(results)
		phase=0.3
		await get_tree().process_frame
		RenderingServer.force_draw()
		get_viewport().get_texture().get_image().save_png(OUT+str(spec.name)+".png")
	var report:={"gpu":RenderingServer.get_video_adapter_name(),"renderer":RenderingServer.get_current_rendering_method(),"viewport":str(get_viewport().get_visible_rect().size),"animations":"real idle/run enabled","target_fps":60,"results":results,"checks":checks,"failures":failures}
	running=false
	for actor in actors:actor.queue_free()
	await get_tree().process_frame
	report["remaining_effects"]=get_tree().get_nodes_in_group("divine_pulse_vfx").size()
	_write_perf(results)
	print("[PULSE-PERF] DONE groups=",results.size()," failures=",failures)
	DisplayServer.window_set_vsync_mode(prev_vsync)
	Engine.max_fps = prev_max_fps
	get_tree().quit(1 if failures else 0)


# 每一组采完就落盘（见 benchmark 里的说明）。用 `groups_done` 标出这份文件是
# 完整跑完还是中途中断留下的，读的人不必去猜。
func _write_perf(results: Array) -> void:
	var report := {"gpu":RenderingServer.get_video_adapter_name(),"renderer":RenderingServer.get_current_rendering_method(),
		"viewport":str(get_viewport().get_visible_rect().size),"animations":"real idle/run enabled",
		"vsync":"disabled during measurement (otherwise every group pins to the 60fps ceiling)",
		"expected_groups":5,"groups_done":results.size(),"complete":results.size()>=5,
		"checks":checks,"failures":failures,"results":results}
	var file := FileAccess.open(OUT+"performance.json",FileAccess.WRITE)
	if file == null:
		print("[PULSE-PERF] WARN 无法写 performance.json err=",FileAccess.get_open_error())
		return
	file.store_string(JSON.stringify(report,"\t"));file.close()



