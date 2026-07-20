extends VFXBlockRoot
class_name VFXRoarCone3D

const CURVES:=preload("res://effects/vfx3d/core/VFXCurveLibrary3D.gd")
const PATH_RIBBON:=preload("res://effects/vfx3d/modules/VFXPathRibbon3D.gd")

const CONE_SHADER:="""
shader_type spatial;render_mode unshaded,cull_disabled,depth_draw_never,blend_add;
uniform vec4 dark_color:source_color;uniform vec4 main_color:source_color;uniform vec4 core_color:source_color;uniform float reveal=0.0;uniform float dissolve=0.0;uniform float opacity=1.0;uniform float seed=0.0;uniform float layer=0.0;
void fragment(){float across=abs(UV.y*2.0-1.0);float painted=smoothstep(1.0,.12,across+sin(UV.x*29.0+seed)*.055);float broken=.68+.32*step(-.15,sin(UV.x*41.0+seed)+sin(UV.x*17.0-seed));float show=1.0-smoothstep(reveal,reveal+.06,UV.x);float fade=1.0-smoothstep(.02,.24,dissolve+UV.x-.78);float core=1.0-smoothstep(.08,.38,across);vec3 c=mix(dark_color.rgb,main_color.rgb,painted*(1.0-layer*.34));c=mix(c,core_color.rgb,core*(1.0-layer));ALBEDO=c;EMISSION=c*(1.5+core*2.4);ALPHA=painted*broken*show*fade*opacity*(layer>.5?.34:.88);}
"""

const DUST_SHADER:="""
shader_type spatial;render_mode unshaded,cull_disabled,depth_draw_never,blend_mix;uniform vec4 color:source_color;uniform float progress=0.0;uniform float opacity=1.0;
void vertex(){MODELVIEW_MATRIX=VIEW_MATRIX*mat4(INV_VIEW_MATRIX[0],INV_VIEW_MATRIX[1],INV_VIEW_MATRIX[2],MODEL_MATRIX[3]);}
float b(vec2 p,vec2 c,float s){return 1.0-smoothstep(s*.56,s,length(p-c));}
void fragment(){vec2 p=(UV-vec2(.5))*2.0;float m=clamp(b(p,vec2(-.32,-.1),.62)+b(p,vec2(.24,-.14),.68)+b(p,vec2(.05,.30),.54),0.0,1.0);float f=1.0-smoothstep(.34,1.0,progress);ALBEDO=color.rgb;EMISSION=color.rgb*.08;ALPHA=m*f*opacity*.60;}
"""

const HIT_SHADER:="""
shader_type spatial;render_mode unshaded,cull_disabled,depth_draw_never,blend_add;uniform vec4 main_color:source_color;uniform vec4 core_color:source_color;uniform float progress=0.0;uniform float opacity=1.0;
void vertex(){MODELVIEW_MATRIX=VIEW_MATRIX*mat4(INV_VIEW_MATRIX[0],INV_VIEW_MATRIX[1],INV_VIEW_MATRIX[2],MODEL_MATRIX[3]);}
void fragment(){vec2 p=(UV-vec2(.5))*2.0;float r=length(p);float a=atan(p.y,p.x);float rays=pow(max(0.0,cos(a*6.0)),16.0)*smoothstep(1.0,.08,r);float core=smoothstep(.40,.02,r);float life=1.0-smoothstep(.24,1.0,progress);vec3 c=mix(main_color.rgb,core_color.rgb,core);ALBEDO=c;EMISSION=c*(2.4+core*3.0);ALPHA=(core+rays*.72)*life*opacity;}
"""

var _materials:Array[ShaderMaterial]=[]

func play_profile(profile:VFXProfile3D,context:Dictionary)->void:play_roar(context.get("origin",Vector3(-1.15,.48,0.0)),context.get("target",Vector3(.62,.22,0.0)),profile)

func play_roar(origin:Vector3,target:Vector3,profile:VFXProfile3D=null)->void:
	begin();position=origin
	var active:=profile if profile!=null else _fallback_profile();var local_end:=target-origin;var direction:=local_end.normalized();var distance:=local_end.length()
	_spawn_mouth_flash(active)
	await get_tree().create_timer(active.duration*.10).timeout
	if _finished:return
	_spawn_center_pressure(local_end,direction,distance,active)
	for i in range(2):
		await get_tree().create_timer(active.duration*.025).timeout
		_spawn_pressure_arc(direction,distance,active,i)
	_spawn_edge_sparks(direction,distance,active)
	await get_tree().create_timer(active.duration*.28).timeout
	if _finished:return
	_spawn_target_hit(local_end,active)
	await get_tree().create_timer(active.duration*.52).timeout
	finish()

func _make_cone_sheet(direction:Vector3,distance:float,start_half:float,phase:float)->MeshInstance3D:
	var side:=Vector3(-direction.y,direction.x,0).normalized();var vertices:=PackedVector3Array();var uvs:=PackedVector2Array();var indices:=PackedInt32Array();var segments:=9
	for i in range(segments+1):
		var t:=float(i)/float(segments);var center:=direction*distance*t+side*sin(t*PI*2.0+phase)*start_half*.12;var width:=start_half*(.12+pow(t,.72)*2.15)*(1.0+sin(float(i)*2.3+phase)*.08);vertices.append(center-side*width);vertices.append(center+side*width);uvs.append(Vector2(t,0));uvs.append(Vector2(t,1));if i<segments:var b:=i*2;indices.append_array(PackedInt32Array([b,b+1,b+3,b,b+3,b+2]))
	var arr:=[];arr.resize(Mesh.ARRAY_MAX);arr[Mesh.ARRAY_VERTEX]=vertices;arr[Mesh.ARRAY_TEX_UV]=uvs;arr[Mesh.ARRAY_INDEX]=indices;var mesh:=ArrayMesh.new();mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arr);var n:=MeshInstance3D.new();n.mesh=mesh;n.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;return n

func _spawn_center_pressure(local_end:Vector3,direction:Vector3,distance:float,profile:VFXProfile3D)->void:
	var side:=Vector3(-direction.y,direction.x,0.0).normalized()
	var points:=PackedVector3Array()
	for i in range(15):
		var t:=float(i)/14.0
		points.append(local_end*t+side*sin(t*PI*2.0)*profile.size*.055*(1.0-t))
	var stream_profile:=profile.duplicate_runtime()
	stream_profile.duration=profile.duration*.50
	stream_profile.size=1.0
	stream_profile.main_color=profile.main_color.lightened(.12)
	stream_profile.core_color=profile.core_color
	stream_profile.emission_energy=maxf(profile.emission_energy,3.5)
	stream_profile.parameters={"width":profile.size*.24,"halo_width":1.9,"taper_both_ends":true,"curve_bias":.42,"reveal_ratio":.18,"hold_ratio":.08,"spark_count":0}
	var ribbon:=PATH_RIBBON.new()
	ribbon.name="RoarCentralPressure"
	add_child(ribbon)
	ribbon.play_path(points,Vector3.FORWARD,stream_profile)

func _spawn_pressure_arc(direction:Vector3,distance:float,profile:VFXProfile3D,index:int)->void:
	var side:=Vector3(-direction.y,direction.x,0.0).normalized()
	var center:=direction*distance*(.42+float(index)*.22)
	var half_width:=profile.size*(.38+float(index)*.13)
	var points:=PackedVector3Array()
	for i in range(15):
		var u:=-1.0+float(i)/14.0*2.0
		var bow:=direction*profile.size*(.16+float(index)*.035)*(1.0-u*u)
		points.append(center+side*half_width*u-bow)
	var arc_profile:=profile.duplicate_runtime()
	arc_profile.duration=profile.duration*(.38+float(index)*.035)
	arc_profile.size=1.0
	arc_profile.main_color=profile.main_color.lightened(.16)
	arc_profile.core_color=profile.core_color
	arc_profile.emission_energy=maxf(profile.emission_energy,3.4)
	arc_profile.parameters={"width":profile.size*(.15+float(index)*.022),"halo_width":1.85,"taper_both_ends":true,"curve_bias":.32,"reveal_ratio":.16,"hold_ratio":.08,"spark_count":0}
	var ribbon:=PATH_RIBBON.new()
	ribbon.name="RoarPressureArc_%d"%index
	add_child(ribbon)
	ribbon.play_path(points,Vector3.FORWARD,arc_profile)

func _cone_material(profile:VFXProfile3D,seed:float,halo:bool)->ShaderMaterial:
	var m:=ShaderMaterial.new();var s:=Shader.new();s.code=CONE_SHADER;m.shader=s;m.set_shader_parameter("dark_color",profile.dark_color.darkened(.18) if halo else profile.dark_color);m.set_shader_parameter("main_color",profile.main_color.darkened(.20) if halo else profile.main_color);m.set_shader_parameter("core_color",profile.core_color);m.set_shader_parameter("seed",seed);m.set_shader_parameter("layer",1.0 if halo else 0.0);m.set_shader_parameter("reveal",0.0);m.set_shader_parameter("dissolve",0.0);m.set_shader_parameter("opacity",vfx_alpha);_materials.append(m);return m

func _spawn_mouth_flash(profile:VFXProfile3D)->void:
	var n:=_billboard("RoarCompression",profile.size*Vector2(.72,.62),HIT_SHADER,{"main_color":profile.main_color,"core_color":profile.core_color});n.scale=Vector3.ONE*.12;CURVES.tween_method(self,func(v:float)->void:if is_instance_valid(n):n.scale=Vector3.ONE*v,.12,.72,profile.duration*.12,"ease_out_back");_tween_shader(n.material_override as ShaderMaterial,"progress",0.0,1.0,profile.duration*.18);var cleanup:=track_tween(create_tween());cleanup.tween_interval(profile.duration*.20);cleanup.tween_callback(n.queue_free)

func _spawn_dust_line(direction:Vector3,distance:float,profile:VFXProfile3D)->void:
	for i in range(5):
		var t:float=.22+float(i)*.17;var n:=_billboard("RoarDust_%d"%i,profile.size*Vector2(.62+.08*i,.38+.05*i),DUST_SHADER,{"color":profile.dark_color.lightened(.14)});n.position=direction*distance*t+Vector3(0,-.22,0);n.scale=Vector3.ONE*.42;var m:=n.material_override as ShaderMaterial;var tw:=track_tween(create_tween());tw.tween_interval(profile.duration*(.06+.025*i));tw.set_parallel(true);tw.tween_property(n,"scale",Vector3.ONE*(1.0+.06*i),profile.duration*.34);tw.tween_property(n,"position:y",n.position.y+.22,profile.duration*.34);_tween_shader(m,"progress",0.0,1.0,profile.duration*.34)

func _spawn_edge_sparks(direction:Vector3,distance:float,profile:VFXProfile3D)->void:
	var side:=Vector3(-direction.y,direction.x,0).normalized()
	for i in range(10):
		var sign:float=-1.0 if i%2==0 else 1.0;var t:float=.18+float(i/2)*.15;var out:=(direction*.72+side*sign*.68).normalized();var s:=_spark(out,profile.size*(.28+float(i%3)*.08),profile.size*.03,profile.core_color,profile.emission_energy);s.position=direction*distance*t+side*sign*profile.size*(.18+t*.22);add_child(s);var tw:=track_tween(create_tween());tw.set_parallel(true);tw.tween_property(s,"position",s.position+out*profile.size*.46,profile.duration*.22);tw.tween_property(s,"scale",Vector3(.06,.08,1),profile.duration*.22);tw.set_parallel(false);tw.tween_callback(s.queue_free)

func _spawn_target_hit(local_end:Vector3,profile:VFXProfile3D)->void:
	var n:=_billboard("RoarTargetHit",profile.size*Vector2(1.08,.92),HIT_SHADER,{"main_color":profile.main_color,"core_color":profile.core_color});n.position=local_end;n.scale=Vector3.ONE*.18;CURVES.tween_method(self,func(v:float)->void:if is_instance_valid(n):n.scale=Vector3.ONE*v,.18,1.0,profile.duration*.14,"explosive_out");_tween_shader(n.material_override as ShaderMaterial,"progress",0.0,1.0,profile.duration*.25)

func _billboard(name:String,size:Vector2,code:String,params:Dictionary)->MeshInstance3D:
	var q:=QuadMesh.new()
	q.size=size
	var n:=MeshInstance3D.new()
	n.name=name
	n.mesh=q
	n.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m:=ShaderMaterial.new()
	var s:=Shader.new()
	s.code=code
	m.shader=s
	for key in params:
		m.set_shader_parameter(key,params[key])
	m.set_shader_parameter("opacity",vfx_alpha)
	n.material_override=m
	add_child(n)
	_materials.append(m)
	return n
func _spark(dir:Vector3,length:float,width:float,color:Color,energy:float)->MeshInstance3D:
	var side:=Vector3(-dir.y,dir.x,0).normalized();var arr:=[];arr.resize(Mesh.ARRAY_MAX);arr[Mesh.ARRAY_VERTEX]=PackedVector3Array([-side*width,side*width,dir*length]);arr[Mesh.ARRAY_INDEX]=PackedInt32Array([0,1,2]);var mesh:=ArrayMesh.new();mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arr);var n:=MeshInstance3D.new();n.mesh=mesh;n.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;var m:=StandardMaterial3D.new();m.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED;m.albedo_color=color;m.emission_enabled=true;m.emission=color;m.emission_energy_multiplier=minf(energy,4.0);n.material_override=m;return n
func _tween_shader(m:ShaderMaterial,param:String,from:float,to:float,duration:float)->void:var tw:=track_tween(create_tween());tw.tween_method(func(v:float)->void:if is_instance_valid(m):m.set_shader_parameter(param,v),from,to,duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
func set_vfx_alpha(value:float)->void:
	super.set_vfx_alpha(value)
	for m in _materials:
		if is_instance_valid(m):m.set_shader_parameter("opacity",vfx_alpha)
func _fallback_profile()->VFXProfile3D:var p:=VFXProfile3D.new();p.dark_color=Color(.07,.055,.035);p.main_color=Color(.45,.34,.18);p.core_color=Color(.92,.78,.46);p.size=1.0;p.duration=.94;p.particle_count=16;p.emission_energy=2.8;return p
