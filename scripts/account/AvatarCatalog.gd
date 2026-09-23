extends RefCounted
# 头像清单（客户端侧）。数据源与后端是**同一个文件** —— res://data/avatars.json。
#
# 刻意**不用 class_name**，与 AccountConfig.gd / SessionContext.gd 同样的理由：
# make_server_zip.ps1 会打包 .godot/global_script_class_cache.cfg，
# 新增全局类若未先重建缓存就打包，服务器会在解析阶段直接挂。用 preload 引用。
#
# 为什么不放进 DataRegistry：那八张表每次冷启动都读，而这份清单只有玩家点开
# 资料页才要。启动预算是有人盯的（GLORY_STARTUP 的 data_registry_loaded），
# 不该为一个一个月用一次的东西加一笔。所以这里是**懒加载 + 进程内缓存**。
#
# ⚠️ 客户端这一层只负责**画得出来**，不负责授权。
# 「这个 id 合不合法、有没有资格用」由后端的 avatar_catalog.py 说了算 ——
# 客户端的清单可能比部署的后端旧（玩家没更新包），那时后端会回 400，
# 照它给的话提示玩家即可，不要在这里自己判。

const CATALOG_PATH := "res://data/avatars.json"

static var _cache: Dictionary = {}


static func _catalog() -> Dictionary:
	if not _cache.is_empty():
		return _cache
	var text := FileAccess.get_file_as_string(CATALOG_PATH)
	if text.is_empty():
		push_error("[AVATAR] 读不到 %s" % CATALOG_PATH)
		return {}
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("[AVATAR] %s 解析失败" % CATALOG_PATH)
		return {}
	_cache = parsed as Dictionary
	return _cache


# [{id, name, name_en, source}, ...]，顺序与文件一致（文件里就是排好的）。
static func avatars() -> Array:
	return _catalog().get("avatars", [])


static func frames() -> Array:
	return _catalog().get("frames", [])


static func default_avatar() -> String:
	return "preset:%s" % str(_catalog().get("default_id", "avatar_001"))


static func default_frame() -> String:
	return "preset:%s" % str(_catalog().get("default_frame_id", "frame_default"))


# 选择器用的小图。缩略图由 tools/make_avatar_thumbs.py 生成 ——
# 原图 330x330、解码后每张约 435 KB 显存，二十张一起铺出来会卡一下，
# 而这是每个玩家进资料页必做的第一个操作。
static func thumb_path(avatar_id: String) -> String:
	var dir := str(_catalog().get("thumb_dir", "res://assets/ui/avatars/thumb"))
	return "%s/%s.png" % [dir, avatar_id]


# 资料页上那张大图用原图。
static func source_path(avatar_id: String) -> String:
	for entry in avatars():
		if str((entry as Dictionary).get("id", "")) == avatar_id:
			return str((entry as Dictionary).get("source", ""))
	return ""


static func frame_source_path(frame_id: String) -> String:
	for entry in frames():
		if str((entry as Dictionary).get("id", "")) == frame_id:
			return str((entry as Dictionary).get("source", ""))
	return ""


static func display_name(avatar_id: String) -> String:
	var english := TranslationServer.get_locale().begins_with("en")
	for entry in avatars():
		var row := entry as Dictionary
		if str(row.get("id", "")) == avatar_id:
			return str(row.get("name_en" if english else "name", avatar_id))
	return avatar_id


# 把数据库里的 "preset:avatar_012" 拆成 "avatar_012"。
# 认不出来的（例如以后的 upload:）返回空串，调用方回落到默认头像 ——
# **不要在这里报错**：一个客户端画不出来的头像不该让整页打不开。
static func id_from_value(value: String) -> String:
	if value.begins_with("preset:"):
		return value.substr("preset:".length())
	return ""


static func texture_for(value: String, thumb: bool = false) -> Texture2D:
	var id := id_from_value(value)
	if id.is_empty():
		id = str(_catalog().get("default_id", "avatar_001"))
	var path := thumb_path(id) if thumb else source_path(id)
	if path.is_empty() or not ResourceLoader.exists(path):
		# 缩略图没生成（忘了跑 make_avatar_thumbs.py）时退回原图，
		# 慢一点但画得出来。两个都没有才是真缺资源。
		path = source_path(id)
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D


static func frame_texture_for(value: String) -> Texture2D:
	var id := id_from_value(value)
	if id.is_empty():
		id = str(_catalog().get("default_frame_id", "frame_default"))
	var path := frame_source_path(id)
	if path.is_empty() or not ResourceLoader.exists(path):
		path = frame_source_path(str(_catalog().get("default_frame_id", "frame_default")))
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D
