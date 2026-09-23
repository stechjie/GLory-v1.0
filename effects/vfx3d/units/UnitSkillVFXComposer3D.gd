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
const VFX_OGA_PROJECTILE:=preload("res://effects/vfx3d/modules/VFXFlipbookProjectile3D.gd")
const VFX_OGA_MELEE:=preload("res://effects/vfx3d/modules/VFXFlipbookMelee3D.gd")
const VFX_OGA_SKILL:=preload("res://effects/vfx3d/modules/VFXFlipbookSkill3D.gd")
const VFX_ANGEL_GUARD:=preload("res://effects/vfx3d/modules/VFXAngelGuard3D.gd")
const PROFILE_ANGEL_GUARD:=preload("res://effects/vfx3d/profiles/examples/angel_guard_example.tres")
const OGA_CHESS_CATALOG:=preload("res://effects/vfx3d/units/OgaChessVFXCatalog.gd")
const BASIC_GOD:=preload("res://effects/vfx3d/profiles/examples/basic_attack_god.tres")
const BASIC_HUMAN:=preload("res://effects/vfx3d/profiles/examples/basic_attack_human.tres")
const BASIC_DARK:=preload("res://effects/vfx3d/profiles/examples/basic_attack_dark.tres")
const BASIC_UNDEAD:=preload("res://effects/vfx3d/profiles/examples/basic_attack_undead.tres")
const VFX_MOTHER_EXECUTE:=preload("res://effects/vfx3d/modules/VFXMotherExecute3D.gd")
const VFX_EXTERNAL:=preload("res://effects/vfx3d/vfxv2/VFXV2ExternalReference3D.gd")
const VFX_PAINTED:=preload("res://effects/vfx3d/modules/VFXBossTextureLayer3D.gd")
const VFX_ARBITER_GROUND:=preload("res://effects/vfx3d/units/VFXArbiterGroundBrush3D.gd")
const VFX_ARBITER_GUARD:=preload("res://effects/vfx3d/units/VFXArbiterGuardFragments3D.gd")
const VFX_DOOM_LINK:=preload("res://effects/vfx3d/units/VFXDoomBloodLink3D.gd")
const VFX_SHOCKWAVE:=preload("res://effects/vfx3d/modules/VFXShockwave3D.gd")
const VFX_GROUND_SIGIL:=preload("res://effects/vfx3d/modules/VFXGroundSigil3D.gd")
const VFX_LIGHTNING_ARC:=preload("res://effects/vfx3d/VFXLightningArc.gd")
const STAR_PRAYER_SIGIL_TEXTURE:="res://assets/vfx/skills/god_priest_star_prayer/starlight_prayer_sigil.png"
const STAR_PRAYER_DESCENT_TEXTURE:="res://assets/vfx/skills/god_priest_star_prayer/starlight_prayer_descent.png"
const STAR_PRAYER_IMPACT_TEXTURE:="res://assets/vfx/skills/god_priest_star_prayer/starlight_prayer_impact.png"
const STAR_PRAYER_FRAGMENTS_TEXTURE:="res://assets/vfx/skills/god_priest_star_prayer/starlight_prayer_fragments.png"
const STAR_PRAYER_CLEANSE_TEXTURE:="res://assets/vfx/skills/god_priest_star_prayer/starlight_prayer_cleanse.png"
const PRIESTESS_BLESSING_SIGIL_TEXTURE:="res://assets/vfx/skills/god_priestess_blessing/priestess_blessing_sigil.png"
const PRIESTESS_BLESSING_RIBBON_TEXTURE:="res://assets/vfx/skills/god_priestess_blessing/priestess_blessing_ribbon.png"
const PRIESTESS_BLESSING_BURST_TEXTURE:="res://assets/vfx/skills/god_priestess_blessing/priestess_blessing_burst.png"
const PRIESTESS_BLESSING_PARTICLES_TEXTURE:="res://assets/vfx/skills/god_priestess_blessing/priestess_blessing_particles.png"
const GUARDIAN_SHIELD_SIGIL_TEXTURE:="res://assets/vfx/skills/god_guardian/guardian_shield_sigil.png"
const GUARDIAN_SHIELD_SHELL_TEXTURE:="res://assets/vfx/skills/god_guardian/guardian_shield_shell.png"
const GUARDIAN_TAUNT_RING_TEXTURE:="res://assets/vfx/skills/god_guardian/guardian_taunt_ring.png"
const GUARDIAN_CRYSTAL_SHARDS_TEXTURE:="res://assets/vfx/skills/god_guardian/guardian_crystal_shards.png"
const AURORA_TRUE_PIERCE_TEXTURE:="res://assets/vfx/skills/god_aurora/god_aurora_true_pierce.png"
const AURORA_TRUE_HIT_TEXTURE:="res://assets/vfx/skills/god_aurora/god_aurora_true_hit.png"
const ANGEL_CAST_WINGS_TEXTURE:="res://assets/vfx/skills/god_angel/god_angel_cast_wings.png"
const ANGEL_HEAL_PULSE_TEXTURE:="res://assets/vfx/skills/god_angel/god_angel_heal_pulse.png"
const ANGEL_HEAL_STROKES_TEXTURE:="res://assets/vfx/skills/god_angel/god_angel_heal_strokes.png"
const ANGEL_BUFF_FRAGMENTS_TEXTURE:="res://assets/vfx/skills/god_angel/god_angel_buff_fragments.png"
const ANGEL_BUFF_RESIDUE_TEXTURE:="res://assets/vfx/skills/god_angel/god_angel_buff_residue.png"
const ARBITER_VERDICT_SLASH_TEXTURE:="res://assets/vfx/skills/god_arbiter/god_arbiter_verdict_slash_v7.png"
const ARBITER_VERDICT_IMPACT_TEXTURE:="res://assets/vfx/skills/god_arbiter/god_arbiter_verdict_impact_v7.png"
const IMP_CLAW_HOOK_TEXTURE:="res://assets/vfx/skills/dark_imp_curse/imp_claw_hook.png"
const IMP_CURSE_INK_TEXTURE:="res://assets/vfx/skills/dark_imp_curse/imp_curse_ink.png"
const MAGE_INK_GATHER_TEXTURE:="res://assets/vfx/skills/dark_mage_silence/mage_ink_gather.png"
const MAGE_INK_SPIKE_TEXTURE:="res://assets/vfx/skills/dark_mage_silence/mage_ink_spike.png"
const MAGE_SILENCE_SEAL_TEXTURE:="res://assets/vfx/skills/dark_mage_silence/mage_silence_seal.png"
const MAGE_SILENCE_WRAP_TEXTURE:="res://assets/vfx/skills/dark_mage_silence/mage_silence_wrap.png"
const FEAR_LOW_SMOKE_TEXTURE:="res://assets/vfx/skills/dark_fear_skill/fear_low_smoke.png"
const FEAR_CLAW_TEAR_TEXTURE:="res://assets/vfx/skills/dark_fear_skill/fear_claw_tear.png"
const FEAR_FLEE_STROKES_TEXTURE:="res://assets/vfx/skills/dark_fear_skill/fear_flee_strokes.png"
const QUEEN_PAIN_WHIP_TEXTURE:="res://assets/vfx/skills/dark_queen_pain/queen_pain_whip.png"
const QUEEN_PAIN_CRACK_TEXTURE:="res://assets/vfx/skills/dark_queen_pain/queen_pain_crack.png"
const QUEEN_PAIN_BREAK_TEXTURE:="res://assets/vfx/skills/dark_queen_pain/queen_pain_break.png"
const SCYTHE_INK_TEAR_TEXTURE:="res://assets/vfx/skills/dark_scythe_blink/scythe_ink_tear.png"
const SCYTHE_CROSS_SLASH_TEXTURE:="res://assets/vfx/skills/dark_scythe_blink/scythe_cross_slash.png"
const SCYTHE_RECALL_TEXTURE:="res://assets/vfx/skills/dark_scythe_blink/scythe_recall_afterimage.png"
const SUC_HOOK_SLASH_TEXTURE:="res://assets/vfx/skills/dark_suc_stun/suc_hook_slash.png"
const SUC_HOOK_IMPACT_TEXTURE:="res://assets/vfx/skills/dark_suc_stun/suc_hook_impact.png"
const SUC_BIND_KNOT_TEXTURE:="res://assets/vfx/skills/dark_suc_stun/suc_bind_knot.png"
const DRAGON_GROUND_CURL_TEXTURE:="res://assets/vfx/skills/dark_dragon_hole/dragon_ground_curl.png"
const DRAGON_DARK_MASS_TEXTURE:="res://assets/vfx/skills/dark_dragon_hole/dragon_dark_mass.png"
const DRAGON_PULL_SHARDS_TEXTURE:="res://assets/vfx/skills/dark_dragon_hole/dragon_pull_shards.png"
const DRAGON_TARGET_DRAG_TEXTURE:="res://assets/vfx/skills/dark_dragon_hole/dragon_target_drag.png"
# 阵型盟友（第 21 回合的守护者）。这五个技能以前全是程序化几何，截帧下
# burn_claw / soul_chain 的画面占比只有 0.05%，等于没有表现。
const FLAMECLAW_EMBER_SHELL_TEXTURE:="res://assets/vfx/skills/ally_flame_claw/flameclaw_ember_shell.png"
const FLAMECLAW_HEAL_UPDRAFT_TEXTURE:="res://assets/vfx/skills/ally_flame_claw/flameclaw_heal_updraft.png"
const FLAMECLAW_GROUND_COALS_TEXTURE:="res://assets/vfx/skills/ally_flame_claw/flameclaw_ground_coals.png"
const SOULCHAIN_CAST_COIL_TEXTURE:="res://assets/vfx/skills/ally_soul_chain/soulchain_cast_coil.png"
const SOULCHAIN_CHAIN_LINK_TEXTURE:="res://assets/vfx/skills/ally_soul_chain/soulchain_chain_link.png"
const SOULCHAIN_LOCK_SEAL_TEXTURE:="res://assets/vfx/skills/ally_soul_chain/soulchain_lock_seal.png"
const SOULCHAIN_DRAG_SMEAR_TEXTURE:="res://assets/vfx/skills/ally_soul_chain/soulchain_drag_smear.png"
const DEVOUR_MAW_TEAR_TEXTURE:="res://assets/vfx/skills/ally_abyss_beast/devour_maw_tear.png"
const DEVOUR_SILENCE_GAG_TEXTURE:="res://assets/vfx/skills/ally_abyss_beast/devour_silence_gag.png"
const DEVOUR_LIFESTEAL_PULL_TEXTURE:="res://assets/vfx/skills/ally_abyss_beast/devour_lifesteal_pull.png"
const INFERNO_SKY_COLUMN_TEXTURE:="res://assets/vfx/skills/ally_hell_inferno/inferno_sky_column.png"
const INFERNO_GROUND_SCORCH_TEXTURE:="res://assets/vfx/skills/ally_hell_inferno/inferno_ground_scorch.png"
const INFERNO_ATK_DOWN_BRAND_TEXTURE:="res://assets/vfx/skills/ally_hell_inferno/inferno_atk_down_brand.png"
const ETERNAL_NIGHT_VORTEX_TEXTURE:="res://assets/vfx/skills/ally_eternal_night/eternal_night_vortex.png"
const ETERNAL_NIGHT_METEOR_TEXTURE:="res://assets/vfx/skills/ally_eternal_night/eternal_night_meteor.png"
const ETERNAL_NIGHT_IMPACT_TEXTURE:="res://assets/vfx/skills/ally_eternal_night/eternal_night_impact.png"
const BUBBLE_BODY_TEXTURE:="res://assets/vfx/skills/merc_pisces_bubble/bubble_body.png"
const BUBBLE_BURST_TEXTURE:="res://assets/vfx/skills/merc_pisces_bubble/bubble_burst_damage.png"
const BUBBLE_STICKY_TEXTURE:="res://assets/vfx/skills/merc_pisces_bubble/bubble_slow_sticky.png"
const BUBBLE_SPLASH_TEXTURE:="res://assets/vfx/skills/merc_pisces_bubble/bubble_heal_splash.png"
const JUDGE_SLASH_TEXTURE:="res://assets/vfx/skills/merc_libra_judge/judge_slash.png"
const JUDGE_IMPACT_TEXTURE:="res://assets/vfx/skills/merc_libra_judge/judge_impact.png"
const JUDGE_SCALE_MARK_TEXTURE:="res://assets/vfx/skills/merc_libra_judge/judge_scale_mark.png"
const HUNT_SCYTHE_CUT_TEXTURE:="res://assets/vfx/skills/merc_scorpio_death/hunt_scythe_cut.png"
const HUNT_RIFT_TEXTURE:="res://assets/vfx/skills/merc_scorpio_death/hunt_rift.png"
const HUNT_ARMOR_CRACK_TEXTURE:="res://assets/vfx/skills/merc_scorpio_death/hunt_armor_crack.png"
const CHARGE_DUST_TEXTURE:="res://assets/vfx/skills/merc_taurus_charge/charge_dust.png"
const CHARGE_TRAIL_TEXTURE:="res://assets/vfx/skills/merc_taurus_charge/charge_trail.png"
const CHARGE_IMPACT_TEXTURE:="res://assets/vfx/skills/merc_taurus_charge/charge_impact.png"
const CHARGE_STUN_DEBRIS_TEXTURE:="res://assets/vfx/skills/merc_taurus_charge/charge_stun_debris.png"
const MOTHER_EXECUTE_PROFILE:=preload("res://effects/vfx3d/profiles/examples/mother_execute_example.tres")

var last_spawned:Node3D
var _poison_residue_nodes:Dictionary = {}

func play_skill(skill_id:String,origin:Vector3,target:Vector3,context:Dictionary={})->Node3D:
	last_spawned=null
	match skill_id:
		"lowest_ally_heal":_holy_heal(target,context)
		"nearest_ally_bless":_ally_bless(origin,target,context)
		"nearby_ally_heal_buff":_holy_group_v2(origin,context)
		"random_attribute_bolt":_attribute_bolt(origin,target,context)
		"judgement_strike":_oga_formal_skill("judgement_strike",origin,target,context)
		"random_ally_damage_reduction":_angel_guard(target,context)
		"global_divine_blast":_global_divine(target,context)
		"silence_bolt":_silence_bolt(origin,target,context)
		"fear":_fear_hit(origin,target,context)
		"stun":_stun_hit(origin,target,context)
		"black_hole":_oga_formal_skill("black_hole",origin,target,context)
		"blink_low_def_backline":_blink_slash(origin,target,context)
		"shared_hp_link":_doom_blood_link(origin,target,context)
		"front_cone_stun":_front_stun(origin,target,context)
		"guardian_shield_taunt":_guardian_shield_taunt(origin,context)
		"true_damage_attack":_true_damage_hit(target)
		"curse_attack":_imp_curse(origin,target,context)
		"same_target_damage_stack":_stack_pulse(origin,target,context)
		"poison_attack":_poison_attack(origin,target,context)
		"defense_down_attack":_defense_down_hit(target,context)
		"every_fourth_combo":_combo_hit(origin,target,context)
		"every_fifth_group_heal":_holy_group(origin,context)
		"death_poison_explosion":_poison_death(origin)
		"poison_reflect_armor_stack":_poison_reflect_stack(origin)
		"parasite_on_kill":_summon(target)
		"left_neighbor_sacrifice":_tracked_link(origin,target,context,_blood_profile(.76,2.0))
		"attack_interrupt":_interrupt_hit(target)
		"bubble_dream":_bubble_dream(origin,target,context)
		"shell_guard":_shell_guard(origin,context)
		"balance_judge":_balance_judge(origin,target,context)
		"gold_charge":_gold_charge(origin,target,context)
		"holy_song":_holy_song(origin,context)
		"twin_strike":_twin_strike(origin,target,context)
		"king_aura":_king_aura(origin,context)
		"arrow_rain":_arrow_rain(origin,target,context)
		"blood_rampage":_blood_rampage(origin)
		"steel_order":_steel_order(origin,context)
		"time_slow":_time_slow(origin,target,context)
		"death_hunt":_death_hunt(origin,target,context)
		"basic_attack_ranged_god":_basic_attack(origin,target,"god","ranged",context)
		"basic_attack_melee_god":_basic_attack(origin,target,"god","melee",context)
		"basic_attack_ranged_human":_basic_attack(origin,target,"human","ranged",context)
		"basic_attack_melee_human":_basic_attack(origin,target,"human","melee",context)
		"basic_attack_ranged_dark":_basic_attack(origin,target,"dark","ranged",context)
		"basic_attack_melee_dark":_basic_attack(origin,target,"dark","melee",context)
		"basic_attack_ranged_undead":_basic_attack(origin,target,"undead","ranged",context)
		"basic_attack_melee_undead":_basic_attack(origin,target,"undead","melee",context)
		"unique_death_execute":
			# 强制生成：书是玩家必须读到的关键事件，跳过并发上限，不被特效密集回合饿死。
			_spawn_forced(VFX_MOTHER_EXECUTE,MOTHER_EXECUTE_PROFILE,{"origin":origin,"target":target,"origin_node":context.get("origin_node"),"target_node":context.get("target_node")})
		"unique_king_growth":_king_attack(origin,target,context)
		# ── PVE 怪物 ──────────────────────────────────────
		"chain_lightning":_chain_lightning(origin,target,context)
		"dive_backline":_dive_backline(origin,target,context)
		"heal_allies":_sky_heal(origin,context)
		"holy_shield_burst":_dome_shield(origin,context)
		"wind_bleed":_wind_bleed(origin,target,context)
		"slow_aura":_slow_aura(origin,context)
		"stun_impact":_stun_impact(origin,target,context)
		"entangle":_entangle(target,context)
		"burrow_ambush":_burrow_ambush(origin,target)
		"lava_burst":_lava_burst(target)
		"nature_heal":_nature_heal(origin,context)
		"earth_slam":_earth_slam(origin,target)
		"backstab":_backstab(origin,target)
		"curse":_curse_hit(target,context)
		"counter_slash":_counter_slash(target)
		# ── 阵型盟友 ──────────────────────────────────────
		"burn_claw":_burn_claw(origin,context)
		"soul_chain":_soul_chain(origin,target,context)
		"devour_bite":_devour_bite(origin,target,context)
		"hell_burst":_hell_burst(target,context)
		"eternal_night":_eternal_night(origin,context)
		_:
			# 兜底：技能表新增条目而这里还没配表现时，至少给一次可读的命中反馈，
			# 而不是像以前那样静默什么都不放（PVE 全套怪物就是这么漏掉的）。
			_generic_hit(target)
	return last_spawned

func _basic_attack(origin:Vector3,target:Vector3,race:String,mode:String,context:Dictionary)->void:
	var uid:=str(context.get("source_unit_id",""))
	# Formal OGA player-chess routes are exclusive. Returning here is intentional:
	# the old race bolt/slash, trail, shards and impact must never be layered under
	# the newly approved flipbook effect.
	if mode=="ranged":
		var projectile_spec:Dictionary=OGA_CHESS_CATALOG.projectile_for(uid)
		if not projectile_spec.is_empty():
			var projectile:=_block(VFX_OGA_PROJECTILE) as VFXFlipbookProjectile3D
			if projectile!=null:
				last_spawned=projectile
				projectile.play_spec(origin,target,projectile_spec,{"target_node":context.get("target_node")})
			return
	else:
		var melee_spec:Dictionary=OGA_CHESS_CATALOG.melee_for(uid,race)
		if not melee_spec.is_empty():
			var melee:=_block(VFX_OGA_MELEE) as VFXFlipbookMelee3D
			if melee!=null:
				last_spawned=melee
				melee.play_spec(origin,target,melee_spec,{"target_node":context.get("target_node")})
			return
	var profile:=_basic_profile_for(uid,race)
	# 有专属 PNG 箭矢的单位（弓箭手/极光射手），远程普攻用它自己的图当弹体；
	# 走同一套弹道系统，所以会跟着飞行方向朝向目标（不再横着）。
	var bolt_tex:=str(PROJECTILE_TEX_BY_UNIT.get(uid,"")) if mode=="ranged" else ""
	_spawn(VFX_RACE_BASIC_ATTACK,profile,{"origin":origin,"target":target,"target_node":context.get("target_node"),"race":race,"mode":mode,"bolt_kind":_bolt_kind_for(uid),"melee_kind":_melee_kind_for(uid),"bolt_tex":bolt_tex})

func _oga_formal_skill(skill_id:String,origin:Vector3,target:Vector3,context:Dictionary)->void:
	var spec:Dictionary=OGA_CHESS_CATALOG.formal_skill_for(skill_id)
	if spec.is_empty():
		return
	var anchor:=target
	var track_node:Variant=context.get("target_node")
	match str(spec.get("anchor","target_body")):
		"origin_ground":
			anchor=_lvl(origin,_uh(context,"origin_height"),LEVEL_FOOT,0.0)
			track_node=context.get("origin_node")
		"target_ground":
			anchor=_lvl(target,_uh(context),LEVEL_FOOT,0.0)
		_:
			anchor=_lvl(target,_uh(context),LEVEL_BODY)
	var effect:=_block(VFX_OGA_SKILL) as VFXFlipbookSkill3D
	if effect==null:
		return
	last_spawned=effect
	effect.play_spec(anchor,spec,{"track_node":track_node})

func _angel_guard(target:Vector3,context:Dictionary)->void:
	# Dedicated new-material route. Do not call the generic barrier, the old
	# HOLY_SHIELD scene, or any god_archangel texture from assets/vfx/skills.
	var active:=PROFILE_ANGEL_GUARD.duplicate_runtime()
	active.duration=maxf(0.9,float(context.get("status_duration",active.duration)))
	var anchor:=_lvl(target,_uh(context),LEVEL_BODY)
	# This is a six-to-eight-second gameplay state, not a disposable hit spark.
	# Spawn it through the critical lane so a crowded battle cannot silently drop
	# the only protection readout for the selected ally.
	var guard:=_block_forced(VFX_ANGEL_GUARD) as VFXAngelGuard3D
	if guard!=null:
		last_spawned=guard
		var guard_context:=context.duplicate(false)
		guard_context["target"]=anchor
		guard_context["status_duration"]=active.duration
		guard.play_guard(anchor,active,guard_context)

# 普攻用的着色 profile：怪物/Boss/佣兵统一灰色中性弹道，和玩家种族区分开；
# 玩家种族按种族色。
var _gray_basic_cache:VFXProfile3D=null
func _basic_profile_for(uid:String,race:String)->VFXProfile3D:
	if uid.begins_with("pve_") or uid.begins_with("boss_") or uid.begins_with("merc_"):
		if _gray_basic_cache==null:
			var g:=BASIC_HUMAN.duplicate_runtime()  # 借用尺寸/时长/参数，只改颜色
			g.dark_color=Color(0.10,0.10,0.12)
			g.main_color=Color(0.56,0.58,0.63)
			g.core_color=Color(0.90,0.92,0.96)
			_gray_basic_cache=g
		return _gray_basic_cache
	match race:
		"god":return BASIC_GOD
		"dark":return BASIC_DARK
		"undead":return BASIC_UNDEAD
	return BASIC_HUMAN

# 专属 PNG 弹道贴图（普攻用）。这些单位本就有画好的箭矢图；走弹道系统的
# 贴图弹体路径，会跟随飞行方向朝向目标。将来别的单位出了 PNG 也填这里。
const PROJECTILE_TEX_BY_UNIT := {
	"human_archer":"res://assets/vfx/skills/human_archer/human_archer_arrow_trail.png",
	"god_aurora":"res://assets/vfx/skills/god_aurora/god_aurora_arrow_trail.png",
}

# 远程普攻的弹道原型：按施法者 unit_id 归类到 6 种形状之一。
# 近战单位不会走到这里（前端按 range_px 分流），所以只列远程单位。
# 未列出的远程单位回落到默认 "lance"（针/矛）。
const BOLT_KIND_BY_UNIT := {
	# 🏹 箭矢
	"human_archer":"arrow", "god_aurora":"arrow", "merc_sagittarius_rain":"arrow",
	"pve_sky_wind_falcon":"arrow",
	# 🔮 法球
	"human_mage":"orb", "merc_pisces_bubble":"orb",
	"merc_aquarius_time":"orb", "pve_ren_voodoo_witch":"orb", "boss_meteor_caster":"orb",
	# 🌙 Authored ink sickle (Shadow Mage; replaces the procedural crescent)
	"dark_mage":"shadow_sickle",
	# ☠️ 毒镖
	"pve_ren_poison_doctor":"dart", "undead_spike":"dart", "undead_mother":"dart",
	# ✨ 圣光弹
	"god_archangel":"holy",
	# 神侍与大祭司使用各自的手绘白金弹道，其他神族继续使用通用圣光弹。
	"god_priest":"star_prayer", "god_priestess":"priestess_ring",
	"human_cleric":"holy", "boss_holy_priest":"holy", "merc_virgo_heal":"holy",
	"pve_sky_hymn_spirit":"holy", "pve_sky_star_butterfly":"holy", "pve_land_ancient_tree":"holy",
	# ✦ 四芒星光羽（天使，避开太圆的圣光弹）
	"god_angel":"star",
	# 🌑 暗能弹
	"ally_soul_chain":"dark", "ally_hell_inferno":"dark",
	# 🌵 Pain Queen's authored barbed needle
	"dark_queen":"thorn_lash",
	# ⚡ 雷弹
	"boss_thunder_core":"thunder", "pve_sky_thunder_spirit":"thunder",
}

func _bolt_kind_for(unit_id:String)->String:
	return str(BOLT_KIND_BY_UNIT.get(unit_id,"lance"))

# 近战 T3 的专属斩击（保持近战、不飞弹道）。人王已有专属天堂剑走别的路，不在此列。
# 其余近战单位回落空串 = 默认单斩。
const MELEE_KIND_BY_UNIT := {
	"dark_imp":"imp_claw",       # Imp: painted claw swipe + break hit
	"dark_fear":"fear_claw",     # Fear Demon: heavy bent claw
	"dark_scythe":"scythe_cut",  # Ambusher: fast narrow cut
	"dark_suc":"suc_hook",       # Succubus: hooked whip swipe
	"dark_dragon":"dragon_claw", # Black Dragon: painted triple claw
	"god_king":"cross",      # 神王·神圣交叉斩
	"god_guard":"guardian_crystal", # 光之卫士·晶体圣刃
	"dark_doom":"doom_scythe",   # Doom Guard: painted scythe arc
	# 焰爪魔灵的普攻带灼烧 DoT（BattleSimulator._apply_attack_statuses 的 burn_claw
	# 分支），所以普攻这条路也要有火爪与灼烧印，主动技那条只管自保。
	"ally_flame_claw":"flame_claw",
}

func _melee_kind_for(unit_id:String)->String:
	return str(MELEE_KIND_BY_UNIT.get(unit_id,""))

func _guardian_shield_taunt(origin:Vector3,context:Dictionary)->void:
	var oh := _uh(context,"origin_height")
	# The guardian skill is self-centered: shield and taunt radius belong to the caster.
	var sigil:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if sigil!=null:
		sigil.play_layer(GUARDIAN_SHIELD_SIGIL_TEXTURE,{
			"name":"GuardianShield_Sigil","position":_lvl(origin,oh,LEVEL_FOOT,0.0),
			"size":Vector2(1.30,1.30),"ground":true,"duration":1.12,
			"start_scale":.08,"peak_scale":.78,"end_scale":1.02,
			"dark_tint":Color(.055,.065,.10),"body_tint":Color(1.0,.97,.88),
			"core_tint":Color(1.0,1.0,.98),"flow_strength":.007,"opacity":.90,"seed":61.0
		})
	var ring:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if ring!=null:
		ring.play_layer(GUARDIAN_TAUNT_RING_TEXTURE,{
			"name":"GuardianTaunt_Ring","position":_lvl(origin,oh,LEVEL_FOOT,0.0),
			"size":Vector2(1.78,1.78),"ground":true,"duration":1.02,
			"start_scale":.08,"peak_scale":.68,"end_scale":1.0,
			"dark_tint":Color(.055,.065,.10),"body_tint":Color(1.0,.96,.84),
			"core_tint":Color(1.0,1.0,.98),"flow_strength":.010,"opacity":.82,"delay":.20,"seed":67.0
		})
	var shell:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if shell!=null:
		shell.play_layer(GUARDIAN_SHIELD_SHELL_TEXTURE,{
			"name":"GuardianShield_Shell","position":_lvl(origin,oh,LEVEL_BODY),
			"size":Vector2(.96,1.56),"duration":1.24,
			"start_scale":.12,"peak_scale":.72,"end_scale":.88,
			"dark_tint":Color(.055,.065,.10),"body_tint":Color(1.0,.97,.88),
			"core_tint":Color(1.0,1.0,.98),"flow_strength":.012,"opacity":.86,"delay":.12,"seed":71.0
		})
	var shards:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if shards!=null:
		shards.play_layer(GUARDIAN_CRYSTAL_SHARDS_TEXTURE,{
			"name":"GuardianShield_Shards","position":_lvl(origin,oh,LEVEL_BODY),
			"size":Vector2(1.22,1.22),"duration":1.02,
			"start_scale":.08,"peak_scale":.54,"end_scale":.90,
			"dark_tint":Color(.055,.065,.10),"body_tint":Color(1.0,.96,.84),
			"core_tint":Color(1.0,1.0,.98),"flow_strength":.022,"opacity":.78,"delay":.30,"seed":79.0
		})
	# The authored guardian layers above are the complete shield/taunt presentation.
	# Do not add the legacy generic barrier or its old gold shield texture here.

func _holy_heal(target:Vector3,context:Dictionary={})->void:
	var th := _uh(context)
	# Star Prayer uses a new ComfyUI-authored white/gold language. Each layer has
	# its own timing so the skill reads as a blessing, not a rotating PNG card.
	var sigil:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if sigil!=null:
		sigil.play_layer(STAR_PRAYER_SIGIL_TEXTURE,{
			"name":"StarPrayer_Sigil",
			"position":_lvl(target,th,LEVEL_FOOT,0.0),"size":Vector2(1.18,1.18),"ground":true,
			"duration":1.16,"start_scale":.10,"peak_scale":.88,"end_scale":1.05,
			"dark_tint":Color(.055,.065,.10),"body_tint":Color(1.0,.97,.86),
			"core_tint":Color(1.0,.98,.88),"flow_strength":.006,"opacity":.86,
			"seed":17.0
		})
	var descent:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if descent!=null:
		descent.play_layer(STAR_PRAYER_DESCENT_TEXTURE,{
			"name":"StarPrayer_Descent",
			"from":_lvl(target,th,LEVEL_SKY),"to":_lvl(target,th,LEVEL_BODY),"track_node":context.get("target_node"),
			"size":Vector2(.78,1.62),"duration":.72,"travel_ratio":.48,
			"start_scale":.12,"peak_scale":.82,"end_scale":1.02,
			"dark_tint":Color(.045,.055,.085),"body_tint":Color(1.0,.96,.84),
			"core_tint":Color(1.0,.98,.86),"flow_strength":.010,"opacity":.92,
			"delay":.10,"seed":23.0
		})
	var fragments:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if fragments!=null:
		fragments.play_layer(STAR_PRAYER_FRAGMENTS_TEXTURE,{
			"name":"StarPrayer_Fragments",
			"position":_lvl(target,th,LEVEL_BODY),"size":Vector2(1.12,1.12),
			"duration":.92,"start_scale":.08,"peak_scale":.58,"end_scale":.92,
			"dark_tint":Color(.055,.065,.10),"body_tint":Color(1.0,.95,.78),
			"core_tint":Color(1.0,.98,.86),"flow_strength":.022,"opacity":.84,
			"delay":.24,"rotation_z":-8.0,"seed":29.0
		})
	var impact:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if impact!=null:
		impact.play_layer(STAR_PRAYER_IMPACT_TEXTURE,{
			"name":"StarPrayer_Impact",
			"position":_lvl(target,th,LEVEL_BODY),"size":Vector2(.92,.92),
			"duration":.54,"start_scale":.08,"peak_scale":.72,"end_scale":.98,
			"dark_tint":Color(.06,.07,.11),"body_tint":Color(1.0,.97,.88),
			"core_tint":Color(1.0,1.0,.92),"flow_strength":.014,"opacity":.96,
			"delay":.39,"seed":37.0
		})
	if bool(context.get("cleanse_triggered",false)):
		var cleanse:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
		if cleanse!=null:
			cleanse.play_layer(STAR_PRAYER_CLEANSE_TEXTURE,{
				"name":"StarPrayer_Cleanse",
				"position":_lvl(target,th,LEVEL_HEAD),"size":Vector2(.74,.74),
				"duration":.78,"start_scale":.10,"peak_scale":.70,"end_scale":1.02,
				"dark_tint":Color(.06,.07,.11),"body_tint":Color(1.0,.96,.84),
				"core_tint":Color(1.0,1.0,.94),"flow_strength":.018,"opacity":.92,
				"delay":.52,"seed":43.0
			})

func _ally_bless(origin:Vector3,target:Vector3,context:Dictionary)->void:
	var th := _uh(context)
	var oh := _uh(context,"origin_height")
	# Priestess Blessing reads as a short source-to-ally connection, then resolves
	# into a target-bound protective seal and a soft restorative burst.
	var seed:=float(abs(int(target.x*31.0+target.z*17.0))%97)
	var ribbon:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if ribbon!=null:
		ribbon.play_layer(PRIESTESS_BLESSING_RIBBON_TEXTURE,{
			"name":"PriestessBlessing_Ribbon",
			"from":_lvl(origin,oh,LEVEL_BODY),"to":_lvl(target,th,LEVEL_BODY),"track_node":context.get("target_node"),
			"size":Vector2(1.24,.62),"duration":.74,"travel_ratio":.68,
			"start_scale":.10,"peak_scale":.78,"end_scale":.92,
			"dark_tint":Color(.055,.065,.10),"body_tint":Color(1.0,.96,.84),
			"core_tint":Color(1.0,1.0,.96),"flow_strength":.022,"opacity":.90,"seed":seed
		})
	var sigil:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if sigil!=null:
		sigil.play_layer(PRIESTESS_BLESSING_SIGIL_TEXTURE,{
			"name":"PriestessBlessing_Sigil","position":_lvl(target,th,LEVEL_FOOT,0.0),
			"size":Vector2(1.02,1.02),"ground":true,"duration":1.02,
			"start_scale":.10,"peak_scale":.72,"end_scale":.94,
			"dark_tint":Color(.055,.065,.10),"body_tint":Color(1.0,.97,.86),
			"core_tint":Color(1.0,1.0,.96),"flow_strength":.008,"opacity":.88,"delay":.22,"seed":seed+1.0
		})
	var burst:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if burst!=null:
		burst.play_layer(PRIESTESS_BLESSING_BURST_TEXTURE,{
			"name":"PriestessBlessing_Burst","position":_lvl(target,th,LEVEL_BODY),
			"size":Vector2(.92,.92),"duration":.58,"start_scale":.08,
			"peak_scale":.66,"end_scale":.98,"dark_tint":Color(.06,.07,.11),
			"body_tint":Color(1.0,.97,.88),"core_tint":Color(1.0,1.0,1.0),
			"flow_strength":.016,"opacity":.94,"delay":.52,"seed":seed+2.0
		})
	var particles:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if particles!=null:
		particles.play_layer(PRIESTESS_BLESSING_PARTICLES_TEXTURE,{
			"name":"PriestessBlessing_Particles","position":_lvl(target,th,LEVEL_SHOULDER),
			"size":Vector2(.84,.84),"duration":1.02,"start_scale":.08,
			"peak_scale":.58,"end_scale":.86,"dark_tint":Color(.055,.065,.10),
			"body_tint":Color(1.0,.96,.84),"core_tint":Color(1.0,1.0,.96),
			"flow_strength":.024,"opacity":.82,"delay":.38,"seed":seed+3.0
		})
	_barrier(target,_holy_profile(.66,1.30),context)

func _holy_group(origin:Vector3,context:Dictionary)->void:
	var th := _uh(context)
	var oh := _uh(context,"origin_height")
	# Group heal is target-readable and one-shot. Do not keep a source-to-target
	# beam alive: several simultaneous beams become a yellow screen-covering link.
	# 圣光整体放大 20%（尺寸 .30→.36），让群体治疗更醒目。
	var p:=_holy_profile(.36,.46);p.main_color=Color(.48,.25,.035);p.core_color=Color(1.0,.72,.22);p.emission_energy=1.25
	_spawn(VFX_LIGHT_PULSE,p,{"target":_lvl(origin,oh,LEVEL_BODY)})
	for value in _capped_targets(context.get("targets",[])):
		var ally:=_holy_profile(.41,.62)
		ally.main_color=Color(.58,.32,.055);ally.core_color=Color(1.0,.78,.28);ally.emission_energy=1.35
		var target_node_value:Variant=context.get("target_node")
		var layer:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
		if layer!=null:
			layer.play_layer("res://assets/vfx/skills/human_cleric/human_cleric_heal_ribbon.png",{
				"position":_lvl_foot(value,th,LEVEL_BODY),"size":Vector2(.86,.86),"duration":.62,
				"start_scale":.16,"peak_scale":.94,"dark_tint":Color(.20,.08,.01),
				"body_tint":ally.main_color,"core_tint":ally.core_color,"seed":float(abs(int(value.x*31.0+value.z*17.0))%97),
				"flow_strength":.018,"opacity":.92,"target_node":target_node_value
			})
		_spawn(VFX_LIGHT_PULSE,ally,{"target":_lvl_foot(value,th,LEVEL_BODY)})

func _holy_group_v2(origin:Vector3,context:Dictionary)->void:
	var oh := _uh(context,"origin_height")
	var wing:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if wing!=null:
		wing.play_layer(ANGEL_CAST_WINGS_TEXTURE,{"position":_lvl(origin,oh,LEVEL_HEAD),"size":Vector2(1.24,.86),"duration":.72,"start_scale":.10,"peak_scale":.92,"end_scale":.68,"dark_tint":Color(.035,.028,.020),"body_tint":Color(1.0,.72,.16),"core_tint":Color(1.0,.99,.84),"flow_strength":.020,"opacity":1.0,"seed":211.0})
	var values:=_capped_targets(context.get("targets",[])).slice(0,4)
	for i in range(values.size()):
		_angel_target_heal_fx(values[i],i)

func _angel_target_heal_fx(value:Vector3,index:int)->void:
	var th := UNIT_HEIGHT_FALLBACK
	var seed:=float((abs(int(value.x*31.0+value.z*17.0))+index*19)%97)
	var mark:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if mark!=null:
		mark.play_layer(ANGEL_HEAL_STROKES_TEXTURE,{"position":_lvl_foot(value,th,LEVEL_BODY),"size":Vector2(1.02,.50),"duration":.62,"start_scale":.10,"peak_scale":.88,"end_scale":.74,"rotation_z":-.10,"dark_tint":Color(.035,.028,.020),"body_tint":Color(.98,.70,.14),"core_tint":Color(1.0,.98,.78),"flow_strength":.016,"opacity":1.0,"seed":seed})
	var pulse:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	var fragments:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	var residue:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	var tw:=create_tween();tw.tween_interval(.10+float(index)*.035);tw.tween_callback(func():
		if is_instance_valid(pulse):
			pulse.play_layer(ANGEL_HEAL_PULSE_TEXTURE,{"position":_lvl_foot(value,th,LEVEL_BODY),"size":Vector2(.68,.76),"duration":.42,"start_scale":.12,"peak_scale":.80,"end_scale":.96,"dark_tint":Color(.035,.028,.020),"body_tint":Color(1.0,.76,.16),"core_tint":Color(1.0,.99,.86),"flow_strength":.018,"opacity":1.0,"seed":seed+3.0})
	)
	var tw2:=create_tween();tw2.tween_interval(.22+float(index)*.035);tw2.tween_callback(func():
		if is_instance_valid(fragments):
			fragments.play_layer(ANGEL_BUFF_FRAGMENTS_TEXTURE,{"position":_lvl_foot(value,th,LEVEL_BODY),"size":Vector2(.68,.68),"duration":.66,"start_scale":.12,"peak_scale":.74,"end_scale":.86,"dark_tint":Color(.035,.028,.020),"body_tint":Color(.98,.72,.16),"core_tint":Color(1.0,.99,.82),"flow_strength":.020,"opacity":.98,"seed":seed+7.0})
	)
	var tw3:=create_tween();tw3.tween_interval(.34+float(index)*.035);tw3.tween_callback(func():
		if is_instance_valid(residue):
			residue.play_layer(ANGEL_BUFF_RESIDUE_TEXTURE,{"position":_lvl_foot(value,th,LEVEL_HEAD),"size":Vector2(.50,.84),"duration":1.02,"start_scale":.10,"peak_scale":.66,"end_scale":.82,"dark_tint":Color(.035,.028,.020),"body_tint":Color(.94,.68,.14),"core_tint":Color(1.0,.96,.72),"flow_strength":.014,"opacity":.96,"seed":seed+11.0})
	)

func _attribute_bolt(origin:Vector3,target:Vector3,context:Dictionary)->void:
	var th := _uh(context)
	var oh := _uh(context,"origin_height")
	# Attribute bolts use the authored mage orb silhouette, then tint by element.
	var element := str(context.get("attribute", context.get("element", "arcane"))).to_lower()
	var dark := Color(.025,.035,.10)
	var body := Color(.18,.42,.92)
	var core := Color(.72,.94,1.0)
	match element:
		"fire":
			dark=Color(.12,.018,.004);body=Color(.86,.16,.018);core=Color(1.0,.78,.26)
		"ice", "frost":
			dark=Color(.015,.07,.14);body=Color(.08,.52,.92);core=Color(.72,1.0,1.0)
		"shadow", "dark":
			dark=Color(.05,.008,.10);body=Color(.42,.10,.72);core=Color(.92,.66,1.0)
	var bolt:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if bolt!=null:
		bolt.play_layer("res://assets/vfx/skills/human_mage/human_mage_element_orb.png",{"from":_lvl(origin,oh,LEVEL_BODY),"to":_lvl(target,th,LEVEL_BODY),"track_node":context.get("target_node"),"size":Vector2(.64,.28),"duration":.72,"travel_ratio":.70,"dark_tint":dark,"body_tint":body,"core_tint":core,"seed":float(element.hash()%97),"flow_strength":.026,"opacity":1.0})
	var impact:=_block(VFX_IMPACT_FLASH) as VFXImpactFlash3D
	var hit_profile:=_profile(dark,body,core,.48,.42,3.2,7)
	var tw:=create_tween();tw.tween_interval(.62);tw.tween_callback(func():
		if is_instance_valid(impact):impact.play_profile(hit_profile,{"target":_lvl(target,th,LEVEL_BODY)})
	)

func _stun_hit(origin:Vector3,target:Vector3,context:Dictionary)->void:
	var th := _uh(context)
	# Succubus stun: a hooked slash, the hook tip gathering above the head, then
	# an incomplete thorn knot left there.  This used to be an orange EnergyBurst
	# plus a white flash - a fire palette the dark race should never wear.
	var flip:=(target-origin).x<0.0
	var seed:=float(abs(int(target.x*37.0+target.z*19.0))%97)
	var target_node_value:Variant=context.get("target_node")
	var slash:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if slash!=null:
		slash.play_layer(SUC_HOOK_SLASH_TEXTURE,{
			"name":"SucStun_Hook","position":_lvl(target,th,LEVEL_BODY),
			"size":Vector2(1.52,1.14),"duration":.40,
			"start_scale":.14,"peak_scale":.94,"end_scale":1.06,
			"rotation_z":PI if flip else 0.0,
			"dark_tint":DARK_EDGE,"body_tint":DARK_BODY,"core_tint":DARK_CORE,
			"flow_strength":.022,"opacity":.96,"seed":seed
		})
	var impact:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if impact!=null:
		impact.play_layer(SUC_HOOK_IMPACT_TEXTURE,{
			"name":"SucStun_Impact","position":_lvl(target,th,LEVEL_BODY),
			"size":Vector2(1.16,.82),"duration":.38,
			"start_scale":.10,"peak_scale":.78,"end_scale":.92,
			"rotation_z":-.42,
			"dark_tint":DARK_EDGE,"body_tint":DARK_BODY,"core_tint":DARK_CORE,
			"flow_strength":.020,"opacity":.94,"delay":.16,"seed":seed+3.0
		})
	var knot:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if knot!=null:
		# The head-top stun icon still belongs to StatusVFXController; this only
		# adds a thorn knot that follows the target.
		knot.play_layer(SUC_BIND_KNOT_TEXTURE,{
			"name":"SucStun_Knot","position":_lvl(target,th,LEVEL_HEAD),
			"size":Vector2(.62,.63),
			"duration":clampf(float(context.get("status_duration",1.0)),.80,2.0),
			# Peak capped at .68: any larger covers the head and the HP bar (4.3).
			"start_scale":.16,"peak_scale":.68,"end_scale":.86,
			"dark_tint":DARK_INK_EDGE,"body_tint":Color(1.0,.76,.90),"core_tint":Color(1.0,.70,.92),
			"flow_strength":.018,"opacity":.96,"delay":.30,"seed":seed+7.0,
			"follow_node":target_node_value
		})

func _judgement(origin:Vector3,target:Vector3)->void:
	var th := UNIT_HEIGHT_FALLBACK
	var oh := UNIT_HEIGHT_FALLBACK
	# Arbiter: one new ground brush anchors the action, then the new slash and impact overlap it.
	var mark:=_block(VFX_ARBITER_GROUND) as VFXArbiterGroundBrush3D
	if mark!=null:
		mark.play_brush(target)
	var slash:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if slash!=null:
		var tw:=create_tween();tw.tween_interval(.10);tw.tween_callback(func():
			if is_instance_valid(slash):slash.play_layer(ARBITER_VERDICT_SLASH_TEXTURE,{"position":_lvl(target,th,LEVEL_BODY),"size":Vector2(1.42,1.02),"duration":.42,"start_scale":.10,"peak_scale":1.0,"dark_tint":Color(.045,.022,.006),"body_tint":Color(.64,.38,.08),"core_tint":Color(1.0,.98,.86),"seed":89.0,"flow_strength":.012,"opacity":1.0})
		)
	var impact:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if impact!=null:
		var hit_tw:=create_tween();hit_tw.tween_interval(.24);hit_tw.tween_callback(func():
			if is_instance_valid(impact):impact.play_layer(ARBITER_VERDICT_IMPACT_TEXTURE,{"position":_lvl(target,th,LEVEL_BODY),"size":Vector2(1.08,1.02),"duration":.56,"start_scale":.08,"peak_scale":.92,"dark_tint":Color(.045,.022,.006),"body_tint":Color(.62,.34,.06),"core_tint":Color(1.0,.98,.86),"seed":97.0,"flow_strength":.012,"opacity":1.0})
		)
	var guard_fx:=_block(VFX_ARBITER_GUARD)
	if guard_fx!=null:
		var guard_tw:=create_tween();guard_tw.tween_interval(.18);guard_tw.tween_callback(func():
			if is_instance_valid(guard_fx):guard_fx.call("play_guard",_lvl(origin,oh,LEVEL_BODY))
		)

func _global_divine(target:Vector3,context:Dictionary)->void:
	var targets:Array=_capped_targets(context.get("targets",[]))
	if targets.is_empty():targets=[target]
	for i in range(targets.size()):
		if i>0: await get_tree().create_timer(.075).timeout
		var value:Variant=targets[i]
		var p:=_holy_profile(.78,1.0);p.main_color=Color(.24,.42,.96);p.core_color=Color(.84,.96,1.0);p.emission_energy=4.4
		_spawn(VFX_FALLING_PILLAR,p,{"target":value})

# ── Dark race ─────────────────────────────────────────────────────────
# Note: play_layer's three tints MULTIPLY into the plate, they do not replace
# its colour.  The authored art already carries the dark-race structure
# (black-violet edge, magenta body, cold pink-white core), so body has to stay
# near 1.0 to let that art through.  Filling these with the faction colour
# multiplies an already dark plate a second time and it disappears entirely at
# the battle camera - that is exactly how the first pass failed.
const DARK_EDGE:=Color(.14,.06,.16)     # torn low-alpha edge, darkened but not crushed to black
const DARK_BODY:=Color(1.0,.90,.98)     # body keeps the plate's own colour, barely cooled
const DARK_CORE:=Color(1.0,.86,.96)     # the small hot core: cold pink-white
# Ink and status layers are texture, not action: darker and more matte than the
# action layers, but still darkening the plate rather than recolouring it.
const DARK_INK_EDGE:=Color(.10,.04,.11)
const DARK_INK_BODY:=Color(.62,.38,.54)
const DARK_INK_CORE:=Color(.88,.44,.72)

func _imp_curse(origin:Vector3,target:Vector3,context:Dictionary)->void:
	var th := _uh(context)
	# Imp's curse claw: a hooked claw mark lands on the target, then a low ink
	# stain settles at its feet.
	#
	# About the "two stacks": the design bible wants the second stack to deepen
	# the stain and add a wine-red cracked edge, but the sim only refreshes
	# attack_down/slow - there is no real stack count reaching the visuals.  So
	# the deep tier only runs when the context states stacks explicitly; other-
	# wise every hit presses a fresh layer of ink, and the change in thickness
	# and pulse comes from repetition rather than a second icon.
	var deep:=int(context.get("stacks",1))>=2
	var flip:=(target-origin).x<0.0
	var target_node_value:Variant=context.get("target_node")
	var seed:=float(abs(int(target.x*31.0+target.z*17.0))%97)
	var hook:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if hook!=null:
		hook.play_layer(IMP_CLAW_HOOK_TEXTURE,{
			"name":"ImpCurse_Claw","position":_lvl(target,th,LEVEL_BODY),
			"size":Vector2(1.72,1.30),"duration":.52,
			"start_scale":.14,"peak_scale":.92,"end_scale":1.06,
			"rotation_z":PI if flip else 0.0,
			"dark_tint":DARK_EDGE,"body_tint":DARK_BODY,"core_tint":DARK_CORE,
			"flow_strength":.022,"opacity":.96,"seed":seed
		})
	var ink:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if ink!=null:
		ink.play_layer(IMP_CURSE_INK_TEXTURE,{
			"name":"ImpCurse_Ink","position":_lvl(target,th,LEVEL_FOOT,0.0),"ground":true,
			"size":Vector2(1.16,1.16) if deep else Vector2(.96,.96),
			"duration":2.1 if deep else 1.7,
			"start_scale":.10,"peak_scale":.86 if deep else .70,"end_scale":.98,
			"dark_tint":DARK_INK_EDGE,
			# The second stack is not another icon: same ink, thicker, more wine-red, stronger pulse.
			"body_tint":Color(.86,.42,.56) if deep else DARK_INK_BODY,
			"core_tint":Color(1.0,.40,.58) if deep else DARK_INK_CORE,
			"flow_strength":.022 if deep else .014,"opacity":.92 if deep else .78,
			"delay":.16,"seed":seed+5.0,"follow_node":target_node_value
		})

func _silence_bolt(origin:Vector3,target:Vector3,context:Dictionary)->void:
	var th := _uh(context)
	var oh := _uh(context,"origin_height")
	# Shadow Mage's silence spike: an ink mass contracts into a spike, the spike
	# flies, an angular band folds shut at the target's head, and a gathered ink
	# wrap stays on its shoulder for the silence duration.
	var seed:=float(abs(int(target.x*29.0+target.z*13.0))%97)
	var target_node_value:Variant=context.get("target_node")
	var gather:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if gather!=null:
		# start > peak > end so the whole curve contracts - that is what reads as
		# "gathering into a spike" rather than another expanding puff.
		gather.play_layer(MAGE_INK_GATHER_TEXTURE,{
			"name":"Silence_Gather","position":_lvl(origin,oh,LEVEL_BODY),
			"size":Vector2(.88,1.20),"duration":.34,
			"start_scale":.76,"peak_scale":.46,"end_scale":.26,
			"dark_tint":DARK_EDGE,"body_tint":DARK_BODY,"core_tint":DARK_CORE,
			"flow_strength":.028,"opacity":.92,"seed":seed
		})
	var spike:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if spike!=null:
		spike.play_layer(MAGE_INK_SPIKE_TEXTURE,{
			"name":"Silence_Spike","from":_lvl(origin,oh,LEVEL_BODY),"to":_lvl(target,th,LEVEL_BODY),"track_node":target_node_value,
			"size":Vector2(1.16,.34),"duration":.74,"travel_ratio":.70,
			"start_scale":.30,"peak_scale":1.0,"end_scale":.86,
			"dark_tint":DARK_EDGE,"body_tint":DARK_BODY,"core_tint":DARK_CORE,
			"flow_strength":.020,"opacity":1.0,"delay":.14,"seed":seed+3.0
		})
	var seal:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if seal!=null:
		seal.play_layer(MAGE_SILENCE_SEAL_TEXTURE,{
			"name":"Silence_Seal","position":_lvl(target,th,LEVEL_HEAD),
			"size":Vector2(.54,.66),"duration":.46,
			"start_scale":.10,"peak_scale":.80,"end_scale":.94,
			"dark_tint":DARK_EDGE,"body_tint":DARK_BODY,"core_tint":DARK_CORE,
			"flow_strength":.024,"opacity":.96,"delay":.70,"seed":seed+7.0
		})
	var wrap:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if wrap!=null:
		# The status layer follows the target.  The head-top silence icon still
		# belongs to StatusVFXController; this layer only adds texture.
		wrap.play_layer(MAGE_SILENCE_WRAP_TEXTURE,{
			"name":"Silence_Wrap","position":_lvl(target,th,LEVEL_SHOULDER),
			"size":Vector2(.50,.64),
			"duration":clampf(float(context.get("status_duration",1.9)),1.2,3.2),
			"start_scale":.12,"peak_scale":.60,"end_scale":.72,
			"dark_tint":DARK_INK_EDGE,"body_tint":Color(.82,.56,.74),"core_tint":Color(.94,.56,.82),
			"flow_strength":.016,"opacity":.72,"delay":.84,"seed":seed+11.0,
			"follow_node":target_node_value
		})

func _poison_attack(origin:Vector3,target:Vector3,context:Dictionary)->void:
	var th := _uh(context)
	var oh := _uh(context,"origin_height")
	# Poison is deliberately a narrow authored dart, not another generic orb projectile.
	var dart:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	var dart_profile:=_profile(Color(.025,.07,.012),Color(.26,.72,.08),Color(.78,1.0,.24),.52,.86,3.8,8)
	var source_id:=str(context.get("source_unit_id",""))
	var dart_texture:="res://assets/vfx/skills/undead_spike/undead_spike_bone_dart.png"
	var dart_size:=Vector2(.72,.24)
	if source_id.contains("undead_fly"):
		dart_texture="res://assets/vfx/skills/distinct_v2/undead_fly_poison_feather_v2.png"
		dart_size=Vector2(.86,.42)
	if dart!=null:
		dart.play_layer(dart_texture,{"from":_lvl(origin,oh,LEVEL_BODY),"to":_lvl(target,th,LEVEL_BODY),"track_node":context.get("target_node"),"size":dart_size,"duration":.78,"travel_ratio":.68,"dark_tint":dart_profile.dark_color,"body_tint":dart_profile.main_color,"core_tint":dart_profile.core_color,"seed":4.6,"flow_strength":.022})
	var impact:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	var tw:=create_tween();tw.tween_interval(.54);tw.tween_callback(func():
		if is_instance_valid(impact):
			impact.play_layer("res://assets/vfx/skills/undead_poison/undead_poison_spore_orb.png",{"position":_lvl(target,th,LEVEL_BODY),"size":Vector2(.82,.82),"duration":.72,"start_scale":.10,"peak_scale":.78,"dark_tint":Color(.03,.10,.012),"body_tint":Color(.28,.74,.06),"core_tint":Color(.82,1.0,.24),"seed":8.3})
		_status_hit(target,"poison",context)
	)

func _fear_hit(origin:Vector3,target:Vector3,context:Dictionary)->void:
	var th := _uh(context)
	var oh := _uh(context,"origin_height")
	# Fear Demon: a low bank of black haze is pushed toward the target, then one
	# wide short tear, then strokes fleeing outward behind the target.
	# The old version shared distinct_v2/fear_mask_impact_v2.png with the Imp,
	# which is the "recolour and call it a different skill" the bible forbids.
	var direction:=target-origin
	var flee_dir:=Vector3(direction.x,0.0,direction.z)
	flee_dir=flee_dir.normalized() if flee_dir.length_squared()>.0001 else Vector3.FORWARD
	var flip:=direction.x<0.0
	var seed:=float(abs(int(target.x*23.0+target.z*29.0))%97)
	var target_node_value:Variant=context.get("target_node")
	var smoke:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if smoke!=null:
		# Ground travel: from the caster's feet to the target's, so it reads as
		# haze being pushed across rather than smoke rising in place.
		smoke.play_layer(FEAR_LOW_SMOKE_TEXTURE,{
			"name":"Fear_LowSmoke","ground":true,
			"from":_lvl(origin,oh,LEVEL_FOOT,0.0),"to":_lvl(target,th,LEVEL_FOOT,0.0),
			"size":Vector2(1.72,1.30),"duration":.72,"travel_ratio":.56,
			"start_scale":.16,"peak_scale":.92,"end_scale":1.08,
			"dark_tint":DARK_INK_EDGE,"body_tint":Color(.74,.48,.68),"core_tint":Color(.90,.48,.74),
			"flow_strength":.024,"opacity":.92,"seed":seed
		})
	var tear:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if tear!=null:
		tear.play_layer(FEAR_CLAW_TEAR_TEXTURE,{
			"name":"Fear_ClawTear","position":_lvl(target,th,LEVEL_BODY),
			"size":Vector2(1.64,.92),"duration":.42,
			"start_scale":.16,"peak_scale":.96,"end_scale":1.10,
			"rotation_z":PI if flip else 0.0,
			"dark_tint":DARK_EDGE,"body_tint":DARK_BODY,"core_tint":DARK_CORE,
			"flow_strength":.022,"opacity":.96,"delay":.18,"seed":seed+5.0
		})
	var flee:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if flee!=null:
		# The fleeing strokes sit on the far side of the target (away from the
		# caster) and travel with it.
		flee.play_layer(FEAR_FLEE_STROKES_TEXTURE,{
			"name":"Fear_Flee","position":_lvl(target,th,LEVEL_BODY)+flee_dir*th*.30,
			"size":Vector2(1.42,1.06),
			"duration":clampf(float(context.get("status_duration",1.5)),1.0,2.4),
			"start_scale":.12,"peak_scale":.72,"end_scale":.88,
			"rotation_z":PI if flip else 0.0,
			"dark_tint":DARK_INK_EDGE,"body_tint":Color(.92,.66,.86),"core_tint":Color(1.0,.62,.88),
			"flow_strength":.026,"opacity":.94,"delay":.34,"seed":seed+11.0,
			"follow_node":target_node_value
		})

func _doom_blood_link(origin:Vector3,target:Vector3,context:Dictionary)->void:
	# Doom Guard's blood pact: a painted rope body with a knot at each end that
	# tears apart in the middle when it breaks.  The generic TrackedLink is a
	# glowing ribbon - no weight, no endpoint knots.
	var p:=_profile(Color(.16,.06,.14),Color(1.0,.88,.94),Color(1.0,.72,.84),1.0,2.4,1.6,6)
	_spawn(VFX_DOOM_LINK,p,{
		"origin":origin,"target":target,
		"origin_node":context.get("origin_node"),"target_node":context.get("target_node"),
		"persistent":bool(context.get("persistent",false))
	})

func _black_hole(origin:Vector3,context:Dictionary={})->void:
	var th := _uh(context)
	var oh := _uh(context,"origin_height")
	# Black Dragon's black hole: ground strokes bending inward, then an irregular
	# dark mass, then shards dragged toward the centre, then a stretched smear at
	# each pulled target's feet.  The old version was one generic purple vortex,
	# exactly the "regular ring" the bible bans in 3.3.  The mass is deliberately
	# not a sphere; torn edges and an off-centre weight keep it hand-painted.
	var seed:=float(abs(int(origin.x*47.0+origin.z*29.0))%97)
	var curl:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if curl!=null:
		curl.play_layer(DRAGON_GROUND_CURL_TEXTURE,{
			"name":"BlackHole_GroundCurl","position":_lvl(origin,oh,LEVEL_FOOT,0.0),"ground":true,
			# A T3 signature AoE that drags a whole lane inward needs to read as an
			# area, not a puff on the caster: about two tiles across.
			"size":Vector2(4.30,4.30),"duration":1.34,
			"start_scale":.12,"peak_scale":.92,"end_scale":1.06,
			"dark_tint":DARK_INK_EDGE,"body_tint":Color(.78,.50,.72),"core_tint":Color(.92,.52,.80),
			"flow_strength":.020,"opacity":.90,"seed":seed
		})
	var mass:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if mass!=null:
		mass.play_layer(DRAGON_DARK_MASS_TEXTURE,{
			# Keep the mass low and wide so the dragon casting it stays visible; a
			# billboard centred on its chest just hides the unit (bible 4.3).
			"name":"BlackHole_Mass","position":_lvl(origin,oh,LEVEL_LOW,0.4),
			"size":Vector2(2.40,1.70),"duration":1.10,
			"start_scale":.10,"peak_scale":.88,"end_scale":.72,
			"dark_tint":DARK_EDGE,"body_tint":DARK_BODY,"core_tint":DARK_CORE,
			"flow_strength":.026,"opacity":.94,"delay":.22,"seed":seed+5.0
		})
	var shards:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if shards!=null:
		# Shards start large and shrink: sucked in, not blown out.
		shards.play_layer(DRAGON_PULL_SHARDS_TEXTURE,{
			"name":"BlackHole_Shards","position":_lvl(origin,oh,LEVEL_LOW,0.6),
			"size":Vector2(2.30,1.90),"duration":.86,
			"start_scale":1.02,"peak_scale":.60,"end_scale":.24,
			"dark_tint":DARK_EDGE,"body_tint":DARK_BODY,"core_tint":DARK_CORE,
			"flow_strength":.030,"opacity":.92,"delay":.34,"seed":seed+9.0
		})
	# Each pulled target gets a smear stretched toward the centre; the dragon
	# itself carries none.
	for value in _capped_targets(context.get("targets",[])):
		var drag:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
		if drag==null:continue
		var pulled:Vector3=value
		var to_center:=origin-pulled
		var facing:=atan2(to_center.z,to_center.x) if to_center.length_squared()>.0001 else 0.0
		drag.play_layer(DRAGON_TARGET_DRAG_TEXTURE,{
			"name":"BlackHole_Drag","position":_lvl_foot(pulled,th,LEVEL_FOOT,0.0),"ground":true,
			"size":Vector2(1.70,1.20),"duration":.92,
			"start_scale":.14,"peak_scale":.82,"end_scale":.96,
			"rotation_z":facing,
			"dark_tint":DARK_INK_EDGE,"body_tint":Color(.72,.44,.66),"core_tint":Color(.88,.46,.74),
			"flow_strength":.024,"opacity":.84,"delay":.30,
			"seed":float(abs(int(pulled.x*53.0+pulled.z*37.0))%97)
		})

func _blink_slash(origin:Vector3,target:Vector3,context:Dictionary={})->void:
	var th := _uh(context)
	var oh := _uh(context,"origin_height")
	# Ambusher: an ink rip opens where it stood, then the blink afterimage, then
	# one long and one short crossing cut behind the target.  The old version was
	# a single cyan afterimage - wrong faction colour, and no double strike.
	var seed:=float(abs(int(target.x*41.0+target.z*23.0))%97)
	var tear:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if tear!=null:
		tear.play_layer(SCYTHE_INK_TEAR_TEXTURE,{
			"name":"Blink_InkTear","position":_lvl(origin,oh,LEVEL_BODY),
			"size":Vector2(.62,1.24),"duration":.40,
			"start_scale":.10,"peak_scale":.88,"end_scale":1.04,
			"dark_tint":DARK_EDGE,"body_tint":DARK_BODY,"core_tint":DARK_CORE,
			"flow_strength":.024,"opacity":.94,"seed":seed
		})
	# The blink itself: dark violet afterimage, no longer cyan.
	var dash:=_shadow_profile(.74,.72);dash.dark_color=Color(.035,.010,.050)
	dash.main_color=Color(.46,.08,.34);dash.core_color=Color(1.0,.66,.88)
	_spawn(VFX_AFTERIMAGE,dash,{"origin":origin,"target":target})
	var cross:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if cross!=null:
		cross.play_layer(SCYTHE_CROSS_SLASH_TEXTURE,{
			"name":"Blink_CrossSlash","position":_lvl(target,th,LEVEL_BODY),
			"size":Vector2(1.52,1.52),"duration":.60,
			"start_scale":.12,"peak_scale":.94,"end_scale":1.08,
			"dark_tint":DARK_EDGE,"body_tint":DARK_BODY,"core_tint":DARK_CORE,
			"flow_strength":.020,"opacity":.96,"delay":.20,"seed":seed+5.0
		})
	# The recoiling afterimage only appears on a kill refresh.  The sim never
	# tells the visuals that this cast was a refresh, so in battle this branch is
	# currently dead; the hook stays until BattleVfx passes a refreshed flag.
	if bool(context.get("refreshed",false)):
		var recall:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
		if recall!=null:
			recall.play_layer(SCYTHE_RECALL_TEXTURE,{
				"name":"Blink_Recall","position":_lvl(target,th,LEVEL_BODY),
				"size":Vector2(1.24,.94),"duration":.52,
				"start_scale":.88,"peak_scale":.52,"end_scale":.28,
				"dark_tint":DARK_INK_EDGE,"body_tint":Color(.80,.52,.74),"core_tint":Color(.94,.56,.84),
				"flow_strength":.026,"opacity":.82,"delay":.46,"seed":seed+9.0
			})

func _front_stun(origin:Vector3,target:Vector3,context:Dictionary)->void:
	# The authored swordsman slash masks are owned by BattleVfx and placed on
	# the confirmed hit target. Do not add the old orange cone underneath them.
	_status_hit(target,"stun",context)

func _barrier(target:Vector3,profile:VFXProfile3D,context:Dictionary={})->void:
	var th := _uh(context)
	var source_id:=str(context.get("source_unit_id",""))
	# god_archangel 的减伤护盾原本走退化分支，在战斗取景下只有 ~30px，几乎看不见。
	# 50 费传奇单位理应走全尺寸护盾。
	var full_barrier:=bool(context.get("legendary",false)) or bool(context.get("boss",false)) or source_id.contains("god_guard") or source_id.contains("merc_cancer_shell") or source_id.contains("god_archangel")
	var barrier_profile:VFXProfile3D=profile
	if not full_barrier:
		barrier_profile=profile.duplicate() as VFXProfile3D
		barrier_profile.size*=.52
		barrier_profile.duration=minf(profile.duration,.76)
		barrier_profile.particle_count=4
		barrier_profile.emission_energy=minf(profile.emission_energy,2.2)
		barrier_profile.parameters["edge_only"]=true
	_spawn(VFX_BARRIER,barrier_profile,{"target":target})
	var texture_path:=""
	var tint:=barrier_profile.main_color
	var core:=barrier_profile.core_color
	if source_id.contains("merc_cancer_shell"):
		texture_path="res://assets/vfx/skills/distinct_v2/shell_cyan_carapace_v2.png"
		tint=Color(.05,.48,.62);core=Color(.55,1.0,1.0)
	if not texture_path.is_empty():
		var layer:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
		if layer!=null:
			layer.play_layer(texture_path,{"position":_lvl(target,th,LEVEL_BODY),"size":Vector2(.94,.94),"duration":1.42,"start_scale":.22,"peak_scale":.92,"dark_tint":tint.darkened(.78),"body_tint":tint,"core_tint":core,"seed":41.0,"flow_strength":.018,"opacity":.98})

func _tracked_link(origin:Vector3,target:Vector3,context:Dictionary,profile:VFXProfile3D)->void:
	_spawn(VFX_TRACKED_LINK,profile,{"origin":origin,"target":target,"origin_node":context.get("origin_node"),"target_node":context.get("target_node"),"persistent":bool(context.get("persistent",false))})

func _status_hit(target:Vector3,status_type:String,context:Dictionary)->void:
	# Status icons must have a live target. Never fall back to a world position:
	# that creates detached circles in empty lanes when a victim is already gone.
	var target_node_value:Variant=context.get("target_node")
	if not (is_instance_valid(target_node_value) and target_node_value is Node3D):
		return
	var live_target:Node3D=target_node_value
	var p:=_shadow_profile(.62,1.18);p.parameters={"status_type":status_type};p.particle_count=7
	if context.has("status_duration"):
		p.duration=maxf(.30,float(context.get("status_duration",p.duration)))
	var status_slots:Dictionary={"stun":0,"silence":1,"poison":2,"fear":3,"defense_down":4,"slow":5}
	p.parameters["status_slot"]=int(status_slots.get(status_type,0))
	_spawn(VFX_STATUS,p,{"target":target,"target_node":live_target})

func _curse_hit(target:Vector3,context:Dictionary)->void:
	var th := _uh(context)
	var p:=_profile(Color(.04,.008,.08),Color(.28,.06,.58),Color(.86,.42,1.0),.72,.76,3.8,8)
	_spawn(VFX_ENERGY_BURST,p,{"target":_lvl(target,th,LEVEL_BODY),"direction":Vector3.UP})
	_status_hit(target,"fear",context)
	var mark:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if mark!=null:
		mark.play_layer("res://assets/vfx/skills/distinct_v2/fear_mask_impact_v2.png",{"position":_lvl(target,th,LEVEL_HEAD),"size":Vector2(.52,.52),"duration":.82,"start_scale":.12,"peak_scale":.78,"dark_tint":Color(.035,.004,.07),"body_tint":Color(.28,.06,.58),"core_tint":Color(.86,.42,1.0),"seed":37.0,"flow_strength":.022,"opacity":.96})

# 刺灵的减防攻击。原本只挂一个头顶减防图标，看不出"这一下打中了"。
# 补一次暗绿命中爆发，把"被打了"和"中了减防"分开表达（图标仍由 _status_hit 负责）。
func _defense_down_hit(target:Vector3,context:Dictionary)->void:
	var th := _uh(context)
	var p:=_profile(Color(.02,.06,.03),Color(.16,.52,.20),Color(.66,1.0,.60),.58,.52,3.4,7)
	_spawn(VFX_ENERGY_BURST,p,{"target":_lvl(target,th,LEVEL_BODY),"direction":Vector3.UP})
	_spawn(VFX_IMPACT_FLASH,p,{"target":_lvl(target,th,LEVEL_BODY)})
	_status_hit(target,"defense_down",context)

func _true_damage_hit(target:Vector3)->void:
	var th := UNIT_HEIGHT_FALLBACK
	# Aurora Archer's proc is target-bound: a painted piercing mark lands first,
	# then a compact aurora fracture confirms the true-damage hit.
	var pierce:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if pierce!=null:
		pierce.play_layer(AURORA_TRUE_PIERCE_TEXTURE,{
			"position":_lvl(target,th,LEVEL_BODY),"size":Vector2(1.92,1.20),"duration":.48,
			"start_scale":.10,"peak_scale":.86,"end_scale":.94,
			"rotation_z":-0.34,"dark_tint":Color(.025,.035,.14),
			"body_tint":Color(.12,.56,.94),"core_tint":Color(.86,.98,1.0),
			"flow_strength":.020,"opacity":.96,"seed":152.0
		})
	var hit:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	var tw:=create_tween();tw.tween_interval(.16);tw.tween_callback(func():
		if is_instance_valid(hit):
			hit.play_layer(AURORA_TRUE_HIT_TEXTURE,{
				"position":_lvl(target,th,LEVEL_BODY),"size":Vector2(1.36,1.36),"duration":.42,
				"start_scale":.10,"peak_scale":.68,"end_scale":.98,
				"dark_tint":Color(.025,.035,.14),"body_tint":Color(.10,.62,.94),
				"core_tint":Color(.90,.99,1.0),"flow_strength":.018,"opacity":.94,"seed":156.0
			})
	)

func _stack_pulse(origin:Vector3,target:Vector3,context:Dictionary)->void:
	var th := _uh(context)
	var oh := _uh(context,"origin_height")
	# Pain Queen: an elastic barbed lash strikes the same target, and the fissure
	# deepens with the real stack count (skill_stacks, handed over by BattleVfx).
	# The fourth stack adds a wine-red rupture.  Three tiers, never a pile of icons.
	var stacks:=clampi(int(context.get("stacks",1)),1,4)
	var depth:=float(stacks-1)/3.0
	var seed:=float(abs(int(target.x*43.0+target.z*31.0))%97)
	var target_node_value:Variant=context.get("target_node")
	var whip:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if whip!=null:
		whip.play_layer(QUEEN_PAIN_WHIP_TEXTURE,{
			"name":"Pain_Whip","from":_lvl_foot(origin,oh,LEVEL_BODY),"to":_lvl(target,th,LEVEL_BODY),"track_node":target_node_value,
			"size":Vector2(1.30,.42),"duration":.52,"travel_ratio":.62,
			"start_scale":.28,"peak_scale":1.0,"end_scale":.88,
			"dark_tint":DARK_EDGE,"body_tint":DARK_BODY,"core_tint":DARK_CORE,
			"flow_strength":.024,"opacity":.96,"seed":seed
		})
	var crack:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if crack!=null:
		crack.play_layer(QUEEN_PAIN_CRACK_TEXTURE,{
			"name":"Pain_Crack","position":_lvl(target,th,LEVEL_BODY),
			"size":Vector2(.62+.22*depth,.86+.30*depth),
			"duration":1.10+.50*depth,
			"start_scale":.12,"peak_scale":.66+.22*depth,"end_scale":.86,
			"dark_tint":DARK_INK_EDGE,
			"body_tint":Color(.70,.42,.58).lerp(Color(1.0,.72,.80),depth),
			"core_tint":Color(.86,.44,.68).lerp(Color(1.0,.58,.72),depth),
			"flow_strength":.014+.010*depth,"opacity":.74+.20*depth,
			"delay":.34,"seed":seed+5.0,"follow_node":target_node_value
		})
	if stacks>=4:
		var brk:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
		if brk!=null:
			brk.play_layer(QUEEN_PAIN_BREAK_TEXTURE,{
				"name":"Pain_Break","position":_lvl(target,th,LEVEL_BODY),
				"size":Vector2(1.16,1.10),"duration":.44,
				"start_scale":.10,"peak_scale":.90,"end_scale":1.06,
				"dark_tint":DARK_EDGE,"body_tint":DARK_BODY,"core_tint":DARK_CORE,
				"flow_strength":.024,"opacity":1.0,"delay":.44,"seed":seed+9.0
			})

func _poison_reflect_stack(origin:Vector3)->void:
	var oh := UNIT_HEIGHT_FALLBACK
	# 紧凑的毒性外壳爆发：向上的碎片 + 破碎轮廓，不要通用大圆环。
	#
	# 原本用的是 binbun 的 "loot" —— 但那个场景本体是**掉落物的垂直光柱**，
	# 放进战斗就变成一根贯穿画面的巨大绿光柱，读起来完全不像"叠了一层毒甲"。
	# 换成自制的 EnergyBurst：同样是向上的碎片形态，但紧凑、球状、有轮廓。
	# 顺带省掉 loot 场景的 11 节点 / 25 子资源 / 6 个 ShaderMaterial / 97 粒子 / 1 盏灯。
	var p:=_profile(Color(.015,.045,.008),Color(.20,.68,.06),Color(.76,1.0,.20),.44,.62,3.4,7)
	_spawn(VFX_ENERGY_BURST,p,{"target":_lvl(origin,oh,LEVEL_BODY),"direction":Vector3.UP})
	_spawn(VFX_LIGHT_PULSE,p,{"target":_lvl(origin,oh,LEVEL_BODY)})

func _combo_hit(origin:Vector3,target:Vector3,context:Dictionary)->void:
	var th := _uh(context)
	var oh := _uh(context,"origin_height")
	# The archer's fourth-hit skill is a straight, narrow authored arrow.
	# Keep the projectile and its pierce flash target-bound; do not reuse the
	# large generic slash sheet which obscures nearby units at the battle zoom.
	var arrow:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if arrow!=null:
		arrow.play_layer("res://assets/vfx/skills/human_archer/human_archer_arrow_trail.png",{"from":_lvl(origin,oh,LEVEL_BODY),"to":_lvl(target,th,LEVEL_BODY),"track_node":context.get("target_node"),"size":Vector2(1.42,.30),"duration":.56,"travel_ratio":.82,"start_scale":.24,"peak_scale":1.0,"dark_tint":Color(.015,.035,.10),"body_tint":Color(.16,.48,.92),"core_tint":Color(.82,.98,1.0),"seed":52.0,"flow_strength":.018,"opacity":.98})
	var impact:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	var hit_tw:=create_tween();hit_tw.tween_interval(.42);hit_tw.tween_callback(func():
		if is_instance_valid(impact):
			impact.play_layer("res://assets/vfx/skills/human_archer/human_archer_pierce_flash.png",{"position":_lvl(target,th,LEVEL_BODY),"size":Vector2(.78,.78),"duration":.30,"start_scale":.12,"peak_scale":.72,"dark_tint":Color(.02,.04,.12),"body_tint":Color(.18,.52,.94),"core_tint":Color(.82,.98,1.0),"seed":56.0,"flow_strength":.012,"opacity":.82})
	)

func _poison_death(origin:Vector3)->void:
	var oh := UNIT_HEIGHT_FALLBACK
	# Death poison is a readable ground event: a tight toxic burst, a painted
	# puddle that remains briefly, and a rising miasma cone.  Keep the layers
	# staggered so it reads as an event instead of one opaque green blob.
	var residue_key:="%d:%d"%[roundi(origin.x*4.0),roundi(origin.z*4.0)]
	for suffix in [":puddle",":miasma"]:
		var old:Variant=_poison_residue_nodes.get(residue_key+suffix)
		if is_instance_valid(old) and old is Node3D:old.queue_free()
		_poison_residue_nodes.erase(residue_key+suffix)
	var burst:=_block(VFX_ENERGY_BURST) as VFXEnergyBurst3D
	var bp:=_profile(Color(.018,.045,.008),Color(.20,.62,.035),Color(.74,1.0,.18),.86,.78,3.4,10)
	if burst!=null:
		burst.play_profile(bp,{"target":_lvl(origin,oh,LEVEL_LOW),"direction":Vector3.UP})
	var puddle:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	_poison_residue_nodes[residue_key+":puddle"]=puddle
	if puddle!=null:
		puddle.play_layer("res://assets/vfx/skills/undead_poison/undead_poison_puddle.png",{"position":_lvl(origin,oh,LEVEL_FOOT,0.0),"size":Vector2(1.25,.70),"duration":1.65,"start_scale":.18,"peak_scale":1.0,"dark_tint":Color(.015,.05,.008),"body_tint":Color(.20,.58,.025),"core_tint":Color(.68,1.0,.16),"seed":12.4,"flow_strength":.018,"opacity":.96})
	var miasma:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	_poison_residue_nodes[residue_key+":miasma"]=miasma
	var tw:=create_tween();tw.tween_interval(.12);tw.tween_callback(func():
		if is_instance_valid(miasma):
			miasma.play_layer("res://assets/vfx/skills/undead_poison/undead_poison_miasma_cone.png",{"position":_lvl(origin,oh,LEVEL_BODY),"size":Vector2(.92,1.10),"duration":1.08,"start_scale":.10,"peak_scale":.78,"dark_tint":Color(.02,.06,.008),"body_tint":Color(.22,.66,.03),"core_tint":Color(.76,1.0,.20),"seed":14.8,"flow_strength":.026,"opacity":.92})
	)

func _summon(target:Vector3)->void:
	var th := UNIT_HEIGHT_FALLBACK
	var p:=_shadow_profile(.86,1.34);p.main_color=Color(.08,.48,.38);p.core_color=Color(.64,1.0,.82);p.emission_energy=3.8
	_spawn(VFX_SUMMON,p,{"target":target})
	_spawn(VFX_LIGHT_PULSE,p,{"target":_lvl(target,th,LEVEL_BODY)})

func _interrupt_hit(target:Vector3)->void:
	# Militia's interrupt was a single flat ground flash 0.29 units across, which
	# measured as literally zero changed pixels at the battle camera. It reads as
	# a short shield-bash: a compact burst on the body plus a brighter flash.
	var th := UNIT_HEIGHT_FALLBACK
	var p:=_profile(Color(.10,.025,.008),Color(.88,.18,.025),Color(1.0,.72,.18),.94,.42,3.3,7)
	_spawn(VFX_ENERGY_BURST,p,{"target":_lvl(target,th,LEVEL_BODY),"direction":Vector3.UP})
	_spawn(VFX_IMPACT_FLASH,_profile(Color(.10,.025,.008),Color(.92,.24,.03),Color(1.0,.80,.26),1.15,.38,3.6,6),{"target":_lvl(target,th,LEVEL_BODY)})

# ── Anatomical placement ──────────────────────────────────────────────
# Levels are fractions of the unit's own rendered height, measured from the
# BODY anchor (world_hit / world_cast, which sits at 0.55 * height above the
# feet). CAMERA_PUSH moves a layer toward the camera so the model stops
# occluding it; it scales with the unit too.
const LEVEL_FOOT := -0.55
const LEVEL_LOW := -0.30
# Slightly below the anchor: painted plates are taller than they are wide and
# extend upward, so centring them exactly on the chest anchor pushes their mass
# up to the shoulders. -0.10 lands the visible mass on the torso.
const LEVEL_BODY := -0.10
const LEVEL_SHOULDER := 0.26
const LEVEL_HEAD := 0.52
const LEVEL_SKY := 1.05
const CAMERA_PUSH := 0.62
const UNIT_HEIGHT_FALLBACK := 0.98

# Rendered height of the unit this effect belongs to. BattleVfx reads it off the
# model pivot; the fallback is the measured median so preview tools still work.
func _uh(context: Dictionary, key := "target_height") -> float:
	return maxf(0.12, float(context.get(key, UNIT_HEIGHT_FALLBACK)))

# base is a BODY anchor (world_hit / world_cast).
func _lvl(base: Vector3, h: float, level: float, push := 1.0) -> Vector3:
	return base + Vector3(0.0, h * level, 0.0) + VFXBlockRoot.vfx_toward_camera(h * CAMERA_PUSH * push)

# base is a FOOT position (world_foot, or an entry of a targets array).
func _lvl_foot(base: Vector3, h: float, level: float, push := 1.0) -> Vector3:
	return base + Vector3(0.0, h * (level + 0.55), 0.0) + VFXBlockRoot.vfx_toward_camera(h * CAMERA_PUSH * push)

# ── Mercenaries ───────────────────────────────────────────────────────
# Each mercenary keeps its own colour set (bible section 10) but shares the dark
# heavy brush edge. As everywhere else these are multiplied into the plate, so
# the body value stays near 1.0.
const BUBBLE_EDGE:=Color(.10,.16,.18)
const BUBBLE_BODY:=Color(.94,1.0,1.0)
const BUBBLE_CORE:=Color(1.0,1.0,1.0)
const JUDGE_EDGE:=Color(.10,.12,.17)
const JUDGE_BODY:=Color(.94,.96,1.0)
const JUDGE_CORE:=Color(1.0,1.0,1.0)
const HUNT_EDGE:=Color(.10,.04,.06)
const HUNT_BODY:=Color(1.0,.88,.90)
const HUNT_CORE:=Color(1.0,.70,.70)
const CHARGE_EDGE:=Color(.16,.11,.06)
const CHARGE_BODY:=Color(1.0,.94,.84)
const CHARGE_CORE:=Color(1.0,.98,.92)

func _bubble_dream(origin:Vector3,target:Vector3,context:Dictionary)->void:
	var th := _uh(context)
	var oh := _uh(context,"origin_height")
	# Bubble Dream: one slow authored bubble flies out, then the outcome decides
	# which of three distinct silhouettes resolves - a burst, a sticky puddle or
	# an upward splash.  The bible is explicit that these three must not be one
	# shape in three colours, so they are three separate plates.
	# This replaces the binbun reference scene, whose world-space particles could
	# not be brought into the project's scale calibration (a bubble covered 20%
	# of the screen).
	var seed:=float(abs(int(target.x*31.0+target.z*23.0))%97)
	var target_node_value:Variant=context.get("target_node")
	var body:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if body!=null:
		body.play_layer(BUBBLE_BODY_TEXTURE,{
			"name":"Bubble_Body","from":_lvl(origin,oh,LEVEL_BODY),
			"to":_lvl(target,th,LEVEL_BODY),
			"track_node":target_node_value,
			"size":Vector2(1.06,1.06),"duration":.92,"travel_ratio":.72,
			"start_scale":.24,"peak_scale":1.0,"end_scale":.86,
			"dark_tint":BUBBLE_EDGE,"body_tint":BUBBLE_BODY,"core_tint":BUBBLE_CORE,
			"flow_strength":.020,"opacity":.92,"seed":seed
		})
	var burst:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if burst!=null:
		burst.play_layer(BUBBLE_BURST_TEXTURE,{
			"name":"Bubble_Burst","position":_lvl(target,th,LEVEL_BODY),
			"size":Vector2(1.14,1.14),"duration":.44,
			"start_scale":.16,"peak_scale":.94,"end_scale":1.12,
			"dark_tint":BUBBLE_EDGE,"body_tint":BUBBLE_BODY,"core_tint":BUBBLE_CORE,
			"flow_strength":.024,"opacity":.96,"delay":.62,"seed":seed+3.0
		})
	var sticky:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if sticky!=null:
		sticky.play_layer(BUBBLE_STICKY_TEXTURE,{
			"name":"Bubble_Sticky","position":_lvl(target,th,LEVEL_FOOT,0.0),"ground":true,
			"size":Vector2(1.02,1.02),"duration":1.55,
			"start_scale":.14,"peak_scale":.82,"end_scale":.96,
			"dark_tint":BUBBLE_EDGE,"body_tint":Color(.84,.94,.96),"core_tint":Color(.92,1.0,1.0),
			"flow_strength":.016,"opacity":.80,"delay":.70,"seed":seed+7.0,
			"follow_node":target_node_value
		})
	# The heal half of the skill lands on a different unit, so it gets its own
	# splash rather than sharing the burst.
	var heal_at:Vector3=context.get("heal_target",origin)
	var splash:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if splash!=null:
		splash.play_layer(BUBBLE_SPLASH_TEXTURE,{
			"name":"Bubble_HealSplash","position":_lvl_foot(heal_at,th,LEVEL_BODY),
			"size":Vector2(.86,1.06),"duration":.72,
			"start_scale":.14,"peak_scale":.88,"end_scale":1.02,
			"dark_tint":BUBBLE_EDGE,"body_tint":BUBBLE_BODY,"core_tint":BUBBLE_CORE,
			"flow_strength":.022,"opacity":.94,"delay":.66,"seed":seed+11.0
		})

func _shell_guard(origin:Vector3,context:Dictionary)->void:
	var oh := _uh(context,"origin_height")
	var shell_profile:=_profile(Color(.025,.07,.10),Color(.08,.42,.58),Color(.62,.96,1.0),.88,1.40,3.0,10)
	_spawn(VFX_BARRIER,shell_profile,{"target":origin})
	var layer:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if layer!=null:
		layer.play_layer("res://assets/vfx/skills/distinct_v2/shell_cyan_carapace_v2.png",{"position":_lvl(origin,oh,LEVEL_BODY),"size":Vector2(.94,.94),"duration":1.42,"start_scale":.18,"peak_scale":.88,"dark_tint":Color(.01,.08,.14),"body_tint":Color(.05,.52,.66),"core_tint":Color(.60,1.0,1.0),"seed":45.0,"flow_strength":.018,"opacity":.98})
	_spawn(VFX_LIGHT_PULSE,_profile(Color(.02,.08,.12),Color(.10,.54,.72),Color(.70,1.0,1.0),.58,.72,2.8,8),{"target":_lvl(origin,oh,LEVEL_BODY)})

func _balance_judge(origin:Vector3,target:Vector3,context:Dictionary={})->void:
	var th := _uh(context)
	# Balance Judge: a tilted measuring mark appears on the target just before the
	# cut, then one heavy asymmetric strike with a tight core.  Deliberately
	# shorter than the Arbiter's verdict so the two do not read as the same skill,
	# and cold steel blue instead of the god race's white and gold.
	var flip:=(target-origin).x<0.0
	var seed:=float(abs(int(target.x*29.0+target.z*37.0))%97)
	var mark:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if mark!=null:
		mark.play_layer(JUDGE_SCALE_MARK_TEXTURE,{
			"name":"Judge_ScaleMark","position":_lvl(target,th,LEVEL_BODY),
			"size":Vector2(.72,.94),"duration":.34,
			"start_scale":.16,"peak_scale":.78,"end_scale":.62,
			"dark_tint":JUDGE_EDGE,"body_tint":JUDGE_BODY,"core_tint":JUDGE_CORE,
			"flow_strength":.014,"opacity":.86,"seed":seed
		})
	var slash:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if slash!=null:
		slash.play_layer(JUDGE_SLASH_TEXTURE,{
			"name":"Judge_Slash","position":_lvl(target,th,LEVEL_BODY),
			"size":Vector2(1.48,1.10),"duration":.38,
			"start_scale":.14,"peak_scale":.94,"end_scale":1.06,
			"rotation_z":PI if flip else 0.0,
			"dark_tint":JUDGE_EDGE,"body_tint":JUDGE_BODY,"core_tint":JUDGE_CORE,
			"flow_strength":.018,"opacity":.98,"delay":.20,"seed":seed+3.0
		})
	var impact:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if impact!=null:
		impact.play_layer(JUDGE_IMPACT_TEXTURE,{
			"name":"Judge_Impact","position":_lvl(target,th,LEVEL_BODY),
			"size":Vector2(.92,.92),"duration":.36,
			"start_scale":.10,"peak_scale":.74,"end_scale":.92,
			"dark_tint":JUDGE_EDGE,"body_tint":JUDGE_BODY,"core_tint":JUDGE_CORE,
			"flow_strength":.016,"opacity":.96,"delay":.32,"seed":seed+7.0
		})

func _gold_charge(origin:Vector3,target:Vector3,context:Dictionary)->void:
	var th := _uh(context)
	var oh := _uh(context,"origin_height")
	# Gold Charge in the four stages the bible asks for: wind-up dust at the
	# start, the charge trail along the path, the collision, and stun debris over
	# the victim.  The charge path IS the projectile here, so the trail travels.
	var seed:=float(abs(int(target.x*41.0+target.z*19.0))%97)
	var target_node_value:Variant=context.get("target_node")
	var dust:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if dust!=null:
		dust.play_layer(CHARGE_DUST_TEXTURE,{
			"name":"Charge_Dust","position":_lvl(origin,oh,LEVEL_FOOT,0.0),"ground":true,
			"size":Vector2(1.22,.86),"duration":.66,
			"start_scale":.14,"peak_scale":.90,"end_scale":1.10,
			"dark_tint":CHARGE_EDGE,"body_tint":CHARGE_BODY,"core_tint":CHARGE_CORE,
			"flow_strength":.022,"opacity":.88,"seed":seed
		})
	# Body rush: keep the procedural afterimage, retinted to the ochre set.
	var dash:=_profile(Color(.16,.11,.06),Color(.86,.62,.20),Color(1.0,.94,.72),.78,.72,3.0,8)
	_spawn(VFX_AFTERIMAGE,dash,{"origin":origin,"target":target})
	var trail:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if trail!=null:
		trail.play_layer(CHARGE_TRAIL_TEXTURE,{
			"name":"Charge_Trail","from":_lvl(origin,oh,LEVEL_BODY),
			"to":_lvl(target,th,LEVEL_BODY),
			"track_node":target_node_value,
			"size":Vector2(1.62,.66),"duration":.56,"travel_ratio":.68,
			"start_scale":.30,"peak_scale":1.0,"end_scale":.84,
			"dark_tint":CHARGE_EDGE,"body_tint":CHARGE_BODY,"core_tint":CHARGE_CORE,
			"flow_strength":.020,"opacity":.94,"delay":.12,"seed":seed+3.0
		})
	var impact:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if impact!=null:
		impact.play_layer(CHARGE_IMPACT_TEXTURE,{
			"name":"Charge_Impact","position":_lvl(target,th,LEVEL_BODY),
			"size":Vector2(1.32,.94),"duration":.40,
			"start_scale":.14,"peak_scale":.92,"end_scale":1.08,
			"dark_tint":CHARGE_EDGE,"body_tint":CHARGE_BODY,"core_tint":CHARGE_CORE,
			"flow_strength":.018,"opacity":.98,"delay":.44,"seed":seed+7.0
		})
	var debris:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if debris!=null:
		# Head-top stun icon still belongs to StatusVFXController; this is the
		# short "you got rammed" debris the bible asks for, and it follows the
		# victim for the stun duration.
		debris.play_layer(CHARGE_STUN_DEBRIS_TEXTURE,{
			"name":"Charge_StunDebris","position":_lvl(target,th,LEVEL_HEAD),
			"size":Vector2(.60,.48),
			"duration":clampf(float(context.get("status_duration",1.2)),.80,2.0),
			"start_scale":.16,"peak_scale":.72,"end_scale":.88,
			"dark_tint":CHARGE_EDGE,"body_tint":CHARGE_BODY,"core_tint":CHARGE_CORE,
			"flow_strength":.020,"opacity":.90,"delay":.56,"seed":seed+11.0,
			"follow_node":target_node_value
		})

func _holy_song(origin:Vector3,context:Dictionary)->void:
	var th := _uh(context)
	var oh := _uh(context,"origin_height")
	var hymn:=_holy_profile(.88,1.05);hymn.main_color=Color(.42,.72,.22);hymn.core_color=Color(.86,1.0,.52);hymn.emission_energy=3.8
	_spawn(VFX_LIGHT_PULSE,hymn,{"target":_lvl(origin,oh,LEVEL_BODY)})
	for value in _capped_targets(context.get("targets",[])):
		var note:=_profile(Color(.05,.10,.02),Color(.32,.66,.12),Color(.82,1.0,.46),.44,.72,3.4,8)
		# 原本用 binbun "beam"（15 节点 / 28 子资源 / 7 个 ShaderMaterial / 132 粒子）。
		# 这三处 beam 的形态都是「从施法者连到每个目标」，正是 TrackedLink 做的事，
		# 而它是自制模块、已做过 mesh 复用优化，成本低一个数量级。
		_spawn(VFX_TRACKED_LINK,note,{"origin":_lvl(origin,oh,LEVEL_BODY),"target":_lvl_foot(value,th,LEVEL_BODY),"persistent":false})
		_spawn(VFX_LIGHT_PULSE,note,{"target":_lvl_foot(value,th,LEVEL_BODY)})

func _twin_strike(origin:Vector3,target:Vector3,context:Dictionary)->void:
	var th := _uh(context)
	# 300 费佣兵。两道弧原本 width 只有 .085/.075，是全场最细的技能。
	# 加宽到 .16/.14，并叠上早已画好的专属双斩贴图作为主体，程序弧退为衬底。
	var first:=_profile(Color(.015,.025,.06),Color(.10,.30,.62),Color(.58,.86,1.0),.34,.30,1.55,3)
	first.parameters={"width":.16,"arc_degrees":104.0,"tilt_degrees":14.0}
	_spawn(VFX_SLASH_ARC,first,{"target":_lvl(target,th,LEVEL_BODY),"direction":Vector3.RIGHT})
	var second:=_profile(Color(.06,.012,.04),Color(.36,.05,.46),Color(.78,.38,.78),.32,.27,1.45,3)
	second.parameters={"width":.14,"arc_degrees":100.0,"tilt_degrees":-14.0}
	_spawn(VFX_SLASH_ARC,second,{"target":_lvl(target,th,LEVEL_BODY),"direction":Vector3.LEFT})
	var slash:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if slash!=null:
		slash.play_layer("res://assets/vfx/skills/distinct_v2/twin_assassin_double_slash_v2.png",{"position":_lvl(target,th,LEVEL_BODY),"size":Vector2(1.02,.82),"duration":.44,"start_scale":.16,"peak_scale":.94,"dark_tint":Color(.03,.01,.06),"body_tint":Color(.30,.26,.62),"core_tint":Color(.80,.78,1.0),"seed":63.0,"flow_strength":.020,"opacity":.98})
	var flash_profile:=_profile(Color(.04,.008,.06),Color(.34,.06,.46),Color(.78,.52,.90),.16,.12,1.15,2)
	_spawn(VFX_IMPACT_FLASH,flash_profile,{"target":_lvl(target,th,LEVEL_BODY)})

func _king_aura(origin:Vector3,context:Dictionary)->void:
	var th := _uh(context)
	# Human King: a single vertical heaven-sword drop per affected target.
	# It falls straight down, keeps its authored gold colour, then dissolves.
	var targets:Array=_capped_targets(context.get("targets",[]))
	if targets.is_empty():
		targets=[origin]
	for i in range(targets.size()):
		var value:Vector3=targets[i]
		var sword:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
		if sword!=null:
			sword.play_layer("res://assets/vfx/skills/human_king/human_king_heaven_sword.png",{"from":_lvl_foot(value,th,LEVEL_SKY),"to":_lvl_foot(value,th,LEVEL_BODY),"size":Vector2(.64,1.72),"duration":.58,"travel_ratio":.48,"start_scale":.20,"peak_scale":.86,"end_scale":.72,"dark_tint":Color(.08,.04,.012),"body_tint":Color(.98,.62,.12),"core_tint":Color(1.0,.92,.42),"seed":10.0+float(i),"flow_strength":.010,"opacity":.92})

func _king_attack(origin:Vector3,target:Vector3,context:Dictionary)->void:
	var th := _uh(context)
	# One straight, target-bound sword drop for Human King's normal attack.
	var sword:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if sword!=null:
		sword.play_layer("res://assets/vfx/skills/human_king/human_king_heaven_sword.png",{"from":_lvl(target,th,LEVEL_SKY),"to":_lvl(target,th,LEVEL_BODY),"size":Vector2(.64,1.72),"duration":.58,"travel_ratio":.48,"start_scale":.20,"peak_scale":.86,"end_scale":.72,"dark_tint":Color(.08,.04,.012),"body_tint":Color(.98,.62,.12),"core_tint":Color(1.0,.92,.42),"seed":91.0,"flow_strength":.010,"opacity":.92})

func _arrow_rain(origin:Vector3,target:Vector3,context:Dictionary)->void:
	var th := _uh(context)
	var targets:Array=_capped_targets(context.get("targets",[]))
	if targets.is_empty():targets=[target]
	for i in range(targets.size()):
		var value:Vector3=targets[i]
		var arrow:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
		var delay:=float(i)*.06
		var tw:=create_tween();tw.tween_interval(delay);tw.tween_callback(func():
			if is_instance_valid(arrow):
				arrow.play_layer("res://assets/vfx/skills/god_aurora/god_aurora_arrow_trail.png",{"from":_lvl_foot(value,th,LEVEL_SKY),"to":_lvl_foot(value,th,LEVEL_LOW),"size":Vector2(.62,.16),"duration":.46,"travel_ratio":.88,"dark_tint":Color(.015,.06,.18),"body_tint":Color(.10,.42,.92),"core_tint":Color(.74,.96,1.0),"seed":20.0+float(i),"flow_strength":.02,"opacity":1.0})
		)
		var impact:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
		var hit_tw:=create_tween();hit_tw.tween_interval(delay+.40);hit_tw.tween_callback(func():
			if is_instance_valid(impact):
				impact.play_layer("res://assets/vfx/skills/human_militia/human_militia_hit_dust_pop.png",{"position":_lvl_foot(value,th,LEVEL_FOOT,0.0),"size":Vector2(.72,.72),"duration":.48,"start_scale":.16,"peak_scale":.88,"dark_tint":Color(.03,.08,.16),"body_tint":Color(.10,.42,.86),"core_tint":Color(.78,.96,1.0),"seed":24.0+float(i),"flow_strength":.018,"opacity":.94})
		)

func _blood_rampage(origin:Vector3)->void:
	var oh := UNIT_HEIGHT_FALLBACK
	var p:=_blood_profile(1.02,1.05)
	_spawn(VFX_ENERGY_BURST,p,{"target":origin,"direction":Vector3.UP})
	_spawn(VFX_LIGHT_PULSE,p,{"target":_lvl(origin,oh,LEVEL_BODY)})

func _steel_order(origin:Vector3,context:Dictionary)->void:
	var th := _uh(context)
	var oh := _uh(context,"origin_height")
	var p:=_profile(Color(.025,.035,.05),Color(.22,.34,.46),Color(.74,.92,1.0),.64,.92,2.8,8)
	_spawn(VFX_LIGHT_PULSE,p,{"target":_lvl(origin,oh,LEVEL_BODY)})
	for value in _capped_targets(context.get("targets",[])):
		_spawn(VFX_BARRIER,p,{"target":value})
		_spawn(VFX_TRACKED_LINK,p,{"origin":_lvl(origin,oh,LEVEL_BODY),"target":_lvl_foot(value,th,LEVEL_BODY),"persistent":false})

func _time_slow(origin:Vector3,target:Vector3,context:Dictionary)->void:
	var th := _uh(context)
	var oh := _uh(context,"origin_height")
	var p:=_profile(Color(.018,.025,.10),Color(.10,.28,.68),Color(.58,.90,1.0),1.12,1.48,3.8,12)
	_spawn(VFX_ENERGY_BURST,p,{"target":_lvl(origin,oh,LEVEL_BODY),"direction":Vector3.UP})
	for value in _capped_targets(context.get("targets",[])):
		var slow:=_profile(Color(.02,.04,.10),Color(.10,.38,.72),Color(.58,.90,1.0),.38,1.05,2.5,6);slow.parameters["status_type"]="slow"
		_spawn(VFX_TRACKED_LINK,p,{"origin":_lvl(origin,oh,LEVEL_BODY),"target":_lvl_foot(value,th,LEVEL_BODY),"persistent":false})
		_spawn(VFX_STATUS,slow,{"target":value})

func _death_hunt(origin:Vector3,target:Vector3,context:Dictionary)->void:
	var th := _uh(context)
	# Death Hunt: blink in, one reaping cut, then an underworld rift that closes
	# inward on the target, and a crimson crack for the armour break / heal cut.
	# The old distinct_v2 plate was a complete scythe, which the bible bans; this
	# cut has no handle and no blade shape.
	var flip:=(target-origin).x<0.0
	var seed:=float(abs(int(target.x*43.0+target.z*29.0))%97)
	var target_node_value:Variant=context.get("target_node")
	var dash:=_profile(Color(.10,.04,.06),Color(.62,.10,.16),Color(1.0,.62,.60),.74,.62,3.0,7)
	_spawn(VFX_AFTERIMAGE,dash,{"origin":origin,"target":target})
	var cut:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if cut!=null:
		cut.play_layer(HUNT_SCYTHE_CUT_TEXTURE,{
			"name":"Hunt_Cut","position":_lvl(target,th,LEVEL_BODY),
			"size":Vector2(1.58,1.16),"duration":.40,
			"start_scale":.14,"peak_scale":.96,"end_scale":1.08,
			"rotation_z":PI if flip else 0.0,
			"dark_tint":HUNT_EDGE,"body_tint":HUNT_BODY,"core_tint":HUNT_CORE,
			"flow_strength":.022,"opacity":.98,"delay":.14,"seed":seed
		})
	var rift:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if rift!=null:
		# Ends smaller than it starts: the rift closes in, it does not explode.
		rift.play_layer(HUNT_RIFT_TEXTURE,{
			"name":"Hunt_Rift","position":_lvl(target,th,LEVEL_BODY),
			"size":Vector2(1.12,1.12),"duration":.52,
			"start_scale":.96,"peak_scale":.78,"end_scale":.42,
			"dark_tint":HUNT_EDGE,"body_tint":HUNT_BODY,"core_tint":HUNT_CORE,
			"flow_strength":.024,"opacity":.96,"delay":.30,"seed":seed+5.0
		})
	var crack:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if crack!=null:
		crack.play_layer(HUNT_ARMOR_CRACK_TEXTURE,{
			"name":"Hunt_ArmorCrack","position":_lvl(target,th,LEVEL_BODY),
			"size":Vector2(.84,.88),
			"duration":clampf(float(context.get("status_duration",1.8)),1.2,2.6),
			"start_scale":.14,"peak_scale":.70,"end_scale":.86,
			"dark_tint":HUNT_EDGE,"body_tint":Color(.90,.70,.72),"core_tint":Color(1.0,.56,.56),
			"flow_strength":.016,"opacity":.86,"delay":.48,"seed":seed+9.0,
			"follow_node":target_node_value
		})

# 所有 VFX 块都从这里生成，统一受全局并发上限约束；超限返回 null。
# 调用方要么判空，要么依赖已有的 is_instance_valid() 守卫（对 null 返回 false）。
#
# 脚本是运行期传进来的，所以这里只能声明成 Node3D；调用点必须显式
# `as <具体类型>`，否则变量被定型成 Node3D，被 tween 的 lambda 捕获后
# 运行时会报 "Nonexistent function 'play_layer' in base 'Node3D'"。
# 改造前的 `var x := VFX_PAINTED.new()` 本来就推断出具体类型，转换是为了保持等价。
func _block(script:Script)->Node3D:
	return VFXBlockRoot.spawn_block(script,self)

# 关键事件专用：跳过并发上限，保证一定生成（母灵处决的书等）。
func _block_forced(script:Script)->Node3D:
	return VFXBlockRoot.spawn_block(script,self,true)

func _spawn_forced(script:Script,profile:VFXProfile3D,context:Dictionary)->Node3D:
	var node:=_block_forced(script)
	if node==null:return null
	last_spawned=node;node.call("play_profile",profile,context);return node

# 群体技能的特效目标列表，按画质档位截断。纯表现层：
# 伤害/治疗/命中判定仍然由战斗模拟作用于全部目标，这里只少画几个。
func _capped_targets(targets:Array)->Array:
	var limit:=VFXQualityBudget.max_aoe_targets(targets.size())
	return targets if limit>=targets.size() else targets.slice(0,limit)

# ── PVE 怪物 / 阵型盟友 ────────────────────────────────────────────────
# 这批单位（16 只 PVE 怪 + 5 个阵型盟友）以前在两个 composer 的 match 里
# 都没有分支，施法时是静默无表现。下面全部用现成模块按属性拼装，
# 不依赖任何新美术资源；后续要专属贴图再逐个替换即可。

# 天空系：青白 + 金，走电/风/光。
func _chain_lightning(origin:Vector3,target:Vector3,context:Dictionary)->void:
	var th := _uh(context)
	var arc:=_block(VFX_LIGHTNING_ARC) as VFXLightningArc
	if arc!=null:arc.play_arc(_lvl(target,th,LEVEL_SKY),target)
	var p:=_profile(Color(.02,.05,.12),Color(.22,.54,.96),Color(.84,.97,1.0),.50,.42,3.8,7)
	_spawn(VFX_IMPACT_FLASH,p,{"target":_lvl(target,th,LEVEL_BODY)})
	# 有群体目标时把电弧串下去，没有就只打单体。
	for value in _capped_targets(context.get("targets",[])):
		var link:=_profile(Color(.02,.05,.12),Color(.26,.60,1.0),Color(.88,.98,1.0),.18,.30,2.4,3)
		_spawn(VFX_TRACKED_LINK,link,{"origin":_lvl(target,th,LEVEL_BODY),"target":_lvl_foot(value,th,LEVEL_BODY),"persistent":false})

func _dive_backline(origin:Vector3,target:Vector3,context:Dictionary)->void:
	var th := _uh(context)
	var dash:=_profile(Color(.05,.08,.12),Color(.52,.78,.94),Color(.94,1.0,1.0),.70,.62,3.0,8)
	_spawn(VFX_AFTERIMAGE,dash,{"origin":origin,"target":target})
	var hit:=_profile(Color(.04,.07,.11),Color(.58,.84,.98),Color(1.0,1.0,1.0),.46,.34,3.2,6)
	hit.parameters={"width":.075,"arc_degrees":96.0,"tilt_degrees":18.0}
	_spawn(VFX_SLASH_ARC,hit,{"target":_lvl(target,th,LEVEL_BODY),"direction":(target-origin).normalized()})
	_spawn(VFX_IMPACT_FLASH,hit,{"target":_lvl(target,th,LEVEL_BODY)})

func _sky_heal(origin:Vector3,context:Dictionary)->void:
	var th := _uh(context)
	var oh := _uh(context,"origin_height")
	var p:=_profile(Color(.06,.10,.14),Color(.42,.76,.92),Color(.92,1.0,1.0),.34,.52,2.8,7)
	_spawn(VFX_LIGHT_PULSE,p,{"target":_lvl(origin,oh,LEVEL_BODY)})
	for value in _capped_targets(context.get("targets",[])):
		_spawn(VFX_LIGHT_PULSE,p,{"target":_lvl_foot(value,th,LEVEL_BODY)})

func _dome_shield(origin:Vector3,context:Dictionary)->void:
	var oh := _uh(context,"origin_height")
	var p:=_profile(Color(.10,.08,.03),Color(.74,.62,.22),Color(1.0,.96,.68),.80,1.05,3.0,8)
	_barrier(origin,p,context)
	_spawn(VFX_LIGHT_PULSE,p,{"target":_lvl(origin,oh,LEVEL_BODY)})

func _wind_bleed(origin:Vector3,target:Vector3,context:Dictionary)->void:
	var th := _uh(context)
	# 两道细风刃，错开角度，读起来是"割"而不是"砸"。
	var direction:=(target-origin).normalized()
	var first:=_profile(Color(.04,.08,.08),Color(.48,.86,.82),Color(.94,1.0,1.0),.62,.26,1.8,3)
	first.parameters={"width":.105,"arc_degrees":112.0,"tilt_degrees":22.0}
	_spawn(VFX_SLASH_ARC,first,{"target":_lvl(target,th,LEVEL_BODY),"direction":direction})
	var second:=_profile(Color(.04,.08,.08),Color(.40,.78,.76),Color(.88,1.0,1.0),.56,.24,1.6,3)
	second.parameters={"width":.092,"arc_degrees":106.0,"tilt_degrees":-20.0}
	_spawn(VFX_SLASH_ARC,second,{"target":_lvl(target,th,LEVEL_BODY),"direction":direction})
	_spawn(VFX_IMPACT_FLASH,first,{"target":_lvl(target,th,LEVEL_BODY)})

func _slow_aura(origin:Vector3,context:Dictionary)->void:
	var oh := _uh(context,"origin_height")
	var p:=_profile(Color(.03,.05,.12),Color(.24,.44,.86),Color(.78,.94,1.0),.86,1.15,2.8,9)
	_spawn(VFX_ENERGY_BURST,p,{"target":_lvl(origin,oh,LEVEL_BODY),"direction":Vector3.UP})
	for value in _capped_targets(context.get("targets",[])):
		var slow:=_profile(p.dark_color,p.main_color,p.core_color,.34,.95,2.2,5)
		slow.parameters={"status_type":"slow","status_slot":5}
		_spawn(VFX_STATUS,slow,{"target":value})

# 大地系：土黄 / 苔绿 / 熔岩橙。
func _stun_impact(origin:Vector3,target:Vector3,context:Dictionary)->void:
	var th := _uh(context)
	var p:=_profile(Color(.08,.06,.03),Color(.62,.44,.18),Color(1.0,.86,.50),.62,.48,3.0,8)
	_spawn(VFX_ENERGY_BURST,p,{"target":_lvl(target,th,LEVEL_BODY),"direction":(target-origin).normalized()})
	_spawn(VFX_IMPACT_FLASH,p,{"target":_lvl(target,th,LEVEL_BODY)})
	_status_hit(target,"stun",context)

func _entangle(target:Vector3,context:Dictionary)->void:
	var th := _uh(context)
	var p:=_profile(Color(.02,.06,.015),Color(.24,.58,.14),Color(.74,1.0,.42),.72,1.05,2.6,8)
	_spawn(VFX_GROUND_SIGIL,p,{"target":_lvl(target,th,LEVEL_FOOT,0.0)})
	_status_hit(target,"slow",context)

func _burrow_ambush(origin:Vector3,target:Vector3)->void:
	var th := UNIT_HEIGHT_FALLBACK
	var oh := UNIT_HEIGHT_FALLBACK
	# 先在出发点炸开土，再窜到目标脚下。
	var dirt:=_profile(Color(.07,.055,.03),Color(.50,.38,.16),Color(.92,.80,.46),.58,.52,2.4,8)
	_spawn(VFX_ENERGY_BURST,dirt,{"target":_lvl(origin,oh,LEVEL_LOW),"direction":Vector3.UP})
	_spawn(VFX_AFTERIMAGE,dirt,{"origin":origin,"target":target})
	_spawn(VFX_ENERGY_BURST,dirt,{"target":_lvl(target,th,LEVEL_LOW),"direction":Vector3.UP})
	_spawn(VFX_IMPACT_FLASH,dirt,{"target":_lvl(target,th,LEVEL_BODY)})

func _lava_burst(target:Vector3)->void:
	var th := UNIT_HEIGHT_FALLBACK
	var p:=_profile(Color(.10,.02,.004),Color(.88,.26,.03),Color(1.0,.82,.32),.84,.72,4.2,10)
	_spawn(VFX_ENERGY_BURST,p,{"target":_lvl(target,th,LEVEL_LOW),"direction":Vector3.UP})
	_spawn(VFX_LIGHT_PULSE,p,{"target":_lvl(target,th,LEVEL_BODY)})

func _nature_heal(origin:Vector3,context:Dictionary)->void:
	var oh := _uh(context,"origin_height")
	var p:=_profile(Color(.03,.08,.02),Color(.34,.68,.20),Color(.84,1.0,.56),.44,.68,2.8,8)
	_spawn(VFX_LIGHT_PULSE,p,{"target":_lvl(origin,oh,LEVEL_BODY)})
	for value in _capped_targets(context.get("targets",[])):
		_spawn(VFX_FALLING_PILLAR,p,{"target":value})

func _earth_slam(origin:Vector3,target:Vector3)->void:
	var th := UNIT_HEIGHT_FALLBACK
	var p:=_profile(Color(.07,.055,.03),Color(.56,.40,.16),Color(.96,.84,.48),.96,.68,3.0,10)
	_spawn(VFX_SHOCKWAVE,p,{"target":_lvl(target,th,LEVEL_FOOT,0.0)})
	_spawn(VFX_ENERGY_BURST,p,{"target":_lvl(target,th,LEVEL_LOW),"direction":Vector3.UP})
	_spawn(VFX_IMPACT_FLASH,p,{"target":_lvl(target,th,LEVEL_BODY)})

# 人系。
func _backstab(origin:Vector3,target:Vector3)->void:
	var th := UNIT_HEIGHT_FALLBACK
	var dash:=_profile(Color(.03,.02,.05),Color(.24,.18,.34),Color(.76,.68,.92),.62,.52,2.4,7)
	_spawn(VFX_AFTERIMAGE,dash,{"origin":origin,"target":target})
	var cut:=_profile(Color(.05,.02,.05),Color(.42,.16,.44),Color(.94,.72,.96),.44,.30,3.0,5)
	cut.parameters={"width":.070,"arc_degrees":98.0,"tilt_degrees":-24.0}
	_spawn(VFX_SLASH_ARC,cut,{"target":_lvl(target,th,LEVEL_BODY),"direction":(target-origin).normalized()})
	_spawn(VFX_IMPACT_FLASH,cut,{"target":_lvl(target,th,LEVEL_BODY)})

func _counter_slash(target:Vector3)->void:
	var th := UNIT_HEIGHT_FALLBACK
	# 反击：一正一反两刀，比普通斩击更短促。
	var first:=_profile(Color(.03,.035,.05),Color(.34,.42,.56),Color(.88,.94,1.0),.66,.24,1.8,3)
	first.parameters={"width":.140,"arc_degrees":108.0,"tilt_degrees":16.0}
	_spawn(VFX_SLASH_ARC,first,{"target":_lvl(target,th,LEVEL_BODY),"direction":Vector3.RIGHT})
	var second:=_profile(first.dark_color,first.main_color,first.core_color,.58,.22,1.6,3)
	second.parameters={"width":.126,"arc_degrees":102.0,"tilt_degrees":-16.0}
	_spawn(VFX_SLASH_ARC,second,{"target":_lvl(target,th,LEVEL_BODY),"direction":Vector3.LEFT})
	_spawn(VFX_IMPACT_FLASH,first,{"target":_lvl(target,th,LEVEL_BODY)})

# 阵型盟友：深渊/炼狱配色，比 PVE 怪更重一档。手绘分层，和暗族同规格。
#
# 这五个以前全是程序化几何，截帧下 burn_claw 0.056% / soul_chain 0.052%，
# 低于 vfx_diff 的 0.2% 空表现阈值 —— 玩家在最终回合看到的是「什么都没放」。
#
# 三条在重画时一并纠正的错配：
#   1. 全场技（锁魂/噬兽）过去只画一个目标，BattleVfx 传进来的 targets 被忽略；
#   2. 焰爪的主动技其实是自保（BattleSimSkills._skill_ally_self_sustain 回血+加盾），
#      过去却往最近的敌人身上挠爪；
#   3. 锁魂挂的状态图标是 slow，而技能的主效果是 stun。
const INFERNO_EDGE:=Color(.11,.03,.01)   # 炼狱系：焦黑边
const INFERNO_BODY:=Color(1.0,.86,.72)   # 本体几乎保留贴图原色，只压一点暖
const INFERNO_CORE:=Color(1.0,.94,.78)   # 熔核：偏白的金
# 锁魂者：烧红的锻铁。五个友军同为橙红，靠明度和饱和度分层次，不靠色相分。
#
# body 必须贴近 1.0：这几个 tint 是**乘进**贴图的（见 VFXBossTextureLayer3D 的
# TEXTURE_SHADER），链子本身画的就是深灰铁，body 再压到 .8 以下就整个发黑，
# 实测暖色像素只剩 31%，看上去是一坨灰的。
const FORGE_EDGE:=Color(.10,.03,.01)
const FORGE_BODY:=Color(1.0,.74,.52)
const FORGE_CORE:=Color(1.0,.70,.30)

# 焰爪魔灵（1-10 血）：自保技。回血 + 护盾都作用在自己身上，所以三层全部
# 锚在施法者身上 —— 脚下焦土、裹身炭壳、上升的余烬。
func _burn_claw(origin:Vector3,context:Dictionary)->void:
	var oh := _uh(context,"origin_height")
	var seed:=float(abs(int(origin.x*31.0+origin.z*17.0))%97)
	var coals:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if coals!=null:
		coals.play_layer(FLAMECLAW_GROUND_COALS_TEXTURE,{
			"name":"BurnClaw_Coals","position":_lvl(origin,oh,LEVEL_FOOT,0.0),
			"size":Vector2(2.00,2.00),"ground":true,"duration":1.05,
			"start_scale":.14,"peak_scale":.86,"end_scale":1.04,
			"dark_tint":INFERNO_EDGE,"body_tint":INFERNO_BODY,"core_tint":INFERNO_CORE,
			"flow_strength":.010,"opacity":.88,"seed":seed
		})
	var shell:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if shell!=null:
		# 护盾壳：start < peak > end 收一点，读作「合拢包住自己」而不是炸开。
		shell.play_layer(FLAMECLAW_EMBER_SHELL_TEXTURE,{
			"name":"BurnClaw_Shell","position":_lvl(origin,oh,LEVEL_BODY),
			"size":Vector2(1.72,1.84),"duration":.92,
			"start_scale":.36,"peak_scale":.96,"end_scale":.84,
			"dark_tint":INFERNO_EDGE,"body_tint":INFERNO_BODY,"core_tint":INFERNO_CORE,
			"flow_strength":.022,"opacity":.96,"delay":.10,"seed":seed+3.0,
			"follow_node":context.get("origin_node")
		})
	var updraft:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if updraft!=null:
		# 回血：余烬往上飘，尺寸一路放大，是全场唯一一处「向上」的读法。
		updraft.play_layer(FLAMECLAW_HEAL_UPDRAFT_TEXTURE,{
			"name":"BurnClaw_Heal","position":_lvl(origin,oh,LEVEL_SHOULDER),
			"size":Vector2(1.16,1.70),"duration":.86,
			"start_scale":.20,"peak_scale":.88,"end_scale":1.06,
			"dark_tint":INFERNO_EDGE,"body_tint":INFERNO_BODY,"core_tint":INFERNO_CORE,
			"flow_strength":.026,"opacity":.90,"delay":.26,"seed":seed+7.0,
			"follow_node":context.get("origin_node")
		})

# 暗狱锁魂者（11-20 血）：全场眩晕 + 减攻速。链子从施法者甩向每一个敌人，
# 锁印落在每个目标头上 —— 这是「全场」，不是单体。
func _soul_chain(origin:Vector3,target:Vector3,context:Dictionary)->void:
	var th := _uh(context)
	var oh := _uh(context,"origin_height")
	var seed:=float(abs(int(target.x*23.0+target.z*11.0))%97)
	var coil:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if coil!=null:
		coil.play_layer(SOULCHAIN_CAST_COIL_TEXTURE,{
			"name":"SoulChain_Coil","position":_lvl(origin,oh,LEVEL_BODY),
			"size":Vector2(1.52,1.64),"duration":.40,
			"start_scale":.72,"peak_scale":.50,"end_scale":.30,
			"dark_tint":FORGE_EDGE,"body_tint":FORGE_BODY,"core_tint":FORGE_CORE,
			"flow_strength":.024,"opacity":.94,"seed":seed
		})
	# 链体飞向最近的那个目标（有 track_node 会跟着走），其余目标只落锁印 ——
	# 十条链同时在场会糊成一团，读不出「谁被锁住了」。
	var chain:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if chain!=null:
		chain.play_layer(SOULCHAIN_CHAIN_LINK_TEXTURE,{
			"name":"SoulChain_Link","from":_lvl(origin,oh,LEVEL_BODY),"to":_lvl(target,th,LEVEL_BODY),
			"track_node":context.get("target_node"),
			"size":Vector2(2.05,.58),"duration":.62,"travel_ratio":.68,
			"start_scale":.34,"peak_scale":1.0,"end_scale":.88,
			"dark_tint":FORGE_EDGE,"body_tint":FORGE_BODY,"core_tint":FORGE_CORE,
			"flow_strength":.018,"opacity":1.0,"delay":.16,"seed":seed+3.0
		})
	var index:=0.0
	for value in _capped_targets(context.get("targets",[])):
		var seal:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
		if seal==null:
			continue
		# 逐目标错开一点，全场同帧齐闪会读成一次全屏闪光而不是「一个个被锁上」。
		seal.play_layer(SOULCHAIN_LOCK_SEAL_TEXTURE,{
			"name":"SoulChain_Seal","position":_lvl_foot(value,th,LEVEL_HEAD),
			"size":Vector2(1.00,1.06),"duration":.52,
			"start_scale":.12,"peak_scale":.84,"end_scale":.96,
			"dark_tint":FORGE_EDGE,"body_tint":FORGE_BODY,"core_tint":FORGE_CORE,
			"flow_strength":.020,"opacity":.96,"delay":.46+index*.05,"seed":seed+index*13.0
		})
		index+=1.0
	# 减攻速的残迹留在最近那个目标肩上，跟着它走。
	var smear:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if smear!=null:
		smear.play_layer(SOULCHAIN_DRAG_SMEAR_TEXTURE,{
			"name":"SoulChain_Drag","position":_lvl(target,th,LEVEL_SHOULDER),
			"size":Vector2(.90,1.14),
			"duration":clampf(float(context.get("status_duration",1.5)),1.2,3.0),
			"start_scale":.14,"peak_scale":.62,"end_scale":.74,
			"dark_tint":FORGE_EDGE,"body_tint":Color(.86,.66,.52),"core_tint":Color(1.0,.74,.44),
			"flow_strength":.016,"opacity":.70,"delay":.58,"seed":seed+11.0,
			"follow_node":context.get("target_node")
		})
	_status_hit(target,"stun",context)

# 深渊噬兽（21-30 血）：全场沉默 + 吸血。巨口咬在最近的目标上，封口印落在
# 每一个敌人身上，血再回抽到施法者。
func _devour_bite(origin:Vector3,target:Vector3,context:Dictionary)->void:
	var th := _uh(context)
	var oh := _uh(context,"origin_height")
	var seed:=float(abs(int(target.x*19.0+target.z*29.0))%97)
	var maw:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if maw!=null:
		maw.play_layer(DEVOUR_MAW_TEAR_TEXTURE,{
			"name":"Devour_Maw","position":_lvl(target,th,LEVEL_BODY),
			"size":Vector2(1.96,1.60),"duration":.50,
			"start_scale":.24,"peak_scale":1.0,"end_scale":.78,
			"dark_tint":Color(.12,.03,.01),"body_tint":Color(1.0,.84,.62),"core_tint":Color(1.0,.72,.34),
			"flow_strength":.024,"opacity":1.0,"seed":seed
		})
	var index:=0.0
	for value in _capped_targets(context.get("targets",[])):
		var gag:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
		if gag==null:
			continue
		gag.play_layer(DEVOUR_SILENCE_GAG_TEXTURE,{
			"name":"Devour_Gag","position":_lvl_foot(value,th,LEVEL_HEAD),
			"size":Vector2(.98,.98),"duration":.58,
			"start_scale":.12,"peak_scale":.80,"end_scale":.92,
			"dark_tint":Color(.12,.03,.01),"body_tint":Color(.96,.76,.58),"core_tint":Color(1.0,.74,.38),
			"flow_strength":.018,"opacity":.94,"delay":.30+index*.05,"seed":seed+index*17.0
		})
		index+=1.0
	var pull:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if pull!=null:
		# 吸血：方向和链体相反，从目标回到施法者。
		pull.play_layer(DEVOUR_LIFESTEAL_PULL_TEXTURE,{
			"name":"Devour_Lifesteal","from":_lvl(target,th,LEVEL_BODY),"to":_lvl(origin,oh,LEVEL_BODY),
			"track_node":context.get("origin_node"),
			"size":Vector2(1.80,.56),"duration":.66,"travel_ratio":.72,
			"start_scale":.30,"peak_scale":.92,"end_scale":.62,
			"dark_tint":Color(.10,.02,.01),"body_tint":Color(.96,.52,.24),"core_tint":Color(1.0,.66,.30),
			"flow_strength":.022,"opacity":.92,"delay":.34,"seed":seed+5.0
		})

# 炼狱焚界者（31-40 血）：全场灼烧 + 减攻。火柱落在最近的目标，焦痕铺满每一个
# 敌人脚下，减攻烙印跟着补。
func _hell_burst(target:Vector3,context:Dictionary)->void:
	var th := _uh(context)
	var seed:=float(abs(int(target.x*37.0+target.z*13.0))%97)
	var column:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if column!=null:
		column.play_layer(INFERNO_SKY_COLUMN_TEXTURE,{
			"name":"Inferno_Column","from":_lvl(target,th,LEVEL_SKY),"to":_lvl(target,th,LEVEL_BODY),
			"track_node":context.get("target_node"),
			"size":Vector2(.76,2.30),"duration":.58,"travel_ratio":.62,
			"start_scale":.62,"peak_scale":1.0,"end_scale":.86,
			"dark_tint":INFERNO_EDGE,"body_tint":INFERNO_BODY,"core_tint":INFERNO_CORE,
			"flow_strength":.026,"opacity":1.0,"seed":seed
		})
	var index:=0.0
	for value in _capped_targets(context.get("targets",[])):
		var scorch:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
		if scorch!=null:
			scorch.play_layer(INFERNO_GROUND_SCORCH_TEXTURE,{
				"name":"Inferno_Scorch","position":_lvl_foot(value,th,LEVEL_FOOT),
				"size":Vector2(1.74,1.74),"ground":true,"duration":.96,
				"start_scale":.16,"peak_scale":.90,"end_scale":1.02,
				"dark_tint":INFERNO_EDGE,"body_tint":INFERNO_BODY,"core_tint":INFERNO_CORE,
				"flow_strength":.012,"opacity":.86,"delay":.40+index*.04,"seed":seed+index*7.0
			})
		var brand:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
		if brand!=null:
			brand.play_layer(INFERNO_ATK_DOWN_BRAND_TEXTURE,{
				"name":"Inferno_Brand","position":_lvl_foot(value,th,LEVEL_BODY),
				"size":Vector2(.84,1.18),"duration":.72,
				"start_scale":.10,"peak_scale":.74,"end_scale":.86,
				"dark_tint":INFERNO_EDGE,"body_tint":Color(.88,.72,.62),"core_tint":Color(1.0,.82,.52),
				"flow_strength":.016,"opacity":.82,"delay":.54+index*.04,"seed":seed+index*11.0
			})
		index+=1.0

# 深渊魔君·厄夜（41-50 血）：全场流星，无视防御。地面漩涡开场，每个敌人头顶
# 落一颗流星，落点撕开一道裂口。
func _eternal_night(origin:Vector3,context:Dictionary)->void:
	var th := _uh(context)
	var oh := _uh(context,"origin_height")
	var seed:=float(abs(int(origin.x*41.0+origin.z*23.0))%97)
	var vortex:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
	if vortex!=null:
		vortex.play_layer(ETERNAL_NIGHT_VORTEX_TEXTURE,{
			"name":"EternalNight_Vortex","position":_lvl(origin,oh,LEVEL_FOOT,0.0),
			"size":Vector2(2.34,2.34),"ground":true,"duration":1.24,
			"start_scale":.10,"peak_scale":.94,"end_scale":1.14,
			"dark_tint":Color(.05,.02,.01),"body_tint":Color(.82,.60,.44),"core_tint":Color(1.0,.62,.26),
			"flow_strength":.020,"opacity":.92,"seed":seed
		})
	var index:=0.0
	for value in _capped_targets(context.get("targets",[])):
		var meteor:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
		if meteor!=null:
			meteor.play_layer(ETERNAL_NIGHT_METEOR_TEXTURE,{
				"name":"EternalNight_Meteor",
				"from":_lvl_foot(value,th,LEVEL_SKY),"to":_lvl_foot(value,th,LEVEL_BODY),
				"size":Vector2(.74,1.82),"duration":.62,"travel_ratio":.70,
				"start_scale":.46,"peak_scale":.96,"end_scale":.78,
				"dark_tint":Color(.05,.02,.01),"body_tint":Color(.86,.64,.46),"core_tint":Color(1.0,.66,.28),
				"flow_strength":.018,"opacity":1.0,"delay":.28+index*.07,"seed":seed+index*19.0
			})
		var tear:=_block(VFX_PAINTED) as VFXBossTextureLayer3D
		if tear!=null:
			tear.play_layer(ETERNAL_NIGHT_IMPACT_TEXTURE,{
				"name":"EternalNight_Tear","position":_lvl_foot(value,th,LEVEL_BODY),
				"size":Vector2(1.44,1.50),"duration":.54,
				"start_scale":.16,"peak_scale":.92,"end_scale":.72,
				"dark_tint":Color(.05,.02,.01),"body_tint":Color(.88,.66,.48),"core_tint":Color(1.0,.68,.30),
				"flow_strength":.024,"opacity":.96,"delay":.66+index*.07,"seed":seed+index*23.0
			})
		index+=1.0

# match 的兜底分支用：一次中性的命中反馈。
func _generic_hit(target:Vector3)->void:
	var th := UNIT_HEIGHT_FALLBACK
	_spawn(VFX_IMPACT_FLASH,_profile(Color(.04,.04,.05),Color(.52,.54,.60),Color(.94,.96,1.0),.44,.32,2.6,5),{"target":_lvl(target,th,LEVEL_BODY)})

func _spawn(script:Script,profile:VFXProfile3D,context:Dictionary)->Node3D:
	var node:=_block(script)
	if node==null:return null
	last_spawned=node;node.call("play_profile",profile,context);return node

# size is scaled here so every procedural module (burst / barrier / arc / link)
# re-calibrates from the same constant as the painted layers.
func _profile(dark:Color,main:Color,core:Color,size:float,duration:float,energy:float,count:int)->VFXProfile3D:
	var p:=VFXProfile3D.new();p.dark_color=dark;p.main_color=main;p.core_color=core;p.size=VFXBlockRoot.vfx_size(size);p.duration=duration;p.emission_energy=energy;p.particle_count=count;return p

func _holy_profile(size:float,duration:float)->VFXProfile3D:return _profile(Color(.13,.055,.012),Color(.86,.44,.08),Color(1.0,.92,.58),size,duration,3.2,10)
func _shadow_profile(size:float,duration:float)->VFXProfile3D:return _profile(Color(.025,.012,.055),Color(.28,.08,.52),Color(.76,.46,1.0),size,duration,3.0,10)
func _blood_profile(size:float,duration:float)->VFXProfile3D:return _profile(Color(.065,.008,.012),Color(.58,.025,.055),Color(1.0,.22,.22),size,duration,3.0,9)
