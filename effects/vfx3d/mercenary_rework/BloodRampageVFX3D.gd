extends "res://effects/vfx3d/mercenary_rework/MercenaryVFXBase3D.gd"

var _rune: Sprite3D
var _stacks := 0
var _origin := Vector3.ZERO
var _anchor: Node3D

func start(_skill_id: String, origin: Vector3, _target: Vector3, context: Dictionary) -> void:
	_duration = -1.0
	_origin = origin
	_anchor = _origin_anchor(context)
	_rune = _sprite("blood_runes.png", origin + Vector3(0.0, 0.58, 0.0), 0.7, 0.5, _anchor, Vector3.ZERO)
	set_stacks(int(context.get("stacks", 0)))

func set_stacks(value: int) -> void:
	var next := clampi(value, 0, 9)
	if next > _stacks:
		var burst := _sprite("blood_sparks.png", _origin + Vector3(0.0, 0.52, 0.0), 0.65 + 0.06 * next, 0.96, _anchor, Vector3.ZERO)
		_fade(burst, 0.45, 0.7, 1.23)
	_stacks = next
	if _rune != null:
		_rune.visible = _stacks > 0
		_rune.scale = Vector3.ONE * (0.72 + 0.055 * _stacks)
		_rune.modulate = Color(1.0, 1.0, 1.0, minf(0.86, 0.32 + 0.065 * _stacks))
