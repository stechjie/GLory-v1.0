extends SceneTree
const UNITS = ["crimson", "dancer", "drumer", "hunter", "armbreaker", "Icey", "skypierce", "lattern"]
var vp: SubViewport
var cam: Camera3D
func _initialize():
 call_deferred("run")
func meshes(n: Node) -> Array:
 var a: Array = []
 if n is MeshInstance3D: a.append(n)
 for ch in n.get_children(): a.append_array(meshes(ch))
 return a
func run():
 if DisplayServer.get_name() == "headless":
  push_error("Visual validation requires a real renderer");quit(2);return
 assert(OS.get_user_data_dir().contains("CrimsonNormalReview"),"Use an isolated CrimsonNormalReview project")
 vp = SubViewport.new(); vp.size=Vector2i(320,320);vp.own_world_3d=true;vp.render_target_update_mode=SubViewport.UPDATE_ALWAYS;vp.msaa_3d=Viewport.MSAA_2X;root.add_child(vp)
 var env=WorldEnvironment.new();env.environment=Environment.new();env.environment.background_mode=Environment.BG_COLOR;env.environment.background_color=Color(0.25,0.33,0.22);env.environment.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR;env.environment.ambient_light_energy=0.5;vp.add_child(env)
 var light=DirectionalLight3D.new();light.rotation_degrees=Vector3(-45,-25,0);light.light_energy=1.2;vp.add_child(light)
 cam=Camera3D.new();cam.projection=Camera3D.PROJECTION_ORTHOGONAL;cam.near=0.01;cam.far=1000;vp.add_child(cam)
 var sheet=Image.create(320*3,320*8,false,Image.FORMAT_RGBA8)
 var checks=[]
 var actions=["idle","attack","run"]
 var out=OS.get_environment("CAPTURE_OUT");DirAccess.make_dir_recursive_absolute(out)
 for i in UNITS.size():
  var unit=UNITS[i];var model=load("res://assets/models/units/crimson_refined/%s/%s_refined.tscn" %[unit,unit]).instantiate();vp.add_child(model)
  var players=model.find_children("*","AnimationPlayer",true,false)
  for p in players:
   print(unit," animations ",p.get_animation_list())
   if p.has_animation("idle"):p.play("idle");p.seek(0.2,true);p.pause()
  await process_frame
  var mm=meshes(model);var bounds=AABB();var first=true
  for m in mm:
   var box=m.global_transform*m.get_aabb()
   bounds=box if first else bounds.merge(box);first=false
  var center=bounds.get_center();var size=bounds.size.length();cam.size=size*0.95;cam.position=center+Vector3(0,size*0.5,size*1.5);cam.look_at(center)
  for variant in 3:
   var action=actions[variant]
   for p in players:
    assert(p.has_animation(action),unit+" missing "+action)
    var anim=p.get_animation(action)
    assert(anim.length>0)
    p.play(action);p.seek(0.0,true);p.advance(0.01)
    assert(p.current_animation_position>0.0,unit+" stopped "+action)
    p.pause()
    for sample in 3:
     var time=anim.length*[0.0,0.35,0.7][sample]
     p.seek(time,true);p.advance(0.0001)
     for frame in 3:await process_frame
     await RenderingServer.frame_post_draw
     var img=vp.get_texture().get_image()
     img.save_png(out.path_join(unit+"_"+action+"_%d.png" %sample))
     if sample==1:sheet.blit_rect(img,Rect2i(0,0,320,320),Vector2i(variant*320,i*320))
    checks.append({"unit":unit,"action":action,"length":anim.length,"tracks":anim.get_track_count(),"rendered_samples":3,"advances":true})
  model.queue_free();await process_frame
 sheet.save_png(out.path_join("actions.png"))
 var report=FileAccess.open(out.path_join("actions.json"),FileAccess.WRITE);report.store_string(JSON.stringify(checks,"\t"))
 print("CRIMSON_VISUAL_CHECK PASS: ",checks.size()," animations, ",checks.size()*3," rendered poses")
 quit()
