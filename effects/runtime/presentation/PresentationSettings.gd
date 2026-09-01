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
