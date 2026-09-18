@tool
extends EditorPlugin

# 游戏内语音插件的导出接线（docs/聊天系统设计.md 第九节方案 ②）。
#
# 插件本体是 addons/glory_voice/bin/GloryVoice.aar，源码与打包脚本在
# android_plugins/glory_voice/（改了 Java 要重新跑 build_aar.ps1，
# tools/voice_check 会拿源码指纹对账）。
#
# 🔴 **无条件交出 .aar：每个安卓包都必须带语音（2026-09-18）。**
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
# 出包后 tools/apk_identity.py 还会再验一次包里有没有这个插件。

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

	func _get_name() -> String:
		return "GloryVoice"

	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformAndroid

	func _get_android_libraries(_platform: EditorExportPlatform, _debug: bool) -> PackedStringArray:
		# 🔴 无条件。没有开关可关 —— 见文件头：开关两次让语音悄悄从包里消失。
		return PackedStringArray([AAR])
