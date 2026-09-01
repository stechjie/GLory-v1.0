extends RefCounted

# 回放摘要：规范化 JSON、SHA-256、首差异定位。
#
# 为什么要有这个文件：这三件事原本是 scripts/qa/battle_presentation_baseline.gd 的私有方法，
# 而 tools/determinism_check_node.gd 用的是 32 位 String.hash()。两套实现意味着
# 两个工具算出来的"同一份回放"根本没有可比性 —— 而跨平台确定性比对的全部意义，
# 就是两边用**同一套**规范化和哈希。所以抽成一处，两边共用。
#
# 用法：const ReplayDigest := preload("res://scripts/qa/ReplayDigest.gd")
# 不用 class_name：新增的全局类要靠编辑器导入才进 global_script_class_cache，
# 直接 --headless 跑场景时可能解析不到（详见 docs/CHECKS.md）。
#
# 本文件的实现是从 battle_presentation_baseline.gd 逐字搬过来的。
# Director D0-D6 的四个冻结哈希依赖它，任何行为改动都会让那些哈希漂移，
# 所以改这里必须重跑 baseline 验证四个哈希一字不变。


# 把 Variant 转成 JSON 能表达的形式。Vector/Color/Packed* 展开成数组，
# Resource 取 resource_path —— 否则 JSON.stringify 会得到不稳定的对象表示。
static func json_safe(value: Variant) -> Variant:
	match typeof(value):
		TYPE_DICTIONARY:
			var dict_output: Dictionary = {}
			for key in (value as Dictionary).keys():
				dict_output[str(key)] = json_safe((value as Dictionary)[key])
			return dict_output
		TYPE_ARRAY:
			var array_output: Array = []
			for item in value as Array:
				array_output.append(json_safe(item))
			return array_output
		TYPE_STRING_NAME, TYPE_NODE_PATH:
			return str(value)
		TYPE_VECTOR2, TYPE_VECTOR2I:
			return [value.x, value.y]
		TYPE_VECTOR3, TYPE_VECTOR3I:
			return [value.x, value.y, value.z]
		TYPE_VECTOR4, TYPE_VECTOR4I:
			return [value.x, value.y, value.z, value.w]
		TYPE_COLOR:
			return [value.r, value.g, value.b, value.a]
		TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY, TYPE_PACKED_VECTOR4_ARRAY:
			var packed_output: Array = []
			for item in value:
				packed_output.append(json_safe(item))
			return packed_output
		TYPE_OBJECT:
			if value is Resource:
				return (value as Resource).resource_path
			return str(value)
		_:
			return value


# 规范化 JSON：sort_keys=true 保证键顺序稳定，full_precision=true 保证浮点不丢位。
# 这两个参数是哈希可比性的前提，改任何一个都会让所有历史哈希失效。
static func canonical_json(value: Variant) -> String:
	return JSON.stringify(json_safe(value), "", true, true)


# 失败返回空串，由调用方决定怎么记（baseline 记 failure，determinism_check 记 fail）。
static func sha256_text(value: String) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	context.update(value.to_utf8_buffer())
	return context.finish().hex_encode()


static func sha256_variant(value: Variant) -> String:
	return sha256_text(canonical_json(value))


static func sha256_file(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		file.close()
		return ""
	while file.get_position() < file.get_length():
		context.update(file.get_buffer(mini(1024 * 1024, file.get_length() - file.get_position())))
	file.close()
	return context.finish().hex_encode()


# 返回第一个不同之处的路径，如 $.frames[3].units[2].hp(12 != 9)；完全相同返回空串。
#
# 这是 README「D3 验收」的硬要求：跨平台差异必须给出首个不同的 tick、事件和字段，
# 只输出"总哈希不一致"不算通过 —— 那种报告没法用来定位问题。
static func first_difference(a: Variant, b: Variant, path: String = "$") -> String:
	if typeof(a) != typeof(b):
		return "%s(type %d != %d)" % [path, typeof(a), typeof(b)]
	if a is Dictionary:
		var da := a as Dictionary
		var db := b as Dictionary
		var keys: Array = da.keys()
		keys.sort_custom(_key_less)
		for key in keys:
			if not db.has(key):
				return "%s.%s(missing in repeat)" % [path, str(key)]
			var nested := first_difference(da[key], db[key], "%s.%s" % [path, str(key)])
			if not nested.is_empty():
				return nested
		for key in db.keys():
			if not da.has(key):
				return "%s.%s(extra in repeat)" % [path, str(key)]
		return ""
	if a is Array:
		var aa := a as Array
		var ab := b as Array
		if aa.size() != ab.size():
			return "%s(size %d != %d)" % [path, aa.size(), ab.size()]
		for index in aa.size():
			var nested := first_difference(aa[index], ab[index], "%s[%d]" % [path, index])
			if not nested.is_empty():
				return nested
		return ""
	return "" if a == b else "%s(%s != %s)" % [path, str(a), str(b)]


static func _key_less(a: Variant, b: Variant) -> bool:
	return str(a) < str(b)
