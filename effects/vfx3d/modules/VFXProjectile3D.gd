extends VFXBlockRoot
class_name VFXProjectile3D
const QUALITY := preload("res://effects/vfx3d/core/VFXQualityBudget.gd")
const SHADER_CACHE := preload("res://effects/vfx3d/core/VFXShaderCache.gd")

const CURVES := preload("res://effects/vfx3d/core/VFXCurveLibrary3D.gd")

const PROJECTILE_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;
uniform vec4 dark_color : source_color;
uniform vec4 main_color : source_color;
uniform vec4 core_color : source_color;
uniform float progress = 0.0;
uniform float opacity = 1.0;
uniform float seed = 0.0;
uniform float halo = 0.0;
uniform float wave_amount = 0.06;
uniform float spiral_amount = 0.18;
uniform float flow_speed = 7.0;
void vertex(){ MODELVIEW_MATRIX=VIEW_MATRIX*mat4(INV_VIEW_MATRIX[0],INV_VIEW_MATRIX[1],INV_VIEW_MATRIX[2],MODEL_MATRIX[3]); }
void fragment(){
	vec2 p=(UV-vec2(0.5))*2.0;
	float a=atan(p.y,p.x);
	float r=length(p*vec2(0.86,1.08));
	float jag=sin(a*7.0+seed+TIME*flow_speed)*wave_amount+sin(a*13.0-seed-TIME*flow_speed*0.7)*wave_amount*0.45;
	float spiral=sin((a + r*3.2)*6.0 - TIME*flow_speed + seed)*spiral_amount*(1.0-r);
	float body=smoothstep(0.94+jag+halo*0.16,0.18+halo*0.08,r);
	float forward=pow(max(0.0,UV.x),2.2);
	float tail=smoothstep(0.46,0.02,abs(p.y))*smoothstep(0.88,-0.80,p.x)*(0.52+0.48*sin(p.x*11.0+seed));
	float core=smoothstep(0.36+spiral,0.02,r)*smoothstep(-0.55,0.45,p.x);
	float pulse=0.90+0.10*sin(TIME*20.0+seed);
	float life=smoothstep(0.0,0.12,progress)*(1.0-smoothstep(0.82,1.0,progress));
	float mask=clamp(body+tail*0.72+forward*body*0.18,0.0,1.0)*life;
	vec3 color=mix(dark_color.rgb,main_color.rgb,body*(1.0-halo*0.45));
	color=mix(color,core_color.rgb,core*(1.0-halo));
	ALBEDO=color; EMISSION=color*(1.7+core*3.8+body*1.2)*pulse;
	ALPHA=mask*opacity*(halo>0.5?0.34:0.96);
}
"""

const PUFF_SHADER := """
shader_type spatial;
render_mode unshaded,cull_disabled,depth_draw_never,blend_mix;
uniform vec4 color : source_color;
uniform float progress=0.0;
uniform float opacity=1.0;
uniform float seed=0.0;
void vertex(){ MODELVIEW_MATRIX=VIEW_MATRIX*mat4(INV_VIEW_MATRIX[0],INV_VIEW_MATRIX[1],INV_VIEW_MATRIX[2],MODEL_MATRIX[3]); }
float b(vec2 p,vec2 c,float s){return 1.0-smoothstep(s*0.55,s,length(p-c));}
void fragment(){vec2 p=(UV-vec2(0.5))*2.0;float m=clamp(b(p,vec2(-.28,-.08),.68)+b(p,vec2(.27,-.16),.58)+b(p,vec2(.05,.30),.62),0.0,1.0);float f=1.0-smoothstep(.24,1.0,progress);ALBEDO=color.rgb;EMISSION=color.rgb*.18;ALPHA=m*f*opacity*.62;}
"""

const TAIL_SHADER := """
shader_type spatial;
render_mode unshaded,cull_disabled,depth_draw_never,blend_add;
uniform vec4 dark_color:source_color; uniform vec4 main_color:source_color; uniform vec4 core_color:source_color;
uniform float progress=0.0; uniform float opacity=1.0;
void fragment(){
	vec2 p=vec2(UV.x,abs(UV.y-.5)*2.0);
	float taper=mix(.05,.48,p.x);
	float torn=sin(p.x*31.0+TIME*8.0)*.055+sin(p.x*67.0-TIME*11.0)*.025;
	float body=smoothstep(taper+torn,taper*.42,p.y)*smoothstep(.0,.18,p.x);
	float gaps=.72+.28*smoothstep(-.15,.45,sin(p.x*42.0+UV.y*9.0));
	float hot=smoothstep(taper*.28,.0,p.y)*smoothstep(.24,.92,p.x);
	float life=1.0-smoothstep(.78,1.0,progress);
	vec3 c=mix(dark_color.rgb,main_color.rgb,body); c=mix(c,core_color.rgb,hot);
	ALBEDO=c; EMISSION=c*(1.8+hot*3.8); ALPHA=body*gaps*life*opacity*.92;
}
"""

const STREAK_SHADER := """
shader_type spatial;
render_mode unshaded,cull_disabled,depth_draw_never,blend_add;
uniform vec4 dark_color:source_color; uniform vec4 main_color:source_color; uniform vec4 core_color:source_color;
uniform float progress=0.0; uniform float opacity=1.0; uniform float seed=0.0; uniform float emission=2.0;
void vertex(){ MODELVIEW_MATRIX=VIEW_MATRIX*mat4(INV_VIEW_MATRIX[0],INV_VIEW_MATRIX[1],INV_VIEW_MATRIX[2],MODEL_MATRIX[3]); }
void fragment(){
	vec2 p=UV-vec2(0.5);
	float longitudinal=clamp((p.x+0.5),0.0,1.0);
	float center=sin(longitudinal*18.0+TIME*10.0+seed)*0.035+sin(longitudinal*41.0-seed)*0.018;
	float width=mix(0.035,0.22,longitudinal)*(0.8+0.2*sin(longitudinal*13.0+seed));
	float band=smoothstep(width+0.02,width*0.28,abs(p.y-center));
	float torn=0.72+0.28*smoothstep(-0.4,0.5,sin(longitudinal*32.0+UV.y*7.0+seed));
	float leading=smoothstep(0.0,0.16,longitudinal);
	float life=(1.0-smoothstep(0.76,1.0,progress))*smoothstep(0.0,0.08,progress);
	vec3 c=mix(dark_color.rgb,main_color.rgb,band);
	c=mix(c,core_color.rgb,smoothstep(0.72,0.98,band));
	ALBEDO=c; EMISSION=c*emission*(0.8+band*2.6);
	ALPHA=band*torn*leading*life*opacity*0.9;
}
"""

const IMPACT_SHADER := """
shader_type spatial;
render_mode unshaded,cull_disabled,depth_draw_never,blend_add;
uniform vec4 main_color:source_color;uniform vec4 core_color:source_color;uniform float progress=0.0;uniform float opacity=1.0;
void vertex(){ MODELVIEW_MATRIX=VIEW_MATRIX*mat4(INV_VIEW_MATRIX[0],INV_VIEW_MATRIX[1],INV_VIEW_MATRIX[2],MODEL_MATRIX[3]); }
void fragment(){vec2 p=(UV-vec2(.5))*2.0;float r=length(p);float a=atan(p.y,p.x);float rays=pow(max(0.0,cos(a*7.0)),16.0)*smoothstep(1.12,.08,r);float core=smoothstep(.46,.02,r);float life=1.0-smoothstep(.22,1.0,progress);vec3 c=mix(main_color.rgb,core_color.rgb,core);ALBEDO=c;EMISSION=c*(2.8+core*3.4);ALPHA=clamp(core+rays*.82,0.0,1.0)*life*opacity;}
"""

var _materials:Array[ShaderMaterial]=[]

func play_profile(profile:VFXProfile3D,context:Dictionary)->void:
	play_projectile(context.get("origin",Vector3(-1.35,0.72,0.0)),context.get("target",Vector3.ZERO),profile,context.get("target_node"))

func play_projectile(origin:Vector3,target:Vector3,profile:VFXProfile3D=null,target_node:Variant=null)->void:
	begin()
	var active:=profile if profile!=null else _fallback_profile()
	var target_ref:WeakRef=null
	if is_instance_valid(target_node) and target_node is Node3D:target_ref=weakref(target_node)
	position=origin
	var tracked_target:=_tracked_target_position(target,target_ref)
	var direction:Vector3=(tracked_target-origin).normalized()
	# 厚重手感：飞行占总时长的比例调高（飞得更慢更沉），并给一道抛物线弧高。
	# arc_height 走 profile 参数，个别技能可覆盖（箭矢压平、巨石抬高）。
	var travel_ratio:=clampf(float(active.parameters.get("travel_ratio",0.66)),0.35,0.86)
	var arc_height:=maxf(0.0,float(active.parameters.get("arc_height",0.42)))
	var trail_puffs:=clampi(int(active.parameters.get("trail_puffs",8)),4,10)
	var charge:=_make_billboard("ChargeCore",Vector2(active.size*.94,active.size*.78),PROJECTILE_SHADER,{"dark_color":active.dark_color,"main_color":active.main_color,"core_color":active.core_color,"seed":3.2,"halo":0.0})
	charge.scale=Vector3.ONE*.12
	# Finish the charge animation before the release phase frees the charge node.
	# This prevents a captured charge reference from becoming null mid-tween.
	CURVES.tween_method(self,func(v:float)->void:if is_instance_valid(charge):charge.scale=Vector3.ONE*v,.12,.82,active.duration*.12,"ease_out_back")
	_tween_shader(charge.material_override as ShaderMaterial,"progress",0.0,.24,active.duration*.12)
	await get_tree().create_timer(active.duration*.15).timeout
	if _finished:return
	_spawn_release_sparks(direction,active)
	charge.queue_free()
	var tail:=_make_tail(direction,active)
	var halo:=_make_billboard("ProjectileDarkHalo",Vector2(active.size*1.38,active.size*1.08),PROJECTILE_SHADER,{"dark_color":active.dark_color.darkened(.18),"main_color":active.main_color.darkened(.25),"core_color":active.main_color,"seed":8.5,"halo":1.0})
	var body:=_make_billboard("ProjectileBody",Vector2(active.size*1.08,active.size*.86),PROJECTILE_SHADER,{"dark_color":active.dark_color,"main_color":active.main_color,"core_color":active.core_color,"seed":5.4,"halo":0.0,"wave_amount":0.07,"spiral_amount":0.20,"flow_speed":7.0})
	var streak:=_make_streak(direction,active)
	_tween_shader(halo.material_override as ShaderMaterial,"progress",.10,.80,active.duration*.62)
	_tween_shader(body.material_override as ShaderMaterial,"progress",.10,.80,active.duration*.62)
	var travel_duration:=active.duration*travel_ratio
	var travel_elapsed:=0.0
	var puff_index:=0
	var puff_interval:=travel_duration/float(trail_puffs)
	while travel_elapsed<travel_duration:
		await get_tree().process_frame
		if _finished:return
		travel_elapsed+=get_process_delta_time()
		tracked_target=_tracked_target_position(tracked_target,target_ref)
		var ratio:=clampf(travel_elapsed/travel_duration,0.0,1.0)
		# 水平匀速推进（不再用 ratio*ratio 的加速冲刺，那是"嗖一下"的轻飘感来源），
		# 叠加一道 sin 抛物线弧——像有质量的重物被抛出、受重力下坠，落点带沉感。
		position=origin.lerp(tracked_target,ratio)+Vector3(0.0,arc_height*sin(ratio*PI),0.0)
		while puff_index<trail_puffs and travel_elapsed>=puff_interval*float(puff_index+1):
			_spawn_trail_puff(active,puff_index)
			puff_index+=1
	await get_tree().create_timer(active.duration*.04).timeout
	if _finished:return
	body.queue_free();halo.queue_free();tail.queue_free();streak.queue_free()
	_spawn_impact(active)
	await get_tree().create_timer(active.duration*.34).timeout
	finish()


func _tracked_target_position(fallback:Vector3,target_ref:WeakRef)->Vector3:
	if target_ref==null:return fallback
	var target_node:Variant=target_ref.get_ref()
	if not (target_node is Node3D) or not is_instance_valid(target_node):return fallback
	var tracked:Vector3=target_node.global_position
	if get_parent() is Node3D:
		tracked=(get_parent() as Node3D).to_local(target_node.global_position)
	tracked.y=fallback.y
	return tracked

func _make_billboard(node_name:String,size:Vector2,shader_code:String,params:Dictionary)->MeshInstance3D:
	var q:=QuadMesh.new();q.size=size
	var n:=MeshInstance3D.new();n.name=node_name;n.mesh=q;n.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m:=ShaderMaterial.new();m.shader = SHADER_CACHE.get_shader(shader_code)
	for key in params:m.set_shader_parameter(key,params[key])
	m.set_shader_parameter("opacity",vfx_alpha);n.material_override=m;add_child(n);_materials.append(m);return n

func _make_tail(direction:Vector3,profile:VFXProfile3D)->MeshInstance3D:
	var tail:=_make_billboard("ProjectileDirectionalTail",Vector2(profile.size*1.55,profile.size*.72),TAIL_SHADER,{"dark_color":profile.dark_color.darkened(.12),"main_color":profile.main_color,"core_color":profile.core_color})
	tail.rotation.z=atan2(direction.y,direction.x)
	tail.position=-direction*profile.size*.58+Vector3(0.0,0.0,.025)
	_tween_shader(tail.material_override as ShaderMaterial,"progress",0.0,.82,profile.duration*.64)
	return tail

func _make_streak(direction:Vector3,profile:VFXProfile3D)->MeshInstance3D:
	var streak:=_make_billboard("ProjectileFlowStreak",Vector2(profile.size*1.75,profile.size*.44),STREAK_SHADER,{"dark_color":profile.dark_color.darkened(.08),"main_color":profile.main_color,"core_color":profile.core_color,"seed":4.7,"emission":profile.emission_energy})
	streak.rotation.z=atan2(direction.y,direction.x)
	streak.position=-direction*profile.size*.72+Vector3(0.0,0.0,.035)
	_tween_shader(streak.material_override as ShaderMaterial,"progress",0.0,.86,profile.duration*.68)
	return streak

func _spawn_trail_puff(profile:VFXProfile3D,index:int)->void:
	var n:=_make_billboard("TrailPuff_%d"%index,Vector2(profile.size*.68,profile.size*.46),PUFF_SHADER,{"color":profile.dark_color.lerp(profile.main_color,.34),"seed":float(index)*2.7})
	n.top_level=true;n.global_position=global_position-Vector3(.10,0.0,.01);n.scale=Vector3.ONE*(.58+float(index%2)*.12)
	var m:=n.material_override as ShaderMaterial
	var t:=track_tween(create_tween());t.set_parallel(true);t.tween_property(n,"scale",Vector3.ONE*1.12,profile.duration*.28).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT);t.tween_property(n,"position:y",n.position.y+.16,profile.duration*.28);_tween_shader(m,"progress",0.0,1.0,profile.duration*.28);t.set_parallel(false);t.tween_callback(n.queue_free)

func _spawn_release_sparks(direction:Vector3,profile:VFXProfile3D)->void:
	for i in range(maxi(3, QUALITY.auxiliary_layers(6))):
		var out:=direction.rotated(Vector3.FORWARD,-.85+float(i)*.34).normalized()
		var spark:=_make_spark(out,profile.size*(.32+float(i%2)*.12),profile.size*.035,profile.core_color,profile.emission_energy)
		add_child(spark)
		var t:=track_tween(create_tween());t.set_parallel(true);t.tween_property(spark,"position",out*profile.size*.58,profile.duration*.20).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT);t.tween_property(spark,"scale",Vector3(.08,.08,1.0),profile.duration*.20);t.set_parallel(false);t.tween_callback(spark.queue_free)

func _spawn_impact(profile:VFXProfile3D)->void:
	var n:=_make_billboard("TargetImpact",Vector2(profile.size*2.05,profile.size*1.72),IMPACT_SHADER,{"main_color":profile.main_color,"core_color":profile.core_color})
	var m:=n.material_override as ShaderMaterial;n.scale=Vector3.ONE*.24
	CURVES.tween_method(self,func(v:float)->void:if is_instance_valid(n):n.scale=Vector3.ONE*v,.24,1.28,profile.duration*.22,"explosive_out")
	_tween_shader(m,"progress",0.0,1.0,profile.duration*.28)
	_spawn_release_sparks(Vector3.RIGHT,profile)

func _make_spark(direction:Vector3,length:float,width:float,color:Color,energy:float)->MeshInstance3D:
	var side:=Vector3(-direction.y,direction.x,0.0).normalized();var arrays:=[];arrays.resize(Mesh.ARRAY_MAX);arrays[Mesh.ARRAY_VERTEX]=PackedVector3Array([-side*width,side*width,direction*length]);arrays[Mesh.ARRAY_INDEX]=PackedInt32Array([0,1,2]);var mesh:=ArrayMesh.new();mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays);var n:=MeshInstance3D.new();n.mesh=mesh;n.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;var m:=StandardMaterial3D.new();m.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED;m.transparency=BaseMaterial3D.TRANSPARENCY_ALPHA;m.albedo_color=color;m.emission_enabled=true;m.emission=color;m.emission_energy_multiplier=minf(energy,4.0);n.material_override=m;return n

func _tween_shader(material:ShaderMaterial,param:String,from:float,to:float,duration:float)->void:
	var t:=track_tween(create_tween());t.tween_method(func(v:float)->void:if is_instance_valid(material):material.set_shader_parameter(param,v),from,to,duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

func set_vfx_alpha(value:float)->void:
	super.set_vfx_alpha(value)
	for m in _materials:if is_instance_valid(m):m.set_shader_parameter("opacity",vfx_alpha)

func _fallback_profile()->VFXProfile3D:
	var p:=VFXProfile3D.new();p.dark_color=Color(.15,.018,.006);p.main_color=Color(.95,.18,.025);p.core_color=Color(1.0,.78,.22);p.size=.82;p.duration=1.05;p.particle_count=12;p.emission_energy=3.6;return p
