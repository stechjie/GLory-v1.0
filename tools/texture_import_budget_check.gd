extends Node

# V2 P1-01 / P1-12 / P0-02 第 4 条：贴图导入合同与显存预算棘轮。
#
# 起因：真机实测反复指向「手机卡是贴图内存，不是 VFX」。这条门禁把那句话
# 变成可度量的数字，并锁住它不再恶化。
#
# 真正的病灶不是「没设尺寸上限」，是 **compress/mode=0（无损）**。
# Godot 给 2D/UI 贴图的默认就是无损 —— 因为 VRAM 压缩会在 UI 上出块状伪影。
# 但无损在安卓上意味着**解压成 RGBA8 进显存，4 字节/像素、没有 GPU 压缩**。
# 一张 4096×4096 的无损贴图就是 64 MB 显存，而它在磁盘上可能只有 3 MB ——
# 磁盘体积完全看不出这件事，所以 APK 大小正常、显存却爆掉。
#
# 2026-09-03 首次全量清点：749 张 PNG 里，**153 张同时满足**
# 「无损 + 无尺寸上限 + 至少一边 >= 1024px」，RGBA8 合计约 1204 MB。
# 对照：真正走 VRAM 压缩的 46 张一共才 65 MB。
#
# 判据是棘轮，**只降不升**，不做硬失败 —— 改 compress/mode 或 size_limit 是
# 画质决定（无损转 VRAM 压缩会在渐变和文字边缘出伪影），归美术/P1-01 负责人，
# 不该由一条门禁替他们一次性做完。这里只保证：
#   * 存量数得清、有台账；
#   * 新加的大无损贴图会立刻顶破这条线。
#
# 台账写到 reports/texture_import_budget.json，含每张的 mode / size_limit /
# 尺寸 / UID，供跨机比对（P0-02 第 4 条要求「同一 source 不允许在不同机器
# 生成不同导入合同」）。

const CheckHarness := preload("res://tools/CheckHarness.gd")

const CHECK_NAME := "texture_import_budget"
const OUT_PATH := "res://reports/texture_import_budget.json"  # asset-manifest-ignore

# 至少一边达到这个像素数才算「大图」。512 及以下即使无损也就 1 MB 级别。
const LARGE_EDGE := 1024

# compress/mode 取值（Godot 4）：0=Lossless 1=Lossy 2=VRAM Compressed 3=Uncompressed
const MODE_LOSSLESS := 0

# 「无损 + 无上限 + 大图」的张数上限。**只降不升。**
#
# 2026-09-03 首次清点实测 153 张、RGBA8 约 1204 MB，分布：
#   ui/treasure_cards 50 张 300 MB、models/battle_crystals 4 张 256 MB、
#   ui/crystals 10 张 160 MB、vfx/skills 35 张 137 MB、models/units 6 张 96 MB。
# 每处理一张就把这个数字调低。
const MAX_OVERSIZED_LOSSLESS := 153

# 显存估算上限（MB）。同样只降不升 —— 只降张数不降尺寸也可能没省下东西。
const MAX_LOSSLESS_VRAM_MB := 1210.0

const ROOT := "res://assets"

var _h: CheckHarness
var _rows: Array[Dictionary] = []
var _scanned := 0


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_walk(ROOT)

	var oversized := 0
	var oversized_bytes := 0
	for row in _rows:
		if bool(row["oversized"]):
			oversized += 1
			oversized_bytes += int(row["rgba8_bytes"])
	var oversized_mb := oversized_bytes / 1048576.0

	_h.item()
	_h.expect(_scanned >= 500, "too_few_textures_scanned",
		"只扫到 %d 张贴图导入合同，这条门禁等于没跑" % _scanned)
	# 非空过守卫：棘轮最危险的失效模式是「解析链断了 -> 数出 0 -> 继续绿」。
	# 只要工程里还有大图，这条就成立；全部处理完之后要连同棘轮一起删掉这条。
	_h.item()
	var peak := 0
	for row in _rows:
		peak = maxi(peak, int(row["max_edge"]))
	_h.expect(peak >= LARGE_EDGE, "measurement_vacuous",
		("全扫下来最大边只有 %d px，低于 %d —— 尺寸解析已经断了，"
			+ "这条门禁现在只是在空转") % [peak, LARGE_EDGE])

	_h.note("扫描 %d 张贴图导入合同；无损+无上限+>=%dpx 的 %d 张，RGBA8 约 %.0f MB"
		% [_scanned, LARGE_EDGE, oversized, oversized_mb])
	_report_by_dir()
	_write_ledger()

	_h.item()
	_h.expect(oversized <= MAX_OVERSIZED_LOSSLESS, "lossless_texture_backlog_grew",
		("无损大图有 %d 张，上限 %d（只降不升）。"
			+ "compress/mode=0 在安卓上是 RGBA8 进显存，4 字节/像素；"
			+ "改 mode 或加 process/size_limit 都能降，但那是画质决定，归 P1-01 负责人")
			% [oversized, MAX_OVERSIZED_LOSSLESS])
	_h.item()
	_h.expect(oversized_mb <= MAX_LOSSLESS_VRAM_MB, "lossless_vram_budget_grew",
		("无损大图 RGBA8 合计 %.0f MB，上限 %.0f MB（只降不升）。"
			+ "只降张数不降尺寸可能一点没省，所以张数和显存两条线都要守")
			% [oversized_mb, MAX_LOSSLESS_VRAM_MB])

	_h.finish(get_tree())


func _walk(dir_path: String) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var entry := d.get_next()
	while entry != "":
		if entry.begins_with("."):
			entry = d.get_next()
			continue
		var full := dir_path.path_join(entry)
		if d.current_is_dir():
			_walk(full)
		elif entry.ends_with(".import"):
			_scan_import(full)
		entry = d.get_next()
	d.list_dir_end()


func _scan_import(import_path: String) -> void:
	var text := FileAccess.get_file_as_string(import_path)
	if not text.contains("importer=\"texture\""):
		return
	var source := import_path.substr(0, import_path.length() - ".import".length())
	var size := _image_size(source)
	if size == Vector2i.ZERO:
		return
	_scanned += 1
	var mode := _int_field(text, "compress/mode=", 0)
	var limit := _int_field(text, "process/size_limit=", 0)
	var max_edge: int = maxi(size.x, size.y)
	var oversized := mode == MODE_LOSSLESS and limit == 0 and max_edge >= LARGE_EDGE
	_rows.append({
		"path": source, "width": size.x, "height": size.y, "max_edge": max_edge,
		"compress_mode": mode, "size_limit": limit,
		"uid": _string_field(text, "uid=\""),
		"rgba8_bytes": size.x * size.y * 4,
		"oversized": oversized,
	})


# 只读文件头，不解码 —— 解码 749 张大图会让这条门禁跑上几分钟。
func _image_size(path: String) -> Vector2i:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return Vector2i.ZERO
	var head := f.get_buffer(24)
	f.close()
	if head.size() < 24:
		return Vector2i.ZERO
	# PNG：8 字节签名 + 4 长度 + "IHDR" + 宽高各 4 字节大端
	if head[0] == 0x89 and head[1] == 0x50 and head[2] == 0x4E and head[3] == 0x47:
		return Vector2i(_be32(head, 16), _be32(head, 20))
	return Vector2i.ZERO


func _be32(buffer: PackedByteArray, offset: int) -> int:
	return (buffer[offset] << 24) | (buffer[offset + 1] << 16) \
		| (buffer[offset + 2] << 8) | buffer[offset + 3]


func _int_field(text: String, key: String, fallback: int) -> int:
	var at := text.find(key)
	if at < 0:
		return fallback
	var rest := text.substr(at + key.length(), 16)
	var digits := ""
	for i in rest.length():
		var c := rest[i]
		if c >= "0" and c <= "9":
			digits += c
		else:
			break
	return int(digits) if not digits.is_empty() else fallback


func _string_field(text: String, key: String) -> String:
	var at := text.find(key)
	if at < 0:
		return ""
	var start := at + key.length()
	var end := text.find("\"", start)
	return text.substr(start, end - start) if end > start else ""


func _report_by_dir() -> void:
	var by_dir := {}
	for row in _rows:
		if not bool(row["oversized"]):
			continue
		var parts := str(row["path"]).split("/")
		var key := "/".join(parts.slice(0, mini(5, parts.size())))
		if not by_dir.has(key):
			by_dir[key] = {"count": 0, "bytes": 0}
		var entry := by_dir[key] as Dictionary
		entry["count"] = int(entry["count"]) + 1
		entry["bytes"] = int(entry["bytes"]) + int(row["rgba8_bytes"])
	var keys := by_dir.keys()
	keys.sort_custom(func(a, b):
		return int((by_dir[a] as Dictionary)["bytes"]) > int((by_dir[b] as Dictionary)["bytes"]))
	for key in keys:
		var entry := by_dir[key] as Dictionary
		_h.note("  %-46s %3d 张  %7.1f MB"
			% [str(key), int(entry["count"]), int(entry["bytes"]) / 1048576.0])


func _write_ledger() -> void:
	_rows.sort_custom(func(a, b): return int(a["rgba8_bytes"]) > int(b["rgba8_bytes"]))
	var doc := {
		"generated_at": Time.get_datetime_string_from_system(true),
		"large_edge_px": LARGE_EDGE,
		"note": "compress_mode: 0=Lossless 1=Lossy 2=VRAM 3=Uncompressed",
		"scanned": _scanned,
		"textures": _rows,
	}
	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if f == null:
		_h.fail("ledger_write_failed", "无法写入 %s" % OUT_PATH)
		return
	f.store_string(JSON.stringify(doc, "  "))
	f.close()
	_h.note("导入合同台账已写到 %s" % OUT_PATH)
