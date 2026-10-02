extends Node

# 10.02 三轮：`AvatarCatalog` 的「内孔几何」两张表的**对表门禁**
# （`FRAME_HOLE_FRAC` 占比 + `FRAME_HOLE_OFFSET` 圆心偏移）。
#
# 这两张表是「戴上头像框头像不变小」的支点：
#   绘制宽度 = 目标内孔 ÷ 表里的内孔占比，盒的落点 = 圆盘中心 − 表里的圆心偏移。
# 数字错了，框要么画小了切头像、要么画大了在头像外露一圈背景缝 —— 而**源码层完全
# 看不出来**（表是数据，抄错了照样解析、照样跑）。
#
# 所以这里把每张框素材的 PNG **重新量一遍**，和表里的值比。AvatarCatalog 的注释写着
# 「tools/frame_hole_check.gd 会把素材重新量一遍来对表」，本文件就是那句话的兑现。
#
# 口径（与 AvatarCatalog 的注释、与量产脚本 `其他/work/_qa_1002c/frame_hole_table.py`
# 完全一致）：
#   ① 从图心往 720 个方向打射线，取打到第一块不透明像素（alpha > 128）的距离 r(θ)；
#   ② 取中位数 med，保留 |r−med| ≤ 6% 的边界点（伸进洞里的宝石/冰晶在这里被剔掉，
#      那是装饰不是洞）；
#   ③ 对保留点做最小二乘圆拟合，得圆心与半径 R，迭代 4 次；
#   ④ 占比 = 2R / 图宽；偏移 = (圆心 − 图心)，以图宽/图高为单位的分数。
#
# ★ 为什么判据不直接调 `AvatarCatalog.frame_drawn_size()` 反算：那是同一份数据的自证
#   （用 A 算 B 再断言 B == A）。这里必须**从像素重新测量**，才与表互相独立。
#
# ★ frame_default 是唯一量不了的：那张图（profile_avatar.png）圆心是**实心**深棕盘，
#   没有 alpha 洞（它的洞是「深棕内盘 ↔ 金色圆环」的颜色边界）。所以改量那张抠空内圆
#   的副本（ProfileScreen 用的 frame_default.png），并放宽容差 —— 两张图同卷美术、洞
#   一样大，副本是工具抠的，边界有亚像素差。

const Harness := preload("res://tools/CheckHarness.gd")
const AvatarCatalog := preload("res://scripts/account/AvatarCatalog.gd")
const LobbyScript := preload("res://scenes/menu/Team3v3Lobby.gd")
const MenuScript := preload("res://scenes/menu/MainMenu.gd")

# 与 ProfileScreen.FRAME_DEFAULT_HOLLOW_PATH 同一个文件。刻意**不**从那个界面脚本取，
# 免得门禁跟着它一起改（路径换了这里应该自己红）。
const HOLLOW_DEFAULT_PATH := "res://assets/ui/shop/headframes/frame_default.png"

const RAYS := 720
const KEEP_BAND := 0.06
const FIT_ITERS := 4
# 每张图 720 条射线 × 最长 713 步 ≈ 51 万次取样。用 PackedByteArray 直接下标
# （不走 get_pixel）就够快；同张图只量一次，结果进 _cache。
const MAX_STEPS := 720

var _cache: Dictionary = {}


func _ready() -> void:
	call_deferred("_run")


# 解 3x3 线性方程组（最小二乘圆拟合的代数解法要用）。退化时返回空数组。
static func _solve3(m: Array, v: Array) -> Array:
	var a := float(m[0][0])
	var b := float(m[0][1])
	var c := float(m[0][2])
	var d := float(m[1][0])
	var e := float(m[1][1])
	var f := float(m[1][2])
	var g := float(m[2][0])
	var h := float(m[2][1])
	var i := float(m[2][2])
	var det := a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
	if absf(det) < 1e-9:
		return []
	var v0 := float(v[0])
	var v1 := float(v[1])
	var v2 := float(v[2])
	return [
		(v0 * (e * i - f * h) - b * (v1 * i - f * v2) + c * (v1 * h - e * v2)) / det,
		(a * (v1 * i - f * v2) - v0 * (d * i - f * g) + c * (d * v2 - v1 * g)) / det,
		(a * (e * v2 - v1 * h) - b * (d * v2 - v1 * g) + v0 * (d * h - e * g)) / det,
	]


# 量一张图的 {frac, off, w, h}；量不了（读不到 / 圆心不透明）返回 {}。
static func _measure(path: String) -> Dictionary:
	if path.is_empty() or not ResourceLoader.exists(path):
		return {}
	var tex := load(path) as Texture2D
	if tex == null:
		return {}
	var img := tex.get_image()
	if img == null:
		return {}
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	if w < 16 or h < 16:
		return {}
	var data := img.get_data()
	var cx0 := float(w) * 0.5
	var cy0 := float(h) * 0.5
	if data[(int(cy0) * w + int(cx0)) * 4 + 3] > 128:
		return {}  # 圆心不透明 ⇒ 没有 alpha 洞
	var rmax := mini(mini(w, h) / 2 - 1, MAX_STEPS)
	if rmax <= 2:
		return {}
	var xs: Array[float] = []
	var ys: Array[float] = []
	var rs: Array[float] = []
	xs.resize(RAYS)
	ys.resize(RAYS)
	rs.resize(RAYS)
	for i in RAYS:
		var ang := TAU * float(i) / float(RAYS)
		var dx := cos(ang)
		var dy := sin(ang)
		var hit := float(rmax)
		for step in range(1, rmax + 1):
			var x := int(roundf(cx0 + dx * float(step)))
			var y := int(roundf(cy0 + dy * float(step)))
			if x < 0 or y < 0 or x >= w or y >= h:
				break
			if data[(y * w + x) * 4 + 3] > 128:
				hit = float(step)
				break
		rs[i] = hit
		xs[i] = cx0 + dx * hit
		ys[i] = cy0 + dy * hit
	var ccx := cx0
	var ccy := cy0
	var radius := 0.0
	for _iter in FIT_ITERS:
		var sorted := rs.duplicate()
		sorted.sort()
		var n := sorted.size()
		var med: float = sorted[n / 2] if n % 2 == 1 \
			else (float(sorted[n / 2 - 1]) + float(sorted[n / 2])) * 0.5
		var sxx := 0.0
		var sxy := 0.0
		var syy := 0.0
		var sx := 0.0
		var sy := 0.0
		var sxz := 0.0
		var syz := 0.0
		var sz := 0.0
		var kept := 0
		for i in RAYS:
			var d := sqrt(pow(xs[i] - ccx, 2.0) + pow(ys[i] - ccy, 2.0))
			if absf(d - med) > KEEP_BAND * med:
				continue
			var px := xs[i]
			var py := ys[i]
			var pz := px * px + py * py
			kept += 1
			sxx += px * px
			sxy += px * py
			syy += py * py
			sx += px
			sy += py
			sxz += px * pz
			syz += py * pz
			sz += pz
		if kept < 20:
			break
		# 最小二乘圆拟合（代数法）：以 [2x, 2y, 1] 为设计矩阵解 z = x²+y²，
		# 解就是圆心 (a,b) 与 r² = c + a² + b²。下面直接写正规方程。
		var sol := _solve3([[4.0 * sxx, 4.0 * sxy, 2.0 * sx],
			[4.0 * sxy, 4.0 * syy, 2.0 * sy],
			[2.0 * sx, 2.0 * sy, float(kept)]],
			[2.0 * sxz, 2.0 * syz, sz])
		if sol.is_empty():
			break
		ccx = float(sol[0])
		ccy = float(sol[1])
		radius = sqrt(maxf(0.0, float(sol[2]) + ccx * ccx + ccy * ccy))
	return {"frac": 2.0 * radius / float(w), "off": Vector2(ccx - cx0, ccy - cy0),
		"off_frac": Vector2((ccx - cx0) / float(w), (ccy - cy0) / float(h)),
		"w": w, "h": h, "r": radius}


func _measure_cached(path: String) -> Dictionary:
	if not _cache.has(path):
		_cache[path] = _measure(path)
	return _cache[path]


func _run() -> void:
	var h := Harness.new("frame_hole")
	var entries := AvatarCatalog.frames()
	h.expect(entries.size() >= 7, "frames_present",
		"avatars.json 只给了 %d 张框（应 7 张）" % entries.size())

	var table: Dictionary = AvatarCatalog.FRAME_HOLE_FRAC
	var off_table: Dictionary = AvatarCatalog.FRAME_HOLE_OFFSET
	var ids: Array[String] = []
	for entry in entries:
		ids.append(str((entry as Dictionary).get("id", "")))

	# 两张表必须**恰好**覆盖清单里的每个 id：少一条 = 那个框走 fallback（画小/画大
	# 都没人管）；多一条 = 表烂了（图早就删了却还留着数）。
	for fid in ids:
		h.expect(table.has(fid), "table_has_" + fid,
			"%s 不在 FRAME_HOLE_FRAC 里 —— 它只能拿到 fallback 占比" % fid)
		h.expect(off_table.has(fid), "off_table_has_" + fid,
			"%s 不在 FRAME_HOLE_OFFSET 里 —— 内孔会按同心画，偏心的框会露背景缝" % fid)
	for key in table.keys():
		h.expect(ids.has(str(key)), "table_stale_" + str(key),
			"FRAME_HOLE_FRAC 里的 %s 在 avatars.json 里已经不存在了" % str(key))
	for key in off_table.keys():
		h.expect(ids.has(str(key)), "off_table_stale_" + str(key),
			"FRAME_HOLE_OFFSET 里的 %s 在 avatars.json 里已经不存在了" % str(key))

	# ── 表 vs 像素 ────────────────────────────────────────────────────────
	# 占比按「分数」比（容差 0.02 ≈ 素材宽度的 2%）；圆心偏移改到下面**按绘制坐标**比 ——
	# 偏移的用途是「把内孔圆心挪到圆盘中心上」，所以只有换算成屏幕上的像素数才有意义。
	# 素材侧的拟合对个别装饰密的框（炽焰之心的火焰）有约 5px 的不稳定，
	# 换算到绘制坐标只有 ~1px，所以在绘制坐标下判 1.5px。
	var worst_frac := 0.0
	var worst_frac_id := ""
	var worst_off := 0.0
	var worst_off_id := ""
	for entry in entries:
		var row := entry as Dictionary
		var fid := str(row.get("id", ""))
		var src_path := str(row.get("source", ""))
		var m := _measure_cached(src_path)
		var tol_frac := 0.02
		var via := src_path
		if m.is_empty():
			if fid != "frame_default":
				h.fail("not_measurable_" + fid,
					"%s 的圆心是不透明的，量不出内孔 —— 它是自定义框，内孔必须真的是个洞"
						% src_path)
				continue
			# 默认圆盘：改量抠空副本，放宽容差。
			m = _measure_cached(HOLLOW_DEFAULT_PATH)
			via = HOLLOW_DEFAULT_PATH
			tol_frac = 0.03
			h.expect(not m.is_empty(), "hollow_default_readable",
				"读不到 %s，默认圆盘的内孔没法对表" % HOLLOW_DEFAULT_PATH)
			if m.is_empty():
				continue
		var want_frac := AvatarCatalog.frame_hole_fraction(fid)
		var d_frac := absf(float(m["frac"]) - want_frac)
		if d_frac > worst_frac:
			worst_frac = d_frac
			worst_frac_id = fid
		h.expect(d_frac <= tol_frac, "frac_" + fid,
			"%s 的内孔占比对不上：表里 %.4f，从 %s 量出来 %.4f（差 %.4f > 容差 %.3f）"
				% [fid, want_frac, via.get_file(), float(m["frac"]), d_frac, tol_frac])

	# ── 组合判据：拿**生产脚本里的常量**算一遍，会不会露缝 ─────────────────
	# ① 内孔目标 ≤ 头像直径（否则头像外必有背景缝）；
	# ② 按「量出来的占比」反推出来的真实内孔，同样 ≤ 头像（+1px 余量给亚像素）；
	# ③ 内孔不能比头像小太多（否则框画得太小、金环离头像太远，看着像没戴上）。
	# 常量从 Team3v3Lobby / MainMenu 里读，不在这里抄一份 —— 抄一份就是两个真相。
	var sites: Array[Dictionary] = [
		{"name": "room", "box": LobbyScript.SLOT_FRAME_SIZE.x,
			"avatar": LobbyScript.SLOT_AVATAR_SIZE.x,
			"target": LobbyScript._slot_hole_target()},
		{"name": "lobby", "box": MenuScript.PROFILE_DISC_BOX.x,
			"avatar": MenuScript.PROFILE_PORTRAIT_SIZE.x,
			"target": MenuScript.PROFILE_DISC_BOX.x
				* AvatarCatalog.default_disc_hole_fraction()},
	]
	for site in sites:
		var sname := str(site["name"])
		var avatar := float(site["avatar"])
		var target := float(site["target"])
		h.expect(target <= avatar + 0.001, sname + "_target_le_avatar",
			"%s：内孔目标 %.1f > 头像 %.0f ⇒ 头像是圆的也盖不住内孔，头像外必露背景缝"
				% [sname, target, avatar])
		h.expect(target > 0.0, sname + "_target_positive",
			"%s：内孔目标算成了 %.1f" % [sname, target])
		for entry in entries:
			var frow := entry as Dictionary
			var fid2 := str(frow.get("id", ""))
			if fid2 == "frame_default":
				continue  # 默认框画的不是这张框，是圆盘本身
			var m2 := _measure_cached(str(frow.get("source", "")))
			var t2 := AvatarCatalog.frame_hole_fraction(fid2)
			if m2.is_empty() or t2 <= 0.0:
				continue
			var drawn_w := target / t2
			var drawn_h := drawn_w * float(m2["h"]) / float(m2["w"])
			var real_hole := drawn_w * float(m2["frac"])
			h.expect(real_hole <= avatar + 1.0, "%s_no_gap_%s" % [sname, fid2],
				"%s：%s 按表里的占比画 %.1f 宽，从像素量出来的真实内孔有 %.1f > 头像 %.0f"
					% [sname, fid2, drawn_w, real_hole, avatar]
				+ " ⇒ 头像外会露出一圈背景缝")
			h.expect(real_hole >= avatar * 0.86, "%s_not_too_small_%s" % [sname, fid2],
				"%s：%s 的真实内孔只有 %.1f，比头像 %.0f 小了 %.0f%% ⇒ 框贴不上去（像没戴）"
					% [sname, fid2, real_hole, avatar,
						(1.0 - real_hole / avatar) * 100.0])
			# 圆心偏移：把「表里的偏移」和「从像素量出来的偏移」都换算到绘制坐标再比。
			# 这条是补偿能不能对上的**唯一**判据 —— 偏 3px 以上就会在头像外露缝。
			var off_t := AvatarCatalog.frame_hole_offset(fid2)
			var off_m: Vector2 = m2["off_frac"]
			var off_t_px := Vector2(off_t.x * drawn_w, off_t.y * drawn_h)
			var off_m_px := Vector2(off_m.x * drawn_w, off_m.y * drawn_h)
			var delta_px := off_t_px.distance_to(off_m_px)
			if delta_px > worst_off:
				worst_off = delta_px
				worst_off_id = "%s/%s" % [sname, fid2]
			h.expect(delta_px <= 1.5, "%s_off_%s" % [sname, fid2],
				"%s：%s 的内孔圆心偏移与表里差 %.2f 绘制像素（`_place_*` 会用表里的值把它"
					% [sname, fid2, delta_px]
				+ "挪到圆盘中心；差得越多就越可能凑巧在头像外露缝）")

	h.note("内孔占比最大偏差 %.4f（%s）；内孔圆心偏移最大偏差 %.2f 绘制像素（%s）"
		% [worst_frac, worst_frac_id, worst_off, worst_off_id])
	h.finish(get_tree())
