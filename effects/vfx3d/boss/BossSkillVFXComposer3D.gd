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
const GROUND_SIGIL := preload("res://effects/vfx3d/modules/VFXGroundSigil3D.gd")
const BINBUN := preload("res://effects/vfx3d/vfxv2/VFXBinbunReference3D.gd")
const EXTERNAL := preload("res://effects/vfx3d/vfxv2/VFXV2ExternalReference3D.gd")

const TEX := "res://assets/vfx/boss/"

func play_skill(effect_id: String, origin: Vector3, target: Vector3, context: Dictionary = {}) -> void:
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
		"blood_lifesteal": _blood_lifesteal(target, origin)
		"soul_devour": _soul_devour(target, origin)
		"twin_timer": _twin_timer(origin, target)
		"twin_revive": _twin_revive(target)
		"apocalypse_charge": _apocalypse_charge(origin)
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

func _meteor_v2(target: Vector3) -> void:
	var profile := _profile(Color(.10,.018,.006), Color(.92,.16,.018), Color(1.0,.82,.30), 1.15, 1.2, 4.2)
	# 地面预警圈用自制的 GroundSigil，不再走 binbun 的 "area"。
	# binbun area 是 7 节点 / 24 子资源 / 3 个 shader / 66 粒子，还带 2 张
	# 512x512 的无缝 cellular 噪声图（加载时 CPU 现算，实测 24.5 ms/张）；
	# 而这里只需要"地上一个可读的红圈"，自制法阵就够，且成本低一个数量级。
	var warning := _block(GROUND_SIGIL)
	if warning != null:
		warning.call("play_profile", profile, {"target": target + Vector3(0,.02,0)})
	_painted("boss_meteor_trail.png", {"from": target + Vector3(-.55,3.25,.02), "to": target + Vector3(0,.34,0), "size": Vector2(.86,.38), "duration": .88, "delay": .12, "rotation_z": -12.0, "body_tint": Color(.92,.16,.018), "core_tint": Color(1.0,.82,.30), "seed": 7.1, "flow_strength": .024})
	var impact := _block(EXTERNAL) as VFXV2ExternalReference3D
	var impact_profile := _profile(Color(.12,.012,.004), Color(1.0,.22,.025), Color(1.0,.92,.52), 1.3, .72, 5.0)
	var tw := create_tween()
	tw.tween_interval(.68)
	tw.tween_callback(func():
		if is_instance_valid(impact): impact.play_external("starter_explosion", target + Vector3(0,.22,.03), target, impact_profile)
	)

func _overload_stack(origin: Vector3) -> void:
	_painted("boss_thunder_stack.png", {"position": origin + Vector3(0,.72,.02), "size": Vector2(.72,.72), "duration": .50, "peak_scale": .72, "body_tint": Color(.22,.55,1), "core_tint": Color(.82,.96,1), "seed": 1.8})

func _overload_counter(origin: Vector3, target: Vector3, context: Dictionary) -> void:
	_painted("boss_thunder_overload.png", {"position": origin + Vector3(0,.52,.02), "size": Vector2(1.28,1.05), "duration": .68, "body_tint": Color(.20,.48,1), "core_tint": Color(.78,.96,1), "seed": 8.2})
	var ball := _block(LIGHTNING_BALL) as VFXLightningBall
	var target_node: Variant = context.get("target_node")
	if ball != null:
		ball.play_ball(origin + Vector3(0,.62,0), target + Vector3(0,.38,0), target_node)
	await get_tree().create_timer(.38).timeout
	target = _tracked_target(target, context)
	var arc := _block(LIGHTNING_ARC) as VFXLightningArc
	if arc != null:
		arc.play_arc(target + Vector3(0,2.75,0), target)
	_painted("boss_thunder_counter.png", {"position": target + Vector3(0,.38,.04), "size": Vector2(1.46,1.32), "duration": .66, "start_scale": .10, "body_tint": Color(.16,.48,1), "core_tint": Color(.85,.98,1), "seed": 3.4})

func _mirror_spawn(target: Vector3) -> void:
	_painted("boss_mirror_split.png", {"position": target + Vector3(0,.42,.02), "size": Vector2(1.65,1.48), "duration": .82, "dark_tint": Color(.04,.015,.08), "body_tint": Color(.46,.20,.72), "core_tint": Color(.92,.72,1), "seed": 4.0})
	_painted("boss_mirror_clone.png", {"position": target + Vector3(0,.55,.03), "size": Vector2(1.05,1.25), "duration": 1.0, "delay": .15, "start_scale": .08, "peak_scale": .92, "dark_tint": Color(.025,.01,.05), "seed": 6.7})

func _mirror_slash(origin: Vector3, target: Vector3) -> void:
	var slash := _block(SLASH_ARC) as VFXSlashArc3D
	var p := _profile(Color(.035,.012,.06), Color(.44,.12,.72), Color(.92,.68,1), .82, .62, 3.0)
	if slash != null:
		slash.play_profile(p, {"target": target + Vector3(0,.35,0), "direction": (target-origin).normalized()})
	_painted("boss_mirror_slash.png", {"position": target + Vector3(0,.36,.04), "size": Vector2(1.32,.95), "duration": .56, "rotation_z": rad_to_deg((target-origin).angle_to(Vector3.RIGHT)), "body_tint": Color(.56,.26,.85), "core_tint": Color(.96,.80,1), "seed": 5.1})

func _holy_purify(origin: Vector3, targets: Array) -> void:
	_painted("boss_holy_purify.png", {"position": origin + Vector3(0,.58,.03), "size": Vector2(1.45,1.42), "duration": 1.10, "body_tint": Color(.92,.72,.30), "core_tint": Color(1,.98,.76), "seed": 2.2})
	var caster_pillar := _block(PILLAR) as VFXFallingPillar3D
	if caster_pillar != null:
		caster_pillar.play_pillar(origin, _profile(Color(.16,.09,.015), Color(.92,.60,.14), Color(1,.96,.70), .88, 1.05, 3.2))
	for value in targets:
		var at: Vector3 = value
		_painted("boss_holy_heal.png", {"position": at + Vector3(0,.48,.03), "size": Vector2(.92,1.0), "duration": .90, "delay": .12, "rise": .22, "body_tint": Color(.94,.77,.36), "core_tint": Color(1,.98,.78), "seed": float(targets.find(value))*2.1})
		var shield := _block(BARRIER) as VFXBarrierShield3D
		if shield != null:
			shield.play_barrier(at, _profile(Color(.10,.07,.02), Color(.78,.58,.15), Color(1,.94,.66), .70, .82, 2.7))

func _rage_stack(origin: Vector3, stacks: int) -> void:
	# 狂战灾兽。原本基数 .58 + 每层 .012，5 层才 .64，几乎看不见。
	# 提到基数 .95 + 每层 .03（20 层封顶 1.55），层数越高越猛，贴合"狂战"。
	_painted("boss_rage_stack.png", {"position": origin + Vector3(0,.46,.02), "size": Vector2(.78,.82), "duration": .42, "peak_scale": .95 + minf(stacks,20)*.03, "body_tint": Color(.82,.16,.05), "core_tint": Color(1,.66,.20), "seed": float(stacks)})

func _rage_milestone(origin: Vector3, target: Vector3, stacks: int) -> void:
	_painted("boss_rage_aura.png", {"position": origin + Vector3(0,.48,.02), "size": Vector2(1.42,1.42), "duration": 1.05, "body_tint": Color(.72,.10,.025), "core_tint": Color(1,.54,.12), "seed": float(stacks)})
	var roar := _block(ROAR) as VFXRoarCone3D
	if roar != null:
		roar.play_roar(origin + Vector3(0,.56,0), target + Vector3(0,.36,0), _profile(Color(.12,.025,.01), Color(.72,.11,.025), Color(1,.56,.14), .92 + stacks*.012, .88, 3.0))
	_painted("boss_rage_burst.png", {"position": target + Vector3(0,.30,.03), "size": Vector2(1.45,1.18), "duration": .62, "delay": .22, "body_tint": Color(.82,.13,.025), "core_tint": Color(1,.72,.24), "seed": 9.3})

func _blood_rage(origin: Vector3) -> void:
	_painted("boss_blood_rage.png", {"position": origin + Vector3(0,.54,.02), "size": Vector2(1.46,1.55), "duration": 1.25, "dark_tint": Color(.08,.005,.012), "body_tint": Color(.65,.025,.04), "core_tint": Color(1,.24,.18), "seed": 4.2})
	_painted("boss_blood_overflow.png", {"position": origin + Vector3(0,.34,.03), "size": Vector2(1.72,1.48), "duration": .78, "delay": .18, "start_scale": .08, "body_tint": Color(.64,.02,.035), "core_tint": Color(1,.30,.18), "seed": 7.2})

func _blood_lifesteal(victim: Vector3, boss: Vector3) -> void:
	_painted("boss_blood_lifesteal.png", {"from": victim + Vector3(0,.38,.02), "to": boss + Vector3(0,.52,.02), "size": Vector2(.66,.88), "duration": .72, "travel_ratio": .70, "body_tint": Color(.72,.025,.04), "core_tint": Color(1,.28,.20), "seed": 5.7})

func _soul_devour(victim: Vector3, boss: Vector3) -> void:
	_painted("boss_soul_devour.png", {"position": victim + Vector3(0,.30,.02), "size": Vector2(1.18,1.12), "duration": .72, "dark_tint": Color(.012,.018,.035), "body_tint": Color(.18,.52,.56), "core_tint": Color(.72,1,.96), "seed": 2.8})
	_painted("boss_soul_fragment.png", {"from": victim + Vector3(0,.42,.03), "to": boss + Vector3(0,.58,.03), "size": Vector2(.62,.82), "duration": .88, "delay": .12, "travel_ratio": .72, "dark_tint": Color(.015,.025,.045), "body_tint": Color(.22,.65,.68), "core_tint": Color(.80,1,.96), "seed": 6.1})
	_painted("boss_soul_growth.png", {"position": boss + Vector3(0,.48,.04), "size": Vector2(1.05,1.05), "duration": .78, "delay": .52, "body_tint": Color(.18,.52,.56), "core_tint": Color(.76,1,.94), "seed": 9.1})

func _twin_timer(dead_at: Vector3, partner: Vector3) -> void:
	_painted("boss_twin_timer.png", {"position": dead_at + Vector3(0,.20,.02), "ground": true, "size": Vector2(1.15,.92), "duration": 4.8, "end_scale": .82, "body_tint": Color(.72,.56,.20), "core_tint": Color(1,.92,.60), "seed": 2.4})
	_painted("boss_twin_link.png", {"position": (dead_at+partner)*.5 + Vector3(0,.42,.03), "size": Vector2(dead_at.distance_to(partner),.42), "duration": 4.6, "body_tint": Color(.44,.28,.70), "core_tint": Color(.88,.72,1), "seed": 5.8})

func _twin_revive(at: Vector3) -> void:
	var pillar := _block(PILLAR) as VFXFallingPillar3D
	if pillar != null:
		pillar.play_pillar(at, _profile(Color(.07,.035,.12), Color(.48,.22,.78), Color(.92,.78,1), .92, 1.08, 3.2))
	_painted("boss_twin_revive.png", {"position": at + Vector3(0,.54,.03), "size": Vector2(1.22,1.52), "duration": 1.10, "body_tint": Color(.52,.26,.82), "core_tint": Color(.94,.82,1), "seed": 7.4})
	var shield := _block(BARRIER) as VFXBarrierShield3D
	if shield != null:
		shield.play_barrier(at, _profile(Color(.05,.025,.10), Color(.42,.20,.72), Color(.90,.76,1), .75, .92, 2.8))

func _apocalypse_charge(origin: Vector3) -> void:
	_painted("boss_apocalypse_chargeup.png", {"position": origin + Vector3(0,.54,.02), "size": Vector2(1.48,1.45), "duration": 1.95, "dark_tint": Color(.025,.012,.045), "body_tint": Color(.44,.18,.62), "core_tint": Color(1,.74,.30), "seed": 3.3, "end_scale": 1.04})
	_painted("boss_apocalypse_shield.png", {"position": origin + Vector3(0,.58,.03), "size": Vector2(1.64,1.50), "duration": 1.95, "delay": .08, "opacity": .82, "dark_tint": Color(.04,.025,.08), "body_tint": Color(.46,.28,.68), "core_tint": Color(1,.80,.42), "seed": 8.0})

func _apocalypse_complete(origin: Vector3, targets: Array) -> void:
	for value in targets:
		var at: Vector3 = value
		_painted("boss_apocalypse_blast.png", {"position": at + Vector3(0,.30,.03), "size": Vector2(1.82,1.62), "duration": .82, "start_scale": .08, "peak_scale": 1.10, "dark_tint": Color(.025,.012,.04), "body_tint": Color(.50,.20,.58), "core_tint": Color(1,.80,.36), "seed": float(targets.find(value))*3.2})
		var pillar := _block(PILLAR) as VFXFallingPillar3D
		if pillar != null:
			pillar.play_pillar(at, _profile(Color(.025,.012,.05), Color(.45,.16,.58), Color(1,.76,.32), .86, .86, 3.4))

func _apocalypse_interrupt(origin: Vector3) -> void:
	var shield := _block(BARRIER) as VFXBarrierShield3D
	if shield != null:
		shield.play_barrier(origin, _profile(Color(.035,.018,.06), Color(.38,.18,.52), Color(.88,.58,.30), .86, .62, 2.6))

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
