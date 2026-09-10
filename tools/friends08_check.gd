extends Node
const Harness = preload("res://tools/CheckHarness.gd")
class FriendsProbe:
	extends "res://scenes/menu/FriendsScreen.gd"
	var mock_changes := false
	var changes := 0
	func _run(action: Callable, message: String) -> void:
		if mock_changes:
			changes += 1
		else:
			await super._run(action, message)
	func _ready() -> void:
		_build()
	func _reload(_show_errors: bool) -> void:
		_render()
class LobbyProbe:
	extends "res://scenes/menu/Team3v3Lobby.gd"
	func _ready() -> void:
		_build()
class ProfileProbe:
	extends "res://scenes/menu/ProfileScreen.gd"
	var changes: Array = []
	var unblock_response := {"code": 204, "body": {}}
	var unblock_calls := 0
	func _send_unblock() -> Dictionary:
		unblock_calls += 1
		return unblock_response
	func _send_friend_change(blocking: bool) -> Dictionary:
		changes.append(blocking)
		return {"code": 204, "body": {}}
	func _ready() -> void:
		_build()

func _ready() -> void:
	var h = Harness.new("friends08")
	var entries := [{"friend_code": "ABCDEFGH", "player_name": "Online", "online": true, "room_id": null}, {"friend_code": "BCDEFGHJ", "player_name": "Offline", "online": false, "room_id": null}]
	h.expect(AccountManager.normalize_list_response("/v1/me/friends", entries).get("friends") == entries, "legacy", "兼容旧服务端顶层好友数组")
	h.expect(AccountManager.normalize_list_response("/v1/me/friends", {"friends": entries}).get("friends") == entries, "current", "兼容当前对象响应")
	var friends = FriendsProbe.new()
	add_child(friends)
	await friends._run(func(): return {"code": 200, "body": {"result": "accepted"}}, "已发送好友请求")
	h.expect(friends._notice == "已成为好友", "cross_request", "交叉申请成功显示已成为好友")
	for entry in entries:
		var row = friends._friend_row(entry)
		h.expect(row != null and row.get_child_count() >= 3, "null_room", "空房间号好友仍正常渲染")
		h.expect(row.get_child(1).get_theme_color("font_color") == (Color.WHITE if entry.online else friends.Tokens.TEXT_DISABLED), "presence_color", "在线好友白色，离线暗色")
		row.free()
	var saved := AccountManager.friend_request_seen.duplicate(true)
	AccountManager.friend_request_seen.clear()
	friends._incoming = [{"friend_code": "ABCDEFGH", "created_at": "one"}]
	friends._render()
	var badge = friends._tab_buttons[friends.Tab.REQUESTS].get_node("RequestBadge")
	h.expect(badge.visible, "new_badge", "新请求红色感叹号")
	friends._switch_tab(friends.Tab.REQUESTS)
	h.expect(not badge.visible, "read_badge", "打开请求后清除提醒")
	friends._switch_tab(friends.Tab.FRIENDS)
	friends._render()
	h.expect(not badge.visible, "read_stays", "旧请求刷新不会重复提醒")
	friends._incoming = [{"friend_code": "ABCDEFGH", "created_at": "two"}]
	friends._render()
	h.expect(badge.visible, "new_again", "新一轮请求重新提醒")
	var lobby = LobbyProbe.new()
	add_child(lobby)
	lobby._render_online_friends(entries)
	h.expect(lobby._friends_box.get_child_count() == 1 and lobby._friends_box.get_child(0).text.begins_with("Online"), "lobby_online", "房间仅显示在线好友")
	var profile = ProfileProbe.new()
	profile._mode = profile.Mode.PUBLIC
	add_child(profile)
	var labels: Array = []
	for button in profile.find_children("*", "Button", true, false):
		labels.append(button.text)
	h.expect(labels.has("添加朋友请求") and labels.has("举报该玩家"), "profile_actions", "公开资料包含加好友与独立举报入口")
	profile._data["relation"] = "friends"
	profile._update_friend_actions()
	h.expect(profile._friend_action.text == "删除好友" and profile._block_action.text == "拉入黑名单", "friend_actions", "好友资料显示删除和拉黑")
	profile._confirm_friend_action(false)
	DialogService._on_dialog_resolved("confirmed", str(DialogService._pending.keys()[0]))
	h.expect(profile.changes == [false] and profile._data.relation == "none" and profile._friend_action.text == "添加朋友请求", "profile_remove", "删除确认实际执行并切换按钮")
	profile._confirm_friend_action(true)
	DialogService._on_dialog_resolved("confirmed", str(DialogService._pending.keys()[0]))
	h.expect(profile.changes == [false, true] and profile._data.relation == "blocked" and not profile._block_action.disabled and profile._block_action.text == "解除黑名单", "profile_block", "已拉黑玩家显示可用解除按钮")
	profile.unblock_response = {"code": 503, "error": "暂时失败"}
	await profile._on_block_action()
	h.expect(profile._data.relation == "blocked" and not profile._block_action.disabled, "unblock_retry", "解除失败保留黑名单状态且可重试")
	profile.unblock_response = {"code": 204, "body": {}}
	profile._block_action.pressed.emit()
	h.expect(profile.unblock_calls == 2 and profile._data.relation == "none" and profile._block_action.text == "拉入黑名单" and not profile._friend_action.disabled, "unblock_success", "解除成功恢复拉黑及加好友按钮，不自动加为好友")
	friends.mock_changes = true
	friends._confirm_remove(entries[0])
	DialogService._on_dialog_resolved("confirmed", str(DialogService._pending.keys()[0]))
	friends._confirm_block(entries[0])
	DialogService._on_dialog_resolved("confirmed", str(DialogService._pending.keys()[0]))
	h.expect(friends.changes == 2, "list_callbacks", "列表删除拉黑接收真实双参数回调")
	AccountManager.friend_request_seen = saved
	profile.free()
	lobby.free()
	friends.free()
	h.finish(get_tree())
