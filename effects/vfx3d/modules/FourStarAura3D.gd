extends Node3D
## Presentation only: never reads or changes combat stats, skills or inventory.
## Two cached aura meshes; optional rim on up to three visible body meshes.
## No lights/particles or per-frame geometry rebuilding.
const PROFILE = preload("res://effects/vfx3d/profiles/examples/four_star_ascension_example.tres")
const AURA_SHADER = preload("res://effects/vfx3d/shaders/four_star_aura.gdshader")
const MASK = preload("res://assets/vfx/textures/slash/slash_blade_mask.png")
static var mesh_cache: Dictionary = {}
var profile: Resource = PROFILE
var element := "sky"
var mode := 0 # 0 hidden, 1 eligible, 2 ascended
var in_battle := false
var age := 0.0
var burst_age := -1.0
var body: MeshInstance3D
var release: MeshInstance3D
var body_material: ShaderMaterial
var release_material: ShaderMaterial
var rim_material: ShaderMaterial
var rim_meshes: Array[MeshInstance3D] = []
var rim_target: WeakRef

func attach_rim(actor: Node3D) -> void:
	if mode == 0 or not rim_meshes.is_empty():
		return
	for node in actor.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if is_ancestor_of(mesh) or not mesh.is_visible_in_tree() or mesh.material_overlay != null or mesh.name in ["ContactShadow3D", "GroundShadow3D", "TeamGlow3D"]:
			continue
		# Preserve any existing gameplay/status overlay rather than replacing it.
		mesh.material_overlay = rim_material
		rim_meshes.append(mesh)
		if rim_meshes.size() >= 3:
			break

func _clear_rim() -> void:
	for mesh in rim_meshes:
		if is_instance_valid(mesh) and mesh.material_overlay == rim_material:
			mesh.material_overlay = null
	rim_meshes.clear()

func _exit_tree() -> void:
	_clear_rim()

static func fit_to_skeleton(aura: Node3D, actor: Node3D, fallback_world_height: float) -> void:
	# Imported skinned AABBs describe the bind pose, not the displayed model.
	# Use live feet/head bones once, then retain this actor-local attachment.
	if not actor.is_inside_tree():
		return
	aura.rim_target = weakref(actor)
	aura.attach_rim(actor)
	var foot := actor.global_position
	var height := fallback_world_height
	var stack: Array[Node] = [actor]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is Node3D and not (node as Node3D).is_visible_in_tree():
			continue
		if node is Skeleton3D:
			var skeleton := node as Skeleton3D
			var feet: Array[Vector3] = []
			var head := Vector3.ZERO
			var has_head := false
			for i in skeleton.get_bone_count():
				var bone_name := skeleton.get_bone_name(i).to_lower()
				var point := skeleton.to_global(skeleton.get_bone_global_pose(i).origin)
				if bone_name.ends_with("head"):
					head = point
					has_head = true
				if bone_name.ends_with("leftfoot") or bone_name.ends_with("rightfoot") or bone_name.ends_with("_l_foot") or bone_name.ends_with("_r_foot"):
					feet.append(point)
			if has_head and not feet.is_empty():
				aura.set_meta("skeleton_fitted", true)
				foot = Vector3.ZERO
				for point in feet:
					foot += point
				foot /= float(feet.size())
				height = maxf(0.01, head.distance_to(foot) * 1.22)
				foot.y -= height * 0.035
				break
		for child in node.get_children():
			if child != aura:
				stack.append(child)
	var local_scale := maxf(0.001, actor.global_basis.get_scale().x)
	aura.scale = Vector3.ONE * height / local_scale
	aura.position = actor.to_local(foot)

static func sync(actor: Node3D, state: int, affinity: String, height := 1.0, battle := false) -> Node3D:
	var aura = actor.get_node_or_null("FourStarAura")
	if aura == null and state > 0 and affinity in ["sky", "land", "ren"]:
		aura = load("res://effects/vfx3d/modules/FourStarAura3D.gd").new()
		aura.name = "FourStarAura"
		actor.add_child(aura)
	if aura != null:
		aura.configure(state, affinity, height, battle)
	return aura

func configure(state: int, affinity: String, height := 1.0, battle := false) -> void:
	if affinity not in ["sky", "land", "ren"]:
		state = 0
	mode = state
	visible = mode > 0
	set_process(visible)
	if not visible:
		_clear_rim()
		burst_age = -1.0
		return
	in_battle = battle
	scale = Vector3.ONE * height
	if body == null or affinity != element:
		element = affinity
		_build()
	var params: Dictionary = profile.parameters
	rim_material.set_shader_parameter("eligible", 1.0 if mode == 1 else 0.0)
	rim_material.set_shader_parameter("opacity", 0.48 if mode == 1 else (0.32 if battle else 0.58))
	rim_material.set_shader_parameter("tint", Color(1.0,0.76,0.28) if mode == 1 else {"sky":Color(0.34,0.83,1.0),"land":Color(1.0,0.66,0.20),"ren":Color(1.0,0.44,0.25)}[element])
	# Prep's painted floor/bench are transparent layers at priorities 0–7.
	# An alpha aura at priority 0 is painted over by those layers regardless
	# of its correct world position. Keep depth testing against characters.
	body_material.render_priority = 0 if battle else 10
	release_material.render_priority = 0 if battle else 10
	rim_material.render_priority = 0 if battle else 10
	body_material.set_shader_parameter("opacity", float(params.get("ready_opacity", 0.38)) if mode == 1 else float(params.get("battle_opacity", 0.58) if battle else params.get("prep_opacity", 0.86)))

func play_upgrade() -> void:
	if mode != 2 or body == null:
		return
	burst_age = 0.0
	release.visible = true
	release_material.set_shader_parameter("clock", 0.0)

func _process(delta: float) -> void:
	if rim_meshes.is_empty() and rim_target != null and rim_target.get_ref() != null:
		attach_rim(rim_target.get_ref())
	age += delta
	body_material.set_shader_parameter("clock", age)
	rim_material.set_shader_parameter("clock", age)
	if burst_age >= 0.0:
		burst_age += delta
		release_material.set_shader_parameter("clock", burst_age)
		if burst_age >= profile.duration + 0.15:
			release.visible = false
			burst_age = -1.0

func _build() -> void:
	_clear_rim()
	rim_material = ShaderMaterial.new()
	rim_material.shader = preload("res://effects/vfx3d/shaders/four_star_rim.gdshader")
	for child in get_children():
		remove_child(child)
		child.queue_free()
	body_material = _material(false)
	release_material = _material(true)
	body = _layer(false, body_material)
	release = _layer(true, release_material)
	release.visible = false
	burst_age = -1.0

func _material(is_burst: bool) -> ShaderMaterial:
	var palettes := {
		"sky": [Color(0.06,0.20,0.31), Color(0.24,0.70,0.84), Color(0.85,0.97,1.0)],
		"land": [Color(0.28,0.10,0.025), Color(0.85,0.48,0.10), Color(1.0,0.87,0.48)],
		"ren": [Color(0.30,0.055,0.04), Color(0.79,0.28,0.14), Color(1.0,0.89,0.68)]}
	var colors: Array = palettes[element]
	var mat := ShaderMaterial.new()
	mat.shader = AURA_SHADER
	mat.set_shader_parameter("blade_mask", MASK)
	mat.set_shader_parameter("dark_color", colors[0])
	mat.set_shader_parameter("body_color", colors[1])
	mat.set_shader_parameter("core_color", colors[2])
	mat.set_shader_parameter("element_mode", float(["sky", "land", "ren"].find(element)))
	mat.set_shader_parameter("burst", 1.0 if is_burst else 0.0)
	mat.set_shader_parameter("opacity", 0.94)
	mat.set_shader_parameter("energy", profile.emission_energy * (1.8 if is_burst else 1.0))
	mat.set_shader_parameter("duration", profile.duration)
	return mat

func _layer(is_burst: bool, mat: ShaderMaterial) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var key := "%s/%s/%s" % [element, is_burst, str(profile.parameters)]
	if not mesh_cache.has(key):
		mesh_cache[key] = _mesh(is_burst)
	node.mesh = mesh_cache[key]
	node.material_override = mat
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.extra_cull_margin = 0.6
	add_child(node)
	return node

func _mesh(is_burst: bool) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var uv := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var count := 6 if is_burst else (3 if element == "sky" else 4)
	var params: Dictionary = profile.parameters
	var radius := float(params.get("radius", 0.32))
	var height := float(params.get("height", 0.92))
	for strand in count:
		var angle := TAU * float(strand) / float(count) + 0.19 * sin(float(strand) * 3.7)
		var base := vertices.size()
		for step in 25:
			var t := float(step) / 24.0
			var theta := angle + t * (1.15 if element == "sky" else (0.98 if element == "land" else 0.52))
			var r := radius * (1.0 + 0.12 * sin(t * 8.0 + strand))
			var y := 0.08 + t * height * 0.78
			if element == "land":
				r *= 1.17 + t * 0.22
				y = 0.045 + sin(t * PI) * height * 0.17
			elif element == "ren":
				r *= 0.85 + sin(t * PI) * 0.20
				y = 0.10 + t * height * 0.55
			if is_burst:
				y *= 1.45 if element != "land" else 2.5
				r *= 1.05 + t * 0.28
			var center := Vector3(cos(theta) * r, y, sin(theta) * r)
			var side := Vector3(cos(theta), 0.14, sin(theta)).normalized()
			if element == "land":
				side = Vector3(cos(theta) * 0.5, 0.9, sin(theta) * 0.5).normalized()
			var width := (0.20 if is_burst else 0.13) * pow(sin(t * PI), 0.65)
			vertices.append(center - side * width)
			vertices.append(center + side * width)
			uv.append_array(PackedVector2Array([Vector2(t,0), Vector2(t,1)]))
			var color := Color(float(strand) / 6.0, 0, 0, 1)
			colors.append_array(PackedColorArray([color,color]))
			if step < 24:
				var i := base + step * 2
				indices.append_array(PackedInt32Array([i,i+1,i+3,i,i+3,i+2]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
