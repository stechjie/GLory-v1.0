extends VFXBlockRoot
class_name VFXRaceBasicAttack3D

const SLASH_ARC := preload("res://effects/vfx3d/modules/VFXSlashArc3D.gd")
const IMPACT_FLASH := preload("res://effects/vfx3d/modules/VFXImpactFlash3D.gd")
const PAINTED_LAYER := preload("res://effects/vfx3d/modules/VFXBossTextureLayer3D.gd")
const UPRIGHT_PROJECTILE_ROTATION := PI * 0.5
const GOD_PRIEST_STAR_PROJECTILE := "res://assets/vfx/skills/god_basic_projectiles/god_priest_star_projectile.png"
const GOD_PRIEST_STAR_TRAIL := "res://assets/vfx/skills/god_basic_projectiles/god_priest_star_trail.png"
const GOD_PRIEST_STAR_IMPACT := "res://assets/vfx/skills/god_basic_projectiles/god_priest_star_impact.png"
const GOD_PRIESTESS_RING_PROJECTILE := "res://assets/vfx/skills/god_basic_projectiles/god_priestess_ring_projectile.png"
const GOD_PRIESTESS_RING_TRAIL := "res://assets/vfx/skills/god_basic_projectiles/god_priestess_ring_trail.png"
const GOD_PRIESTESS_RING_IMPACT := "res://assets/vfx/skills/god_basic_projectiles/god_priestess_ring_impact.png"
const GUARDIAN_CRYSTAL_SLASH := "res://assets/vfx/skills/god_guardian/guardian_crystal_slash.png"
const GUARDIAN_CRYSTAL_HIT := "res://assets/vfx/skills/god_guardian/guardian_crystal_hit.png"
const AURORA_TRUE_HIT := "res://assets/vfx/skills/god_aurora/god_aurora_true_hit.png"
const DARK_MAGE_BOLT_PROJECTILE := "res://assets/vfx/skills/dark_basic_projectiles/dark_mage_bolt_projectile.png"
const DARK_MAGE_BOLT_TRAIL := "res://assets/vfx/skills/dark_basic_projectiles/dark_mage_bolt_trail.png"
const DARK_MAGE_BOLT_IMPACT := "res://assets/vfx/skills/dark_basic_projectiles/dark_mage_bolt_impact.png"
const DARK_IMP_CLAW_SWIPE := "res://assets/vfx/skills/dark_basic_melee/dark_imp_claw_swipe.png"
const DARK_FEAR_CLAW_SWIPE := "res://assets/vfx/skills/dark_basic_melee/dark_fear_claw_swipe.png"
const DARK_SCYTHE_SLASH := "res://assets/vfx/skills/dark_basic_melee/dark_scythe_slash.png"
const DARK_SUC_SWIPE := "res://assets/vfx/skills/dark_basic_melee/dark_suc_swipe.png"
const DARK_DOOM_SCYTHE_ARC := "res://assets/vfx/skills/dark_basic_melee/dark_doom_scythe_arc.png"
const DARK_DRAGON_CLAW_ARC := "res://assets/vfx/skills/dark_basic_melee/dark_dragon_claw_arc.png"
const FLAMECLAW_CLAW_SWIPE := "res://assets/vfx/skills/ally_flame_claw/flameclaw_claw_swipe.png"
const FLAMECLAW_BURN_BREAK := "res://assets/vfx/skills/ally_flame_claw/flameclaw_burn_break.png"
const DARK_QUEEN_BOLT_PROJECTILE := "res://assets/vfx/skills/dark_basic_projectiles/dark_queen_bolt_projectile.png"
const DARK_QUEEN_BOLT_TRAIL := "res://assets/vfx/skills/dark_basic_projectiles/dark_queen_bolt_trail.png"
const DARK_QUEEN_BOLT_IMPACT := "res://assets/vfx/skills/dark_basic_projectiles/dark_queen_bolt_impact.png"
const DARK_MELEE_BREAK := "res://assets/vfx/skills/dark_basic_melee/dark_melee_break.png"

# Authored basic-attack projectiles.  Each entry carries its own body / trail /
# impact plates plus its three-value colour set, so adding a race is one more
# row instead of another branch.  The two god entries hold the exact values the
# hardcoded branch used, so their look is unchanged.
const AUTHORED_BOLTS := {
	"star_prayer": {
		"projectile": GOD_PRIEST_STAR_PROJECTILE,
		"trail": GOD_PRIEST_STAR_TRAIL,
		"impact": GOD_PRIEST_STAR_IMPACT,
		"dark": Color(.055, .065, .10), "body": Color(1.0, .97, .88), "core": Color(1.0, 1.0, .98),
		"size": .68, "duration": .88,
		"trail_size": Vector2(.95, .42), "trail_emission": Color(1.0, .94, .78),
		"impact_size": .86, "impact_flow": .012,
		"impact_dark": Color(.06, .07, .11), "impact_body": Color(1.0, .97, .86), "impact_core": Color(1.0, 1.0, .98),
	},
	"priestess_ring": {
		"projectile": GOD_PRIESTESS_RING_PROJECTILE,
		"trail": GOD_PRIESTESS_RING_TRAIL,
		"impact": GOD_PRIESTESS_RING_IMPACT,
		"dark": Color(.055, .065, .10), "body": Color(1.0, .97, .88), "core": Color(1.0, 1.0, .98),
		"size": .68, "duration": .88,
		"trail_size": Vector2(1.02, .52), "trail_emission": Color(1.0, .94, .78),
		"impact_size": .94, "impact_flow": .012,
		"impact_dark": Color(.06, .07, .11), "impact_body": Color(1.0, .97, .86), "impact_core": Color(1.0, 1.0, .98),
	},
	# Shadow Mage's ink sickle.  A dark bolt reads as mass first and magenta rim
	# second, so its trail is thinner and more broken than the god bolts and its
	# impact collapses inward instead of bursting outward.
	# "dark/body/core" are profile colours feeding an additive material, hence the
	# brighter magenta; "impact_*" are play_layer tints, which MULTIPLY into the
	# plate, so the body value has to stay near 1.0 or the art goes black.
	"shadow_sickle": {
		"projectile": DARK_MAGE_BOLT_PROJECTILE,
		"trail": DARK_MAGE_BOLT_TRAIL,
		"impact": DARK_MAGE_BOLT_IMPACT,
		"dark": Color(.10, .03, .12), "body": Color(.88, .28, .60), "core": Color(1.0, .82, .95),
		"size": .92, "duration": .92,
		"trail_size": Vector2(1.12, .34), "trail_emission": Color(.86, .30, .64),
		"impact_size": 1.02, "impact_flow": .020, "impact_z": .30, "impact_duration": .46,
		"impact_dark": Color(.14, .06, .16), "impact_body": Color(1.0, .90, .98), "impact_core": Color(1.0, .86, .96),
	},
	"thorn_lash": {
		"projectile": DARK_QUEEN_BOLT_PROJECTILE,
		"trail": DARK_QUEEN_BOLT_TRAIL,
		"impact": DARK_QUEEN_BOLT_IMPACT,
		"dark": Color(.10, .03, .10), "body": Color(.92, .24, .48), "core": Color(1.0, .78, .90),
		"size": .82, "duration": .84,
		"trail_size": Vector2(1.04, .26), "trail_emission": Color(.90, .26, .52),
		"impact_size": .94, "impact_flow": .022, "impact_z": .30, "impact_duration": .42,
		"impact_dark": Color(.14, .06, .15), "impact_body": Color(1.0, .90, .96), "impact_core": Color(1.0, .84, .92),
	},
}

# Authored melee trails: one slash plate plus one break plate, replacing the
# procedural arc and the generic shard burst.
const PAINTED_MELEE := {
	"imp_claw": {
		"slash": DARK_IMP_CLAW_SWIPE, "hit": DARK_MELEE_BREAK,
		"slash_size": Vector2(1.68, 1.02), "hit_size": Vector2(1.16, 1.16),
		"dark": Color(.14, .06, .16), "body": Color(1.0, .90, .98), "core": Color(1.0, .86, .96),
		"seed": 131.0,
	},
	"fear_claw": {
		"slash": DARK_FEAR_CLAW_SWIPE, "hit": DARK_MELEE_BREAK,
		"slash_size": Vector2(1.54, 1.16), "hit_size": Vector2(1.22, 1.22),
		"dark": Color(.14, .06, .16), "body": Color(1.0, .90, .98), "core": Color(1.0, .86, .96),
		"seed": 137.0,
	},
	"scythe_cut": {
		"slash": DARK_SCYTHE_SLASH, "hit": DARK_MELEE_BREAK,
		"slash_size": Vector2(1.72, 1.04), "hit_size": Vector2(.96, .96),
		"dark": Color(.14, .06, .16), "body": Color(1.0, .90, .98), "core": Color(1.0, .86, .96),
		"seed": 139.0,
	},
	"suc_hook": {
		"slash": DARK_SUC_SWIPE, "hit": DARK_MELEE_BREAK,
		"slash_size": Vector2(1.46, 1.10), "hit_size": Vector2(1.04, 1.04),
		"dark": Color(.14, .06, .16), "body": Color(1.0, .90, .98), "core": Color(1.0, .86, .96),
		"seed": 149.0,
	},
	# The two T3 heavy weapons: wider, heavier trails than T1/T2 and a bigger
	# break on impact.
	"doom_scythe": {
		"slash": DARK_DOOM_SCYTHE_ARC, "hit": DARK_MELEE_BREAK,
		"slash_size": Vector2(2.05, 1.12), "hit_size": Vector2(1.34, 1.34),
		"dark": Color(.14, .06, .16), "body": Color(1.0, .90, .98), "core": Color(1.0, .86, .96),
		"seed": 151.0,
	},
	"dragon_claw": {
		"slash": DARK_DRAGON_CLAW_ARC, "hit": DARK_MELEE_BREAK,
		"slash_size": Vector2(1.86, 1.40), "hit_size": Vector2(1.30, 1.30),
		"dark": Color(.14, .06, .16), "body": Color(1.0, .90, .98), "core": Color(1.0, .86, .96),
		"seed": 157.0,
	},
	# Formation ally. The only inferno-palette melee: its basic attack applies the
	# burn DoT, so the hit plate is a scorch rather than the shared dark break.
	"flame_claw": {
		"slash": FLAMECLAW_CLAW_SWIPE, "hit": FLAMECLAW_BURN_BREAK,
		"slash_size": Vector2(1.74, 1.10), "hit_size": Vector2(1.12, 1.12),
		"dark": Color(.11, .03, .01), "body": Color(1.0, .86, .72), "core": Color(1.0, .94, .78),
		"seed": 163.0,
	},
}

# Projectile speed in world units per second, keyed by bolt_kind.  A battle tile
# is ~0.92 world units across the lane and ~1.22 along it, so a range-4 shooter
# fires from roughly 3.7-4.9 units away.
const DEFAULT_BOLT_SPEED := 7.2
# Bible 3.2: a projectile should be legible for 0.25-0.80s.
const MIN_TRAVEL_TIME := 0.28
const MAX_TRAVEL_TIME := 0.80
const BOLT_SPEED := {
	"arrow": 10.0,          # arrows are the fastest thing on the field
	"dart": 8.8,
	"lance": 7.6,
	"orb": 6.4,             # spellcasters read slower and heavier
	"holy": 6.4,
	"dark": 6.8,
	"star": 7.2,
	"thunder": 11.0,        # lightning should feel near-instant
	"crescent": 7.2,
	"star_prayer": 5.8,     # the two authored god bolts stay ceremonial...
	"priestess_ring": 5.8,  # ...but no longer 2x slower than their own race
	"shadow_sickle": 6.8,
	"thorn_lash": 8.0,
}

func play_profile(profile: VFXProfile3D, context: Dictionary) -> void:
	var mode := str(context.get("mode", "ranged"))
	var race := str(context.get("race", profile.parameters.get("race", "human")))
	var origin: Vector3 = context.get("origin", Vector3(-0.7, 0.72, 0.0))
	var target: Vector3 = context.get("target", Vector3(0.8, 0.48, 0.0))
	# 弹道形状按兵种原型走：composer 依据施法者 unit_id 传入 bolt_kind。
	# 缺省 "lance" = 原来的针/矛，保持向后兼容。bolt_tex 非空则用该 PNG 做弹道。
	var bolt_kind := str(context.get("bolt_kind", "lance"))
	var bolt_tex := str(context.get("bolt_tex", ""))
	if mode == "melee":
		_play_melee(origin, target, race, profile, str(context.get("melee_kind", "")))
	else:
		_play_ranged(origin, target, race, profile, context.get("target_node"), bolt_kind, bolt_tex)

func _play_ranged(origin: Vector3, target: Vector3, race: String, profile: VFXProfile3D, target_node: Variant, bolt_kind := "lance", bolt_tex := "") -> void:
	begin()
	var active := _runtime_profile(profile, race, true)
	# A non-empty bolt texture is a fully authored projectile.  It must not be
	# mixed with the legacy procedural shards/needle trail, otherwise the new
	# hand-painted projectile is visually buried under the old generic VFX.
	var bolt_spec: Dictionary = AUTHORED_BOLTS.get(bolt_kind, {})
	var authored_projectile := not bolt_spec.is_empty() or bolt_tex != ""
	if not bolt_spec.is_empty():
		# Do not inherit the generic race profile colours for an authored shot:
		# the painted plate already carries its own three-value colour structure.
		active.dark_color = bolt_spec["dark"]
		active.main_color = bolt_spec["body"]
		active.core_color = bolt_spec["core"]
		# vfx_size again: _runtime_profile already scaled the .tres size, and this
		# line replaces it, so the authored value has to go through the same
		# calibration or authored bolts stay 2x oversized.
		active.size = vfx_size(float(bolt_spec["size"]))
		active.duration = float(bolt_spec["duration"])
	var target_ref: WeakRef = null
	if is_instance_valid(target_node) and target_node is Node3D:
		target_ref = weakref(target_node)
	var tracked_target := _tracked_target_position(target, target_ref)
	var direction := _safe_direction(origin, tracked_target)
	if not authored_projectile:
		_spawn_shards(origin, direction, active, race, false)
	var needle := _make_projectile_body(bolt_kind, active, race, bolt_tex)
	needle.position = origin + Vector3(0.0, 0.0, 0.10)
	needle.rotation.z = _screen_facing(origin, tracked_target)
	add_child(needle)
	# Travel time comes from distance / speed, not from a fixed duration.
	# With a fixed duration a unit that has closed from 4 tiles to 1 fires the
	# same bolt 4x slower, and two shooters of the same race read as having
	# different weapons.  Speed is in world units per second; see BOLT_SPEED.
	var travel_distance := origin.distance_to(tracked_target)
	var bolt_speed := float(bolt_spec.get("speed", BOLT_SPEED.get(bolt_kind, DEFAULT_BOLT_SPEED)))
	var travel_duration := clampf(travel_distance / maxf(0.5, bolt_speed), MIN_TRAVEL_TIME, MAX_TRAVEL_TIME)
	var arc_height := maxf(0.0, float(active.parameters.get("arc_height", 0.0)))
	var travel_elapsed := 0.0
	var trail_elapsed := 0.0
	var trail_index := 0
	while travel_elapsed < travel_duration:
		await get_tree().process_frame
		if _finished:
			return
		var delta := get_process_delta_time()
		travel_elapsed += delta
		trail_elapsed += delta
		tracked_target = _tracked_target_position(tracked_target, target_ref)
		direction = _safe_direction(origin, tracked_target)
		var ratio := clampf(travel_elapsed / travel_duration, 0.0, 1.0)
		# 匀速推进（去掉 1-pow(...) 的快射-减速冲刺，那是轻飘"嗖一下"的来源）。
		needle.position = origin.lerp(tracked_target, ratio) + Vector3(0.0, arc_height * sin(ratio * PI), 0.10)
		needle.rotation.z = _screen_facing(origin, tracked_target)
		if trail_elapsed >= (0.075 if authored_projectile else 0.045):
			trail_elapsed = 0.0
			if bolt_tex != "":
				_spawn_textured_trail(needle.position, direction, active, bolt_tex, trail_index)
			elif authored_projectile:
				_spawn_authored_trail(needle.position, direction, active, bolt_kind, bolt_spec, trail_index)
			else:
				_spawn_needle_trail(needle.position, direction, active, race, trail_index)
			trail_index += 1
	needle.queue_free()
	if bolt_tex != "":
		_spawn_textured_impact(tracked_target + Vector3(0.0, 0.04, 0.04), active, AURORA_TRUE_HIT)
	elif authored_projectile:
		# impact_z pushes the impact layer toward the camera.  God bolts keep the
		# original 0.04 so nothing changes for them; dark impacts are dark-on-dark
		# and vanish completely behind the model unless they sit in front of it.
		var impact_z := float(bolt_spec.get("impact_z", 0.04)) * VFX_OFFSET_SCALE
		_spawn_authored_impact(tracked_target + Vector3(0.0, 0.04, 0.0) + vfx_toward_camera(impact_z), active, bolt_kind, bolt_spec)
	else:
		_spawn_linear_hit(tracked_target + Vector3(0.0, 0.04, 0.04), direction, active, race)
	await get_tree().create_timer(active.duration * 0.34).timeout
	finish()

func _play_melee(origin: Vector3, target: Vector3, race: String, profile: VFXProfile3D, melee_kind := "") -> void:
	begin()
	var active := _runtime_profile(profile, race, false)
	var direction := (target - origin).normalized()
	if direction.length_squared() < 0.001:
		direction = Vector3.RIGHT
	var hit_at := target + vfx_offset(Vector3(0.0, 0.22, 0.02))
	# Units with an authored trail use the painted slash and skip both the
	# procedural arc and the generic shards: stacking the two only buries the
	# silhouette that was just painted (design bible 14.2).
	var painted: Dictionary = PAINTED_MELEE.get(melee_kind, {})
	if not painted.is_empty():
		_spawn_painted_melee_slash(hit_at, direction, active, painted)
		await get_tree().create_timer(active.duration * 0.16).timeout
		if _finished:
			return
		_spawn_painted_melee_hit(target + vfx_offset(Vector3(0.0, 0.26, 0.04)), active, painted)
		await get_tree().create_timer(active.duration * 0.82).timeout
		finish()
		return
	# 近战 T3 专属斩击（保持近战定位，只是斩击更派头）。其余单位走默认单斩。
	match melee_kind:
		"claw":
			# 黑龙·龙爪三连：三道错开倾角的平行爪痕。
			for i in range(3):
				_spawn_slash(hit_at + Vector3(0.0, float(i - 1) * 0.11, 0.004 * float(i)), direction, active, {"tilt": -26.0 + float(i) * 26.0, "width_mul": 0.9, "radius_mul": 1.08})
		"cross":
			# 神王·神圣交叉：两道对角 X 斩。
			_spawn_slash(hit_at, direction, active, {"tilt": 36.0, "width_mul": 1.2, "radius_mul": 1.18})
			_spawn_slash(hit_at, direction, active, {"tilt": -36.0, "width_mul": 1.2, "radius_mul": 1.18})
		"guardian_crystal":
			_spawn_guardian_crystal_slash(hit_at, direction, active)
		"scythe":
			# 末日守卫·厄夜镰斩：一道又宽又低的大横扫。
			_spawn_slash(hit_at + Vector3(0.0, -0.06, 0.0), direction, active, {"arc": 172.0, "tilt": 6.0, "width_mul": 1.55, "radius_mul": 1.32})
		_:
			var slash := SLASH_ARC.new()
			slash.name = "RaceSlash_%s" % race
			add_child(slash)
			slash.play_slash(hit_at, direction, active)
	await get_tree().create_timer(active.duration * 0.16).timeout
	if _finished:
		return
	if melee_kind == "guardian_crystal":
		_spawn_guardian_crystal_hit(target + Vector3(0.0, 0.28, 0.04), active)
	else:
		_spawn_shards(target + Vector3(0.0, 0.24, 0.04), direction, active, race, true)
	var flash := IMPACT_FLASH.new()
	flash.name = "RaceMeleeImpact_%s" % race
	add_child(flash)
	# T3 专属斩击给更强的命中闪。
	var flash_scale := active.size * (0.52 if melee_kind != "" else 0.38)
	flash.play_flash(target, active.core_color, flash_scale, active.duration * 0.16)
	await get_tree().create_timer(active.duration * 0.82).timeout
	finish()

func _spawn_painted_melee_slash(at: Vector3, direction: Vector3, profile: VFXProfile3D, spec: Dictionary) -> void:
	var slash := PAINTED_LAYER.new()
	slash.name = "PaintedMeleeSlash"
	add_child(slash)
	var slash_size: Vector2 = spec.get("slash_size", Vector2(1.0, .60))
	slash.play_layer(str(spec.get("slash", "")), {
		"position":at + vfx_offset(Vector3(0.0, .10, 0.0)) + vfx_toward_camera(.22),
		"size":slash_size,
		"duration":.38,
		"start_scale":.12,
		"peak_scale":.88,
		"end_scale":1.04,
		"rotation_z":_screen_facing(at - direction, at),
		"dark_tint":spec.get("dark", Color(.14,.06,.16)),
		"body_tint":spec.get("body", Color(1.0,.90,.98)),
		"core_tint":spec.get("core", Color(1.0,.86,.96)),
		"flow_strength":.020,
		"opacity":.94,
		"seed":float(spec.get("seed", 131.0))
	})

func _spawn_painted_melee_hit(at: Vector3, profile: VFXProfile3D, spec: Dictionary) -> void:
	var hit := PAINTED_LAYER.new()
	hit.name = "PaintedMeleeHit"
	add_child(hit)
	hit.play_layer(str(spec.get("hit", "")), {
		"position":at + vfx_toward_camera(.20),
		"size":spec.get("hit_size", Vector2(.74,.74)),
		"duration":.34,
		"start_scale":.08,
		"peak_scale":.66,
		"end_scale":.94,
		"dark_tint":spec.get("dark", Color(.14,.06,.16)),
		"body_tint":spec.get("body", Color(1.0,.90,.98)),
		"core_tint":spec.get("core", Color(1.0,.86,.96)),
		"flow_strength":.018,
		"opacity":.92,
		"seed":float(spec.get("seed", 131.0)) + 7.0
	})

func _spawn_guardian_crystal_slash(at: Vector3, direction: Vector3, profile: VFXProfile3D) -> void:
	var slash := PAINTED_LAYER.new()
	slash.name = "GuardianCrystalSlash"
	add_child(slash)
	slash.play_layer(GUARDIAN_CRYSTAL_SLASH, {
		"position":at + Vector3(0.0, .10, .02),
		"size":Vector2(1.18, .72),
		"duration":.46,
		"start_scale":.10,
		"peak_scale":.86,
		"end_scale":1.06,
		"rotation_z":_screen_facing(at - direction, at),
		"dark_tint":Color(.055,.065,.10),
		"body_tint":Color(1.0,.97,.88),
		"core_tint":Color(1.0,1.0,.98),
		"flow_strength":.018,
		"opacity":.94,
		"seed":87.0
	})

func _spawn_guardian_crystal_hit(at: Vector3, profile: VFXProfile3D) -> void:
	var hit := PAINTED_LAYER.new()
	hit.name = "GuardianCrystalHit"
	add_child(hit)
	hit.play_layer(GUARDIAN_CRYSTAL_HIT, {
		"position":at,
		"size":Vector2(.82,.82),
		"duration":.42,
		"start_scale":.08,
		"peak_scale":.72,
		"end_scale":1.04,
		"dark_tint":Color(.055,.065,.10),
		"body_tint":Color(1.0,.97,.88),
		"core_tint":Color(1.0,1.0,.98),
		"flow_strength":.016,
		"opacity":.94,
		"seed":89.0
	})

# 生成一道斩击，用 overrides 覆盖弧度/倾角/粗细/半径。
func _spawn_slash(at: Vector3, direction: Vector3, base: VFXProfile3D, overrides: Dictionary) -> void:
	var p := base.duplicate_runtime()
	p.parameters = p.parameters.duplicate()
	if overrides.has("arc"):
		p.parameters["arc_degrees"] = float(overrides["arc"])
	if overrides.has("tilt"):
		p.parameters["tilt_degrees"] = float(overrides["tilt"])
	if overrides.has("width_mul"):
		p.parameters["width"] = float(p.parameters.get("width", 0.16)) * float(overrides["width_mul"])
	if overrides.has("radius_mul"):
		p.parameters["radius"] = float(p.parameters.get("radius", 1.15)) * float(overrides["radius_mul"])
	var slash := SLASH_ARC.new()
	add_child(slash)
	slash.play_slash(at, direction, p)

func _tracked_target_position(fallback: Vector3, target_ref: WeakRef) -> Vector3:
	if target_ref == null:
		return fallback
	var target_node: Variant = target_ref.get_ref()
	if not is_instance_valid(target_node) or not (target_node is Node3D):
		return fallback
	var tracked := to_local((target_node as Node3D).global_position)
	tracked.y = fallback.y
	return tracked

# 弹道朝向 = 飞行方向在屏幕上的角度。战斗相机 (0,7.4,7) 俯视：
# 世界 X → 屏幕右；世界 Y/Z → 屏幕纵向（Y 抬升 0.688、Z 远近 -0.726 的俯角投影）。
# 形状都沿 +X 建，rotation.z 设成这个角就把箭头对准目标。正对射击(纯 Z)时 = ±90°，
# 和原来固定竖直一致，向后兼容。
func _screen_facing(from: Vector3, to: Vector3) -> float:
	var d := to - from
	var screen_y := d.y * 0.688 - d.z * 0.726
	if absf(d.x) < 0.0001 and absf(screen_y) < 0.0001:
		return UPRIGHT_PROJECTILE_ROTATION
	return atan2(screen_y, d.x)

func _safe_direction(origin: Vector3, target: Vector3) -> Vector3:
	var direction := target - origin
	if direction.length_squared() < 0.0001:
		return Vector3.RIGHT
	return direction.normalized()

func _make_projectile_needle(profile: VFXProfile3D, race: String) -> Node3D:
	var root := Node3D.new()
	root.name = "StraightRaceBolt_%s" % race
	var length := profile.size * (0.92 if race == "human" else 1.02)
	var layers := [
		{"name": "DarkEdge", "length": length * 1.10, "width": profile.size * 0.075, "color": profile.dark_color.lerp(profile.main_color, 0.18), "energy": profile.emission_energy * 0.52, "z": 0.000},
		{"name": "ColorBody", "length": length, "width": profile.size * 0.052, "color": profile.main_color, "energy": profile.emission_energy * 0.82, "z": 0.008},
		{"name": "HotCore", "length": length * 0.84, "width": profile.size * 0.020, "color": profile.core_color, "energy": profile.emission_energy, "z": 0.016},
	]
	for layer: Dictionary in layers:
		var lance := _lance_mesh(float(layer["length"]), float(layer["width"]), layer["color"], float(layer["energy"]))
		lance.name = str(layer["name"])
		lance.position.z = float(layer["z"])
		root.add_child(lance)
	return root

# ── 弹道形状库（6 种兵种原型 + 默认矛）──────────────────────────────
# 颜色仍取 profile（按种族），差异化的是形状。所有形状都是程序化几何体，
# 零美术成本；将来要精致版再用贴图替换单个原型。
func _make_projectile_body(kind: String, profile: VFXProfile3D, race: String, tex_path := "") -> Node3D:
	if tex_path != "":
		return _body_texture(tex_path, profile)
	match kind:
		"arrow": return _body_arrow(profile, race)
		"orb": return _body_orb(profile, race, "magic")
		"dart": return _body_dart(profile, race)
		"holy": return _body_orb(profile, race, "holy")
		"dark": return _body_orb(profile, race, "dark")
		"thunder": return _body_thunder(profile, race)
		"crescent": return _body_crescent(profile, race)
		"star": return _body_star(profile, race)
		_:
			if AUTHORED_BOLTS.has(kind):
				return _body_texture(str(AUTHORED_BOLTS[kind]["projectile"]), profile)
			return _make_projectile_needle(profile, race)

# 🖼 PNG 弹道：用一张贴图做弹体。贴图里的箭头朝右(+X)，rotation.z 会把它对准目标。
func _body_texture(tex_path: String, profile: VFXProfile3D) -> Node3D:
	var tex := load(tex_path) as Texture2D
	if tex == null:
		return _make_projectile_needle(profile, "human")
	var root := Node3D.new(); root.name = "BoltTexture"
	var quad := QuadMesh.new()
	# Respect the plate's own aspect ratio.  This used to be a hardcoded 3:1 quad,
	# which squashed every square projectile plate (the god, aurora and undead
	# bolts are all 1:1) to a third of its height.  profile.size now drives the
	# long side and the short side follows the art.
	var tex_aspect := float(tex.get_width()) / maxf(1.0, float(tex.get_height()))
	var long_side := profile.size * 1.5
	quad.size = Vector2(long_side, long_side / tex_aspect) if tex_aspect >= 1.0 else Vector2(long_side * tex_aspect, long_side)
	var mi := MeshInstance3D.new(); mi.mesh = quad
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = true
	mat.render_priority = 3
	mat.albedo_texture = tex
	mat.albedo_color = profile.main_color.lerp(Color.WHITE, 0.35)
	mat.emission_enabled = true
	mat.emission = profile.main_color
	mat.emission_texture = tex
	mat.emission_energy_multiplier = minf(profile.emission_energy, 3.6)
	mi.material_override = mat
	root.add_child(mi)
	return root

# 🌙 弯月镰：一段两端收尖、中段饱满的弧刃，比圆球灵动。给暗影法师。
func _body_crescent(profile: VFXProfile3D, race: String) -> Node3D:
	var root := Node3D.new(); root.name = "BoltCrescent"
	var rc := profile.size * 0.5
	for layer in [
		{"w": profile.size * 0.20, "c": profile.dark_color.lerp(profile.main_color, 0.2), "e": profile.emission_energy * 0.5, "z": 0.0},
		{"w": profile.size * 0.135, "c": profile.main_color, "e": profile.emission_energy * 0.9, "z": 0.008},
		{"w": profile.size * 0.055, "c": profile.core_color, "e": profile.emission_energy, "z": 0.016},
	]:
		var m := _crescent_mesh(rc, float(layer["w"]), 150.0, layer["c"], float(layer["e"]))
		m.position.z = float(layer["z"]); root.add_child(m)
	return root

# ✦ 四芒星光羽：四长尖交替短尖，尖锐飘逸。给天使。
func _body_star(profile: VFXProfile3D, race: String) -> Node3D:
	var root := Node3D.new(); root.name = "BoltStar"
	var rl := profile.size * 0.52
	root.add_child(_disc_mesh(rl * 0.42, profile.main_color, profile.emission_energy * 0.28, 16))  # 柔和光核底
	for layer in [
		{"rl": rl, "rs": rl * 0.30, "c": profile.dark_color.lerp(profile.main_color, 0.25), "e": profile.emission_energy * 0.5, "z": 0.002},
		{"rl": rl * 0.82, "rs": rl * 0.24, "c": profile.main_color, "e": profile.emission_energy * 0.9, "z": 0.010},
		{"rl": rl * 0.5, "rs": rl * 0.16, "c": profile.core_color, "e": profile.emission_energy, "z": 0.018},
	]:
		var m := _star_mesh(float(layer["rl"]), float(layer["rs"]), layer["c"], float(layer["e"]), 4)
		m.position.z = float(layer["z"]); root.add_child(m)
	return root

# 🏹 箭矢：细长带箭羽，比默认矛更锐利。
func _body_arrow(profile: VFXProfile3D, race: String) -> Node3D:
	var root := Node3D.new(); root.name = "BoltArrow"
	var length := profile.size * 1.28
	for layer in [
		{"l": length * 1.08, "w": profile.size * 0.052, "c": profile.dark_color.lerp(profile.main_color, 0.2), "e": profile.emission_energy * 0.5, "z": 0.0},
		{"l": length, "w": profile.size * 0.034, "c": profile.main_color, "e": profile.emission_energy * 0.85, "z": 0.008},
		{"l": length * 0.8, "w": profile.size * 0.014, "c": profile.core_color, "e": profile.emission_energy, "z": 0.016},
	]:
		var m := _lance_mesh(float(layer["l"]), float(layer["w"]), layer["c"], float(layer["e"]))
		m.position.z = float(layer["z"]); root.add_child(m)
	# 箭羽：尾端两片小三角
	for s in [-1.0, 1.0]:
		var fletch := _tri_mesh(profile.size * 0.22, profile.size * 0.10 * s, profile.main_color.lerp(profile.core_color, 0.3), profile.emission_energy * 0.7)
		fletch.position = Vector3(-length * 0.5, 0.0, 0.004)
		root.add_child(fletch)
	return root

# ☠️ 毒镖：短粗带倒刺，重心靠前。
func _body_dart(profile: VFXProfile3D, race: String) -> Node3D:
	var root := Node3D.new(); root.name = "BoltDart"
	var length := profile.size * 0.78
	for layer in [
		{"l": length * 1.12, "w": profile.size * 0.14, "c": profile.dark_color.lerp(profile.main_color, 0.25), "e": profile.emission_energy * 0.55, "z": 0.0},
		{"l": length, "w": profile.size * 0.095, "c": profile.main_color, "e": profile.emission_energy * 0.9, "z": 0.008},
		{"l": length * 0.7, "w": profile.size * 0.04, "c": profile.core_color, "e": profile.emission_energy, "z": 0.016},
	]:
		var m := _lance_mesh(float(layer["l"]), float(layer["w"]), layer["c"], float(layer["e"]))
		m.position.z = float(layer["z"]); root.add_child(m)
	# 倒刺
	for s in [-1.0, 1.0]:
		var barb := _tri_mesh(profile.size * 0.20, profile.size * 0.13 * s, profile.dark_color.lerp(profile.main_color, 0.4), profile.emission_energy * 0.6)
		barb.position = Vector3(-length * 0.28, 0.0, 0.004)
		root.add_child(barb)
	return root

# 🔮✨🌑 球形弹（法球/圣光/暗能）：圆盘 + 光晕，按 style 加不同点缀。
func _body_orb(profile: VFXProfile3D, race: String, style: String) -> Node3D:
	var root := Node3D.new(); root.name = "BoltOrb_%s" % style
	var r := profile.size * 0.34
	root.add_child(_disc_mesh(r * 1.9, profile.dark_color.lerp(profile.main_color, 0.15), profile.emission_energy * 0.30, 20))  # halo
	root.add_child(_disc_mesh(r, profile.main_color, profile.emission_energy * 0.9, 20))                                        # body
	var core := _disc_mesh(r * 0.5, profile.core_color, profile.emission_energy * 1.25, 16); core.position.z = 0.012
	root.add_child(core)
	match style:
		"holy":
			# 十字光芒
			for rot in [0.0, PI * 0.5]:
				var ray := _lance_mesh(r * 3.0, r * 0.06, profile.core_color, profile.emission_energy)
				ray.rotation.z = rot; ray.position.z = 0.014
				root.add_child(ray)
		"dark":
			# 外圈锯齿扰动环
			var ring := _ring_jag_mesh(r * 1.4, r * 0.22, 9, profile.main_color.lerp(profile.dark_color, 0.4), profile.emission_energy * 0.7)
			ring.position.z = 0.006; root.add_child(ring)
	return root

# ⚡ 雷弹：锯齿折线，层叠。
func _body_thunder(profile: VFXProfile3D, race: String) -> Node3D:
	var root := Node3D.new(); root.name = "BoltThunder"
	var length := profile.size * 1.2
	for layer in [
		{"w": profile.size * 0.07, "c": profile.dark_color.lerp(profile.main_color, 0.3), "e": profile.emission_energy * 0.55, "z": 0.0},
		{"w": profile.size * 0.038, "c": profile.main_color, "e": profile.emission_energy * 0.9, "z": 0.008},
		{"w": profile.size * 0.016, "c": profile.core_color, "e": profile.emission_energy, "z": 0.016},
	]:
		var m := _zigzag_mesh(length, float(layer["w"]), layer["c"], float(layer["e"]))
		m.position.z = float(layer["z"]); root.add_child(m)
	return root

func _spawn_needle_trail(at: Vector3, direction: Vector3, profile: VFXProfile3D, race: String, index: int) -> void:
	var length := profile.size * (0.54 + 0.06 * float(index % 2))
	var body := _lance_mesh(length, profile.size * 0.040, profile.main_color, profile.emission_energy * 0.58)
	body.name = "StraightTrail_%s_%d" % [race, index]
	body.position = at - direction * profile.size * 0.28 + Vector3(0.0, 0.0, 0.006)
	body.rotation.z = UPRIGHT_PROJECTILE_ROTATION
	body.scale = Vector3(0.84, 0.72, 1.0)
	body.transparency = 0.18
	add_child(body)
	var tween := track_tween(create_tween())
	tween.set_parallel(true)
	tween.tween_property(body, "position", body.position - direction * profile.size * 0.18, profile.duration * 0.20).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(body, "scale", Vector3(0.34, 0.10, 1.0), profile.duration * 0.20).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_IN)
	tween.tween_property(body, "transparency", 1.0, profile.duration * 0.20).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.set_parallel(false)
	tween.tween_callback(body.queue_free)

func _spawn_linear_hit(at: Vector3, direction: Vector3, profile: VFXProfile3D, race: String) -> void:
	var angles := [-0.24, 0.0, 0.24]
	for i in range(angles.size()):
		var out := direction.rotated(Vector3.FORWARD, float(angles[i])).normalized()
		var color := profile.core_color if i == 2 else profile.main_color
		var streak := _lance_mesh(profile.size * (0.30 + 0.05 * float(i % 2)), profile.size * (0.018 if i == 1 else 0.024), color, profile.emission_energy * 0.68)
		streak.name = "LinearHit_%s_%d" % [race, i]
		streak.position = at + Vector3(0.0, 0.0, 0.02 + float(i) * 0.002)
		streak.rotation.z = atan2(out.y, out.x)
		streak.scale = Vector3(0.30, 0.44, 1.0)
		add_child(streak)
		var tween := track_tween(create_tween())
		tween.set_parallel(true)
		tween.tween_property(streak, "position", streak.position + out * profile.size * (0.32 + 0.05 * float(i % 3)), profile.duration * 0.18).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
		tween.tween_property(streak, "scale", Vector3(1.0, 0.08, 1.0), profile.duration * 0.18).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
		tween.tween_property(streak, "transparency", 1.0, profile.duration * 0.18).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tween.set_parallel(false)
		tween.tween_callback(streak.queue_free)

func _spawn_authored_trail(at: Vector3, direction: Vector3, profile: VFXProfile3D, bolt_kind: String, spec: Dictionary, index: int) -> void:
	var texture := load(str(spec.get("trail", ""))) as Texture2D
	if texture == null:
		return
	var trail_size: Vector2 = spec.get("trail_size", Vector2(1.0, .48))
	var quad := QuadMesh.new()
	quad.size = Vector2(profile.size * trail_size.x, profile.size * trail_size.y)
	var mi := MeshInstance3D.new()
	mi.name = "AuthoredTrail_%s_%d" % [bolt_kind, index]
	mi.mesh = quad
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = at - direction * profile.size * 0.24 + Vector3(0.0, 0.0, 0.006)
	mi.rotation.z = _screen_facing(at - direction, at)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = true
	mat.render_priority = 3
	mat.albedo_texture = texture
	mat.albedo_color = Color(1.0, 1.0, 1.0, 0.72)
	mat.emission_enabled = true
	mat.emission = spec.get("trail_emission", Color(1.0, 0.94, 0.78))
	mat.emission_texture = texture
	mat.emission_energy_multiplier = minf(profile.emission_energy, 3.2)
	mi.material_override = mat
	mi.scale = Vector3(0.82 + 0.08 * float(index % 2), 0.82 + 0.08 * float(index % 2), 1.0)
	add_child(mi)
	var tween := track_tween(create_tween())
	tween.set_parallel(true)
	tween.tween_property(mi, "position", mi.position - direction * profile.size * 0.20, profile.duration * 0.24).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(mi, "scale", Vector3(0.32, 0.16, 1.0), profile.duration * 0.24).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_IN)
	tween.tween_property(mi, "transparency", 1.0, profile.duration * 0.24).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.set_parallel(false)
	tween.tween_callback(mi.queue_free)

func _spawn_textured_trail(at: Vector3, direction: Vector3, profile: VFXProfile3D, texture_path: String, index: int) -> void:
	var texture := load(texture_path) as Texture2D
	if texture == null:
		return
	var quad := QuadMesh.new()
	quad.size = Vector2(profile.size * 0.86, profile.size * 0.34)
	var mi := MeshInstance3D.new()
	mi.name = "TexturedTrail_%d" % index
	mi.mesh = quad
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = at - direction * profile.size * 0.22 + Vector3(0.0, 0.0, 0.006)
	mi.rotation.z = _screen_facing(at - direction, at)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = true
	mat.render_priority = 3
	mat.albedo_texture = texture
	mat.albedo_color = Color(1.0, 1.0, 1.0, 0.76)
	mat.emission_enabled = true
	mat.emission = Color(.38, .72, 1.0)
	mat.emission_texture = texture
	mat.emission_energy_multiplier = minf(profile.emission_energy, 2.8)
	mi.material_override = mat
	mi.scale = Vector3(0.72 + 0.06 * float(index % 2), 0.72 + 0.06 * float(index % 2), 1.0)
	add_child(mi)
	var tween := track_tween(create_tween())
	tween.set_parallel(true)
	tween.tween_property(mi, "position", mi.position - direction * profile.size * 0.16, profile.duration * 0.22).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(mi, "scale", Vector3(0.22, 0.12, 1.0), profile.duration * 0.22).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_IN)
	tween.tween_property(mi, "transparency", 1.0, profile.duration * 0.22).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.set_parallel(false)
	tween.tween_callback(mi.queue_free)

func _spawn_textured_impact(at: Vector3, profile: VFXProfile3D, texture_path: String) -> void:
	var impact := PAINTED_LAYER.new()
	impact.name = "TexturedProjectileImpact"
	add_child(impact)
	impact.play_layer(texture_path, {
		"position":at,
		"size":Vector2(.72,.72),
		"duration":.34,
		"start_scale":.08,
		"peak_scale":.58,
		"end_scale":.86,
		"dark_tint":Color(.025,.035,.14),
		"body_tint":Color(.10,.62,.94),
		"core_tint":Color(.90,.99,1.0),
		"flow_strength":.018,
		"opacity":.92,
		"seed":float(abs(int(at.x * 23.0 + at.y * 17.0)) % 97)
	})

func _spawn_authored_impact(at: Vector3, profile: VFXProfile3D, bolt_kind: String, spec: Dictionary) -> void:
	var impact := PAINTED_LAYER.new()
	impact.name = "AuthoredImpact_%s" % bolt_kind
	add_child(impact)
	var impact_size := float(spec.get("impact_size", .90))
	impact.play_layer(str(spec.get("impact", "")), {
		"position":at,
		"size":Vector2(impact_size, impact_size),
		"duration":float(spec.get("impact_duration", 0.38)),
		"start_scale":0.08,
		"peak_scale":0.70,
		"end_scale":0.96,
		"dark_tint":spec.get("impact_dark", Color(.06,.07,.11)),
		"body_tint":spec.get("impact_body", Color(1.0,.97,.86)),
		"core_tint":spec.get("impact_core", Color(1.0,1.0,.98)),
		"flow_strength":float(spec.get("impact_flow", .012)),
		"opacity":.92,
		"seed":float(abs(int(at.x * 23.0 + at.y * 17.0)) % 97)
	})

# 网格与材质的进程级缓存。
#
# 为什么安全共享：这个模块里所有动画都作用在**节点**属性上
# （position / scale / transparency —— transparency 是 GeometryInstance3D 的
# per-instance 字段），没有任何 tween 去改材质或 shader 参数。所以同一份
# Mesh/Material 可以被任意多个 MeshInstance3D 复用。
#
# 为什么值得：_spawn_needle_trail 在弹体飞行期间**每 0.045 秒**调一次，
# 每次都 new 一个 ArrayMesh + 一个 StandardMaterial。12 个单位持续攻击时
# 这是稳定的分配热点（新 RID、新资源对象、等 GC）。
static var _mesh_cache: Dictionary = {}
static var _mat_cache: Dictionary = {}

# 共享的加法/无光材质，弹道所有形状复用。
func _bolt_material(color: Color, energy: float) -> StandardMaterial3D:
	var clamped := minf(energy, 4.2)
	var key := "%d|%d" % [color.to_rgba32(), int(round(clamped * 64.0))]
	var cached: StandardMaterial3D = _mat_cache.get(key)
	if cached != null:
		return cached
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.no_depth_test = true
	material.render_priority = 3
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = clamped
	_mat_cache[key] = material
	return material

# 从顶点+索引直接组网格，套共享材质。
# shape_key 让相同几何只建一次 ArrayMesh —— 顶点数组仍每次构造（很便宜），
# 省掉的是 ArrayMesh 资源本身和它的 RID。
func _shape_mesh(verts: PackedVector3Array, indices: PackedInt32Array, color: Color, energy: float, shape_key: String = "") -> MeshInstance3D:
	var mesh: ArrayMesh = _mesh_cache.get(shape_key) if not shape_key.is_empty() else null
	if mesh == null:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_INDEX] = indices
		mesh = ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		if not shape_key.is_empty():
			_mesh_cache[shape_key] = mesh
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.material_override = _bolt_material(color, energy)
	return node

func _lance_mesh(length: float, width: float, color: Color, energy: float) -> MeshInstance3D:
	return _shape_mesh(PackedVector3Array([
		Vector3(-length * 0.56, 0.0, 0.0),
		Vector3(-length * 0.43, -width, 0.0),
		Vector3(length * 0.56, 0.0, 0.0),
		Vector3(-length * 0.43, width, 0.0),
	]), PackedInt32Array([0, 1, 2, 0, 2, 3]), color, energy, "lance|%.4f|%.4f" % [length, width])

# 小三角（箭羽 / 倒刺）。tip_y 的正负决定朝哪一侧。
func _tri_mesh(base: float, tip_y: float, color: Color, energy: float) -> MeshInstance3D:
	return _shape_mesh(PackedVector3Array([
		Vector3(base * 0.5, 0.0, 0.0),
		Vector3(-base * 0.5, 0.0, 0.0),
		Vector3(-base * 0.1, tip_y, 0.0),
	]), PackedInt32Array([0, 1, 2]), color, energy)

# 圆盘（法球 / 圣光 / 暗能的球体）。
func _disc_mesh(radius: float, color: Color, energy: float, segments: int) -> MeshInstance3D:
	var verts := PackedVector3Array([Vector3.ZERO])
	var indices := PackedInt32Array()
	for i in range(segments + 1):
		var a := TAU * float(i) / float(segments)
		verts.append(Vector3(cos(a) * radius, sin(a) * radius, 0.0))
	for i in range(segments):
		indices.append_array([0, i + 1, i + 2])
	return _shape_mesh(verts, indices, color, energy)

# 锯齿扰动环（暗能弹外圈）。
func _ring_jag_mesh(radius: float, jag: float, spikes: int, color: Color, energy: float) -> MeshInstance3D:
	var verts := PackedVector3Array([Vector3.ZERO])
	var indices := PackedInt32Array()
	var pts := spikes * 2
	for i in range(pts + 1):
		var a := TAU * float(i) / float(pts)
		var rr: float = radius + (jag if i % 2 == 0 else -jag * 0.5)
		verts.append(Vector3(cos(a) * rr, sin(a) * rr, 0.0))
	for i in range(pts):
		indices.append_array([0, i + 1, i + 2])
	return _shape_mesh(verts, indices, color, energy)

# 弯月镰：沿一段圆弧的中心线，两端收尖、中段最粗（半宽随 sin 变化）。
func _crescent_mesh(rc: float, half_w: float, span_deg: float, color: Color, energy: float) -> MeshInstance3D:
	var verts := PackedVector3Array()
	var indices := PackedInt32Array()
	var segs := 16
	var span := deg_to_rad(span_deg)
	for i in range(segs + 1):
		var t := float(i) / float(segs)
		var ang := -span * 0.5 + t * span
		var w := half_w * sin(t * PI)
		verts.append(Vector3(cos(ang) * (rc + w), sin(ang) * (rc + w), 0.0))
		verts.append(Vector3(cos(ang) * (rc - w), sin(ang) * (rc - w), 0.0))
		if i > 0:
			var o := (i - 1) * 2
			indices.append_array([o, o + 1, o + 2, o + 1, o + 3, o + 2])
	return _shape_mesh(verts, indices, color, energy)

# 四芒星：长尖/短尖交替，三角扇。
func _star_mesh(r_long: float, r_short: float, color: Color, energy: float, spikes: int) -> MeshInstance3D:
	var verts := PackedVector3Array([Vector3.ZERO])
	var indices := PackedInt32Array()
	var pts := spikes * 2
	for i in range(pts + 1):
		var a := TAU * float(i) / float(pts) + PI * 0.5
		var r: float = r_long if i % 2 == 0 else r_short
		verts.append(Vector3(cos(a) * r, sin(a) * r, 0.0))
	for i in range(pts):
		indices.append_array([0, i + 1, i + 2])
	return _shape_mesh(verts, indices, color, energy)

# 锯齿折线（雷弹）。沿 X 前进，Y 方向来回抖。
func _zigzag_mesh(length: float, width: float, color: Color, energy: float) -> MeshInstance3D:
	var verts := PackedVector3Array()
	var indices := PackedInt32Array()
	var segs := 5
	var amp := width * 3.2
	var prev_top := 0
	var prev_bot := 0
	for i in range(segs + 1):
		var t := float(i) / float(segs)
		var x := lerpf(-length * 0.5, length * 0.5, t)
		var y: float = (amp if i % 2 == 0 else -amp) * (1.0 - abs(t - 0.5) * 0.6)
		verts.append(Vector3(x, y + width, 0.0))
		verts.append(Vector3(x, y - width, 0.0))
		var top := verts.size() - 2
		var bot := verts.size() - 1
		if i > 0:
			indices.append_array([prev_top, prev_bot, top, prev_bot, bot, top])
		prev_top = top
		prev_bot = bot
	return _shape_mesh(verts, indices, color, energy)

func _runtime_profile(source: VFXProfile3D, race: String, ranged: bool) -> VFXProfile3D:
	var p := source.duplicate_runtime()
	p.parameters = p.parameters.duplicate()
	p.parameters["race"] = race
	# Same world-scale calibration as the painted layers: the authored numbers
	# assume a ~1.7 unit tall fighter, the real ones are ~0.45.
	p.size = vfx_size(p.size)
	var s := VFX_SIZE_SCALE
	match race:
		"god":
			p.parameters["radius"] = 0.62 * s if ranged else 0.78 * s
			p.parameters["arc_degrees"] = 112.0
			p.parameters["tilt_degrees"] = 24.0
			p.parameters["width"] = 0.18 * s
		"dark":
			p.parameters["radius"] = 0.78 * s if ranged else 0.94 * s
			p.parameters["arc_degrees"] = 148.0
			p.parameters["tilt_degrees"] = -14.0
			p.parameters["width"] = 0.25 * s
		"undead":
			p.parameters["radius"] = 0.70 * s if ranged else 0.86 * s
			p.parameters["arc_degrees"] = 126.0
			p.parameters["tilt_degrees"] = 8.0
			p.parameters["width"] = 0.23 * s
		_:
			p.parameters["radius"] = 0.58 * s if ranged else 0.74 * s
			p.parameters["arc_degrees"] = 94.0
			p.parameters["tilt_degrees"] = 18.0
			p.parameters["width"] = 0.16 * s
	return p

func _spawn_shards(at: Vector3, direction: Vector3, profile: VFXProfile3D, race: String, impact: bool) -> void:
	var count := 3 if impact else 3
	var fan := _fan_width(race)
	for i in range(count):
		var t := 0.5 if count <= 1 else float(i) / float(count - 1)
		var angle := lerpf(-fan, fan, t)
		var out := direction.rotated(Vector3.FORWARD, angle).normalized()
		if impact:
			out = -out
		var length := profile.size * (0.24 + 0.09 * float(i % 3))
		var shard := _triangle_shard(length, profile.size * (0.026 + 0.009 * float(i % 2)), profile.core_color if i % 3 == 0 else profile.main_color, profile.emission_energy)
		shard.position = at
		shard.rotation.z = atan2(out.y, out.x)
		shard.scale = Vector3.ONE * 0.22
		add_child(shard)
		var travel := profile.size * (0.34 + 0.10 * float((i + 1) % 3))
		var duration := profile.duration * (0.16 + 0.025 * float(i % 2))
		var tween := track_tween(create_tween())
		tween.set_parallel(true)
		tween.tween_property(shard, "position", at + out * travel, duration).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
		tween.tween_property(shard, "scale", Vector3(0.04, 0.04, 1.0), duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tween.set_parallel(false)
		tween.tween_callback(shard.queue_free)

func _triangle_shard(length: float, width: float, color: Color, energy: float) -> MeshInstance3D:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(-length * 0.45, -width, 0.0), Vector3(length * 0.55, 0.0, 0.0), Vector3(-length * 0.45, width, 0.0)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	# 走共享缓存：碎片形状只依赖 length/width，材质只依赖 color/energy。
	var shard_key := "shard|%.4f|%.4f" % [length, width]
	var mesh: ArrayMesh = _mesh_cache.get(shard_key)
	if mesh == null:
		mesh = ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		_mesh_cache[shard_key] = mesh
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.material_override = _bolt_material(color, energy)
	return node

func _fan_width(race: String) -> float:
	match race:
		"god": return 0.72
		"dark": return 1.18
		"undead": return 0.96
		_: return 0.52

func _impact_scale(race: String) -> float:
	match race:
		"dark": return 1.30
		"undead": return 1.18
		"god": return 1.08
		_: return 0.92
