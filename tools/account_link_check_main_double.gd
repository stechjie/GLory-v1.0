extends "res://scenes/main/Main.gd"

# account_link_check 用的测试替身。
#
# 只换掉一件事：真正的 _return_to_login() 会 change_scene_to_file 切回启动页，
# 在门禁里调它等于把门禁自己切走。这里改成记一笔，其余逻辑一行不动 ——
# 测的就是 Main.gd 里的判据与计时本身。

var return_calls := 0
var last_reason := ""


# 🔴 签名必须和 Main._return_to_login 一模一样。2026-09-24 那边加了 reason 参数、这里没跟着改，
# 替身从那天起就编译不过 —— 门禁照样报 PASS（用到替身的那几条根本没跑），直到 09-28 才发现。
func _return_to_login(reason := "") -> void:
	return_calls += 1
	last_reason = reason
