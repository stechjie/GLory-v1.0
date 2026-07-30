extends Node

const EffectDatabase := preload("res://effects/EffectDatabase.gd")
const QUALITY := preload("res://effects/vfx3d/core/VFXQualityBudget.gd")

# 所有加法/普通混合的 VFX 精灵共用这两份材质，避免每个特效实例 new 一份。
static var MAT_ADD: CanvasItemMaterial = _make_blend_material(CanvasItemMaterial.BLEND_MODE_ADD)
static var MAT_MIX: CanvasItemMaterial = _make_blend_material(CanvasItemMaterial.BLEND_MODE_MIX)

var _hitstop_until_msec := 0
var _shake_until_msec := 0
var _shake_strength := 0.0
var _camera: Camera2D
var _camera_base_offset := Vector2.ZERO
# 战斗中 VFX 贴图必须提前进内存：命中/技能时才同步 load 会造成可感顿挫。
var _texture_cache: Dictionary = {}
var _pending_texture_loads: Array[String] = []

static func _make_blend_material(mode: int) -> CanvasItemMaterial:
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = mode as CanvasItemMaterial.BlendMode
	return mat

func _ready() -> void:
	_detect_quality_tier()

func _process(_delta: float) -> void:
	_update_screen_shake()
	_drain_pending_texture_loads()

# VFXQualityBudget.tier 以前永远停在编译期的 MEDIUM，没有任何机型判断，
# 等于桌面和低端安卓跑同一套预算。这里在启动时定一次档。
# 玩家在设置里手动选的档位（-1 = 未选，走自动判定）。存盘，启动时应用。
const QUALITY_PREF_PATH := "user://glory_quality_tier.txt"

func _detect_quality_tier() -> void:
	# 玩家手选的优先级最高，自动判定永远不覆盖它。
	var saved := _load_quality_pref()
	if saved >= 0:
		QUALITY.tier = clampi(saved, QUALITY.Tier.LOW, QUALITY.Tier.HIGH)
		return
	if not OS.has_feature("mobile"):
		QUALITY.tier = QUALITY.Tier.HIGH
		return
	# 按总内存分档，不再按核心数。
	#
	# 旧写法是 `OS.get_processor_count() <= 4 -> LOW`，但实测 Redmi A5 是 **8 核**
	# 却是市面上最低端的一档（Unisoc T7250 / Mali-G57 单核 / 3.9 GB），于是被判成
	# MEDIUM —— 而当时 MEDIUM 的 particle_count 系数是 1.0，等于一点没减。
	# 核心数在低端安卓上根本不反映性能；内存和它的相关性好得多，也直接对应
	# 实测到的硬约束（显存峰值 1180 MB / 整机 3.9 GB）。
	var total_mb := _total_memory_mb()
	if total_mb > 0:
		QUALITY.tier = QUALITY.Tier.LOW if total_mb < 4096 else QUALITY.Tier.MEDIUM
	else:
		# 读不到内存信息时保守走 LOW：宁可画面简单也不要卡。
		QUALITY.tier = QUALITY.Tier.LOW
	# 把判定过程打出来：OS.get_memory_info() 在安卓上是否返回有效的 physical
	# 无法在桌面验证（桌面走 HIGH 分支就返回了）。如果日志里 totalMB=0，
	# 说明这条判据在安卓上失效、所有机型都会落到 LOW，需要换判据。
	print("[QUALITY] 自动判定 tier=%d  totalMB=%d  cores=%d" % [
		QUALITY.tier, total_mb, OS.get_processor_count()])

func _total_memory_mb() -> int:
	var info := OS.get_memory_info()
	for key in ["physical", "total"]:
		var v := int(info.get(key, 0))
		if v > 0:
			return v / 1048576
	return 0

func set_quality_pref(value: int) -> void:
	QUALITY.tier = clampi(value, QUALITY.Tier.LOW, QUALITY.Tier.HIGH)
	var f := FileAccess.open(QUALITY_PREF_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(str(QUALITY.tier))
		f.close()

func _load_quality_pref() -> int:
	if not FileAccess.file_exists(QUALITY_PREF_PATH):
		return -1
	var f := FileAccess.open(QUALITY_PREF_PATH, FileAccess.READ)
	if f == null:
		return -1
	var text := f.get_as_text().strip_edges()
	f.close()
	return int(text) if text.is_valid_int() else -1

# 调试/设置面板用：允许手动压档验证低端表现。
func set_quality_tier(value: int) -> void:
	QUALITY.tier = clampi(value, QUALITY.Tier.LOW, QUALITY.Tier.HIGH)

func get_quality_tier() -> int:
	return QUALITY.tier

# 同步取贴图（带缓存）。预载过的路径这里是纯字典查找。
func get_texture(path: String) -> Texture2D:
	if path.is_empty():
		return null
	var cached: Texture2D = _texture_cache.get(path)
	if cached != null:
		return cached
	# A background load may already be in flight for this path. Harvesting it is
	# far cheaper than ResourceLoader.load(), which would kick off a SECOND, cold
	# read of the same file while the worker thread is still reading it.
	# Remove it from the pending list so _drain_pending_texture_loads() never
	# calls load_threaded_get() on the same path twice.
	var pending_index := _pending_texture_loads.find(path)
	if pending_index >= 0:
		_pending_texture_loads.remove_at(pending_index)
		var pending_tex := ResourceLoader.load_threaded_get(path) as Texture2D
		if pending_tex != null:
			_texture_cache[path] = pending_tex
		return pending_tex
	var tex := ResourceLoader.load(path) as Texture2D
	if tex != null:
		_texture_cache[path] = tex
	return tex

# 开战前调用：把本场会用到的 VFX 贴图丢给后台线程加载，
# _process 里逐个收割进缓存。加载没赶上时 get_texture 会同步兜底（等于现状）。
func preload_textures(paths: Array) -> void:
	for p in paths:
		var path := str(p)
		if path.is_empty() or _texture_cache.has(path) or _pending_texture_loads.has(path):
			continue
		if ResourceLoader.load_threaded_request(path) == OK:
			_pending_texture_loads.append(path)

# 还有多少张贴图在后台加载中。备战期的读条用它判断"资源齐了没"，
# 这样等待是逐帧轮询、进度条能一直走，而不是阻塞在 load_threaded_get() 上。
func pending_texture_count() -> int:
	return _pending_texture_loads.size()

func _drain_pending_texture_loads() -> void:
	if _pending_texture_loads.is_empty():
		return
	for i in range(_pending_texture_loads.size() - 1, -1, -1):
		var path := _pending_texture_loads[i]
		var status := ResourceLoader.load_threaded_get_status(path)
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			var tex := ResourceLoader.load_threaded_get(path) as Texture2D
			if tex != null:
				_texture_cache[path] = tex
			_pending_texture_loads.remove_at(i)
		elif status != ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			_pending_texture_loads.remove_at(i)

# 每种特效的并发上限：AoE 密集回合的兜底，超限直接跳过生成
# （玩家看不出少一两个命中闪光，但帧率保得住）。
const EFFECT_CAPS := {
	"DEATH_EXPLOSION": 8,
	"SKILL_TEXTURE": 12,
	"PROJECTILE_ARROW": 14,
	"PROJECTILE_MAGIC": 14,
}
const EFFECT_CAP_DEFAULT := 8

# 命中类特效（ProceduralVFXEffect）用对象池复用，其余类型仍自生自灭、只受上限约束。
var _effect_pools: Dictionary = {}   # vfx_id -> Array[Node2D]（空闲、隐藏、仍在树上）
var _active_counts: Dictionary = {}  # vfx_id -> 活跃数量

func spawn_vfx(vfx_id: String, world_position: Vector2, config: Dictionary = {}) -> Node2D:
	if _at_effect_cap(vfx_id):
		return null
	var effect := _acquire_effect(vfx_id)
	if effect == null:
		return null
	effect.global_position = world_position
	if _has_property(effect, "effect_id"):
		effect.set("effect_id", vfx_id)
	_mark_effect_active(vfx_id, effect)
	if effect.has_method("play"):
		effect.play(config)
	return effect

func _at_effect_cap(vfx_id: String) -> bool:
	return int(_active_counts.get(vfx_id, 0)) >= int(EFFECT_CAPS.get(vfx_id, EFFECT_CAP_DEFAULT))

func _acquire_effect(vfx_id: String) -> Node2D:
	var pool: Array = _effect_pools.get(vfx_id, [])
	while not pool.is_empty():
		var pooled = pool.pop_back()
		# 场景切换会把 FX 层连同池里的节点一起销毁，取用时必须验活。
		if pooled != null and is_instance_valid(pooled) and (pooled as Node).is_inside_tree():
			(pooled as CanvasItem).visible = true
			return pooled as Node2D
	var scene := EffectDatabase.get_scene(vfx_id)
	if scene == null:
		push_warning("VFX scene not found: %s" % vfx_id)
		return null
	var effect := scene.instantiate() as Node2D
	if effect == null:
		push_warning("VFX root is not Node2D: %s" % vfx_id)
		return null
	_get_parent().add_child(effect)
	return effect

# 特效播完后归还（目前只有 ProceduralVFXEffect 走这里）。
func release_effect(effect: Node2D) -> void:
	if effect == null or not is_instance_valid(effect):
		return
	_mark_effect_inactive(effect)
	var id := str(effect.get("effect_id")) if _has_property(effect, "effect_id") else ""
	if id.is_empty() or not (effect is ProceduralVFXEffect) or not effect.is_inside_tree():
		effect.queue_free()
		return
	effect.visible = false
	var pool: Array = _effect_pools.get_or_add(id, [])
	if pool.size() >= int(EFFECT_CAPS.get(id, EFFECT_CAP_DEFAULT)):
		effect.queue_free()
		return
	pool.append(effect)

func _mark_effect_active(vfx_id: String, effect: Node) -> void:
	_active_counts[vfx_id] = int(_active_counts.get(vfx_id, 0)) + 1
	effect.set_meta("vfx_active_id", vfx_id)
	# 自由自灭的特效（queue_free 自己）靠 tree_exited 归还计数。
	if not effect.tree_exited.is_connected(_on_effect_tree_exited):
		effect.tree_exited.connect(_on_effect_tree_exited.bind(effect))

func _mark_effect_inactive(effect: Node) -> void:
	if not effect.has_meta("vfx_active_id"):
		return
	var id := str(effect.get_meta("vfx_active_id"))
	effect.remove_meta("vfx_active_id")
	_active_counts[id] = maxi(0, int(_active_counts.get(id, 0)) - 1)

func _on_effect_tree_exited(effect: Node) -> void:
	if is_instance_valid(effect):
		_mark_effect_inactive(effect)

func spawn_vfx_attached(vfx_id: String, target_node: Node, config: Dictionary = {}) -> Node2D:
	if target_node == null or not is_instance_valid(target_node):
		return null
	return spawn_vfx(vfx_id, _node_world_position(target_node, str(config.get("anchor", "HitAnchor"))), config)

func spawn_projectile_vfx(vfx_id: String, start_position: Vector2, target_node: Node, config: Dictionary = {}) -> Node2D:
	if _at_effect_cap(vfx_id):
		return null
	var scene := EffectDatabase.get_scene(vfx_id)
	if scene == null:
		push_warning("Projectile VFX scene not found: %s" % vfx_id)
		return null
	var projectile := scene.instantiate() as Node2D
	if projectile == null:
		return null
	_get_parent().add_child(projectile)
	_mark_effect_active(vfx_id, projectile)
	projectile.global_position = start_position
	config["effect_id"] = vfx_id
	config["target_node"] = target_node
	if not config.has("target_position") and target_node != null and is_instance_valid(target_node):
		config["target_position"] = _node_world_position(target_node, str(config.get("target_anchor", "HitAnchor")))
	if projectile.has_method("play"):
		projectile.play(config)
	return projectile

func play_hitstop(duration: float) -> void:
	_hitstop_until_msec = maxi(_hitstop_until_msec, Time.get_ticks_msec() + int(round(duration * 1000.0)))

func is_hitstop_active() -> bool:
	return Time.get_ticks_msec() < _hitstop_until_msec

func play_screen_shake(strength: float, duration: float) -> void:
	_shake_strength = maxf(_shake_strength, strength)
	_shake_until_msec = maxi(_shake_until_msec, Time.get_ticks_msec() + int(round(duration * 1000.0)))

func set_camera(camera: Camera2D) -> void:
	_camera = camera
	if _camera != null:
		_camera_base_offset = _camera.offset

func _update_screen_shake() -> void:
	if _camera == null or not is_instance_valid(_camera):
		_camera = get_viewport().get_camera_2d()
		if _camera != null:
			_camera_base_offset = _camera.offset
	if _camera == null:
		return
	if Time.get_ticks_msec() >= _shake_until_msec:
		_camera.offset = _camera_base_offset
		_shake_strength = 0.0
		return
	_camera.offset = _camera_base_offset + Vector2(randf_range(-_shake_strength, _shake_strength), randf_range(-_shake_strength, _shake_strength))

func _node_world_position(node: Node, anchor_name := "") -> Vector2:
	if not anchor_name.is_empty():
		var anchor := node.get_node_or_null(anchor_name)
		if anchor is Node2D:
			return (anchor as Node2D).global_position
		if anchor is Control:
			var c := anchor as Control
			return c.global_position + c.size * 0.5
	if node is Node2D:
		return (node as Node2D).global_position
	if node is Control:
		var c := node as Control
		return c.global_position + c.size * 0.5
	return Vector2.ZERO

func _has_property(object: Object, property_name: String) -> bool:
	for item in object.get_property_list():
		if str(item.get("name", "")) == property_name:
			return true
	return false

func _get_parent() -> Node:
	var scene := get_tree().current_scene
	if scene == null:
		scene = get_tree().root
	var layer_name := "BattleFXLayer" if scene.name.contains("Battle") else "WorldFXLayer"
	var layer := scene.get_node_or_null(layer_name)
	if layer == null:
		layer = Node2D.new()
		layer.name = layer_name
		scene.add_child(layer)
		if layer is CanvasItem:
			(layer as CanvasItem).z_index = 80
	return layer
