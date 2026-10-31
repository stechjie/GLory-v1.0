extends Node

# 羁绊跨档画面反馈门禁（10.31）。
#
# 反馈：「棋子羁绊生效的时候，在备战区没有特效。」
# 判跨档的口径沿用声音那条（PrepUI._check_synergy_activation，已解锁档位集合），
# 本门禁只盯画面分档有没有按约定出：
#
#   1. 进场第一帧棋盘已是 7 神 —— 不出任何特效（旧战果不是新闻）；
#   2. minor（该族第 1 档）—— 棋盘不出光环；
#   3. major（神 2 -> 3）—— 棋盘上**每一枚**神都有一份光环，且不出终极档的暗角 / 弹字；
#   4. ultimate（神 6 -> 7）—— 每枚神一份光环（带光柱）+ 屏幕暗角 + 档位名弹字；
#   5. 只换一族时另一族的棋子不亮（人族棋子不该跟着神族亮）。
#
# 每条「没出」都有一条「该出」的正对照，避免「整条路径从不出特效」也全绿。
# 夹具直接写 board_slots，与 synergy_activation_sfx_check 同一套（理由见那边顶部）。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const SynergyService := preload("res://scripts/units/SynergyService.gd")
const PrepScript := preload("res://scenes/prep/PrepScreen.gd")
const BurstScript := preload("res://scenes/prep/effects/PrepSynergyActivateBurst.gd")

const CHECK_NAME := "synergy_activation_fx"
const PREP_SCENE := "res://scenes/prep/PrepScreen.tscn"

const GOD_IDS := [
	"god_priest", "god_priestess", "god_guard", "god_aurora",
	"god_angel", "god_arbiter", "god_archangel", "god_king",
]
const HUMAN_IDS := [
	"human_militia", "human_merchant", "human_archer", "human_swordsman",
]

var _h: CheckHarness
var _defs: Dictionary = {}


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	GameState.reset_run()
	await get_tree().process_frame
	_h.expect(not GameState.tutorial_mode, "tutorial_mode_on", "教程模式下采样点会错位")

	await _case_entry_silent()
	await _case_tiers()

	_clear_board()
	_h.finish(get_tree())


func _case_entry_silent() -> void:
	_set_board(7, 0)
	var prep := _new_prep()
	if prep == null:
		return
	await _wait(0.3)
	_h.expect(_bursts(prep).is_empty(), "entry_burst",
		"刚进备战页就为既有的 7 神出了 %d 份羁绊光环" % _bursts(prep).size())
	_h.expect(not _has_screen_fx(prep), "entry_screen_fx", "刚进备战页就弹了终极羁绊暗角 / 弹字")
	prep.queue_free()
	await _wait(0.1)


func _case_tiers() -> void:
	var prep := _new_prep()
	if prep == null:
		return
	await _wait(0.2)

	# 2. minor：0 -> 1 神（god 第 1 档特性）
	_set_board(0, 2)
	prep._refresh_all()
	await _wait(1.2)
	_set_board(1, 2)
	prep._refresh_all()
	await _wait(0.25)
	_h.expect(_bursts(prep).is_empty(), "minor_board_burst",
		"神第 1 档（特性）出了 %d 份棋盘光环 —— 只该弹面板图标" % _bursts(prep).size())

	# 3. major：2 -> 3 神
	_set_board(2, 2)
	prep._refresh_all()
	await _wait(1.2)
	_set_board(3, 2)
	prep._refresh_all()
	await _wait(0.25)
	var models := _board_model_count(prep)
	_h.expect(models == 5, "fixture_models_missing",
		"夹具摆了 5 枚棋子，棋盘模型只建出 %d 个 —— 后面「每枚都有」的断言会失真" % models)
	var bursts := _bursts(prep)
	_h.expect(bursts.size() == 3, "major_burst_count",
		"神 2 -> 3（中间档）应给 3 枚神各一份光环，实际 %d 份（人族不该跟着亮）" % bursts.size())
	_h.expect(not _any_pillar(bursts), "major_has_pillar", "中间档不该带终极档的光柱")
	_h.expect(not _has_screen_fx(prep), "major_screen_fx", "中间档弹了终极档的暗角 / 弹字")

	# 同一状态再采样：不许重放
	await _wait(1.2)
	prep._refresh_all()
	await _wait(0.25)
	_h.expect(_bursts(prep).is_empty(), "idle_resample_burst",
		"棋盘没变再采样一次，又出了 %d 份光环" % _bursts(prep).size())

	# 4. ultimate：6 -> 7 神
	_set_board(6, 2)
	prep._refresh_all()
	await _wait(1.2)
	_set_board(7, 2)
	prep._refresh_all()
	await _wait(0.3)
	bursts = _bursts(prep)
	_h.expect(bursts.size() == 7, "ultimate_burst_count",
		"神 6 -> 7（终极档）应给 7 枚神各一份光环，实际 %d 份" % bursts.size())
	_h.expect(_any_pillar(bursts), "ultimate_no_pillar", "终极档光环没有光柱")
	_h.expect(_has_screen_fx(prep), "ultimate_no_screen_fx", "终极档没有屏幕暗角 / 档位名弹字")
	var caption := prep.find_child("SynergyTierCaption", true, false) as Label
	_h.expect(caption != null and not caption.text.is_empty(), "ultimate_caption_empty",
		"终极档弹字没有档位名")
	_h.expect(_screen_fx_ignores_mouse(prep), "screen_fx_blocks_mouse",
		"终极档全屏层会吃掉鼠标 —— 玩家这时很可能在拖下一枚棋子")

	# 全部播完要自己清掉
	await _wait(1.5)
	_h.expect(_bursts(prep).is_empty(), "burst_not_freed", "光环播完没有自行释放")
	_h.expect(not _has_screen_fx(prep), "screen_fx_not_freed", "暗角 / 弹字播完没有自行释放")

	prep.queue_free()
	await _wait(0.1)


# --- 观测 ---------------------------------------------------------------------

func _bursts(root: Node) -> Array:
	var out: Array = []
	_collect_bursts(root, out)
	return out


func _collect_bursts(node: Node, out: Array) -> void:
	for child in node.get_children():
		if child.get_script() == BurstScript and not child.is_queued_for_deletion():
			out.append(child)
		_collect_bursts(child, out)


func _any_pillar(bursts: Array) -> bool:
	for b in bursts:
		if b.get("_pillar") != null:
			return true
	return false


func _has_screen_fx(prep: Node) -> bool:
	for n in ["SynergyVignette", "SynergyTierCaption"]:
		var found := prep.find_child(n, true, false)
		if found != null and not found.is_queued_for_deletion():
			return true
	return false


func _screen_fx_ignores_mouse(prep: Node) -> bool:
	for n in ["SynergyVignette", "SynergyTierCaption"]:
		var c := prep.find_child(n, true, false) as Control
		if c == null or c.mouse_filter != Control.MOUSE_FILTER_IGNORE:
			return false
	return true


func _board_model_count(prep: PrepScript) -> int:
	var n := 0
	for key in prep._prep_board_model_nodes:
		if is_instance_valid(prep._prep_board_model_nodes[key]):
			n += 1
	return n


# --- 夹具 ---------------------------------------------------------------------

func _new_prep() -> PrepScript:
	var packed := load(PREP_SCENE) as PackedScene
	if not _h.expect(packed != null, "prep_scene_load_failed", "%s 加载不出来" % PREP_SCENE):
		return null
	var prep = packed.instantiate() as PrepScript
	add_child(prep)
	return prep


func _clear_board() -> void:
	GameState.board_slots.resize(GameConstants.CELL_COUNT)
	for i in GameConstants.CELL_COUNT:
		GameState.board_slots[i] = null


func _set_board(god_count: int, human_count: int) -> void:
	_clear_board()
	var idx := 0
	for i in mini(god_count, GOD_IDS.size()):
		GameState.board_slots[idx] = _cell(GOD_IDS[i], "g%d" % i)
		idx += 1
	for i in mini(human_count, HUMAN_IDS.size()):
		GameState.board_slots[idx] = _cell(HUMAN_IDS[i], "h%d" % i)
		idx += 1
	var counts := SynergyService.count_races_from_board()
	_h.expect(int(counts.get("god", -1)) == god_count and int(counts.get("human", -1)) == human_count,
		"board_counts_mismatch", "夹具摆了 %d 神 %d 人，SynergyService 数到 %s" % [god_count, human_count, counts])


func _cell(unit_id: String, uid: String) -> Dictionary:
	if _defs.is_empty():
		for cand in DataRegistry.get_table("race_units").get("units", []):
			_defs[str((cand as Dictionary).get("id", ""))] = cand
	if not _defs.has(unit_id):
		_h.expect(false, "fixture_unit_missing", "数据表里找不到棋子 %s" % unit_id)
		return {}
	return {"id": unit_id, "uid": uid, "star": 3,
		"def": (_defs[unit_id] as Dictionary).duplicate(true), "is_mercenary": false}


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout
