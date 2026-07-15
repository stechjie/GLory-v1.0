class_name JsonUtil
extends RefCounted

static func read(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed != null else {}
