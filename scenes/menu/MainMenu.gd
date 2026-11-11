extends Control

signal new_game_requested
signal continue_requested
signal settings_requested
signal team_host_requested
signal team_join_requested(address: String)
signal team_room_create_requested
signal team_room_join_requested(room_id: int)
signal team_room_spectate_requested(room_id: int)  # 观战（协议 44）：房间列表的「观战」行、好友列表的「观战」键
signal team_room_list_requested
signal public_token_generate_requested
signal public_token_resume_requested(token_id: String)
signal team_offline_requested   # 不联网，本地单人 vs AI 自测
signal team_reconnect_requested # 手动重连回上一场对局
signal casual_requested         # 「休闲」按钮：进匹配队列（协议 32，docs/排位系统设计.md 第五节）
signal ranked_requested         # 「排位」按钮：进排位队列。窗口 / 信誉分的闸在服务器那边
signal prep_requested           # 「备战」按钮：进入备战界面（暂时只有宠物系统）
signal codex_requested          # 「图鉴」按钮：进入图鉴界面
signal profile_requested        # 左上角名牌：进入玩家资料界面
signal friends_requested        # 左侧「朋友」按钮：进入好友界面
signal chat_requested           # 左侧「聊天」按钮：进入私聊界面
signal announcements_requested  # 右侧「公告 / 活动」：进入公告界面
signal shop_requested           # 右侧「商店」：进入商城
signal diamond_shop_requested   # 顶部钻石 +：直接进入钻石档位
signal bag_requested            # 右上角「背包」：进入背包
signal mail_requested           # 右上角「邮件」：进入邮箱（docs/邮件系统设计.md）

var _tutorial_casual_target: Button
var _tutorial_profile_target: Button
var _tutorial_prep_target: Button

func tutorial_casual_target() -> Control:
	return _tutorial_casual_target


func tutorial_profile_target() -> Control:
	return _tutorial_profile_target


func tutorial_prep_target() -> Control:
	return _tutorial_prep_target

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const AvatarCatalog := preload("res://scripts/account/AvatarCatalog.gd")
const SignInBridge := preload("res://scripts/account/SignInBridge.gd")
# 9.17：BGM 走常驻服务（播放器挂 root），音效走 SfxService 的播放器池。
# 两者都不做 autoload，由 Main._ready() 各 install() 一次。
const MusicService := preload("res://ui/services/MusicService.gd")
const SfxService := preload("res://ui/services/SfxService.gd")
const GloryToastScript := preload("res://ui/components/GloryToast.gd")
const REF_SIZE := Vector2(1672.0, 941.0)

# V3 P0-07：房间面板改由 ModalStack 收口。
# priority 40 与组队佣兵检阅台同档 —— 都是页面级面板，
# 低于 pvp_warning 60 < 战斗加载 80 < 重连 90 < DialogService 100。
const ROOM_MODAL_ID := "main_menu_room_panel"
const ROOM_MODAL_PRIORITY := 40

# ── 自定义房间面板：方案C「雾林夜幕」尺寸表 ──────────────────────────
# 设计稿与截图在 桌面\自定义功能界面布局\（方案C_设计规范.md + c_empty/c_rooms/c_spec.png）。
# 这些数字是从**截图逐像素量出来的**，不是照抄稿子里的意图描述 —— 稿子写「左栏 300、
# 按钮高 52、行高 46、行距 8」，实测面板 800×540、内边距 32、标题行 46、主区块间距 22、
# 分隔线 1px、左右栏间距 28、左栏 300、按钮 52、输入框 46、行 46 + 行距 8（三行文字实测
# 中心距 54 = 46 + 8），全部吻合。唯一的偏差点是面板描边：稿子里是 1px，这里用 2px ——
# 面板在 1672×941 画布上按 _layout_scale≈0.77 输出，1px 逻辑描边落地不到 1 个设备像素，
# 金色描边会糊掉；2px 才稳。
const ROOM_PANEL_SIZE := Vector2(800, 540)
const ROOM_PAD := 32
const ROOM_GAP_SECTION := 22
const ROOM_GAP_COLUMN := 28
const ROOM_GAP_LEFT_COLUMN := 18
const ROOM_COLUMN_LEFT := 300
const ROOM_TITLE_ROW_H := 46
const ROOM_BUTTON_H := 52
const ROOM_INPUT_H := 46
const ROOM_ROW_H := 46
const ROOM_ROW_GAP := 8
const ROOM_RADIUS := 8
const ROOM_RADIUS_PANEL := 16
const ROOM_FONT_TITLE := 26
const ROOM_FONT_HEAD := 18
const ROOM_FONT_BODY := 15
const ROOM_FONT_HINT := 13
const ROOM_ICON_SIZE := 44
const TEX_BACKGROUND := preload("res://assets/ui/main_menu_v2/background.png")
const TEX_PROFILE_PANEL := preload("res://assets/ui/main_menu_v2/profile_panel.png")
const TEX_PROFILE_AVATAR := preload("res://assets/ui/main_menu_v2/profile_avatar.png")
const TEX_SCROLL_BAR := preload("res://assets/ui/main_menu_v2/scroll_bar.png")
# 11.10 用户给的金币 / 钻石图标（只用在主菜单货币栏）。
const TEX_COIN_ICON := preload("res://assets/ui/main_menu_v2/coin_icon.png")
const TEX_DIAMOND_ICON := preload("res://assets/ui/main_menu_v2/diamond_icon.png")
const SHINE_SHADER := preload("res://shaders/main_menu_shine.gdshader")
# 11.10 资料卡：名牌卷轴（head exp bar）画在圆环右边，圆环压住它左端。
const PROFILE_PLATE_POS := Vector2(150, 46)
const PROFILE_PLATE_SIZE := Vector2(375, 117)
# 新圆环（head.png 裁边后 420x365）的透明洞：直径 289px、洞心在图的 (205.5, 181)。
# 换了那张图就要重新量（PIL 从图中心找透明连通块即可）。
const PROFILE_RING_HOLE_FRAC := 289.0 / 420.0
const PROFILE_RING_HOLE_CENTER := Vector2(205.5 / 420.0, 181.0 / 365.0)
const PROFILE_PLACEHOLDER_COLOR := Color("4a3220")
const PROFILE_XP_POS := Vector2(250, 101)
const PROFILE_XP_SIZE := Vector2(174, 32)
const SHOP_POS := Vector2(1412, 132)
const SHOP_SIZE := Vector2(232, 283)
const NEWS_POS := Vector2(1412, 420)
const NEWS_SIZE := Vector2(232, 284)
# 羊皮纸上的字：深棕、带一圈浅色描边，跟概念图一致。
const INK_TEXT := Color("4a2c14")
const INK_OUTLINE := Color(1.0, 0.95, 0.80, 0.75)
# 11.11 自定义房间面板换成羊皮纸风（ui/theme/ParchmentKit.gd）
const Kit := preload("res://ui/theme/ParchmentKit.gd")
const ROOM_SECTION_COLOR := Color("8a4b12")
const TouchScrollContainer := preload("res://ui/components/TouchScrollContainer.gd")
# ── 资料卡那组头像的几何（10.02 三轮）────────────────────────────────────
# 头像 123、圆盘盒 180x175。**自定义框按内孔反推尺寸**（`_profile_hole_target()` +
# `AvatarCatalog.frame_drawn_size`）：内孔直径对齐到「默认圆盘的内孔」≈112.9
# （< 头像 123，所以头像盖得住、不会露缝），框的**内孔圆心**再按 FRAME_HOLE_OFFSET
# 压到圆盘中心上。于是不管戴哪张商城框，内孔几何都与默认圆盘重合、头像一点不变。
# 竖长素材要画得比圆盘更大才能做到这一点。
#
# ★ `PROFILE_DISC_POS` 就在画布左上角（y=12）。最厚的那些按内孔反推后画出来
#   约 197x246（炽焰之心）⇒ 圆盘中心在 y=99.5，顶点会跑到画布外约 23px 被裁掉。
#   **这是允许的**：2026-10-02 用户明确「允许头像框超出屏幕外」。
#   不要为了不出屏去缩框或挪资料卡 —— 那会把「任意框头像一样大」这条破坏掉。
const PROFILE_DISC_POS := Vector2(18, 12)
const PROFILE_DISC_BOX := Vector2(180, 175)
const PROFILE_PORTRAIT_SIZE := Vector2(123, 123)
# 圆盘盒中心。头像与自定义框（的**内孔圆心**）都以它为心。
const PROFILE_DISC_CENTER := PROFILE_DISC_POS + PROFILE_DISC_BOX * 0.5
const PROFILE_PORTRAIT_POS := PROFILE_DISC_CENTER - PROFILE_PORTRAIT_SIZE * 0.5
const TEX_MAIL := preload("res://assets/ui/main_menu_v2/mail.png")
# 千分位与商城、邮件共用这一份（两处显示同一个数，格式不一样很显眼）。
const Currency := preload("res://scripts/account/Currency.gd")
const TEX_BAG := preload("res://assets/ui/main_menu_v2/bag.png")
const TEX_SETTINGS := preload("res://assets/ui/main_menu_v2/settings.png")
const TEX_FRIENDS := preload("res://assets/ui/main_menu_v2/friends.png")
const TEX_CHAT := preload("res://assets/ui/main_menu_v2/chat.png")
const TEX_SHOP := preload("res://assets/ui/main_menu_v2/shop.png")
const TEX_NEWS := preload("res://assets/ui/main_menu_v2/news.png")
const TEX_PREP := preload("res://assets/ui/main_menu_v2/prep.png")
const TEX_CASUAL := preload("res://assets/ui/main_menu_v2/casual.png")
const LevelUpRewardDialog := preload("res://scenes/menu/LevelUpRewardDialog.gd")
const LEVEL_REWARD_MODAL_ID := "main_menu_level_rewards"
const TEX_RANKED := preload("res://assets/ui/main_menu_v2/ranked.png")
const TEX_CUSTOM := preload("res://assets/ui/main_menu_v2/custom.png")
const TEX_GALLERY := preload("res://assets/ui/main_menu_v2/gallery.png")
const MAIN_MENU_AMBIENCE := preload("res://scenes/menu/MainMenuAmbience.gd")
const MAIN_MENU_PET := preload("res://scenes/menu/MainMenuPet.gd")
const MENU_MUSIC_PATH := "res://assets/audio/bgm/menu_music.mp3"
# 9.27：右侧「商店」预览最新商品缩略图、「公告 / 活动」预览最新公告标题。
# AvatarCatalog 已在本文件顶部预加载，不再重复声明。
const PetPreview := preload("res://scripts/pets/PetPreview.gd")
const AnnouncementText := preload("res://scripts/account/AnnouncementText.gd")

# ── 布局调试overlay ────────────────────────────────────────────────
# 打开后：黑线 = 空间划分（参考画布边界 / 功能分区 / 每个元素占位框）
#         红线 = 所有按钮的点击判定区（_add_hit 与真实 Button）
# 游戏里按 F3 开关。调完把 DEBUG_LAYOUT 改回 false 即可。
const DEBUG_LAYOUT := false
# 参考画布(1672x941)下的功能分区，只用于画黑色分区带
const DEBUG_BANDS := [
	{"name": "顶部 HUD", "y": 0.0, "h": 135.0},
	{"name": "左侧社交栏", "y": 290.0, "h": 290.0},
	{"name": "右侧商店/公告", "y": 130.0, "h": 580.0},
	{"name": "令牌行", "y": 585.0, "h": 75.0},
	{"name": "底部主按钮区", "y": 640.0, "h": 280.0},
]

# 左上角名牌上的两行字。要在账号资料到达后就地刷新，所以留引用。
# 头像只有一个节点：默认框与自定义框共用它（10.02 三轮删掉了那个 78x78 的副本）。
var _profile_portrait: TextureRect
var _profile_base_frame: TextureRect
var _profile_frame_overlay: Control
var _profile_frame_art: TextureRect
var _profile_name_label: Label
var _profile_sub_label: Label
# 头像右上角的红点：游客号、并且这台设备能绑 Google / Apple 时亮，提醒去资料页绑定
# （docs/三方登录设计.md 第一节：只亮红点，不弹窗）。绑上之后 identities_changed 会把它灭掉。
var _profile_dot: Label
var _account_level := 0
var _account_xp_progress := 0
var _account_xp_required := 0
var _profile_xp_fill: ColorRect
var _profile_xp_bar: Control
var _coin_label: Label
var _diamond_label: Label
# 「聊天」图标右上角的未读红点。显隐只跟 ChatService 走（状态只有一份）。
var _chat_dot: Label
# ★ 10.07h 第 6 / 10 条：左侧「聊天」按钮的图标节点。房间/组队邀请气泡要
#   从它**右边引出**（用户要求「位置要设计在『聊天』UI 旁边，以信息气泡框的形式
#   引出」），所以得留个引用好算锚点 —— 见 `chat_invite_anchor()`。
var _chat_icon: TextureRect
# 「朋友」图标右上角的申请红点。显隐只跟 AccountManager 的未读申请集合走。
var _friends_dot: Label
# 「公告 / 活动」右上角的红点。显隐只跟 AnnouncementService 走。
var _news_dot: Label
var _mail_dot: Label
# 9.27：商店 / 公告图标内的实时预览。
var _shop_preview: Control
var _shop_dot: Label
var _shop_preview_timer: Timer
var _shop_preview_index := 0
var _news_title: Label
# 手绘宠物在主菜单右侧小框里留一点空间给金框和名称牌。
const SHOP_PREVIEW_SCALE := 0.94
const SHOP_PREVIEW_PETS := [
	"pet_cat",
	"pet_rabbit",
	"pet_mushroom",
	"pet_squirrel",
	"pet_tiger",
]
var _address_edit: LineEdit
var _net_status: Label
# 「敬请期待」不再持有 AcceptDialog 节点：见 _show_coming_soon()。
# 迁移前这是常驻在 MainMenu 下的 overlay 节点。现在面板由 ModalStack 持有，
# 开关状态用 ModalStack.has(ROOM_MODAL_ID) 问，不再自己记一个节点引用。
var _room_list_box: VBoxContainer
var _room_id_edit: LineEdit
var _room_status: Label
# 方案C：空列表态与房间列表**互斥显示**。设计稿里空态是一个铺满列表区的大圆角块
# （实测 x=右栏整宽、y=列表区上下沿），塞在 ScrollContainer 里做不到「铺满」——
# ScrollContainer 的滚动轴只按子节点 min size 给高度。所以两者并列，谁可见由
# show_room_list() 决定。
var _room_scroll: ScrollContainer
var _room_empty_box: Control
var _token_id_edit: LineEdit
var _token_label: Label
var _placed: Array[Dictionary] = []
var _screen_bands: Array[Dictionary] = []
var _debug_layer: Control
var _debug_on := DEBUG_LAYOUT
var _layout_scale := 1.0
var _layout_origin := Vector2.ZERO
# `_layout()` 那次用的安全区。`_apply_item()` 要单独落到某个元素时得复用它，
# 否则就得在循环里对每个元素重算一次 SafeArea（上百个元素 × 每次布局）。
var _layout_safe := Rect2()

func _ready() -> void:
	_build()
	_refresh_saved_match.call_deferred()
	_layout()
	_show_shop_fallback()
	_start_menu_music()
	if not AccountManager.profile_changed.is_connected(_on_account_profile_changed):
		AccountManager.profile_changed.connect(_on_account_profile_changed)
	if not ChatService.unread_changed.is_connected(_on_chat_unread_changed):
		ChatService.unread_changed.connect(_on_chat_unread_changed)
	if not AnnouncementService.changed.is_connected(_on_announcements_changed):
		AnnouncementService.changed.connect(_on_announcements_changed)
	if not MailService.changed.is_connected(_on_mail_changed):
		MailService.changed.connect(_on_mail_changed)
	if not AccountManager.identities_changed.is_connected(_refresh_guest_dot):
		AccountManager.identities_changed.connect(_refresh_guest_dot)
	_refresh_guest_dot()
	# 转屏（灵动岛换边）、切回前台时安全区会变，宽高不一定变。
	if not SafeArea.changed.is_connected(_layout):
		SafeArea.changed.connect(_layout)
	_refresh_profile_plate()
	_ensure_profile_loaded()
	# 钱包**每次回主菜单都重拉**，不像资料那样吃缓存 —— 玩家多半是刚从商城买完东西回来的。
	_refresh_wallet()
	_refresh_progression()
	_refresh_login_dot()
	# 9.17 反馈第 6 条：朋友申请的红点与提示音。
	#
	# ★ 这一行**曾经漏掉了** —— `_refresh_friend_requests()` 连同红点都写好了，却没人调它，
	# 于是红点永远是 _build() 里的初值 false、提示音一次都没响（「音效不响」与「没红点」
	# 两条反馈其实是同一个根因）。主菜单每次都是新实例（Main._clear() 会 free 掉旧的），
	# _ready() 必然重跑 —— 所以这里就是「每次回到主菜单都重新拉一次」的可靠落点。
	_refresh_friend_requests()
	# 大厅是停留最久的页面：只靠上面这一次的话，「已经停在大厅时收到的申请」要等下一次
	# 进出页面才会亮。补一个轻量轮询，把红点与提示音对齐到聊天那种「实时」的观感。
	_start_friend_request_poll()
	# 9.27：商店最新商品缩略图、公告最新标题预览。
	_refresh_news_title()
	_refresh_shop_preview.call_deferred()

func _exit_tree() -> void:
	if AccountManager.profile_changed.is_connected(_on_account_profile_changed):
		AccountManager.profile_changed.disconnect(_on_account_profile_changed)
	if ChatService.unread_changed.is_connected(_on_chat_unread_changed):
		ChatService.unread_changed.disconnect(_on_chat_unread_changed)
	if AnnouncementService.changed.is_connected(_on_announcements_changed):
		AnnouncementService.changed.disconnect(_on_announcements_changed)
	if MailService.changed.is_connected(_on_mail_changed):
		MailService.changed.disconnect(_on_mail_changed)
	if AccountManager.identities_changed.is_connected(_refresh_guest_dot):
		AccountManager.identities_changed.disconnect(_refresh_guest_dot)
	if SafeArea.changed.is_connected(_layout):
		SafeArea.changed.disconnect(_layout)

func _on_account_profile_changed(_profile: Dictionary) -> void:
	_refresh_profile_plate()

func _start_menu_music() -> void:
	# 9.17 反馈第 2 条：菜单 BGM 改为常驻播放，打开图鉴/聊天/朋友/设置时不暂停。
	#
	# 原实现在这里自建一个 AudioStreamPlayer 并 add_child 到主菜单上 ——
	# 而 Main._clear() 每次切子界面都会释放整个页面子树，播放器跟着没，
	# 于是「开个设置，音乐就断了」。现在播放器挂在 get_tree().root 下
	# （见 MusicService），不随任何一页生灭。
	#
	# 「同一首不重启」由 MusicService 内部判等负责：从子界面返回主菜单会再调
	# 一次这里，不会把 menu_music 从 0 秒重头播。
	MusicService.play(MENU_MUSIC_PATH)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_layout()

func _build() -> void:
	var bg := TextureRect.new()
	bg.texture = TEX_BACKGROUND
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var ambience := MAIN_MENU_AMBIENCE.new() as Control
	add_child(ambience)

	# 中心草地上的宠物（拥有几只出几只）。加在这里 = 在背景之上、所有 UI 之下。
	add_child(MAIN_MENU_PET.new() as Control)

	# ── 11.10 主菜单换成 main_menu_v2（森林空地 + 羊皮纸卷轴按钮）────────────────
	# 坐标是对着用户的概念图（同一张 1672x941 参考画布）摆的。按钮底图都是空白的，
	# 字由代码写（中英文切换）。顺序 = 绘制层级，hit 必须放在同组最后。
	# 每组按钮用 _anim_group() 登记，进场弹出 / 按下回弹 / 悬停放大都在那里统一做。

	# 左上角资料卡：名牌卷轴垫底，圆环压在它左端。
	var plate := _add_texture(TEX_PROFILE_PANEL, PROFILE_PLATE_POS, PROFILE_PLATE_SIZE, "left")
	# 新圆环中间是透明的洞。按「洞的直径 = 默认圆盘内孔（_profile_hole_target）、
	# 洞心 = 圆盘中心」反推画多大、画在哪 —— 这样自定义框的那套几何（按旧默认圆盘
	# 内孔反推）完全不用动，戴不戴框头像都一样大。
	var ring_size := _profile_ring_size()
	var ring_pos := PROFILE_DISC_CENTER - Vector2(ring_size.x * PROFILE_RING_HOLE_CENTER.x,
		ring_size.y * PROFILE_RING_HOLE_CENTER.y)
	_profile_base_frame = _add_texture(TEX_PROFILE_AVATAR, ring_pos, ring_size, "left")
	# 没头像时洞里垫一块深棕圆盘（概念图里的样子），不然会露出背后的草地。
	var placeholder := _add_round_portrait(PROFILE_PORTRAIT_POS, PROFILE_PORTRAIT_SIZE, "left")
	placeholder.texture = _solid_texture(PROFILE_PLACEHOLDER_COLOR)
	# 头像画在框**之上**、裁成圆形（10.02 三轮：只有这一个头像节点，任何框下都是 123）。
	_profile_portrait = _add_round_portrait(PROFILE_PORTRAIT_POS, PROFILE_PORTRAIT_SIZE, "left")
	# 自定义框的容器。**初始是圆盘盒的大小，实际尺寸由 `_refresh_profile_plate()`
	# 按内孔反推后改**（见 `_profile_hole_target()`）。
	_profile_frame_overlay = _add_container(PROFILE_DISC_POS, PROFILE_DISC_BOX, "left")
	_profile_frame_overlay.visible = false
	_profile_frame_art = TextureRect.new()
	_profile_frame_art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_profile_frame_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_profile_frame_art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_profile_frame_art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_profile_frame_overlay.add_child(_profile_frame_art)
	# ★ 10.02 三轮：自定义框画在头像**下面**，与默认圆盘同一层次（见 seat_frame_check）。
	move_child(_profile_frame_overlay, placeholder.get_parent().get_index())
	_profile_name_label = _add_label("", Vector2(207, 49), Vector2(260, 36), 26, "left")
	_ink(_profile_name_label)
	# 等级与经验文字居中覆盖在同一个进度条上。
	_profile_xp_bar = _add_container(PROFILE_XP_POS, PROFILE_XP_SIZE, "left")
	_profile_xp_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_profile_xp_bar.clip_contents = true
	var xp_track := Panel.new()
	var xp_track_style := StyleBoxFlat.new()
	xp_track_style.bg_color = Color("26374c")
	xp_track_style.set_corner_radius_all(3)
	xp_track.add_theme_stylebox_override("panel", xp_track_style)
	xp_track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	xp_track.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_profile_xp_bar.add_child(xp_track)
	_profile_xp_fill = ColorRect.new()
	_profile_xp_fill.color = Color("79d8ff")
	_profile_xp_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_profile_xp_fill.anchor_bottom = 1.0
	_profile_xp_fill.offset_left = 1.0
	_profile_xp_fill.offset_top = 1.0
	_profile_xp_fill.offset_right = -1.0
	_profile_xp_fill.offset_bottom = -1.0
	_profile_xp_bar.add_child(_profile_xp_fill)
	_profile_sub_label = _add_label("", PROFILE_XP_POS, PROFILE_XP_SIZE, 16, "left")
	_ink(_profile_sub_label)
	_profile_dot = _add_dot(Vector2(150, 26), "left")
	_tutorial_profile_target = _add_hit(Vector2(18, 20), Vector2(520, 160), _emit_profile, "left")
	_anim_group([plate, _profile_base_frame, placeholder.get_parent(), _profile_portrait.get_parent(),
		_profile_frame_overlay, _profile_name_label, _profile_xp_bar, _profile_sub_label],
		_tutorial_profile_target, 0, 0.0)

	# 货币：两条空白卷轴 + 图标 + 数字 + 「+」。拉到钱包之前显示 "—"（0 是看起来正常的错值）。
	_coin_label = _add_currency_bar("coin", Vector2(622, 30), Callable())
	_diamond_label = _add_currency_bar("diamond", Vector2(872, 30),
		func() -> void: diamond_shop_requested.emit())

	# 左侧好友 / 聊天
	var friends_tex := _add_texture(TEX_FRIENDS, Vector2(24, 296), Vector2(145, 137), "left")
	var friends_text := _add_label(_menu_text("好友", "Friends"), Vector2(39, 372), Vector2(115, 30), 22, "left")
	_ink(friends_text)
	# 9.17 反馈第 6 条：他人申请加好友时亮小红点，点进朋友后消失。初值不亮，等拉到申请再定。
	_friends_dot = _add_dot(Vector2(136, 298), "left")
	var friends_hit := _add_hit(Vector2(24, 296), Vector2(145, 137), _emit_friends, "left")
	_anim_group([friends_tex, friends_text, _friends_dot], friends_hit, 1, 0.06)
	# ★★ 10.07h 第 6 / 10 条：房间/组队邀请气泡从「聊天」图标右边引出，见 `chat_invite_anchor()`。
	_chat_icon = _add_texture(TEX_CHAT, Vector2(24, 440), Vector2(145, 130), "left")
	var chat_text := _add_label(_menu_text("聊天", "Chat"), Vector2(39, 512), Vector2(115, 30), 22, "left")
	_ink(chat_text)
	_chat_dot = _add_dot(Vector2(136, 442), "left")
	_chat_dot.visible = ChatService.any_unread()
	var chat_hit := _add_hit(Vector2(24, 440), Vector2(145, 130), _emit_chat, "left")
	_anim_group([_chat_icon, chat_text, _chat_dot], chat_hit, 1, 0.12)

	# 右上角背包 / 邮件 / 设置
	var bag_tex := _add_texture(TEX_BAG, Vector2(1342, 16), Vector2(102, 98), "right")
	var bag_text := _add_label(_menu_text("背包", "Bag"), Vector2(1353, 69), Vector2(80, 24), 18, "right")
	_ink(bag_text)
	var bag_hit := _add_hit(Vector2(1342, 16), Vector2(102, 98), _emit_bag, "right")
	_anim_group([bag_tex, bag_text], bag_hit, 1, 0.04)
	var mail_tex := _add_texture(TEX_MAIL, Vector2(1452, 14), Vector2(102, 102), "right")
	var mail_text := _add_label(_menu_text("邮件", "Mail"), Vector2(1462, 69), Vector2(73, 24), 18, "right")
	_ink(mail_text)
	# 有没读的邮件、或者有没领的附件时亮红点（MailService.needs_attention）。
	_mail_dot = _add_dot(Vector2(1524, 12), "right")
	_mail_dot.visible = MailService.needs_attention()
	var mail_hit := _add_hit(Vector2(1452, 14), Vector2(102, 102), _emit_mail, "right")
	_anim_group([mail_tex, mail_text, _mail_dot], mail_hit, 1, 0.08)
	var settings_tex := _add_texture(TEX_SETTINGS, Vector2(1562, 16), Vector2(102, 100), "right")
	var settings_text := _add_label(_menu_text("设置", "Settings"), Vector2(1572, 69), Vector2(79, 24), 18, "right")
	_ink(settings_text)
	var settings_hit := _add_hit(Vector2(1562, 16), Vector2(102, 100), _emit_settings, "right")
	_anim_group([settings_tex, settings_text], settings_hit, 1, 0.12)

	# 右侧商店 / 新闻
	var shop_tex := _add_texture(TEX_SHOP, SHOP_POS, SHOP_SIZE, "right")
	var shop_text := _add_label(_menu_text("商店", "Shop"), SHOP_POS + Vector2(43, 5), Vector2(146, 32), 23, "right")
	_ink(shop_text)
	# 中间那块只轮播宠物手绘图；底部小牌固定写「进入商店」。
	_shop_preview = _add_container(SHOP_POS + Vector2(22, 58), Vector2(SHOP_SIZE.x - 44, 158), "right")
	_shop_preview.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	var shop_enter := _add_label(_menu_text("进入商店  ›", "ENTER SHOP  ›"),
		SHOP_POS + Vector2(43, 222), Vector2(146, 27), 17, "right")
	_ink(shop_enter)
	_shop_dot = _add_dot(SHOP_POS + Vector2(SHOP_SIZE.x - 30, 2), "right")
	_shop_dot.visible = false
	var shop_hit := _add_hit(SHOP_POS, SHOP_SIZE, _emit_shop, "right")
	_anim_group([shop_tex, shop_text, _shop_preview, shop_enter, _shop_dot], shop_hit, 2, 0.10)
	var news_tex := _add_texture(TEX_NEWS, NEWS_POS, NEWS_SIZE, "right")
	var news_text := _add_label(_menu_text("新闻 / 活动", "News / Events"), NEWS_POS + Vector2(43, 5), Vector2(146, 30), 20, "right")
	_ink(news_text)
	# 9.27：新闻牌里显示最新一条公告的标题。
	_news_title = _add_label("", NEWS_POS + Vector2(36, 62), Vector2(160, 178), 18, "right")
	_ink(_news_title)
	_news_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_news_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_news_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_news_title.max_lines_visible = 5
	_news_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_news_title.visible = false
	_news_dot = _add_dot(NEWS_POS + Vector2(NEWS_SIZE.x - 30, 2), "right")
	_news_dot.visible = AnnouncementService.any_unread()
	var news_hit := _add_hit(NEWS_POS, NEWS_SIZE, _emit_announcements, "right")
	_anim_group([news_tex, news_text, _news_title, _news_dot], news_hit, 2, 0.16)

	# 底部五个模式按钮。排位赛最大、居中，常驻轻浮动 + 盾牌扫光。
	var mode_specs := [
		[TEX_PREP, Vector2(195, 668), Vector2(225, 169), _menu_text("备战", "Prep"), 30, 0.65, _emit_prep],
		[TEX_CASUAL, Vector2(435, 682), Vector2(215, 156), _menu_text("休闲", "Casual"), 30, 0.64, _on_casual],
		[TEX_RANKED, Vector2(650, 652), Vector2(335, 191), _menu_text("排位赛", "Ranked"), 38, 0.68, _on_ranked],
		[TEX_CUSTOM, Vector2(995, 658), Vector2(235, 185), _menu_text("自定义", "Custom"), 30, 0.67, _show_room_overlay],
		[TEX_GALLERY, Vector2(1240, 672), Vector2(245, 168), _menu_text("图鉴", "Gallery"), 30, 0.66, _emit_codex],
	]
	for i in mode_specs.size():
		var spec: Array = mode_specs[i]
		var pos: Vector2 = spec[1]
		var size: Vector2 = spec[2]
		var tex := _add_texture(spec[0], pos, size)
		var font_px: int = spec[4]
		var text_center_y: float = pos.y + size.y * float(spec[5])
		var text := _add_label(spec[3], Vector2(pos.x + size.x * 0.12, text_center_y - font_px * 0.75),
			Vector2(size.x * 0.76, font_px * 1.5), font_px)
		_ink(text, spec[0] == TEX_RANKED)
		var hit := _add_hit(pos, size, spec[6])
		var ranked: bool = spec[0] == TEX_RANKED
		if ranked:
			var shine := ShaderMaterial.new()
			shine.shader = SHINE_SHADER
			tex.material = shine
		_anim_group([tex, text], hit, 3, 0.18 + i * 0.05, ranked)
		if i == 0:
			_tutorial_prep_target = hit
		elif i == 1:
			_tutorial_casual_target = hit

	# 「离线自测」**只在调试版出现**（编辑器里跑、调试包）。
	#
	# 它不经过账号服务器就能打一整局，而规则是「连不上账号服务器就进不了游戏」——
	# 发布包里留着它，等于给玩家一个绕开这条规则的入口。开发时照样能用。
	if OS.is_debug_build():
		var offline_btn := Button.new()
		offline_btn.text = _menu_text("离线自测", "Offline")
		offline_btn.focus_mode = Control.FOCUS_NONE
		offline_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		_scroll_skin(offline_btn, 22)
		offline_btn.pressed.connect(_emit_offline)
		add_child(offline_btn)
		_track(offline_btn, Vector2(36, 862), Vector2(190, 52), 0, "left")

	# 游戏重连：仅在本地存在重连凭证时显示，点击回到上一场。
	var reconnect_btn := Button.new()
	reconnect_btn.name = "ReconnectButton"
	# 不用字体可能缺失的箭头占位，保证可见文字位于按钮正中。
	reconnect_btn.text = _menu_text("游戏重连", "Reconnect")
	reconnect_btn.alignment = HORIZONTAL_ALIGNMENT_CENTER
	reconnect_btn.focus_mode = Control.FOCUS_NONE
	reconnect_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	# 11.10：跟货币栏同一条空白卷轴（用户指定），深棕字。
	_scroll_skin(reconnect_btn, 26)
	reconnect_btn.pressed.connect(_emit_reconnect)
	# Active leave requests retain credentials only for the server receipt.
	reconnect_btn.visible = false # Wait for a verified resumable room, not just a disk token.
	add_child(reconnect_btn)
	_track(reconnect_btn, Vector2(1110, 591), Vector2(235, 64))

	_net_status = _add_label("", Vector2(640, 64), Vector2(320, 32), 20)
	_net_status.hide() # Background status checks must not overlay the currency HUD.
	_net_status.add_theme_color_override("font_color", Color(0.98, 0.88, 0.55))

	_address_edit = LineEdit.new()
	_address_edit.text = NetworkConfig.server_host()
	_address_edit.visible = false
	add_child(_address_edit)

	_build_debug_layer()

# 每次开层现建一份。ModalStack.push() 接管所有权，pop 时连同宿主层一起释放，
# 所以这里**不能**挂到 MainMenu 下 —— 那样切界面时会被清理逻辑连带删掉。
#
# 也不再自带 dim：背景交给 ModalStack 的 backdrop。自建那层不参与
# 「只有栈顶 backdrop 吃输入」的合同，而且两层黑会叠在一起。
func _build_room_panel() -> Control:
	var center := CenterContainer.new()
	center.name = "RoomPanel"
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var panel := PanelContainer.new()
	panel.custom_minimum_size = ROOM_PANEL_SIZE
	# 羊皮纸大面板（原来是深色毛玻璃 _room_panel_box）；主题给输入框 / 滚动条用
	panel.theme = Kit.theme()
	panel.add_theme_stylebox_override("panel", Kit.box("panel", Vector4(64, 44, 64, 36)))
	center.add_child(panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", ROOM_GAP_SECTION)
	panel.add_child(column)

	column.add_child(_room_title_row())
	column.add_child(_room_divider())

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", ROOM_GAP_COLUMN)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(body)

	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(ROOM_COLUMN_LEFT, 0)
	left.add_theme_constant_override("separation", ROOM_GAP_LEFT_COLUMN)
	body.add_child(left)

	# 9.14 反馈：Token ID / 输入 Token ID / 生成 / 恢复 四个控件在实测里都没有作用，
	# 从这里移除（网络侧动作与 Main 的信号处理保持不动，tools/main_team_*_action_check
	# 直接调 Main 的处理函数，不经过这些按钮）。移除后左栏首项就是「创建房间」。
	left.add_child(_dialog_button(_menu_text("创建房间", "Create Room"), _emit_create_room, "room_primary"))

	_room_id_edit = LineEdit.new()
	_room_id_edit.placeholder_text = _menu_text("输入房间 ID", "Enter Room ID")
	_room_id_edit.custom_minimum_size = Vector2(0, ROOM_INPUT_H)
	_room_id_edit.add_theme_stylebox_override("normal", Kit.box("plate", Vector4(20, 4, 20, 4), Color(0.93, 0.9, 0.84)))
	_room_id_edit.add_theme_stylebox_override("focus", Kit.box("plate", Vector4(20, 4, 20, 4)))
	_room_id_edit.add_theme_color_override("font_color", Kit.INK)
	_room_id_edit.add_theme_color_override("font_placeholder_color", Color(Kit.INK_SOFT, 0.7))
	_room_id_edit.add_theme_color_override("caret_color", Kit.INK)
	_room_id_edit.add_theme_font_size_override("font_size", ROOM_FONT_BODY)
	left.add_child(_room_id_edit)

	left.add_child(_dialog_button(_menu_text("加入房间", "Join Room"), _emit_join_room, "room_second"))

	_room_status = Label.new()
	_room_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_room_status.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_room_status.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_room_status.add_theme_color_override("font_color", Color("7a5210"))
	_room_status.add_theme_font_size_override("font_size", ROOM_FONT_HINT)
	left.add_child(_room_status)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 16)
	body.add_child(right)

	var list_title := Label.new()
	list_title.text = _menu_text("可加入房间", "Open Rooms")
	list_title.add_theme_font_size_override("font_size", ROOM_FONT_HEAD)
	list_title.add_theme_color_override("font_color", ROOM_SECTION_COLOR)
	right.add_child(list_title)

	_room_scroll = TouchScrollContainer.new()
	_room_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_room_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(_room_scroll)
	_room_list_box = VBoxContainer.new()
	_room_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_room_list_box.add_theme_constant_override("separation", ROOM_ROW_GAP)
	_room_scroll.add_child(_room_list_box)

	_room_empty_box = _room_empty_state()
	_room_empty_box.visible = false
	right.add_child(_room_empty_box)

	column.add_child(_room_footer_row())
	return center

# --- 方案C 的样式与零件 ---------------------------------------------------
#
# 刻意**不**碰 _dialog_button 的默认配色：那个工厂还供给主菜单自己的按钮
# （_add_text_button），改成深色会把羊皮纸菜单一起带进去。房间面板走 variant。
#
# 所有 StyleBox 都来自 GloryTokens.flat_box()，本文件不新增 StyleBoxFlat.new()
# —— procedural_ui_ratchet 盯的就是这个计数（当前 4 Button + 1 StyleBox，只许降不许升）。

func _room_panel_box() -> StyleBoxFlat:
	var box := Tokens.flat_box(Tokens.MIST_PANEL, Tokens.MIST_GOLD, 2, ROOM_RADIUS_PANEL)
	box.set_content_margin_all(ROOM_PAD)
	# 设计稿的毛玻璃（BACKGROUND_BLUR）Godot 4 没有内置（方案C §五.2），用大范围柔和
	# 阴影近似。稿子写 y=20 / size=60，那是 2× 设计稿像素，折半成 y=10 / size=30；
	# 这里再收到 24，避免大面积阴影在低端机上采样过重。
	box.shadow_color = Color(0, 0, 0, 0.6)
	box.shadow_size = 24
	box.shadow_offset = Vector2(0, 10)
	return box

func _room_divider() -> Control:
	# 1px 金 @40% 细分隔线。用 Panel + 扁 StyleBox 画，不用 ColorRect ——
	# modal_lifecycle_check 断言 _build_room_panel 的函数体里不得出现 ColorRect.new()
	# （那是「面板自建 dim」的痕迹，会和 ModalStack 的 backdrop 叠成两层黑）。
	# 11.11：带叶子的金线（羊皮纸部件），不是 ColorRect（理由见上）
	return Kit.separator(24.0)

func _room_title_row() -> Control:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, ROOM_TITLE_ROW_H)
	row.add_theme_constant_override("separation", 16)
	var title_slot := HBoxContainer.new()
	title_slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_slot.add_child(Kit.title_banner(_menu_text("自定义房间", "Custom Room"), 62.0, 24))
	row.add_child(title_slot)
	row.add_child(_dialog_button(_menu_text("刷新", "Refresh"), _emit_room_list, "room_ghost_gold"))
	return row

func _room_footer_row() -> Control:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, ROOM_BUTTON_H)
	row.add_child(_dialog_button(_menu_text("关闭", "Close"), _close_room_panel, "room_ghost"))
	return row

func _room_input_box(focused: bool) -> StyleBoxFlat:
	var edge := Tokens.MIST_GOLD if focused else Tokens.MIST_LINE_GOLD
	var box := Tokens.flat_box(Tokens.MIST_INPUT_BG, edge, 2, ROOM_RADIUS)
	box.set_content_margin_all(14)
	return box

func _room_label(text: String, size_px: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", size_px)
	label.add_theme_color_override("font_color", color)
	return label

# 空列表态：铺满列表区的圆角块 + 居中「图标 + 文案」。
# 图标**不引入新素材** —— 稿子 §五.3 明确要求不要为这套 UI 临时加资源（会牵动
# --import 与已导出 EXE/APK 重导）。这里用「圆角圆环 + 45° 短条」拼一个放大镜：
# StyleBoxFlat 的圆角给到半径值就是正圆，所以 26×26 + radius 13 + 2px 描边 = 圆环。
func _room_empty_state() -> Control:
	var box := PanelContainer.new()
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	var column := VBoxContainer.new()
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", 12)
	box.add_child(column)
	column.add_child(_room_empty_icon())
	var hint := _room_label(_menu_text("目前没有可加入房间", "No open rooms"),
		ROOM_FONT_BODY, Kit.INK_SOFT)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(hint)
	return box

func _room_empty_icon() -> Control:
	# 11.11：用羊皮纸部件里的放大镜图标（原来用两个 Panel 拼）
	var icon := TextureRect.new()
	icon.texture = Kit.icon("search")
	icon.custom_minimum_size = Vector2(ROOM_ICON_SIZE * 1.6, ROOM_ICON_SIZE * 1.6)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.modulate = Color(1, 1, 1, 0.85)
	return icon

# 房间行。三态（常态 / 悬停 / 满员）在稿子里是「底色透明度 + 描边 + 人数颜色」三处
# 同时变，所以三处一起给：底色与描边走 stylebox，人数颜色靠 mouse_entered/exited 切。
# ★ 满员行 `disabled = true`（稿子 §四.5 的建议）：榜单里已经知道满员的房间不该还能点。
#   服务端的 room_full 仍然守得住，而且「列表发出后才满上」那条路照样会走到
#   show_room_error("room_full")，不是把反馈路径删掉。
func _room_row(room_id: int, players: int, max_players: int, full: bool) -> Button:
	var row := _dialog_button("", func(rid := room_id): team_room_join_requested.emit(rid),
		"room_row_full" if full else "room_row")
	row.custom_minimum_size = Vector2(0, ROOM_ROW_H)
	var line := HBoxContainer.new()
	line.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	line.offset_left = 30
	line.offset_right = -32
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(line)
	var name_label := _room_label(_menu_text("房间 %d", "Room %d") % room_id,
		ROOM_FONT_BODY, Kit.INK_SOFT if full else Kit.INK)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(name_label)
	var count_label := _room_label("%d/%d" % [players, max_players],
		ROOM_FONT_BODY, Kit.INK_SOFT)
	line.add_child(count_label)
	if full:
		row.disabled = true
		return row
	count_label.add_theme_color_override("font_color", Kit.INK_SOFT)
	row.mouse_entered.connect(func() -> void:
		count_label.add_theme_color_override("font_color", ROOM_SECTION_COLOR))
	row.mouse_exited.connect(func() -> void:
		count_label.add_theme_color_override("font_color", Kit.INK_SOFT))
	return row

func show_connecting() -> void:
	if _net_status != null:
		_net_status.text = ""
		_net_status.hide()

func show_connection_error(msg: String) -> void:
	if _net_status != null:
		_net_status.text = ""
		_net_status.hide()
	# Explicit room operations still report errors inside their own dialog.
	if _room_status != null:
		_room_status.text = "" if "token_unknown" in msg else msg

func show_public_token(token_id: String) -> void:
	if _token_label != null:
		_token_label.text = _menu_text("Token ID：", "Token ID: ") + token_id
	if _token_id_edit != null:
		_token_id_edit.text = token_id
	if _room_status != null:
		_room_status.text = _menu_text("Token ID 已生成", "Token ID generated")

func show_room_list(rooms: Array) -> void:
	if _room_list_box == null:
		return
	for child in _room_list_box.get_children():
		# 只 queue_free 的话旧行要到帧末才真离树，同一帧里新旧两套会并存 ——
		# 先 remove_child 摘出去，刷新的当帧列表就只剩新内容（同 SettingsScreen._build）。
		_room_list_box.remove_child(child)
		child.queue_free()
	var empty := rooms.is_empty()
	if _room_scroll != null:
		_room_scroll.visible = not empty
	if _room_empty_box != null:
		_room_empty_box.visible = empty
	if empty:
		return
	for entry in rooms:
		var d := entry as Dictionary
		var id := int(d.get("id", 0))
		var players := int(d.get("players", 0))
		var max_players := int(d.get("max", 6))
		var full := max_players > 0 and players >= max_players
		_room_list_box.add_child(_room_row(id, players, max_players, full))

# 只能观战的房间（满员 / 已开局 / 匹配房），接在能加入的房间后面。
# 服务器在同一条回复里给两类，NetworkService 拆成两个信号：show_room_list 先清空并画能加入的，
# 这里紧接着补上观战行 —— 所以这里不清空，只追加。
func show_spectate_rooms(rooms: Array) -> void:
	if _room_list_box == null or rooms.is_empty():
		return
	if _room_scroll != null:
		_room_scroll.visible = true
	if _room_empty_box != null:
		_room_empty_box.visible = false
	for entry in rooms:
		var d := entry as Dictionary
		_room_list_box.add_child(_spectate_row(int(d.get("id", 0)), int(d.get("players", 0)),
			int(d.get("max", 6)), int(d.get("spectators", 0))))

func _spectate_row(room_id: int, players: int, max_players: int, spectators: int) -> Button:
	var row := _dialog_button("", func(rid := room_id): team_room_spectate_requested.emit(rid), "room_row")
	row.name = "spectate_row_%d" % room_id
	row.custom_minimum_size = Vector2(0, ROOM_ROW_H)
	var line := HBoxContainer.new()
	line.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	line.offset_left = 30
	line.offset_right = -32
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(line)
	var name_label := _room_label(_menu_text("房间 %d", "Room %d") % room_id, ROOM_FONT_BODY, Kit.INK)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(name_label)
	line.add_child(_room_label("%d/%d" % [players, max_players], ROOM_FONT_BODY, Kit.INK_SOFT))
	var full := spectators >= 10
	var spectate_label := _room_label("  " + _menu_text("观战 %d/10", "Spectate %d/10") % spectators,
		ROOM_FONT_BODY, Kit.INK_SOFT if full else ROOM_SECTION_COLOR)
	line.add_child(spectate_label)
	# 观战席满了：同满员房间那一行的样子，点不了（服务器也会拒 spectate_full）。
	if full:
		row.disabled = true
	return row

func show_room_error(reason: String) -> void:
	if _room_status == null:
		return
	_room_status.text = _room_error_text(reason, true)


# 加入房间被战斗服务器拒绝（Main._on_team_room_action_failed 在加入动作进行中时调它）。
#
# 🔴 从邀请、好友列表点「加入」时，「自定房间」面板**没开**，_room_status 是 null。
# 以前只走 show_room_error，原因直接丢掉，加入开头 show_connecting() 写上的「连接中…」
# 也一直挂着 —— 玩家看到的就是「点了立即参与，一直连接中」（9.28 反馈第 3 条的真正原因）。
# 所以先收回「连接中…」；面板开着就写进面板，没开就弹提示。
func show_join_rejected(reason: String) -> void:
	if _net_status != null:
		_net_status.text = ""
	if _room_status != null:
		_room_status.text = _room_error_text(reason, true)
	else:
		GloryToastScript.show_text(_room_error_text(reason, false))


# 房间动作失败时给玩家看的话。面板里外只有 room_not_found 说法不同：
# 面板里的号是玩家自己输的，可能打错了 →「找不到房间」；
# 从邀请 / 好友列表进来的号是真实存在过的房间 →「房间已关闭」。
func _room_error_text(reason: String, typed_by_player: bool) -> String:
	match reason:
		"room_not_found":
			if typed_by_player:
				return _menu_text("找不到房间", "Room not found")
			return _menu_text("房间已关闭", "This room has closed")
		"room_started":
			return _menu_text("房间已开局", "This match has already started")
		"seat_busy":
			return _menu_text("原座位正在恢复，请稍后重试", "Your seat is reconnecting. Please retry shortly.")
		"room_full":
			return _menu_text("房间已满", "Room is full")
		"token_id_unknown":
			return _menu_text("没有找到可恢复的 Token ID", "No resumable game for this Token ID")
		"spectate_full":
			return _menu_text("观战人数已满", "The number of spectators is full")
		"spectate_closed":
			return _menu_text("该房间未开放观战", "Spectating is closed for this room")
		"spectate_seated":
			return _menu_text("你正在房间里，先离开才能观战", "Leave your room before spectating")
	# 出战名片的各种失败（领不到、过期、验不过…）对玩家是同一件事。
	# 具体原因在战斗服务器日志里（seat card rejected reason=…），不给玩家看代码。
	if reason.begins_with("card_"):
		return _menu_text("暂时进不了对局，请稍后再试", "Can't join a match right now — try again later")
	return reason

func _emit_join() -> void:
	var address := NetworkConfig.server_host()
	if _address_edit != null:
		address = _address_edit.text.strip_edges()
	if address.is_empty():
		address = NetworkConfig.server_host()
	team_join_requested.emit(address)

func _show_room_overlay() -> void:
	if not await NetworkService.allow_new_match():
		return
	if not is_inside_tree():
		return
	# 去重交给 has()：连点两次「自定房间」不该开出两层。
	if ModalStack.has(ROOM_MODAL_ID):
		return
	var content := _build_room_panel()
	var modal_id := ModalStack.push(content, {
		"id": ROOM_MODAL_ID,
		"owner": self,
		"priority": ROOM_MODAL_PRIORITY,
		# 点外面可以关：这是纯浏览面板，没有未完成的强制选择。
		"dismiss_on_backdrop": true,
	})
	if modal_id.is_empty():
		# content 已被 push 收走，不能再 free，只清引用。
		_room_status = null
		_room_list_box = null
		_room_scroll = null
		_room_empty_box = null
		return
	if _room_status != null:
		_room_status.text = ""
	team_room_list_requested.emit()


func _close_room_panel() -> void:
	ModalStack.pop(ROOM_MODAL_ID)

func _emit_generate_token() -> void:
	public_token_generate_requested.emit()

func _emit_resume_token() -> void:
	var token_id := _token_id_edit.text.strip_edges().to_upper()
	if token_id.is_empty():
		_room_status.text = _menu_text("请先输入 Token ID", "Enter Token ID first")
		return
	public_token_resume_requested.emit(token_id)

func _emit_create_room() -> void:
	team_room_create_requested.emit()

func _emit_join_room() -> void:
	var room_id := int(_room_id_edit.text.strip_edges())
	if room_id <= 0:
		_room_status.text = _menu_text("请输入正确的房间 ID", "Enter a valid Room ID")
		return
	team_room_join_requested.emit(room_id)

func _emit_room_list() -> void:
	team_room_list_requested.emit()

func _emit_offline() -> void:
	team_offline_requested.emit()

func _emit_reconnect() -> void:
	if SaveManager.load_resumable_reconnect().is_empty():
		_apply_saved_match_status("clear", "")
		return
	team_reconnect_requested.emit()

# 「休闲」：进匹配队列（协议 32）。
#
# 先过 allow_new_match —— 上一局还没打完时不该让他去排新的队，
# 同「排位」和「开始游戏」那两条。
func _on_casual() -> void:
	if PlayerProfile.startup_route() == PlayerProfile.STARTUP_TUTORIAL:
		casual_requested.emit()
		return
	if await NetworkService.allow_new_match():
		casual_requested.emit()

# 「排位」：进排位队列（第 5 步起开放）。
#
# ⚠️ **窗口外 / 信誉分不够 / 被禁赛时，拒绝是服务器给的**，不是这里判的 ——
# 客户端改系统时区就能绕过本地判断，而排位是发分的（docs/排位系统设计.md 第二节）。
# 这里照常进队列面板，面板把服务器给的原因显示出来。
func _on_ranked() -> void:
	if await NetworkService.allow_new_match():
		ranked_requested.emit()

# A local token is only a candidate. Show a return action after its current
# server status is confirmed; never reuse the result for a replacement token.
func _apply_saved_match_status(status: String, checked_token: String) -> void:
	var rc := SaveManager.load_resumable_reconnect()
	var can_return := not rc.is_empty() and not checked_token.is_empty() \
		and str(rc.get("token", "")) == checked_token and status in ["lobby", "active"]
	for child in get_children():
		if child is Button and child.pressed.is_connected(_emit_reconnect):
			child.visible = can_return
			if can_return:
				child.text = _menu_text("返回房间", "Back to Room") if status == "lobby" else _menu_text("游戏重连", "Reconnect")

func _refresh_saved_match() -> void:
	while is_inside_tree():
		var rc := SaveManager.load_resumable_reconnect()
		if rc.is_empty():
			_apply_saved_match_status("clear", "")
			return
		var token := str(rc.get("token", ""))
		var status := await NetworkService.check_saved_match()
		if not is_inside_tree():
			return
		_apply_saved_match_status(status, token)
		await get_tree().create_timer(3.0).timeout

func _emit_prep() -> void:
	prep_requested.emit()

func _emit_codex() -> void:
	codex_requested.emit()

func _emit_settings() -> void:
	settings_requested.emit()

# 原来是 Godot 默认 AcceptDialog：系统标题栏、默认灰按钮，和游戏其余部分完全两种风格。
# 主菜单上有 9 个热区都指向它，所以它是玩家最常看到的弹窗（V3 P1-03 迁移清单第 2 项）。
# 固定 request_id 让连点多个热区只出一个框。
func _show_coming_soon() -> void:
	DialogService.info({
		"request_id": "main_menu_coming_soon",
		"owner": self,
		"title": _menu_text("敬请期待", "Coming Soon"),
		"body": _menu_text("这个功能还在开发中。", "This feature is still in development."),
		"confirm_text": _menu_text("知道了", "Got it"),
	})

func _emit_profile() -> void:
	profile_requested.emit()


func _emit_friends() -> void:
	friends_requested.emit()


# 「聊天」按钮：此前是「敬请期待」，批次 C 起进私聊界面（世界频道以后也在那个界面里）。
func _emit_chat() -> void:
	chat_requested.emit()


# ★★ 10.07h 第 6 / 10 条返工：邀请气泡的锚点 —— 左侧「聊天」按钮**右侧中点**的
# 全局屏幕坐标。气泡拿它把自己摆到按钮右边，尖角朝左指向按钮。
#
# 为什么用 `get_global_rect()` 现算而不是给常量：按钮走 `_track` + `_layout()`，
# 位置 = 安全区左边 + 参考坐标 × `_layout_scale`，**随窗口尺寸/刘海安全区变**
# （`_apply_item` 里 edge="left" 那一支）。写死一个屏幕坐标，在 16:9 桌面端对、
# 在带灵动岛的宽屏手机上就跑偏了 —— 而用户报的正是**安卓真机**。
#
# 返回 `Vector2.INF` 表示「按钮现在不可能有锚点」（不在树里 / 还没布局完），
# 由调用方决定回落到哪 —— 这里不替它猜。
func chat_invite_anchor() -> Vector2:
	if _chat_icon == null or not is_instance_valid(_chat_icon) or not _chat_icon.is_inside_tree():
		return Vector2.INF
	var rect := _chat_icon.get_global_rect()
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return Vector2.INF
	return Vector2(rect.end.x, rect.position.y + rect.size.y * 0.5)


func _on_chat_unread_changed(any_unread: bool) -> void:
	if _chat_dot != null and is_instance_valid(_chat_dot):
		_chat_dot.visible = any_unread


# 「公告 / 活动」：此前是「敬请期待」（docs/公告系统设计.md）。
func _emit_announcements() -> void:
	announcements_requested.emit()


func _on_announcements_changed() -> void:
	if _news_dot != null and is_instance_valid(_news_dot):
		_news_dot.visible = AnnouncementService.any_unread()
	_refresh_news_title()


# 「邮件」：此前是「敬请期待」（docs/邮件系统设计.md）。
func _emit_mail() -> void:
	mail_requested.emit()


func _on_mail_changed() -> void:
	if _mail_dot != null and is_instance_valid(_mail_dot):
		_mail_dot.visible = MailService.needs_attention()

# 名牌上的昵称与副行。**不自己拼显示名** —— 只从 AccountManager.display_name 出，
# 那是全仓唯一的拼法。理由：player_name 不唯一（database/001 的设计），
# 任何一处只显示昵称的地方，改名冒充就成立。
func _refresh_profile_plate() -> void:
	if _profile_name_label == null or not is_instance_valid(_profile_name_label):
		return
	var profile: Dictionary = AccountManager.profile
	var show_xp := not profile.is_empty() and _account_level > 0
	_profile_xp_bar.visible = show_xp
	_profile_sub_label.add_theme_color_override("font_color", Color("f8fcff") if show_xp else INK_TEXT)
	_profile_sub_label.add_theme_color_override("font_outline_color", Color("14273e") if show_xp else INK_OUTLINE)
	if profile.is_empty():
		# 还没登录 / 还没拉到资料。**不放假名字** —— 玩家看到一个陌生昵称
		# 比看到一条横线更糟，而且那正是这次要消灭的东西。
		# 头像同理：宁可空着露出框里的深棕底，也不要先画一个默认头像再跳变。
		_profile_name_label.text = _menu_text("玩家", "Player")
		_profile_sub_label.text = "—"
		if _profile_portrait != null and is_instance_valid(_profile_portrait):
			_profile_portrait.texture = null
		_profile_base_frame.visible = true
		_profile_portrait.visible = true
		_profile_frame_overlay.visible = false
		return
	if _profile_portrait != null and is_instance_valid(_profile_portrait):
		_profile_portrait.texture = AvatarCatalog.texture_for(str(profile.get("avatar", "")))
		var frame_id := AvatarCatalog.id_from_value(str(profile.get("avatar_frame", "")))
		var custom_frame := not frame_id.is_empty() and frame_id != "frame_default"
		# ★ 10.02 三轮：头像**永远可见、永远是 123**，默认框与自定义框只是换外圈。
		#   原先 custom_frame 时把头像换成那个 78x78 的副本 ⇒ 同一张立绘戴框就变小。
		_profile_portrait.visible = true
		_profile_base_frame.visible = not custom_frame
		_profile_frame_overlay.visible = custom_frame
		if custom_frame:
			_profile_frame_art.texture = AvatarCatalog.frame_texture_for(
				str(profile.get("avatar_frame", "")))
			_place_profile_frame(frame_id)
	_profile_xp_fill.anchor_right = clampf(float(_account_xp_progress) / maxf(1.0, _account_xp_required), 0.0, 1.0) if _account_xp_required > 0 else 1.0
	# 10.04 bug 文档第 5 条：大厅左上角资料卡只显示昵称（隐藏 #好友码）。
	_profile_name_label.text = AccountManager.display_name(
		str(profile.get("player_name", "")), str(profile.get("friend_code", "")), false)
	if _account_level > 0:
		_profile_sub_label.text = (_menu_text("等级%d %d/%d", "Level %d %d/%d") % [_account_level, _account_xp_progress, _account_xp_required]) if _account_xp_required > 0 else (_menu_text("等级%d 已满级", "Level %d MAX") % _account_level)
	else:
		var days := int(profile.get("days_since_created", 1))
		_profile_sub_label.text = _menu_text("第 %d 天" % days, "Day %d" % days)


# 目标内孔直径 = **默认圆盘的内孔直径**（圆盘盒 180 × 默认框内孔占比 0.6271 ≈ 112.9）。
#
# ★ 为什么不是「头像画出来的直径（123）」：内孔只要 ≤ 头像就不会露缝，而取「默认圆盘的内孔」
#   有三个好处：① 与玩家已经认可的默认框**逐像素同款**（内孔直径、圆心都对齐，见
#   `frame_box_origin`）；② 比内孔=123 小一圈 ⇒ 框的绘制尺寸也小一圈，最厚的炽焰之心
#   只需 197 宽（内孔=123 时要 219，左边缘会出屏）；③ 头像被内孔盖住的那 5px 是
#   默认圆盘本来就有的观感，不是新引入的。
#
# ★ 内孔必须 **≤ 头像**，否则头像外面会留一圈背景缝（框画在头像下面，缝里是背景）。
#   这条由门禁 frame_hole_check 的 `*_no_gap_*` 与 seat_frame_check 的
#   `hole_not_larger_than_avatar` 两处一起锁。
#
# ★ 这条是渲染 + 像素测量的结论：`其他/work/_qa_1002c/`（7 种框 × 房间/大厅 ×
#   有头像/无头像/无框三种渲染）。
func _profile_hole_target() -> float:
	return PROFILE_DISC_BOX.x * AvatarCatalog.default_disc_hole_fraction()


# 把自定义框的容器改成「按内孔反推」的尺寸与落点：**内孔**压在圆盘中心上。
# 不是「盒心压在圆盘中心上」—— 每个框的内孔在图里的位置都不一样（偏上 2~3%），
# 少这一步就会在头像外露一圈背景缝（三轮门禁 frame_hole_check 抓到的就是它）。
# 框可能比画布还高/宽（最厚的炽焰之心约 199x250）⇒ 顶部会被画布裁掉，这是允许的。
func _place_profile_frame(frame_id: String) -> void:
	if _profile_frame_overlay == null or not is_instance_valid(_profile_frame_overlay):
		return
	var drawn := AvatarCatalog.frame_drawn_size(frame_id, _profile_hole_target())
	if drawn.x <= 0.0:
		return
	for placement in _placed:
		if placement.node == _profile_frame_overlay:
			placement.pos = AvatarCatalog.frame_box_origin(
				frame_id, _profile_hole_target(), PROFILE_DISC_CENTER)
			placement.size = drawn
			_apply_item(placement)
			return

func _emit_shop() -> void:
	shop_requested.emit()

func _emit_bag() -> void:
	bag_requested.emit()

# 拉余额。失败就**保持 "—"**，不要退回 0：0 是个看起来正常的错值。
func _refresh_progression() -> void:
	var response: Dictionary = await AccountManager.fetch_progression()
	if not is_inside_tree() or int(response.get("code", 0)) != 200:
		return
	var state: Dictionary = response.get("body", {})
	_apply_profile_progression(state)
	var pending: Array = state.get("unseen_levels", [])
	if not PlayerProfile.tutorial_followup_step.is_empty():
		return
	if pending.is_empty() or ModalStack.has(LEVEL_REWARD_MODAL_ID):
		return
	var rewards: Array = []
	var seen: Array[int] = []
	for raw in state.get("rewards", []):
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var reward: Dictionary = raw
		var level := int(reward.get("level", 0))
		if not pending.has(level):
			continue
		seen.append(level)
		rewards.append(reward)
	if seen.is_empty():
		return
	var dialog := LevelUpRewardDialog.new() as Control
	dialog.configure(seen, rewards)
	dialog.claimed.connect(func(go_prep: bool) -> void:
		ModalStack.pop(LEVEL_REWARD_MODAL_ID)
		AccountManager.mark_progression_seen(seen)
		if go_prep:
			prep_requested.emit())
	ModalStack.push(dialog, {"id": LEVEL_REWARD_MODAL_ID, "owner": self,
		"priority": 100, "dismiss_on_backdrop": false, "persistent": true})


func _refresh_wallet() -> void:
	if not AccountManager.is_logged_in():
		return
	var result: Dictionary = await AccountManager.fetch_wallet()
	if not is_inside_tree() or _coin_label == null:
		return
	if int(result.get("code", 0)) / 100 != 2:
		return
	var body: Dictionary = result.get("body", {})
	_coin_label.text = Currency.comma(int(body.get("coin", 0)))
	_diamond_label.text = Currency.comma(int(body.get("diamond", 0)))


# 只看本机就能定（access token 里的 is_anonymous），不发请求。
# 这台设备绑不了（电脑版、没有 Google 服务的手机）就不亮：亮了点进去也没有按钮可按。
func _refresh_guest_dot() -> void:
	if _profile_dot == null or not is_instance_valid(_profile_dot):
		return
	_profile_dot.visible = AccountManager.is_logged_in() and AccountManager.is_guest() \
		and SignInBridge.any_available()


func _refresh_login_dot() -> void:
	if not AccountManager.is_logged_in():
		return
	var result: Dictionary = await AccountManager.fetch_seven_day_login()
	if not is_inside_tree() or _shop_dot == null:
		return
	if int(result.get("code", 0)) / 100 == 2:
		_shop_dot.visible = bool((result.get("body", {}) as Dictionary).get("claimable_today", false))

# 9.27：公告图标内显示最新公告标题（含【系统】/【活动】等分类标签）。
func _refresh_news_title() -> void:
	if _news_title == null or not is_instance_valid(_news_title):
		return
	var items: Array = AnnouncementService.items()
	if items.is_empty():
		_news_title.visible = false
		return
	var latest: Dictionary = items[0] as Dictionary
	var title := AnnouncementText.row_text(latest, _english())
	if title.is_empty():
		_news_title.visible = false
		return
	_news_title.text = title
	_news_title.visible = true

# 商店入口轮播三只手绘宠物；它只是陈列，不参与商品价格或归属判定。
func _refresh_shop_preview() -> void:
	if _shop_preview == null or not is_instance_valid(_shop_preview):
		return
	# 视觉回归截图固定在第一张，避免定时器让截图抖动。
	if has_meta("ui_capture_fixture"):
		return
	_shop_preview_timer = Timer.new()
	_shop_preview_timer.name = "ShopPetRotation"
	_shop_preview_timer.wait_time = 3.0
	_shop_preview_timer.timeout.connect(_next_shop_preview)
	add_child(_shop_preview_timer)
	_shop_preview_timer.start()


func _show_shop_fallback() -> void:
	_shop_preview_index = 0
	_set_shop_preview(str(SHOP_PREVIEW_PETS[_shop_preview_index]))


func _next_shop_preview() -> void:
	_shop_preview_index = (_shop_preview_index + 1) % SHOP_PREVIEW_PETS.size()
	_set_shop_preview(str(SHOP_PREVIEW_PETS[_shop_preview_index]))


func _set_shop_preview(pet_id: String) -> void:
	if _shop_preview == null:
		return
	_clear_shop_preview()
	var box := _shop_preview.size
	if box.x <= 0 or box.y <= 0:
		box = Vector2(210, 132)
	# CenterContainer 保持手绘原画比例，不拉伸。
	var preview_size := Vector2(box.x * SHOP_PREVIEW_SCALE, box.y * SHOP_PREVIEW_SCALE)
	var stage := Panel.new()
	stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stage.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stage.add_theme_stylebox_override("panel", Tokens.flat_box(
		Tokens.MIST_ROW_IDLE, Tokens.MIST_LINE_GOLD, 1, 5))
	_shop_preview.add_child(stage)
	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stage.add_child(center)

	var preview: Control = PetPreview.build_illustration(pet_id, preview_size, false)
	if preview == null:
		return
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview.custom_minimum_size = preview_size
	center.add_child(preview)
	_shop_preview.visible = true


func _clear_shop_preview() -> void:
	if _shop_preview == null:
		return
	_shop_preview.visible = false
	for child in _shop_preview.get_children():
		_shop_preview.remove_child(child)
		child.queue_free()


func _english() -> bool:
	return TranslationServer.get_locale().begins_with("en")


# 朋友申请的轮询间隔。与 AccountManager 的 presence 心跳同拍（10 秒）——
# 朋友申请**没有实时推送**（socket 只推私聊与公告），轮询是唯一的近实时手段。
const FRIEND_REQUEST_POLL_SEC := 10.0

var _friend_request_poll: Timer
# 同一时刻只允许一趟在飞：弱网下会堆出一串在途请求，回来的顺序还是乱的。
var _friend_request_busy := false

# 轮询只在主菜单活着时存在（跟着页面一起被 Main._clear() 释放），不常驻。
func _start_friend_request_poll() -> void:
	_friend_request_poll = Timer.new()
	_friend_request_poll.name = "FriendRequestPoll"
	_friend_request_poll.wait_time = FRIEND_REQUEST_POLL_SEC
	_friend_request_poll.autostart = false
	_friend_request_poll.timeout.connect(_refresh_friend_requests)
	add_child(_friend_request_poll)
	_friend_request_poll.start()

# 取数单独一层：无头门禁靠替换它来喂固定响应（同 ProfileScreen._send_friend_request
# 的先例，friends08_check 就是那样打的桩）。真实现只是转调 AccountManager。
func _fetch_friend_requests() -> Dictionary:
	return await AccountManager.fetch_friend_requests()

# 9.17 反馈第 6 条：朋友申请红点。
#
# 红点跟 AccountManager 那个**已读集合**走（状态只有一份，同聊天红点的理由）：
# 「有没有未读申请」由 has_unread_friend_requests() 判，而点进朋友界面时
# FriendsScreen 会调 mark_friend_requests_seen() —— 回到主菜单这次重拉就
# 自然不再亮。所以这里不需要自己记「玩家点过没有」。
#
# 每次进主菜单都拉一次：朋友申请没有实时推送，主菜单是唯一稳定的轮询点。
func _refresh_friend_requests() -> void:
	if _friend_request_busy:
		return
	if not AccountManager.is_logged_in():
		return
	_friend_request_busy = true
	var result: Dictionary = await _fetch_friend_requests()
	_friend_request_busy = false
	if not is_inside_tree():
		return
	if int(result.get("code", 0)) / 100 != 2:
		# 拉不到就保持现状：宁可留着上一次的红点，也不要在网络抖一下时
		# 把这个「有人申请加你」的提示抹掉。
		return
	var body: Dictionary = result.get("body", {})
	var incoming: Array = body.get("incoming", [])
	if _friends_dot != null and is_instance_valid(_friends_dot):
		_friends_dot.visible = AccountManager.has_unread_friend_requests(incoming)
	_alert_new_friend_requests(incoming)

# 新申请到的时候响一声（与「聊天新信息」共用同一条 cue，素材就是一条）。
#
# **去重放在这里，不只靠 SfxService 的 10 秒节流。** 节流管的是「10 秒内只响
# 一次」，管不了「同一份申请每次回主菜单都响一遍」；而本函数每次进主菜单都跑。
# 所以这里按 AccountManager 的申请键记账：同一个键在本次进程内只提醒一次，
# 之后新到的申请是新键，照常提醒（与聊天音共用一个 10 秒窗口）。
#
# 用 static：主菜单每次都是**新建**的实例（Main._clear() 会 free 掉旧的），
# 记在实例字段上等于每次回主菜单就清零，去重会完全失效。
static var _alerted_request_keys: Dictionary = {}

func _alert_new_friend_requests(incoming: Array) -> void:
	for entry in incoming:
		if not (entry is Dictionary):
			continue
		var key := AccountManager.friend_request_key(entry)
		if key.is_empty() or AccountManager.friend_request_seen.has(key):
			continue
		if _alerted_request_keys.has(key):
			continue
		_alerted_request_keys[key] = true
		SfxService.play(SfxService.CUE_CHAT_ALERT)
		# 一次采样最多一声：同时收到三份申请不该连响三下。
		return

# 首次进主菜单时拉一次资料，之后吃 AccountManager 的缓存。
# 每次回主菜单都发一次请求既慢又费流量，而这些字段只有玩家自己能改。
func _ensure_profile_loaded() -> void:
	if not AccountManager.profile.is_empty():
		return
	if not AccountManager.is_logged_in():
		return
	await AccountManager.fetch_my_profile()

func _menu_text(zh: String, en: String) -> String:
	return en if TranslationServer.get_locale().begins_with("en") else zh

func _layout() -> void:
	var viewport_size := get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	# 按钮和字放进安全区（iPhone 横屏的灵动岛 / 圆角 / 手势条让出来，ui/services/SafeArea.gd）；
	# 背景和上下装饰带照样铺满整屏。没有刘海时 safe 就是整个视口，和以前一模一样。
	var safe := SafeArea.rect()
	var scale := minf(safe.size.x / REF_SIZE.x, safe.size.y / REF_SIZE.y)
	var origin := safe.position + (safe.size - REF_SIZE * scale) * 0.5
	_layout_scale = scale
	_layout_origin = origin
	_layout_safe = safe
	if _debug_layer != null:
		_debug_layer.queue_redraw()
	for band in _screen_bands:
		var rect := band.node as Control
		var height := float(band.height) * scale
		rect.position = Vector2(0.0, viewport_size.y - height if bool(band.from_bottom) else float(band.y) * scale)
		rect.size = Vector2(viewport_size.x, height)
	for item in _placed:
		_apply_item(item)


# 把一个登记过的元素落到屏幕上。**单独抽出来**是为了让「资料卡上的自定义框」
# 能在资料变动时就地换尺寸（`_place_profile_frame`）—— 只改 `_placed` 不落到节点，
# 框会停在数据里的新尺寸、屏幕上还是旧的（10.01 第 4 条那个坑）。
# 用到的 safe / scale / origin 都是 `_layout()` 存下来的，所以它只能在 `_layout()`
# 跑过之后用；`_refresh_profile_plate()` 都发生在 `_ready()` 的 `_layout()` 之后。
func _apply_item(item: Dictionary) -> void:
	var node := item.node as Control
	if node == null or not is_instance_valid(node):
		return
	var safe := _layout_safe
	var scale := _layout_scale
	var origin := _layout_origin
	var pos := item.pos as Vector2
	var size := item.size as Vector2
	# edge=left/right 的元素锚定到安全区的左右边（消除宽屏下的左右留白，又不钻进灵动岛）；
	# 其余保持 16:9 画布居中缩放。垂直方向一律跟随居中画布。
	var x: float
	match str(item.get("edge", "")):
		"left":
			x = safe.position.x + pos.x * scale
		"right":
			x = safe.end.x - (REF_SIZE.x - pos.x) * scale
		_:
			x = origin.x + pos.x * scale
	node.position = Vector2(x, origin.y + pos.y * scale)
	item.base_pos = node.position
	if node is Button:
		# 整体缩放按钮：文字、内边距、边框和点击区域使用同一比例。
		# 只缩 size 会让固定字号挤满底板，且被最小尺寸反向撑开。
		node.size = size
		node.scale = Vector2.ONE * scale
	else:
		node.size = size * scale
	if node is Label:
		node.add_theme_font_size_override("font_size", maxi(10, int(item.font_size * scale)))

func _add_currency_bar(currency: String, pos: Vector2, cb: Callable) -> Label:
	var size := Vector2(240, 65)
	var bar := _add_texture(TEX_SCROLL_BAR, pos, size)
	var icon := _add_texture(TEX_DIAMOND_ICON if currency == "diamond" else TEX_COIN_ICON,
		pos + Vector2(16, 8), Vector2(50, 50))
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var amount := _add_label("—", pos + Vector2(70, 0), Vector2(118, 60), 24)
	_ink(amount)
	var plus := _add_label("+", pos + Vector2(192, 0), Vector2(32, 60), 34)
	_ink(plus, true)
	var hit: Button = _add_hit(pos, size, cb) if cb.is_valid() else null
	_anim_group([bar, icon, amount, plus], hit, 0, 0.05)
	return amount


# 羊皮纸底上的深棕字。big=true 给主按钮那种大字加粗一点描边。
func _ink(label: Label, big := false) -> void:
	label.add_theme_color_override("font_color", INK_TEXT)
	label.add_theme_color_override("font_outline_color", INK_OUTLINE)
	label.add_theme_constant_override("outline_size", 6 if big else 4)


# 未读红点：初值不亮，显隐由各自的服务决定。
func _add_dot(pos: Vector2, edge: String) -> Label:
	var dot := _add_label("●", pos, Vector2(32, 32), 26, edge)
	dot.add_theme_color_override("font_color", Tokens.UNREAD_DOT)
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dot.visible = false
	return dot


# 离线自测 / 游戏重连：铺一条空白卷轴当底，文字仍是 Button 自己的 text。
func _scroll_skin(btn: Button, font_size: int) -> void:
	for state in ["normal", "hover", "pressed", "disabled"]:
		var box := StyleBoxTexture.new()
		box.texture = TEX_SCROLL_BAR
		match state:
			"hover":
				box.modulate_color = Color(1.06, 1.06, 1.0)
			"pressed":
				box.modulate_color = Color(0.86, 0.82, 0.74)
		btn.add_theme_stylebox_override(state, box)
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		btn.add_theme_color_override(state, INK_TEXT)
	btn.add_theme_color_override("font_outline_color", INK_OUTLINE)
	btn.add_theme_constant_override("outline_size", 4)
	btn.add_theme_font_size_override("font_size", font_size)


func _profile_ring_size() -> Vector2:
	var w := _profile_hole_target() / PROFILE_RING_HOLE_FRAC
	return Vector2(w, w * float(TEX_PROFILE_AVATAR.get_height()) / float(TEX_PROFILE_AVATAR.get_width()))


func _solid_texture(color: Color) -> Texture2D:
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(color)
	return ImageTexture.create_from_image(img)


# ── 按钮动效（11.10）────────────────────────────────────────────────────
# 一组 = 一个按钮的所有图层（底图、字、红点……），共用一个缩放中心（热区中心）。
#   进场：按 delay 依次从 0.6 弹到 1（TRANS_BACK 那种过冲），同时淡入
#   悬停 1.05、按下 0.93，松手用弹簧回弹（带一点过冲）
#   idle_float：常驻上下浮动（只给排位赛）
# 只改 scale / pivot / position 偏移 / modulate.a，不碰 _placed 里的布局数据；
# 布局刷新后 _apply_item 会把 base_pos 记下来，这里每帧在它上面叠偏移。
const ANIM_ENTER_TIME := 0.42
const ANIM_HOVER_SCALE := 1.05
const ANIM_PRESS_SCALE := 0.93
const ANIM_SPRING_K := 420.0
const ANIM_SPRING_DAMP := 16.0
const ANIM_FLOAT_PX := 4.0
const ANIM_FLOAT_HZ := 0.55
var _anim_groups: Array[Dictionary] = []
var _anim_time := 0.0

func _anim_group(nodes: Array, hit: Button, _row: int, delay: float, idle_float := false) -> void:
	var items: Array = []
	for node in nodes:
		for placement in _placed:
			if placement.node == node:
				items.append(placement)
				break
	if items.is_empty():
		return
	# 缩放中心：有热区用热区中心，没有就用第一个图层的中心。
	var ref: Dictionary = items[0]
	if hit != null:
		for placement in _placed:
			if placement.node == hit:
				ref = placement
				break
	var group := {
		"items": items, "ref": ref, "delay": delay, "idle": idle_float,
		"s": 1.0, "v": 0.0, "hover": false, "down": false,
	}
	_anim_groups.append(group)
	for item in items:
		var node := item.node as CanvasItem
		node.modulate.a = 0.0
	if hit != null:
		hit.mouse_entered.connect(func() -> void: group.hover = true)
		hit.mouse_exited.connect(func() -> void:
			group.hover = false
			group.down = false)
		hit.button_down.connect(func() -> void: group.down = true)
		hit.button_up.connect(func() -> void:
			group.down = false
			# 松手给一个往外的速度，弹回来时有过冲
			group.v += 3.2)
	set_process(true)


func _process(delta: float) -> void:
	if _anim_groups.is_empty():
		return
	_anim_time += delta
	for group in _anim_groups:
		var target := ANIM_PRESS_SCALE if group.down else (ANIM_HOVER_SCALE if group.hover else 1.0)
		var s: float = group.s
		var v: float = group.v
		v += (target - s) * ANIM_SPRING_K * delta
		v *= exp(-ANIM_SPRING_DAMP * delta)
		s += v * delta
		group.s = s
		group.v = v
		var e := clampf((_anim_time - float(group.delay)) / ANIM_ENTER_TIME, 0.0, 1.0)
		var enter_scale := lerpf(0.6, 1.0, _ease_out_back(e))
		var alpha := clampf(e * 2.5, 0.0, 1.0)
		var dy := 0.0
		if group.idle and e >= 1.0:
			dy = sin((_anim_time - float(group.delay)) * TAU * ANIM_FLOAT_HZ) * ANIM_FLOAT_PX
		_apply_group(group, s * enter_scale, alpha, dy)


func _apply_group(group: Dictionary, s: float, alpha: float, dy: float) -> void:
	var ref: Dictionary = group.ref
	var ref_node := ref.node as Control
	if ref_node == null or not is_instance_valid(ref_node) or not ref.has("base_pos"):
		return
	var ref_size: Vector2 = (ref.size as Vector2) * _layout_scale
	var center: Vector2 = (ref.base_pos as Vector2) + ref_size * 0.5
	for item in group.items:
		var node := item.node as Control
		if node == null or not is_instance_valid(node) or not item.has("base_pos"):
			continue
		var base: Vector2 = item.base_pos
		node.pivot_offset = center - base
		node.scale = Vector2.ONE * s
		node.position = base + Vector2(0.0, dy * _layout_scale)
		node.modulate.a = alpha


static func _ease_out_back(x: float) -> float:
	const C1 := 1.70158
	const C3 := C1 + 1.0
	return 1.0 + C3 * pow(x - 1.0, 3.0) + C1 * pow(x - 1.0, 2.0)

func _add_texture(texture: Texture2D, pos: Vector2, size: Vector2, edge: String = "") -> TextureRect:
	var rect := TextureRect.new()
	rect.texture = texture
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
	add_child(rect)
	_track(rect, pos, size, 0, edge)
	return rect

# 圆形头像。用一个画满圆角的 Panel 当遮罩，clip_children 只画被它盖住的部分 ——
# 比写 shader 轻，也不用等美术出新素材。
#
# 位置与直径是从 profile_avatar.png 量出来的：图 850x825，内圆直径 532px、
# 圆心 (423, 399)，换算到参考画布是直径约 113、圆心 (107.6, 96.6)。
# 这里取 104 略小一圈，免得压到金色圆环。**换了那张框图就要重新量。**
func _add_round_portrait(pos: Vector2, size: Vector2, edge: String = "") -> TextureRect:
	var mask := Panel.new()
	mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 只画孩子、不画自己，用自己的形状当裁剪蒙版。
	mask.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	var circle := StyleBoxFlat.new()
	circle.bg_color = Color.WHITE
	# 圆角给到边长，引擎会自动收敛成正圆。
	circle.set_corner_radius_all(int(maxf(size.x, size.y)))
	mask.add_theme_stylebox_override("panel", circle)
	add_child(mask)

	var portrait := TextureRect.new()
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	# COVERED 而不是 KEEP_ASPECT：立绘不是正方形，留边会在圆里露出缺口。
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	portrait.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mask.add_child(portrait)

	_track(mask, pos, size, 0, edge)
	return portrait

func _add_rect(color: Color, pos: Vector2, size: Vector2) -> ColorRect:
	var rect := ColorRect.new()
	rect.color = color
	add_child(rect)
	_track(rect, pos, size)
	return rect

func _add_screen_band(color: Color, y: float, height: float, from_bottom: bool) -> ColorRect:
	var rect := ColorRect.new()
	rect.color = color
	add_child(rect)
	_screen_bands.append({"node": rect, "y": y, "height": height, "from_bottom": from_bottom})
	return rect

func _add_label(text: String, pos: Vector2, size: Vector2, font_size: int, edge: String = "") -> Label:
	var label := Label.new()
	label.text = text
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", Color(1.0, 0.92, 0.63))
	label.add_theme_color_override("font_outline_color", Color(0.12, 0.07, 0.025, 0.95))
	label.add_theme_constant_override("outline_size", 5)
	label.add_theme_font_size_override("font_size", font_size)
	add_child(label)
	_track(label, pos, size, font_size, edge)
	return label


# 9.27：透明容器，用于在图标内部叠加动态内容（商店缩略图）。本身不绘制、不吃输入。
func _add_container(pos: Vector2, size: Vector2, edge: String = "") -> Control:
	var container := Control.new()
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(container)
	_track(container, pos, size, 0, edge)
	return container

func _add_pill(text: String, pos: Vector2, size: Vector2) -> void:
	# 四角同值，等价于原来逐角赋的 size.y * 0.5（药丸形）。
	var bg := Tokens.flat_box(Tokens.PARCHMENT_SOFT, Tokens.PARCHMENT_EDGE_SOFT,
		2, int(size.y * 0.5))
	var panel := Panel.new()
	panel.add_theme_stylebox_override("panel", bg)
	add_child(panel)
	_track(panel, pos, size)
	_add_label(text, pos, size, 22)

func _add_hit(pos: Vector2, size: Vector2, cb: Callable, edge: String = "") -> Button:
	var btn := Button.new()
	btn.flat = true
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.modulate = Color(1, 1, 1, 0)
	btn.pressed.connect(cb)
	btn.name = "hit_%s" % cb.get_method()
	add_child(btn)
	_track(btn, pos, size, 0, edge)
	return btn

func _add_text_button(text: String, pos: Vector2, size: Vector2, cb: Callable) -> Button:
	var btn := _dialog_button(text, cb)
	btn.add_theme_font_size_override("font_size", 18)
	add_child(btn)
	_track(btn, pos, size)
	return btn

# 主菜单的通用按钮工厂。本文件只有两处 Button.new()（另一处是 _add_hit 的隐形热区），
# 所以房间面板那四种形态也必须从这里出来 —— 各自 new 一个会让
# procedural_ui_ratchet 的单文件计数上涨，棘轮立刻转红。
#
# variant（默认 "menu" = 原羊皮纸外观，主菜单自己的按钮走这条，观感不变）：
#   "room_primary"    实心金，主操作（创建房间）
#   "room_second"     透明底 + 金描边，次操作（加入房间）
#   "room_ghost_gold" 幽灵，金 1px 描边（刷新）
#   "room_ghost"      幽灵，低对比描边（关闭）
#   "room_row"        房间列表行，常态
#   "room_row_full"   房间列表行，满员（禁用）
func _dialog_button(text: String, cb: Callable, variant: String = "menu") -> Button:
	var btn := Button.new()
	btn.text = text
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.pressed.connect(cb)
	match variant:
		"room_primary":
			_style_room_button(btn, Tokens.MIST_GOLD_BRIGHT, Tokens.MIST_GOLD_BRIGHT,
				Tokens.MIST_ON_GOLD, ROOM_BUTTON_H, Tokens.MIST_NONE)
			Kit.style_plate(btn, true)
		"room_second":
			_style_room_button(btn, Tokens.MIST_NONE, Tokens.MIST_GOLD,
				Tokens.MIST_GOLD_BRIGHT, ROOM_BUTTON_H, Tokens.MIST_HOVER_TINT, 2)
			Kit.style_plate(btn, false)
		"room_ghost_gold":
			_style_room_button(btn, Tokens.MIST_NONE, Tokens.MIST_GOLD,
				Tokens.MIST_GOLD_BRIGHT, ROOM_TITLE_ROW_H, Tokens.MIST_GHOST_HOVER, 1)
			Kit.style_plate(btn, false)
		"room_ghost":
			_style_room_button(btn, Tokens.MIST_NONE, Tokens.MIST_GHOST_EDGE,
				Tokens.MIST_TEXT_SOFT, ROOM_BUTTON_H, Tokens.MIST_GHOST_HOVER, 1)
			Kit.style_plate(btn, false)
		"room_row":
			_style_room_row(btn, Tokens.MIST_ROW_IDLE, Tokens.MIST_LINE, Tokens.MIST_ROW_HOVER, Tokens.MIST_GOLD)
			Kit.style_list_row(btn, ROOM_FONT_BODY)
		"room_row_full":
			_style_room_row(btn, Tokens.MIST_ROW_FULL, Tokens.MIST_LINE, Tokens.MIST_ROW_FULL, Tokens.MIST_LINE)
			Kit.style_list_row(btn, ROOM_FONT_BODY)
			# 满员：同一张纸条压暗
			btn.add_theme_stylebox_override("disabled", Kit.box("list_row", Vector4(26, 6, 30, 8), Color(0.78, 0.74, 0.68)))
		_:
			btn.custom_minimum_size = Vector2(150, 42)
			var style := Tokens.flat_box(Tokens.PARCHMENT_BUTTON, Tokens.PARCHMENT_EDGE, 2, 18)
			btn.add_theme_stylebox_override("normal", style)
			btn.add_theme_stylebox_override("hover", style)
			btn.add_theme_stylebox_override("pressed", style)
			btn.add_theme_color_override("font_color", Color(0.45, 0.27, 0.08))
			btn.add_theme_font_size_override("font_size", 20)
	return btn

func _room_button_box(bg: Color, edge: Color, border: int) -> StyleBoxFlat:
	var box := Tokens.flat_box(bg, edge, border, ROOM_RADIUS)
	box.content_margin_left = 16
	box.content_margin_right = 16
	box.content_margin_top = 8
	box.content_margin_bottom = 8
	return box

# 房间面板四种按钮形态的共用上色。三档（normal / hover / pressed）必须**分别**给，
# 否则按下没有反馈；文字色也要给 hover / pressed / focus 三档，不然鼠标一悬停
# 文字会掉回主题默认色（深色底上几乎看不见）。
func _style_room_button(
	btn: Button, bg: Color, edge: Color, fg: Color,
	height: int, hover_tint: Color, border: int = 2
) -> void:
	btn.custom_minimum_size = Vector2(0, height)
	var transparent := bg == Tokens.MIST_NONE
	var normal_box := _room_button_box(bg, edge, border)
	if not transparent:
		# 主按钮的「金色外发光」（稿子 §四.1）。只给实心金这一种加 —— 四个按钮都发光
		# 就等于没有主次。稿子的 size=16 是 2× 设计稿像素，这里取 10。
		var glow := Tokens.MIST_GOLD
		glow.a = 0.35
		normal_box.shadow_color = glow
		normal_box.shadow_size = 10
		normal_box.shadow_offset = Vector2(0, 2)
	btn.add_theme_stylebox_override("normal", normal_box)
	if transparent:
		# 透明底：hover 用传入的淡色，pressed 再往描边色压一档，才有「按下去」的手感。
		btn.add_theme_stylebox_override("hover", _room_button_box(hover_tint, edge, border))
		btn.add_theme_stylebox_override("pressed",
			_room_button_box(hover_tint.lerp(edge, 0.35), edge, border))
	else:
		btn.add_theme_stylebox_override("hover",
			_room_button_box(Tokens.MIST_GOLD_HOVER, edge, border))
		btn.add_theme_stylebox_override("pressed",
			_room_button_box(Tokens.MIST_GOLD_PRESSED, edge, border))
	btn.add_theme_stylebox_override("focus",
		Tokens.flat_box(Tokens.MIST_NONE, Tokens.MIST_GOLD_BRIGHT, 2, ROOM_RADIUS))
	btn.add_theme_color_override("font_color", fg)
	btn.add_theme_color_override("font_hover_color", fg)
	btn.add_theme_color_override("font_pressed_color", fg)
	btn.add_theme_color_override("font_focus_color", fg)
	btn.add_theme_font_size_override("font_size", 20)

func _style_room_row(btn: Button, bg: Color, edge: Color, hover_bg: Color, hover_edge: Color) -> void:
	# 行内文字由 _room_row 用两个 Label 画（房间名与人数颜色不同），所以这里只管
	# 底板三态。disabled 与 normal 同款：满员行的「不可用」靠更低的底色 + 更灰的
	# 文字表达，不做额外的灰化处理。
	var idle := Tokens.flat_box(bg, edge, 1, ROOM_RADIUS)
	btn.add_theme_stylebox_override("normal", idle)
	btn.add_theme_stylebox_override("disabled", idle)
	btn.add_theme_stylebox_override("hover", Tokens.flat_box(hover_bg, hover_edge, 1, ROOM_RADIUS))
	btn.add_theme_stylebox_override("pressed", Tokens.flat_box(hover_bg, hover_edge, 1, ROOM_RADIUS))
	btn.add_theme_stylebox_override("focus",
		Tokens.flat_box(Tokens.MIST_NONE, Tokens.MIST_GOLD, 1, ROOM_RADIUS))

func _track(node: Control, pos: Vector2, size: Vector2, font_size: int = 0, edge: String = "") -> void:
	_placed.append({"node": node, "pos": pos, "size": size, "font_size": font_size, "edge": edge})

# ── 布局调试overlay ────────────────────────────────────────────────
func _build_debug_layer() -> void:
	_debug_layer = Control.new()
	_debug_layer.name = "DebugLayoutOverlay"
	_debug_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_debug_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_debug_layer.z_index = 4096
	_debug_layer.visible = _debug_on
	_debug_layer.draw.connect(_draw_debug_layout)
	add_child(_debug_layer)

func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo or key.keycode != KEY_F3:
		return
	_debug_on = not _debug_on
	if _debug_layer != null:
		_debug_layer.visible = _debug_on
		_debug_layer.queue_redraw()
	get_viewport().set_input_as_handled()

func _draw_debug_layout() -> void:
	if _debug_layer == null:
		return
	var viewport_size := get_viewport_rect().size
	var scale := _layout_scale
	var origin := _layout_origin
	var font := ThemeDB.fallback_font
	var black := Color(0.0, 0.0, 0.0, 0.95)
	var black_soft := Color(0.0, 0.0, 0.0, 0.45)
	var red := Color(1.0, 0.10, 0.10, 0.95)

	# 1) 参考画布 1672x941 的外框（居中缩放的那块 16:9 区域）
	var canvas := Rect2(origin, REF_SIZE * scale)
	_debug_layer.draw_rect(canvas, black, false, 3.0)
	_debug_layer.draw_string(font, origin + Vector2(6.0, -6.0),
		"参考画布 %dx%d  scale=%.3f  视口 %dx%d" % [int(REF_SIZE.x), int(REF_SIZE.y), scale,
		int(viewport_size.x), int(viewport_size.y)],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, black)

	# 2) 画布中线 + 四等分竖线（摆按钮时用来对齐）
	for i in range(1, 4):
		var gx := origin.x + REF_SIZE.x * scale * float(i) / 4.0
		_debug_layer.draw_line(Vector2(gx, canvas.position.y), Vector2(gx, canvas.end.y),
			black if i == 2 else black_soft, 2.0 if i == 2 else 1.0)

	# 3) 功能分区带（横向黑带，标注参考坐标 y 范围）
	for band in DEBUG_BANDS:
		var by := origin.y + float(band.y) * scale
		var bh := float(band.h) * scale
		_debug_layer.draw_rect(Rect2(canvas.position.x, by, canvas.size.x, bh), black, false, 2.0)
		_debug_layer.draw_string(font, Vector2(canvas.position.x + 8.0, by + 18.0),
			"%s  y=%d~%d" % [band.name, int(band.y), int(band.y) + int(band.h)],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, black)

	# 3.5) 宠物活动区域（中心草地）
	var pet_rect := Rect2(origin + MAIN_MENU_PET.AREA_POS * scale, MAIN_MENU_PET.AREA_SIZE * scale)
	_debug_layer.draw_rect(pet_rect, black, false, 2.0)
	_debug_layer.draw_string(font, pet_rect.position + Vector2(8.0, 18.0),
		"宠物活动区 (%d,%d) %dx%d" % [int(MAIN_MENU_PET.AREA_POS.x), int(MAIN_MENU_PET.AREA_POS.y),
		int(MAIN_MENU_PET.AREA_SIZE.x), int(MAIN_MENU_PET.AREA_SIZE.y)],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, black)

	# 4) edge=left / edge=right 锚定边（这两列贴安全区的左右边，不跟画布走）
	var safe := SafeArea.rect()
	var left_edge_x := safe.position.x + 176.0 * scale
	var right_edge_x := safe.end.x - (REF_SIZE.x - 1355.0) * scale
	_debug_layer.draw_line(Vector2(left_edge_x, 0.0), Vector2(left_edge_x, viewport_size.y), black, 2.0)
	_debug_layer.draw_line(Vector2(right_edge_x, 0.0), Vector2(right_edge_x, viewport_size.y), black, 2.0)
	_debug_layer.draw_string(font, Vector2(6.0, viewport_size.y - 26.0),
		"edge=left 贴安全区左", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, black)
	_debug_layer.draw_string(font, Vector2(right_edge_x + 6.0, viewport_size.y - 26.0),
		"edge=right 贴安全区右", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, black)

	# 5) 每个元素的占位框：按钮判定区红色，其余（图片/文字）黑色细框
	for item in _placed:
		var node := item.node as Control
		if node == null or not node.is_visible_in_tree():
			continue
		var rect := Rect2(node.position, node.size)
		var pos := item.pos as Vector2
		var size := item.size as Vector2
		if node is Button:
			_debug_layer.draw_rect(rect, red, false, 2.0)
			var edge_tag := str(item.get("edge", ""))
			var tag := "%s  (%d,%d) %dx%d%s" % [node.name, int(pos.x), int(pos.y),
				int(size.x), int(size.y), "" if edge_tag.is_empty() else "  edge=" + edge_tag]
			_debug_layer.draw_string(font, rect.position + Vector2(2.0, -4.0), tag,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 13, red)
		else:
			_debug_layer.draw_rect(rect, black_soft, false, 1.0)


func _apply_profile_progression(state: Dictionary) -> void:
	_account_level = int(state.get("level", 1))
	_account_xp_progress = maxi(0, int(state.get("xp", 0)) - int(state.get("level_xp", 0)))
	_account_xp_required = maxi(0, int(state.get("next_xp", 0)) - int(state.get("level_xp", 0))) if state.get("next_xp") != null else 0
	if _account_xp_required > 0:
		_account_xp_progress = mini(_account_xp_progress, _account_xp_required)
	_refresh_profile_plate()
