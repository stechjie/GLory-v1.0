extends VFXBlockRoot
class_name VFXSummonSpawn3D

signal reveal_requested

const TEX_RING:=preload("res://assets/vfx_textures/ragged_ring.png")
const TEX_SWIRL:=preload("res://assets/vfx_textures/swirl_arms.png")
const TEX_WISP:=preload("res://assets/vfx_textures/smoke_wisp.png")
const TEX_FLARE:=preload("res://assets/vfx_textures/flare_star.png")
const TEX_NOISE:=preload("res://assets/vfx_textures/noise_tile.png")

const CARD_SHADER:="""
shader_type spatial;render_mode unshaded,cull_disabled,depth_draw_never,blend_mix;
uniform sampler2D mask_tex:filter_linear_mipmap,repeat_disable;uniform sampler2D noise_tex:filter_linear_mipmap,repeat_enable;uniform vec4 dark_color:source_color;uniform vec4 main_color:source_color;uniform vec4 core_color:source_color;uniform float life=0.0;uniform float opacity=1.0;uniform float phase=0.0;uniform float energy=3.0;uniform float billboard=1.0;
void vertex(){if(billboard>.5){MODELVIEW_MATRIX=VIEW_MATRIX*mat4(INV_VIEW_MATRIX[0],INV_VIEW_MATRIX[1],INV_VIEW_MATRIX[2],MODEL_MATRIX[3]);}}
void fragment(){float m=texture(mask_tex,UV).a;float n=texture(noise_tex,UV*2.0+vec2(phase,TIME*.12)).r;float reveal=smoothstep(n-.12,n+.12,clamp(life*1.55,0.0,1.0));float fade=1.0-smoothstep(.72,1.0,life);float hot=pow(m,2.5);vec3 c=mix(dark_color.rgb,main_color.rgb,m);c=mix(c,core_color.rgb,hot*.76);ALBEDO=c;EMISSION=c*energy*(.25+hot*1.25);ALPHA=m*reveal*fade*opacity*(.68+hot*.25);}
"""

const SHARD_SHADER:="""
shader_type spatial;render_mode unshaded,cull_disabled,depth_draw_never,blend_add;uniform vec4 main_color:source_color;uniform vec4 core_color:source_color;uniform float life=0.0;uniform float opacity=1.0;uniform float energy=3.0;void fragment(){float edge=1.0-smoothstep(.45,1.0,abs(UV.y*2.0-1.0));float f=sin(clamp(life,0.0,1.0)*3.14159);vec3 c=mix(main_color.rgb,core_color.rgb,edge);ALBEDO=c;EMISSION=c*energy*(.65+edge*1.8);ALPHA=edge*f*opacity;}
"""

var _materials:Array[ShaderMaterial]=[]

func play_profile(profile:VFXProfile3D,context:Dictionary)->void:
	play_summon(context.get("target",Vector3.ZERO),profile)

func play_summon(at:Vector3,profile:VFXProfile3D=null)->void:
	begin();position=at+Vector3(0.0,.025,0.0);var active:=profile if profile!=null else _fallback_profile();var d:=active.duration;var s:=active.size
	var anchor:=_card("SummonBrokenAnchor",TEX_RING,Vector2(s*1.78,s*1.22),active,0.0,false);anchor.rotation_degrees.x=-90.0;anchor.scale=Vector3.ONE*.15
	var swirl:=_card("SummonInwardSwirl",TEX_SWIRL,Vector2(s*1.48,s*1.02),active,2.7,false);swirl.rotation_degrees.x=-90.0;swirl.position.y=.012;swirl.scale=Vector3.ONE*.10
	for n in [anchor,swirl]:var tw:=track_tween(create_tween());tw.tween_property(n,"scale",Vector3.ONE,d*.17).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_life(anchor,d*.88,0.0);_life(swirl,d*.76,d*.05)
	_spawn_rising_curtains(active)
	_spawn_wisps(active)
	await get_tree().create_timer(d*.36).timeout
	if _finished:return
	reveal_requested.emit();_spawn_reveal_flash(active)
	await get_tree().create_timer(d*.72).timeout;finish()

func _spawn_rising_curtains(profile:VFXProfile3D)->void:
	for curtain in range(4):
		var verts:=PackedVector3Array();var uvs:=PackedVector2Array();var indices:=PackedInt32Array();var segments:=10;var base_x:=profile.size*(-.42+.28*float(curtain));var z:=.03+float(curtain)*.008;var width:=profile.size*(.11+.025*float(curtain%2))
		for i in range(segments+1):
			var t:=float(i)/float(segments);var x:=base_x+sin(t*PI*(1.4+.15*float(curtain))+float(curtain))*profile.size*.16;var y:=profile.size*(.02+t*(.82+.10*float(curtain%2)));var w:=width*(.35+.65*sin(t*PI));verts.append(Vector3(x-w,y,z));verts.append(Vector3(x+w,y,z));uvs.append(Vector2(t,0));uvs.append(Vector2(t,1));if i<segments:var k:=i*2;indices.append_array(PackedInt32Array([k,k+1,k+3,k,k+3,k+2]))
		var arrays:=[];arrays.resize(Mesh.ARRAY_MAX);arrays[Mesh.ARRAY_VERTEX]=verts;arrays[Mesh.ARRAY_TEX_UV]=uvs;arrays[Mesh.ARRAY_INDEX]=indices;var mesh:=ArrayMesh.new();mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays);var n:=MeshInstance3D.new();n.name="SummonEnergyCurtain_%d"%curtain;n.mesh=mesh;n.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;var m:=_material(SHARD_SHADER,profile);n.material_override=m;add_child(n);n.scale=Vector3.ONE*.08
		var delay:=profile.duration*(.07+.045*float(curtain));var tw:=track_tween(create_tween());tw.tween_interval(delay);tw.tween_property(n,"scale",Vector3.ONE,profile.duration*.14).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT);tw.tween_property(n,"position:y",profile.size*.22,profile.duration*.32).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT);_life(n,profile.duration*.54,delay)

func _spawn_wisps(profile:VFXProfile3D)->void:
	for i in range(clampi(profile.particle_count,7,13)):
		var n:=_card("SummonWisp_%d"%i,TEX_WISP,Vector2(profile.size*(.13+.04*float(i%3)),profile.size*(.42+.10*float(i%2))),profile,float(i)*1.3,true);var a:=float(i)*2.399;var r:=profile.size*(.34+.10*float(i%3));n.position=Vector3(cos(a)*r,.05,sin(a)*r*.62);n.visible=false
		var delay:=profile.duration*(.10+.035*float(i));var tw:=track_tween(create_tween());tw.tween_interval(delay);tw.tween_callback(func():if is_instance_valid(n):n.visible=true);tw.set_parallel(true);tw.tween_property(n,"position:y",profile.size*(1.05+.12*float(i%2)),profile.duration*.44).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT);tw.tween_property(n,"position:x",n.position.x*.45,profile.duration*.44);tw.set_parallel(false);tw.tween_callback(n.queue_free);_life(n,profile.duration*.44,delay)

func _spawn_reveal_flash(profile:VFXProfile3D)->void:
	var n:=_card("SummonRevealFlash",TEX_FLARE,Vector2(profile.size*1.38,profile.size*1.38),profile,8.1,true);n.position.y=profile.size*.66;n.scale=Vector3.ONE*.16;var tw:=track_tween(create_tween());tw.tween_property(n,"scale",Vector3.ONE*1.15,profile.duration*.10).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT);tw.tween_property(n,"scale",Vector3.ONE*.34,profile.duration*.18).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN);_life(n,profile.duration*.30,0.0)

func _card(node_name:String,texture:Texture2D,size:Vector2,profile:VFXProfile3D,phase:float,billboard:bool)->MeshInstance3D:
	var q:=QuadMesh.new();q.size=size;var n:=MeshInstance3D.new();n.name=node_name;n.mesh=q;n.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;var m:=_material(CARD_SHADER,profile);m.set_shader_parameter("mask_tex",texture);m.set_shader_parameter("noise_tex",TEX_NOISE);m.set_shader_parameter("phase",phase);m.set_shader_parameter("billboard",1.0 if billboard else 0.0);n.material_override=m;add_child(n);return n

func _material(code:String,profile:VFXProfile3D)->ShaderMaterial:
	var m:=ShaderMaterial.new();var sh:=Shader.new();sh.code=code;m.shader=sh;m.set_shader_parameter("dark_color",profile.dark_color);m.set_shader_parameter("main_color",profile.main_color);m.set_shader_parameter("core_color",profile.core_color);m.set_shader_parameter("energy",profile.emission_energy);m.set_shader_parameter("opacity",vfx_alpha);_materials.append(m);return m

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
	var p:=VFXProfile3D.new();p.dark_color=Color(.025,.045,.055);p.main_color=Color(.12,.64,.58);p.core_color=Color(.76,1.0,.82);p.size=.9;p.duration=1.55;p.particle_count=10;p.emission_energy=3.2;return p
