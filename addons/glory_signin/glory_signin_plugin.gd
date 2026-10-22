@tool
extends EditorPlugin

# 用 Google 登录的安卓桥接的导出接线（docs/三方登录设计.md 第六节）。
#
# 桥接本体是 addons/glory_signin/bin/GlorySignIn.aar（Kotlin，Credential Manager），
# 源码与打包脚本在 android_plugins/glory_signin/（改了要重跑 build_aar.ps1，
# tools/account_provider_check 拿源码指纹对账）。
# aar 里只有我们自己的类；Credential Manager 与 googleid 由 _get_android_dependencies
# 交给出包时的 Gradle，从 Google Maven 下载 —— 同语音桥接：**出安卓包的电脑要能上网**。
#
# 🔴 无条件交出，没有开关：语音桥接那边两次因为「每台机器记得勾一下」悄悄从包里消失
# （addons/glory_voice/glory_voice_plugin.gd 文件头），这里不重蹈。
#
# 不需要任何权限、也不改清单：INTERNET 应用本来就有。
# iOS 那一期（Apple + Google）另做，这里只管安卓。

var _export_plugin: EditorExportPlugin = null


func _enter_tree() -> void:
	_export_plugin = GlorySignInExport.new()
	add_export_plugin(_export_plugin)


func _exit_tree() -> void:
	if _export_plugin != null:
		remove_export_plugin(_export_plugin)
		_export_plugin = null


class GlorySignInExport extends EditorExportPlugin:
	# 相对 res://addons/（_get_android_libraries 的约定）。
	const AAR := "glory_signin/bin/GlorySignIn.aar"
	# 与 android_plugins/glory_signin/build.gradle.kts 的 compileOnly 一致（account_provider_check 对账）。
	# play-services-base 不列：play-services-auth 运行时会把它带进来。
	const DEPENDENCIES := [
		"androidx.credentials:credentials:1.5.0",
		"androidx.credentials:credentials-play-services-auth:1.5.0",
		"com.google.android.libraries.identity.googleid:googleid:1.1.1",
	]

	func _get_name() -> String:
		return "GlorySignIn"

	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformAndroid

	func _get_android_libraries(_platform: EditorExportPlatform, _debug: bool) -> PackedStringArray:
		return PackedStringArray([AAR])

	func _get_android_dependencies(_platform: EditorExportPlatform, _debug: bool) -> PackedStringArray:
		return PackedStringArray(DEPENDENCIES)
