extends Node3D
class_name BossProceduralVFX3D

const VFXLightningArc := preload("res://effects/vfx3d/VFXLightningArc.gd")
const VFXLightningBall := preload("res://effects/vfx3d/VFXLightningBall.gd")
const BOSS_COMPOSER := preload("res://effects/vfx3d/boss/BossSkillVFXComposer3D.gd")
const UNIT_COMPOSER := preload("res://effects/vfx3d/units/UnitSkillVFXComposer3D.gd")

const UNIT_SKILLS := [
	"lowest_ally_heal", "nearest_ally_bless", "nearby_ally_heal_buff",
	"random_attribute_bolt", "judgement_strike", "random_ally_damage_reduction",
	"global_divine_blast", "silence_bolt", "fear", "stun", "black_hole",
	"blink_low_def_backline", "shared_hp_link", "front_cone_stun",
	"guardian_shield_taunt", "true_damage_attack", "curse_attack",
	"same_target_damage_stack", "poison_attack", "defense_down_attack",
	"every_fourth_combo", "every_fifth_group_heal", "death_poison_explosion",
	"poison_reflect_armor_stack", "parasite_on_kill", "left_neighbor_sacrifice",
	"attack_interrupt",
	"basic_attack_ranged_god", "basic_attack_melee_god",
	"basic_attack_ranged_human", "basic_attack_melee_human",
	"basic_attack_ranged_dark", "basic_attack_melee_dark",
	"basic_attack_ranged_undead", "basic_attack_melee_undead",
	"unique_death_execute", "unique_king_growth",
	# 佣兵（data/mercenary/mercenaries.json）。UnitSkillVFXComposer3D 里
	# 一直有这 12 个技能的实现，但它们没写进这张路由表，于是全都被派给了
	# BossSkillVFXComposer3D —— 那边没有对应分支，结果是静默无表现。
	"bubble_dream", "shell_guard", "balance_judge", "gold_charge", "holy_song",
	"twin_strike", "king_aura", "arrow_rain", "blood_rampage", "steel_order",
	"time_slow", "death_hunt",
	# PVE 怪物（data/pve/pve_monsters.json）
	"chain_lightning", "dive_backline", "heal_allies", "holy_shield_burst",
	"wind_bleed", "slow_aura", "stun_impact", "entangle", "burrow_ambush",
	"lava_burst", "nature_heal", "earth_slam", "backstab", "curse",
	"counter_slash",
	# 阵型盟友（data/formation/formation_allies.json）
	"burn_claw", "soul_chain", "devour_bite", "hell_burst", "eternal_night",
]

var _composer: BossSkillVFXComposer3D
var _unit_composer: UnitSkillVFXComposer3D

func _ready() -> void:
	_composer = BOSS_COMPOSER.new()
	_composer.name = "BossSkillVFXComposer3D"
	add_child(_composer)
	_unit_composer = UNIT_COMPOSER.new()
	_unit_composer.name = "UnitSkillVFXComposer3D"
	add_child(_unit_composer)

func play(skill_id: String, origin: Vector3, target: Vector3, context: Dictionary = {}) -> Node3D:
	if skill_id in UNIT_SKILLS:
		return _unit_composer.play_skill(skill_id, origin, target, context)
	match skill_id:
		"lightning_strike":
			var arc := VFXLightningArc.new()
			arc.name = "LightningArc"
			add_child(arc)
			arc.play_arc(target + Vector3(0.0, 2.85, 0.0), target)
		"lightning_ball":
			var ball := VFXLightningBall.new()
			ball.name = "LightningBall"
			add_child(ball)
			ball.play_ball(origin, target, context.get("target_node"))
		"meteor_strike":
			_composer.play_skill("element_meteor", origin, target, context)
		_:
			_composer.play_skill(skill_id, origin, target, context)
	return null
