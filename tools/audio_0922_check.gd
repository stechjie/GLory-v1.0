extends Node

# 9.22 第四批音效的接线探针（9.23 第五批按用户逐条点名订正后加厚）。
#
# ## 用户口径逐条对应
#
#   ① 「boss 技能音效播放，我方队友都能听见」：8 只 boss 有素材，
#      **不做归属门控** —— 这条用**缩进**判定（见 `_check_boss_dispatch_ungated`），
#      不是「源码里出现过这个名字」。狂战灾兽用户确认先留空，这里钉住「它取不到 cue」，
#      免得将来有人补一张兜底音把它变成「所有 boss 一个声」。
#   ② ★★ 9.23 第五批订正：boss 技能音是**两条通道**，不是一条。
#      `_check_boss_channels` 钉住归属（哪只 boss 走哪条），
#      `_check_boss_event_emitters` **真的跑一遍模拟器**钉住触发时刻，
#      `_check_apocalypse_event_beats` 钉住灭世裁决者那三拍的「起 / 停 / 完成」。
#      第一版把 7 只全挂在「施法这一下」上，其中 6 只是错的（4 只压根没有
#      `skill_ready` 上升沿 → 「一次都不响」；镜像魔君是每秒一次 → 「一直播放」）。
#   ③ 「审判剑士 / 四星刺灵·毒灵·飞灵·巨甲灵·魔童 在触发的普通攻击时播放」：
#      模拟器补 `sfx_proc` 事件 → BattleVfx 派发。这里**真的跑一遍**模拟器的
#      `_apply_attack_statuses` / `_perform_attack`，断言事件真的产生、
#      且只在对应 skill_id 上产生（两条反证：不相关 skill_id 不产生；增伤没生效时不产生）。
#   ④ 「最终回合 pvp 开局音替换」：新素材能被 SfxService 读到（文件在 / 时长 > 0）。
#   ⑤ 「黄金重骑技能音被 pvp BGM 压住」：cue 级音量表把它抬 6dB，且 `play()` 真的加进去。
#
# ## 为什么不是「跑一遍真场景听一下」
#
# 战斗是重型 3D 场景，headless 下 instantiate 会挂死（项目约定）。
# 所以走两条不会挂死的路：
#   * **源级契约**：关键调用点与顺序在源码里存在，且**顺序 / 缩进正确**
#     （不是「有就行」—— 那正是本仓反复踩过的假绿陷阱）。
#   * **运行级行为**：真的调模拟器那两个函数，看 `visual_events` 里有没有事件；
#     真的调 SfxService 的计数缝，看那几条 cue 播不播得出去。
#
# ★★ 9.23 第五批最要紧的一条教训（写在这里免得下次再犯）：
#   **音效的判据必须跟着「会过回放边界的数据」走。** 真实 3v3 打的不是本地模拟，
#   而是 `BattleScreen` 播回放；回放帧只打包 13 个数值列
#   （`BattleSimulator._replay_capture_frame`），`_state` 里的单位字典也只按
#   `_load_replay_roster` 那一组固定键重建。`apocalypse_due` / `blood_rage_active` /
#   `killer_uid` 这类字段**在回放侧根本不存在**，任何挂在它们上面的音在真机上
#   恒不响 —— 而这套探针原来的判据全是「读源码文本」，一条都发现不了。
#   所以这一批新增的 `_check_*_event*` 一律**跑真模拟器 + 走 schema 归一化**，
#   而不是再补几句 `contains`。
#
# ★★ 9.23 第五批第二条教训 —— 本文件自己也踩了一次假绿：
#   **凡是「用 `%` 格式化」的提示串里有 `30%` 这种裸百分号，必须写成 `%%`。**
#   写成 `30% 血` 时 GDScript 报 `String formatting error: unsupported format
#   character`，**该函数当场中断、后面所有断言一条都不执行** —— 而探针整体
#   只表现为「失败数没变多」，看上去像全绿。当时 `_check_blood_rage_emitter`
#   整段（含「仅播放一次」那条用户明确要求）就是这么被静默跳过的。
#   变异测试是唯一能发现它的手段：故意改坏产品代码，看对应那条**有没有**变红。
#   所以本批收尾跑了三条针对性变异（`boss_event_cue_wrong_mirror_clone` /
#   `apocalypse_*_emit_missing` / `mirror_clone_proc_*`），确认 7 条都变红后才算过。
#   ⚠ 另一个坑：同一个 .gd 在一次消息里连发两条 Edit 会**互相覆盖**（后一条按旧快照
#   重写文件），先前那条静默丢失 —— 这三条变异第一次就只生效了两条。改同一份文件
#   要一次一条。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const SfxService := preload("res://ui/services/SfxService.gd")
const EventSchema := preload("res://scripts/battle/BattlePresentationEvent.gd")

const CHECK_NAME := "audio_0922"

const VFX_PATH := "res://scenes/battle/BattleVfx.gd"


func _ready() -> void:
	var h := CheckHarness.new(CHECK_NAME)

	_check_boss_cues(h)
	_check_boss_channels(h)
	_check_proc_cues(h)
	_check_boss_dispatch_ungated(h)
	_check_apocalypse_event_beats(h)
	_check_boss_diff_triggers(h)
	_check_volume_override(h)
	_check_sfx_proc_schema(h)
	_check_sim_emits_sfx_proc(h)
	_check_boss_event_emitters(h)
	await _check_runtime_playback(h)

	SfxService.shutdown()
	h.finish(get_tree())


func _src(path: String) -> String:
	return FileAccess.get_file_as_string(path)


# 取 `needle` 所在行的缩进（制表符个数）。找不到返回 -1。
#
# 为什么需要它：这套门禁反复栽在「源码 contains 被自己满足」上。判断
# 「这条派发有没有被 if 门控住」用 contains 是判不出来的 ——
# 同一个字符串在缩进 1（函数体，无门控）与缩进 3（if 里面）下含义完全不同。
# 缩进是本文件里唯一能**结构性**表达「在不在分支里」的判据。
func _indent_of(source: String, needle: String) -> int:
	var at := source.find(needle)
	if at < 0:
		return -1
	var line_start := source.rfind("\n", at) + 1
	var indent := 0
	while line_start + indent < source.length() and source[line_start + indent] == "\t":
		indent += 1
	return indent


# --- ① boss 技能音 -------------------------------------------------------------

func _check_boss_cues(h) -> void:
	var cases := [
		["boss_mirror_lord", SfxService.CUE_BOSS_MIRROR_LORD_SKILL],        # 镜像魔君技能
		["boss_thunder_core", SfxService.CUE_BOSS_THUNDER_CORE_SKILL],      # 雷怒核心技能
		["boss_holy_priest", SfxService.CUE_BOSS_HOLY_PRIEST_SKILL],        # 圣愈祭司技能
		["boss_soul_devourer", SfxService.CUE_BOSS_SOUL_DEVOURER_SKILL],    # 噬魂领主技能
		["boss_twin_gate", SfxService.CUE_BOSS_TWIN_GATE_REVIVE],           # 双生守门人复活
		["boss_meteor_caster", SfxService.CUE_BOSS_METEOR_CASTER_SKILL],    # 天罚投星者技能
		["boss_blood_demon", SfxService.CUE_BOSS_BLOOD_DEMON_SKILL],        # 血怒魔王技能
	]
	for pair in cases:
		var boss_id: String = pair[0]
		var cue: String = pair[1]
		h.expect(not cue.is_empty(), "boss_cue_const_empty_%s" % boss_id,
			"常量没取到值（宏没定义？）：%s" % boss_id)
		h.expect(SfxService.boss_skill_cue_for(boss_id) == cue, "boss_cue_lookup_wrong_%s" % boss_id,
			"boss_skill_cue_for(%s) 取值不对 —— 这只 boss 的技能音挂错了" % boss_id)
		var path := str(SfxService.CUES.get(cue, ""))
		h.expect(path.begins_with("res://assets/audio/sfx/battle/") and FileAccess.file_exists(path),
			"boss_cue_file_missing_%s" % boss_id,
			"%s 的素材不存在或不在 sfx/battle 下：%s" % [boss_id, path])
		h.expect(SfxService.cue_length(cue) > 0.0, "boss_cue_length_zero_%s" % boss_id,
			"%s 的素材读不出时长 —— 文件在、但引擎没导入（要跑 --import）" % boss_id)

	# 灭世裁决者与狂战灾兽**必须**取不到值：
	#   * 灭世裁决者走「蓄力 / 完成」两条独立 cue（有停播这一档，派发表表达不了）；
	#   * 狂战灾兽用户确认先留空。
	# 这两条是刻意的，不是漏接 —— 钉住它们，将来补兜底音时会被这条挡住。
	for boss_id in ["boss_apocalypse", "boss_rage_beast"]:
		h.expect(SfxService.boss_skill_cue_for(boss_id).is_empty(), "boss_unexpected_cue_%s" % boss_id,
			"%s 不该在 BOSS_SKILL_CUES 里取到值（灭世裁决者走蓄力/完成两条独立 cue；\
狂战灾兽用户确认先留空）" % boss_id)
	h.expect(SfxService.boss_skill_cue_for("boss_not_a_thing").is_empty(), "boss_cue_fallback_leak",
		"没登记的 boss id 返回了非空 cue —— 会让没素材的 boss 也响")

	# ④ 最终回合 pvp 开局音（本轮是**替换**同路径素材）。路径不变，只换内容，
	#    所以这里钉的是「换了之后仍然是可读素材」。
	var intro := str(SfxService.CUES.get(SfxService.CUE_FINAL_ROUND_PVP_INTRO, ""))
	h.expect(intro.ends_with("final_round_pvp_intro.mp3") and FileAccess.file_exists(intro),
		"final_intro_file_missing", "最终回合 pvp 开局音素材不在：%s" % intro)
	h.expect(SfxService.cue_length(SfxService.CUE_FINAL_ROUND_PVP_INTRO) > 0.0,
		"final_intro_length_zero",
		"最终回合 pvp 开局音读不出时长 —— 「播完再让棋子行动」会退化成 0 秒")


# --- ① 续：两条通道的**归属** --------------------------------------------------
#
# 这张表是 9.23 第五批的核心契约。用户逐条点名之后，每只 boss 的「该在什么时候响」
# 都落在这里 —— 谁走施法边沿、谁走真事件，必须一眼看得出来。
func _check_boss_channels(h) -> void:
	# 走施法边沿的**只有**这两只：它们的技能确实产生 `skill_ready` 上升沿
	# （在 `_tick_skills` 的 match 里），且「施法这一下」就是用户要的那一声。
	var edge_cases := [
		["boss_holy_priest", SfxService.CUE_BOSS_HOLY_PRIEST_SKILL],
		["boss_meteor_caster", SfxService.CUE_BOSS_METEOR_CASTER_SKILL],
	]
	for pair in edge_cases:
		var boss_id: String = pair[0]
		h.expect(SfxService.boss_cast_edge_cue_for(boss_id) == pair[1],
			"boss_edge_cue_wrong_%s" % boss_id,
			"%s 不在施法边沿表里（或取值不对）—— 它的技能音会不响" % boss_id)

	# ★ 反证（这一批的**主判据**）：这 6 只**必须**取不到施法边沿的 cue。
	#   取到了就是回退成 9.22 的写法，而那一版对它们全是错的：
	#   4 只根本没有上升沿（一次都不响）、镜像魔君每秒一次（一直播放）。
	for boss_id in ["boss_mirror_lord", "boss_thunder_core", "boss_soul_devourer",
			"boss_blood_demon", "boss_twin_gate", "boss_apocalypse"]:
		h.expect(SfxService.boss_cast_edge_cue_for(boss_id).is_empty(),
			"boss_edge_leak_%s" % boss_id,
			"%s 还能从施法边沿表里取到 cue —— 9.22 那版「挂错时刻」的写法回归了" % boss_id)

	# 真事件通道：键是 skill_id，值是动作表（cue / stop 两个字段）。
	var event_cases := [
		["overload_counter", SfxService.CUE_BOSS_THUNDER_CORE_SKILL, ""],
		["mirror_clone", SfxService.CUE_BOSS_MIRROR_LORD_SKILL, ""],
		["soul_devour", SfxService.CUE_BOSS_SOUL_DEVOURER_SKILL, ""],
		["blood_rage", SfxService.CUE_BOSS_BLOOD_DEMON_SKILL, ""],
		["twin_revive", SfxService.CUE_BOSS_TWIN_GATE_REVIVE, ""],
		["apocalypse_charge", SfxService.CUE_BOSS_APOCALYPSE_CHARGE, ""],
		# 完成那一档要**先收口**再放音，否则两声叠在一起。
		["apocalypse_impact", SfxService.CUE_BOSS_APOCALYPSE_IMPACT, SfxService.CUE_BOSS_APOCALYPSE_CHARGE],
		# 被打断 / 完成了但没打到人：只收口，不补音。
		["apocalypse_stop", "", SfxService.CUE_BOSS_APOCALYPSE_CHARGE],
	]
	for row in event_cases:
		var sid: String = row[0]
		var action: Dictionary = SfxService.boss_event_action_for(sid)
		h.expect(not action.is_empty(), "boss_event_action_missing_%s" % sid,
			"BOSS_EVENT_ACTIONS 里没有 %s —— 这条技能音永远不会响" % sid)
		h.expect(str(action.get("cue", "")) == str(row[1]), "boss_event_cue_wrong_%s" % sid,
			"BOSS_EVENT_ACTIONS[%s].cue 取值不对（拿到 %s）" % [sid, str(action.get("cue", ""))])
		h.expect(str(action.get("stop", "")) == str(row[2]), "boss_event_stop_wrong_%s" % sid,
			"BOSS_EVENT_ACTIONS[%s].stop 取值不对（拿到 %s）—— 蓄力音会漏收口或提前被掐"
				% [sid, str(action.get("stop", ""))])

	# 两条通道**不能同时**登记同一只 boss：都登记就是两声。
	var channels_overlap: Array = []
	for boss_id in SfxService.BOSS_CAST_EDGE_CUES.keys():
		if SfxService.boss_skill_cue_for(boss_id).is_empty():
			channels_overlap.append(str(boss_id))
	h.expect(channels_overlap.is_empty(), "boss_channel_orphan",
		"施法边沿表里有 boss 不在全量素材表里：%s（两张表脱钩了）" % str(channels_overlap))

	# 反证：没登记的 skill_id 不能借到 boss 的 cue。
	h.expect(SfxService.boss_event_action_for("poison_attack").is_empty(),
		"boss_event_table_leak",
		"普攻触发型的 skill_id 也能从 BOSS_EVENT_ACTIONS 借到动作 —— 两组表串了")


# --- ③ 普攻触发型 -------------------------------------------------------------

func _check_proc_cues(h) -> void:
	var cases := [
		["defense_down_attack", SfxService.CUE_STAR4_SPIKE_PROC],          # 四星刺灵
		["poison_attack", SfxService.CUE_STAR4_POISON_PROC],               # 四星毒灵 / 四星飞灵
		["curse_attack", SfxService.CUE_STAR4_MOTONG_PROC],                # 四星魔童
		["poison_reflect_armor_stack", SfxService.CUE_STAR4_TITAN_PROC],   # 四星巨甲灵
	]
	for pair in cases:
		var skill_id: String = pair[0]
		var cue: String = pair[1]
		h.expect(SfxService.proc_skill_cue_for(skill_id) == cue, "proc_cue_lookup_wrong_%s" % skill_id,
			"proc_skill_cue_for(%s) 取值不对" % skill_id)
		h.expect(SfxService.cue_length(cue) > 0.0, "proc_cue_length_zero_%s" % skill_id,
			"%s 的素材读不出时长" % skill_id)

	h.expect(SfxService.proc_skill_cue_for("attack_interrupt") == SfxService.CUE_STAR4_MILITIA_SKILL,
		"proc_cue_militia_regressed",
		"四星民兵那条（attack_interrupt）在新表里的取值变了 —— 9.21 的行为被破坏了")

	# 审判剑士是**佣兵**：它的音必须走 merc_proc_cue_for，不能混进 STAR4_PROC_SKILL_CUES。
	# 混进去的后果不是「多一条冗余」，而是「永远不响」—— 消费端那条路会叠 `_is_star4`，
	# 而佣兵永远到不了四星。
	h.expect(SfxService.merc_proc_cue_for("balance_judge") == SfxService.CUE_MERC_LIBRA_JUDGE_PROC,
		"merc_proc_cue_lookup_wrong", "merc_proc_cue_for(balance_judge) 取值不对")
	h.expect(SfxService.proc_skill_cue_for("balance_judge").is_empty(), "balance_judge_in_star4_table",
		"balance_judge 挂进了 STAR4_PROC_SKILL_CUES —— 佣兵升不到四星，这条音永远不会响")
	h.expect(SfxService.merc_proc_cue_for("poison_attack").is_empty(), "poison_in_merc_table",
		"poison_attack 挂进了佣兵表 —— 四星毒灵的音会绕过星级门控")
	h.expect(SfxService.merc_skill_cue_for("merc_gemini_assassin") == SfxService.CUE_MERC_GEMINI_ASSASSIN_SKILL,
		"gemini_assassin_cue_wrong",
		"镜像刺客（merc_gemini_assassin）的技能音没登记进 MERC_SKILL_CUES")


# --- ① 续：boss 派发**不在归属门控里** ----------------------------------------

func _check_boss_dispatch_ungated(h) -> void:
	var vfx := _src(VFX_PATH)
	var fn_at := vfx.find("func _play_skill_cast_vfx(")
	h.expect(fn_at >= 0, "vfx_skill_cast_fn_missing", "找不到 BattleVfx._play_skill_cast_vfx()")
	if fn_at < 0:
		return
	var fn_end := vfx.find("\nfunc ", fn_at + 10)
	var body := vfx.substr(fn_at, (fn_end - fn_at) if fn_end > 0 else 6000)

	h.expect(body.contains("SfxService.boss_cast_edge_cue_for(uid)"), "vfx_boss_dispatch_missing",
		"BattleVfx 里没有 boss_cast_edge_cue_for 的调用点 —— 圣愈祭司 / 天罚投星者的技能音永远不响")
	h.expect(body.contains("SfxService.play(boss_cue)"), "vfx_boss_play_missing",
		"BattleVfx 取到 boss_cue 之后没有 play() —— 一条永远不会响的音")

	# ★ 9.23 第五批主判据：施法边沿**不能**再拿 `boss_skill_cue_for()` 当派发表。
	#   那张表是全量素材表（7 条），拿它派发 = 把 4 只没有上升沿的 boss 也挂在这里
	#   （一次都不响）、并且让镜像魔君每秒重响一次。
	h.expect(not body.contains("SfxService.boss_skill_cue_for(uid)"), "vfx_boss_dispatch_regressed",
		"`_play_skill_cast_vfx` 里又用 boss_skill_cue_for(uid) 派发了 —— 那是 9.22 的写法：\
全量表里有 4 只根本没有 skill_ready 上升沿（一次都不响），镜像魔君还会每秒重响")

	# ★ 结构性判据：boss 那条派发必须落在**函数体层级**（缩进 1），
	#   也就是**不在** `if _owned` / `elif _owned` 里面。
	#   用户口径「boss 技能音效播放，我方队友都能听见」= 不做归属门控；
	#   而 boss 在 3v3 里固定是敌方单位，被 `_is_own_or_ally_unit` 判真根本不可能 ——
	#   一旦有人把这一行挪进 `_owned` 分支，就是「永远不响」，而 contains 判据照样全绿。
	var boss_indent := _indent_of(body, "SfxService.boss_cast_edge_cue_for(uid)")
	var gate_indent := _indent_of(body, "if _owned and _is_star4(_sim_uid):")
	h.expect(gate_indent == 1, "vfx_owner_gate_not_at_fn_level",
		"找不到函数体层级的 `if _owned and _is_star4(...)`（BattleVfx 结构变了，缩进判据无从谈起）")
	h.expect(boss_indent == 1, "vfx_boss_dispatch_gated",
		"boss 技能音的派发缩进是 %d（应为 1 = 函数体层级）—— 它被挪进归属门控里了；\
boss 固定是敌方单位，进 `_owned` 分支就是永远不响" % boss_indent)
	# 反向对照：四星技能音**应该**在门控里（缩进更深）。少了这条，
	# 「缩进 1」在整段被压平的文件里也会通过。
	var star4_indent := _indent_of(body, "SfxService.play(SfxService.star4_cue_for(uid, true))")
	h.expect(star4_indent > 1, "vfx_star4_not_gated",
		"四星技能音跑到函数体层级了（缩进 %d）—— 归属门控被拆掉了" % star4_indent)

	# ★ 9.22 **事故守卫**：佣兵技能音必须留在 `elif _owned:` **里面**（缩进 2）。
	#   本批真的出过这个事故：加 boss 派发时顺手把 merc 那三行抬到了函数体层级，
	#   于是 `elif _owned:` 只剩注释 —— 在 GDScript 里「elif 没有语句体」是**解析期错误**，
	#   整份 BattleVfx.gd 加载失败（BattleScreen 继承链一起塌）。
	#   **本探针所有判据都是读源码文本的，解析错误它一条都看不见** —— 上面 3 条
	#   contains / 缩进判据当时全绿。所以这里必须有一条能识别「被抬出去」的判据。
	var merc_indent := _indent_of(body, "var merc_cue := SfxService.merc_skill_cue_for(uid)")
	h.expect(merc_indent == 2, "vfx_merc_dispatch_dedented",
		"佣兵技能音派发的缩进是 %d（应为 2 = 在 `elif _owned:` 分支里）。\
把它抬到函数体层级会让 `elif _owned:` 只剩注释 → 解析期错误 → 整份 BattleVfx.gd 加载失败" % merc_indent)


# --- ② 灭世裁决者：三拍全部走事件通道 -------------------------------------------
#
# 9.23 第五批把这条整段重写了。旧版钉的是 BattleVfx 里那段**依赖
# `apocalypse_due` 的 diff** —— 而那个字段**不过回放边界**（回放帧只打包 13 个数值列，
# `_load_replay_roster` 也只重建固定那一组键），真实 3v3 路径上整段是死代码。
# 旧判据全绿，产品里一声不响 —— 这正是本批要堵的那类假绿。
#
# 现在钉的是：**模拟器在三个真时刻补事件** + 消费端有一支专门的派发。
func _check_apocalypse_event_beats(h) -> void:
	var vfx := _src(VFX_PATH)
	var sim := _src("res://scripts/battle/BattleSimulator.gd")
	var skills := _src("res://scripts/battle/BattleSimSkills.gd")

	# ① 起播：蓄力**真的开始**那一次补事件。
	#    判据必须是「返回值 = 这次真的开始了」，不能是无条件补 ——
	#    `_skill_apocalypse_charge` 在已经在蓄力时会提前 return false。
	h.expect(skills.contains("static func _skill_apocalypse_charge(caster: Dictionary, state: Dictionary, d: Dictionary) -> bool:"),
		"apocalypse_charge_returns_void",
		"`_skill_apocalypse_charge` 还是 void —— 调用方分不出「这次真的开始蓄力了」与\
「已经在蓄力」，「开始蓄力响一次」会退化成「每次 match 都响」")
	h.expect(sim.contains("if BattleSimSkills._skill_apocalypse_charge(caster, state, d):"),
		"apocalypse_charge_return_ignored",
		"调用方没有用 `_skill_apocalypse_charge` 的返回值判定 —— 事件会被无条件补")
	h.expect(sim.contains('_emit_sfx_proc(state, "apocalypse_charge", caster, caster)'),
		"apocalypse_charge_emit_missing", "蓄力开始没有补 sfx_proc 事件 —— 蓄力音永远不会响")

	# ② 收口：被打断那一支 + 「完成但没打到人」那一档，都要补 stop。
	h.expect(sim.contains('_emit_sfx_proc(state, "apocalypse_stop", caster, caster)'),
		"apocalypse_interrupt_emit_missing",
		"蓄力被打断那一支没有补 apocalypse_stop 事件 —— 蓄力音会一直放到素材结束")
	h.expect(sim.contains('_emit_sfx_proc(state, "apocalypse_impact" if hit_any else "apocalypse_stop", caster, caster)'),
		"apocalypse_impact_emit_missing",
		"蓄力窗口结束只补一种事件 —— 「完成但没打到人」那一档的分支塌了\
（那正是 9.22 把 stop_cue 排在两个 if 之前要解决的那一档）")
	h.expect(sim.contains("var hit_any := false") and sim.contains("if charged > 0:"),
		"apocalypse_hit_any_missing",
		"找不到「这一下到底打到人没有」的判定 —— impact / stop 两档无从区分")

	# ③ 消费端：那一支必须存在，且在 `sfx_proc` 分支里。
	h.expect(vfx.contains("func _maybe_play_boss_skill_proc("), "boss_event_consumer_missing",
		"BattleVfx 里没有 boss 真事件的消费支 —— 模拟器补的事件没人接")
	h.expect(vfx.contains("if not _maybe_play_boss_skill_proc(event):"), "boss_event_consumer_not_wired",
		"`sfx_proc` 分支里没有调 `_maybe_play_boss_skill_proc` —— boss 事件被当成普通事件走掉了\
（那一条开头就是 `_is_own_or_ally_unit`，boss 永远过不了）")

	# ④ ★ 死路不得回归：BattleVfx 里**不该**再有蓄力/完成那三条音。
	#    它们挂的 `apocalypse_charging`（= `f.has("apocalypse_due")`）在回放侧恒为假，
	#    留着就是「看起来有、实际不响」，而且会和事件通道叠成两声。
	for pair in [
		["charge_play", "SfxService.play(SfxService.CUE_BOSS_APOCALYPSE_CHARGE)"],
		["charge_stop", "SfxService.stop_cue(SfxService.CUE_BOSS_APOCALYPSE_CHARGE)"],
		["impact_play", "SfxService.play(SfxService.CUE_BOSS_APOCALYPSE_IMPACT)"],
	]:
		var label: String = pair[0]
		var dead: String = pair[1]
		h.expect(not vfx.contains(dead), "apocalypse_dead_path_back_%s" % label,
			"BattleVfx 里又出现了 `%s` —— 它挂的 `apocalypse_charging` 在回放路径上恒为假\
（字段不过回放边界），既不会响、又会和事件通道叠音" % dead)


# --- ⑤ 黄金重骑音量 ------------------------------------------------------------

func _check_volume_override(h) -> void:
	var raised := SfxService.cue_volume_db(SfxService.CUE_MERC_TAURUS_CHARGE_SKILL)
	h.expect(raised >= 6.0, "taurus_volume_not_raised",
		"黄金重骑技能音的音量偏移是 %s dB，没有抬到 6dB 以上 —— 还会被 pvp_battle_music 压住" % raised)
	h.expect(is_zero_approx(SfxService.cue_volume_db(SfxService.CUE_UI_POPUP)), "volume_override_leaked",
		"没登记的 cue 拿到了非零音量偏移 —— 这张表在漏，所有音效都会被误抬")

	# ★ 光有表没用 —— `play()` 必须真的把它加进去。
	# 变异测试口径：把 `play()` 里那行改回 `voice.volume_db = volume_db`，
	# 只判表的实现照旧全绿，产品里黄金重骑还是听不清。
	var sfx := _src("res://ui/services/SfxService.gd")
	h.expect(sfx.contains("volume_db + cue_volume_db(cue)"), "volume_override_not_applied",
		"SfxService.play() 没有把 cue 级音量加进 voice.volume_db —— 音量表是个摆设")
	var assign_at := sfx.find("voice.volume_db = volume_db + cue_volume_db(cue)")
	var play_at := sfx.find("voice.play()", maxi(assign_at, 0))
	h.expect(assign_at >= 0 and play_at > assign_at, "volume_assign_order_wrong",
		"音量赋值没有排在 voice.play() 之前 —— 这一声还是按旧音量走")


# --- sfx_proc 事件类型必须登记 -------------------------------------------------

func _check_sfx_proc_schema(h) -> void:
	h.expect(EventSchema.is_known_type("sfx_proc"), "sfx_proc_unknown_type",
		"`sfx_proc` 没有登记进 BattlePresentationEvent.KNOWN_TYPES —— 每只棋子的每次普攻都会产生一条 \
unknown 警告，回放采集里也会被标成非法事件")
	var normalized: Dictionary = EventSchema.normalize(
		{"type": "sfx_proc", "skill_id": "poison_attack", "source_uid": "unit_a", "target_uid": "unit_b"},
		"qa922:sim:team0", 5, 0)
	var errors: Array = EventSchema.validate(normalized)
	h.expect(not errors.has("unknown_type:sfx_proc"), "sfx_proc_rejected",
		"sfx_proc 被 schema 判成 unknown：%s" % str(errors))
	h.expect(str(normalized.get("type", "")) == "sfx_proc" \
			and str(normalized.get("skill_id", "")) == "poison_attack" \
			and str(normalized.get("source_uid", "")) == "unit_a",
		"sfx_proc_fields_lost",
		"归一化之后 type / skill_id / source_uid 丢了一个：%s" % JSON.stringify(normalized))


# --- ③ 续：真的跑一遍模拟器，看事件产不产生 -------------------------------------

func _dummy_def() -> Dictionary:
	return {
		"id": "qa922_dummy", "name": "靶子", "hp": 4000, "atk": 0, "def": 0,
		"attack_speed": 0.0, "range": 1, "move_speed": 0.0, "crit": 0.0,
		"crit_dmg": 1.0, "skill_id": "none", "tier": 1, "element": "-", "race": "-",
	}


func _row(unit_id: String) -> Dictionary:
	for row in DataRegistry.get_table("race_units").get("units", []):
		if str((row as Dictionary).get("id", "")) == unit_id:
			return row as Dictionary
	return {}


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


func _sfx_procs(state: Dictionary, skill_id: String) -> Array:
	var out: Array = []
	for e in state.get("visual_events", []):
		if e is Dictionary and str((e as Dictionary).get("type", "")) == "sfx_proc" \
				and str((e as Dictionary).get("skill_id", "")) == skill_id:
			out.append(e)
	return out


func _check_sim_emits_sfx_proc(h) -> void:
	# 三条「普攻附状态」型：真的调一次 `_apply_attack_statuses`。
	var cases := [
		["curse_attack", "dark_imp"],
		["poison_attack", "undead_poison"],
		["poison_attack", "undead_fly"],
		["defense_down_attack", "undead_spike"],
	]
	for pair in cases:
		var sid: String = pair[0]
		var unit_id: String = pair[1]
		var row := _row(unit_id)
		if row.is_empty():
			h.fail("sim_row_missing_%s" % unit_id, "数据表里找不到 %s" % unit_id)
			continue
		var attacker: Dictionary = BattleSimShared._fighter_from_def(row, 0, "player", 0, 1, 1)
		var target: Dictionary = BattleSimShared._fighter_from_def(_dummy_def(), 0, "enemy", 0, 1, 1)
		var st := _state([attacker], [target])
		DamageService.begin_stat_context(st, attacker)
		BattleSimulator._apply_attack_statuses(attacker, target, st)
		DamageService.clear_stat_context()

		var hits := _sfx_procs(st, sid)
		h.expect(hits.size() == 1, "sfx_proc_not_emitted_%s" % sid,
			"%s（%s）打了一次普攻，模拟器补的 sfx_proc 事件有 %d 条（应为 1）—— 这只棋子的技能音不会响"
				% [unit_id, sid, hits.size()])
		if hits.size() == 1:
			var e: Dictionary = hits[0]
			h.expect(str(e.get("source_uid", "")) == str(attacker.get("uid", "")),
				"sfx_proc_source_wrong_%s" % sid,
				"sfx_proc 的 source_uid 不是触发技能的那只棋子 —— 归属门控会判到别人头上")
		# 反证：这条事件只该在对应 skill_id 上产生，不能是「无脑补一条」。
		var all: Array = st.get("visual_events", [])
		h.expect(all.size() == 1, "sfx_proc_extra_events_%s" % sid,
			"%s 触发一次却产生了 %d 条视觉事件 —— 有别的分支也在补事件" % [sid, all.size()])

	# 反证②：不带任何普攻附状态技能的棋子打一下，**不该**产生 sfx_proc。
	var plain_row := _row("human_swordsman")
	if not plain_row.is_empty():
		var plain: Dictionary = BattleSimShared._fighter_from_def(plain_row, 0, "player", 0, 1, 1)
		var victim: Dictionary = BattleSimShared._fighter_from_def(_dummy_def(), 0, "enemy", 0, 1, 1)
		var st2 := _state([plain], [victim])
		DamageService.begin_stat_context(st2, plain)
		BattleSimulator._apply_attack_statuses(plain, victim, st2)
		DamageService.clear_stat_context()
		var none: Array = st2.get("visual_events", [])
		h.expect(none.is_empty(), "sfx_proc_spurious",
			"没带普攻附状态技能的棋子也产生了 %d 条 sfx_proc 事件 —— 事件是无条件补的" % none.size())

	# 审判剑士：`balance_judge` 在 `_perform_attack` 里，条件是「目标血量更高」。
	var judge := {
		"id": "merc_libra_judge", "name": "审判剑士", "hp": 500, "atk": 50, "def": 7,
		"attack_speed": 1.0, "range": 1, "move_speed": 3.1, "crit": 0.0, "crit_dmg": 1.5,
		"skill_id": "balance_judge", "bonus_vs_higher_hp": 0.40, "tier": 1,
		"element": "-", "race": "-",
	}
	var jf: Dictionary = BattleSimShared._fighter_from_def(judge, 0, "player", 0, 1, 1, true)
	var big: Dictionary = BattleSimShared._fighter_from_def(_dummy_def(), 0, "enemy", 0, 1, 1)
	var st3 := _state([jf], [big])
	DamageService.begin_stat_context(st3, jf)
	var dealt_high := BattleSimulator._perform_attack(jf, big, st3)
	DamageService.clear_stat_context()
	h.expect(dealt_high > 0, "judge_attack_dealt_nothing",
		"审判剑士这一击伤害为 0 —— 下面的判据无从谈起")
	h.expect(_sfx_procs(st3, "balance_judge").size() == 1, "balance_judge_proc_missing",
		"审判剑士对高血目标普攻（增伤生效）没有补 sfx_proc 事件 —— 这条音永远不会响")

	# 反证③：目标血量**更低**时不增伤，也就不该响。
	var small: Dictionary = BattleSimShared._fighter_from_def(_dummy_def(), 0, "enemy", 0, 1, 1)
	small.max_hp = 10
	small.hp = 10
	var st4 := _state([jf], [small])
	DamageService.begin_stat_context(st4, jf)
	BattleSimulator._perform_attack(jf, small, st4)
	DamageService.clear_stat_context()
	h.expect(_sfx_procs(st4, "balance_judge").is_empty(), "balance_judge_proc_unconditional",
		"审判剑士打低血目标（增伤**没**生效）也补了事件 —— 这一声会在每次普攻都响")

	# 巨甲灵：反弹真的发生时补事件。★ 判据不能用「护甲层数涨了」——
	# 层数有 max_stacks 封顶，封顶之后反弹照旧生效，按层数判就是「第 N+1 次起没声音」。
	var titan_row := _row("undead_titan")
	if titan_row.is_empty():
		h.fail("titan_row_missing", "数据表里找不到 undead_titan")
		return
	var scaled := UnitFactory.apply_star_stats(titan_row, GameConstants.MAX_STAR)
	var titan: Dictionary = BattleSimShared._fighter_from_def(
		scaled, 0, "enemy", 0, 1, GameConstants.MAX_STAR)
	var hitter: Dictionary = BattleSimShared._fighter_from_def(_dummy_def(), 0, "player", 0, 1, 1)
	hitter.atk = 200
	var st5 := _state([hitter], [titan])
	DamageService.begin_stat_context(st5, hitter)
	BattleSimulator._perform_attack(hitter, titan, st5)
	DamageService.clear_stat_context()
	h.expect(_sfx_procs(st5, "poison_reflect_armor_stack").size() == 1, "titan_reflect_proc_missing",
		"巨甲灵被打了一下（反弹条件成立：dealt>0 且自己活着）却没补 sfx_proc 事件")


# --- ② 续：两条「就地构造事件」的触发点（雷怒核心 / 双生守门人）------------------
#
# 这两只的音**没走模拟器**：触发判据要的那两个量（`skill_stacks` / `alive`）
# 本来就会过回放边界，所以就在 BattleVfx 的那一格就地构造一条 `sfx_proc` 事件、
# 交给同一个消费支（`_maybe_play_boss_skill_proc`）。
# 就地构造必须**落在正确的分支里** —— contains 判不出来，所以用「位置落在两行之间」判。
func _check_boss_diff_triggers(h) -> void:
	var vfx := _src(VFX_PATH)

	# 雷怒核心：层数由 8 落回 0 那一格 = 反击真的打出去了。
	var overload_branch := vfx.find('elif sid_now == "overload_counter" and stack_delta < 0:')
	var overload_emit := vfx.find('"skill_id": "overload_counter",', maxi(overload_branch, 0))
	var overload_next := vfx.find("var prev_ratio := ", maxi(overload_branch, 0))
	h.expect(overload_branch >= 0, "overload_branch_missing",
		"找不到「过载层数下落」那一支 —— 雷怒核心的反击判定无从谈起")
	h.expect(overload_branch >= 0 and overload_emit > overload_branch
			and (overload_next < 0 or overload_emit < overload_next),
		"overload_emit_outside_branch",
		"雷怒核心的技能音没有落在 `stack_delta < 0`（反击发生）那一支里 —— \
它会在别的帧响（比如每次挨打涨层数时）")

	# 双生守门人：`alive` 由假转真那一格 = 复活。
	var twin_branch := vfx.find('if sid_now == "twin_revive" and not bool(prev.get("alive", true))')
	var twin_emit := vfx.find('"skill_id": "twin_revive",', maxi(twin_branch, 0))
	var twin_next := vfx.find("var prev_apocalypse := ", maxi(twin_branch, 0))
	h.expect(twin_branch >= 0, "twin_branch_missing", "找不到「双生守门人复活」那一格")
	h.expect(twin_branch >= 0 and twin_emit > twin_branch
			and (twin_next < 0 or twin_emit < twin_next),
		"twin_emit_outside_branch",
		"双生守门人的复活音没有落在 alive 上升沿那一格 —— 它会在别的时刻响")

	# 反向对照：**普攻触发型**那条路必须继续带归属门控（缩进无关，看的是函数体里有没有）。
	# 少了这条，「boss 那支没门控」在整份文件都没门控时也会通过。
	var proc_at := vfx.find("func _maybe_play_sfx_proc(")
	var proc_end := vfx.find("\nfunc ", maxi(proc_at, 0) + 10)
	var proc_body := vfx.substr(proc_at, (proc_end - proc_at) if (proc_at >= 0 and proc_end > proc_at) else 1200)
	h.expect(proc_at >= 0 and proc_body.contains("_is_own_or_ally_unit(source_uid)"),
		"sfx_proc_gate_removed",
		"四星 / 佣兵那条 `sfx_proc` 分支的归属门控被拆掉了 —— 敌方棋子的普攻技能音也会响")

	# 消费支本身：`play()` **既不套归属门控、也不套星级门** ——
	# boss 固定是敌方单位，套上 `_is_own_or_ally_unit` 就是「永远不响」。
	# 判据不能用缩进：`play(cue)` 天然在 `if not cue.is_empty():`（缩进 2）里，
	# 它该在的层级与「在不在门控里」是两件事，锚错一个就会误红。
	var consume_at := vfx.find("func _maybe_play_boss_skill_proc(")
	if consume_at < 0:
		h.fail("boss_event_consumer_missing_in_diff", "找不到 _maybe_play_boss_skill_proc 函数体")
		return
	var consume_end := vfx.find("\nfunc ", consume_at + 10)
	var consume_body := vfx.substr(consume_at, (consume_end - consume_at) if consume_end > 0 else 2000)
	h.expect(consume_body.contains("SfxService.play(cue)"), "boss_event_consumer_no_play",
		"boss 真事件的消费支里没有 play() —— 一条永远不会响的音")
	h.expect(not consume_body.contains("_is_own_or_ally_unit"), "boss_event_consumer_gated",
		"boss 真事件的消费支里出现了 `_is_own_or_ally_unit` —— boss 固定是敌方单位，\
套上归属门控就是永远不响")
	h.expect(not consume_body.contains("_is_star4"), "boss_event_consumer_star_gated",
		"boss 真事件的消费支里出现了 `_is_star4` —— boss 不是四星棋子，套上星级门就是永远不响")
	h.expect(_indent_of(vfx, "if not _maybe_play_boss_skill_proc(event):") == 3,
		"boss_event_consumer_dedented",
		"`if not _maybe_play_boss_skill_proc(event):` 的缩进不是 3（应在 `sfx_proc` 分支里）—— \
它跑到别的位置去了，事件不会经过 boss 那一支")


# --- ② 续：**真的跑一遍模拟器**，看那四条真事件的触发时刻 ------------------------
#
# 判据全部落在 `visual_events` 上（而不是源码文本），因为这一批错的正是
# 「时刻」而不是「有没有写」。每条都配一条反证，免得把「无条件补一条」当成功。
func _check_boss_event_emitters(h) -> void:
	_check_blood_rage_emitter(h)
	_check_soul_devour_emitter(h)
	_check_apocalypse_emitter(h)
	_check_mirror_clone_emitter(h)


func _sfx_proc_count(state: Dictionary) -> int:
	var n := 0
	for e in state.get("visual_events", []):
		if e is Dictionary and str((e as Dictionary).get("type", "")) == "sfx_proc":
			n += 1
	return n


func _boss_fighter(def: Dictionary, team: String) -> Dictionary:
	var f: Dictionary = BattleSimShared._fighter_from_def(def, 0, team, 0, 1, 1)
	f.pos = Vector2(500.0, 300.0 if team == "enemy" else 295.0)
	return f


func _check_blood_rage_emitter(h) -> void:
	var rage := {
		"id": "boss_blood_demon", "name": "血怒魔王", "hp": 4000, "atk": 100, "def": 20,
		"attack_speed": 1.0, "range": 1, "move_speed": 0.0, "crit": 0.0, "crit_dmg": 1.5,
		"skill_id": "blood_rage", "trigger_hp_pct": 0.35, "atk_bonus": 0.40,
		"aspd_bonus": 0.30, "lifesteal": 0.10, "is_boss": true, "tier": 1,
		"element": "-", "race": "-",
	}
	var boss := _boss_fighter(rage, "enemy")
	var prey := _boss_fighter(_dummy_def(), "player")
	var st := _state([prey], [boss])

	# 反证①：血量还高（60%）时不该响。
	boss.hp = int(round(float(boss.max_hp) * 0.60))
	BattleSimTreasures._apply_boss_attacker_passives(boss, st)
	h.expect(_sfx_procs(st, "blood_rage").is_empty(), "blood_rage_proc_early",
		"血怒魔王在 60% 血就补了暴走事件 —— 「降至 35% 以下」这个门槛没生效")
	h.expect(not bool(boss.get("blood_rage_active", false)), "blood_rage_flag_early",
		"血量还高就进了暴走状态 —— 门槛判据本身错了")

	# 正例：掉到 30% 以下 → 一次。
	boss.hp = int(round(float(boss.max_hp) * 0.30))
	BattleSimTreasures._apply_boss_attacker_passives(boss, st)
	var hits := _sfx_procs(st, "blood_rage")
	h.expect(hits.size() == 1, "blood_rage_proc_missing",
		"血怒魔王掉到 30%% 血（进入暴走）却没有补事件（实际 %d 条）—— 用户报的「音效未生效」"
			% hits.size())
	if hits.size() == 1:
		h.expect(str((hits[0] as Dictionary).get("source_uid", "")) == str(boss.get("uid", "")),
			"blood_rage_proc_source_wrong",
			"血怒魔王事件的 source_uid 不是它自己 —— 排障时认不出是谁在响")

	# ★ 「**仅播放一次**」（用户明确要求）：后面再挨多少次打都不能再补。
	for i in 3:
		BattleSimTreasures._apply_boss_attacker_passives(boss, st)
	h.expect(_sfx_procs(st, "blood_rage").size() == 1, "blood_rage_proc_repeat",
		"暴走事件补了不止一次 —— 用户要求「进入暴走时播放**一次**该音效」")


func _check_soul_devour_emitter(h) -> void:
	var soul := {
		"id": "boss_soul_devourer", "name": "噬魂领主", "hp": 4000, "atk": 100, "def": 20,
		"attack_speed": 1.0, "range": 1, "move_speed": 0.0, "crit": 0.0, "crit_dmg": 1.5,
		"skill_id": "soul_devour", "kill_heal_pct": 0.15, "atk_stack": 0.10,
		"is_boss": true, "tier": 1, "element": "-", "race": "-",
	}
	var boss := _boss_fighter(soul, "enemy")
	var victim := _boss_fighter(_dummy_def(), "player")
	victim.hp = 0
	victim.alive = false
	var st := _state([victim], [boss])
	BattleSimulator._on_unit_killed(boss, victim, st, [boss], [victim])
	var hits := _sfx_procs(st, "soul_devour")
	h.expect(hits.size() == 1, "soul_devour_proc_missing",
		"噬魂领主击杀了一个单位却没有补事件（实际 %d 条）—— 用户报的「音效未生效」" % hits.size())
	if hits.size() == 1:
		h.expect(str((hits[0] as Dictionary).get("source_uid", "")) == str(boss.get("uid", "")),
			"soul_devour_proc_source_wrong", "噬魂领主事件的 source_uid 不是击杀者")

	# 反证：不带 soul_devour 的击杀者不该补这条事件。
	var plain_row := _row("human_swordsman")
	if plain_row.is_empty():
		return
	var plain := _boss_fighter(_dummy_def(), "enemy")
	plain["def"] = plain_row
	var prey := _boss_fighter(_dummy_def(), "player")
	prey.hp = 0
	prey.alive = false
	var st2 := _state([prey], [plain])
	BattleSimulator._on_unit_killed(plain, prey, st2, [plain], [prey])
	h.expect(_sfx_procs(st2, "soul_devour").is_empty(), "soul_devour_proc_spurious",
		"不带 soul_devour 的棋子击杀也补了噬魂领主那条音 —— 事件是无条件补的")


func _check_apocalypse_emitter(h) -> void:
	var charge := {
		"id": "boss_apocalypse", "name": "灭世裁决者", "hp": 5000, "atk": 100, "def": 30,
		"attack_speed": 1.0, "range": 1, "move_speed": 0.0, "crit": 0.0, "crit_dmg": 1.5,
		"skill_id": "apocalypse_charge", "charge_shield_pct": 0.10, "charge_sec": 2.0,
		"damage_atk_pct": 2.5, "ignore_def": true, "skill_cd": 10.0, "is_boss": true,
		"tier": 1, "element": "-", "race": "-",
	}
	var boss := _boss_fighter(charge, "enemy")
	var prey := _boss_fighter(_dummy_def(), "player")
	var st := _state([prey], [boss])
	boss.skill_ready = 0.0
	st.elapsed = 0.0
	BattleSimulator._tick_skills([boss], [prey], st)

	# ① 起播：一次，且必须在真的开始蓄力之后（盾跟着涨）。
	var charge_hits := _sfx_procs(st, "apocalypse_charge")
	h.expect(charge_hits.size() == 1, "apocalypse_charge_proc_missing",
		"灭世裁决者开始蓄力却没有补事件（实际 %d 条）—— 用户报的「音效未生效」" % charge_hits.size())
	h.expect(int(boss.get("shield", 0)) > 0, "apocalypse_charge_no_shield",
		"蓄力开始了却没加盾 —— 下面「被打断」那一档无从谈起")
	h.expect(_source_ok(charge_hits, boss), "apocalypse_charge_proc_source_wrong",
		"蓄力事件的 source_uid 不是灭世裁决者自己")

	# ★ 「仅播放一次」（用户明确要求）：再走一次 match（还在蓄力中）也不能再补。
	boss.skill_ready = 0.0
	BattleSimulator._tick_skills([boss], [prey], st)
	h.expect(_sfx_procs(st, "apocalypse_charge").size() == 1, "apocalypse_charge_proc_repeat",
		"蓄力事件补了不止一次 —— 用户要求「技能开始蓄力的音效**仅播放一次**」")

	# ② 蓄力中：不该补任何收口事件。
	st.elapsed = 1.0
	BattleSimulator._process_boss_charges(st)
	h.expect(_sfx_procs(st, "apocalypse_stop").is_empty() and _sfx_procs(st, "apocalypse_impact").is_empty(),
		"apocalypse_stop_too_early", "蓄力还没到点就补了收口事件 —— 蓄力音会被提前掐掉")

	# ③ 完成：到点且真的打到了人 → impact。
	st.elapsed = float(boss.get("apocalypse_due", 0.0))
	BattleSimulator._process_boss_charges(st)
	h.expect(_sfx_procs(st, "apocalypse_impact").size() == 1, "apocalypse_impact_proc_missing",
		"蓄力完成并打出全场伤害却没有补 impact 事件 —— 「蓄力完成」那一声不会响")
	h.expect(int(prey.get("hp", 0)) < int(prey.get("max_hp", 1)), "apocalypse_impact_no_damage",
		"蓄力完成却没对目标造成伤害 —— 上面那条判据是假绿")

	# ④ 完成但**没打到人** → 只收口（stop），不补 impact。
	#    这一档正是 9.22 把 stop_cue 排在两个 if 之前要防的那个洞。
	var no_target := _boss_fighter(_dummy_def(), "player")
	no_target.hp = 0
	no_target.alive = false
	var st2 := _state([no_target], [boss])
	boss.erase("apocalypse_due")
	boss.shield = maxi(1, int(boss.get("shield", 1)))
	var impact_before := _sfx_procs(st2, "apocalypse_impact").size()
	var stop_before := _sfx_procs(st2, "apocalypse_stop").size()
	boss.apocalypse_due = 0.0
	st2.elapsed = 0.0
	BattleSimulator._process_boss_charges(st2)
	h.expect(_sfx_procs(st2, "apocalypse_stop").size() == stop_before + 1,
		"apocalypse_fizzle_stop_missing",
		"蓄力完成但没打到任何人时没有补 stop 事件 —— 2 秒的蓄力音会继续放到素材结束，与「已经打完了」错位")
	h.expect(_sfx_procs(st2, "apocalypse_impact").size() == impact_before,
		"apocalypse_fizzle_plays_impact",
		"蓄力完成但没打到任何人却补了 impact 事件 —— 会响一声空的完成音")

	# ⑤ 被打断：盾被打光 → stop。
	var st3 := _state([_boss_fighter(_dummy_def(), "player")], [boss])
	boss.erase("apocalypse_due")
	boss.shield = 0
	boss.apocalypse_due = float(st3.elapsed) + 2.0
	BattleSimulator._process_boss_charges(st3)
	h.expect(_sfx_procs(st3, "apocalypse_stop").size() == 1, "apocalypse_interrupt_proc_missing",
		"蓄力被打断（盾被打光）却没有补 stop 事件 —— 用户口径「蓄力时的音效暂停播放」做不到")


func _check_mirror_clone_emitter(h) -> void:
	var mirror := {
		"id": "boss_mirror_lord", "name": "镜像魔君", "hp": 4000, "atk": 100, "def": 20,
		"attack_speed": 1.0, "range": 1, "move_speed": 0.0, "crit": 0.0, "crit_dmg": 1.5,
		"skill_id": "mirror_clone", "clone_per_missing_hp_pct": 0.25, "clone_hp_pct": 0.30,
		"clone_atk_pct": 0.40, "clone_def": 0, "is_boss": true, "tier": 1,
		"element": "-", "race": "-",
	}
	var boss := _boss_fighter(mirror, "enemy")
	var prey := _boss_fighter(_dummy_def(), "player")
	var st := _state([prey], [boss])
	# 血量满 → 不该召唤，也不该响。
	boss.skill_ready = 0.0
	BattleSimulator._tick_skills([boss], [prey], st)
	h.expect(_sfx_procs(st, "mirror_clone").is_empty(), "mirror_clone_proc_early",
		"镜像魔君满血（掉血比例 0）就补了召唤事件 —— 事件是无条件补的")

	# 掉到 50% → 掉血 0.5 / 每 0.25 一个分身 = 该有 2 个 → 一次事件（技能是「召唤」这一下）。
	boss.hp = int(round(float(boss.max_hp) * 0.50))
	boss.skill_ready = 0.0
	BattleSimulator._tick_skills([boss], [prey], st)
	var hits := _sfx_procs(st, "mirror_clone")
	h.expect(hits.size() == 1, "mirror_clone_proc_missing",
		"镜像魔君真的召唤出分身却没有补事件（实际 %d 条）—— 用户报的「音效未生效」/「一直播放」"
			% hits.size())

	# ★ 「不是一直播放」（用户原话）：技能每秒都会被 `_tick_skills` 调到一次，
	#   但只有分身数量变化的**那一次**才该响 —— 这里连走 3 次 match 逼它。
	for i in 3:
		boss.skill_ready = 0.0
		BattleSimulator._tick_skills([boss], [prey], st)
	h.expect(_sfx_procs(st, "mirror_clone").size() == 1, "mirror_clone_proc_repeat",
		"账号没再召唤新分身，事件却补了 %d 次 —— 用户报的「一直播放」又回来了"
			% _sfx_procs(st, "mirror_clone").size())


# 事件里的 source_uid 是否指向给定的棋子（排障用：认得出是谁在响）。
func _source_ok(events: Array, unit: Dictionary) -> bool:
	for e in events:
		if e is Dictionary and str((e as Dictionary).get("source_uid", "")) == str(unit.get("uid", "")):
			return true
	return false


# --- 运行级：那几条 cue 真的播得出去 -------------------------------------------

func _check_runtime_playback(h) -> void:
	var waited := 0
	while not SfxService.voices_ready() and waited < 60:
		await get_tree().process_frame
		waited += 1
	h.expect(SfxService.voices_ready(), "sfx_voices_not_ready",
		"等了 %d 帧，播放器池仍未挂进场景树 —— 后面的播放断言都不成立" % waited)
	if not SfxService.voices_ready():
		return
	await get_tree().process_frame

	for cue in [
		SfxService.CUE_BOSS_MIRROR_LORD_SKILL,
		SfxService.CUE_BOSS_TWIN_GATE_REVIVE,
		SfxService.CUE_BOSS_APOCALYPSE_CHARGE,
		SfxService.CUE_BOSS_APOCALYPSE_IMPACT,
		SfxService.CUE_MERC_GEMINI_ASSASSIN_SKILL,
		SfxService.CUE_MERC_LIBRA_JUDGE_PROC,
		SfxService.CUE_STAR4_SPIKE_PROC,
		SfxService.CUE_STAR4_POISON_PROC,
		SfxService.CUE_STAR4_TITAN_PROC,
		SfxService.CUE_STAR4_MOTONG_PROC,
	]:
		SfxService.reset_counters_for_check()
		var ok := SfxService.play(cue)
		h.expect(ok, "cue_play_refused_%s" % cue, "play(%s) 被拒（文件缺失 / 未登记）" % cue)
		h.expect(SfxService.play_count(cue) == 1, "cue_not_counted_%s" % cue,
			"play(%s) 没有真的计数 —— 播放器池没就绪" % cue)
