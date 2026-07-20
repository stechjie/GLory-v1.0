extends RefCounted
class_name VFXValidationReport

const QUALITY := preload("res://effects/vfx3d/core/VFXQualityBudget.gd")

static func validate(root: Node, recipe: Resource = null) -> Dictionary:
	var nodes: Array[Node] = []
	_collect_nodes(root, nodes)
	var particles := 0
	var visual_layers := 0
	var transparent_layers := 0
	var tiny_layers := 0
	var placeholder_layers := 0
	var card_placeholders := 0
	for node in nodes:
		if node is GPUParticles3D:
			var particle_node := node as GPUParticles3D
			particles += particle_node.amount
			visual_layers += 1
			for pass_index in range(particle_node.draw_passes):
				var pass_mesh := particle_node.get_draw_pass_mesh(pass_index)
				if pass_mesh is BoxMesh:
					card_placeholders += 1
				elif pass_mesh is QuadMesh and not (pass_mesh as QuadMesh).material is ShaderMaterial:
					card_placeholders += 1
		elif node is VisualInstance3D:
			visual_layers += 1
			var visual := node as VisualInstance3D
			var aabb := visual.get_aabb()
			if aabb.size.length() < 0.16:
				tiny_layers += 1
			if node is MeshInstance3D:
				var mesh_node := node as MeshInstance3D
				if mesh_node.mesh is SphereMesh or mesh_node.mesh is TorusMesh:
					if not mesh_node.material_override is ShaderMaterial:
						placeholder_layers += 1
				var material := mesh_node.material_override
				if material is ShaderMaterial:
					transparent_layers += 1
	var warnings: PackedStringArray = []
	if visual_layers < 3:
		warnings.append("Layer count below production minimum (3).")
	if particles > QUALITY.max_particles_per_effect():
		warnings.append("Particle budget exceeded: %d/%d." % [particles, QUALITY.max_particles_per_effect()])
	if tiny_layers > 0:
		warnings.append("%d layer(s) may be unreadable at gameplay camera distance." % tiny_layers)
	if transparent_layers > 6:
		warnings.append("Too many overlapping transparent layers: %d." % transparent_layers)
	if placeholder_layers > 0:
		warnings.append("Placeholder sphere/ring geometry detected: %d." % placeholder_layers)
	if card_placeholders > 0:
		warnings.append("Visible box or unmasked particle card detected: %d." % card_placeholders)
	if recipe != null and recipe.get("tracks") != null:
		_validate_timeline(recipe.tracks, warnings)
	return {
		"passed": warnings.is_empty(),
		"visual_layers": visual_layers,
		"particles": particles,
		"transparent_layers": transparent_layers,
		"warnings": warnings,
	}

static func _validate_timeline(tracks: Array, warnings: PackedStringArray) -> void:
	var starts: Dictionary = {}
	var required := ["Cast", "Charge", "Release", "Projectile", "Trail", "Impact Flash", "Shockwave", "Debris", "Ground Residue", "Fade Out"]
	var phases := PackedStringArray()
	for track in tracks:
		if track == null:
			continue
		starts[snappedf(float(track.start_time), 0.01)] = true
		if not phases.has(str(track.phase)):
			phases.append(str(track.phase))
		if float(track.fade_out) <= 0.01:
			warnings.append("Track '%s' can disappear abruptly." % str(track.track_id))
	if starts.size() <= 1 and tracks.size() > 1:
		warnings.append("All timeline layers start together.")
	for phase in required:
		if not phases.has(phase):
			warnings.append("Missing production phase: %s." % phase)

static func _collect_nodes(root: Node, output: Array[Node]) -> void:
	if root == null:
		return
	output.append(root)
	for child in root.get_children():
		_collect_nodes(child, output)
