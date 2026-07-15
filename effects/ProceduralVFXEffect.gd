extends Node2D
class_name ProceduralVFXEffect

@export var effect_id: String = "HIT_MELEE"

var _config: Dictionary = {}
# 对象池复用支撑：代际计数让上一轮播放遗留的 await 回调失效；
# _tweens 记录本轮创建的 tween，归还/复用时统一 kill。
var _generation := 0
var _tweens: Array[Tween] = []

func play(config: Dictionary = {}) -> void:
	_begin_play(config)
	match effect_id:
		"HIT_MELEE":
			_play_hit(Color(1.0, 0.92, 0.68), 0.9)
			_play_slash(Color(1.0, 0.96, 0.82), float(config.get("angle", 0.0)))
		"HIT_RANGED":
			_play_hit(Color(0.72, 0.9, 1.0), 0.75)
		"DEATH_EXPLOSION":
			_play_burst(Color(0.95, 0.95, 0.92), 44, 1.2)
			_play_ring(Color(0.95, 0.95, 0.92, 0.85), 18.0, 78.0, 0.42, 5.0)
		"HOLY_HEAL":
			_play_ring(Color(0.48, 1.0, 0.68, 0.92), 22.0, 58.0, 0.55, 4.0)
			_play_rise_particles(Color(0.48, 1.0, 0.68), 24)
		"HOLY_SHIELD":
			_play_disc(Color(0.42, 0.82, 1.0, 0.16), 46.0, 0.5)
			_play_ring(Color(0.48, 0.86, 1.0, 0.95), 36.0, 58.0, 0.5, 5.0)
		"LIGHTNING_STRIKE":
			_play_lightning(Color(0.72, 0.9, 1.0, 0.95))
			_play_hit(Color(0.72, 0.9, 1.0), 0.8)
		"DARK_EXPLOSION":
			_play_ring(Color(0.55, 0.26, 0.9, 0.9), 18.0, 86.0, 0.48, 7.0)
			_play_burst(Color(0.48, 0.22, 0.86), 52, 1.15)
		"BLACK_HOLE":
			_play_black_hole()
		"TELEPORT_SLASH":
			_play_slash(Color(0.82, 0.72, 1.0, 0.95), float(config.get("angle", 0.0)))
			_play_ring(Color(0.55, 0.45, 1.0, 0.6), 14.0, 48.0, 0.24, 4.0)
		"SOUL_CHAIN":
			_play_link(Color(0.7, 0.25, 1.0, 0.92))
		"GROWTH_AURA":
			_play_ring(Color(0.45, 1.0, 0.45, 0.9), 28.0, 64.0, 0.55, 4.0)
			_play_rise_particles(Color(0.42, 1.0, 0.42), 18)
		"FEAR_SKULL":
			_play_skull(Color(0.72, 0.25, 1.0, 0.92))
		"POISON_CLOUD":
			_play_poison_cloud()
		"STUN_RING":
			_play_ring(Color(0.75, 0.42, 1.0, 0.94), 24.0, 76.0, 0.42, 6.0)
			_play_stun_marks(Color(0.75, 0.42, 1.0, 0.9))
		_:
			_play_hit(Color.WHITE, 0.6)

func _begin_play(config: Dictionary) -> void:
	_generation += 1
	for tween in _tweens:
		if tween != null and tween.is_valid():
			tween.kill()
	_tweens.clear()
	_config = config
	visible = true

func _make_tween() -> Tween:
	var tween := create_tween()
	_tweens.append(tween)
	return tween

# 池化复用核心：同名子节点已存在就重置基础属性后复用，
# 不存在才创建。同一个池实例只会反复播同一种 effect_id，子节点集合稳定。
func _acquire_child(child_name: String, factory: Callable) -> Node:
	var node := get_node_or_null(child_name)
	if node == null:
		node = factory.call()
		node.name = child_name
		add_child(node)
	if node is CanvasItem:
		var canvas := node as CanvasItem
		canvas.visible = true
		canvas.modulate = Color(1, 1, 1, 1)
	if node is Node2D:
		var node_2d := node as Node2D
		node_2d.position = Vector2.ZERO
		node_2d.rotation = 0.0
		node_2d.scale = Vector2.ONE
	return node

func _acquire_particles(child_name: String) -> CPUParticles2D:
	return _acquire_child(child_name, func(): return CPUParticles2D.new()) as CPUParticles2D

func _play_hit(color: Color, scale_mul: float) -> void:
	var flash := _acquire_child("Flash", func(): return Polygon2D.new()) as Polygon2D
	flash.color = Color(color.r, color.g, color.b, 0.42)
	flash.polygon = _circle_polygon(22.0 * scale_mul, 18)

	var particles := _acquire_particles("ImpactParticles")
	var amount := int(_config.get("amount", 22))
	if particles.amount != amount:
		particles.amount = amount
	particles.lifetime = 0.24
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.direction = Vector2.UP
	particles.spread = 180.0
	particles.gravity = Vector2(0.0, 220.0)
	particles.initial_velocity_min = 55.0
	particles.initial_velocity_max = 135.0
	particles.scale_amount_min = 0.45
	particles.scale_amount_max = 1.05
	particles.color = color
	particles.restart()

	var tween := _make_tween()
	tween.set_parallel(true)
	tween.tween_property(flash, "scale", Vector2.ONE * 1.65, 0.18)
	tween.tween_property(flash, "modulate:a", 0.0, 0.18)
	_free_after(0.42)

func _play_slash(color: Color, angle: float) -> void:
	var slash := _acquire_child("Slash", func(): return Line2D.new()) as Line2D
	slash.width = float(_config.get("width", 6.0))
	slash.default_color = color
	slash.points = PackedVector2Array([
		Vector2(-42.0, 24.0),
		Vector2(-14.0, -10.0),
		Vector2(42.0, -26.0)
	])
	slash.rotation = angle
	slash.z_index = 20

	var tween := _make_tween()
	tween.set_parallel(true)
	tween.tween_property(slash, "scale", Vector2.ONE * 1.18, 0.14)
	tween.tween_property(slash, "modulate:a", 0.0, 0.2)
	_free_after(0.28)

func _play_ring(color: Color, start_radius: float, end_radius: float, duration: float, width: float) -> void:
	var ring := _acquire_child("Ring", func(): return Line2D.new()) as Line2D
	ring.width = width
	ring.closed = true
	ring.default_color = color
	ring.points = _circle_points(start_radius, 48)

	var end_points := _circle_points(end_radius, 48)
	var tween := _make_tween()
	tween.set_parallel(true)
	tween.tween_property(ring, "points", end_points, duration)
	tween.tween_property(ring, "modulate:a", 0.0, duration).set_delay(duration * 0.35)
	_free_after(duration + 0.12)

func _play_disc(color: Color, radius: float, duration: float) -> void:
	var disc := _acquire_child("Disc", func(): return Polygon2D.new()) as Polygon2D
	disc.color = color
	disc.polygon = _circle_polygon(radius, 48)
	var tween := _make_tween()
	tween.set_parallel(true)
	tween.tween_property(disc, "scale", Vector2.ONE * 1.15, duration)
	tween.tween_property(disc, "modulate:a", 0.0, duration).set_delay(duration * 0.4)

func _play_burst(color: Color, amount: int, velocity_mul: float) -> void:
	var particles := _acquire_particles("BurstParticles")
	var clamped := clampi(amount, 8, 70)
	if particles.amount != clamped:
		particles.amount = clamped
	particles.lifetime = 0.55
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.direction = Vector2.UP
	particles.spread = 180.0
	particles.gravity = Vector2(0.0, 260.0)
	particles.initial_velocity_min = 65.0 * velocity_mul
	particles.initial_velocity_max = 170.0 * velocity_mul
	particles.scale_amount_min = 0.45
	particles.scale_amount_max = 1.35
	particles.color = color
	particles.restart()
	_free_after(0.85)

func _play_rise_particles(color: Color, amount: int) -> void:
	var particles := _acquire_particles("RiseParticles")
	var clamped := clampi(amount, 8, 44)
	if particles.amount != clamped:
		particles.amount = clamped
	particles.lifetime = 0.75
	particles.one_shot = true
	particles.explosiveness = 0.75
	particles.direction = Vector2.UP
	particles.spread = 32.0
	particles.gravity = Vector2(0.0, -45.0)
	particles.initial_velocity_min = 18.0
	particles.initial_velocity_max = 58.0
	particles.scale_amount_min = 0.45
	particles.scale_amount_max = 1.1
	particles.color = color
	particles.restart()
	_free_after(1.0)

func _play_lightning(color: Color) -> void:
	var bolt := _acquire_child("Lightning", func(): return Line2D.new()) as Line2D
	bolt.width = 5.0
	bolt.default_color = color
	bolt.points = PackedVector2Array([
		Vector2(-10.0, -74.0),
		Vector2(8.0, -38.0),
		Vector2(-6.0, -10.0),
		Vector2(14.0, 22.0)
	])
	var tween := _make_tween()
	tween.tween_property(bolt, "modulate:a", 0.0, 0.18)
	_free_after(0.24)

func _play_black_hole() -> void:
	var core := _acquire_child("BlackHoleCore", func(): return Polygon2D.new()) as Polygon2D
	core.color = Color(0.08, 0.03, 0.12, 0.9)
	core.polygon = _circle_polygon(30.0, 48)
	for i in 3:
		var ring := _acquire_child("InwardRing%d" % i, func(): return Line2D.new()) as Line2D
		ring.width = 3.0
		ring.closed = true
		ring.default_color = Color(0.55, 0.26, 0.9, 0.55)
		ring.points = _circle_points(76.0 - i * 14.0, 48)
		var tween := _make_tween()
		tween.set_parallel(true)
		tween.tween_property(ring, "scale", Vector2.ONE * 0.25, 0.55)
		tween.tween_property(ring, "rotation", PI * 1.4, 0.55)
		tween.tween_property(ring, "modulate:a", 0.0, 0.55).set_delay(0.2)
	_play_burst(Color(0.55, 0.26, 0.9), 34, 0.55)
	_free_after(0.72)

func _play_link(color: Color) -> void:
	var target_position: Vector2 = _config.get("target_position", Vector2(70.0, 0.0))
	var link := _acquire_child("SoulChain", func(): return Line2D.new()) as Line2D
	link.width = 4.0
	link.default_color = color
	link.points = PackedVector2Array([Vector2.ZERO, target_position - global_position])
	var tween := _make_tween()
	tween.set_parallel(true)
	tween.tween_property(link, "width", 7.0, 0.12)
	tween.tween_property(link, "modulate:a", 0.0, 0.48).set_delay(0.18)
	_free_after(0.72)

func _play_skull(color: Color) -> void:
	var skull := _acquire_child("FearSkull", func(): return Label.new()) as Label
	skull.text = "!"
	skull.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	skull.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	skull.size = Vector2(44.0, 44.0)
	skull.position = Vector2(-22.0, -52.0)
	skull.add_theme_font_size_override("font_size", 28)
	skull.add_theme_color_override("font_color", color)
	skull.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
	skull.add_theme_constant_override("outline_size", 4)
	var tween := _make_tween()
	tween.set_parallel(true)
	tween.tween_property(skull, "position", skull.position + Vector2(0.0, -20.0), 0.42)
	tween.tween_property(skull, "modulate:a", 0.0, 0.42).set_delay(0.12)
	_free_after(0.62)

func _play_poison_cloud() -> void:
	var particles := _acquire_particles("PoisonCloud")
	if particles.amount != 36:
		particles.amount = 36
	particles.lifetime = 0.95
	particles.one_shot = true
	particles.explosiveness = 0.35
	particles.direction = Vector2.UP
	particles.spread = 90.0
	particles.gravity = Vector2(0.0, -12.0)
	particles.initial_velocity_min = 18.0
	particles.initial_velocity_max = 48.0
	particles.scale_amount_min = 1.0
	particles.scale_amount_max = 2.2
	particles.color = Color(0.35, 0.9, 0.28, 0.7)
	particles.restart()
	_free_after(1.15)

func _play_stun_marks(color: Color) -> void:
	for i in 4:
		var mark := _acquire_child("StunMark%d" % i, func(): return Line2D.new()) as Line2D
		mark.width = 3.0
		mark.default_color = color
		mark.points = PackedVector2Array([Vector2(-8.0, 0.0), Vector2(8.0, 0.0)])
		var angle := TAU * float(i) / 4.0
		mark.position = Vector2(cos(angle), sin(angle)) * 34.0
		mark.rotation = angle
	_free_after(0.52)

func _circle_points(radius: float, segments: int) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i in segments:
		var angle := TAU * float(i) / float(segments)
		points.append(Vector2(cos(angle), sin(angle)) * radius)
	return points

func _circle_polygon(radius: float, segments: int) -> PackedVector2Array:
	return _circle_points(radius, segments)

# 播完归还对象池（多次调用时最早到期的那次生效，和旧版 queue_free 行为一致）。
# 代际计数保证：归还后如果实例已被复用，旧的 await 回调直接失效。
func _free_after(seconds: float) -> void:
	var generation := _generation
	await get_tree().create_timer(seconds).timeout
	if not is_instance_valid(self) or generation != _generation:
		return
	_release_self()

func _release_self() -> void:
	_generation += 1
	for tween in _tweens:
		if tween != null and tween.is_valid():
			tween.kill()
	_tweens.clear()
	for child in get_children():
		if child is CPUParticles2D:
			(child as CPUParticles2D).emitting = false
	if has_node("/root/VFXManager"):
		VFXManager.release_effect(self)
	else:
		queue_free()
