extends Node
const Peer := preload("res://tools/void_match_report_1027_peer.gd")
const DIR := "user://void_match_report_1027/"
const Harness := preload("res://tools/CheckHarness.gd")
var h := Harness.new("void_match_report_1027")
var server: Node
var client: Node
var results: Array = []
func endpoint(label: String, peer: ENetMultiplayerPeer) -> Node:
 var branch := Node.new()
 branch.name=label
 add_child(branch)
 var api := SceneMultiplayer.new()
 get_tree().set_multiplayer(api,branch.get_path())
 api.multiplayer_peer=peer
 api.server_relay=false
 var node := Peer.new()
 node.name="Network"
 branch.add_child(node)
 return node
func _ready() -> void:
 DirAccess.make_dir_recursive_absolute(DIR)
 NetworkService.set_process(false)
 Engine.max_fps=120
 var transport := ENetMultiplayerPeer.new()
 transport.create_server(0,8)
 server=endpoint("Server",transport)
 server.enter_test_server_mode()
 server.key=Crypto.new().generate_rsa(2048)
 var f := FileAccess.open(DIR+"test_public.pem",FileAccess.WRITE)
 f.store_string(server.key.save_to_string(true))
 f.close()
 var remote := ENetMultiplayerPeer.new()
 remote.create_client("127.0.0.1",transport.host.get_local_port())
 client=endpoint("Client",remote)
 var deadline := Time.get_ticks_msec()+5000
 while server.multiplayer.get_peers().is_empty() and Time.get_ticks_msec()<deadline:
  await get_tree().process_frame
 if server.multiplayer.get_peers().is_empty():
  print("XP_PROBE_FAILED no transport")
  get_tree().quit(2)
  return
 var pid: int=client.multiplayer.get_unique_id()
 var index := 0
 var specs := [{"name":"manual_before_disconnect_round1","round":1,"disconnect":false},{"name":"manual_after_disconnect_round1","round":1,"disconnect":true},{"name":"manual_before_disconnect_round14","round":14,"disconnect":false},{"name":"manual_after_disconnect_round14","round":14,"disconnect":true}]
 for n in range(5):
  specs.append({"name":"repeat_short_manual_%d" % n,"round":1,"disconnect":false})
 for spec: Dictionary in specs:
  index+=1
  var room: Dictionary=server._new_room()
  room.state=server.ROOM_PREP
  room.round_index=int(spec.round)
  room.initial_seats=["player","dummy","dummy","dummy","dummy","dummy"]
  room.slot_states=room.initial_seats.duplicate()
  room.peer_slot={pid:0}
  room.mode="ranked"
  room.ruleset="seedling" if int(spec.round)<=13 else "normal"
  room.ai_filled=true
  room.match_uid=("%032x" % index)
  room.match_started_wall=int(Time.get_unix_time_from_system())-5
  room.seat_pid={0:"00000000-0000-0000-0000-000000000001"}
  var token := "xp-probe-%d" % index
  room.seat_tokens={0:token}
  server._peer_room[pid]=int(room.id)
  server._token_seat[token]={"room_id":int(room.id),"slot":0}
  server._rate_forget(pid)
  h.expect(bool(server._room_report_ctx(room,1,2,50,50,{}).seats[0].online_at_end),"connected_before_exit","Live connected human is online before exit")
  var live_before: int=server._room_live_human_count(room)
  client._rpc_manual_exit_seat.rpc_id(1,token)
  deadline=Time.get_ticks_msec()+3000
  while not room.get("manual_exit_slots",{}).has(0) and Time.get_ticks_msec()<deadline:
   await get_tree().process_frame
  var marked: bool=room.get("manual_exit_slots",{}).has(0)
  if bool(spec.disconnect):
   server._room_reserve_peer(room,pid)
  var live_after: int=server._room_live_human_count(room)
  server._tick_void_watchdog()
  var raw: Dictionary=server.captured.duplicate(true)
  h.expect(marked,"manual_exit_rpc","Real authenticated exit RPC arrives")
  h.expect(live_before==1 and live_after==0 and bool(room.run_over),"void_terminal","Exit immediately ends the room with no live humans")
  h.expect(not bool(raw.seats[0].online),"exit_is_offline","A still-connected exit holder is not reported as online")
  h.expect(str(raw.get("end_reason",""))=="no_live_human" and str(raw.out)=="draw","signed_end_reason","Void draw carries its reason inside the report")
  h.expect(not server.signed_report.is_empty(),"report_signed","Report is signed for cross-language validation")
  results.append({"case":spec.name,"manual_exit_rpc_received":marked,"live_before":live_before,"live_after":live_after,"run_over":bool(room.get("run_over",false)),"end_reason":str(room.get("final_settlement",{}).get("end_reason","")),"report":raw,"signed_report":server.signed_report})
  server._rooms.erase(int(room.id))
  server._peer_room.erase(pid)
 var out := FileAccess.open(DIR+"battle_probe.json",FileAccess.WRITE)
 out.store_string(JSON.stringify(results,"  "))
 out.close()
 var ok := results.all(func(r): return r.manual_exit_rpc_received and r.run_over and r.live_after==0)
 print("XP_BATTLE_PROBE ","PASS" if ok else "FAIL"," cases=",results.size())
 for r: Dictionary in results:
  print("XP_CASE ",r.case," outcome=",r.report.get("out")," online=",r.report.get("seats",[{}])[0].get("online")," reason=",r.end_reason)
 client.multiplayer.multiplayer_peer.close()
 for i in 3:
  await get_tree().process_frame
 for branch in get_children():
  var api: MultiplayerAPI=branch.multiplayer
  if api.multiplayer_peer != null:
   api.multiplayer_peer.close()
   api.multiplayer_peer=null
  get_tree().set_multiplayer(null,branch.get_path())
  branch.queue_free()
 await get_tree().process_frame
 h.finish(get_tree())
