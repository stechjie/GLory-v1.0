extends Node

# 9.24 临时验证探针（跑完即删）—— docx 第 (5) 条：
#   「法师：存在首次发动技能不播放技能音效，也没有技能弹道，只造成伤害的bug。需要进行修复。」
#
# 走真实路径，两条对照：
#   Part 1（live 散 tick）：`OfficeTestSim.build_test_state` 的真 state，逐 tick 喂
#           `BattleVfx._refresh_battle_vfx`。
#   Part 2（3v3 回放，**生产 seed 时序**）：`_start_replay` 的真实三步 ——
#           `_apply_replay_frame(0)` → `_prepare_battle_models()` 末尾的 `_refresh_visuals()`
#           （= 播种帧）→ 逐帧 `_apply_replay_frame` + `_refresh_visuals`。
#           `frames[0]` 是 **step 过 1 次之后** 的状态（`_replay_capture_frame` 在
#           `step_state` 之后才写），所以「第 0 tick 就施法的单位」的 skill_ready
#           上升沿正好落在播种帧之前 —— 这一路是本条 bug 的嫌疑现场。
#
# 两条独立读数：
#   A. **技能弹道**：SpyRoot 替身接管 `_battle_3d_vfx_root`（BattleUI 里声明为
#      Node3D），记录 composer 的 `play(effect_id, ...)`。`random_attribute_bolt`
#      出现即 = 弹道被派发。
#   B. **技能音效**：`SfxService.play_count(CUE_STAR4_MAGE_SKILL)`。
#
# ★ 只 `.new()`、不 add_child → 不跑 `_ready()` 的重型 3D 初始化，headless 不挂死。
# ★ 同一 cue 有 40 ms RETRIGGER_GUARD_MSEC；每次测量前 `reset_counters_for_check()`
#   （它同时清 `_last_play_msec`），并在测量前 await 70 ms。

const BattleVfxScript := preload("res://scenes/battle/BattleVfx.gd")
const ScreenScript := preload("res://officetest/OfficeTestScreen.gd")
const SfxService := preload("res://ui/services/SfxService.gd")
const OgaCatalog := preload("res://effects/vfx3d/units/OgaSkillVFXCatalog.gd")

const MAGE := "human_mage"
const MIL := "human_militia"
const MAGE_EFFECT := "random_attribute_bolt"

# 记录 composer 被要求播了什么。`play` 的签名照 `BossProceduralVFX3D.play`。
class SpyRoot extends Node3D:
	var calls: Array = []

	func play(effect_id: String, origin: Vector3, target: Vector3, context: Dictionary = {}) -> Node3D:
		calls.append({"id": effect_id, "origin": origin, "target": target})
		return null


var _fail := 0
var _checks := 0
var _saved_team_mode := false


func _ready() -> void:
	SfxService.install()
	for i in 5:
		await get_tree().process_frame
	_saved_team_mode = GameState.team_mode
	# 3v3 才有「友军」这条放宽判据；单人下两级判据等价。
	GameState.team_mode = true

	await _part_live()
	await _part_replay()
	_part_catalog()
	_part_wiring()

	GameState.team_mode = _saved_team_mode
	if _fail == 0:
		print("\nPROBE_DONE checks=%d fail=0" % _checks)
	else:
		print("\nPROBE_DONE checks=%d fail=%d" % [_checks, _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- Part 1: live 散 tick -----------------------------------------------------

func _part_live() -> void:
	var state: Dictionary = OfficeTestSim.build_test_state(_cfg())
	var vfx = BattleVfxScript.new()
	var spy := SpyRoot.new()
	vfx.set("_state", state)
	vfx.set("_battle_3d_vfx_root", spy)
	print("=== Part 1: live 逐 tick（红 slot0 = 4★法师 + 民兵；黄 slot3 = 3 民兵）===")
	print("  [diag] %s" % _mage_diag(state))

	# 播种帧（生产 live 路径里 `_prepare_battle_models()` 末尾那一次）。
	vfx.call("_refresh_battle_vfx", state)

	var rises := 0
	var rises_with_vfx := 0
	var rises_with_sfx := 0
	var lines: Array = []
	var tick := 0
	while tick < 4000 and not bool(state.get("finished", false)):
		var prev_ready := _mage_ready(state)
		BattleSimulator.step_state(state)
		var now_ready := _mage_ready(state)
		var rise := now_ready > prev_ready + 0.1
		if rise:
			SfxService.reset_counters_for_check()
			await _tick()
		var before := spy.calls.size()
		vfx.call("_refresh_battle_vfx", state)
		if rise:
			var vfx_hits := _mage_calls(spy, before)
			var sfx := SfxService.play_count(SfxService.CUE_STAR4_MAGE_SKILL)
			rises += 1
			if vfx_hits > 0:
				rises_with_vfx += 1
			if sfx > 0:
				rises_with_sfx += 1
			lines.append("tick=%-4d ready %.2f->%.2f  composer=%d  sfx=%d" % [
				tick, prev_ready, now_ready, vfx_hits, sfx])
		tick += 1

	print("  [live] 整场跑了 %d tick，法师施法 %d 次" % [tick, rises])
	for i in lines.size():
		print("      #%-2d %s" % [i + 1, lines[i]])
	_expect(rises > 0, true, "[live] 法师真的放过技能（上升沿 > 0）")
	_expect(rises_with_vfx, rises, "[live] 每次施法都派发了技能弹道（composer）")
	_expect(rises_with_sfx, rises, "[live] 每次施法都播了技能音效")


# --- Part 2: 3v3 回放（生产 seed 时序）----------------------------------------

func _part_replay() -> void:
	var replay: Dictionary = await OfficeTestSim.compute_test_replay_async(_cfg())
	var frames: Array = replay.get("frames", [])
	print("\n=== Part 2: 3v3 回放路径（生产 seed 时序）===")
	print("  [replay] frames=%d" % frames.size())
	var mage_uid := _replay_mage_uid(replay.get("roster", {}))
	_expect(not mage_uid.is_empty(), true, "[replay] 回放 roster 里找到法师 uid")
	if mage_uid.is_empty():
		return
	print("  [replay] 法师 uid=%s" % mage_uid)
	# 期望施法次数 = 逐帧 skill_ready 上升沿（与 BattleVfx 的判据同一公式）。
	var expected := 0
	var first_rise := -1
	var prev := -1.0
	for i in frames.size():
		var r := _frame_ready(frames, i, mage_uid)
		if r < 0.0:
			continue
		if prev >= 0.0 and r > prev + 0.1:
			expected += 1
			if first_rise < 0:
				first_rise = i
		prev = r
	# ★ 真实施法次数要把「frame 0 之前那一次」算进去：`frames[0]` 是 step 过 1 次
	#   之后的状态，所以 frames[0].skill_ready > 0 意味着第 0 tick 就施过法了
	#   （fighter 的 skill_ready 初值恒为 0.0，见 `_fighter_from_def`）。
	var pre_seed_cast := 1 if _frame_ready(frames, 0, mage_uid) > 0.1 else 0
	expected += pre_seed_cast
	print("  [replay] 模拟器真实施法 %d 次（其中 %d 次发生在 frames[0] 之前），首拍在第 %d 帧" % [
		expected, pre_seed_cast, first_rise])
	# 爆炸半径：frame 0 就已经 skill_ready > 0 的单位 = 在播种帧之前就施过法的单位，
	# 它们的首次施法演出在这一路全丢。
	var pre_cast: Array = []
	var roster: Dictionary = replay.get("roster", {})
	for uid in roster.keys():
		var r := _frame_ready(frames, 0, str(uid))
		if r > 0.1:
			pre_cast.append("%s(%s) ready=%.2f" % [
				str(uid), str((roster[uid] as Dictionary).get("id", "")), r])
	print("  [replay] frames[0] 已施法（skill_ready>0）的单位 %d 个：%s" % [pre_cast.size(), str(pre_cast)])

	# 生产 `_start_replay` 的真实顺序。
	var v = ScreenScript.new()
	var spy := SpyRoot.new()
	v.set("_battle_3d_vfx_root", spy)
	_prime(v, replay)
	v.call("_apply_replay_frame", 0)
	SfxService.reset_counters_for_check()
	await _tick()
	v.call("_refresh_battle_vfx", v.get("_state"))     # 播种帧
	var seed_vfx := _mage_calls(spy, 0)
	var seed_sfx := SfxService.play_count(SfxService.CUE_STAR4_MAGE_SKILL)
	print("  [replay] 播种帧：composer=%d sfx=%d" % [seed_vfx, seed_sfx])

	var got_vfx := seed_vfx
	var got_sfx := seed_sfx
	var per_frame: Array = []
	for i in range(1, frames.size()):
		v.call("_apply_replay_frame", i)
		SfxService.reset_counters_for_check()
		await _tick()
		var before := spy.calls.size()
		v.call("_refresh_battle_vfx", v.get("_state"))
		var hits := _mage_calls(spy, before)
		var sfx := SfxService.play_count(SfxService.CUE_STAR4_MAGE_SKILL)
		got_vfx += hits
		got_sfx += sfx
		if hits > 0 or sfx > 0:
			per_frame.append("frame=%-4d composer=%d sfx=%d" % [i, hits, sfx])
	print("  [replay] 实际 composer=%d sfx=%d（期望 %d 次）" % [got_vfx, got_sfx, expected])
	for line in per_frame:
		print("      %s" % line)
	_expect(got_vfx, expected, "[replay] 每次施法都有技能弹道（composer 派发）")
	_expect(got_sfx, expected, "[replay] 每次施法都有技能音效")


# --- Part 3: 弹道素材表（排除「目录里没这条元素」这类原因）------------------------

func _part_catalog() -> void:
	print("\n=== Part 3: OGA 元素弹道素材表 ===")
	for elem in ["fire", "ice", "thunder", "poison", "arcane"]:
		var spec: Dictionary = OgaCatalog.projectile_for_element(elem)
		var path := str(spec.get("path", ""))
		_expect(not path.is_empty(), true, "[catalog] %s 有弹道贴图" % elem)
		_expect(ResourceLoader.exists(path), true, "[catalog] %s 贴图存在" % elem)


# --- Part 4: 接线文本断言（防探针镜像与生产漂移）---------------------------------

func _part_wiring() -> void:
	print("\n=== Part 4: 接线 ===")
	var vfx_src := FileAccess.get_file_as_string("res://scenes/battle/BattleVfx.gd").replace("\r\n", "\n")
	var comp_src := FileAccess.get_file_as_string("res://effects/vfx3d/units/UnitSkillVFXComposer3D.gd").replace("\r\n", "\n")
	_expect(vfx_src.contains("\"random_attribute_bolt\", \"judgement_strike\""), true,
		"[wiring] BattleVfx 的 ACTIVE_UNIT_SKILLS 含 random_attribute_bolt")
	_expect(vfx_src.contains("context[\"attribute\"]=visual_elements[posmod("), true,
		"[wiring] BattleVfx 按 attack_count 选元素")
	_expect(comp_src.contains("\"random_attribute_bolt\":_oga_element_projectile(origin,target,context)"),
		true, "[wiring] composer 把 random_attribute_bolt 接到元素弹道")


# --- 工具 ---------------------------------------------------------------------

func _cfg() -> Dictionary:
	return {
		"placements": [
			{"slot": 0, "cell": 0, "kind": "piece", "unit_id": MAGE, "star": 4},
			{"slot": 0, "cell": 2, "kind": "piece", "unit_id": MIL, "star": 1},
			{"slot": 3, "cell": 0, "kind": "piece", "unit_id": MIL, "star": 1},
			{"slot": 3, "cell": 1, "kind": "piece", "unit_id": MIL, "star": 1},
			{"slot": 3, "cell": 3, "kind": "piece", "unit_id": MIL, "star": 1},
		],
		"slot_treasures": {},
	}


# 复刻 `BattleScreen._start_replay` 里「装载回放」的那几步（同 9.20 探针）。
func _prime(vfx, replay: Dictionary) -> void:
	vfx.set("_replay", replay)
	vfx.set("_replay_events_applied", -1)
	vfx.call("_load_replay_roster", replay)
	vfx.call("_reseat_vfx_diff_for_new_battle")


func _mage_ready(state: Dictionary) -> float:
	for side in ["player", "enemy"]:
		for f in state.get(side, []):
			if typeof(f) == TYPE_DICTIONARY and str((f as Dictionary).get("id", "")) == MAGE:
				return float((f as Dictionary).get("skill_ready", 0.0))
	return 0.0


func _mage_diag(state: Dictionary) -> String:
	for side in ["player", "enemy"]:
		for f in state.get(side, []):
			if typeof(f) != TYPE_DICTIONARY:
				continue
			var d: Dictionary = f
			if str(d.get("id", "")) != MAGE:
				continue
			return "法师 uid=%s side=%s star=%s owner_slot=%s skill_id=%s skill_ready=%.2f" % [
				str(d.get("uid", "")), side, str(d.get("star", "")), str(d.get("owner_slot", "")),
				str(d.get("def", {}).get("skill_id", "")), float(d.get("skill_ready", 0.0))]
	return "[diag] 场上没有法师"


# 回放帧数组下标照 `_replay_capture_frame`：0 uid / 1 x / 2 y / 3 hp / 4 alive /
# 5 attack_count / 6 skill_ready ...
# uid 形如 `player_human_mage_0`（不是 unit id 的子串判据），所以按 roster 的
# `id` 字段取 —— 逐帧扫字符串会在 officetest 的 `test_s0_c0` 命名下失手。
func _replay_mage_uid(roster: Dictionary) -> String:
	for uid in roster.keys():
		var info = roster[uid]
		if typeof(info) == TYPE_DICTIONARY and str((info as Dictionary).get("id", "")) == MAGE:
			return str(uid)
	return ""


func _frame_ready(frames: Array, i: int, uid: String) -> float:
	if i < 0 or i >= frames.size() or typeof(frames[i]) != TYPE_ARRAY:
		return -1.0
	for entry in frames[i]:
		if typeof(entry) == TYPE_ARRAY and (entry as Array).size() > 6 and str(entry[0]) == uid:
			return float(entry[6])
	return -1.0


# 从 `from` 开始数本帧派发的法师技能弹道次数。
func _mage_calls(spy, from: int) -> int:
	var n := 0
	var all: Array = spy.calls
	for i in range(from, all.size()):
		if str((all[i] as Dictionary).get("id", "")) == MAGE_EFFECT:
			n += 1
	return n


func _tick() -> void:
	await get_tree().create_timer(0.07).timeout


func _expect(got, want, label: String) -> void:
	_checks += 1
	var ok: bool = got == want
	if not ok:
		_fail += 1
	print("  %s %-58s got=%s want=%s" % ["PASS" if ok else "FAIL", label, str(got), str(want)])
