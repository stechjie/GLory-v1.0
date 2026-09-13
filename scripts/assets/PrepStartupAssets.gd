extends RefCounted

# Only the preparation screen's visible board, controls and current units.
# Reuse the actual UI constants so an art update cannot leave this list stale.
const Prep := preload("res://scenes/prep/PrepScreen.gd")
const Shop := preload("res://scenes/prep/panels/ShopPanel.gd")
const Resolver := preload("res://effects/runtime/presentation/UnitVisualResolver.gd")
const Rules := preload("res://scenes/prep/PrepRules.gd")

static func paths() -> Array:
	var out: Array = [
		Prep.PREP_BOARD_BASE_PATH, Prep.PREP_CELL_MARK_PATH,
		Prep.PREP_STANDBY_BG_PATH, Prep.PREP_RIVER_TOP_PATH, Prep.PREP_RIVER_BOTTOM_PATH,
		Prep.PREP_RIVER_TOP_EF_PATH, Prep.PREP_RIVER_BOTTOM_EF_PATH, Prep.PREP_RIVER_FLOW_SHADER,
		Prep.PREP_CARROT_PROP_PATH, Prep.PREP_CARROT_FARM_DECOR_PATH,
		Prep.START_BTN_PATH, Prep.STATS_BTN_PATH, Prep.REFRESH_BTN_PATH,
		Prep.MERC_BTN_PATH, Prep.TEAM_MERCS_BTN_PATH, Prep.CARROT_BTN_PATH,
		Prep.CHAT_BTN_PATH, Prep.CARROT_CURRENCY_ICON_PATH,
		Prep.TEAM_MERCS_STAGE_BACKGROUND_PATH, Prep.SHOP_REFRESH_FIRE_ATLAS_PATH,
		Prep.TEAM_MERC_ALERT_ATLAS_PATH,
		Shop.SHOP_CLOSED_BTN_PATH, Shop.SHOP_IDLE_ATLAS_PATH, Shop.SHOP_IDLE_HALO_PATH,
		Shop.SHOP_PANEL_BACKGROUND_PATH, Shop.PrepMoneyBagIcon.MONEY_BAG_TEXTURE_PATH,
	]
	# A restored tutorial can already be at its PvP step. Match the music and
	# announcement chosen by PrepScreen without warming unrelated future rounds.
	if Rules.next_round_kind() in ["pvp", "final"]:
		out.append_array([Prep.PREP_PVP_MUSIC_PATH, Prep.PVP_WARNING_FRAME_PATH])
	else:
		out.append(Prep.PREP_MUSIC_PATH)
	out.append_array(Prep.CRYSTAL_FIRE_PATHS)
	out.append_array(Prep.CRYSTAL_WATER_PATHS)
	out.append_array(Shop.SHOP_CARD_FRAME_PATHS.values())
	# The farm displays the starter pets even before the player chooses one.
	var pets: Array = PetService.starter_ids().duplicate()
	if not PlayerProfile.get_active().is_empty():
		pets.append(PlayerProfile.get_active())
	for pet_id in pets:
		out.append(PetService.model_path(str(pet_id)))
	for slots in [GameState.board_slots, GameState.bench_slots]:
		for cell in slots:
			if cell is Dictionary:
				_append_definition(Resolver.resolve_for_cell(cell), out)
	for offer in GameState.shop_offers:
		if offer is Dictionary and not offer.is_empty():
			_append_definition(Resolver.resolve_definition(str(offer.get("id", "")), offer), out)
	return out

static func _append_definition(definition: Dictionary, out: Array) -> void:
	for key in ["model", "model_idle_animation", "portrait", "fallback_frame"]:
		var path := str(definition.get(key, ""))
		if not path.is_empty():
			out.append(path)
