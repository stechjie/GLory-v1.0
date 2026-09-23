extends Node3D

const VFX_STATUS_EFFECT:=preload("res://effects/vfx3d/modules/VFXStatusEffect3D.gd")
const SHIELD_EVENT_TEXTURE := preload("res://assets/vfx/oga/skills/angel_shield_event_frame.tres")
const SHIELD_STEADY_TEXTURE := preload("res://assets/vfx/oga/skills/angel_shield_steady_frame.tres")
# Status icons are persistent gameplay state, not one-shot hit bursts.  Keep
# them on the existing readable logo textures so players can identify them at
# the current distant camera angle.
const PROCEDURAL_STATUS_ANCHORS:={}

const EFFECTS := {
	"shield": {"anchor": "BodyAnchor", "path": "res://assets/vfx/oga/skills/angel_shield.png", "scale": Vector3(0.86, 0.86, 0.86), "alpha": 0.62, "rot": 0.0, "bob": 0.035, "pulse": 0.035},
	"stun": {"anchor": "HeadAnchor", "path": "res://assets/vfx/status/status_stun_icon_v2.png", "scale": Vector3(0.50, 0.50, 0.50), "alpha": 1.0, "rot": 0.0, "bob": 0.018, "pulse": 0.045},
	"poison": {"anchor": "HeadAnchor", "path": "res://assets/vfx/status/status_poison_icon_v2.png", "scale": Vector3(0.66, 0.66, 0.66), "alpha": 1.0, "rot": 0.0, "bob": 0.035, "pulse": 0.075},
	"burn": {"anchor": "HeadAnchor", "path": "res://assets/vfx/status/status_burn_icon_v2.png", "scale": Vector3(0.58, 0.58, 0.58), "alpha": 1.0, "rot": 0.0, "bob": 0.025, "pulse": 0.07},
	"silence": {"anchor": "HeadAnchor", "path": "res://assets/vfx/status/status_silence_icon_v2.png", "scale": Vector3(0.68, 0.68, 0.68), "alpha": 1.0, "rot": 0.0, "bob": 0.03, "pulse": 0.06},
	"slow": {"anchor": "HeadAnchor", "path": "res://assets/vfx/status/status_slow_icon_v2.png", "scale": Vector3(0.58, 0.58, 0.58), "alpha": 1.0, "rot": 0.0, "bob": 0.025, "pulse": 0.06},
	"bleed": {"anchor": "HeadAnchor", "path": "res://assets/vfx/status/status_bleed_icon_v2.png", "scale": Vector3(0.58, 0.58, 0.58), "alpha": 1.0, "rot": 0.0, "bob": 0.025, "pulse": 0.07},
	"attack_down": {"anchor": "HeadAnchor", "path": "res://assets/vfx/status/status_attack_down_icon_v2.png", "scale": Vector3(0.56, 0.56, 0.56), "alpha": 1.0, "rot": 0.0, "bob": 0.025, "pulse": 0.06},
	"interrupt": {"anchor": "HeadAnchor", "path": "res://assets/vfx/status/status_interrupt_icon_v2.png", "scale": Vector3(0.56, 0.56, 0.56), "alpha": 1.0, "rot": 0.0, "bob": 0.025, "pulse": 0.06},
	"defense_down": {"anchor": "HeadAnchor", "path": "res://assets/vfx/status/status_defense_down_icon_v2.png", "scale": Vector3(0.60, 0.60, 0.60), "alpha": 1.0, "rot": 0.0, "bob": 0.025, "pulse": 0.06},
	"defense_flat_down": {"anchor": "HeadAnchor", "path": "res://assets/vfx/status/status_defense_down_icon_v2.png", "scale": Vector3(0.52, 0.52, 0.52), "alpha": 0.92, "rot": 0.0, "bob": 0.025, "pulse": 0.055},
	"heal_reduction": {"anchor": "HeadAnchor", "path": "res://assets/vfx/status/status_heal_reduction_icon_v2.png", "scale": Vector3(0.58, 0.58, 0.58), "alpha": 1.0, "rot": 0.0, "bob": 0.025, "pulse": 0.06},
	"ice_vulnerable": {"anchor": "HeadAnchor", "path": "res://assets/vfx/status/status_ice_vulnerable_icon_v2.png", "scale": Vector3(0.56, 0.56, 0.56), "alpha": 1.0, "rot": 0.0, "bob": 0.025, "pulse": 0.06},
	"ice_affected": {"anchor": "HeadAnchor", "path": "res://assets/vfx/status/status_ice_affected_icon_v2.png", "scale": Vector3(0.56, 0.56, 0.56), "alpha": 1.0, "rot": 0.0, "bob": 0.025, "pulse": 0.06},
	"fear": {"anchor": "HeadAnchor", "path": "res://assets/vfx/status/status_fear_icon_v2.png", "scale": Vector3(0.62, 0.62, 0.62), "alpha": 1.0, "rot": 0.0, "bob": 0.025, "pulse": 0.08},
}

# 状态图标是固定小集合，preload 到常量里——中毒/燃烧首次触发时
# 绝不能在战斗帧里同步读盘。
const STATUS_TEXTURES := {
	"shield": SHIELD_EVENT_TEXTURE,
	"stun": preload("res://assets/vfx/status/status_stun_icon_v2.png"),
	"poison": preload("res://assets/vfx/status/status_poison_icon_v2.png"),
	"burn": preload("res://assets/vfx/status/status_burn_icon_v2.png"),
	"silence": preload("res://assets/vfx/status/status_silence_icon_v2.png"),
	"slow": preload("res://assets/vfx/status/status_slow_icon_v2.png"),
	"bleed": preload("res://assets/vfx/status/status_bleed_icon_v2.png"),
	"attack_down": preload("res://assets/vfx/status/status_attack_down_icon_v2.png"),
	"interrupt": preload("res://assets/vfx/status/status_interrupt_icon_v2.png"),
	"defense_down": preload("res://assets/vfx/status/status_defense_down_icon_v2.png"),
	"defense_flat_down": preload("res://assets/vfx/status/status_defense_down_icon_v2.png"),
	"heal_reduction": preload("res://assets/vfx/status/status_heal_reduction_icon_v2.png"),
	"ice_vulnerable": preload("res://assets/vfx/status/status_ice_vulnerable_icon_v2.png"),
	"ice_affected": preload("res://assets/vfx/status/status_ice_affected_icon_v2.png"),
	"fear": preload("res://assets/vfx/status/status_fear_icon_v2.png"),
}

# --- V2 P1-03：护盾从「常亮大泡泡」改为「短促施加 + 低占用常驻」------------------
#
# 问题：人族羁绊会给全队上盾，所以 `shield > 0` 是常态而非偶发。而此前的实现只有
# 一个 bool —— 有盾就以 alpha 0.62 常亮并永久脉动，于是满场角色都被一层泡泡洗白。
# 实测截图（PVE round 1 中段 / final round 21 开局）里，泡泡是画面最大的视觉噪声。
#
# 改法：把"有没有盾"拆成四个相位，只有**事件发生的那一刻**才亮起来，其余时间压下去。
# 玩家需要知道"这个单位有盾"，但不需要每一帧都被提醒。
#
# 注意"压下去"的幅度是用户实看定的，不是 V2 定的：常驻最终是 0.50（改前 0.62 淡 20%），
# 而不是 V2 写的 ≤0.22。真正把画面还给角色的是**去掉常驻脉动**和**事件才亮**这两件事，
# 不是把 alpha 压到看不见。
#
# 为什么用 _process 里的显式计时状态机而不是 Tween：_process 每帧都会重写
# sprite.modulate.a，Tween 会和它逐帧打架。这是既有结构决定的约束，不是偏好。
enum ShieldPhase { NONE, APPLY, STEADY, ABSORB, BREAK }

# 常驻 alpha = 改前的 0.62 淡 20%。
#
# **不是 V2 原文的 ≤0.22。** 第一版按 V2 写了 0.20，用户实看后否决：「护盾太透明了，
# 不要那么浅，用回之前的颜色淡 20% 就行了」。0.20 能让角色完全露出来，但护盾本身
# 淡到快看不见了 —— 它毕竟是个需要被读出来的状态，不是纯背景。
# 与 P1-02 晶柱同一个模式：V2 的数值区间是拍的，真机实看才是判据。
const SHIELD_STEADY_ALPHA := 0.50

# 三个事件相位必须**明显亮于常驻**，否则"只在事件时被看见"就不成立。
# 常驻从 0.20 提到 0.50 之后这几个值必须跟着抬 —— 尤其是吸收闪：原本 0.45，
# 现在比常驻还暗，挡下伤害反而会让泡泡变淡，读成反的。
const SHIELD_APPLY_ALPHA := 0.92
const SHIELD_APPLY_SEC := 0.35
const SHIELD_ABSORB_ALPHA := 0.78
const SHIELD_ABSORB_SEC := 0.14
const SHIELD_BREAK_ALPHA := 1.0
const SHIELD_BREAK_SEC := 0.28
# 破盾时泡泡放大着消散，读作"被撑破"而不是"渐隐消失"。
const SHIELD_BREAK_SCALE := 1.35
var _sprites := {}
var _procedural_statuses:={}
var _phase := randf() * TAU
# 上一次看到的护盾值。相位判定全靠它与本次的差：
#   0 -> N      APPLY
#   N -> N-k    ABSORB
#   N -> 0      BREAK
#   N -> N      保持 STEADY
var _shield_amount := 0
var _shield_phase: ShieldPhase = ShieldPhase.NONE
var _shield_phase_elapsed := 0.0
# 破盾演完后要隐藏精灵，但不能在 _process 遍历 _active_kinds 的过程中改那个数组。
var _shield_hide_pending := false
# Kinds currently visible. Iterating this array allocates nothing, unlike
# _sprites.keys() which built a fresh Array every frame, for every unit.
var _active_kinds: Array[String] = []
# 同一时刻挂在头顶的图标以前全叠在 HeadAnchor 的同一点，第二个以后完全看不见。
# 这里给每个头顶图标算一个水平槽位，以头顶为中心左右摊开。
# kind -> 目标 x 偏移（世界单位），在 _process 里应用。
var _slot_x := {}
# 相邻图标的水平间距。图标本身约 0.5–0.7 宽，这个间距刚好不重叠又不散开。
const STATUS_SLOT_SPACING := 0.42

func _ready() -> void:
	# Most units carry no status effect most of the time; stay idle until one shows.
	set_process(false)

func update_from_fighter(fighter: Dictionary) -> void:
	var shield_now := int(fighter.get("shield", 0))
	_note_shield_transition(shield_now)
	# BREAK 期间必须保持可见，否则 shield 归零的同一帧精灵就被隐藏，
	# 破盾演出一帧都放不出来 —— 那等于没做。
	_set_effect_visible("shield", shield_now > 0 or _shield_phase == ShieldPhase.BREAK)
	var statuses: Dictionary = fighter.get("statuses", {})
	# Iterate the fixed definitions without allocating per-fighter dictionaries,
	# key arrays or an unused remaining-duration map on every rendered frame.
	for kind in EFFECTS:
		if kind == "shield":
			continue
		var status: Dictionary = statuses.get(kind, {})
		# Blood Pact's nonlethal self-bleed is stored separately so an enemy bleed
		# can remain lethal and keep its own attribution. Both share one icon.
		if kind == "bleed" and float(status.get("remaining", 0.0)) <= 0.0:
			status = statuses.get("bleed_nonlethal", {})
		_set_effect_visible(kind, float(status.get("remaining", 0.0)) > 0.0)

# 按护盾值的变化定相位。只在这里判定，_process 只负责把相位画出来。
func _note_shield_transition(shield_now: int) -> void:
	var was := _shield_amount
	_shield_amount = shield_now
	if shield_now > 0 and was <= 0:
		_begin_shield_phase(ShieldPhase.APPLY)
	elif shield_now <= 0 and was > 0:
		_begin_shield_phase(ShieldPhase.BREAK)
	elif shield_now > 0 and shield_now < was:
		# 低画质档丢掉吸收短闪。V2：critical 的破盾不可丢，ambient 的常驻波纹可降级 ——
		# 吸收闪属于后者，破盾属于前者。
		if not _shield_low_quality():
			_begin_shield_phase(ShieldPhase.ABSORB)
	elif shield_now <= 0:
		# 本来就没盾，且不在破盾演出中：彻底归位。
		if _shield_phase != ShieldPhase.BREAK:
			_shield_phase = ShieldPhase.NONE


func _begin_shield_phase(phase: ShieldPhase) -> void:
	_shield_phase = phase
	_shield_phase_elapsed = 0.0


# 直接读画质档的静态变量，而不是绕 VFXManager.get_quality_tier()。
# 两者读的是同一个 VFXQualityBudget.tier，但直接读不依赖 autoload 是否就位 ——
# headless 门禁里可以直接设这个静态量来测低画质分支。
func _shield_low_quality() -> bool:
	return VFXQualityBudget.tier == VFXQualityBudget.Tier.LOW


# 当前这一帧护盾该用的 alpha 与缩放系数。
func _shield_visual(delta: float) -> Vector2:
	_shield_phase_elapsed += delta
	match _shield_phase:
		ShieldPhase.APPLY:
			var t := clampf(_shield_phase_elapsed / SHIELD_APPLY_SEC, 0.0, 1.0)
			if t >= 1.0:
				_shield_phase = ShieldPhase.STEADY
				return Vector2(SHIELD_STEADY_ALPHA, 1.0)
			# 爆发起手最亮，然后收到常驻。
			return Vector2(lerpf(SHIELD_APPLY_ALPHA, SHIELD_STEADY_ALPHA, t), 1.0)
		ShieldPhase.ABSORB:
			var t := clampf(_shield_phase_elapsed / SHIELD_ABSORB_SEC, 0.0, 1.0)
			if t >= 1.0:
				_shield_phase = ShieldPhase.STEADY
				return Vector2(SHIELD_STEADY_ALPHA, 1.0)
			return Vector2(lerpf(SHIELD_ABSORB_ALPHA, SHIELD_STEADY_ALPHA, t), 1.0)
		ShieldPhase.BREAK:
			var t := clampf(_shield_phase_elapsed / SHIELD_BREAK_SEC, 0.0, 1.0)
			if t >= 1.0:
				# 演完才允许隐藏。这里**不能**直接调 _set_effect_visible ——
				# 它会改 _active_kinds，而调用方正在遍历那个数组。改成置一个待办标记，
				# 由 _process 在循环结束后处理。
				_shield_phase = ShieldPhase.NONE
				_shield_hide_pending = true
				return Vector2(0.0, 1.0)
			return Vector2(lerpf(SHIELD_BREAK_ALPHA, 0.0, t), lerpf(1.0, SHIELD_BREAK_SCALE, t))
		_:
			# STEADY / NONE：常驻很淡，且**不脉动** —— 常驻脉动正是"每帧都在提醒你"的来源。
			return Vector2(SHIELD_STEADY_ALPHA, 1.0)


func _process(delta: float) -> void:
	var t := float(Time.get_ticks_msec()) * 0.001 + _phase
	for kind in _active_kinds:
		var sprite := _sprites[kind] as Sprite3D
		if sprite == null:
			continue
		var cfg: Dictionary = EFFECTS[kind]
		if kind == "shield":
			# 护盾走自己的相位状态机，不参与下面那套通用脉动。
			var visual := _shield_visual(delta)
			# 完整泡泡只属于施加/吸收/破盾事件；常驻换成中央透明的空心环。
			# 0.50 alpha 保持用户确认值不变，真正让出角色主体的是贴图中央不再填满。
			var steady := _shield_phase == ShieldPhase.STEADY
			var desired_texture: Texture2D = SHIELD_STEADY_TEXTURE if steady else SHIELD_EVENT_TEXTURE
			if sprite.texture != desired_texture:
				sprite.texture = desired_texture
			sprite.scale = (cfg.scale as Vector3) * visual.y
			sprite.position.x = 0.0
			sprite.position.y = 0.0
			sprite.modulate.a = visual.x
			continue
		var pulse := 1.0 + sin(t * 2.1 + float(kind.length())) * float(cfg.pulse)
		sprite.scale = (cfg.scale as Vector3) * pulse
		sprite.position.x = float(_slot_x.get(kind, 0.0))
		sprite.position.y = sin(t * 1.6 + float(kind.length())) * float(cfg.bob)
		sprite.rotation.z += float(cfg.rot) * delta
		sprite.modulate.a = float(cfg.alpha) * (0.9 + 0.1 * sin(t * 2.7 + float(kind.length())))
	# 循环结束后再收掉破盾精灵，避免在遍历中修改 _active_kinds。
	if _shield_hide_pending:
		_shield_hide_pending = false
		_set_effect_visible("shield", false)

func _set_effect_visible(kind: String, visible: bool) -> void:
	var sprite := _sprites.get(kind) as Sprite3D
	# A status that stays active needs no visibility/layout/process notifications.
	# Shield phase transitions still run above, and animate in _process.
	if sprite != null and sprite.visible == visible:
		return
	if sprite == null:
		if not visible:
			return
		sprite = _make_sprite(kind)
		if sprite == null:
			return
		_sprites[kind] = sprite
	sprite.visible = visible
	var index := _active_kinds.find(kind)
	var changed := false
	if visible and index < 0:
		_active_kinds.append(kind)
		changed = true
	elif not visible and index >= 0:
		_active_kinds.remove_at(index)
		changed = true
	if changed:
		_relayout_slots()
	# Only animate while something is actually on screen.
	set_process(not _active_kinds.is_empty())

# 头顶图标以头顶为中心横向排开：N 个图标时，第 i 个 x = (i - (N-1)/2) * 间距。
# 只排头顶（HeadAnchor）图标；shield 挂在 BodyAnchor，是独立的，不参与。
func _relayout_slots() -> void:
	var head_kinds: Array[String] = []
	for kind in _active_kinds:
		if str((EFFECTS[kind] as Dictionary).anchor) == "HeadAnchor":
			head_kinds.append(kind)
	_slot_x.clear()
	var count := head_kinds.size()
	if count <= 1:
		return
	var center := float(count - 1) * 0.5
	for i in range(count):
		_slot_x[head_kinds[i]] = (float(i) - center) * STATUS_SLOT_SPACING

func _set_procedural_status(kind:String,active:bool,remaining:float)->void:
	if not PROCEDURAL_STATUS_ANCHORS.has(kind):
		return
	var current=_procedural_statuses.get(kind)
	if current!=null and not is_instance_valid(current):
		_procedural_statuses.erase(kind);current=null
	if not active:
		if current!=null:
			current.stop_vfx(true)
			_procedural_statuses.erase(kind)
		return
	if current!=null:return
	var anchor:=_anchor(str(PROCEDURAL_STATUS_ANCHORS[kind]))
	var effect:=VFX_STATUS_EFFECT.new()
	effect.name="ProceduralStatus_%s"%kind
	anchor.add_child(effect)
	var profile:=VFXProfile3D.new()
	profile.size=.52 if kind!="poison" else .62
	profile.duration=maxf(.45,remaining)
	profile.particle_count=7
	profile.emission_energy=2.6
	profile.parameters={"status_type":kind}
	effect.play_profile(profile,{"target":Vector3.ZERO})
	_procedural_statuses[kind]=effect

func _make_sprite(kind: String) -> Sprite3D:
	if get_parent() == null or not is_instance_valid(get_parent()):
		return null
	var cfg: Dictionary = EFFECTS[kind]
	var anchor := _anchor(str(cfg.anchor))
	var sprite := Sprite3D.new()
	sprite.name = "Status_%s" % kind
	sprite.texture = STATUS_TEXTURES.get(kind)
	sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	# Keep the icon head-mounted and readable in the 1280x720 distant camera;
	# it is still much smaller than a unit and never becomes a world burst.
	# Each selected OGA shield cell is 200x176 px. Its larger pixel size keeps
	# the same readable world footprint as the retired 1254px event bubble.
	sprite.pixel_size = 0.0076 if kind == "shield" else (0.00160 if kind == "stun" else 0.00145)
	sprite.modulate = Color(1, 1, 1, float(cfg.alpha))
	sprite.scale = cfg.scale
	sprite.transparent = true
	sprite.no_depth_test = false
	sprite.shaded = false
	anchor.add_child(sprite)
	return sprite

func _anchor(anchor_name: String) -> Node3D:
	var existing := get_parent().get_node_or_null(anchor_name)
	if existing is Node3D:
		return existing as Node3D
	var anchor := Node3D.new()
	anchor.name = anchor_name
	match anchor_name:
		"HeadAnchor":
			anchor.position = Vector3(0.0, 1.55, 0.0)
		"BodyAnchor":
			anchor.position = Vector3(0.0, 0.85, -0.06)
		_:
			anchor.position = Vector3(0.0, 0.08, 0.0)
	get_parent().add_child(anchor)
	return anchor
