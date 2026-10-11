@tool
extends EditorPlugin

class DeferredExport extends EditorExportPlugin:
	var saved: Dictionary = {}
	var autoload_scripts: Array[Resource] = []

	func _get_name() -> String:
		return "GLoryDeferredBootstrap"

	func _export_begin(_features: PackedStringArray, _debug: bool, _path: String, _flags: int) -> void:
		var boot = JSON.parse_string(FileAccess.get_file_as_string("res://patcher/boot.json"))
		var runtime := ConfigFile.new()
		for entry in boot.autoloads:
			var key := "autoload/" + str(entry.name)
			saved[key] = ProjectSettings.get_setting(key)
			ProjectSettings.set_setting(key, "*" + str(entry.path))
			runtime.set_value("autoload", str(entry.name), "*res://patcher/AutoloadPlaceholder.tscn")
		# Match the real startup compilation order before the exporter walks
		# scenes. Otherwise scene -> singleton -> preloaded scene dependencies
		# can encounter a still-busy script during resource customization.
		for entry in boot.autoloads:
			var script := load(str(entry.path))
			if script != null:
				autoload_scripts.append(script)
		add_file("res://override.cfg", runtime.encode_to_text().to_utf8_buffer(), false)

	func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
		if path.begins_with("res://patcher/export_plugin/"):
			skip()

	func _export_end() -> void:
		for key in saved:
			ProjectSettings.set_setting(key, saved[key])
		saved.clear()
		autoload_scripts.clear()

var exporter: DeferredExport

func _enter_tree() -> void:
	exporter = DeferredExport.new()
	add_export_plugin(exporter)

func _exit_tree() -> void:
	remove_export_plugin(exporter)
