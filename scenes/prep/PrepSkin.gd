extends RefCounted

# 棋盘皮肤：对局里摆放界面（摆棋子那页）的底图、河流、待命区、萝卜、商店按钮与商店背景换成哪一套。
# 只换图，不碰玩法。
# 在主界面「备战」页的「棋盘皮肤」页签里换（PetScreen），设计与加皮肤的步骤见 docs/棋盘皮肤.md。
#
# 一张皮肤 = data/prep_skins.json 里的一段 + assets/skins/prep/<皮肤 id>/ 下的图，
# 文件名就是下面 SLOTS 的键（board.png、river.png …），外加卡片用的 preview.png。
# 缺哪张就沿用默认那张，所以加皮肤只放图、改配置，不改代码。
#
# **只有自己看得见**：游戏里没有看别人摆放界面的功能（观战在战斗画面），
# 所以皮肤不进出战名片，战斗服务器也不知道它。
#
# 这里只给路径、不 load：战斗服务器包不带导入资源，专服上解析到的脚本
# 一旦 preload 贴图，冷启动就失败。

const DEFAULT_ID := "prep_skin_default"
const SKIN_FILE := "res://assets/skins/prep/%s/%s.png"

# 皮肤能换的图：槽位名（= 皮肤文件夹里的文件名）→ 默认皮肤用的那张。
const SLOTS := {
	# 棋盘底图：3D 地面那层，也是满屏 2D 垫底（PrepUI，盖住 3D 视口没铺到的角）
	"board": "res://assets/board/prep_2_5d/glory_grass_base_2560x1440.png",
	"river": "res://assets/board/prep_2_5d/prep20_river_bottom.png",  # 下河流：恢复原始窄带高度
	"bench": "res://assets/board/prep_2_5d/standby_bg.png",  # 待命区 8 格平台
	"carrot": "res://assets/props/prep/carrot_gathering_v1.png",
	"shop_button": "res://assets/ui/buttons/shop_closed.png",  # 底部商店按钮（图自带框，不叠字）
	"shop_panel": "res://assets/ui/shop/btm_stone_frame_v4.png",  # 商店打开时的卷轴背景（拉伸到 920×280 显示）
}

# 皮肤在 data/prep_skins.json 里可以另写的两项，不写就是默认：
#   firefly_color: [r, g, b]  满场飘的光点颜色
#   river_glow: false         关掉下河面的流动波光（那层是照草地河道画的）
const FIREFLY_DEFAULT := Color(1.0, 0.85, 0.45)  # 金色萤火虫

# 当前用哪张。游戏里只有 PlayerProfile 写它（账号服务器上存的那张）；皮肤预览场景会临时改。
static var active_id := DEFAULT_ID


# 当前皮肤这个槽位该用哪张图。
static func path(slot: String) -> String:
	return path_for(active_id, slot)


# 某张皮肤这个槽位该用哪张图。皮肤没给这张、或者这个包里根本没有这张皮肤，就用默认那张。
static func path_for(skin_id: String, slot: String) -> String:
	var fallback := str(SLOTS.get(slot, ""))
	if skin_id == DEFAULT_ID or not has_skin(skin_id):
		return fallback
	var own := SKIN_FILE % [skin_id, slot]
	return own if ResourceLoader.exists(own) else fallback


# 当前皮肤的全部图（进摆放界面前预热用）。
static func active_paths() -> Array:
	var out: Array = []
	for slot in SLOTS:
		out.append(path(slot))
	return out


# 卡片上的预览图：皮肤文件夹里的 preview.png（皮肤预览场景「生成预览图」拍的实机画面）；
# 没有就拿这张皮肤的棋盘底图顶上。
static func preview_path(skin_id: String) -> String:
	var own := SKIN_FILE % [skin_id, "preview"]
	return own if ResourceLoader.exists(own) else path_for(skin_id, "board")


static func firefly_color() -> Color:
	var raw: Variant = entry(active_id).get("firefly_color", null)
	if raw is Array and (raw as Array).size() == 3:
		return Color(float(raw[0]), float(raw[1]), float(raw[2]))
	return FIREFLY_DEFAULT


static func river_glow() -> bool:
	return bool(entry(active_id).get("river_glow", true))


# 这个包里有的皮肤，按 data/prep_skins.json 里的顺序。
static func catalog() -> Array:
	var table: Variant = DataRegistry.get_table("prep_skins")
	if not (table is Dictionary):
		return []
	var skins: Variant = (table as Dictionary).get("skins", [])
	return skins if skins is Array else []


# 目录里这张皮肤的那一段；包里没有就是空字典。
static func entry(skin_id: String) -> Dictionary:
	for item in catalog():
		if item is Dictionary and str(item.get("id", "")) == skin_id:
			return item
	return {}


static func has_skin(skin_id: String) -> bool:
	return not entry(skin_id).is_empty()


static func display_name(skin_id: String) -> String:
	var item := entry(skin_id)
	if item.is_empty():
		return skin_id
	if LocaleManager.get_locale().begins_with("en"):
		return str(item.get("name_en", item.get("name", skin_id)))
	return str(item.get("name", skin_id))
