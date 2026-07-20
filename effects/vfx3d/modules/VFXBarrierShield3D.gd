extends VFXBlockRoot
class_name VFXBarrierShield3D

const CURVES:=preload("res://effects/vfx3d/core/VFXCurveLibrary3D.gd")

const ARC_SHADER:="""
shader_type spatial;render_mode unshaded,cull_disabled,depth_draw_never,blend_add;
uniform vec4 dark_color:source_color;uniform vec4 main_color:source_color;uniform vec4 core_color:source_color;uniform float progress=0.0;uniform float opacity=1.0;uniform float seed=0.0;uniform float hit=0.0;
void fragment(){float across=abs(UV.y*2.0-1.0);float edge=1.0-smoothstep(.64,1.0,across);float painted=.86+.14*smoothstep(-.35,.45,sin(UV.x*23.0+seed)+sin(UV.x*51.0-seed)*.45);float sweep=smoothstep(0.0,.12,progress-UV.x*.22)*(1.0-smoothstep(.82,1.0,progress));float hot=1.0-smoothstep(.08,.30,across);vec3 c=mix(dark_color.rgb,main_color.rgb,edge);c=mix(c,core_color.rgb,hot*(.34+hit*.66));ALBEDO=c;EMISSION=c*(1.9+hot*2.7+hit*2.6);ALPHA=edge*painted*sweep*opacity*(.70+hot*.26);}
"""

const MEMBRANE_SHADER:="""
shader_type spatial;render_mode unshaded,cull_disabled,depth_draw_never,blend_add;
uniform vec4 dark_color:source_color;uniform vec4 main_color:source_color;uniform vec4 core_color:source_color;uniform float progress=0.0;uniform float opacity=1.0;
void vertex(){MODELVIEW_MATRIX=VIEW_MATRIX*mat4(INV_VIEW_MATRIX[0],INV_VIEW_MATRIX[1],INV_VIEW_MATRIX[2],MODEL_MATRIX[3]);}
void fragment(){vec2 p=(UV-vec2(.5))*2.0;float a=atan(p.y,p.x);float r=length(p*vec2(.88,1.04));float edge=.78+.035*sin(a*6.0)+.022*sin(a*11.0);float shell=smoothstep(edge,edge-.10,r);float inside=smoothstep(edge-.03,.16,r);float scan=.5+.5*sin(p.y*18.0-TIME*4.0);float life=smoothstep(.0,.16,progress)*(1.0-smoothstep(.78,1.0,progress));vec3 c=mix(dark_color.rgb,main_color.rgb,inside);c=mix(c,core_color.rgb,shell);ALBEDO=c;EMISSION=c*(.7+shell*2.5);ALPHA=(inside*.13+shell*.40+scan*inside*.035)*life*opacity;}
"""

const RIPPLE_SHADER:="""
shader_type spatial;render_mode unshaded,cull_disabled,depth_draw_never,blend_add;
uniform vec4 main_color:source_color;uniform vec4 core_color:source_color;uniform float progress=0.0;uniform float opacity=1.0;
void vertex(){MODELVIEW_MATRIX=VIEW_MATRIX*mat4(INV_VIEW_MATRIX[0],INV_VIEW_MATRIX[1],INV_VIEW_MATRIX[2],MODEL_MATRIX[3]);}
void fragment(){vec2 p=(UV-vec2(.5))*2.0;float r=length(p);float a=atan(p.y,p.x);float ring=smoothstep(.09,.008,abs(r-progress*.92));float crack=pow(max(0.0,cos(a*6.0+sin(r*17.0)*.25)),28.0)*smoothstep(.15,.32,r)*(1.0-smoothstep(.48,.90,r));float fade=1.0-smoothstep(.46,1.0,progress);vec3 c=mix(main_color.rgb,core_color.rgb,ring);ALBEDO=c;EMISSION=c*(2.1+ring*2.6);ALPHA=(ring+crack*.58)*fade*opacity;}
"""

var _materials:Array[ShaderMaterial]=[]
var _arc_nodes:Array[MeshInstance3D]=[]

func play_profile(profile:VFXProfile3D,context:Dictionary)->void:
	play_barrier(context.get("target",Vector3.ZERO),profile)

func play_barrier(at:Vector3,profile:VFXProfile3D=null)->void:
	begin();position=at+Vector3(0.0,.62,0.0)
	var active:=profile if profile!=null else _fallback_profile()
	var membrane:=_make_membrane(active)
	for i in range(3):
		var start:float=-2.72+float(i)*2.08;var span:=1.72+float(i%2)*.16;var radius:=active.size*(.76+float(i%2)*.055);var arc:=_make_arc(radius,active.size*.12,start,start+span,40);arc.name="BrokenShieldArc_%d"%i;arc.material_override=_arc_material(active,float(i)*4.3);arc.scale=Vector3.ONE*.10;add_child(arc);_arc_nodes.append(arc);CURVES.tween_method(self,func(v:float)->void:if is_instance_valid(arc):arc.scale=Vector3.ONE*v,.10,1.0,active.duration*(.14+float(i)*.022),"ease_out_back")
	_tween_shader(membrane.material_override as ShaderMaterial,"progress",0.0,.72,active.duration*.76)
	await get_tree().create_timer(active.duration*.22).timeout
	if _finished:return
	_hit_ripple(active)
	for m in _materials:_tween_shader(m,"hit",0.0,1.0,active.duration*.12)
	await get_tree().create_timer(active.duration*.28).timeout
	if _finished:return
	_spawn_crack_shards(active)
	for i in range(_arc_nodes.size()):
		var arc:=_arc_nodes[i];var outward:=Vector3(cos(float(i)*1.6),sin(float(i)*1.6),0.0);var t:=track_tween(create_tween());t.set_parallel(true);t.tween_property(arc,"position",outward*active.size*.42,active.duration*.28).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT);t.tween_property(arc,"scale",Vector3.ONE*(.18+float(i)*.04),active.duration*.28).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await get_tree().create_timer(active.duration*.34).timeout
	finish()

func _make_arc(radius:float,thickness:float,start:float,end:float,segments:int)->MeshInstance3D:
	var vertices:=PackedVector3Array();var uvs:=PackedVector2Array();var indices:=PackedInt32Array()
	for i in range(segments+1):
		var t:=float(i)/float(segments);var a:=lerpf(start,end,t);var wobble:=(sin(t*PI*5.0+start)*.10+sin(t*PI*9.0-start)*.04)*thickness;var inner:=radius-thickness+wobble;var outer:=radius+thickness*.34+wobble;vertices.append(Vector3(cos(a)*inner,sin(a)*inner,0));vertices.append(Vector3(cos(a)*outer,sin(a)*outer,0));uvs.append(Vector2(t,0));uvs.append(Vector2(t,1));if i<segments:var b:=i*2;indices.append_array(PackedInt32Array([b,b+1,b+3,b,b+3,b+2]))
	var arr:=[];arr.resize(Mesh.ARRAY_MAX);arr[Mesh.ARRAY_VERTEX]=vertices;arr[Mesh.ARRAY_TEX_UV]=uvs;arr[Mesh.ARRAY_INDEX]=indices;var mesh:=ArrayMesh.new();mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arr);var n:=MeshInstance3D.new();n.mesh=mesh;n.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;return n

func _arc_material(profile:VFXProfile3D,seed:float)->ShaderMaterial:
	var m:=ShaderMaterial.new();var s:=Shader.new();s.code=ARC_SHADER;m.shader=s;m.set_shader_parameter("dark_color",profile.dark_color);m.set_shader_parameter("main_color",profile.main_color);m.set_shader_parameter("core_color",profile.core_color);m.set_shader_parameter("seed",seed);m.set_shader_parameter("progress",.18);m.set_shader_parameter("hit",0.0);m.set_shader_parameter("opacity",vfx_alpha);_materials.append(m);_tween_shader(m,"progress",.18,.70,profile.duration*.72);return m

func _make_membrane(profile:VFXProfile3D)->MeshInstance3D:
	var q:=QuadMesh.new();q.size=profile.size*Vector2(1.72,1.78)
	var n:=MeshInstance3D.new();n.name="ShieldEnergyMembrane";n.mesh=q;n.position.z=.03;n.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m:=ShaderMaterial.new();var s:=Shader.new();s.code=MEMBRANE_SHADER;m.shader=s;m.set_shader_parameter("dark_color",profile.dark_color);m.set_shader_parameter("main_color",profile.main_color);m.set_shader_parameter("core_color",profile.core_color);m.set_shader_parameter("opacity",vfx_alpha);n.material_override=m;add_child(n);_materials.append(m);return n

func _hit_ripple(profile:VFXProfile3D)->void:
	var q:=QuadMesh.new();q.size=profile.size*Vector2(1.42,1.42);var n:=MeshInstance3D.new();n.name="ShieldHitRipple";n.mesh=q;n.position=Vector3(profile.size*.42,.05,-.04);n.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;var m:=ShaderMaterial.new();var s:=Shader.new();s.code=RIPPLE_SHADER;m.shader=s;m.set_shader_parameter("main_color",profile.main_color);m.set_shader_parameter("core_color",profile.core_color);m.set_shader_parameter("opacity",vfx_alpha);n.material_override=m;add_child(n);_materials.append(m);_tween_shader(m,"progress",0.0,1.0,profile.duration*.24)

func _spawn_crack_shards(profile:VFXProfile3D)->void:
	for i in range(9):
		var a:=-1.1+float(i)*.28;var dir:=Vector3(cos(a),sin(a),0.0);var n:=_make_shard(dir,profile.size*(.18+float(i%3)*.05),profile.size*.035,profile.core_color,profile.emission_energy);n.position=Vector3(profile.size*.38,0.0,-.02);add_child(n);var t:=track_tween(create_tween());t.set_parallel(true);t.tween_property(n,"position",n.position+dir*profile.size*(.42+float(i%2)*.12),profile.duration*.25);t.tween_property(n,"scale",Vector3(.06,.08,1.0),profile.duration*.25);t.set_parallel(false);t.tween_callback(n.queue_free)

func _make_shard(dir:Vector3,length:float,width:float,color:Color,energy:float)->MeshInstance3D:
	var side:=Vector3(-dir.y,dir.x,0).normalized();var arr:=[];arr.resize(Mesh.ARRAY_MAX);arr[Mesh.ARRAY_VERTEX]=PackedVector3Array([-side*width,side*width,dir*length]);arr[Mesh.ARRAY_INDEX]=PackedInt32Array([0,1,2]);var mesh:=ArrayMesh.new();mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arr);var n:=MeshInstance3D.new();n.mesh=mesh;n.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;var m:=StandardMaterial3D.new();m.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED;m.albedo_color=color;m.emission_enabled=true;m.emission=color;m.emission_energy_multiplier=minf(energy,4.0);n.material_override=m;return n

func _tween_shader(m:ShaderMaterial,param:String,from:float,to:float,duration:float)->void:
	var t:=track_tween(create_tween());t.tween_method(func(v:float)->void:if is_instance_valid(m):m.set_shader_parameter(param,v),from,to,duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
func set_vfx_alpha(value:float)->void:
	super.set_vfx_alpha(value)
	for m in _materials:
		if is_instance_valid(m):m.set_shader_parameter("opacity",vfx_alpha)
func _fallback_profile()->VFXProfile3D:
	var p:=VFXProfile3D.new();p.dark_color=Color(.045,.025,.11);p.main_color=Color(.28,.34,.92);p.core_color=Color(.72,.88,1.0);p.size=1.05;p.duration=1.45;p.particle_count=12;p.emission_energy=3.2;return p
