class_name BattleStatsFormat
extends RefCounted
# 战后统计表格的单元格格式化（纯静态，无实例状态）。
# 原本只存在于备战链（PrepDetails 的「上局统计」弹窗），战斗链（officetest）继承不到，
# 于是抽到这里两边共用：PrepDetails 保留原方法名改为薄委托，officetest 直接调用。
# 注：静态化后 tr() 改用 TranslationServer.translate()（等价，全局翻译表）。

static func entry_stats_group(entry: Dictionary) -> String:
	var group := str(entry.get("group", ""))
	if group == "mercenary":
		return "enemy" if str(entry.get("team", "")) == "enemy" else "player"
	return group

static func stats_display_name(row: Dictionary) -> String:
	# Battle history rows also carry names by value. Resolve normal units by id so
	# an old pre-rename fight cannot reintroduce Shadow Mage in Last Battle.
	return sanitize_stats_cell(DataRegistry.unit_display_name(row, UnitDetailFormat.is_en()))

static func stats_display_position(row: Dictionary) -> String:
	if not UnitDetailFormat.is_en():
		return sanitize_stats_cell(str(row.get("position", "?")))
	var slot := int(row.get("slot", -1))
	if entry_stats_group(row) == "boss":
		return "Boss %d" % maxi(1, slot + 1)
	if bool(row.get("is_mercenary", false)):
		return "%s Merc %d" % ["Enemy" if str(row.get("team", "")) == "enemy" else "Ally", maxi(1, slot - 24)]
	if slot >= 0 and slot < GameConstants.CELL_COUNT:
		return "Board %d" % (slot + 1)
	return "%s %d" % ["Enemy" if str(row.get("team", "")) == "enemy" else "Ally", maxi(1, slot + 1)]

static func stats_color_cell(row: Dictionary, text: String) -> String:
	var owner_slot := int(row.get("owner_slot", -1))
	if owner_slot < 0:
		return text
	return "[color=#%s]%s[/color]" % [GameConstants.team_slot_color(owner_slot).to_html(false), text]

static func sanitize_stats_cell(text: String) -> String:
	return text.replace("[", "").replace("]", "")

static func format_status_bucket(value: Variant) -> String:
	if typeof(value) != TYPE_DICTIONARY:
		return "None" if UnitDetailFormat.is_en() else "无"
	var bucket: Dictionary = value
	if bucket.is_empty():
		return "None" if UnitDetailFormat.is_en() else "无"
	var keys := bucket.keys()
	keys.sort()
	var parts: Array[String] = []
	for key in keys:
		var seconds := float(bucket.get(key, 0.0))
		if seconds <= 0.05:
			continue
		if UnitDetailFormat.is_en():
			parts.append("%s %.1fs" % [status_display_name(str(key)), seconds])
		else:
			parts.append("%s %s秒" % [status_display_name(str(key)), format_seconds(seconds)])
	if UnitDetailFormat.is_en():
		return " + ".join(parts) if not parts.is_empty() else "None"
	return " + ".join(parts) if not parts.is_empty() else "无"

static func format_seconds(seconds: float) -> String:
	if is_equal_approx(seconds, round(seconds)):
		return str(int(round(seconds)))
	return "%.1f" % seconds

static func status_display_name(kind: String) -> String:
	var key := "status_" + kind
	var text := TranslationServer.translate(key)
	return text if text != key else kind
