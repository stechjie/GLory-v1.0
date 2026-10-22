extends CanvasLayer
signal seat_selected(slot: int)
signal leave_requested
const Catalog=preload("res://scripts/account/AvatarCatalog.gd")
const Voice=preload("res://ui/components/VoiceControls.gd")
const Action=preload("res://ui/components/GloryActionButton.tscn")
var waiting:=true
var _root:Control
var _center:VBoxContainer
var _title:Label
var _teams:Array[Button]=[]
var _portraits:Array[TextureRect]=[]
var _names:Array[Label]=[]
var _observers:HBoxContainer
var _signature=""
var _voice:RefCounted
var _timer=0.0
func _ready():
	layer=60
	_root=Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter=Control.MOUSE_FILTER_IGNORE
	_root.theme=preload("res://ui/theme/GloryTheme.gd").get_theme()
	add_child(_root)
	var leave=Action.instantiate()
	leave.name="LeaveMatch"
	leave.text=_t("离开对局","Leave Match")
	leave.position=Vector2(20,16)
	leave.custom_minimum_size=Vector2(150,48)
	leave.pressed.connect(func():leave_requested.emit())
	_root.add_child(leave)
	_title=Label.new()
	_title.text=_t("等待玩家准备...","Waiting for the players to get ready...")
	_title.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER
	_title.anchor_left=.5
	_title.anchor_right=.5
	_title.offset_left=-360
	_title.offset_right=360
	_title.offset_top=24
	_title.add_theme_font_size_override("font_size",25)
	_root.add_child(_title)
	_center=VBoxContainer.new()
	_center.anchor_left=.5
	_center.anchor_right=.5
	_center.anchor_top=.5
	_center.anchor_bottom=.5
	_center.offset_left=-390
	_center.offset_right=390
	_center.offset_top=-145
	_center.add_theme_constant_override("separation",28)
	_root.add_child(_center)
	for team in 2:
		var row=HBoxContainer.new()
		row.alignment=BoxContainer.ALIGNMENT_CENTER
		row.add_theme_constant_override("separation",30)
		_center.add_child(row)
		var button=Action.instantiate() as Button
		button.name="WatchRed" if team==0 else "WatchBlue"
		button.custom_minimum_size=Vector2(190,68)
		button.modulate=Color(1,.65,.62) if team==0 else Color(.64,.8,1)
		button.pressed.connect(func():seat_selected.emit(0 if team==0 else 3))
		row.add_child(button)
		_teams.append(button)
		for index in 3:
			var box=VBoxContainer.new()
			box.custom_minimum_size=Vector2(110,0)
			row.add_child(box)
			var avatar=TextureRect.new()
			avatar.custom_minimum_size=Vector2(68,68)
			avatar.size_flags_horizontal=Control.SIZE_SHRINK_CENTER
			avatar.expand_mode=TextureRect.EXPAND_IGNORE_SIZE
			avatar.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			box.add_child(avatar)
			_portraits.append(avatar)
			var label=Label.new()
			label.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER
			label.custom_minimum_size=Vector2(110,28)
			label.text_overrun_behavior=TextServer.OVERRUN_TRIM_ELLIPSIS
			box.add_child(label)
			_names.append(label)
	var margin=CenterContainer.new()
	margin.anchor_left=0
	margin.anchor_right=1
	margin.anchor_top=1
	margin.anchor_bottom=1
	margin.offset_top=-118
	margin.offset_bottom=-12
	margin.mouse_filter=Control.MOUSE_FILTER_IGNORE
	_root.add_child(margin)
	_observers=HBoxContainer.new()
	_observers.add_theme_constant_override("separation",12)
	margin.add_child(_observers)
	_voice=Voice.new()
	_voice.build(_root,Vector2(120,56),Vector2(120,56),14,{"panel_context":"battle"})
	var y=100
	for b in [_voice.voice_button,_voice.audience_button]:
		_root.add_child(b)
		b.anchor_left=1
		b.anchor_right=1
		b.offset_left=-132
		b.offset_right=-12
		b.offset_top=y
		b.offset_bottom=y+56
		y+=64
	_root.add_child(_voice.members_button)
	_voice.members_button.hide()
	refresh()
func _exit_tree():
	if _voice!=null:_voice.teardown()
func _process(delta):
	_timer+=delta
	if _timer<.15:return
	_timer=0
	refresh()
func refresh(state:Dictionary=NetworkService.spectate_state,selected:int=NetworkService.spectate_view_slot):
	if _root==null:return
	_center.visible=waiting
	_title.visible=waiting
	var profiles:Dictionary=state.get("seat_profiles",{})
	for i in 6:
		var profile:Dictionary=profiles.get(i,profiles.get(str(i),{}))
		_portraits[i].texture=Catalog.texture_for(str(profile.get("avatar",Catalog.default_avatar())),true)
		var states:Array=state.get("slot_states",[])
		_names[i].text=str(profile.get("player_name","AI" if i<states.size() and states[i]=="dummy" else "—"))
	for team in 2:
		var chosen=GameConstants.team_of_slot(selected)==GameConstants.team_of_slot(team*3)
		_teams[team].text=_t("观看中","Watching") if chosen else (_t("观看红队","Watch Red Team") if team==0 else _t("观看蓝队","Watch Blue Team"))
		_teams[team].disabled=str(state.get("phase",""))!="prep" or bool(state.get("replay_pending",false))
	var list:Array=state.get("spectators",[])
	var signature=JSON.stringify(list)
	if signature!=_signature:
		_signature=signature
		for c in _observers.get_children():
			_observers.remove_child(c)
			c.queue_free()
		var caption=Label.new()
		caption.text=_t("观战者：","Spectators:")
		_observers.add_child(caption)
		for entry in list:
			var column=VBoxContainer.new()
			column.custom_minimum_size=Vector2(72,0)
			_observers.add_child(column)
			var image=TextureRect.new()
			image.name="Portrait"
			image.custom_minimum_size=Vector2(52,52)
			image.size_flags_horizontal=Control.SIZE_SHRINK_CENTER
			image.expand_mode=TextureRect.EXPAND_IGNORE_SIZE
			image.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			var identity:Dictionary=entry.get("identity",{})
			image.texture=Catalog.texture_for(str(identity.get("avatar",Catalog.default_avatar())),true)
			column.add_child(image)
			Voice.attach_speaking_mic(image)
			column.set_meta("entry",entry)
			var name_label=Label.new()
			name_label.text=str(identity.get("player_name",_t("观战者","Spectator")))
			name_label.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER
			name_label.text_overrun_behavior=TextServer.OVERRUN_TRIM_ELLIPSIS
			name_label.custom_minimum_size=Vector2(72,24)
			column.add_child(name_label)
	for c in _observers.get_children():
		if c.has_meta("entry"):Voice.show_speaking_mic(c.get_node("Portrait"),VoiceService.spectator_speaking(c.get_meta("entry")))
func _t(zh:String,en:String)->String:return en if TranslationServer.get_locale().begins_with("en") else zh
