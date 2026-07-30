extends Node

# 量外部 VFX 参考场景（Binbun / Starter）常驻的代价。
#
# 背景：这 14 个场景现在是在**施法那一帧同步 load()** 的
# （VFXBinbunReference3D.gd:22 / VFXV2ExternalReference3D.gd:25），
# 实测 Boss 大圈那一下主线程冻结 5.9 秒。而且播完引用归零就被卸载，下次再卡一遍。
#
# 打算改成开战前预加载 + 静态持有。改之前先确认常驻内存代价。
#
# 口径：递归收集每个场景的资源依赖，累加导入产物（.ctex 就是上传显存的那份数据）。
# 不含网格/材质等小结构，所以是偏保守的下界，但贴图占大头。
#
# 运行：Godot --headless --path . tools/external_vfx_cost.tscn

const BINBUN := preload("res://effects/vfx3d/vfxv2/VFXBinbunReference3D.gd")
const STARTER := preload("res://effects/vfx3d/vfxv2/VFXV2ExternalReference3D.gd")

var _seen: Dictionary = {}

func _ready() -> void:
	var all: Dictionary = {}
	for k in BINBUN.SCENES:
		all["binbun/" + str(k)] = str(BINBUN.SCENES[k])
	for k in STARTER.SCENES:
		all["starter/" + str(k)] = str(STARTER.SCENES[k])

	print("[EXT] === 外部 VFX 场景常驻代价 ===")
	print("[EXT] %-28s %10s %8s" % ["场景", "贴图数据", "依赖数"])
	var grand := 0
	var shared: Dictionary = {}
	for name in all:
		var path: String = all[name]
		if not ResourceLoader.exists(path):
			print("[EXT] %-28s %10s" % [name, "缺失"])
			continue
		_seen.clear()
		var deps: Dictionary = {}
		_walk(path, deps)
		var bytes := 0
		for d in deps:
			bytes += _imported_size(d)
			shared[d] = true
		grand += bytes
		print("[EXT] %-28s %8.1f MB %8d" % [name, bytes / 1048576.0, deps.size()])

	# 多个场景共用同一张贴图时，上面的逐场景累加会重复计算。去重后才是真实常驻。
	var unique := 0
	for d in shared:
		unique += _imported_size(d)
	print("")
	print("[EXT] 逐场景累加     : %.1f MB（含重复）" % (grand / 1048576.0))
	print("[EXT] 去重后实际常驻 : %.1f MB  /  %d 个唯一资源" % [unique / 1048576.0, shared.size()])
	get_tree().quit()

func _walk(path: String, out: Dictionary, depth: int = 0) -> void:
	if depth > 10 or _seen.has(path):
		return
	_seen[path] = true
	for raw in ResourceLoader.get_dependencies(path):
		var parts := str(raw).split("::")
		var target := str(parts[parts.size() - 1])
		if not target.begins_with("res://"):
			continue
		var ext := target.get_extension().to_lower()
		if ext == "png" or ext == "jpg" or ext == "jpeg" or ext == "exr":
			out[target] = true
		else:
			_walk(target, out, depth + 1)

func _imported_size(res_path: String) -> int:
	# .import 里记着导入产物的位置；.ctex 才是真正进显存的那份。
	var imp := res_path + ".import"
	if not FileAccess.file_exists(imp):
		return 0
	var text := FileAccess.get_file_as_string(imp)
	var re := RegEx.create_from_string("res://\\.godot/imported/[^\"]+\\.ctex")
	var m := re.search(text)
	if m == null:
		return 0
	var f := FileAccess.open(m.get_string(), FileAccess.READ)
	if f == null:
		return 0
	var n := f.get_length()
	f.close()
	return n
