extends Node
const PORT := 19937
const TOKEN := "EXIT-TRANSPORT-1027"
func _ready() -> void:
 NetworkService.set_process(false)
 if "--exit-server" in OS.get_cmdline_user_args():
  await _server()
 else:
  await _client()
func _server() -> void:
 var peer := ENetMultiplayerPeer.new()
 if peer.create_server(PORT) != OK:
  get_tree().quit(2)
  return
 NetworkService.team_active=true
 NetworkService.is_host=true
 NetworkService._dedicated_server=true
 NetworkService.state=NetworkService.SessionState.READY
 var room := {"id":1,"state":"prep","run_over":false,"peer_slot":{999:5},"seat_tokens":{0:TOKEN,5:"OTHER-TOKEN"},"seat_pid":{0:"account-under-test"},"state_started_at":NetworkService._now()}
 NetworkService._rooms={1:room}
 NetworkService._token_seat={TOKEN:{"room_id":1,"slot":0},"OTHER-TOKEN":{"room_id":1,"slot":5}}
 multiplayer.peer_connected.connect(func(id:int): room.peer_slot[id]=0)
 multiplayer.multiplayer_peer=peer
 var deadline := Time.get_ticks_msec()+8000
 while not bool(room.get("manual_exit_slots",{}).get(0,false)) and Time.get_ticks_msec()<deadline:
  await get_tree().create_timer(0.02).timeout
 var ok: bool = bool(room.get("manual_exit_slots",{}).get(0,false)) and not NetworkService._token_seat.has(TOKEN) and str(room.seat_pid.get(0,""))=="account-under-test"
 await get_tree().create_timer(2.0).timeout
 print("EXIT_TRANSPORT_SERVER_RESULT ","PASS" if ok else "FAIL", " credentials_revoked=",not NetworkService._token_seat.has(TOKEN)," identity_preserved=",str(room.seat_pid.get(0,""))=="account-under-test")
 get_tree().quit(0 if ok else 1)
func _client() -> void:
 SaveManager.clear_reconnect()
 await _connect_fixture()
 SaveManager.save_reconnect(TOKEN,"127.0.0.1",PORT,"ranked")
 SaveManager.mark_match_started()
 var active := await NetworkService.check_saved_match()
 NetworkService.session_token=TOKEN
 await NetworkService.abandon_started_match()
 await get_tree().create_timer(0.3).timeout
 await _connect_fixture()
 var gone := await NetworkService.check_saved_match()
 var cleared := SaveManager.load_reconnect().is_empty()
 var ok := active=="active" and gone=="clear" and cleared
 print("EXIT_TRANSPORT_CLIENT_RESULT ","PASS" if ok else "FAIL"," active=",active," after_exit=",gone," local_credentials_cleared=",cleared)
 NetworkService.reset()
 get_tree().quit(0 if ok else 1)

# This loopback fixture tests RPC delivery; deployment DTLS certificates are unrelated.
func _connect_fixture() -> void:
 var peer := ENetMultiplayerPeer.new()
 NetworkService.remote_address="127.0.0.1"
 NetworkService.remote_port=PORT
 NetworkService.team_active=true
 NetworkService.is_host=false
 NetworkService.state=NetworkService.SessionState.JOINING
 peer.create_client("127.0.0.1",PORT)
 NetworkService._peer=peer
 multiplayer.multiplayer_peer=peer
 var deadline := Time.get_ticks_msec()+5000
 while NetworkService.state==NetworkService.SessionState.JOINING and Time.get_ticks_msec()<deadline:
  await get_tree().create_timer(0.05).timeout
