extends Node

# V2 P1-05 第 1、3 条的门禁。
#
# 第 1 条「普攻：轻微前冲/后坐、命中闪、单次小屏震；暴击只放大 20%-35%，不堆全屏闪白」
#   * 命中闪本来就有（ProceduralVFXEffect 的 Flash + 冲击粒子）。
#   * 前冲/后坐**原本没有**，是这一项新加的。
#   * ~~"单次小屏震"~~ **2026-10-24 手游化推翻**：真机上一场普攻几百下，再小的屏震
#     叠起来也是整局在抖。2905067e 删掉 IMPACT_SHAKE_STRENGTH / IMPACT_SHAKE_SEC，
#     cue_play_impact_feedback 改成空实现，屏震只留给技能（BattleCameraShakePolicy）。
#     本门禁跟着转向：见 _check_basic_hit_does_not_shake()，验的是"普攻一下都不许震、
#     但技能的还在"。
#   * "暴击只放大，不另堆一层"现在落在 BattleHitFeedback 的逐单位反馈上：
#     闪白/后仰/压扁三条通道 basic 与 crit 同 key 不同值，crit 只能是 basic 的放大。
#     V2 原文的 20%-35% 是给全屏震动定的，不再直接套用，理由见 CRIT_LOCAL_RATIO_MAX。
#
# 第 3 条「胜利：镜头轻收束、幸存者定格、胜利字样和短音效/震动；至少保持 0.8 秒」
#   * 保持时长本来就够（RESULT_DISPLAY_SECONDS = 1.0）。
#   * 收束和定格是新加的。
#   * ~~**短音效没做**~~ **2026-09-17 已补**：assets/audio 下此前只有 BGM 和一个
#     start_game.mp3，没有胜利音效资源，这条门禁当时如实记缺口。9.17 音效批次
#     交付了 `assets/audio/sfx/battle/battle_victory.mp3` / `battle_defeat.mp3`，
#     由 `ui/services/SfxService.gd` 在 BattleResult 的结算浮层处播。
#     本门禁**仍然不验发声**（headless 是 Dummy 音频驱动，验不了），
#     「有没有接上」由 `tools/audio_sfx_check.gd` 的 `cue_without_call_site` 管。
#
# 前冲位移打在 ActorRoot 上，因为 _position_3d_model_node() 每帧都会重写
# actor.position。这条约束写成了下面的反向断言：谁把位移改到 actor 上就会红。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const BattleVfxScript := preload("res://scenes/battle/BattleVfx.gd")
const BattleUIScript := preload("res://scenes/battle/BattleUI.gd")
const UnitActor3DScript := preload("res://effects/runtime/presentation/UnitActor3D.gd")
const ShakePolicyScript := preload("res://scripts/battle/BattleCameraShakePolicy.gd")
const CHECK_NAME := "battle_hit_victory"

# 暴击在**逐单位**反馈上的放大上限。V2 原文的 1.20-1.35 是给全屏震动定的，
# 10.24 普攻屏震拿掉之后那一档不存在了；局部反馈只动受击的那一只棋子，
# 读得出来的上限高得多（实测 flash 1.73 / flinch 1.67 / squash 1.57）。
const CRIT_LOCAL_RATIO_MAX := 1.80
# 顿帧上限：自走棋每秒几十下命中，再长就读成卡顿。
const HITSTOP_MAX_SEC := 0.08
# V2 原文：结算至少保持 0.8 秒再进奖励。
const RESULT_HOLD_MIN_SEC := 0.8

var _h: RefCounted


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_check_crit_is_only_an_amplifier()
	_check_lunge_is_small_and_returns()
	_check_basic_hit_does_not_shake()
	_check_victory_hold_and_tighten()
	_check_wiring()
	await _check_lunge_meta_guard()
	_h.finish(get_tree())


# 2026-08-30，Codex 真机验收发现的运行时红灯：
#
#   ERROR: The object does not have any 'meta' values with the key 'lunge_tween'.
#
# 设备 logcat 135 次，本地 round 1 一场 18 次 —— **不是 Android 特有的**。
# 起因是前冲用了 `get_meta("lunge_tween", null)` 的两参数形式：Godot 4.7 里这个形式
# 照样会为缺失 key 打引擎 ERROR（默认值确实返回了，错误也确实打了），而第一次攻击时
# 这个 key 根本没设过，于是每个单位的第一拳都刷一条。
#
# 它能溜过桌面全套门禁，是因为那是普通的 `ERROR:` 而不是 `SCRIPT ERROR:`，
# 而 run_check.ps1 的 EngineErrorPatterns 里没有这个模式。
#
# 下面这些是**运行时断言**：真造两个 actor、真调 cue_play_attack_lunge，
# 走的正是会打 ERROR 的那条路径。不靠源码文本。
func _check_lunge_meta_guard() -> void:
	var vfx := BattleVfxScript.new()
	add_child(vfx)
	var attacker: Node3D = UnitActor3DScript.new()
	var target: Node3D = UnitActor3DScript.new()
	add_child(attacker)
	add_child(target)
	attacker.configure_contract(0.98, "melee")
	target.configure_contract(0.98, "melee")
	attacker.position = Vector3.ZERO
	target.position = Vector3(0.0, 0.0, 2.0)
	vfx._battle_3d_models = {"attacker": attacker, "target": target}

	var root := attacker.get_node_or_null("ActorRoot") as Node3D
	if not _h.expect(root != null, "lunge_actor_has_no_root", "测试用 actor 没有 ActorRoot"):
		vfx.queue_free()
		return

	# 第一次攻击：key 还不存在。这正是会打 ERROR 的那一刻。
	_h.expect(not attacker.has_meta("lunge_tween"),
		"lunge_meta_preset",
		"第一次攻击前 lunge_tween 就已经存在了 —— 那这条断言测不到真正的首拳路径")
	var first_ok: bool = vfx.cue_play_attack_lunge("attacker", "target", false)
	if not _h.expect(first_ok, "lunge_first_call_failed", "第一次 cue_play_attack_lunge 返回 false"):
		vfx.queue_free()
		return
	_h.expect(attacker.has_meta("lunge_tween"),
		"lunge_tween_not_stored", "第一次前冲之后没有把 tween 存进 meta，第二次就杀不掉它")
	var first_tween = attacker.get_meta("lunge_tween")
	_h.expect(first_tween is Tween and (first_tween as Tween).is_valid(),
		"lunge_tween_invalid", "存进 meta 的不是一条有效的 Tween")
	_h.expect(root.position.is_equal_approx(Vector3.ZERO),
		"lunge_does_not_start_at_origin",
		"起手瞬间 ActorRoot 不在原点（%s）" % str(root.position))

	# 让第一条真的跑起来，位移离开原点 —— 否则下面「第二次复位」测不到东西。
	for _i in range(6):
		await get_tree().process_frame
	_h.expect(root.position.length() > 0.0001,
		"lunge_never_moves",
		"推进 6 帧后 ActorRoot 仍在原点，前冲根本没动")

	# 第二次攻击：必须杀掉上一条并从原点重新起步，否则位移会累加。
	var second_ok: bool = vfx.cue_play_attack_lunge("attacker", "target", false)
	_h.expect(second_ok, "lunge_second_call_failed", "第二次 cue_play_attack_lunge 返回 false")
	_h.expect(not (first_tween as Tween).is_valid(),
		"previous_tween_not_killed",
		"第二次前冲没有杀掉上一条 tween —— 两条一起推，ActorRoot 会被推走")
	_h.expect(root.position.is_equal_approx(Vector3.ZERO),
		"lunge_not_reset_before_restart",
		"第二次前冲没有把 ActorRoot 复位到原点（%s），位移会累加" % str(root.position))

	attacker.queue_free()
	target.queue_free()
	vfx.queue_free()

	# 精确的否定断言：源码里不得再出现两参数形式。
	#
	# 需要这一条是因为有守卫和无守卫两个版本**行为完全相同**（都返回 null 继续走），
	# 唯一差别是打了一条引擎 ERROR —— GDScript 侧捕获不到。所以上面那些运行时断言
	# 抓不住这个变异，只有针对确切缺陷形态的否定断言能抓。
	#
	# 这不是「字符串存在即通过」的假绿：它断言的是那个**有缺陷的写法不存在**，
	# 改回去必然红。
	var src := FileAccess.get_file_as_string("res://scenes/battle/BattleVfx.gd")
	if not _h.expect(not src.is_empty(), "vfx_source_unreadable", "读不到 BattleVfx.gd"):
		return
	_h.expect(not src.contains('get_meta("lunge_tween", '),
		"lunge_meta_read_unguarded",
		"出现了 get_meta(\"lunge_tween\", …) 的两参数形式 —— 它会为缺失 key 打引擎 ERROR，"
			+ "首次攻击每个单位刷一条。必须先 has_meta 再单参数 get_meta。")
	_h.expect(src.contains('actor.has_meta("lunge_tween")'),
		"lunge_meta_guard_missing",
		"找不到 has_meta(\"lunge_tween\") 守卫")


# 暴击只能是"同一套演出乘一个系数"，不另开一层效果。
#
# 10.24 手游化之后，这条的落点换了地方：暴击的强调原本是 IMPACT_SHAKE_STRENGTH *
# CRIT_EMPHASIS_SCALE 的那一下屏震，现在屏震整个从普攻/暴击路径拿掉了（见
# _check_basic_hit_does_not_shake），强调改由 BattleHitFeedback 的**逐单位**反馈承担：
# 闪白强度、后仰角度、压扁幅度三条通道，basic / crit 用同一组 key 取不同数值。
# 所以"同一套演出乘一个系数"在这里的可执行判据是：**crit 不得出现 basic 没有的通道**，
# 并且每条通道上 crit 都只是把 basic 的值放大。
#
# V2 原文的 20%-35% 不再直接套用：那是全屏震动的幅度上限，一场里每次普攻都要震，
# 稍大就糊成一片；现在是只动受击那一只棋子的局部反馈，看得见的上限高得多
# （实际 1.57-1.73）。所以这里换成 CRIT_LOCAL_RATIO_MAX 这个**局部反馈**的上限，
# 并且仍然守住"不许另开一层"和"不许全屏闪白"这两条真正的红线。
func _check_crit_is_only_an_amplifier() -> void:
	var channels := {
		"flash": BattleHitFeedback.FLASH_STRENGTH,
		"flinch": BattleHitFeedback.FLINCH_DEG,
		"squash": BattleHitFeedback.SQUASH,
	}
	for channel in channels:
		var table: Dictionary = channels[channel]
		if not _h.expect(table.has("basic") and table.has("crit"),
			"crit_channel_missing",
			"BattleHitFeedback 的 %s 没有同时给 basic 和 crit —— 暴击必须和普攻走同一条通道" % channel):
			continue
		var base := float(table["basic"])
		var crit := float(table["crit"])
		_h.expect(base > 0.0 and crit > base,
			"crit_not_an_amplification",
			"%s 通道上暴击 %.3f 不是普攻 %.3f 的放大" % [channel, crit, base])
		_h.expect(crit <= base * CRIT_LOCAL_RATIO_MAX,
			"crit_ratio_out_of_range",
			"%s 通道上暴击是普攻的 %.2f 倍，超过局部反馈上限 %.2f —— 再大就读成「另一种命中」了"
				% [channel, crit / maxf(base, 0.0001), CRIT_LOCAL_RATIO_MAX])

	# 顿帧是暴击/技能独有的一档，basic 没有。它是唯一允许的"多出来的通道"，
	# 条件是必须短到只读成一下发力：超过 0.08 秒就会读成卡顿。
	for tier in BattleHitFeedback.HITSTOP_SEC:
		_h.expect(float(BattleHitFeedback.HITSTOP_SEC[tier]) <= HITSTOP_MAX_SEC,
			"hitstop_too_long",
			"%s 的顿帧 %.3f 秒超过 %.2f —— 自走棋每秒几十下命中，会读成卡顿"
				% [tier, float(BattleHitFeedback.HITSTOP_SEC[tier]), HITSTOP_MAX_SEC])
	_h.expect(not BattleHitFeedback.HITSTOP_SEC.has("basic"),
		"basic_got_hitstop",
		"普攻也带上顿帧了 —— 普攻数量远多于技能，会一卡一卡")

	# 反向：仓里不该出现全屏闪白。V2 第 1 条明确禁止。闪白实现搬到 BattleHitFeedback
	# 之后，这条也要跟着看那个文件，否则换个文件写全屏闪白就绕过去了。
	for path in ["res://scenes/battle/BattleVfx.gd",
			"res://effects/runtime/presentation/BattleHitFeedback.gd"]:
		var src := FileAccess.get_file_as_string(path)
		if not _h.expect(not src.is_empty(), "crit_source_unreadable", "读不到 %s" % path):
			continue
		for banned in ["fullscreen_flash", "screen_flash", "white_flash"]:
			_h.expect(not src.contains(banned),
				"fullscreen_flash_added",
				"%s 里出现了 %s —— V2 第 1 条明确写「不堆全屏闪白」" % [path, banned])


# 前冲要"轻微"，而且必须回到原点。回不去的话单位会被一路推走。
func _check_lunge_is_small_and_returns() -> void:
	var distance: float = BattleVfxScript.ATTACK_LUNGE_DISTANCE
	# 单位实测世界高度约 0.95，前冲超过身高的四分之一就不叫"轻微"了。
	_h.expect(distance > 0.0 and distance <= 0.24,
		"lunge_not_subtle",
		"前冲距离 %.3f 不在 (0, 0.24] —— 单位实测约 0.95 高，再大就成冲锋了" % distance)
	_h.expect(BattleVfxScript.RANGED_RECOIL_FACTOR < 0.0,
		"ranged_not_recoil",
		"远程的系数 %.2f 不是负数 —— 远程该是后坐，不是往目标冲"
			% BattleVfxScript.RANGED_RECOIL_FACTOR)
	_h.expect(absf(BattleVfxScript.RANGED_RECOIL_FACTOR) < 1.0,
		"ranged_recoil_too_big",
		"远程后坐幅度不应超过近战前冲")

	var out_sec: float = BattleVfxScript.ATTACK_LUNGE_OUT_SEC
	var back_sec: float = BattleVfxScript.ATTACK_LUNGE_BACK_SEC
	_h.expect(out_sec > 0.0 and back_sec > 0.0,
		"lunge_has_no_duration", "前冲的出手或收回时长是 0")
	_h.expect(out_sec + back_sec <= 0.30,
		"lunge_too_slow",
		"一次前冲要 %.3f 秒 —— 普攻间隔比这短，会一直堆在半路" % (out_sec + back_sec))
	# 收回要比出手慢：出手快、收回缓才读得出"发力"。
	_h.expect(back_sec > out_sec,
		"lunge_snaps_back",
		"收回 %.3f 秒不比出手 %.3f 秒慢 —— 会读成抖了一下而不是发力"
			% [back_sec, out_sec])


# 10.24 手游化改掉的是这一条的前提：原来普攻命中有一下"小屏震"，这里只管它够不够小。
# 真机上一场战斗普攻几百下，再小的屏震叠起来也是整局在抖，所以那一下被整个拿掉了
# （2905067e 删了 IMPACT_SHAKE_STRENGTH / IMPACT_SHAKE_SEC，cue_play_impact_feedback
# 改成空实现），强调改走 BattleHitFeedback 的逐单位反馈。
#
# 门禁跟着换方向：从"小屏震够不够小"变成"普攻这条路上一下都不许震"。
func _check_basic_hit_does_not_shake() -> void:
	var src := FileAccess.get_file_as_string("res://scenes/battle/BattleVfx.gd")
	if not _h.expect(not src.is_empty(), "vfx_source_unreadable", "读不到 BattleVfx.gd"):
		return

	# 只看 cue_play_impact_feedback 的函数体。整文件 contains 会被技能屏震那条满足，
	# 也会被这上面的注释满足 —— 那样这条断言不可证伪。
	var body := _function_body(src, "func cue_play_impact_feedback(")
	if _h.expect(not body.is_empty(), "impact_cue_missing",
			"找不到 cue_play_impact_feedback —— adapter 还在按这个名字回调"):
		for banned in ["_screen_shake(", "play_screen_shake("]:
			_h.expect(not body.contains(banned),
				"basic_hit_shakes_again",
				"cue_play_impact_feedback 里又调了 %s —— 普攻每秒几十下，会抖一整场" % banned)

	# 常量也不该复活：留着就会有人顺手接回去。
	for gone in ["IMPACT_SHAKE_STRENGTH", "IMPACT_SHAKE_SEC"]:
		_h.expect(not src.contains("const %s" % gone),
			"impact_shake_const_back",
			"%s 回来了 —— 普攻命中屏震是 10.24 手游化有意删掉的" % gone)

	# 正向控制：屏震本身必须还在、还只给技能。只断言"普攻不震"的话，
	# 把 is_candidate 改成恒 false（技能也不震了）同样会绿。
	var basic_hit := {"type": "hit_number", "kind": "dmg", "amount": 120, "skill": false}
	var skill_hit := {"type": "hit_number", "kind": "dmg", "amount": 120, "skill": true}
	_h.expect(not ShakePolicyScript.is_candidate(basic_hit),
		"basic_hit_is_shake_candidate",
		"普攻命中仍然算屏震候选 —— BattleCameraShakePolicy 必须只认技能伤害")
	_h.expect(ShakePolicyScript.is_candidate(skill_hit),
		"skill_shake_gone",
		"技能伤害也不再是屏震候选 —— 屏震被整个关掉了，不是只关普攻")
	_h.expect(src.contains("_screen_shake(6.5, 0.20)"),
		"skill_shake_call_gone",
		"找不到技能屏震的调用 —— 第 1 条只去掉普攻那一下，技能的要留着")


func _check_victory_hold_and_tighten() -> void:
	_h.expect(BattleUIScript.RESULT_DISPLAY_SECONDS >= RESULT_HOLD_MIN_SEC,
		"result_hold_too_short",
		"结算只保持 %.2f 秒，V2 要求至少 %.1f 秒"
			% [BattleUIScript.RESULT_DISPLAY_SECONDS, RESULT_HOLD_MIN_SEC])

	var renderer := FileAccess.get_file_as_string("res://scenes/battle/BattleRenderer.gd")
	if not _h.expect(not renderer.is_empty(), "renderer_unreadable", "读不到 BattleRenderer.gd"):
		return
	# 收束必须"轻"：正交相机 size 越小越近，收得太狠会把边上的幸存者挤出画面。
	var at := renderer.find("const VICTORY_CAMERA_TIGHTEN := ")
	if not _h.expect(at >= 0, "tighten_const_missing", "找不到 VICTORY_CAMERA_TIGHTEN"):
		return
	var line := renderer.substr(at, 60).split("\n")[0]
	var tighten := line.split(":=")[1].strip_edges().to_float()
	_h.expect(tighten < 1.0 and tighten >= 0.88,
		"tighten_out_of_range",
		"镜头收束系数 %.3f 不在 [0.88, 1.0) —— 不收或者收太狠都不对" % tighten)


# 光有函数不够，得证明它们真的被战斗流程调到了。
func _check_wiring() -> void:
	var adapter := FileAccess.get_file_as_string(
		"res://effects/runtime/presentation/adapters/LegacyBattleVfxAdapter.gd")
	var screen := FileAccess.get_file_as_string("res://scenes/battle/BattleScreen.gd")
	var renderer := FileAccess.get_file_as_string("res://scenes/battle/BattleRenderer.gd")
	if not _h.expect(not adapter.is_empty() and not screen.is_empty() and not renderer.is_empty(),
		"wiring_source_unreadable", "读不到接线涉及的源文件"):
		return

	_h.expect(adapter.contains("cue_play_attack_lunge"),
		"lunge_not_wired", "起手那一拍没有调 cue_play_attack_lunge —— 前冲是死代码")
	_h.expect(adapter.contains("cue_play_impact_feedback"),
		"impact_feedback_not_wired",
		"命中那一拍没有调 cue_play_impact_feedback —— 它现在是空实现，但 adapter 的拍点契约还靠它")
	_h.expect(screen.contains("play_victory_finish()"),
		"victory_not_wired", "结算流程没有调 play_victory_finish() —— 收束和定格是死代码")
	_h.expect(screen.contains("reset_battle_camera_framing()"),
		"camera_never_reset", "开局没有重置取景 —— 收束会一场比一场紧")

	# 位移必须打在 ActorRoot 上。打在 actor 上会被 _position_3d_model_node() 每帧覆盖，
	# 前冲就完全看不见 —— 这是这一项最容易写错的地方。
	var vfx := FileAccess.get_file_as_string("res://scenes/battle/BattleVfx.gd")
	var lunge_at := vfx.find("func cue_play_attack_lunge")
	if not _h.expect(lunge_at >= 0, "lunge_missing", "找不到 cue_play_attack_lunge()"):
		return
	var body := vfx.substr(lunge_at, 1500)
	_h.expect(body.contains('get_node_or_null("ActorRoot")'),
		"lunge_on_wrong_node",
		"前冲没有打在 ActorRoot 上 —— actor.position 每帧都被模拟位置重写，位移会看不见")
	_h.expect(body.contains("kill()"),
		"lunge_tween_not_killed",
		"连续攻击时没有杀掉上一条前冲 tween —— 位移会累加，单位会被一路推走")


# 取某个函数的函数体（不含签名行，去掉行注释）。
#
# 整文件 contains 做否定断言会被别处的同名调用、甚至被断言自己上面那条注释满足 ——
# 那样的门禁不可证伪。所以凡是"某函数里不得出现 X"的判据，都先切出函数体再看。
# 结束条件是下一个顶格的 func / 顶格声明：GDScript 的函数体必须缩进。
func _function_body(src: String, signature: String) -> String:
	var at := src.find(signature)
	if at < 0:
		return ""
	var lines := src.substr(at).split("
")
	var body := PackedStringArray()
	for i in range(1, lines.size()):
		var line: String = lines[i]
		if not line.is_empty() and not line.begins_with("	") and not line.begins_with(" "):
			break
		var hash_at := line.find("#")
		body.append(line.substr(0, hash_at) if hash_at >= 0 else line)
	return "
".join(body)
