extends PanelContainer

# 可作为「出售放置区」的面板。
#
# D2 第三步从 PrepShared 的内部类里搬出来，理由同 PrepDragButton：
# 商店面板的 `panel` 字段需要这个类型。
#
# `is_sell_zone` 默认 false 是刻意的：顶栏、左面板、商店底板也用这个类做布局，
# 但它们**不应该**成为隐性出售区 —— 否则在空白处松手就会把棋子卖掉。
# 只有显式标记的面板（当前只有商店那块红色覆盖层）才接受卖出放置。

var screen: Control
var is_sell_zone := false


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if not is_sell_zone:
		return false
	return screen != null and screen.has_method("_can_drop_to_sell") and screen._can_drop_to_sell(data)


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if not is_sell_zone:
		return
	if screen != null and screen.has_method("_drop_to_sell"):
		screen._drop_to_sell(data)
