extends Node
const Harness = preload("res://tools/CheckHarness.gd")
const Shop = preload("res://scenes/prep/panels/ShopPanel.gd")
const Choice = preload("res://scenes/prep/panels/TreasureChoicePanel.gd")
var _wait_released := false
class ReceiptProbe:
	extends "res://scenes/prep/PrepUI.gd"
	var message := ""
	func _ready() -> void:
		pass
	func show_message(text: String) -> void:
		message = text

class MainProbe:
	extends "res://scenes/main/Main.gd"
	var applied := false
	var entered := false
	func _ready() -> void:
		pass
	func _apply_team_match_state_payload(_payload: Dictionary, _result: Dictionary = {}) -> void:
		applied = true
	func _show_prep() -> void:
		entered = true

func _release_wait(probe, h) -> void:
	await get_tree().create_timer(0.05).timeout
	h.expect(not probe.applied and not probe.entered, "wait_before_income", "其他人未结束时不应用收益或进入备战")
	_wait_released = true
	NetworkService.is_host = false
	NetworkService.server_phase = NetworkService.ROOM_PREP
	NetworkService.server_round_index = GameState.round_index + 1

func _ready() -> void:
	var h = Harness.new("bug0912")
	var shop := Shop.new()
	var card := Button.new()
	GameState.shop_offers = [{"id": "fixture"}]
	GameState.shop_sold = [false]
	shop._on_card_pressed(card, 0)
	h.expect(shop.selected == 0, "select", "首次点击选中")
	shop._on_card_pressed(card, 0)
	h.expect(shop.selected == -1, "deselect", "再次点击取消")
	shop.selected = 0
	shop.picker_open = true
	shop.close_picker()
	h.expect(shop.selected == -1 and not shop.picker_open, "close", "关闭清空选中")
	shop.selected = 0
	shop.picker_open = true
	shop.toggle_picker()
	h.expect(shop.selected == -1 and not shop.picker_open, "toggle_close", "收起商店清除选中")
	card.free()
	shop.free()
	var a := {"uid": "a", "attack_speed": 1.0, "statuses": {}, "alive": true}
	var b := {"uid": "b", "alive": true, "owner_treasures": ["ctrl_binding_weight", "atk_frenzy_assault"]}
	BattleSimTreasures._apply_frenzy_assault(a, b)
	BattleSimTreasures._apply_frenzy_assault(a, b)
	h.expect(is_equal_approx(StatusEffectService.attack_speed_multiplier(a), 1.15 * 1.15), "stack", "同目标叠加攻速")
	BattleSimTreasures._apply_frenzy_assault(a, {"uid": "c"})
	h.expect(is_equal_approx(StatusEffectService.attack_speed_multiplier(a), 1.15) and a.attack_speed == 1.0, "reset", "换目标仅保留新的一层，基础攻速未污染")
	a.frenzy_stacks = 0
	BattleSimTreasures._apply_defender_treasure_reaction(b, a, {"elapsed": 0.0}, 1)
	h.expect(int(a.get("frenzy_stacks", 0)) == 1 and int(b.get("frenzy_stacks", 0)) == 0, "counter", "压迫反击给攻击者叠加攻速")
	var choice := Choice.new()
	h.expect(choice.effect_text("ctrl_corrosive_needle").contains("3 秒"), "bleed_text", "选宝显示失血3秒")
	choice.free()
	var book: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/codex/treasure_text.json"))
	h.expect(book.treasures.atk_wail_resonance.effect.contains("15%"), "wail", "图鉴为15%")
	h.expect(book.linkages.link_hu_pai_master.requires_text.contains("狂怒阵容"), "hand", "胡牌手第五件为狂怒阵容")
	h.expect(NetworkService.shop_refresh_error_text("bad_phase") == "需等待其他人战斗结束", "bad_phase_text", "旧服务端回执显示等待提示")
	NetworkService.server_phase = NetworkService.ROOM_PREP
	NetworkService.server_round_index = 4
	h.expect(not NetworkService.server_prep_confirmed(5), "stale_prep", "上回合prep不能放行下一回合")
	NetworkService.server_round_index = 5
	h.expect(NetworkService.server_prep_confirmed(5), "current_prep", "同回合prep可放行")
	NetworkService.server_phase = NetworkService.ROOM_RESULT
	h.expect(not NetworkService.server_prep_confirmed(5), "result_not_prep", "回合号已推进但仍在结算不能放行")
	var receipt_probe := ReceiptProbe.new()
	receipt_probe._on_carrot_economy_receipt({"action": "shop_refresh", "ok": false, "error": "bad_phase"})
	h.expect(receipt_probe.message == "需等待其他人战斗结束", "actual_receipt", "刷新回执真实UI处理分支显示等待提示")
	receipt_probe.free()
	var probe := MainProbe.new()
	add_child(probe)
	NetworkService.team_active = true
	NetworkService.is_host = true
	NetworkService.server_phase = NetworkService.ROOM_PREP
	NetworkService.server_round_index = GameState.round_index
	NetworkService.latest_match_state = {"protocol": NetworkConfig.NETWORK_PROTOCOL_VERSION, "completed_round": GameState.round_index, "battle_id": "fixture", "run_over": false}
	_release_wait(probe, h)
	await probe._finish_server_authoritative_team_battle({})
	h.expect(_wait_released and probe.applied and probe.entered, "release", "服务端进入备战后才应用结算")
	NetworkService.team_active = false
	probe.queue_free()
	if "--review" in OS.get_cmdline_user_args():
		var row := HBoxContainer.new()
		add_child(row)
		for name in ["打断锁链", "腐蚀毒针"]:
			var col := VBoxContainer.new()
			row.add_child(col)
			var label := Label.new()
			label.text = name
			col.add_child(label)
			var icon := TextureRect.new()
			icon.texture = load("res://assets/ui/treasure_logos/" + name + ".png")
			col.add_child(icon)
			var imported := icon.texture.get_image()
			var original := Image.load_from_file(ProjectSettings.globalize_path("res://assets/ui/treasure_logos/" + name + ".png"))
			imported.convert(Image.FORMAT_RGBA8)
			original.convert(Image.FORMAT_RGBA8)
			var matches := true
			for y in range(0, original.get_height(), 8):
				for x in range(0, original.get_width(), 8):
					var pixel := original.get_pixel(x, y)
					if pixel.a == 1.0 and imported.get_pixel(x, y) != pixel:
						matches = false
			h.expect(matches, "import_matches", "运行时纹理不透明区域与修正PNG采样像素一致")
		var copy := Label.new()
		copy.text = book.treasures.ctrl_interrupt_chain.effect
		copy.position = Vector2(20, 565)
		add_child(copy)
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://work/bug0912-resource-review.png")
	h.expect(book.treasures.ctrl_interrupt_chain.effect.contains("缴械"), "disarm", "图鉴数据明确缴械")
	h.finish(get_tree())
