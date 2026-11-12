extends RefCounted

# 摆放界面草地的「风吹光影」（11.12）。shader 见 shaders/prep_sun_dapple.gdshader。
# 只给默认青草地皮肤用：别的皮肤（樱花、夜荧光……）的底图没有那种黄色光斑，套上去只会乱闪。

const SHADER := preload("res://shaders/prep_sun_dapple.gdshader")

static var _noise: NoiseTexture2D


# 挂上 / 摘掉。皮肤晚到（reapply_prep_skin）时会再调一次。
static func apply(rect: CanvasItem, enabled: bool) -> void:
	if rect == null or not is_instance_valid(rect):
		return
	if not enabled:
		rect.material = null
		return
	if rect.material is ShaderMaterial and (rect.material as ShaderMaterial).shader == SHADER:
		return
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter("noise_tex", _noise_texture())
	rect.material = mat


static func _noise_texture() -> NoiseTexture2D:
	if _noise != null:
		return _noise
	var fn := FastNoiseLite.new()
	fn.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	fn.frequency = 0.012
	fn.fractal_octaves = 3
	fn.seed = 1112
	_noise = NoiseTexture2D.new()
	_noise.noise = fn
	_noise.width = 256
	_noise.height = 256
	_noise.seamless = true
	_noise.normalize = true
	return _noise
