@tool
extends EditorPlugin

# 组队语音安卓桥接的导出接线（docs/语音LiveKit方案.md 5.1）。
#
# 桥接本体是 addons/glory_voice/bin/GloryVoice.aar（Kotlin，包 LiveKit 安卓开发包），
# 源码与打包脚本在 android_plugins/glory_voice/（改了要重跑 build_aar.ps1，tools/voice_check 拿源码指纹对账）。
# aar 里只有我们自己的类；LiveKit 本身由下面的 _get_android_dependencies 交给出包时的 Gradle，
# 从 Maven Central 下载（它依赖的 audioswitch 只在 JitPack 上）—— **每台出安卓包的电脑都要能上网**，
# 第一次出包会多下载约 30 MB，之后走 ~/.gradle 缓存。
#
# 🔴 **无条件交出：每个安卓包都必须带语音（2026-09-18）。**
#
# 原来这里有一个 Android 预设勾选项 glory_voice/enabled（默认关）。它两次让语音**悄悄**从包里消失：
#   - 09-14「只在一台电脑上开」→ 另一台出的 p27–p30 包全都没有语音；
#   - 09-17 改成「仓库模板里开」之后仍然没用 —— export_presets.cfg 在 .gitignore 里，
#     模板只在新建/覆盖时才起作用，覆盖不了同事机器上**已有**的那份旧预设。
#     他拉了新代码照样出没语音的包。
#
# 结论：这件事不能靠「每台机器记得勾一下」。开关删掉之后只剩两种结果 ——
# 包里有语音，或者**导出直接报错**（Godot 的安卓导出只要有插件提供 .aar 就要求开 Gradle 构建）。
# 报错是有意的：比出一个装上去才发现没语音的包好得多。
#
# 所以每台出安卓包的机器都要：勾上 Use Gradle Build、装 4.7.1 安卓构建模板、配好 JDK17 与 SDK。
# 出包后 tools/apk_identity.py 还会再验一次包里有没有桥接和 LiveKit、有没有多出不该有的权限。

var _export_plugin: EditorExportPlugin = null


func _enter_tree() -> void:
	_export_plugin = GloryVoiceExport.new()
	add_export_plugin(_export_plugin)


func _exit_tree() -> void:
	if _export_plugin != null:
		remove_export_plugin(_export_plugin)
		_export_plugin = null


class GloryVoiceExport extends EditorExportPlugin:
	# 相对 res://addons/（_get_android_libraries 的约定）。
	const AAR := "glory_voice/bin/GloryVoice.aar"
	# 与 android_plugins/glory_voice/build.gradle.kts、GloryVoicePlugin.kt 的 LIVEKIT_VERSION 一致（voice_check 对账）。
	const LIVEKIT := "io.livekit:livekit-android:2.28.2"
	# LiveKit 依赖的 audioswitch（com.github.davidliu:audioswitch）只发布在这里。
	const JITPACK := "https://jitpack.io"
	# LiveKit 自己的清单带着摄像头、屏幕录制前台服务 —— 只用语音，一样都不要：
	# 摄像头权限会出现在 Google Play 的应用信息里；屏幕录制前台服务还要在 Play 管理中心单独申报。
	# 必须写在应用自己的清单里才去得掉（库清单之间的 remove 看合并顺序，不可靠）。
	const REMOVED_PERMISSIONS := [
		"android.permission.CAMERA",
		"android.permission.FOREGROUND_SERVICE",
		"android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION",
	]
	const REMOVED_SERVICE := "io.livekit.android.room.track.screencapture.ScreenCaptureService"

	func _get_name() -> String:
		return "GloryVoice"

	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformAndroid or platform.get_os_name() == "iOS"

	func _get_export_options_overrides(platform: EditorExportPlatform) -> Dictionary:
		if platform.get_os_name() == "iOS":
			return {"privacy/microphone_usage_description": "用于队伍语音聊天，仅在您主动开启麦克风时录音。"}
		return {}

	func _get_android_libraries(_platform: EditorExportPlatform, _debug: bool) -> PackedStringArray:
		# 🔴 无条件。没有开关可关 —— 见文件头：开关两次让语音悄悄从包里消失。
		return PackedStringArray([AAR])

	func _get_android_dependencies(_platform: EditorExportPlatform, _debug: bool) -> PackedStringArray:
		return PackedStringArray([LIVEKIT])

	func _get_android_dependencies_maven_repos(_platform: EditorExportPlatform, _debug: bool) -> PackedStringArray:
		return PackedStringArray([JITPACK])

	func _get_android_manifest_element_contents(_platform: EditorExportPlatform, _debug: bool) -> String:
		var lines := PackedStringArray()
		for permission in REMOVED_PERMISSIONS:
			lines.append('<uses-permission android:name="%s" tools:node="remove" />' % permission)
		return "\n".join(lines)

	func _get_android_manifest_application_element_contents(_platform: EditorExportPlatform, _debug: bool) -> String:
		return '<service android:name="%s" tools:node="remove" />' % REMOVED_SERVICE
