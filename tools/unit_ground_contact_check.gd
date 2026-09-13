extends Node

# Regression for the phone's floating prep pieces and doubled battle shadows.
# No PrepScreen lifecycle, scene transition, gameplay state or save is invoked.
const Harness := preload("res://tools/CheckHarness.gd")
const PrepModels := preload("res://scenes/prep/PrepBoardModels.gd")
const BattleRenderer := preload("res://scenes/battle/BattleRenderer.gd")
const Actor := preload("res://effects/runtime/presentation/UnitActor3D.gd")

func _ready() -> void:
	var h := Harness.new("unit_ground_contact")
	var prep := PrepModels.new()
	var stage := Node3D.new()
	stage.position = prep.PREP_RIVER_STAGE_POSITION
	stage.scale = prep.PREP_RIVER_STAGE_SCALE
	add_child(stage)
	prep._prep_model_root = Node3D.new()
	prep._prep_model_root.position = prep.board_origin
	stage.add_child(prep._prep_model_root)
	prep._prep_standby_model_root = Node3D.new()
	prep._prep_standby_model_root.position = prep.board_origin + prep.standby_origin
	stage.add_child(prep._prep_standby_model_root)
	var piece := Node3D.new()
	prep._prep_model_root.add_child(piece)
	for slot in GameConstants.CELL_COUNT:
		prep._position_prep_board_model(piece, slot, {})
		var expected := prep.PREP_BOARD_GROUND_CENTER.y + prep.PREP_CELL_MARK_Y_LIFT
		h.expect(absf(piece.global_position.y - expected) < 0.00001, "board_floating",
			"Board slot %d rests at %.5f; cell surface is %.5f" % [slot, piece.global_position.y, expected])
	piece.reparent(prep._prep_standby_model_root)
	for slot in GameState.BENCH_SLOTS:
		prep._position_prep_standby_model(piece, slot, {})
		var expected := prep.PREP_BOARD_GROUND_CENTER.y + prep.PREP_STANDBY_BG_Y_LIFT
		h.expect(absf(piece.global_position.y - expected) < 0.00001, "bench_floating",
			"Bench slot %d rests at %.5f; platform surface is %.5f" % [slot, piece.global_position.y, expected])
	# An explicit artist offset remains additive after the world/local conversion.
	prep.standby_unit_y_offset = 0.01
	prep._position_prep_standby_model(piece, 0, {})
	var raised := prep.PREP_BOARD_GROUND_CENTER.y + prep.PREP_STANDBY_BG_Y_LIFT + stage.scale.y * 0.01
	h.expect(absf(piece.global_position.y - raised) < 0.00001, "artist_offset_lost", "Artist lift must remain additive")
	prep._add_prep_contact_shadow(piece)
	var prep_shadow := piece.get_node("ContactShadow3D") as MeshInstance3D
	h.expect(prep_shadow.get_active_material(0).render_priority > 7, "prep_shadow_hidden_by_platform", "Prep contact shade must draw after the transparent platform")
	# The reveal hides the stage while anchors are initialized. A hidden stage
	# must not hide active rig feet from this one-time placement measurement.
	stage.visible = false
	var samples: Array[Node3D] = []
	for unit_id in ["human_militia", "human_archer", "human_merchant", "dark_imp", "dark_queen"]:
		var definition := DataRegistry.canonical_unit_def(unit_id)
		var sample: Node3D = prep._make_prep_board_model({"id": unit_id, "star": 1, "def": definition}, definition)
		prep._prep_standby_model_root.add_child(sample)
		samples.append(sample)
	for frame in 4:
		await get_tree().process_frame
	for sample in samples:
		var model: Node3D = sample.visual_root
		var original_y := model.position.y - prep._prep_node3d_bounds(model).position.y
		prep._center_prep_model(model)
		var feet: Variant = prep._prep_model_foot_center(model)
		var unit_id := str(sample.get_meta("unit_id"))
		h.expect(feet is Vector3 and Vector2(feet.x, feet.z).length() < 0.001,
			"idle_feet_off_center", "%s: idle feet must center even under a hidden stage" % unit_id)
		h.expect(absf(model.position.y - original_y) < 0.00001,
			"centering_lifts_model", "%s: horizontal centering must preserve existing vertical clearance" % unit_id)
	stage.free()
	# PrepUI normally adopts these panels; this geometry fixture never builds UI.
	for panel in [prep._shop, prep._synergy, prep._stats, prep._treasure, prep._board_hud]:
		panel.free()
	prep.free()

	var renderer := BattleRenderer.new()
	var fighter := {"id":"dark_imp", "uid":"ground_contact_qa", "team":"player", "def":{}}
	var hud := renderer._make_unit_node(fighter)
	h.expect(hud.get_node_or_null("GroundShadow") == null, "duplicate_hud_shadow", "The HUD must not draw a second shadow")
	hud.free()
	var actor := Actor.new()
	add_child(actor)
	renderer._add_3d_unit_readability(actor, fighter)
	var shadow := actor.get_node("Shadow/GroundShadow3D") as MeshInstance3D
	h.expect(shadow.mesh is PlaneMesh, "solid_shadow_volume", "Contact shadow must be a flat fading surface")
	h.expect(shadow.mesh.material is ShaderMaterial, "hard_shadow_edge", "Contact shadow must use a feathered alpha material")
	h.expect(shadow.get_active_material(0).render_priority == 0, "prep_priority_leaked_to_battle", "Prep layer ordering must not change battle shadows")
	var ring := actor.get_node("TeamGlow3D") as MeshInstance3D
	h.expect(ring.mesh is PlaneMesh and ring.material_override is ShaderMaterial, "solid_team_disc", "Team color must use a hollow ring")
	actor.position = Vector3(3.0, 1.0, -4.0)
	actor.rotation.y = 1.3
	var relative := actor.to_local(shadow.global_position)
	h.expect(absf(relative.x) < 0.00001 and absf(relative.z) < 0.00001, "shadow_trails_actor", "Shadow must stay directly below a moving/turning actor")
	h.expect(relative.y > 0.0 and relative.y < 0.025, "shadow_above_feet", "Shadow must be close to the contact plane")
	var body := MeshInstance3D.new()
	body.mesh = BoxMesh.new()
	actor.actor_root.add_child(body)
	var aura := preload("res://effects/vfx3d/modules/FourStarAura3D.gd").new()
	actor.add_child(aura)
	aura.mode = 2
	aura.rim_material = ShaderMaterial.new()
	aura.attach_rim(actor)
	h.expect(body.material_overlay == aura.rim_material, "body_rim_missing", "Four-star body rim remains available")
	h.expect(shadow.material_overlay == null and ring.material_overlay == null, "ground_rim_leak", "Four-star glow must not fill the contact shadow or team ring")
	actor.free()
	renderer.free()
	h.finish(get_tree())
