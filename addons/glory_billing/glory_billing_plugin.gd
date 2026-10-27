@tool
extends EditorPlugin

# Google Play 结算的安卓桥接的导出接线（docs/充值系统设计.md 第九节）。
#
# 桥接本体是 addons/glory_billing/bin/GloryBilling.aar（Kotlin，Play 结算库 8），
# 源码与打包脚本在 android_plugins/glory_billing/（改了要重跑 build_aar.ps1，
# tools/iap_check 拿源码指纹对账）。
# aar 里只有我们自己的类；结算库由 _get_android_dependencies 交给出包时的 Gradle，
# 从 Google Maven 下载 —— 同登录桥接：**出安卓包的电脑要能上网**。
#
# 🔴 无条件交出，没有开关：语音桥接那边两次因为「每台机器记得勾一下」悄悄从包里消失
# （addons/glory_voice/glory_voice_plugin.gd 文件头），这里不重蹈。
#
# 不改清单：结算库自己的清单带着 com.android.vending.BILLING，Gradle 合并时会加进来。

var _export_plugin: EditorExportPlugin = null


func _enter_tree() -> void:
	_export_plugin = GloryBillingExport.new()
	add_export_plugin(_export_plugin)


func _exit_tree() -> void:
	if _export_plugin != null:
		remove_export_plugin(_export_plugin)
		_export_plugin = null


class GloryBillingExport extends EditorExportPlugin:
	# 相对 res://addons/（_get_android_libraries 的约定）。
	const AAR := "glory_billing/bin/GloryBilling.aar"
	# 与 android_plugins/glory_billing/build.gradle.kts 的 compileOnly 一致（iap_check 对账）。
	const DEPENDENCIES := [
		"com.android.billingclient:billing:8.0.0",
	]

	func _get_name() -> String:
		return "GloryBilling"

	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformAndroid

	func _get_android_libraries(_platform: EditorExportPlatform, _debug: bool) -> PackedStringArray:
		return PackedStringArray([AAR])

	func _get_android_dependencies(_platform: EditorExportPlatform, _debug: bool) -> PackedStringArray:
		return PackedStringArray(DEPENDENCIES)
