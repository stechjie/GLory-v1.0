extends "res://tools/promo_capture.gd"
# 临时探针（用完删除）：带血之契约/剧毒爆发/富裕之路/炎焰碎裂/凤凰涅槃的 3v3 实时截图，
# 记录每个宝藏特效（VFXTreasureSkill3D / 序列帧毒爆）的屏幕坐标。
const COMBO := ["elem_flame_shatter", "def_lifesteal_emblem", "atk_burst_core", "elem_toxic_spread", "money_compound", "elem_thunder_haste"]
const FIRE_PHOENIX := ["elem_flame_shatter", "atk_wail_resonance", "def_soul_counter"]
const PER_BOARD := [COMBO, FIRE_PHOENIX, FIRE_PHOENIX, COMBO, COMBO, FIRE_PHOENIX]
var _sub_calls := 0
var _shot_dir := ""
var _last_shot_msec := 0
var _shot_index := 0
var _t0 := -1
var _tracked := {}

func total_frames() -> int:
	return 1000000

func _submission_for(unit_ids: Array) -> Dictionary:
	var owned: Array = _game_state.get("owned_treasures")
	owned.clear()
	for tid in (PER_BOARD[_sub_calls % PER_BOARD.size()] as Array):
		owned.append(str(tid))
	_sub_calls += 1
	return super._submission_for(unit_ids)

func _screen_of(p: Vector3) -> Vector2:
	var cam = _screen.get("_battle_3d_camera")
	var vp := (cam as Camera3D).get_viewport()
	return (cam as Camera3D).unproject_position(p) * Vector2(root.get_viewport().get_visible_rect().size) / Vector2(vp.get_visible_rect().size)

func _process(delta: float) -> bool:
	var done := super._process(delta)
	if _screen == null or not is_instance_valid(_screen) or _start_frame < 0:
		return done
	if _t0 < 0:
		_t0 = Time.get_ticks_msec()
		_shot_dir = _out_dir + "/shots"
		DirAccess.make_dir_recursive_absolute(_shot_dir)
	var root3d = _screen.get("_battle_3d_vfx_root")
	if root3d is Node:
		var pending: Array[Node] = [root3d]
		while not pending.is_empty():
			var n: Node = pending.pop_back()
			var id := n.get_instance_id()
			if n.has_method("play_treasure"):
				if not _tracked.has(id):
					_tracked[id] = {"skill": str((n.call("get_debug_state") as Dictionary).get("skill", "?")), "shot": _shot_index, "logged": false}
				var rec: Dictionary = _tracked[id]
				if not bool(rec["logged"]):
					for c in n.get_children():
						if c is GeometryInstance3D and (c as GeometryInstance3D).visible:
							var sp := _screen_of((c as Node3D).global_position)
							print("PROBE %s shot=%d screen=%d,%d" % [rec["skill"], int(rec["shot"]), int(sp.x), int(sp.y)])
							rec["logged"] = true
							break
				continue
			var sc = n.get_script()
			if sc != null and str(sc.resource_path).ends_with("VFXFlipbookSkill3D.gd") and not _tracked.has(id):
				var fx := n.get_node_or_null("OgaFormalSkill") as Node3D
				if fx != null:
					_tracked[id] = true
					var sp2 := _screen_of(fx.global_position)
					print("PROBE flipbook shot=%d screen=%d,%d" % [_shot_index, int(sp2.x), int(sp2.y)])
			pending.append_array(n.get_children())
	var now := Time.get_ticks_msec()
	if now - _last_shot_msec >= 70:
		_last_shot_msec = now
		root.get_viewport().get_texture().get_image().save_jpg("%s/s%04d.jpg" % [_shot_dir, _shot_index], 0.9)
		_shot_index += 1
	return done
