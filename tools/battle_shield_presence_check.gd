extends Node

# V2 P1-03 的门禁：护盾只在事件发生时被看见，其余时间必须让位给角色。
#
# 背景（2026-08-29 固定 seed 实测截图）：人族羁绊给全队上盾，于是 `shield > 0` 是常态。
# 而此前的实现只有一个 bool —— 有盾就以 alpha 0.62 常亮并永久脉动，满场角色被泡泡洗白。
#
# 这里守的是**行为**，不是源码文本。StatusVFXController._anchor() 找不到锚点会自建，
# 所以可以在 headless 下把控制器挂到一个裸 Node3D 上，喂合成 fighter 字典直接驱动它。
# 上一轮 P1-02 我写过一条 contains() 断言，变异测试当场证明它抓不住字面量改动；
# 这一轮全部改成真驱动 + 读实际 alpha。
#
# 时间推进用手动调 _process(dt)，不靠真实帧：控制器的 process_mode 设为 DISABLED，
# 引擎不会再自己调一次。否则"施加爆发持续多久"这种断言会随帧率漂移。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const StatusVFX := preload("res://scenes/battle/StatusVFXController.gd")
const CHECK_NAME := "battle_shield_presence"

# 改前的常驻 alpha。这是本项要摆脱的那个值，任何时候都不允许回到它。
const PRE_CHANGE_ALPHA := 0.62

# 常驻不透明度上限。
#
# **不是 V2 原文的 0.22。** 第一版按 V2 写了 0.20，用户实看后否决：
# 「护盾太透明了，不要那么浅，用回之前的颜色淡 20% 就行了」——即 0.62 x 0.8 ≈ 0.50。
# 0.20 确实把画面还给了角色，但护盾本身淡到快读不出来，而它是个需要被看见的状态。
#
# 记一句以免将来误会：这里放宽上限**不是为了让检查变绿**。V2 的 0.22 是拍的数值，
# 用户实看后给了新的判据，上限跟着新判据走。护栏没有消失 —— 下面
# _check_steady_is_quiet() 仍然要求严格低于改前的 0.62，谁想整个退回去照样红。
const STEADY_ALPHA_MAX := 0.55
const APPLY_SEC_MIN := 0.25
const APPLY_SEC_MAX := 0.45

const STEP := 0.01

# 其余 14 个状态的配置 alpha。本项只动护盾，动到别人就是越界。
const OTHER_STATUS_ALPHA := {
	"stun": 1.0, "poison": 1.0, "burn": 1.0, "silence": 1.0, "slow": 1.0,
	"bleed": 1.0, "attack_down": 1.0, "interrupt": 1.0, "defense_down": 1.0,
	"defense_flat_down": 0.92, "heal_reduction": 1.0, "ice_vulnerable": 1.0,
	"ice_affected": 1.0, "fear": 1.0,
}

var _h: RefCounted
var _hosts: Array[Node3D] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	var restore_tier: int = VFXQualityBudget.tier
	VFXQualityBudget.tier = VFXQualityBudget.Tier.HIGH

	await _check_steady_is_quiet()
	_check_steady_center_is_open()
	_check_apply_burst()
	_check_absorb_flash()
	_check_break_plays_out()
	_check_no_replay_without_change()
	_check_low_quality_tiering()
	await _check_other_statuses_untouched()

	VFXQualityBudget.tier = restore_tier
	for host in _hosts:
		if is_instance_valid(host):
			host.queue_free()
	_h.finish(get_tree())


# --- 驱动辅助 ---------------------------------------------------------------

func _make_controller() -> Node:
	var host := Node3D.new()
	host.name = "ShieldTestHost"
	add_child(host)
	_hosts.append(host)
	var ctrl := Node3D.new()
	ctrl.set_script(StatusVFX)
	ctrl.name = "StatusVFX"
	# 引擎别自己调 _process —— 时间推进全部由本门禁手动控制。
	ctrl.process_mode = Node.PROCESS_MODE_DISABLED
	host.add_child(ctrl)
	return ctrl


func _shield(ctrl: Node, amount: int) -> void:
	ctrl.update_from_fighter({"shield": amount, "statuses": {}})


func _sprite(ctrl: Node) -> Sprite3D:
	return ctrl._sprites.get("shield") as Sprite3D


func _alpha(ctrl: Node) -> float:
	var s := _sprite(ctrl)
	return -1.0 if s == null else s.modulate.a


func _phase(ctrl: Node) -> int:
	return int(ctrl._shield_phase)


func _advance(ctrl: Node, seconds: float) -> void:
	var steps := int(round(seconds / STEP))
	for _i in range(steps):
		ctrl._process(STEP)


# 推进直到相位不再是 want_phase，返回耗时。超过 limit 秒仍未离开则返回 -1。
func _time_until_leaves(ctrl: Node, want_phase: int, limit := 2.0) -> float:
	var elapsed := 0.0
	while elapsed < limit:
		ctrl._process(STEP)
		elapsed += STEP
		if _phase(ctrl) != want_phase:
			return elapsed
	return -1.0


# --- 判据 -------------------------------------------------------------------

# 本项的核心：护盾常驻必须很淡，而且**完全不动**。
# 常驻脉动正是"每帧都在提醒你这里有个泡泡"的来源，去掉它才算真的让位。
func _check_steady_is_quiet() -> void:
	var ctrl := _make_controller()
	_shield(ctrl, 10)
	_advance(ctrl, 1.0)  # 走完施加爆发，落到常驻

	var steady := _alpha(ctrl)
	_h.expect(steady > 0.0 and steady <= STEADY_ALPHA_MAX,
		"steady_alpha_too_high",
		"护盾常驻 alpha 是 %.3f，超过上限 %.2f —— 泡泡又会长期盖住角色"
			% [steady, STEADY_ALPHA_MAX])
	# 独立的一条：无论上限怎么随实看结果调整，都不许退回改前那个值。
	# 这是本项存在的理由，比上面那个区间更硬。
	_h.expect(steady < PRE_CHANGE_ALPHA,
		"steady_alpha_reverted",
		"护盾常驻 alpha 回到了 %.3f，不低于改前的 %.2f —— P1-03 等于被整个退回去"
			% [steady, PRE_CHANGE_ALPHA])
	_h.expect(is_equal_approx(steady, StatusVFX.SHIELD_STEADY_ALPHA),
		"steady_alpha_mismatch",
		"常驻实际 alpha %.3f 与常量 SHIELD_STEADY_ALPHA %.3f 不符"
			% [steady, StatusVFX.SHIELD_STEADY_ALPHA])

	# 常驻期间逐帧比对：任何一帧偏离就说明脉动还在。
	for i in range(120):
		ctrl._process(STEP)
		var a := _alpha(ctrl)
		if not is_equal_approx(a, steady):
			_h.fail("steady_still_pulses",
				"常驻第 %d 帧 alpha 变成 %.5f（应恒为 %.5f）—— 护盾仍在脉动"
					% [i, a, steady])
			return

	# 上面那段紧循环**不足以**证明没有脉动：通用脉动的相位来自
	# Time.get_ticks_msec()，而手动连调 _process 时墙钟几乎不走，脉动会被冻成常数。
	# 变异测试证实了这一点 —— 给护盾加回 sin(t*2.7) 因子，紧循环那段一帧都没抓到。
	# 所以这里必须跨真实帧再采一遍，让墙钟真的前进。
	var t0 := Time.get_ticks_msec()
	for i in range(40):
		await get_tree().process_frame
		ctrl._process(STEP)
		var a := _alpha(ctrl)
		if not is_equal_approx(a, steady):
			_h.fail("steady_still_pulses",
				"常驻跨帧第 %d 次采样 alpha 变成 %.5f（应恒为 %.5f）—— 护盾仍在随时间脉动"
					% [i, a, steady])
			return
	var spanned := Time.get_ticks_msec() - t0
	# 墙钟没走就等于这段采样什么都没测到，不能算通过。
	if not _h.expect(spanned > 0,
		"pulse_probe_did_not_advance",
		"跨帧采样期间 Time.get_ticks_msec() 没有前进，无法证明护盾不随时间脉动"):
		return
	_h.item()
	_h.note("常驻 alpha 恒为 %.3f：120 次手动推进 + 40 帧真实时间（跨 %d ms）均无变化"
		% [steady, spanned])


# 常驻 alpha 由用户确认保持 0.50，因此不能再靠继续调淡解决遮挡。真正的门禁是
# 贴图中央必须至少 80% 透明，让面部/武器主体从空心环里露出来。
func _check_steady_center_is_open() -> void:
	var ctrl := _make_controller()
	_shield(ctrl, 10)
	_advance(ctrl, 1.0)
	var sprite := _sprite(ctrl)
	if not _h.expect(sprite != null, "steady_sprite_missing", "常驻护盾精灵不存在"):
		return
	_h.expect(sprite.texture == StatusVFX.SHIELD_STEADY_TEXTURE,
		"steady_uses_full_bubble",
		"常驻阶段仍在使用完整泡泡贴图，0.50 alpha 会继续覆盖角色主体")
	var image := sprite.texture.get_image()
	if not _h.expect(image != null and not image.is_empty(),
		"steady_texture_unreadable", "无法读取常驻护盾贴图像素"):
		return
	if image.is_compressed():
		var decompress_error := image.decompress()
		if not _h.expect(decompress_error == OK,
			"steady_texture_decompress_failed",
			"常驻护盾贴图解压失败，错误码 %d，无法执行像素遮挡门禁" % decompress_error):
			return
	var x0 := int(floor(image.get_width() * 0.30))
	var x1 := int(ceil(image.get_width() * 0.70))
	var y0 := int(floor(image.get_height() * 0.30))
	var y1 := int(ceil(image.get_height() * 0.70))
	var samples := 0
	var covered := 0
	for y in range(y0, y1, 2):
		for x in range(x0, x1, 2):
			samples += 1
			if image.get_pixel(x, y).a >= 0.10:
				covered += 1
	var covered_ratio := float(covered) / maxf(1.0, float(samples))
	_h.expect(covered_ratio <= 0.20,
		"steady_center_occludes_actor",
		"常驻护盾中央 40%% 有 %.2f%% 像素 alpha>=0.10，要求不超过 20%%" % (covered_ratio * 100.0))
	_h.note("常驻护盾中央覆盖 %.2f%%（上限 20%%），alpha 仍为 %.2f"
		% [covered_ratio * 100.0, StatusVFX.SHIELD_STEADY_ALPHA])


# 0 -> N：必须有一次明显的施加爆发，且**自己落回常驻**。落不回去就等于没改。
func _check_apply_burst() -> void:
	var ctrl := _make_controller()
	_shield(ctrl, 8)
	_h.expect(_phase(ctrl) == StatusVFX.ShieldPhase.APPLY,
		"apply_not_triggered",
		"护盾从 0 变 8，相位却是 %d，不是 APPLY" % _phase(ctrl))

	ctrl._process(STEP)
	var burst := _alpha(ctrl)
	_h.expect(_sprite(ctrl).texture == StatusVFX.SHIELD_EVENT_TEXTURE,
		"apply_lost_full_bubble", "施加阶段没有使用完整护盾泡泡")
	_h.expect(burst > StatusVFX.SHIELD_STEADY_ALPHA,
		"apply_not_brighter",
		"施加瞬间 alpha %.3f 不比常驻 %.3f 亮 —— 上盾这件事看不见"
			% [burst, StatusVFX.SHIELD_STEADY_ALPHA])

	# 时长：上面已消耗一帧，补回来。
	var rest := _time_until_leaves(ctrl, StatusVFX.ShieldPhase.APPLY)
	if not _h.expect(rest > 0.0, "apply_never_settles",
		"施加爆发 2 秒内没有落回常驻 —— 泡泡会一直亮着"):
		return
	var duration := rest + STEP
	_h.expect(duration >= APPLY_SEC_MIN and duration <= APPLY_SEC_MAX,
		"apply_duration_out_of_window",
		"施加爆发持续 %.3f 秒，不在 %.2f-%.2f 秒窗口内（太短看不清，太长又变成常亮）"
			% [duration, APPLY_SEC_MIN, APPLY_SEC_MAX])
	_h.expect(_phase(ctrl) == StatusVFX.ShieldPhase.STEADY,
		"apply_wrong_next_phase",
		"施加爆发之后相位是 %d，不是 STEADY" % _phase(ctrl))
	_h.note("施加爆发 %.3f 秒，起手 alpha %.3f" % [duration, burst])


# N -> N-k：吸收伤害要闪一下，然后回常驻。护盾没破，所以精灵必须还在。
func _check_absorb_flash() -> void:
	var ctrl := _make_controller()
	_shield(ctrl, 20)
	_advance(ctrl, 1.0)
	var steady := _alpha(ctrl)

	_shield(ctrl, 12)
	_h.expect(_phase(ctrl) == StatusVFX.ShieldPhase.ABSORB,
		"absorb_not_triggered",
		"护盾从 20 掉到 12，相位却是 %d，不是 ABSORB" % _phase(ctrl))

	ctrl._process(STEP)
	var flash := _alpha(ctrl)
	_h.expect(_sprite(ctrl).texture == StatusVFX.SHIELD_EVENT_TEXTURE,
		"absorb_lost_full_bubble", "吸收阶段没有使用完整护盾泡泡")
	_h.expect(flash > steady,
		"absorb_not_brighter",
		"吸收瞬间 alpha %.3f 不比常驻 %.3f 亮 —— 挡下伤害这件事看不见" % [flash, steady])

	var rest := _time_until_leaves(ctrl, StatusVFX.ShieldPhase.ABSORB)
	_h.expect(rest > 0.0, "absorb_never_settles", "吸收闪没有落回常驻")
	_h.expect(is_equal_approx(_alpha(ctrl), steady),
		"absorb_wrong_resting_alpha",
		"吸收闪之后 alpha 停在 %.3f，不是常驻 %.3f" % [_alpha(ctrl), steady])
	var s := _sprite(ctrl)
	_h.expect(s != null and s.visible,
		"absorb_hid_shield", "护盾只是变少不是破了，精灵不该被隐藏")


# N -> 0：破盾是**必须被看见**的关键事件。最容易写错的一条是"shield 归零的同一帧
# 就把精灵隐藏"—— 那样破盾动画一帧都放不出来，等于没做。
func _check_break_plays_out() -> void:
	var ctrl := _make_controller()
	_shield(ctrl, 15)
	_advance(ctrl, 1.0)
	var steady := _alpha(ctrl)

	_shield(ctrl, 0)
	_h.expect(_phase(ctrl) == StatusVFX.ShieldPhase.BREAK,
		"break_not_triggered",
		"护盾从 15 归 0，相位却是 %d，不是 BREAK" % _phase(ctrl))

	var s := _sprite(ctrl)
	if not _h.expect(s != null, "break_sprite_missing", "破盾时护盾精灵不存在"):
		return
	_h.expect(s.visible,
		"break_hidden_immediately",
		"shield 归零的同一帧精灵就被隐藏了 —— 破盾演出一帧都放不出来")

	ctrl._process(STEP)
	var peak := _alpha(ctrl)
	_h.expect(s.texture == StatusVFX.SHIELD_EVENT_TEXTURE,
		"break_lost_full_bubble", "破盾阶段没有使用完整护盾泡泡")
	_h.expect(peak > steady,
		"break_not_brighter",
		"破盾瞬间 alpha %.3f 不比常驻 %.3f 亮" % [peak, steady])

	# 演出期间必须一直可见，走完才允许隐藏。
	var visible_frames := 1
	var settled := -1.0
	var elapsed := STEP
	while elapsed < 2.0:
		ctrl._process(STEP)
		elapsed += STEP
		if not s.visible:
			settled = elapsed
			break
		visible_frames += 1
	_h.expect(settled > 0.0,
		"break_never_hides",
		"破盾演出 2 秒后精灵仍可见 —— 盾已经没了却还挂着一层泡泡")
	_h.expect(visible_frames >= 10,
		"break_too_short_to_see",
		"破盾演出只持续了 %d 帧（%.3f 秒）—— 太短，玩家看不到" % [visible_frames, settled])

	# 破盾只演一次，不是每帧重放。
	#
	# 断言必须**紧跟在那次无变化刷新之后**，中间不能推进时间。第一版写成先
	# _advance(0.5) 再断言，变异测试当场证明它没用：把触发条件放宽成"只要 shield<=0
	# 就重播"，重放会在 0.28 秒内自己演完并归位成 NONE + 隐藏，两条断言照样通过。
	# 每帧重播这件事只在**刚刷新的那一帧**看得见。
	_shield(ctrl, 0)
	_h.expect(_phase(ctrl) == StatusVFX.ShieldPhase.NONE,
		"break_replays",
		"护盾已经是 0 且没有变化，刷新一次却把相位变成 %d —— 破盾在重复播放"
			% _phase(ctrl))
	_h.expect(not s.visible, "break_resurfaces", "盾早就没了，刷新一次精灵又出现了")

	# 再连刷 30 帧，确认它不会在后面某一帧突然复活。
	for i in range(30):
		_shield(ctrl, 0)
		ctrl._process(STEP)
		if _phase(ctrl) != StatusVFX.ShieldPhase.NONE or s.visible:
			_h.fail("break_replays_later",
				"第 %d 帧护盾又活了（相位 %d，可见 %s）" % [i, _phase(ctrl), s.visible])
			return
	_h.item()
	_h.note("破盾演出 %.3f 秒后隐藏，其后 30 帧未复活" % settled)


# 数值没变就不该有任何事件。护盾每帧都被 update_from_fighter 刷新，
# 若判定写成"有盾就播"，画面会变成每帧一次爆发。
func _check_no_replay_without_change() -> void:
	var ctrl := _make_controller()
	_shield(ctrl, 30)
	_advance(ctrl, 1.0)
	var steady := _alpha(ctrl)

	for i in range(60):
		_shield(ctrl, 30)
		ctrl._process(STEP)
		if _phase(ctrl) != StatusVFX.ShieldPhase.STEADY:
			_h.fail("steady_retriggers",
				"护盾数值不变，第 %d 次刷新却把相位变成了 %d" % [i, _phase(ctrl)])
			return
		if not is_equal_approx(_alpha(ctrl), steady):
			_h.fail("steady_alpha_drifts",
				"护盾数值不变，第 %d 次刷新后 alpha 变成 %.5f" % [i, _alpha(ctrl)])
			return
	_h.item()


# 低画质档：吸收闪是 ambient，可以丢；破盾是 critical，丢不得。
func _check_low_quality_tiering() -> void:
	VFXQualityBudget.tier = VFXQualityBudget.Tier.LOW
	var ctrl := _make_controller()

	_shield(ctrl, 20)
	_h.expect(_phase(ctrl) == StatusVFX.ShieldPhase.APPLY,
		"low_quality_drops_apply",
		"低画质档把施加爆发也丢了 —— 上盾必须仍然可见")
	_advance(ctrl, 1.0)

	_shield(ctrl, 12)
	_h.expect(_phase(ctrl) == StatusVFX.ShieldPhase.STEADY,
		"low_quality_keeps_absorb",
		"低画质档仍在播吸收闪（相位 %d）—— 这一档该降级掉它" % _phase(ctrl))

	_shield(ctrl, 0)
	_h.expect(_phase(ctrl) == StatusVFX.ShieldPhase.BREAK,
		"low_quality_drops_break",
		"低画质档把破盾丢了 —— critical 事件不可降级")

	VFXQualityBudget.tier = VFXQualityBudget.Tier.HIGH


# 回归护栏：本项只动护盾。其余 14 个状态的配置与通用脉动都必须原样。
func _check_other_statuses_untouched() -> void:
	for kind in OTHER_STATUS_ALPHA.keys():
		var cfg: Dictionary = StatusVFX.EFFECTS.get(kind, {})
		if not _h.expect(not cfg.is_empty(), "status_config_removed",
			"状态 %s 的配置不见了" % kind):
			continue
		_h.expect(is_equal_approx(float(cfg.alpha), float(OTHER_STATUS_ALPHA[kind])),
			"status_alpha_changed",
			"状态 %s 的 alpha 变成 %.3f（应为 %.3f）—— P1-03 只该动护盾"
				% [kind, float(cfg.alpha), float(OTHER_STATUS_ALPHA[kind])])
		_h.expect(float(cfg.pulse) > 0.0,
			"status_pulse_removed",
			"状态 %s 的 pulse 被清零了 —— 去掉脉动只针对护盾" % kind)

	# 对照组：通用脉动分支必须还活着。若被顺手删掉，所有图标的 alpha 会恒等于
	# 配置值。这里采样 4 个状态、跨真实帧多次（脉动相位来自 Time.get_ticks_msec()，
	# 手动推进不会让它前进），只要有一次不等于配置值就说明脉动仍在。
	var ctrl := _make_controller()
	var probe := ["stun", "poison", "burn", "fear"]
	var statuses := {}
	for kind in probe:
		statuses[kind] = {"remaining": 5.0}
	ctrl.update_from_fighter({"shield": 0, "statuses": statuses})
	var saw_pulse := false
	for _i in range(8):
		ctrl._process(STEP)
		for kind in probe:
			var s := ctrl._sprites.get(kind) as Sprite3D
			if s == null:
				continue
			var cfg: Dictionary = StatusVFX.EFFECTS[kind]
			if not is_equal_approx(s.modulate.a, float(cfg.alpha)):
				saw_pulse = true
		await get_tree().process_frame
	_h.expect(saw_pulse,
		"generic_pulse_removed",
		"其余状态的 alpha 始终等于配置值 —— 通用脉动被一起删掉了，改动越界")
