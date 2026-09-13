extends RefCounted

# Bounded background I/O for a single screen. Keep strong references until the
# caller has constructed its nodes; otherwise load() in _ready would read again.
# Runtime model wrappers name their FBX actions in script constants, so merely
# loading their PackedScene does not load the resources that _ready will need.
const MAX_IN_FLIGHT := 2

var resources: Dictionary = {}
var failed_paths: Array[String] = []
var requested_paths: Array[String] = []
var _queue: Array[String] = []
var _pending: Array[String] = []
var _seen: Dictionary = {}
var _cancelled := false

func load_paths(tree: SceneTree, paths: Array, progress: Callable = Callable()) -> bool:
	_append_paths(paths)
	while not _queue.is_empty() or not _pending.is_empty():
		# One new request and one completed resource per frame. A completed texture
		# can still require rendering-server work, so don't harvest an entire batch.
		if not _queue.is_empty() and _pending.size() < MAX_IN_FLIGHT:
			var path: String = _queue.pop_front()
			if not ResourceLoader.exists(path):
				failed_paths.append(path)
			elif ResourceLoader.load_threaded_request(path) != OK:
				failed_paths.append(path)
			else:
				requested_paths.append(path)
				_pending.append(path)
		for path in _pending.duplicate():
			var status := ResourceLoader.load_threaded_get_status(path)
			if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				continue
			_pending.erase(path)
			if status != ResourceLoader.THREAD_LOAD_LOADED:
				failed_paths.append(path)
				break
			# Never call get while a request is in progress: that blocks the UI.
			var resource := ResourceLoader.load_threaded_get(path)
			if resource == null:
				failed_paths.append(path)
			else:
				resources[path] = resource
				_append_runtime_dependencies(resource)
			break
		if progress.is_valid():
			progress.call(resources.size(), _seen.size())
		await tree.process_frame
	return not _cancelled and failed_paths.is_empty()

# In-flight jobs are drained without waiting on the UI thread. Stop requesting
# new work after cancellation; the caller can immediately show another screen.
func cancel() -> void:
	_cancelled = true
	_queue.clear()

func _append_paths(paths: Array) -> void:
	if _cancelled:
		return
	for raw_path in paths:
		var path := str(raw_path)
		if path.is_empty() or _seen.has(path):
			continue
		_seen[path] = true
		_queue.append(path)

func _append_runtime_dependencies(resource: Resource) -> void:
	if not resource is PackedScene:
		return
	var state := (resource as PackedScene).get_state()
	for node_index in state.get_node_count():
		for property_index in state.get_node_property_count(node_index):
			if state.get_node_property_name(node_index, property_index) != &"script":
				continue
			var script := state.get_node_property_value(node_index, property_index) as Script
			while script != null:
				var constants := script.get_script_constant_map()
				var actions: Variant = constants.get("ACTION_SCENES", {})
				if actions is Dictionary:
					_append_paths(actions.values())
				var material: String = str(constants.get("BODY_MATERIAL_PATH", ""))
				if not material.is_empty():
					_append_paths([material])
				script = script.get_base_script()
