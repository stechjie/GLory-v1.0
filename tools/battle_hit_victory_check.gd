extends Node

# V2 P1-05 第 1、3 条的门禁。
#
# 第 1 条「普攻：轻微前冲/后坐、命中闪、单次小屏震；暴击只放大 20%-35%，不堆全屏闪白」
#   * 命中闪本来就有（ProceduralVFXEffect 的 Flash + 冲击粒子）。
#   * 前冲/后坐**原本没有**，普攻的命中屏震也没有 —— 改前只有技能会触发
#     skill_shake，普攻一次都不震。这两样是新加的。
#   * "暴击只放大 20%-35%"在这里落成一个可执行判据：暴击不另加任何一层效果，
#     只把同一次演出乘上 CRIT_EMPHASIS_SCALE，且该系数必须落在 1.20-1.35。
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
const CHECK_NAME := "battle_hit_victory"

# V2 原文的暴击放大区间。
const CRIT_SCALE_MIN := 1.20
const CRIT_SCALE_MAX := 1.35
# V2 原文：结算至少保持 0.8 秒再进奖励。
const RESULT_HOLD_MIN_SEC := 0.8

var _h: RefCounted


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_check_crit_is_only_an_amplifier()
	_check_lunge_is_small_and_returns()
	_check_impact_shake_is_small()
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


# 暴击只能是"同一套演出乘一个系数"，而且系数必须在 V2 给的 20%-35% 内。
func _check_crit_is_only_an_amplifier() -> void:
	var scale: float = BattleVfxScript.CRIT_EMPHASIS_SCALE
	_h.expect(scale >= CRIT_SCALE_MIN and scale <= CRIT_SCALE_MAX,
		"crit_scale_out_of_range",
		"暴击放大系数 %.3f 不在 V2 的 %.2f-%.2f —— 再大就变成「另加一层效果」了"
			% [scale, CRIT_SCALE_MIN, CRIT_SCALE_MAX])

	# 暴击的屏震必须正好是普通命中乘这个系数，不能另走一条更响的路径。
	var base: float = BattleVfxScript.IMPACT_SHAKE_STRENGTH
	_h.expect(base > 0.0, "impact_shake_absent",
		"普攻命中的屏震强度是 %.3f —— V2 第 1 条要求「单次小屏震」" % base)
	_h.expect(is_equal_approx(base * scale, base * BattleVfxScript.CRIT_EMPHASIS_SCALE),
		"crit_uses_other_path", "暴击没有走「同一次演出乘系数」这条路")

	# 反向：仓里不该出现全屏闪白。V2 第 1 条明确禁止。
	var vfx_src := FileAccess.get_file_as_string("res://scenes/battle/BattleVfx.gd")
	for banned in ["fullscreen_flash", "screen_flash", "white_flash"]:
		_h.expect(not vfx_src.contains(banned),
			"fullscreen_flash_added",
			"出现了 %s —— V2 第 1 条明确写「不堆全屏闪白」" % banned)


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


func _check_impact_shake_is_small() -> void:
	var impact: float = BattleVfxScript.IMPACT_SHAKE_STRENGTH
	# 技能震动默认 6.5（见 BattleVfx._play_visual_events 的 skill_shake 分支）。
	# 普攻的数量远多于技能，必须明显更小，否则整场都在抖。
	_h.expect(impact < 6.5 * 0.5,
		"impact_shake_too_strong",
		"普攻命中屏震 %.2f 不明显小于技能的 6.5 —— 普攻数量远多于技能，会抖一整场" % impact)
	_h.expect(BattleVfxScript.IMPACT_SHAKE_SEC <= 0.15,
		"impact_shake_too_long",
		"普攻命中屏震持续 %.3f 秒，太长了" % BattleVfxScript.IMPACT_SHAKE_SEC)


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
		"impact_feedback_not_wired", "命中那一拍没有调 cue_play_impact_feedback —— 普攻仍然不震")
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
