extends Node

# Regenerates export_presets.template.cfg from the live export_presets.cfg.
#
# Run it after changing any export preset:
#   Godot --headless --path . res://tools/export_presets_template.tscn
#
# tools/export_presets_check.tscn goes red until you do, which is the point:
# the committed copy cannot quietly fall behind the file it mirrors.

const Template := preload("res://tools/ExportPresetsTemplate.gd")


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	if not FileAccess.file_exists(Template.LIVE_PATH):
		printerr("[export_presets_template] 读不到 %s —— 没有实文件就没什么可生成的。" % Template.LIVE_PATH)
		get_tree().quit(1)
		return

	var source := FileAccess.get_file_as_string(Template.LIVE_PATH)
	if source.is_empty():
		printerr("[export_presets_template] %s 是空的。" % Template.LIVE_PATH)
		get_tree().quit(1)
		return

	var blanked: PackedStringArray = []
	var localized: PackedStringArray = []
	for raw_line in source.split("\n"):
		var key := Template.key_of(str(raw_line))
		if key.is_empty():
			continue
		if Template.SECRET_KEYS.has(key):
			blanked.append(key)
		elif Template.LOCAL_KEYS.has(key):
			localized.append(key)

	var out := FileAccess.open(Template.TEMPLATE_PATH, FileAccess.WRITE)
	if out == null:
		printerr("[export_presets_template] 写不了 %s (err %d)" % [Template.TEMPLATE_PATH, FileAccess.get_open_error()])
		get_tree().quit(1)
		return
	out.store_string(Template.render(source))
	out.close()

	print("[export_presets_template] 已写 %s" % Template.TEMPLATE_PATH)
	if blanked.is_empty():
		print("[export_presets_template] 本次没有密钥字段需要清空（项目还没设过 keystore）。")
	else:
		print("[export_presets_template] 已清空 %d 个密钥字段：%s" % [blanked.size(), ", ".join(blanked)])
	if not localized.is_empty():
		print("[export_presets_template] 已清空 %d 个本机字段（不参与漂移比对）：%s"
			% [localized.size(), ", ".join(localized)])
	get_tree().quit(0)
