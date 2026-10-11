extends Node
## Same-host control plane. Desired snapshots belong to the account service.
const Runtime = preload("res://patcher/HotfixRuntime.gd")
const Context = preload("res://scripts/multiplayer/BattleHotfixContext.gd")
var desired_path := ""
var status_path := ""
var instance_id := "main"
var _runtime: Node
var _deployment := ""
var _epoch := ""
var _revision := -1
var _error := ""


func accepts_card(card: Dictionary) -> bool:
	if OS.get_environment("GLORY_BATTLE_PATCH_ENFORCE").to_lower() != "true":
		return true
	# Read the compact atomic file at admission time, not the periodic hotfix cache.
	var file := FileAccess.open(desired_path + ".admission", FileAccess.READ)
	if file == null or file.get_length() > 32768:
		return false
	var rules = JSON.parse_string(file.get_as_text())
	if not rules is Dictionary:
		return false
	if (rules.get("protocol") != 1 or rules.get("instance_id") != instance_id
		or rules.get("battle_deployment_id") != _deployment
		or absf(Time.get_unix_time_from_system() - float(rules.get("generated_at", 0))) > 15):
		return false
	var patch = card.get("patch", {})
	if not patch is Dictionary or patch.get("channel") != rules.get("channel"):
		return false
	var sequence := int(patch.get("seq", -1))
	if sequence < 0 or sequence != int(rules.get("seq", -2)):
		return false
	if sequence == 0:
		return true
	var bases = rules.get("bases", {})
	return (bases is Dictionary and bases.has(str(patch.get("platform", "")))
		and bases[str(patch.platform)] == patch.get("base_id"))


func _ready() -> void:
	desired_path = OS.get_environment("GLORY_BATTLE_HOTFIX_DESIRED") if desired_path.is_empty() else desired_path
	status_path = OS.get_environment("GLORY_BATTLE_HOTFIX_STATUS") if status_path.is_empty() else status_path
	var configured_id := OS.get_environment("GLORY_BATTLE_HOTFIX_INSTANCE")
	if not configured_id.is_empty():
		instance_id = configured_id
	_runtime = Runtime.new()
	_runtime.context_script = Context
	add_child(_runtime)
	_deployment = _deployment_identity()
	var timer := Timer.new()
	timer.wait_time = 2
	timer.autostart = true
	timer.timeout.connect(tick)
	add_child(timer)
	tick()


func _deployment_identity() -> String:
	# Hash deployed code/data, including direct file deployments without a new
	# build_info.txt. Timestamps and process restarts alone must not expire fixes.
	var paths: Array[String] = []
	for folder in ["res://scripts", "res://data", "res://patcher", "res://ui"]:
		_identity_files(folder, paths)
	paths.append_array(["res://build_info.txt", "res://build_info.json", "res://project.godot"])
	paths.sort()
	var identity := str(Engine.get_version_info().get("string", ""))
	for path in paths:
		if FileAccess.file_exists(path):
			identity += "\n" + path + ":" + FileAccess.get_sha256(path)
	return identity.sha256_text()


func _identity_files(folder: String, paths: Array[String]) -> void:
	var directory := DirAccess.open(folder)
	if directory == null:
		return
	for file in directory.get_files():
		if file.get_extension().to_lower() in ["gd", "gdc", "json", "tscn", "tres", "csv"]:
			paths.append(folder.path_join(file))
	for child in directory.get_directories():
		if not child.begins_with("."):
			_identity_files(folder.path_join(child), paths)


func tick() -> void:
	if desired_path.is_empty() or status_path.is_empty():
		return
	var snapshot: Dictionary = {}
	if FileAccess.file_exists(desired_path):
		var file := FileAccess.open(desired_path, FileAccess.READ)
		if file != null and file.get_length() <= 2 * 1024 * 1024:
			var parsed = JSON.parse_string(file.get_as_text())
			if parsed is Dictionary:
				snapshot = parsed
	var fresh: bool = (snapshot.get("protocol") == 1 and snapshot.get("instance_id") == instance_id
		and snapshot.get("battle_deployment_id") == _deployment
		and absf(Time.get_unix_time_from_system() - float(snapshot.get("generated_at", 0))) <= 15)
	if not fresh:
		_runtime.clear()
		_revision = -1
		_error = "等待当前部署的有效快照"
	else:
		var epoch := str(snapshot.get("deployment_id", "")) + ":" + str(snapshot.get("hotfix_epoch", 0))
		if epoch != _epoch:
			_runtime.clear()
			_epoch = epoch
			_revision = -1
		var revision := int(snapshot.get("revision", -1))
		if revision > _revision:
			var items = snapshot.get("hotfixes", [])
			if items is Array and _runtime.replace(items):
				_revision = revision
				_error = ""
			else:
				_error = "Hotfix 应用失败，保留同一生效周期内的旧集合"
	_write_status()


func _write_status() -> void:
	var file := FileAccess.open(status_path + ".tmp", FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({"protocol": 1, "instance_id": instance_id,
		"deployment_id": _deployment, "applied_revision": _revision,
		"heartbeat": Time.get_unix_time_from_system(), "error": _error}))
	file.close()
	DirAccess.rename_absolute(status_path + ".tmp", status_path)
