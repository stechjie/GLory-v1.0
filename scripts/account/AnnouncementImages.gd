extends Node

# 公告图片的下载、校验与缓存（docs/公告系统设计.md）。AnnouncementService 的子节点。
#
# 服务器取回图片时已经检查过大小、格式和尺寸，并把内容的 SHA-256 写在列表里。
# 这里下载完**逐字节校验哈希**：拿到的一定就是服务器检查过的那份文件 ——
# 中途被换、下载截断、本地缓存损坏都会被认出来，认不出的一律不解码。解码后再判一次长边，只是兜底。
#
# 缓存：user://announcement_images/<sha256>.<ext>。同一个哈希永远是同一张图，不需要过期判断；
# 只清「列表里已经没有、并且 KEEP_UNUSED_SEC 之前下载的」文件（prune）。
#
# **只下载账号服务器自己的 /media/ 地址**。列表里就算出现别的地址也不去。

signal load_finished(sha: String)

const AccountConfig := preload("res://scripts/account/AccountConfig.gd")

# 与 backend/app/announcements.py 的 IMAGE_MAX_BYTES / IMAGE_MAX_SIDE 一致（tools/announcement_check 钉着）。
const MAX_BYTES := 512 * 1024
const MAX_SIDE := 2048
const EXTENSIONS := ["png", "jpg", "webp"]
const CACHE_DIR := "user://announcement_images"
const KEEP_UNUSED_SEC := 7 * 86400
# 内存里最多留几张贴图。公告同时在线的通常就几条。
const MEMORY_CACHE_LIMIT := 12
const REQUEST_TIMEOUT_SEC := 20.0

var _textures: Dictionary = {}  # sha -> Texture2D
var _recent: Array[String] = []  # 最近用过的在后面；超过上限从前面丢
var _loading: Dictionary = {}  # sha -> true
var _failed: Dictionary = {}  # sha -> true：这次启动里失败过，不反复下载


# 公告里的 image 字典 -> 贴图。没图、不合规、下载或解码失败都返回 null（界面只显示文字，不弹错误）。
func texture_for(image: Variant) -> Texture2D:
	if not (image is Dictionary):
		return null
	var info: Dictionary = image
	var url := str(info.get("url", ""))
	var sha := str(info.get("sha256", ""))
	if not is_valid_ref(url, sha):
		return null
	# 同一张图同时被列表和弹窗要：只下一次，后来的等前面那个。
	while _loading.has(sha):
		await load_finished
	if _textures.has(sha):
		_touch(sha)
		return _textures[sha]
	if _failed.has(sha):
		return null
	_loading[sha] = true
	var texture: Texture2D = await _load(url, sha)
	_loading.erase(sha)
	if texture == null:
		_failed[sha] = true
	else:
		_remember(sha, texture)
	load_finished.emit(sha)
	return texture


# 地址必须恰好是 /media/<小写哈希>.<png|jpg|webp>，而且哈希与字段里的一致。
static func is_valid_ref(url: String, sha: String) -> bool:
	var ext := url.get_extension()
	return sha.length() == 64 and sha.is_valid_hex_number() and sha == sha.to_lower() \
		and ext in EXTENSIONS and url == "/media/%s.%s" % [sha, ext]


static func sha256_hex(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()


static func bytes_match(bytes: PackedByteArray, sha: String) -> bool:
	return not bytes.is_empty() and bytes.size() <= MAX_BYTES and sha256_hex(bytes) == sha


static func decode(bytes: PackedByteArray, ext: String) -> Texture2D:
	var image := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	match ext:
		"png":
			err = image.load_png_from_buffer(bytes)
		"jpg":
			err = image.load_jpg_from_buffer(bytes)
		"webp":
			err = image.load_webp_from_buffer(bytes)
	if err != OK or image.is_empty():
		return null
	if maxi(image.get_width(), image.get_height()) > MAX_SIDE:
		return null
	return ImageTexture.create_from_image(image)


static func cache_path(sha: String, ext: String) -> String:
	return "%s/%s.%s" % [CACHE_DIR, sha, ext]


# 清掉列表里已经没有、并且 KEEP_UNUSED_SEC 之前下载的缓存。referenced：sha -> true。返回删了几个。
func prune(referenced: Dictionary) -> int:
	var dir := DirAccess.open(CACHE_DIR)
	if dir == null:
		return 0
	var now := int(Time.get_unix_time_from_system())
	var removed := 0
	for file_name in dir.get_files():
		if referenced.has(file_name.get_basename()):
			continue
		var path := CACHE_DIR + "/" + file_name
		if now - int(FileAccess.get_modified_time(path)) < KEEP_UNUSED_SEC:
			continue
		if DirAccess.remove_absolute(path) == OK:
			removed += 1
	return removed


# --- 内部 ---------------------------------------------------------------------

func _load(url: String, sha: String) -> Texture2D:
	var ext := url.get_extension()
	var path := cache_path(sha, ext)
	if FileAccess.file_exists(path):
		var cached := FileAccess.get_file_as_bytes(path)
		if bytes_match(cached, sha):
			return decode(cached, ext)
		# 缓存坏了（写到一半被杀、存储出错）：删掉重下。
		DirAccess.remove_absolute(path)
	var bytes: PackedByteArray = await _download(url)
	if not bytes_match(bytes, sha):
		return null
	var texture := decode(bytes, ext)
	if texture != null:
		_write_cache(path, bytes)
	return texture


func _download(url: String) -> PackedByteArray:
	var http := HTTPRequest.new()
	http.timeout = REQUEST_TIMEOUT_SEC
	# 引擎层就截断：服务器配错了也不会把一个大文件整个读进内存。
	http.body_size_limit = MAX_BYTES
	add_child(http)
	var err := http.request(AccountConfig.endpoint(url))
	if err != OK:
		http.queue_free()
		return PackedByteArray()
	var result: Array = await http.request_completed
	http.queue_free()
	if int(result[0]) != HTTPRequest.RESULT_SUCCESS or int(result[1]) != 200:
		return PackedByteArray()
	return result[3] as PackedByteArray


# 写不进去只是下次再下一遍，不报错。先写临时文件再改名：被杀在半路也不会留下半截图。
func _write_cache(path: String, bytes: PackedByteArray) -> void:
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	f.store_buffer(bytes)
	f.close()
	DirAccess.rename_absolute(tmp, path)


func _remember(sha: String, texture: Texture2D) -> void:
	_textures[sha] = texture
	_touch(sha)
	while _recent.size() > MEMORY_CACHE_LIMIT:
		_textures.erase(_recent.pop_front())


func _touch(sha: String) -> void:
	_recent.erase(sha)
	_recent.append(sha)
