extends Node3D
class_name BossSkillVFXComposer3D

const PROFILE := preload("res://effects/vfx3d/core/VFXProfile3D.gd")
const PAINTED := preload("res://effects/vfx3d/modules/VFXBossTextureLayer3D.gd")
const PROJECTILE := preload("res://effects/vfx3d/modules/VFXProjectile3D.gd")
const METEOR := preload("res://effects/vfx3d/modules/VFXMeteorStrike3D.gd")
const BARRIER := preload("res://effects/vfx3d/modules/VFXBarrierShield3D.gd")
const PILLAR := preload("res://effects/vfx3d/modules/VFXFallingPillar3D.gd")
const ROAR := preload("res://effects/vfx3d/modules/VFXRoarCone3D.gd")
const LIGHTNING_ARC := preload("res://effects/vfx3d/VFXLightningArc.gd")
const LIGHTNING_BALL := preload("res://effects/vfx3d/VFXLightningBall.gd")
const PATH_RIBBON := preload("res://effects/vfx3d/modules/VFXPathRibbon3D.gd")
const SLASH_ARC := preload("res://effects/vfx3d/modules/VFXSlashArc3D.gd")
const BINBUN := preload("res://effects/vfx3d/vfxv2/VFXBinbunReference3D.gd")
const EXTERNAL := preload("res://effects/vfx3d/vfxv2/VFXV2ExternalReference3D.gd")

const FLIPBOOK := preload("res://effects/vfx3d/modules/VFXFlipbookSkill3D.gd")
const EXTRAS := preload("res://effects/vfx3d/boss/VFXBossExtras3D.gd")

const TEX := "res://assets/vfx/boss/"
const OGA := "res://assets/vfx/oga/skill_packs/"
# 圣光祭司给队友的护盾：用图鉴「状态」页里那张护盾（10.18 用户定）。
const SHIELD_AURA := "res://assets/vfx/status/status_shield_aura.png"

# 10.18 Boss 特效优化：Boss 模型是普通单位的 2 倍高（model_visual_scale 2.0），原来所有
# 挂在 Boss 身上的层都按普通单位的尺寸/高度写，显得又小又低（只到膝盖）。用户定按 1.5 倍放大。
# 只作用于「挂在 Boss 身上」的层；打在普通单位身上的层（治疗、命中、刀光）保持原尺寸。
const BOSS_SCALE := 1.5
# 普通单位 / Boss 的身高（世界单位），给程序化补层算尺寸用。
const UNIT_H := 0.98
const BOSS_H := UNIT_H * BOSS_SCALE

var _apocalypse_warns: Array = []
var _last_apocalypse_shake_msec := -100000

# 返回值只有常驻效果才有（blood_qi：调用方负责在 Boss 死亡时释放），其余为 null。
func play_skill(effect_id: String, origin: Vector3, target: Vector3, context: Dictionary = {}) -> Node3D:
	match effect_id:
		"element_meteor": _meteor_v2(_tracked_target(target, context))
		"overload_stack": _overload_stack(origin)
		"overload_counter": _overload_counter(origin, target, context)
		"mirror_spawn": _mirror_spawn(target)
		"mirror_slash": _mirror_slash(origin, target)
		"holy_purify": _holy_purify(origin, _capped_targets(context.get("targets", [target])))
		"rage_stack": _rage_stack(origin, int(context.get("stacks", 1)))
		"rage_milestone": _rage_milestone(origin, target, int(context.get("stacks", 5)))
		"blood_rage": _blood_rage(origin)
		"blood_qi": return _extra_forced("blood_qi", origin, origin, {"origin_height": BOSS_H, "origin_node": context.get("boss_node")})
		"blood_lifesteal": _blood_lifesteal(target, origin)
		"soul_devour": _soul_devour(target, origin, context)
		"twin_timer": _twin_timer(origin, target)
		"twin_revive": _twin_revive(target)
		"apocalypse_charge": _apocalypse_charge(origin, context)
		"apocalypse_complete": _apocalypse_complete(origin, _capped_targets(context.get("targets", [target])))
		"apocalypse_interrupt": _apocalypse_interrupt(origin)
		_:
			# 不在 UNIT_SKILLS 里、这里也没有分支的技能会落到这。以前是静默无表现，
			# 现在至少给一次可读的命中反馈，并在编辑器里留个警告好定位。
			if not effect_id.is_empty():
				push_warning("No boss VFX branch for effect_id: %s" % effect_id)
				var flash := _block(SLASH_ARC) as VFXSlashArc3D
				if flash != null:
					flash.play_profile(_profile(Color(.04,.04,.05), Color(.52,.54,.60), Color(.94,.96,1.0), .48, .32, 2.6), {"target": target + Vector3(0,.30,0), "direction": (target-origin).normalized()})
	return null

# Boss 身上的挂点：原来的高度偏移按 BOSS_SCALE 放大，往镜头推一点。
func _on_boss(foot: Vector3, y: float, toward := .02) -> Vector3:
	return foot + Vector3(0, y * BOSS_SCALE, toward)

# ── 陨星 ────────────────────────────────────────────────────────────────
# 10.18：落地爆炸原来走 EXTERNAL "starter_explosion"，实战里显示成一块黑色多边形（素材坏了），
# 换成手绘 boss_meteor_explosion + 地裂序列帧 + 火星。用户口径「爆炸范围弄小」：原来的
# 预警圈是 VFXGroundSigil3D（其实是火团 + 红烟的命中模块，施法一出手就在落点炸一大团），
# 换成纯预警圈（VFXBossExtras3D.meteor_warn）；屏震从施法那一刻挪到陨石落地那一刻（BattleVfx 跳过了这招的施法屏震）。
const METEOR_FALL_SEC := .68

func _meteor_v2(target: Vector3) -> void:
	_extra("meteor_warn", target, target, {"target_height": UNIT_H, "fall_sec": METEOR_FALL_SEC})
	_painted("boss_meteor_trail.png", {"from": target + Vector3(-.55,3.25,.02), "to": target + Vector3(0,.34,0), "size": Vector2(1.15,.62), "duration": .80, "delay": .08, "rotation_z": -12.0, "dark_tint": Color(.30,.04,.0), "body_tint": Color(1.0,.36,.04), "core_tint": Color(1.0,.92,.55), "seed": 7.1, "flow_strength": .024})
	_after(METEOR_FALL_SEC, func() -> void:
		# 10.19 用户：爆炸再放大 100%（预警圈不变）。
		_painted("boss_meteor_explosion.png", {"position": target + Vector3(0,.50,.06), "size": Vector2(2.1,1.96), "duration": .62, "start_scale": .25, "peak_scale": 1.0, "dark_tint": Color(.10,.06,.06), "body_tint": Color(1.0,.62,.30), "core_tint": Color(1.0,.96,.80), "seed": 2.6})
		_flip(target + Vector3(0,.02,0), {"path": OGA + "earth_crack.png", "columns": 5, "rows": 1, "frame_count": 5, "fps": 10.0, "size": Vector2(2.2,1.8), "duration": .9, "ground": true, "color": Color(1.0,.62,.32,.95)})
		_extra("meteor_embers", target, target, {"target_height": UNIT_H * 2.0})
		_impact_feedback(9.0, .22, .05))

func _overload_stack(origin: Vector3) -> void:
	_painted("boss_thunder_stack.png", {"position": _on_boss(origin, .72, .04), "size": Vector2(.72,.72) * BOSS_SCALE, "duration": .50, "peak_scale": .80, "dark_tint": Color(.02,.10,.30), "body_tint": Color(.30,.68,1), "core_tint": Color(.92,1,1), "seed": 1.8})

# ── 雷核 ────────────────────────────────────────────────────────────────
# 10.18：Boss 身上的过载原来是一团深蓝（手绘石环 + 深色球心），改成电光序列帧，雷球内核改亮；
# 雷球砸下来后落点留一圈电场（VFXBossExtras3D.thunder_field），用户口径「周围有电的感觉」。
func _overload_counter(origin: Vector3, target: Vector3, context: Dictionary) -> void:
	# 手绘 boss_thunder_overload.png 主体是一圈灰石头，染色也救不成「电」，Boss 身上改用两层错开的电光序列帧。
	_flip(_on_boss(origin, .62, .08), {"path": OGA + "mage_lightning.png", "columns": 6, "rows": 4, "frame_count": 20, "fps": 30.0, "size": Vector2(1.45,1.45), "duration": .6, "color": Color(.80,.95,1.0,1.0)})
	_after(.10, func() -> void:
		_flip(_on_boss(origin, .50, .10), {"path": OGA + "mage_lightning.png", "columns": 6, "rows": 4, "frame_count": 20, "fps": 26.0, "size": Vector2(1.1,1.1), "duration": .5, "color": Color(.70,.90,1.0,.95)}))
	var ball := _block(LIGHTNING_BALL) as VFXLightningBall
	var target_node: Variant = context.get("target_node")
	if ball != null:
		# 球模块自己会在起点上再抬 1.05（约 Boss 胸口），所以这里直接给脚底。
		ball.play_ball(origin, target + Vector3(0,.38,0), target_node)
	if not is_inside_tree() or is_queued_for_deletion():
		return
	var tree := get_tree()
	if tree == null:
		return
	await tree.create_timer(.38).timeout
	if not is_inside_tree() or is_queued_for_deletion():
		return
	target = _tracked_target(target, context)
	var arc := _block(LIGHTNING_ARC) as VFXLightningArc
	if arc != null:
		arc.play_arc(target + Vector3(0,2.75,0), target)
	_painted("boss_thunder_counter.png", {"position": target + Vector3(0,.38,.04), "size": Vector2(1.46,1.32), "duration": .66, "start_scale": .10, "dark_tint": Color(.03,.12,.34), "body_tint": Color(.30,.68,1), "core_tint": Color(.94,1,1), "seed": 3.4})
	_extra("thunder_field", target, target, {"target_height": UNIT_H})
	# 电场里错开再闪两下电光
	for i in 2:
		var side := Vector3(-.32 if i == 0 else .30, .05 + .12 * float(i), 0)
		_after(.12 + .16 * float(i), func() -> void:
			_flip(target + side + Vector3(0,.20,.06), {"path": OGA + "mage_lightning.png", "columns": 6, "rows": 4, "frame_count": 20, "fps": 34.0, "size": Vector2(.62,.62), "duration": .42, "color": Color(.80,.95,1.0,1.0)}))
	_impact_feedback(7.0, .18, .04)

# ── 镜像魔君 ────────────────────────────────────────────────────────────
# 10.18 用户定：刀光（一局 150+ 刀）保持短促，只略加粗加亮；重点给分身出现那一下（镜面碎裂）。
func _mirror_spawn(target: Vector3) -> void:
	_painted("boss_mirror_split.png", {"position": _on_boss(target, .42), "size": Vector2(1.65,1.48) * BOSS_SCALE, "duration": .82, "dark_tint": Color(.06,.02,.12), "body_tint": Color(.56,.28,.86), "core_tint": Color(.96,.84,1), "seed": 4.0})
	_painted("boss_mirror_clone.png", {"position": _on_boss(target, .55, .03), "size": Vector2(1.05,1.25) * BOSS_SCALE, "duration": 1.0, "delay": .15, "start_scale": .08, "peak_scale": .92, "dark_tint": Color(.04,.015,.08), "seed": 6.7})
	_extra("mirror_shatter", target, target, {"target_height": BOSS_H})

func _mirror_slash(origin: Vector3, target: Vector3) -> void:
	var slash := _block(SLASH_ARC) as VFXSlashArc3D
	var p := _profile(Color(.05,.015,.09), Color(.56,.20,.88), Color(.98,.82,1), .92, .58, 3.6)
	if slash != null:
		slash.play_profile(p, {"target": target + Vector3(0,.35,0), "direction": (target-origin).normalized()})
	_painted("boss_mirror_slash.png", {"position": target + Vector3(0,.36,.04), "size": Vector2(1.45,1.05), "duration": .50, "rotation_z": rad_to_deg((target-origin).angle_to(Vector3.RIGHT)), "body_tint": Color(.66,.34,.96), "core_tint": Color(1,.90,1), "seed": 5.1})

# ── 圣光祭司 ────────────────────────────────────────────────────────────
# 10.18：光柱原来细得像针 → 放宽 + 脚下金色光圈；队友身上的护盾换成图鉴里那张蓝金护盾
# （status_shield_aura.png，原图上色，不走着色器染色）。
func _holy_purify(origin: Vector3, targets: Array) -> void:
	_painted("boss_holy_purify.png", {"position": _on_boss(origin, .58, .03), "size": Vector2(1.45,1.42) * BOSS_SCALE, "duration": 1.10, "dark_tint": Color(.26,.14,.02), "body_tint": Color(1.0,.78,.26), "core_tint": Color(1,1,.82), "seed": 2.2})
	var caster_pillar := _block(PILLAR) as VFXFallingPillar3D
	if caster_pillar != null:
		caster_pillar.play_pillar(origin, _profile(Color(.22,.12,.0), Color(1.0,.70,.16), Color(1,.98,.76), 1.6, 1.05, 3.8))
	_extra("holy_ring", origin, origin, {"origin_height": BOSS_H})
	for i in targets.size():
		var at: Vector3 = targets[i]
		_painted("boss_holy_heal.png", {"position": at + Vector3(0,.48,.03), "size": Vector2(.92,1.0), "duration": .90, "delay": .12, "rise": .22, "dark_tint": Color(.26,.14,.02), "body_tint": Color(1.0,.80,.30), "core_tint": Color(1,1,.82), "seed": float(i)*2.1})
		_after(.22 + .05 * float(i), func() -> void:
			_flip(at + Vector3(0,.44,.02), {"path": SHIELD_AURA, "size": Vector2(.95,.95), "duration": 1.0, "color": Color(1,1,1,.92)}))

# ── 狂暴兽 ──────────────────────────────────────────────────────────────
func _rage_stack(origin: Vector3, stacks: int) -> void:
	# 狂战灾兽。层数越高越猛（基数 .95 + 每层 .03，20 层封顶 1.55），再整体按 Boss 体型放大。
	_painted("boss_rage_stack.png", {"position": _on_boss(origin, .46), "size": Vector2(.78,.82) * BOSS_SCALE, "duration": .42, "peak_scale": .95 + minf(stacks,20)*.03, "dark_tint": Color(.22,.03,.0), "body_tint": Color(.95,.22,.05), "core_tint": Color(1,.74,.30), "seed": float(stacks)})

func _rage_milestone(origin: Vector3, target: Vector3, stacks: int) -> void:
	_painted("boss_rage_aura.png", {"position": _on_boss(origin, .48), "size": Vector2(1.42,1.42) * BOSS_SCALE, "duration": 1.05, "dark_tint": Color(.22,.03,.0), "body_tint": Color(.90,.16,.03), "core_tint": Color(1,.62,.18), "seed": float(stacks)})
	var roar := _block(ROAR) as VFXRoarCone3D
	if roar != null:
		roar.play_roar(_on_boss(origin, .56, 0), target + Vector3(0,.36,0), _profile(Color(.20,.03,.0), Color(.92,.16,.03), Color(1,.64,.20), (.92 + stacks*.012) * BOSS_SCALE, .88, 3.6))
	_painted("boss_rage_burst.png", {"position": target + Vector3(0,.30,.03), "size": Vector2(1.45,1.18), "duration": .62, "delay": .22, "body_tint": Color(.92,.18,.03), "core_tint": Color(1,.78,.30), "seed": 9.3})
	_flip(origin + Vector3(0,.02,0), {"path": OGA + "earth_crack.png", "columns": 5, "rows": 1, "frame_count": 5, "fps": 10.0, "size": Vector2(1.9,1.5), "duration": 1.0, "ground": true, "color": Color(1.0,.55,.30,.95)})
	_extra("rage_shock", origin, origin, {"origin_height": BOSS_H})
	_impact_feedback(6.5, .2, .0)

# ── 血怒魔王 ────────────────────────────────────────────────────────────
# 10.18：暗红光环叠在黑色模型上几乎看不见。进入暴走那一下保留手绘层（放大），
# 常驻的红色粒子气由 BattleVfx 另起 blood_qi（Boss 活着就一直冒）。
func _blood_rage(origin: Vector3) -> void:
	_painted("boss_blood_rage.png", {"position": _on_boss(origin, .54), "size": Vector2(1.46,1.55) * BOSS_SCALE, "duration": 1.25, "dark_tint": Color(.14,.0,.02), "body_tint": Color(.92,.06,.08), "core_tint": Color(1,.42,.32), "seed": 4.2})
	_painted("boss_blood_overflow.png", {"position": _on_boss(origin, .34, .03), "size": Vector2(1.72,1.48) * BOSS_SCALE, "duration": .78, "delay": .18, "start_scale": .08, "body_tint": Color(.90,.05,.08), "core_tint": Color(1,.44,.32), "seed": 7.2})
	_impact_feedback(6.0, .2, .0)

func _blood_lifesteal(victim: Vector3, boss: Vector3) -> void:
	_painted("boss_blood_lifesteal.png", {"from": victim + Vector3(0,.38,.02), "to": _on_boss(boss, .52), "size": Vector2(.66,.88), "duration": .72, "travel_ratio": .70, "dark_tint": Color(.14,.0,.02), "body_tint": Color(.92,.06,.08), "core_tint": Color(1,.42,.32), "seed": 5.7})

# ── 噬魂领主 ────────────────────────────────────────────────────────────
func _soul_devour(victim: Vector3, boss: Vector3, context: Dictionary) -> void:
	_painted("boss_soul_devour.png", {"position": victim + Vector3(0,.30,.02), "size": Vector2(1.18,1.12), "duration": .72, "dark_tint": Color(.012,.04,.06), "body_tint": Color(.22,.70,.72), "core_tint": Color(.80,1,.98), "seed": 2.8})
	_painted("boss_soul_fragment.png", {"from": victim + Vector3(0,.42,.03), "to": _on_boss(boss, .58, .03), "size": Vector2(.62,.82), "duration": .88, "delay": .12, "travel_ratio": .72, "dark_tint": Color(.015,.04,.06), "body_tint": Color(.26,.78,.80), "core_tint": Color(.86,1,.98), "seed": 6.1})
	_painted("boss_soul_growth.png", {"position": _on_boss(boss, .48, .04), "size": Vector2(1.05,1.05) * BOSS_SCALE, "duration": .78, "delay": .52, "dark_tint": Color(.012,.04,.06), "body_tint": Color(.22,.70,.72), "core_tint": Color(.82,1,.96), "seed": 9.1})
	_extra("soul_wisps", boss, victim + Vector3(0,.4,0), {"origin_height": BOSS_H, "origin_node": context.get("boss_node")})

# ── 双生守门人 ──────────────────────────────────────────────────────────
# 连线的长度要正好连上两只：手绘层会把 size 统一乘 VFX_SIZE_SCALE（0.6），这里先除回去，
# 否则线只有两者距离的六成，实战里看着是中间一小截。
func _twin_timer(dead_at: Vector3, partner: Vector3) -> void:
	# 倒计时由 twin_countdown 的金色计时圈表达；手绘计时盘保留在中心做装饰。
	_extra_forced("twin_countdown", dead_at, dead_at, {"origin_height": BOSS_H, "revive_sec": 5.0})
	_painted("boss_twin_timer.png", {"position": dead_at + Vector3(0,.20,.02), "ground": true, "size": Vector2(1.15,.92) * BOSS_SCALE, "duration": 4.8, "end_scale": .92, "dark_tint": Color(.20,.12,.0), "body_tint": Color(.92,.70,.22), "core_tint": Color(1,.96,.66), "seed": 2.4})
	_painted("boss_twin_link.png", {"position": (dead_at+partner)*.5 + Vector3(0,.42*BOSS_SCALE,.03), "size": Vector2(dead_at.distance_to(partner) / VFXBlockRoot.VFX_SIZE_SCALE,.72), "duration": 4.6, "dark_tint": Color(.08,.02,.16), "body_tint": Color(.62,.36,.96), "core_tint": Color(.96,.86,1), "seed": 5.8})

func _twin_revive(at: Vector3) -> void:
	var pillar := _block(PILLAR) as VFXFallingPillar3D
	if pillar != null:
		pillar.play_pillar(at, _profile(Color(.10,.04,.18), Color(.60,.30,.94), Color(.96,.86,1), 1.6, 1.08, 3.8))
	_painted("boss_twin_revive.png", {"position": _on_boss(at, .54, .03), "size": Vector2(1.22,1.52) * BOSS_SCALE, "duration": 1.10, "dark_tint": Color(.08,.02,.16), "body_tint": Color(.62,.34,.96), "core_tint": Color(.98,.90,1), "seed": 7.4})
	_extra("twin_sigil", at, at, {"origin_height": BOSS_H})
	var shield := _block(BARRIER) as VFXBarrierShield3D
	if shield != null:
		shield.play_barrier(at, _profile(Color(.05,.025,.10), Color(.50,.26,.82), Color(.94,.82,1), .75 * BOSS_SCALE, .92, 3.0))

# ── 灭世裁决者 ──────────────────────────────────────────────────────────
# 10.18：蓄力 2 秒时这一路每个敌人脚下一个逐渐填满的预警圈（倒计时）；落下时每个目标大爆闪 +
# 光柱 + 屏震卡帧（施法屏震已在 BattleVfx 跳过）；被打断时收掉预警圈。全屏闪光试过，
# 柔光片在画面上是一团圆雾，去掉了。
func _apocalypse_charge(origin: Vector3, context: Dictionary) -> void:
	_painted("boss_apocalypse_chargeup.png", {"position": _on_boss(origin, .54), "size": Vector2(1.48,1.45) * BOSS_SCALE, "duration": 1.95, "dark_tint": Color(.05,.02,.08), "body_tint": Color(.60,.26,.80), "core_tint": Color(1,.80,.40), "seed": 3.3, "end_scale": 1.04})
	_painted("boss_apocalypse_shield.png", {"position": _on_boss(origin, .58, .03), "size": Vector2(1.64,1.50) * BOSS_SCALE, "duration": 1.95, "delay": .08, "opacity": .82, "dark_tint": Color(.06,.03,.10), "body_tint": Color(.58,.36,.82), "core_tint": Color(1,.84,.48), "seed": 8.0})
	var lane: Array = context.get("lane_targets", [])
	if not lane.is_empty():
		var warn := _extra_forced("apocalypse_warn", origin, origin, {"targets": lane, "charge_sec": 1.95, "target_height": UNIT_H})
		if warn != null:
			_apocalypse_warns.append({"ref": weakref(warn), "at": origin})

func _apocalypse_complete(origin: Vector3, targets: Array) -> void:
	_clear_apocalypse_warns(origin)
	for i in targets.size():
		var at: Vector3 = targets[i]
		_painted("boss_apocalypse_blast.png", {"position": at + Vector3(0,.30,.03), "size": Vector2(1.82,1.62), "duration": .82, "start_scale": .08, "peak_scale": 1.10, "dark_tint": Color(.05,.02,.07), "body_tint": Color(.66,.26,.72), "core_tint": Color(1,.86,.46), "seed": float(i)*3.2})
		var pillar := _block(PILLAR) as VFXFallingPillar3D
		if pillar != null:
			pillar.play_pillar(at, _profile(Color(.05,.02,.08), Color(.60,.22,.72), Color(1,.82,.40), 1.0, .86, 3.8))
	_extra_forced("apocalypse_flash", origin, origin, {"targets": targets, "target_height": UNIT_H})
	# 三路的灭世往往同一拍落下：屏震卡帧同一拍只给一次，免得叠成三倍。
	var now := Time.get_ticks_msec()
	if now - _last_apocalypse_shake_msec > 300:
		_last_apocalypse_shake_msec = now
		_impact_feedback(12.0, .28, .08)

func _apocalypse_interrupt(origin: Vector3) -> void:
	_clear_apocalypse_warns(origin)
	var shield := _block(BARRIER) as VFXBarrierShield3D
	if shield != null:
		shield.play_barrier(origin, _profile(Color(.05,.025,.08), Color(.50,.24,.68), Color(.94,.66,.36), .86 * BOSS_SCALE, .62, 3.0))
	_extra("mirror_shatter", origin, origin, {"target_height": BOSS_H})

# 只收这一只 Boss 的预警圈（三路的灭世各自蓄力，一只被打断不影响别路）。
# 按蓄力时的 Boss 位置认领：Boss 蓄力期间不移动。
func _clear_apocalypse_warns(boss_at: Vector3) -> void:
	var keep: Array = []
	for entry in _apocalypse_warns:
		var node: Variant = (entry["ref"] as WeakRef).get_ref()
		if not is_instance_valid(node):
			continue
		if (entry["at"] as Vector3).distance_to(boss_at) < .6:
			(node as Node).queue_free()
		else:
			keep.append(entry)
	_apocalypse_warns = keep

# ── 共用 ────────────────────────────────────────────────────────────────

# 命中那一拍的屏震 + 卡帧（施法那一刻的屏震由模拟器的 skill_shake 给；落点有延迟的
# 陨星 / 灭世在 BattleVfx 那边跳过了施法屏震，改由这里在真正落下时给）。
# VFXManager 是 autoload，按名字取（--script 跑截帧工具时可能不在）。
func _impact_feedback(strength: float, duration: float, hitstop: float) -> void:
	if not is_inside_tree():
		return
	var manager := get_tree().root.get_node_or_null("VFXManager")
	if manager == null:
		return
	if hitstop > 0.0 and manager.has_method("play_hitstop"):
		manager.call("play_hitstop", hitstop)
	if manager.has_method("play_screen_shake"):
		manager.call("play_screen_shake", strength, duration)

func _after(seconds: float, fn: Callable) -> void:
	if not is_inside_tree():
		return
	get_tree().create_timer(seconds).timeout.connect(func() -> void:
		if is_inside_tree() and not is_queued_for_deletion():
			fn.call())

# 原色贴图 / 序列帧（不走手绘层的染色着色器）。
func _flip(at: Vector3, spec: Dictionary) -> void:
	var fx := _block(FLIPBOOK) as VFXFlipbookSkill3D
	if fx == null:
		return
	var full := {"columns": 1, "rows": 1, "frame_count": 1, "fps": 1.0, "billboard": true}
	full.merge(spec, true)
	fx.play_spec(at, full, {})

func _extra(kind: String, origin: Vector3, target: Vector3, context: Dictionary) -> Node3D:
	var fx := _block(EXTRAS)
	if fx == null:
		return null
	fx.name = "BossExtra" + kind.to_pascal_case()
	fx.call("play_extra", kind, origin, target, context)
	return fx

# 关键提示（预警圈 / 常驻粒子气 / 全屏闪光）不受并发上限约束。
func _extra_forced(kind: String, origin: Vector3, target: Vector3, context: Dictionary) -> Node3D:
	var fx := VFXBlockRoot.spawn_block(EXTRAS, self, true)
	if fx == null:
		return null
	fx.name = "BossExtra" + kind.to_pascal_case()
	fx.call("play_extra", kind, origin, target, context)
	return fx

# 所有 VFX 块都从这里生成，统一受全局并发上限约束；超限返回 null。
# 调用方要么判空，要么依赖已有的 is_instance_valid() 守卫（对 null 返回 false）。
#
# 脚本是运行期传进来的，所以这里只能声明成 Node3D；调用点必须显式
# `as <具体类型>`，否则变量被定型成 Node3D，被 tween 的 lambda 捕获后
# 运行时会报 "Nonexistent function 'play_layer' in base 'Node3D'"。
func _block(script: Script) -> Node3D:
	return VFXBlockRoot.spawn_block(script, self)

# 群体技能的特效目标列表，按画质档位截断。纯表现层：
# 伤害/治疗判定仍然由战斗模拟作用于全部目标，这里只少画几个。
func _capped_targets(targets: Array) -> Array:
	var limit := VFXQualityBudget.max_aoe_targets(targets.size())
	return targets if limit >= targets.size() else targets.slice(0, limit)

func _painted(file_name: String, params: Dictionary) -> void:
	var layer := _block(PAINTED) as VFXBossTextureLayer3D
	if layer == null:
		return
	layer.name = file_name.get_basename().to_pascal_case()
	layer.play_layer(TEX + file_name, params)

func _profile(dark: Color, main: Color, core: Color, size: float, duration: float, energy: float) -> VFXProfile3D:
	var p := PROFILE.new()
	p.dark_color = dark
	p.main_color = main
	p.core_color = core
	p.size = size
	p.duration = duration
	p.emission_energy = energy
	p.particle_count = 12
	return p

func _tracked_target(fallback: Vector3, context: Dictionary) -> Vector3:
	var target_node: Variant = context.get("target_node")
	# Check lifetime before any type query: a freed Object can throw while
	# evaluating `is Node3D` even though is_instance_valid() is safe.
	if not is_instance_valid(target_node):
		return fallback
	var target_object := target_node as Node3D
	if target_object == null:
		return fallback
	var tracked := to_local(target_object.global_position)
	tracked.y = fallback.y
	return tracked

# Same contract as VFXBlockRoot.wait_for(): this composer extends Node3D, not
# VFXBlockRoot, so it needs its own copy. Without it _overload_counter() fails to
# compile and takes the whole battle script chain (and Main.gd) down with it (10-07).
func wait_for(seconds: float, process_always := false) -> bool:
	if not is_inside_tree() or is_queued_for_deletion():
		return false
	var tree := get_tree()
	if tree == null:
		return false
	var timer := tree.create_timer(maxf(seconds, 0.0), process_always)
	await timer.timeout
	return is_inside_tree() and not is_queued_for_deletion()
