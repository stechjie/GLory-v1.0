extends SceneTree
# 宣传片专用：一条**连续长镜**，中路两名极光射手顶着一波又一波怪，
# 期间升星、上裁决者、集齐四个元素宝藏，最后一波 20 只小怪加一只 Boss。
#
#   godot --path . --script tools/trailer_capture.gd \
#         --write-movie <out>/frame.png --fixed-fps 60 --resolution 1080x1920 \
#         --quit-after <N> -- --out <out>
#
# 用 tools/trailer_capture.ps1 调，别直接跑：它算 --quit-after、清输出目录、
# 把 PNG 挡在资源导入器外面。
#
# —— 为什么这条长镜拍得出来 ——
#
# `BattleSimulator._replay_capture_roster()` 是**每 tick 都跑**的（见 BattleSimulator.gd
# 的 compute_team_replay 循环），不是开场快照；`BattleScreen._load_replay_roster()`
# 把 roster 里所有单位都预建成 `alive: false`，之后逐帧用 alive/pos/hp 列驱动显隐。
# 寄生灵的分身就是靠这条路中途进场的（BattleScreen.gd 自己的注释写了这件事）。
# 所以「战斗中途往 state.enemy 里 append 怪」是游戏里已经在跑的生产能力，
# 本脚本只是把它当编排工具用 —— 战斗核心代码一行都不改。
#
# 与 tools/promo_capture.gd 的关系：那个录**一场真实对局**，有自己的阵容表和取景参数，
# 刻意不共享代码。这个录的是**摆出来的编排**，节奏由 BEATS 表定，两者的「真实性契约」
# 不一样，混在一起只会互相污染。
#
# 诚实声明：游戏里不存在「一场战斗四波怪」这个玩法。画面里的资产、战斗判定、
# 伤害数值全是真的，节奏是为宣传片摆的。

const BATTLE_SCREEN_PATH := "res://scenes/battle/BattleScreen.tscn"

# 中路。TEAM_LANE_CENTERS = [230, 500, 770]，取中间那条。
const LANE := 1

# 棋盘 4x4，slot = row * 4 + col。玩家侧 y = 260 + 55 + row*44，
# 敌方在低 y，所以**row 越大越靠后**。后排中间两列 = slot 13 / 14，
# 这就是「两个极光射手放在后面射」。
const SHOOTER_SLOTS := [13, 14]
# 裁决者射程 1，是近战，放前排中间挡着射手。
const ARBITER_SLOT := 1
# 前排两侧的光之卫士。它的技能是 `guardian_shield_taunt`（嘲讽）——
# 这才是后排两个射手能活下来的**机制**理由，不是靠调数值硬凑：
# 怪被拉到前排，射手在 4 格射程外安心输出。
# 没有这条前排，15 只怪会直接越过裁决者把后排推平（实测过）。
const GUARD_SLOTS := [0, 2]
# 神王。射程 1、模型大，摆在第二排正中（slot 5）：前排三个挡着，
# 他从中路压上去，登场那一下在画面正中央。
const KING_SLOT := 5

# —— 版本表 ——
# 同一条节奏（BEATS）换一套阵容。BEATS 里上场的棋子和宝藏不写死 id，写「位置」：
#   @front     第二波上场、站前排中间（ARBITER_SLOT）
#   @flank     第三波上场的两个、站前排两侧（GUARD_SLOTS）
#   @finisher  Boss 登场时上场的压轴棋子（KING_SLOT）
#   @t0..@t3   第几个宝藏
# 由 --variant 选哪一套。god 是第一版（极光射手），dark 是暗族版（用户 10-21 要的）。
const VARIANTS := {
	"god": {
		"shooter": "god_aurora",
		"front": "god_arbiter",
		"flank": "god_guard",
		"finisher": "god_king",
		"monster": "pve_ren_shadow_thief",
		"boss": "boss_rage_beast",
		"monster_power": 1.0,
		"boss_power": 1.0,
		"count_scale": 1.0,
		# 四件元素宝藏：集齐满足 has_set("element")，20% 攻击触发 180 范围元素爆发。
		"treasures": [
			["elem_toxic_spread", "剧毒蔓延"],
			["elem_flame_shatter", "炎焰碎裂"],
			["elem_frost_blade", "冰封霜刃"],
			["elem_thunder_haste", "雷霆加速"],
		],
		"set_category": "element",
		"set_logo": "4元素",
		"card_decoys": ["god_priest", "god_angel", "god_archangel", "god_priestess", "god_guard"],
		"treasure_decoys": ["def_iron_wall", "atk_blood_pact", "ctrl_shockwave", "def_life_monument", "ctrl_time_compress"],
	},
	# 暗族：暗影法师当主角 → 痛苦女王 → 偷袭者 → 黑龙压轴，雷怒核心当 Boss，
	# 宝藏换成紫色那套「4控制」。
	"dark": {
		"shooter": "dark_mage",
		"front": "dark_queen",
		"flank": "dark_scythe",
		"finisher": "dark_dragon",
		# 雷鸣灵：远程、链式闪电，跟雷系 Boss 配成一套；不会瞬移，600hp 也不算肉。
		"monster": "pve_sky_thunder_spirit",
		"boss": "boss_thunder_core",
		# 怪物强度：小怪 / Boss 的血量、攻击、技能伤害按这个比例缩。宣传片调参，跟游戏真实
		# 数值无关。暗族这套打不过神族版同样的怪量：暗影法师是 1 阶（血 520 / 攻 48，极光
		# 射手是 2 阶 720 / 77），偷袭者会闪去敌人后排、不替法师挡；按原强度实测雷鸣灵 /
		# 流浪剑客 / 巫毒术士 / 星辉蝶 / 藤蔓守卫全都全灭。
		# 用户第二轮要「Boss 活久一点、怪多一点更有打击感」。血量 / 攻击分开调之后：
		#   怪数量 ×2，每只血 0.3、攻 0.25 —— 同屏更多、倒得更多，总压力和原来差不多；
		#   Boss 血 6.5、攻 0.08 —— 从 45.5s 打到 58.7s（原来 0.5 / 0.6 一套只撑 6 秒）。
		# 实测两个 4 星法师、两个偷袭者、黑龙都活到最后，痛苦女王 35s 在前排倒下。
		# 小怪攻击是关键：0.3 时最后一批怪（狂暴阶段伤害翻倍）会在 50s 磨死一个法师，
		# 跟 Boss 攻击调多低无关（阵亡日志对过）。
		"monster_power": 0.3,
		"monster_atk_power": 0.25,
		"count_scale": 2.0,
		"boss_power": 6.5,
		"boss_atk_power": 0.08,
		# 控制类一共 5 件，套装要 4 件。挑打中都有可见效果的四件
		# （眩晕 / 流血 / 打断 / 减速）；时空压缩只改技能冷却，画面上看不出来，不用。
		# 集齐满足 has_set("control")：普攻打出最后一击时刷新技能冷却 —— 技能放得更勤。
		"treasures": [
			["ctrl_shockwave", "震荡余波"],
			["ctrl_corrosive_needle", "腐蚀毒针"],
			["ctrl_interrupt_chain", "打断锁链"],
			["ctrl_binding_weight", "束缚重压"],
		],
		"set_category": "control",
		"set_logo": "4控制",
		"card_decoys": ["dark_imp", "dark_fear", "dark_suc", "dark_doom", "dark_imp"],
		# 陪衬卡不能是控制类，否则观众看不出「为什么偏偏选这张」。
		"treasure_decoys": ["def_iron_wall", "atk_blood_pact", "elem_flame_shatter", "def_life_monument", "money_lucky_envelope"],
	},
}

# 怪的出生点。默认 `_append_lane_monsters` 把怪放在 y≈205（紧贴中线），
# 那样是「凭空出现在脸上」。往远端（低 y）挪，它们才会**走进来**，
# 一波一波压上来的观感全靠这个。board_cell_pos 的 y 下限是 45。
const SPAWN_Y_NEAR := 150.0
const SPAWN_Y_FAR := 55.0
const SPAWN_ROW_GAP := 30.0

# 同屏活怪少到这个数就提前把下一批拉进来 —— 既不让画面空场，也避免
# step_state 看到敌方空了就判定战斗结束。
#
# 取 1 而不是 2：首批只有 2 只，阈值 2 会在它们刚落地那一刻就触发，
# 于是一批接一批连锁拉满，整张编排表被压扁成十几秒（实测第一版就是这样，
# 编排只跑到 35.2 秒、第四波和 4 星根本没来）。
const MIN_ALIVE_FLOOR := 1
# Boss 还没到点、场上却快清空时补的那一小批（见 _fire_due_beats）。
const FILLER_BATCH := 3

const TICK := 0.1
# 编排表最后一拍之后再跑这么久收尾（4 星射手清完最后一波 + Boss）。
const TAIL_SEC := 14.0
# 硬上限，防畸形编排把 PNG 写满硬盘。BattleSimShared.HARD_TIMEOUT_SEC 是 180。
const MAX_TICKS := 1500

# 让画面建完、稳定下来的预热帧数。
const SCREEN_WARMUP_FRAMES := 45
const TAIL_FRAMES := 45

# 宝藏图标按宝藏中文名命名（assets/ui/treasure_logos/<name>.png）。哪四件、哪个套装
# logo 见 VARIANTS；同一类别集齐 4 件就满足 TreasureService.has_set（判据是 >= 4）。
const TREASURE_LOGO_DIR := "res://assets/ui/treasure_logos/"
# 底部居中那排的图标边长。够大到看清是什么元素，但不抢戏 ——
# 它是收集进度，不是主角。
# 按画面**短边**的比例算，不写死像素：横版 1080 高、竖版 1080 宽都按同一观感出。
# 比例取用户看过、点了头的那版预览（540 高的画面里 72px / 96px）。
const LOGO_RATIO := 72.0 / 540.0
# 套装 logo 比元素大一圈，但**排在同一行**，不另起一行。
# 摞在上面那版会爬进战场中央，正好盖住正在打的棋子。
const SET_LOGO_RATIO := 96.0 / 540.0
# 弹出动画时长（回放 tick，1 tick = 0.1 秒）。从 POP_SCALE 倍缩回 1.0。
const POP_TICKS := 6.0
const POP_SCALE := 1.9

# —— 编排表 ——
# `t` 是战斗内秒数（模拟时间，与录制帧率无关）。按 t 升序执行。
#
# 节奏约 60 秒，刻意压在 BattleFrenzyService.SUDDEN_DEATH_SEC（65 秒）之前；
# 真跑过头也不怕 —— 循环里每 tick 把 state.next_sudden_death_tick 往后推，
# 猝死不会把自家射手刮死。狂暴 I/II/III（35/45/55 秒）**不拦**：
# 越到后面越快越凶，正好是宣传片要的。
#
# `growth` 调 GameState.pve_completed，走游戏自己的 growth_per_completed_pve
# （hp ×1.1、atk ×1.08 每场），所以后面的波次是**真的**更硬，不是摆样子。
const BEATS: Array = [
	# —— 第一波：2 个 1 星射手 vs 5 只怪 ——
	# 后三波的怪量比最初多一半（15/22/30）：用户要「打击感」，同屏挨打、倒下的怪
	# 越多，命中和死亡演出就越密。**第一波不加**：这时只有两个后排射手、没有前排，
	# 影行盗徒的 backstab 会跳后排，8 只实测在 t=10 把射手打死（wipeout）。
	{"t": 0.0, "op": "growth", "pve_completed": 0},
	{"t": 0.0, "op": "monsters", "count": 2, "y": SPAWN_Y_NEAR},
	{"t": 2.5, "op": "monsters", "count": 2, "y": SPAWN_Y_NEAR},
	{"t": 5.0, "op": "monsters", "count": 1, "y": SPAWN_Y_NEAR},

	# —— 升 2 星、3 星 ——
	# 每次升星都是：射手卡出现 → 点击 → 两个射手身上放升星迸发 + 头顶飘星级字。
	# 两次之间留够 2.6 秒的选卡演出时长，卡牌不会叠在一起。
	{"t": 6.5, "op": "star", "star": 2},
	{"t": 12.0, "op": "star", "star": 3},

	# —— 第二波：15 只怪，裁决者上前排 ——
	{"t": 13.0, "op": "growth", "pve_completed": 1},
	# 裁决者比 3 星晚 3 秒：每次部署的选卡演出约 2.6 秒，挨太近两组卡会叠在一起。
	{"t": 15.0, "op": "unit", "id": "@front", "slot": ARBITER_SLOT, "star": 2},
	{"t": 13.5, "op": "monsters", "count": 4, "y": SPAWN_Y_NEAR},
	{"t": 16.0, "op": "monsters", "count": 4, "y": SPAWN_Y_FAR},
	{"t": 19.0, "op": "monsters", "count": 4, "y": SPAWN_Y_NEAR},
	{"t": 22.0, "op": "monsters", "count": 3, "y": SPAWN_Y_FAR},

	# —— 两个宝藏：毒 + 火 ——
	{"t": 20.0, "op": "treasure", "id": "@t0"},
	{"t": 24.0, "op": "treasure", "id": "@t1"},

	# —— 第三波：22 只怪，前排补两个嘲讽卫士 ——
	{"t": 27.0, "op": "growth", "pve_completed": 4},
	{"t": 26.5, "op": "unit", "id": "@flank", "slot": GUARD_SLOTS[0], "star": 2},
	{"t": 26.5, "op": "unit", "id": "@flank", "slot": GUARD_SLOTS[1], "star": 2},
	{"t": 27.0, "op": "monsters", "count": 5, "y": SPAWN_Y_NEAR},
	{"t": 30.0, "op": "monsters", "count": 5, "y": SPAWN_Y_FAR},
	{"t": 33.0, "op": "monsters", "count": 6, "y": SPAWN_Y_NEAR},
	{"t": 36.0, "op": "monsters", "count": 6, "y": SPAWN_Y_FAR},

	# —— 集齐四元素：冰 + 雷 → element 套装亮 ——
	{"t": 34.0, "op": "treasure", "id": "@t2"},
	{"t": 38.0, "op": "treasure", "id": "@t3"},

	# —— 升 4 星 ——
	{"t": 41.5, "op": "star", "star": 4},

	# —— 第四波：30 只怪 + Boss 压轴，神王接场 ——
	# 棋子跟着波次一路长：2 个射手 → +裁决者 → +2 卫士 → +神王，收在 6 个
	# （上限 GameConstants.NORMAL_UNIT_CAP = 7）。神王的技能是 global_divine_blast，
	# 全场 AOE，是技能库里最大的一个，正好压 Boss 登场这一拍。
	# 排在 boss 前 1 秒：王先落位，Boss 再压上来，比两个一起冒出来读得清。
	# growth 拉到 6（怪血 ×1.1^6 ≈ 1.77）：4 星射手配齐四元素之后输出太高，
	# 脆怪撑不过一秒就清空，最后一波还没摆完战斗就结束了。
	{"t": 42.0, "op": "growth", "pve_completed": 6},
	{"t": 42.0, "op": "monsters", "count": 7, "y": SPAWN_Y_NEAR},
	{"t": 44.8, "op": "unit", "id": "@finisher", "slot": KING_SLOT, "star": 2},
	{"t": 44.0, "op": "monsters", "count": 7, "y": SPAWN_Y_FAR},
	# Boss 排在最后一批怪**之前**：它得在场上还有怪的时候登场，
	# 不然清场一快就轮不到它（上一版就是这么丢掉 Boss 的）。
	{"t": 45.5, "op": "boss"},
	{"t": 47.0, "op": "monsters", "count": 8, "y": SPAWN_Y_NEAR},
	{"t": 50.0, "op": "monsters", "count": 8, "y": SPAWN_Y_FAR},
]

var _out_dir := ""
var _locale := "en"
var _seed := 20261020
var _fps := 60
var _realtime := false
var _hud := false
# 整场只用这一种怪。不传 --monster 就用版本表里的。神族版是影行盗徒（480hp / def 4）：
# 两个射手要打出「一直在清」的观感，回合自带的藤蔓守卫这类肉怪实测会把射手推平
# （wipeout）；按每波换熔岩傀儡 / 岩甲兽 / 天穹守卫也试过，同样全灭。
var _monster_id := ""
# 当前版本（--variant），以及由它展开的阵容 / 宝藏。见 VARIANTS。
var _variant := "god"
var _shooter_id := ""
var _roles: Dictionary = {}
# 宝藏 id -> 中文名，按底部 logo 条的顺序（Dictionary 保留插入顺序）。
var _treasures: Dictionary = {}
var _treasure_order: Array = []
var _set_category := ""
var _set_logo := ""
var _card_decoys: Array = []
var _treasure_decoys: Array = []
var _monster_power := 1.0
var _boss_power := 1.0
var _count_scale := 1.0
# --monster-power 调参用；< 0 表示没给，用版本表里的。
var _monster_power_cli := -1.0
var _boss_power_cli := -1.0
var _count_scale_cli := -1.0
var _monster_atk_power := 1.0
var _boss_atk_power := 1.0
var _monster_atk_cli := -1.0
var _boss_atk_cli := -1.0
# 当前这一波用哪种怪（BEATS 里的 monster_type 拍子设）。空 = 按回合号挑模板。
var _wave_monster_id := ""
# 单位位置插值。**默认关**：用户对照自己实际玩的一局（桌面录屏逐帧量过）——游戏里
# 单位本来就是每 0.1 秒更新一次位置，没有插值；录制要「跟正常游戏一样」。
# --smooth 打开（只影响单位位置；卡牌 / logo 等 UI 动画始终逐帧平滑，游戏里 UI 也是）。
var _smooth := false
var _boss_id := ""
# 竖版取景。BattleArena 的相机是按 16:9 调的，9:16 下战斗会挤在上半屏。
# 0 表示「按游戏原样」，所以默认值完全复现原生取景。
# 画质（用户：「开最大功率去跑」—— 这是离线录视频，帧耗时不影响任何人）。
#   _ssaa：3D 视口内部渲染倍率。2.0 = 横版内部按 3840x2160 画再缩到 1920x1080（超采样）。
#   _msaa：3D 多重采样。游戏自己最高档只开 2x（BattleArena 里按画质档决定），录制拉到 8x。
var _ssaa := 2.0
var _msaa := 8
var _quality_applied := false
var _camera_size := 0.0
var _pan_x := 0.0
var _pan_z := 0.0

# 自动加载只能经场景树拿。--script 启动时主循环先被换掉，自动加载的全局名
# 还没注册，所以这里写 `GameState.foo` 是编译错误 —— 跟 promo_capture 同一个原因。
var _game_state: Node = null
var _data: Node = null
var _network: Node = null
var _sim: GDScript = null
var _defs_cache: Dictionary = {}

var _screen: Node = null
var _frame := 0
var _setup_done := false
var _start_frame := -1
var _finished_frame := -1
var _start_unix_msec := 0
var _finished_unix_msec := 0
var _replay_frames := 0
var _viewport_size := Vector2i.ZERO
var _camera_applied := false
var _camera_target_size := 0.0
var _camera_target_pos := Vector3.ZERO

# 怪的 uid 序号。`_append_lane_monsters` 自己生成的 uid 是 "enemy_L%d_m%d"，
# 重复调用必然撞车（撞了就等于两批怪共用一个 uid，回放直接错乱），所以生成完一律改写。
var _spawn_serial := 0
# 右下角宝藏 logo 条：按 t 换算出点亮的播放帧号。
var _treasure_cues: Array = []
var _logo_nodes: Dictionary = {}
var _set_logo_node: TextureRect = null
var _logo_layer: CanvasLayer = null
# 套装特效的状态机：0=未开始，1=格子已排进布局（等下一帧读矩形），
# 2=特效播放中，3=已落位，可以亮出真图标。
var _set_fx_state := 0
var _set_landed_age := 0.0
var _set_fx_age := 0.0
# 部署 / 升星演出提示（_record_deploy 写，_update_deploys 播）。
var _deploy_cues: Array = []
# 单位 3D 模型位置插值的状态：节点 instance_id -> {prev, target, shown}。
var _interp: Dictionary = {}
# 宝藏条和部署卡牌共用的覆盖层根节点（铺满画面、不接收输入）。
var _overlay_root: Control = null


func _initialize() -> void:
	_parse_arguments()
	_apply_variant()


func _apply_variant() -> void:
	if not VARIANTS.has(_variant):
		push_error("未知版本 '%s'。可选：%s" % [_variant, ", ".join(VARIANTS.keys())])
		quit(1)
		return
	var v: Dictionary = VARIANTS[_variant]
	_shooter_id = str(v["shooter"])
	_roles = {"@front": str(v["front"]), "@flank": str(v["flank"]), "@finisher": str(v["finisher"])}
	_treasures = {}
	_treasure_order = []
	for pair in v["treasures"]:
		_treasures[str(pair[0])] = str(pair[1])
		_treasure_order.append(str(pair[0]))
	_set_category = str(v["set_category"])
	_set_logo = str(v["set_logo"])
	_card_decoys = (v["card_decoys"] as Array).duplicate()
	_treasure_decoys = (v["treasure_decoys"] as Array).duplicate()
	if _monster_power_cli < 0.0:
		_monster_power = float(v.get("monster_power", 1.0))
	else:
		_monster_power = _monster_power_cli
	_boss_power = float(v.get("boss_power", 1.0)) if _boss_power_cli < 0.0 else _boss_power_cli
	# 攻击系数没单独给就跟血量系数一样（神族版两个都是 1.0）。
	_monster_atk_power = float(v.get("monster_atk_power", _monster_power)) if _monster_atk_cli < 0.0 else _monster_atk_cli
	_boss_atk_power = float(v.get("boss_atk_power", _boss_power)) if _boss_atk_cli < 0.0 else _boss_atk_cli
	_count_scale = float(v.get("count_scale", 1.0)) if _count_scale_cli < 0.0 else _count_scale_cli
	# 命令行显式给了 --monster / --boss 就听命令行的。
	if _monster_id.is_empty():
		_monster_id = str(v["monster"])
	if _boss_id.is_empty():
		_boss_id = str(v["boss"])
	print("trailer_capture: 版本 %s —— 主角 %s，怪 %s 血×%.2f 攻×%.2f 量×%.2f，Boss %s 血×%.2f 攻×%.2f，宝藏 %s" % [
		_variant, _shooter_id, _monster_id, _monster_power, _monster_atk_power, _count_scale,
		_boss_id, _boss_power, _boss_atk_power, _set_logo])


# BEATS 里的 @位置 → 这个版本的真实 id。
func _resolve_id(id: String) -> String:
	if id.begins_with("@t"):
		var i := int(id.substr(2))
		return str(_treasure_order[i]) if i >= 0 and i < _treasure_order.size() else ""
	return str(_roles.get(id, id))
	if _realtime:
		Engine.max_fps = _fps


func total_frames() -> int:
	# 模型预热按机器和输出分辨率变化，不能用固定 45 帧抵扣。
	# 战斗开始后按真实起始帧计算，才不会把最后几秒提前截掉。
	var lead := _start_frame if _start_frame >= 0 else SCREEN_WARMUP_FRAMES
	return lead + int(ceil((_last_beat_time() + TAIL_SEC) * float(_fps))) + TAIL_FRAMES


func _last_beat_time() -> float:
	var last := 0.0
	for b: Dictionary in BEATS:
		last = maxf(last, float(b.get("t", 0.0)))
	return last


# 整套 setup 放在第一个 _process 帧，不在 _initialize()。
# _initialize() 早于自动加载的 _ready()，而 LocaleManager 在它的 _ready() 里
# 才注册翻译表 —— 提前建战斗会让每个单位的名字都变成翻译键。等一帧就解决。
func _setup() -> void:
	if _realtime:
		root.visible = true
		root.borderless = true
		root.size = Vector2i(int(ProjectSettings.get_setting("display/window/size/viewport_width")), int(ProjectSettings.get_setting("display/window/size/viewport_height")))
		root.position = Vector2i.ZERO
		DisplayServer.window_set_title("GLory Trailer Capture")
		print("  实时窗口：visible=%s size=%s viewport=%s" % [str(root.visible), str(root.size), str(root.get_visible_rect().size)])
	_game_state = root.get_node_or_null("GameState")
	_data = root.get_node_or_null("DataRegistry")
	_network = root.get_node_or_null("NetworkService")
	var locale_mgr := root.get_node_or_null("LocaleManager")
	if _game_state == null or _data == null or _network == null or locale_mgr == null:
		push_error("自动加载缺失 —— 请确认 --path 指向工程根目录。")
		quit(1)
		return
	locale_mgr.call("set_locale", _locale)
	_data.call("load_all")
	_sim = load("res://scripts/battle/BattleSimulator.gd") as GDScript
	if _sim == null:
		push_error("加载 BattleSimulator 失败。")
		quit(1)
		return
	_filter_enemy_tables()
	_setup_run_state()
	# 特效画质档拉到最高：低 / 中档会砍粒子数量、关掉部分演出（VFXQualityBudget）。
	# 必须在建 BattleScreen 之前设 —— BattleArena 建视口时按它决定 MSAA，
	# 特效模块也是生成那一刻读档位。
	var vfx := root.get_node_or_null("VFXManager")
	if vfx != null:
		vfx.call("set_quality_tier", 2)
		print("  特效画质档：%d（HIGH）" % int(vfx.call("get_quality_tier")))

	var replay := _compute_choreographed_replay()
	if replay.is_empty():
		push_error("编排回放算出来是空的。")
		quit(1)
		return
	_replay_frames = (replay.get("frames", []) as Array).size()
	print("trailer_capture: 编排完成 —— %d 帧模拟（约 %.1f 秒战斗），roster %d 个单位" % [
		_replay_frames, float(_replay_frames) * TICK, (replay.get("roster", {}) as Dictionary).size()])

	# BattleScreen._ready() 看到这个包在等就走「已备好回放」那条路，跳过全部网络码。
	_game_state.call("set_pending_battle_package", {
		"mode": "team_replay",
		"round_index": int(_game_state.get("round_index")),
		"replay": replay,
	})
	_screen = _instantiate(BATTLE_SCREEN_PATH)
	if _screen == null:
		return
	_screen.battle_finished.connect(_on_battle_finished)
	root.add_child(_screen)
	RenderingServer.frame_pre_draw.connect(_on_frame_pre_draw)


# --- 运行状态 ---------------------------------------------------------------

func _setup_run_state() -> void:
	_game_state.call("reset_run")
	# **必须是 true。** BattleScreen.gd:142 的 `if GameState.team_mode:` 门着整条
	# `team_replay` 包的路径；设成 false 会掉进教学实时模拟分支，从空棋盘建战斗，
	# 当场 no_player_units（实测过：编排算出「我方存活 4」，播放却在第 121 帧判负）。
	# 不会等大厅 —— 已备好回放的分支（BattleScreen.gd:144）在任何网络码之前就短路。
	_game_state.set("team_mode", true)
	# PvE 回合。怪的模板是按回合号挑的（_round_pick_index），
	# 固定下来才能保证同 seed 逐帧复现。
	_game_state.set("round_index", 13)
	_game_state.set("pve_completed", 2)
	_game_state.set("boss_completed", 1)
	_game_state.set("owned_treasures", [])
	_network.set("shared_seed", _seed)
	# 组队座位。走已备好回放的分支其实用不到这些，但界面和取景会读
	# team_local_slot（判断自己在红队还是蓝队、要不要翻转画面），留空会读到 -1。
	_network.set("team_active", true)
	_network.set("team_local_slot", 0)
	_network.set("team_slot_states", ["player", "player", "player", "player", "player", "player"])
	seed(_seed)
	# 模拟代码的随机数全走 RngService.rng（元素 25% 触发、套装 20% 爆发、闪避……），
	# 不是全局 randf —— 只调 seed() 定不住它。真实对局在 prepare_team_state 里用
	# seed_from_parts 播种，这里绕过了那条路，得自己播。不播的话同一个 --seed
	# 两次跑出来结果不同（实测一次我方存活 5、一次存活 4），「同 seed 逐帧复现」就不成立。
	var rng_service := root.get_node_or_null("RngService")
	if rng_service != null:
		rng_service.call("seed_from_parts", ["trailer", _seed])


# `--monster` / `--boss` 把共享表过滤成指定的那一只。get_table 返回的是引用，
# 直接改就行；录制进程用完即退，影响不到工程数据。
func _filter_enemy_tables() -> void:
	if not _monster_id.is_empty():
		var t: Dictionary = _data.call("get_table", "pve_monsters")
		var kept: Array = []
		for m: Dictionary in t.get("monsters", []):
			if str(m.get("id", "")) == _monster_id:
				kept.append(m)
		if kept.is_empty():
			push_error("找不到怪物 id '%s'。" % _monster_id)
			quit(1)
			return
		t["monsters"] = kept
	if not _boss_id.is_empty():
		var tb: Dictionary = _data.call("get_table", "bosses")
		var kept_boss: Array = []
		for b: Dictionary in tb.get("bosses", []):
			if str(b.get("id", "")) == _boss_id:
				kept_boss.append(b)
		if kept_boss.is_empty():
			push_error("找不到 Boss id '%s'。" % _boss_id)
			quit(1)
			return
		tb["bosses"] = kept_boss


# --- 编排 ------------------------------------------------------------------

func _compute_choreographed_replay() -> Dictionary:
	var state := _build_opening_state()
	if state.is_empty():
		return {}
	var roster: Dictionary = {}
	var frames: Array = []
	var frame_events: Array = []
	_sim.call("_replay_capture_roster", state, roster)

	var beats := BEATS.duplicate(true)
	beats.sort_custom(func(a, b): return float(a.get("t", 0.0)) < float(b.get("t", 0.0)))
	# 哪些拍子已经放过。用「消耗集合」而不是单个游标：提前补怪只能动怪的拍子，
	# 单游标会把它前面的升星 / 宝藏 / 上单位一起拖早（第一版就把裁决者从
	# t=13 拖到了 t=12，宝藏同理 —— 编排的时间轴等于白写）。
	var consumed: Dictionary = {}
	# 我方阵亡记录（调参用：哪个棋子、第几秒、被谁打死）。升星换下来的旧单位不算。
	var dead_logged: Dictionary = {}
	var stop_after := _last_beat_time() + TAIL_SEC
	var steps := 0
	while not bool(state.get("finished", false)) and steps < MAX_TICKS:
		# 先执行到点的拍子，**再** step_state：顺序反了的话，某一批怪会在
		# 模拟器已经判定「敌方空了、战斗结束」之后才到，长镜当场断掉。
		_fire_due_beats(state, beats, consumed)
		# 猝死（65 秒起每秒全场掉 5% 最大血）会把自家射手一起刮死。
		# 这是 state 上的键，每 tick 往后推就等于在本次录制里关掉它，
		# 不用动 BattleFrenzyService 的常量。狂暴 I/II/III 照常生效。
		state["next_sudden_death_tick"] = float(state.get("elapsed", 0.0)) + 1e9
		_sim.call("step_state", state)
		steps += 1
		_log_player_deaths(state, dead_logged)
		_sim.call("_replay_capture_roster", state, roster)
		_sim.call("_replay_capture_frame", state, frames, frame_events)
		if float(state.get("elapsed", 0.0)) >= stop_after and consumed.size() >= beats.size():
			break
	if steps >= MAX_TICKS:
		push_warning("编排撞到 %d tick 上限。" % MAX_TICKS)
	var result: Dictionary = _sim.call("result_from_state", state)
	print("  编排收束于 t=%.1f：%s（我方存活 %d，敌方存活 %d，未放的拍子 %d）" % [
		float(state.get("elapsed", 0.0)), str(result.get("reason", "?")),
		_alive_players(state), _alive_enemies(state), beats.size() - consumed.size()])
	var survivors: Array = []
	for f: Dictionary in state.get("player", []):
		if bool(f.get("alive", false)):
			survivors.append("%s★%d" % [str(f.get("id", "?")), int(f.get("star", 1))])
	print("  存活：%s" % ", ".join(survivors))
	return _sim.call("_team_replay_payload", state, roster, frames, frame_events)


func _log_player_deaths(state: Dictionary, logged: Dictionary) -> void:
	for f: Dictionary in state.get("player", []):
		var uid := str(f.get("uid", ""))
		if bool(f.get("alive", false)) or logged.has(uid):
			continue
		logged[uid] = true
		# 升星时旧单位被直接置 alive=false、hp=0，那不是阵亡。
		if int(f.get("hp", 0)) == 0 and _is_replaced_uid(uid):
			continue
		print("  阵亡 t=%.1f：%s（%s）" % [float(state.get("elapsed", 0.0)), uid, str(f.get("id", "?"))])


func _is_replaced_uid(uid: String) -> bool:
	for cue: Dictionary in _deploy_cues:
		if uid in (cue.get("old_uids", []) as Array):
			return true
	return false


func _fire_due_beats(state: Dictionary, beats: Array, consumed: Dictionary) -> void:
	var elapsed := float(state.get("elapsed", 0.0))
	for i in beats.size():
		if consumed.has(i):
			continue
		if float((beats[i] as Dictionary).get("t", 0.0)) > elapsed:
			break
		consumed[i] = true
		_apply_beat(state, beats[i] as Dictionary)
	# 清场比编排快时把下一批敌人提前拉进来：既不空场，也不让战斗提前结束。
	# **只找会放敌人的拍子**（怪和 Boss），升星 / 宝藏 / 上棋子一概不动 ——
	# 那些拖早了整条时间轴就白写了。
	#
	# Boss 必须算在内。只认 "monsters" 的那一版里，4 星射手配齐四元素之后清场
	# 比补怪快，怪的拍子放完、场上一空，step_state 当场判定战斗结束，
	# **Boss 那一拍永远轮不到**（实测编排收束在 t=45.0，「未放的拍子 1」就是它）。
	if _alive_enemies(state) > MIN_ALIVE_FLOOR:
		return
	for i in beats.size():
		if consumed.has(i):
			continue
		var op := str((beats[i] as Dictionary).get("op", ""))
		if op != "monsters" and op != "boss":
			continue
		# 下一个敌人是 Boss、但还没到点：**不提前放 Boss**，先补一小批同种小怪撑住场面，
		# 让「升 4 星 → 压轴棋子落地 → Boss 登场」按原时间走。清场快的版本（暗族）原来会把
		# 这三拍挤到同一个 tick，升星石和选卡在画面顶部叠在一起。
		var due := float((beats[i] as Dictionary).get("t", 0.0))
		if op == "boss" and due > float(state.get("elapsed", 0.0)) + 0.5:
			_spawn_monsters(state, maxi(1, int(round(float(FILLER_BATCH) * _count_scale))), SPAWN_Y_FAR)
			return
		# Boss 被提前时，先把排在它前面、还没放的拍子（升 4 星、压轴棋子上场）放完：
		# 压轴的顺序必须是「升 4 星 → 压轴棋子落地 → Boss 登场」。只提 Boss 的话，
		# 清场快的版本会让 Boss 抢在 4 星和黑龙前面出来（暗族版实测 Boss 在 t=40 就登场）。
		if op == "boss":
			for j in i:
				if not consumed.has(j):
					consumed[j] = true
					_apply_beat(state, beats[j] as Dictionary)
		consumed[i] = true
		_apply_beat(state, beats[i] as Dictionary)
		return


func _apply_beat(state: Dictionary, beat: Dictionary) -> void:
	var op := str(beat.get("op", ""))
	match op:
		"growth":
			_game_state.set("pve_completed", int(beat.get("pve_completed", 2)))
		"monster_type":
			_wave_monster_id = str(beat.get("id", ""))
		"monsters":
			_spawn_monsters(state, maxi(1, int(round(float(beat.get("count", 1)) * _count_scale))), float(beat.get("y", SPAWN_Y_NEAR)))
		"boss":
			_spawn_boss(state)
		"star":
			_upgrade_shooters(state, int(beat.get("star", 3)))
		"unit":
			_add_player_unit(state, _resolve_id(str(beat.get("id", ""))), int(beat.get("slot", 0)), int(beat.get("star", 1)))
		"treasure":
			_grant_treasure(state, _resolve_id(str(beat.get("id", ""))))
		_:
			push_warning("未知的编排动作 '%s'" % op)


func _alive_enemies(state: Dictionary) -> int:
	return _alive_count(state, "enemy")


func _alive_players(state: Dictionary) -> int:
	return _alive_count(state, "player")


func _alive_count(state: Dictionary, side: String) -> int:
	var n := 0
	for f: Dictionary in state.get(side, []):
		if bool(f.get("alive", false)):
			n += 1
	return n


# 一批怪。走游戏自己的 `_append_lane_monsters`（成长系数、技能、模型路径全照常），
# 之后只改两样：uid（原函数的 uid 会在批次间撞车）和出生点（挪到远端让它们走进来）。
func _spawn_monsters(state: Dictionary, count: int, y: float) -> void:
	var template := _monster_template()
	if template.is_empty():
		push_warning("本回合取不到怪物模板。")
		return
	var batch: Array = []
	_sim.call("_append_lane_monsters", batch, LANE, count, template)
	var lane_x: float = float((_sim.get("TEAM_LANE_CENTERS") as Array)[LANE])
	for n in batch.size():
		var f: Dictionary = batch[n]
		_scale_enemy(f, _monster_power, _monster_atk_power)
		f.uid = "enemy_L%d_w%d_m%d" % [LANE, _spawn_serial, n]
		# 每排 4 只横向铺开，排与排沿视线方向错开，不是一堵墙。
		var dx := (float(n % 4) - 1.5) * 34.0
		var dy := float(n / 4) * SPAWN_ROW_GAP
		f.pos = Vector2(clampf(lane_x + dx, 60.0, 940.0), clampf(y - dy, 45.0, 475.0))
		state.enemy.append(f)
		# 不登记就是「无归属伤害」：它打出的伤害、它挂的毒全都无人认领
		# （寄生分身踩过这个坑，见 BattleSimulator._maybe_spawn_parasite_clone 的注释）。
		_sim.call("_register_unit_stat", state, f)
	_spawn_serial += 1
	print("  t=%.1f 第 %d 批：%d 只 %s" % [
		float(state.get("elapsed", 0.0)), _spawn_serial, count, str(template.get("name", "?"))])


# 这一波的怪。BEATS 里用 monster_type 指定了就按 id 取，没指定就按回合号挑
# （跟真实对局一样，一回合一种怪）。
func _monster_template() -> Dictionary:
	if not _wave_monster_id.is_empty():
		var t: Dictionary = _data.call("get_table", "pve_monsters")
		for m: Dictionary in t.get("monsters", []):
			if str(m.get("id", "")) == _wave_monster_id:
				return m
		push_warning("找不到怪物 id '%s'，退回按回合挑。" % _wave_monster_id)
	return _sim.call("_round_monster_template", int(_game_state.get("round_index")))


# 按版本表的强度系数缩一只敌人。血量 / 攻击在 fighter 上，技能伤害读 fighter.def
# （_append_lane_monsters 复制过一份 def，改它不影响共享表）。
# 血量和攻击分开缩：「耐打」和「打人疼」是两回事。绑在一个系数上时，Boss 一加强就会
# 打死主角（暗族版 Boss 1.0 打死一个法师、1.5 全灭），只能弱到几秒就死。
# 攻击系数同时管技能伤害 / 溅射 —— 雷怒核心的 overload_counter 是挨 8 下反击一次
# （300 + 180 范围溅射 200），血越厚挨打越多、反击越勤，这部分必须一起压。
func _scale_enemy(f: Dictionary, hp_power: float, atk_power: float) -> void:
	if not is_equal_approx(hp_power, 1.0):
		f.max_hp = maxi(1, int(round(float(f.get("max_hp", 1)) * hp_power)))
		f.hp = int(f.max_hp)
	if not is_equal_approx(atk_power, 1.0):
		f.atk = maxi(1, int(round(float(f.get("atk", 1)) * atk_power)))
		var d: Dictionary = f.get("def", {})
		for key in ["skill_damage", "splash_damage"]:
			if d.has(key):
				d[key] = maxi(1, int(round(float(d[key]) * atk_power)))


func _spawn_boss(state: Dictionary) -> void:
	var template: Dictionary = _sim.call("_round_boss_template", int(_game_state.get("round_index")))
	if template.is_empty():
		push_warning("取不到 Boss 模板。")
		return
	var batch: Array = []
	_sim.call("_append_lane_boss", batch, LANE, template)
	for n in batch.size():
		var f: Dictionary = batch[n]
		_scale_enemy(f, _boss_power, _boss_atk_power)
		f.uid = "enemy_L%d_boss%d" % [LANE, n]
		f.pos = Vector2(f.pos.x, clampf(SPAWN_Y_FAR, 45.0, 475.0))
		state.enemy.append(f)
		_sim.call("_register_unit_stat", state, f)
	print("  t=%.1f Boss 登场：%s" % [float(state.get("elapsed", 0.0)), str(template.get("name", "?"))])


# 升星。`star` 是 **roster 列**（_replay_capture_roster 只在 uid 首次出现时快照一次），
# 所以中途改 fighter.star 画面上的星级不会变 —— 必须换一个新 uid 进场。
# 旧的同帧置 alive=false 撤掉，新的在同一格出现：读起来就是「升级闪一下」。
func _upgrade_shooters(state: Dictionary, star: int) -> void:
	var replaced := 0
	var spawn_pos: Array = []
	var old_uids: Array = []
	var new_uids: Array = []
	for slot in SHOOTER_SLOTS:
		var old := _find_player_by_cell(state, slot)
		var fresh := _make_player_fighter(_shooter_id, slot, star)
		if fresh.is_empty():
			continue
		# 血量按比例带过去：满血复活会让「升级」变成「回血」，战斗压力整条断掉。
		if not old.is_empty():
			var ratio := clampf(float(old.get("hp", 1)) / maxf(1.0, float(old.get("max_hp", 1))), 0.05, 1.0)
			fresh.hp = maxi(1, int(round(float(fresh.max_hp) * ratio)))
			fresh["owner_treasures"] = (old.get("owner_treasures", []) as Array).duplicate()
			old.alive = false
			old.hp = 0
			old_uids.append(str(old.get("uid", "")))
		fresh.uid = "player_L%d_%d_s%d" % [LANE, slot, star]
		state.player.append(fresh)
		_sim.call("_register_unit_stat", state, fresh)
		spawn_pos.append(fresh.pos)
		new_uids.append(str(fresh.uid))
		replaced += 1
	# 1→2、2→3 走选卡（点一张射手卡 = 买到第三张合成）；4 星没有卡，走升星石。
	var kind := "four" if star >= GameConstants.MAX_STAR else "star"
	_record_deploy(state, kind, _shooter_id, spawn_pos, old_uids, new_uids, star)
	print("  t=%.1f 射手升到 %d 星（换了 %d 个）" % [float(state.get("elapsed", 0.0)), star, replaced])


func _add_player_unit(state: Dictionary, unit_id: String, slot: int, star: int) -> void:
	var f := _make_player_fighter(unit_id, slot, star)
	if f.is_empty():
		return
	f.uid = "player_L%d_%d" % [LANE, slot]
	state.player.append(f)
	_sim.call("_register_unit_stat", state, f)
	_record_deploy(state, "spawn", unit_id, [f.pos], [], [f.uid], star)
	print("  t=%.1f %s 上场（%d 星）" % [float(state.get("elapsed", 0.0)), unit_id, star])


# 记一条部署 / 升星演出。回放是先整场算好再播的，所以演出只能事后「对帧」：
# 这里记下单位出现的那一帧（与宝藏提示同一个坐标系，见 _grant_treasure），
# 播放时提前若干帧把卡牌、点击、召唤法阵摆出来，让揭示正好压在这一帧上。
# 同一帧、同一种的部署并成一组（两个卫士 = 一组卡里点两张）。
func _record_deploy(state: Dictionary, kind: String, card_id: String, spawn_pos: Array,
		old_uids: Array, new_uids: Array, star: int) -> void:
	var tick := int(round(float(state.get("elapsed", 0.0)) / TICK))
	for cue: Dictionary in _deploy_cues:
		if int(cue["tick"]) == tick and str(cue["kind"]) == kind:
			(cue["picks"] as Array).append(card_id)
			(cue["spawn_pos"] as Array).append_array(spawn_pos)
			(cue["old_uids"] as Array).append_array(old_uids)
			(cue["new_uids"] as Array).append_array(new_uids)
			return
	_deploy_cues.append({
		"tick": tick, "kind": kind, "star": star,
		"picks": [card_id], "spawn_pos": spawn_pos.duplicate(),
		"old_uids": old_uids.duplicate(), "new_uids": new_uids.duplicate(),
	})


func _unit_defs() -> Dictionary:
	if not _defs_cache.is_empty():
		return _defs_cache
	var table: Dictionary = _data.call("get_table", "race_units")
	for entry in table.get("units", []):
		if typeof(entry) == TYPE_DICTIONARY:
			_defs_cache[str((entry as Dictionary).get("id", ""))] = entry
	return _defs_cache


func _make_player_fighter(unit_id: String, slot: int, star: int) -> Dictionary:
	var defs := _unit_defs()
	if not defs.has(unit_id):
		push_warning("找不到单位 id '%s'。" % unit_id)
		return {}
	var cell := {
		"id": unit_id,
		"star": star,
		"def": (defs[unit_id] as Dictionary).duplicate(true),
	}
	# 走 `_fighter_from_cell` 而不是自己缩放属性：四星的 `star4` 技能覆写
	# （heal_pct / stun_sec / double_element_chance ...）是 UnitFactory.apply_star_stats
	# 摊平进 def 的，自己抄 hp/atk/def 三个字段就会让四星的技能数值停在三星。
	var f: Dictionary = _sim.call("_fighter_from_cell", cell, slot, "player", false, 0.0)
	_sim.call("_place_in_lane", f, slot, "player", LANE, false)
	f["owner_slot"] = 0
	f["owner_syn"] = {}
	# 新上场 / 升星后的单位也要享受已经吃到的宝藏，
	# 否则它会是场上唯一不触发元素的人。
	f["owner_treasures"] = (_game_state.get("owned_treasures") as Array).duplicate()
	return f


func _find_player_by_cell(state: Dictionary, slot: int) -> Dictionary:
	for f: Dictionary in state.get("player", []):
		if int(f.get("board_cell", -1)) == slot and bool(f.get("alive", false)):
			return f
	return {}


# 宝藏。`_f_treasures(f)` 先读 fighter 身上的 `owner_treasures`
# （BattleSimShared.gd:188），所以把 id 塞进自家单位的这个数组，
# 元素触发和 element 套装当场生效 —— 不需要重开一场。
func _grant_treasure(state: Dictionary, tid: String) -> void:
	if tid.is_empty():
		return
	var owned: Array = _game_state.get("owned_treasures")
	if tid in owned:
		return
	owned.append(tid)
	_game_state.set("owned_treasures", owned)
	for f: Dictionary in state.get("player", []):
		f["owner_treasures"] = owned.duplicate()
	_deploy_cues.append({
		"tick": int(round(float(state.get("elapsed", 0.0)) / TICK)), "kind": "treasure",
		"star": 0, "picks": [tid], "spawn_pos": [], "old_uids": [], "new_uids": [],
	})
	_treasure_cues.append({
		"id": tid,
		"tick": int(round(float(state.get("elapsed", 0.0)) / TICK)),
		"set_complete": owned.size() >= 4,
	})
	print("  t=%.1f 获得宝藏 %s（已收集 %d/4）" % [
		float(state.get("elapsed", 0.0)), str(_treasures.get(tid, tid)), owned.size()])


# 开场：两个 1 星极光射手在中路后排，第一批怪由编排表的 t=0 拍子放。
func _build_opening_state() -> Dictionary:
	var player: Array = []
	for slot in SHOOTER_SLOTS:
		var f := _make_player_fighter(_shooter_id, slot, 1)
		if f.is_empty():
			continue
		f.uid = "player_L%d_%d_s1" % [LANE, slot]
		player.append(f)
	if player.is_empty():
		push_error("开场射手一个都没建出来。")
		quit(1)
		return {}
	var frenzy: GDScript = load("res://scripts/battle/BattleFrenzyService.gd")
	var state := {
		"kind": "pve", "player": player, "enemy": [], "elapsed": 0.0,
		"next_sudden_death_tick": float(frenzy.get("SUDDEN_DEATH_SEC")),
		"finished": false, "log": ([] as Array[String]),
		"player_syn": {}, "enemy_syn": {},
		"enemy_deaths": 0, "total_deaths": 0, "field_death_count": 0,
		"mother_death_counter": 0, "dark_kill_stacks": 0,
		"race_trait_processed_deaths": {}, "revive_queue": [],
		"player_kill_gold": 0, "enemy_kill_gold": 0, "kill_gold_by_slot": {},
		"player_kills": [], "enemy_kills": [], "bonus_gold": 0,
		"temporary_deaths": [], "visual_events": [], "unit_stats": {},
	}
	state["_presentation_battle_id"] = "trailer:%d" % _seed
	_sim.call("_init_unit_stats", state)
	load("res://scripts/battle/DamageService.gd").call("set_stat_state", state)
	return state


# --- 录制 ------------------------------------------------------------------

func _instantiate(path: String) -> Node:
	var packed := load(path) as PackedScene
	if packed == null:
		push_error("加载 %s 失败" % path)
		quit(1)
		return null
	return packed.instantiate()


func _process(_delta: float) -> bool:
	_frame += 1
	if not _setup_done:
		_setup_done = true
		_setup()
		return false
	if _screen == null or not is_instance_valid(_screen):
		return true
	_apply_render_quality()
	if _start_frame < 0:
		# --write-movie 下每帧编码约 0.34 秒，模型还在分帧加载，
		# BattleScreen 的 30 秒**墙钟**就先到了，第 ~94 帧直接 battle_finished。
		# 这是录影片拍不出战斗的唯一原因。deadline 是实例变量
		# （BattleScreen.gd:617 自己就在改它），每帧往后推就绕过去了 —— 不动游戏代码。
		_screen.set("_battle_prepare_deadline_msec", Time.get_ticks_msec() + 600000)
	if _start_frame < 0 and bool(_screen.get("_battle_setup_ready")):
		_start_frame = _frame
		_start_unix_msec = int(round(Time.get_unix_time_from_system() * 1000.0))
		_apply_camera_framing()
		_record_viewport_size()
		if not _hud:
			_strip_hud()
		_build_treasure_bar()
		print("  战斗从第 %d 帧开始（3D 视口 %dx%d）" % [_start_frame, _viewport_size.x, _viewport_size.y])
		# 现在就写一份：--quit-after 会直接杀进程、不跑完 _process，
		# 撞上限的录制否则连 manifest 都没有，编码器就会把加载前导留在片子里。
		_write_manifest()
	if _start_frame >= 0:
		_apply_camera_framing()
		if not _hud:
			_hide_unit_overlays()
		_update_treasure_bar()
		_update_deploys()
	if _finished_frame >= 0 and _frame >= _finished_frame + TAIL_FRAMES:
		_write_manifest()
		return true
	if _frame >= total_frames():
		_write_manifest()
		return true
	return false


func _on_battle_finished(result: Dictionary) -> void:
	_finished_frame = _frame
	_finished_unix_msec = int(round(Time.get_unix_time_from_system() * 1000.0))
	print("  战斗在第 %d 帧结束：%s" % [_frame, str(result.get("reason", "?"))])


# HUD 全关：只留纯 3D 战斗画面。
# 判据是「除了装 3D 视口的那个顶层容器，其余顶层 CanvasItem 全隐」，不逐个点名节点 ——
# 名字会随界面改动漂移，这条判据不会。血条、单位名、Skip 按钮、Top ATK 排行
# 都在那些 2D 层里，一起没掉。
func _strip_hud() -> void:
	var viewport := _screen.get("_battle_3d_viewport") as SubViewport
	if viewport == null:
		push_warning("取不到 3D 视口，HUD 保留原样。")
		return
	var keep: Node = viewport
	while keep != null and keep.get_parent() != _screen:
		keep = keep.get_parent()
	if keep == null:
		push_warning("找不到装 3D 视口的顶层容器，HUD 保留原样。")
		return
	var hidden := 0
	for child in _screen.get_children():
		if child == keep:
			continue
		if child is CanvasItem:
			(child as CanvasItem).visible = false
			hidden += 1
	print("  HUD 已关闭（隐藏 %d 个顶层节点，保留 %s）" % [hidden, keep.name])


# 每个单位头上那层 2D 覆盖（名字、血条、脚下的队伍圈）。
# 它们挂在 `_unit_nodes` 里、位于 3D 视口容器**内部**，所以 _strip_hud()
# 那条「隐藏顶层 CanvasItem」的判据够不着（实测第一版录出来血条和灰圈还在）。
# 必须每帧扫：单位是中途进场的，新建的节点默认可见。
func _hide_unit_overlays() -> void:
	# 单位头顶那层只有三个子节点：HpBg / HpFill / Name（BattleRenderer._make_unit_node）。
	# **血条留着**（用户要），只摘掉名字 —— 整片 61 个单位的名字叠在一起是噪音，
	# 血条则是看得出谁快死了的战斗读感。
	var nodes: Dictionary = _screen.get("_unit_nodes")
	if nodes != null:
		for key in nodes:
			var node := nodes[key] as Node
			if node == null or not is_instance_valid(node):
				continue
			var name_lbl := node.get_node_or_null("Name") as CanvasItem
			if name_lbl != null and name_lbl.visible:
				name_lbl.visible = false
	# 棋盘可读性层：中线和「我方半场 / 敌方半场」两行字。
	# **不能用 visible 关**：BattleArena._sync_battle_readability_static_geometry()
	# 每帧（经 _refresh_visuals）把 visible 无条件写回 true（BattleArena.gd:651），
	# 跟它抢这个属性谁后执行谁赢，实测就是字一直在。改用 modulate —— 那个函数不碰它。
	var readability := _screen.get("_board_readability_layer") as CanvasItem
	if readability != null and is_instance_valid(readability) and readability.modulate.a > 0.0:
		readability.modulate.a = 0.0
	# 脚下那圈队伍色光环。它是单位 3D 枢轴下名为 "TeamGlow3D" 的 MeshInstance3D
	# （BattleRenderer._add_3d_unit_readability），活在 3D 场景里，
	# 不是 Control，所以前面两条判据都够不着。地面投影（GroundShadow3D）留着 ——
	# 那是光影，不是 UI，拿掉单位会像浮在草上。
	var models: Dictionary = _screen.get("_battle_3d_models")
	if models != null:
		for key in models:
			var pivot := models[key] as Node3D
			if pivot == null or not is_instance_valid(pivot):
				continue
			var glow := pivot.get_node_or_null("TeamGlow3D") as Node3D
			if glow != null and glow.visible:
				glow.visible = false


# 覆盖层：盖在战斗画面之上。备战界面的联动特效用 200 层，这里取更高的，
# 确保录制时没有任何东西压在它上面。宝藏条、部署卡牌、星级字、全屏 4 星特效都挂这里。
func _ensure_overlay() -> Control:
	if _overlay_root != null and is_instance_valid(_overlay_root):
		return _overlay_root
	_logo_layer = CanvasLayer.new()
	_logo_layer.layer = 400
	root.add_child(_logo_layer)
	_overlay_root = Control.new()
	_overlay_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_logo_layer.add_child(_overlay_root)
	return _overlay_root


# --- 部署 / 升星演出 ---------------------------------------------------------
#
# 三种：
#   spawn —— 顶部中间落下 3 张商店卡（石框，没有卷轴底），点中要上场的那张，
#            另外两张退场，选中的飞向落点；落点起决赛圈那套召唤法阵
#            （VFXSummonSpawn3D），揭示闪光压在单位出现的那一帧 —— 不凭空出现。
#   star   —— 同一套选卡，点的是射手卡（= 买到第三张合成）；落地那一帧两个射手
#            身上放备战升星迸发（PrepStarUpgradeBurst），头顶飘「2星 / 3星」。
#   four   —— 不走卡牌：顶部中间的升星石亮起、炸开（石头揭示序列帧），
#            接备战升 4 星的全屏特效（PrepFourStarScreenFx）飞向射手，
#            落到的那一帧光环 play_upgrade() 爆发，头顶飘「4星」。
#
# 全是表现：不读、不改任何战斗数值。所有素材和特效都是游戏里现成的那几个，
# 观感跟玩家在备战界面看到的一致。

const CARD_FRAME_PATHS := {
	1: "res://assets/ui/shop/card_frame_common.png",
	2: "res://assets/ui/shop/card_frame_rare.png",
	3: "res://assets/ui/shop/card_frame_epic.png",
}
const UNIT_PORTRAIT_DIR := "res://assets/ui/unit_portraits/"
const PRICE_FONT_PATH := "res://assets/fonts/Knewave-Regular.ttf"
const SUMMON_FX_PATH := "res://effects/vfx3d/modules/VFXSummonSpawn3D.gd"
const SUMMON_PROFILE_PATH := "res://effects/vfx3d/profiles/formation/summon_formation_red.tres"
const STAR_BURST_PATH := "res://scenes/prep/effects/PrepStarUpgradeBurst.gd"
const FOUR_STAR_SCREEN_FX_PATH := "res://scenes/prep/effects/PrepFourStarScreenFx.gd"
const FOUR_STAR_AURA_PATH := "res://effects/vfx3d/modules/FourStarAuraV3_3D.gd"
const STONE_PATH := "res://assets/props/carrot_system/stones/stone_%s.png"
const STONE_REVEAL_ATLAS := "res://assets/props/carrot_system/vfx/atlas_stone_reveal_4x4.png"

# 时间轴：回放 tick，相对「单位出现那一帧」，1 tick = 0.1 秒。
const CARD_DROP_AT := -26      # 三张卡从画面上方落下
const CARD_DROP_TICKS := 4
const CARD_STAGGER := 1        # 三张错开一 tick 落，不是一块板砸下来
const CARD_CLICK_AT := -18     # 点中第一张
const CARD_CLICK_GAP := 3      # 一组里要点两张时（两个卫士），第二下隔多久
const CARD_DISMISS_TICKS := 3
const CARD_FLY_AT := -12       # 选中的卡飞向落点
const CARD_FLY_TICKS := 6
const RIPPLE_TICKS := 5
const STONE_IN_AT := -20       # 升星石出现
const STONE_BURST_AT := -9     # 升星石炸开
const STONE_BURST_TICKS := 6
const CAPTION_TICKS := 18      # 头顶星级字停留
# 卡牌边长 = 画面高度的这个比例。1080 高时约 210px，和备战商店卡（180px @720）同一观感。
const CARD_HEIGHT_RATIO := 0.195


class ClickRipple extends Control:
	var progress := 0.0
	var tint := Color(1.0, 0.88, 0.45)

	func _draw() -> void:
		var r := minf(size.x, size.y) * 0.5
		var a := clampf(1.0 - progress, 0.0, 1.0)
		var ring := tint
		ring.a = a
		draw_arc(size * 0.5, r * (0.25 + 0.95 * progress), 0.0, TAU, 64, ring, maxf(2.0, r * 0.12 * a), true)
		var core := tint
		core.a = a * 0.4
		draw_circle(size * 0.5, r * 0.28 * (1.0 - progress), core)


# 覆盖层元素的尺寸基准：画面短边。按高算的话竖版（1080x1920）三张卡会撑出画面宽度。
func _ui_unit() -> float:
	var c := _canvas_size()
	return minf(c.x, c.y)


# 3D 视口的抗锯齿和超采样。视口是 BattleScreen._ready 里建的，所以等它出现了再设，
# 而且要赶在特效预热之前（预热按当前 MSAA 档编译管线，之后再改会让第一次出招卡一下）。
# 预热要等模型分帧建完才开始，比视口出现晚好几帧，所以第一帧拿到就设是来得及的。
func _apply_render_quality() -> void:
	if _quality_applied or _screen == null or not is_instance_valid(_screen):
		return
	var vp := _screen.get("_battle_3d_viewport") as SubViewport
	if vp == null:
		return
	if _realtime:
		# 实时录制沿用游戏 HIGH 档的视口设置；离线超采样会压低实际帧率。
		_quality_applied = true
		print("  3D 画质：游戏 HIGH 档，MSAA 2x，内部渲染 1.0 倍")
		return
	var msaa_by_count := {2: Viewport.MSAA_2X, 4: Viewport.MSAA_4X, 8: Viewport.MSAA_8X}
	vp.msaa_3d = msaa_by_count.get(_msaa, Viewport.MSAA_8X)
	if _ssaa > 1.0:
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		vp.scaling_3d_scale = _ssaa
	# 远处模型不降 LOD：录片子不缺这点性能。
	vp.mesh_lod_threshold = 0.0
	_quality_applied = true
	print("  3D 画质：MSAA %dx，内部渲染 %.1f 倍" % [_msaa, _ssaa])


# --- 单位位置插值 -------------------------------------------------------------
#
# 战斗每 0.1 秒算一次位置，渲染层（BattleRenderer._position_3d_model_node /
# _position_unit_node）每帧把模型和头顶血条**直接**写到当前 tick 的位置，没有插值。
# 60fps 的片子里就是连续 6 帧不动、再一下跳过去 —— 用户看成片说「一顿一顿、不流畅」。
#
# 这里在 frame_pre_draw（所有逻辑跑完、还没画）里把模型从上一 tick 的目标平滑滑向
# 当前 tick 的目标。每个 tick 都更新两个端点，即使单位没动；停住后两端相同，
# 累加器归零也不会重播上一次移动。血条直接投影到平滑后模型的位置，
# 避免 2D 血条与 3D 模型各自插值时被每帧的相机变化拉得上下晃动。
# 代价是显示比战斗计算晚一个 tick（0.1 秒）；攻击特效挂在模型的锚点上跟着模型走。
# 只动表现层节点的位置，不碰 _state、不碰战斗。
const INTERP_SNAP_3D := 3.0     # 世界单位：超过就是瞬移 / 换位，直接跳过去不滑
const TRAILER_HUD_OFFSET := Vector2(41, 66) # 与 BattleUI.UNIT_VISUAL_OFFSET 一致


func _on_frame_pre_draw() -> void:
	if not _smooth or _start_frame < 0 or _screen == null or not is_instance_valid(_screen):
		return
	var acc = _screen.get("_sim_accumulator")
	var frac := clampf(float(acc) / TICK, 0.0, 1.0) if acc != null else 1.0
	var tick := int(_screen.get("_replay_frame"))
	var seen := {}
	var models: Dictionary = _screen.get("_battle_3d_models")
	if models != null:
		for key in models:
			var node = models[key]
			if node != null and is_instance_valid(node) and node is Node3D:
				_interp_node(node, tick, frac, INTERP_SNAP_3D, seen)
	var huds: Dictionary = _screen.get("_unit_nodes")
	if huds != null:
		for key in huds:
			var node = huds[key]
			var model = models.get(key) if models != null else null
			if node != null and is_instance_valid(node) and node is Control \
					and model != null and is_instance_valid(model) and model is Node3D:
				var mapped: Vector2 = _screen.call("_world_to_arena", model.global_position)
				node.position = mapped - TRAILER_HUD_OFFSET
				node.z_index = int(round(mapped.y))
	for id in _interp.keys():
		if not seen.has(id):
			_interp.erase(id)


func _interp_node(node: Object, tick: int, frac: float, snap: float, seen: Dictionary) -> void:
	var id := node.get_instance_id()
	seen[id] = true
	var cur = node.get("position")
	var st: Dictionary = _interp.get(id, {})
	if st.is_empty():
		_interp[id] = {"prev": cur, "target": cur, "shown": cur, "tick": tick, "frac": frac}
		return
	# 用回放 tick 判断时间前进，不能用“目标位置变了”判断；静止单位也会进入新 tick。
	if tick != int(st["tick"]):
		var from = st["target"]
		st["prev"] = cur if tick < int(st["tick"]) or (cur - from).length() > snap else from
		st["target"] = cur
		st["tick"] = tick
		st["frac"] = frac
	else:
		# 恢复窗口时游戏可能清空累加器；同一 tick 内不允许显示进度倒退。
		st["frac"] = maxf(float(st["frac"]), frac)
	var from_pos = st["prev"]
	var alpha := float(st["frac"])
	var shown = from_pos.lerp(st["target"], alpha)
	st["shown"] = shown
	node.set("position", shown)


# 回放游标，**带小数**。_replay_frame 每 0.1 秒才跳一格；覆盖层动画要是按它走，
# 在 60fps 的片子里就是每 6 帧才动一下、一顿一顿的（用户看成片说「速度很奇怪」）。
# 加上 BattleScreen 自己的帧内累加器（_sim_accumulator，满 SIM_TICK_SEC 才推进一格），
# 卡牌落下 / 飞走、星级字、logo 弹出就跟着每一帧连续走，和单位出现的那一帧仍然对齐。
func _replay_cursor() -> float:
	var f := float(int(_screen.get("_replay_frame")))
	var acc = _screen.get("_sim_accumulator")
	if acc != null:
		f += clampf(float(acc) / TICK, 0.0, 0.999)
	return f


func _canvas_size() -> Vector2:
	if _overlay_root != null and _overlay_root.size.x > 1.0:
		return _overlay_root.size
	return root.get_visible_rect().size


# 3D 世界坐标 → 覆盖层坐标。战斗画在 SubViewport 里、被容器拉伸铺开，
# 所以要先投到视口像素，再按容器矩形换算 —— 直接用 unproject 的结果会偏。
func _world_to_canvas(world: Vector3) -> Vector2:
	var cam := _screen.get("_battle_3d_camera") as Camera3D
	var vp := _screen.get("_battle_3d_viewport") as SubViewport
	if cam == null or vp == null:
		return _canvas_size() * 0.5
	var px := cam.unproject_position(world)
	var container := vp.get_parent() as Control
	if container == null or vp.size.x <= 0:
		return px
	var rect := _screen_rect(container)
	return rect.position + px * (rect.size / Vector2(vp.size))


func _sim_to_world(sim_pos: Vector2) -> Vector3:
	return _screen.call("_sim_to_world_pos", sim_pos)


func _model_for(uid: String) -> Node3D:
	var models: Dictionary = _screen.get("_battle_3d_models")
	if models == null:
		return null
	# 先判有效再转型：对已释放的实例做 `as` 会直接报错，而死亡淡出的模型正是这种。
	var node = models.get(uid)
	if node == null or not is_instance_valid(node) or not (node is Node3D):
		return null
	return node


func _update_deploys() -> void:
	if _deploy_cues.is_empty():
		return
	var cursor := _replay_cursor()
	for i in _deploy_cues.size():
		var cue: Dictionary = _deploy_cues[i]
		if bool(cue.get("done", false)):
			continue
		var rel := cursor - float(int(cue["tick"]))
		if rel < mini(CARD_DROP_AT, STONE_IN_AT):
			continue
		match str(cue["kind"]):
			"spawn", "star", "treasure":
				_update_card_offer(cue, i, rel)
			"four":
				_update_stone(cue, rel)
		_update_landing(cue, rel)


# --- 选卡 ---

func _update_card_offer(cue: Dictionary, cue_index: int, rel: float) -> void:
	if not cue.has("cards"):
		_build_card_offer(cue, cue_index)
	var cards: Array = cue["cards"]
	var picks: Array = cue["picks"]
	var last_click := CARD_CLICK_AT + (picks.size() - 1) * CARD_CLICK_GAP
	for c: Dictionary in cards:
		var node := c["node"] as Control
		if node == null or not is_instance_valid(node):
			continue
		var base: Vector2 = c["base"]
		var drop_start := CARD_DROP_AT + int(c["slot"]) * CARD_STAGGER
		var p := clampf(float(rel - drop_start) / float(CARD_DROP_TICKS), 0.0, 1.0)
		node.visible = rel >= drop_start
		# 落下：从画面上方进来，略过冲再落定（back-out）。
		var eased := 1.0 + 2.7 * pow(p - 1.0, 3.0) + 1.7 * pow(p - 1.0, 2.0)
		var pos := Vector2(base.x, lerpf(-node.size.y * 1.2, base.y, eased))
		var scale_now := 1.0
		var alpha := 1.0
		var pick_index := int(c["pick"])
		if pick_index < 0:
			# 落选：最后一下点完之后往上收、淡出。
			var d := clampf(float(rel - last_click - 1) / float(CARD_DISMISS_TICKS), 0.0, 1.0)
			pos.y -= d * node.size.y * 0.35
			alpha = 1.0 - d
			scale_now = 1.0 - 0.15 * d
			node.modulate = Color(1, 1, 1, alpha) if d > 0.0 else Color(0.82, 0.82, 0.86, 1.0) if rel >= CARD_CLICK_AT else Color.WHITE
		else:
			var click_at := CARD_CLICK_AT + pick_index * CARD_CLICK_GAP
			var since_click := rel - click_at
			if since_click >= 0:
				# 按下 → 回弹：0~1 tick 压到 0.9，再弹到 1.06 落回 1.0。
				if since_click <= 1:
					scale_now = 0.9
				elif since_click <= 3:
					scale_now = 1.06
				node.modulate = Color(1.35, 1.28, 1.05, 1.0)
				_ensure_ripple(c, node)
				var ripple := c.get("ripple") as ClickRipple
				if ripple != null and is_instance_valid(ripple):
					ripple.progress = clampf(float(since_click) / float(RIPPLE_TICKS), 0.0, 1.0)
					ripple.visible = ripple.progress < 1.0
					ripple.queue_redraw()
			# 飞向战场：缩小、淡出，终点是落点在画面上的位置。
			var fly_at := CARD_FLY_AT + pick_index * CARD_CLICK_GAP
			var f := clampf(float(rel - fly_at) / float(CARD_FLY_TICKS), 0.0, 1.0)
			if f > 0.0:
				var target: Vector2 = _card_target(cue, c) - node.size * 0.5
				var ef := f * f
				pos = pos.lerp(target, ef)
				scale_now = lerpf(1.0, float(c.get("end_scale", 0.22)), ef)
				alpha = 1.0 - clampf((f - 0.6) / 0.4, 0.0, 1.0)
				node.modulate.a = alpha
		node.position = pos
		node.scale = Vector2(scale_now, scale_now)
	if rel > CARD_FLY_AT + (picks.size() - 1) * CARD_CLICK_GAP + CARD_FLY_TICKS + 1:
		for c: Dictionary in cards:
			var n := c["node"] as Control
			if n != null and is_instance_valid(n):
				n.queue_free()
		cue["cards"] = []


func _build_card_offer(cue: Dictionary, cue_index: int) -> void:
	var overlay := _ensure_overlay()
	var canvas := _canvas_size()
	if str(cue["kind"]) == "treasure":
		_build_treasure_offer(cue, cue_index)
		return
	var side := _ui_unit() * CARD_HEIGHT_RATIO
	var gap := side * 0.12
	var picks: Array = cue["picks"]
	# 三个位置：一张要点 → 放中间；两张要点 → 放两边，中间一张陪衬。
	var layout: Array = ["", "", ""]
	if picks.size() >= 2:
		layout = [picks[0], "", picks[1]]
	else:
		layout = ["", picks[0], ""]
	var decoys: Array = []
	for d in _card_decoys:
		if not (d in picks):
			decoys.append(d)
	var decoy_i := cue_index
	var total_w := side * 3.0 + gap * 2.0
	var x0 := (canvas.x - total_w) * 0.5
	var y0 := canvas.y * 0.03
	var target := _landing_canvas_pos(cue)
	var cards: Array = []
	var pick_counter := 0
	for slot in 3:
		var unit_id := str(layout[slot])
		var pick := -1
		if unit_id.is_empty():
			unit_id = str(decoys[decoy_i % decoys.size()])
			decoy_i += 1
		else:
			pick = pick_counter
			pick_counter += 1
		var card := _make_card(unit_id, side)
		card.visible = false
		overlay.add_child(card)
		cards.append({
			"node": card, "slot": slot, "pick": pick,
			"base": Vector2(x0 + float(slot) * (side + gap), y0),
			"target": target,
		})
	cue["cards"] = cards


# 宝藏三选一：跟备战抽宝藏时弹的是同一套卡图（assets/ui/treasure_cards/<名字>[_en].png，
# 整张石框卡、3:4）。点中元素宝藏，另两张退场，选中的飞到底部宝藏条它自己那一格，
# 缩成 logo 落位 —— 落位那一帧正好是 _update_treasure_bar 把 logo 弹出来的那一帧。
# 陪衬卡挑非元素宝藏，免得观众以为四元素是随便哪张都行。
const TREASURE_CARD_DIR := "res://assets/ui/treasure_cards/"
const TREASURE_CARD_HEIGHT_RATIO := 0.30


func _build_treasure_offer(cue: Dictionary, cue_index: int) -> void:
	var overlay := _ensure_overlay()
	var canvas := _canvas_size()
	var h := _ui_unit() * TREASURE_CARD_HEIGHT_RATIO
	var w := h * 0.75
	var gap := w * 0.12
	var pick := str((cue["picks"] as Array)[0])
	var layout: Array = [
		_treasure_decoys[cue_index % _treasure_decoys.size()],
		pick,
		_treasure_decoys[(cue_index + 2) % _treasure_decoys.size()],
	]
	var total_w := w * 3.0 + gap * 2.0
	var x0 := (canvas.x - total_w) * 0.5
	var y0 := canvas.y * 0.03
	var logo_px := _ui_unit() * LOGO_RATIO
	var cards: Array = []
	for slot in 3:
		var tid := str(layout[slot])
		var card := TextureRect.new()
		card.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var tname := _treasure_name(tid)
		var tex := load(TREASURE_CARD_DIR + tname + ("_en" if _locale == "en" else "") + ".png") as Texture2D
		if tex == null:
			tex = load(TREASURE_CARD_DIR + tname + ".png") as Texture2D
		card.texture = tex
		card.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		card.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		card.size = Vector2(w, h)
		card.pivot_offset = card.size * 0.5
		card.visible = false
		overlay.add_child(card)
		cards.append({
			"node": card, "slot": slot, "pick": 0 if slot == 1 else -1,
			"base": Vector2(x0 + float(slot) * (w + gap), y0),
			"target": canvas * Vector2(0.5, 0.92),
			# 落位时缩到和底部 logo 一样大。
			"end_scale": logo_px / h,
		})
	cue["cards"] = cards


func _treasure_name(tid: String) -> String:
	if _treasures.has(tid):
		return str(_treasures[tid])
	var table: Dictionary = _data.call("get_table", "treasures")
	for t: Dictionary in table.get("treasures", []):
		if str(t.get("id", "")) == tid:
			return str(t.get("name", tid))
	return tid


# 卡飞向哪。宝藏卡的落点是底部那排里它自己的 logo —— 那排是 HBox 自动居中的，
# 多一个就整排挪，所以飞行途中每帧重新取：先把 logo 设成「可见但全透明」让它占位，
# 布局算好之后读它的矩形中心。其余卡用建卡时算好的固定落点。
func _card_target(cue: Dictionary, c: Dictionary) -> Vector2:
	if str(cue["kind"]) != "treasure":
		return c["target"]
	var tid := str((cue["picks"] as Array)[0])
	var logo = _logo_nodes.get(tid)
	if logo == null or not is_instance_valid(logo):
		return c["target"]
	var node := logo as Control
	if not node.visible:
		node.visible = true
		node.modulate.a = 0.0
		return c["target"]
	var r := _screen_rect(node)
	return r.position + r.size * 0.5


# 选中的卡飞去哪：落点的平均位置（两个射手 = 两人中间；两个卫士各飞各的会更乱，
# 并成一个点读起来反而清楚）。
func _landing_canvas_pos(cue: Dictionary) -> Vector2:
	var pts: Array = cue["spawn_pos"]
	if pts.is_empty():
		return _canvas_size() * 0.5
	var sum := Vector2.ZERO
	for p in pts:
		sum += _world_to_canvas(_sim_to_world(p))
	return sum / float(pts.size())


func _ensure_ripple(c: Dictionary, card: Control) -> void:
	if c.has("ripple"):
		return
	var ripple := ClickRipple.new()
	ripple.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ripple.size = card.size * 1.3
	ripple.position = -card.size * 0.15
	card.add_child(ripple)
	c["ripple"] = ripple


# 一张商店卡：头像 + 稀有度石框 + 金币价格 + 名字铭牌，层次和尺寸比例照
# scenes/prep/panels/ShopPanel.gd 的手牌卡（头像先加、框盖在上面遮毛边）。
func _make_card(unit_id: String, side: float) -> Control:
	var def: Dictionary = _unit_defs().get(unit_id, {})
	var card := Control.new()
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.size = Vector2(side, side)
	card.pivot_offset = card.size * 0.5

	var portrait := TextureRect.new()
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	portrait.texture = load(UNIT_PORTRAIT_DIR + unit_id + ".png") as Texture2D
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_anchor(portrait, 0.09, 0.07, 0.91, 0.80)
	card.add_child(portrait)

	var frame := TextureRect.new()
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tier := clampi(int(def.get("tier", 1)), 1, 3)
	frame.texture = load(str(CARD_FRAME_PATHS[tier])) as Texture2D
	frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	frame.stretch_mode = TextureRect.STRETCH_SCALE
	_anchor(frame, 0.0, 0.0, 1.0, 1.0)
	card.add_child(frame)

	# 价格写在框自带的金币圆牌上：深棕字、不描边（同 ShopPanel）。
	var price := Label.new()
	price.mouse_filter = Control.MOUSE_FILTER_IGNORE
	price.text = str(int(def.get("cost", 0)))
	price.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	price.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var price_font := load(PRICE_FONT_PATH) as Font
	if price_font != null:
		price.add_theme_font_override("font", price_font)
	price.add_theme_font_size_override("font_size", int(side * 0.12))
	price.add_theme_color_override("font_color", Color(0.28, 0.16, 0.02))
	_anchor(price, 0.75, 0.02, 0.98, 0.23)
	card.add_child(price)

	var name_lbl := Label.new()
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_lbl.text = str(def.get("name_en" if _locale == "en" else "name", unit_id))
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", int(side * 0.085))
	name_lbl.add_theme_color_override("font_color", Color(0.96, 0.94, 0.88))
	name_lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	name_lbl.add_theme_constant_override("outline_size", maxi(2, int(side * 0.018)))
	_anchor(name_lbl, 0.22, 0.79, 0.78, 0.93)
	card.add_child(name_lbl)
	return card


func _anchor(c: Control, l: float, t: float, r: float, b: float) -> void:
	c.anchor_left = l
	c.anchor_top = t
	c.anchor_right = r
	c.anchor_bottom = b
	c.offset_left = 0.0
	c.offset_top = 0.0
	c.offset_right = 0.0
	c.offset_bottom = 0.0


# --- 升星石（4 星） ---

func _update_stone(cue: Dictionary, rel: float) -> void:
	if rel < STONE_IN_AT:
		return
	var canvas := _canvas_size()
	var side := _ui_unit() * 0.17
	if not cue.has("stone"):
		var stone := TextureRect.new()
		stone.mouse_filter = Control.MOUSE_FILTER_IGNORE
		stone.texture = load(STONE_PATH % _shooter_element()) as Texture2D
		stone.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		stone.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		stone.size = Vector2(side, side)
		stone.pivot_offset = stone.size * 0.5
		stone.position = Vector2((canvas.x - side) * 0.5, canvas.y * 0.05)
		_ensure_overlay().add_child(stone)
		cue["stone"] = stone
		# 炸开的序列帧：4x4 图集，按进度换格子。
		var atlas_tex := load(STONE_REVEAL_ATLAS) as Texture2D
		if atlas_tex != null:
			var burst := TextureRect.new()
			burst.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var at := AtlasTexture.new()
			at.atlas = atlas_tex
			at.region = Rect2(Vector2.ZERO, atlas_tex.get_size() / 4.0)
			burst.texture = at
			burst.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			burst.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			burst.size = Vector2(side, side) * 2.2
			burst.position = stone.position + stone.size * 0.5 - burst.size * 0.5
			burst.visible = false
			_ensure_overlay().add_child(burst)
			cue["stone_burst"] = burst
	var stone_node := cue["stone"] as TextureRect
	var burst_node := cue.get("stone_burst") as TextureRect
	if rel < STONE_BURST_AT:
		# 出现 → 悬着发亮：先弹进来，再随时间越来越亮（蓄力）。
		var p := clampf(float(rel - STONE_IN_AT) / 4.0, 0.0, 1.0)
		var charge := clampf(float(rel - STONE_IN_AT) / float(STONE_BURST_AT - STONE_IN_AT), 0.0, 1.0)
		var s := lerpf(0.3, 1.0, 1.0 - pow(1.0 - p, 3.0)) * (1.0 + 0.06 * sin(float(rel) * 1.7))
		stone_node.scale = Vector2(s, s)
		stone_node.modulate = Color(1, 1, 1, p).lerp(Color(2.2, 2.2, 2.0, 1.0), charge * charge)
		return
	var b := clampf(float(rel - STONE_BURST_AT) / float(STONE_BURST_TICKS), 0.0, 1.0)
	if stone_node != null and is_instance_valid(stone_node):
		# 炸：一下撑大、瞬间白掉、消失。
		stone_node.scale = Vector2.ONE * (1.0 + 0.8 * b)
		stone_node.modulate = Color(3.0, 3.0, 3.0, 1.0 - clampf(b * 2.5, 0.0, 1.0))
	if burst_node != null and is_instance_valid(burst_node):
		burst_node.visible = b < 1.0
		var at := burst_node.texture as AtlasTexture
		var cell := at.atlas.get_size() / 4.0
		var frame_i := mini(15, int(b * 16.0))
		at.region = Rect2(Vector2(frame_i % 4, frame_i / 4) * cell, cell)
	if b >= 1.0:
		for key in ["stone", "stone_burst"]:
			var n := cue.get(key) as Node
			if n != null and is_instance_valid(n):
				n.queue_free()
			cue.erase(key)
		cue["stone"] = null


func _shooter_element() -> String:
	var e := str((_unit_defs().get(_shooter_id, {}) as Dictionary).get("element", "sky"))
	return e if e in ["sky", "land", "ren"] else "sky"


# --- 落地：召唤法阵 / 升星迸发 / 4 星全屏特效 / 头顶星级字 ---

func _update_landing(cue: Dictionary, rel: float) -> void:
	var kind := str(cue["kind"])
	if kind == "spawn" and not cue.has("summoned") and rel >= -_summon_lead_ticks():
		cue["summoned"] = true
		_play_summons(cue)
	if kind == "four" and not cue.has("screen_fx") and rel >= -_four_star_lead_ticks():
		cue["screen_fx"] = true
		_play_four_star_screen_fx(cue)
	if rel >= 0 and (kind == "star" or kind == "four"):
		_hide_replaced_models(cue)
	if rel >= 0 and not cue.has("landed"):
		cue["landed"] = true
		if kind == "star":
			_play_star_bursts(cue)
		elif kind == "four":
			_play_four_star_bursts(cue)
		if kind == "star" or kind == "four":
			_spawn_star_captions(cue)
	if rel >= 0.0:
		_flush_star_bursts(cue, rel)
	_update_captions(cue, rel)
	if rel > CAPTION_TICKS + 4 and (kind == "spawn" or rel > 30):
		cue["done"] = true


# 召唤法阵的揭示时刻 = duration × reveal_at（VFXSummonSpawn3D.play_summon），
# 决赛圈那份 profile 是 2.0 × 0.5 = 1 秒。提前这么多开播，揭示就落在单位出现那一帧。
func _summon_lead_ticks() -> int:
	var profile := load(SUMMON_PROFILE_PATH)
	if profile == null:
		return 10
	var params: Dictionary = profile.get("parameters") if profile.get("parameters") != null else {}
	var reveal := float(profile.get("duration")) * clampf(float(params.get("reveal_at", 0.5)), 0.15, 0.9)
	return int(round(reveal / TICK))


func _four_star_lead_ticks() -> int:
	var fx_script: GDScript = load(FOUR_STAR_SCREEN_FX_PATH)
	var impact := 0.36
	if fx_script != null:
		impact = float(fx_script.get_script_constant_map().get("IMPACT_SEC", 0.36))
	return int(round(impact / TICK))


func _play_summons(cue: Dictionary) -> void:
	var fx_script: GDScript = load(SUMMON_FX_PATH)
	var profile = _trailer_summon_profile()
	var world := _screen.get("_battle_3d_world") as Node3D
	if fx_script == null or world == null:
		push_warning("召唤特效或 3D 世界缺失，单位会直接出现。")
		return
	for p in cue["spawn_pos"]:
		var fx: Node3D = fx_script.new()
		world.add_child(fx)
		fx.call("play_summon", _sim_to_world(p), profile)


# 召唤法阵用决赛圈那份 profile，但**换成白色、缩小**（用户要求：原版红色太大）。
# 决赛圈本身还在用原文件，所以不改 .tres，运行时复制一份再改 ——
# duplicate() 出来的是内存里的副本，录制进程退出就没了。
# 时长和 reveal_at 不动，_summon_lead_ticks() 算出来的提前量照样成立。
const SUMMON_SIZE := 0.6
func _trailer_summon_profile() -> Resource:
	var base := load(SUMMON_PROFILE_PATH) as Resource
	if base == null:
		return null
	var p := base.duplicate(true)
	p.set("size", SUMMON_SIZE)
	p.set("main_color", Color(0.92, 0.96, 1.0, 1.0))
	p.set("core_color", Color(1.0, 1.0, 1.0, 1.0))
	# 暗部给冷灰而不是黑：法阵外圈的暗边还在，白色才有层次，不是一团糊光。
	p.set("dark_color", Color(0.36, 0.40, 0.48, 1.0))
	p.set("emission_energy", 2.6)
	return p


# 升星迸发（PrepStarUpgradeBurst：大的白色四角星 + 一片青蓝 / 金色小星迸开）。
#
# 它的星星大小、散开距离、冒出的高度全按**备战**的棋子身高（UNIT_HEIGHT 0.32）和
# 格子（CELL_SIZE 0.6）定。第一版照备战的做法按格距缩放 —— 战斗镜头远、格子小，
# 星星缩成几个小点，成片里根本看不出升星（用户：「升星的特效要跟我弄出来」）。
# 现在按**这个棋子的真实身高**（模型 meta model_height）缩放，星星落在头顶一带；
# 再乘 STAR_BURST_BOOST，全场镜头下也看得清。
# 同时补上备战升星的另外两样：模型压扁回弹（PrepBoardModels._squash_prep_model）和升级音效。
const STAR_BURST_BOOST := 1.2
const STAR_SQUASH := {2: 0.16, 3: 0.26, 4: 0.22}   # 同 PrepBoardModels.STAR_UPGRADE_SQUASH
const STAR_SQUASH_SEC := 0.26                       # 同 PrepBoardModels.STAR_UPGRADE_SQUASH_SEC
const STAR_UPGRADE_CUE := {2: "carrot_farm_upgrade", 3: "harvest_tech_upgrade"}


# 落地那一帧只登记「待播」：新单位出现的这一帧，渲染层的模型往往还没建出来，
# 当场去找模型会扑空，迸发和压扁整个被跳过（第二版实测就是这样，只剩脚下几圈白环）。
# 之后每帧由 _flush_star_bursts 去找，找到就播；等太久还找不到就按战斗坐标兜底。
# burst_star：迸发用哪一档颜色。-1 = 按这次升到的星级；4 星传 3（金色那档）。
func _play_star_bursts(cue: Dictionary, burst_star := -1) -> void:
	var star := int(cue["star"]) if burst_star < 0 else burst_star
	cue["burst_pending"] = (cue["new_uids"] as Array).duplicate()
	cue["burst_star"] = star
	var sfx: GDScript = load("res://ui/services/SfxService.gd")
	if sfx != null:
		sfx.call("play", str(STAR_UPGRADE_CUE.get(mini(star, 3), "harvest_tech_upgrade")))


const STAR_BURST_WAIT_TICKS := 10.0


func _flush_star_bursts(cue: Dictionary, rel: float) -> void:
	var pending: Array = cue.get("burst_pending", [])
	if pending.is_empty():
		return
	var burst_script: GDScript = load(STAR_BURST_PATH)
	var world := _screen.get("_battle_3d_world") as Node3D
	if burst_script == null or world == null:
		pending.clear()
		return
	var prep_height := float(burst_script.get_script_constant_map().get("UNIT_HEIGHT", 0.32))
	var star := int(cue.get("burst_star", 3))
	var give_up := rel >= STAR_BURST_WAIT_TICKS
	var done: Array = []
	for i in pending.size():
		var uid := str(pending[i])
		var model := _model_for(uid)
		if model == null and not give_up:
			continue
		var at: Vector3
		var h := 0.5
		if model != null:
			at = model.global_position
			h = float(model.get_meta("model_height", 0.5)) if model.has_meta("model_height") else 0.5
		else:
			# 兜底：模型一直没出来就按战斗坐标放，宁可位置略偏也不能没有升星。
			var idx := (cue["new_uids"] as Array).find(uid)
			var spots: Array = cue["spawn_pos"]
			at = _sim_to_world(spots[idx] if idx >= 0 and idx < spots.size() else spots[0])
		var burst: Node3D = burst_script.new()
		world.add_child(burst)
		burst.global_position = at
		burst.scale = Vector3.ONE * maxf(0.5, h / prep_height) * STAR_BURST_BOOST
		burst.call("play", star)
		_fit_burst_to_battle(burst)
		if model != null:
			_squash_model(model, star)
		print("  升星迸发：%s（%d 星档，身高 %.2f，%s）" % [uid, star, h, "模型" if model != null else "兜底坐标"])
		done.append(uid)
	for uid in done:
		pending.erase(uid)


# 迸发里每颗星是公告板面片。两处要为战场改（只改录制里生成的这几颗，不碰游戏文件）：
# · Godot 的公告板材质默认**不吃父节点缩放**（billboard_keep_scale = false）—— 只放大
#   burst 节点的话，散开位置变大了，星星本身还是备战尺寸，战斗镜头里就是几个小点。
# · 原版是叠加混合（ADD），在备战深色石台上很亮；战场是亮黄绿草地，白 / 青叠上去
#   直接融进背景。改普通混合（MIX），星星在草地上才有对比度。
func _fit_burst_to_battle(burst: Node3D) -> void:
	for child in burst.get_children():
		var mesh := child as MeshInstance3D
		if mesh == null:
			continue
		var mat := mesh.material_override as StandardMaterial3D
		if mat == null:
			continue
		mat.billboard_keep_scale = true
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX


# 先压扁再回弹（TRANS_BACK 的过冲就是「弹」的来源），棋子像被「砸实」了一下。
# 用 scale 而不是 position：位置每帧由渲染层 / 插值写，scale 没人动。
func _squash_model(model: Node3D, star: int) -> void:
	# 原始大小只记一次（同 PrepBoardModels）：连着压两次的话，第二次读到的 scale
	# 已经是压扁过的，回弹完模型就永久变形了。
	if not model.has_meta("star_squash_base"):
		model.set_meta("star_squash_base", model.scale)
	var base: Vector3 = model.get_meta("star_squash_base")
	var amount := float(STAR_SQUASH.get(star, 0.2))
	model.scale = Vector3(base.x * (1.0 + amount), base.y * (1.0 - amount), base.z * (1.0 + amount))
	var tween := model.create_tween()
	tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(model, "scale", base, STAR_SQUASH_SEC)


func _play_four_star_screen_fx(cue: Dictionary) -> void:
	var fx_script: GDScript = load(FOUR_STAR_SCREEN_FX_PATH)
	var aura_script: GDScript = load(FOUR_STAR_AURA_PATH)
	if fx_script == null or aura_script == null:
		return
	var element := _shooter_element()
	var fx: Control = fx_script.new()
	fx.set_anchors_preset(Control.PRESET_FULL_RECT)
	fx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ensure_overlay().add_child(fx)
	# 落点取胸口而不是脚底（同 PrepBoardModels._play_four_star_screen_fx）。
	var chest := _landing_canvas_pos(cue) - Vector2(0.0, _canvas_size().y * 0.04)
	fx.call("play", element, chest, aura_script.call("_palette", element), {
		"feather": aura_script.call("_get_texture", "feather"),
		"shard": aura_script.call("_get_texture", "shard"),
		"sparkle": aura_script.call("_get_texture", "sparkle"),
		"toon_ember": aura_script.call("_get_texture", "toon_ember"),
	})


func _play_four_star_bursts(cue: Dictionary) -> void:
	for uid in cue["new_uids"]:
		var model := _model_for(str(uid))
		if model == null:
			continue
		var aura := model.get_node_or_null("FourStarAuraV2") as Node3D
		if aura != null:
			aura.visible = true
			aura.call("play_upgrade")
	# 4 星同样补一次升星迸发 + 压扁回弹（用金色 3 星那档），和备战「三档手感一致」对齐。
	_play_star_bursts(cue, 3)


# 换 uid 升星时，旧的那个在同一帧 alive=false —— 渲染层会给它放死亡淡出，
# 跟新模型叠在一起像个残影。落地那一刻起直接把旧模型和它的血条藏掉。
func _hide_replaced_models(cue: Dictionary) -> void:
	var nodes: Dictionary = _screen.get("_unit_nodes")
	var deaths: Dictionary = _screen.get("_active_death_actors")
	for uid in cue["old_uids"]:
		var model := _model_for(str(uid))
		if model != null and model.visible:
			model.visible = false
		if nodes != null:
			var hud = nodes.get(uid)
			if hud != null and is_instance_valid(hud) and hud is CanvasItem and hud.visible:
				hud.visible = false
		if deaths != null and deaths.has(uid):
			var entry = deaths[uid]
			var actor = null
			if entry is Dictionary:
				actor = (entry as Dictionary).get("actor", (entry as Dictionary).get("node"))
			elif entry != null and is_instance_valid(entry):
				actor = entry
			if actor != null and is_instance_valid(actor) and actor is Node3D:
				actor.visible = false


func _spawn_star_captions(cue: Dictionary) -> void:
	# **一次升星只飘一行**，放在所有升星棋子的正中上方。两个射手挨着站，
	# 一人一行的话两行字叠在一起、还被血条压住（实测读不出来）。
	var star := int(cue["star"])
	var text := ("%d STAR!" % star) if _locale == "en" else ("%d星了！" % star)
	var lbl := Label.new()
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.text = "%s
%s" % ["★".repeat(star), text]
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var fs := int(_ui_unit() * 0.05)
	lbl.add_theme_font_size_override("font_size", fs)
	# 2★ 冷色、3★ 以上金色 —— 跟升星迸发的配色走（PrepStarUpgradeBurst.PRESETS）。
	var col := Color(0.72, 0.94, 1.0) if star <= 2 else Color(1.0, 0.86, 0.36)
	lbl.add_theme_color_override("font_color", col)
	lbl.add_theme_color_override("font_outline_color", Color(0.08, 0.05, 0.02, 0.95))
	lbl.add_theme_constant_override("outline_size", maxi(3, int(fs * 0.22)))
	lbl.visible = false
	_ensure_overlay().add_child(lbl)
	cue["caption"] = lbl


# 头顶星级字：跟着棋子头顶走，先放大弹出、往上飘，最后几 tick 淡出。
func _update_captions(cue: Dictionary, rel: float) -> void:
	if not cue.has("caption") or rel < 0:
		return
	# 先判有效再转型：上一帧 queue_free 过的 Label 再做 `as` 会直接报错。
	var lbl_v = cue["caption"]
	if lbl_v == null or not is_instance_valid(lbl_v):
		return
	var lbl := lbl_v as Label
	if rel > CAPTION_TICKS:
		lbl.queue_free()
		cue.erase("caption")
		return
	var sum := Vector2.ZERO
	var n := 0
	for uid in cue["new_uids"]:
		var model := _model_for(str(uid))
		if model == null:
			continue
		var head_h := float(model.get_meta("model_height", 0.5)) if model.has_meta("model_height") else 0.5
		sum += _world_to_canvas(model.global_position + Vector3(0.0, head_h * 1.25, 0.0))
		n += 1
	if n == 0:
		return
	var head := sum / float(n)
	var canvas := _canvas_size()
	var t := float(rel) / float(CAPTION_TICKS)
	lbl.visible = true
	lbl.reset_size()
	lbl.pivot_offset = lbl.size * 0.5
	var pop := 1.0 + 0.55 * clampf(1.0 - float(rel) / 3.0, 0.0, 1.0)
	lbl.scale = Vector2(pop, pop)
	# 再往上让出一截：单位头顶那层 2D 血条在这里，字要压在血条上面。
	var lift := canvas.y * (0.07 + 0.05 * t)
	lbl.position = head - Vector2(lbl.size.x * 0.5, lbl.size.y + lift)
	lbl.modulate.a = 1.0 - clampf((t - 0.7) / 0.3, 0.0, 1.0)


# 底部的宝藏收集条：四个元素图标，拿到一个弹出一个；
# 集齐 4 个再把 element 套装的 logo 推出来。
func _build_treasure_bar() -> void:
	if _treasure_cues.is_empty():
		return
	var root_ctrl := _ensure_overlay()

	# 底部居中。不摆未获得的灰色占位 —— 观众看到的只有「已经拿到的」，
	# 每收一个就从中间弹出来一个，收集感是靠**数量变多**表达的，不是靠点亮空格。
	# 一条贴着画面底边的细带，水平居中。不往上摞第二行 ——
	# 战场就在上面，多一行就会盖住正在打的棋子。
	var row := HBoxContainer.new()
	row.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 16)
	var logo_size := int(_ui_unit() * LOGO_RATIO)
	var set_logo_size := int(_ui_unit() * SET_LOGO_RATIO)
	row.offset_top = -float(set_logo_size) - 16.0
	row.offset_bottom = -14.0
	root_ctrl.add_child(row)

	for tid in _treasures:
		var node := _make_logo(str(_treasures[tid]), logo_size)
		if node == null:
			continue
		# 拿到之前连位置都不占：visible=false 的子节点不参与 HBox 布局，
		# 所以每多一个，整排会自己重新居中。
		node.visible = false
		row.add_child(node)
		_logo_nodes[tid] = node

	# 套装 logo 接在四个元素后面，集齐才出现。
	_set_logo_node = _make_logo(_set_logo, set_logo_size)
	if _set_logo_node != null:
		_set_logo_node.visible = false
		row.add_child(_set_logo_node)
	print("  底部宝藏条已建（%d 个图标，%d 个出现提示）" % [_logo_nodes.size(), _treasure_cues.size()])


func _make_logo(logo_name: String, size: int) -> TextureRect:
	var path := TREASURE_LOGO_DIR + logo_name + ".png"
	var tex := load(path) as Texture2D
	if tex == null:
		push_warning("宝藏图标缺失：%s" % path)
		return null
	var node := TextureRect.new()
	node.texture = tex
	node.custom_minimum_size = Vector2(size, size)
	node.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	node.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return node


# 跟着回放游标点亮，不是跟着挂钟 —— `_replay_frame` 是 BattleScreen 的播放游标
# （scenes/battle/BattleScreen.gd:45），编排里的 t 换算成的 tick 与它同一个坐标系，
# 所以不管录制掉不掉帧，图标亮起的时刻都正好压在宝藏生效的那一帧。
func _update_treasure_bar() -> void:
	if _logo_nodes.is_empty():
		return
	var cursor := _replay_cursor()
	for cue: Dictionary in _treasure_cues:
		var cue_tick := int(cue.get("tick", 0))
		if cursor < cue_tick:
			continue
		var age := cursor - float(cue_tick)
		_pop_in(_logo_nodes.get(str(cue.get("id", ""))) as TextureRect, age)
		if bool(cue.get("set_complete", false)):
			_advance_set_fx(age)


# 集齐四件 → 播游戏自己的套装激活特效（scenes/prep/fx/LinkageFx.gd）：
# 四个元素图标射出光束汇到屏幕中央 → 中央爆开闪光和星光粒子 + 横幅打出套装名
# → 套装图标飞回底部那一格落位。这是备战界面激活套装时玩家看到的同一个演出，
# 不是我另画的东西，所以观感和游戏一致。
#
# 分两步做：这一帧先把套装格子设成「可见但全透明」，让 HBoxContainer 把它排进布局
# 算出真实矩形（invisible 的子节点不参与布局，直接读会拿到 0 尺寸、光束飞向左上角），
# 下一帧再拿矩形启动特效。
func _advance_set_fx(age: float) -> void:
	if _set_logo_node == null or not is_instance_valid(_set_logo_node):
		return
	_set_fx_age = age
	match _set_fx_state:
		0:
			_set_logo_node.visible = true
			_set_logo_node.modulate.a = 0.0
			_set_fx_state = 1
		1:
			_start_set_fx()
			_set_fx_state = 2
		3:
			# landed 之后才把真图标亮出来，和 LinkageFx 的调用约定一致。
			_pop_in(_set_logo_node, age - _set_landed_age)


func _start_set_fx() -> void:
	var fx_script: GDScript = load("res://scenes/prep/fx/LinkageFx.gd")
	var logo := load(TREASURE_LOGO_DIR + _set_logo + ".png") as Texture2D
	if fx_script == null or logo == null:
		push_warning("套装特效或图标缺失，跳过演出直接亮图标。")
		_set_fx_state = 3
		return
	var sources: Array = []
	for tid in _logo_nodes:
		var node := _logo_nodes[tid] as Control
		if node == null or not is_instance_valid(node) or not node.visible:
			continue
		sources.append({"rect": _screen_rect(node), "category": _set_category})
	var fx: Control = fx_script.new()
	_logo_layer.add_child(fx)
	fx.connect("landed", func() -> void:
		_set_landed_age = _set_fx_age
		_set_fx_state = 3)
	fx.play(sources, logo, _set_banner_text(), _screen_rect(_set_logo_node))
	print("  套装特效开播（%d 道光束）" % sources.size())


# 宝藏栏在画布 0 层、特效在自己的图层：带画布变换的矩形才能换到同一个屏幕坐标系。
# 判据抄 PrepUI._screen_rect()，那边是同一个问题。
func _screen_rect(c: Control) -> Rect2:
	var xf := c.get_global_transform_with_canvas()
	return Rect2(xf.origin, c.size * xf.get_scale())


# 横幅文案。套装名在 data/codex/treasure_text.json 的 sets.set_<类别> 里
# （"4元素" / "4 Element"），外面再套 ui_set_fx_banner 这个句式 —— 和备战界面
# 激活套装时打出来的那行字完全一样。
func _set_banner_text() -> String:
	var name := "4元素"
	var file := FileAccess.open("res://data/codex/treasure_text.json", FileAccess.READ)
	if file != null:
		var parsed = JSON.parse_string(file.get_as_text())
		file.close()
		if typeof(parsed) == TYPE_DICTIONARY:
			var entry: Dictionary = (parsed as Dictionary).get("sets", {}).get("set_" + _set_category, {})
			var key := "name_en" if _locale == "en" else "name"
			if not str(entry.get(key, "")).is_empty():
				name = str(entry[key])
	var banner := TranslationServer.translate("ui_set_fx_banner")
	return (banner % name) if banner.contains("%") else name


# 放大着出现，再缩回原大小：拿到的那一刻图标从中间"弹"出来，眼睛会被带过去。
# 缩放围绕节点中心做，所以 pivot 要先摆到中点，否则会从左上角长出来。
func _pop_in(node: TextureRect, age: float) -> void:
	if node == null or not is_instance_valid(node):
		return
	if not node.visible:
		node.visible = true
	var t: float = clampf(age / POP_TICKS, 0.0, 1.0)
	# 缓出：开头冲得快、末尾稳稳落定。
	var eased := 1.0 - pow(1.0 - t, 3.0)
	var scale_now: float = lerpf(POP_SCALE, 1.0, eased)
	node.pivot_offset = node.size * 0.5
	node.scale = Vector2(scale_now, scale_now)
	node.modulate.a = clampf(t * 2.0, 0.0, 1.0)


# 取景。第一次算出目标值并记下来，之后**每帧重设** —— 开战那一帧设一次是不够的，
# 战斗开始后还有东西会把相机写回去（实测 --camera-size / --pan-z 完全没生效）。
# 记的是绝对值不是增量，否则每帧累加会把相机推飞。
func _apply_camera_framing() -> void:
	if _camera_size <= 0.0 and is_zero_approx(_pan_x) and is_zero_approx(_pan_z):
		return
	var cam := _screen.get("_battle_3d_camera") as Camera3D
	if cam == null or not is_instance_valid(cam):
		if not _camera_applied:
			push_warning("取不到战斗相机，取景参数未生效。")
		return
	if not _camera_applied:
		_camera_target_size = _camera_size if _camera_size > 0.0 else cam.size
		_camera_target_pos = cam.position + Vector3(_pan_x, 0.0, _pan_z)
		_camera_applied = true
		print("  取景：size %.2f -> %.2f，位置 %s -> %s" % [
			cam.size, _camera_target_size, str(cam.position), str(_camera_target_pos)])
	cam.size = _camera_target_size
	cam.position = _camera_target_pos


func _record_viewport_size() -> void:
	var viewport := _screen.get("_battle_3d_viewport") as SubViewport
	if viewport != null:
		_viewport_size = viewport.size


func _write_manifest() -> void:
	if _out_dir.is_empty():
		return
	var cues: Array = []
	for cue: Dictionary in _treasure_cues:
		cues.append({
			"id": str(cue.get("id", "")),
			"name": str(_treasures.get(str(cue.get("id", "")), "")),
			"tick": int(cue.get("tick", 0)),
		})
	var manifest := {
		"scene": "trailer",
		"variant": _variant,
		"realtime": _realtime,
		"seed": _seed,
		"fps": _fps,
		"locale": _locale,
		"hud": _hud,
		# 这一帧之前是模型分帧加载的进度条，不是战斗。Movie Maker 从
		# frame00000000.png 开始编号，所以第 N 帧的文件序号是 N-1。
		"start_frame": maxi(0, _start_frame - 1),
		"finished_frame": maxi(0, _finished_frame - 1),
		"start_unix_msec": _start_unix_msec,
		"finished_unix_msec": _finished_unix_msec,
		"total_frames": _frame,
		"replay_frames": _replay_frames,
		"viewport_3d": [_viewport_size.x, _viewport_size.y],
		"treasure_cues": cues,
	}
	var path := _out_dir.path_join("manifest.json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("写不进 manifest：%s" % path)
		return
	file.store_string(JSON.stringify(manifest, "  "))
	file.close()
	print("trailer_capture: 已写 %s" % path)


# 不加这个 Godot 退出时会报 "1 ObjectDB instance was leaked at exit"。
# 本身无害，但每次录制都在 stderr 刷一行；而 PowerShell 一旦重定向该流，
# 原生 stderr 会被变成终止性错误 —— 光这条泄漏警告就能让一次好录制失败。
func _finalize() -> void:
	if RenderingServer.frame_pre_draw.is_connected(_on_frame_pre_draw):
		RenderingServer.frame_pre_draw.disconnect(_on_frame_pre_draw)
	if _screen != null and is_instance_valid(_screen):
		root.remove_child(_screen)
		_screen.free()
		_screen = null
	if _logo_layer != null and is_instance_valid(_logo_layer):
		root.remove_child(_logo_layer)
		_logo_layer.free()
		_logo_layer = null


func _parse_arguments() -> void:
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		var key := str(args[i])
		var value := str(args[i + 1]) if i + 1 < args.size() else ""
		match key:
			"--out": _out_dir = value
			"--seed": _seed = int(value)
			"--fps": _fps = int(value)
			"--locale": _locale = value
			"--variant": _variant = value
			"--monster-power": _monster_power_cli = float(value)
			"--boss-power": _boss_power_cli = float(value)
			"--count-scale": _count_scale_cli = float(value)
			"--monster-atk": _monster_atk_cli = float(value)
			"--boss-atk": _boss_atk_cli = float(value)
			"--monster": _monster_id = value
			"--boss": _boss_id = value
			"--camera-size": _camera_size = float(value)
			"--pan-x": _pan_x = float(value)
			"--pan-z": _pan_z = float(value)
			"--ssaa": _ssaa = clampf(float(value), 1.0, 2.0)
			"--msaa": _msaa = int(value)
			"--smooth":
				_smooth = true
				i += 1
				continue
			"--realtime":
				_realtime = true
				i += 1
				continue
			"--hud":
				_hud = true
				i += 1
				continue
			_:
				push_warning("未知参数 '%s'" % key)
				i += 1
				continue
		i += 2
