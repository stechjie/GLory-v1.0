extends AudioStreamPlayer

# A root-owned player receives lifecycle events even while its scene is paused.
signal application_suspended
signal application_resumed

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		application_suspended.emit()
	elif what == NOTIFICATION_APPLICATION_RESUMED:
		# Resume after Godot has restarted its platform audio driver.
		application_resumed.emit.call_deferred()
