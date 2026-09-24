extends Node
const Harness = preload("res://tools/CheckHarness.gd")
const Rules = preload("res://scripts/economy/CarrotEconomy.gd")
const Ledger = preload("res://scripts/multiplayer/EconomyLedger.gd")
const Aura = preload("res://effects/vfx3d/modules/FourStarAuraV3_3D.gd")
var h: RefCounted

func _ready() -> void:
	h = Harness.new("four_star_upgrade")
	NetworkService.reset()
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	for d in units:
		var cost: int = {1:500, 2:800, 3:1100}.get(int(d.get("tier", 0)), -1)
		h.expect(cost == Rules.four_star_gold(int(d.get("tier", 0))), "tier_cost", str(d.id))
		if cost < 0 or not Rules.valid_stone_type(str(d.get("element", ""))):
			continue
		GameState.reset_run()
		var cell := {"uid":"check-" + str(d.id), "id":d.id, "star":3, "def":d.duplicate(true)}
		GameState.gold = cost - 1
		GameState.team_upgrade_stones = {"sky":2, "land":2, "ren":2}
		var before := cell.duplicate(true)
		var denied := GameState.upgrade_cell_to_four_star(cell)
		h.expect(not denied.ok and cell == before and GameState.gold == cost - 1 and GameState.team_upgrade_stones[d.element] == 2, "local_atomic_denial", str(d.id))
		GameState.gold = cost
		h.expect(GameState.upgrade_cell_to_four_star(cell).ok and GameState.gold == 0 and GameState.team_upgrade_stones[d.element] == 1 and cell.star == 4, "local_exact_cost", str(d.id))
		h.expect(cell.def == before.def and cell.id == before.id and cell.uid == before.uid, "identity_skill_unchanged", str(d.id))
		h.expect(not GameState.upgrade_cell_to_four_star(cell).ok and GameState.gold == 0 and GameState.team_upgrade_stones[d.element] == 1, "local_double_click", str(d.id))
		var prep := Ledger.new_prep(cost - 1)
		prep.roster[cell.uid] = {"unit_id":d.id,"star":3,"kind":"unit","cost_basis":30}
		var stones := {"sky":2,"land":2,"ren":2}
		var ctx := {"unit_table":units,"team_stones":stones,"round_index":4}
		var payload := {"uid":cell.uid,"unit_id":d.id,"tier":1,"cost":0,"element":"forged"}
		var original := prep.duplicate(true)
		var receipt := Ledger.apply(prep, "use_upgrade_stone", payload, ctx)
		h.expect(not receipt.ok and prep == original and stones[d.element] == 2, "server_atomic_denial", str(d.id))
		prep.gold = cost
		receipt = Ledger.apply(prep, "use_upgrade_stone", payload, ctx)
		h.expect(receipt.ok and prep.gold == 0 and receipt.result.cost == cost and stones[d.element] == 1 and prep.roster[cell.uid].star == 4, "server_trusted_tier", str(d.id))
		h.expect(not Ledger.apply(prep,"use_upgrade_stone",payload,ctx).ok and stones[d.element] == 1 and prep.gold == 0, "server_repeat", str(d.id))
	_server_modes(units)
	await _ui_and_visuals(units[0])
	var room: Dictionary = NetworkService._new_room()
	var actions: Array = NetworkService.ECONOMY_ACTIONS.duplicate()
	actions.sort()
	var fields: Array = NetworkService._build_economy_state(room,0).keys()
	fields.sort()
	print("FOUR_STAR_CONTRACT ", Marshalls.raw_to_base64((",".join(PackedStringArray(actions)) + "|" + ",".join(PackedStringArray(fields))).sha256_buffer()).substr(0,16))
	h.finish(get_tree())

func _server_modes(units: Array) -> void:
	var saved_flags := ServerFlags._values.duplicate(true)
	for tier in [1,2,3]:
		var d: Dictionary = {}
		for unit in units:
			if int(unit.get("tier",0)) == tier:
				d = unit
				break
		var cost: int = {1:500,2:800,3:1100}[tier]
		for authority in [false,true]:
			ServerFlags._values["economy_ledger_enabled"] = true
			ServerFlags._values["economy_ledger_authoritative"] = authority
			var room: Dictionary = NetworkService._new_room()
			room.state = NetworkService.ROOM_PREP
			var prep: Dictionary = NetworkService._room_prep(room,0)
			prep.gold = cost - 1
			prep.roster["mode-test"] = {"unit_id":d.id,"star":3,"kind":"unit","cost_basis":30}
			var stones: Dictionary = NetworkService._room_team_stones(room,0)
			stones[d.element] = 1
			var before := prep.duplicate(true)
			var payload := {"uid":"mode-test","unit_id":d.id,"gold":cost - 1}
			var denied := NetworkService._room_apply_economy(room,0,"use_upgrade_stone",payload)
			h.expect(not denied.ok and prep == before and stones[d.element] == 1,"mode_denial",str([tier,authority]))
			if authority:
				payload.gold = 999999
				denied = NetworkService._room_apply_economy(room,0,"use_upgrade_stone",payload)
				h.expect(not denied.ok and prep == before,"authority_rejects_reported_gold",str(tier))
				prep.gold = cost
			payload.gold = cost
			var receipt := NetworkService._room_apply_economy(room,0,"use_upgrade_stone",payload)
			h.expect(receipt.ok and prep.gold == 0 and room.slot_gold[0] == 0 and stones[d.element] == 0,"mode_success",str([tier,authority]))
			GameState.reset_run()
			GameState.gold = cost
			GameState.bench_slots[0] = {"id":d.id,"uid":"mode-test","star":3,"def":d}
			NetworkService._apply_carrot_receipt(receipt)
			NetworkService._apply_carrot_receipt(receipt)
			h.expect(GameState.gold == 0 and GameState.bench_slots[0].star == 4,"receipt_applied_once",str([tier,authority]))
			# Simulate the process dying before receipt application and loading
			# its last three-star save. The room snapshot must recover payment.
			GameState.bench_slots[0].star = 3
			GameState.gold = cost
			var snapshot := NetworkService._build_economy_state(room,0)
			NetworkService._apply_carrot_state(snapshot)
			NetworkService._apply_carrot_state(snapshot)
			NetworkService._apply_carrot_receipt(receipt)
			h.expect(GameState.gold == 0 and GameState.bench_slots[0].star == 4,"lost_receipt_recovery",str([tier,authority]))
	ServerFlags._values = saved_flags

func _ui_and_visuals(d: Dictionary) -> void:
	GameState.reset_run()
	GameState.gold = 2000
	GameState.team_upgrade_stones = {"sky":2,"land":2,"ren":2}
	var cell := {"uid":"ui-unit","id":d.id,"star":2,"def":d.duplicate(true)}
	GameState.board_slots[0] = cell
	var panel := preload("res://scenes/prep/FourStarUpgradePanel.gd").new()
	add_child(panel)
	panel.open_for(cell, func(_uid): GameState.upgrade_cell_to_four_star(panel.selected_cell()))
	h.expect(panel.action.disabled,"two_star_disabled","三星前不可升级")
	cell.star = 3
	panel.refresh()
	h.expect(not panel.action.disabled,"ready_enabled","满足条件可升级")
	panel._pressed()
	h.expect(panel.confirming and cell.star == 3 and GameState.gold == 2000,"inline_confirmation","第一次点击只确认")
	GameState.board_slots[0] = null
	GameState.bench_slots[2] = cell
	panel._pressed()
	h.expect(cell.star == 4 and panel.action.disabled,"uid_after_move","按 UID 找到移动后的原棋子")
	cell.star = 3
	NetworkService.team_active = true
	NetworkService.is_host = false
	NetworkService.server_four_star_cost_version = 0
	panel.refresh()
	h.expect(panel.action.disabled,"old_server_disabled","旧服务器不可免费升星")
	NetworkService.server_four_star_cost_version = Rules.FOUR_STAR_COST_VERSION
	NetworkService.four_star_request_id = "pending-test"
	panel.refresh()
	h.expect(panel.action.disabled,"pending_disabled","等待回执不可重发")
	NetworkService.reset()
	h.expect(NetworkService.four_star_request_id.is_empty() and NetworkService.server_four_star_cost_version == 0,"session_reset","不能将旧请求带进新局")
	panel.queue_free()
	for element in ["sky","land","ren"]:
		var actor := Node3D.new()
		add_child(actor)
		var aura = Aura.sync(actor,2,element)
		h.expect(aura != null and aura.visible and aura.configured,"four_star_aura",element)
		Aura.sync(actor,0,element)
		h.expect(not aura.visible and not aura.is_processing(),"unready_hidden",element)
		Aura.sync(actor,2,element,1.0,true)
		h.expect(aura.visible and aura.in_battle and aura.particles.size() == 2,"battle_aura",element)
		aura.play_upgrade()
		h.expect(aura.visible and aura.ring != null,"upgrade_no_burst",element)
		actor.queue_free()
	await get_tree().process_frame
