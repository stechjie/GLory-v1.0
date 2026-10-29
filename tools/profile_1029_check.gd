extends Node
const H=preload("res://tools/CheckHarness.gd")
const Sfx=preload("res://ui/services/SfxService.gd")
const Currency=preload("res://scripts/account/Currency.gd")
var h=H.new("profile_1029")
class Growth extends "res://scenes/menu/ProgressionPanel.gd":
	func _load() -> void:pass
class Profile extends "res://scenes/menu/ProfileScreen.gd":
	func _load() -> void:pass
	func _load_ranked() -> void:pass
	func _load_identities() -> void:pass
func _ready() -> void:
	call_deferred("run")
func mouse(v: Viewport,pos:Vector2,pressed:bool) -> void:
	var e=InputEventMouseButton.new();e.button_index=MOUSE_BUTTON_LEFT;e.position=pos;e.pressed=pressed;v.push_input(e,true)
func touch(v: Viewport,pos:Vector2,pressed:bool) -> void:
	var e=InputEventScreenTouch.new();e.index=0;e.position=pos;e.pressed=pressed;v.push_input(e,true)
func run() -> void:
	PlayerProfile.set_presentation_toggle("ui_sound",true)
	Sfx.install()
	await get_tree().process_frame
	await get_tree().process_frame
	for locale in ["zh","en"]:
		LocaleManager.set_locale(locale)
		for resolution in [Vector2i(1600,720),Vector2i(1280,720),Vector2i(960,540),Vector2i(1920,1080)]:
			var viewport=SubViewport.new();viewport.size=resolution;viewport.handle_input_locally=true;add_child(viewport)
			var g=Growth.new();viewport.add_child(g)
			g._show_state({"level":4,"xp":100,"next_xp":200,"rewards":[{"level":2,"units":[],"coin":300},{"level":3,"units":[],"diamond":100}]})
			for frame in 4:await get_tree().process_frame
			for raw in g._cards:
				var card:Button=g._cards[raw]
				var label:Label=card.get_child(0).get_child(card.get_child(0).get_child_count()-1)
				h.expect(label.get_global_rect().end.y<=card.get_global_rect().end.y-2,"status_inside_"+locale+str(resolution)+str(raw),"Earned/locked label must stay within its card")
			for entry in [[2,"coin"],[3,"diamond"]]:
				var holder:Control=g._cards[entry[0]].get_child(0).get_child(1)
				h.expect(holder.get_child(0) is TextureRect and holder.get_child(0).texture==Currency.icon(entry[1]),"currency_icon_"+entry[1]+locale+str(resolution),"Reward art reuses actual main-menu currency texture")
			var scroll=g._track_scroll
			scroll.scroll_horizontal=100
			var start:Vector2=scroll.get_global_rect().get_center()
			var selected:int=g._selected_level
			mouse(viewport,start,true)
			var move=InputEventMouseMotion.new();move.position=start-Vector2(100,0);move.relative=Vector2(-100,0);move.button_mask=MOUSE_BUTTON_MASK_LEFT;viewport.push_input(move,true)
			mouse(viewport,move.position,false)
			await get_tree().process_frame
			h.expect(scroll.scroll_horizontal>100,"mouse_drag_"+locale+str(resolution),"Actual mouse events scroll horizontally")
			h.expect(g._selected_level==selected,"no_drag_click_"+locale+str(resolution),"Dragging must not select a reward")
			scroll.scroll_horizontal=100
			touch(viewport,start,true)
			var drag=InputEventScreenDrag.new();drag.index=0;drag.position=start-Vector2(100,0);drag.relative=Vector2(-100,0);viewport.push_input(drag,true)
			touch(viewport,drag.position,false)
			await get_tree().process_frame
			h.expect(scroll.scroll_horizontal>100,"touch_drag_"+locale+str(resolution),"Actual touchscreen events scroll horizontally")
			viewport.queue_free();await get_tree().process_frame
		var p=Profile.new();p._data={"player_name":"Old name","friend_code":"AB123456","avatar":"preset:avatar_001","avatar_frame":"preset:frame_default","signature":"Old signature","gender":"male","region":"CN","birth_month":null,"birth_day":null};add_child(p);p._refresh()
		p._signature_edit.text="Unsaved signature"
		p._gender_pick.select(1)
		p._region_pick.select(0)
		p._birth_private.button_pressed=true
		var before:Dictionary=p._bio_payload()
		var updated:Dictionary=p._data.duplicate(true);updated.player_name="New name";updated.rename_available_at="2099-01-01T00:00:00Z"
		var count:int=Sfx.play_count(Sfx.CUE_PROFILE_SAVE)
		p._finish_submit({"code":200,"body":updated},true)
		h.expect(p._bio_payload()==before,"keep_all_drafts_"+locale,"Rename preserves signature, gender, birthday visibility and region draft")
		h.expect(p._name_edit.text=="New name" and p._name_label.text.contains("New name"),"rename_updated_"+locale,"Acknowledged nickname updates")
		h.expect(Sfx.play_count(Sfx.CUE_PROFILE_SAVE)==count+1,"success_cue_"+locale,"Successful confirmation plays one success cue")
		AccountManager._access_token=""
		count=Sfx.play_count(Sfx.CUE_PROFILE_SAVE)
		await p._save_bio(p._bio_payload())
		h.expect(Sfx.play_count(Sfx.CUE_PROFILE_SAVE)==count,"failed_bio_silent_"+locale,"A failed save must not play success")
		h.expect(p._bio_payload()==before,"failed_save_preserves_draft_"+locale,"A failed save keeps unsaved controls")
		p._name_edit.text="Another name"
		await p._on_rename_pressed()
		h.expect(Sfx.play_count(Sfx.CUE_PROFILE_SAVE)==count,"failed_rename_silent_"+locale,"A failed rename must not play success")
		h.expect(p._status.text==AccountManager.localized_error("尚未登录"),"localized_error_"+locale,"Failure uses localized feedback")
		p.queue_free();await get_tree().process_frame
	h.finish(get_tree())
