extends Node3D

const EFFECTS := {
	"shield": {"anchor": "BodyAnchor", "path": "res://assets/vfx/status/status_shield_aura.png", "scale": Vector3(0.86, 0.86, 0.86), "alpha": 0.62, "rot": 0.0, "bob": 0.035, "pulse": 0.035},
	"stun": {"anchor": "HeadAnchor", "path": "res://assets/vfx/status/status_stun_ring.png", "scale": Vector3(0.30, 0.30, 0.30), "alpha": 0.9, "rot": 1.4, "bob": 0.025, "pulse": 0.03},
	"poison": {"anchor": "FeetAnchor", "path": "res://assets/vfx/status/status_poison_cloud.png", "scale": Vector3(0.58, 0.58, 0.58), "alpha": 0.48, "rot": 0.12, "bob": 0.018, "pulse": 0.045},
	"burn": {"anchor": "FeetAnchor", "path": "res://assets/vfx/status/status_burn_ring.png", "scale": Vector3(0.48, 0.48, 0.48), "alpha": 0.7, "rot": 0.35, "bob": 0.012, "pulse": 0.055},
	"silence": {"anchor": "BodyAnchor", "path": "res://assets/vfx/status/status_silence_seal.png", "scale": Vector3(0.42, 0.42, 0.42), "alpha": 0.78, "rot": -0.45, "bob": 0.03, "pulse": 0.025},
	"slow": {"anchor": "FeetAnchor", "path": "res://assets/vfx/status/status_slow_frost_ring.png", "scale": Vector3(0.52, 0.52, 0.52), "alpha": 0.58, "rot": -0.25, "bob": 0.01, "pulse": 0.035},
	"bleed": {"anchor": "BodyAnchor", "path": "res://assets/vfx/status/status_bleed_body.png", "scale": Vector3(0.46, 0.46, 0.46), "alpha": 0.62, "rot": 0.18, "bob": 0.028, "pulse": 0.04},
}

# 状态图标是固定小集合，preload 到常量里——中毒/燃烧首次触发时
# 绝不能在战斗帧里同步读盘。
const STATUS_TEXTURES := {
	"shield": preload("res://assets/vfx/status/status_shield_aura.png"),
	"stun": preload("res://assets/vfx/status/status_stun_ring.png"),
	"poison": preload("res://assets/vfx/status/status_poison_cloud.png"),
	"burn": preload("res://assets/vfx/status/status_burn_ring.png"),
	"silence": preload("res://assets/vfx/status/status_silence_seal.png"),
	"slow": preload("res://assets/vfx/status/status_slow_frost_ring.png"),
	"bleed": preload("res://assets/vfx/status/status_bleed_body.png"),
}

var _sprites := {}
var _phase := randf() * TAU

func update_from_fighter(fighter: Dictionary) -> void:
	var active := {}
	active["shield"] = int(fighter.get("shield", 0)) > 0
	var statuses: Dictionary = fighter.get("statuses", {})
	for kind in ["stun", "poison", "burn", "silence", "slow", "bleed"]:
		var status: Dictionary = statuses.get(kind, {})
		active[kind] = float(status.get("remaining", 0.0)) > 0.0
	for kind in EFFECTS.keys():
		_set_effect_visible(kind, bool(active.get(kind, false)))

func _process(_delta: float) -> void:
	var t := float(Time.get_ticks_msec()) * 0.001 + _phase
	for kind in _sprites.keys():
		var sprite := _sprites[kind] as Sprite3D
		if sprite == null or not sprite.visible:
			continue
		var cfg: Dictionary = EFFECTS[kind]
		var pulse := 1.0 + sin(t * 2.1 + float(kind.length())) * float(cfg.pulse)
		sprite.scale = (cfg.scale as Vector3) * pulse
		sprite.position.y = sin(t * 1.6 + float(kind.length())) * float(cfg.bob)
		sprite.rotation.z += float(cfg.rot) * _delta
		sprite.modulate.a = float(cfg.alpha) * (0.9 + 0.1 * sin(t * 2.7 + float(kind.length())))

func _set_effect_visible(kind: String, visible: bool) -> void:
	var sprite := _sprites.get(kind) as Sprite3D
	if sprite == null:
		if not visible:
			return
		sprite = _make_sprite(kind)
		_sprites[kind] = sprite
	sprite.visible = visible

func _make_sprite(kind: String) -> Sprite3D:
	var cfg: Dictionary = EFFECTS[kind]
	var anchor := _anchor(str(cfg.anchor))
	var sprite := Sprite3D.new()
	sprite.name = "Status_%s" % kind
	sprite.texture = STATUS_TEXTURES.get(kind)
	sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sprite.pixel_size = 0.00145
	sprite.modulate = Color(1, 1, 1, float(cfg.alpha))
	sprite.scale = cfg.scale
	sprite.transparent = true
	sprite.no_depth_test = false
	sprite.shaded = false
	anchor.add_child(sprite)
	return sprite

func _anchor(anchor_name: String) -> Node3D:
	var existing := get_parent().get_node_or_null(anchor_name)
	if existing is Node3D:
		return existing as Node3D
	var anchor := Node3D.new()
	anchor.name = anchor_name
	match anchor_name:
		"HeadAnchor":
			anchor.position = Vector3(0.0, 1.55, 0.0)
		"BodyAnchor":
			anchor.position = Vector3(0.0, 0.85, -0.06)
		_:
			anchor.position = Vector3(0.0, 0.08, 0.0)
	get_parent().add_child(anchor)
	return anchor
