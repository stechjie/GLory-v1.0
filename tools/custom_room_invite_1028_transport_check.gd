extends Node
const Keys = preload("res://tools/battle_card_test_keys.gd")
const SS = preload("res://scripts/multiplayer/SpectatorService.gd")
const PORT := 19944
const ACCOUNT := "11111111-1111-1111-1111-111111111111"
class MainProbe extends "res://scenes/main/Main.gd":
	var navigation := 0
	var menus := 0
	func _ready() -> void:
		pass
	func _show_team3v3_lobby() -> void:
		navigation+=1
	func _show_menu() -> void:
		menus+=1
var server_role := false
var key: CryptoKey
var peer_id := 0
var step := 0
var old: Dictionary = {}
var target: Dictionary = {}
var original: Dictionary = {}
var main: MainProbe
var card := ""
var done := false
var reports := []
func _ready() -> void:
	server_role=OS.get_cmdline_user_args().has("--invite-server")
	NetworkService.set_process(false)
	NetworkService.team_active=true
	NetworkService.is_host=server_role
	NetworkService._dedicated_server=server_role
	NetworkService.remote_address="127.0.0.1"
	NetworkService.remote_port=NetworkConfig.SERVER_PORT
	NetworkService._setup_auth()
	var peer=ENetMultiplayerPeer.new()
	if server_role:
		key=Keys.generate()
		NetworkService._battle_card_public_key=Keys.public_pem(key)
		if peer.create_server(PORT)!=OK:
			get_tree().quit(2)
			return
	else:
		LocaleManager.set_locale("en" if OS.get_cmdline_user_args().has("--invite-en") else "zh")
		main=MainProbe.new()
		add_child(main)
		NetworkService.seat_card_provider=func():return card
		multiplayer.connected_to_server.connect(func(): register.rpc_id(1))
		peer.create_client("127.0.0.1",PORT)
	multiplayer.multiplayer_peer=peer
	await get_tree().create_timer(28).timeout
	if not done:
		print("INVITE_TRANSPORT TIMEOUT step=",step)
		get_tree().quit(2)
@rpc("any_peer","call_remote","reliable")
func register() -> void:
	if not server_role:return
	peer_id=multiplayer.get_remote_sender_id()
	prepare()
func prepare() -> void:
	NetworkService._rate_forget(peer_id)
	var current: Dictionary=NetworkService._room_for_peer(peer_id)
	if not current.is_empty():NetworkService._room_remove_peer(current,peer_id)
	NetworkService._spectate_detach(peer_id)
	old=NetworkService._new_room()
	NetworkService._rpc_settlement_room_switch.rpc_id(peer_id)
	if step<3:
		NetworkService._assign_peer_to_room(peer_id,old,"",Keys.card(ACCOUNT))
		old.ready[0]=true
		old.state_seq=1000
		NetworkService._broadcast_room_lobby(old)
	else:
		NetworkService._spectate_join(peer_id,int(old.id),Keys.sign(key,Keys.card(ACCOUNT)))
		old.state = "prep" if step==4 else ("result" if step==6 else "battle")
		NetworkService._broadcast_room_lobby(old)
	original=old.duplicate(true)
	target=NetworkService._new_room()
	target.slot_states[3]="player" # Authoritative host fixture; the joining client is independent.
	if step in [0,3]:NetworkService._rooms.erase(int(target.id))
	elif step==1:target.state="prep"
	elif step==4:
		target.slot_states=["dummy","dummy","dummy","player","dummy","dummy"]
		target[SS.KEY_OPEN]=false
	elif step==6:target.slot_states=["dummy","dummy","dummy","player","dummy","dummy"]
	begin.rpc_id(peer_id,step,int(old.id),int(target.id),Keys.sign(key,Keys.card(ACCOUNT)))
@rpc("authority","call_remote","reliable")
func begin(index: int,old_id: int,target_id: int,signed_card: String) -> void:
	step=index
	card=signed_card
	var before_nav:=main.navigation
	var before_menu:=main.menus
	var before_peer=multiplayer.multiplayer_peer
	var token:=NetworkService.session_token
	main._spectate_active=step>=3
	main._accept_room_invite(target_id)
	var deadline:=Time.get_ticks_msec()+12000
	while main._invited_room_joining and Time.get_ticks_msec()<deadline:
		await get_tree().create_timer(0.025).timeout
	var success:=step in [2,5,6]
	var valid:=not main._invited_room_joining and main.menus==before_menu and multiplayer.multiplayer_peer==before_peer
	if success:
		valid=valid and NetworkService.team_room_id==target_id and main.navigation==before_nav+1
		valid=valid and NetworkService.spectating==(step==6)
		if step==5:valid=valid and not main._spectate_active
	else:
		valid=valid and NetworkService.team_room_id==old_id and main.navigation==before_nav and NetworkService.session_token==token
		valid=valid and NetworkService.spectating==(step>=3)
		if step<3:valid=valid and bool(NetworkService.team_ready[NetworkService.team_local_slot])
	report.rpc_id(1,valid,NetworkService.team_room_id,NetworkService.spectating)
@rpc("any_peer","call_remote","reliable")
func report(client_ok: bool,room_id: int,observer: bool) -> void:
	if not server_role:return
	var success:=step in [2,5,6]
	var valid:=client_ok
	if success:
		valid=valid and int(room_id)==int(target.id)
		valid=valid and not (old.peer_slot as Dictionary).has(peer_id) and SS.sid_of_peer(old,peer_id)<0
		if observer:valid=valid and int(NetworkService._peer_spectate.get(peer_id,0))==int(target.id) and not NetworkService._peer_room.has(peer_id)
		else:valid=valid and int(NetworkService._peer_room.get(peer_id,0))==int(target.id) and not NetworkService._peer_spectate.has(peer_id)
	else:
		valid=valid and old==original
		valid=valid and (int(NetworkService._peer_spectate.get(peer_id,0))==int(old.id) if observer else int(NetworkService._peer_room.get(peer_id,0))==int(old.id))
	reports.append({"step":step,"ok":valid,"client_ok":client_ok,"observer":observer})
	print("INVITE_TRANSPORT_CASE ",JSON.stringify(reports.back()))
	if not valid:
		finish.rpc_id(peer_id,false)
		done=true
		await get_tree().create_timer(0.3).timeout
		get_tree().quit(1)
		return
	step+=1
	if step<7:
		prepare()
		return
	print("INVITE_TRANSPORT_RESULT PASS cases=",reports.size()," actual_auth=true actual_signed_cards=true")
	finish.rpc_id(peer_id,true)
	done=true
	await get_tree().create_timer(0.3).timeout
	get_tree().quit()
@rpc("authority","call_remote","reliable")
func finish(ok: bool) -> void:
	done=true
	print("INVITE_TRANSPORT_CLIENT ","PASS" if ok else "FAIL")
	get_tree().quit(0 if ok else 1)
