extends Node

# 棋盘皮肤的门禁（docs/棋盘皮肤.md）：加一张新皮肤之后跑它。
#
# 护的是几种「不报错、只是悄悄显示成草地」的失误：
#   - 皮肤文件夹没拷到出包那台电脑（美术不进 git）→ 玩家买到的是一张青草地
#   - 忘了生成预览图 → 备战页和商城卡片上是一整张没裁的底图
#   - data/prep_skins.json 里的键写错（river_glwo）→ 设置静默不生效
#   - data/shop.json 卖了一张目录里没有的皮肤 → 新包把它藏掉，卖不出去也没人发现
#
# 跑：Godot --headless --path . res://tools/prep_skin_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const PrepSkin := preload("res://scenes/prep/PrepSkin.gd")
const CHECK_NAME := "prep_skin"
const SHOP_PATH := "res://data/shop.json"
const ALLOWED_KEYS := ["id", "name", "name_en", "firefly_color", "river_glow"]

var _h: RefCounted


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	DataRegistry.load_all()
	var skins := PrepSkin.catalog()
	_h.expect(not skins.is_empty(), "catalog_empty", "data/prep_skins.json 没有任何皮肤")
	if not skins.is_empty():
		_h.expect(str((skins[0] as Dictionary).get("id", "")) == PrepSkin.DEFAULT_ID,
			"default_not_first", "第一张必须是默认皮肤 %s" % PrepSkin.DEFAULT_ID)
	var id_format := RegEx.create_from_string("^prep_skin_[a-z0-9_]{1,54}$")
	var seen := {}
	for raw in skins:
		var entry := raw as Dictionary
		var skin_id := str(entry.get("id", ""))
		_h.expect(id_format.search(skin_id) != null, "bad_id",
			"皮肤 id「%s」不符合 prep_skin_小写字母数字下划线（账号服务器存不进去）" % skin_id)
		_h.expect(not seen.has(skin_id), "duplicate_id", "皮肤 id 重复：%s" % skin_id)
		seen[skin_id] = true
		_check_entry(skin_id, entry)
	_check_shop(seen)
	_h.finish(get_tree())


func _check_entry(skin_id: String, entry: Dictionary) -> void:
	for key in entry:
		_h.expect(str(key) in ALLOWED_KEYS, "unknown_key",
			"%s 里有不认识的键「%s」（写错了的设置会静默不生效）" % [skin_id, str(key)])
	_h.expect(not str(entry.get("name", "")).is_empty() and not str(entry.get("name_en", "")).is_empty(),
		"missing_name", "%s 缺中文或英文名字" % skin_id)
	if entry.has("firefly_color"):
		var color: Variant = entry["firefly_color"]
		var ok := color is Array and (color as Array).size() == 3
		if ok:
			for part in color:
				ok = ok and (part is float or part is int) and float(part) >= 0.0 and float(part) <= 1.0
		_h.expect(ok, "bad_firefly_color", "%s 的 firefly_color 要是 3 个 0~1 的数" % skin_id)
	if entry.has("river_glow"):
		_h.expect(entry["river_glow"] is bool, "bad_river_glow", "%s 的 river_glow 要是 true / false" % skin_id)
	if skin_id != PrepSkin.DEFAULT_ID:
		var board := PrepSkin.SKIN_FILE % [skin_id, "board"]
		_h.expect(ResourceLoader.exists(board), "skin_images_missing",
			"%s 没有自己的 board.png —— 皮肤文件夹没拷过来，或者还没 --import（%s）" % [skin_id, board])
	var preview := PrepSkin.SKIN_FILE % [skin_id, "preview"]
	_h.expect(ResourceLoader.exists(preview), "preview_missing",
		"%s 没有 preview.png —— 在皮肤预览场景里点「生成预览图」（%s）" % [skin_id, preview])
	for slot in PrepSkin.SLOTS:
		var path := PrepSkin.path_for(skin_id, str(slot))
		_h.expect(ResourceLoader.exists(path), "slot_unresolved", "%s 的 %s 找不到图：%s" % [skin_id, slot, path])


func _check_shop(catalog_ids: Dictionary) -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(SHOP_PATH))
	_h.expect(parsed is Dictionary, "shop_unreadable", "读不了 %s" % SHOP_PATH)
	if not (parsed is Dictionary):
		return
	for raw in (parsed as Dictionary).get("items", []):
		var item := raw as Dictionary
		if str(item.get("kind", "")) != "prep_skin":
			continue
		var grants := str(item.get("grants", ""))
		_h.expect(catalog_ids.has(grants), "sold_skin_not_in_catalog",
			"shop.json 的 %s 卖的 %s 不在 data/prep_skins.json 里（新包会把它藏掉）" % [str(item.get("id", "")), grants])
		_h.expect(grants != PrepSkin.DEFAULT_ID, "default_skin_sold", "默认皮肤不许卖（所有人会一夜失去它）")
