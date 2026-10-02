extends RefCounted
# 头像清单（客户端侧）。数据源与后端是**同一个文件** —— res://data/avatars.json。
#
# 刻意**不用 class_name**，与 AccountConfig.gd / SessionContext.gd 同样的理由：
# make_server_zip.ps1 会打包 .godot/global_script_class_cache.cfg，
# 新增全局类若未先重建缓存就打包，服务器会在解析阶段直接挂。用 preload 引用。
#
# 为什么不放进 DataRegistry：那八张表每次冷启动都读，而这份清单只有玩家点开
# 资料页才要。启动预算是有人盯的（GLORY_STARTUP 的 data_registry_loaded），
# 不该为一个一个月用一次的东西加一笔。所以这里是**懒加载 + 进程内缓存**。
#
# ⚠️ 客户端这一层只负责**画得出来**，不负责授权。
# 「这个 id 合不合法、有没有资格用」由后端的 avatar_catalog.py 说了算 ——
# 客户端的清单可能比部署的后端旧（玩家没更新包），那时后端会回 400，
# 照它给的话提示玩家即可，不要在这里自己判。

const CATALOG_PATH := "res://data/avatars.json"

static var _cache: Dictionary = {}


static func _catalog() -> Dictionary:
	if not _cache.is_empty():
		return _cache
	var text := FileAccess.get_file_as_string(CATALOG_PATH)
	if text.is_empty():
		push_error("[AVATAR] 读不到 %s" % CATALOG_PATH)
		return {}
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("[AVATAR] %s 解析失败" % CATALOG_PATH)
		return {}
	_cache = parsed as Dictionary
	return _cache


# [{id, name, name_en, source}, ...]，顺序与文件一致（文件里就是排好的）。
static func avatars() -> Array:
	return _catalog().get("avatars", [])


static func frames() -> Array:
	return _catalog().get("frames", [])


static func default_avatar() -> String:
	return "preset:%s" % str(_catalog().get("default_id", "avatar_001"))


static func default_frame() -> String:
	return "preset:%s" % str(_catalog().get("default_frame_id", "frame_default"))


# 选择器用的小图。缩略图由 tools/make_avatar_thumbs.py 生成 ——
# 原图 330x330、解码后每张约 435 KB 显存，二十张一起铺出来会卡一下，
# 而这是每个玩家进资料页必做的第一个操作。
static func thumb_path(avatar_id: String) -> String:
	var dir := str(_catalog().get("thumb_dir", "res://assets/ui/avatars/thumb"))
	return "%s/%s.png" % [dir, avatar_id]


# 资料页上那张大图用原图。
static func source_path(avatar_id: String) -> String:
	for entry in avatars():
		if str((entry as Dictionary).get("id", "")) == avatar_id:
			return str((entry as Dictionary).get("source", ""))
	return ""


static func frame_source_path(frame_id: String) -> String:
	for entry in frames():
		if str((entry as Dictionary).get("id", "")) == frame_id:
			return str((entry as Dictionary).get("source", ""))
	return ""


static func display_name(avatar_id: String) -> String:
	var english := TranslationServer.get_locale().begins_with("en")
	for entry in avatars():
		var row := entry as Dictionary
		if str(row.get("id", "")) == avatar_id:
			return str(row.get("name_en" if english else "name", avatar_id))
	return avatar_id


# 把数据库里的 "preset:avatar_012" 拆成 "avatar_012"。
# 认不出来的（例如以后的 upload:）返回空串，调用方回落到默认头像 ——
# **不要在这里报错**：一个客户端画不出来的头像不该让整页打不开。
static func id_from_value(value: String) -> String:
	if value.begins_with("preset:"):
		return value.substr("preset:".length())
	return ""


static func texture_for(value: String, thumb: bool = false) -> Texture2D:
	var id := id_from_value(value)
	if id.is_empty():
		id = str(_catalog().get("default_id", "avatar_001"))
	var path := thumb_path(id) if thumb else source_path(id)
	if path.is_empty() or not ResourceLoader.exists(path):
		# 缩略图没生成（忘了跑 make_avatar_thumbs.py）时退回原图，
		# 慢一点但画得出来。两个都没有才是真缺资源。
		path = source_path(id)
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D


# ── 内孔几何（10.02 三轮：「戴上框头像就变小」的根因）───────────────────────
# 五张商城框都是**竖长**图（W/H 0.773~0.889），默认圆盘是 850x825（1.030）。
# 同一个方盒里 KEEP_ASPECT 按长边贴满 ⇒ 竖长的框被按高贴满，画出来的宽度只有盒子的
# 8 成，内孔于是比圆盘小一大截。旧口径是「把头像缩到 78 去迁就框」，玩家看到的就是
# 「戴上框，头像变小」。
#
# 正解：**头像尺寸恒定**，框反过来按内孔的几何反推 ——
#     绘制宽度 = 目标内孔直径 ÷ 本表的「内孔占比」
# 并且让**框的内孔圆心**落在圆盘圆心上（见 FRAME_HOLE_OFFSET），于是自定义框的
# 内孔与默认圆盘的内孔在屏幕上**完全重合**，头像怎么画都一样。
#
# 占比 = 内孔直径 ÷ 图宽。量法：从**内孔圆心**往 720 个方向打射线，取到第一块不透明
# 像素的距离，再取**中位数** ×2 —— 中位数就是那个干净的内圆；伸进洞里的宝石/尖刺不算
# 进去，它们正好对应「默认框的金环会压住头像边缘一点点」那种正常观感。
#
# ★ 这是**数据**不是结论：tools/frame_hole_check.gd 会把素材重新量一遍来对表。
#   换图 / 重裁 / 改内孔而对不上，门禁直接红。别手改这里去迁就一张新图。
#   量产脚本：其他/work/_qa_1002c/frame_hole_table.py（同一套算法）。
const FRAME_HOLE_FRAC := {
	"frame_default": 0.6271,
	"avatar_frame_7day_01": 0.6617,
	"avatar_frame_shop_01": 0.6122,
	"avatar_frame_shop_02": 0.6333,
	"avatar_frame_shop_03": 0.5998,
	"avatar_frame_shop_04": 0.6122,
	"avatar_frame_shop_05": 0.5741,
}

# 内孔圆心相对**素材图心**的偏移，以图宽 / 图高为单位的分数。
# 绘制坐标里的偏移 = (dx * 绘制宽, dy * 绘制高)。
#
# ★ 为什么必须有这张表：框画在头像**下面**，靠「内孔略小于头像」来避免露缝
#   （默认圆盘就是这样：内孔 0.6271×180 ≈ 112.9 < 头像 123）。这点余量只有
#   (123-112.9)/2 ≈ 5 px，而 6 张商城框的内孔在图里普遍**偏上 20~35px**
#   （换算到绘制坐标就是 3~5px）—— 不补偿就会在头像外露出一圈背景缝。
#   补偿之后，自定义框的内孔圆心与默认圆盘的**重合**，于是任何一张框的观感
#   都等于玩家已经认可的默认框。
const FRAME_HOLE_OFFSET := {
	"frame_default": Vector2(-0.00059, -0.00059),
	"avatar_frame_7day_01": Vector2(-0.00432, -0.02801),
	"avatar_frame_shop_01": Vector2(0.00818, -0.02432),
	"avatar_frame_shop_02": Vector2(-0.01021, -0.01385),
	"avatar_frame_shop_03": Vector2(0.00012, 0.01123),
	"avatar_frame_shop_04": Vector2(0.00228, -0.00272),
	"avatar_frame_shop_05": Vector2(-0.01201, -0.00679),
}
# 表里没有的框（美术刚加、还没量）：按默认圆盘估。宁可差一点，也不能算出 0 宽度。
const FRAME_HOLE_FALLBACK := 0.6271


static func frame_hole_fraction(frame_id: String) -> float:
	var frac := float(FRAME_HOLE_FRAC.get(frame_id, 0.0))
	return frac if frac > 0.0 else FRAME_HOLE_FALLBACK


# 内孔圆心相对素材图心的偏移（分数）。表里没有就当作同心 —— 新框先按默认圆盘那个
# 位置画，等 frame_hole_table.py 量完再补进表里（补之前门禁会红，这是刻意的）。
static func frame_hole_offset(frame_id: String) -> Vector2:
	return FRAME_HOLE_OFFSET.get(frame_id, Vector2.ZERO)


# 默认圆盘（frame_default）的内孔占比。
#
# 「戴上商城框头像就变小」的正解是**让自定义框的内孔与默认圆盘的内孔一样大** ——
# 该值就是那个尺寸的换算系数：内孔直径 = 圆盘盒边长 × 本值。
# 走本函数而不是在调用方写 `FRAME_HOLE_FRAC["frame_default"]`，是为了让
# 「默认框换成哪张图」只有 catalog 一个真相（调用方连 id 都不用知道）。
static func default_disc_hole_fraction() -> float:
	return frame_hole_fraction(id_from_value(default_frame()))


# 默认圆盘的内孔圆心相对**圆盘盒**中心的偏移（参考画布 px）。
# 圆盘是 `KEEP_ASPECT` 居中画的，所以「素材图心的偏移」直接换算到盒尺寸即可
# （实测约 (-0.1, -0.1) px，也就是「内孔就是同心的」）。留着是给下面那条注释一个
# 可核算的口径，不在生产路径上。
static func default_disc_hole_offset(box: Vector2) -> Vector2:
	var off := frame_hole_offset(id_from_value(default_frame()))
	return Vector2(off.x * box.x, off.y * box.y)


# 让「框的内孔圆心」正好落在 `disc_center` 上时，框盒左上角的坐标（参考画布）。
#
# 调用方**必须**走这个函数而不是自己算 `disc_center - drawn*0.5`：每个框的内孔在
# 图里的位置都不一样（见 FRAME_HOLE_OFFSET），少减一次就在头像外露一圈背景缝。
static func frame_box_origin(frame_id: String, target_hole: float,
		disc_center: Vector2) -> Vector2:
	var drawn := frame_drawn_size(frame_id, target_hole)
	if drawn.x <= 0.0:
		return Vector2.ZERO
	var off := frame_hole_offset(frame_id)
	return disc_center - Vector2(off.x * drawn.x, off.y * drawn.y) - drawn * 0.5


# 素材原始像素尺寸。读不到给 (0,0)，由调用方自己判 —— 不在这里报错。
static func frame_source_size(frame_id: String) -> Vector2:
	var path := frame_source_path(frame_id)
	if path.is_empty() or not ResourceLoader.exists(path):
		return Vector2.ZERO
	var tex := load(path) as Texture2D
	if tex == null:
		return Vector2.ZERO
	return Vector2(float(tex.get_width()), float(tex.get_height()))


# 让「画出来的内孔直径 == target_hole」所需要的绘制尺寸（保持素材长宽比）。
static func frame_drawn_size(frame_id: String, target_hole: float) -> Vector2:
	var src := frame_source_size(frame_id)
	if src.x <= 0.0 or src.y <= 0.0 or target_hole <= 0.0:
		return Vector2.ZERO
	var w := target_hole / frame_hole_fraction(frame_id)
	return Vector2(w, w * src.y / src.x)


static func frame_texture_for(value: String, fallback_to_default: bool = true) -> Texture2D:
	var id := id_from_value(value)
	if id.is_empty():
		if not fallback_to_default:
			return null
		id = str(_catalog().get("default_frame_id", "frame_default"))
	var path := frame_source_path(id)
	if (path.is_empty() or not ResourceLoader.exists(path)) and fallback_to_default:
		path = frame_source_path(str(_catalog().get("default_frame_id", "frame_default")))
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D
