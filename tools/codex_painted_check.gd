extends Node
# Isolated preview/check runner; never saves discovered entries or changes gameplay.
const Screen := preload("res://scenes/menu/CodexScreen.gd")
const SkillArt := preload("res://ui/components/CodexSkillArt.gd")
const OUT := "C:/Users/Leno/Desktop/main button/codex/"
var failures: Array[String] = []
var checked := 0

func _ready() -> void:
	LocaleManager.set_locale("zh")
	SaveManager.set("_save_pending", true)
	NetworkService.set_process(false)
	var args := OS.get_cmdline_user_args()
	if "--fourstar" in args:
		add_child(load("res://tools/codex_four_star_check.gd").new())
		return
	var seen_before: Array[String] = PlayerProfile.codex_seen.duplicate()
	for race in ["god", "human", "dark", "undead", "crimson"]:
		for entry in CodexService.entries_for(race):
			PlayerProfile.codex_seen.append(str(entry.id))
	var screen := Screen.new()
	add_child(screen)
	await get_tree().process_frame
	await get_tree().process_frame
	for locale in ["zh", "en"]:
		LocaleManager.set_locale(locale)
		for race in ["god", "human", "dark", "undead", "crimson"]:
			screen._category = race
			screen._refresh()
			await get_tree().process_frame
			var entries := CodexService.entries_for(race)
			for i in entries.size():
				var entry: Dictionary = entries[i]
				var tile := screen._grid.get_child(i) as Button
				tile.pressed.emit()
				await get_tree().process_frame
				await get_tree().process_frame
				check(screen._picked == str(entry.id), "click selection " + str(entry.id))
				check(SkillArt.for_entry(entry) != null, "missing icon " + str(entry.id))
				var texts := labels(screen._detail)
				check(UnitDetailFormat.format_skill_detail(entry.raw) in texts, "missing actual skill " + str(entry.id))
				check(screen._detail.size.x <= screen._right_page.size.x + 2.0, "detail overflows " + str(entry.id) + " " + str(screen._detail.size))
				checked += 1
	# Locked entries must continue to hide descriptions and new ability artwork.
	PlayerProfile.codex_seen.clear()
	screen._category = "dark"
	screen._picked = "dark_dragon"
	screen._refresh()
	await get_tree().process_frame
	check(find_icon(screen._detail) == null, "locked ability artwork leaked")
	check(tr("codex_locked_text") in labels(screen._detail), "locked hint missing")
	PlayerProfile.codex_seen.assign(seen_before)
	if "--capture" in args:
		for race in ["god", "human", "dark", "undead", "crimson"]:
			for entry in CodexService.entries_for(race):
				if not PlayerProfile.codex_seen.has(str(entry.id)):
					PlayerProfile.codex_seen.append(str(entry.id))
		DisplayServer.window_set_size(Vector2i(1600, 900))
		LocaleManager.set_locale("zh")
		# Rebuild banner so it follows the newly selected language.
		screen.queue_free()
		await get_tree().process_frame
		screen = Screen.new()
		add_child(screen)
		for sample in [["god", "god_priest"], ["dark", "dark_dragon"], ["crimson", "Icey"]]:
			screen._category = sample[0]
			screen._picked = sample[1]
			screen._refresh()
			await get_tree().create_timer(0.6).timeout
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(OUT + "preview_" + sample[0] + ".png")
		DisplayServer.window_set_size(Vector2i(1600, 720))
		LocaleManager.set_locale("en")
		screen.queue_free()
		await get_tree().process_frame
		screen = Screen.new()
		add_child(screen)
		screen._category = "undead"
		screen._picked = "undead_mother"
		screen._refresh()
		await get_tree().create_timer(0.6).timeout
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(OUT + "preview_english_1600x720.png")
	PlayerProfile.codex_seen.assign(seen_before)
	for failure in failures:
		push_error(failure)
	print("CODEX_PAINTED_CHECK checked=", checked, " failures=", failures.size())
	get_tree().quit(0 if failures.is_empty() else 1)

func check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)

func labels(node: Node) -> Array[String]:
	var texts: Array[String] = []
	if node is Label:
		texts.append(node.text)
	for child in node.get_children():
		texts.append_array(labels(child))
	return texts

func find_icon(node: Node) -> Node:
	if node.name == "AbilityIcon":
		return node
	for child in node.get_children():
		var found := find_icon(child)
		if found != null:
			return found
	return null

