class_name PresentationSettings
extends RefCounted

# V2 P1-05 第 4 条：无障碍开关的**唯一**裁决处。
#
# 玩家开关存在 PlayerProfile（跨局持久），画质档来自 VFXQualityBudget。两者在这里
# 合流，消费点只问这里、不各自实现一遍 —— 否则"关掉屏震"迟早会漏掉某个调用点。
#
# 关于"低画质自动降级"到底降什么，实测后的判断（不是照抄 V2 原文）：
#
#   * 屏震：几乎不花性能，低画质档**降幅度而不是关掉**。完全关掉是在替玩家做
#     无障碍决定，而这里的动机是性能。
#   * 命中闪：加色的透明层，是这三项里唯一有真实填充率成本的，低画质档关掉。
#   * hit-stop：只是把时间停一下，成本为零。低画质档**不降级** —— 降它只会让
#     打击感变差，一点性能都省不下来。
#
# 关于"低电量"：Godot 4 没有可移植的电量 API，仓里也没有任何电量探针。
# 这半条做不了，没有假装做到。

const QUALITY := preload("res://effects/vfx3d/core/VFXQualityBudget.gd")

# 低画质档的屏震幅度系数。留 0.6 而不是 0，是因为屏震本身不是性能问题。
const LOW_TIER_SHAKE_SCALE := 0.6


static func _low_tier() -> bool:
	return QUALITY.tier == QUALITY.Tier.LOW


static func _toggle(key: String) -> bool:
	# autoload 在门禁/工具场景里可能不在，缺省按"开"处理：
	# 无障碍开关的默认值是开启，取不到设置不该让演出比默认更差。
	if not is_instance_valid(PlayerProfile):
		return true
	return bool(PlayerProfile.get_presentation_toggle(key))


# 屏震幅度系数。0 表示完全不震。
static func screen_shake_scale() -> float:
	if not _toggle("screen_shake"):
		return 0.0
	return LOW_TIER_SHAKE_SCALE if _low_tier() else 1.0


static func screen_shake_allowed() -> bool:
	return screen_shake_scale() > 0.0


# 命中闪。低画质档一并关掉：三项里只有它有填充率成本。
static func flash_allowed() -> bool:
	if not _toggle("flash_effects"):
		return false
	return not _low_tier()


# hit-stop 只受玩家开关影响，不随画质档降级 —— 它不花性能。
static func hit_stop_allowed() -> bool:
	return _toggle("hit_stop")


# --- V3 P1-04：UI 音效与触觉 ------------------------------------------

# 关于「系统静音」：Godot 4 **没有可移植的 OS 静音查询 API**。
# 能查的只有游戏自己的 Master 总线（备战页那个静音按钮写的就是它）。
# 所以这里只保证「游戏内静音时不出声」，做不到「跟随系统静音」——
# 同上面低电量那半条，说清楚，不假装做到。
#
# 不随画质档降级：音效的成本是解码一个几十 KB 的短音，跟填充率无关，
# 低画质档关掉它只会让反馈变差、一点性能都省不下来（同 hit-stop 的理由）。
static func ui_sound_allowed() -> bool:
	if not _toggle("ui_sound"):
		return false
	var master := AudioServer.get_bus_index("Master")
	if master < 0:
		return true
	return not AudioServer.is_bus_mute(master)


# 9.17 反馈第 5 条：设置页新增的「背景音乐」开关。
#
# 与界面音效**分开裁决** —— 这正是这个开关存在的意义：只想听 BGM 的人
# 可以关掉音效，只想静音效的人可以关掉 BGM。所以这里**不**复用 ui_sound，
# 两者的键各自独立（"music" / "ui_sound"）。
#
# **刻意不看 Master 总线的静音状态。** 备战页那个「静音」按钮掐的是 Master，
# 而反馈第 5 条要的是「在设置里关了音乐之后，对局中按右上的『已静音』能重新
# 打开音乐」—— 那条路径由 PrepUI 在解除静音时把这个开关一并打开来实现，
# 不是让这里去读总线。反过来写会让「关掉音乐」在按过静音键之后自动失效。
static func music_allowed() -> bool:
	return _toggle("music")


# 触觉只有手持设备有。桌面即使开关是开的也不该假装能震 ——
# Input.vibrate_handheld() 在桌面是 no-op，但明确挡在这里，
# 门禁才能断言「桌面不调用」，而不是依赖引擎碰巧不做事。
#
# 刻意**不**并进 reduced motion：那个开关压的是屏幕上的运动，
# 而震动不是屏幕运动。把两者绑一起是概念混淆 —— 想关震动的人
# 未必想让所有过场动画也变静。
#
# `device_supported` 是**默认参数**，不是可变的测试开关：生产调用一律不传，
# 取的就是 _haptics_device_supported()。门禁跑在 Windows 上，如果没有这个参数，
# 「关掉开关就不震」这半条**在桌面上恒真**——平台判断会先返回 false，
# 断言永远绿，等于没测。加了它，门禁才能在桌面上跑手机那条分支。
static func haptics_allowed(device_supported := _haptics_device_supported()) -> bool:
	if not _toggle("haptics"):
		return false
	return device_supported


static func _haptics_device_supported() -> bool:
	return OS.get_name() in ["Android", "iOS"]
