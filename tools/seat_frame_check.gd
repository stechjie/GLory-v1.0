extends Node

# 10.02 bug 文档：自定义房间（3v3 大厅）席位的头像框展示。
#
# 需求原文：「AI、空位维持原样不变，玩家的座位头像框展示与大厅的头像保持一致，
# 不再保留当前的头像框后面的座位」「但需要保留这部分（房主铭牌）」。
#
# 所以本门禁分**两半**，缺一不可：
#
#   A 玩家席：木环底图必须隐藏；没戴自定义框时画大厅那套「金棕圆盘 + 106 头像」，
#             戴了自定义框时画「按内孔反推尺寸的框 + 同一个 106 头像」；铭牌复本一律补上。
#             **头像尺寸与戴哪个框无关**（10.02 三轮）—— 框画在头像下面。
#   B 空位 / 假想敌：**逐项断言与改动前一致** —— 底图照旧显示、不画圆盘、不画框、
#             不补铭牌复本、头像不可见、头像落点仍是 106@(39,40)、状态文字不变。
#
# B 这一半同等重要。需求点名要求这两态「维持原样」，只锁玩家席而不锁它们的话，
# 「隐藏底图」这种一刀切的改法会把 AI / 空位一起带偏，而且门禁照样全绿。
#
# 判据为什么读**节点**而不读源码文本：本次改动的作用点就是「哪几个 TextureRect
# 可见 + 头像节点的实际尺寸/位置」。源码断言只能证明"写了"，证明不了"落到节点上"——
# 而 10.01 第 4 条踩过的坑正是「只写 _placed 不落 _apply_tracked()」。
# 所以这里既读 _placed 的期望值，也读节点的实际 size/position，两者都要对。

const Harness := preload("res://tools/CheckHarness.gd")
const AvatarCatalog := preload("res://scripts/account/AvatarCatalog.gd")
const LobbyScript := preload("res://scenes/menu/Team3v3Lobby.gd")
const MenuScript := preload("res://scenes/menu/MainMenu.gd")
# 排位房间（10.10：用户第二次反馈「席位头像框只露一半」，本门禁原先**没覆盖它**）。
const PartyScript := preload("res://scenes/menu/PartyLobby.gd")
const PartyScene := preload("res://scenes/menu/PartyLobby.tscn")

# 真例化整页：不 stub _build/_refresh/_layout，直接跑生产实现，再读它自己落下的显隐。
# 与 profile_bug03_check.gd 的 LobbyProbe 同一套写法。
class LobbyProbe:
	extends "res://scenes/menu/Team3v3Lobby.gd"
	func _ready() -> void:
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_build()
		_refresh()
		_layout()


# 拿大厅资料卡当**参照物**（10.02 二轮）。需求是「席位与大厅保持一致」，
# 那就别把大厅那边的取值抄一份常量过来 —— 抄一份就等于两个真相，改一处忘另一处
# 门禁照样绿。这里真建一个大厅页，直接读它的两个节点取值来比。
# `_ready()` 覆盖掉生产的 `_ready()`，只跑 `_build()/_layout()`，不启动 BGM / 定时器。
class MenuProbe:
	extends "res://scenes/menu/MainMenu.gd"
	func _ready() -> void:
		_build()
		_layout()


func _ready() -> void:
	call_deferred("_run")


# 取某个节点在 _placed 里的**期望值**记录（_apply_slot_frame 写的就是这条）。
static func _placement_of(placed: Array, node: Control) -> Dictionary:
	for p in placed:
		if p.node == node:
			return p
	return {}


func _profile_with_frame(frame: String) -> Dictionary:
	return {
		"player_name": "Me",
		"friend_code": "ABCDEFGH",
		"avatar": "preset:avatar_001",
		"avatar_frame": frame,
	}


# 头像在参考画布上的中心点（席位基点 + 内孔中心偏移）。
static func _design_center(slot_index: int) -> Vector2:
	return Vector2(LobbyScript.SLOT_POS[slot_index]) + Vector2(92, 93)


static func _node_center(node: Control) -> Vector2:
	return node.position + node.size * 0.5


# _placed 里存的是**参考画布绝对坐标**（_add_texture / _apply_slot_frame 都往里写
# SLOT_POS[i] + 偏移），不是席位局部坐标 —— 别拿 (39,40) 直接比。
#
# ★ 10.02 三轮：头像落点**不再**分支。旧口径「有框 → 78@(53,54)」正是玩家报的
#   「戴上框头像变小」，现在三分支（无框 / 默认框 / 自定义框）都是 106@(39,40)。
static func _design_avatar_pos(slot_index: int) -> Vector2:
	return Vector2(LobbyScript.SLOT_POS[slot_index]) + LobbyScript.SLOT_AVATAR_POS


static func _design_avatar_size() -> Vector2:
	return LobbyScript.SLOT_AVATAR_SIZE


func _run() -> void:
	var h := Harness.new("seat_frame")
	var saved_profile := AccountManager.profile
	var saved_active := NetworkService.team_active
	var saved_seats := NetworkService.team_seat_profiles
	NetworkService.team_active = false
	NetworkService.team_seat_profiles = {
		1: {
			"player_name": "Other",
			"friend_code": "BCDEFGHJ",
			"avatar": "preset:avatar_002",
			"avatar_frame": "preset:avatar_frame_shop_05",
		},
	}
	# 本机（席位 0）= 房主、**没自定义框**（空串 = 没戴），正好是「默认框」那一支。
	AccountManager.profile = _profile_with_frame("")
	var lobby := LobbyProbe.new()
	lobby._slot_states = ["player", "player", "empty", "empty", "dummy", "empty"]
	add_child(lobby)

	# ── 前提体检 ──────────────────────────────────────────────────────────
	# _apply_tracked() 在 _layout_scale <= 0 时**直接 return**。比例是 0 的话下面
	# 所有「节点实际尺寸」的断言都会读到降级前的旧值 —— 那种绿是无声失效，先挡掉。
	var s: float = lobby._layout_scale
	h.expect(s > 0.0, "layout_scale",
		"布局比例未就绪（_layout_scale=%.3f），节点落点断言会静默失真" % s)

	# ── 结构：引用必须先被留住 ────────────────────────────────────────────
	# 原先 `_add_texture(TEX_SLOT, ...)` 的返回值被直接丢掉，想隐藏木环也没有把手。
	# 这一条就是防它被改回去 —— 一旦改回，数组元素为 null。
	h.expect(lobby._slot_bases.size() == 6 and lobby._slot_frame_bases.size() == 6,
		"ref_arrays", "席位底图 / 圆盘引用数组没有按 6 席建立")
	var refs_ok := true
	for i in 6:
		var base: TextureRect = lobby._slot_bases[i]
		var disc: TextureRect = lobby._slot_frame_bases[i]
		if base == null or base.texture != LobbyScript.TEX_SLOT:
			refs_ok = false
		if disc == null or disc.texture != LobbyScript.TEX_PROFILE_AVATAR:
			refs_ok = false
	h.expect(refs_ok, "ref_textures",
		"席位底图必须仍是 slot.png、圆盘必须是 profile_avatar.png")

	# 圆盘素材 == 「默认框」的素材：这是「与大厅保持一致」的**唯一依据**。
	# 素材一改名/一挪窝，席位画的就不再是默认框那张图 —— 这条会先红。
	h.expect(AvatarCatalog.frame_source_path("frame_default") == "res://assets/ui/main_menu_live/profile_avatar.png",
		"disc_is_default_frame",
		"席位用的圆盘不再是 frame_default 的素材，席位与大厅的默认框已经不是同一个东西")

	# ── 形状：框与圆盘都必须**保持长宽比**（10.02 二轮报的「变成椭圆」）────
	# 五张商城框素材实测 W/H = 0.773~0.889（都是竖长），金棕圆盘 850x825 也不是方的。
	# `_add_texture()` 的默认 `STRETCH_SCALE` 会把它们拉满 160x160 的矩形 ⇒ 非等比拉伸
	# ⇒ **横向压成椭圆**。大厅那两个节点用的是 keep-aspect 系，这里跟着一致。
	#
	# 判据不抄大厅的取值当常量，而是**真建一个大厅页**去读它 —— 抄一份就是两个真相，
	# 以后改了一处忘另一处，门禁仍然绿。
	var menu := MenuProbe.new()
	add_child(menu)
	# 目标内孔直径（下面几条量化都用它）。它必须跟着**默认圆盘**走，见 A3。
	var hole_target := LobbyScript._slot_hole_target()
	# ★ 三点必须一起成立，少一条「头像不会被框切到」就不成立：
	#   ① 框画在头像下面（A3 的 frame_below_avatar）
	#   ② 内孔 ≤ 头像（A3 的 hole_not_larger_than_avatar）
	#   ③ 反推出来的盒与素材同比例（下面的 drawn_box_matches_art）
	h.expect(menu._profile_frame_overlay.get_index()
			< menu._profile_portrait.get_parent().get_index(),
		"lobby_frame_below_portrait",
		"大厅资料卡的头像框画在头像**上面**了（框 idx=%d ≥ 头像 idx=%d）—— 席位跟着它学"
			% [menu._profile_frame_overlay.get_index(),
				menu._profile_portrait.get_parent().get_index()]
		+ "就会把头像边缘切掉，戴不同框头像就不一样大")
	var want_frame_mode: int = menu._profile_frame_art.stretch_mode
	var want_base_mode: int = menu._profile_base_frame.stretch_mode
	h.expect(want_frame_mode != TextureRect.STRETCH_SCALE
		and want_base_mode != TextureRect.STRETCH_SCALE,
		"lobby_modes", "大厅自己那两个节点就在拉满矩形 —— 前提不成立，下面的比对没有意义")
	h.expect(lobby._slot_frames[0].stretch_mode == want_frame_mode, "frame_mode_like_lobby",
		"席位头像框的拉伸方式(%d)与大厅资料卡(%d)不一致 ⇒ 非方素材会被压成椭圆"
			% [lobby._slot_frames[0].stretch_mode, want_frame_mode])
	h.expect(lobby._slot_frame_bases[0].stretch_mode == want_base_mode, "base_mode_like_lobby",
		"金棕圆盘的拉伸方式(%d)与大厅(%d)不一致"
			% [lobby._slot_frame_bases[0].stretch_mode, want_base_mode])
	h.expect(lobby._slot_frames[0].stretch_mode != TextureRect.STRETCH_SCALE
		and lobby._slot_frame_bases[0].stretch_mode != TextureRect.STRETCH_SCALE,
		"no_stretch_scale", "席位仍用 STRETCH_SCALE 拉满矩形（非等比）")

	# 量化：逐张框素材，**按内孔反推出来的那个盒**算宽高比，必须等于素材自己的宽高比。
	#
	# ★ 这里早先读的是「固定 160 盒 + 当前 mode」——三轮把盒改成按内孔反推之后，
	#   反推出来的盒天生与素材同比例（`frame_drawn_size` 就是这么算的），所以那条
	#   旧判据变成了恒真（无声失效）。改成直接锁**反推结果与素材的比例一致**：
	#   有人把 `frame_drawn_size` 改成返回方盒/固定盒时，这里立刻红。
	#   同时确认**真的有非方素材**，否则「盒贴素材比例」与「拉满方盒」画出来一样，
	#   这条判据同样会失去判别力（判别力本身要单独验，不能只看它绿）。
	var worst_drawn_aspect := 0.0
	var worst_box_gap := 0.0
	var frames_read := 0
	for entry in AvatarCatalog.frames():
		var fid := str((entry as Dictionary).get("id", ""))
		var tex: Texture2D = AvatarCatalog.frame_texture_for("preset:%s" % fid)
		if tex == null:
			continue
		frames_read += 1
		var src := Vector2(tex.get_width(), tex.get_height())
		var src_ratio := src.x / src.y
		var drawn := AvatarCatalog.frame_drawn_size(fid, hole_target)
		if drawn.y > 0.0:
			worst_drawn_aspect = maxf(worst_drawn_aspect,
				absf(drawn.x / drawn.y - src_ratio))
		worst_box_gap = maxf(worst_box_gap, absf(src_ratio - 1.0))
	h.expect(frames_read >= 7, "frames_readable",
		"只读到 %d 张框素材（应 7 张）—— 读不到就没有检查对象，这种绿是假绿" % frames_read)
	h.expect(worst_drawn_aspect < 0.01, "drawn_box_matches_art",
		"按内孔反推出来的绘制盒与素材宽高比不一致（最大偏差 %.4f）⇒ 会被压成椭圆"
			% worst_drawn_aspect)
	h.expect(worst_box_gap > 0.1, "non_square_frames_exist",
		"框素材最大的「离方图」偏差只有 %.4f —— 全是方图的话「盒贴素材比例」与「拉满方盒」"
			% worst_box_gap + "画出来一样，上面那条判据会失去判别力")

	# ── A1 玩家席：没自定义框（席位 0，房主） ─────────────────────────────
	h.expect(not lobby._slot_bases[0].visible, "player0_base_hidden",
		"玩家席位仍露着头像框后面的座位木环（需求：不再保留）")
	h.expect(lobby._slot_frame_bases[0].visible, "player0_disc",
		"玩家没戴自定义框时没画大厅那套金棕圆盘")
	h.expect(not lobby._slot_frames[0].visible, "player0_no_frame",
		"玩家没戴自定义框时不该画头像框")
	h.expect(lobby._slot_plates[0].visible, "player0_plate",
		"玩家席位的「房主」铭牌没补上（底图已隐藏，不补就没底）")
	h.expect(lobby._slot_avatars[0].visible, "player0_avatar",
		"玩家席位头像不可见")
	h.expect(lobby._slot_avatars[0].size.is_equal_approx(LobbyScript.SLOT_AVATAR_SIZE * s),
		"player0_avatar_size",
		"无框玩家头像实际尺寸应为 %.0f，实得 %.1f"
			% [LobbyScript.SLOT_AVATAR_SIZE.x, lobby._slot_avatars[0].size.x])
	var pl0 := _placement_of(lobby._placed, lobby._slot_avatars[0])
	h.expect(pl0.get("pos", Vector2.ZERO).is_equal_approx(_design_avatar_pos(0))
		and pl0.get("size", Vector2.ZERO).is_equal_approx(_design_avatar_size()),
		"player0_placement", "_placed 没把无框头像落回 106@(39,40)（只写期望值不落节点的老坑）")
	h.expect(lobby._slot_status_lbls[0].text in ["房主", "Host"], "player0_host_text",
		"房主席位的铭牌文字丢了：%s" % lobby._slot_status_lbls[0].text)

	# ── A2 玩家席：戴自定义框（席位 1） ──────────────────────────────────
	h.expect(not lobby._slot_bases[1].visible, "player1_base_hidden",
		"戴自定义框的玩家席位仍露着座位木环")
	h.expect(not lobby._slot_frame_bases[1].visible, "player1_no_disc",
		"戴自定义框时不该再画金棕圆盘（头像框已经把那一圈盖住了）")
	h.expect(lobby._slot_frames[1].visible, "player1_frame",
		"玩家的自定义头像框没画出来")
	h.expect(lobby._slot_plates[1].visible, "player1_plate",
		"戴框的玩家席位没补铭牌复本")
	# ★ 10.02 三轮的正题：**有框也不能缩**。旧口径这里是 78（玩家报的「变小」）。
	h.expect(lobby._slot_avatars[1].size.is_equal_approx(LobbyScript.SLOT_AVATAR_SIZE * s),
		"player1_avatar_size",
		"有框玩家头像实际尺寸应为 %.0f（与无框一致），实得 %.1f"
			% [LobbyScript.SLOT_AVATAR_SIZE.x, lobby._slot_avatars[1].size.x])
	var pl1 := _placement_of(lobby._placed, lobby._slot_avatars[1])
	h.expect(pl1.get("pos", Vector2.ZERO).is_equal_approx(_design_avatar_pos(1))
		and pl1.get("size", Vector2.ZERO).is_equal_approx(_design_avatar_size()),
		"player1_placement", "_placed 没把有框头像落成 106@(39,40)")

	# ── A3 结构不变式：为什么头像不可能被框切到 ───────────────────────────
	# 上面「尺寸 == 106」只证明**节点**是 106。节点 106 不等于**露出来** 106 ——
	# 框盖在头像上时，它那道圆内孔会实打实地吃掉头像边缘（三轮渲染实测：
	# 大厅各框 -0.8% ~ -4.1%）。所以这里锁两条**结构**上的保证：
	#
	#   ① 框画在头像**下面**（同父级、绘制序在前）。后加的画在上面，所以判据是
	#      「框的 child index < 头像的 child index」。
	#   ② 框的内孔直径 ≤ 头像直径。内孔比头像大就会在头像外面留一圈背景缝。
	#
	# ①+② 合起来 ⇒ 头像的可见像素与戴哪个框**逐像素无关**。这是结构性证明，
	# 不是「调一调数值碰运气」——渲染量测（`其他/work/_qa_1002c/`）只在佐证它。
	h.expect(lobby._slot_frames[1].get_index() < lobby._slot_avatars[1].get_index(),
		"frame_below_avatar",
		"头像框画在头像**上面**了（框 idx=%d ≥ 头像 idx=%d）—— 它的圆内孔会吃掉头像边缘，"
			% [lobby._slot_frames[1].get_index(), lobby._slot_avatars[1].get_index()]
		+ "戴上不同框头像就会不一样大")
	h.expect(hole_target <= LobbyScript.SLOT_AVATAR_SIZE.x + 0.001, "hole_not_larger_than_avatar",
		"目标内孔 %.1f 大于头像 %.1f —— 头像外面会露出背景缝"
			% [hole_target, LobbyScript.SLOT_AVATAR_SIZE.x])
	h.expect(hole_target > 0.0, "hole_target_positive", "目标内孔算成了 %.1f（占比表读不到？）" % hole_target)
	# 内孔目标必须**跟着默认圆盘的素材**走，而不是写死一个数字：素材换了/内孔占比
	# 被改错，这里会先红（FRAME_HOLE_FRAC 是数据，frame_hole_check 会重量它）。
	h.expect(is_equal_approx(hole_target,
			LobbyScript.SLOT_FRAME_SIZE.x * AvatarCatalog.default_disc_hole_fraction()),
		"hole_target_from_default_disc",
		"目标内孔不是「默认圆盘内孔」（实得 %.2f）" % hole_target)
	# 大厅那一侧同样要成立（席位是跟大厅学的，不能只有席位对）。
	var lobby_hole := menu._profile_hole_target()
	var lobby_avatar := float(MenuScript.PROFILE_PORTRAIT_SIZE.x)
	h.expect(lobby_hole <= lobby_avatar + 0.001, "lobby_hole_le_avatar",
		"大厅内孔目标 %.1f > 头像 %.0f ⇒ 头像是圆的也盖不住内孔，头像外必露背景缝"
			% [lobby_hole, lobby_avatar])
	h.expect(is_equal_approx(lobby_hole,
			float(MenuScript.PROFILE_DISC_BOX.x) * AvatarCatalog.default_disc_hole_fraction()),
		"lobby_hole_from_default_disc",
		"大厅的目标内孔不是「默认圆盘内孔」（实得 %.2f）" % lobby_hole)

	# ── 不变式：头像中心恒在 (92,93)（圆盘内孔中心 / 各分支同一个心） ─────
	# 三分支的**直径现在相同**，但中心仍必须同一个点：否则换框时头像横跳。
	var c0 := _node_center(lobby._slot_avatars[0])
	var c1 := _node_center(lobby._slot_avatars[1])
	var e0 := lobby._layout_origin + _design_center(0) * s
	var e1 := lobby._layout_origin + _design_center(1) * s
	h.expect(c0.distance_to(e0) < 1.0, "center_default",
		"无框头像中心偏离圆盘内孔中心 (92,93)：%.2f px" % c0.distance_to(e0))
	h.expect(c1.distance_to(e1) < 1.0, "center_custom",
		"有框头像中心与无框不是同一点 —— 换框时头像会横跳（偏 %.2f px）" % c1.distance_to(e1))

	# ── A4 自定义框的**绘制尺寸**由内孔反推（不是固定 160）─────────────────
	# 竖长的框素材按 160 盒贴满只剩 ~124 宽的内孔 —— 旧口径就是靠把头像缩到 78 去迁就它。
	# 现在反过来：先定内孔，再按各框自己的内孔占比反推整框要画多大。
	var fid1 := AvatarCatalog.id_from_value("preset:avatar_frame_shop_05")
	var want_drawn := AvatarCatalog.frame_drawn_size(fid1, hole_target)
	var plf := _placement_of(lobby._placed, lobby._slot_frames[1])
	h.expect(not want_drawn.is_zero_approx()
		and Vector2(plf.get("size", Vector2.ZERO)).is_equal_approx(want_drawn),
		"frame_drawn_size",
		"自定义框的绘制尺寸没按内孔反推：期望 %s，_placed 里是 %s"
			% [want_drawn, plf.get("size", Vector2.ZERO)])
	h.expect(Vector2(plf.get("size", Vector2.ZERO)) != LobbyScript.SLOT_FRAME_SIZE,
		"frame_not_fixed_box",
		"自定义框仍画在固定 160 盒里 —— 内孔必然对不上头像（这张框的内孔占比 %.4f）"
			% AvatarCatalog.frame_hole_fraction(fid1))
	# 落点必须由 `AvatarCatalog.frame_box_origin` 给出 —— 它把「内孔圆心」压到圆盘中心上。
	# 自己写 `中心 - 尺寸/2`（早先就是）会让内孔偏心的框（偏 2~3%）在头像外露一圈背景缝。
	var want_origin := LobbyScript.SLOT_POS[1] + AvatarCatalog.frame_box_origin(
		fid1, hole_target, LobbyScript.SLOT_DISC_CENTER)
	h.expect(Vector2(plf.get("pos", Vector2.ZERO)).is_equal_approx(want_origin),
		"frame_hole_centered_on_disc",
		"自定义框的内孔圆心没压在圆盘中心 (92,93) 上：期望落点 %s，_placed 里是 %s"
			% [want_origin, plf.get("pos", Vector2.ZERO)])
	# 反证：这张框的内孔在图里是**偏心**的，所以「按盒心对齐」和「按内孔心对齐」必须不同。
	# 若两者相同，说明表里的偏移是 0（新框没量过）——那时候这条判据就没有判别力，
	# 得先去 其他/work/_qa_1002c/frame_hole_table.py 把这张框量出来。
	h.expect(not want_origin.is_equal_approx(
			LobbyScript.SLOT_POS[1] + LobbyScript.SLOT_DISC_CENTER - want_drawn * 0.5),
		"frame_hole_eccentric",
		"%s 的内孔圆心偏移是零，这条判据退化成恒真 —— 请先用 frame_hole_table.py 量它"
			% fid1)
	h.expect(lobby._slot_frames[1].texture != null, "frame_texture_loaded",
		"自定义框素材没加载上")
	# ★ 框**节点自己**也必须落到 _placed 的期望值上 —— 10.01 第 4 条那个坑
	# （只写期望值不落节点）在框上同样成立，而上面那些断言读的都是 _placed。
	h.expect(lobby._slot_frames[1].size.is_equal_approx(want_drawn * s),
		"frame_node_size",
		"自定义框节点实际尺寸 %s ≠ _placed 期望 %s（只写了 _placed 没落节点）"
			% [lobby._slot_frames[1].size, want_drawn * s])
	h.expect(lobby._slot_frames[1].position.is_equal_approx(
			lobby._layout_origin + want_origin * s),
		"frame_node_pos",
		"自定义框节点实际位置 %s ≠ _placed 期望 %s（只写了 _placed 没落节点）"
			% [lobby._slot_frames[1].position, lobby._layout_origin + want_origin * s])
	# ★ 「占比表里的数字是不是真的」这类判据**不在这里**：它是同一份数据的自证。
	#   由 tools/frame_hole_check.gd 把每张 PNG 重新量一遍来对表。

	# ── 活切换：同一席位在「默认框 ↔ 自定义框」之间来回 ───────────────────
	# 覆盖 _on_profile_changed / 广播回来后只调 _refresh() 的那条路径。
	AccountManager.profile = _profile_with_frame("preset:avatar_frame_shop_05")
	lobby._refresh()
	h.expect(not lobby._slot_frame_bases[0].visible and lobby._slot_frames[0].visible,
		"switch_to_custom", "换成自定义框后：圆盘应熄灭、头像框应亮起（实得 盘=%s 框=%s）"
			% [lobby._slot_frame_bases[0].visible, lobby._slot_frames[0].visible])
	# ★ 10.02 三轮的正题：换上自定义框，头像**一像素都不许动**（旧口径这里缩到 78）。
	var avatar0_size := lobby._slot_avatars[0].size
	h.expect(avatar0_size.is_equal_approx(LobbyScript.SLOT_AVATAR_SIZE * s),
		"switch_size", "换成自定义框后头像尺寸变成了 %.1f（应恒为 %.0f，与无框一致）"
			% [avatar0_size.x, LobbyScript.SLOT_AVATAR_SIZE.x])
	h.expect(_node_center(lobby._slot_avatars[0]).distance_to(c0) < 1.0, "switch_center",
		"换自定义框后头像中心动了 %.2f px —— 玩家会看到头像横跳"
			% _node_center(lobby._slot_avatars[0]).distance_to(c0))
	# ★ 通用不变式：刚只调过 _refresh()（没有 _layout()），此时每一席头像节点的**实际**
	# 尺寸都必须等于 _placed 里的期望值。9.29 那个坑就是「写进 _placed ≠ 写进节点」
	# —— 座位从此停在旧字号旧位置，而在只跑过 _layout() 的路径上完全看不出来。
	# 所以这一条必须卡在「只 _refresh()」之后，那是唯一能照出它的时刻。
	for i in 6:
		var want_size := Vector2(_placement_of(lobby._placed, lobby._slot_avatars[i]).get("size", Vector2.ZERO)) * s
		h.expect(lobby._slot_avatars[i].size.is_equal_approx(want_size), "tracked_%d" % i,
			"第 %d 席头像节点实际尺寸 %s ≠ _placed 期望 %s（只写期望值没落节点）"
				% [i, lobby._slot_avatars[i].size, want_size])
	AccountManager.profile = _profile_with_frame("preset:frame_default")
	lobby._refresh()
	h.expect(lobby._slot_frame_bases[0].visible and not lobby._slot_frames[0].visible,
		"switch_back_default", "换回默认框后：圆盘应亮起、头像框应熄灭")
	h.expect(lobby._slot_avatars[0].size.is_equal_approx(LobbyScript.SLOT_AVATAR_SIZE * s),
		"switch_back_size", "换回默认框后头像尺寸不是 %.0f —— 头像尺寸不该随框变"
			% LobbyScript.SLOT_AVATAR_SIZE.x)
	h.expect(not lobby._slot_bases[0].visible, "switch_back_base",
		"换回默认框后座位木环又冒出来了")
	h.expect(_node_center(lobby._slot_avatars[0]).distance_to(c0) < 1.0, "switch_back_center",
		"换回默认框后头像中心动了 %.2f px" % _node_center(lobby._slot_avatars[0]).distance_to(c0))
	# 空串（没登录 / 老数据没有这个字段）也必须走「默认框」这一支。
	AccountManager.profile = _profile_with_frame("")
	lobby._refresh()
	h.expect(lobby._slot_frame_bases[0].visible and not lobby._slot_bases[0].visible,
		"empty_frame_value", "avatar_frame 为空串时应按默认框画圆盘（与大厅一致）")

	# ── B 空位 / 假想敌：逐项与改动前一致 ────────────────────────────────
	for i in [2, 3, 5]:
		var tag := "empty%d" % i
		h.expect(lobby._slot_bases[i].visible, tag + "_base",
			"空位席位不再显示座位底图（需求：空位维持原样）")
		h.expect(not lobby._slot_frame_bases[i].visible, tag + "_disc",
			"空位席位画了玩家的金棕圆盘")
		h.expect(not lobby._slot_frames[i].visible, tag + "_frame",
			"空位席位画了玩家头像框")
		h.expect(not lobby._slot_plates[i].visible, tag + "_plate",
			"空位给补了铭牌复本（会与底图自带的那块重复绘制）")
		h.expect(not lobby._slot_avatars[i].visible, tag + "_avatar",
			"空位显示了玩家头像")
		h.expect(lobby._slot_status_lbls[i].text in ["空位", "Empty"], tag + "_label",
			"空位状态文字变了：%s" % lobby._slot_status_lbls[i].text)
		var pl := _placement_of(lobby._placed, lobby._slot_avatars[i])
		h.expect(pl.get("pos", Vector2.ZERO).is_equal_approx(_design_avatar_pos(i))
			and pl.get("size", Vector2.ZERO).is_equal_approx(_design_avatar_size()),
			tag + "_placement", "空位头像落点被带偏了（应仍是 106@(39,40)）")

	var dd := 4
	h.expect(lobby._slot_bases[dd].visible, "dummy_base",
		"假想敌席位不再显示座位底图（需求：AI 维持原样）")
	h.expect(not lobby._slot_frame_bases[dd].visible, "dummy_disc",
		"假想敌席位画了玩家的金棕圆盘")
	h.expect(not lobby._slot_frames[dd].visible, "dummy_frame",
		"假想敌席位画了玩家头像框")
	h.expect(not lobby._slot_plates[dd].visible, "dummy_plate",
		"假想敌给补了铭牌复本（会与底图自带的那块重复绘制）")
	h.expect(not lobby._slot_avatars[dd].visible, "dummy_avatar",
		"假想敌显示了玩家头像")
	h.expect(lobby._slot_status_lbls[dd].text in ["假想敌", "AI"], "dummy_label",
		"假想敌状态文字变了：%s" % lobby._slot_status_lbls[dd].text)

	# ── 回切：把玩家席位打回空位，原来的木环必须回来 ──────────────────────
	# 上面「玩家席隐藏木环」这一条如果实现成「开局隐藏、之后不管」，
	# 换座到空位后整个座位会消失 —— 这里锁住反方向。
	lobby._slot_states = ["empty", "player", "player", "empty", "dummy", "empty"]
	lobby._refresh()
	h.expect(lobby._slot_bases[0].visible and not lobby._slot_plates[0].visible,
		"release_seat", "玩家离开席位后木环没回来（实得 底图=%s 铭牌=%s）"
			% [lobby._slot_bases[0].visible, lobby._slot_plates[0].visible])
	h.expect(not lobby._slot_frame_bases[0].visible, "release_disc",
		"玩家离开席位后金棕圆盘还留着")

	lobby.queue_free()
	menu.queue_free()
	await get_tree().process_frame
	AccountManager.profile = saved_profile
	NetworkService.team_active = saved_active
	NetworkService.team_seat_profiles = saved_seats

	await _check_party_lobby(h)

	h.finish(get_tree())


# ── 排位房间（PartyLobby）席位 ───────────────────────────────────────────────
#
# ★ 10.10 用户**第二次**反馈「排位房间头像框只露一半」。上一版确实改了
#   `PartyLobby._render_seats`，但**没把 avatar_frame 归一化**：那个字段存的是
#   `preset:<id>`，而 `frame_drawn_size` / `frame_box_origin` 要的是裸 id。
#   传原始值时 `frame_source_size()` 读不到素材、`FRAME_HOLE_FRAC` 也查不到，
#   直接返回 (0,0)，于是静默掉进 else 分支、退回旧的固定 154 盒 —— 框照旧只露一半，
#   而且**一声不响**（没有任何报错，门禁也没覆盖这里）。
#
# 自定义房间（Team3v3Lobby._apply_slot_frame）一直是归一化的；本门禁原先只覆盖了
# 那边和大厅，所以排位这条路径漏网。这里补齐，并且刻意**真例化整页 + 真跑
# `_apply`**，读席位节点自己落下的尺寸 —— 不是复刻一遍算式。
#
# 最后一条 `party_raw_value_yields_zero` 是**判别力**断言：它证明「归一化」这一步
# 确实是必需的。哪天 AvatarCatalog 改成也认裸 id 了，这条会先红 ——
# 那时该做的是删掉这条判据并说明，而不是留着一个永远为真的空断言。
func _check_party_lobby(h) -> void:
	var avatar := 100.0   # PartyLobby 席位头像圆直径（mask.size.x）
	var hole := PartyScript._seat_hole_target()
	h.expect(hole > 0.0, "party_hole_positive",
		"排位房目标内孔算成了 %.2f（默认圆盘内孔占比读不到？）" % hole)
	h.expect(is_equal_approx(hole, PartyScript.SEAT_FRAME_SIZE.x
			* AvatarCatalog.default_disc_hole_fraction()),
		"party_hole_from_default_disc",
		"排位房目标内孔不是「盘盒 × 默认圆盘内孔占比」（实得 %.2f）" % hole)
	h.expect(hole <= avatar + 0.001, "party_hole_not_larger_than_avatar",
		"排位房目标内孔 %.1f 大于头像 %.0f —— 头像外面会露出一圈背景缝"
			% [hole, avatar])

	var frame_value := "preset:avatar_frame_shop_04"
	var frame_id := AvatarCatalog.id_from_value(frame_value)
	var party := PartyScene.instantiate()
	party.call("configure_preview", "host")
	add_child(party)
	await get_tree().process_frame
	await get_tree().process_frame
	party.call("_apply", {
		"state": "room", "id": "probe", "mode": "ranked", "host_code": "AAAA0001",
		"queued": false, "host_pet": "pet_cat",
		"members": [{"friend_code": "AAAA0001", "player_name": "明", "tier": 3,
			"host": true, "ready": true, "seat": 0,
			"avatar": AvatarCatalog.default_avatar(), "avatar_frame": frame_value}],
		"pets": [], "messages": [],
	})
	await get_tree().process_frame

	var mask: Panel = null
	var frame: TextureRect = null
	var seat: Control = party.get("_seat_layer").get_child(0)
	for child in seat.get_children():
		if child is Panel and absf((child as Control).size.x - avatar) < 0.5:
			mask = child
		elif child is TextureRect and (child as TextureRect).texture != null:
			frame = child
	if not h.expect(mask != null and frame != null, "party_seat_nodes",
			"排位房席位没有头像圆(%s) / 头像框(%s) 节点" % [mask != null, frame != null]):
		party.queue_free()
		return

	var disc_center := mask.position + mask.size * 0.5
	var want_drawn := AvatarCatalog.frame_drawn_size(frame_id, hole)
	h.expect(want_drawn.x > 0.0, "party_want_drawn_positive",
		"用归一化后的 id「%s」反推不出绘制尺寸（素材路径变了？）" % frame_id)
	h.expect(frame.size.is_equal_approx(want_drawn), "party_frame_drawn_from_id",
		"席位框实际尺寸 %s != 由归一化 id 反推的 %s —— 没归一化时会退回旧的 154 盒"
			% [frame.size, want_drawn])
	h.expect(frame.position.is_equal_approx(
			AvatarCatalog.frame_box_origin(frame_id, hole, disc_center)),
		"party_frame_origin_from_id",
		"席位框落点 %s != 内孔圆心压在头像圆心的落点 %s"
			% [frame.position, AvatarCatalog.frame_box_origin(frame_id, hole, disc_center)])
	h.expect(frame.get_index() < mask.get_index(), "party_frame_below_avatar",
		"排位房头像框画在头像**上面**了（框 idx=%d ≥ 头像 idx=%d）—— 圆内孔会吃掉头像边缘"
			% [frame.get_index(), mask.get_index()])
	# 判别力：原始值（未归一化）必须算不出尺寸 —— 否则上面那条
	# `party_frame_drawn_from_id` 就算没归一化也会绿，判据等于空的。
	h.expect(AvatarCatalog.frame_drawn_size(frame_value, hole) == Vector2.ZERO,
		"party_raw_value_yields_zero",
		"原始值「%s」竟然能反推出尺寸 —— 归一化那一步已经不是必需的了，本组判据失去判别力"
			% frame_value)

	party.queue_free()
	await get_tree().process_frame
