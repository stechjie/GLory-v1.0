extends Node3D
class_name UnitSkillVFXComposer3D

const VFX_PROJECTILE:=preload("res://effects/vfx3d/modules/VFXProjectile3D.gd")
const VFX_FALLING_PILLAR:=preload("res://effects/vfx3d/modules/VFXFallingPillar3D.gd")
const VFX_BARRIER:=preload("res://effects/vfx3d/modules/VFXBarrierShield3D.gd")
const VFX_ROAR_CONE:=preload("res://effects/vfx3d/modules/VFXRoarCone3D.gd")
const VFX_TRACKED_LINK:=preload("res://effects/vfx3d/modules/VFXTrackedLink3D.gd")
const VFX_VORTEX:=preload("res://effects/vfx3d/modules/VFXVortexField3D.gd")
const VFX_SUMMON:=preload("res://effects/vfx3d/modules/VFXSummonSpawn3D.gd")
const VFX_AFTERIMAGE:=preload("res://effects/vfx3d/modules/VFXAfterimageDash3D.gd")
const VFX_STATUS:=preload("res://effects/vfx3d/modules/VFXStatusEffect3D.gd")
const VFX_SLASH_ARC:=preload("res://effects/vfx3d/modules/VFXSlashArc3D.gd")
const VFX_SLASH_RING:=preload("res://effects/vfx3d/modules/VFXSlashRing3D.gd")
const VFX_LIGHT_PULSE:=preload("res://effects/vfx3d/modules/VFXLightPulse3D.gd")
const VFX_ENERGY_BURST:=preload("res://effects/vfx3d/modules/VFXEnergyBurst3D.gd")
const VFX_IMPACT_FLASH:=preload("res://effects/vfx3d/modules/VFXImpactFlash3D.gd")
const VFX_RACE_BASIC_ATTACK:=preload("res://effects/vfx3d/modules/VFXRaceBasicAttack3D.gd")
const BASIC_GOD:=preload("res://effects/vfx3d/profiles/examples/basic_attack_god.tres")
const BASIC_HUMAN:=preload("res://effects/vfx3d/profiles/examples/basic_attack_human.tres")
const BASIC_DARK:=preload("res://effects/vfx3d/profiles/examples/basic_attack_dark.tres")
const BASIC_UNDEAD:=preload("res://effects/vfx3d/profiles/examples/basic_attack_undead.tres")
const VFX_MOTHER_EXECUTE:=preload("res://effects/vfx3d/modules/VFXMotherExecute3D.gd")
const MOTHER_EXECUTE_PROFILE:=preload("res://effects/vfx3d/profiles/examples/mother_execute_example.tres")

func play_skill(skill_id:String,origin:Vector3,target:Vector3,context:Dictionary={})->void:
	match skill_id:
		"lowest_ally_heal":_holy_heal(target)
		"nearest_ally_bless":_ally_bless(origin,target,context)
		"nearby_ally_heal_buff":_holy_group(origin,context)
		"random_attribute_bolt":_arcane_bolt(origin,target,context)
		"judgement_strike":_judgement(target)
		"random_ally_damage_reduction":_barrier(target,_holy_profile(.72,1.25))
		"global_divine_blast":_global_divine(target,context)
		"silence_bolt":_silence_bolt(origin,target,context)
		"fear":_fear_hit(origin,target,context)
		"stun":_status_hit(target,"stun",context)
		"black_hole":_black_hole(origin)
		"blink_low_def_backline":_blink_slash(origin,target)
		"shared_hp_link":_tracked_link(origin,target,context,_shadow_profile(.78,1.7))
		"front_cone_stun":_front_stun(origin,target,context)
		"guardian_shield_taunt":_barrier(origin,_holy_profile(.86,1.55))
		"true_damage_attack":_true_damage_hit(target)
		"curse_attack":_status_hit(target,"fear",context)
		"same_target_damage_stack":_stack_pulse(origin)
		"poison_attack":_status_hit(target,"poison",context)
		"defense_down_attack":_status_hit(target,"defense_down",context)
		"every_fourth_combo":_combo_hit(origin,target)
		"every_fifth_group_heal":_holy_group(origin,context)
		"death_poison_explosion":_poison_death(origin)
		"poison_reflect_armor_stack":_stack_pulse(origin,Color(.30,.76,.10))
		"parasite_on_kill":_summon(target)
		"left_neighbor_sacrifice":_tracked_link(origin,target,context,_blood_profile(.76,2.0))
		"attack_interrupt":_interrupt_hit(target)
		"basic_attack_ranged_god":_basic_attack(origin,target,"god","ranged",context)
		"basic_attack_melee_god":_basic_attack(origin,target,"god","melee",context)
		"basic_attack_ranged_human":_basic_attack(origin,target,"human","ranged",context)
		"basic_attack_melee_human":_basic_attack(origin,target,"human","melee",context)
		"basic_attack_ranged_dark":_basic_attack(origin,target,"dark","ranged",context)
		"basic_attack_melee_dark":_basic_attack(origin,target,"dark","melee",context)
		"basic_attack_ranged_undead":_basic_attack(origin,target,"undead","ranged",context)
		"basic_attack_melee_undead":_basic_attack(origin,target,"undead","melee",context)
		"unique_death_execute":_spawn(VFX_MOTHER_EXECUTE,MOTHER_EXECUTE_PROFILE,{"origin":origin,"target":target})

func _basic_attack(origin:Vector3,target:Vector3,race:String,mode:String,context:Dictionary)->void:
	var profile:VFXProfile3D=BASIC_HUMAN
	match race:
		"god":profile=BASIC_GOD
		"dark":profile=BASIC_DARK
		"undead":profile=BASIC_UNDEAD
	_spawn(VFX_RACE_BASIC_ATTACK,profile,{"origin":origin,"target":target,"target_node":context.get("target_node"),"race":race,"mode":mode})

func _holy_heal(target:Vector3)->void:
	_spawn(VFX_FALLING_PILLAR,_holy_profile(.68,1.15),{"target":target})
	_spawn(VFX_LIGHT_PULSE,_holy_profile(.62,.72),{"target":target+Vector3(0,.34,0)})

func _ally_bless(origin:Vector3,target:Vector3,context:Dictionary)->void:
	_tracked_link(origin,target,context,_holy_profile(.58,1.15));_barrier(target,_holy_profile(.66,1.30))

func _holy_group(origin:Vector3,context:Dictionary)->void:
	_spawn(VFX_LIGHT_PULSE,_holy_profile(1.05,1.0),{"target":origin+Vector3(0,.28,0)})
	for value in context.get("targets",[]):_spawn(VFX_FALLING_PILLAR,_holy_profile(.46,.90),{"target":value})

func _arcane_bolt(origin:Vector3,target:Vector3,context:Dictionary)->void:
	var p:=_profile(Color(.04,.06,.16),Color(.24,.48,.94),Color(.72,.94,1.0),.62,.92,3.15,10)
	_spawn(VFX_PROJECTILE,p,{"origin":origin,"target":target,"target_node":context.get("target_node")})

func _judgement(target:Vector3)->void:
	_spawn(VFX_FALLING_PILLAR,_holy_profile(.82,1.0),{"target":target})
	var slash:=_holy_profile(.82,.72);slash.dark_color=Color(.18,.07,.012);slash.main_color=Color(.94,.42,.055);slash.core_color=Color(1.0,.92,.52)
	_spawn(VFX_SLASH_RING,slash,{"target":target})

func _global_divine(target:Vector3,context:Dictionary)->void:
	var targets:Array=context.get("targets",[])
	if targets.is_empty():targets=[target]
	for value in targets:_spawn(VFX_FALLING_PILLAR,_holy_profile(.72,1.02),{"target":value})

func _silence_bolt(origin:Vector3,target:Vector3,context:Dictionary)->void:
	var p:=_shadow_profile(.64,.98);p.main_color=Color(.38,.10,.68);p.core_color=Color(.82,.50,1.0)
	_spawn(VFX_PROJECTILE,p,{"origin":origin,"target":target,"target_node":context.get("target_node")});_status_hit(target,"silence",context)

func _fear_hit(origin:Vector3,target:Vector3,context:Dictionary)->void:
	var p:=_blood_profile(.82,.88);p.dark_color=Color(.04,.006,.025);p.main_color=Color(.48,.025,.13);p.core_color=Color(1.0,.20,.42)
	_spawn(VFX_ENERGY_BURST,p,{"target":target,"direction":(target-origin).normalized()});_status_hit(target,"fear",context)

func _black_hole(origin:Vector3)->void:
	var p:=_shadow_profile(1.18,2.05);p.main_color=Color(.22,.035,.42);p.core_color=Color(.70,.26,1.0);p.particle_count=14
	_spawn(VFX_VORTEX,p,{"target":origin})

func _blink_slash(origin:Vector3,target:Vector3)->void:
	var dash:=_shadow_profile(.74,.72);dash.main_color=Color(.16,.50,.70);dash.core_color=Color(.70,.96,1.0)
	_spawn(VFX_AFTERIMAGE,dash,{"origin":origin,"target":target})
	var slash:=_shadow_profile(.72,.62);slash.main_color=Color(.48,.12,.66);slash.core_color=Color(.92,.58,1.0)
	_spawn(VFX_SLASH_ARC,slash,{"target":target+Vector3(0,.36,0),"direction":(target-origin).normalized()})

func _front_stun(origin:Vector3,target:Vector3,context:Dictionary)->void:
	var p:=_profile(Color(.10,.035,.012),Color(.82,.26,.035),Color(1.0,.76,.24),.92,.86,3.2,12)
	_spawn(VFX_ROAR_CONE,p,{"origin":origin+Vector3(0,.35,0),"target":target+Vector3(0,.25,0)});_status_hit(target,"stun",context)

func _barrier(target:Vector3,profile:VFXProfile3D)->void:_spawn(VFX_BARRIER,profile,{"target":target})

func _tracked_link(origin:Vector3,target:Vector3,context:Dictionary,profile:VFXProfile3D)->void:
	_spawn(VFX_TRACKED_LINK,profile,{"origin":origin,"target":target,"origin_node":context.get("origin_node"),"target_node":context.get("target_node")})

func _status_hit(target:Vector3,status_type:String,context:Dictionary)->void:
	var p:=_shadow_profile(.54,1.18);p.parameters={"status_type":status_type};p.particle_count=7
	_spawn(VFX_STATUS,p,{"target":target,"target_node":context.get("target_node")})

func _true_damage_hit(target:Vector3)->void:
	var p:=_holy_profile(.54,.42);p.main_color=Color(.28,.68,1.0);p.core_color=Color(.88,.98,1.0)
	_spawn(VFX_IMPACT_FLASH,p,{"target":target})

func _stack_pulse(origin:Vector3,color:=Color(.58,.18,.82))->void:
	_spawn(VFX_LIGHT_PULSE,_profile(color.darkened(.72),color,color.lightened(.48),.48,.52,2.5,6),{"target":origin+Vector3(0,.42,0)})

func _combo_hit(origin:Vector3,target:Vector3)->void:
	_spawn(VFX_SLASH_ARC,_profile(Color(.08,.035,.012),Color(.90,.28,.035),Color(1.0,.82,.32),.72,.58,3.0,8),{"target":target+Vector3(0,.30,0),"direction":(target-origin).normalized()})

func _poison_death(origin:Vector3)->void:
	_spawn(VFX_ENERGY_BURST,_profile(Color(.035,.06,.015),Color(.30,.68,.06),Color(.80,1.0,.22),.92,1.05,3.1,13),{"target":origin,"direction":Vector3.UP})

func _summon(target:Vector3)->void:
	var p:=_shadow_profile(.78,1.34);p.main_color=Color(.12,.58,.46);p.core_color=Color(.70,1.0,.78);_spawn(VFX_SUMMON,p,{"target":target})

func _interrupt_hit(target:Vector3)->void:
	_spawn(VFX_IMPACT_FLASH,_profile(Color(.10,.025,.008),Color(.88,.18,.025),Color(1.0,.72,.18),.48,.36,3.3,7),{"target":target})

func _spawn(script:Script,profile:VFXProfile3D,context:Dictionary)->Node3D:
	var node:=script.new() as Node3D;add_child(node);node.call("play_profile",profile,context);return node

func _profile(dark:Color,main:Color,core:Color,size:float,duration:float,energy:float,count:int)->VFXProfile3D:
	var p:=VFXProfile3D.new();p.dark_color=dark;p.main_color=main;p.core_color=core;p.size=size;p.duration=duration;p.emission_energy=energy;p.particle_count=count;return p

func _holy_profile(size:float,duration:float)->VFXProfile3D:return _profile(Color(.13,.055,.012),Color(.86,.44,.08),Color(1.0,.92,.58),size,duration,3.2,10)
func _shadow_profile(size:float,duration:float)->VFXProfile3D:return _profile(Color(.025,.012,.055),Color(.28,.08,.52),Color(.76,.46,1.0),size,duration,3.0,10)
func _blood_profile(size:float,duration:float)->VFXProfile3D:return _profile(Color(.065,.008,.012),Color(.58,.025,.055),Color(1.0,.22,.22),size,duration,3.0,9)
