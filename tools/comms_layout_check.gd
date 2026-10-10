extends Node
const Lobby = preload("res://scenes/menu/Team3v3Lobby.tscn")
const Prep = preload("res://scenes/prep/PrepUI.gd")
const Harness = preload("res://tools/CheckHarness.gd")
class BattleFixture extends "res://scenes/battle/BattleScreen.gd":
 func _ready(): pass
 func _process(_delta): pass
var h = Harness.new("comms_layout")
func frames(n=5):
 for i in n: await get_tree().process_frame
func shot(name):
 if DisplayServer.get_name()=="headless": return
 await RenderingServer.frame_post_draw
 get_viewport().get_texture().get_image().save_png("res://work/issues_20260930/"+name+".png")
func buttons(vc, context):
 var list=[vc.voice_button,vc.audience_button,vc.members_button]
 # 10.11 第 5 条：自定义房间**不摆放** members_button（「全房间」那颗），它不会进树。
 # 布局判据只对真正显示出来的按钮成立，所以先把没进树的滤掉；
 # 调用方拿到的 bs 长度会随语境变化（房间 2 个、备战/战斗 3 个）。
 var shown=list.filter(func(b): return b!=null and is_instance_valid(b) and b.is_inside_tree())
 print("GEOMETRY ",context," ",list.map(func(b):return [b.name,b.is_inside_tree(),b.position,b.size,b.get_minimum_size()]))
 for b in shown:
  h.expect(b.size.is_equal_approx(shown[0].size),context+"_equal",str(b.size))
  h.expect(b.get_minimum_size().y<=b.size.y,context+"_text_fits",str(b.get_minimum_size()))
 var saved_mode=VoiceService.mode
 for mode in [VoiceService.Mode.OFF,VoiceService.Mode.LISTEN,VoiceService.Mode.TALK]:
  VoiceService.mode=mode
  vc.refresh()
  for b in shown:
   h.expect(b.size.is_equal_approx(shown[0].size) and b.get_minimum_size().y<=b.size.y,context+"_mode_size","voice mode changes keep equal size")
 VoiceService.mode=saved_mode
 vc.refresh()
 return shown
func scroll_checks(scroll,emit_message,tag):
 await frames()
 h.expect(not scroll.floating_bar.visible,tag+"_bottom_hidden","bottom hides bar")
 h.expect(scroll.get_v_scroll_bar().max_value>scroll.get_v_scroll_bar().page,tag+"_overflow","history must exceed visible area")
 var bottom=scroll.scroll_vertical
 var wheel=InputEventMouseButton.new()
 wheel.button_index=MOUSE_BUTTON_WHEEL_UP
 wheel.pressed=true
 wheel.factor=3.0
 wheel.position=scroll.get_global_rect().get_center()
 get_viewport().push_input(wheel)
 await frames()
 h.expect(scroll.scroll_vertical<bottom,tag+"_wheel","native wheel works while the native scrollbar is hidden")
 scroll.scroll_vertical=30
 await frames()
 h.expect(scroll.floating_bar.visible,tag+"_browsing_visible","scrolling history reveals bar")
 var before=scroll.scroll_vertical
 emit_message.call()
 await frames()
 h.expect(scroll.scroll_vertical==before,tag+"_no_jump","new message preserves reading position")
 scroll.floating_bar.value=60
 await frames()
 h.expect(scroll.scroll_vertical==60,tag+"_drag","floating thumb controls actual scroll")
 await shot(tag+"_history")
 scroll.scroll_vertical=int(scroll.get_v_scroll_bar().max_value)
 await frames()
 h.expect(not scroll.floating_bar.visible,tag+"_return_bottom","bar disappears at bottom")
 emit_message.call()
 await frames()
 h.expect(absf(scroll.get_v_scroll_bar().max_value-scroll.get_v_scroll_bar().page-scroll.scroll_vertical)<3,tag+"_follow","latest message followed only at bottom")
func _ready():
 DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://work/issues_20260930"))
 NetworkService.set_process(false)
 GameState.tutorial_mode=false
 NetworkService.team_active=false
 NetworkService.team_room_id=99001
 NetworkService.team_local_slot=0
 AccountManager.profile={"player_name":"测试玩家","friend_code":"TEST0001","avatar":""}
 var lobby=Lobby.instantiate()
 add_child(lobby)
 await frames(35)
 # 10.11 第 5 条：自定义房间不显示「全房间」那颗键 —— 整颗不进树（不是 visible=false 混过去）。
 h.expect(not lobby._voice_controls.members_button.is_inside_tree(),"lobby_full_room_hidden",
  "自定义房间不应把 VoiceControls.members_button（「全房间」）放进树")
 h.expect(lobby._voice_controls.voice_button.is_inside_tree()
  and lobby._voice_controls.audience_button.is_inside_tree(),"lobby_mic_speaker_kept",
  "隐藏的只能是「全房间」那一颗，麦克风 / 扬声器必须还在")
 for width in [1280,1600]:
  get_tree().root.content_scale_size=Vector2i(width,720)
  get_tree().root.size=Vector2i(width,720)
  await frames(10)
  lobby._layout()
  var bs=buttons(lobby._voice_controls,"lobby%d"%width)
  var prior=bs[0].size
  lobby._toggle_dummy(1)
  await frames()
  h.expect(bs[0].size.is_equal_approx(prior),"ai_size_stable","adding AI must not resize voice button")
  buttons(lobby._voice_controls,"lobby_ai")
 for i in 24: NetworkService.team_chat_text_received.emit(0,"第%d条：上翻查看历史消息，保留完整文字。"%i,false)
 await frames()
 await scroll_checks(lobby._record_scroll,func():NetworkService.team_chat_text_received.emit(0,"新消息不打断阅读",false),"lobby")
 await shot("lobby_latest")
 lobby.queue_free()
 await frames()
 NetworkService.team_active=true
 GameState.reset_run()
 GameState.tutorial_mode=false
 NetworkService.is_host=false
 NetworkService.server_phase=NetworkService.ROOM_PREP
 var full_prep="--full-prep" in OS.get_cmdline_user_args()
 var prep=load("res://scenes/prep/PrepScreen.tscn").instantiate() if full_prep else Prep.new()
 add_child(prep)
 prep.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
 if not full_prep: prep._build_chat_entry()
 await frames(60 if full_prep else 5)
 await frames()
 var bs=buttons(prep._voice_controls,"prep")
 var dock=prep._comms_dock.get_global_rect()
 for b in bs:
  h.expect(dock.encloses(b.get_global_rect()),"prep_in_dock","buttons fit inside dock")
 h.expect(prep._chat_record_page.get_theme_stylebox("panel") is StyleBoxEmpty,"transparent","no chat background")
 await scroll_checks(prep._chat_record_scroll,func():NetworkService.team_chat_text_received.emit(0,"备战新消息不打断阅读",true),"prep")
 await shot("prep_latest")
 prep._teardown_chat_entry()
 prep.queue_free()
 await frames()
 var battle=BattleFixture.new()
 add_child(battle)
 battle.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
 battle._setup_voice_controls()
 await frames()
 bs=buttons(battle._voice_controls,"battle")
 h.expect(is_equal_approx(bs[1].position.y-bs[0].get_rect().end.y,bs[2].position.y-bs[1].get_rect().end.y),"battle_equal_gaps","vertical spacing equal")
 await shot("battle_controls")
 battle.queue_free()
 await frames()
 h.finish(get_tree())
