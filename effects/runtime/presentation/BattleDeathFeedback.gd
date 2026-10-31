class_name BattleDeathFeedback
extends RefCounted
## 10.29 死亡反馈：棋子被打死那一拍的身体动作。由 BattleVfx.cue_play_death 调用。
##
## 改前死亡只有「下沉 0.35 + 缩到 0.72 + 淡出」，缓入曲线，读起来是沉进地板，
## 不是被打死。现在按档位分两种：
##
##   碎裂（normal / heavy / finale）：定格闪白 + 压扁 → 朝远离击杀者的方向被顶飞、
##       往后倒 → 碎成种族色碎片（on_shatter 回调里生成）并快速化掉。
##   倒下（own）：己方阵亡。要看得清但不庆祝：不闪白、不碎，往后倒下再沉下去淡出。
##
## 分档（10.29 用户确认）：普通击杀不震屏；重量级（Boss / 四星 / 大体型）加轻震和
## 地面冲击环；己方那一路清场的最后一击定格 0.2 秒、全场最强。屏震 / 音效 / 多杀合并 /
## 清场定格由 BattleVfx 决定，这里只管身体。
##
## 槽位约定和 BattleHitFeedback 一致：死亡写 actor 的 position / scale / basis
## （actor 已从 _battle_3d_models 摘下，渲染层不再每帧重写它）；ActorRoot 的
## rotation / scale 归受击后仰，不碰。

const HIT_FEEDBACK := preload("res://effects/runtime/presentation/BattleHitFeedback.gd")

# hold：打死瞬间的定格（压扁 + 闪白顶满）。knock：被顶飞的距离（世界单位，单位约 0.98 高）。
# tilt：往后倒的角度。dissolve：碎裂后化掉的时长上限，实际再按 profile 时长缩。
const TIERS := {
	"normal": {"hold": 0.05, "knock": 0.20, "hop": 0.07, "tilt": 34.0, "squash": 0.16, "dissolve": 0.12},
	"heavy": {"hold": 0.09, "knock": 0.11, "hop": 0.04, "tilt": 22.0, "squash": 0.12, "dissolve": 0.15},
	"finale": {"hold": 0.20, "knock": 0.26, "hop": 0.09, "tilt": 38.0, "squash": 0.18, "dissolve": 0.15},
}
const KNOCK_SEC := 0.13
const FINALE_KNOCK_SEC := 0.15
# 己方阵亡：倒下用时、倒地角度、倒地后下沉。
const OWN_FALL_SEC := 0.26
const OWN_TILT_DEG := 72.0
const OWN_KNOCK := 0.06
const OWN_SINK := 0.22


# 10.30 怪物专用：身体倒地后消散，不再把模型换成彩色石块。
# 这里只由 pve_ / boss_ 的表现入口调用，既有棋子碎裂和己方阵亡不变。
const MONSTER_TIERS := {
	"normal": {"hold": 0.035, "fall": 0.22, "knock": 0.14, "tilt": 72.0, "squash": 0.075, "fade": 0.18},
	"heavy": {"hold": 0.055, "fall": 0.25, "knock": 0.09, "tilt": 66.0, "squash": 0.055, "fade": 0.22},
	"finale": {"hold": 0.20, "fall": 0.24, "knock": 0.17, "tilt": 78.0, "squash": 0.085, "fade": 0.20},
}


# 棋子与佣兵把重量留在身体：倒地、短促落地沉降，最后才淡出。
# 己方不闪、不挤压，只保留更小位移和清楚的阵亡轮廓。
const PIECE_TIERS := {
	"normal": {"hold": 0.03, "fall": 0.27, "settle": 0.045, "tilt": 76.0, "knock": 0.10, "squash": 0.04, "fade": 0.22},
	"heavy": {"hold": 0.055, "fall": 0.31, "settle": 0.055, "tilt": 70.0, "knock": 0.065, "squash": 0.025, "fade": 0.26},
	"finale": {"hold": 0.20, "fall": 0.29, "settle": 0.055, "tilt": 78.0, "knock": 0.13, "squash": 0.045, "fade": 0.26},
	"own": {"hold": 0.0, "fall": 0.32, "settle": 0.05, "tilt": 74.0, "knock": 0.045, "squash": 0.0, "fade": 0.24},
}


## on_tail 是第一次落地的一拍；淡种族残光/佣兵短星点在这里生成。
static func play_piece_body(tween: Tween, actor: Node3D, away_global: Vector3, tier: String,
		fade_targets: Array, duration_sec: float, flash_allowed: bool,
		on_tail: Callable, on_done: Callable, own: bool = false) -> float:
	var spec: Dictionary = PIECE_TIERS["own"] if own else PIECE_TIERS.get(tier, PIECE_TIERS["normal"])
	var hold := float(spec["hold"])
	var fall_sec := float(spec["fall"])
	var settle_sec := float(spec["settle"])
	var fade := clampf(duration_sec * 0.64, 0.16, float(spec["fade"]))
	var total := hold + fall_sec + settle_sec + fade
	var base_pos := actor.position
	var base_scale := actor.scale
	var base_basis := actor.basis
	var away := _to_parent_space(actor, _horizontal(away_global))
	var axis := _to_parent_space(actor, _tilt_axis(_horizontal(away_global)))
	var tilt := deg_to_rad(float(spec["tilt"]))
	var knock := float(spec["knock"])
	var squash := float(spec["squash"])
	HIT_FEEDBACK.freeze_animation(actor, total + 0.05)
	if flash_allowed and not own:
		HIT_FEEDBACK.flash(actor, 0.52, minf(hold, 0.055))
	actor.scale = base_scale * Vector3(1.0 + squash, 1.0 - squash, 1.0 + squash)
	if hold > 0.0:
		tween.tween_interval(hold)
	var fall := func(p: float) -> void:
		if not is_instance_valid(actor):
			return
		var travel := 1.0 - (1.0 - p) * (1.0 - p)
		var tipping := p * p * (2.0 - p)
		actor.position = base_pos + away * knock * travel + Vector3.DOWN * 0.018 * tipping
		actor.basis = Basis(axis, tilt * tipping) * base_basis
		var compression := squash * (1.0 - p) * (1.0 - p)
		actor.scale = base_scale * Vector3(1.0 + compression, 1.0 - compression, 1.0 + compression)
	tween.tween_method(fall, 0.0, 1.0, fall_sec)
	tween.tween_callback(on_tail)
	var landed := base_pos + away * knock + Vector3.DOWN * 0.018
	var settle := func(p: float) -> void:
		if not is_instance_valid(actor):
			return
		var out := 1.0 - (1.0 - p) * (1.0 - p)
		actor.position = landed + Vector3.DOWN * 0.022 * out
		actor.basis = Basis(axis, tilt + deg_to_rad(4.0) * out) * base_basis
		actor.scale = base_scale
	tween.tween_method(settle, 0.0, 1.0, settle_sec)
	# 淡出全程不再缩小模型，完整倒地轮廓就是最主要的死亡反馈。
	tween.set_parallel(true)
	tween.chain().tween_property(actor, "position", landed + Vector3.DOWN * 0.05, fade).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	for geometry in fade_targets:
		if is_instance_valid(geometry):
			tween.tween_property(geometry, "transparency", 1.0, fade).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.set_parallel(false)
	tween.chain().tween_callback(on_done)
	return total


## 与 play_shatter_body 同接口；on_shatter 在身体落地、尘雾开始的一拍调用。
## 致死第一帧的声音由调用方触发，不等待倒地回调。只停死者动作，不改游戏时间。
static func play_monster_body(tween: Tween, actor: Node3D, away_global: Vector3, tier: String,
		fade_targets: Array, duration_sec: float, flash_allowed: bool,
		on_shatter: Callable, on_done: Callable) -> float:
	var spec: Dictionary = MONSTER_TIERS.get(tier, MONSTER_TIERS["normal"])
	var hold := float(spec["hold"])
	var fall_sec := float(spec["fall"])
	var fade := clampf(duration_sec * 0.56, 0.14, float(spec["fade"]))
	var total := hold + fall_sec + fade
	var base_pos := actor.position
	var base_scale := actor.scale
	var base_basis := actor.basis
	var away := _to_parent_space(actor, _horizontal(away_global))
	var axis := _to_parent_space(actor, _tilt_axis(_horizontal(away_global)))
	var tilt := deg_to_rad(float(spec["tilt"]))
	var knock := float(spec["knock"])
	var squash := float(spec["squash"])
	HIT_FEEDBACK.freeze_animation(actor, total + 0.05)
	if flash_allowed:
		HIT_FEEDBACK.flash(actor, 0.65, minf(hold, 0.065))
	actor.scale = base_scale * Vector3(1.0 + squash, 1.0 - squash, 1.0 + squash)
	tween.tween_interval(hold)
	var fall := func(p: float) -> void:
		if not is_instance_valid(actor):
			return
		# 位移先冲后收，倒地先慢后快；模型全程保留轮廓，脚底为旋转支点。
		var travel := 1.0 - (1.0 - p) * (1.0 - p)
		var tipping := p * p * (2.0 - p)
		actor.position = base_pos + away * knock * travel
		actor.basis = Basis(axis, tilt * tipping) * base_basis
		var compression := squash * (1.0 - p) * (1.0 - p)
		actor.scale = base_scale * Vector3(1.0 + compression, 1.0 - compression, 1.0 + compression)
	tween.tween_method(fall, 0.0, 1.0, fall_sec)
	tween.tween_callback(on_shatter)
	# 只做轻微落地沉降，避免整只怪物缩成小球；透明度接手最后一段消散。
	tween.set_parallel(true)
	var landed := base_pos + away * knock
	tween.chain().tween_property(actor, "position", landed + Vector3(0.0, -0.045, 0.0), fade).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	for geometry in fade_targets:
		if is_instance_valid(geometry):
			tween.tween_property(geometry, "transparency", 1.0, fade).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.set_parallel(false)
	tween.chain().tween_callback(on_done)
	return total


## 碎裂档。tween 由调用方创建（绑在 BattleVfx 上，重置 / 跳转时能统一 kill）。
## away_global：远离击杀者的水平方向（全局空间），零向量时只倒不飞。
## on_shatter 在被顶飞结束、碎片该炸开的那一帧调用；on_done 在完全化掉后调用。
## 返回整段时长（秒），调用方用它同步 2D 血条层的淡出。
## flash_allowed：闪白开关（PresentationSettings.flash_allowed，低画质档 / 玩家关闪光时为假）。
static func play_shatter_body(tween: Tween, actor: Node3D, away_global: Vector3, tier: String,
		fade_targets: Array, duration_sec: float, flash_allowed: bool,
		on_shatter: Callable, on_done: Callable) -> float:
	var spec: Dictionary = TIERS.get(tier, TIERS["normal"])
	var hold := float(spec["hold"])
	var knock_sec := FINALE_KNOCK_SEC if tier == "finale" else KNOCK_SEC
	# profile 在低档会把死亡缩到 0.22 秒；碎裂后化掉这一段跟着缩，定格和顶飞不缩 ——
	# 那两段才是「打死了」的读点。
	var dissolve := clampf(duration_sec * 0.4, 0.07, float(spec["dissolve"]))
	var base_pos := actor.position
	var base_scale := actor.scale
	var base_basis := actor.basis
	var away := _to_parent_space(actor, _horizontal(away_global))
	var axis := _to_parent_space(actor, _tilt_axis(_horizontal(away_global)))
	var tilt := deg_to_rad(float(spec["tilt"]))
	var squash := float(spec["squash"])

	# 整段都停动作：尸体不该在倒下的时候还播待机 / 跑步。
	HIT_FEEDBACK.freeze_animation(actor, hold + knock_sec + dissolve + 0.05)
	if flash_allowed:
		HIT_FEEDBACK.flash(actor, 1.0, hold)
	# 第一帧直接压扁到最大，不做过渡：那一下就是「被打中」的瞬间。
	actor.scale = base_scale * Vector3(1.0 + squash, 1.0 - squash, 1.0 + squash)
	if hold > 0.0:
		tween.tween_interval(hold)
	var knock_dist := float(spec["knock"])
	var hop := float(spec["hop"])
	var knock := func(p: float) -> void:
		if not is_instance_valid(actor):
			return
		var out := 1.0 - (1.0 - p) * (1.0 - p)
		actor.position = base_pos + away * knock_dist * out + Vector3.UP * hop * sin(p * PI)
		actor.basis = Basis(axis, tilt * out) * base_basis
		# 压扁 → 拉长 → 回正：被顶飞的半程身体是拉长的。
		var stretch := sin(p * PI) * 0.10
		var s := squash * (1.0 - p)
		actor.scale = base_scale * Vector3(1.0 + s - stretch * 0.5, 1.0 - s + stretch, 1.0 + s - stretch * 0.5)
	tween.tween_method(knock, 0.0, 1.0, knock_sec)
	tween.tween_callback(on_shatter)
	# 碎裂后身体快速化掉：碎片已经炸出去了，留着整只身体会和碎片抢画面。
	tween.set_parallel(true)
	tween.chain().tween_property(actor, "scale", base_scale * 0.55, dissolve).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	for geometry in fade_targets:
		if is_instance_valid(geometry):
			tween.tween_property(geometry, "transparency", 1.0, dissolve)
	tween.set_parallel(false)
	tween.chain().tween_callback(on_done)
	return hold + knock_sec + dissolve


## 倒下档（己方阵亡）。不闪白、不碎、不停别人的动作。
static func play_fall_body(tween: Tween, actor: Node3D, away_global: Vector3,
		fade_targets: Array, duration_sec: float, on_done: Callable) -> float:
	var base_pos := actor.position
	var base_scale := actor.scale
	var base_basis := actor.basis
	var away := _to_parent_space(actor, _horizontal(away_global))
	var axis := _to_parent_space(actor, _tilt_axis(_horizontal(away_global)))
	var tilt := deg_to_rad(OWN_TILT_DEG)
	var fade := maxf(0.08, duration_sec * 0.92)
	HIT_FEEDBACK.freeze_animation(actor, OWN_FALL_SEC + fade + 0.05)
	# 倒下用缓入（越倒越快，像被重力拽下去），落地后再沉下去淡出。
	var fall := func(p: float) -> void:
		if not is_instance_valid(actor):
			return
		actor.position = base_pos + away * OWN_KNOCK * p
		actor.basis = Basis(axis, tilt * p * p) * base_basis
	tween.tween_method(fall, 0.0, 1.0, OWN_FALL_SEC)
	tween.set_parallel(true)
	var landed := base_pos + away * OWN_KNOCK
	tween.chain().tween_property(actor, "position", landed + Vector3(0.0, -OWN_SINK, 0.0), fade).set_ease(Tween.EASE_IN)
	tween.tween_property(actor, "scale", base_scale * 0.85, fade).set_ease(Tween.EASE_IN)
	for geometry in fade_targets:
		if is_instance_valid(geometry):
			tween.tween_property(geometry, "transparency", 1.0, fade * 0.94)
	tween.set_parallel(false)
	tween.chain().tween_callback(on_done)
	return OWN_FALL_SEC + fade


## 远离击杀者的水平方向（全局空间）。取不到击杀者就沿受击者面朝的反方向。
static func away_from(victim: Node3D, killer: Node3D) -> Vector3:
	if killer != null and is_instance_valid(killer) and killer.is_inside_tree() and victim.is_inside_tree():
		var delta := victim.global_position - killer.global_position
		delta.y = 0.0
		if delta.length() > 0.001:
			return delta.normalized()
	if victim.is_inside_tree():
		var local := HIT_FEEDBACK._away_direction_local(victim, null)
		var global := victim.global_transform.basis * local
		global.y = 0.0
		if global.length() > 0.001:
			return global.normalized()
	return Vector3.ZERO


static func _horizontal(v: Vector3) -> Vector3:
	var h := Vector3(v.x, 0.0, v.z)
	return h.normalized() if h.length() > 0.001 else Vector3.ZERO


# position / basis 是父节点空间的；方向在全局空间算，这里换过去。
# 战斗 3D 根节点目前没有旋转，换算是零成本保险：以后谁给单位层加了旋转也不会倒错方向。
static func _to_parent_space(actor: Node3D, v: Vector3) -> Vector3:
	var parent := actor.get_parent() as Node3D
	if parent == null or not parent.is_inside_tree() or v.length() < 0.001:
		return v
	return (parent.global_basis.inverse() * v).normalized()


# 绕「竖直 × 后退方向」转：头顶朝后退方向倒，脚底是 actor 原点，脚不离地。
static func _tilt_axis(away: Vector3) -> Vector3:
	var axis := Vector3.UP.cross(away)
	return axis.normalized() if axis.length() > 0.001 else Vector3.RIGHT

## Fatal hit: no falling pose, coins and shards leave on the impact beat.
static func play_burst_body(tween: Tween, actor: Node3D, targets: Array, flash_allowed: bool, on_burst: Callable, on_done: Callable) -> float:
	HIT_FEEDBACK.freeze_animation(actor, 0.18)
	if flash_allowed:
		HIT_FEEDBACK.flash(actor, 0.75, 0.025)
	tween.tween_interval(0.035)
	tween.tween_callback(on_burst)
	tween.set_parallel(true)
	tween.chain().tween_property(actor, "scale", actor.scale * 0.78, 0.085)
	for geometry in targets:
		if is_instance_valid(geometry):
			tween.tween_property(geometry, "transparency", 1.0, 0.085)
	tween.set_parallel(false)
	tween.chain().tween_callback(on_done)
	return 0.12
