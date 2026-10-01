extends Node

const SCREEN := preload("res://scenes/menu/RankedRewardScreen.gd")
const OUT := "res://reports/ranked_reward_ui"


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Ranked reward capture requires a rendering backend")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	DisplayServer.window_set_size(Vector2i(1280, 720))
	for result in ["win", "lose", "draw"]:
		await _capture(result)
	for tier in 5:
		await _capture("win", tier)
	await _capture("win", 4, true)
	await _capture("lose", 2, false, true)
	get_tree().quit(0)


func _capture(result: String, tier: int = -1, promoted: bool = false, demoted: bool = false) -> void:
	var screen := SCREEN.new()
	var outcome := 2 if result == "draw" else (0 if result == "win" else 1)
	var shown_tier := 2 if tier < 0 else tier
	var before_score: int = 320 if tier < 0 else [25, 125, 325, 525, 725][tier]
	var after_score: int = (345 if result == "win" else (320 if result == "draw" else 301)) if tier < 0 else before_score + 25
	if promoted:
		before_score = 695
		after_score = 720
	if demoted:
		before_score = 505
		after_score = 480
	var span: int = [100, 200, 200, 200, 0][shown_tier]
	var progress: int = after_score - [0, 100, 300, 500, 700][shown_tier]
	screen.data = {"mode": "ranked", "match_uid": "a".repeat(32),
		"local_team": 0, "outcome": outcome, "show_details": true,
		"preview_receipt": {"status": "settled", "result": result,
			"coin": 12 if result == "win" else (5 if result == "draw" else 4),
			"score_before": before_score, "score_after": after_score,
			"tier_before": 3 if promoted or demoted else shown_tier, "tier_after": shown_tier,
			"tier_progress": progress, "tier_span": span,
			"coin_balance_after": 1512}}
	add_child(screen)
	for _i in (45 if promoted or demoted else 30):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var shot := "promotion" if promoted else ("demotion" if demoted else (("tier_%d" % tier) if tier >= 0 else result))
	var path := "%s/%s_1280.png" % [OUT, shot]
	var error := get_viewport().get_texture().get_image().save_png(path)
	if error != OK:
		push_error("Could not save %s: %s" % [path, error_string(error)])
	else:
		print("CAPTURED %s" % path)
	screen.queue_free()
	await get_tree().process_frame
