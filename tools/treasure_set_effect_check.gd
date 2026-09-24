extends Node

# 五个 4 件套装在**组队模式**下是否真的生效（线上 3v3 与离线自测都走组队模式，
# 只有新手教学不是）。每项都对比「凑齐 4 件」与「同类只有 3 件」，全部调用真实的
# 战斗 / 账本代码，不复制判定逻辑。
#
# 9.24：4 攻击改为「≤10% 斩杀」，4 控制改为「普攻补刀刷新技能」；本脚本同步改了
# 对应两段探针，并加了目标锁定的探针。冥界执行者 death_hunt 仍验证低血优先。

const Harness := preload("res://tools/CheckHarness.gd")
const TreasureChoicePanelScript := preload("res://scenes/prep/panels/TreasureChoicePanel.gd")

const DEF_3 := ["def_formation_heal", "def_soul_counter", "def_lifesteal_emblem"]
const DEF_4 := ["def_formation_heal", "def_soul_counter", "def_lifesteal_emblem", "def_iron_wall"]
const ATK_3 := ["atk_blood_pact", "atk_burst_core", "atk_frenzy_assault"]
const ATK_4 := ["atk_blood_pact", "atk_burst_core", "atk_frenzy_assault", "atk_fury_roster"]
const ELEM_3 := ["elem_flame_shatter", "elem_frost_blade", "elem_thunder_haste"]
const ELEM_4 := ["elem_flame_shatter", "elem_frost_blade", "elem_thunder_haste", "elem_toxic_spread"]
const CTRL_3 := ["ctrl_shockwave", "ctrl_corrosive_needle", "ctrl_interrupt_chain"]
const CTRL_4 := ["ctrl_shockwave", "ctrl_corrosive_needle", "ctrl_interrupt_chain", "ctrl_binding_weight"]
const MONEY_3 := ["money_compound", "money_generous_fate", "money_discount"]
const MONEY_4 := ["money_compound", "money_generous_fate", "money_discount", "money_lucky_envelope"]

var _h


func _ready() -> void:
	_h = Harness.new("treasure_set_effect")
	_probe_defense()
	_probe_attack_targeting()
	_probe_element()
	_probe_control()
	_probe_money()
	_probe_codex_sets()
	GameState.reset_run()
	GameState.team_mode = false
	NetworkService.team_active = false
	NetworkService.team_boards = {}
	_h.finish(get_tree())


# --- helpers -----------------------------------------------------------------

func _plain_def(id: String, atk: int) -> Dictionary:
	return {"id": id, "name": id, "hp": 3000, "atk": atk, "def": 0,
		"attack_speed": 1.0, "range": 1, "move_speed": 3.0, "crit": 0.0, "crit_dmg": 1.0,
		"skill_id": "none", "tier": 1, "element": "-", "race": "-"}


func _fighter(d: Dictionary, team: String, lane: int, treasures: Array) -> Dictionary:
	var f: Dictionary = BattleSimShared._fighter_from_def(d.duplicate(true), 0, team, 0, 1, 1, false, false)
	f["lane"] = lane
	f["owner_treasures"] = treasures.duplicate()
	f["owner_syn"] = {}
	return f


func _target(team: String, lane: int, uid: String, max_hp: int, hp: int, pos: Vector2) -> Dictionary:
	var f := _fighter(_plain_def("probe_" + uid, 0), team, lane, [])
	f.uid = uid
	f.max_hp = max_hp
	f.hp = hp
	f.pos = pos
	return f


func _state(player: Array, enemy: Array) -> Dictionary:
	var st := {
		"kind": "pvp", "player": player, "enemy": enemy, "elapsed": 0.0,
		"next_decay": BattleSimShared.DECAY_START_SEC, "finished": false, "log": [],
		"player_syn": {}, "enemy_syn": {}, "enemy_deaths": 0, "total_deaths": 0,
		"field_death_count": 0, "mother_death_counter": 0, "dark_kill_stacks": 0,
		"undead_trait_death_counter": 0, "race_trait_processed_deaths": {},
		"death_history": [], "revive_queue": [], "player_kill_gold": 0, "enemy_kill_gold": 0,
		"kill_gold_by_slot": {}, "player_kills": [], "enemy_kills": [], "bonus_gold": 0,
		"temporary_deaths": [], "visual_events": [], "unit_stats": {},
	}
	BattleSimShared._init_unit_stats(st)
	DamageService.set_stat_state(st)
	return st


# Same setup as tools/ai_survival_curve_check.gd: the online 3v3 path, where
# every seat's treasures arrive in its board snapshot.
func _team_state_with(slot0_treasures: Array) -> Dictionary:
	GameState.reset_run()
	GameState.team_mode = true
	GameState.round_index = 10
	NetworkService.team_active = true
	NetworkService.team_local_slot = 0
	NetworkService.shared_seed = 424242
	NetworkService.team_slot_states = ["player", "player", "player", "player", "player", "player"]
	var boards: Dictionary = {}
	for slot in 6:
		var rng := RandomNumberGenerator.new()
		rng.seed = 424242 * 10 + slot
		var board := BattleSimShared.build_dummy_board(rng)
		boards[slot] = {
			"version": NetProtocol.SNAPSHOT_VERSION, "round": 10, "board": board,
			"mercenaries": [], "treasures": slot0_treasures.duplicate() if slot == 0 else [],
			"syn": NetProtocol.rebuild_syn_from_board(board), "pet": "",
		}
	NetworkService.team_boards = boards
	return BattleSimulator.prepare_team_state(0)


func _lane0_units(state: Dictionary) -> Array:
	var out: Array = []
	for f in state.get("player", []):
		if str(f.get("uid", "")).begins_with("player_L0_") and not BattleSimShared._ignores_treasure(f):
			out.append(f)
	return out


# --- 4 defense ---------------------------------------------------------------

func _probe_defense() -> void:
	var s3 := _team_state_with(DEF_3)
	var s4 := _team_state_with(DEF_4)
	var u3 := _lane0_units(s3)
	var u4 := _lane0_units(s4)
	if not _h.expect(not u3.is_empty() and u3.size() == u4.size(), "defense_setup", "lane 0 units: %d vs %d" % [u3.size(), u4.size()]):
		return
	for i in u3.size():
		var a: Dictionary = u3[i]
		var b: Dictionary = u4[i]
		var hp_ratio := float(b.max_hp) / float(maxi(1, int(a.max_hp)))
		var expected_def := int(round(float(a.defense) * 1.30)) + 10
		var dodge_delta := float(b.get("dodge", 0.0)) - float(a.get("dodge", 0.0))
		print("[defense] %s  hp %d -> %d (x%.3f)  def %d -> %d (expect %d)  dodge +%.2f" % [
			str(a.uid), int(a.max_hp), int(b.max_hp), hp_ratio, int(a.defense), int(b.defense), expected_def, dodge_delta])
		_h.expect(absf(hp_ratio - 1.30) < 0.02, "defense_hp", "%s hp x%.3f" % [str(a.uid), hp_ratio])
		_h.expect(int(b.defense) == expected_def, "defense_def", "%s def %d != %d" % [str(a.uid), int(b.defense), expected_def])
		_h.expect(absf(dodge_delta - 0.15) < 0.001, "defense_dodge", "%s dodge +%.3f" % [str(a.uid), dodge_delta])


# --- 4 attack: execute (9.24 改版) ----------------------------------------------
# 旧版「优先打生命比例最低」已删除，改为：普攻打完目标 ≤10% 生命 → 斩杀；
# Boss 不吃；无敌挡不住。另外顺带验证 9.24 的目标锁定。

func _pick_with(attacker: Dictionary) -> String:
	var near := _target("enemy", 0, "near_full_hp", 3000, 3000, Vector2(500.0, 340.0))
	var far := _target("enemy", 0, "far_low_hp", 3000, 300, Vector2(500.0, 160.0))
	attacker.pos = Vector2(500.0, 420.0)
	return str(BattleSimShared._select_target(attacker, [near, far]).get("uid", ""))


func _hit_once(treasures: Array, target_hp: int, boss: bool, invulnerable: bool) -> Dictionary:
	RngService.rng.seed = 91
	var a := _fighter(_plain_def("probe_atk", 100), "player", 0, treasures)
	a.pos = Vector2(500.0, 330.0)
	var tgt := _target("enemy", 0, "target", 3000, target_hp, Vector2(500.0, 300.0))
	if boss:
		tgt.def["is_boss"] = true
	if invulnerable:
		StatusEffectService.add_status(tgt, "invulnerable", 5.0, {})
	var st := _state([a], [tgt])
	DamageService.begin_stat_context(st, a)
	BattleSimulator._perform_attack(a, tgt, st)
	DamageService.clear_stat_context()
	return tgt


func _probe_attack_targeting() -> void:
	GameState.team_mode = true
	# 350 血挨 100 → 250（≤300 = 10%）
	var t3 := _hit_once(ATK_3, 350, false, false)
	var t4 := _hit_once(ATK_4, 350, false, false)
	var tb := _hit_once(ATK_4, 350, true, false)
	var ti := _hit_once(ATK_4, 200, false, true)
	var th := _hit_once(ATK_4, 1000, false, false)
	print("[attack] 3 treasures hp=%d alive=%s ; 4 treasures hp=%d alive=%s ; boss alive=%s ; invulnerable alive=%s ; 1000hp target hp=%d" % [
		int(t3.hp), str(t3.alive), int(t4.hp), str(t4.alive), str(tb.alive), str(ti.alive), int(th.hp)])
	_h.expect(bool(t3.alive) and int(t3.hp) == 250, "attack_baseline", "without the set the target should survive at 250, got %d" % int(t3.hp))
	_h.expect(not bool(t4.alive) and int(t4.hp) == 0, "attack_set_execute", "with the set a <=10%% target should be executed, hp=%d" % int(t4.hp))
	_h.expect(bool(tb.alive), "attack_set_boss", "bosses must not be executed")
	_h.expect(not bool(ti.alive), "attack_set_invulnerable", "invulnerability must not block the execute")
	_h.expect(bool(th.alive) and int(th.hp) == 900, "attack_set_threshold", "a target above 10%% must just take damage, hp=%d" % int(th.hp))

	# 4 攻击不再改选敌：凑齐 4 件也选最近的。
	var p4 := _pick_with(_fighter(_plain_def("probe_atk", 100), "player", 0, ATK_4))
	_h.expect(p4 == "near_full_hp", "attack_set_no_retarget", "4 attack set should no longer change targeting, got %s" % p4)

	var merc_def: Dictionary = {}
	for m in DataRegistry.get_table("mercenaries").get("mercenaries", []):
		if str(m.get("skill_id", "")) == "death_hunt":
			merc_def = (m as Dictionary).duplicate(true)
	var merc: Dictionary = BattleSimShared._fighter_from_def(merc_def, 0, "player", 0, 1, 1, true, false)
	merc["lane"] = 0
	merc["owner_treasures"] = []
	var pm := _pick_with(merc)
	print("[attack] team_mode death_hunt mercenary (%s) -> %s" % [str(merc_def.get("id", "")), pm])
	_h.expect(pm == "far_low_hp", "death_hunt", "death_hunt mercenary should pick the low-HP target, got %s" % pm)

	# 目标锁定：选定后，另一个敌人走得更近也不换；锁定目标死了才换。
	var att := _fighter(_plain_def("probe_lock", 100), "player", 0, [])
	att.pos = Vector2(500.0, 420.0)
	var e1 := _target("enemy", 0, "first", 3000, 3000, Vector2(500.0, 340.0))
	var e2 := _target("enemy", 0, "second", 3000, 3000, Vector2(500.0, 160.0))
	var pick1 := str(BattleSimShared._select_target(att, [e1, e2]).get("uid", ""))
	e2.pos = Vector2(500.0, 400.0)
	var pick2 := str(BattleSimShared._select_target(att, [e1, e2]).get("uid", ""))
	e1.alive = false
	e1.hp = 0
	var pick3 := str(BattleSimShared._select_target(att, [e1, e2]).get("uid", ""))
	print("[lock] first pick %s ; after other moves closer %s ; after first dies %s" % [pick1, pick2, pick3])
	_h.expect(pick1 == "first" and pick2 == "first", "target_lock", "target should stay locked, got %s -> %s" % [pick1, pick2])
	_h.expect(pick3 == "second", "target_lock_release", "target should switch after death, got %s" % pick3)


# --- 4 element: AoE burst on a bystander -----------------------------------------

func _element_bursts(treasures: Array) -> Dictionary:
	RngService.rng.seed = 20260923
	var a := _fighter(_plain_def("probe_elem", 100), "player", 0, treasures)
	a.pos = Vector2(500.0, 330.0)
	var tgt := _target("enemy", 0, "target", 3000, 50000000, Vector2(500.0, 300.0))
	var by := _target("enemy", 0, "bystander", 3000, 50000000, Vector2(620.0, 300.0))
	var st := _state([a], [tgt, by])
	DamageService.begin_stat_context(st, a)
	var bursts := 0
	var other := 0
	for _i in 1000:
		var before := int(by.hp)
		BattleSimulator._perform_attack(a, tgt, st)
		var lost := before - int(by.hp)
		if lost == 300:
			bursts += 1
		elif lost != 0:
			other += 1
		st.elapsed = float(st.elapsed) + 1.0
	DamageService.clear_stat_context()
	return {"bursts": bursts, "other": other}


func _probe_element() -> void:
	GameState.team_mode = true
	var r3 := _element_bursts(ELEM_3)
	var r4 := _element_bursts(ELEM_4)
	print("[element] 1000 attacks, bystander 120px from target: 3 treasures bursts=%d other=%d ; 4 treasures bursts=%d other=%d" % [
		int(r3.bursts), int(r3.other), int(r4.bursts), int(r4.other)])
	_h.expect(int(r3.bursts) == 0, "element_baseline", "bursts without the set: %d" % int(r3.bursts))
	_h.expect(int(r4.bursts) >= 150 and int(r4.bursts) <= 250, "element_set", "bursts with the set: %d (expect ~200)" % int(r4.bursts))


# --- 4 control: basic-attack kill refreshes the skill (9.24 改版) -----------------

func _control_refresh(treasures: Array, kill: bool) -> float:
	RngService.rng.seed = 777
	var a := _fighter(_plain_def("probe_ctrl", 100), "player", 0, treasures)
	a.pos = Vector2(500.0, 330.0)
	a.skill_ready = 50.0
	a.next_attack = 0.0
	var tgt := _target("enemy", 0, "target", 3000, 50 if kill else 3000, Vector2(500.0, 300.0))
	var st := _state([a], [tgt])
	st.elapsed = 3.0
	BattleSimulator._step_team([a], [tgt], 3.0, st)
	return float(a.skill_ready)


func _probe_control() -> void:
	GameState.team_mode = true
	var r3 := _control_refresh(CTRL_3, true)
	var r4 := _control_refresh(CTRL_4, true)
	var r4n := _control_refresh(CTRL_4, false)
	print("[control] skill_ready after basic-attack kill: 3 treasures %.1f ; 4 treasures %.1f ; 4 treasures no kill %.1f" % [r3, r4, r4n])
	_h.expect(is_equal_approx(r3, 50.0), "control_baseline", "without the set cooldown must stay 50, got %.1f" % r3)
	_h.expect(is_equal_approx(r4, 3.0), "control_set", "with the set a kill must reset cooldown to now (3.0), got %.1f" % r4)
	_h.expect(is_equal_approx(r4n, 50.0), "control_set_no_kill", "no kill, no refresh, got %.1f" % r4n)


# --- 4 money: server ledger refresh costs ---------------------------------------

func _money_costs(owned: Array) -> Dictionary:
	var prep := EconomyLedger.new_prep(100000)
	prep["shop"] = {"offer_id": "o0", "offers": [], "sold": [], "refresh_uses": 0}
	var shop: Array = []
	for i in 3:
		var r := EconomyLedger.apply(prep, "shop_refresh", {},
			{"owned_treasures": owned, "rolled_offers": [], "offer_id": "o%d" % (i + 1)})
		shop.append(-int(r.get("delta", 0)))
	var treasure: Array = []
	for idx in 3:
		var r2 := EconomyLedger.apply(prep, "treasure_refresh_cost", {"refresh_index": idx}, {"owned_treasures": owned})
		treasure.append(-int(r2.get("delta", 0)))
	return {"shop": shop, "treasure": treasure}


func _probe_money() -> void:
	var r3 := _money_costs(MONEY_3)
	var r4 := _money_costs(MONEY_4)
	print("[money] server ledger costs: 3 treasures %s ; 4 treasures %s" % [str(r3), str(r4)])
	_h.expect(r3.treasure == [50, 100, 200], "money_baseline", "treasure refresh without the set: %s" % str(r3.treasure))
	_h.expect(r4.shop == [0, 0, 0] and r4.treasure == [0, 0, 0], "money_set", "with the set: %s" % str(r4))


# --- codex: sets live in the linkage tab --------------------------------------------
# Only pure reads here: TreasureService.add_owned() would write user://profile.json.

func _probe_codex_sets() -> void:
	var link_tab := CodexService.entries_for("link")
	var entries: Array[Dictionary] = []
	for e in link_tab:
		if str(e.get("id", "")).begins_with("set_"):
			entries.append(e)
	var linkage_count: int = (DataRegistry.get_table("treasures").get("linkages", []) as Array).size()
	_h.expect(entries.size() == TreasureService.SET_CATEGORIES.size()
			and link_tab.size() == linkage_count + entries.size(), "codex_set_count",
		"linkage tab: %d entries, %d of them sets" % [link_tab.size(), entries.size()])
	for e in entries:
		var id := str(e.get("id", ""))
		_h.expect(not str(e.get("name", "")).is_empty() and not str(e.get("name_en", "")).is_empty(),
			"codex_set_name", "%s has no name" % id)
		_h.expect(not str(e.get("effect", "")).is_empty() and not str(e.get("requires_text", "")).is_empty(),
			"codex_set_text", "%s has no effect / requires text" % id)
		_h.expect(ResourceLoader.exists(str(e.get("portrait", ""))), "codex_set_art",
			"%s art missing: %s" % [id, str(e.get("portrait", ""))])
		print("[codex] %s  %s | %s | %s" % [id, str(e.get("name", "")), str(e.get("requires_text", "")), str(e.get("portrait", "")).get_file()])

	var saved := GameState.owned_treasures.duplicate()
	GameState.owned_treasures.assign(DEF_3)
	var with3 := TreasureService.active_set_ids()
	GameState.owned_treasures.assign(DEF_4)
	var with4 := TreasureService.active_set_ids()
	GameState.owned_treasures.assign(saved)
	_h.expect(with3.is_empty() and with4.size() == 1 and with4[0] == "set_defense", "codex_set_unlock",
		"active sets with 3 / 4 defense treasures: %s / %s" % [str(with3), str(with4)])

	var saved_locale := LocaleManager.get_locale()
	LocaleManager.set_locale("zh")
	var panel = TreasureChoicePanelScript.new()
	var prep_text := str(panel.set_effect_text("defense"))
	panel.free()
	LocaleManager.set_locale(saved_locale)
	_h.expect(prep_text == "4防御：普通棋子开战 HP/DEF +30%，闪避 +15%。", "prep_set_text",
		"prep detail set text changed: %s" % prep_text)
