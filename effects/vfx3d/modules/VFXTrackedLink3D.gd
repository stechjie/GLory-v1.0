extends VFXBlockRoot
class_name VFXTrackedLink3D
const SHADER_CACHE := preload("res://effects/vfx3d/core/VFXShaderCache.gd")

const TEX_DOT:=preload("res://assets/vfx_textures/soft_dot.png")
const TEX_NOISE:=preload("res://assets/vfx_textures/noise_tile.png")

const LINK_SHADER:="""
shader_type spatial;render_mode unshaded,cull_disabled,depth_draw_never,blend_add;
uniform sampler2D noise_tex:filter_linear_mipmap,repeat_enable;
uniform vec4 dark_color:source_color;uniform vec4 main_color:source_color;uniform vec4 core_color:source_color;
uniform float life=0.0;uniform float opacity=1.0;uniform float phase=0.0;uniform float layer=0.0;uniform float energy=3.0;
void fragment(){float across=abs(UV.y*2.0-1.0);float n=texture(noise_tex,vec2(UV.x*2.8-TIME*.8+phase,UV.y*1.7)).r;float torn=1.0-smoothstep(.52+n*.16,.92,across);float gaps=smoothstep(.12,.42,sin(UV.x*41.0+phase+n*4.0));float hot=1.0-smoothstep(.04,.24,across);float fade=smoothstep(0.0,.10,life)*(1.0-smoothstep(.78,1.0,life));vec3 c=mix(dark_color.rgb,main_color.rgb,torn);c=mix(c,core_color.rgb,hot*(1.0-layer*.48));ALBEDO=c;EMISSION=c*energy*(.55+hot*2.1);ALPHA=torn*mix(.72,.30,layer)*mix(.72,1.0,gaps)*fade*opacity;}
"""

const PULSE_SHADER:="""
shader_type spatial;render_mode unshaded,cull_disabled,depth_draw_never,blend_add;
uniform sampler2D dot_tex:filter_linear_mipmap,repeat_disable;uniform vec4 main_color:source_color;uniform vec4 core_color:source_color;uniform float life=0.0;uniform float opacity=1.0;uniform float energy=3.0;
void vertex(){MODELVIEW_MATRIX=VIEW_MATRIX*mat4(INV_VIEW_MATRIX[0],INV_VIEW_MATRIX[1],INV_VIEW_MATRIX[2],MODEL_MATRIX[3]);}
void fragment(){float a=texture(dot_tex,UV).a;float f=sin(clamp(life,0.0,1.0)*3.14159);vec3 c=mix(main_color.rgb,core_color.rgb,a);ALBEDO=vec3(0.0);EMISSION=c*energy*a*f;ALPHA=a*f*opacity;}
"""

var _origin_ref:WeakRef
var _target_ref:WeakRef
var _origin_fallback:=Vector3.ZERO
var _target_fallback:=Vector3.ZERO
var _ribbons:Array[MeshInstance3D]=[]
var _materials:Array[ShaderMaterial]=[]
# 复用的几何缓冲。以前 _update_ribbons() 每次调用都为 3 层各 new 一个 ArrayMesh
# 和 3 个 PackedArray —— 18 Hz 更新 = 每秒 54 个新 Mesh 资源 + 162 个新数组，
# 一条持续链接就能把资源计数搅得很浑。现在整条链接只建一次，之后原地重写。
const RIBBON_SEGMENTS:=18
var _ribbon_meshes:Array[ArrayMesh]=[]
var _buf_verts:=PackedVector3Array()
var _buf_uvs:=PackedVector2Array()
var _buf_indices:=PackedInt32Array()
var _buf_arrays:Array=[]
var _profile:VFXProfile3D
var _elapsed:=0.0
var _mesh_accum:=0.0
var _persistent:=false
var _released:=false

func play_profile(profile:VFXProfile3D,context:Dictionary)->void:
	play_link(context.get("origin",Vector3(-1.0,.8,0.0)),context.get("target",Vector3(1.0,.8,0.0)),profile,context.get("origin_node"),context.get("target_node"),bool(context.get("persistent",false)))

func play_link(origin:Vector3,target:Vector3,profile:VFXProfile3D=null,origin_node:Variant=null,target_node:Variant=null,persistent:bool=false)->void:
	begin();_persistent=persistent;_released=false;_profile=profile if profile!=null else _fallback_profile();_origin_fallback=origin;_target_fallback=target;_origin_ref=null;_target_ref=null
	if is_instance_valid(origin_node) and origin_node is Node3D:_origin_ref=weakref(origin_node)
	if is_instance_valid(target_node) and target_node is Node3D:_target_ref=weakref(target_node)
	_update_endpoint_fallbacks()
	_init_ribbon_buffers()
	for i in range(3):
		var n:=MeshInstance3D.new();n.name="TrackedLinkLayer_%d"%i;n.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;n.material_override=_make_material(i);add_child(n)
		var m:=ArrayMesh.new();n.mesh=m;_ribbon_meshes.append(m);_ribbons.append(n)
	_update_ribbons()
	for i in range(4):_spawn_pulse(float(i)*_profile.duration*.16)
	var tw:=track_tween(create_tween())
	if _persistent:
		tw.set_loops()
		tw.tween_method(func(t:float):for m in _materials:if is_instance_valid(m):m.set_shader_parameter("life",t),.22,.64,_profile.duration*.72).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	else:
		tw.tween_method(func(t:float):for m in _materials:if is_instance_valid(m):m.set_shader_parameter("life",t),0.0,1.0,_profile.duration)
		await get_tree().create_timer(_profile.duration+.08).timeout;finish()

func release_link(fade_duration:float=0.20)->void:
	if _finished or _released:return
	_released=true
	var tw:=track_tween(create_tween())
	tw.tween_method(func(v:float):for m in _materials:if is_instance_valid(m):m.set_shader_parameter("opacity",v),vfx_alpha,0.0,fade_duration)
	tw.tween_callback(finish)

func _process(delta:float)->void:
	if _finished or _profile==null:return
	_elapsed+=delta;_mesh_accum+=delta
	if _mesh_accum>=.055:_mesh_accum=0.0;_update_endpoint_fallbacks();_update_ribbons()

func _endpoint(ref:WeakRef,fallback:Vector3)->Vector3:
	if ref==null:return fallback
	var node:Variant=ref.get_ref()
	if is_instance_valid(node) and node is Node3D:return to_local((node as Node3D).global_position)
	return fallback

func _update_endpoint_fallbacks()->void:
	_origin_fallback=_endpoint(_origin_ref,_origin_fallback)
	_target_fallback=_endpoint(_target_ref,_target_fallback)

func _curve_point(t:float,layer:int)->Vector3:
	var a:=_origin_fallback;var b:=_target_fallback;var d:=b-a;var side:=Vector3(-d.y,d.x,0.0).normalized();var arch:=Vector3.UP*sin(t*PI)*_profile.size*(.28+.06*float(layer));var wave:=side*sin(t*PI*(3.0+float(layer))+_elapsed*(7.0+float(layer)*1.7)+float(layer)*2.1)*_profile.size*(.055+.018*float(layer));return a.lerp(b,t)+arch+wave

# 索引拓扑固定不变（段数是常量），整条链接只算一次。
func _init_ribbon_buffers()->void:
	var vcount:=(RIBBON_SEGMENTS+1)*2
	_buf_verts.resize(vcount)
	_buf_uvs.resize(vcount)
	_buf_indices.resize(RIBBON_SEGMENTS*6)
	for i in range(RIBBON_SEGMENTS):
		var k:=i*2;var o:=i*6
		_buf_indices[o]=k;_buf_indices[o+1]=k+1;_buf_indices[o+2]=k+3
		_buf_indices[o+3]=k;_buf_indices[o+4]=k+3;_buf_indices[o+5]=k+2
	# UV 只依赖段号，也是固定的。
	for i in range(RIBBON_SEGMENTS+1):
		var t:=float(i)/float(RIBBON_SEGMENTS);var k:=i*2
		_buf_uvs[k]=Vector2(t,0.0);_buf_uvs[k+1]=Vector2(t,1.0)
	_buf_arrays.resize(Mesh.ARRAY_MAX)
	_buf_arrays[Mesh.ARRAY_TEX_UV]=_buf_uvs
	_buf_arrays[Mesh.ARRAY_INDEX]=_buf_indices

func _update_ribbons()->void:
	for layer in range(_ribbons.size()):
		var width:=_profile.size*(.032+.028*float(2-layer))
		# 只重算顶点：UV 和索引在 _init_ribbon_buffers 里一次算好，之后不再动。
		for i in range(RIBBON_SEGMENTS+1):
			var t:=float(i)/float(RIBBON_SEGMENTS)
			var p:=_curve_point(t,layer)
			var prev:=_curve_point(maxf(0.0,t-.02),layer)
			var next:=_curve_point(minf(1.0,t+.02),layer)
			var tangent:=(next-prev).normalized()
			var side:=Vector3(-tangent.y,tangent.x,0.0).normalized()
			var taper:=sin(t*PI)*.76+.24
			var k:=i*2
			_buf_verts[k]=p-side*width*taper
			_buf_verts[k+1]=p+side*width*taper
		_buf_arrays[Mesh.ARRAY_VERTEX]=_buf_verts
		# 复用同一个 ArrayMesh：clear_surfaces + 重加面，比每次 new 一个 Mesh 资源便宜得多
		# （后者每次都产生新 RID、新资源对象，并要等 GC 回收旧的）。
		var mesh:ArrayMesh=_ribbon_meshes[layer]
		mesh.clear_surfaces()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,_buf_arrays)

func _spawn_pulse(delay:float)->void:
	var q:=QuadMesh.new();q.size=Vector2(_profile.size*.24,_profile.size*.24);var n:=MeshInstance3D.new();n.name="LinkTransferPulse";n.mesh=q;n.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m:=ShaderMaterial.new();m.shader = SHADER_CACHE.get_shader(PULSE_SHADER);m.set_shader_parameter("dot_tex",TEX_DOT);m.set_shader_parameter("main_color",_profile.main_color);m.set_shader_parameter("core_color",_profile.core_color);m.set_shader_parameter("energy",_profile.emission_energy);m.set_shader_parameter("opacity",vfx_alpha);n.material_override=m;add_child(n);_materials.append(m);n.visible=false
	var travel:=_profile.duration*.46;var tw:=track_tween(create_tween());tw.tween_interval(delay);tw.tween_callback(func():if is_instance_valid(n):n.visible=true);tw.tween_method(func(t:float):if is_instance_valid(n):n.position=_curve_point(t,0);m.set_shader_parameter("life",t),0.0,1.0,travel).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT);tw.tween_callback(n.queue_free)

func _make_material(layer:int)->ShaderMaterial:
	var m:=ShaderMaterial.new();m.shader = SHADER_CACHE.get_shader(LINK_SHADER);m.set_shader_parameter("noise_tex",TEX_NOISE);m.set_shader_parameter("dark_color",_profile.dark_color);m.set_shader_parameter("main_color",_profile.main_color);m.set_shader_parameter("core_color",_profile.core_color);m.set_shader_parameter("phase",float(layer)*2.73);m.set_shader_parameter("layer",float(layer)/2.0);m.set_shader_parameter("energy",_profile.emission_energy);m.set_shader_parameter("opacity",vfx_alpha);_materials.append(m);return m

func set_vfx_alpha(value:float)->void:
	super.set_vfx_alpha(value)
	for m in _materials:if is_instance_valid(m):m.set_shader_parameter("opacity",vfx_alpha)

func _fallback_profile()->VFXProfile3D:
	var p:=VFXProfile3D.new();p.dark_color=Color(.035,.025,.11);p.main_color=Color(.32,.28,.88);p.core_color=Color(.72,.90,1.0);p.size=.9;p.duration=1.65;p.particle_count=8;p.emission_energy=3.2;return p
