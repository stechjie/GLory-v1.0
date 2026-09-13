@tool
extends EditorPlugin

# 语音验证插件的导出接线（docs/聊天系统设计.md 第九节方案 ②）。
#
# 插件本体是 addons/glory_voice/bin/GloryVoice.aar，源码与打包脚本在
# android_plugins/glory_voice/（改了 Java 要重新跑 build_aar.ps1，
# tools/voice_spike_check 会拿源码指纹对账）。
#
# 🔴 **默认不打进包。** Godot 的安卓导出只要有插件提供 .aar，就要求开 Gradle 构建，
# 否则整个导出直接报错 —— 那会让现在不开 Gradle 的正式出包流程当场失败。
# 所以 Android 预设里多一个勾选项 glory_voice/enabled（默认关），只有出语音测试包时才勾，
# 同时勾上 Use Gradle Build。

var _export_plugin: EditorExportPlugin = null


func _enter_tree() -> void:
	_export_plugin = GloryVoiceExport.new()
	add_export_plugin(_export_plugin)


func _exit_tree() -> void:
	if _export_plugin != null:
		remove_export_plugin(_export_plugin)
		_export_plugin = null


class GloryVoiceExport extends EditorExportPlugin:
	const OPTION := "glory_voice/enabled"
	# 相对 res://addons/（_get_android_libraries 的约定）。
	const AAR := "glory_voice/bin/GloryVoice.aar"

	func _get_name() -> String:
		return "GloryVoice"

	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformAndroid

	func _get_export_options(platform: EditorExportPlatform) -> Array[Dictionary]:
		if not (platform is EditorExportPlatformAndroid):
			return []
		return [{
			"option": {"name": OPTION, "type": TYPE_BOOL},
			"default_value": false,
		}]

	func _get_android_libraries(_platform: EditorExportPlatform, _debug: bool) -> PackedStringArray:
		# 没勾就什么都不给：普通导出（不开 Gradle）照旧能出包，只是没有语音插件。
		# 不写 bool(get_option(...))：不在导出过程中被调到时它可能是 null，而 bool(null) 会报错。
		var enabled: Variant = get_option(OPTION)
		if not (enabled is bool and enabled):
			return PackedStringArray()
		return PackedStringArray([AAR])
