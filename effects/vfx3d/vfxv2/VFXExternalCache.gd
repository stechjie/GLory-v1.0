class_name VFXExternalCache
extends RefCounted

# 外部参考 VFX（Binbun / Starter）的取用入口。
#
# 为什么需要：这些场景原本是在**施法那一帧同步 load()** 的
# （VFXBinbunReference3D.play_reference / VFXV2ExternalReference3D.play_external）。
# 真机实测 Boss 大圈那一下主线程冻结 5.9 秒。而且 load() 拿到的资源在特效播完、
# 引用归零后会被卸载，下次同一个技能再来一遍 —— 不是只卡第一次。
#
# 现在只是 BattleAssetService 的一层薄封装：加载与所有权统一由它管，
# 预取在大厅完成（见 BattleAssetManifest.seed_independent_paths）。
#
# ⚠️ 这里曾经有个 warm_draw()：把 14 个场景一次性实例化进离屏视口画一帧，
# 想借此提前建 shader 管线。真机实测 **28,336 ms**，超过服务器 20 秒心跳阈值，
# 直接被判掉线。**不要再加回来。** 若确实需要 shader 预热，必须分帧分批、
# 且绝不能放在阻塞路径上。

const BINBUN := preload("res://effects/vfx3d/vfxv2/VFXBinbunReference3D.gd")
const STARTER := preload("res://effects/vfx3d/vfxv2/VFXV2ExternalReference3D.gd")

static func get_scene(path: String) -> PackedScene:
	return BattleAssetService.get_scene(path)
