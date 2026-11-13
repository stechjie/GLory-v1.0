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
var _legacy_enabled := false

# Independent opt-in recorder. Normal play only checks the marker once per five
# seconds; it does not run this node's per-frame callback or walk the scene tree.
const RESOURCE_FLAG := "--resource-perf-log"
const RESOURCE_TRIGGER := "user://resource_perf.enabled"
const RESOURCE_LOG := "user://logs/resource_perf.jsonl"
const RESOURCE_INTERVAL := 1.0
const RESOURCE_CENSUS_INTERVAL := 5.0
const RESOURCE_MAX_BYTES := 8 * 1024 * 1024
const RESOURCE_MAX_FRAME_SAMPLES := 4096
const RESOURCE_MAX_MESH_CACHE := 512
const RESOURCE_THRESHOLDS_MS := [33.0, 50.0, 100.0]
const HIDDEN_ANIMATION_SCOPE := "heuristic: playing AnimationPlayer whose parent subtree has no tree-visible 3D mesh; may include visible 2D/UI animation; not proof of hidden or wasted work"

# Injectable paths/limit keep checks away from a player's recordings.
var resource_trigger_path := RESOURCE_TRIGGER
var resource_log_path := RESOURCE_LOG
var resource_max_bytes := RESOURCE_MAX_BYTES
var _resource_forced := false
var _resource_enabled := false
var _resource_poll_timer: Timer
var _resource_window_start_usec := 0
var _resource_last_frame_usec := 0
var _resource_last_census_usec := 0
var _resource_wall_ms := PackedFloat64Array()
var _resource_delta_ms := PackedFloat64Array()
var _resource_frame_count := 0
var _resource_wall_sum := 0.0
var _resource_delta_sum := 0.0
var _resource_wall_max := 0.0
var _resource_delta_max := 0.0
var _resource_wall_slow := [0, 0, 0]
var _resource_delta_slow := [0, 0, 0]
var _resource_mesh_cache := {}
var _resource_write_failed := false
var _resource_frame_collection_us := 0
var _resource_frame_collection_max_us := 0
var _resource_completed_tick_us := 0
var _resource_completed_tick_max_us := 0

# Full-tree skinning census is a diagnostic, not part of normal gameplay.
# Keep headless checks observable and allow device captures to opt in explicitly.
static func diagnostics_enabled(args: PackedStringArray, headless: bool) -> bool:
	if "--server" in args or "--dedicated-server" in args:
		return false
	return headless or "--perf-log" in args or "--device-baseline" in args

func _ready() -> void:
	var args := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	_configure_diagnostics(args, DisplayServer.get_name() == "headless")

func _configure_diagnostics(args: PackedStringArray, headless: bool) -> void:
	_legacy_enabled = diagnostics_enabled(args, headless)
	_resource_forced = RESOURCE_FLAG in args
	if "--server" in args or "--dedicated-server" in args:
		_legacy_enabled = false
		_resource_forced = false
		_set_resource_enabled(false)
		set_process(false)
		if is_instance_valid(_resource_poll_timer):
			_resource_poll_timer.stop()
		return
	if not is_instance_valid(_resource_poll_timer):
		_resource_poll_timer = Timer.new()
		_resource_poll_timer.name = "ResourcePerfPoll"
		_resource_poll_timer.wait_time = RESOURCE_CENSUS_INTERVAL
		_resource_poll_timer.timeout.connect(_poll_resource_switch)
		add_child(_resource_poll_timer)
	_resource_poll_timer.start()
	_poll_resource_switch()
	# 专服上这个采样一分钱价值都没有，代价却是实打实的：每 0.5 秒两行，一天约 34 万行
	# 灌进 journald，把 `server started protocol=N` 这类只出现一次的启动日志冲到几千行
	# 以外（实测查不到）。而 _print_skinning_census() 每次还要遍历整棵场景树找
	# Skeleton3D / MeshInstance3D —— headless 下一个都没有，纯白跑。
	#
	# 判定条件跟 NetworkService._should_boot_dedicated_server() 保持一致：**只认显式
	# 命令行参数**。不能用「裸 headless」来判——tools/ 下的采集工具都是 headless 跑的，
	# 而它们正是要看这些数的那批人。
	if _legacy_enabled:
		print("[PERFLOG] started interval=%.1fs" % SAMPLE_INTERVAL)

func _process(delta: float) -> void:
	if _resource_enabled:
		_resource_tick(delta)
	if not _legacy_enabled:
		return
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


func _poll_resource_switch() -> void:
	_set_resource_enabled(_resource_forced or _resource_marker_enabled())
	set_process(_legacy_enabled or _resource_enabled)


func _resource_marker_enabled() -> bool:
	if not FileAccess.file_exists(resource_trigger_path):
		return false
	var marker := FileAccess.open(resource_trigger_path, FileAccess.READ)
	if marker == null:
		return false
	var value := marker.get_as_text().strip_edges().to_lower()
	marker.close()
	# An empty marker remains compatible with existing device captures. Overwrite
	# it with "off" to stop recording when deleting app-container files is awkward.
	return value not in ["off", "false", "0"]


func _set_resource_enabled(enabled: bool) -> void:
	if enabled == _resource_enabled:
		return
	_resource_enabled = enabled
	_reset_resource_window(Time.get_ticks_usec())
	_resource_last_frame_usec = _resource_window_start_usec
	_resource_last_census_usec = _resource_window_start_usec
	_resource_mesh_cache.clear()
	_resource_write_failed = false
	_write_resource_record({"kind": "state", "enabled": enabled,
		"sample_interval_sec": RESOURCE_INTERVAL, "census_interval_sec": RESOURCE_CENSUS_INTERVAL,
		"wall_frame_scope": "monotonic callback interval including frame limiting, idle and interruptions; not CPU time",
		"geometry_scope": "configured instance geometry; tree visibility is not camera culling or actual GPU work",
		"particle_scope": "emitting node configured amount and amount_ratio; not live particles; one-shot tails may outlive emitting",
		"hidden_animation_scope": HIDDEN_ANIMATION_SCOPE,
		"canvas_scope": "visible CanvasItem nodes; custom draw commands and their particle-like elements cannot be counted uniformly"})


func _reset_resource_window(now_usec: int) -> void:
	_resource_window_start_usec = now_usec
	_resource_wall_ms.clear()
	_resource_delta_ms.clear()
	_resource_frame_count = 0
	_resource_wall_sum = 0.0
	_resource_delta_sum = 0.0
	_resource_wall_max = 0.0
	_resource_delta_max = 0.0
	_resource_wall_slow = [0, 0, 0]
	_resource_delta_slow = [0, 0, 0]
	_resource_frame_collection_us = 0
	_resource_frame_collection_max_us = 0
	_resource_completed_tick_us = 0
	_resource_completed_tick_max_us = 0


func _resource_tick(delta: float) -> void:
	var now := Time.get_ticks_usec()
	_record_resource_frame(float(now - _resource_last_frame_usec) / 1000.0, delta * 1000.0)
	_resource_last_frame_usec = now
	var collection_us := Time.get_ticks_usec() - now
	_resource_frame_collection_us += collection_us
	_resource_frame_collection_max_us = maxi(_resource_frame_collection_max_us, collection_us)
	if now - _resource_window_start_usec >= int(RESOURCE_INTERVAL * 1000000.0):
		var record := _resource_engine_sample()
		record["window_sec"] = float(now - _resource_window_start_usec) / 1000000.0
		record["wall_frame_ms"] = _resource_frame_distribution(true)
		record["engine_delta_ms"] = _resource_frame_distribution(false)
		record["recorder_overhead"] = {"frame_collection_us": _resource_frame_collection_us,
			"frame_collection_max_us": _resource_frame_collection_max_us,
			"completed_callback_us": _resource_completed_tick_us,
			"completed_callback_max_us": _resource_completed_tick_max_us,
			"scope": "collection excludes emission; completed callbacks include log IO and census; current callback cost appears in next window"}
		_write_resource_record(record)
		_reset_resource_window(now)
	if now - _resource_last_census_usec >= int(RESOURCE_CENSUS_INTERVAL * 1000000.0):
		_write_resource_record(_resource_census(get_tree().root))
		_resource_last_census_usec = Time.get_ticks_usec()
	var elapsed_us := Time.get_ticks_usec() - now
	_resource_completed_tick_us += elapsed_us
	_resource_completed_tick_max_us = maxi(_resource_completed_tick_max_us, elapsed_us)


func _record_resource_frame(wall_ms: float, delta_ms: float) -> void:
	_resource_frame_count += 1
	_resource_wall_sum += wall_ms
	_resource_delta_sum += delta_ms
	_resource_wall_max = maxf(_resource_wall_max, wall_ms)
	_resource_delta_max = maxf(_resource_delta_max, delta_ms)
	if _resource_wall_ms.size() < RESOURCE_MAX_FRAME_SAMPLES:
		_resource_wall_ms.append(wall_ms)
		_resource_delta_ms.append(delta_ms)
	for i in RESOURCE_THRESHOLDS_MS.size():
		if wall_ms > RESOURCE_THRESHOLDS_MS[i]:
			_resource_wall_slow[i] += 1
		if delta_ms > RESOURCE_THRESHOLDS_MS[i]:
			_resource_delta_slow[i] += 1


func _resource_frame_distribution(wall: bool) -> Dictionary:
	var samples := _resource_wall_ms.duplicate() if wall else _resource_delta_ms.duplicate()
	samples.sort()
	var slow: Array = _resource_wall_slow if wall else _resource_delta_slow
	return {"count": _resource_frame_count, "percentile_samples": samples.size(),
		"percentile_method": "nearest_rank_first_4096_per_window",
		"mean": (_resource_wall_sum if wall else _resource_delta_sum) / maxf(1.0, _resource_frame_count),
		"max": _resource_wall_max if wall else _resource_delta_max,
		"p50": _resource_percentile(samples, 0.5), "p95": _resource_percentile(samples, 0.95),
		"p99": _resource_percentile(samples, 0.99),
		"over_33_ms": slow[0], "over_50_ms": slow[1], "over_100_ms": slow[2]}


static func _resource_percentile(sorted: PackedFloat64Array, fraction: float) -> float:
	if sorted.is_empty():
		return 0.0
	return sorted[clampi(int(ceil(sorted.size() * fraction)) - 1, 0, sorted.size() - 1)]


func _resource_engine_sample() -> Dictionary:
	var sample := {"kind": "sample", "engine_fps": Engine.get_frames_per_second(),
		"fps_limit": Engine.max_fps,
		"process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"physics_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		"rendered_primitives": int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		"draw_calls": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"rendered_objects": int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		"video_mb": _mb(Performance.RENDER_VIDEO_MEM_USED),
		"texture_mb": _mb(Performance.RENDER_TEXTURE_MEM_USED),
		"buffer_mb": _mb(Performance.RENDER_BUFFER_MEM_USED),
		"static_mb": _mb(Performance.MEMORY_STATIC),
		"objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"resources": int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"orphans": int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		"tweens": get_tree().get_processed_tweens().size(),
		"network": _resource_network_sample(),
		"counter_scope": "engine rendering counters include passes and Canvas primitives; process/physics monitors are not a per-frame trace"}
	return _resource_apply_monitor_availability(sample, OS.is_debug_build())


static func _resource_apply_monitor_availability(sample: Dictionary, debug_build: bool) -> Dictionary:
	# Godot 4.7: Memory::get_mem_usage() and Performance::_get_orphan_node_count()
	# return a placeholder zero without DEBUG_ENABLED. Keep that separate from a
	# measured zero; object/resource/node counts and rendering monitors remain valid.
	var availability := {"debug_build": debug_build}
	for field in ["static_mb", "orphans"]:
		availability[field] = {"available": debug_build}
		if not debug_build:
			sample[field] = null
			availability[field]["reason"] = "requires_DEBUG_ENABLED; release engine returns a placeholder zero"
	sample["monitor_availability"] = availability
	return sample


func _resource_network_sample() -> Dictionary:
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if enet == null or enet.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED or enet.get_unique_id() == 1:
		return {"available": false, "reason": "no_connected_enet_client"}
	var peer := enet.get_peer(1)
	if peer == null:
		return {"available": false, "reason": "no_server_peer"}
	return {"available": true,
		"round_trip_time_ms": peer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME),
		"round_trip_time_variance_ms": peer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME_VARIANCE),
		"packet_loss_raw": peer.get_statistic(ENetPacketPeer.PEER_PACKET_LOSS),
		"packet_throttle_raw": peer.get_statistic(ENetPacketPeer.PEER_PACKET_THROTTLE),
		"scope": "ENet rolling transport statistics, not application heartbeat latency or an exact interval loss rate"}


func _resource_census(root: Node) -> Dictionary:
	var started := Time.get_ticks_usec()
	var result := {"kind": "census", "scanned_nodes": 0,
		"mesh_nodes": 0, "resident_mesh_instances": 0, "tree_visible_mesh_instances": 0,
		"resident_vertices_configured": 0, "tree_visible_vertices_configured": 0,
		"resident_triangles_configured": 0, "tree_visible_triangles_configured": 0,
		"resident_material_surfaces": 0, "tree_visible_material_surfaces": 0,
		"skeletons": 0, "bones": 0, "animation_players": 0, "playing_animations": 0,
		"hidden_playing_animations": 0, "canvas_items": 0, "tree_visible_canvas_items": 0,
		"hidden_animation_scope": HIDDEN_ANIMATION_SCOPE,
		"particles": {"gpu_3d": _empty_particle_census(), "cpu_3d": _empty_particle_census(),
			"gpu_2d": _empty_particle_census(), "cpu_2d": _empty_particle_census()}}
	if root == null:
		return result
	# Rebuild metadata at most once per mesh per census. Weak references let freed
	# resources disappear; the cache never keeps a model alive or grows unbounded.
	for key in _resource_mesh_cache.keys():
		if (_resource_mesh_cache[key]["weak"] as WeakRef).get_ref() == null:
			_resource_mesh_cache.erase(key)
	var visible_mesh_ancestors := {}
	var players: Array[AnimationPlayer] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		result.scanned_nodes += 1
		for child in node.get_children():
			stack.append(child)
		if node is CanvasItem:
			result.canvas_items += 1
			if (node as CanvasItem).is_visible_in_tree():
				result.tree_visible_canvas_items += 1
		if node is Skeleton3D:
			result.skeletons += 1
			result.bones += (node as Skeleton3D).get_bone_count()
		if node is AnimationPlayer:
			players.append(node as AnimationPlayer)
		if node is MeshInstance3D or node is MultiMeshInstance3D:
			var mesh: Mesh
			var resident_count := 1
			var visible_count := 1
			if node is MeshInstance3D:
				mesh = (node as MeshInstance3D).mesh
			else:
				var multi := (node as MultiMeshInstance3D).multimesh
				if multi != null:
					mesh = multi.mesh
					resident_count = multi.instance_count
					visible_count = multi.instance_count if multi.visible_instance_count < 0 else multi.visible_instance_count
			if mesh != null:
				var counts := _resource_mesh_counts(mesh)
				result.mesh_nodes += 1
				result.resident_mesh_instances += resident_count
				for field in ["vertices", "triangles", "material_surfaces"]:
					var suffix: String = field + ("_configured" if field != "material_surfaces" else "")
					result["resident_" + suffix] += int(counts[field]) * resident_count
				if (node as Node3D).is_visible_in_tree() and visible_count > 0:
					result.tree_visible_mesh_instances += visible_count
					for field in ["vertices", "triangles", "material_surfaces"]:
						var suffix: String = field + ("_configured" if field != "material_surfaces" else "")
						result["tree_visible_" + suffix] += int(counts[field]) * visible_count
					var ancestor: Node = node
					while ancestor != null:
						visible_mesh_ancestors[ancestor.get_instance_id()] = true
						if ancestor == root:
							break
						ancestor = ancestor.get_parent()
		var particle_kind := ""
		if node is GPUParticles3D:
			particle_kind = "gpu_3d"
		elif node is CPUParticles3D:
			particle_kind = "cpu_3d"
		elif node is GPUParticles2D:
			particle_kind = "gpu_2d"
		elif node is CPUParticles2D:
			particle_kind = "cpu_2d"
		if not particle_kind.is_empty():
			_add_particle_census(result.particles[particle_kind], node, particle_kind.begins_with("gpu"))
	for player in players:
		result.animation_players += 1
		if player.is_playing():
			result.playing_animations += 1
			if player.get_parent() == null or not visible_mesh_ancestors.has(player.get_parent().get_instance_id()):
				result.hidden_playing_animations += 1
	result["scan_ms"] = float(Time.get_ticks_usec() - started) / 1000.0
	result["geometry_scope"] = "configured source geometry per attached instance, before LOD/culling/passes; resident means scene-attached, not all ResourceCache meshes"
	result["canvas_scope"] = "tree visibility only; custom draw element/particle counts are not available uniformly"
	return result


func _resource_mesh_counts(mesh: Mesh) -> Dictionary:
	var key := mesh.get_instance_id()
	if _resource_mesh_cache.has(key):
		return _resource_mesh_cache[key]["counts"]
	var counts := {"vertices": 0, "triangles": 0, "material_surfaces": mesh.get_surface_count()}
	for surface in mesh.get_surface_count():
		var vertices := 0
		var indices := 0
		if mesh is ArrayMesh:
			vertices = (mesh as ArrayMesh).surface_get_array_len(surface)
			indices = (mesh as ArrayMesh).surface_get_array_index_len(surface)
		else:
			var arrays := mesh.surface_get_arrays(surface)
			if arrays.size() > Mesh.ARRAY_VERTEX and arrays[Mesh.ARRAY_VERTEX] != null:
				vertices = arrays[Mesh.ARRAY_VERTEX].size()
			if arrays.size() > Mesh.ARRAY_INDEX and arrays[Mesh.ARRAY_INDEX] != null:
				indices = arrays[Mesh.ARRAY_INDEX].size()
		counts.vertices += vertices
		var drawn := indices if indices > 0 else vertices
		# PrimitiveMesh exposes generated arrays but not ArrayMesh's primitive-type
		# accessor; built-in PrimitiveMesh surfaces use triangles.
		var primitive_type := (mesh as ArrayMesh).surface_get_primitive_type(surface) if mesh is ArrayMesh else Mesh.PRIMITIVE_TRIANGLES
		match primitive_type:
			Mesh.PRIMITIVE_TRIANGLES:
				counts.triangles += drawn / 3
			Mesh.PRIMITIVE_TRIANGLE_STRIP:
				counts.triangles += maxi(0, drawn - 2)
	if _resource_mesh_cache.size() >= RESOURCE_MAX_MESH_CACHE:
		_resource_mesh_cache.clear()
	_resource_mesh_cache[key] = {"weak": weakref(mesh), "counts": counts}
	var invalidation := _resource_mesh_changed.bind(key)
	if not mesh.changed.is_connected(invalidation):
		mesh.changed.connect(invalidation)
	return counts


func _resource_mesh_changed(instance_id: int) -> void:
	_resource_mesh_cache.erase(instance_id)


static func _empty_particle_census() -> Dictionary:
	return {"nodes": 0, "resident_amount_capacity": 0, "emitting_nodes": 0,
		"emitting_amount_capacity": 0, "emitting_ratio_scaled_capacity": 0.0,
		"tree_visible_emitting_amount_capacity": 0,
		"amount_ratio_min": 1.0, "amount_ratio_max": 0.0}


static func _add_particle_census(counts: Dictionary, node: Node, gpu: bool) -> void:
	var amount := int(node.get("amount"))
	var ratio := float(node.get("amount_ratio")) if gpu else 1.0
	counts.nodes += 1
	counts.resident_amount_capacity += amount
	counts.amount_ratio_min = minf(counts.amount_ratio_min, ratio)
	counts.amount_ratio_max = maxf(counts.amount_ratio_max, ratio)
	if bool(node.get("emitting")):
		counts.emitting_nodes += 1
		counts.emitting_amount_capacity += amount
		counts.emitting_ratio_scaled_capacity += amount * ratio
		var tree_visible := (node as CanvasItem).is_visible_in_tree() if node is CanvasItem else (node as Node3D).is_visible_in_tree()
		if tree_visible:
			counts.tree_visible_emitting_amount_capacity += amount


func _write_resource_record(payload: Dictionary) -> bool:
	var record := payload.duplicate()
	record["schema_version"] = 1
	record["utc"] = Time.get_datetime_string_from_system(true)
	record["ticks_ms"] = Time.get_ticks_msec()
	var line := JSON.stringify(record) + "\n"
	var line_bytes := line.to_utf8_buffer().size()
	if line_bytes > resource_max_bytes:
		return false
	var absolute := ProjectSettings.globalize_path(resource_log_path)
	if DirAccess.make_dir_recursive_absolute(absolute.get_base_dir()) != OK:
		return _resource_log_failure()
	var file := FileAccess.open(absolute, FileAccess.READ_WRITE)
	if file != null and file.get_length() + line_bytes > resource_max_bytes:
		file.close()
		file = null
		if FileAccess.file_exists(absolute + ".1"):
			if DirAccess.remove_absolute(absolute + ".1") != OK:
				return _resource_log_failure()
		if DirAccess.rename_absolute(absolute, absolute + ".1") != OK:
			return _resource_log_failure()
	if file == null:
		file = FileAccess.open(absolute, FileAccess.WRITE)
	if file == null:
		return _resource_log_failure()
	file.seek_end()
	file.store_string(line)
	var success := file.get_error() == OK
	file.close()
	return success if success else _resource_log_failure()


func _resource_log_failure() -> bool:
	if not _resource_write_failed:
		_resource_write_failed = true
		push_warning("Resource performance recording could not write its bounded log")
	return false
