class_name UnitActor3D
extends Node3D

const PortraitFallbackScene := preload("res://effects/runtime/presentation/UnitPortraitFallback3D.tscn")
const PortraitFallbackScript := preload("res://effects/runtime/presentation/UnitPortraitFallback3D.gd")

const DEFAULT_HEIGHT := 0.98
const HEAD_RATIO := 1.02
const CAST_RATIO := 0.66
const HIT_RATIO := 0.55
const FOOT_RATIO := 0.05

# V2 P1-04 第 4 条：近战、远程、Boss 分别配置 anchor，不允许所有角色共用同一套比例。
#
# 只有 CastAnchor 按类型分档 —— 它是投射物/法术的**出手点**，近战从身体发力、
# 远程要从抬起的弓/杖出手，Boss 体型是普通单位的两倍、出手点相对更低。
# 其余锚点（头顶图标、受击点、脚底）按身体比例走，与类型无关，分档反而会让
# 同一场里的状态图标高低不齐。
#
# 这三个数是起点，不是实测结论 —— 由用户看 1280x720 / 2640x1216 截图定。
# 改动请连 tools/unit_anchor_contract_check 的期望值一起改。
const CAST_RATIO_BY_ARCHETYPE := {
	"melee": 0.60,
	"ranged": 0.72,
	"boss": 0.62,
}

var actor_root: Node3D
var visual_root: Node3D
var portrait_fallback: PortraitFallbackScript

var _archetype := "melee"


func _init() -> void:
	_ensure_contract(DEFAULT_HEIGHT)


func configure_contract(height: float, archetype: String = "melee") -> void:
	_archetype = archetype if CAST_RATIO_BY_ARCHETYPE.has(archetype) else "melee"
	set_meta("archetype", _archetype)
	_ensure_contract(height)
	set_meta("model_height", maxf(0.4, height))


func cast_ratio() -> float:
	return float(CAST_RATIO_BY_ARCHETYPE.get(_archetype, CAST_RATIO))


func attach_model(model: Node3D) -> void:
	if model == null:
		return
	_ensure_contract(float(get_meta("model_height", DEFAULT_HEIGHT)))
	actor_root.add_child(model)
	visual_root = model
	set_meta("visual_kind", "model")


func attach_portrait_fallback(portrait_path: String, frame_path: String, team_color: Color, height: float) -> bool:
	_ensure_contract(height)
	portrait_fallback = PortraitFallbackScene.instantiate() as PortraitFallbackScript
	actor_root.add_child(portrait_fallback)
	visual_root = portrait_fallback
	set_meta("visual_kind", "portrait_fallback")
	return portrait_fallback.configure(portrait_path, frame_path, team_color, height)


func is_portrait_fallback() -> bool:
	return str(get_meta("visual_kind", "")) == "portrait_fallback"


func get_anchor(anchor_name: String) -> Node3D:
	var canonical := anchor_name
	if canonical == "FeetAnchor":
		canonical = "FootAnchor"
	elif canonical == "BodyAnchor":
		canonical = "HitAnchor"
	var node := get_node_or_null(canonical)
	return node as Node3D if node is Node3D else null


func _ensure_contract(height: float) -> void:
	var safe_height := maxf(0.4, height)
	actor_root = get_node_or_null("ActorRoot") as Node3D
	if actor_root == null:
		actor_root = Node3D.new()
		actor_root.name = "ActorRoot"
		add_child(actor_root)
	var positions := {
		"FootAnchor": Vector3(0.0, safe_height * FOOT_RATIO, 0.0),
		"HeadAnchor": Vector3(0.0, safe_height * HEAD_RATIO, 0.0),
		"CastAnchor": Vector3(0.0, safe_height * cast_ratio(), -0.04),
		"HitAnchor": Vector3(0.0, safe_height * HIT_RATIO, -0.06),
		# Compatibility aliases for accepted status effects and old capture tools.
		"FeetAnchor": Vector3(0.0, safe_height * FOOT_RATIO, 0.0),
		"BodyAnchor": Vector3(0.0, safe_height * HIT_RATIO, -0.06),
	}
	for anchor_name in positions:
		var anchor := get_node_or_null(anchor_name) as Node3D
		if anchor == null:
			anchor = Node3D.new()
			anchor.name = anchor_name
			add_child(anchor)
		anchor.position = positions[anchor_name]
	var shadow := get_node_or_null("Shadow") as Node3D
	if shadow == null:
		shadow = Node3D.new()
		shadow.name = "Shadow"
		add_child(shadow)
