extends VFXBlockRoot
class_name VFXVortexField3D

const TEX_SWIRL:=preload("res://assets/vfx_textures/swirl_arms.png")
const TEX_RING:=preload("res://assets/vfx_textures/ragged_ring.png")
const TEX_WISP:=preload("res://assets/vfx_textures/smoke_wisp.png")
const TEX_FLARE:=preload("res://assets/vfx_textures/flare_star.png")
const TEX_NOISE:=preload("res://assets/vfx_textures/noise_tile.png")

const FIELD_SHADER:="""
shader_type spatial;render_mode unshaded,cull_disabled,depth_draw_never,blend_mix;
uniform sampler2D mask_tex:filter_linear_mipmap,repeat_disable;uniform sampler2D noise_tex:filter_linear_mipmap,repeat_enable;
uniform vec4 dark_color:source_color;uniform vec4 main_color:source_color;uniform vec4 core_color:source_color;uniform float life=0.0;uniform float opacity=1.0;uniform float phase=0.0;uniform float speed=1.0;uniform float layer=0.0;uniform float energy=3.0;
vec2 rot(vec2 p,float a){float c=cos(a),s=sin(a);return vec2(c*p.x-s*p.y,s*p.x+c*p.y);}
void fragment(){vec2 p=UV-vec2(.5);float r=length(p)*2.0;float n=texture(noise_tex,UV*2.0+vec2(TIME*.07,phase)).r;float mask=texture(mask_tex,rot(p,TIME*speed+phase)+vec2(.5)).a;float hollow=smoothstep(.12+.10*layer,.34+.10*layer,r);float edge=smoothstep(1.08,0.76+(n-.5)*.16,r);float hot=pow(mask,2.2)*(1.0-layer*.58);float fade=smoothstep(0.0,.10,life)*(1.0-smoothstep(.76,1.0,life));vec3 c=mix(dark_color.rgb,main_color.rgb,mask);c=mix(c,core_color.rgb,hot);ALBEDO=c;EMISSION=c*energy*(.22+hot*1.35);ALPHA=mask*hollow*edge*fade*opacity*mix(.88,.38,layer);}
"""

const WISP_SHADER:="""
shader_type spatial;render_mode unshaded,cull_disabled,depth_draw_never,blend_mix;
uniform sampler2D wisp_tex:filter_linear_mipmap,repeat_disable;uniform vec4 dark_color:source_color;uniform vec4 main_color:source_color;uniform float life=0.0;uniform float opacity=1.0;
void vertex(){MODELVIEW_MATRIX=VIEW_MATRIX*mat4(INV_VIEW_MATRIX[0],INV_VIEW_MATRIX[1],INV_VIEW_MATRIX[2],MODEL_MATRIX[3]);}
void fragment(){float a=texture(wisp_tex,UV).a;float f=sin(clamp(life,0.0,1.0)*3.14159);vec3 c=mix(dark_color.rgb,main_color.rgb,a);ALBEDO=c;EMISSION=c*(.25+a*.7);ALPHA=a*f*opacity*.82;}
"""

const TENDRIL_SHADER:="""
shader_type spatial;render_mode unshaded,cull_disabled,depth_draw_never,blend_mix;
uniform sampler2D noise_tex:filter_linear_mipmap,repeat_enable;uniform vec4 dark_color:source_color;uniform vec4 main_color:source_color;uniform vec4 core_color:source_color;uniform float life=0.0;uniform float opacity=1.0;uniform float phase=0.0;uniform float energy=3.0;
void fragment(){float across=abs(UV.y*2.0-1.0);float n=texture(noise_tex,vec2(UV.x*2.7-TIME*.42+phase,UV.y*1.8)).r;float taper=smoothstep(0.0,.16,UV.x)*(1.0-smoothstep(.84,1.0,UV.x));float torn=1.0-smoothstep(.48+n*.18,.94,across/max(taper,.08));float hot=1.0-smoothstep(.04,.22,across);float reveal=smoothstep(0.0,.16,life-UV.x*.22);float fade=1.0-smoothstep(.72,1.0,life);vec3 c=mix(dark_color.rgb,main_color.rgb,torn*.78);c=mix(c,core_color.rgb,hot*.42);ALBEDO=c;EMISSION=c*energy*(.18+hot*.78);ALPHA=torn*reveal*fade*opacity*.86;}
"""

var _materials:Array[ShaderMaterial]=[]

func play_profile(profile:VFXProfile3D,context:Dictionary)->void:
	play_vortex(context.get("target",Vector3.ZERO),profile)

func play_vortex(at:Vector3,profile:VFXProfile3D=null)->void:
	begin();position=at+Vector3(0.0,.025,0.0);var active:=profile if profile!=null else _fallback_profile();var d:=active.duration;var s:=active.size
	var shadow:=_ground_layer("VortexDarkMass",TEX_SWIRL,Vector2(s*2.35,s*1.62),active,0.0,.34,0);shadow.scale=Vector3.ONE*.18
	var body:=_ground_layer("VortexFlowBody",TEX_SWIRL,Vector2(s*2.02,s*1.38),active,2.4,-.82,1);body.scale=Vector3.ONE*.12
	var rim:=_ground_layer("VortexRaggedRim",TEX_RING,Vector2(s*2.28,s*1.54),active,4.7,.46,2);rim.scale=Vector3.ONE*.10
	for n in [shadow,body,rim]:var tw:=track_tween(create_tween());tw.tween_property(n,"scale",Vector3.ONE,d*.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_tween_life(shadow,d*1.02,0.0);_tween_life(body,d*.94,d*.035);_tween_life(rim,d*.86,d*.08)
	_spawn_ground_tendrils(active)
	_spawn_suction_wisps(active)
	_spawn_center_flash(active,d*.16)
	await get_tree().create_timer(d+.12).timeout;finish()

func _spawn_ground_tendrils(profile:VFXProfile3D)->void:
	for arm in range(5):
		var verts:=PackedVector3Array();var uvs:=PackedVector2Array();var indices:=PackedInt32Array();var segments:=20;var phase:=float(arm)/5.0*TAU;var width:=profile.size*(.13+.025*float(arm%2))
		for i in range(segments+1):
			var t:=float(i)/float(segments);var angle:=phase+t*(2.05+.12*float(arm%2));var radius:=lerpf(profile.size*1.08,profile.size*.10,t);var p:=Vector3(cos(angle)*radius,.016+float(arm)*.002,sin(angle)*radius*.68);var tangent:=Vector3(-sin(angle),0.0,cos(angle)*.68).normalized();var side:=Vector3(-tangent.z,0.0,tangent.x).normalized();var w:=width*sin(t*PI);verts.append(p-side*w);verts.append(p+side*w);uvs.append(Vector2(t,0));uvs.append(Vector2(t,1));if i<segments:var k:=i*2;indices.append_array(PackedInt32Array([k,k+1,k+3,k,k+3,k+2]))
		var arrays:=[];arrays.resize(Mesh.ARRAY_MAX);arrays[Mesh.ARRAY_VERTEX]=verts;arrays[Mesh.ARRAY_TEX_UV]=uvs;arrays[Mesh.ARRAY_INDEX]=indices;var mesh:=ArrayMesh.new();mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays);var n:=MeshInstance3D.new();n.name="VortexTendril_%d"%arm;n.mesh=mesh;n.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;var m:=ShaderMaterial.new();var sh:=Shader.new();sh.code=TENDRIL_SHADER;m.shader=sh;m.set_shader_parameter("noise_tex",TEX_NOISE);m.set_shader_parameter("dark_color",profile.dark_color);m.set_shader_parameter("main_color",profile.main_color);m.set_shader_parameter("core_color",profile.core_color);m.set_shader_parameter("phase",phase);m.set_shader_parameter("energy",profile.emission_energy);m.set_shader_parameter("opacity",vfx_alpha);n.material_override=m;add_child(n);_materials.append(m);n.scale=Vector3.ONE*.12
		var delay:=profile.duration*(.035+.018*float(arm));var tw:=track_tween(create_tween());tw.tween_interval(delay);tw.tween_property(n,"scale",Vector3.ONE,profile.duration*.16).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT);_tween_life(n,profile.duration*.82,delay)

func _ground_layer(node_name:String,texture:Texture2D,size:Vector2,profile:VFXProfile3D,phase:float,speed:float,layer:int)->MeshInstance3D:
	var q:=QuadMesh.new();q.size=size;var n:=MeshInstance3D.new();n.name=node_name;n.mesh=q;n.rotation_degrees.x=-90.0;n.position.y=.006*float(layer);n.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m:=ShaderMaterial.new();var sh:=Shader.new();sh.code=FIELD_SHADER;m.shader=sh;m.set_shader_parameter("mask_tex",texture);m.set_shader_parameter("noise_tex",TEX_NOISE);m.set_shader_parameter("dark_color",profile.dark_color);m.set_shader_parameter("main_color",profile.main_color);m.set_shader_parameter("core_color",profile.core_color);m.set_shader_parameter("phase",phase);m.set_shader_parameter("speed",speed);m.set_shader_parameter("layer",float(layer)/2.0);m.set_shader_parameter("energy",profile.emission_energy);m.set_shader_parameter("opacity",vfx_alpha);n.material_override=m;add_child(n);_materials.append(m);return n

func _spawn_suction_wisps(profile:VFXProfile3D)->void:
	for i in range(clampi(profile.particle_count,8,16)):
		var q:=QuadMesh.new();q.size=Vector2(profile.size*(.15+.04*float(i%3)),profile.size*(.42+.08*float(i%2)));var n:=MeshInstance3D.new();n.name="VortexSuctionWisp_%d"%i;n.mesh=q;n.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var m:=ShaderMaterial.new();var sh:=Shader.new();sh.code=WISP_SHADER;m.shader=sh;m.set_shader_parameter("wisp_tex",TEX_WISP);m.set_shader_parameter("dark_color",profile.dark_color);m.set_shader_parameter("main_color",profile.main_color);m.set_shader_parameter("opacity",vfx_alpha);n.material_override=m;add_child(n);_materials.append(m)
		var a:=float(i)/float(clampi(profile.particle_count,8,16))*TAU;var r:=profile.size*(1.05+.30*float(i%3));n.position=Vector3(cos(a)*r,.12+profile.size*.08*float(i%2),sin(a)*r*.68);n.visible=false
		var delay:=profile.duration*(.08+.035*float(i));var travel:=profile.duration*(.36+.05*float(i%3));var tw:=track_tween(create_tween());tw.tween_interval(delay);tw.tween_callback(func():if is_instance_valid(n):n.visible=true);tw.tween_method(func(t:float):if is_instance_valid(n):var e:=t*t;var ang:=a+t*2.4;var rr:=lerpf(r,profile.size*.12,e);n.position=Vector3(cos(ang)*rr,lerpf(n.position.y,.04,e),sin(ang)*rr*.68);m.set_shader_parameter("life",t),0.0,1.0,travel);tw.tween_callback(n.queue_free)

func _spawn_center_flash(profile:VFXProfile3D,delay:float)->void:
	var q:=QuadMesh.new();q.size=Vector2(profile.size*.82,profile.size*.82);var n:=MeshInstance3D.new();n.name="VortexCollapseCore";n.mesh=q;n.rotation_degrees.x=-90.0;n.position.y=.025;n.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m:=ShaderMaterial.new();var sh:=Shader.new();sh.code=FIELD_SHADER;m.shader=sh;m.set_shader_parameter("mask_tex",TEX_FLARE);m.set_shader_parameter("noise_tex",TEX_NOISE);m.set_shader_parameter("dark_color",profile.main_color);m.set_shader_parameter("main_color",profile.core_color);m.set_shader_parameter("core_color",Color.WHITE);m.set_shader_parameter("speed",0.0);m.set_shader_parameter("energy",profile.emission_energy*1.25);m.set_shader_parameter("opacity",vfx_alpha);n.material_override=m;add_child(n);_materials.append(m);n.scale=Vector3.ONE*.18
	var tw:=track_tween(create_tween());tw.tween_interval(delay);tw.tween_property(n,"scale",Vector3.ONE*.82,profile.duration*.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT);tw.tween_property(n,"scale",Vector3.ONE*.28,profile.duration*.22).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_tween_life(n,profile.duration*.36,delay)

func _tween_life(node:MeshInstance3D,duration:float,delay:float)->void:
	var m:=node.material_override as ShaderMaterial
	var tw:=track_tween(create_tween())
	if delay>0.0:
		tw.tween_interval(delay)
	tw.tween_method(func(t:float):if is_instance_valid(m):m.set_shader_parameter("life",t),0.0,1.0,duration)

func set_vfx_alpha(value:float)->void:
	super.set_vfx_alpha(value)
	for m in _materials:if is_instance_valid(m):m.set_shader_parameter("opacity",vfx_alpha)

func _fallback_profile()->VFXProfile3D:
	var p:=VFXProfile3D.new();p.dark_color=Color(.015,.008,.035);p.main_color=Color(.25,.055,.48);p.core_color=Color(.74,.30,1.0);p.size=1.05;p.duration=1.85;p.particle_count=12;p.emission_energy=3.2;return p
