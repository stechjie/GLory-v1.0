extends VFXBlockRoot
## Cached batch meshes; no rigid bodies, textures or per-coin scene nodes.
const QUALITY := preload("res://effects/vfx3d/core/VFXQualityBudget.gd")
static var _coin: ArrayMesh
static var _shards: Array[PrismMesh] = []

func play_burst(at: Vector3, _foot_y: float, away: Vector3, color: Color, tier: String, coins := true) -> void:
	begin()
	position = at
	_resources()
	var level := int(QUALITY.tier)
	var heavy := tier in ["heavy", "finale"]
	var coin_counts := [4, 7, 10] if heavy else [3, 5, 7]
	var shard_counts := [10, 14, 18] if heavy else [6, 8, 10]
	if coins:
		_batch(_coin, int(coin_counts[level]), away, 0, heavy)
	for variant in range(3):
		var material := StandardMaterial3D.new()
		material.albedo_color = color.darkened(0.30 + variant * 0.08)
		material.roughness = 0.65
		_batch(_shards[variant], maxi(1, int(shard_counts[level]) / 3), away, variant + 1, heavy, material)
	if not await wait_for(0.86):
		return
	finish()

func _batch(mesh: Mesh, count: int, away: Vector3, variant: int, heavy: bool, material: Material = null) -> void:
	var batch := MultiMeshInstance3D.new()
	batch.name = "GoldCoins" if variant == 0 else "BurstShards%d" % variant
	batch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = count
	batch.multimesh = mm
	if material != null:
		batch.material_override = material
	add_child(batch)
	var velocities: Array[Vector3] = []
	var axes: Array[Vector3] = []
	for index in range(count):
		var angle := TAU * float(index) / float(count) + randf_range(-0.3, 0.3)
		var speed := randf_range(0.8, 1.7) * (1.2 if heavy else 1.0)
		velocities.append(Vector3(cos(angle) * speed, randf_range(1.3, 2.4), sin(angle) * speed) + away * 0.45)
		axes.append(Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)).normalized())
	var update := func(t: float) -> void:
		if not is_instance_valid(batch):
			return
		var shrink := clampf((0.79 - t) / 0.19, 0.0, 1.0)
		for index in range(count):
			var point := velocities[index] * t + Vector3.DOWN * 3.8 * t * t
			point.y = maxf(point.y, -0.35)
			var spin := Basis(axes[index], t * (12.0 + float(index % 4) * 3.0) + float(index))
			mm.set_instance_transform(index, Transform3D(spin.scaled(Vector3.ONE * shrink), point))
	update.call(0.0)
	var tween := track_tween(create_tween())
	tween.tween_method(update, 0.0, 0.8, 0.8)

static func _resources() -> void:
	if _coin != null:
		return
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for side in [-1.0, 1.0]:
		for segment in range(12):
			var a := TAU * float(segment) / 12.0
			var b := TAU * float(segment + 1) / 12.0
			var points := [Vector2.ZERO, Vector2(cos(a),sin(a)), Vector2(cos(b),sin(b))]
			if side > 0.0:
				points.reverse()
			for point: Vector2 in points:
				surface.set_normal(Vector3.UP * side)
				surface.set_uv(point * 0.5 + Vector2.ONE * 0.5)
				surface.add_vertex(Vector3(point.x * 0.065, side * 0.008, point.y * 0.065))
	for segment in range(12):
		var a := TAU * float(segment) / 12.0
		var b := TAU * float(segment+1) / 12.0
		var v0 := Vector3(cos(a)*0.065,-0.008,sin(a)*0.065)
		var v1 := Vector3(cos(b)*0.065,-0.008,sin(b)*0.065)
		for point: Vector3 in [v0,v1,v1+Vector3.UP*0.016,v0,v1+Vector3.UP*0.016,v0+Vector3.UP*0.016]:
			surface.set_normal(Vector3(cos(a),0,sin(a)))
			surface.set_uv(Vector2.ZERO)
			surface.add_vertex(point)
	_coin = surface.commit()
	var gold := ShaderMaterial.new()
	gold.shader = preload("res://shaders/coin_metal.gdshader")
	_coin.surface_set_material(0,gold)
	for variant in range(3):
		var shard := PrismMesh.new()
		shard.size = Vector3(0.065 + variant * 0.018, 0.13 - variant * 0.02, 0.018 + variant * 0.01)
		_shards.append(shard)
