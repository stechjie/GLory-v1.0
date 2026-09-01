extends Node

# Lets a diagnostic tool scene run inside the shipped Android build.
#
# 桌面上要跑 D0 基线，直接把场景路径传给 Godot 就行。出包后这条路全断了，
# 2026-08-20 在真机上逐条验过：
#
#   1. 位置参数覆盖主场景 —— 无效。传 res://scripts/qa/battle_presentation_baseline.tscn，
#      跑起来的还是正常游戏（导出包的主场景来自 pack）。
#   2. `am start --esa command_line ...` —— 参数根本到不了 Godot。同一个包，无参数
#      53 行 godot 日志、加 --verbose 52 行，没有差别。原因是导出的入口是
#      GodotAppLauncher，真正的 GodotApp 没有 exported（直接 am start 它会
#      SecurityException），launcher 转发时把 extras 丢了。
#      （我第一次测这个用 `grep -c godot` 数行，把框架日志里的包名 com.godot.game
#       也数进去了，于是误判成"参数生效"。用 `logcat -s godot` 按 tag 过滤才看清。）
#   3. assets/_cl_ 确实在包里，但那是导出时烘进去的，改它要重签名。
#
# 所以改用文件触发：`adb shell run-as <pkg>` 往 user:// 写一个标记文件，然后正常
# 启动。run-as 在 Debug 包上是可用的（已验证能读写 files/）。
#
# 入口做成 autoload 而不是改 Main.gd：Main.gd 是同事 D2（PrepScreen 拆分）正在
# 动的文件，一个诊断入口不值得在那里制造冲突。

# 桌面用命令行，设备用标记文件。两条路都留着：桌面那条已经验过能跑通，
# 而且它不需要写文件，调试起来更顺手。
const FLAG := "--device-baseline"
const TRIGGER_PATH := "user://device_harness.json"

const BASELINE_SCENE := "res://scripts/qa/battle_presentation_baseline.tscn"

# 交给工具场景的参数。Android 上它们来自标记文件，桌面上来自命令行。
var tool_args: PackedStringArray = []

var _active := false


# 本次启动是否已被诊断接管。VFXWarmup 会读这个：预热挂在 root 上、跨场景存活，
# 放着不管它会一边编译着色器一边读闪存，而那正是基线要测的两件事。
func harness_active() -> bool:
	return _active


func _ready() -> void:
	if _claim_from_cmdline() or _claim_from_trigger_file():
		print("[DEVICE_HARNESS] 已接管本次启动，参数=%s" % str(tool_args))
		# 延后：主场景还在建，autoload 的 _ready() 里不能切场景，
		# 而且要等 Main._ready() 跑完它的节点才能被释放。
		call_deferred("_take_over")
	elif OS.is_debug_build():
		# 没接管时也留一行。上一版失败时设备上什么都没有 —— 分不清是标记文件没写进去、
		# 还是写进去了没被读到。一行字就能把这两种情况分开。
		print("[DEVICE_HARNESS] 未接管：命令行无 %s，且 %s 不存在" % [FLAG, TRIGGER_PATH])


func _claim_from_cmdline() -> bool:
	var args := OS.get_cmdline_args()
	var at := -1
	for i in args.size():
		if str(args[i]) == FLAG:
			at = i
			break
	if at < 0:
		return false
	for i in range(at + 1, args.size()):
		tool_args.append(str(args[i]))
	_active = true
	return true


# 标记文件形如 {"tool_args": ["--rounds", "1"]}。
func _claim_from_trigger_file() -> bool:
	if not FileAccess.file_exists(TRIGGER_PATH):
		return false

	var text := FileAccess.get_file_as_string(TRIGGER_PATH)
	# 先删再跑，而不是跑完再删。跑到一半崩了的话，留着的标记会让**之后每一次**
	# 正常启动都被诊断劫持 —— 玩家会发现游戏变成了一个跑不完的测试场景。
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TRIGGER_PATH))

	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		printerr("[DEVICE_HARNESS] %s 不是合法 JSON，忽略：%s" % [TRIGGER_PATH, text.substr(0, 120)])
		return false
	for value in (parsed as Dictionary).get("tool_args", []):
		tool_args.append(str(value))
	_active = true
	return true


func _take_over() -> void:
	var error := get_tree().change_scene_to_file(BASELINE_SCENE)
	if error != OK:
		# 大声地失败，并且退出码非零：悄悄退回正常游戏的话，一次运行会"跑完"而
		# 既没有证据也没有报错 —— 那正是 tools/android_smoke.sh 存在的理由。
		printerr("[DEVICE_HARNESS] 切换到 %s 失败 (err %d)" % [BASELINE_SCENE, error])
		get_tree().quit(1)
		return
	print("[DEVICE_HARNESS] 已切到 %s" % BASELINE_SCENE)
