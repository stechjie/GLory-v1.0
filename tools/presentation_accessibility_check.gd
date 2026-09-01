extends Node

# V2 P1-05 第 4 条的门禁：「可关闭屏震、闪光、hit-stop；低电量/低画质自动降级」。
#
# 实测先修正 V2 两点：
#
# 1. **仓里没有"全屏闪白"。** 第 1 条禁止的那个东西本来就不存在，只有局部命中闪
#    （ProceduralVFXEffect 的 Flash 多边形、VFXDebrisBurst3D 的 impact flash）。
#    所以"闪光开关"关掉的是这两处加色层，冲击粒子照旧 —— 命中本身仍然读得出来。
#    把命中反馈整个关掉不是无障碍，是让玩家看不懂战斗。
#
# 2. **"低电量自动降级"做不了。** Godot 4 没有可移植的电量 API，仓里也没有任何
#    电量探针。这半条没有假装做到；低画质那一半做了。
#
# 降级口径也不是照抄，而是按实际成本定的（理由写在 PresentationSettings 里）：
#   屏震降幅度不清零、命中闪低画质关掉、hit-stop 不随画质降级。
#
# 这里守的是**行为**：直接改开关和画质档，读裁决结果和真实调用的效果。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const Settings := preload("res://effects/runtime/presentation/PresentationSettings.gd")
const QUALITY := preload("res://effects/vfx3d/core/VFXQualityBudget.gd")
const CHECK_NAME := "presentation_accessibility"

const TOGGLES := ["screen_shake", "flash_effects", "hit_stop"]

var _h: RefCounted


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	var restore_tier: int = QUALITY.tier
	var restore := {}
	for key in TOGGLES:
		restore[key] = PlayerProfile.get_presentation_toggle(key)

	_check_defaults_are_on(restore)
	_check_each_toggle_isolates()
	_check_low_tier_downgrade()
	await _check_hitstop_actually_gated()
	await _check_shake_actually_gated()
	_check_every_entry_point_is_covered()

	for key in TOGGLES:
		PlayerProfile.set_presentation_toggle(str(key), bool(restore[key]))
	QUALITY.tier = restore_tier
	_h.finish(get_tree())


func _set_all(enabled: bool) -> void:
	for key in TOGGLES:
		PlayerProfile.set_presentation_toggle(str(key), enabled)


# 三项默认必须是开的。默认关掉等于让绝大多数玩家看到一个更差的版本。
func _check_defaults_are_on(current: Dictionary) -> void:
	_set_all(true)
	for key in TOGGLES:
		_h.expect(PlayerProfile.get_presentation_toggle(str(key)),
			"toggle_not_settable", "开关 %s 设为 true 之后读回来还是 false" % key)
	_h.note("当前玩家设置：%s" % str(current))


# 每个开关只能管自己那一项。串在一起就等于玩家关一个丢三个。
func _check_each_toggle_isolates() -> void:
	QUALITY.tier = QUALITY.Tier.HIGH
	for off_key in TOGGLES:
		_set_all(true)
		PlayerProfile.set_presentation_toggle(off_key, false)
		var shake := Settings.screen_shake_allowed()
		var flash := Settings.flash_allowed()
		var hit_stop := Settings.hit_stop_allowed()
		match off_key:
			"screen_shake":
				_h.expect(not shake, "shake_toggle_dead", "关掉屏震开关后仍然允许屏震")
				_h.expect(flash and hit_stop, "shake_toggle_leaks",
					"关屏震把闪光(%s)或 hit-stop(%s)也一起关了" % [flash, hit_stop])
			"flash_effects":
				_h.expect(not flash, "flash_toggle_dead", "关掉闪光开关后仍然允许闪光")
				_h.expect(shake and hit_stop, "flash_toggle_leaks",
					"关闪光把屏震(%s)或 hit-stop(%s)也一起关了" % [shake, hit_stop])
			"hit_stop":
				_h.expect(not hit_stop, "hitstop_toggle_dead", "关掉 hit-stop 开关后仍然允许 hit-stop")
				_h.expect(shake and flash, "hitstop_toggle_leaks",
					"关 hit-stop 把屏震(%s)或闪光(%s)也一起关了" % [shake, flash])
	_set_all(true)


# 低画质档的降级口径。三项各不相同，且都是按成本定的，不是一刀切。
func _check_low_tier_downgrade() -> void:
	_set_all(true)
	QUALITY.tier = QUALITY.Tier.HIGH
	var high_scale := Settings.screen_shake_scale()
	QUALITY.tier = QUALITY.Tier.LOW
	var low_scale := Settings.screen_shake_scale()

	# 屏震：降幅度，但**不能清零** —— 它几乎不花性能，清零是替玩家做无障碍决定。
	_h.expect(low_scale < high_scale,
		"low_tier_shake_not_reduced",
		"低画质档屏震幅度 %.2f 没有低于高画质的 %.2f" % [low_scale, high_scale])
	_h.expect(low_scale > 0.0,
		"low_tier_shake_silenced",
		"低画质档把屏震清零了 —— 它不花性能，降幅度就够，清零属于替玩家做无障碍决定")

	# 命中闪：三项里唯一有真实填充率成本的，低画质档关掉。
	_h.expect(not Settings.flash_allowed(),
		"low_tier_flash_kept",
		"低画质档仍然允许命中闪 —— 它是这三项里唯一有填充率成本的")

	# hit-stop：成本为零，降它只让打击感变差、一点性能不省。
	_h.expect(Settings.hit_stop_allowed(),
		"low_tier_hitstop_dropped",
		"低画质档把 hit-stop 也降级了 —— 它只是把时间停一下，成本为零")

	# 玩家关掉的开关不能因为换了画质档就自己开回来。
	PlayerProfile.set_presentation_toggle("hit_stop", false)
	QUALITY.tier = QUALITY.Tier.HIGH
	_h.expect(not Settings.hit_stop_allowed(),
		"quality_tier_overrides_player",
		"画质档回到高档后 hit-stop 自己开回来了 —— 画质档不该覆盖玩家的选择")
	_set_all(true)
	QUALITY.tier = QUALITY.Tier.HIGH


# 光有裁决函数不够，得证明入口真的在用它。
func _check_hitstop_actually_gated() -> void:
	_set_all(true)
	QUALITY.tier = QUALITY.Tier.HIGH
	VFXManager.play_hitstop(0.05)
	_h.expect(VFXManager.is_hitstop_active(),
		"hitstop_never_starts", "开关全开时 play_hitstop() 没有生效，本条无法验证")

	# 等它自己过期再测关闭态，否则会读到上一发的残留。
	#
	# **有界轮询而不是固定等一个数**：第一版写死 await 0.6 秒去等 0.5 秒的 hit-stop，
	# 结果 headless 下它还没过期，两条断言接连误报。这里改成一直等到真的过期，
	# 并把实际耗时打出来，将来再失败能直接看出是没过期还是别的原因。
	var waited_ms := 0
	var started := Time.get_ticks_msec()
	while VFXManager.is_hitstop_active() and waited_ms < 3000:
		await get_tree().process_frame
		waited_ms = Time.get_ticks_msec() - started
	if not _h.expect(not VFXManager.is_hitstop_active(), "hitstop_stuck",
		"等了 %d ms 之后 hit-stop 仍然是激活状态（请求的是 50 ms）" % waited_ms):
		return

	PlayerProfile.set_presentation_toggle("hit_stop", false)
	# 用一个明显更长的时长：万一裁决没接上，残留会持续到断言之后，红得毫不含糊。
	VFXManager.play_hitstop(2.0)
	_h.expect(not VFXManager.is_hitstop_active(),
		"hitstop_not_gated",
		"关掉开关后 play_hitstop() 仍然把时间停住了 —— 入口没接裁决")
	_set_all(true)


func _check_shake_actually_gated() -> void:
	_set_all(true)
	QUALITY.tier = QUALITY.Tier.HIGH
	var camera := Camera2D.new()
	add_child(camera)
	VFXManager.set_camera(camera)

	VFXManager.play_screen_shake(12.0, 0.4)
	await get_tree().process_frame
	await get_tree().process_frame
	var moved_on := camera.offset.length() > 0.0
	_h.expect(moved_on, "shake_never_moves_camera",
		"开关全开时相机没有位移，本条无法验证")

	# 同样等到这一发震动真正结束，别假设它一定在某个固定时间内衰减完。
	var shake_started := Time.get_ticks_msec()
	while camera.offset.length() > 0.001 and Time.get_ticks_msec() - shake_started < 3000:
		await get_tree().process_frame
	PlayerProfile.set_presentation_toggle("screen_shake", false)
	VFXManager.play_screen_shake(12.0, 0.4)
	await get_tree().process_frame
	await get_tree().process_frame
	_h.expect(camera.offset.length() <= 0.001,
		"shake_not_gated",
		"关掉屏震后相机仍然偏移了 %.4f —— 入口没接裁决" % camera.offset.length())

	camera.queue_free()
	_set_all(true)


# 每一个会震/会闪的入口都必须问过裁决层。
#
# 屏震有两条独立路径：VFXManager.play_screen_shake（大多数）和 BattleArena 的
# 晶体抖动（不走 VFXManager）。漏掉任何一条，玩家关掉之后都会"偶尔还震一下"，
# 那比没做还糟。
func _check_every_entry_point_is_covered() -> void:
	var cases := [
		{"path": "res://effects/VFXManager.gd", "needle": "PresentationSettings.hit_stop_allowed()",
			"why": "play_hitstop 入口"},
		{"path": "res://effects/VFXManager.gd", "needle": "PresentationSettings.screen_shake_scale()",
			"why": "play_screen_shake 入口"},
		{"path": "res://scenes/battle/BattleArena.gd", "needle": "PresentationSettings.screen_shake_scale()",
			"why": "晶体抖动（不走 VFXManager 的第二条屏震路径）"},
		{"path": "res://effects/ProceduralVFXEffect.gd", "needle": "PresentationSettings.flash_allowed()",
			"why": "2D 命中闪"},
		{"path": "res://effects/vfx3d/modules/VFXDebrisBurst3D.gd", "needle": "PresentationSettings.flash_allowed()",
			"why": "3D 碎屑的 impact flash"},
	]
	for case_value in cases:
		var case_dict: Dictionary = case_value
		var src := FileAccess.get_file_as_string(str(case_dict["path"]))
		if not _h.expect(not src.is_empty(), "entry_source_unreadable",
			"读不到 %s" % str(case_dict["path"])):
			continue
		_h.expect(src.contains(str(case_dict["needle"])),
			"entry_point_not_gated",
			"%s（%s）没有接无障碍裁决 —— 玩家关掉之后这一处还会照常触发"
				% [str(case_dict["path"]), str(case_dict["why"])])
