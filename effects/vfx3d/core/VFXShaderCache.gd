extends RefCounted
class_name VFXShaderCache

# 每个 VFX 模块以前都在 play_* 里 Shader.new() + shader.code = <常量字符串>。
# 代码文本相同，但每份 Shader 资源都是独立 RID，要各自解析源码并建一次管线，
# 手机上第一次施法必掉帧、之后每次施法还在重复建。
# 这里按源码文本缓存，同一段 shader 全局只存在一份 RID；
# 各实例仍然各自 new ShaderMaterial，所以 uniform 互不影响。
static var _shaders: Dictionary = {}

static func get_shader(code: String) -> Shader:
	var cached: Shader = _shaders.get(code)
	if cached != null:
		return cached
	var shader := Shader.new()
	shader.code = code
	_shaders[code] = shader
	return shader

# 便捷入口：直接拿到挂好共享 Shader 的新材质。
static func make_material(code: String) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = get_shader(code)
	return material

static func cached_shader_count() -> int:
	return _shaders.size()
