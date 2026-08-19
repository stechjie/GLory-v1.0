extends "res://scenes/battle/BattleArena.gd"

const StatusVFXController := preload("res://scenes/battle/StatusVFXController.gd")
const UnitActor3DScript := preload("res://effects/runtime/presentation/UnitActor3D.gd")
const UnitVisualResolverScript := preload("res://effects/runtime/presentation/UnitVisualResolver.gd")

# Per-frame visual caches: the separation pass is O(N) per unit over the living
# set, and several call sites ask for the same unit's position within one frame.
# Rebuilt at the top of every _refresh_visuals — never carried across frames.
var _frame_living_ids: PackedStringArray = PackedStringArray()
var _frame_living_pos: PackedVector2Array = PackedVector2Array()
# id -> fighter dict for this frame. Facing needs to resolve a target uid back
# to a unit; holding the references costs nothing and keeps the lookup O(1).
var _frame_fighter_by_id: Dictionary = {}
var _visual_pos_cache: Dictionary = {}
var _status_vfx_by_id: Dictionary = {}
# HpFill refs cached at node creation so the per-frame HP sync never walks the tree.
var _hp_fill_by_id: Dictionary = {}
var _top5_next_refresh_msec := 0
var _formation_allies_hidden_for_intro := false

func _fighter_display_name(f: Dictionary) -> String:
	if LocaleManager.get_locale() == "en":
		var d: Dictionary = f.get("def", {})
		var en := str(f.get("name_en", d.get("name_en", "")))
		if not en.is_empty():
			return en
		return _english_name_from_id(str(f.get("id", d.get("id", ""))))
	return str(f.get("name", str(f.get("id", "?"))))

func _english_name_from_id(id: String) -> String:
	for prefix in ["pve_", "boss_", "merc_"]:
		if id.begins_with(prefix):
			id = id.substr(prefix.length())
	for element in ["land_", "sky_", "water_", "fire_", "ren_"]:
		if id.begins_with(element):
			id = id.substr(element.length())
	var words := id.split("_", false)
	for i in words.size():
		var w := str(words[i])
		words[i] = w.substr(0, 1).to_upper() + w.substr(1)
	return " ".join(words) if not words.is_empty() else "Unit"

func _refresh_visuals() -> void:
	var facing_delta := _model_facing_delta()
	# Compute the living set ONCE per frame and reuse it everywhere.
	var living := BattleSim.living_units(_state)
	_begin_visual_frame(living)
	var living_ids := {}
	var player_alive := 0
	var enemy_alive := 0
	for f in living:
		living_ids[_visual_id(f)] = true
		if str(f.get("team", "")) == "player":
			player_alive += 1
		else:
			enemy_alive += 1
	if not _selected_battle_unit_id.is_empty() and not living_ids.has(_selected_battle_unit_id):
		_selected_battle_unit_id = ""
	_sync_unit_nodes(_state.get("player", []), living_ids)
	_sync_unit_nodes(_state.get("enemy", []), living_ids)
	_sync_3d_model_nodes(living, facing_delta)
	# These HUD labels are hidden — only rebuild their text if actually shown.
	if _battle_state_lbl != null and _battle_state_lbl.visible:
		_battle_state_lbl.text = tr("battle_state") % [player_alive, enemy_alive, float(_state.get("elapsed", 0.0)), tr("battle_ended_suffix") if _finished else ""]
	# Per-unit: only the things that actually change each frame (position + HP fill).
	for f in living:
		var node: Control = _unit_nodes.get(_visual_id(f))
		if node == null:
			continue
		_position_unit_node(node, f)
		var hp_bar: ColorRect = _hp_fill_by_id.get(_visual_id(f))
		if hp_bar != null and is_instance_valid(hp_bar):
			hp_bar.scale.x = clampf(float(f.hp) / float(maxi(1, f.max_hp)), 0.0, 1.0)
	_update_3v3_dividers()
	_sync_battle_readability_static_geometry()
	_update_battle_readability_focus()
	_refresh_top5_atk(living)
	if _summary_lbl != null and _summary_lbl.visible:
		_refresh_summary()

# (8) Left-middle leaderboard: top 5 living units by ATK, colored by owner/team,
# with the damage each has dealt so far.
func _refresh_top5_atk(living: Array) -> void:
	if _top5_atk_lbl == null:
		return
	# Rebuilding BBCode text re-parses the whole label; 4x/sec is plenty.
	var now := Time.get_ticks_msec()
	if now < _top5_next_refresh_msec:
		return
	_top5_next_refresh_msec = now + 250
	var ranked := living.duplicate()
	ranked.sort_custom(func(a, b): return _fighter_atk(a) > _fighter_atk(b))
	var en := LocaleManager.get_locale() == "en"
	var lines: Array[String] = []
	lines.append("[b]%s[/b]" % tr("top_atk"))
	var shown := mini(5, ranked.size())
	for i in shown:
		var f: Dictionary = ranked[i]
		var col := _fighter_display_color(f)
		var name_txt := _fighter_display_name(f)
		if en:
			name_txt = name_txt.substr(0, 10)
		else:
			name_txt = name_txt.substr(0, 5)
		lines.append("[color=#%s]%s  %s %d  %s %d[/color]" % [
			col.to_html(false),
			name_txt,
			tr("abbr_atk"), _fighter_atk(f),
			tr("abbr_dmg"), _fighter_damage_dealt(f),
		])
	var text := "\n".join(lines)
	# Assigning identical text still re-parses the BBCode — skip it.
	if _top5_atk_lbl.text != text:
		_top5_atk_lbl.text = text

func _fighter_atk(f: Dictionary) -> int:
	return int(f.get("atk", f.get("def", {}).get("atk", 0)))

func _fighter_damage_dealt(f: Dictionary) -> int:
	# Replay frames carry per-unit damage directly; the live sim keeps it in unit_stats.
	if f.has("damage_dealt"):
		return int(f.get("damage_dealt", 0))
	var stats: Dictionary = _state.get("unit_stats", {})
	var entry: Dictionary = stats.get(str(f.get("uid", "")), {})
	return int(entry.get("damage_dealt", 0))

func _fighter_display_color(f: Dictionary) -> Color:
	var owner_slot := int(f.get("owner_slot", -1))
	var fid := str(f.get("id", ""))
	if fid.is_empty():
		fid = str(f.get("def", {}).get("id", ""))
	var is_boss := bool(f.get("def", {}).get("is_boss", false)) or fid.begins_with("boss_")
	var is_monster := fid.begins_with("pve_")
	if is_boss:
		return Color(0.90, 0.45, 0.95)
	if is_monster:
		return Color(0.72, 0.76, 0.84)
	if owner_slot >= 0:
		return GameConstants.team_slot_color(owner_slot)
	return Color(0.35, 0.85, 1.0) if _display_team(f) == "player" else Color(1.0, 0.42, 0.30)

func _position_unit_node(node: Control, f: Dictionary) -> void:
	var visual_pos := _visual_sim_pos_for_fighter(f)
	var world_pos := _sim_to_world_pos(visual_pos)
	var mapped := _world_to_arena(Vector3(world_pos.x, battle_unit_y_offset, world_pos.z))
	node.position = mapped - UNIT_VISUAL_OFFSET
	# Units lower on the arena should visually stand in front of units behind them.
	node.z_index = int(round(mapped.y))

func _sync_unit_nodes(fighters: Array, living_ids: Dictionary) -> void:
	for f in fighters:
		var id := _visual_id(f)
		if _unit_nodes.has(id):
			continue
		var node := _make_unit_node(f)
		_position_unit_node(node, f)
		_unit_nodes[id] = node
		_hp_fill_by_id[id] = node.get_node("HpFill")
		_arena.add_child(node)
		_apply_formation_intro_visibility(id, f)
	# O(N) cleanup: drop nodes whose unit is no longer alive (set lookup).
	for key in _unit_nodes.keys():
		if not living_ids.has(key):
			var n: Node = _unit_nodes[key]
			n.queue_free()
			_unit_nodes.erase(key)
			_hp_fill_by_id.erase(key)

func _hp_color_for_team(team: String) -> Color:
	return Color(1.0, 0.18, 0.12) if team == "enemy" else Color(0.2, 0.9, 0.25)

# (4) Team color from the VIEWER's point of view: the local player's own units keep
# the friendly color and the opponent stays red, even when the arena is flipped.
# 观战敌方战场时同样反转：敌队 replay 里 "player" 侧是敌方棋子（显示红色），
# "enemy" 侧是他们打的怪（显示绿色）。_arena_flip_y 只在 PVP、_watching_rival
# 只在 PVE/Boss 出现，两者不会同时为真。
func _display_team(f: Dictionary) -> String:
	var t := str(f.get("team", ""))
	if _arena_flip_y or _watching_rival:
		return "player" if t == "enemy" else "enemy"
	return t

func _make_unit_node(f: Dictionary) -> Control:
	var root := Control.new()
	var visual_id := _visual_id(f)
	root.name = "UnitHit_%s" % visual_id.validate_node_name()
	root.custom_minimum_size = UNIT_VISUAL_SIZE
	root.size = UNIT_VISUAL_SIZE
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	root.focus_mode = Control.FOCUS_NONE
	root.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	root.tooltip_text = _fighter_display_name(f)
	root.gui_input.connect(_on_battle_unit_gui_input.bind(visual_id))
	# Prevent the parent layout from touching this node
	root.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_add_unit_anchors(root)
	_add_unit_shadow(root)
	var hp_bg := ColorRect.new()
	hp_bg.name = "HpBg"
	hp_bg.color = Color(0.05, 0.05, 0.05)
	hp_bg.position = Vector2(5, 8)
	hp_bg.size = Vector2(72, 9)
	hp_bg.z_index = 20
	hp_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(hp_bg)
	var hp := ColorRect.new()
	hp.name = "HpFill"
	hp.color = _hp_color_for_team(_display_team(f))
	hp.position = Vector2(8, 11)
	hp.size = Vector2(66, 4)
	hp.z_index = 21
	hp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(hp)
	var label := Label.new()
	label.name = "Name"
	label.position = Vector2(0, 86)
	label.size = Vector2(82, 28)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 9)
	label.add_theme_color_override("font_color", Color(0.94, 0.98, 1.0))
	label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.92))
	label.add_theme_constant_override("outline_size", 3)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Names don't change mid-battle: set once here instead of every frame.
	var dn := _fighter_display_name(f)
	label.text = dn.substr(0, 8) if LocaleManager.get_locale() == "en" else dn.substr(0, 4)
	root.add_child(label)
	return root


func _on_battle_unit_gui_input(event: InputEvent, unit_id: String) -> void:
	var pressed := false
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		pressed = mouse_event.button_index == MOUSE_BUTTON_LEFT and mouse_event.pressed
	elif event is InputEventScreenTouch:
		pressed = (event as InputEventScreenTouch).pressed
	if not pressed:
		return
	_selected_battle_unit_id = "" if _selected_battle_unit_id == unit_id else unit_id
	_update_battle_readability_focus()
	accept_event()


func _update_battle_readability_focus() -> void:
	if _board_readability_layer == null or not is_instance_valid(_board_readability_layer):
		return
	_board_readability_layer.set_guides_enabled(PlayerProfile.board_readability_enabled)
	_board_readability_layer.set_low_quality(VFXManager.get_quality_tier() == VFXQualityBudget.Tier.LOW)
	if _selected_battle_unit_id.is_empty():
		_board_readability_layer.clear_battle_focus()
		return
	var fighter_value = _frame_fighter_by_id.get(_selected_battle_unit_id)
	if typeof(fighter_value) != TYPE_DICTIONARY:
		_board_readability_layer.clear_battle_focus()
		return
	var fighter: Dictionary = fighter_value
	var source_sim := _visual_sim_pos_for_fighter(fighter)
	var source := _battle_focus_screen_point(source_sim)
	var range_polygon := PackedVector2Array()
	var attack_range := maxf(1.0, float(fighter.get("range_px", BattleSimShared.ATTACK_RANGE_SCALE)))
	for segment in 40:
		var angle := TAU * float(segment) / 40.0
		range_polygon.append(_battle_focus_screen_point(source_sim + Vector2(cos(angle), sin(angle)) * attack_range))
	var target_id := str(fighter.get("vfx_skill_target_uid", ""))
	if target_id.is_empty():
		target_id = str(fighter.get("vfx_attack_target_uid", ""))
	var target := Vector2.ZERO
	var has_target := false
	var target_value = _frame_fighter_by_id.get(target_id)
	if typeof(target_value) == TYPE_DICTIONARY:
		target = _battle_focus_screen_point(_visual_sim_pos_for_fighter(target_value as Dictionary))
		has_target = true
	var focus_color := _actor_team_color(fighter)
	focus_color.a = 1.0
	_board_readability_layer.set_battle_focus(
		_selected_battle_unit_id,
		source,
		range_polygon,
		target,
		has_target,
		focus_color
	)


func _battle_focus_screen_point(sim_pos: Vector2) -> Vector2:
	var world_pos := _sim_to_world_pos(sim_pos)
	return _world_to_arena(Vector3(world_pos.x, battle_unit_y_offset, world_pos.z))

func _add_unit_anchors(root: Control) -> void:
	var anchors := {
		"FootAnchor": Vector2(41, 70),
		"CastAnchor": Vector2(41, 42),
		"HitAnchor": Vector2(41, 48),
		"HeadAnchor": Vector2(41, 14),
	}
	for anchor_name: String in anchors.keys():
		var marker := Marker2D.new()
		marker.name = anchor_name
		marker.position = anchors[anchor_name]
		marker.visible = false
		root.add_child(marker)

func _add_unit_shadow(root: Control) -> void:
	var shadow := Polygon2D.new()
	shadow.name = "GroundShadow"
	shadow.color = Color(0.0, 0.0, 0.0, 0.48)
	shadow.position = Vector2(41, 70)
	shadow.z_index = -1
	var points: PackedVector2Array = []
	for i in 24:
		var angle := TAU * float(i) / 24.0
		points.append(Vector2(cos(angle) * 34.0, sin(angle) * 10.0))
	shadow.polygon = points
	root.add_child(shadow)

# prune=false：只建不删。分帧建造（_prepare_battle_models）一次只喂一个单位进来，
# 若照常执行收尾的清理，每建一个就会把前面建好的全部 queue_free —— 最后只剩一个。
func _sync_3d_model_nodes(living: Array, facing_delta: float, prune := true) -> void:
	if _battle_3d_root == null:
		return
	var seen := {}
	for f in living:
		if typeof(f) != TYPE_DICTIONARY:
			continue
		var id := _visual_id(f)
		seen[id] = true
		var model_node: Node3D = _battle_3d_models.get(id)
		if model_node == null:
			model_node = _make_shared_model_node(f)
			if model_node == null:
				continue
			_battle_3d_models[id] = model_node
			_battle_3d_root.add_child(model_node)
			if not _unit_actor_registry.register_actor(id, model_node):
				UnitVisualResolverScript.report_failure(str(f.get("id", id)), str(f.get("def", {}).get("model", "")), "battle", "actor contract registration failed")
		_position_3d_model_node(model_node, f, facing_delta)
		_apply_formation_intro_visibility(id, f)
		_update_model_animation_state(model_node, f)
		var status_vfx: Node = _status_vfx_by_id.get(id)
		if status_vfx == null or not is_instance_valid(status_vfx):
			status_vfx = _ensure_status_vfx_controller(model_node)
			_status_vfx_by_id[id] = status_vfx
		status_vfx.update_from_fighter(f)
	if not prune:
		return
	for key in _battle_3d_models.keys():
		if not seen.has(key):
			var node: Node = _battle_3d_models[key]
			node.queue_free()
			_battle_3d_models.erase(key)
			_unit_actor_registry.unregister_actor(str(key))
			_status_vfx_by_id.erase(key)

# 和备战棋盘共用 BattleAssetService 的缓存 —— 备战期加载过的模型，进战斗直接命中。
func _scene_for_model_path(model_path: String) -> PackedScene:
	return BattleAssetService.get_scene(model_path)

func _make_shared_model_node(f: Dictionary) -> Node3D:
	var unit_def := _display_unit_def_for_fighter(f)
	# Every fighter that reaches the battlefield passes through here — allied and
	# enemy, piece, mercenary, monster, boss and formation ally — so this single
	# call covers the whole codex. mark_seen is a no-op after the first sighting.
	PlayerProfile.mark_seen(str(f.get("id", unit_def.get("id", ""))))
	var actor: Node3D = UnitActor3DScript.new()
	actor.name = "UnitActor_%s" % str(f.get("id", "unit"))
	var model_height := NOMINAL_UNIT_HEIGHT
	if int(unit_def.get("tier", 1)) == 3:
		model_height *= 1.12
	actor.configure_contract(model_height)
	actor.set_meta("unit_id", str(f.get("id", unit_def.get("id", ""))))
	actor.set_meta("resolved_visual", unit_def)
	var base_yaw := float(unit_def.get("model_base_yaw", 180.0))
	actor.set_meta("base_yaw", base_yaw)
	actor.rotation_degrees.y = _spawn_facing_yaw(f, base_yaw)
	var model_path := str(unit_def.get("model", ""))
	var scene := _scene_for_model_path(model_path) if _model_path_available(model_path) else null
	var instance = scene.instantiate() if scene != null else null
	if instance is Node3D:
		var model := instance as Node3D
		if model_path == "res://assets/models/units/dark_imp_motong/dark_imp_motong_attack_punching.fbx":
			cleanup_imported_model_visuals(model)
		var visual_scale := float(unit_def.get("model_visual_scale", 1.0)) * battle_unit_visual_scale
		if int(unit_def.get("tier", 1)) == 3:
			visual_scale *= 1.2
		model.scale = Vector3(visual_scale, visual_scale, visual_scale)
		model.rotation_degrees = Vector3.ZERO
		actor.attach_model(model)
		_center_model_for_full_body_view(model)
		_setup_model_animation_state(actor, model, unit_def, f)
	else:
		if instance is Node:
			(instance as Node).queue_free()
		var reason := "model scene unavailable" if scene == null else "model root is not Node3D"
		UnitVisualResolverScript.report_failure(str(unit_def.get("id", f.get("id", ""))), model_path, "battle", reason)
		var portrait_ok: bool = actor.attach_portrait_fallback(
			str(unit_def.get("portrait", "")),
			str(unit_def.get("fallback_frame", "")),
			_actor_team_color(f),
			model_height
		)
		if not portrait_ok:
			UnitVisualResolverScript.report_failure(str(unit_def.get("id", f.get("id", ""))), str(unit_def.get("portrait", "")), "battle", "portrait unavailable")
	# Anchors must be derived from the model that was just scaled, not hardcoded.
	# The pivot is unscaled while the model inside it is scaled to ~0.42, so a
	# fixed 0.85 "body" height sat 1.5x-3x above the head of every unit and every
	# projectile aimed at empty air. Measured with tools/measure_unit_anchors.gd.
	# Do NOT derive this from the mesh AABB. These are skinned models and their
	# stored AABB covers only part of the rig: measured against the rendered
	# silhouette it underestimates by 1.15x to 3.5x, inconsistently per model.
	# The rendered heights actually cluster tightly (0.71-1.08 world units over
	# ten sampled units, median ~0.95) because every unit shares the same visual
	# scale, so a nominal height is both simpler and more accurate than a bad
	# measurement. Re-measure with tools/vfx_capture.gd --unit <id> if the model
	# scale ever changes.
	_ensure_status_vfx_controller(actor, model_height)
	_add_3d_unit_readability(actor, f)
	return actor

# model_height is the rendered height of this unit in world units. Pass 0 when
# it is unknown (the late-repair path below) and the legacy 1.7 stand-in is used,
# which reproduces the old fixed anchor heights exactly.
# Measured from rendered silhouettes, not from mesh AABBs (see _build_3d_unit).
const NOMINAL_UNIT_HEIGHT := 0.98
const ANCHOR_HEAD_RATIO := 1.02   # just above the crown, where a status icon sits
const ANCHOR_BODY_RATIO := 0.55   # chest: what every projectile aims at
const ANCHOR_FEET_RATIO := 0.05
const ANCHOR_FALLBACK_HEIGHT := NOMINAL_UNIT_HEIGHT

func _ensure_status_vfx_controller(pivot: Node3D, model_height: float = 0.0) -> Node:
	var height := model_height if model_height > 0.05 else ANCHOR_FALLBACK_HEIGHT
	for anchor_name in ["HeadAnchor", "BodyAnchor", "FeetAnchor"]:
		if pivot.get_node_or_null(anchor_name) != null:
			continue
		var anchor := Node3D.new()
		anchor.name = anchor_name
		match anchor_name:
			"HeadAnchor":
				anchor.position = Vector3(0.0, height * ANCHOR_HEAD_RATIO, 0.0)
			"BodyAnchor":
				anchor.position = Vector3(0.0, height * ANCHOR_BODY_RATIO, -0.06)
			_:
				anchor.position = Vector3(0.0, height * ANCHOR_FEET_RATIO, 0.0)
		pivot.add_child(anchor)
	var controller := pivot.get_node_or_null("StatusVFXController")
	if controller == null:
		controller = StatusVFXController.new()
		controller.name = "StatusVFXController"
		pivot.add_child(controller)
	return controller

func cleanup_imported_model_visuals(root: Node) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if node is Light3D:
			var parent := node.get_parent()
			if parent != null:
				parent.remove_child(node)
			node.queue_free()
			continue
		if node is MeshInstance3D:
			_disable_mesh_emission(node as MeshInstance3D)

func _disable_mesh_emission(mesh_instance: MeshInstance3D) -> void:
	var override := mesh_instance.material_override
	if override != null:
		mesh_instance.material_override = _material_without_emission(override)
	var mesh := mesh_instance.mesh
	if mesh == null:
		return
	for surface in range(mesh.get_surface_count()):
		var material := mesh_instance.get_surface_override_material(surface)
		if material == null:
			material = mesh.surface_get_material(surface)
		if material != null:
			mesh_instance.set_surface_override_material(surface, _material_without_emission(material))

# 去自发光材质缓存：duplicate(true) 会触发着色器变体编译（手机上 50~200ms 顿挫），
# 同一份源材质整局只复制/编译一次。static：跨战斗场景复用。
static var _clean_material_cache: Dictionary = {}

func _material_without_emission(material: Material) -> Material:
	var key := material.resource_path
	if key.is_empty():
		key = str(material.get_rid())
	var cached: Material = _clean_material_cache.get(key)
	if cached != null:
		return cached
	# duplicate(false) 而不是 (true)：这里只要改 emission 两个属性，那是材质自身的
	# 字段。深拷贝会连子资源一起复制——**包括贴图**，等于同一张贴图在显存里存两份。
	# 实测 video 峰值 1206 MB / tex 峰值 889 MB，这条是其中一份重复。
	# 浅拷贝后贴图与原材质共享，改 emission 不会影响原材质。
	var clean := material.duplicate(false) as Material
	if clean is BaseMaterial3D:
		var base := clean as BaseMaterial3D
		base.emission_enabled = false
		base.emission_energy_multiplier = 0.0
	_clean_material_cache[key] = clean
	return clean
func _setup_model_animation_state(pivot: Node3D, model: Node3D, unit_def: Dictionary, f: Dictionary) -> void:
	if _supports_model_action_methods(model):
		pivot.set_meta("model_action_node_path", pivot.get_path_to(model))
		pivot.set_meta("current_model_action", "")
		_setup_animation_tracking_meta(pivot, unit_def, f)
		return
	var players := _find_animation_players(model)
	if players.is_empty():
		_setup_animation_tracking_meta(pivot, unit_def, f)
		return
	var player := _select_model_animation_player(players, unit_def)
	if player == null:
		_setup_animation_tracking_meta(pivot, unit_def, f)
		return
	var player_path := pivot.get_path_to(player)
	var attack_name := str(unit_def.get("model_attack_animation_name", ""))
	if attack_name.is_empty() or not player.has_animation(attack_name):
		attack_name = _first_animation_name(player)
	var idle_name := "idle"
	var idle_source_path := str(unit_def.get("model_idle_animation", ""))
	var idle_source_name := str(unit_def.get("model_idle_animation_name", ""))
	if not idle_source_path.is_empty():
		_add_animation_from_scene(player, idle_source_path, idle_source_name, idle_name, true)
	if not player.has_animation(idle_name):
		idle_name = attack_name
	if not idle_name.is_empty() and player.has_animation(idle_name):
		var idle_anim := player.get_animation(idle_name)
		if idle_anim != null:
			idle_anim.loop_mode = Animation.LOOP_LINEAR
		player.play(idle_name)
	if not attack_name.is_empty() and player.has_animation(attack_name):
		var attack_anim := player.get_animation(attack_name)
		if attack_anim != null and attack_name != idle_name:
			attack_anim.loop_mode = Animation.LOOP_NONE
	var run_name := str(unit_def.get("model_run_animation_name", ""))
	if run_name.is_empty():
		run_name = "run"
	if not player.has_animation(run_name):
		run_name = ""
	if not run_name.is_empty():
		var run_anim := player.get_animation(run_name)
		if run_anim != null:
			run_anim.loop_mode = Animation.LOOP_LINEAR
	pivot.set_meta("animation_player_path", player_path)
	pivot.set_meta("idle_animation", idle_name)
	pivot.set_meta("attack_animation", attack_name)
	pivot.set_meta("run_animation", run_name)
	_setup_animation_tracking_meta(pivot, unit_def, f)

func _setup_animation_tracking_meta(pivot: Node3D, unit_def: Dictionary, f: Dictionary) -> void:
	pivot.set_meta("last_animation_position", pivot.position)
	pivot.set_meta("last_visual_sim_pos", _visual_sim_pos_for_fighter(f))
	pivot.set_meta("attack_sync_seek", float(unit_def.get("model_attack_sync_seek", 0.0)))
	pivot.set_meta("attack_lock_time", float(unit_def.get("model_attack_lock_time", 0.45)))
	pivot.set_meta("attack_lock_left", 0.0)
	pivot.set_meta("attack_lock_until", 0.0)
	pivot.set_meta("run_lock_until", 0.0)
	pivot.set_meta("last_attack_count", int(f.get("attack_count", 0)))
	pivot.set_meta("last_next_attack", float(f.get("next_attack", 0.0)))
func _update_model_animation_state(model_node: Node3D, f: Dictionary) -> void:
	var has_action_methods := model_node.has_meta("model_action_node_path")
	var player: AnimationPlayer = null
	if model_node.has_meta("animation_player_path"):
		player = model_node.get_node_or_null(model_node.get_meta("animation_player_path")) as AnimationPlayer
	if player == null and not has_action_methods:
		return
	var idle_name := str(model_node.get_meta("idle_animation", ""))
	var attack_name := str(model_node.get_meta("attack_animation", ""))
	var run_name := str(model_node.get_meta("run_animation", ""))
	var visual_now := float(Time.get_ticks_msec()) * 0.001
	var current_sim_pos := _visual_sim_pos_for_fighter(f)
	var raw_last_sim_pos = model_node.get_meta("last_visual_sim_pos", current_sim_pos)
	var last_sim_pos := current_sim_pos
	if raw_last_sim_pos is Vector2:
		last_sim_pos = raw_last_sim_pos
	var moved := current_sim_pos.distance_to(last_sim_pos) > 1.0
	model_node.set_meta("last_visual_sim_pos", current_sim_pos)
	var attack_count := int(f.get("attack_count", 0))
	var last_attack_count := int(model_node.get_meta("last_attack_count", attack_count))
	var attack_triggered := attack_count > last_attack_count
	model_node.set_meta("last_attack_count", attack_count)
	model_node.set_meta("last_next_attack", float(f.get("next_attack", 0.0)))
	if attack_triggered:
		var played_attack := _play_model_action_method(model_node, "attack", true)
		if not played_attack and player != null and not attack_name.is_empty() and player.has_animation(attack_name):
			player.stop()
			player.play(attack_name)
			var sync_seek := float(model_node.get_meta("attack_sync_seek", 0.0))
			if sync_seek > 0.0:
				player.seek(sync_seek, true)
			player.advance(0.001)
		_play_model_attack_pulse(model_node)
		model_node.set_meta("attack_lock_until", visual_now + maxf(0.08, float(model_node.get_meta("attack_lock_time", 0.45))))
		model_node.set_meta("run_lock_until", 0.0)
		return
	if visual_now < float(model_node.get_meta("attack_lock_until", 0.0)):
		return
	if moved:
		model_node.set_meta("run_lock_until", visual_now + 0.18)
	var should_run := visual_now < float(model_node.get_meta("run_lock_until", 0.0))
	if should_run:
		if not _play_model_action_method(model_node, "run") and player != null and not run_name.is_empty() and player.has_animation(run_name):
			_play_animation_if_needed(player, run_name)
	elif not _play_model_action_method(model_node, "idle") and player != null and not idle_name.is_empty() and player.has_animation(idle_name):
		_play_animation_if_needed(player, idle_name)

func _play_model_attack_pulse(model_node: Node3D) -> void:
	if not model_node.is_inside_tree():
		return
	model_node.scale = Vector3(1.08, 1.08, 1.08)
	var tween := model_node.create_tween()
	tween.tween_property(model_node, "scale", Vector3.ONE, 0.16).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

func _play_animation_if_needed(player: AnimationPlayer, animation_name: String) -> void:
	if player.current_animation != animation_name or not player.is_playing():
		player.play(animation_name)

func _supports_model_action_methods(model: Node) -> bool:
	return model.has_method("play_idle") or model.has_method("play_attack") or model.has_method("play_run")

func _play_model_action_method(model_node: Node3D, action: String, force_restart := false) -> bool:
	if not model_node.has_meta("model_action_node_path"):
		return false
	var action_node := model_node.get_node_or_null(model_node.get_meta("model_action_node_path"))
	if action_node == null:
		return false
	var method_name := _model_action_method_name(action)
	if method_name.is_empty() or not action_node.has_method(method_name):
		return false
	if not force_restart and str(model_node.get_meta("current_model_action", "")) == action:
		return true
	action_node.call(method_name)
	model_node.set_meta("current_model_action", action)
	return true

func _model_action_method_name(action: String) -> String:
	match action:
		"idle":
			return "play_idle"
		"attack":
			return "play_attack"
		"run":
			return "play_run"
		_:
			return ""
func _add_animation_from_scene(player: AnimationPlayer, scene_path: String, source_name: String, target_name: String, should_loop: bool) -> void:
	if player.has_animation(target_name):
		return
	var source_scene := _animation_scene_for_path(scene_path)
	if source_scene == null:
		return
	var source_root := source_scene.instantiate()
	var source_players := _find_animation_players(source_root)
	for source_player in source_players:
		var anim_name := source_name
		if anim_name.is_empty() or not source_player.has_animation(anim_name):
			anim_name = _first_animation_name(source_player)
		if anim_name.is_empty() or not source_player.has_animation(anim_name):
			continue
		var anim := source_player.get_animation(anim_name).duplicate(true) as Animation
		if should_loop:
			anim.loop_mode = Animation.LOOP_LINEAR
		var library := player.get_animation_library("")
		if library == null:
			library = AnimationLibrary.new()
			player.add_animation_library("", library)
		library.add_animation(target_name, anim)
		break
	source_root.queue_free()

var _animation_prefetch_started: Dictionary = {}

# 开战预取：把本场阵容会用到的模型场景、待机动画场景、技能/弹道贴图
# 全部丢给后台线程加载，避免战斗中首次出场/首次施法时同步读盘顿挫。
func _prefetch_battle_assets() -> void:
	var texture_paths: Array = []
	# 玩家阵容整局都在，敌人每回合都换 —— 分开预取，好让回合结束只放后者。
	for f in _state.get("player", []):
		_prefetch_one_fighter(f, texture_paths, true)
	for f in _state.get("enemy", []):
		_prefetch_one_fighter(f, texture_paths, false)
	VFXManager.preload_textures(texture_paths)

func _prefetch_one_fighter(f: Dictionary, texture_paths: Array, persistent: bool) -> void:
	var unit_def := _display_unit_def_for_fighter(f)
	# 玩家阵容整局持有；本回合的怪 / Boss / 对手回合末释放。
	var owner := BattleAssetService.OWNER_PLAYER if persistent else BattleAssetService.OWNER_BATTLE
	var model_path := str(unit_def.get("model", ""))
	if _model_path_available(model_path):
		BattleAssetService.acquire(model_path, owner)
	var idle_path := str(unit_def.get("model_idle_animation", ""))
	if not idle_path.is_empty() and _model_path_available(idle_path):
		BattleAssetService.acquire(idle_path, owner)
	var unit_id := str(unit_def.get("id", f.get("id", "")))
	for tex_cfg in SkillVFXConfig.get_textures(unit_id):
		texture_paths.append(str(tex_cfg.get("path", "")))

# 回合结束调用：放掉本回合的怪 / Boss / PVP 对手，保留玩家阵容。
#
# 为什么需要：这几个缓存是 static（否则玩家自己的棋子每回合都要重新加载），
# 而 static 只增不减的话，一局里遇到过的每个敌人都会被永久钉在显存里 ——
# 实测 6 个回合 video 峰值从 688 MB 涨到 1206 MB，约 +90 MB/轮，
# 第 20 回合外推约 1.9 GB，而整机只有 3.9 GB。
#
# 材质缓存整份清掉：它的 key 是源材质路径，映射不回具体单位，没法分级。
# 清掉的代价只是下回合重新 duplicate(false)（浅拷贝，很便宜）；着色器变体由
# 引擎按 shader+变体缓存、不按材质实例，所以不会重新编译。
# 共享 Shader 缓存（VFXShaderCache）不动 —— 那个清了才会真的重新编译。
# 备战期调用：把接下来几个回合的敌方模型丢给后台线程。
#
# 为什么能提前知道：怪物 / Boss 的选择只依赖 shared_seed + 回合号
# （BattleSimShared._round_pick_index），开局那一刻整局名单就定了。
#
# 为什么不是"开局全载 20 轮"：实测每轮新内容约 +104 MB，20 轮外推 2.5 GB 以上，
# 而测试机（3.9 GB 整机）可用约 2 GB —— 那正是原本第 20 回合加载不出来的成因。
# 提前量取 3 轮是内存与保险的折中。
#
# 这里**只发请求、不收割**：Godot 会把加载好的资源留着，直到有人调
# load_threaded_get()。等开打时 _scene_for_model_path 走到状态检查那一步就是
# THREAD_LOAD_LOADED，直接取走，没有磁盘 I/O，也不需要备战期每帧轮询。
static func prefetch_upcoming_rounds(current_round: int) -> void:
	var by_round := BattleAssetManifest.rounds_enemy_paths(
		current_round + 1, BattleAssetManifest.LOOKAHEAD_ROUNDS)
	for n in by_round:
		BattleAssetService.acquire_many(by_round[n], BattleAssetService.owner_future(int(n)))

# 回合结束：摘掉 battle/current 这个 owner。
#
# 关键在于**只摘一个 owner，不是按「是不是玩家阵容」清表**。旧写法会把备战期为
# 未来 3 轮预取的资源一并删掉（它们同样不属于玩家阵容），于是每回合结束丢弃一次
# 预取成果、下回合重新加载 —— 实测每轮战斗中仍现加载 96–426 MB 贴图。
# 现在只要还有 run/player 或 future/round/N 持有，资源就留着。
static func release_round_assets() -> void:
	# 本回合资源取用统计：走了几次同步路径、总共堵了主线程多久。
	# 「hit / harvest」是便宜的，「wait / cold」才是卡顿来源。
	print("[ASSET] 回合结束 %s" % BattleAssetService.stats_line())
	BattleAssetService.reset_stats()
	BattleAssetService.release_owner(BattleAssetService.OWNER_BATTLE)
	# 材质缓存的 key 是源材质路径，映射不回单位，没法分级 —— 整份清掉。
	# 代价只是下回合重新 duplicate(false)（浅拷贝，很便宜）；着色器变体由引擎
	# 按 shader+变体缓存、不按材质实例，所以不会重新编译。
	_clean_material_cache.clear()

func _prefetch_animation_scene(scene_path: String) -> void:
	BattleAssetService.acquire(scene_path, BattleAssetService.OWNER_BATTLE)

func _animation_scene_for_path(scene_path: String) -> PackedScene:
	if not _model_path_available(scene_path):
		return null
	return BattleAssetService.get_scene(scene_path)

func _select_model_animation_player(players: Array[AnimationPlayer], unit_def: Dictionary) -> AnimationPlayer:
	if players.is_empty():
		return null
	var desired_names := _desired_model_animation_names(unit_def)
	var best_player := players[0]
	var best_score := -1
	for player in players:
		var score := 0
		for animation_name in desired_names:
			if player.has_animation(animation_name):
				score += 1
		if score > best_score:
			best_score = score
			best_player = player
	return best_player

func _desired_model_animation_names(unit_def: Dictionary) -> Array[String]:
	var names: Array[String] = []
	var attack_name := str(unit_def.get("model_attack_animation_name", ""))
	if not attack_name.is_empty():
		names.append(attack_name)
	var idle_name := str(unit_def.get("model_idle_animation_name", ""))
	if idle_name.is_empty():
		idle_name = "idle"
	names.append(idle_name)
	var run_name := str(unit_def.get("model_run_animation_name", ""))
	if run_name.is_empty():
		run_name = "run"
	names.append(run_name)
	return names
func _first_animation_name(player: AnimationPlayer) -> String:
	var names := player.get_animation_list()
	return str(names[0]) if not names.is_empty() else ""

func _find_animation_players(root: Node) -> Array[AnimationPlayer]:
	var out: Array[AnimationPlayer] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is AnimationPlayer:
			out.append(node as AnimationPlayer)
		for child in node.get_children():
			stack.append(child)
	return out

func _add_3d_unit_readability(pivot: Node3D, f: Dictionary) -> void:
	var team_color := _actor_team_color(f)
	var shadow := MeshInstance3D.new()
	shadow.name = "GroundShadow3D"
	var shadow_mesh := CylinderMesh.new()
	shadow_mesh.top_radius = 0.26
	shadow_mesh.bottom_radius = 0.26
	shadow_mesh.height = 0.018
	shadow_mesh.radial_segments = 48
	shadow.mesh = shadow_mesh
	var shadow_mat := StandardMaterial3D.new()
	shadow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	shadow_mat.albedo_color = Color(0.0, 0.0, 0.0, 0.54)
	shadow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shadow.material_override = shadow_mat
	shadow.position = Vector3(0.0, 0.012, 0.0)
	shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var shadow_root := pivot.get_node_or_null("Shadow") as Node3D
	if shadow_root != null:
		shadow_root.add_child(shadow)
	else:
		pivot.add_child(shadow)

	var glow := MeshInstance3D.new()
	glow.name = "TeamGlow3D"
	var glow_mesh := CylinderMesh.new()
	glow_mesh.top_radius = 0.30
	glow_mesh.bottom_radius = 0.30
	glow_mesh.height = 0.012
	glow_mesh.radial_segments = 24
	glow.mesh = glow_mesh
	var glow_mat := StandardMaterial3D.new()
	glow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glow_mat.albedo_color = team_color
	glow_mat.emission_enabled = true
	glow_mat.emission = Color(team_color.r, team_color.g, team_color.b, 1.0)
	glow_mat.emission_energy_multiplier = 0.55
	glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.material_override = glow_mat
	glow.position = Vector3(0.0, 0.022, 0.0)
	glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pivot.add_child(glow)


func _actor_team_color(f: Dictionary) -> Color:
	# 3v3: ring uses the owning player's slot color. Otherwise team blue/red.
	var owner_slot := int(f.get("owner_slot", -1))
	var fid := str(f.get("id", ""))
	var def_value = f.get("def", {})
	var definition: Dictionary = def_value if typeof(def_value) == TYPE_DICTIONARY else {}
	if fid.is_empty():
		fid = str(definition.get("id", ""))
	var is_boss := bool(definition.get("is_boss", false)) or fid.begins_with("boss_")
	var is_monster := fid.begins_with("pve_")
	if is_boss:
		return Color(0.82, 0.22, 0.85, 0.55)
	if is_monster:
		return Color(0.58, 0.62, 0.70, 0.52)
	if owner_slot >= 0:
		var slot_color := GameConstants.team_slot_color(owner_slot)
		slot_color.a = 0.55
		return slot_color
	return Color(0.25, 0.85, 1.0, 0.48) if _display_team(f) == "player" else Color(1.0, 0.34, 0.18, 0.52)

func _position_3d_model_node(model_node: Node3D, f: Dictionary, facing_delta: float) -> void:
	var pos := _sim_to_world_pos(_visual_sim_pos_for_fighter(f))
	var world_pos := Vector3(pos.x, battle_unit_y_offset, pos.z)
	model_node.position = world_pos
	if facing_delta <= 0.0:
		return
	_update_model_facing(model_node, f, world_pos, facing_delta)

# Seconds since the previous facing update. Read off the wall clock rather than
# a _process delta because _refresh_visuals also runs from one-off call sites
# (model build, replay seek, skip-to-end) that have no delta to pass down.
func _model_facing_delta() -> float:
	var now := Time.get_ticks_msec()
	var last := _model_facing_last_msec
	_model_facing_last_msec = now
	if last <= 0:
		return MODEL_FACING_MAX_DELTA
	return clampf(float(now - last) * 0.001, 0.0, MODEL_FACING_MAX_DELTA)

# Turn the model toward its aim direction at a fixed angular speed. Everything
# is resolved in world space, so the arena flip and the final round's rotated
# layout fall out of _sim_to_world_pos and need no special case here.
func _update_model_facing(model_node: Node3D, f: Dictionary, world_pos: Vector3, delta: float) -> void:
	var aim := _model_aim_dir(model_node, f, world_pos)
	if aim == Vector2.ZERO:
		return
	# atan2(x, z) is the yaw that points +Z along `aim`; model_base_yaw is the
	# per-model art calibration (180 for a model whose forward is -Z), which is
	# exactly the value the old team-based facing used for the player side.
	var base_yaw := float(model_node.get_meta("base_yaw", 180.0))
	var target_yaw := atan2(aim.x, aim.y) + deg_to_rad(base_yaw - 180.0)
	if not bool(model_node.get_meta("facing_ready", false)):
		model_node.set_meta("facing_ready", true)
		model_node.rotation.y = target_yaw
		return
	var diff := wrapf(target_yaw - model_node.rotation.y, -PI, PI)
	var max_step := deg_to_rad(MODEL_FACING_TURN_SPEED_DEG) * delta
	model_node.rotation.y = wrapf(model_node.rotation.y + clampf(diff, -max_step, max_step), -PI, PI)

# Where the unit should be looking, as a world-space (x, z) direction:
# where its feet are going while it closes in, who it is hitting while it
# stands and swings. Returns ZERO to mean "keep the current facing".
func _model_aim_dir(model_node: Node3D, f: Dictionary, world_pos: Vector3) -> Vector2:
	var here := Vector2(world_pos.x, world_pos.z)
	# Movement is measured on the raw simulation position rather than the on-screen
	# one: the separation pass keeps nudging idle models as their neighbours shift,
	# and that must never read as "this unit is running somewhere".
	var sim_now := Vector2(float(f.pos.x), float(f.pos.y))
	if not model_node.has_meta("facing_last_sim_pos"):
		model_node.set_meta("facing_last_sim_pos", sim_now)
	var raw_last: Variant = model_node.get_meta("facing_last_sim_pos")
	var sim_last := sim_now
	if raw_last is Vector2:
		sim_last = raw_last
	# The reference point only advances once the unit clears the dead zone, so a
	# slow crawl still accumulates into a heading while a unit standing still
	# never spins on sub-pixel noise.
	if sim_now.distance_to(sim_last) >= MODEL_FACING_MOVE_EPS_SIM:
		model_node.set_meta("facing_last_sim_pos", sim_now)
		var from_world := _sim_to_world_pos(sim_last)
		var to_world := _sim_to_world_pos(sim_now)
		var travel := Vector2(to_world.x - from_world.x, to_world.z - from_world.z)
		if travel.length() > 0.0001:
			return travel.normalized()
	var target_dir := _dir_to_fighter_id(here, str(f.get("vfx_attack_target_uid", "")))
	if target_dir != Vector2.ZERO:
		return target_dir
	# No target yet (nobody hit so far) or it just died: look at the nearest
	# live enemy so ranged units that never move still face the fight.
	return _dir_to_nearest_enemy(here, f)

func _dir_to_fighter_id(here: Vector2, target_id: String) -> Vector2:
	if target_id.is_empty():
		return Vector2.ZERO
	# Only living units are in the frame table, so a dead target falls through
	# to the nearest-enemy path instead of leaving the model aimed at a corpse.
	var target: Variant = _frame_fighter_by_id.get(target_id)
	if typeof(target) != TYPE_DICTIONARY:
		return Vector2.ZERO
	var pos := _sim_to_world_pos(_visual_sim_pos_for_fighter(target))
	var dir := Vector2(pos.x, pos.z) - here
	return dir.normalized() if dir.length() > 0.001 else Vector2.ZERO

func _dir_to_nearest_enemy(here: Vector2, f: Dictionary) -> Vector2:
	var my_team := str(f.get("team", ""))
	var my_id := _visual_id(f)
	# Rank on the raw sim positions already gathered this frame (cheap, no
	# separation pass), then take the winner's visual position for the aim.
	var my_sim := Vector2(float(f.pos.x), float(f.pos.y))
	var best_id := ""
	var best_dist := INF
	for i in _frame_living_ids.size():
		var id := _frame_living_ids[i]
		if id == my_id:
			continue
		var other: Variant = _frame_fighter_by_id.get(id)
		if typeof(other) != TYPE_DICTIONARY:
			continue
		if str((other as Dictionary).get("team", "")) == my_team:
			continue
		var dist := my_sim.distance_squared_to(_frame_living_pos[i])
		if dist < best_dist:
			best_dist = dist
			best_id = id
	return _dir_to_fighter_id(here, best_id)

# Spawn pose, held only until the first facing update snaps the model onto its
# aim direction — the build pass runs before any frame table exists.
func _spawn_facing_yaw(f: Dictionary, base_yaw: float) -> float:
	var is_player := str(f.get("team", "")) == "player"
	if _arena_flip_y:
		is_player = not is_player
	return base_yaw if is_player else base_yaw + MODEL_FACING_SPAWN_ENEMY_YAW


func _set_formation_allies_intro_hidden(hidden: bool) -> void:
	_formation_allies_hidden_for_intro = hidden
	for fighter in _state.get("player", []) + _state.get("enemy", []):
		_apply_formation_intro_visibility(_visual_id(fighter), fighter)


func _apply_formation_intro_visibility(id: String, fighter: Dictionary) -> void:
	if not bool(fighter.get("is_formation_ally", false)):
		return
	var should_show := not _formation_allies_hidden_for_intro
	var unit_node: Control = _unit_nodes.get(id)
	if unit_node != null and is_instance_valid(unit_node):
		unit_node.visible = should_show
	var model_node: Node3D = _battle_3d_models.get(id)
	if model_node != null and is_instance_valid(model_node):
		model_node.visible = should_show

# Rebuilds the per-frame snapshot of living units (ids + raw sim positions) and
# clears the memoized visual positions. Display-only: never writes to _state.
func _begin_visual_frame(living: Array) -> void:
	_visual_pos_cache.clear()
	_frame_living_ids.clear()
	_frame_living_pos.clear()
	_frame_fighter_by_id.clear()
	for f in living:
		if typeof(f) != TYPE_DICTIONARY:
			continue
		var id := _visual_id(f)
		_frame_living_ids.append(id)
		_frame_living_pos.append(Vector2(float(f.pos.x), float(f.pos.y)))
		_frame_fighter_by_id[id] = f

func _visual_sim_pos_for_fighter(f: Dictionary) -> Vector2:
	var id := _visual_id(f)
	var cached: Variant = _visual_pos_cache.get(id)
	if cached is Vector2:
		return cached as Vector2
	var pos := _compute_visual_sim_pos(f, id)
	_visual_pos_cache[id] = pos
	return pos

func _compute_visual_sim_pos(f: Dictionary, id: String) -> Vector2:
	var base := Vector2(float(f.pos.x), float(f.pos.y))
	var offset := _stable_unit_spread_dir(f) * MODEL_SEPARATION_BASE_NUDGE
	for i in _frame_living_ids.size():
		if _frame_living_ids[i] == id:
			continue
		var delta := base - _frame_living_pos[i]
		var dist := delta.length()
		if dist < 0.01:
			delta = _stable_unit_spread_dir(f)
			dist = 1.0
		if dist < MODEL_SEPARATION_RADIUS:
			var strength := (MODEL_SEPARATION_RADIUS - dist) / MODEL_SEPARATION_RADIUS
			offset += delta.normalized() * strength * MODEL_SEPARATION_STRENGTH
	if offset.length() > MODEL_SEPARATION_MAX_OFFSET:
		offset = offset.normalized() * MODEL_SEPARATION_MAX_OFFSET
	return _clamp_visual_sim_pos(base + offset)

func _stable_unit_spread_dir(f: Dictionary) -> Vector2:
	var slot := int(f.get("slot", 0))
	var uid_len := str(f.get("uid", "")).length()
	var team_bias := 97 if str(f.get("team", "")) == "enemy" else 23
	var degrees := (slot * 47 + uid_len * 29 + team_bias) % 360
	var angle := deg_to_rad(float(degrees))
	return Vector2(cos(angle), sin(angle))

func _display_unit_def_for_fighter(f: Dictionary) -> Dictionary:
	return UnitVisualResolverScript.resolve_for_fighter(f)

func _model_path_available(model_path: String) -> bool:
	return UnitVisualResolverScript.resource_exists(model_path)

func _center_model_for_full_body_view(model: Node3D) -> void:
	var bounds := _node3d_bounds(model)
	if bounds.size == Vector3.ZERO:
		return
	var center := bounds.get_center()
	# _node3d_bounds is measured in the model's unscaled local space. Apply the
	# model basis so the centering offset stays correct after model_visual_scale;
	# subtracting the raw AABB values made 0.42-scale actors float above FootAnchor.
	model.position -= model.transform.basis * Vector3(center.x, bounds.position.y, center.z)

func _camera_distance_for_bounds(bounds: AABB, frame_fill: float, fov_deg: float) -> float:
	if bounds.size == Vector3.ZERO:
		return 3.2
	var fill := clampf(frame_fill, 0.55, 1.15)
	var half_height := maxf(bounds.size.y * 0.5, 0.2)
	var half_width := maxf(bounds.size.x * 0.5, 0.2)
	var half_fov := deg_to_rad(fov_deg) * 0.5
	var needed := maxf(half_height / tan(half_fov), half_width / tan(half_fov))
	return maxf(1.2, needed / fill)

func _visual_id(f: Dictionary) -> String:
	return str(f.get("uid", "%s_%s" % [str(f.get("team", "")), str(f.get("id", ""))]))
