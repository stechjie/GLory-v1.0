extends Node3D
class_name BossProceduralVFX3D

const VFXLightningArc := preload("res://effects/vfx3d/VFXLightningArc.gd")
const VFXLightningBall := preload("res://effects/vfx3d/VFXLightningBall.gd")
const BOSS_COMPOSER := preload("res://effects/vfx3d/boss/BossSkillVFXComposer3D.gd")

var _composer: BossSkillVFXComposer3D

func _ready() -> void:
	_composer = BOSS_COMPOSER.new()
	_composer.name = "BossSkillVFXComposer3D"
	add_child(_composer)

func play(skill_id: String, origin: Vector3, target: Vector3, context: Dictionary = {}) -> void:
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
			ball.play_ball(origin, target, context.get("target_node") as Node3D)
		"meteor_strike":
			_composer.play_skill("element_meteor", origin, target, context)
		_:
			_composer.play_skill(skill_id, origin, target, context)
