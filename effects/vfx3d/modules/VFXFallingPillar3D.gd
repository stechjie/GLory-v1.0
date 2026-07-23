extends VFXBlockRoot
class_name VFXFallingPillar3D
const SHADER_CACHE := preload("res://effects/vfx3d/core/VFXShaderCache.gd")

const CURVES:=preload("res://effects/vfx3d/core/VFXCurveLibrary3D.gd")

const PILLAR_SHADER:="""
shader_type spatial;render_mode unshaded,cull_disabled,depth_draw_never,blend_add;
uniform vec4 dark_color:source_color;uniform vec4 main_color:source_color;uniform vec4 core_color:source_color;uniform float progress=0.0;uniform float opacity=1.0;uniform float seed=0.0;uniform float core_width=.24;
void vertex(){MODELVIEW_MATRIX=VIEW_MATRIX*mat4(INV_VIEW_MATRIX[0],INV_VIEW_MATRIX[1],INV_VIEW_MATRIX[2],MODEL_MATRIX[3]);}
void fragment(){vec2 p=UV;float x=abs(p.x-.5)*2.0;float y=p.y;float edge=.36+sin(y*22.0+seed)*.055+sin(y*47.0-seed)*.025;float body=smoothstep(edge,edge*.48,x);float core=smoothstep(core_width,0.0,x);float bands=.82+.18*sin(y*31.0+TIME*13.0);float head=smoothstep(1.0,max(.02,progress*1.28),y);float life=smoothstep(0.0,.14,progress)*(1.0-smoothstep(.68,1.0,progress));vec3 c=mix(dark_color.rgb,main_color.rgb,body);c=mix(c,core_color.rgb,core*bands);ALBEDO=c;EMISSION=c*(2.0+core*3.4);ALPHA=body*head*life*opacity*(.72+core*.28);}
"""

const GROUND_SHADER:="""
shader_type spatial;render_mode unshaded,cull_disabled,depth_draw_never,blend_add;uniform vec4 dark_color:source_color;uniform vec4 main_color:source_color;uniform vec4 core_color:source_color;uniform float progress=0.0;uniform float opacity=1.0;
void fragment(){vec2 p=(UV-vec2(.5))*2.0;float r=length(p);float a=atan(p.y,p.x);float ring=smoothstep(.12,.012,abs(r-mix(.62,.28,progress)));float rays=pow(max(0.0,cos(a*8.0)),20.0)*smoothstep(.94,.14,r);float life=1.0-smoothstep(.58,1.0,progress);vec3 c=mix(dark_color.rgb,main_color.rgb,ring);c=mix(c,core_color.rgb,rays*.54);ALBEDO=c;EMISSION=c*(1.7+ring*2.4+rays*1.6);ALPHA=(ring+rays*.42)*life*opacity;}
"""

const HIT_SHADER:="""
shader_type spatial;render_mode unshaded,cull_disabled,depth_draw_never,blend_add;uniform vec4 main_color:source_color;uniform vec4 core_color:source_color;uniform float progress=0.0;uniform float opacity=1.0;
void vertex(){MODELVIEW_MATRIX=VIEW_MATRIX*mat4(INV_VIEW_MATRIX[0],INV_VIEW_MATRIX[1],INV_VIEW_MATRIX[2],MODEL_MATRIX[3]);}
void fragment(){vec2 p=(UV-vec2(.5))*2.0;float r=length(p);float a=atan(p.y,p.x);float rays=pow(max(0.0,cos(a*8.0+.2)),17.0)*smoothstep(1.10,.06,r);float core=smoothstep(.48,.02,r);float life=1.0-smoothstep(.20,1.0,progress);vec3 c=mix(main_color.rgb,core_color.rgb,core);ALBEDO=c;EMISSION=c*(2.8+core*3.5);ALPHA=(core+rays*.84)*life*opacity;}
"""

var _materials:Array[ShaderMaterial]=[]

func play_profile(profile:VFXProfile3D,context:Dictionary)->void:play_pillar(context.get("target",Vector3.ZERO),profile)

func play_pillar(at:Vector3,profile:VFXProfile3D=null)->void:
	begin();position=at
	var active:=profile if profile!=null else _fallback_profile()
	var mark:=_ground_quad("PillarAnticipation",active.size*Vector2(1.34,.92),GROUND_SHADER,{"dark_color":active.dark_color,"main_color":active.main_color,"core_color":active.core_color})
	_tween_shader(mark.material_override as ShaderMaterial,"progress",0.0,.82,active.duration*.22)
	await get_tree().create_timer(active.duration*.14).timeout
	if _finished:return
	var outer:=_billboard("FallingPillarOuter",active.size*Vector2(.94,3.45),PILLAR_SHADER,{"dark_color":active.dark_color.darkened(.20),"main_color":active.main_color.darkened(.20),"core_color":active.main_color,"seed":3.8,"core_width":.16})
	outer.position.y=active.size*1.62;outer.scale=Vector3(.52,.08,1.0)
	var body:=_billboard("FallingPillarBody",active.size*Vector2(.62,3.35),PILLAR_SHADER,{"dark_color":active.dark_color,"main_color":active.main_color,"core_color":active.core_color,"seed":9.2,"core_width":.28})
	body.position=outer.position+Vector3(0,0,-.025);body.scale=Vector3(.36,.08,1.0)
	CURVES.tween_method(self,func(v:float)->void:if is_instance_valid(outer):outer.scale=Vector3(lerpf(.52,1.0,v),v,1.0),.08,1.0,active.duration*.14,"snap")
	CURVES.tween_method(self,func(v:float)->void:if is_instance_valid(body):body.scale=Vector3(lerpf(.36,1.0,v),v,1.0),.08,1.0,active.duration*.12,"snap")
	_tween_shader(outer.material_override as ShaderMaterial,"progress",0.0,1.0,active.duration*.46);_tween_shader(body.material_override as ShaderMaterial,"progress",0.0,1.0,active.duration*.42)
	await get_tree().create_timer(active.duration*.10).timeout
	if _finished:return
	_spawn_hit(active)
	await get_tree().create_timer(active.duration*.58).timeout
	finish()

func _spawn_hit(profile:VFXProfile3D)->void:
	var hit:=_billboard("PillarTargetImpact",profile.size*Vector2(1.42,1.18),HIT_SHADER,{"main_color":profile.main_color,"core_color":profile.core_color});hit.position.y=profile.size*.24;hit.scale=Vector3.ONE*.18;CURVES.tween_method(self,func(v:float)->void:if is_instance_valid(hit):hit.scale=Vector3.ONE*v,.18,1.12,profile.duration*.14,"explosive_out");_tween_shader(hit.material_override as ShaderMaterial,"progress",0.0,1.0,profile.duration*.24)
	for i in range(10):
		var a:=float(i)/10.0*TAU;var dir:=Vector3(cos(a),.18+float(i%2)*.08,sin(a)).normalized();var s:=_spark(dir,profile.size*(.34+float(i%3)*.10),profile.size*.035,profile.core_color,profile.emission_energy);s.position=Vector3(0,.08,0);add_child(s);var t:=track_tween(create_tween());t.set_parallel(true);t.tween_property(s,"position",dir*profile.size*(.58+float(i%2)*.12),profile.duration*.24);t.tween_property(s,"scale",Vector3(.06,.08,1.0),profile.duration*.24);t.set_parallel(false);t.tween_callback(s.queue_free)

func _ground_quad(name:String,size:Vector2,code:String,params:Dictionary)->MeshInstance3D:
	var n:=_quad(name,size,code,params)
	n.position.y=.026
	n.rotation_degrees.x=-90.0
	return n
func _billboard(name:String,size:Vector2,code:String,params:Dictionary)->MeshInstance3D:
	return _quad(name,size,code,params)
func _quad(name:String,size:Vector2,code:String,params:Dictionary)->MeshInstance3D:
	var q:=QuadMesh.new()
	q.size=size
	var n:=MeshInstance3D.new()
	n.name=name
	n.mesh=q
	n.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m:=ShaderMaterial.new()
	m.shader = SHADER_CACHE.get_shader(code)
	for key in params:
		m.set_shader_parameter(key,params[key])
	m.set_shader_parameter("opacity",vfx_alpha)
	n.material_override=m
	add_child(n)
	_materials.append(m)
	return n
func _spark(dir:Vector3,length:float,width:float,color:Color,energy:float)->MeshInstance3D:
	var side:=Vector3(-dir.y,dir.x,0).normalized();var arr:=[];arr.resize(Mesh.ARRAY_MAX);arr[Mesh.ARRAY_VERTEX]=PackedVector3Array([-side*width,side*width,dir*length]);arr[Mesh.ARRAY_INDEX]=PackedInt32Array([0,1,2]);var mesh:=ArrayMesh.new();mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arr);var n:=MeshInstance3D.new();n.mesh=mesh;n.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;var m:=StandardMaterial3D.new();m.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED;m.albedo_color=color;m.emission_enabled=true;m.emission=color;m.emission_energy_multiplier=minf(energy,4.0);n.material_override=m;return n
func _tween_shader(m:ShaderMaterial,param:String,from:float,to:float,duration:float)->void:var t:=track_tween(create_tween());t.tween_method(func(v:float)->void:if is_instance_valid(m):m.set_shader_parameter(param,v),from,to,duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
func set_vfx_alpha(value:float)->void:
	super.set_vfx_alpha(value)
	for m in _materials:
		if is_instance_valid(m):m.set_shader_parameter("opacity",vfx_alpha)
func _fallback_profile()->VFXProfile3D:var p:=VFXProfile3D.new();p.dark_color=Color(.15,.09,.015);p.main_color=Color(.94,.58,.08);p.core_color=Color(1.0,.94,.66);p.size=1.0;p.duration=1.12;p.particle_count=12;p.emission_energy=3.6;p.ground_aligned=true;return p
