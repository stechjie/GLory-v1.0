extends RefCounted

# Only waiting rooms and settlement screens use the reduced cadence. Returning
# through Main._clear restores the normal budget before any interactive page.
const ACTIVE_FPS := 60
const WAITING_FPS := 30

static func apply(waiting: bool) -> void:
	if not OS.has_feature("mobile") or DisplayServer.get_name() == "headless":
		return
	Engine.max_fps = WAITING_FPS if waiting else ACTIVE_FPS
