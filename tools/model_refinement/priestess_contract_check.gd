extends SceneTree
## God priestess refinement contract. The refined scene must keep the original
## mesh / skin / UV / blend-shape resources and the original clips plus the
## 83-bone rest pose identical, only swapping the body material and adding the
## mitre and blessing-clasp ornaments. Scope is the asset/animation contract,
## not visual acceptance.
## Usage: godot --headless --path . --script tools/model_refinement/priestess_contract_check.gd -- [--out <abs-json>]
class PolicyHost:
	extends Node3D
	var visual_root: Node3D

const OLD="res://assets/models/units/god_priestess_animated/god_priestess_animated.tscn"
const NEW="res://assets/models/units/god_priestess_refined/god_priestess_refined.tscn"
var failures=[]
var checks=0
var report={"unit_id":"god_priestess","scope":"asset/animation contract, not visual acceptance","actions":{}}
func check(ok,label):
	checks+=1
	if not ok:failures.append(label);push_error(label)
func _initialize():call_deferred("run")
func run():
	var args=OS.get_cmdline_user_args()
	var out=args[args.find("--out")+1] if "--out" in args else "res://reports/priestess-contract.json"
	var old=load(OLD).instantiate();var new=load(NEW).instantiate()
	root.add_child(old);root.add_child(new)
	for model in [old,new]:
		model.set_process(false)
		for p in model.find_children("*","AnimationPlayer",true,false):p.callback_mode_process=AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	for action in ["idle","run","attack"]:
		old.call("play_"+action);new.call("play_"+action)
		var om=old.action_nodes[action].find_children("*","MeshInstance3D",true,false)[0]
		var nm=new.action_nodes[action].find_children("*","MeshInstance3D",true,false)[0]
		check(om.mesh==nm.mesh and om.skin==nm.skin,action+" original mesh, skin, UV, shape keys identical resources")
		check(nm.get_surface_override_material(0)==new.REFINED_BODY,action+" material route")
		var op=old.action_players[action];var np=new.action_players[action]
		check(op.get_animation_list()==np.get_animation_list(),action+" clip names")
		for name in op.get_animation_list():check(op.get_animation(name)==np.get_animation(name),action+" full clip resource unchanged")
		var proxy_o=old.animation_player.get_animation(action);var proxy_n=new.animation_player.get_animation(action)
		check(proxy_o.length==proxy_n.length and proxy_o.loop_mode==proxy_n.loop_mode,action+" proxy timing")
		var osk=old.action_nodes[action].find_children("*","Skeleton3D",true,false)[0]
		var nsk=new.action_nodes[action].find_children("*","Skeleton3D",true,false)[0]
		check(osk.get_bone_count()==nsk.get_bone_count(),action+" bone count")
		for i in osk.get_bone_count():check(osk.get_bone_name(i)==nsk.get_bone_name(i) and osk.get_bone_parent(i)==nsk.get_bone_parent(i) and osk.get_bone_rest(i).is_equal_approx(nsk.get_bone_rest(i)),action+" bone "+str(i))
		for t in [0.0,0.18,0.4,0.7,1.0,2.0,3.0,3.3]:
			op.seek(t,true);np.seek(t,true);op.advance(0);np.advance(0)
			await process_frame
			for i in osk.get_bone_count():check(osk.get_bone_global_pose(i).is_equal_approx(nsk.get_bone_global_pose(i)),action+" pose "+str(t)+" bone "+str(i))
			for label in ["MitreInlay","BlessingClasp"]:
				var at=nsk.get_node(label)
				check(at.transform.is_equal_approx(nsk.get_bone_global_pose(nsk.find_bone(at.bone_name))),action+" attachment "+label+str(t))
		var tris=0;var surfaces=0
		for m in new.action_nodes[action].find_children("*","MeshInstance3D",true,false):
			for i in m.mesh.get_surface_count():tris+=m.mesh.surface_get_arrays(i)[Mesh.ARRAY_INDEX].size()/3;surfaces+=1
		check(tris<3600 and surfaces<=6,action+" geometry budget")
		report.actions[action]={"triangles":tris,"surfaces":surfaces,"bones":nsk.get_bone_count(),"blend_shapes":nm.mesh.get_blend_shape_count()}
	var texture=new.REFINED_BODY.get_shader_parameter("albedo_texture")
	check(texture.get_width()==1024,"imported texture 1024")
	var policy=load("res://effects/runtime/presentation/ModelRootMotionPolicy.gd")
	var ho=PolicyHost.new();var hn=ho.duplicate();ho.visual_root=old;hn.visual_root=new
	root.add_child(ho);root.add_child(hn)
	var a=policy.apply_to_actor(ho,{"model_in_place_actions":["run"]});var b=policy.apply_to_actor(hn,{"model_in_place_actions":["run"]})
	check(a.locked_tracks==b.locked_tracks and b.locked_tracks>0,"formal run root policy identical")
	for def in JSON.parse_string(FileAccess.get_file_as_string("res://data/units/race_units.json")).units:
		if def.id=="god_priestess":check(def.model==NEW,"formal mapping")
	report.checks=checks;report.failures=failures
	var file=FileAccess.open(out,FileAccess.WRITE)
	if file==null:push_error("cannot write report "+out+" error="+str(FileAccess.get_open_error()))
	else:
		file.store_string(JSON.stringify(report,"\t"))
		file.close()
	print("PRIESTESS_CONTRACT ",checks," failures=",failures," report=",out," written=",FileAccess.file_exists(out))
	quit(0 if failures.is_empty() else 1)
