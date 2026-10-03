extends SceneTree
# Remove precisely the disconnected original halo, compact all vertex channels,
# preserve skin, UVs, normals and all original action scenes/animation libraries.
func _initialize(): call_deferred("run")
func run():
	var model=load("res://assets/models/units/god_priest_halo_animated/god_priest_animated.tscn").instantiate()
	root.add_child(model)
	var removed=JSON.parse_string(FileAccess.get_file_as_string("res://tools/model_refinement/priest_original_halo_vertices.json"))
	var mask={}
	for i in removed: mask[int(i)]=true
	var reference=model.action_nodes.idle.find_children("*","MeshInstance3D",true,false)[0].mesh.surface_get_arrays(0)
	for action in model.action_nodes:
		var src=model.action_nodes[action].find_children("*","MeshInstance3D",true,false)[0].mesh
		var a=src.surface_get_arrays(0)
		assert(a[Mesh.ARRAY_VERTEX]==reference[Mesh.ARRAY_VERTEX],"Action topology differs; regenerate mask for this action")
		var ids=PackedInt32Array();var remap={};var selected=[]
		for j in range(0,a[Mesh.ARRAY_INDEX].size(),3):
			var face=[a[Mesh.ARRAY_INDEX][j],a[Mesh.ARRAY_INDEX][j+1],a[Mesh.ARRAY_INDEX][j+2]]
			if mask.has(face[0]):
				assert(mask.has(face[1]) and mask.has(face[2]));continue
			for old in face:
				if not remap.has(old):remap[old]=selected.size();selected.append(old)
				ids.append(remap[old])
		var count=a[Mesh.ARRAY_VERTEX].size()
		for channel in range(Mesh.ARRAY_MAX):
			if channel==Mesh.ARRAY_INDEX or a[channel]==null:continue
			var old=a[channel];var stride=int(old.size()/count);var arr=old.duplicate();arr.resize(selected.size()*stride)
			for i in selected.size():
				for k in stride: arr[i*stride+k]=old[selected[i]*stride+k]
			a[channel]=arr
		a[Mesh.ARRAY_INDEX]=ids
		var mesh=ArrayMesh.new()
		mesh.blend_shape_mode=src.blend_shape_mode
		var shapes=[]
		for si in src.get_blend_shape_count():mesh.add_blend_shape(src.get_blend_shape_name(si))
		for shape in src.surface_get_blend_shape_arrays(0):
			var compact=shape.duplicate(true)
			for channel in [Mesh.ARRAY_VERTEX,Mesh.ARRAY_NORMAL,Mesh.ARRAY_TANGENT]:
				if shape[channel]==null or shape[channel].is_empty():continue
				var stride=int(shape[channel].size()/count)
				compact[channel].resize(selected.size()*stride)
				for i in selected.size():
					for k in stride:compact[channel][i*stride+k]=shape[channel][selected[i]*stride+k]
			shapes.append(compact)
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,a,shapes,{},src.surface_get_format(0)&Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS)
		var err=ResourceSaver.save(mesh,"res://assets/models/units/god_priest_refined/body_"+action+".res")
		assert(err==OK);print("PRIEST_BODY ",action," vertices=",selected.size()," triangles=",ids.size()/3)
	quit()
