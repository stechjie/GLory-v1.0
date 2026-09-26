extends Control

# One-shot native-component probe, selected only by DeviceHarness's local file.
# Credentials stay in user storage and are never printed or copied to reports.
# Capture requires pressing Talk; no automatic microphone activation.
const CONFIG := "user://voice_probe_config.json"
const REPORT := "user://voice_probe_status.json"
var bridge: Object
var status_label: Label
var action_label: Label
var elapsed := 0.0
var previous := ""
var observations: Array = []

func _ready() -> void:
	VoiceService.set_process(false)
	VoiceService.set_mode(VoiceService.Mode.OFF)
	NetworkService.set_process(false)
	var background := ColorRect.new()
	background.color = Color("172033")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 32)
	add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	margin.add_child(column)
	var title := Label.new()
	title.text = "iPhone 语音真机检查"
	title.add_theme_font_size_override("font_size", 28)
	column.add_child(title)
	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(status_label)
	action_label = Label.new()
	action_label.text = "点击开麦才会申请权限并使用麦克风。诊断不保存录音。"
	action_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(action_label)
	var buttons := HBoxContainer.new()
	column.add_child(buttons)
	for item in [["连接并只听", _listen], ["开麦 / 申请权限", _talk], ["关麦", _mute], ["退出诊断", _exit_probe]]:
		var button := Button.new()
		button.text = item[0]
		button.custom_minimum_size.y = 56
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(item[1])
		buttons.add_child(button)
	if Engine.has_singleton("GloryVoice"):
		bridge = Engine.get_singleton("GloryVoice")
	_refresh()

func _process(delta: float) -> void:
	elapsed += delta
	if elapsed >= 0.25:
		elapsed = 0.0
		_refresh()

func _native_status() -> Dictionary:
	if bridge == null:
		return {"error": "native_bridge_missing", "platform": OS.get_name()}
	var parsed: Variant = JSON.parse_string(str(bridge.getStatus()))
	return parsed if parsed is Dictionary else {"error": "invalid_native_status"}

func _refresh() -> void:
	var status := _native_status()
	status_label.text = JSON.stringify(status, "  ")
	var encoded := JSON.stringify(status)
	if encoded == previous:
		return
	previous = encoded
	observations.append({"at_msec": Time.get_ticks_msec(), "status": status})
	if observations.size() > 240:
		observations.pop_front()
	var report := {"platform": OS.get_name(), "bridge_present": bridge != null,
		"status": status, "observations": observations}
	var file := FileAccess.open(REPORT, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
	print("VOICE_DEVICE_STATUS " + encoded)

func _listen() -> void:
	if bridge == null:
		return
	var config: Variant = JSON.parse_string(FileAccess.get_file_as_string(CONFIG)) if FileAccess.file_exists(CONFIG) else null
	if not config is Dictionary or not config.has("url") or not config.has("token"):
		action_label.text = "等待本机写入临时测试房间配置。麦克风权限可先检查。"
		return
	var error := str(bridge.joinRoom(str(config.url), str(config.token), true))
	action_label.text = "正在连接测试房间（只听）" if error.is_empty() else error

func _talk() -> void:
	if bridge == null:
		return
	if not bridge.hasRecordPermission():
		bridge.requestRecordPermission()
		action_label.text = "请处理系统授权弹窗，允许后再点击开麦。"
		return
	var error := str(bridge.setMicrophoneEnabled(true))
	action_label.text = "已请求开麦；请连接测试房间并说一句话。" if error.is_empty() else error

func _mute() -> void:
	if bridge != null:
		bridge.setMicrophoneEnabled(false)
	action_label.text = "已请求关麦。"

func _exit_probe() -> void:
	if bridge != null:
		bridge.leaveRoom()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CONFIG))
	get_tree().quit()

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_WM_CLOSE_REQUEST:
		if bridge != null:
			bridge.leaveRoom()
