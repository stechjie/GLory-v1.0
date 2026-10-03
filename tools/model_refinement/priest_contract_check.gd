extends SceneTree
const OLD="res://assets/models/units/god_priest_halo_animated/god_priest_animated.tscn"
const NEW="res://assets/models/units/god_priest_refined/god_priest_refined.tscn"
var failures=[]
var checks=0
var max_channel_error={}
func channel_equal(a,b,channel):
	var error:float=a.distance_to(b) if a is Vector3 or a is Vector2 else absf(float(a)-float(b))
	max_channel_error[str(channel)]=maxf(float(max_channel_error.get(str(channel),0.0)),error)
	return error <= 0.0002 if channel in [Mesh.ARRAY_NORMAL,Mesh.ARRAY_TANGENT] else a==b
var report={"scope":"asset/animation contract, not visual acceptance","actions":{}}
func check(ok:bool,label:String):
	checks+=1
	if not ok: failures.append(label);push_error(label)
func _initialize():call_deferred("run")
func run():
	var args=OS.get_cmdline_user_args();var out=args[args.find("--out")+1] if "--out" in args else "res://reports/priest-contract.json"
	var old=load(OLD).instantiate();var new=load(NEW).instantiate();root.add_child(old);root.add_child(new)
	old.set_process(false);new.set_process(false)
	for model in [old,new]:
		for player in model.find_children("*","AnimationPlayer",true,false):player.callback_mode_process=AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	var removed=JSON.parse_string(FileAccess.get_file_as_string("res://tools/model_refinement/priest_original_halo_vertices.json"));var mask={}
	for i in removed:mask[int(i)]=true
	for action in ["idle","run","attack"]:
		old.call("play_"+action);new.call("play_"+action)
		var om=old.action_nodes[action].find_children("*","MeshInstance3D",true,false)[0]
		var nm=new.action_nodes[action].find_children("*","MeshInstance3D",true,false)[0]
		check(om.skin==nm.skin,action+" original skin preserved")
		var oa=om.mesh.surface_get_arrays(0);var na=nm.mesh.surface_get_arrays(0)
		var selected=[];var seen={}
		for i in oa[Mesh.ARRAY_INDEX]:
			if not mask.has(i) and not seen.has(i):seen[i]=true;selected.append(i)
		for channel in [Mesh.ARRAY_VERTEX,Mesh.ARRAY_NORMAL,Mesh.ARRAY_TANGENT,Mesh.ARRAY_TEX_UV,Mesh.ARRAY_BONES,Mesh.ARRAY_WEIGHTS]:
			var stride=int(oa[channel].size()/oa[Mesh.ARRAY_VERTEX].size());var same=true
			for i in selected.size():
				for j in stride:
					if not channel_equal(oa[channel][selected[i]*stride+j],na[channel][i*stride+j],channel):same=false
			check(same,action+" retained channel "+str(channel))
		check(om.mesh.get_blend_shape_count()==nm.mesh.get_blend_shape_count(),action+" blend shape count")
		for si in om.mesh.get_blend_shape_count():
			check(om.mesh.get_blend_shape_name(si)==nm.mesh.get_blend_shape_name(si),action+" blend shape name "+str(si))
			var os=om.mesh.surface_get_blend_shape_arrays(0)[si];var ns=nm.mesh.surface_get_blend_shape_arrays(0)[si]
			for ch in [Mesh.ARRAY_VERTEX,Mesh.ARRAY_NORMAL,Mesh.ARRAY_TANGENT]:
				if os[ch]==null or os[ch].is_empty():continue
				var stride=int(os[ch].size()/oa[Mesh.ARRAY_VERTEX].size());var same=true
				for i in selected.size():
					for j in stride:
						if not channel_equal(os[ch][selected[i]*stride+j],ns[ch][i*stride+j],ch):same=false
				check(same,action+" blend shape data "+str(si)+" channel "+str(ch))
		var op=old.action_players[action];var np=new.action_players[action]
		check(op.get_animation_list()==np.get_animation_list(),action+" clip names")
		for name in op.get_animation_list():check(op.get_animation(name)==np.get_animation(name),action+" unchanged clip resource "+str(name))
		check(old.animation_player.get_animation(action)==new.animation_player.get_animation(action),action+" proxy clip unchanged")
		var osk=old.action_nodes[action].find_children("*","Skeleton3D",true,false)[0];var nsk=new.action_nodes[action].find_children("*","Skeleton3D",true,false)[0]
		check(osk.get_bone_count()==nsk.get_bone_count(),action+" bone count")
		for i in osk.get_bone_count():check(osk.get_bone_name(i)==nsk.get_bone_name(i) and osk.get_bone_parent(i)==nsk.get_bone_parent(i) and osk.get_bone_rest(i).is_equal_approx(nsk.get_bone_rest(i)),action+" bone rest "+str(i))
		var attachment=nsk.get_node("RefinedHaloAttachment")
		for t in [0.0,0.18,0.4,0.7,1.0,2.0]:
			old.call("play_"+action);new.call("play_"+action)
			op.seek(t,true);np.seek(t,true);op.advance(0);np.advance(0)
			await process_frame
			var same=true
			for i in osk.get_bone_count():
				if not osk.get_bone_global_pose(i).is_equal_approx(nsk.get_bone_global_pose(i)):same=false
			check(same,action+" evaluated pose "+str(t))
			check(attachment.transform.is_equal_approx(nsk.get_bone_global_pose(nsk.find_bone("CC_Base_Head"))),action+" halo follows head "+str(t))
		var tris=0;var verts=0;var surfaces=0
		for m in new.action_nodes[action].find_children("*","MeshInstance3D",true,false):
			for i in m.mesh.get_surface_count():
				var ar=m.mesh.surface_get_arrays(i);verts+=ar[Mesh.ARRAY_VERTEX].size();tris+=ar[Mesh.ARRAY_INDEX].size()/3;surfaces+=1
		report.actions[action]={"old_vertices":oa[Mesh.ARRAY_VERTEX].size(),"old_triangles":oa[Mesh.ARRAY_INDEX].size()/3,"new_vertices":verts,"new_triangles":tris,"new_surfaces":surfaces,"bones":nsk.get_bone_count(),"clip":np.get_animation_list(),"blend_shapes":nm.mesh.get_blend_shape_count()}
		check(tris<=4500 and surfaces==2,action+" triangle/surface budget")
	for def in JSON.parse_string(FileAccess.get_file_as_string("res://data/units/race_units.json")).units:
		if def.id=="god_priest":check(def.model==NEW,"formal mapping")
	report.checks=checks;report.failures=failures;report.max_channel_error=max_channel_error
	FileAccess.open(out,FileAccess.WRITE).store_string(JSON.stringify(report,"\t"));print("PRIEST_CONTRACT ",checks," checks; failures=",failures)
	quit(0 if failures.is_empty() else 1)
