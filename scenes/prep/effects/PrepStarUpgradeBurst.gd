extends Node3D

# 升星（1→2★ / 2→3★）的特效：一次性的**四角星迸发 + 飘散**。
#
# ## 这一版是照实拍改的，不是照印象做的
#
# Leno 给了一段金铲铲实录（XO1CicVll8E，25~28 秒左下角待命区那次 2★）。
# 逐帧定格之后看到的是：
#   · 26.65s 峰值：3~4 颗**大的白色四角星**（带明显的十字光芒，lens flare 那种）
#     散在棋子上方，同时**几十颗小的青蓝色四角星**铺开，范围远超一个格子；
#   · 26.95s：大星已经没了，小星数量减半、还在飘散；
#   · 27.25s：基本散尽。整段约 0.5 秒，整体**冷色**（白 + 青蓝）。
#   · **没有光柱，没有地面圆环**，一个都没有。
#
# 所以之前那版（外扩地面环 → 竖直光柱）两个主体全部作废，换成这里的星星迸发。
# 唯一留下来的结论是「2★ 用冷色」—— 那条实拍对上了。
#
# 3★ 在那段视频里没有出现，所以是**按同配方换金色加量**推的，没有实拍依据。
#
# 备战阶段不做顿帧：Engine.time_scale 会把备战倒计时一起拖慢。

# 星星贴图：中心一个亮核 + 上下左右四道光芒。纯色面片会渲成硬边方块，
# 圆形柔光点又少了那四道芒 —— 实拍里大星的「十字光芒」是辨识度的来源。
const STAR_TEX_SIZE := 96
# 光芒的细度（越小越细）。0.14 大致对得上实拍里那种细长芒。
const SPIKE_WIDTH := 0.14

# 备战棋子渲染高度（PrepBoardModels 里 FOUR_STAR_AURA.fit_to_actor 的第三参），
# 星星的起点高度按它取，不要写死。
const UNIT_HEIGHT := 0.32
# 一个格子的世界尺寸（PrepBoardModels.PREP_CELL_MARK_SIZE）。散布半径按格数折算，
# 改棋盘尺寸时这里跟着走。
const CELL_SIZE := 0.6

const PRESETS := {
	2: {
		# 冷色：大星近白，小星青蓝 —— 实拍就是这两色。
		"big_color": Color(1.0, 1.0, 1.0),
		"small_color": Color(0.55, 0.88, 1.0),
		"big_count": 4, "big_size": 0.20,
		"small_count": 34, "small_size": 0.065,
		# 散开约两格半（半径 = 1.25 格）。实拍里小星铺得比一个格子远得多。
		"spread_cells": 1.25,
		"big_spread_cells": 0.28,
		"duration": 0.50,
	},
	3: {
		# 3★ 没有实拍，按同配方换暖金 + 加量加时长。
		"big_color": Color(1.0, 0.96, 0.80),
		"small_color": Color(1.0, 0.82, 0.35),
		"big_count": 6, "big_size": 0.27,
		"small_count": 48, "small_size": 0.082,
		"spread_cells": 1.6,
		"big_spread_cells": 0.34,
		"duration": 0.70,
	},
}

# 星星冒出来的快慢：pop 内从 0 弹到满尺寸，之后一路缩小淡出。
const POP_RATIO := 0.12
# 迸发之后整体还会往上飘一点（不是纯平面散开）。
const DRIFT_UP := 0.14

static var _star_texture: ImageTexture

var _star := 0
var _elapsed := 0.0
var _playing := false
var _stars: Array[MeshInstance3D] = []
# 每颗星的参数：{dir, dist, delay, rise, size}
var _specs: Array[Dictionary] = []


func play(star: int) -> void:
	_star = star if PRESETS.has(star) else 3
	_elapsed = 0.0
	_playing = true
	_rebuild()
	_apply()
	visible = true


# 跳到播放中的任意时刻。截帧预览（tools/star_upgrade_preview）和门禁靠它取样 ——
# 等真实帧率去推进的话，抓出来的图每次都不一样，也就没法拿来挑方案。
func seek(t: float) -> void:
	if _stars.is_empty():
		_rebuild()
	_elapsed = maxf(0.0, t)
	_apply()


func total_duration() -> float:
	return float((PRESETS[_star if PRESETS.has(_star) else 3] as Dictionary)["duration"])


func _process(delta: float) -> void:
	if not _playing:
		return
	_elapsed += delta
	_apply()
	if _elapsed >= total_duration():
		_playing = false
		queue_free()


# 中心亮核 + 四道光芒。整个进程只生成一次（static），两档共用一张白图，
# 颜色走各自材质的 albedo_color。
static func _star_tex() -> ImageTexture:
	if _star_texture != null:
		return _star_texture
	var image := Image.create(STAR_TEX_SIZE, STAR_TEX_SIZE, false, Image.FORMAT_RGBA8)
	var half := float(STAR_TEX_SIZE) * 0.5
	for y in STAR_TEX_SIZE:
		for x in STAR_TEX_SIZE:
			var nx := (float(x) + 0.5 - half) / half
			var ny := (float(y) + 0.5 - half) / half
			var core := pow(clampf(1.0 - sqrt(nx * nx + ny * ny), 0.0, 1.0), 5.0)
			# 横芒：纵向极窄、横向慢慢收。竖芒同理转 90°。
			var spike_x := pow(clampf(1.0 - absf(ny) / SPIKE_WIDTH, 0.0, 1.0), 8.0) \
				* pow(clampf(1.0 - absf(nx), 0.0, 1.0), 1.6)
			var spike_y := pow(clampf(1.0 - absf(nx) / SPIKE_WIDTH, 0.0, 1.0), 8.0) \
				* pow(clampf(1.0 - absf(ny), 0.0, 1.0), 1.6)
			var a := clampf(core + 0.85 * (spike_x + spike_y), 0.0, 1.0)
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	_star_texture = ImageTexture.create_from_image(image)
	return _star_texture


func _rebuild() -> void:
	for node in _stars:
		if is_instance_valid(node):
			node.queue_free()
	_stars.clear()
	_specs.clear()
	var preset: Dictionary = PRESETS[_star if PRESETS.has(_star) else 3]
	_spawn_group(preset, true)
	_spawn_group(preset, false)


func _spawn_group(preset: Dictionary, big: bool) -> void:
	var count := int(preset["big_count" if big else "small_count"])
	var size := float(preset["big_size" if big else "small_size"])
	var color: Color = preset["big_color" if big else "small_color"]
	var spread := float(preset["big_spread_cells" if big else "spread_cells"]) * CELL_SIZE
	for i in count:
		# 全部走固定种子：同一档每次播出来一模一样，截图才可比、门禁才量得住。
		var rng := RandomNumberGenerator.new()
		rng.seed = hash("star_upgrade_%d_%s_%d" % [_star, "big" if big else "small", i])
		var angle := TAU * float(i) / float(count) + rng.randf_range(-0.35, 0.35)
		_specs.append({
			"dir": Vector3(cos(angle), 0.0, sin(angle)),
			"dist": spread * rng.randf_range(0.35, 1.0),
			# 大星几乎同时炸开，小星错峰铺到前三成时长 —— 一起冒会糊成一团。
			"delay": 0.0 if big else rng.randf_range(0.0, 0.30),
			# 大星落在**头顶一带**（实拍里那几颗带十字光芒的白星就在棋子上方），
			# 小星从脚到头铺开。都按棋子身高折算，不写死。
			"rise": UNIT_HEIGHT * (rng.randf_range(0.85, 1.55) if big else rng.randf_range(0.25, 1.30)),
			"size": size * rng.randf_range(0.75, 1.15),
		})
		_stars.append(_make_star(color, size))


func _make_star(color: Color, size: float) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * size
	node.mesh = quad
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	# 公告板：俯视相机下不转向相机的面片会被压成一条线，四道光芒也就没了。
	# 实拍里那些星芒是贴着屏幕的，正好是公告板的效果。
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.albedo_texture = _star_tex()
	mat.albedo_color = color
	mat.disable_receive_shadows = true
	node.material_override = mat
	add_child(node)
	return node


func _apply() -> void:
	var duration := total_duration()
	for i in _stars.size():
		_apply_star(_stars[i], _specs[i], duration)


func _apply_star(node: MeshInstance3D, spec: Dictionary, duration: float) -> void:
	if not is_instance_valid(node):
		return
	var delay := float(spec["delay"]) * duration
	var life := maxf(duration - delay, 0.001)
	var t := (_elapsed - delay) / life
	if t < 0.0 or t > 1.0:
		node.visible = false
		return
	node.visible = true
	# 向外散开：ease-out，起步快、收尾慢（迸发然后飘，不是匀速平移）。
	var out := 1.0 - pow(1.0 - t, 2.2)
	var dir: Vector3 = spec["dir"]
	node.position = dir * float(spec["dist"]) * out \
		+ Vector3(0.0, float(spec["rise"]) + DRIFT_UP * out, 0.0)
	# 尺寸：POP_RATIO 内弹到满，之后缓缓缩小 —— 星星是"炸出来"的，不是"亮起来"的。
	var pop := clampf(t / POP_RATIO, 0.0, 1.0)
	var shrink := 1.0 - 0.45 * smoothstep(0.35, 1.0, t)
	var quad := node.mesh as QuadMesh
	quad.size = Vector2.ONE * float(spec["size"]) * pop * shrink
	var mat := node.material_override as StandardMaterial3D
	var color: Color = mat.albedo_color
	color.a = pop * (1.0 - smoothstep(0.30, 1.0, t))
	mat.albedo_color = color
