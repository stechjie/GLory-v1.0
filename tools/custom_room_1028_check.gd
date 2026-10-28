extends Node
const H = preload("res://tools/CheckHarness.gd")
const SS = preload("res://scripts/multiplayer/SpectatorService.gd")
const PanelScript = preload("res://ui/components/SpectatorListPanel.gd")
var h = H.new("custom_room_1028")
class SettlementMain extends "res://scenes/main/Main.gd":
	var returned_to_menu := false
	func _ready() -> void:
		pass
	func _on_return_menu_requested() -> void:
		returned_to_menu = true

class Server extends "res://scripts/autoload/NetworkService.gd":
	var live := {}
	var failures := []
	func _ready() -> void:
		_reconnect_service.configure(_now, _net_log, {})
		_room_service.configure(_now, _wall_now, _net_log, func(): return 0, {}, _reconnect_service)
		_match_state.configure(_now)
	func _process(_delta: float) -> void:
		pass
	func _peer_connected(peer: int) -> bool:
		return live.has(peer)
	func _send_room_state(_room: Dictionary, _peer: int, _seq: int) -> void:
		pass
	func _send_spectate_state(_room: Dictionary, _peer: int, _seq: int) -> void:
		pass
	func _send_custom_room_failure(peer: int, reason: String) -> void:
		failures.append([peer,reason])
	func _send_custom_room_switch(_peer: int) -> void:
		pass
	func _spectate_fail(peer: int, reason: String) -> void:
		failures.append([peer,reason])
	func _spectate_notify_ended(_peer: int, _reason: String) -> void:
		pass
	func _voice_seat_released(_room: Dictionary, _slot: int, _identity: String) -> void:
		pass
	func _voice_rooms_closed(_room: Dictionary) -> void:
		pass
func server() -> Server:
	var s=Server.new()
	add_child(s)
	return s
func room(s: Server) -> Dictionary:
	var r: Dictionary=s._new_room()
	r.slot_states=["player","empty","empty","player","empty","empty"]
	r.peer_slot={100:0,103:3}
	r.initial_seats=r.slot_states.duplicate()
	r.leader_slot=0
	r.initial_leader=0
	s._peer_room[100]=int(r.id)
	s._peer_room[103]=int(r.id)
	s.live[100]=true
	s.live[103]=true
	return r
func observe(s: Server,r: Dictionary,p: int) -> void:
	SS.add(r,p,{"friend_code":"AB123456","player_name":"viewer"},0.0,"observer-"+str(p))
	s._peer_spectate[p]=int(r.id)
	s.live[p]=true
func ended(s: Server) -> Dictionary:
	var r=room(s)
	observe(s,r,501)
	r.state="result"
	r.run_over=true
	return r
func _ready() -> void:
	call_deferred("run")
func run() -> void:
	var s=server()
	var r=room(s)
	for phase in ["prep","battle","result","closed"]:
		r.state=phase
		h.expect(s._room_list_with_spectate().is_empty(),"hide_"+phase,"Started/closed rooms must not appear in public discovery")
	r.state="lobby"
	h.expect(s._room_list_with_spectate().size()==1,"lobby_listed","Waiting custom rooms remain discoverable")
	r.matched=true
	h.expect(s._room_list_with_spectate().is_empty(),"matched_hidden","Matchmade rooms are private")
	r.matched=false
	r.slot_states=["player","dummy","dummy","player","dummy","dummy"]
	h.expect(s._room_list_with_spectate().size()==1,"full_waiting_listed","Full waiting rooms may still be spectated")
	r.state="result"
	r.run_over=true
	r[SS.KEY_OPEN]=false
	var t: Dictionary=s._settlement_target(r)
	h.expect(not SS.is_open(t),"closed_inherited","Return must preserve the host spectator switch")
	# Viewers do not reserve or appear in the continuation until they click return.
	s=server()
	r=ended(s)
	t=s._settlement_target(r)
	h.expect(s._listed_spectator_peers(t).is_empty() and SS.public_list(t).is_empty(),"no_early_presence","A remains only in the old settlement")
	for peer in range(601,611):
		s._spectate_join(peer,int(t.id),"")
	h.expect(SS.count(t)==10,"newcomers_can_fill","New spectators may fill all ten seats")
	h.expect(s._return_spectator_to_settlement_room(501).is_empty() and s._spectator_return_errors.get(501)=="spectate_full","full_return","Returning viewer receives full reason")
	SS.remove_peer(t,601)
	h.expect(not s._return_spectator_to_settlement_room(501).is_empty(),"free_return","Returning viewer may take an actually free seat")
	h.expect(SS.count(t)==10 and SS.sid_of_peer(r,501)<0 and int(s._peer_spectate[501])==int(t.id),"one_identity","Successful return moves exactly one spectator identity")
	for phase in ["prep","battle","result"]:
		s=server()
		r=ended(s)
		t=s._settlement_target(r)
		t.state=phase
		h.expect(s._return_spectator_to_settlement_room(501).is_empty() and s._spectator_return_errors.get(501)=="room_started","started_"+phase,"Never follow an already started continuation")
	s=server()
	r=ended(s)
	t=s._settlement_target(r)
	t.run_over=true
	t.rematch_room_id=int(s._new_room().id)
	h.expect(s._return_spectator_to_settlement_room(501).is_empty() and s._spectator_return_errors.get(501)=="room_started","later_continuation","Do not follow a second continuation")
	for kind in ["closed","missing","spectate_closed"]:
		s=server()
		r=ended(s)
		t=s._settlement_target(r)
		if kind=="missing":s._rooms.erase(int(t.id))
		elif kind=="closed":t.state="closed"
		else:t[SS.KEY_OPEN]=false
		h.expect(s._return_spectator_to_settlement_room(501).is_empty() and s._spectator_return_errors.get(501)=="room_not_found",kind,"Unavailable room returns not-found reason")
	s=server()
	r=ended(s)
	s.live.erase(100)
	s.live.erase(103)
	var room_count: int=s._rooms.size()
	h.expect(s._return_spectator_to_settlement_room(501).is_empty() and s._spectator_return_errors.get(501)=="room_not_found","all_players_left","An abandoned source cannot recreate a new room for its viewer")
	h.expect(s._rooms.size()==room_count,"no_ghost_room","Rejected returns do not create empty discoverable rooms")
	# Failed real admission leaves the original seat, ready state, token and observer identity intact.
	for observer in [false,true]:
		for invalid in ["missing","started","closed","matched","abandoned","full_closed","spectators_full"]:
			s=server()
			r=room(s)
			r.ready[0]=true
			r.seat_tokens[0]="original-token"
			var peer := 100
			if observer:
				peer=501
				observe(s,r,peer)
			t=s._new_room()
			var target_id:=int(t.id)
			if invalid != "abandoned":t.slot_states[3]="player"
			match invalid:
				"missing":s._rooms.erase(target_id)
				"started":t.state="prep"
				"closed":t.state="closed"
				"matched":t.matched=true
				"full_closed":
					t.slot_states=["dummy","dummy","dummy","player","dummy","dummy"]
					t[SS.KEY_OPEN]=false
				"spectators_full":
					t.slot_states=["dummy","dummy","dummy","player","dummy","dummy"]
					for p in range(601,611):observe(s,t,p)
			var before=r.duplicate(true)
			s._join_custom_room(peer,target_id,"",{"pid":"account-"+str(peer),"code":"AB123456","name":"User"})
			h.expect(not s.failures.is_empty(),"refused_"+invalid+str(observer),"Invalid invitation is refused")
			h.expect(r==before,"preserve_"+invalid+str(observer),"Failure keeps full original room state")
			if observer:h.expect(int(s._peer_spectate.get(peer,0))==int(r.id),"observer_mapping_"+invalid,"Original viewer identity stays mapped")
			else:h.expect(int(s._peer_room.get(peer,0))==int(r.id),"seat_mapping_"+invalid,"Original player identity stays mapped")
	s=server()
	r=room(s)
	observe(s,r,501)
	t=s._new_room()
	t[SS.KEY_OPEN]=false
	s._spectate_join(501,int(t.id),"")
	h.expect(SS.sid_of_peer(r,501)>=0 and int(s._peer_spectate[501])==int(r.id),"failed_spectate_switch","Direct observer-switch refusal also retains original identity")
	var panel=PanelScript.new()
	add_child(panel)
	for width in [132,165,220,330,495]:
		panel.size=Vector2(width,width*480.0/330.0)
		panel._relayout()
		await get_tree().process_frame
		h.expect(is_equal_approx(panel._join.size.x,panel._join.size.y),"circle_"+str(width),"The spectator plus button remains square/circular at every scale")
	for en in [false,true]:
		for reason in ["spectate_full","room_started","room_not_found"]:
			var expected: String=({"spectate_full":"Spectator seats are full","room_started":"The match has started","room_not_found":"Room does not exist"} if en else {"spectate_full":"观战席已满","room_started":"对局已开始","room_not_found":"房间不存在"})[reason]
			h.expect(NetworkService.custom_room_error_text(reason,en)==expected,"localized_"+reason+str(en),"Exact Chinese and English return reasons")
	# Exercise the actual client reply and Main navigation/toast handler in both locales.
	var saved_locale := LocaleManager.get_locale()
	for locale in ["zh", "en"]:
		LocaleManager.set_locale(locale)
		for reason in ["spectate_full", "room_started", "room_not_found"]:
			var main=SettlementMain.new()
			add_child(main)
			main._spectate_active = true
			NetworkService.settlement_returned.connect(main._on_settlement_returned)
			NetworkService._rpc_settlement_returned(false, reason)
			h.expect(main.returned_to_menu and not main._spectate_active, "return_navigation_"+locale+reason,"Refused viewer returns to menu and restores own run")
			h.expect(preload("res://ui/components/GloryToast.gd")._last_text == NetworkService.custom_room_error_text(reason,locale=="en"),"return_toast_"+locale+reason,"The actual toast uses the authoritative localized reason")
			main.queue_free()
	LocaleManager.set_locale(saved_locale)
	panel.queue_free()
	h.finish(get_tree())
