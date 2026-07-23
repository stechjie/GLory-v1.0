extends VFXBlockRoot
class_name VFXMeteorStrike3D
const SHADER_CACHE := preload("res://effects/vfx3d/core/VFXShaderCache.gd")

const CURVES:=preload("res://effects/vfx3d/core/VFXCurveLibrary3D.gd")

const WARNING_SHADER:="""
shader_type spatial;render_mode unshaded,cull_disabled,depth_draw_never,blend_add;
uniform vec4 dark_color:source_color;uniform vec4 main_color:source_color;uniform vec4 core_color:source_color;uniform float progress=0.0;uniform float opacity=1.0;
void fragment(){vec2 p=(UV-vec2(.5))*2.0;float r=length(p);float a=atan(p.y,p.x);float radius=mix(.88,.34,progress);float ring=smoothstep(.11,.012,abs(r-radius+sin(a*9.0)*.025));float teeth=pow(max(0.0,cos(a*8.0)),18.0)*smoothstep(radius+.16,radius-.18,r);float pulse=.72+.28*sin(progress*18.0);vec3 c=mix(dark_color.rgb,main_color.rgb,ring);c=mix(c,core_color.rgb,teeth*.5);ALBEDO=c;EMISSION=c*(1.8+ring*2.2);ALPHA=(ring+teeth*.38)*pulse*opacity;}
"""

const METEOR_SHADER:="""
shader_type spatial;render_mode unshaded,cull_disabled,depth_draw_never,blend_add;
uniform vec4 dark_color:source_color;uniform vec4 main_color:source_color;uniform vec4 core_color:source_color;uniform float progress=0.0;uniform float opacity=1.0;uniform float seed=0.0;
void vertex(){MODELVIEW_MATRIX=VIEW_MATRIX*mat4(INV_VIEW_MATRIX[0],INV_VIEW_MATRIX[1],INV_VIEW_MATRIX[2],MODEL_MATRIX[3]);}
void fragment(){vec2 p=(UV-vec2(.5))*2.0;float a=atan(p.y,p.x);float r=length(p*vec2(.82,1.08));float jag=sin(a*6.0+seed)*.11+sin(a*11.0-seed)*.05;float body=smoothstep(.92+jag,.18,r);float core=smoothstep(.36,.02,r);float upper=smoothstep(-.25,.86,p.y);float flame=smoothstep(.42,.02,abs(p.x))*smoothstep(-.92,.12,p.y)*(1.0-upper)*(.65+.35*sin(p.y*17.0+seed));vec3 c=mix(dark_color.rgb,main_color.rgb,body);c=mix(c,core_color.rgb,core);ALBEDO=c;EMISSION=c*(2.1+core*3.8);ALPHA=clamp(body+flame*.78,0.0,1.0)*opacity*(1.0-smoothstep(.88,1.0,progress));}
"""

const TRAIL_SHADER:="""
shader_type spatial;render_mode unshaded,cull_disabled,depth_draw_never,blend_add;
uniform vec4 dark_color:source_color;uniform vec4 main_color:source_color;uniform vec4 core_color:source_color;uniform float progress=0.0;uniform float opacity=1.0;uniform float seed=0.0;
void vertex(){MODELVIEW_MATRIX=VIEW_MATRIX*mat4(INV_VIEW_MATRIX[0],INV_VIEW_MATRIX[1],INV_VIEW_MATRIX[2],MODEL_MATRIX[3]);}
void fragment(){vec2 p=vec2(abs(UV.x-.5)*2.0,UV.y);float taper=mix(.12,.72,p.y);float torn=sin(p.y*27.0+seed)*.07+sin(p.y*61.0-seed)*.035;float tongue=smoothstep(taper+torn,taper*.35,p.x)*smoothstep(.02,.20,p.y);float split=.70+.30*smoothstep(-.2,.42,sin(p.y*43.0+UV.x*12.0+seed));float hot=smoothstep(taper*.30,.0,p.x)*smoothstep(.38,.98,p.y);float life=1.0-smoothstep(.82,1.0,progress);vec3 c=mix(dark_color.rgb,main_color.rgb,tongue);c=mix(c,core_color.rgb,hot);ALBEDO=c;EMISSION=c*(1.9+hot*3.4);ALPHA=tongue*split*life*opacity*.94;}
"""

const IMPACT_SHADER:="""
shader_type spatial;render_mode unshaded,cull_disabled,depth_draw_never,blend_add;
uniform vec4 dark_color:source_color;uniform vec4 main_color:source_color;uniform vec4 core_color:source_color;uniform float progress=0.0;uniform float opacity=1.0;
void vertex(){MODELVIEW_MATRIX=VIEW_MATRIX*mat4(INV_VIEW_MATRIX[0],INV_VIEW_MATRIX[1],INV_VIEW_MATRIX[2],MODEL_MATRIX[3]);}
void fragment(){vec2 p=(UV-vec2(.5))*2.0;float r=length(p);float a=atan(p.y,p.x);float rays=pow(max(0.0,cos(a*7.0+.4)),18.0)*smoothstep(1.18,.10,r);float core=smoothstep(.54,.02,r);float smoke=smoothstep(.98+.08*sin(a*9.0),.28,r);float life=1.0-smoothstep(.42,1.0,progress);vec3 c=mix(dark_color.rgb,main_color.rgb,smoke);c=mix(c,core_color.rgb,core);ALBEDO=c;EMISSION=c*(1.6+core*4.2+rays*1.4);ALPHA=clamp(smoke*.74+core+rays*.62,0.0,1.0)*life*opacity;}
"""

const SCORCH_SHADER:="""
shader_type spatial;render_mode unshaded,cull_disabled,depth_draw_never,blend_mix;uniform vec4 dark_color:source_color;uniform vec4 ember_color:source_color;uniform float progress=0.0;uniform float opacity=1.0;
void fragment(){vec2 p=(UV-vec2(.5))*2.0;float r=length(p);float a=atan(p.y,p.x);float cracks=pow(max(0.0,cos(a*7.0+sin(r*16.0)*.24)),32.0)*smoothstep(.16,.30,r)*(1.0-smoothstep(.48,.92,r));float burn=smoothstep(.76,.24,r)*smoothstep(.12,.34,r);float fade=1.0-smoothstep(.55,1.0,progress);vec3 c=mix(dark_color.rgb,ember_color.rgb,cracks*.48);ALBEDO=c;EMISSION=ember_color.rgb*cracks*.46;ALPHA=(burn*.34+cracks*.88)*fade*opacity;}
"""

var _materials:Array[ShaderMaterial]=[]

func play_profile(profile:VFXProfile3D,context:Dictionary)->void:
	play_strike(context.get("target",Vector3.ZERO),profile)

func play_strike(target:Vector3,profile:VFXProfile3D=null)->void:
	begin();position=target
	var active:=profile if profile!=null else _fallback_profile()
	var warning:=_ground_quad("MeteorWarning",active.size*Vector2(1.62,1.10),WARNING_SHADER,{"dark_color":active.dark_color,"main_color":active.main_color,"core_color":active.core_color})
	_tween_shader(warning.material_override as ShaderMaterial,"progress",0.0,1.0,active.duration*.42)
	await get_tree().create_timer(active.duration*.18).timeout
	if _finished:return
	var meteor:=_billboard("FallingMeteor",active.size*Vector2(1.22,1.34),METEOR_SHADER,{"dark_color":active.dark_color,"main_color":active.main_color,"core_color":active.core_color,"seed":7.1})
	meteor.position=Vector3(-active.size*.82,active.size*3.55,0.0)
	var trail_outer:=_billboard("MeteorTrailOuter",active.size*Vector2(1.28,2.75),TRAIL_SHADER,{"dark_color":active.dark_color.darkened(.18),"main_color":active.main_color,"core_color":active.core_color,"seed":2.8})
	trail_outer.position=meteor.position+Vector3(0.0,active.size*1.38,.03)
	var trail_core:=_billboard("MeteorTrailCore",active.size*Vector2(.62,2.10),TRAIL_SHADER,{"dark_color":active.main_color.darkened(.22),"main_color":active.core_color,"core_color":Color.WHITE,"seed":8.4})
	trail_core.position=meteor.position+Vector3(0.0,active.size*1.08,.02)
	var fall_time:=active.duration*.38
	var fall:=track_tween(create_tween());fall.set_parallel(true);fall.tween_property(meteor,"position",Vector3(0.0,.18,0.0),fall_time).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN);fall.tween_property(trail_outer,"position",Vector3(0.0,active.size*1.55,.03),fall_time).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN);fall.tween_property(trail_core,"position",Vector3(0.0,active.size*1.18,.02),fall_time).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_tween_shader(trail_outer.material_override as ShaderMaterial,"progress",0.0,.72,fall_time)
	_tween_shader(trail_core.material_override as ShaderMaterial,"progress",0.0,.72,fall_time)
	for i in range(5):
		await get_tree().create_timer(fall_time/5.0).timeout
		_spawn_falling_ember(meteor.position,active,i)
	if _finished:return
	meteor.visible=false;trail_outer.visible=false;trail_core.visible=false;warning.visible=false
	_spawn_impact(active)
	await get_tree().create_timer(active.duration*.52).timeout
	finish()

func _spawn_impact(profile:VFXProfile3D)->void:
	var flash:=_billboard("MeteorImpactMass",profile.size*Vector2(2.85,2.15),IMPACT_SHADER,{"dark_color":profile.dark_color.darkened(.22),"main_color":profile.main_color,"core_color":profile.core_color})
	flash.position.y=profile.size*.46;flash.scale=Vector3.ONE*.18
	CURVES.tween_method(self,func(v:float)->void:if is_instance_valid(flash):flash.scale=Vector3.ONE*v,.18,1.32,profile.duration*.15,"explosive_out")
	_tween_shader(flash.material_override as ShaderMaterial,"progress",0.0,1.0,profile.duration*.34)
	var scorch:=_ground_quad("MeteorScorch",profile.size*Vector2(2.18,1.45),SCORCH_SHADER,{"dark_color":profile.dark_color.darkened(.48),"ember_color":profile.main_color.darkened(.12)})
	_tween_shader(scorch.material_override as ShaderMaterial,"progress",0.0,1.0,profile.duration*.50)
	_spawn_debris(profile)

func _spawn_debris(profile:VFXProfile3D)->void:
	for i in range(12):
		var a:=float(i)/12.0*TAU+sin(float(i)*2.4)*.12;var out:=Vector3(cos(a),.34+float(i%3)*.12,sin(a)).normalized();var shard:=_shard(profile,i);shard.position=Vector3(0.0,.12,0.0);add_child(shard);var peak:=out*profile.size*(.54+float(i%4)*.10);var t:=track_tween(create_tween());t.tween_property(shard,"position",peak,profile.duration*.20).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT);t.set_parallel(true);t.tween_property(shard,"position:y",.02,profile.duration*.26).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN);t.tween_property(shard,"scale",Vector3.ONE*.10,profile.duration*.26);t.set_parallel(false);t.tween_callback(shard.queue_free)

func _spawn_falling_ember(at:Vector3,profile:VFXProfile3D,index:int)->void:
	var dir:=Vector3(-.18+float(index%3)*.18,.42+float(index%2)*.12,0.0).normalized();var s:=_spark(dir,profile.size*.34,profile.size*.038,profile.core_color,profile.emission_energy);s.position=at;s.top_level=true;add_child(s);var t:=track_tween(create_tween());t.set_parallel(true);t.tween_property(s,"position",at+dir*profile.size*.52,profile.duration*.18);t.tween_property(s,"scale",Vector3(.08,.08,1.0),profile.duration*.18);t.set_parallel(false);t.tween_callback(s.queue_free)

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

func _shard(profile:VFXProfile3D,index:int)->MeshInstance3D:
	var w:=profile.size*(.055+float(index%3)*.016);var h:=profile.size*(.14+float(index%2)*.05);var arr:=[];arr.resize(Mesh.ARRAY_MAX);arr[Mesh.ARRAY_VERTEX]=PackedVector3Array([Vector3(-w,0,0),Vector3(w*.72,0,0),Vector3(-w*.15,h,0)]);arr[Mesh.ARRAY_INDEX]=PackedInt32Array([0,1,2]);var mesh:=ArrayMesh.new();mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arr);var n:=MeshInstance3D.new();n.mesh=mesh;n.rotation_degrees.z=float(index)*31.0;n.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;var m:=StandardMaterial3D.new();m.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED;m.albedo_color=profile.dark_color.lerp(profile.main_color,.44);m.emission_enabled=true;m.emission=profile.main_color.darkened(.24);m.emission_energy_multiplier=1.4;n.material_override=m;return n

func _spark(direction:Vector3,length:float,width:float,color:Color,energy:float)->MeshInstance3D:
	var side:=Vector3(-direction.y,direction.x,0).normalized();var arr:=[];arr.resize(Mesh.ARRAY_MAX);arr[Mesh.ARRAY_VERTEX]=PackedVector3Array([-side*width,side*width,direction*length]);arr[Mesh.ARRAY_INDEX]=PackedInt32Array([0,1,2]);var mesh:=ArrayMesh.new();mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arr);var n:=MeshInstance3D.new();n.mesh=mesh;var m:=StandardMaterial3D.new();m.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED;m.albedo_color=color;m.emission_enabled=true;m.emission=color;m.emission_energy_multiplier=minf(energy,4.0);n.material_override=m;n.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;return n

func _tween_shader(m:ShaderMaterial,param:String,from:float,to:float,duration:float)->void:
	var t:=track_tween(create_tween());t.tween_method(func(v:float)->void:if is_instance_valid(m):m.set_shader_parameter(param,v),from,to,duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
func set_vfx_alpha(value:float)->void:
	super.set_vfx_alpha(value)
	for m in _materials:
		if is_instance_valid(m):
			m.set_shader_parameter("opacity",vfx_alpha)
func _fallback_profile()->VFXProfile3D:var p:=VFXProfile3D.new();p.dark_color=Color(.13,.012,.006);p.main_color=Color(.92,.12,.018);p.core_color=Color(1.0,.74,.18);p.size=1.05;p.duration=1.62;p.particle_count=18;p.emission_energy=3.8;p.ground_aligned=true;return p
