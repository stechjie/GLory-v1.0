extends VFXBlockRoot
class_name VFXMotherExecute3D

const BOOK_TEXTURE:=preload("res://assets/vfx/skills/undead_mother/undead_mother_execution_book.png")
const PATH_RIBBON:=preload("res://effects/vfx3d/modules/VFXPathRibbon3D.gd")
const VORTEX:=preload("res://effects/vfx3d/modules/VFXVortexField3D.gd")
const IMPACT:=preload("res://effects/vfx3d/modules/VFXImpactFlash3D.gd")

const BOOK_SHADER:="""
shader_type spatial;
render_mode unshaded,cull_disabled,depth_draw_never,blend_mix;
uniform sampler2D book_texture:source_color;
uniform vec4 shadow_tint:source_color=vec4(0.10,0.02,0.18,1.0);
uniform vec4 energy_tint:source_color=vec4(0.72,0.22,0.95,1.0);
uniform float reveal=0.0;
uniform float pulse=0.0;
uniform float opacity=1.0;
float hash(vec2 p){return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453);}
void fragment(){
	vec4 tex=texture(book_texture,UV);
	float edge=smoothstep(0.02,0.34,tex.a);
	float noise=hash(floor(UV*18.0));
	float mask=smoothstep(reveal-0.16,reveal+0.08,UV.y+noise*0.08);
	float hot=pow(max(tex.r,max(tex.g,tex.b)),5.0);
	vec3 body=mix(tex.rgb,shadow_tint.rgb,0.12);
	vec3 color=mix(body,energy_tint.rgb,hot*(0.30+0.32*pulse));
	ALBEDO=color;
	EMISSION=color*(0.45+hot*(2.2+1.6*pulse));
	ALPHA=edge*mask*opacity;
}
"""

var _book_material:ShaderMaterial

func play_profile(profile:VFXProfile3D,context:Dictionary)->void:
	play_execute(context.get("origin",Vector3(-0.6,1.4,0.0)),context.get("target",Vector3(0.8,0.25,0.0)),profile)

func play_execute(book_at:Vector3,victim_at:Vector3,profile:VFXProfile3D)->void:
	begin()
	var book:=_make_book(profile)
	book.position=book_at+Vector3(0.0,0.06,0.08)
	book.scale=Vector3.ONE*0.06
	add_child(book)
	var appear:=track_tween(create_tween())
	appear.set_parallel(true)
	# The book is a deliberate gameplay emblem: about half the Mother model's
	# height, held above the HeadAnchor long enough to read in the distant view.
	appear.tween_property(book,"scale",Vector3.ONE*0.56,profile.duration*0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	appear.tween_property(_book_material,"shader_parameter/reveal",-0.08,profile.duration*0.16).from(1.10).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	appear.tween_property(_book_material,"shader_parameter/pulse",1.0,profile.duration*0.18).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	await get_tree().create_timer(profile.duration*0.16).timeout
	if _finished:return
	_spawn_soul_streams(victim_at+Vector3(0.0,0.38,0.03),book.position,profile)
	var vortex_profile:=profile.duplicate_runtime();vortex_profile.size*=0.72;vortex_profile.duration=profile.duration*0.55;vortex_profile.particle_count=10
	var vortex:=VORTEX.new();vortex.name="VictimSoulCollapse";add_child(vortex);vortex.play_profile(vortex_profile,{"target":victim_at})
	await get_tree().create_timer(profile.duration*0.34).timeout
	if _finished:return
	var flash:=IMPACT.new();flash.name="DevourSnap";add_child(flash);flash.play_flash(victim_at,profile.core_color,profile.size*1.10,profile.duration*0.16)
	var close:=track_tween(create_tween());close.set_parallel(true)
	close.tween_property(book,"scale",Vector3(0.42,0.12,0.42),profile.duration*0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	close.tween_property(_book_material,"shader_parameter/opacity",0.0,profile.duration*0.26).set_delay(profile.duration*0.08)
	close.tween_property(_book_material,"shader_parameter/pulse",0.0,profile.duration*0.18)
	await get_tree().create_timer(profile.duration*0.48).timeout
	finish()

func _make_book(profile:VFXProfile3D)->MeshInstance3D:
	var quad:=QuadMesh.new();quad.size=Vector2(profile.size*1.34,profile.size*1.34)
	var node:=MeshInstance3D.new();node.name="MotherExecutionBook";node.mesh=quad;node.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_book_material=ShaderMaterial.new();var shader:=Shader.new();shader.code=BOOK_SHADER;_book_material.shader=shader
	_book_material.set_shader_parameter("book_texture",BOOK_TEXTURE)
	_book_material.set_shader_parameter("shadow_tint",profile.dark_color)
	_book_material.set_shader_parameter("energy_tint",profile.main_color)
	_book_material.set_shader_parameter("reveal",1.1);_book_material.set_shader_parameter("pulse",0.0);_book_material.set_shader_parameter("opacity",vfx_alpha)
	node.material_override=_book_material
	return node

func _spawn_soul_streams(from:Vector3,to:Vector3,profile:VFXProfile3D)->void:
	for i in range(3):
		var side:float=float(i-1)*0.16
		var points:=PackedVector3Array()
		for step in range(10):
			var ratio:=float(step)/9.0
			var base:=from.lerp(to,ratio)
			var envelope:=sin(ratio*PI)
			var wave:=sin(ratio*PI*2.4+float(i)*1.7)*(.09+.025*float(i))*envelope
			points.append(base+Vector3(side*envelope+wave,.16*envelope+cos(ratio*PI*2.0+float(i))*.035*envelope,.025*float(i)))
		var p:=profile.duplicate_runtime();p.duration=profile.duration*(.46+.05*float(i));p.size=1.0;p.parameters=p.parameters.duplicate();p.parameters["width"]=.105+.018*float(i%2);p.parameters["spark_count"]=0;p.parameters["reveal_ratio"]=.15;p.parameters["hold_ratio"]=.05;p.parameters["curve_bias"]=.42
		var ribbon:=PATH_RIBBON.new();ribbon.name="SoulStream_%d"%i;add_child(ribbon);ribbon.play_path(points,Vector3.FORWARD,p)

func set_vfx_alpha(value:float)->void:
	super.set_vfx_alpha(value)
	if _book_material!=null:_book_material.set_shader_parameter("opacity",vfx_alpha)
