extends SceneTree
const MOD := preload("res://effects/vfx3d/modules/VFXRaceBasicAttack3D.gd")
const PROFILE := preload("res://effects/vfx3d/core/VFXProfile3D.gd")
func _initialize() -> void: call_deferred("_run")
func _marker(world, at, col, r):
	var m := MeshInstance3D.new(); var s := SphereMesh.new(); s.radius=r; s.height=r*2; m.mesh=s
	var mat := StandardMaterial3D.new(); mat.albedo_color=col; mat.emission_enabled=true; mat.emission=col; m.material_override=mat
	m.position=at; world.add_child(m)
func _run() -> void:
	var world := Node3D.new(); root.add_child(world)
	var env := WorldEnvironment.new(); var e := Environment.new(); e.background_mode=Environment.BG_COLOR; e.background_color=Color(0.1,0.11,0.13); env.environment=e; world.add_child(env)
	var cam := Camera3D.new(); cam.projection=Camera3D.PROJECTION_ORTHOGONAL; cam.size=7.2
	cam.look_at_from_position(Vector3(0,7.4,7.0), Vector3.ZERO, Vector3.UP); cam.current=true; world.add_child(cam)
	var mod=MOD.new(); world.add_child(mod)
	var p := PROFILE.new(); p.dark_color=Color(0.05,0.10,0.28); p.main_color=Color(0.30,0.62,1.0); p.core_color=Color(0.82,0.95,1.0); p.size=1.6; p.emission_energy=3.2
	# 单个对角射击：起点(蓝) 左近, 目标(红) 右远。箭放在 3 个插值点上以显轨迹。
	var o := Vector3(-2.6,0,2.2); var t := Vector3(2.6,0,-2.2)
	_marker(world, o, Color(0.3,0.5,1), 0.18); _marker(world, t, Color(1,0.3,0.3), 0.18)
	for r in [0.25, 0.5, 0.75]:
		var body = mod._make_projectile_body("arrow", p, "human")
		body.position = o.lerp(t, r)
		body.rotation.z = mod._screen_facing(o, t)
		world.add_child(body)
	await process_frame; await process_frame; await RenderingServer.frame_post_draw
	root.get_viewport().get_texture().get_image().save_png("C:/Users/Leno/Desktop/Beta 0.04/_or.png")
	print("saved")
	quit()
