extends Node
# 电脑版（Steam / Windows 导出包）的窗口模式。
#
# 11.14 用户定：从 Steam 打开默认全屏。只认「Windows + 导出包」：
#   · 手机包没有 windows 特性，完全不进来；
#   · 编辑器里 F5 没有 template 特性，开发时照旧是窗口，方便调试。
# 用的是 WINDOW_MODE_FULLSCREEN（无边框全屏，不改显示器分辨率），不是独占全屏：
# Alt+Tab 切出去不黑屏、不闪；多显示器时在游戏所在的那块屏上铺满。
# Alt+Enter / F11 在全屏和窗口之间切换，玩家的选择记在本机 user://display.cfg
# （是这台电脑的偏好，不进账号存档、不跟云同步）。

const CONFIG_PATH := "user://display.cfg"
const CONFIG_SECTION := "window"
const CONFIG_KEY := "fullscreen"

var _enabled := false


func _ready() -> void:
	_enabled = is_managed_platform()
	if not _enabled:
		set_process_input(false)
		return
	_apply(_load_fullscreen_preference())


static func is_managed_platform() -> bool:
	return OS.has_feature("windows") and OS.has_feature("template") \
		and DisplayServer.get_name() != "headless"


func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	var toggle := key.keycode == KEY_F11 \
		or (key.alt_pressed and (key.keycode == KEY_ENTER or key.keycode == KEY_KP_ENTER))
	if not toggle:
		return
	# 在 _input 里吃掉：聊天输入框获得焦点时 Alt+Enter 也不会被当成「发送」。
	get_viewport().set_input_as_handled()
	set_fullscreen(not is_fullscreen())


func is_fullscreen() -> bool:
	var mode := DisplayServer.window_get_mode()
	return mode == DisplayServer.WINDOW_MODE_FULLSCREEN \
		or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN


func set_fullscreen(fullscreen: bool) -> void:
	if not _enabled:
		return
	_apply(fullscreen)
	var config := ConfigFile.new()
	config.load(CONFIG_PATH)
	config.set_value(CONFIG_SECTION, CONFIG_KEY, fullscreen)
	config.save(CONFIG_PATH)


func _apply(fullscreen: bool) -> void:
	if fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)


func _load_fullscreen_preference() -> bool:
	var config := ConfigFile.new()
	if config.load(CONFIG_PATH) != OK:
		return true
	return bool(config.get_value(CONFIG_SECTION, CONFIG_KEY, true))
