extends Node
const CarrotEconomy := preload("res://scripts/economy/CarrotEconomy.gd")

signal completed
signal skip_requested

const TutorialTargetProviderScript := preload("res://scripts/tutorial/TutorialTargetProvider.gd")
const TutorialGuideLightScript := preload("res://scripts/tutorial/TutorialGuideLight.gd")
const DOG_WELCOME := preload("res://assets/ui/tutorial/dog_welcome.png")
const DOG_GUIDE := preload("res://assets/ui/tutorial/dog_guide.png")
const DOG_EXPLAIN := preload("res://assets/ui/tutorial/dog_explain.png")
const DOG_ENCOURAGE := preload("res://assets/ui/tutorial/dog_encourage.png")
# 聚焦遮罩的着色器：整幅压暗 + 逐片元开洞。见 FOCUS_DIM_COUNT 上方的长注释。
const TutorialFocusMaskShader := preload("res://shaders/tutorial_focus_mask.gdshader")

const GOLD_TEXT := "∞"
const TUTORIAL_GOLD := 9999
const TUTORIAL_HP := 10
# 9.25：萝卜教学在 Boss 后一次性送出的萝卜。够抽一次升级石（50）再雇两个佣兵。
const TUTORIAL_CARROT_GIFT := 100
# 萝卜营地面板的两个页签（CarrotCampPanelV3._show_page 的下标）。
const CAMP_PAGE_CAMP := 0
const CAMP_PAGE_STONE := 1

enum Step {
	BUY_3,
	PLACE_3,
	START_PVE_1,
	UPGRADE_2,
	START_PVE_2,
	TAKE_TREASURE_1,
	UPGRADE_3,
	UPGRADE_OTHERS,
	BOND_HINT,
	VIEW_TREASURE,
	# 9.25 萝卜 / 四星教学（方案 B）：Boss 前先开营地、升级采集；
	# Boss 后看到升级带来的收获，再领萝卜 → 抽升级石 → 升四星 → 用萝卜雇佣兵。
	CARROT_CAMP,
	HARVEST_UPGRADE,
	START_BOSS,
	TAKE_TREASURE_2,
	CARROT_HARVEST,
	DRAW_STONE,
	FOUR_STAR,
	HIRE_MERC,
	FILL_7,
	FORMATION_HP,
	START_PVP,
	DONE,
}

# 进度显示用的「实际到访顺序」，不是枚举顺序。FORMATION_HP 会被走两次
# （VIEW_TREASURE 之后讲一次、FILL_7 之后 PVP 前再讲一次），所以它在表里出现两回；
# 配合 _progress_index 只向前走，步数就不会倒退。增删步骤时这张表要同步改。
const STEP_SEQUENCE: Array = [
	Step.BUY_3,
	Step.PLACE_3,
	Step.START_PVE_1,
	Step.UPGRADE_2,
	Step.START_PVE_2,
	Step.TAKE_TREASURE_1,
	Step.UPGRADE_3,
	Step.UPGRADE_OTHERS,
	Step.BOND_HINT,
	Step.VIEW_TREASURE,
	Step.FORMATION_HP,
	Step.CARROT_CAMP,
	Step.HARVEST_UPGRADE,
	Step.START_BOSS,
	Step.TAKE_TREASURE_2,
	Step.CARROT_HARVEST,
	Step.DRAW_STONE,
	Step.FOUR_STAR,
	Step.HIRE_MERC,
	Step.FILL_7,
	Step.FORMATION_HP,
	Step.START_PVP,
]

# FILL_7 的三个子阶段（V2 P1-07）。**必须是显式状态**：
# 不靠气泡当前显示什么、不靠某个节点可不可见、也不靠固定帧数去反推玩家走到哪了。
# 三个阶段各自有一条来自生产链的推进条件：
#   BUY        <- PrepBoardController 成交后调 record_shop_purchase()
#   CLOSE_SHOP <- ShopPanel.picker_toggled(false) 经 PrepUI 调 record_shop_toggled()
#   DEPLOY     <- GameState.board_slots 的真实占用数
enum FillPhase { BUY, CLOSE_SHOP, DEPLOY }

enum ArrowDir { DOWN, UP, LEFT } # Reused as bubble placement preference; no arrow is drawn.

# 气泡尺寸。气泡是浮在 overlay 上的自由控件，没有父容器约束它，
# 所以宽高必须显式钉死：autowrap 的 Label 在宽度未定时，最小高度会按
# 「每行一个词」算成巨值，把气泡撑到半屏、盖掉商店和按钮。
const BUBBLE_WIDTH := 400.0
const BUBBLE_MARGIN_X := 14.0
const BUBBLE_TEXT_WIDTH := BUBBLE_WIDTH - BUBBLE_MARGIN_X * 2.0
const BUBBLE_MIN_HEIGHT := 72.0
const BUBBLE_MAX_HEIGHT := 200.0

# V2 P1-09 的版面常量。
# 气泡与安全区边缘之间的最小间隙。
const BUBBLE_EDGE_MARGIN := 18.0
# 压住目标的单位面积代价。验收线是「目标可见面积 ≥90%」，所以它必须显著高于禁区。
const TARGET_OVERLAP_WEIGHT := 8.0
# 候选顺序的固定代价，只用来在完全同分时保住首选方向，不足以压过任何真实遮挡。
const CANDIDATE_ORDER_PENALTY := 1.0
# Once a bubble is valid for the same semantic target, small layout noise must not
# make it jump to another candidate. These are the same 90% visibility limits used
# by tutorial_overlay_layout_check.
const MAX_STICKY_OVERLAP_RATIO := 0.10
const LAYOUT_GEOMETRY_EPS := 2.0

# 聚焦遮罩（2026-10-15 反馈问题 2）：**一整块**暗幕，洞由 shader 逐片元抠出来。
#
# ⚠ 这里曾经是 4（上/下/左/右四块拼成环形）。同日返工前玩家实测报「屏幕会闪，伴有线」，
#   查下来是这套拼法的结构缺陷，换成单块 + shader 才根治：
#     ① 相邻两块共用一条**同值的分数坐标边**，而 GPU 按每个 quad 各自的顶点独立
#        栅格化，公共边在像素级上会错开 1px ⇒ 一条亮线；
#     ② 被框住的目标（商店木牌）本身在**逐帧漂移**（实测 y ≈ −0.027 px/帧、
#        x ≈ +0.003 px/帧），于是那条缝每秒被扫过一两次 ⇒ 「闪」。
#   单块方案下遮罩内部**没有任何边界**，缝在结构上不可能出现；同时这块 quad 的
#   矩形恒等于整幅 overlay，**每帧几何零变化**（只改 uniform），亚像素游走也没了。
#   长度恒为 1；保留数组形态是为了让门禁沿用同一套「遍历暗幕」的写法。
const FOCUS_DIM_COUNT := 1
# 压暗强度。与既有遮罩同一档（萝卜营地 0.68 / 商店不可买原因 0.64）：
# 够暗到能一眼分出主角，又留住足够多的场景轮廓让新手知道自己在哪一步。
const FOCUS_DIM_COLOR := Color(0.02, 0.025, 0.04, 0.72)
# 洞比目标外扩这么多像素：给光圈与目标自己留一圈呼吸位，
# 免得暗幕边界贴着卡面切过去显得像渲染错误。
const FOCUS_HOLE_PADDING := 6.0
# 「点一下继续」四个步骤的受理外扩（2026-10-15 第三轮，见 `_input()`）。
# 与已上线那版透明热区同值：热区当时是 `position - pad` / `size + pad * 2`，
# 与矩形 `grow(10)` 等价 ⇒「点哪儿算数」相对真机反馈过的版本**零变化**，
# 本次改的只是「吃不吃输入」。
const TAP_TARGET_PAD := 10.0

var active := false
var step: int = Step.BUY_3
var bought_units := 0

# --- FILL_7 子阶段状态（V2 P1-07）---------------------------------------------
# _fill_started 保证「进入 FILL_7 时只初始化一次」：重复 sync()、面板刷新、
# 重复信号都不会把计数打回去或重复补偿。离开 FILL_7 / finish() / start() 会完整清理。
var _fill_started := false
var _fill_phase: int = FillPhase.BUY
# 还需要买几个才能凑够 7 个可上阵棋子。正常基线（棋盘 3 个）下就是 4。
var _fill_buy_target := 0
# 真实成交次数：只由 record_shop_purchase() 递增，而它只在扣钱与 shop_sold 都已落地
# 之后才被调用 —— 所以这不是「按钮点击计数」，买失败（钱不够/待命区满）不会计。
var _fill_bought := 0
var _fill_shop_open := false
# 自动合成/融合导致买够了却仍凑不满 7 个时补发的数量。门禁和交接要能看见它。
var _fill_compensated := 0
# 进度条指针，指向 STEP_SEQUENCE 的下标；只增不减。
var _progress_index := 0

# --- 萝卜 / 四星教学状态（9.25）------------------------------------------------
# 营地开合与当前页签由 PrepUI 在真实开合/切页时经 record_carrot_camp_state() 上报，
# 与 record_shop_toggled() 同一种接线：不轮询面板可见性、不伸手读 PrepScreen 的字段。
# 这两项是纯界面状态，不进断点（重建备战页时营地一定是关着的，见 attach()）。
var _camp_open := false
var _camp_page := CAMP_PAGE_CAMP
# 教学里只收获一次（Boss 后）。收获与领奖都要幂等：sync() 会被反复调用。
var _carrot_harvested := false
var _carrot_harvest_gain := 0
var _carrot_gift_claimed := false
# 教学 PVP 步的伪造对手棋盘（原先借用 NetworkService.opponent_board_snapshot，
# 1v1 联机删除后由教学模式自持，BattleSimulator 的教学 PVP 路径从这里读）。
var opponent_snapshot: Dictionary = {}
var _target_provider: TutorialTargetProviderScript
var _overlay: Control
var _light: TutorialGuideLightScript
var _guide: TextureRect
var _bubble: PanelContainer
var _text: Label
var _progress_label: Label
# Shows the localized step NAME. Never the enum key — see step_display_name().
var _step_name_label: Label
var _progress_bar: ProgressBar
var _continue_btn: Button
var _skip_btn: Button
# 新手教学「聚焦遮罩」：一整块铺满 overlay 的 ColorRect（挂 shader），
# 洞由 fragment 逐片元抠出来。恒为 1 个元素，见 FOCUS_DIM_COUNT 上方的注释。
var _focus_dim: Array[ColorRect] = []
var _overlay_suppressed := false
var _layout_signature := ""
var _layout_context := ""
var _last_bubble_position := Vector2.ZERO
var _last_candidate_index := -1
var _layout_recompute_count := 0
var _last_layout_reason := "not_laid_out"
var _last_content_key := ""
var _last_target_rect := Rect2()
var _last_safe_rect := Rect2()
var _last_keep_clear_rects: Array[Rect2] = []
# 跳过确认框不再由本文件持有节点：见 _show_skip_confirm()。

const START_SHOP := ["human_militia", "human_archer", "human_merchant", "human_swordsman"]
# FILL_7 铺货（买齐 7 个上阵）。**9.25 教程优化第 3 条：不出死侍**，
# 所以这里把 human_death_servant 拿掉、只留三种。
# 三种而不是四种没关系：_apply_shop() 按 `offers[i % size]` 循环填满 4 个卡位，
# 刷新（_roll_shop -> tutorial_shop_ids -> 本表）也走同一张表，
# 于是「不再出现、也不再刷新出死侍」两条由同一处保证。
# 这几种都是「场上还没有的棋子」——若有同名在场，买入会立刻自动合成、
# 可上阵数不增，_fill_buy_target 就永远凑不满（见 _compensate_fill_shortfall）。
const FILL_SHOP := ["human_swordsman", "human_mage", "human_cleric"]

# PVP 前要凑满的上阵数。取生产常量而不是写死 7 —— 规则改了这里跟着走。
const FILL_TARGET_UNITS := GameConstants.NORMAL_UNIT_CAP
# 开战前的最低上阵数（board_slots 上的普通棋子，即 GameState.normal_unit_count）。
# 与 PLACE_3 的完成条件、battle_board_gate_message() 共用同一个值。
# 注意别和 _owned_normal_count() 混：那个数是「棋盘 + 待命区」的持有数，
# 教学里同样是 3，但口径不同（BUY_3 用它）。
const EARLY_DEPLOY_UNITS := 3
# 升星步：商店铺满玩家要凑的同名棋子，让玩家自己买 + 刷新
const UPGRADE_2_SHOP := ["human_militia", "human_militia", "human_militia", "human_militia"]
const UPGRADE_OTHERS_SHOP := ["human_archer", "human_archer", "human_merchant", "human_merchant"]
const PVP_OPPONENT := ["human_militia", "human_archer", "human_merchant", "human_swordsman", "human_mage"]
const TREASURE_1 := ["def_iron_wall", "atk_blood_pact", "ctrl_shockwave"]
const TREASURE_2 := ["atk_fury_roster", "def_formation_heal", "money_discount"]

func start() -> void:
	active = true
	step = Step.BUY_3
	bought_units = 0
	_progress_index = 0
	_end_fill_step()
	_reset_carrot_tutorial()
	# 重新开始教程：旧断点必须先清掉，否则下次启动会把玩家拽回上一局的进度。
	clear_checkpoint()
	GameState.reset_run()
	GameState.tutorial_mode = true
	GameState.player_formation_hp = TUTORIAL_HP
	GameState.enemy_formation_hp = TUTORIAL_HP
	GameState.gold = TUTORIAL_GOLD
	_apply_shop(START_SHOP)
	AnalyticsService.tutorial_started()

func finish(clear_saved_checkpoint: bool = true) -> void:
	active = false
	GameState.tutorial_mode = false
	opponent_snapshot = {}
	_end_fill_step()
	if clear_saved_checkpoint:
		clear_checkpoint()
	_detach()
	completed.emit()

func attach(provider: TutorialTargetProviderScript) -> void:
	if not active:
		return
	_target_provider = provider
	# 每次挂到新建的备战页上，萝卜营地都是关着的、停在「营地」页。
	_camp_open = false
	_camp_page = CAMP_PAGE_CAMP
	_ensure_overlay()
	sync()
	update_overlay()

func sync() -> void:
	if not active:
		return
	GameState.gold = TUTORIAL_GOLD
	# 旧版本重复领取会关掉选择层却没有增加持有数。恢复候选让该步骤可继续。
	var required := 1 if step == Step.TAKE_TREASURE_1 else 2 if step == Step.TAKE_TREASURE_2 else 0
	if required > 0 and GameState.owned_treasures.size() < required:
		var preferred: Array = GameState.pending_treasure.get("candidates", [])
		if preferred.is_empty():
			preferred = TREASURE_1 if required == 1 else TREASURE_2
		var candidates := TreasureService.available_candidates(preferred)
		if not bool(GameState.pending_treasure.get("active", false)) or candidates != preferred:
			GameState.pending_treasure["active"] = true
			GameState.pending_treasure["candidates"] = candidates
			_refresh_prep()
	# 按「实际拥有 3 个」推进，不按采购次数：自动合成下重复买同名会融合，
	# 买满 3 次也可能只剩 2 个棋子，那样 PLACE_3 的 3 个上阵条件永远达不到。
	# 9.13 #4：买满 3 个之后不直接跳到第 2 步，先在**同一步（1/17）**里引导玩家
	# 关闭商店 —— 商店盖着棋盘，不关掉就没法把待命区的棋子拖上棋盘
	# （第 2 步的目标正是棋盘）。完成条件仍是「商店已关」，与 FILL_7 的
	# CLOSE_SHOP 子阶段共用 record_shop_toggled() 的生产事件，不轮询、不猜。
	if step == Step.BUY_3 and _owned_normal_count() >= 3 and not _fill_shop_open:
		_advance_to(Step.PLACE_3)
	if step == Step.PLACE_3 and GameState.normal_unit_count() >= EARLY_DEPLOY_UNITS:
		_advance_to(Step.START_PVE_1)
	if step == Step.UPGRADE_2 and _unit_star("human_militia") >= 2:
		_advance_to(Step.START_PVE_2)
	if step == Step.TAKE_TREASURE_1 and GameState.owned_treasures.size() >= 1:
		# 只送 1 个 2 星（送 2 个会和场上那个凑满 3 个、当场自动合成到 3 星，
		# UPGRADE_3 就被跳过了）。剩下 1 个 2 星让玩家自己买 2 个 1 星凑。
		_grant_units("human_militia", 1, 2)
		_advance_to(Step.UPGRADE_3)
		_refresh_prep()
	if step == Step.UPGRADE_3 and _unit_star("human_militia") >= 3:
		# 弓手/商人升 2 星也让玩家自己在商店买，不再直接发材料。
		_apply_shop(UPGRADE_OTHERS_SHOP)
		_advance_to(Step.UPGRADE_OTHERS)
		_refresh_prep()
	if step == Step.UPGRADE_OTHERS and _unit_star("human_archer") >= 2 and _unit_star("human_merchant") >= 2:
		_advance_to(Step.BOND_HINT)
	# --- 9.25 萝卜 / 四星教学 ---
	if step == Step.CARROT_CAMP and _camp_open:
		_advance_to(Step.HARVEST_UPGRADE)
		# 9.25 教程优化第 2 条：必须在这里刷一次视图。
		#
		# 营地面板的「升级采集」按钮 disabled 里有一项 `not allows_carrot_action(
		# "harvest_upgrade")`，而它只在 step==HARVEST_UPGRADE 时为假。玩家点营地
		# 打开面板那一刻，PrepUI._toggle_carrot_camp 的顺序是「toggle() 先 refresh()
		# 一次 → 再上报状态」，于是那一次 refresh 看到的是**还没推进的 CARROT_CAMP**，
		# 按钮被算成禁用（灰）；状态上报触发 sync() 推进到 HARVEST_UPGRADE 之后又没人
		# 再刷新，按钮就一直灰着，玩家只能关掉营地再打开（第二次 toggle 时 step 已经是
		# HARVEST_UPGRADE，才亮起来）——提交截图 image6（灰）/image7（关营地）/image8
		# （重开后亮）就是这个来回。本项目的既有做法就是「推进改变面板内容的步骤后
		# 请求一次 ACTION_REFRESH_VIEW」（见 UPGRADE_2 / UPGRADE_3 / FORMATION_HP 等
		# 分支），这里漏了，补上即可：按钮在营地打开的同一帧内就变亮。
		_refresh_prep()
	# 升级完还要玩家自己关掉营地（营地盖住了「开始战斗」），关掉才进 Boss。
	if step == Step.HARVEST_UPGRADE and GameState.harvest_tech_level >= 1 and not _camp_open:
		_advance_to(Step.START_BOSS)
	if step == Step.TAKE_TREASURE_2 and GameState.owned_treasures.size() >= 2:
		_advance_to(Step.CARROT_HARVEST)
	if step == Step.CARROT_HARVEST and not _carrot_harvested:
		_run_tutorial_harvest()
	if step == Step.DRAW_STONE:
		_ensure_four_star_candidate()
		_ensure_draw_budget()
		if _stone_count() > 0:
			_advance_to(Step.FOUR_STAR)
	if step == Step.FOUR_STAR:
		if _max_normal_star() >= GameState.MAX_UNIT_STAR:
			_advance_to(Step.HIRE_MERC)
			_refresh_prep()
		else:
			_ensure_four_star_path()
	if step == Step.HIRE_MERC and _mercenary_count() >= 2:
		if _target_provider != null:
			_target_provider.request_action(
				TutorialTargetProviderScript.ACTION_CLOSE_MERCENARY)
		_apply_shop(FILL_SHOP)
		# 必须排在推进之前：_advance_to() 会立刻落盘，晚一步就会把
		# _fill_started=false 记进 FILL_7 的断点，恢复时子状态机对不上。
		_begin_fill_step()
		_advance_to(Step.FILL_7)
	if step == Step.FILL_7:
		# 幂等：重复 sync() 只会把子阶段往前推，不会重置计数、不会重复补偿。
		_advance_fill_step()
	if step == Step.FILL_7 and GameState.normal_unit_count() >= FILL_TARGET_UNITS:
		_end_fill_step()
		_advance_to(Step.FORMATION_HP)
	# 每次推进都落一次断点（内部按进度签名节流，不会每帧写盘）。
	save_checkpoint()
	update_overlay()

func can_start_battle() -> bool:
	return step in [Step.START_PVE_1, Step.START_PVE_2, Step.START_BOSS, Step.START_PVP]


# 当前这一步开战前的最低上阵数。0 = 不在开战步、不设限。
#
# 与 battle_board_gate_message() 共用同一个来源：那条提示里的数字必须由这里算，
# 否则会出现「提示说少于 3、实际按 7 判」这类两处漂移。开战闸
# （_ensure_board_ready_for_battle）与 PrepFlowController 的 UI 闸门也都读它。
func required_board_units() -> int:
	if step in [Step.START_PVE_1, Step.START_PVE_2, Step.START_BOSS]:
		return EARLY_DEPLOY_UNITS
	if step == Step.START_PVP:
		return FILL_TARGET_UNITS
	return 0

# 9.25 教程优化第 4/5 条：开战前的最低上阵人数门槛。
#
# 文档里的「步骤 3 / 5 / 14 / 22」是 STEP_SEQUENCE 的 1-based 序号（也就是气泡右上角
# 那个「步 N/22」），逐条对上：
#   3  = START_PVE_1 、5  = START_PVE_2 、14 = START_BOSS  -> 至少 3 个
#   22 = START_PVP                                          -> 至少 7 个（FILL_TARGET_UNITS）
# 上阵数一律取 GameState.normal_unit_count()：那是 board_slots 上的**普通**棋子数，
# 与 PLACE_3 / FILL_7 的完成条件同一口径（佣兵在 mercenary_slots，不算）。
#
# 返回空串 = 放行；非空 = 要弹给玩家的拦截提示。文案按要求固定为「上阵棋子数目少于N」，
# 与 follow_arrow_hint() 的「请先完成前置任务」走同一个出口（PrepFlowController 的
# show_message），因此样式天然一致。
func battle_board_gate_message() -> String:
	var need := required_board_units()
	if need <= 0 or GameState.normal_unit_count() >= need:
		return ""
	return _t("上阵棋子数目少于%d" % need, "Deploy at least %d units first" % need)

# 无效点击的反馈（V3 P1-10）。
#
# 原来无论在哪一步都只回一句「先完成箭头指示的操作」。那句话有两个问题：
# 它没说要做什么，而且箭头指的地方**可能正被商店盖住** —— 玩家照着看，
# 看到的是商店，于是在商店里反复找。
#
# 现在说清两件事：商店开着就先让它关掉；否则统一回一句「请先完成前置任务」。
# 商店那条要复述这一步的目标，目标直接取 current_text() 的首行，不另建一张会漂移的
# 文案表 —— 那张表还会成为第二处可能泄漏 enum key 的地方。
func follow_arrow_hint() -> String:
	var objective := current_text().split("
")[0].strip_edges()
	if _fill_shop_open and not _target_is_in_shop():
		if objective.is_empty():
			return _t("商店挡住了要点的地方，先关掉商店。",
				"The shop is covering the target. Close it first.")
		return _t("商店挡住了要点的地方。先关掉商店，然后：%s" % objective,
			"The shop is covering the target. Close it first, then: %s" % objective)
	# 9.25 教程优化第 1 条：原来这里回「这一步还没完成：<整段目标文案>」。
	# 目标文案本身就长，玩家在商店里连点卡片时同一句会堆满整个屏幕（见提交截图
	# image4）。改成一句短的，与 ③(4)/(5) 的「上阵棋子数目少于 N」同为纯 `show_message`
	# 提示（同一个出口、同一种样式）。
	return _t("请先完成前置任务", "Finish the previous task first")


# 这一步的目标本来就在商店里时，不该让玩家去关商店。
func _target_is_in_shop() -> bool:
	if step == Step.BUY_3:
		# 9.13 #4：买满 3 个后这一步的目标变成「商店外面」（点外面关商店），
		# 这里必须跟着变，否则 follow_arrow_hint() 会把该提示当成
		# 「目标本来就在商店里」而吞掉。
		return _owned_normal_count() < 3
	if step in [Step.UPGRADE_2, Step.UPGRADE_3, Step.UPGRADE_OTHERS]:
		return true
	return step == Step.FILL_7 and _fill_phase == FillPhase.BUY

func begin_battle() -> bool:
	if not can_start_battle():
		if _target_provider != null:
			_target_provider.show_feedback(follow_arrow_hint())
		return false
	# 第 2 层兜底：开战闸 + 状态自愈。只查步骤的 can_start_battle() 挡不住「棋盘是空的」，
	# 而空棋盘一开战就会被 prepare_tutorial_state 按 no_player_units 判负。
	if not _ensure_board_ready_for_battle():
		return false
	if step == Step.START_PVP:
		opponent_snapshot = _tutorial_opponent_snapshot()
	_detach()
	return true

# 开战前的最后一道闸（10.16 bug 第 1 条，第 2 层兜底）。
#
# 为什么需要它：重启教程（「重新体验教学」）或断点恢复都会走 TutorialMode.start() /
# restore_checkpoint()，两条路都会把 board_slots 清空重铺。若玩家在铺满之前就点到
# 「开始战斗」， prepare_tutorial_state 看到空棋盘会直接返回
# forced_result.player_wins=false（no_player_units），于是结算字幕播「失败」，
# 而 TutorialMode.after_battle() 又照样把步骤往前推 —— 玩家看到的就是
# 「打了场没打的仗、还输了、然后被拽到下一步」。
#
# 原来的闸门只住在 UI 按钮层（PrepFlowController._on_start_battle 的
# battle_board_gate_message），那条路有旁路（PrepScreen 的战斗加载重试、
# team_round_start、断点恢复后的自动开战），挡不全。所以闸门搬进这里 ——
# begin_battle() 是 Main._on_battle_requested 开战前的最后一个函数，
# 所有入口都要经过它。
#
# 顺序不能换：先自愈、再判定、最后才允许开战。
#   * 自愈只从待命区补，且挑「放上去不会触发合成」的棋子（合成可让上阵数不增反减）；
#   * 补完还不够 → 不烧调用方的一次性发射锁，直接给提示返回 false，让玩家自己拖。
func _ensure_board_ready_for_battle() -> bool:
	var need := required_board_units()
	if need <= 0:
		return true
	var missing := need - GameState.normal_unit_count()
	if missing <= 0:
		return true
	var moved := _auto_deploy_from_bench(missing)
	if moved > 0:
		# 自愈搬动了棋盘：必须刷一次视图，否则玩家看到的计数还是旧的
		#（返回 false 时人还停在备战页，尤其不能忍）。
		_refresh_prep()
		print("[TUTORIAL] begin_battle self-heal: moved %d unit(s) from bench (need %d, had %d)" % [moved, need, need - missing])
	if GameState.normal_unit_count() < need:
		if _target_provider != null:
			_target_provider.show_feedback(battle_board_gate_message())
		return false
	return true

# 从待命区挑棋子补上棋盘，返回真正搬上去几个。
#
# 挑法（两条都只为「让上阵数真的增加」服务）：
#   1. 不放会触发合成的：放上去若凑满 copies_to_upgrade(star) 个同名同星，
#      当场合成，上阵数不增反减（1 星 2 个就合、2 星 3 个才合，见
#      GameConstants.STAR_UPGRADE_COPIES）；
#   2. 不放重复的唯一棋子：unique_on_board 的棋子棋盘上只允许 board_limit 个，
#      战斗侧 build_tutorial_player_fighters 会用 _is_duplicate_unique_cell 把
#      多出来的那个直接跳过 —— 搬上去也不参战，纯占格子。
func _auto_deploy_from_bench(want: int) -> int:
	if want <= 0:
		return 0
	var cap := GameState.normal_unit_cap()
	# 棋盘上每个 (id, star) 的现有数量，合成按这个口径判。
	var counts := {}
	var unique_used := {}
	for cell in GameState.board_slots:
		if typeof(cell) != TYPE_DICTIONARY:
			continue
		var data := cell as Dictionary
		var key := _merge_key(data)
		counts[key] = int(counts.get(key, 0)) + 1
		var uid := str(data.get("id", ""))
		if not uid.is_empty():
			unique_used[uid] = int(unique_used.get(uid, 0)) + 1
	var moved := 0
	for bench_index in GameState.bench_slots.size():
		if moved >= want or GameState.normal_unit_count() >= cap:
			break
		var bench_cell: Variant = GameState.bench_slots[bench_index]
		if typeof(bench_cell) != TYPE_DICTIONARY:
			continue
		var data := bench_cell as Dictionary
		var star := int(data.get("star", 1))
		# (1) 会触发合成 → 跳过
		if int(counts.get(_merge_key(data), 0)) + 1 >= GameState.copies_to_upgrade(star):
			continue
		# (2) 唯一棋子且棋盘上已经用满额度 → 跳过
		var def: Dictionary = data.get("def", {})
		if bool(def.get("unique_on_board", false)):
			var uid := str(data.get("id", def.get("id", "")))
			var limit := maxi(1, int(def.get("board_limit", 1)))
			if not uid.is_empty() and int(unique_used.get(uid, 0)) >= limit:
				continue
		var board_index := GameState.board_slots.find(null)
		if board_index < 0:
			break
		GameState.board_slots[board_index] = data
		GameState.bench_slots[bench_index] = null
		counts[_merge_key(data)] = int(counts.get(_merge_key(data), 0)) + 1
		var moved_uid := str(data.get("id", ""))
		if not moved_uid.is_empty():
			unique_used[moved_uid] = int(unique_used.get(moved_uid, 0)) + 1
		moved += 1
	return moved

# 合成口径的键：同名**同星**才合成。星级不同不合成（1 星 + 2 星各算各的）。
func _merge_key(cell: Dictionary) -> String:
	return "%s@%d" % [str(cell.get("id", "")), int(cell.get("star", 1))]

func battle_kind() -> String:
	match step:
		Step.START_BOSS:
			return "boss"
		Step.START_PVP:
			return "pvp"
		_:
			return "pve"

func pve_enemy_count() -> int:
	return 4 if step == Step.START_PVE_2 else 3

# 教程战斗强制胜利（10.16 bug 第 1 条，第 1 层兜底）。
#
# 调用点是 BattleResult._finish_simulation() —— 拿到结果之后、任何演出之前。
# 那里是本地模拟路的唯一收口点（BattleUI._finish_simulation 只是 pass 占位，
# BattleResult 才是真身；BattleScreen._process 的 finished 分支与 _skip_animation
# 两条路都汇到它），所以「教程战斗必为胜」由这一处保证，不依赖调用方做对。
#
# 为什么需要它：教程是叙事流程，胜负只由步骤推进表达，战斗本身只是过场。而本地
# 模拟按真实规则判胜负，下面这几条路都会给出「失败 / 平局」：
#   * 空棋盘开局：prepare_tutorial_state 的 no_player_units 强制判负
#     （重启教程 / 断点恢复后棋盘被清空、旁路开战都会走到）；
#   * 双方全灭 → double_ko 平局；
#   * 超时按剩余战力比较 → 1 星棋子可能打不完 80HP 的小怪。
# 原来只有本文件 after_battle() 的 START_PVP 分支改写过结果，且那发生在
# battle_finished 之后 —— 结算字幕（BattleResult._show_result_overlay）早把那句
# 「失败」播完了，玩家先看到失败、再被拽回备战，正是本次反馈的视频现象。
#
# 只改结果字典，**不动 GameState.enemy_formation_hp**：备战界面的敌方法阵血量在
# 教程中途要保持 10/10（START_PVP 通关时由 after_battle() 自己置 0）。
func coerce_victory(result: Dictionary) -> void:
	if result.is_empty():
		return
	result["kind"] = battle_kind()
	result["player_wins"] = true
	result["is_draw"] = false
	result["reason"] = "tutorial_forced_victory"
	result["enemy_alive"] = 0
	result["enemy_hp_current"] = 0

func after_battle(result: Dictionary) -> void:
	match step:
		Step.START_PVE_1:
			# 升 2 星的民兵材料让玩家自己在商店买，不再直接发。
			_apply_shop(UPGRADE_2_SHOP)
			_advance_to(Step.UPGRADE_2)
		Step.START_PVE_2:
			_start_treasure(TREASURE_1)
			_advance_to(Step.TAKE_TREASURE_1)
		Step.START_BOSS:
			_start_treasure(TREASURE_2)
			_advance_to(Step.TAKE_TREASURE_2)
		Step.START_PVP:
			coerce_victory(result)
			GameState.enemy_formation_hp = 0
			_advance_to(Step.DONE)
	GameState.gold = TUTORIAL_GOLD
	save_checkpoint(true)

func current_text() -> String:
	match step:
		Step.BUY_3:
			# 9.13 #4：第 3 个棋子买完、商店还开着时，这一步的后半段改成「关闭商店」。
			# 步骤号仍是 1/17（step 未变），关掉商店后 sync() 才推进到第 2 步。
			if _owned_normal_count() >= 3 and _fill_shop_open:
				return _t("点击「商店」界面外的地方关闭「商店」。", "Tap outside the shop to close it.")
			return _t("点击下方「商店」按钮打开商店，点击商店棋子，再点击采购按钮。买到的棋子会先进入待命区。已拥有：%d/3" % mini(_owned_normal_count(), 3), "Tap the Shop button at the bottom to open the shop, tap a unit, then tap Buy. Bought units go to standby first. Owned: %d/3" % mini(_owned_normal_count(), 3))
		Step.PLACE_3:
			return _t("从待命区把 3 个棋子拖到棋盘。棋盘上的棋子才会参战。", "Drag 3 units from standby onto the board. Only board units fight.")
		Step.START_PVE_1:
			return _t("已经上阵 3 个棋子，点击开始战斗，打 3 个小怪。", "You placed 3 units. Start battle to fight 3 monsters.")
		Step.UPGRADE_2:
			return _t("在商店买 1 个「民兵」（不够就点刷新）。凑够 2 个相同棋子会自动合成，民兵就升到 2 星。", "Buy 1 Militia from the shop (refresh if needed). Two matching units merge automatically, taking your Militia to 2-star.")
		Step.START_PVE_2:
			return _t("主力已经 2 星了。再开始战斗，这次打 4 个小怪。", "Your main unit is 2-star. Start battle again against 4 monsters.")
		Step.TAKE_TREASURE_1:
			return _t("选择一个宝藏。拿到的宝藏会显示在左下角。", "Choose a treasure. Owned treasures appear at the bottom-left.")
		Step.UPGRADE_3:
			return _t("已经送你 1 个 2 星民兵。再去商店买 2 个民兵（不够就刷新），它们会先合成 2 星，凑够 3 个 2 星就自动升到 3 星。", "You received one 2-star Militia. Buy 2 more Militia from the shop (refresh if needed) — they merge into a 2-star, and three 2-stars merge into a 3-star.")
		Step.UPGRADE_OTHERS:
			return _t("在商店买弓手和商人各 1 个（不够就刷新），会各自和场上的同名棋子自动合成到 2 星。", "Buy 1 Archer and 1 Merchant from the shop (refresh if needed). Each merges automatically with its matching board unit to reach 2-star.")
		Step.BOND_HINT:
			return _t("同族数量够了会激活羁绊。看看左侧的羁绊效果，点一下继续。", "Matching races activate bonds. Check the bond effects on the left, then tap to continue.")
		Step.VIEW_TREASURE:
			return _t("点击左下角的宝藏图标，看看已获得宝藏的效果。", "Tap the treasure icon at the bottom-left to see your treasure's effect.")
		Step.START_BOSS:
			return _t("阵容变强了，点击开始战斗挑战 Boss。", "Your team is stronger. Start battle to challenge the Boss.")
		Step.TAKE_TREASURE_2:
			return _t("Boss 打完后，再选择一个宝藏强化阵容。", "After the Boss, choose another treasure to strengthen your team.")
		Step.CARROT_CAMP:
			return _t("新资源「萝卜」来了！点击右侧的「萝卜营地」。宠物每回合会自动收获萝卜，萝卜用来雇佣兵和抽升级石。",
				"New resource: carrots! Tap Carrot Camp on the right. Your pet harvests carrots every round — spend them on mercenaries and upgrade stones.")
		Step.HARVEST_UPGRADE:
			return _harvest_upgrade_text()
		Step.CARROT_HARVEST:
			return _t("新回合开始，宠物自动收获了 %d 萝卜——升级后的采集生效了。点一下，领取教学奖励 %d 萝卜。" % [_carrot_harvest_gain, TUTORIAL_CARROT_GIFT],
				"A new round: your pet harvested %d carrots — your harvest upgrade is working. Tap to claim a %d-carrot tutorial bonus." % [_carrot_harvest_gain, TUTORIAL_CARROT_GIFT])
		Step.DRAW_STONE:
			return _draw_stone_text()
		Step.FOUR_STAR:
			return _four_star_text()
		Step.HIRE_MERC:
			return _t("打开佣兵面板，用萝卜召唤 2 个佣兵。花掉的萝卜会让萝卜营地升级（容量、产量、金币收益都会提高）。佣兵是额外战力，但不算羁绊。",
				"Open the mercenary panel and hire 2 mercenaries with carrots. Spending carrots levels up Carrot Camp (more capacity, yield and gold). Mercenaries add power but do not count for bonds.")
		Step.FILL_7:
			return _fill_step_text()
		Step.FORMATION_HP:
			return _t("看上方血条——教学局法阵 HP 是 10，把敌方法阵打到归零就胜利。点一下继续。", "See the HP bar above — tutorial formation HP is 10. Bring the enemy's to 0 to win. Tap to continue.")
		Step.START_PVP:
			return _t("点击开始战斗进入 PVP，赢下最后一战。", "Start battle for PVP and win the final fight.")
		_:
			return _t("教学胜利。", "Tutorial victory.")

func update_overlay() -> void:
	if not active or _target_provider == null or _overlay == null:
		return
	if _overlay_suppressed:
		_overlay.visible = false
		return
	_overlay.visible = true
	var target := _target_control()
	var rect := Rect2(Vector2(540, 290), Vector2(200, 80))
	if target is Control and target.is_inside_tree():
		# Targets can belong to a modal CanvasLayer. Convert through canvas space
		# before assigning the overlay's local position.
		var to_overlay := _overlay.get_global_transform_with_canvas().affine_inverse() \
			* target.get_global_transform_with_canvas()
		rect = to_overlay * Rect2(Vector2.ZERO, target.size)
	elif _last_target_rect.size.x > 0.0 and _last_target_rect.size.y > 0.0:
		# 9.25 教程优化第 6 条（配套）：目标这一刻解析不出来（上面的空反馈）时，
		# **沿用上一次的位置**，不要让箭头掉到屏幕中央那个占位矩形上去。
		# 这样 transient 的空目标对玩家完全不可见：箭头原地不动，下一帧目标回来了自然对上。
		rect = _last_target_rect
	var dir := _arrow_dir()
	# 聚焦遮罩每帧跟上目标（2026-10-15 问题 2）。刻意放在下面那段「版面没变就早退」
	# **之前**：遮罩只依赖 rect 与 overlay 尺寸，代价是 4 次赋值，而早退的判据里
	# `safe` 是被安全区裁剪过的，存在"overlay 变宽但 safe 没变"的组合（安全区比
	# overlay 小的时候），把遮罩塞进重排分支就会在那一种情形下留着旧尺寸。
	# 目标既没解析出来、也没有上一次的位置（开机第一帧）时不留洞：
	# 那时的 rect 是 (540,290,200,80) 那个占位矩形，照它开洞等于在屏幕中央凭空
	# 亮出一块 —— 宁可整幅压暗。
	var focus := rect
	if not (target is Control and target.is_inside_tree()) \
			and not (_last_target_rect.size.x > 0.0 and _last_target_rect.size.y > 0.0):
		focus = Rect2()
	# 关商店 / 上阵布阵这两处整幅不压暗（反馈 2026-10-15 第二轮，见 focus_mask_disabled_for）。
	# 做法是**把遮罩整块藏掉**，而不是"给一个填满屏幕的洞" —— 后者会白留一个满屏的
	# 半透明 quad 每帧参与混合，视觉上也没区别。
	var mask_on := not focus_mask_disabled()
	var dim := _focus_dim_node()
	if dim != null and dim.visible != mask_on:
		dim.visible = mask_on
	if mask_on:
		_update_focus_dim(focus)
	var next_text := current_text()
	if _text.text != next_text:
		_text.text = next_text
	_update_progress()
	var safe := _safe_rect()
	var keep_clear := _keep_clear_rects()
	var content_key := _overlay_content_key(target, next_text, dir)
	if not _layout_signature.is_empty() and _layout_inputs_equivalent(
			content_key, rect, safe, keep_clear):
		_update_guide_light(focus)
		return
	var signature := _overlay_layout_signature(target, rect, next_text, dir)
	var previous_signature := _layout_signature
	_layout_signature = signature
	_last_content_key = content_key
	_last_target_rect = rect
	_last_safe_rect = safe
	_last_keep_clear_rects = keep_clear.duplicate()
	_layout_recompute_count += 1
	_last_layout_reason = "initial" if previous_signature.is_empty() else "inputs_changed"
	# Measure the combined minimum after content changed. Reading size immediately
	# after reset_size() used to alternate between stale and settled container sizes.
	_fit_bubble()
	var target_id := target.get_instance_id() if target != null and is_instance_valid(target) else 0
	var context := "%d|%d" % [step, target_id]
	_bubble.position = _bubble_position(rect, dir, context)
	_position_chrome()
	_position_guide(rect, keep_clear)
	_update_guide_light(focus)
	_continue_btn.visible = false


# 「这一步该不该整幅压暗」的**纯判据**：只看状态，不碰节点。
# 拆成一个纯函数是为了让门禁能直接喂参数验真值表，不必去伪造 GameState 的棋盘/商店。
#
# 反馈（2026-10-15 第二 / 第三轮，共 5 张真机截图）明令这些步骤**取消遮罩** —— 因为它们
# 要玩家做的动作**正好落在被压暗的区域上**，遮罩不是在帮忙，是在挡路：
#   ① `BUY_3` 的「关闭商店」子阶段：要点的就是**商店外面**的地方，而遮罩恰好把外面全压暗
#      （洞开在商店上）—— 指引和画面完全拧着。注意判的是**子阶段**（step 仍是 BUY_3），
#      不是整个 BUY_3：正常「购买棋子」那一段遮罩是有效的，要留着。
#   ② `PLACE_3`（上阵布阵）：要从待命区把棋子拖到棋盘，起手必须看清并落在**被压暗的
#      待命区**上。压暗后待命区的棋子几乎看不见（实测真机反馈「无法拖动操作」）；
#      把它**藏掉**即可，不必碰输入。
#      ⚠ 旧注释曾把结论写成「遮罩不吃输入」——作为泛化是**错的**：覆盖层里那个
#      `modulate.a = 0` 的 `_hotspot`（Button + STOP）确实会吃点击，已在第三轮整个删除
#      （见 `_input()` 一节）。这里取消遮罩的理由只有一条：**看不清**。
#   ③ `TAKE_TREASURE_1` / `TAKE_TREASURE_2`（步骤 6/22、15/22「选择宝藏」）：宝藏三选一
#      本身就是一整块全屏面板，已经把别处盖住了；再叠一层压暗只会把「长按看详情」要读的
#      卡面糊掉，指引价值为零。
#   ④ `FILL_7`（步骤 20/22「补满七人」）：与 `PLACE_3` 同理 —— 要把待命区的棋子拖上棋盘，
#      压暗后待命区几乎看不见。
func focus_mask_disabled_for(step_value: int, shop_close_phase: bool) -> bool:
	if step_value == Step.PLACE_3:
		return true
	if step_value == Step.BUY_3 and shop_close_phase:
		return true
	if step_value in [Step.TAKE_TREASURE_1, Step.TAKE_TREASURE_2, Step.FILL_7]:
		return true
	return false


# `shop_close_phase` 沿用 current_text() / step_display_name() 里那个「买够 3 个且商店还开着」的判据，
# 三处必须同源，否则会出现"标题写着关闭商店、遮罩却还在压暗"这种半截状态。
func focus_mask_disabled() -> bool:
	return focus_mask_disabled_for(step, _owned_normal_count() >= 3 and _fill_shop_open)


func _focus_dim_node() -> ColorRect:
	if _focus_dim.is_empty():
		return null
	var dim := _focus_dim[0]
	if dim == null or not is_instance_valid(dim):
		return null
	return dim


# 把「洞」交给遮罩的 shader（2026-10-15 问题 2；同日返工改为单块 + 逐片元开洞）。
# 洞口 = 目标矩形外扩 FOCUS_HOLE_PADDING，再裁进 overlay，最后换算成控件 UV（0..1）。
# 洞退化成空（目标解析不出来）时把 hole_on 置 0，等价于整幅压暗。
#
# ⚠ 这里刻意**不碰**节点的 position / size：这块 quad 被 FULL_RECT 锚定，
#   矩形恒等于整幅 overlay。每帧只写 uniform ⇒ 几何零变化 ⇒ 目标再怎么漂，
#   遮罩边缘也不会做亚像素游走 —— 那正是玩家实测报的「屏幕会闪 + 1px 亮线」的来源。
func _update_focus_dim(hole: Rect2) -> void:
	if _focus_dim.is_empty():
		return
	var dim := _focus_dim[0]
	if dim == null or not is_instance_valid(dim):
		return
	var mat := dim.material as ShaderMaterial
	if mat == null:
		return
	var ov: Control = _overlay
	if ov == null or not is_instance_valid(ov):
		return
	var full := Rect2(Vector2.ZERO, ov.size)
	if full.size.x <= 0.0 or full.size.y <= 0.0:
		return
	# ⚠ 先判空再 grow：`Rect2().grow(6)` 会在原点长出一个 12×12 的洞，
	# 于是"没有目标"会变成"左上角亮一小块"。
	var h := hole if hole.size.x > 0.0 and hole.size.y > 0.0 else Rect2()
	if h.size.x > 0.0 and h.size.y > 0.0:
		h = h.grow(FOCUS_HOLE_PADDING).intersection(full)
	if h.size.x <= 0.0 or h.size.y <= 0.0:
		# 洞没了（或整个落在 overlay 外）：整幅压暗，不留洞。
		mat.set_shader_parameter("hole_on", 0.0)
		return
	mat.set_shader_parameter("hole", Vector4(
		h.position.x / full.size.x,
		h.position.y / full.size.y,
		h.size.x / full.size.x,
		h.size.y / full.size.y))
	mat.set_shader_parameter("hole_on", 1.0)


func set_overlay_suppressed(suppressed: bool) -> void:
	if _overlay_suppressed == suppressed:
		return
	_overlay_suppressed = suppressed
	_layout_signature = ""
	if _overlay != null and is_instance_valid(_overlay):
		_overlay.visible = not suppressed
	if not suppressed:
		update_overlay()


func layout_debug_snapshot() -> Dictionary:
	return {
		"step": step_key(),
		"signature": _layout_signature,
		"context": _layout_context,
		"bubble_rect": _bubble.get_global_rect() if _bubble != null and is_instance_valid(_bubble) else Rect2(),
		"guide_rect": _guide.get_global_rect() if _guide != null and is_instance_valid(_guide) else Rect2(),
		"light_target_rect": _light.target_rect if _light != null and is_instance_valid(_light) else Rect2(),
		"candidate_index": _last_candidate_index,
		"recompute_count": _layout_recompute_count,
		"reason": _last_layout_reason,
		"suppressed": _overlay_suppressed,
	}

func total_steps() -> int:
	return STEP_SEQUENCE.size()

# 步骤序号从 1 开始。指针只向前找下一个匹配项，所以同一个 Step 被重复走到时
# 拿到的是后一个位置，不会出现「15 跳回 11」。
func _sync_progress_index() -> void:
	if step == Step.DONE:
		_progress_index = STEP_SEQUENCE.size() - 1
		return
	if _progress_index < STEP_SEQUENCE.size() and STEP_SEQUENCE[_progress_index] == step:
		return
	for i in range(_progress_index + 1, STEP_SEQUENCE.size()):
		if STEP_SEQUENCE[i] == step:
			_progress_index = i
			return
	# 前面找不到（理论上只有回退流程才会），退回全表首次匹配。
	var first := STEP_SEQUENCE.find(step)
	if first >= 0:
		_progress_index = first

func step_number() -> int:
	return _progress_index + 1

# 步骤代号（枚举名，如 UPGRADE_2）。**内部标识，不得直接显示给玩家。**
# 玩家可见的名字走 step_display_name()。V2 R-09 记的正是这个键漏到界面上：
# 教学气泡右上角原本直接打 BUY_3 / FORMATION_HP / START_BOSS / FILL_7。
func step_key() -> String:
	var keys: Array = Step.keys()
	if step >= 0 and step < keys.size():
		return str(keys[step])
	return "?"


# 玩家可见的步骤名。
#
# 三条硬要求（V2 P1-06）：
#   1. 任何分支都不能返回枚举名或其它内部标识；
#   2. 缺文案时的兜底也必须是玩家看得懂的话，不能是 "?" 或步骤代号；
#   3. 中英都要有 —— 沿用本文件通用的 _t() 惯例，它读 LocaleManager.get_locale()。
# 由 tools/tutorial_text_leak_check 逐值守住。
func step_display_name() -> String:
	match step:
		Step.BUY_3:
			# 9.13 #4：关商店子阶段换个玩家可见的名字，免得标题还写着「购买棋子」
			# 而正文在让他关商店。
			if _owned_normal_count() >= 3 and _fill_shop_open:
				return _t("关闭商店", "Close Shop")
			return _t("购买棋子", "Buy Units")
		Step.PLACE_3:
			return _t("上阵布阵", "Place Units")
		Step.START_PVE_1:
			return _t("首场战斗", "First Battle")
		Step.UPGRADE_2:
			return _t("升到 2 星", "Reach 2-Star")
		Step.START_PVE_2:
			return _t("第二场战斗", "Second Battle")
		Step.TAKE_TREASURE_1:
			return _t("选择宝藏", "Choose Treasure")
		Step.UPGRADE_3:
			return _t("升到 3 星", "Reach 3-Star")
		Step.UPGRADE_OTHERS:
			return _t("继续升星", "Upgrade More")
		Step.BOND_HINT:
			return _t("查看羁绊", "Check Synergies")
		Step.VIEW_TREASURE:
			return _t("查看宝藏", "View Treasures")
		Step.START_BOSS:
			return _t("挑战首领", "Boss Battle")
		Step.TAKE_TREASURE_2:
			return _t("再选宝藏", "Choose Again")
		Step.CARROT_CAMP:
			return _t("萝卜营地", "Carrot Camp")
		Step.HARVEST_UPGRADE:
			return _t("升级采集", "Upgrade Harvest")
		Step.CARROT_HARVEST:
			return _t("收获萝卜", "Carrot Harvest")
		Step.DRAW_STONE:
			return _t("抽升级石", "Draw a Stone")
		Step.FOUR_STAR:
			return _t("升到四星", "Reach 4-Star")
		Step.HIRE_MERC:
			return _t("召唤佣兵", "Hire Mercenaries")
		Step.FILL_7:
			return _t("补满七人", "Fill Seven Slots")
		Step.FORMATION_HP:
			return _t("了解法阵", "Formation HP")
		Step.START_PVP:
			return _t("玩家对战", "Player Battle")
		Step.DONE:
			return _t("教学完成", "Tutorial Complete")
	# 兜底：新增步骤但忘了在上面补一行时走到这里。玩家看到的是一句通用的话，
	# 不是 "?" 也不是枚举名 —— 漏文案是我们的问题，不该由玩家来读代号。
	return _t("教学步骤", "Tutorial Step")

func progress_text() -> String:
	var total := total_steps()
	if step == Step.DONE:
		return _t("教学完成 %d/%d" % [total, total], "Complete %d/%d" % [total, total])
	return _t("步骤 %d/%d" % [step_number(), total], "Step %d/%d" % [step_number(), total])

func _update_progress() -> void:
	if _progress_label == null or not is_instance_valid(_progress_label):
		return
	_sync_progress_index()
	_progress_label.text = _t("狗狗 · ", "Guide · ") + progress_text()
	_step_name_label.text = step_display_name()
	_progress_bar.value = float(step_number())

# 候选气泡的首选方向：目标在上方时放到下方，左侧面板时放到右侧。
func _arrow_dir() -> int:
	# 萝卜 / 四星教学按当前控件定气泡方向；实际光线由控件位置实时计算。
	var carrot_target := _carrot_target_id()
	if not carrot_target.is_empty():
		match carrot_target:
			TutorialTargetProviderScript.TARGET_CARROT_CAMP_TAB, \
			TutorialTargetProviderScript.TARGET_CARROT_STONE_TAB:
				return ArrowDir.DOWN
			TutorialTargetProviderScript.TARGET_FOUR_STAR_ROW:
				return ArrowDir.LEFT
			_:
				return ArrowDir.UP
	match step:
		Step.BOND_HINT, Step.VIEW_TREASURE:
			return ArrowDir.LEFT
		# HIRE_MERC 的两个目标（右上角佣兵按钮、面板里的佣兵手牌）都在上半屏，
		# 箭头压在它们下面朝上指，气泡再排到箭尾下方，才不会盖住要点的东西。
		Step.START_PVE_1, Step.START_PVE_2, Step.START_BOSS, Step.START_PVP, Step.FORMATION_HP, Step.HIRE_MERC:
			return ArrowDir.UP
	return ArrowDir.DOWN

func _guide_texture() -> Texture2D:
	match step:
		Step.BUY_3, Step.START_PVE_1, Step.TAKE_TREASURE_1, Step.TAKE_TREASURE_2:
			return DOG_WELCOME
		Step.BOND_HINT, Step.VIEW_TREASURE, Step.FORMATION_HP, \
		Step.CARROT_CAMP, Step.HARVEST_UPGRADE, Step.CARROT_HARVEST:
			return DOG_EXPLAIN
		Step.UPGRADE_3, Step.FOUR_STAR, Step.FILL_7:
			return DOG_ENCOURAGE
	return DOG_GUIDE


# The target provider supplies live rectangles, including the redesigned carrot
# camp controls. Place the mascot around the existing bubble while scoring both
# against the target and every keep-clear control. Neither node receives input.
func _position_guide(target_rect: Rect2, keep_clear: Array[Rect2]) -> void:
	if _guide == null or not is_instance_valid(_guide):
		return
	_guide.texture = _guide_texture()
	var safe := _safe_rect()
	var side := clampf(safe.size.y * 0.18, 96.0, 145.0)
	_guide.size = Vector2.ONE * side
	var bubble := Rect2(_bubble.position, _bubble.size)
	var candidates: Array[Vector2] = [
		Vector2(bubble.position.x - side - 8.0, bubble.end.y - side),
		Vector2(bubble.end.x + 8.0, bubble.end.y - side),
		Vector2(bubble.position.x - side - 8.0, bubble.position.y),
		Vector2(bubble.end.x + 8.0, bubble.position.y),
		Vector2(safe.position.x, safe.end.y - side),
		Vector2(safe.end.x - side, safe.end.y - side),
		Vector2(safe.position.x, safe.position.y),
		Vector2(safe.end.x - side, safe.position.y),
	]
	var skip_rect := Rect2(_skip_btn.position, _skip_btn.size) if _skip_btn != null else Rect2()
	var best := candidates[0]
	var best_score := INF
	for i in candidates.size():
		var pos := _clamp_into(candidates[i], _guide.size, safe)
		var area := Rect2(pos, _guide.size)
		var score := _overlap_area(area, target_rect) * 30.0
		score += _overlap_area(area, bubble) * 12.0
		score += _overlap_area(area, skip_rect) * 20.0
		for blocked in keep_clear:
			score += _overlap_area(area, blocked) * 8.0
		score += pos.distance_to(bubble.position) * 0.5 + float(i) * 12.0
		if score < best_score:
			best_score = score
			best = pos
	_guide.position = best


func _update_guide_light(target_rect: Rect2) -> void:
	if _light == null or _guide == null or not is_instance_valid(_light) \
			or not is_instance_valid(_guide):
		return
	var medal := _guide.position + _guide.size * Vector2(0.63, 0.70)
	_light.aim(medal, target_rect, PlayerProfile.reduced_motion_enabled)

# V2 P1-09：常驻控件（跳过按钮、进度条所在的气泡）也要落在安全区内。
# 跳过按钮原本写死在 (16, 44)；横屏时刘海在左边缘，正好压住它。
func _position_chrome() -> void:
	if _skip_btn == null or not is_instance_valid(_skip_btn):
		return
	var safe := _safe_rect()
	var size := _skip_btn.size
	if size.x <= 0.0 or size.y <= 0.0:
		size = _skip_btn.custom_minimum_size
	_skip_btn.position = _clamp_into(Vector2(16.0, 44.0), size, safe)


# 把一棵子树整个设成不吃点击（2026-10-15 第三轮反馈：遮罩/气泡不许限制玩家操作）。
#
# ⚠ 必须**递归**。Godot 的 GUI 命中测试是逐控件做的，`mouse_filter` 也不是继承属性：
#   `PanelContainer` / `MarginContainer` / `VBoxContainer` 的默认值都是 **STOP**（不是
#   PASS），所以「把气泡那一个 PanelContainer 设成 IGNORE」根本不成立 —— 它下面那层
#   MarginContainer 照样会把落在气泡矩形里的点击吃掉。只改父节点属于半截修法，
#   真机表现就是「气泡底下的按钮点不动」这种「操作受限」。
#   （`Label` 默认就是 IGNORE；`_continue_btn` 也是 Button(STOP)，但它的 `visible`
#    恒为 false，不参与命中测试。真要用它，得先把它自己的 mouse_filter 改回来。）
func _make_mouse_transparent(node: Node) -> void:
	var ctl := node as Control
	if ctl != null:
		ctl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in node.get_children():
		_make_mouse_transparent(child)


func _on_skip_pressed() -> void:
	if not active:
		return
	_show_skip_confirm()

# 跳过确认改走 DialogService（V3 P1-02 / P1-03）。
#
# 原来这里现场 new 出 ColorRect + PanelContainer + 两个 140×40 的默认 Button：
#   - 40 的按钮高度低于手机 48 dp 触控下限，且两个按钮长得一模一样，没有主次；
#   - 遮罩 add_child 到教程自己的 _overlay 上，教程销毁时机不对就会留在树上吃输入；
#   - 没有按压态，玩家点下去没有任何反馈。
# 现在遮罩归 ModalStack、外观归 GloryTheme、防连点归组件的 resolved-once 合同。
const SkipDialog := preload("res://ui/components/GloryConfirmDialog.gd")
const SKIP_DIALOG_REQUEST := "tutorial_skip"


func _show_skip_confirm() -> void:
	# request_id 固定：连点「跳过」只会有一个框（DialogService 按 id 合并）。
	DialogService.confirm({
		"request_id": SKIP_DIALOG_REQUEST,
		"owner": self,
		"intent": SkipDialog.Intent.DANGER,
		"title": _t("跳过新手教学", "Skip Tutorial"),
		"body": _t("确定跳过整段新手教学吗？将直接回到主菜单。",
			"Skip the whole tutorial and return to the main menu?"),
		"confirm_text": _t("跳过", "Skip"),
		"cancel_text": _t("继续教学", "Keep Playing"),
		"on_result": _on_skip_dialog_result,
	})


func _on_skip_dialog_result(result: String, _request_id: String) -> void:
	if result != SkipDialog.RESULT_CONFIRMED:
		return
	if not active:
		return
	AnalyticsService.tutorial_skipped(step_key(), step_number())
	skip_requested.emit()

# ── 「点一下继续」的四个步骤：改成**旁听**真实点击（2026-10-15 第三轮反馈）──────────
#
# 反馈原文：「此次修复增加的遮罩，你改动一下，不要增加玩家操作的**限制**，仅设为提醒和
# 明亮度的不同，但是其他操作都可以做的，就不会引发这么多问题」。
#
# 于是教程覆盖层里**再没有任何一个吃点击的节点**：
#   * 透明热点 `_hotspot`（Button + `MOUSE_FILTER_STOP`；BOND_HINT / VIEW_TREASURE 时
#     盖在目标上，FORMATION_HP / CARROT_HARVEST 时铺满整屏）—— **整个删掉**；
#   * 气泡 `_bubble` 连同 MarginContainer / VBoxContainer 子树 —— 一律 IGNORE
#     （见 `_make_mouse_transparent()`：只把父节点设 IGNORE 不够，Container 默认是 STOP）。
# 覆盖层剩下的三样 —— 变暗、箭头、文字 —— 本来就只有「看」这一种用法。
#
# 推进改由 `_input()` **旁听**：按下落在当前步骤的受理范围内就推进，并且
# **绝不 `set_input_as_handled()`** —— 同一次点击照常穿透到下面那个真控件上
# （点羁绊栏真的会开羁绊说明、点宝藏图标真的会打开宝藏面板）。这才是「其他操作都可以做」
# 的字面实现：遮罩只负责明暗，不负责放行。
#
# 顺序上为什么安全：Godot 的 `Viewport.push_input()` 先派发 `Node._input()`，再做 GUI 命中
# 测试。所以在 `_input` 里推进 step 影响不到**这一次**点击落在哪个控件上；而推进后请求的
# 视图刷新走 `_refresh_prep()` → `ACTION_REFRESH_VIEW` → `PrepUI._tutorial_refresh_view()`
# → `_refresh_all.call_deferred()`，天然延迟到本帧 GUI 之后（与 `ShopPanel` 恢复木牌必须
# `set_deferred` 是同一条教训）。
#
# 坐标口径：`_input()` 收到的 `event.position` 已经是**画布空间**，与
# `Control.get_global_rect()` 同一坐标系，直接比即可（`PrepScreen._input` 就是这么写的）。
# ⚠ 别套用 `pos * win / canvas` 那套换算 —— 那是 `Viewport.push_input()` 的口径（它收
#   窗口坐标），两者混用是这套代码里踩过的坑。
func _input(event: InputEvent) -> void:
	if not active or _overlay_suppressed:
		return
	if _overlay == null or not is_instance_valid(_overlay) or not _overlay.visible:
		return
	var pos := Vector2.INF
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if not button.pressed or button.button_index != MOUSE_BUTTON_LEFT:
			return
		pos = button.position
	elif event is InputEventScreenTouch:
		# 触屏设备上 Godot 默认会把每次触摸**再补发一个同位置、同一批 flush 的鼠标事件**
		# （`input_devices/pointing/emulate_mouse_from_touch`，与
		# `ModalStack._mouse_emulated()` 同一个判据）。两个分支都受理的话一次点击会推进
		# 两格 —— VIEW_TREASURE（要真的点到宝藏图标）→ FORMATION_HP（任意处都算）正好是
		# 能撞上的组合，所以补发存在时只认鼠标那一条。
		if bool(ProjectSettings.get_setting(
				"input_devices/pointing/emulate_mouse_from_touch", true)):
			return
		var touch := event as InputEventScreenTouch
		if not touch.pressed:
			return
		pos = touch.position
	else:
		return
	if not _tap_advance_accepts(pos):
		return
	confirm_tap_step()


# 这四个步骤是不是「点一下继续」型。其余步骤全靠真实进度推进（买够/上阵/升星/关面板…），
# 点哪儿都不该跳步 —— 所以受理范围必须**只**覆盖这四步。
func is_tap_step() -> bool:
	return step in [Step.BOND_HINT, Step.VIEW_TREASURE, Step.FORMATION_HP, Step.CARROT_HARVEST]


# 受理范围。与已上线那一版**透明热区的范围逐字对齐** —— 本次改的只是「吃不吃输入」，
# 不是「点哪儿算数」：
#   * BOND_HINT / VIEW_TREASURE：必须真的点到羁绊栏 / 宝藏图标（目标矩形 + TAP_TARGET_PAD）。
#     目标这一刻解析不出来时退回「任意处受理」—— 否则玩家会被一个解析不出来的目标卡死，
#     而那正是「引发更多问题」的形状。
#   * FORMATION_HP / CARROT_HARVEST：讲解 + 领奖，本来就没有对应的真实操作，任意处都算。
# 唯一的例外是「跳过教学」按钮自己的矩形：那一下是去开跳过确认框的，顺手再推一格只会让
# 两个弹窗叠在一起。
func _tap_advance_accepts(pos: Vector2) -> bool:
	if not is_tap_step():
		return false
	if _skip_btn != null and is_instance_valid(_skip_btn) and _skip_btn.visible \
			and _skip_btn.get_global_rect().has_point(pos):
		return false
	if step in [Step.FORMATION_HP, Step.CARROT_HARVEST]:
		return true
	var target := _target_control()
	if target == null or not target.is_inside_tree():
		return true
	return target.get_global_rect().grow(TAP_TARGET_PAD).has_point(pos)


# 四个「点一下继续」步骤的推进入口。由 `_input()` 在真实按下落在受理范围内时调用；
# 门禁也可以直接调（`tools/tutorial_checkpoint_check.gd` / `tutorial_step15_flow_check.gd`
# / `tutorial_carrot_flow_check.gd` 就是这么驱动教程的）。
#
# ⚠ 名字从 `_on_hotspot_pressed()` 改过来了：透明热点 `_hotspot` 已删掉（它会吃点击），
#   所以这里不再是某个按钮的回调，而是「玩家在目标上点了一下」这件事的处理。
func confirm_tap_step() -> void:
	match step:
		Step.BOND_HINT:
			_advance_to(Step.VIEW_TREASURE)
		Step.VIEW_TREASURE:
			_advance_to(Step.FORMATION_HP)
		Step.FORMATION_HP:
			if GameState.normal_unit_count() >= 7 and _mercenary_count() >= 2:
				_advance_to(Step.START_PVP)
			elif GameState.harvest_tech_level < 1:
				# 第一次讲完法阵 HP：Boss 之前先认识萝卜营地（萝卜入口此刻才出现）。
				_advance_to(Step.CARROT_CAMP)
				_refresh_prep()
			else:
				_advance_to(Step.START_BOSS)
		Step.CARROT_HARVEST:
			if not _carrot_harvested:
				_run_tutorial_harvest()
			# 奖励必须在 _advance_to() 之前落到状态上：推进会立刻写断点。
			if not _carrot_gift_claimed:
				GameState.carrots += TUTORIAL_CARROT_GIFT
				_carrot_gift_claimed = true
			_ensure_four_star_candidate()
			_advance_to(Step.DRAW_STONE)
			_refresh_prep()
		_:
			return
	update_overlay()

# --- 教程断点（V2 P1-08）------------------------------------------------------
#
# 为什么需要它：`SaveManager._write_now()` 第一行是 `if GameState.tutorial_mode: return`，
# 教程期间主存档整个被跳过。所以 Back 退出、被系统杀死或切后台之后，
# 回来必然从 BUY_3 重来 —— 这正是 R-10 记录的现象。
#
# 断点只存**语义步骤与可重建的数据**，不存任何 Node 引用（MD 要求「幂等、可恢复」）。
# 2（9.25）：Step 枚举中间插入了萝卜 / 四星教学的 5 步，旧断点里的步骤编号全部错位。
# 版本不符时 restore_checkpoint() 返回 false，调用方回到「从头开始教程」，
# 绝不把旧编号套进新枚举里恢复出一个错步的状态。
const CHECKPOINT_VERSION := 2

# 写盘节流用的进度签名。sync() 每次 _refresh_all() 都会跑，
# 不加签名就会变成每帧写文件。
var _checkpoint_signature := ""


# 唯一的运行时推进入口（V3 P0-08）。
#
# 此前 step 是十几处直接赋值，其中确认型的两处 —— _on_continue_pressed() 与
# confirm_tap_step()（当时还叫 _on_hotspot_pressed()）—— 忘了落盘。玩家按下「继续」
# 之后强杀 app，回来还在
# 按之前那一步：断点要等下一次 sync() 才跟上，而那两步之后玩家做的第一件事
# 就是开战，中间隔着整场战斗。
#
# 逐点补 save_checkpoint() 治不住：下次加步骤照样会漏。所以收口成一个入口，
# 并由门禁断言别处不得直接赋值 step。
#
# 链式推进（一次 sync() 里连推三步）会写三次盘。留着不优化：save_tutorial()
# 是一次原子写，教程全程也就几十次，而任何「攒着最后写」的做法都要引入一个
# 必须记得清的标志位 —— 那正是这条缺陷的形状。
func _advance_to(next_step: int) -> void:
	if step == next_step:
		return
	# 运营数据的教学漏斗也从这唯一的推进入口记：走完哪一步、停了多久（DONE = 整段完成）。
	var from_key := step_key()
	var from_number := step_number()
	step = next_step
	_sync_progress_index()
	save_checkpoint()
	AnalyticsService.tutorial_step(from_key, step_key(), from_number)


func save_checkpoint(force: bool = false) -> void:
	if not active:
		return
	var signature := _checkpoint_progress_signature()
	if not force and signature == _checkpoint_signature:
		return
	_checkpoint_signature = signature
	SaveManager.save_tutorial({
		"version": CHECKPOINT_VERSION,
		"locale": LocaleManager.get_locale(),
		"step": step,
		"progress_index": _progress_index,
		"bought_units": bought_units,
		"fill": {
			"started": _fill_started,
			"phase": _fill_phase,
			"buy_target": _fill_buy_target,
			"bought": _fill_bought,
			"shop_open": _fill_shop_open,
			"compensated": _fill_compensated,
		},
		"round_index": GameState.round_index,
		"gold": GameState.gold,
		# 9.25 起教学也用萝卜雇佣兵、抽升级石、升四星，这几项都是教学进度的一部分。
		"carrot_tutorial": {
			"harvested": _carrot_harvested,
			"harvest_gain": _carrot_harvest_gain,
			"gift_claimed": _carrot_gift_claimed,
		},
		"carrots": GameState.carrots,
		"harvest_tech_level": GameState.harvest_tech_level,
		"merc_carrots_spent_total": GameState.merc_carrots_spent_total,
		"last_harvest_round": GameState.last_harvest_round,
		"stone_draw_used_round": GameState.stone_draw_used_round,
		"stone_draw_count": GameState.stone_draw_count,
		"team_upgrade_stones": GameState.team_upgrade_stones.duplicate(true),
		"player_formation_hp": GameState.player_formation_hp,
		"enemy_formation_hp": GameState.enemy_formation_hp,
		"board_slots": GameState.board_slots.duplicate(true),
		"bench_slots": GameState.bench_slots.duplicate(true),
		"mercenary_slots": GameState.mercenary_slots.duplicate(true),
		"shop_offers": GameState.shop_offers.duplicate(true),
		"shop_sold": GameState.shop_sold.duplicate(true),
		"owned_treasures": GameState.owned_treasures.duplicate(),
		"claimed_treasure_rounds": GameState.claimed_treasure_rounds.duplicate(),
		"pending_treasure": GameState.pending_treasure.duplicate(true),
		"pve_completed": GameState.pve_completed,
		"boss_completed": GameState.boss_completed,
	})


# 进度签名只取「玩家实际推进了什么」，不取金币这类每帧会被 sync() 重置的量。
func _checkpoint_progress_signature() -> String:
	return "%d|%d|%d|%s|%d|%d|%d|%d|%d|%d|%d|%d|%s|%s|%d" % [
		step, _progress_index, bought_units,
		# _fill_started 也算进来：BUY 相位与 bought=0 在「还没开始」和
		# 「刚开始」两种状态下取值相同，只看那两个会漏掉这次转变。
		str(_fill_started), _fill_phase, _fill_bought,
		_owned_normal_count(), GameState.normal_unit_count(),
		_mercenary_count(), GameState.owned_treasures.size(),
		# 萝卜 / 四星教学：采集等级、升级石、收获与领奖、四星都是玩家实际推进的东西。
		GameState.harvest_tech_level, _stone_count(),
		str(_carrot_harvested), str(_carrot_gift_claimed), _max_normal_star(),
	]


func has_checkpoint() -> bool:
	return SaveManager.has_tutorial()


func clear_checkpoint() -> void:
	_checkpoint_signature = ""
	SaveManager.clear_tutorial()


# 从断点恢复。成功返回 true；断点缺失/版本不符/结构损坏一律返回 false，
# 由调用方退回「从头开始教程」——绝不半恢复出一个夹生状态。
func restore_checkpoint() -> bool:
	var data := SaveManager.load_tutorial()
	if data.is_empty() or int(data.get("version", 0)) != CHECKPOINT_VERSION:
		return false
	var saved_step := int(data.get("step", -1))
	if saved_step < 0 or saved_step > int(Step.DONE):
		return false

	active = true
	GameState.reset_run()
	GameState.tutorial_mode = true
	step = saved_step
	_progress_index = int(data.get("progress_index", 0))
	bought_units = int(data.get("bought_units", 0))

	var fill: Dictionary = data.get("fill", {}) if data.get("fill", {}) is Dictionary else {}
	_fill_started = bool(fill.get("started", false))
	_fill_phase = int(fill.get("phase", FillPhase.BUY))
	_fill_buy_target = int(fill.get("buy_target", 0))
	_fill_bought = int(fill.get("bought", 0))
	_fill_shop_open = bool(fill.get("shop_open", false))
	_fill_compensated = int(fill.get("compensated", 0))

	var carrot: Dictionary = data.get("carrot_tutorial", {}) if data.get("carrot_tutorial", {}) is Dictionary else {}
	_carrot_harvested = bool(carrot.get("harvested", false))
	_carrot_harvest_gain = int(carrot.get("harvest_gain", 0))
	_carrot_gift_claimed = bool(carrot.get("gift_claimed", false))
	_camp_open = false
	_camp_page = CAMP_PAGE_CAMP

	GameState.round_index = int(data.get("round_index", 1))
	GameState.gold = int(data.get("gold", TUTORIAL_GOLD))
	GameState.carrots = maxi(0, int(data.get("carrots", 0)))
	GameState.harvest_tech_level = maxi(0, int(data.get("harvest_tech_level", 0)))
	GameState.merc_carrots_spent_total = maxi(0, int(data.get("merc_carrots_spent_total", 0)))
	GameState.last_harvest_round = int(data.get("last_harvest_round", -1))
	GameState.stone_draw_used_round = int(data.get("stone_draw_used_round", -1))
	GameState.stone_draw_count = maxi(0, int(data.get("stone_draw_count", 0)))
	var saved_stones: Variant = data.get("team_upgrade_stones", {})
	if saved_stones is Dictionary:
		# 断点走 JSON，整数会读回成浮点（1 -> 1.0）。9.25 起教学真的会用到升级石，
		# 这里按三种石头逐个取整，恢复出来的库存与存盘前逐值相等。
		var stones := CarrotEconomy.empty_stones()
		for key in (saved_stones as Dictionary).keys():
			if CarrotEconomy.valid_stone_type(str(key)):
				stones[str(key)] = maxi(0, int((saved_stones as Dictionary)[key]))
		GameState.team_upgrade_stones = stones
	GameState.player_formation_hp = int(data.get("player_formation_hp", TUTORIAL_HP))
	GameState.enemy_formation_hp = int(data.get("enemy_formation_hp", TUTORIAL_HP))
	_restore_slots(GameState.board_slots, data.get("board_slots", []))
	_restore_slots(GameState.bench_slots, data.get("bench_slots", []))
	_restore_slots(GameState.mercenary_slots, data.get("mercenary_slots", []))
	_restore_slots(GameState.shop_offers, data.get("shop_offers", []))
	_restore_slots(GameState.shop_sold, data.get("shop_sold", []), false)
	GameState.owned_treasures.clear()
	for tid in data.get("owned_treasures", []):
		GameState.owned_treasures.append(str(tid))
	GameState.claimed_treasure_rounds.clear()
	for r in data.get("claimed_treasure_rounds", []):
		GameState.claimed_treasure_rounds.append(int(r))
	var pending: Variant = data.get("pending_treasure", {})
	if pending is Dictionary:
		GameState.pending_treasure = (pending as Dictionary).duplicate(true)
	GameState.pve_completed = int(data.get("pve_completed", 0))
	GameState.boss_completed = int(data.get("boss_completed", 0))

	_checkpoint_signature = _checkpoint_progress_signature()
	AnalyticsService.tutorial_resumed(step_key(), step_number())
	return true


# 按目标数组的既有长度逐格写回，不改容量 —— reset_run() 已经把尺寸摆好了。
func _restore_slots(target: Array, raw: Variant, fallback: Variant = null) -> void:
	if not (raw is Array):
		return
	var source: Array = raw
	for i in target.size():
		target[i] = source[i] if i < source.size() else fallback


func record_shop_purchase() -> void:
	if not active:
		return
	if step == Step.BUY_3:
		bought_units += 1
		sync()
	elif step == Step.FILL_7:
		# 生产链在扣钱、写 shop_sold、完成合成之后才调到这里，所以这一次
		# 一定是**真实成交**。钱不够、待命区满、槽位已售都在上游就 return 了。
		if _fill_started and _fill_phase == FillPhase.BUY:
			_fill_bought += 1
		sync()


# 商店开合的生产事件（ShopPanel.picker_toggled -> PrepUI._on_shop_picker_toggled）。
# 「关闭商店」这一子阶段必须靠它推进，不能靠延时或轮询猜。
func record_shop_toggled(is_open: bool) -> void:
	if not active:
		return
	_fill_shop_open = is_open
	var step_before := step
	if step == Step.FILL_7:
		sync()
	elif step == Step.BUY_3:
		# 9.13 #4：第 1 步的「关闭商店」子阶段靠这条事件推进。
		sync()
	# ★ 2026-10-15 真机反馈「步骤 2/22 待命区棋子拖不动」的修法（本事件就是元凶那一环）。
	#
	# 推进到 PLACE_3 会让**「待命格此刻能不能拖」翻面**：BoardHud.refresh_bench() 把
	# 「tutorial_mode 且 step == BUY_3 ⇒ drag_payload = {}」这个判据**烘进按钮的数据快照**
	# （BUY_3 期间不让拖 —— 要先买；PLACE_3 起必须能拖）。而本事件此前只改 step、不刷待命区：
	# 玩家买满 3 个（每次买入都刷一遍待命区，但那一刻 step 仍是 BUY_3，于是快照全落成 `{}`），
	# 再点商店外面关店，step 走到 PLACE_3 却**没有任何人再刷新** ⇒ 快照永远停在 `{}` ⇒
	# PrepDragButton._maybe_launch_drag() 里的 `drag_payload.is_empty()` 直接早退 ⇒
	# 待命区棋子**永远拖不起来**。
	# 实测（`_qa_1016/_diag_drag_block.tscn`）：待命格中心没有任何控件遮挡，
	# `gui_get_hovered_control()` 返回的就是待命格自己；把 step 手工改成 PLACE_3 但**不刷 UI**，
	# payload 仍是 `{}`；一旦刷新就变成 `{"kind":"bench","index":i}` ⇒ 铁证是**快照过期**，不是遮挡。
	#
	# 用既有的「请宿主刷新视图」通道补发（与 sync() 里补发宝藏候选同一根线）：
	# `_refresh_prep()` → provider ACTION_REFRESH_VIEW → PrepUI._tutorial_refresh_view()
	# → `_refresh_all.call_deferred()`。选它而不是直接摸 UI，有两个原因：
	#   ① 它天然是**延迟**的 —— 关店的点击跑在 PrepScreen._input 里，当场刷 UI 会跟同一次
	#      命中测试打照面（与 ShopPanel 恢复木牌必须 set_deferred 是同一条教训）；
	#   ② `_refresh_all()` 恰好是 **sync() 在前、refresh_bench() 在后**，所以快照拿到的一定是
	#      刚推进完的 step，顺序不可能反。
	# 只在**真的推进了**的时候补发，省掉商店每次开合都做一次全量刷新。
	if step != step_before:
		_refresh_prep()


# --- FILL_7 子阶段（V2 P1-07）--------------------------------------------------

func fill_phase() -> int:
	return _fill_phase


func fill_started() -> bool:
	return _fill_started


# [已成交, 需要买的总数]
func fill_buy_progress() -> Array:
	return [mini(_fill_bought, _fill_buy_target), _fill_buy_target]


func fill_shop_closed() -> bool:
	return not _fill_shop_open


# [已上阵, 目标]
func fill_deploy_progress() -> Array:
	return [mini(GameState.normal_unit_count(), FILL_TARGET_UNITS), FILL_TARGET_UNITS]


func fill_compensated_count() -> int:
	return _fill_compensated


func _begin_fill_step() -> void:
	if _fill_started:
		return
	_fill_started = true
	_fill_phase = FillPhase.BUY
	_fill_bought = 0
	_fill_compensated = 0
	# 目标按**还差几个**算，而不是写死 4：玩家可能带着待命区里的棋子进这一步
	# （提前达成部分目标），那样就不该再逼他买满 4 个。
	_fill_buy_target = maxi(0, FILL_TARGET_UNITS - _owned_normal_count())


func _end_fill_step() -> void:
	_fill_started = false
	_fill_phase = FillPhase.BUY
	_fill_buy_target = 0
	_fill_bought = 0
	_fill_shop_open = false
	_fill_compensated = 0


func _advance_fill_step() -> void:
	if not _fill_started:
		_begin_fill_step()
	match _fill_phase:
		FillPhase.BUY:
			if _fill_buy_done():
				# 走出购买阶段前先把「买够了却还是不满 7 个」补齐 ——
				# 否则自动合成会把玩家留在一个永远完成不了的上阵阶段里。
				_compensate_fill_shortfall()
				# 商店没开过就没有「关闭商店」可言（比如进这一步时就已经有 7 个）。
				_fill_phase = FillPhase.CLOSE_SHOP if _fill_shop_open else FillPhase.DEPLOY
		FillPhase.CLOSE_SHOP:
			if not _fill_shop_open:
				_fill_phase = FillPhase.DEPLOY
		_:
			pass


func _fill_buy_done() -> bool:
	if _fill_bought >= _fill_buy_target:
		return true
	# 玩家已经（提前或中途）攒够 7 个可上阵棋子，不必再买。
	if _owned_normal_count() >= FILL_TARGET_UNITS:
		return true
	# 商店里已经没有买得到的东西了（全部售罄，或 FILL_SHOP 的候选在数据表里
	# 取不到 def 而变成空槽）。再等下去就是死局，交给下面的补偿收场。
	return _fill_shop_purchasable_count() <= 0


# 补足「可上阵棋子」到 7 个。只发到待命区 —— 上阵那一步必须由玩家自己完成，
# 直接放上棋盘等于替玩家把教学做完了。
#
# 待命区满时这里必然不会被触发：满 = 待命区 8 个，加上棋盘的就已经 >= 8 > 7，
# 差额是负的、直接 return。所以不存在「补偿时没地方放」的分支。
func _compensate_fill_shortfall() -> void:
	var guard := 0
	while _owned_normal_count() < FILL_TARGET_UNITS and guard < FILL_TARGET_UNITS:
		var before := _owned_normal_count()
		_grant_units(str(FILL_SHOP[guard % FILL_SHOP.size()]), 1, 1)
		if _owned_normal_count() <= before:
			break
		_fill_compensated += 1
		guard += 1


# 三个阶段的玩家可见文案。数字全部来自真实游戏状态：
# 购买数来自成交回调，关闭商店来自 picker_toggled，上阵数来自 board_slots。
# 三行同时显示，玩家始终看得到自己走到哪、还差什么。
func _fill_step_text() -> String:
	var buy: Array = fill_buy_progress()
	var deploy: Array = fill_deploy_progress()
	var buy_line := _t("① 在商店买 %d/%d 个棋子" % [int(buy[0]), int(buy[1])],
		"1. Buy %d/%d units from the shop" % [int(buy[0]), int(buy[1])])
	var close_line := ""
	if fill_shop_closed():
		close_line = _t("② 关闭商店：已完成", "2. Close the shop: done")
	else:
		close_line = _t("② 关闭商店：未完成", "2. Close the shop: not yet")
	var deploy_line := _t("③ 把棋子拖上棋盘 %d/%d" % [int(deploy[0]), int(deploy[1])],
		"3. Drag units onto the board %d/%d" % [int(deploy[0]), int(deploy[1])])
	var head := ""
	match _fill_phase:
		FillPhase.BUY:
			head = _t("PVP 前要凑满 %d 个上阵棋子。先去商店把缺的买齐。" % FILL_TARGET_UNITS,
				"You need %d units on the board before PVP. Buy what you are missing first." % FILL_TARGET_UNITS)
		FillPhase.CLOSE_SHOP:
			head = _t("买齐了。先关掉商店，才能把棋子拖上棋盘。",
				"All bought. Close the shop so you can drag units onto the board.")
		_:
			head = _t("把待命区的棋子拖到棋盘的空位上。",
				"Drag the units from standby onto the empty board slots.")
	return "%s\n%s\n%s\n%s" % [head, buy_line, close_line, deploy_line]


func _fill_shop_purchasable_count() -> int:
	var n := 0
	for i in GameState.shop_offers.size():
		if i >= GameState.shop_sold.size() or bool(GameState.shop_sold[i]):
			continue
		var offer = GameState.shop_offers[i]
		if typeof(offer) == TYPE_DICTIONARY and not (offer as Dictionary).is_empty():
			n += 1
	return n

# 按当前文案把气泡收到内容高度，并限死在 BUBBLE_MAX_HEIGHT 内，
# 避免任何一步的长文案再次把气泡撑成半屏。
func _fit_bubble() -> void:
	if _bubble == null or not is_instance_valid(_bubble):
		return
	_bubble.custom_minimum_size = Vector2(BUBBLE_WIDTH, 0.0)
	var measured := _bubble.get_combined_minimum_size()
	var height := clampf(measured.y, BUBBLE_MIN_HEIGHT, BUBBLE_MAX_HEIGHT)
	_bubble.custom_minimum_size = Vector2(BUBBLE_WIDTH, height)
	_bubble.size = Vector2(BUBBLE_WIDTH, height)


func _rect_signature(rect: Rect2) -> String:
	return "%d,%d,%d,%d" % [
		roundi(rect.position.x), roundi(rect.position.y),
		roundi(rect.size.x), roundi(rect.size.y)]


func _overlay_layout_signature(target: Control, target_rect: Rect2, text: String, dir: int) -> String:
	var parts: Array[String] = [
		str(step),
		str(target.get_instance_id() if target != null and is_instance_valid(target) else 0),
		_rect_signature(target_rect),
		_rect_signature(_safe_rect()),
		str(dir),
		text,
		progress_text(),
		step_display_name(),
	]
	for blocked in _keep_clear_rects():
		parts.append(_rect_signature(blocked))
	return "|".join(parts)


func _overlay_content_key(target: Control, text: String, dir: int) -> String:
	return "%d|%d|%d|%s|%s|%s" % [
		step,
		target.get_instance_id() if target != null and is_instance_valid(target) else 0,
		dir,
		text,
		progress_text(),
		step_display_name(),
	]


func _layout_inputs_equivalent(content_key: String, target_rect: Rect2,
		safe: Rect2, keep_clear: Array[Rect2]) -> bool:
	if content_key != _last_content_key:
		return false
	if not _rect_near(target_rect, _last_target_rect) or not _rect_near(safe, _last_safe_rect):
		return false
	if keep_clear.size() != _last_keep_clear_rects.size():
		return false
	for i in keep_clear.size():
		if not _rect_near(keep_clear[i], _last_keep_clear_rects[i]):
			return false
	return true


func _rect_near(a: Rect2, b: Rect2) -> bool:
	return absf(a.position.x - b.position.x) <= LAYOUT_GEOMETRY_EPS \
		and absf(a.position.y - b.position.y) <= LAYOUT_GEOMETRY_EPS \
		and absf(a.size.x - b.size.x) <= LAYOUT_GEOMETRY_EPS \
		and absf(a.size.y - b.size.y) <= LAYOUT_GEOMETRY_EPS

# 屏幕安全区（灵动岛、刘海、圆角、手势条），换算到 overlay 局部坐标并收掉边距。
#
# 全游戏同一个来源 ui/services/SafeArea.gd（手机上读系统安全区、按视口/窗口比例换算，
# 电脑上是整个窗口；门禁能注入假刘海）。它给的是根视口坐标，这里减掉 overlay 的原点。
func _safe_rect() -> Rect2:
	var full := Rect2(Vector2.ZERO, _overlay.size)
	var mapped := SafeArea.rect()
	mapped.position -= _overlay.get_global_rect().position
	var clipped := full.intersection(mapped)
	if clipped.size.x > 0.0 and clipped.size.y > 0.0:
		full = clipped
	# 极窄屏下不要把安全区收成负的，宁可贴边也不要算出 NaN 版面。
	var inset := minf(BUBBLE_EDGE_MARGIN, minf(full.size.x, full.size.y) * 0.25)
	return full.grow(-inset)


func _keep_clear_rects() -> Array[Rect2]:
	if _target_provider == null:
		return [] as Array[Rect2]
	return _target_provider.keep_clear_rects()


func _overlap_area(a: Rect2, b: Rect2) -> float:
	var hit := a.intersection(b)
	if hit.size.x <= 0.0 or hit.size.y <= 0.0:
		return 0.0
	return hit.size.x * hit.size.y


func _clamp_into(pos: Vector2, size: Vector2, bounds: Rect2) -> Vector2:
	var max_x := maxf(bounds.position.x, bounds.position.x + bounds.size.x - size.x)
	var max_y := maxf(bounds.position.y, bounds.position.y + bounds.size.y - size.y)
	return Vector2(
		clampf(pos.x, bounds.position.x, max_x),
		clampf(pos.y, bounds.position.y, max_y))


# 四个候选位置：目标的上方 / 下方 / 右侧 / 左侧。返回时首选方向排在第 0 位，
# 这样同分的情况下版面与迁移前一致，只有真的压住目标或禁区才会换位。
func _bubble_candidates(target_rect: Rect2, size: Vector2, dir: int) -> Array[Vector2]:
	var center_x := target_rect.position.x + target_rect.size.x * 0.5 - size.x * 0.5
	var center_y := target_rect.position.y + target_rect.size.y * 0.5 - size.y * 0.5
	# Keep the dialogue clear of the interaction area, including the shop and
	# reserve bench. The guide light spans this gap without taking input.
	var above_y := target_rect.position.y - 94.0 - size.y
	var below_y := target_rect.end.y + 90.0
	var right_x := target_rect.end.x + 104.0
	var left_x := target_rect.position.x - 104.0 - size.x
	# 每个方向再给三个沿垂直轴的对齐变体（居中 / 贴目标一边 / 贴另一边）。
	# 只给四个正中候选时，四个都压住禁区就只能挑「最不糟」的那个；
	# 多这几档平移能真正让开待命区和主按钮，而不是少压一点。
	var above: Array[Vector2] = [
		Vector2(center_x, above_y),
		Vector2(target_rect.position.x, above_y),
		Vector2(target_rect.position.x + target_rect.size.x - size.x, above_y)]
	var below: Array[Vector2] = [
		Vector2(center_x, below_y),
		Vector2(target_rect.position.x, below_y),
		Vector2(target_rect.position.x + target_rect.size.x - size.x, below_y)]
	var right: Array[Vector2] = [
		Vector2(right_x, center_y),
		Vector2(right_x, target_rect.position.y),
		Vector2(right_x, target_rect.position.y + target_rect.size.y - size.y)]
	var left: Array[Vector2] = [
		Vector2(left_x, center_y),
		Vector2(left_x, target_rect.position.y),
		Vector2(left_x, target_rect.position.y + target_rect.size.y - size.y)]
	var out: Array[Vector2] = []
	match dir:
		ArrowDir.LEFT:
			# 箭头 ◀ 指向目标左侧的面板，气泡让到箭头右边。
			for group in [right, above, below, left]:
				out.append_array(group)
		ArrowDir.UP:
			# 目标在屏幕顶部：箭头在气泡上方指向目标，气泡排在箭尾下面。
			for group in [below, above, right, left]:
				out.append_array(group)
		_:
			for group in [above, below, right, left]:
				out.append_array(group)
	return out


# V2 P1-09：气泡按「目标矩形 + 安全区 + 当前面板禁区」动态选位，
# 不再是按步骤写死一个方向再硬 clamp —— 那种做法在 20:9 和 2640×1216 下
# 会把气泡直接压在目标上，验收要求的「目标可见面积 ≥90%」达不到。
func _bubble_position(target_rect: Rect2, dir: int, context: String = "") -> Vector2:
	# 用气泡的**实际**尺寸夹边，不能用 BUBBLE_WIDTH：PanelContainer 的边框会让
	# 实测宽度比常量大几像素，按常量夹就会有一条窄边露在安全区之外。
	var bubble_size := Vector2(
		maxf(_bubble.size.x, BUBBLE_WIDTH),
		maxf(_bubble.size.y, BUBBLE_MIN_HEIGHT))
	var safe := _safe_rect()
	var keep_clear := _keep_clear_rects()
	if context == _layout_context and _sticky_position_is_valid(
			_last_bubble_position, bubble_size, safe, target_rect, keep_clear):
		_last_layout_reason = "sticky_valid"
		return _last_bubble_position
	var candidates := _bubble_candidates(target_rect, bubble_size, dir)
	# A bench or shop can span almost the full width below the target. In that
	# case every target-adjacent candidate clips a playable control, so also
	# search stable screen-edge positions. The light keeps the target connection.
	for y_ratio in [0.0, 0.25, 0.5, 0.75, 1.0]:
		for x_ratio in [0.0, 0.25, 0.5, 0.75, 1.0]:
			candidates.append(Vector2(
				safe.position.x + (safe.size.x - bubble_size.x) * x_ratio,
				safe.position.y + (safe.size.y - bubble_size.y) * y_ratio))
	var best := _clamp_into(candidates[0], bubble_size, safe)
	var best_score := INF
	var best_index := 0
	for i in candidates.size():
		var pos := _clamp_into(candidates[i], bubble_size, safe)
		var rect := Rect2(pos, bubble_size)
		# 压住目标的代价远高于压住禁区：验收线画在目标可见度上。
		var score := _overlap_area(rect, target_rect) * TARGET_OVERLAP_WEIGHT
		for blocked in keep_clear:
			score += _overlap_area(rect, blocked)
		# 同分时保持首选方向。代价足够小，一旦真压住目标就必然让位。
		score += float(i) * CANDIDATE_ORDER_PENALTY
		if score < best_score:
			best_score = score
			best = pos
			best_index = i
	_layout_context = context
	_last_bubble_position = best
	_last_candidate_index = best_index
	return best


func _sticky_position_is_valid(pos: Vector2, size: Vector2, safe: Rect2,
		target_rect: Rect2, keep_clear: Array[Rect2]) -> bool:
	var bubble_rect := Rect2(pos, size)
	if not safe.encloses(bubble_rect):
		return false
	var target_area := maxf(1.0, target_rect.size.x * target_rect.size.y)
	if _overlap_area(bubble_rect, target_rect) / target_area > MAX_STICKY_OVERLAP_RATIO:
		return false
	for blocked in keep_clear:
		var blocked_area := maxf(1.0, blocked.size.x * blocked.size.y)
		if _overlap_area(bubble_rect, blocked) / blocked_area > MAX_STICKY_OVERLAP_RATIO:
			return false
	return true

func _target_control() -> Control:
	if _target_provider == null:
		return null
	var target_id := ""
	match step:
		Step.BUY_3:
			target_id = TutorialTargetProviderScript.TARGET_BUY_UNIT
		Step.PLACE_3:
			target_id = TutorialTargetProviderScript.TARGET_PLACE_UNIT
		Step.UPGRADE_2, Step.UPGRADE_3, Step.UPGRADE_OTHERS:
			target_id = TutorialTargetProviderScript.TARGET_UPGRADE_UNIT
		Step.START_PVE_1, Step.START_PVE_2, Step.START_BOSS, Step.START_PVP:
			target_id = TutorialTargetProviderScript.TARGET_START_BATTLE
		Step.FORMATION_HP:
			target_id = TutorialTargetProviderScript.TARGET_FORMATION_HP
		Step.TAKE_TREASURE_1, Step.TAKE_TREASURE_2:
			target_id = TutorialTargetProviderScript.TARGET_TREASURE_CHOICE
		Step.HIRE_MERC:
			target_id = TutorialTargetProviderScript.TARGET_HIRE_MERCENARY
		Step.FILL_7:
			target_id = TutorialTargetProviderScript.TARGET_FILL_SEVEN
		Step.BOND_HINT:
			target_id = TutorialTargetProviderScript.TARGET_BOND_ROW
		Step.VIEW_TREASURE:
			target_id = TutorialTargetProviderScript.TARGET_TREASURE_LOGO
		Step.CARROT_CAMP, Step.HARVEST_UPGRADE, Step.CARROT_HARVEST, \
		Step.DRAW_STONE, Step.FOUR_STAR:
			target_id = _carrot_target_id()
	if target_id.is_empty():
		return null
	# 9.25 教程优化第 6 条：这里**不再请求玩家反馈**（原来传的是「教学目标暂时不可用，
	# 请关闭当前面板后重试。」）。
	#
	# 有些目标是随界面瞬时状态而变的，解析不出来并不代表出错：UPGRADE_3 那一步的箭头
	# 指着「商店里第一个还能买的卡位」，4 个卡位全买光（或商店正在重建）时
	# _tutorial_first_available_shop() 就返回 null；提交截图（image16，步骤 6「升到3星」）
	# 就是这时候弹了一条「教学目标暂时不可用」。玩家什么都没做错，这句话只会让人以为
	# 关卡坏了。
	#
	# 传空串 -> TutorialTargetProvider.show_feedback("") 直接返回 false，不弹任何东西；
	# provider 那边的 push_warning 诊断不受影响（仍会记 last_missing_snapshot）。
	# 注意保留「未绑定 / resolver 无效」那两类**代码错误**的反馈：tutorial_target_check
	# 要求缺目标时给玩家可恢复的反馈，那是自测用的假 provider 主动传的文本，不经过这里。
	return _target_provider.resolve_target(target_id, step_key(), "")

func _ensure_overlay() -> void:
	if _overlay != null and is_instance_valid(_overlay):
		return
	if _target_provider == null:
		return
	var host := _target_provider.overlay_host()
	if host == null:
		push_warning("Tutorial overlay host missing provider=%s" %
			_target_provider.provider_name())
		return
	_overlay = Control.new()
	_overlay.name = "TutorialOverlay"
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.z_index = 500
	host.add_child(_overlay)

	# ── 聚焦遮罩（2026-10-15 反馈问题 2）────────────────────────────────────
	# 反馈原文：「调整明亮度，使除步骤、箭头提示和目标外的地方变暗，方便新手玩家
	# 更好看到操作指引。举例，如图里的"步骤1/22"，要保留亮度的就是步骤1/22、
	# 红色箭头、民兵，其他区域变暗。」
	#
	# 做法：**一整块**铺满 overlay 的 ColorRect + shader，洞由 fragment 逐片元判定。
	# 四个刻意选择：
	#   ① 单块，不是四块拼环形 —— 内部没有公共边，就不可能有"拼接处 1px 亮线"。
	#      这是玩家实测报的「屏幕会闪，伴有线」的根因与修法，详见
	#      shaders/tutorial_focus_mask.gdshader 与 FOCUS_DIM_COUNT 上方的注释。
	#   ② mouse_filter IGNORE —— 遮罩只负责变暗，一颗点击都不许吃：
	#      「跳过教学」、商店、棋盘都还要照常可点。
	#      （2026-10-15 第三轮起覆盖层里**已经没有别的吃点击的节点**了：透明热点连同
	#       它那个 `MOUSE_FILTER_STOP` 一起删掉，气泡整棵子树也一律 IGNORE，
	#       见 `_input()` 与 `_make_mouse_transparent()`。）
	#   ③ 它是 _overlay 的**第 1 个子节点**，于是画在箭头 / 气泡 / 跳过键
	#      **下面**。这三样本来就该保持亮度，压在上层自然不受影响 ——
	#      所以真正需要开洞的只有**目标本身**（目标在游戏 UI 里，位于 overlay 之下）。
	#      ⚠ 这条"靠层级保亮度"是设计的一部分，改画序就等于改动亮度承诺，
	#      门禁里有一条专门钉它（dim 的 index 必须小于这三者）。
	#   ④ 这块 quad 的矩形恒等于整幅 overlay（每帧只改 uniform），于是几何零变化 ——
	#      目标漂移不会带动遮罩边缘做亚像素游走。
	_focus_dim.clear()
	var dim := ColorRect.new()
	dim.name = "TutorialFocusDim"
	# 节点色留白：真正的颜色由 shader 的 dim_color 决定（避免两处各写一份而漂移）。
	dim.color = Color.WHITE
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var dim_mat := ShaderMaterial.new()
	dim_mat.shader = TutorialFocusMaskShader
	dim_mat.set_shader_parameter("dim_color", FOCUS_DIM_COLOR)
	dim_mat.set_shader_parameter("hole", Vector4(0.0, 0.0, 0.0, 0.0))
	dim_mat.set_shader_parameter("hole_on", 0.0)
	dim.material = dim_mat
	_overlay.add_child(dim)
	_focus_dim.append(dim)

	_light = TutorialGuideLightScript.new()
	_light.name = "TutorialGuideLight"
	_overlay.add_child(_light)
	_guide = TextureRect.new()
	_guide.name = "TutorialDog"
	_guide.texture = DOG_WELCOME
	_guide.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_guide.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_guide.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(_guide)

	_bubble = PanelContainer.new()
	# 气泡只负责显示文字，不吃任何点击（2026-10-15 第三轮反馈）。整棵子树都要设，
	# 见 `_make_mouse_transparent()` —— 只改这一层的话 MarginContainer / VBoxContainer
	# 会照旧把落在气泡矩形里的点击吃掉。
	_bubble.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 只定宽不定高，高度由 _fit_bubble() 按内容算完再钉死。
	_bubble.custom_minimum_size = Vector2(BUBBLE_WIDTH, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.05, 0.06, 0.88)
	style.border_color = Color(1.0, 0.86, 0.28, 0.95)
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	_bubble.add_theme_stylebox_override("panel", style)
	_overlay.add_child(_bubble)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_bottom", 10)
	_bubble.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	margin.add_child(box)

	# 进度指示：左边「步骤 n/16」，右边步骤代号（如 UPGRADE_2）。
	# 代号是枚举名，改流程时按代号沟通，不受插入/删除步骤导致的编号漂移影响。
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	box.add_child(header)
	_progress_label = Label.new()
	_progress_label.add_theme_font_size_override("font_size", 14)
	_progress_label.add_theme_color_override("font_color", Color(1.0, 0.86, 0.28))
	header.add_child(_progress_label)
	_step_name_label = Label.new()
	_step_name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_step_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_step_name_label.add_theme_font_size_override("font_size", 14)
	_step_name_label.add_theme_color_override("font_color", Color(0.60, 0.65, 0.72))
	header.add_child(_step_name_label)

	_progress_bar = ProgressBar.new()
	_progress_bar.custom_minimum_size = Vector2(0, 6)
	_progress_bar.min_value = 0.0
	_progress_bar.max_value = float(total_steps())
	_progress_bar.show_percentage = false
	var bar_bg := StyleBoxFlat.new()
	bar_bg.bg_color = Color(0.16, 0.17, 0.20, 0.9)
	bar_bg.set_corner_radius_all(3)
	var bar_fill := StyleBoxFlat.new()
	bar_fill.bg_color = Color(1.0, 0.86, 0.28, 0.95)
	bar_fill.set_corner_radius_all(3)
	_progress_bar.add_theme_stylebox_override("background", bar_bg)
	_progress_bar.add_theme_stylebox_override("fill", bar_fill)
	box.add_child(_progress_bar)

	_text = Label.new()
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# 定宽后 autowrap 才能算出正确的最小高度（否则气泡会被撑爆）。
	_text.custom_minimum_size = Vector2(BUBBLE_TEXT_WIDTH, 0)
	_text.add_theme_font_size_override("font_size", 18)
	_text.add_theme_color_override("font_color", Color(0.98, 0.96, 0.86))
	box.add_child(_text)
	_continue_btn = Button.new()
	_continue_btn.text = _t("继续", "Continue")
	_continue_btn.custom_minimum_size = Vector2(120, 34)
	_continue_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_continue_btn.visible = false
	_continue_btn.pressed.connect(_on_continue_pressed)
	box.add_child(_continue_btn)
	# 气泡子树建完之后整棵设成不吃点击。刻意放在**最后**：`_make_mouse_transparent()`
	# 只能遍历当时已经挂上的节点，早调一步就会漏掉后面 add_child 的那几个。
	_make_mouse_transparent(_bubble)

	# 这里原本有一个 `_hotspot`（透明 Button，`MOUSE_FILTER_STOP`）——「点一下继续」靠它
	# 吃点击推进。2026-10-15 第三轮反馈明令「不要增加玩家操作的**限制**」，于是整个删掉：
	# 透明按钮哪怕 `modulate.a = 0`，也仍然是一块**真的会在命中测试里胜出**的墙 ——
	# 盖在目标上时把目标自己的点击抢走，铺满全屏时把整屏的点击抢走。
	# 现在推进由 `_input()` 旁听（不回吞事件），同一次点击照常落到下面的真控件上。

	# 「跳过教学」按钮：固定在左上角，任何步都能一键跳过整段教学。
	# ⚠ 它是覆盖层里**唯一**该吃点击的节点，`MOUSE_FILTER_STOP` 是故意的。
	_skip_btn = Button.new()
	_skip_btn.name = "TutorialSkipButton"
	_skip_btn.text = _t("跳过教学", "Skip Tutorial")
	_skip_btn.focus_mode = Control.FOCUS_NONE
	_skip_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	_skip_btn.anchor_left = 0.0
	_skip_btn.anchor_top = 0.0
	_skip_btn.anchor_right = 0.0
	_skip_btn.anchor_bottom = 0.0
	_skip_btn.position = Vector2(16, 44)
	_skip_btn.custom_minimum_size = Vector2(112, 34)
	_skip_btn.add_theme_font_size_override("font_size", 15)
	_skip_btn.add_theme_color_override("font_color", Color(0.98, 0.96, 0.86))
	var skip_style := StyleBoxFlat.new()
	skip_style.bg_color = Color(0.04, 0.05, 0.06, 0.88)
	skip_style.border_color = Color(1.0, 0.86, 0.28, 0.95)
	skip_style.set_border_width_all(2)
	skip_style.set_corner_radius_all(8)
	skip_style.set_content_margin_all(6)
	_skip_btn.add_theme_stylebox_override("normal", skip_style)
	_skip_btn.add_theme_stylebox_override("hover", skip_style)
	_skip_btn.add_theme_stylebox_override("pressed", skip_style)
	_skip_btn.add_theme_stylebox_override("focus", skip_style)
	_skip_btn.pressed.connect(_on_skip_pressed)
	_overlay.add_child(_skip_btn)

func _detach() -> void:
	if _overlay != null and is_instance_valid(_overlay):
		_overlay.queue_free()
	_overlay = null
	_light = null
	_guide = null
	_focus_dim.clear()
	_target_provider = null
	_overlay_suppressed = false
	_layout_signature = ""
	_layout_context = ""
	_last_candidate_index = -1
	_last_content_key = ""
	_last_target_rect = Rect2()
	_last_safe_rect = Rect2()
	_last_keep_clear_rects.clear()

func tutorial_shop_ids() -> Array:
	# 刷新商店时按当前步铺货：升星步铺满要凑的同名棋子。
	match step:
		Step.UPGRADE_2, Step.UPGRADE_3:
			return UPGRADE_2_SHOP
		Step.UPGRADE_OTHERS:
			return UPGRADE_OTHERS_SHOP
		_:
			return FILL_SHOP if step >= Step.HIRE_MERC else START_SHOP

func _apply_shop(ids: Array) -> void:
	var offers: Array = []
	for id in ids:
		var def := _unit_def(str(id))
		if not def.is_empty():
			offers.append(def)
	GameState.shop_offers.resize(GameState.SHOP_UNIT_SLOTS)
	GameState.shop_sold.resize(GameState.SHOP_UNIT_SLOTS)
	for i in GameState.SHOP_UNIT_SLOTS:
		GameState.shop_offers[i] = offers[i % offers.size()].duplicate(true) if not offers.is_empty() else {}
		GameState.shop_sold[i] = false

func _grant_units(id: String, count: int, star: int = 1) -> void:
	var def := _unit_def(id)
	if def.is_empty():
		return
	for n in count:
		var index := GameState.bench_slots.find(null)
		if index < 0:
			return
		GameState.bench_slots[index] = {"id": id, "uid": GameState.mint_piece_uid(), "star": star, "def": def.duplicate(true)}

func _on_continue_pressed() -> void:
	if step == Step.BOND_HINT:
		_advance_to(Step.START_BOSS)
	elif step == Step.FORMATION_HP:
		_advance_to(Step.START_PVP)
	update_overlay()

func _refresh_prep() -> void:
	if _target_provider != null:
		_target_provider.request_action(TutorialTargetProviderScript.ACTION_REFRESH_VIEW)


# 9.25 教程优化第 3 条：教学里商店刷新「无限制次数 + 一直免费」。
#
# 这两件事是同一件事：EconomyService.shop_refresh_cost() 在 all_free 为真时恒返回 0，
# 而 0 费用既不会扣钱也不会随 `shop_refresh_uses_this_round` 递增（那个计数只喂给
# 递增价公式），所以「免费」自然等于「无限次」。
#
# **判定必须只在这一处**：PrepBoardController._on_refresh_shop（真正扣钱的那边）和
# ShopPanel.refresh（画按钮、写「免费」标签的那边）各算一遍的话，两处一旦漂移就会出现
# 「按钮写着免费、点下去照扣」这类只在一处生效的错。非教学始终使用正常刷新费用；
# 4 金钱套装已改为按持有金币提高开战 ATK/HP。
func shop_refresh_all_free() -> bool:
	return GameState.tutorial_mode

func _start_treasure(ids: Array) -> void:
	GameState.pending_treasure = {"active": true, "round": GameState.round_index, "candidates": TreasureService.available_candidates(ids), "refresh_index": 0}

func _tutorial_opponent_snapshot() -> Dictionary:
	var board := []
	board.resize(GameConstants.CELL_COUNT)
	board.fill(null)
	var slots := [1, 2, 5, 6, 9]
	for i in mini(PVP_OPPONENT.size(), slots.size()):
		var id := str(PVP_OPPONENT[i])
		var def := _unit_def(id)
		if not def.is_empty():
			board[int(slots[i])] = {"id": id, "uid": GameState.mint_piece_uid(), "star": 1, "def": def}
	return {
		"version": NetProtocol.SNAPSHOT_VERSION,
		"round": GameState.round_index,
		"board": NetProtocol.sanitize_board(board),
		"mercenaries": [],
		"treasures": [],
		"syn": {},
	}

func _unit_def(id: String) -> Dictionary:
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	for unit in units:
		if str((unit as Dictionary).get("id", "")) == id:
			return (unit as Dictionary).duplicate(true)
	return {}

func _owned_normal_count() -> int:
	var count := 0
	for cell in GameState.board_slots + GameState.bench_slots:
		if typeof(cell) == TYPE_DICTIONARY:
			count += 1
	return count

func _unit_star(id: String) -> int:
	var best := 0
	for cell in GameState.board_slots + GameState.bench_slots:
		if typeof(cell) == TYPE_DICTIONARY and str((cell as Dictionary).get("id", "")) == id:
			best = maxi(best, int((cell as Dictionary).get("star", 1)))
	return best

func _mercenary_count() -> int:
	var count := 0
	for cell in GameState.mercenary_slots:
		if cell != null:
			count += 1
	return count

# --- 萝卜 / 四星教学（9.25）-----------------------------------------------------

func _reset_carrot_tutorial() -> void:
	_camp_open = false
	_camp_page = CAMP_PAGE_CAMP
	_carrot_harvested = false
	_carrot_harvest_gain = 0
	_carrot_gift_claimed = false


# 萝卜营地开合 / 切页的生产事件（PrepUI._toggle_carrot_camp / _close_carrot_camp /
# CarrotCampPanelV3.page_changed）。教学步骤靠它推进，不靠轮询面板可见性。
func record_carrot_camp_state(is_open: bool, page: int) -> void:
	if not active:
		return
	if is_open == _camp_open and page == _camp_page:
		return
	_camp_open = is_open
	_camp_page = page
	sync()


func carrot_camp_open() -> bool:
	return _camp_open


func carrot_camp_page() -> int:
	return _camp_page


# 萝卜入口（营地按钮 + 萝卜数量）从萝卜教学开始才出现；之前的步骤里它只会分散注意力。
func carrot_ui_unlocked() -> bool:
	if not active:
		return false
	if step == Step.DONE:
		return true
	var intro := STEP_SEQUENCE.find(Step.CARROT_CAMP)
	return intro >= 0 and _progress_index >= intro


# 教学里萝卜相关操作「现在能不能做」。只在箭头指着它的那一步放行 ——
# 这是「强制按顺序点」的业务侧保证：箭头之外的同类按钮即使点到也不会生效。
func allows_carrot_action(action: String) -> bool:
	if not active:
		return false
	match action:
		"harvest_upgrade":
			return step == Step.HARVEST_UPGRADE and GameState.harvest_tech_level < 1
		"draw_stone":
			return step == Step.DRAW_STONE
		"four_star":
			return step == Step.FOUR_STAR
		"hire_merc":
			# 佣兵从 HIRE_MERC 这一步起才开放：更早雇会把抽升级石要用的萝卜花掉。
			var hire_at := STEP_SEQUENCE.find(Step.HIRE_MERC)
			return step == Step.DONE or (hire_at >= 0 and _progress_index >= hire_at)
	return false


func last_harvest_gain() -> int:
	return _carrot_harvest_gain


# 教学抽石头固定出「与 3 星棋子同属性」的那一种，四星那一步才一定接得上。
# 优先看民兵（教学第 7 步升到 3 星的就是它，地属性）。
func forced_stone_type() -> String:
	var cell := _four_star_candidate_cell()
	var element := str((cell.get("def", {}) as Dictionary).get("element", "")) if not cell.is_empty() else ""
	return element if CarrotEconomy.valid_stone_type(element) else "land"


func _carrot_target_id() -> String:
	match step:
		Step.CARROT_CAMP:
			return TutorialTargetProviderScript.TARGET_CARROT_CAMP
		Step.HARVEST_UPGRADE:
			if not _camp_open:
				return TutorialTargetProviderScript.TARGET_CARROT_CAMP
			if GameState.harvest_tech_level >= 1:
				return TutorialTargetProviderScript.TARGET_CARROT_CLOSE
			if _camp_page != CAMP_PAGE_CAMP:
				return TutorialTargetProviderScript.TARGET_CARROT_CAMP_TAB
			return TutorialTargetProviderScript.TARGET_HARVEST_UPGRADE
		Step.CARROT_HARVEST:
			return TutorialTargetProviderScript.TARGET_CARROT_COUNTER
		Step.DRAW_STONE:
			if not _camp_open:
				return TutorialTargetProviderScript.TARGET_CARROT_CAMP
			if _camp_page != CAMP_PAGE_STONE:
				return TutorialTargetProviderScript.TARGET_CARROT_STONE_TAB
			return TutorialTargetProviderScript.TARGET_STONE_DRAW
		Step.FOUR_STAR:
			if not _camp_open:
				return TutorialTargetProviderScript.TARGET_CARROT_CAMP
			if _camp_page != CAMP_PAGE_STONE:
				return TutorialTargetProviderScript.TARGET_CARROT_STONE_TAB
			return TutorialTargetProviderScript.TARGET_FOUR_STAR_ROW
	return ""


func _harvest_upgrade_text() -> String:
	var before := CarrotEconomy.production_for_tech(0)
	var after := CarrotEconomy.production_for_tech(1)
	if not _camp_open:
		return _t("点击「萝卜营地」打开营地。", "Tap Carrot Camp to open it.")
	if GameState.harvest_tech_level >= 1:
		return _t("采集升级了：每回合产量 %d → %d，下回合生效。点右上角「×」关闭营地，去挑战 Boss。" % [before, after],
			"Harvest upgraded: yield per round %d → %d, starting next round. Tap × at the top-right to close the camp and face the Boss." % [before, after])
	if _camp_page != CAMP_PAGE_CAMP:
		return _t("点「营地」页签。", "Tap the Camp tab.")
	var price := CarrotEconomy.tech_price(0)
	return _t("点「升级采集」，花 %d 金币把每回合产量从 %d 提到 %d。升级在下回合生效。" % [price, before, after],
		"Tap Upgrade Harvest: %d gold raises the yield per round from %d to %d, starting next round." % [price, before, after])


func _draw_stone_text() -> String:
	if not _camp_open:
		return _t("打开「萝卜营地」，用萝卜抽一颗升级石。", "Open Carrot Camp and spend carrots on an upgrade stone.")
	if _camp_page != CAMP_PAGE_STONE:
		return _t("点「升级石」页签。", "Tap the Upgrade Stones tab.")
	var cost := GameState.upgrade_stone_draw_cost()
	return _t("点「抽取一次」，花 %d 萝卜抽一颗升级石。教学奖励的萝卜可以超过容量；平时每回合自动收获，最多收到容量上限。" % cost,
		"Tap Draw Once: %d carrots for one upgrade stone. Tutorial bonus carrots may exceed capacity; normally each round's harvest stops at the cap." % cost)


func _four_star_text() -> String:
	var cell := _four_star_candidate_cell()
	var en := LocaleManager.get_locale() == "en"
	var unit_name := DataRegistry.unit_display_name(cell.get("def", {}), en) if not cell.is_empty() else _t("棋子", "unit")
	if not _camp_open:
		return _t("打开「萝卜营地」→「升级石」，把 3 星%s升到四星。" % unit_name,
			"Open Carrot Camp → Upgrade Stones and take your 3-star %s to 4 stars." % unit_name)
	if _camp_page != CAMP_PAGE_STONE:
		return _t("点「升级石」页签。", "Tap the Upgrade Stones tab.")
	var stone := forced_stone_type()
	var stone_name := str(({"sky": "Sky", "land": "Land", "ren": "Ren"} if en \
		else {"sky": "天", "land": "地", "ren": "人"}).get(stone, stone))
	return _t("抽到的%s石正好配 3 星%s。点它这一行的「升至四星」，再在弹出的详情里点「升级至四星」→「确认升级」。" % [stone_name, unit_name],
		"Your %s Stone matches the 3-star %s. Tap Upgrade to 4 Stars on its row, then Upgrade → Confirm in the details." % [stone_name, unit_name])


# 教学里唯一的一次萝卜收获（Boss 后）。与正式局同一条规则：GameState.harvest_carrots_for_round。
# 回合号取「当前回合」与「上次收获回合 + 1」中较大的那个 —— 不依赖教学局的回合怎么推进，
# 同时保留该函数「同一回合只收一次」的幂等语义。
func _run_tutorial_harvest() -> void:
	if _carrot_harvested:
		return
	var round_number := maxi(maxi(1, GameState.round_index), GameState.last_harvest_round + 1)
	var result := GameState.harvest_carrots_for_round(round_number)
	_carrot_harvest_gain = int(result.get("gain", 0))
	_carrot_harvested = true
	if _target_provider != null:
		_target_provider.request_action(TutorialTargetProviderScript.ACTION_PLAY_CARROT_HARVEST)
	_refresh_prep()


func _stone_count() -> int:
	var total := 0
	for stone_type in CarrotEconomy.STONE_TYPES:
		total += int(GameState.team_upgrade_stones.get(stone_type, 0))
	return total


func _max_normal_star() -> int:
	var best := 0
	for cell in GameState.board_slots + GameState.bench_slots:
		if typeof(cell) == TYPE_DICTIONARY and not bool((cell as Dictionary).get("is_mercenary", false)):
			best = maxi(best, int((cell as Dictionary).get("star", 1)))
	return best


# 能升四星的那枚 3 星棋子：优先民兵，其次任意 3 星普通棋子。
func _four_star_candidate_cell() -> Dictionary:
	var fallback: Dictionary = {}
	for cell in GameState.board_slots + GameState.bench_slots:
		if typeof(cell) != TYPE_DICTIONARY:
			continue
		var c: Dictionary = cell
		if bool(c.get("is_mercenary", false)) or int(c.get("star", 1)) != GameState.MAX_MERGE_STAR:
			continue
		if str(c.get("id", "")) == "human_militia":
			return c
		if fallback.is_empty():
			fallback = c
	return fallback


# 防卡死：进抽石头这一步时手里必须有一枚 3 星（玩家可能把民兵卖了）。
# 没有就补一枚 3 星民兵到待命区 —— 与 FILL_7 的补偿同一个思路：只补材料，不替玩家操作。
func _ensure_four_star_candidate() -> void:
	if _max_normal_star() >= GameState.MAX_UNIT_STAR:
		return
	if not _four_star_candidate_cell().is_empty():
		return
	_grant_units("human_militia", 1, GameState.MAX_MERGE_STAR)
	_refresh_prep()


# 防卡死：抽石头之前萝卜必须够。正常流程送的 100 萝卜一定够；这里兜住断点异常等情况。
func _ensure_draw_budget() -> void:
	if _stone_count() > 0:
		return
	if not GameState.can_draw_upgrade_stone(GameState.round_index):
		GameState.stone_draw_used_round = -1
	var cost := GameState.upgrade_stone_draw_cost()
	if GameState.carrots < cost:
		GameState.carrots = cost


# 防卡死：四星这一步必须存在「3 星棋子 + 同属性石头」这一对。
func _ensure_four_star_path() -> void:
	_ensure_four_star_candidate()
	var cell := _four_star_candidate_cell()
	if cell.is_empty():
		return
	var stone := str((cell.get("def", {}) as Dictionary).get("element", ""))
	if CarrotEconomy.valid_stone_type(stone) and int(GameState.team_upgrade_stones.get(stone, 0)) <= 0:
		GameState.apply_team_stone(stone)
		_refresh_prep()


func _t(zh: String, en: String) -> String:
	return en if LocaleManager.get_locale() == "en" else zh
