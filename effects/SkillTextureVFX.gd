extends Node2D

const BATTLE_SKILL_TEXTURE_SCALE_MUL := 0.62
const BATTLE_SKILL_TEXTURE_ALPHA_MUL := 0.68
const BATTLE_SKILL_GLOW_ALPHA_MUL := 0.45

func play(config: Dictionary = {}) -> void:
	var textures: Array = config.get("textures", [])
	var base_dur := float(config.get("duration", 0.5))
	var max_end := base_dur

	for tex_cfg in textures:
		var path := str(tex_cfg.get("path", ""))
		if path.is_empty():
			continue
		var texture := VFXManager.get_texture(path)
		if texture == null:
			push_warning("SkillTextureVFX: texture missing %s" % path)
			continue

		var delay := float(tex_cfg.get("delay", 0.0))
		var dur := float(tex_cfg.get("duration", base_dur))
		var sc := float(tex_cfg.get("scale", 0.5)) * BATTLE_SKILL_TEXTURE_SCALE_MUL
		var role := str(tex_cfg.get("role", "hit"))
		var alpha := clampf(float(tex_cfg.get("alpha", 1.0)) * BATTLE_SKILL_TEXTURE_ALPHA_MUL, 0.0, 0.72)
		var offset: Vector2 = tex_cfg.get("offset", Vector2.ZERO)
		var drift: Vector2 = tex_cfg.get("drift", Vector2.ZERO)
		var target_scale := _target_scale(sc, bool(tex_cfg.get("flatten", false)))

		_spawn_layer(texture, tex_cfg, offset, target_scale, delay, dur, alpha, drift)
		_spawn_particles(int(tex_cfg.get("particles", 0)), role, delay, dur)
		max_end = maxf(max_end, delay + dur)

	_free_after(max_end + 0.25)

func _spawn_layer(texture: Texture2D, tex_cfg: Dictionary, offset: Vector2, target_scale: Vector2, delay: float, dur: float, alpha: float, drift: Vector2) -> void:
	var role := str(tex_cfg.get("role", "hit"))
	var spin := float(tex_cfg.get("spin", 0.0))
	var start_scale := target_scale * (0.35 if role == "hit" else 0.55)
	var fade_in := minf(0.16, dur * 0.25)
	var fade_out := minf(0.35, dur * 0.35)
	var hold_start := maxf(0.0, dur - fade_out)

	if bool(tex_cfg.get("glow", true)):
		var glow := Sprite2D.new()
		glow.texture = texture
		glow.position = offset
		glow.scale = start_scale * 1.18
		glow.modulate = Color(1.0, 0.94, 0.72, 0.0)
		glow.z_index = 24
		glow.material = _add_material()
		add_child(glow)
		var glow_tween := create_tween()
		glow_tween.set_parallel(true)
		glow_tween.tween_property(glow, "modulate:a", alpha * BATTLE_SKILL_GLOW_ALPHA_MUL, fade_in).set_delay(delay)
		glow_tween.tween_property(glow, "scale", target_scale * 1.12, dur * 0.35).set_delay(delay)
		glow_tween.tween_property(glow, "position", offset + drift, dur).set_delay(delay)
		glow_tween.tween_property(glow, "modulate:a", 0.0, fade_out).set_delay(delay + hold_start)

	var sprite := Sprite2D.new()
	sprite.texture = texture
	sprite.position = offset
	sprite.scale = start_scale
	sprite.modulate.a = 0.0
	sprite.z_index = 25 if role != "foot" else 18
	sprite.material = _add_material()
	add_child(sprite)

	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(sprite, "modulate:a", alpha, fade_in).set_delay(delay)
	tween.tween_property(sprite, "scale", target_scale, minf(0.22, dur * 0.35)).set_delay(delay)
	tween.tween_property(sprite, "position", offset + drift, dur).set_delay(delay)
	if absf(spin) > 0.001:
		tween.tween_property(sprite, "rotation", sprite.rotation + spin * TAU, dur).set_delay(delay)
	tween.tween_property(sprite, "modulate:a", 0.0, fade_out).set_delay(delay + hold_start)

func _spawn_particles(count: int, role: String, delay: float, dur: float) -> void:
	if count <= 0:
		return
	for i in count:
		var dot := Polygon2D.new()
		dot.polygon = _circle_polygon(randf_range(1.6, 3.4), 8)
		dot.color = _particle_color(role)
		dot.modulate.a = 0.0
		dot.position = Vector2(randf_range(-8.0, 8.0), randf_range(-8.0, 8.0))
		dot.z_index = 27
		add_child(dot)

		var drift := _particle_drift(role)
		var life := minf(0.55, maxf(0.22, dur * 0.45))
		var start_delay := delay + randf_range(0.0, minf(0.12, dur * 0.25))
		var tween := create_tween()
		tween.set_parallel(true)
		tween.tween_property(dot, "modulate:a", 0.55, life * 0.25).set_delay(start_delay)
		tween.tween_property(dot, "position", dot.position + drift, life).set_delay(start_delay)
		tween.tween_property(dot, "scale", Vector2.ONE * randf_range(0.35, 0.75), life).set_delay(start_delay)
		tween.tween_property(dot, "modulate:a", 0.0, life * 0.45).set_delay(start_delay + life * 0.55)

func _target_scale(sc: float, flatten: bool) -> Vector2:
	if flatten:
		return Vector2(sc * 1.12, sc * 0.42)
	return Vector2.ONE * sc

func _particle_drift(role: String) -> Vector2:
	if role == "foot":
		return Vector2(randf_range(-24.0, 24.0), randf_range(-8.0, 8.0))
	if role == "head":
		return Vector2(randf_range(-14.0, 14.0), randf_range(-24.0, -10.0))
	return Vector2(randf_range(-20.0, 20.0), randf_range(-18.0, 10.0))

func _particle_color(role: String) -> Color:
	if role == "head":
		return Color(0.88, 0.72, 1.0, 1.0)
	if role == "foot":
		return Color(0.62, 0.92, 0.78, 1.0)
	return Color(1.0, 0.86, 0.48, 1.0)

func _add_material() -> CanvasItemMaterial:
	# 共享材质：所有加法混合的 VFX 精灵用同一份，见 VFXManager。
	return VFXManager.MAT_ADD

func _circle_polygon(radius: float, segments: int) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i in segments:
		var angle := TAU * float(i) / float(segments)
		points.append(Vector2(cos(angle), sin(angle)) * radius)
	return points

func _free_after(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
	if is_instance_valid(self):
		queue_free()
