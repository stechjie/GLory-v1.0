extends RefCounted

# 判断原生插件单例（Engine.get_singleton() 拿到的对象）有没有某个方法。所有平台通用。
#
# 🔴 规则：对原生插件判断方法是否存在，一律用 NativeBridge.supports()，不要直接写 bridge.has_method()。
#   - Android 的 JNISingleton：Kotlin / Java 方法登记在单独的表里，Object.has_method() 查不到，
#     要用 has_java_method()。直接写 has_method() 在安卓上永远是 false。
#     2026-11-18 给 iOS 加 Apple 登录时，SignInBridge 改成了 has_method()，安卓的 Google 登录按钮因此消失。
#   - iOS / 桌面的原生扩展、门禁里的 GDScript 替身：普通 has_method() 就能查到。
#   VoiceService._bridge_has_method()、BillingBridge.installed_from_play() 是同样的写法（早于本文件）。
#
# 不声明 class_name、不 preload 资源：战斗服务器也会加载账号脚本（见 AccountConfig.gd 顶部）。

static func supports(bridge: Object, method: StringName) -> bool:
	if bridge == null:
		return false
	if bridge.has_method("has_java_method"):
		return bool(bridge.call("has_java_method", method))
	return bridge.has_method(method)
