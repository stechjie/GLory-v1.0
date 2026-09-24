extends Node3D
## Four-star persistent presentation V3: ground ring + element particles + body rim.
## Layers: ground ring + aura column (overlaps the model) + particles + rim.
## Three art styles, one per element:
##   sky  = soft glow   (double ring + wind streaks, drifting feathers + sparkles)
##   land = low-poly    (faceted 12-gon ring, faceted ember shards + sparks)
##   ren  = toon        (thick outlined ring, lightning flicks + outlined embers)
## Presentation only: never reads or changes combat stats, skills or inventory.
##
## Drop-in replacement for FourStarAuraV2_3D. Public API is identical
## (sync / fit_to_actor / configure / deactivate / attach_rim / play_upgrade),
## and the node keeps the name "FourStarAuraV2" so existing get_node lookups in
## PrepBoardModels.gd and BattleRenderer.gd keep working. Swapping = change the
## two preload paths.
##
## All geometry is in actor-height units (height = 1.0); the node is scaled by
## fit_to_actor / configure. Particles use local coords so they scale with it.
## Meshes, materials and textures are static caches shared by every aura.

const SCRIPT_PATH := "res://effects/vfx3d/modules/FourStarAuraV3_3D.gd"
const NODE_NAME := "FourStarAuraV2"
const RING_SHADER := preload("res://effects/vfx3d/shaders/four_star_ring_v3.gdshader")
const COLUMN_SHADER := preload("res://effects/vfx3d/shaders/four_star_column_v3.gdshader")
const RIM_SHADER := preload("res://effects/vfx3d/shaders/four_star_rim.gdshader")
const ELEMENTS := ["sky", "land", "ren"]

const RING_RADIUS := 0.82        # default ring centre-line radius, in actor heights
const TEAM_RING_UV_RADIUS := 0.825  # centre of the band in shaders/unit_team_ring.gdshader
const RING_UV_RADIUS := 0.80     # must match ring_radius in the shader
const RING_Z_SCALE := 0.86       # slight squash so neighbouring cells don't overlap
const COLUMN_HEIGHT := 0.95      # aura wall height, in actor heights (overlaps the model on purpose)
const PREP_PRIORITY := 10        # prep floor/bench are transparent layers at 0–7
const BATTLE_PRIORITY := 0

static var _ring_mesh: PlaneMesh
static var _ring_materials: Dictionary = {}
static var _column_mesh: ArrayMesh
static var _column_materials: Dictionary = {}
static var _particle_parts: Dictionary = {}
static var _textures: Dictionary = {}

var element := "sky"
var in_battle := false
var configured := false
var ring: MeshInstance3D
## Ring centre-line radius in aura units. fit_to_actor() sets it so the aura
## hugs the circle already under the unit instead of spreading outward.
var footprint := RING_RADIUS
var column: MeshInstance3D
var particles: Array[GPUParticles3D] = []
var rim_material: ShaderMaterial
var rim_meshes: Array[MeshInstance3D] = []

# ---------------------------------------------------------------- public API

static func sync(actor: Node3D, state: int, affinity: String, height := 1.0, battle := false) -> Node3D:
	var aura := actor.get_node_or_null(NODE_NAME) as Node3D
	if aura == null and state > 0 and affinity in ELEMENTS:
		aura = load(SCRIPT_PATH).new()
		aura.name = NODE_NAME
		actor.add_child(aura)
	if aura != null:
		if state > 0:
			aura.configure(affinity, height, battle)
		else:
			aura.deactivate()
	return aura

static func fit_to_actor(aura: Node3D, actor: Node3D, fallback_world_height := 0.24, footprint_world_radius := -1.0) -> void:
	if aura == null or actor == null or not actor.is_inside_tree():
		return
	var foot := actor.global_position
	var height := fallback_world_height
	var foot_anchor := actor.get_node_or_null("FootAnchor") as Node3D
	var head_anchor := actor.get_node_or_null("HeadAnchor") as Node3D
	if foot_anchor != null:
		foot = foot_anchor.global_position
	if foot_anchor != null and head_anchor != null:
		height = maxf(0.01, head_anchor.global_position.distance_to(foot) * 1.18)
	var local_scale := maxf(0.001, actor.global_basis.get_scale().x)
	aura.scale = Vector3.ONE * height / local_scale
	aura.position = actor.to_local(foot - Vector3.UP * height * 0.01)
	# Snap the ring onto the unit's existing ground circle. Battle actors carry
	# TeamGlow3D (unit_team_ring.gdshader); prep passes its cell-mark radius.
	var r_world := footprint_world_radius
	var glow := actor.get_node_or_null("TeamGlow3D") as MeshInstance3D
	if glow != null and glow.mesh is PlaneMesh:
		r_world = (glow.mesh as PlaneMesh).size.x * 0.5 * TEAM_RING_UV_RADIUS * glow.global_basis.get_scale().x
	if r_world > 0.0 and aura.has_method("set_footprint"):
		aura.call("set_footprint", r_world / maxf(0.001, height))
	if aura.has_method("attach_rim"):
		aura.call("attach_rim", actor)

func configure(affinity: String, world_height := 1.0, battle := false) -> void:
	if affinity not in ELEMENTS:
		deactivate()
		return
	var rebuild := not configured or element != affinity or in_battle != battle
	element = affinity
	in_battle = battle
	scale = Vector3.ONE * maxf(0.25, world_height)
	visible = true
	if rebuild:
		_build()
		configured = true
	for p in particles:
		p.emitting = true
	# Everything animates on the GPU (TIME in shaders, GPU particles),
	# so no per-frame script work is needed.
	set_process(false)

func deactivate() -> void:
	visible = false
	set_process(false)
	for p in particles:
		p.emitting = false
	_clear_rim()

func attach_rim(actor: Node3D) -> void:
	_clear_rim()
	if rim_material == null:
		return
	for node in actor.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if is_ancestor_of(mesh) or not mesh.is_visible_in_tree() or mesh.material_overlay != null:
			continue
		if mesh.name in ["ContactShadow3D", "GroundShadow3D", "TeamGlow3D"]:
			continue
		mesh.material_overlay = rim_material
		rim_meshes.append(mesh)
		if rim_meshes.size() >= 8:
			break

func set_footprint(radius: float) -> void:
	radius = clampf(radius, 0.15, 1.2)
	if absf(radius - footprint) < 0.005:
		return
	footprint = radius
	if configured:
		_build()

## Kept for API compatibility. V3 has no ascension burst by design.
func play_upgrade() -> void:
	pass

func _exit_tree() -> void:
	_clear_rim()

func _clear_rim() -> void:
	for mesh in rim_meshes:
		if is_instance_valid(mesh) and mesh.material_overlay == rim_material:
			mesh.material_overlay = null
	rim_meshes.clear()

# ---------------------------------------------------------------- build

func _build() -> void:
	_clear_rim()
	for child in get_children():
		remove_child(child)
		child.queue_free()
	particles.clear()
	var palette := _palette(element)

	ring = MeshInstance3D.new()
	ring.name = "GroundRing"
	ring.mesh = _get_ring_mesh()
	ring.material_override = _get_ring_material(element, in_battle)
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ring.position.y = 0.012
	var fp := footprint / RING_RADIUS
	ring.scale = Vector3(fp, 1.0, fp * RING_Z_SCALE)
	add_child(ring)

	column = MeshInstance3D.new()
	column.name = "AuraColumn"
	column.mesh = _get_column_mesh()
	column.material_override = _get_column_material(element, in_battle)
	column.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	column.scale = Vector3(fp, 1.0, fp * RING_Z_SCALE)
	add_child(column)

	for kind in _particle_kinds(element):
		particles.append(_make_particles(kind))

	rim_material = ShaderMaterial.new()
	rim_material.shader = RIM_SHADER
	rim_material.render_priority = BATTLE_PRIORITY if in_battle else PREP_PRIORITY
	rim_material.set_shader_parameter("eligible", 0.0)
	rim_material.set_shader_parameter("opacity", 0.70 if in_battle else 0.85)
	rim_material.set_shader_parameter("tint", palette[1])

static func _palette(elem: String) -> Array[Color]:
	# [dark/outline, body, core]
	match elem:
		"land": return [Color(0.48, 0.10, 0.0), Color(1.0, 0.46, 0.04), Color(1.0, 0.88, 0.45)]
		"ren": return [Color(0.34, 0.0, 0.04), Color(0.92, 0.08, 0.20), Color(1.0, 0.80, 0.70)]
		_: return [Color(0.01, 0.10, 0.42), Color(0.08, 0.46, 1.0), Color(0.82, 0.95, 1.0)]

static func _get_ring_mesh() -> PlaneMesh:
	if _ring_mesh == null:
		_ring_mesh = PlaneMesh.new()
		var half := RING_RADIUS / RING_UV_RADIUS
		_ring_mesh.size = Vector2(half * 2.0, half * 2.0)
	return _ring_mesh

static func _get_ring_material(elem: String, battle: bool) -> ShaderMaterial:
	var key := "%s/%s" % [elem, battle]
	if _ring_materials.has(key):
		return _ring_materials[key]
	var palette := _palette(elem)
	var mat := ShaderMaterial.new()
	mat.shader = RING_SHADER
	mat.render_priority = BATTLE_PRIORITY if battle else PREP_PRIORITY
	mat.set_shader_parameter("style", ELEMENTS.find(elem))
	mat.set_shader_parameter("dark_color", palette[0])
	mat.set_shader_parameter("body_color", palette[1])
	mat.set_shader_parameter("core_color", palette[2])
	mat.set_shader_parameter("opacity", 1.0)
	mat.set_shader_parameter("ring_radius", RING_UV_RADIUS)
	_ring_materials[key] = mat
	return mat

static func _get_column_mesh() -> ArrayMesh:
	if _column_mesh != null:
		return _column_mesh
	var segs := 40
	var r0 := RING_RADIUS * 1.00  # wall stands on the ring, not inside the body
	var r1 := RING_RADIUS * 0.92
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for i in segs + 1:  # duplicate seam column so UV.x runs 0..1 cleanly
		var t := float(i) / segs
		var ang := TAU * t
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		verts.append(dir * r0 + Vector3.UP * 0.01)
		verts.append(dir * r1 + Vector3.UP * COLUMN_HEIGHT)
		uvs.append(Vector2(t, 0.0))
		uvs.append(Vector2(t, 1.0))
		if i < segs:
			var b := i * 2
			idx.append_array(PackedInt32Array([b, b + 2, b + 1, b + 1, b + 2, b + 3]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	_column_mesh = ArrayMesh.new()
	_column_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return _column_mesh

static func _get_column_material(elem: String, battle: bool) -> ShaderMaterial:
	var key := "%s/%s" % [elem, battle]
	if _column_materials.has(key):
		return _column_materials[key]
	var palette := _palette(elem)
	var mat := ShaderMaterial.new()
	mat.shader = COLUMN_SHADER
	mat.render_priority = BATTLE_PRIORITY if battle else PREP_PRIORITY
	mat.set_shader_parameter("style", ELEMENTS.find(elem))
	mat.set_shader_parameter("dark_color", palette[0])
	mat.set_shader_parameter("body_color", palette[1])
	mat.set_shader_parameter("core_color", palette[2])
	mat.set_shader_parameter("opacity", 0.85 if battle else 0.95)
	mat.set_shader_parameter("front_opacity", 0.55 if battle else 0.62)
	_column_materials[key] = mat
	return mat

# ---------------------------------------------------------------- particles

static func _particle_kinds(elem: String) -> Array[String]:
	match elem:
		"land": return ["land_shard", "land_spark"]
		"ren": return ["ren_bolt", "ren_ember"]
		_: return ["sky_feather", "sky_sparkle"]

func _make_particles(kind: String) -> GPUParticles3D:
	var parts: Dictionary = _get_particle_parts(kind, in_battle, footprint)
	var node := GPUParticles3D.new()
	node.name = kind
	node.local_coords = true
	node.amount = parts.amount
	node.lifetime = parts.lifetime
	node.preprocess = parts.lifetime
	node.randomness = 0.5
	node.process_material = parts.process
	node.draw_pass_1 = parts.mesh
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.visibility_aabb = AABB(Vector3(-1.5, -0.1, -1.5), Vector3(3.0, 2.4, 3.0))
	add_child(node)
	return node

static func _get_particle_parts(kind: String, battle: bool, radius: float) -> Dictionary:
	var key := "%s/%s/%.2f" % [kind, battle, radius]
	if _particle_parts.has(key):
		return _particle_parts[key]
	var elem := kind.get_slice("_", 0)
	var palette := _palette(elem)
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	pm.emission_ring_axis = Vector3.UP
	pm.emission_ring_radius = radius
	pm.emission_ring_inner_radius = radius * 0.80
	pm.emission_ring_height = 0.0
	pm.direction = Vector3.UP
	pm.gravity = Vector3.ZERO
	var amount := 6
	var lifetime := 1.0
	var size := Vector2(0.1, 0.1)
	var offset := Vector3.ZERO
	var tex_name := ""
	var frames := 1
	var billboard := BaseMaterial3D.BILLBOARD_PARTICLES
	var ramp: PackedColorArray
	var ramp_at: PackedFloat32Array
	var curve: Array = []  # scale over life [[t, v], ...]

	match kind:
		"sky_feather":
			amount = 12; lifetime = 2.8
			size = Vector2(0.32, 0.32); tex_name = "feather"
			pm.emission_ring_inner_radius = radius * 0.55
			pm.spread = 12.0
			pm.initial_velocity_min = 0.18; pm.initial_velocity_max = 0.30
			pm.tangential_accel_min = 0.10; pm.tangential_accel_max = 0.22
			pm.damping_min = 0.02; pm.damping_max = 0.05
			pm.radial_accel_min = -0.12; pm.radial_accel_max = -0.04
			pm.angle_min = -180.0; pm.angle_max = 180.0
			pm.angular_velocity_min = -70.0; pm.angular_velocity_max = 70.0
			pm.scale_min = 0.75; pm.scale_max = 1.2
			ramp = PackedColorArray([Color(1, 1, 1, 0), Color(0.95, 0.99, 1.0, 1.0), Color(0.80, 0.92, 1.0, 0.9), Color(0.70, 0.86, 1.0, 0)])
			ramp_at = PackedFloat32Array([0.0, 0.15, 0.7, 1.0])
			curve = [[0.0, 0.6], [0.2, 1.0], [1.0, 0.85]]
		"sky_sparkle":
			amount = 12; lifetime = 0.9
			size = Vector2(0.28, 0.28); tex_name = "sparkle"
			pm.emission_ring_height = 0.9
			pm.emission_ring_inner_radius = radius * 0.7
			pm.initial_velocity_min = 0.02; pm.initial_velocity_max = 0.08
			pm.scale_min = 0.6; pm.scale_max = 1.3
			ramp = PackedColorArray([palette[2], Color(1, 1, 1, 1), palette[1]])
			ramp_at = PackedFloat32Array([0.0, 0.4, 1.0])
			curve = [[0.0, 0.0], [0.25, 1.0], [0.55, 0.35], [1.0, 0.0]]
		"land_shard":
			amount = 22; lifetime = 1.4
			size = Vector2(0.11, 0.11); tex_name = "dot"   # round embers, no triangles
			pm.spread = 8.0
			pm.initial_velocity_min = 0.35; pm.initial_velocity_max = 0.60
			pm.gravity = Vector3(0.0, -0.22, 0.0)
			pm.angle_min = -180.0; pm.angle_max = 180.0
			pm.angular_velocity_min = -220.0; pm.angular_velocity_max = 220.0
			pm.scale_min = 0.6; pm.scale_max = 1.25
			ramp = PackedColorArray([palette[2], palette[1], palette[0].lerp(palette[1], 0.4), Color(palette[0], 0.0)])
			ramp_at = PackedFloat32Array([0.0, 0.3, 0.75, 1.0])
			curve = [[0.0, 1.0], [0.7, 0.8], [1.0, 0.0]]
		"land_spark":
			amount = 18; lifetime = 1.8
			size = Vector2(0.09, 0.09); tex_name = "dot"
			pm.emission_ring_inner_radius = radius * 0.4
			pm.spread = 30.0
			pm.initial_velocity_min = 0.12; pm.initial_velocity_max = 0.28
			pm.tangential_accel_min = -0.1; pm.tangential_accel_max = 0.1
			ramp = PackedColorArray([Color(palette[2], 0.0), palette[2], Color(palette[1], 0.0)])
			ramp_at = PackedFloat32Array([0.0, 0.2, 1.0])
		"ren_bolt":
			amount = 7; lifetime = 0.42
			size = Vector2(0.42, 0.95); tex_name = "bolt"; frames = 2
			offset = Vector3(0.0, 0.475, 0.0)   # bolt rises from the ring (screen-up)
			pm.emission_ring_inner_radius = radius * 0.92
			pm.initial_velocity_min = 0.0; pm.initial_velocity_max = 0.0
			pm.anim_offset_min = 0.0; pm.anim_offset_max = 1.0
			pm.scale_min = 0.7; pm.scale_max = 1.15
			# Hard on/off flicker reads as toon lightning.
			ramp = PackedColorArray([Color(1, 0.9, 0.97, 1), Color(0.92, 0.95, 1.0, 1), Color(1, 1, 1, 0), Color(1, 0.9, 0.97, 1), Color(1, 1, 1, 0)])
			ramp_at = PackedFloat32Array([0.0, 0.3, 0.45, 0.6, 0.85])
		"ren_ember":
			amount = 16; lifetime = 1.3
			size = Vector2(0.12, 0.12); tex_name = "toon_ember"
			pm.spread = 20.0
			pm.initial_velocity_min = 0.30; pm.initial_velocity_max = 0.55
			pm.gravity = Vector3(0.0, -0.1, 0.0)
			pm.tangential_accel_min = 0.2; pm.tangential_accel_max = 0.4
			pm.radial_accel_min = -0.15; pm.radial_accel_max = -0.05
			pm.scale_min = 0.7; pm.scale_max = 1.3
			ramp = PackedColorArray([palette[2], palette[1], palette[1]])
			ramp_at = PackedFloat32Array([0.0, 0.35, 1.0])
			curve = [[0.0, 1.0], [0.75, 0.75], [1.0, 0.0]]

	var gradient := Gradient.new()
	gradient.offsets = ramp_at
	gradient.colors = ramp
	# Gradient interpolation constant for the bolt keeps the flicker hard.
	if kind == "ren_bolt":
		gradient.interpolation_mode = Gradient.GRADIENT_INTERPOLATE_CONSTANT
	var ramp_tex := GradientTexture1D.new()
	ramp_tex.gradient = gradient
	pm.color_ramp = ramp_tex
	if not curve.is_empty():
		var c := Curve.new()
		for point in curve:
			c.add_point(Vector2(point[0], point[1]))
		var ct := CurveTexture.new()
		ct.curve = c
		pm.scale_curve = ct

	var quad := QuadMesh.new()
	quad.size = size
	quad.center_offset = offset
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = _get_texture(tex_name)
	mat.billboard_mode = billboard
	mat.billboard_keep_scale = true
	mat.no_depth_test = false
	mat.render_priority = BATTLE_PRIORITY if battle else PREP_PRIORITY
	if frames > 1:
		mat.particles_anim_h_frames = frames
		mat.particles_anim_v_frames = 1
		mat.particles_anim_loop = false
	if battle:
		mat.albedo_color = Color(1, 1, 1, 0.85)
	quad.material = mat

	var parts := {"process": pm, "mesh": quad, "amount": amount, "lifetime": lifetime}
	_particle_parts[key] = parts
	return parts

# ---------------------------------------------------------------- textures
# Generated once at runtime (white RGB shading + alpha); particle colour ramps
# tint them, so one texture serves any palette.

static func _get_texture(tex_name: String) -> Texture2D:
	if _textures.has(tex_name):
		return _textures[tex_name]
	var img: Image
	match tex_name:
		"feather": img = _img_feather()
		"sparkle": img = _img_sparkle()
		"shard": img = _img_shard()
		"bolt": img = _img_bolt()
		"toon_ember": img = _img_toon_ember()
		_: img = _img_dot()
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_textures[tex_name] = tex
	return tex

static func _img_feather() -> Image:
	var n := 64
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			# v: -1 (quill, bottom) .. 1 (tip, top); u across.
			var v := 1.0 - 2.0 * (float(y) + 0.5) / n
			var u := 2.0 * (float(x) + 0.5) / n - 1.0
			var bend := 0.18 * v * v - 0.06
			var du := u - bend
			var t := clampf((v + 0.8) / 1.75, 0.0, 1.0)
			var half := 0.34 * pow(sin(t * PI), 0.7) * (1.0 - 0.25 * t)
			var edge := 1.0 - smoothstep(half - 0.06, half + 0.02, absf(du))
			# Barb notches on alternate sides.
			var notch := smoothstep(0.82, 0.95, sin(v * 16.0 + signf(du) * 1.7)) * smoothstep(half * 0.45, half, absf(du))
			var alpha := edge * (1.0 - notch) * (0.82 + 0.18 * (1.0 - absf(du) / maxf(half, 0.01)))
			var shade := 0.92
			if absf(du) < 0.035 and v > -0.95 and v < 0.9:
				alpha = maxf(alpha, 0.95)
				shade = 0.72
			img.set_pixel(x, y, Color(shade, shade, shade, clampf(alpha, 0.0, 1.0)))
	return img

static func _img_sparkle() -> Image:
	var n := 48
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var u := 2.0 * (float(x) + 0.5) / n - 1.0
			var v := 2.0 * (float(y) + 0.5) / n - 1.0
			var cross := exp(-absf(u) * 16.0) * exp(-absf(v) * 2.6) + exp(-absf(v) * 16.0) * exp(-absf(u) * 2.6)
			var core := exp(-(u * u + v * v) * 22.0)
			var a := clampf(cross + core, 0.0, 1.0) * (1.0 - smoothstep(0.85, 1.0, maxf(absf(u), absf(v))))
			img.set_pixel(x, y, Color(1, 1, 1, a))
	return img

static func _img_shard() -> Image:
	var n := 48
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var u := 2.0 * (float(x) + 0.5) / n - 1.0
			var v := 1.0 - 2.0 * (float(y) + 0.5) / n
			# Kite-shaped shard, longer upward.
			var k := absf(u) / 0.62 + (v / 0.95 if v > 0.0 else -v / 0.55)
			var a := 1.0 - smoothstep(0.96, 1.02, k)
			# Four flat facets (low-poly shading).
			var shade := 1.0
			if u > 0.0 and v > 0.0: shade = 0.78
			elif u <= 0.0 and v <= 0.0: shade = 0.66
			elif u > 0.0 and v <= 0.0: shade = 0.52
			img.set_pixel(x, y, Color(shade, shade, shade, a))
	return img

static func _img_dot() -> Image:
	var n := 32
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var u := 2.0 * (float(x) + 0.5) / n - 1.0
			var v := 2.0 * (float(y) + 0.5) / n - 1.0
			var d := sqrt(u * u + v * v)
			var a := clampf(1.0 - d, 0.0, 1.0)
			a = a * a * (3.0 - 2.0 * a)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	return img

static func _img_toon_ember() -> Image:
	var n := 32
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var u := 2.0 * (float(x) + 0.5) / n - 1.0
			var v := 2.0 * (float(y) + 0.5) / n - 1.0
			var d := sqrt(u * u + v * v)
			var a := 1.0 - smoothstep(0.80, 0.88, d)
			# Hard two-tone: bright centre, darker outline ring.
			var shade := 1.0 if d < 0.52 else 0.5
			img.set_pixel(x, y, Color(shade, shade, shade, a))
	return img

static func _img_bolt() -> Image:
	# Two frames side by side (2 x 48 wide, 128 tall), bottom = ground.
	var fw := 48
	var h := 128
	var img := Image.create(fw * 2, h, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	for frame in 2:
		var pts: Array[Vector2] = []
		var segs := 7
		for i in segs + 1:
			var t := float(i) / segs
			var jitter := 0.0 if i == 0 else rng.randf_range(-0.32, 0.32) * (1.0 - t * 0.3)
			pts.append(Vector2((0.5 + jitter) * fw, (1.0 - t) * (h - 4) + 2))
		for y in h:
			for x in fw:
				var p := Vector2(x + 0.5, y + 0.5)
				var d := 1e9
				for i in segs:
					d = minf(d, _seg_dist(p, pts[i], pts[i + 1]))
				# Taper toward the top.
				var taper := 1.0 - 0.55 * (1.0 - float(y) / h)
				var core := 1.0 - smoothstep(2.0 * taper, 2.9 * taper, d)
				var edge := 1.0 - smoothstep(3.0 * taper, 3.8 * taper, d)
				var glow := (1.0 - smoothstep(3.5, 9.0 * taper, d)) * 0.45
				var a := maxf(maxf(core, edge * 0.95), glow)
				# White core, dark toon outline, soft halo.
				var shade := 1.0 if core > 0.5 else (0.38 if edge > 0.5 else 0.8)
				img.set_pixel(frame * fw + x, y, Color(shade, shade, shade, a))
	return img

static func _seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 0.0001), 0.0, 1.0)
	return p.distance_to(a + ab * t)
