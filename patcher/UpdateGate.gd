extends Control
## Immutable launcher. Business singletons are inert nodes until packs are mounted.
## Export tooling supplies patcher/boot.json and switches autoloads to placeholders.

var _title: Label
var _detail: Label
var _amount: Label
var _progress: ProgressBar
var _retry: Button
var _request: HTTPRequest
var _busy := false
var _download_size := 0
var _boot: Dictionary = {}
var _directory := ""
var _download_started := 0
var _committed := false


func _ready() -> void:
	_build_ui()
	_run()


func _build_ui() -> void:
	var launcher_font := load("res://patcher/LauncherFont.otf") as Font
	if launcher_font != null:
		theme = Theme.new()
		theme.default_font = launcher_font
	var background := ColorRect.new()
	background.color = Color("101923")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var accent := ColorRect.new()
	accent.color = Color("b9985b")
	accent.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	accent.offset_bottom = 3
	add_child(accent)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var column := VBoxContainer.new()
	column.custom_minimum_size = Vector2(640, 0)
	column.add_theme_constant_override("separation", 22)
	center.add_child(column)
	var brand := Label.new()
	brand.text = "G L O R Y"
	brand.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	brand.add_theme_font_size_override("font_size", 58)
	brand.add_theme_color_override("font_color", Color("dec797"))
	column.add_child(brand)
	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", 25)
	column.add_child(_title)
	_detail = Label.new()
	_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail.custom_minimum_size.y = 52
	_detail.add_theme_color_override("font_color", Color("aab8c9"))
	column.add_child(_detail)
	_progress = ProgressBar.new()
	_progress.custom_minimum_size.y = 8
	_progress.show_percentage = false
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color("c7ab70")
	fill.set_corner_radius_all(4)
	var track := StyleBoxFlat.new()
	track.bg_color = Color("263546")
	track.set_corner_radius_all(4)
	_progress.add_theme_stylebox_override("fill", fill)
	_progress.add_theme_stylebox_override("background", track)
	column.add_child(_progress)
	_amount = Label.new()
	_amount.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_amount.add_theme_color_override("font_color", Color("8394a8"))
	column.add_child(_amount)
	_retry = Button.new()
	_retry.text = "重新连接"
	_retry.custom_minimum_size.y = 48
	_retry.visible = false
	_retry.pressed.connect(_run)
	column.add_child(_retry)
	_request = HTTPRequest.new()
	_request.accept_gzip = false
	_request.use_threads = true
	_request.timeout = 900
	add_child(_request)


func _process(_delta: float) -> void:
	if _download_size > 0:
		var received := _request.get_downloaded_bytes()
		_progress.value = 100.0 * float(received) / float(_download_size)
		var seconds := maxf(float(Time.get_ticks_msec() - _download_started) / 1000.0, 0.1)
		_amount.text = "%.1f / %.1f MB  ·  %.1f MB/s" % [received / 1000000.0,
			_download_size / 1000000.0, received / seconds / 1000000.0]


func _fail(message: String) -> void:
	_download_size = 0
	_busy = false
	_title.text = "更新尚未完成"
	_detail.text = message
	# Resource packs and initialized scripts cannot be safely unloaded in-process.
	_retry.visible = not _committed
	if _committed:
		_detail.text += " 请退出并重新启动游戏。"
	_amount.text = "完成更新后即可进入游戏"


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var value = JSON.parse_string(FileAccess.get_file_as_string(path))
	return value if value is Dictionary else {}


func _check(installed: int) -> Dictionary:
	_request.download_file = ""
	_request.body_size_limit = 2 * 1024 * 1024
	var url := str(_boot.backend_url).trim_suffix("/") + "/v1/patches/check"
	url += "?channel=%s&platform=%s&base_id=%s&installed_seq=%d" % [
		str(_boot.channel).uri_encode(), str(_boot.platform).uri_encode(),
		str(_boot.base_id).uri_encode(), installed]
	var error := _request.request(url)
	if error != OK:
		return {}
	var response: Array = await _request.request_completed
	if response[0] != HTTPRequest.RESULT_SUCCESS or response[1] != 200:
		return {}
	var value = JSON.parse_string(response[3].get_string_from_utf8())
	if not value is Dictionary or int(value.get("protocol", 0)) != 1:
		return {}
	if value.get("base_id") != _boot.base_id or value.get("platform") != _boot.platform:
		return {}
	if value.get("channel") != _boot.channel:
		return {}
	return value


func _run() -> void:
	if _busy or _committed:
		return
	_busy = true
	_retry.visible = false
	_title.text = "正在连接远征大厅"
	_detail.text = "检查游戏版本…"
	_amount.text = ""
	_progress.value = 0
	_boot = _read_json("res://patcher/boot.json")
	for key in ["backend_url", "channel", "platform", "base_id", "autoloads", "main_scene", "firebase_host"]:
		if not _boot.has(key):
			_fail("安装包缺少更新配置，请安装完整的新版本。")
			return
	if not str(_boot.backend_url).begins_with("https://"):
		_fail("更新服务地址无效。")
		return
	_directory = "user://patches/" + str(_boot.platform) + "/" + str(_boot.base_id)
	if DirAccess.make_dir_recursive_absolute(_directory) != OK:
		_fail("无法创建更新目录，请检查设备存储空间。")
		return
	var active := _read_json(_directory + "/active.json")
	var installed := int(active.get("seq", 0))
	if installed > 0:
		var digest := str(active.get("sha256", ""))
		if not _valid_digest(digest) or not _matches_file(_directory + "/" + digest + ".zip", digest):
			installed = 0
			active = {}
	var manifest: Dictionary = await _check(installed)
	if manifest.is_empty():
		_fail("暂时无法确认最新版本，请检查网络后重试。")
		return
	var action := str(manifest.get("action", ""))
	if action == "store_update":
		_fail("此版本需要更新完整安装包，请前往原下载渠道更新游戏。")
		return
	if action == "reset_to_base":
		active = {}
	elif action == "download":
		var artifact = manifest.get("artifact")
		if not artifact is Dictionary or not _valid_artifact(artifact):
			_fail("更新文件信息无效，请稍后重试。")
			return
		var digest: String = artifact.sha256
		var target := _directory + "/" + digest + ".zip"
		_title.text = "准备新的远征"
		_detail.text = "正在下载游戏更新，请保持网络连接。"
		if not _matches_file(target, digest):
			_request.body_size_limit = int(artifact.size)
			_request.download_file = target + ".part"
			_download_size = int(artifact.size)
			_download_started = Time.get_ticks_msec()
			if _request.request(str(artifact.url)) != OK:
				_fail("无法开始下载，请重试。")
				return
			var response: Array = await _request.request_completed
			_download_size = 0
			if response[0] != HTTPRequest.RESULT_SUCCESS or response[1] != 200:
				_fail("下载未完成，请检查网络和可用存储空间后重试。")
				return
			_detail.text = "下载完成，正在校验文件…"
			await get_tree().process_frame
			var downloaded := FileAccess.open(target + ".part", FileAccess.READ)
			if downloaded == null or downloaded.get_length() != int(artifact.size):
				_fail("更新文件大小不符，请重新下载。")
				return
			downloaded.close()
			if FileAccess.get_sha256(target + ".part") != digest:
				_fail("更新文件校验失败，请重新下载。")
				return
			if DirAccess.rename_absolute(target + ".part", target) != OK:
				_fail("无法保存更新，请检查设备存储空间。")
				return
		# Publication may have changed during download. Never boot a stale candidate.
		var candidate_seq := int(manifest.required_patch_seq)
		var latest: Dictionary = await _check(candidate_seq)
		if latest.is_empty() or latest.get("action") != "none" or int(latest.get("required_patch_seq", -1)) != candidate_seq:
			_fail("游戏版本刚刚更新，请重试以获取最新版本。")
			return
		manifest = latest
		active = {"seq": candidate_seq, "sha256": digest}
	elif action != "none":
		_fail("暂时无法确认更新状态，请稍后重试。")
		return
	var state_file := FileAccess.open(_directory + "/active.json.tmp", FileAccess.WRITE)
	if state_file == null:
		_fail("无法保存版本状态，请检查存储空间。")
		return
	state_file.store_string(JSON.stringify(active))
	state_file.close()
	if DirAccess.rename_absolute(_directory + "/active.json.tmp", _directory + "/active.json") != OK:
		_fail("无法保存版本状态，请重新启动游戏。")
		return
	# Finish all retryable filesystem/network work before changing resource state.
	_committed = true
	if not active.is_empty():
		if not ProjectSettings.load_resource_pack(_directory + "/" + str(active.sha256) + ".zip", true):
			_fail("无法加载更新文件。")
			return
	ProjectSettings.set_meta("glory_patch_snapshot", manifest)
	_progress.value = 100
	_title.text = "一切就绪"
	_detail.text = "正在进入远征大厅…"
	_amount.text = ""
	await get_tree().process_frame
	_start_business()


func _valid_digest(value: String) -> bool:
	if value.length() != 64:
		return false
	for character in value:
		if not character in "0123456789abcdef":
			return false
	return true


func _matches_file(path: String, digest: String) -> bool:
	return FileAccess.file_exists(path) and FileAccess.get_sha256(path) == digest


func _valid_artifact(artifact: Dictionary) -> bool:
	var digest := str(artifact.get("sha256", ""))
	var expected_url := "https://" + str(_boot.firebase_host) + "/patches/" + digest + "/" + str(_boot.platform) + ".zip"
	return (_valid_digest(digest) and artifact.get("url") == expected_url
		and artifact.get("base_id") == _boot.base_id and artifact.get("platform") == _boot.platform
		and int(artifact.get("size", 0)) > 0 and int(artifact.get("size", 0)) <= 2000000000)


func _start_business() -> void:
	var nodes: Array[Node] = []
	# Restore all parser metadata before compiling any mutually dependent service.
	for entry in _boot.autoloads:
		var node := get_tree().root.get_node_or_null(NodePath(str(entry.name)))
		if node == null or node.get_script() != null:
			_fail("启动服务状态异常，请重新启动游戏。")
			return
		nodes.append(node)
		ProjectSettings.set_setting("autoload/" + str(entry.name), "*" + str(entry.path))
	for node in nodes:
		get_tree().root.remove_child(node)
	for index in range(nodes.size()):
		var script = load(str(_boot.autoloads[index].path))
		if script == null or not script.can_instantiate():
			_fail("更新后的服务无法加载，请重新启动游戏。")
			return
		nodes[index].set_script(script)
		nodes[index].request_ready()
	for node in nodes:
		get_tree().root.add_child(node)
	var hotfix_agent = load("res://patcher/HotfixAgent.gd").new()
	hotfix_agent.name = "GloryHotfixAgent"
	get_tree().root.add_child(hotfix_agent)
	if get_tree().change_scene_to_file(str(_boot.main_scene)) != OK:
		_fail("无法进入游戏，请重新启动。")
