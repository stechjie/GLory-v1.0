extends SceneTree

func _initialize() -> void:
    call_deferred("_capture")

func _capture() -> void:
    root.size = Vector2i(1280, 720)
    var screen: Control = (load("res://scenes/menu/GameOverScreen.gd") as GDScript).new()
    screen.result_kind = "win"
    screen.title_text = "Final Victory"
    screen.body_text = "3v3 round 21 complete: Win\nTeam HP: 50"
    screen.show_details = true
    root.add_child(screen)
    await process_frame
    await process_frame
    await process_frame
    var picture := root.get_texture().get_image()
    print("CAPTURE_SIZE=", picture.get_size())
    picture.save_png("res://captures/game_over_ui_review_win_1280.png")
    quit()




