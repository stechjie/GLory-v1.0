@tool
extends EditorPlugin

var _exporter: EditorExportPlugin

func _enter_tree() -> void:
	_exporter = SpeechExport.new()
	add_export_plugin(_exporter)

func _exit_tree() -> void:
	remove_export_plugin(_exporter)

class SpeechExport extends EditorExportPlugin:
	func _get_name() -> String:
		return "GloryOfflineSpeech"

	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformWindows

	func _export_begin(features: PackedStringArray, _debug: bool, _path: String, _flags: int) -> void:
		if not features.has("windows") or not features.has("x86_64"):
			return
		var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://addons/glory_speech/runtime.json"))
		for filename in manifest.files:
			# Export loose files beside the executable; an executable/model inside PCK cannot run.
			# Missing inputs deliberately fail the export rather than ship a broken button.
			add_shared_object("res://addons/glory_speech/bin/windows/" + filename,
				PackedStringArray(["windows", "x86_64"]), "speech")
