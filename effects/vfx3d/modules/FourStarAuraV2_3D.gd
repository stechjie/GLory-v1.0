extends Node3D
## Production four-star presentation shared by preparation and battle actors.
## Gameplay state remains outside this module; callers only pass visual state.

const PROFILE := preload("res://effects/vfx3d/profiles/examples/four_star_envelope_v2_example.tres")
const ENVELOPE_SHADER := preload("res://effects/vfx3d/shaders/four_star_envelope_v2.gdshader")
const GROUND_SHADER := preload("res://effects/vfx3d/shaders/four_star_ground_v2.gdshader")
const RIM_SHADER := preload("res://effects/vfx3d/shaders/four_star_rim.gdshader")

static var _mesh_cache: Dictionary = {}
static var _particle_texture: Texture2D

static func sync(actor: Node3D, state: int, affinity: String, height := 1.0, battle := false) -> Node3D:
	var aura := actor.get_node_or_null("FourStarAuraV2") as Node3D
	if aura == null and state > 0 and affinity in ["sky", "land", "ren"]:
		aura = load("res://effects/vfx3d/modules/FourStarAuraV2_3D.gd").new()
		aura.name = "FourStarAuraV2"
		actor.add_child(aura)
	if aura != null:
		if state > 0:
			aura.configure(affinity, height, battle)
		else:
			aura.deactivate()
	return aura

var profile: Resource = PROFILE
var element := "sky"
var in_battle := false
var configured := false
var age := 0.0
var burst_age := -1.0
var persistent_body: MeshInstance3D
var persistent_mantle: MeshInstance3D
var persistent_ground: MeshInstance3D
var burst_body: MeshInstance3D
var burst_mantle: MeshInstance3D
var burst_ground: MeshInstance3D
var body_material: ShaderMaterial
var ground_material: ShaderMaterial
var burst_body_material: ShaderMaterial
var burst_ground_material: ShaderMaterial
var motes: GPUParticles3D
var burst_motes: GPUParticles3D
var rim_material: ShaderMaterial
var rim_meshes: Array[MeshInstance3D] = []

static func fit_to_actor(aura: Node3D, actor: Node3D, fallback_world_height := 0.24) -> void:
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
	aura.position = actor.to_local(foot - Vector3.UP * height * 0.025)
	if aura.has_method("attach_rim"):
		aura.call("attach_rim", actor)

func configure(affinity: String, world_height := 1.0, battle := false) -> void:
	if affinity not in ["sky", "land", "ren"]:
		deactivate()
		return
	var rebuild := not configured or element != affinity or in_battle != battle
	element = affinity
	in_battle = battle
	scale = Vector3.ONE * maxf(0.25, world_height)
	visible = true
	if rebuild:
		_build(battle)
		configured = true
	set_process(true)

func deactivate() -> void:
	visible = false
	set_process(false)
	burst_age = -1.0
	if burst_body != null:
		burst_body.visible = false
	if burst_mantle != null:
		burst_mantle.visible = false
	if burst_ground != null:
		burst_ground.visible = false
	if burst_motes != null:
		burst_motes.emitting = false
	_clear_rim()

func attach_rim(actor: Node3D) -> void:
	_clear_rim()
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

func play_upgrade() -> void:
	if burst_body == null:
		return
	burst_age = 0.0
	burst_body.visible = true
	burst_mantle.visible = true
	burst_ground.visible = true
	burst_body_material.set_shader_parameter("clock", 0.0)
	burst_ground_material.set_shader_parameter("clock", 0.0)
	burst_motes.restart()
	burst_motes.emitting = true

func _process(delta: float) -> void:
	age += delta
	body_material.set_shader_parameter("clock", age)
	ground_material.set_shader_parameter("clock", age)
	rim_material.set_shader_parameter("clock", age)
	# Opposing drift prevents the aura from reading as a single rotating ring.
	persistent_body.rotation.y = sin(age * 0.42) * 0.16
	persistent_mantle.rotation.y = -sin(age * 0.31) * 0.11
	persistent_ground.rotation.y = -age * 0.10
	if burst_age >= 0.0:
		burst_age += delta
		burst_body_material.set_shader_parameter("clock", burst_age)
		burst_ground_material.set_shader_parameter("clock", burst_age)
		burst_body.rotation.y = -burst_age * 0.34
		burst_mantle.rotation.y = burst_age * 0.18
		if burst_age >= float(profile.duration) + 0.12:
			burst_body.visible = false
			burst_mantle.visible = false
			burst_ground.visible = false
			burst_age = -1.0

func _exit_tree() -> void:
	_clear_rim()

func _clear_rim() -> void:
	for mesh in rim_meshes:
		if is_instance_valid(mesh) and mesh.material_overlay == rim_material:
			mesh.material_overlay = null
	rim_meshes.clear()

func _build(battle: bool) -> void:
	_clear_rim()
	for child in get_children():
		child.queue_free()
	body_material = _envelope_material(false, battle)
	ground_material = _ground_material(false, battle)
	burst_body_material = _envelope_material(true, battle)
	burst_ground_material = _ground_material(true, battle)
	persistent_body = _mesh_node("PersistentEnvelope", _envelope_mesh(false), body_material)
	persistent_mantle = _mesh_node("PersistentMantle", _mantle_mesh(false), body_material)
	persistent_ground = _mesh_node("PersistentGroundFlow", _ground_mesh(false), ground_material)
	burst_body = _mesh_node("AscensionEnvelope", _envelope_mesh(true), burst_body_material)
	burst_mantle = _mesh_node("AscensionMantle", _mantle_mesh(true), burst_body_material)
	burst_ground = _mesh_node("AscensionGroundFlow", _ground_mesh(true), burst_ground_material)
	burst_body.visible = false
	burst_mantle.visible = false
	burst_ground.visible = false
	motes = _particles(false, battle)
	burst_motes = _particles(true, battle)
	burst_motes.emitting = false
	rim_material = ShaderMaterial.new()
	rim_material.shader = RIM_SHADER
	rim_material.set_shader_parameter("eligible", 0.0)
	rim_material.set_shader_parameter("opacity", 0.50 if battle else 0.62)
	rim_material.set_shader_parameter("tint", _palette()[1])

func _palette() -> Array[Color]:
	match element:
		"land": return [Color(0.20, 0.065, 0.015), Color(0.92, 0.48, 0.07), Color(1.0, 0.88, 0.42)]
		"ren": return [Color(0.22, 0.025, 0.018), Color(0.86, 0.18, 0.08), Color(1.0, 0.74, 0.36)]
		_: return [Color(0.018, 0.085, 0.18), Color(0.08, 0.66, 0.92), Color(0.74, 0.96, 1.0)]

func _envelope_material(is_burst: bool, battle: bool) -> ShaderMaterial:
	var colors := _palette()
	var material := ShaderMaterial.new()
	material.shader = ENVELOPE_SHADER
	material.set_shader_parameter("dark_color", colors[0])
	material.set_shader_parameter("body_color", colors[1])
	material.set_shader_parameter("core_color", colors[2])
	material.set_shader_parameter("opacity", (0.60 if battle else float(profile.parameters.persistent_opacity)) * (1.12 if is_burst else 1.0))
	material.set_shader_parameter("energy", float(profile.emission_energy) * (1.45 if is_burst else 1.0))
	material.set_shader_parameter("burst", 1.0 if is_burst else 0.0)
	material.set_shader_parameter("burst_duration", float(profile.duration))
	return material

func _ground_material(is_burst: bool, battle: bool) -> ShaderMaterial:
	var colors := _palette()
	var material := ShaderMaterial.new()
	material.shader = GROUND_SHADER
	material.set_shader_parameter("dark_color", colors[0])
	material.set_shader_parameter("body_color", colors[1])
	material.set_shader_parameter("core_color", colors[2])
	material.set_shader_parameter("opacity", (0.22 if battle else 0.30) * (1.38 if is_burst else 1.0))
	material.set_shader_parameter("burst", 1.0 if is_burst else 0.0)
	return material

func _mesh_node(node_name: String, mesh: ArrayMesh, material: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = mesh
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.extra_cull_margin = 0.8
	add_child(node)
	return node

func _envelope_mesh(is_burst: bool) -> ArrayMesh:
	var key := "envelope/%s/%s" % [element, str(is_burst)]
	if _mesh_cache.has(key):
		return _mesh_cache[key]
	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var ribbon_count := 6 if is_burst else int(profile.parameters.ribbon_count)
	var ribbon_angles := PackedFloat32Array([-2.55, -1.82, -0.58, 0.15, 0.68, 2.48])
	var base_radius := float(profile.parameters.radius) * (1.10 if is_burst else 1.0)
	for ribbon in ribbon_count:
		var seed := float(ribbon) / float(maxi(1, ribbon_count - 1))
		var start := ribbon_angles[ribbon]
		var direction := -1.0 if ribbon % 3 == 1 else 1.0
		var height := 0.86 + 0.28 * sin(float(ribbon) * 1.71)
		if is_burst:
			height *= 1.20
		var base := vertices.size()
		for step in 21:
			var t := float(step) / 20.0
			# Each strand is an upright, curling energy leaf rooted around the unit's
			# footprint.  Different lean and height values avoid a cylindrical cage.
			var curl := direction * (0.16 + 0.16 * seed) * sin(t * PI) + direction * t * 0.10
			var angle := start + curl
			var irregular := 1.0 + 0.08 * sin(t * 9.0 + ribbon * 1.9)
			var radius := base_radius * irregular * (1.0 - t * (0.12 + 0.05 * seed))
			var lift := 0.025 + t * height + 0.055 * sin(t * PI * 2.0 + ribbon)
			var center := Vector3(cos(angle) * radius, lift, sin(angle) * radius * 0.82)
			var tangent := Vector3(-sin(angle), 0.10 * direction, cos(angle) * 0.82).normalized()
			var width := (0.155 + 0.035 * sin(ribbon * 1.7)) * pow(sin(t * PI), 0.52)
			if is_burst:
				width *= 1.22
			vertices.append(center - tangent * width)
			vertices.append(center + tangent * width)
			uvs.append_array(PackedVector2Array([Vector2(t, 0), Vector2(t, 1)]))
			var near_side := clampf(0.5 + 0.5 * sin(angle), 0.0, 1.0)
			var color := Color(seed, float(ribbon % 4) / 3.0, near_side, 1.0)
			colors.append_array(PackedColorArray([color, color]))
			if step < 20:
				var i := base + step * 2
				indices.append_array(PackedInt32Array([i, i + 1, i + 3, i, i + 3, i + 2]))
	var mesh := _arrays_to_mesh(vertices, uvs, colors, indices)
	_mesh_cache[key] = mesh
	return mesh

func _mantle_mesh(is_burst: bool) -> ArrayMesh:
	var key := "mantle/%s/%s" % [element, str(is_burst)]
	if _mesh_cache.has(key):
		return _mesh_cache[key]
	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var segment_count := 6 if is_burst else 4
	var mantle_angles := PackedFloat32Array([-2.82, -2.05, -1.08, -0.28, 0.42, 2.72])
	for segment in segment_count:
		var seed := float(segment) / float(maxi(1, segment_count - 1))
		# Elevated curling strokes fill the left, right and rear silhouette that a
		# top-down camera can actually see. They stay broken to avoid a cage shape.
		var center_angle := mantle_angles[segment]
		var direction := -1.0 if segment % 2 else 1.0
		var base_height := 0.24 + 0.055 * float(segment % 3)
		var strand_height := 0.58 + 0.12 * sin(segment * 1.61)
		if is_burst: strand_height *= 1.20
		var base := vertices.size()
		for step in 19:
			var t := float(step) / 18.0
			var angle := center_angle + direction * (0.13 * sin(t * PI) + t * 0.075)
			var radius := float(profile.parameters.radius) * (0.76 + 0.055 * sin(t * 8.0 + segment * 1.9))
			if is_burst:
				radius *= 1.06
			var lift := base_height + t * strand_height + 0.035 * sin(t * PI * 2.0 + segment)
			var center := Vector3(cos(angle) * radius, lift, sin(angle) * radius * 0.76 - 0.06)
			var tangent := Vector3(-sin(angle), 0.08 * direction, cos(angle) * 0.76).normalized()
			var width := (0.15 + 0.025 * float(segment % 3)) * pow(sin(t * PI), 0.50)
			if is_burst:
				width *= 1.18
			vertices.append(center - tangent * width)
			vertices.append(center + tangent * width)
			uvs.append_array(PackedVector2Array([Vector2(t, 0), Vector2(t, 1)]))
			var near_side := clampf(0.5 + 0.5 * sin(angle), 0.0, 1.0)
			var color := Color(seed, float(segment % 4) / 3.0, near_side, 1.0)
			colors.append_array(PackedColorArray([color, color]))
			if step < 18:
				var i := base + step * 2
				indices.append_array(PackedInt32Array([i, i + 1, i + 3, i, i + 3, i + 2]))
	var mesh := _arrays_to_mesh(vertices, uvs, colors, indices)
	_mesh_cache[key] = mesh
	return mesh

func _ground_mesh(is_burst: bool) -> ArrayMesh:
	var key := "ground/%s/%s" % [element, str(is_burst)]
	if _mesh_cache.has(key):
		return _mesh_cache[key]
	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var count := 4 if is_burst else int(profile.parameters.ground_arc_count)
	for arc in count:
		var seed := float(arc) / float(maxi(1, count - 1))
		var start := 0.5 + seed * TAU + 0.31 * sin(arc * 2.7)
		var sweep := (2.7 + 0.35 * sin(arc * 1.4)) * (-1.0 if arc % 2 else 1.0)
		var base := vertices.size()
		for step in 19:
			var t := float(step) / 18.0
			var angle := start + sweep * t
			var radius := float(profile.parameters.ground_radius) * (0.82 + seed * 0.19 + 0.055 * sin(t * 11.0 + arc))
			if is_burst:
				radius *= 1.12
			var center := Vector3(cos(angle) * radius, 0.018 + seed * 0.012, sin(angle) * radius * 0.72)
			var radial := Vector3(cos(angle), 0.0, sin(angle) * 0.72).normalized()
			var width := (0.09 + 0.018 * arc) * pow(sin(t * PI), 0.55)
			vertices.append(center - radial * width)
			vertices.append(center + radial * width)
			uvs.append_array(PackedVector2Array([Vector2(t, 0), Vector2(t, 1)]))
			var color := Color(seed, float(arc % 3) / 2.0, 0.0, 1.0)
			colors.append_array(PackedColorArray([color, color]))
			if step < 18:
				var i := base + step * 2
				indices.append_array(PackedInt32Array([i, i + 1, i + 3, i, i + 3, i + 2]))
	var mesh := _arrays_to_mesh(vertices, uvs, colors, indices)
	_mesh_cache[key] = mesh
	return mesh

func _arrays_to_mesh(vertices: PackedVector3Array, uvs: PackedVector2Array, colors: PackedColorArray, indices: PackedInt32Array) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

func _particles(is_burst: bool, battle: bool) -> GPUParticles3D:
	var node := GPUParticles3D.new()
	node.name = "AscensionMotes" if is_burst else "OrbitMotes"
	node.amount = int(profile.particle_count) if is_burst else 8
	node.lifetime = 0.82 if is_burst else 1.65
	node.one_shot = is_burst
	node.randomness = 0.42
	node.visibility_aabb = AABB(Vector3(-0.8, -0.1, -0.8), Vector3(1.6, 1.4, 1.6))
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = 0.42
	process.direction = Vector3(0.0, 1.0, 0.0)
	process.spread = 34.0 if is_burst else 18.0
	process.initial_velocity_min = 0.42 if is_burst else 0.12
	process.initial_velocity_max = 0.82 if is_burst else 0.28
	process.gravity = Vector3(0.0, 0.08, 0.0)
	process.scale_min = 0.60
	process.scale_max = 1.28
	var gradient := Gradient.new()
	var palette := _palette()
	gradient.colors = PackedColorArray([Color(palette[1], 0.0), Color(palette[2], 0.92), Color(palette[1], 0.0)])
	gradient.offsets = PackedFloat32Array([0.0, 0.20, 1.0])
	process.color_ramp = GradientTexture1D.new()
	process.color_ramp.gradient = gradient
	node.process_material = process
	var quad := QuadMesh.new()
	quad.size = Vector2(0.075, 0.16) * (1.35 if is_burst else 1.0)
	quad.orientation = PlaneMesh.FACE_Z
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.albedo_texture = _soft_mote_texture()
	material.emission_enabled = true
	material.emission = palette[1]
	material.emission_energy_multiplier = (1.1 if is_burst else 0.55) * (0.82 if battle else 1.0)
	quad.material = material
	node.draw_pass_1 = quad
	add_child(node)
	return node

static func _soft_mote_texture() -> Texture2D:
	if _particle_texture != null:
		return _particle_texture
	var image := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	for y in 32:
		for x in 32:
			var uv := Vector2((float(x) + 0.5) / 32.0, (float(y) + 0.5) / 32.0)
			var dx := (uv.x - 0.5) / (0.30 + uv.y * 0.12)
			var dy := (uv.y - 0.48) / 0.50
			var d := sqrt(dx * dx + dy * dy)
			var alpha := clampf((1.0 - d) * 2.8, 0.0, 1.0) * smoothstep(0.0, 0.16, uv.y) * (1.0 - smoothstep(0.82, 1.0, uv.y))
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha))
	_particle_texture = ImageTexture.create_from_image(image)
	return _particle_texture
