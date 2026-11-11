class_name BattleHitFeedback
extends RefCounted
## 受击反馈：闪白、后仰 + 压扁、局部顿帧。由 BattleVfx.cue_spawn_hit_number 在伤害数字
## 出现的同一拍调用（远程普攻已被 adapter 推迟到弹体落地），所以反馈和数字永远对齐。
##
## 三条硬约束：
##   1. 只动表现，不碰模拟。后仰 / 压扁打在 ActorRoot 的 rotation / scale 上 ——
##      actor.position 每帧被模拟位置重写；ActorRoot.position 归攻击前冲用；
##      actor.scale / position 归死亡下沉用。rotation / scale 这两个槽位没人写。
##   2. 顿帧只停「这一两个单位」的 AnimationPlayer，不动 Engine.time_scale：
##      自走棋每秒几十下命中，全局停帧会让整局一卡一卡；3v3 回放的时间轴也不能停。
##   3. 闪白用临时 material_overlay，不改角色材质。四星 / 亡灵光环已占用这个槽位的
##      网格跳过闪白（只保留动作反馈），绝不覆盖光环。
##
## 分档（10.21 用户确认）：普攻 = 闪白 + 后仰；暴击 = 加强闪白 + 攻击者与受击者
## 一起顿帧；技能 = 闪白 + 后仰 + 受击者顿帧。屏震另由 BattleVfx 的衰减式屏震负责。

const FLASH_SHADER := preload("res://shaders/hit_flash_overlay.gdshader")

const FLASH_SEC := 0.10
const FLINCH_SEC := 0.20
# 后仰角度（度）和压扁幅度：单位实测约 0.95 高，8° 在棋子尺寸下刚好读得出「被推了一下」。
const FLINCH_DEG := {"basic": 6.0, "crit": 10.0, "skill": 8.0}
const SQUASH := {"basic": 0.07, "crit": 0.11, "skill": 0.09}
const FLASH_STRENGTH := {"basic": 0.55, "crit": 0.95, "skill": 0.8}
const HITSTOP_SEC := {"crit": 0.06, "skill": 0.05}
# 同一个目标两次反馈的最短间隔：多段技能 / 多个攻击者同一帧命中时只演一次，免得抖成筛子。
const MIN_INTERVAL_MSEC := 70


## tier: "basic" | "crit" | "skill"。attacker 可为 null（取不到攻击者时按「向后仰」处理）。
static func play(victim: Node3D, attacker: Node3D, tier: String, flash_allowed: bool, hitstop_allowed: bool) -> void:
	if victim == null or not is_instance_valid(victim) or not victim.is_inside_tree():
		return
	var now := Time.get_ticks_msec()
	if now - int(victim.get_meta("hit_feedback_msec", -100000)) < MIN_INTERVAL_MSEC:
		return
	victim.set_meta("hit_feedback_msec", now)
	if flash_allowed:
		flash(victim, float(FLASH_STRENGTH.get(tier, 0.55)))
	flinch(victim, attacker, tier)
	if hitstop_allowed and HITSTOP_SEC.has(tier):
		var duration := float(HITSTOP_SEC[tier])
		freeze_animation(victim, duration)
		if tier == "crit" and attacker != null and is_instance_valid(attacker):
			freeze_animation(attacker, duration)


# --- 闪白 ---------------------------------------------------------------------

## hold：顶满亮度先停多久再开始褪（死亡定格用）；受击闪白传 0。
static func flash(actor: Node3D, strength: float, hold := 0.0) -> void:
	_end_flash(actor)
	var material := ShaderMaterial.new()
	material.shader = FLASH_SHADER
	material.set_shader_parameter("amount", strength)
	var meshes: Array[MeshInstance3D] = []
	for mesh in _model_meshes(actor):
		if mesh.material_overlay == null:
			mesh.material_overlay = material
			meshes.append(mesh)
	if meshes.is_empty():
		return
	actor.set_meta("hit_flash", {"material": material, "meshes": meshes})
	var tween := actor.create_tween()
	if hold > 0.0:
		tween.tween_interval(hold)
	tween.tween_method(func(value: float) -> void: material.set_shader_parameter("amount", value),
			strength, 0.0, FLASH_SEC).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_callback(_end_flash.bind(actor))
	actor.set_meta("hit_flash_tween", tween)


## 摘掉自己挂的覆盖层；期间被别的系统（死亡发光、光环）换掉的不动。
static func _end_flash(actor: Node3D) -> void:
	if not is_instance_valid(actor):
		return
	if actor.has_meta("hit_flash_tween"):
		var tween = actor.get_meta("hit_flash_tween")
		if tween is Tween and (tween as Tween).is_valid():
			(tween as Tween).kill()
		actor.remove_meta("hit_flash_tween")
	if not actor.has_meta("hit_flash"):
		return
	var entry: Dictionary = actor.get_meta("hit_flash")
	actor.remove_meta("hit_flash")
	for mesh in entry.get("meshes", []):
		if is_instance_valid(mesh) and (mesh as MeshInstance3D).material_overlay == entry.get("material"):
			(mesh as MeshInstance3D).material_overlay = null


## 只取导入的角色网格（ArrayMesh）。脚底影、队伍光圈、状态图标是 PrimitiveMesh，不闪。
static func _model_meshes(actor: Node3D) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var stack: Array[Node] = [actor]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		stack.append_array(node.get_children())
		if node is MeshInstance3D and (node as MeshInstance3D).mesh is ArrayMesh and (node as MeshInstance3D).is_visible_in_tree():
			out.append(node as MeshInstance3D)
	return out


# --- 后仰 + 压扁 ---------------------------------------------------------------

static func flinch(victim: Node3D, attacker: Node3D, tier: String) -> void:
	var root := victim.get_node_or_null("ActorRoot") as Node3D
	if root == null:
		return
	var back := _away_direction_local(victim, attacker)
	var angle := deg_to_rad(float(FLINCH_DEG.get(tier, 6.0)))
	var squash := float(SQUASH.get(tier, 0.07))
	# 绕「竖直 × 后退方向」转，头顶朝后退方向倒；脚底是 ActorRoot 原点，所以脚不离地。
	var axis := Vector3.UP.cross(back)
	if axis.length() < 0.001:
		axis = Vector3.RIGHT
	axis = axis.normalized()
	if victim.has_meta("hit_flinch_tween"):
		var previous = victim.get_meta("hit_flinch_tween")
		if previous is Tween and (previous as Tween).is_valid():
			(previous as Tween).kill()
	var apply := func(p: float) -> void:
		if not is_instance_valid(root):
			return
		root.quaternion = Quaternion(axis, angle * p)
		root.scale = Vector3(1.0 + squash * 0.6 * p, 1.0 - squash * p, 1.0 + squash * 0.6 * p)
	# 命中那一帧直接到最大，再带一点回弹回到原位：快出、缓收，读得出「挨了一下」。
	apply.call(1.0)
	var tween := victim.create_tween()
	tween.tween_method(apply, 1.0, 0.0, FLINCH_SEC).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_callback(func() -> void:
		if is_instance_valid(root):
			root.quaternion = Quaternion.IDENTITY
			root.scale = Vector3.ONE)
	victim.set_meta("hit_flinch_tween", tween)


## 受击者本地空间里「远离攻击者」的水平方向。取不到攻击者就用「面朝方向的反方向」：
## 战斗里单位基本面朝自己的目标，往后仰也读得通。
static func _away_direction_local(victim: Node3D, attacker: Node3D) -> Vector3:
	var inverse := victim.global_transform.basis.inverse()
	if attacker != null and is_instance_valid(attacker) and attacker.is_inside_tree():
		var delta := victim.global_position - attacker.global_position
		delta.y = 0.0
		if delta.length() > 0.001:
			var local := inverse * delta.normalized()
			local.y = 0.0
			if local.length() > 0.001:
				return local.normalized()
	# 模型的美术正面：model_base_yaw = 180 的模型正面在本地 +Z（见 BattleRenderer 的朝向公式）。
	var base_yaw := float(victim.get_meta("base_yaw", 180.0))
	var forward := Basis(Vector3.UP, deg_to_rad(base_yaw - 180.0)).inverse() * Vector3(0, 0, 1)
	return -forward


# --- 局部顿帧 -------------------------------------------------------------------

## 把这个单位下所有 AnimationPlayer 停 duration 秒。连续命中会顺延，不会提前恢复。
## speed_scale = 0 而不是 pause()：模型动作脚本发现播放器停了会自己重新 play。
static func freeze_animation(actor: Node3D, duration: float) -> void:
	if not is_instance_valid(actor) or not actor.is_inside_tree():
		return
	var until := Time.get_ticks_msec() + int(duration * 1000.0)
	var already := actor.has_meta("hitstop_until")
	actor.set_meta("hitstop_until", maxi(until, int(actor.get_meta("hitstop_until", 0))))
	if not already:
		for player in actor.find_children("*", "AnimationPlayer", true, false):
			(player as AnimationPlayer).speed_scale = 0.0
	# ignore_time_scale = true：不受 Engine.time_scale 影响，也不会被别处的全局停帧拖住。
	actor.get_tree().create_timer(duration, true, false, true).timeout.connect(_release_freeze_by_id.bind(actor.get_instance_id()))


# A SceneTreeTimer outlives freed actors. Binding a typed Node3D directly fails
# argument conversion before _release_freeze can check is_instance_valid().
static func _release_freeze_by_id(actor_id: int) -> void:
	var actor := instance_from_id(actor_id) as Node3D
	if is_instance_valid(actor):
		_release_freeze(actor)


static func _release_freeze(actor: Node3D) -> void:
	if not is_instance_valid(actor) or not actor.has_meta("hitstop_until"):
		return
	var remaining := int(actor.get_meta("hitstop_until")) - Time.get_ticks_msec()
	if remaining > 2:
		# 卡顿帧的帧间隔很大时计时器会提前到点；时间没到就按剩余时长再排一次，
		# 不能直接 return —— 那样没有下一个计时器，这个单位会一直停着。
		# （顺延的那次命中也会自己排计时器，多排一个只是空跑一次。）
		if actor.is_inside_tree():
			actor.get_tree().create_timer(remaining * 0.001, true, false, true).timeout.connect(_release_freeze_by_id.bind(actor.get_instance_id()))
		return
	actor.remove_meta("hitstop_until")
	# 恢复到渲染层记的基准倍率（跑步时按移动速度调过），而不是一律 1.0。
	var base_speed := float(actor.get_meta("anim_base_speed", 1.0))
	for player in actor.find_children("*", "AnimationPlayer", true, false):
		(player as AnimationPlayer).speed_scale = base_speed
