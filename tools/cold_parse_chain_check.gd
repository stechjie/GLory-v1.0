extends Node

const CheckHarness := preload("res://tools/CheckHarness.gd")
const CHECK_NAME := "cold_parse_chain"

const TARGETS: Array[Dictionary] = [
	{"kind": "script", "path": "res://effects/runtime/presentation/BoardReadabilityStyle.gd"},
	{"kind": "resource", "path": "res://data/presentation/board_readability_default.tres"},
	{"kind": "scene", "path": "res://effects/runtime/presentation/BoardReadabilityLayer.tscn"},
	{"kind": "scene", "path": "res://effects/runtime/presentation/UnitPortraitFallback3D.tscn"},
	{"kind": "script", "path": "res://effects/runtime/presentation/UnitActor3D.gd"},
	# 战斗继承链 `BattleUI → BattleArena → BattleRenderer → BattleVfx → BattleResult → BattleScreen`。
	# ★ 9.22 事故后补齐：此前只列了 BattleResult.gd，而**真正被改坏的那一层是 BattleVfx.gd**。
	#   出事形态是 `elif _owned:` 的语句体被整段抬出缩进 → 只剩注释 → 解析期错误。
	#   它能被抓到纯属侥幸（BattleScreen.tscn 实例化时连带失败）；把链上每一层都单列出来，
	#   才是「谁坏了就指谁」，而不是靠上层连带。
	{"kind": "script", "path": "res://scenes/battle/BattleUI.gd"},
	{"kind": "script", "path": "res://scenes/battle/BattleArena.gd"},
	{"kind": "script", "path": "res://scenes/battle/BattleRenderer.gd"},
	{"kind": "script", "path": "res://scenes/battle/BattleVfx.gd"},
	{"kind": "script", "path": "res://scenes/battle/BattleResult.gd"},
	# ★ 9.24 补齐：链的**最上一层 BattleScreen.gd 本身**之前只是靠 BattleScreen.tscn
	#   连带覆盖的。同 9.22 那条教训（"把链上每一层都单列出来，才是谁坏了就指谁"）——
	#   9.24 这一批真的改了 BattleScreen.gd（回放解码里补"策反锁存"），
	#   而它若解析失败，只能寄希望于 .tscn 连带报错，那就又回到靠侥幸。
	{"kind": "script", "path": "res://scenes/battle/BattleScreen.gd"},
	{"kind": "scene", "path": "res://scenes/battle/BattleScreen.tscn"},
	# ★ 9.25 补齐：这一批改了 BattleSimulator.gd（血链）、UnitDetailFormat.gd（技能文案）、
	#   PrepFlowController.gd / PrepBoardController.gd / ShopPanel.gd（教学开战门槛、
	#   商店刷新免费口径）。按 9.24 的教训「改的每个文件都要在清单里，谁坏了就指谁」，
	#   逐个单列 —— 只靠 PrepScreen.tscn 连带实例化等于把判据押在别人身上。
	{"kind": "script", "path": "res://scripts/battle/BattleSimulator.gd"},
	{"kind": "script", "path": "res://scripts/ui/UnitDetailFormat.gd"},
	{"kind": "script", "path": "res://scenes/prep/PrepFlowController.gd"},
	{"kind": "script", "path": "res://scenes/prep/PrepBoardController.gd"},
	{"kind": "script", "path": "res://scenes/prep/panels/ShopPanel.gd"},
	{"kind": "scene", "path": "res://scenes/prep/PrepScreen.tscn"},
	{"kind": "script", "path": "res://scripts/tutorial/TutorialMode.gd"},
	# ★ 9.25 第二批：改门禁本身也要在清单里。tutorial_text_leak_check.gd 的无效点击
	#   判据这轮换了口径（用户 ③(1)），新探针是这轮新增的行为判据 —— 它们各自都是
	#   直接以主场景加载的，解析失败时确实会自己报错，但按同一条教训还是单列出来，
	#   免得以后有人只跑批跑、看到"全绿"却不知道这两条根本没被解析过。
	{"kind": "script", "path": "res://tools/tutorial_text_leak_check.gd"},
	{"kind": "script", "path": "res://tools/qa_history/20260922/probe_blood_link_boss_immune_925.gd"},
	# ★ 9.25 追加订正：预备阶段又被改了（PrepUI.gd 的刷新按钮判定）。按「改的每个文件
	#   都要在清单里」补进来 —— PrepUI.gd 处在 PrepScreen 继承链的底层
	#   （PrepScreen → PrepBoardController → PrepFlowController → PrepUI → PrepBoardModels
	#   → PrepShared），解析失败会连带整条链；单列才是「谁坏了就指谁」。
	{"kind": "script", "path": "res://scenes/prep/PrepUI.gd"},
	# 新门禁自身也在清单里（同 9.25 第二批的理由：改门禁也要被解析过）。
	{"kind": "script", "path": "res://tools/shop_refresh_free_source_check.gd"},
	# ★ 9.26 新增：大厅宠物脚步声。改了 MainMenuPet.gd（每宠物独立播放器 + 步频触发）、
	#   SfxService.gd（新增 CUE_PET_FOOTSTEP），并新增 pet_footstep_check.gd 门禁。
	#   按「改的每个文件都要在清单里，谁坏了就指谁」逐个单列。
	{"kind": "script", "path": "res://scenes/menu/MainMenuPet.gd"},
	{"kind": "script", "path": "res://ui/services/SfxService.gd"},
	{"kind": "script", "path": "res://tools/pet_footstep_check.gd"},
	# ★ 9.27 新增：大厅商店 / 公告图标预览。改 MainMenu.gd（图标内显示最新商品缩略图与
	#   最新公告标题），按同一条教训补进清单。
	{"kind": "script", "path": "res://scenes/menu/MainMenu.gd"},
	# ★ 9.27 第二批（bug提交和修复.docx 5 条）：改了 BattleSimShared.gd（毒灵可达性选敌 +
	#   隔断唯一真源 + C 层跨路限制）、BattleSimSkills.gd（瞬移/冲锋类技能按可达 lane 过滤）、
	#   NetworkService.gd（重连时把服务端权威的商店刷新次数同步回客户端计数）。
	#   BattleSimulator.gd / BattleArena.gd / UnitDetailFormat.gd 已在上面清单里。
	#   按「改的每个文件都要在清单里，谁坏了就指谁」逐个单列。
	{"kind": "script", "path": "res://scripts/battle/BattleSimShared.gd"},
	{"kind": "script", "path": "res://scripts/battle/BattleSimSkills.gd"},
	{"kind": "script", "path": "res://scripts/autoload/NetworkService.gd"},
	# ★ 9.27 第三批（bug提交和修复.docx 第 2 条：房间邀请好友）。新增
	#   scripts/multiplayer/RoomInvite.gd（纯判据），改了 ChatScreen.gd（邀请框 + 立即参与）、
	#   Team3v3Lobby.gd（朋友列表可点 + 亮一下 + 限流）、Main.gd（把 join_room_requested
	#   接到已有的加入路径）、AccountManager.gd（send_chat_message 带 kind/payload）。
	#   按「改的每个文件都要在清单里，谁坏了就指谁」逐个单列 —— ChatScreen.gd / Team3v3Lobby.gd
	#   都会被 Main 直接 instantiate，但那只在运行时才暴露，不能把判据押在别人身上。
	{"kind": "script", "path": "res://scripts/multiplayer/RoomInvite.gd"},
	{"kind": "script", "path": "res://scenes/menu/ChatScreen.gd"},
	{"kind": "script", "path": "res://scenes/menu/Team3v3Lobby.gd"},
	{"kind": "script", "path": "res://scenes/main/Main.gd"},
	{"kind": "script", "path": "res://scripts/autoload/AccountManager.gd"},
	{"kind": "script", "path": "res://tools/room_invite_check.gd"},
	# ★ 9.28 第一批（9.28bug提交及修复.docx 5 条）：改了 ui/components/ReportDialog.gd
	#   （举报弹窗选中/未选中边框）、scripts/autoload/ChatService.gd（新消息音效场景门控）、
	#   scripts/multiplayer/RoomInvite.gd（10 秒冷却改为仅换房计时）、ChatScreen.gd /
	#   Main.gd / Team3v3Lobby.gd / AccountManager.gd（邀请失效前移 + room_started 上报，
	#   这一项 09-29 已撤回）。
	#   ReportDialog.gd 与 ChatService.gd（autoload）此前只在别的清单里靠连带覆盖 ——
	#   按「改的每个文件都要在清单里，谁坏了就指谁」逐个单列。
	{"kind": "script", "path": "res://ui/components/ReportDialog.gd"},
	{"kind": "script", "path": "res://scripts/autoload/ChatService.gd"},
	# ★ 9.29：撤回邀请「点之前变灰」与 room_started；加入被拒改走 MainMenu.show_join_rejected
	#   （MainMenu.gd / Main.gd / ChatScreen.gd / RoomInvite.gd 已在上面），门禁替身跟着改。
	{"kind": "script", "path": "res://tools/main_team_join_room_action_check.gd"},
	# ★ 9.29 第二批：换座后账号跟着人走 + 对局历史「详细战况」（结算面板进战报、历史里复用）。
	{"kind": "script", "path": "res://scripts/multiplayer/RoomService.gd"},
	{"kind": "script", "path": "res://scripts/multiplayer/BattleReport.gd"},
	{"kind": "script", "path": "res://scenes/menu/FinalSettlementPanel.gd"},
	{"kind": "script", "path": "res://scenes/menu/MatchHistoryPanel.gd"},
	{"kind": "script", "path": "res://tools/seat_identity_check.gd"},
	{"kind": "script", "path": "res://tools/match_history_ui_check.gd"},
	{"kind": "script", "path": "res://tools/battle_report_check.gd"},
	{"kind": "script", "path": "res://tools/final_settlement_check.gd"},
	# ★ 10.05（10.05bug提交及修复.docx 5 条）：按「改的每个文件都要在清单里，谁坏了就指谁」
	#   逐个单列。★ 这一批**真的抓到一个漏网**：`ui/components/TouchScrollContainer.gd`
	#   在补进清单之前根本没人解析它 —— 它里面 `var local := _accepts(pos)`（从 Variant
	#   推断）触发了本工程当错误用的 `inference_on_variant`，解析直接失败；门禁却全绿，
	#   只有日志里一行 SCRIPT ERROR。教训与 9.22 一模一样：**没有单列 = 靠别人连带**，
	#   而别人连带失败时 `CHECK_RESULT` 仍可能是 PASS。
	{"kind": "script", "path": "res://ui/components/TouchScrollContainer.gd"},
	{"kind": "script", "path": "res://ui/components/RoundedRectDraw.gd"},
	{"kind": "script", "path": "res://ui/components/SoftEdgeGlow.gd"},
	{"kind": "script", "path": "res://scenes/prep/CarrotCampPanelV3.gd"},
	{"kind": "script", "path": "res://scenes/prep/PrepShared.gd"},
	{"kind": "script", "path": "res://scenes/prep/PrepRules.gd"},
	{"kind": "script", "path": "res://scenes/prep/panels/PrepDeployCounter.gd"},
	{"kind": "script", "path": "res://effects/runtime/presentation/BoardReadabilityLayer.gd"},
	{"kind": "script", "path": "res://scenes/prep/PrepWidgets.gd"},
	{"kind": "script", "path": "res://scenes/prep/panels/TreasureChoicePanel.gd"},
	{"kind": "script", "path": "res://scripts/autoload/LocaleManager.gd"},
	{"kind": "script", "path": "res://scripts/pets/PetPreview.gd"},
	{"kind": "script", "path": "res://tools/battle_loading_layout_check.gd"},
	# ★ 本轮新写的两个行为门禁也要单列：它们是新代码，没人「连带」解析。
	#   （`prep_1005` 覆盖第 2/3/4 条，`touch_scroll` 覆盖第 1 条。）
	{"kind": "script", "path": "res://tools/prep_1005_check.gd"},
	{"kind": "script", "path": "res://tools/touch_scroll_check.gd"},
	# ★ 10.06 新增：摆放界面头像放大 + 点开卡片（不看留言 / 不听语音）。
	#   PrepUI.gd 已在上面；新卡片、聊天记录的屏蔽、新门禁按同一条教训单列。
	{"kind": "script", "path": "res://scenes/prep/panels/PrepSeatCard.gd"},
	{"kind": "script", "path": "res://scripts/multiplayer/RoomChatLog.gd"},
	{"kind": "script", "path": "res://tools/prep_seat_card_check.gd"},
	# ★ 10.06 第二批：退出对局（断线遮罩 / 摆放界面「设定」/ 开新局被拦）。
	#   Main / NetworkService / PrepUI / PrepShared / MatchHistoryPanel / LocaleManager 已在上面，
	#   新文字表、设定页、重连凭证、新门禁单列。
	{"kind": "script", "path": "res://scripts/multiplayer/MatchExitPenalty.gd"},
	{"kind": "script", "path": "res://scenes/menu/SettingsScreen.gd"},
	{"kind": "script", "path": "res://scripts/autoload/SaveManager.gd"},
	{"kind": "script", "path": "res://tools/match_exit_check.gd"},
	# ★ 10.06 第三批：分路光墙换成能量护栏（按半场分红蓝）。BattleArena.gd 已在上面；
	#   护栏脚本 / 场景、预热、预览场景和改过的三个门禁单列。
	{"kind": "script", "path": "res://effects/battlefield/energy_barrier/EnergyBarrierSegment.gd"},
	{"kind": "scene", "path": "res://effects/battlefield/energy_barrier/EnergyBarrierSegment.tscn"},
	{"kind": "script", "path": "res://effects/vfx3d/VFXWarmup.gd"},
	{"kind": "script", "path": "res://scenes/debug/EnergyBarrierReview.gd"},
	{"kind": "script", "path": "res://tools/battle_lane_barrier_check.gd"},
	{"kind": "script", "path": "res://tools/battle_final_lane_wall_check.gd"},
	{"kind": "script", "path": "res://tools/vfx_warmup_check.gd"},
	# ★ 10.06 第四批：PvP 正上方对正下方（蓝队棋盘不镜像、蓝队画面只上下翻，协议 38）。
	#   BattleSimShared / BattleSimulator / BattleArena 已在上面；协议号文件和新门禁单列。
	{"kind": "script", "path": "res://scripts/multiplayer/NetworkConfig.gd"},
	{"kind": "script", "path": "res://tools/pvp_lane_alignment_check.gd"},
]


func _ready() -> void:
	var harness := CheckHarness.new(CHECK_NAME)
	for target: Dictionary in TARGETS:
		_check_target(harness, target)
	harness.finish(get_tree())


func _check_target(harness: RefCounted, target: Dictionary) -> void:
	var path: String = str(target.get("path", ""))
	var kind: String = str(target.get("kind", ""))
	var resource: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if not harness.expect(resource != null, "resource_load", "%s must load without a warm global class cache" % path):
		return
	if kind == "script":
		if not harness.expect(resource is Script, "script_type", "%s must load as a Script" % path):
			return
		# ★ 判据必须落在 `can_instantiate()` 上，**不能只看 `load() != null`**。
		#   9.22 实测：一个**解析失败**的 GDScript，`ResourceLoader.load()` 照样返回
		#   非 null 对象（`res == null` 为 false、`res is Script` 为 true），
		#   但 `can_instantiate()` 为 false、`get_script_method_list()` 为 0 条。
		#   所以「load 得到东西」证明不了「这份脚本是好的」。
		var script := resource as Script
		harness.expect(script.can_instantiate(), "script_parseable",
			"%s 解析失败：load() 拿到了非 null 对象，但 can_instantiate() 为 false（说明有解析期错误）" % path)
		return
	if kind == "scene":
		if not harness.expect(resource is PackedScene, "scene_type", "%s must load as a PackedScene" % path):
			return
		var instance: Node = (resource as PackedScene).instantiate()
		if not harness.expect(instance != null, "scene_instantiate", "%s must instantiate after a cold parse" % path):
			return
		harness.expect(instance.get_script() != null, "root_script", "%s root must retain its script" % path)
		instance.free()

