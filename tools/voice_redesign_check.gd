extends Node
const H = preload("res://tools/CheckHarness.gd")
const Voice = preload("res://scripts/autoload/VoiceService.gd")
const Fixtures = preload("res://tools/voice_check.gd")
const Settlement = preload("res://scripts/multiplayer/FinalSettlementData.gd")
const SettlementPanel = preload("res://scenes/menu/FinalSettlementPanel.gd")
const TouchScroll = preload("res://ui/components/TouchScrollContainer.gd")
var h = H.new("voice_redesign")
var clicks=0
class NetProbe extends "res://scripts/autoload/NetworkService.gd":
 var reconnect_reason=""
 func _ready():
  _reconnect_service.configure(_now,_net_log,{})
  _room_service.configure(_now,_wall_now,_net_log,func():return 0,{},_reconnect_service)
 func _process(_delta): pass
 func _begin_reconnect(reason): reconnect_reason=reason
 func _broadcast_room_lobby(_room): pass
 func _voice_seat_released(_room,_slot,_identity): pass
func frames():
 for i in 5: await get_tree().process_frame
func _ready():
 VoiceService.set_process(false)
 NetworkService.set_process(false)
 h.expect(Engine.has_singleton("GloryVoice"),"native_loaded","Windows extension loads")
 if Engine.has_singleton("GloryVoice"):
  var native=Engine.get_singleton("GloryVoice")
  for method in Voice.BRIDGE_METHODS:
   h.expect(native.has_method(method),"native_api",method)
 NetworkService.team_active=true
 NetworkService.team_local_slot=0
 NetworkService.team_room_id=90123
 var v=Voice.new()
 var fake=Fixtures.FakeBridge.new()
 v._bridge=fake
 v.token_requester=func():return true
 v._defaulted_room=90123
 h.expect(v.set_mode(Voice.Mode.LISTEN).is_empty(),"listen_request","listen starts")
 v._on_voice_token("wss://example.invalid","test","g90123-test-all","",0)
 fake.participants=["seat1"]
 h.expect(v.set_microphone_enabled(true).is_empty() and fake.mic_on,"mic_on","mic toggles on")
 v.set_speaker_enabled(false)
 h.expect(fake.mic_on and fake.volumes.get("seat1",-1)==0.0,"speaker_independent","mute output keeps mic on")
 v.set_microphone_enabled(false)
 h.expect(v.mode==Voice.Mode.OFF and not fake.mic_on,"both_off","both off leaves room")
 v.set_microphone_enabled(true)
 v._on_voice_token("wss://example.invalid","test","g90123-test-all","",0)
 v._apply_volumes()
 h.expect(fake.mic_on and not v.speaker_enabled and fake.volumes.get("seat1",-1)==0.0,"mic_without_speaker","mic alone never enables receiving")
 v.set_speaker_enabled(true)
 h.expect(fake.mic_on and fake.volumes.get("seat1",-1)==1.0,"speaker_restore","speaker resumes independently")
 v.set_microphone_enabled(false)
 h.expect(v.mode==Voice.Mode.LISTEN and not fake.mic_on and v.speaker_enabled,"listen_only","mic off preserves listening")
 fake.permission=false
 v.set_microphone_enabled(true)
 v.set_speaker_enabled(false)
 h.expect(v._want_talk_after_permission and not v.speaker_enabled,"pending_permission","speaker toggle preserves pending microphone request")
 fake.permission=true
 v._on_permission_result("microphone",true)
 h.expect(v.mode==Voice.Mode.TALK and fake.mic_on and not v.speaker_enabled,"permission_resume","permission grant enables only microphone")
 v.set_mode(Voice.Mode.OFF)
 v.free()
 var room={"slot_states":["player","dummy","dummy","player","dummy","dummy"]}
 var replay={"kind":"pvp","roster":{"a":{"team":"player","is_formation_ally":true,"name":"红队守护者"},"b":{"team":"enemy","is_formation_ally":true,"name":"蓝队守护者"}},"result":{"unit_stats":{"a":{"owner_slot":0,"damage_dealt":123},"b":{"owner_slot":3,"damage_dealt":456},"m":{"owner_slot":0,"damage_dealt":77,"is_mercenary":true}}}}
 var result=Settlement.build(room,[replay,replay],1,true)
 h.expect(result.allies==["红队守护者","蓝队守护者"],"guardians","canonical player/enemy sides map to A/B")
 h.expect(result.seats[0].round_damage==200 and result.seats[3].round_damage==456,"round_damage","unit plus mercenary damage summed once")
 h.expect(result.show_details,"pvp_details","PvP has details")
 h.expect(not Settlement.build(room,[{"kind":"pve"}],0,true).show_details,"pve_no_details","PvE has return actions only")
 var panel=SettlementPanel.new()
 panel.data={"allies":["",""]}
 h.expect(panel._team_title(0)=="红队" and panel._team_title(1)=="蓝队","empty_guardian","no empty parentheses")
 panel.free()
 var net=NetProbe.new()
 add_child(net)
 net.team_active=true
 net.is_host=false
 net.state=net.SessionState.READY
 net._mobile_was_paused=true
 net._resume_mobile_connection()
 h.expect(net._foreground_probe_deadline>0 and net._ping_accum==net.HEARTBEAT_INTERVAL_SEC,"foreground_probe","resume probes existing connection first")
 net._tick_foreground_probe(net._foreground_probe_deadline+0.1)
 h.expect(net.reconnect_reason=="foreground_probe_timeout","foreground_reconnect","half-open connection promptly reconnects")
 net.reconnect_reason=""
 net._mobile_was_paused=true
 net._resume_mobile_connection()
 net._rpc_pong()
 net._tick_foreground_probe(net._now()+10)
 h.expect(net.reconnect_reason.is_empty(),"healthy_resume","fresh pong keeps healthy connection")
 var lobby=net._new_room()
 lobby.peer_slot={11:0};lobby.slot_states[0]="player";lobby.seat_tokens={0:"test-token"}
 net._token_seat["test-token"]={"room_id":lobby.id,"slot":0}
 net._room_reserve_peer(lobby,11)
 h.expect(lobby.seat_tokens.has(0) and lobby.reserve_deadline[0]-net._now()>110,"lobby_reserve","unexpected lobby disconnect preserves credential for 120 seconds")
 net._room_auto_complete_seat(lobby,0)
 h.expect(lobby.slot_states[0]=="empty" and not lobby.seat_tokens.has(0),"lobby_expire","expired lobby reservation releases seat instead of adding AI")
 net.queue_free()
 var scroll=TouchScroll.new()
 scroll.position=Vector2(40,40);scroll.size=Vector2(320,160)
 add_child(scroll)
 var list=VBoxContainer.new()
 list.size_flags_horizontal=Control.SIZE_EXPAND_FILL
 scroll.add_child(list)
 for i in 15:
  var button=Button.new()
  button.text="可点击升级项%d"%i
  button.custom_minimum_size=Vector2(280,60)
  button.pressed.connect(func():clicks+=1)
  list.add_child(button)
 await frames()
 var touch=InputEventScreenTouch.new();touch.index=0;touch.pressed=true;touch.position=Vector2(100,160)
 get_viewport().push_input(touch, true)
 var drag=InputEventScreenDrag.new();drag.index=0;drag.position=Vector2(100,80);drag.relative=Vector2(0,-80)
 get_viewport().push_input(drag, true)
 touch=InputEventScreenTouch.new();touch.index=0;touch.pressed=false;touch.position=Vector2(100,80)
 get_viewport().push_input(touch, true)
 await frames()
 h.expect(scroll.scroll_vertical>=70,"touch_drag","vertical touch starting over a button scrolls content")
 h.expect(clicks==0,"drag_not_click","drag never activates upgrade action")
 scroll.queue_free()
 await frames()
 h.finish(get_tree())
