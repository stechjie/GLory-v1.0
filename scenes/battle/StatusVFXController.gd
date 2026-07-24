extends Node3D

const VFX_STATUS_EFFECT:=preload("res://effects/vfx3d/modules/VFXStatusEffect3D.gd")
# Status icons are persistent gameplay state, not one-shot hit bursts.  Keep
# them on the existing readable logo textures so players can identify them at
# the current distant camera angle.
const PROCEDURAL_STATUS_ANCHORS:={}

const EFFECTS := {
	"shield": {"anchor": "BodyAnchor", "path": "res://assets/vfx/status/status_shield_aura.png", "scale": Vector3(0.86, 0.86, 0.86), "alpha": 0.62, "rot": 0.0, "bob": 0.035, "pulse": 0.035},
	"stun": {"anchor": "HeadAnchor", "path": "res://assets/vfx/status/status_stun_icon_v2.png", "scale": Vector3(0.50, 0.50, 0.50), "alpha": 1.0, "rot": 0.0, "bob": 0.018, "pulse": 0.045},
	"poison": {"anchor": "HeadAnchor", "path": "res://assets/vfx/status/status_poison_icon_v2.png", "scale": Vector3(0.66, 0.66, 0.66), "alpha": 1.0, "rot": 0.0, "bob": 0.035, "pulse": 0.075},
	"burn": {"anchor": "HeadAnchor", "path": "res://assets/vfx/status/status_burn_icon_v2.png", "scale": Vector3(0.58, 0.58, 0.58), "alpha": 1.0, "rot": 0.0, "bob": 0.025, "pulse": 0.07},
	"silence": {"anchor": "HeadAnchor", "path": "res://assets/vfx/status/status_silence_icon_v2.png", "scale": Vector3(0.68, 0.68, 0.68), "alpha": 1.0, "rot": 0.0, "bob": 0.03, "pulse": 0.06},
	"slow": {"anchor": "HeadAnchor", "path": "res://assets/vfx/status/status_slow_icon_v2.png", "scale": Vector3(0.58, 0.58, 0.58), "alpha": 1.0, "rot": 0.0, "bob": 0.025, "pulse": 0.06},
	"bleed": {"anchor": "HeadAnchor", "path": "res://assets/vfx/status/status_bleed_icon_v2.png", "scale": Vector3(0.58, 0.58, 0.58), "alpha": 1.0, "rot": 0.0, "bob": 0.025, "pulse": 0.07},
	"attack_down": {"anchor": "HeadAnchor", "path": "res://assets/vfx/status/status_attack_down_icon_v2.png", "scale": Vector3(0.56, 0.56, 0.56), "alpha": 1.0, "rot": 0.0, "bob": 0.025, "pulse": 0.06},
	"interrupt": {"anchor": "HeadAnchor", "path": "res://assets/vfx/status/status_interrupt_icon_v2.png", "scale": Vector3(0.56, 0.56, 0.56), "alpha": 1.0, "rot": 0.0, "bob": 0.025, "pulse": 0.06},
	"defense_down": {"anchor": "HeadAnchor", "path": "res://assets/vfx/status/status_defense_down_icon_v2.png", "scale": Vector3(0.60, 0.60, 0.60), "alpha": 1.0, "rot": 0.0, "bob": 0.025, "pulse": 0.06},
	"defense_flat_down": {"anchor": "HeadAnchor", "path": "res://assets/vfx/status/status_defense_down_icon_v2.png", "scale": Vector3(0.52, 0.52, 0.52), "alpha": 0.92, "rot": 0.0, "bob": 0.025, "pulse": 0.055},
	"heal_reduction": {"anchor": "HeadAnchor", "path": "res://assets/vfx/status/status_heal_reduction_icon_v2.png", "scale": Vector3(0.58, 0.58, 0.58), "alpha": 1.0, "rot": 0.0, "bob": 0.025, "pulse": 0.06},
	"ice_vulnerable": {"anchor": "HeadAnchor", "path": "res://assets/vfx/status/status_ice_vulnerable_icon_v2.png", "scale": Vector3(0.56, 0.56, 0.56), "alpha": 1.0, "rot": 0.0, "bob": 0.025, "pulse": 0.06},
	"ice_affected": {"anchor": "HeadAnchor", "path": "res://assets/vfx/status/status_ice_affected_icon_v2.png", "scale": Vector3(0.56, 0.56, 0.56), "alpha": 1.0, "rot": 0.0, "bob": 0.025, "pulse": 0.06},
	"fear": {"anchor": "HeadAnchor", "path": "res://assets/vfx/status/status_fear_icon_v2.png", "scale": Vector3(0.62, 0.62, 0.62), "alpha": 1.0, "rot": 0.0, "bob": 0.025, "pulse": 0.08},
}

# 状态图标是固定小集合，preload 到常量里——中毒/燃烧首次触发时
# 绝不能在战斗帧里同步读盘。
const STATUS_TEXTURES := {
	"shield": preload("res://assets/vfx/status/status_shield_aura.png"),
	"stun": preload("res://assets/vfx/status/status_stun_icon_v2.png"),
	"poison": preload("res://assets/vfx/status/status_poison_icon_v2.png"),
	"burn": preload("res://assets/vfx/status/status_burn_icon_v2.png"),
	"silence": preload("res://assets/vfx/status/status_silence_icon_v2.png"),
	"slow": preload("res://assets/vfx/status/status_slow_icon_v2.png"),
	"bleed": preload("res://assets/vfx/status/status_bleed_icon_v2.png"),
	"attack_down": preload("res://assets/vfx/status/status_attack_down_icon_v2.png"),
	"interrupt": preload("res://assets/vfx/status/status_interrupt_icon_v2.png"),
	"defense_down": preload("res://assets/vfx/status/status_defense_down_icon_v2.png"),
	"defense_flat_down": preload("res://assets/vfx/status/status_defense_down_icon_v2.png"),
	"heal_reduction": preload("res://assets/vfx/status/status_heal_reduction_icon_v2.png"),
	"ice_vulnerable": preload("res://assets/vfx/status/status_ice_vulnerable_icon_v2.png"),
	"ice_affected": preload("res://assets/vfx/status/status_ice_affected_icon_v2.png"),
	"fear": preload("res://assets/vfx/status/status_fear_icon_v2.png"),
}

var _sprites := {}
var _procedural_statuses:={}
var _phase := randf() * TAU
# Kinds currently visible. Iterating this array allocates nothing, unlike
# _sprites.keys() which built a fresh Array every frame, for every unit.
var _active_kinds: Array[String] = []
# 同一时刻挂在头顶的图标以前全叠在 HeadAnchor 的同一点，第二个以后完全看不见。
# 这里给每个头顶图标算一个水平槽位，以头顶为中心左右摊开。
# kind -> 目标 x 偏移（世界单位），在 _process 里应用。
var _slot_x := {}
# 相邻图标的水平间距。图标本身约 0.5–0.7 宽，这个间距刚好不重叠又不散开。
const STATUS_SLOT_SPACING := 0.42

func _ready() -> void:
	# Most units carry no status effect most of the time; stay idle until one shows.
	set_process(false)

func update_from_fighter(fighter: Dictionary) -> void:
	var active := {}
	active["shield"] = int(fighter.get("shield", 0)) > 0
	var statuses: Dictionary = fighter.get("statuses", {})
	var remaining_by_kind:={}
	for kind in ["stun", "poison", "burn", "silence", "slow", "bleed", "attack_down", "interrupt", "defense_down", "defense_flat_down", "heal_reduction", "ice_vulnerable", "ice_affected", "fear"]:
		var status: Dictionary = statuses.get(kind, {})
		var remaining:=float(status.get("remaining",0.0))
		active[kind] = remaining > 0.0
		remaining_by_kind[kind]=remaining
	for kind in EFFECTS.keys():
		_set_effect_visible(kind, bool(active.get(kind, false)))

func _process(delta: float) -> void:
	var t := float(Time.get_ticks_msec()) * 0.001 + _phase
	for kind in _active_kinds:
		var sprite := _sprites[kind] as Sprite3D
		if sprite == null:
			continue
		var cfg: Dictionary = EFFECTS[kind]
		var pulse := 1.0 + sin(t * 2.1 + float(kind.length())) * float(cfg.pulse)
		sprite.scale = (cfg.scale as Vector3) * pulse
		sprite.position.x = float(_slot_x.get(kind, 0.0))
		sprite.position.y = sin(t * 1.6 + float(kind.length())) * float(cfg.bob)
		sprite.rotation.z += float(cfg.rot) * delta
		sprite.modulate.a = float(cfg.alpha) * (0.9 + 0.1 * sin(t * 2.7 + float(kind.length())))

func _set_effect_visible(kind: String, visible: bool) -> void:
	var sprite := _sprites.get(kind) as Sprite3D
	if sprite == null:
		if not visible:
			return
		sprite = _make_sprite(kind)
		if sprite == null:
			return
		_sprites[kind] = sprite
	sprite.visible = visible
	var index := _active_kinds.find(kind)
	var changed := false
	if visible and index < 0:
		_active_kinds.append(kind)
		changed = true
	elif not visible and index >= 0:
		_active_kinds.remove_at(index)
		changed = true
	if changed:
		_relayout_slots()
	# Only animate while something is actually on screen.
	set_process(not _active_kinds.is_empty())

# 头顶图标以头顶为中心横向排开：N 个图标时，第 i 个 x = (i - (N-1)/2) * 间距。
# 只排头顶（HeadAnchor）图标；shield 挂在 BodyAnchor，是独立的，不参与。
func _relayout_slots() -> void:
	var head_kinds: Array[String] = []
	for kind in _active_kinds:
		if str((EFFECTS[kind] as Dictionary).anchor) == "HeadAnchor":
			head_kinds.append(kind)
	_slot_x.clear()
	var count := head_kinds.size()
	if count <= 1:
		return
	var center := float(count - 1) * 0.5
	for i in range(count):
		_slot_x[head_kinds[i]] = (float(i) - center) * STATUS_SLOT_SPACING

func _set_procedural_status(kind:String,active:bool,remaining:float)->void:
	if not PROCEDURAL_STATUS_ANCHORS.has(kind):
		return
	var current=_procedural_statuses.get(kind)
	if current!=null and not is_instance_valid(current):
		_procedural_statuses.erase(kind);current=null
	if not active:
		if current!=null:
			current.stop_vfx(true)
			_procedural_statuses.erase(kind)
		return
	if current!=null:return
	var anchor:=_anchor(str(PROCEDURAL_STATUS_ANCHORS[kind]))
	var effect:=VFX_STATUS_EFFECT.new()
	effect.name="ProceduralStatus_%s"%kind
	anchor.add_child(effect)
	var profile:=VFXProfile3D.new()
	profile.size=.52 if kind!="poison" else .62
	profile.duration=maxf(.45,remaining)
	profile.particle_count=7
	profile.emission_energy=2.6
	profile.parameters={"status_type":kind}
	effect.play_profile(profile,{"target":Vector3.ZERO})
	_procedural_statuses[kind]=effect

func _make_sprite(kind: String) -> Sprite3D:
	if get_parent() == null or not is_instance_valid(get_parent()):
		return null
	var cfg: Dictionary = EFFECTS[kind]
	var anchor := _anchor(str(cfg.anchor))
	var sprite := Sprite3D.new()
	sprite.name = "Status_%s" % kind
	sprite.texture = STATUS_TEXTURES.get(kind)
	sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	# Keep the icon head-mounted and readable in the 1280x720 distant camera;
	# it is still much smaller than a unit and never becomes a world burst.
	sprite.pixel_size = 0.00160 if kind == "stun" else 0.00145
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
