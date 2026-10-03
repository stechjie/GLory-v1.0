extends SceneTree
var output := ""
func _initialize():
	call_deferred("run")
func run():
	var args=OS.get_cmdline_user_args()
	if not "--out" in args: push_error("Required: --out absolute-directory");quit(2);return
	output=args[args.find("--out")+1]
	DirAccess.make_dir_recursive_absolute(output)
	var model_path="res://assets/models/units/god_priest_refined/god_priest_refined.tscn" if "--refined" in args else "res://assets/models/units/god_priest_halo_animated/god_priest_animated.tscn"
	var scene = load(model_path).instantiate()
	root.add_child(scene)
	await process_frame
	var report = {}
	for action in scene.action_nodes:
		var node = scene.action_nodes[action]
		var entry = {"meshes":[],"skeletons":[],"animations":[]}
		for mesh in node.find_children("*","MeshInstance3D",true,false):
			var vertices=0;var triangles=0
			for i in mesh.mesh.get_surface_count():
				var a=mesh.mesh.surface_get_arrays(i)
				vertices+=a[Mesh.ARRAY_VERTEX].size(); triangles+=a[Mesh.ARRAY_INDEX].size()/3
			entry.meshes.append({"name":mesh.name,"vertices":vertices,"triangles":triangles,"aabb":str(mesh.get_aabb()),"transform":str(mesh.global_transform)})
		for sk in node.find_children("*","Skeleton3D",true,false):
			var bones=[]
			for i in sk.get_bone_count():
				var t=sk.get_bone_global_rest(i)
				bones.append({"name":sk.get_bone_name(i),"parent":sk.get_bone_parent(i),"global_rest":{"basis_x":Array([t.basis.x.x,t.basis.x.y,t.basis.x.z]),"basis_y":[t.basis.y.x,t.basis.y.y,t.basis.y.z],"basis_z":[t.basis.z.x,t.basis.z.y,t.basis.z.z],"origin":[t.origin.x,t.origin.y,t.origin.z]}})
			entry.skeletons.append({"name":sk.name,"transform":str(sk.global_transform),"bones":bones})
		var player=scene.action_players[action]
		for name in player.get_animation_list():
			var anim=player.get_animation(name)
			entry.animations.append({"name":name,"length":anim.length,"tracks":anim.get_track_count(),"loop":anim.loop_mode})
		report[action]=entry
		if action == "idle":
			var mesh=node.find_children("*","MeshInstance3D",true,false)[0]
			var sk=mesh.get_node(mesh.skeleton)
			var arrays=mesh.mesh.surface_get_arrays(0)
			FileAccess.open(output+"/indices.json",FileAccess.WRITE).store_string(JSON.stringify(Array(arrays[Mesh.ARRAY_INDEX])))
			var points=[]
			for vi in arrays[Mesh.ARRAY_VERTEX].size():
				var v=Vector3.ZERO
				for wi in int(arrays[Mesh.ARRAY_BONES].size()/arrays[Mesh.ARRAY_VERTEX].size()):
					var bi=arrays[Mesh.ARRAY_BONES][vi*int(arrays[Mesh.ARRAY_BONES].size()/arrays[Mesh.ARRAY_VERTEX].size())+wi]
					var weight=arrays[Mesh.ARRAY_WEIGHTS][vi*int(arrays[Mesh.ARRAY_BONES].size()/arrays[Mesh.ARRAY_VERTEX].size())+wi]
					var bone=sk.find_bone(mesh.skin.get_bind_name(bi))
					if bone<0: bone=mesh.skin.get_bind_bone(bi)
					v+=(sk.get_bone_global_rest(bone)*mesh.skin.get_bind_pose(bi)*arrays[Mesh.ARRAY_VERTEX][vi])*weight
				points.append([v.x,v.y,v.z])
			FileAccess.open(output+"/rest-points.json",FileAccess.WRITE).store_string(JSON.stringify(points))
		var state=GLTFState.new()
		var doc=GLTFDocument.new()
		var err=doc.append_from_scene(node,state)
		if err==OK: err=doc.write_to_filesystem(state,output+"/source-"+action+".glb")
		print("EXPORT ",action," ",err)
	var file=FileAccess.open(output+"/inventory.json",FileAccess.WRITE);file.store_string(JSON.stringify(report,"\t"))
	quit()
