extends SceneTree
func _initialize():call_deferred("run")
func run():
	var tex=Image.load_from_file("res://assets/models/units/god_priest_refined/priest_albedo.png")
	var mesh=load("res://assets/models/units/god_priest_refined/body_idle.res")
	var a=mesh.surface_get_arrays(0);var rows=[]
	var bins={"black_transparent":0,"black_opaque":0,"partial_alpha":0,"total":tex.get_width()*tex.get_height()}
	for y in tex.get_height():
		for x in tex.get_width():
			var c=tex.get_pixel(x,y)
			if c.r+c.g+c.b<0.08:
				if c.a<0.5:bins.black_transparent+=1
				else:bins.black_opaque+=1
			if c.a>0.0 and c.a<1.0:bins.partial_alpha+=1
	for i in range(0,a[Mesh.ARRAY_INDEX].size(),3):
		var ix=[a[Mesh.ARRAY_INDEX][i],a[Mesh.ARRAY_INDEX][i+1],a[Mesh.ARRAY_INDEX][i+2]]
		var uv=(a[Mesh.ARRAY_TEX_UV][ix[0]]+a[Mesh.ARRAY_TEX_UV][ix[1]]+a[Mesh.ARRAY_TEX_UV][ix[2]])/3
		var col=tex.get_pixel(clampi(int(uv.x*tex.get_width()),0,tex.get_width()-1),clampi(int(uv.y*tex.get_height()),0,tex.get_height()-1))
		if col.r+col.g+col.b<0.3:
			var pos=(a[Mesh.ARRAY_VERTEX][ix[0]]+a[Mesh.ARRAY_VERTEX][ix[1]]+a[Mesh.ARRAY_VERTEX][ix[2]])/3
			rows.append({"triangle":i/3,"vertex":ix,"position":[pos.x,pos.y,pos.z],"uv":[uv.x,uv.y],"rgba":[col.r,col.g,col.b,col.a]})
	print("TEXTURE_PROBE ",JSON.stringify(bins)," dark triangle centres=",rows.size())
	var path=OS.get_cmdline_user_args()[0]
	FileAccess.open(path,FileAccess.WRITE).store_string(JSON.stringify({"pixels":bins,"dark_triangles":rows},"\t"));quit()
