extends Node
# Temporary diagnostic autoload. Prints engine-side counters to stdout, which
# lands in `adb logcat -s godot`, so the numbers can be collected without the
# editor's Monitors panel and without anyone reading a screen.
#
# Engine bookkeeping is used on purpose: on this Unisoc/Mali device the OS-level
# graphics accounting (dumpsys meminfo "Graphics:") is stuck at a constant and
# cannot be trusted, while Godot counts what it allocated itself.
#
# Remove this file and its autoload entry once the memory question is settled.

const SAMPLE_INTERVAL := 0.5
# A step this large between samples is an event (a unit spawning, a scene
# loading), not drift -- worth its own line so it can be found in the log.
const JUMP_MB := 24.0

var _accum := 0.0
var _last_video_mb := 0.0
var _last_static_mb := 0.0

func _ready() -> void:
	print("[PERFLOG] started interval=%.1fs" % SAMPLE_INTERVAL)

func _process(delta: float) -> void:
	_accum += delta
	if _accum < SAMPLE_INTERVAL:
		return
	_accum = 0.0
	var video_mb := _mb(Performance.RENDER_VIDEO_MEM_USED)
	var texture_mb := _mb(Performance.RENDER_TEXTURE_MEM_USED)
	var buffer_mb := _mb(Performance.RENDER_BUFFER_MEM_USED)
	var static_mb := _mb(Performance.MEMORY_STATIC)
	# tween= 是直接读 SceneTree 当前在处理的 Tween 数，不是从 obj-node-res 减出来的。
	# 之前只能靠减法推断「其它对象占 Δobj 的 38%」，最高的几次甚至比节点数还多
	# （877 vs 720），但那是推测。这一行把它变成读数。
	print("[PERFLOG] fps=%d proc=%.1fms phys=%.1fms video=%.1f tex=%.1f buf=%.1f static=%.1f obj=%d res=%d node=%d orphan=%d draw=%d tween=%d" % [
		Engine.get_frames_per_second(),
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		video_mb, texture_mb, buffer_mb, static_mb,
		int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		get_tree().get_processed_tweens().size(),
	])
	_print_skinning_census()
	if absf(video_mb - _last_video_mb) >= JUMP_MB:
		print("[PERFLOG] !! VIDEO JUMP %+.1f MB -> %.1f (tex=%.1f)" % [
			video_mb - _last_video_mb, video_mb, texture_mb])
	if absf(static_mb - _last_static_mb) >= JUMP_MB:
		print("[PERFLOG] !! STATIC JUMP %+.1f MB -> %.1f" % [
			static_mb - _last_static_mb, static_mb])
	_last_video_mb = video_mb
	_last_static_mb = static_mb

func _mb(monitor: int) -> float:
	return float(Performance.get_monitor(monitor)) / 1048576.0

# 上面那些都是引擎全局计数，看不出「浪费在哪」。这一行专门回答动作模型的两个问题：
#
#   play/AP      —— 正在播的 AnimationPlayer / 总数。每个单位挂 idle+attack+run 三个
#                    动作子模型，切换只改 visible、从不 stop()，所以切走的那两个会一直
#                    播下去。play 明显大于场上单位数 = 这个浪费是真的。
#   hidden_play  —— 正在播、但整棵子树没有一个可见网格的 AnimationPlayer。GPU 蒙皮省了，
#                    骨骼姿势的 CPU 计算一份不少。这个数就是白烧的量。
#   vis/hid vert —— 可见 / 隐藏的蒙皮网格顶点数。隐藏的那部分不进渲染，但常驻显存。
#
# 顶点数按 mesh 缓存，避免每次采样都去翻 surface。
var _vert_cache := {}

func _print_skinning_census() -> void:
	var root := get_tree().root
	if root == null:
		return
	var players := 0
	var playing := 0
	var hidden_playing := 0
	var skeletons := 0
	var bones := 0
	var vis_verts := 0
	var hid_verts := 0

	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for c in node.get_children():
			stack.append(c)
		if node is Skeleton3D:
			skeletons += 1
			bones += (node as Skeleton3D).get_bone_count()
		elif node is AnimationPlayer:
			players += 1
			var ap := node as AnimationPlayer
			if ap.is_playing():
				playing += 1
				if not _subtree_has_visible_mesh(ap.get_parent()):
					hidden_playing += 1
		elif node is MeshInstance3D:
			var mi := node as MeshInstance3D
			if mi.skeleton.is_empty():
				continue
			var v := _mesh_verts(mi.mesh)
			if mi.is_visible_in_tree():
				vis_verts += v
			else:
				hid_verts += v

	print("[PERFLOG] skin skel=%d bones=%d play=%d/%d hidden_play=%d vis_vert=%d hid_vert=%d" % [
		skeletons, bones, playing, players, hidden_playing, vis_verts, hid_verts])

func _subtree_has_visible_mesh(root: Node) -> bool:
	if root == null:
		return false
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D and (node as MeshInstance3D).is_visible_in_tree():
			return true
		for c in node.get_children():
			stack.append(c)
	return false

func _mesh_verts(mesh: Mesh) -> int:
	if mesh == null:
		return 0
	var key := mesh.get_instance_id()
	if _vert_cache.has(key):
		return _vert_cache[key]
	var total := 0
	var array_mesh := mesh as ArrayMesh
	if array_mesh != null:
		for i in array_mesh.get_surface_count():
			total += array_mesh.surface_get_array_len(i)
	_vert_cache[key] = total
	return total
