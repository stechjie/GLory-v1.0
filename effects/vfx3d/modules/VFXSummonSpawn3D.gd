extends VFXBlockRoot
class_name VFXSummonSpawn3D
const SHADER_CACHE := preload("res://effects/vfx3d/core/VFXShaderCache.gd")

signal reveal_requested

# NOTE: everything under assets/vfx_textures/ is a pure-white alpha mask with no
# colour information, which is why mask-only sigils read as washed-out blobs.
# The ground sigil uses real painted art instead and gets re-tinted per team.
const TEX_SIGIL:=preload("res://assets/ui/buttons/ready_magic_circle.png")
const TEX_WISP:=preload("res://assets/vfx_textures/smoke_puff.png")
const TEX_DOT:=preload("res://assets/vfx_textures/soft_dot.png")
const TEX_FLARE:=preload("res://assets/vfx_textures/flare_star.png")
const TEX_NOISE:=preload("res://assets/vfx_textures/noise_tile.png")

# Stage ratios of profile.duration. Override per profile through profile.parameters
# so timing can be tuned in the .tres without touching this script.
#   converge_at: motes finish flying inward, sigil fully lit
#   reveal_at:   column and smoke peak, reveal_requested fires (show the model here)
#   settle_at:   everything starts fading out
const DEF_CONVERGE_AT:=0.25
const DEF_REVEAL_AT:=0.5
const DEF_SETTLE_AT:=0.7

# Painted sigil art on the ground. Luminance is remapped onto the profile colours
# so the same artwork serves both teams while keeping every rune detail.
const SIGIL_SHADER:="""
shader_type spatial;render_mode unshaded,cull_disabled,depth_draw_never,blend_add;
uniform sampler2D sigil_tex:filter_linear_mipmap,repeat_disable;
uniform vec4 dark_color:source_color;uniform vec4 main_color:source_color;uniform vec4 core_color:source_color;
uniform float life=0.0;uniform float opacity=1.0;uniform float energy=3.0;uniform float charge=0.0;uniform float ring_bias=0.0;
void fragment(){
	vec4 t=texture(sigil_tex,UV);
	float lum=dot(t.rgb,vec3(.299,.587,.114));
	vec3 c=mix(dark_color.rgb,main_color.rgb,smoothstep(.04,.52,lum));
	c=mix(c,core_color.rgb,smoothstep(.52,.94,lum));
	float r=length(UV-vec2(.5))*2.0;
	// Charge-up sweeps a bright band from the rim toward the centre.
	float sweep=1.0-smoothstep(.0,.42,abs(r-(1.25-charge*1.25)));
	float radial=mix(1.0,smoothstep(.15,.95,r),ring_bias);
	float fade_in=smoothstep(.0,.30,life);
	float fade_out=1.0-smoothstep(.72,1.0,life);
	float a=t.a*radial*fade_in*fade_out*opacity;
	ALBEDO=c;
	EMISSION=c*energy*(.35+lum*1.15+sweep*1.30);
	ALPHA=clamp(a*(.55+lum*.75+sweep*.55),0.0,1.0);
}
"""

# Volumetric light column. Height comes from a varying rather than UV.y because
# CylinderMesh UVs run top-down, and the body must be fully transparent well below
# the mesh rim -- otherwise the cone silhouette reads as a solid plastic cup.
const COLUMN_SHADER:="""
shader_type spatial;render_mode unshaded,cull_disabled,depth_draw_never,blend_add;
uniform sampler2D noise_tex:filter_linear_mipmap,repeat_enable;
uniform vec4 main_color:source_color;uniform vec4 core_color:source_color;
uniform float life=0.0;uniform float opacity=1.0;uniform float energy=3.0;uniform float scroll=0.9;
uniform float col_height=1.0;uniform float top_fade=0.58;uniform float max_alpha=0.46;
varying float v_up;
void vertex(){v_up=clamp(VERTEX.y/max(col_height,0.001)+.5,0.0,1.0);}
void fragment(){
	float n=texture(noise_tex,vec2(UV.x*2.4,v_up*1.3-TIME*scroll)).r;
	float n2=texture(noise_tex,vec2(UV.x*1.3+.37,v_up*.8-TIME*scroll*.55)).r;
	float streak=mix(n,n2,.5);
	float tall=1.0-smoothstep(.03,top_fade,v_up);
	float foot=smoothstep(.0,.04,v_up);
	float rim=pow(1.0-abs(dot(normalize(NORMAL),normalize(VIEW))),1.7);
	float body=tall*foot*(.26+rim*1.20)*(.48+streak*.92);
	float grow=smoothstep(.0,.34,life);
	float fall=1.0-smoothstep(.55,1.0,life);
	vec3 c=mix(main_color.rgb,core_color.rgb,clamp(rim*.60+tall*.42,0.0,1.0));
	ALBEDO=c;
	EMISSION=c*energy*(.50+rim*1.30);
	ALPHA=clamp(body*grow*fall*opacity,0.0,max_alpha);
}
"""

# White alpha masks are fine for smoke and sparks, where colour comes from the profile.
const CARD_SHADER:="""
shader_type spatial;render_mode unshaded,cull_disabled,depth_draw_never,blend_add;
uniform sampler2D mask_tex:filter_linear_mipmap,repeat_disable;uniform sampler2D noise_tex:filter_linear_mipmap,repeat_enable;
uniform vec4 dark_color:source_color;uniform vec4 main_color:source_color;uniform vec4 core_color:source_color;
uniform float life=0.0;uniform float opacity=1.0;uniform float phase=0.0;uniform float energy=3.0;uniform float billboard=1.0;uniform float tint_mix=0.35;
void vertex(){if(billboard>.5){MODELVIEW_MATRIX=VIEW_MATRIX*mat4(INV_VIEW_MATRIX[0],INV_VIEW_MATRIX[1],INV_VIEW_MATRIX[2],MODEL_MATRIX[3]);}}
void fragment(){
	float m=texture(mask_tex,UV).a;
	float n=texture(noise_tex,UV*1.7+vec2(phase,TIME*.09)).r;
	float grain=mix(.62,1.0,n);
	float fade_in=smoothstep(.0,.30,life);
	float fade_out=1.0-smoothstep(.72,1.0,life);
	vec3 c=mix(dark_color.rgb,main_color.rgb,.78);
	c=mix(c,core_color.rgb,tint_mix);
	ALBEDO=c;
	EMISSION=c*energy*.55;
	ALPHA=clamp(m*grain*fade_in*fade_out*opacity,0.0,1.0);
}
"""

var _materials:Array[ShaderMaterial]=[]

func play_profile(profile:VFXProfile3D,context:Dictionary)->void:
	play_summon(context.get("target",Vector3.ZERO),profile)

func play_summon(at:Vector3,profile:VFXProfile3D=null)->void:
	begin();position=at+Vector3(0.0,.02,0.0)
	var active:=profile if profile!=null else _fallback_profile();var d:=active.duration;var s:=active.size;var params:=active.parameters
	var t_converge:=d*clampf(float(params.get("converge_at",DEF_CONVERGE_AT)),.05,.80)
	var t_reveal:=d*clampf(float(params.get("reveal_at",DEF_REVEAL_AT)),.15,.90)
	var t_settle:=d*clampf(float(params.get("settle_at",DEF_SETTLE_AT)),.50,.98)
	var t_end:=d*.97
	_spawn_sigils(active,t_converge,t_reveal,t_settle,t_end)
	_spawn_column(active,t_reveal,t_end)
	_spawn_converging_motes(active,t_reveal)
	_spawn_ground_smoke(active,t_reveal,t_settle,t_end)
	await get_tree().create_timer(t_reveal).timeout
	if _finished:return
	reveal_requested.emit()
	_spawn_reveal_flash(active);_spawn_shockwave(active);_spawn_outward_push(active)
	await get_tree().create_timer(d-t_reveal).timeout;finish()

# Two counter-rotating copies of the painted sigil: a wide outer rune band and a
# smaller inner core. Both spin up into the reveal, then wind down.
func _spawn_sigils(profile:VFXProfile3D,t_converge:float,t_reveal:float,t_settle:float,t_end:float)->void:
	var s:=profile.size
	var outer:=_sigil("SummonSigilOuter",Vector2(s*1.95,s*1.95),profile,.85)
	outer.scale=Vector3.ONE*.55
	var inner:=_sigil("SummonSigilInner",Vector2(s*1.06,s*1.06),profile,0.0)
	inner.position.y=.008;inner.scale=Vector3.ONE*.40
	var tw_o:=track_tween(create_tween());tw_o.tween_property(outer,"scale",Vector3.ONE,t_converge*.95).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	var tw_i:=track_tween(create_tween());tw_i.tween_interval(t_converge*.18);tw_i.tween_property(inner,"scale",Vector3.ONE,t_converge*.85).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_spin(outer,168.0,74.0,t_reveal,t_end)
	_spin(inner,-330.0,-140.0,t_reveal,t_end)
	for n in [outer,inner]:
		_charge(n,t_reveal)
		_life_staged(n,t_converge*.85,t_settle,t_end,0.0)

# The cone only draws the column's outer haze; a billboarded core glow supplies the
# solid centre. A second nested cone would just read as a cup inside a cup.
func _spawn_column(profile:VFXProfile3D,t_reveal:float,t_end:float)->void:
	var s:=profile.size
	var height:=s*2.40
	var mesh:=CylinderMesh.new()
	mesh.bottom_radius=s*.52;mesh.top_radius=s*.82;mesh.height=height
	mesh.radial_segments=28;mesh.rings=1;mesh.cap_top=false;mesh.cap_bottom=false
	var n:=MeshInstance3D.new();n.name="SummonLightColumn";n.mesh=mesh
	n.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m:=_material(COLUMN_SHADER,profile)
	m.set_shader_parameter("noise_tex",TEX_NOISE);m.set_shader_parameter("scroll",.95)
	m.set_shader_parameter("col_height",height);m.set_shader_parameter("top_fade",.58);m.set_shader_parameter("max_alpha",.60)
	n.material_override=m;add_child(n)
	n.position.y=height*.5
	n.scale=Vector3(.26,.14,.26)
	var tw:=track_tween(create_tween())
	tw.tween_property(n,"scale",Vector3(1.04,1.0,1.04),t_reveal*.70).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	tw.tween_property(n,"scale",Vector3(1.30,.82,1.30),maxf(t_end-t_reveal*.70,.05)).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_life_peak(n,0.0,t_reveal,t_end)
	# This is what actually hides the model. It has to stay at full brightness for the
	# whole rise, not just the reveal instant, or the model is plainly visible popping in.
	var hold_until:=t_reveal+profile.duration*float(profile.parameters.get("reveal_hold",.22))
	var glow:=_card("SummonCoreGlow",TEX_DOT,Vector2(s*1.90,s*2.30),profile,4.2,true,.80)
	glow.position.y=s*.74;glow.scale=Vector3.ONE*.24
	var tw_g:=track_tween(create_tween())
	tw_g.tween_property(glow,"scale",Vector3.ONE*1.05,t_reveal*.80).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	tw_g.tween_property(glow,"scale",Vector3.ONE*1.20,maxf(hold_until-t_reveal*.80,.05)).set_trans(Tween.TRANS_SINE)
	tw_g.tween_property(glow,"scale",Vector3.ONE*1.55,maxf(t_end-hold_until,.05)).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_life_staged(glow,t_reveal*.86,hold_until,t_end*.94,0.0)

# Small bright sparks streaming inward during the charge-up.
func _spawn_converging_motes(profile:VFXProfile3D,t_reveal:float)->void:
	for i in range(clampi(profile.particle_count,10,22)):
		var n:=_card("SummonConvergeMote_%d"%i,TEX_DOT,Vector2(profile.size*.085,profile.size*.085),profile,float(i)*.77,true,.75)
		var a:=float(i)*2.399+.4;var r:=profile.size*(1.25+.32*float(i%3))
		n.position=Vector3(cos(a)*r,profile.size*(.05+.12*float(i%2)),sin(a)*r*.68)
		var delay:=t_reveal*(.03+.05*float(i%12));var travel:=t_reveal*(.52+.10*float(i%2))
		var tw:=track_tween(create_tween());tw.tween_interval(delay);tw.set_parallel(true)
		tw.tween_property(n,"position",Vector3(cos(a)*profile.size*.09,profile.size*.04,sin(a)*profile.size*.06),travel).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tw.tween_property(n,"scale",Vector3.ONE*.30,travel).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		_life(n,travel,delay)

# Many small, faint, overlapping puffs read as smoke. A few big opaque cards do not.
func _spawn_ground_smoke(profile:VFXProfile3D,t_reveal:float,t_settle:float,t_end:float)->void:
	var count:=clampi(profile.particle_count*2,18,34)
	for i in range(count):
		var scale_v:=profile.size*(.30+.16*float(i%4))
		var n:=_card("SummonSmoke_%d"%i,TEX_WISP,Vector2(scale_v,scale_v*.86),profile,float(i)*1.13,true,.18)
		var a:=float(i)*2.399;var r:=profile.size*(.18+.30*float(i%5)*.25)
		n.position=Vector3(cos(a)*r,profile.size*(.02+.05*float(i%3)),sin(a)*r*.66)
		var delay:=t_reveal*(.06+.028*float(i%14));var rise:=maxf(t_settle-delay,.15)
		var tw:=track_tween(create_tween());tw.tween_interval(delay);tw.set_parallel(true)
		tw.tween_property(n,"position",Vector3(cos(a)*profile.size*(.55+.30*float(i%3)),profile.size*(.30+.42*float(i%4)*.25),sin(a)*profile.size*(.40+.22*float(i%3))),rise).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.tween_property(n,"scale",Vector3.ONE*(1.55+.35*float(i%3)),rise).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		_life_staged(n,t_reveal,t_settle,t_end,delay)

func _spawn_reveal_flash(profile:VFXProfile3D)->void:
	var n:=_card("SummonRevealFlash",TEX_FLARE,Vector2(profile.size*3.1,profile.size*3.1),profile,8.1,true,.88)
	n.position.y=profile.size*.70;n.scale=Vector3.ONE*.18
	var pop:=profile.duration*.08;var tw:=track_tween(create_tween())
	tw.tween_property(n,"scale",Vector3.ONE*1.25,pop).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	tw.tween_property(n,"scale",Vector3.ONE*.35,pop*2.1).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_life(n,pop*3.1,0.0)

func _spawn_shockwave(profile:VFXProfile3D)->void:
	var wave:=VFXShockwave3D.new();wave.name="SummonBurstShockwave";add_child(wave)
	var p:=VFXProfile3D.new();p.dark_color=profile.dark_color;p.main_color=profile.main_color;p.core_color=profile.core_color
	p.size=profile.size*2.8;p.duration=maxf(profile.duration*.30,.34);p.curve_name="explosive_out";p.emission_energy=profile.emission_energy
	p.parameters={"secondary_delay":.22,"thickness":.055,"distortion":.06,"dissolve":.18}
	wave.play_shockwave(Vector3.ZERO,p)

func _spawn_outward_push(profile:VFXProfile3D)->void:
	var dur:=profile.duration*.24
	for i in range(12):
		var a:=float(i)*.524+.3
		var n:=_card("SummonBurstMote_%d"%i,TEX_DOT,Vector2(profile.size*.10,profile.size*.10),profile,float(i)*1.9,true,.80)
		n.position=Vector3(cos(a)*profile.size*.14,profile.size*.09,sin(a)*profile.size*.10)
		var tw:=track_tween(create_tween());tw.set_parallel(true)
		tw.tween_property(n,"position",Vector3(cos(a)*profile.size*(1.25+.22*float(i%3)),profile.size*(.20+.20*float(i%2)),sin(a)*profile.size*(.85+.16*float(i%2))),dur).set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)
		tw.tween_property(n,"scale",Vector3.ONE*.35,dur).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		_life(n,dur,0.0)
	for i in range(8):
		var a:=float(i)*.785+.9
		var n:=_card("SummonBurstPuff_%d"%i,TEX_WISP,Vector2(profile.size*.52,profile.size*.42),profile,float(i)*3.1,true,.22)
		n.position=Vector3(cos(a)*profile.size*.20,profile.size*.06,sin(a)*profile.size*.14)
		var tw:=track_tween(create_tween());tw.set_parallel(true)
		tw.tween_property(n,"position",Vector3(cos(a)*profile.size*1.45,profile.size*.14,sin(a)*profile.size*.95),dur*1.6).set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)
		tw.tween_property(n,"scale",Vector3.ONE*1.9,dur*1.6).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		_life(n,dur*1.6,0.0)

func _sigil(node_name:String,size:Vector2,profile:VFXProfile3D,ring_bias:float)->MeshInstance3D:
	var q:=QuadMesh.new();q.size=size
	var n:=MeshInstance3D.new();n.name=node_name;n.mesh=q;n.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m:=_material(SIGIL_SHADER,profile);m.set_shader_parameter("sigil_tex",TEX_SIGIL);m.set_shader_parameter("ring_bias",ring_bias)
	n.material_override=m;n.rotation_degrees.x=-90.0;add_child(n);return n

func _card(node_name:String,texture:Texture2D,size:Vector2,profile:VFXProfile3D,phase:float,billboard:bool,tint_mix:float)->MeshInstance3D:
	var q:=QuadMesh.new();q.size=size
	var n:=MeshInstance3D.new();n.name=node_name;n.mesh=q;n.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m:=_material(CARD_SHADER,profile);m.set_shader_parameter("mask_tex",texture);m.set_shader_parameter("noise_tex",TEX_NOISE);m.set_shader_parameter("phase",phase);m.set_shader_parameter("billboard",1.0 if billboard else 0.0);m.set_shader_parameter("tint_mix",tint_mix)
	n.material_override=m;add_child(n);return n

func _material(code:String,profile:VFXProfile3D)->ShaderMaterial:
	var m:=ShaderMaterial.new();m.shader = SHADER_CACHE.get_shader(code)
	m.set_shader_parameter("dark_color",profile.dark_color);m.set_shader_parameter("main_color",profile.main_color);m.set_shader_parameter("core_color",profile.core_color)
	m.set_shader_parameter("energy",profile.emission_energy);m.set_shader_parameter("opacity",vfx_alpha)
	_materials.append(m);return m

func _spin(node:MeshInstance3D,accel_deg:float,decel_deg:float,t_reveal:float,t_end:float)->void:
	var setter:=func(a:float):if is_instance_valid(node):node.rotation_degrees.z=a
	var tw:=track_tween(create_tween())
	tw.tween_method(setter,0.0,accel_deg,maxf(t_reveal,.01)).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_method(setter,accel_deg,accel_deg+decel_deg,maxf(t_end-t_reveal,.01)).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

# Drives the rim-to-centre light sweep that peaks exactly on the reveal beat.
func _charge(node:MeshInstance3D,t_reveal:float)->void:
	var m:=node.material_override as ShaderMaterial
	var setter:=func(t:float):if is_instance_valid(m):m.set_shader_parameter("charge",t)
	var tw:=track_tween(create_tween())
	tw.tween_method(setter,0.0,1.0,maxf(t_reveal,.01)).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)

func _life(node:MeshInstance3D,duration:float,delay:float)->void:
	var m:=node.material_override as ShaderMaterial
	var tw:=track_tween(create_tween())
	if delay>0.0:
		tw.tween_interval(delay)
	tw.tween_method(func(t:float):if is_instance_valid(m):m.set_shader_parameter("life",t),0.0,1.0,duration)

# Fully lit by t_in, held until t_settle, gone by t_end.
func _life_staged(node:MeshInstance3D,t_in:float,t_settle:float,t_end:float,delay:float)->void:
	var m:=node.material_override as ShaderMaterial
	var setter:=func(t:float):if is_instance_valid(m):m.set_shader_parameter("life",t)
	var tw:=track_tween(create_tween())
	if delay>0.0:
		tw.tween_interval(delay)
	tw.tween_method(setter,0.0,.66,maxf(t_in-delay,.01)).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_method(setter,.66,.71,maxf(t_settle-t_in,.01))
	tw.tween_method(setter,.71,1.0,maxf(t_end-t_settle,.01)).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)

# Places the shader's brightest moment (life 0.5) exactly on t_peak.
func _life_peak(node:MeshInstance3D,delay:float,t_peak:float,t_end:float)->void:
	var m:=node.material_override as ShaderMaterial
	var setter:=func(t:float):if is_instance_valid(m):m.set_shader_parameter("life",t)
	var tw:=track_tween(create_tween())
	if delay>0.0:
		tw.tween_interval(delay)
	tw.tween_method(setter,0.0,.5,maxf(t_peak-delay,.01))
	tw.tween_method(setter,.5,1.0,maxf(t_end-t_peak,.01))

func set_vfx_alpha(value:float)->void:
	super.set_vfx_alpha(value)
	for m in _materials:if is_instance_valid(m):m.set_shader_parameter("opacity",vfx_alpha)

func _fallback_profile()->VFXProfile3D:
	var p:=VFXProfile3D.new();p.dark_color=Color(.09,.014,.01);p.main_color=Color(1.0,.26,.10);p.core_color=Color(1.0,.86,.55)
	p.size=1.25;p.duration=2.0;p.particle_count=14;p.emission_energy=3.6
	p.parameters={"converge_at":DEF_CONVERGE_AT,"reveal_at":DEF_REVEAL_AT,"settle_at":DEF_SETTLE_AT}
	return p
