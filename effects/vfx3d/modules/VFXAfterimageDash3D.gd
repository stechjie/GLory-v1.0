extends VFXBlockRoot
class_name VFXAfterimageDash3D
const SHADER_CACHE := preload("res://effects/vfx3d/core/VFXShaderCache.gd")

const CURVES:=preload("res://effects/vfx3d/core/VFXCurveLibrary3D.gd")
const TEX_WISP:=preload("res://assets/vfx_textures/smoke_wisp.png")
const TEX_FLARE:=preload("res://assets/vfx_textures/flare_star.png")
const TEX_NOISE:=preload("res://assets/vfx_textures/noise_tile.png")

const RIBBON_SHADER:="""
shader_type spatial;render_mode unshaded,cull_disabled,depth_draw_never,blend_add;
uniform sampler2D noise_tex:filter_linear_mipmap,repeat_enable;uniform vec4 dark_color:source_color;uniform vec4 main_color:source_color;uniform vec4 core_color:source_color;uniform float life=0.0;uniform float opacity=1.0;uniform float layer=0.0;uniform float energy=3.0;
void fragment(){float across=abs(UV.y*2.0-1.0);float n=texture(noise_tex,vec2(UV.x*3.2-TIME*.9,UV.y*1.4+layer)).r;float taper=sin(UV.x*3.14159);float edge=1.0-smoothstep(.46+n*.16,.92,across/max(taper,.08));float tear=.70+.30*smoothstep(-.2,.35,sin(UV.x*48.0+n*5.0));float hot=1.0-smoothstep(.04,.23,across);float reveal=smoothstep(0.0,.14,life-UV.x*.18);float fade=1.0-smoothstep(.62,1.0,life);vec3 c=mix(dark_color.rgb,main_color.rgb,edge);c=mix(c,core_color.rgb,hot*(1.0-layer*.55));ALBEDO=c;EMISSION=c*energy*(.45+hot*1.8);ALPHA=edge*tear*reveal*fade*opacity*mix(.88,.34,layer);}
"""

const GHOST_SHADER:="""
shader_type spatial;render_mode unshaded,cull_disabled,depth_draw_never,blend_mix;
uniform sampler2D mask_tex:filter_linear_mipmap,repeat_disable;uniform sampler2D noise_tex:filter_linear_mipmap,repeat_enable;uniform vec4 dark_color:source_color;uniform vec4 main_color:source_color;uniform float life=0.0;uniform float opacity=1.0;uniform float phase=0.0;
void vertex(){MODELVIEW_MATRIX=VIEW_MATRIX*mat4(INV_VIEW_MATRIX[0],INV_VIEW_MATRIX[1],INV_VIEW_MATRIX[2],MODEL_MATRIX[3]);}
void fragment(){float m=texture(mask_tex,UV).a;float n=texture(noise_tex,UV*2.2+vec2(phase,-TIME*.3)).r;float f=sin(clamp(life,0.0,1.0)*3.14159);float torn=m*smoothstep(.18,-.08,n-life*.45);vec3 c=mix(dark_color.rgb,main_color.rgb,m);ALBEDO=c;EMISSION=c*(.35+m*.85);ALPHA=torn*f*opacity*.68;}
"""

var _materials:Array[ShaderMaterial]=[]

func play_profile(profile:VFXProfile3D,context:Dictionary)->void:
	play_dash(context.get("origin",Vector3(-1.15,.2,0.0)),context.get("target",Vector3(1.15,.2,0.0)),profile)

func play_dash(origin:Vector3,target:Vector3,profile:VFXProfile3D=null)->void:
	begin();var active:=profile if profile!=null else _fallback_profile();var direction:=(target-origin).normalized();var d:=active.duration
	for layer in range(3):
		var ribbon:=_make_ribbon(origin,target,active,layer);ribbon.material_override=_ribbon_material(active,layer);add_child(ribbon);_life(ribbon,d*(.64+.06*float(layer)),d*.025*float(layer))
	for i in range(4):_spawn_ghost(origin,target,active,i)
	_spawn_departure(origin,direction,active)
	_spawn_arrival(target,direction,active,d*.42)
	await get_tree().create_timer(d+.08).timeout;finish()

func _make_ribbon(origin:Vector3,target:Vector3,profile:VFXProfile3D,layer:int)->MeshInstance3D:
	var verts:=PackedVector3Array();var uvs:=PackedVector2Array();var indices:=PackedInt32Array();var segments:=22;var delta:=target-origin;var dir:=delta.normalized();var side:=Vector3(-dir.y,dir.x,0.0).normalized();var width:=profile.size*(.18+.07*float(layer));var phase:=float(layer)*1.9
	for i in range(segments+1):
		var t:=float(i)/float(segments);var arc:=sin(t*PI)*profile.size*(.13+.025*float(layer));var wobble:=sin(t*PI*5.0+phase)*profile.size*.025;var p:=origin.lerp(target,t)+Vector3.UP*arc+side*wobble;var w:=width*sin(t*PI);verts.append(p-side*w);verts.append(p+side*w);uvs.append(Vector2(t,0));uvs.append(Vector2(t,1));if i<segments:var k:=i*2;indices.append_array(PackedInt32Array([k,k+1,k+3,k,k+3,k+2]))
	var arrays:=[];arrays.resize(Mesh.ARRAY_MAX);arrays[Mesh.ARRAY_VERTEX]=verts;arrays[Mesh.ARRAY_TEX_UV]=uvs;arrays[Mesh.ARRAY_INDEX]=indices;var mesh:=ArrayMesh.new();mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays);var n:=MeshInstance3D.new();n.name="DashRibbon_%d"%layer;n.mesh=mesh;n.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;return n

func _spawn_ghost(origin:Vector3,target:Vector3,profile:VFXProfile3D,index:int)->void:
	var q:=QuadMesh.new();q.size=Vector2(profile.size*(.34+.04*float(index%2)),profile.size*(.82+.08*float(index%2)));var n:=MeshInstance3D.new();n.name="DashAfterimage_%d"%index;n.mesh=q;n.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;var m:=_ghost_material(profile,float(index)*2.2);n.material_override=m;add_child(n);var ratio:=.12+.19*float(index);n.position=origin.lerp(target,ratio)+Vector3(0.0,profile.size*.38,.035+float(index)*.005);n.scale=Vector3(.18,.82,1.0);n.visible=false;var delay:=profile.duration*(.06+.07*float(index));var tw:=track_tween(create_tween());tw.tween_interval(delay);tw.tween_callback(func():if is_instance_valid(n):n.visible=true);tw.set_parallel(true);tw.tween_property(n,"position",origin.lerp(target,minf(1.0,ratio+.20))+Vector3(0.0,profile.size*.42,.04),profile.duration*.22).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT);tw.tween_property(n,"scale",Vector3(1.0,.92,1.0),profile.duration*.15).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT);_life(n,profile.duration*.30,delay)

func _spawn_departure(at:Vector3,direction:Vector3,profile:VFXProfile3D)->void:
	for i in range(6):
		var out:=(-direction).rotated(Vector3.FORWARD,-.55+.22*float(i));var n:=_make_streak(at,out,profile,i);var tw:=track_tween(create_tween());tw.tween_property(n,"position",at+out*profile.size*(.42+.08*float(i%2)),profile.duration*.17).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT);tw.tween_property(n,"scale",Vector3(.06,.08,1.0),profile.duration*.10)

func _spawn_arrival(at:Vector3,direction:Vector3,profile:VFXProfile3D,delay:float)->void:
	var q:=QuadMesh.new();q.size=Vector2(profile.size*1.08,profile.size*1.08);var n:=MeshInstance3D.new();n.name="DashArrivalSnap";n.mesh=q;n.position=at+Vector3(0.0,profile.size*.34,.08);n.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;var m:=_ghost_material(profile,9.7);m.set_shader_parameter("mask_tex",TEX_FLARE);n.material_override=m;add_child(n);n.scale=Vector3.ONE*.12;n.visible=false;var tw:=track_tween(create_tween());tw.tween_interval(delay);tw.tween_callback(func():if is_instance_valid(n):n.visible=true);tw.tween_property(n,"scale",Vector3.ONE*1.12,profile.duration*.10).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT);tw.tween_property(n,"scale",Vector3.ONE*.22,profile.duration*.15);_life(n,profile.duration*.27,delay)

func _make_streak(at:Vector3,direction:Vector3,profile:VFXProfile3D,index:int)->MeshInstance3D:
	var side:=Vector3(-direction.y,direction.x,0.0).normalized();var length:=profile.size*(.38+.06*float(index%3));var width:=profile.size*.026;var arrays:=[];arrays.resize(Mesh.ARRAY_MAX);arrays[Mesh.ARRAY_VERTEX]=PackedVector3Array([at-side*width,at+side*width,at+direction*length]);arrays[Mesh.ARRAY_TEX_UV]=PackedVector2Array([Vector2(0,0),Vector2(0,1),Vector2(1,.5)]);arrays[Mesh.ARRAY_INDEX]=PackedInt32Array([0,1,2]);var mesh:=ArrayMesh.new();mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays);var n:=MeshInstance3D.new();n.name="DashDepartureStreak_%d"%index;n.mesh=mesh;n.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;var mat:=StandardMaterial3D.new();mat.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED;mat.transparency=BaseMaterial3D.TRANSPARENCY_ALPHA;mat.albedo_color=profile.core_color;mat.emission_enabled=true;mat.emission=profile.core_color;mat.emission_energy_multiplier=minf(profile.emission_energy,4.0);n.material_override=mat;add_child(n);return n

func _ribbon_material(profile:VFXProfile3D,layer:int)->ShaderMaterial:
	var m:=ShaderMaterial.new();m.shader = SHADER_CACHE.get_shader(RIBBON_SHADER);m.set_shader_parameter("noise_tex",TEX_NOISE);m.set_shader_parameter("dark_color",profile.dark_color);m.set_shader_parameter("main_color",profile.main_color);m.set_shader_parameter("core_color",profile.core_color);m.set_shader_parameter("layer",float(layer)/2.0);m.set_shader_parameter("energy",profile.emission_energy);m.set_shader_parameter("opacity",vfx_alpha);_materials.append(m);return m

func _ghost_material(profile:VFXProfile3D,phase:float)->ShaderMaterial:
	var m:=ShaderMaterial.new();m.shader = SHADER_CACHE.get_shader(GHOST_SHADER);m.set_shader_parameter("mask_tex",TEX_WISP);m.set_shader_parameter("noise_tex",TEX_NOISE);m.set_shader_parameter("dark_color",profile.dark_color);m.set_shader_parameter("main_color",profile.main_color);m.set_shader_parameter("phase",phase);m.set_shader_parameter("opacity",vfx_alpha);_materials.append(m);return m

func _life(node:MeshInstance3D,duration:float,delay:float)->void:
	var m:=node.material_override as ShaderMaterial
	var tw:=track_tween(create_tween())
	if delay>0.0:
		tw.tween_interval(delay)
	tw.tween_method(func(t:float):if is_instance_valid(m):m.set_shader_parameter("life",t),0.0,1.0,duration)

func set_vfx_alpha(value:float)->void:
	super.set_vfx_alpha(value)
	for m in _materials:if is_instance_valid(m):m.set_shader_parameter("opacity",vfx_alpha)

func _fallback_profile()->VFXProfile3D:
	var p:=VFXProfile3D.new();p.dark_color=Color(.025,.035,.065);p.main_color=Color(.12,.62,.78);p.core_color=Color(.72,.98,1.0);p.size=.84;p.duration=.88;p.particle_count=10;p.emission_energy=3.3;return p
