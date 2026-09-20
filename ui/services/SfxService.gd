extends RefCounted

# 全局音效服务（9.17 音效/BGM 接入批次）。
#
# ## 为什么不做 autoload
#
# 照 `ui/services/UiFeedback.gd` 的先例：autoload 全部在第一个场景之前构造，
# 条条都在冷启动关键路径上（T3 实测 8730–8890 ms，预算 ≤3 s，是未闭环 blocker）。
# 所以由 `Main._ready()` 调一次 `install()`，播放器和代币监视器都挂在
# `get_tree().root` 下**按需创建**。
#
# 挂 root 而不是挂页面：`Main._clear()` 会把页面子树整个释放，挂页面上会出现
# 「战斗胜利音刚开口就被掐掉」——胜负结算那一刻页面正在换。
#
# 挂载走 `add_child.call_deferred`，**不是**同步 add_child：`install()` 的时机
# 正好是 root 在装配子节点的窗口里，同步挂必失败且不报错。本文件最容易静默
# 失效的一处就在这，细节见 `_ensure_voices`。
#
# ## 消费方怎么拿它
#
# 一律 `const SfxService := preload("res://ui/services/SfxService.gd")`，
# 与 Main 拿 `UiFeedbackService` 的方式一致。刻意**不声明 class_name**：
# 少注册一个全局类，也不会踩「局部 const 名与全局类名同名」那种只能靠试出来的报错。
#
# ## 总线：只有 SFX，不加 Music
#
# `default_bus_layout.tres` 里只有 Master 和 SFX 两条。四处 BGM 代码写着
# `bus = "Music" if get_bus_index("Music") >= 0 else "Master"` —— 加一条 Music
# 总线会让它们**同时**改走一条从没调过音量的总线。`ui_feedback_check` 的
# `music_bus_added_silently` 钉着这一条，别顺手补上。
#
# ## 静音门只有一处
#
# 每个 play() 都过 `Presentation.ui_sound_allowed()`：玩家关掉「界面音效」开关、
# 或在备战页按了 Master 静音键，这里一律不出声。裁决不散到各调用点 ——
# 散出去的结果是「关掉了但某个音还在响」。
#
# ## 一次点击只发一次
#
# 本服务**不接任何输入回调**（`_input` / `_unhandled_input` / `_gui_input`）。
# `PrepScreen._input()` 用 if/elif 同时处理鼠标与触摸且无去重，挂上去在 Android
# 上一次触摸会响两次，**而在 Windows 开发机上完全看不出来**。所以调用点必须
# 落在「业务已确认成功」的那一行之后，见各调用点自己的注释。
#
# 另有一道 `RETRIGGER_GUARD_MSEC` 兜底：同一 cue 在 40 ms 内只发一次。
# 它挡的是「同一帧里多条路径都判定成功」，不替代上面的结构性保证。

const Presentation := preload("res://effects/runtime/presentation/PresentationSettings.gd")

const SFX_BUS := "SFX"
const VOICE_PREFIX := "GlorySfxVoice"

# 循环音专用播放器名。**刻意不带 `GlorySfxVoice` 前缀**：audio_sfx_check 会数
# root 下以 `GlorySfxVoice` 开头的节点并要求正好 8 个，名字撞上去会把那条
# 「播放器池没挂进树」的断言弄红 —— 而那个诊断跟循环播放器毫无关系。
const LOOP_PLAYER_NAME := "GlorySfxLoopVoice"

# 同时能重叠几条。8 是取舍：AOE 多杀时的死亡音、连点时的按钮音都要能叠，
# 但再多就是白白占着播放器不放。
const VOICE_COUNT := 8

# 同一 cue 的最小重触发间隔。
const RETRIGGER_GUARD_MSEC := 40


# --- cue id -----------------------------------------------------------------
#
# 用字符串 id 而不是裸路径：调用点把 id 写错是一个能搜出来的拼写差异，
# 写错路径只会在运行时静默无声。路径只在本文件的 CUES 里出现一次。

const CUE_UI_POPUP := "ui_popup"
const CUE_UI_CONFIRM := "ui_confirm"
const CUE_UI_REJECT := "ui_reject"
const CUE_UI_CURRENCY_GAIN := "ui_currency_gain"
const CUE_UI_CURRENCY_SPEND := "ui_currency_spend"

const CUE_SYNERGY_ACTIVATE := "synergy_activate"
const CUE_SHOP_REFRESH := "shop_refresh"
const CUE_SHOP_BUY := "shop_buy"
const CUE_UNIT_SELL := "unit_sell"
const CUE_STAR4_HUMAN_KING := "star4_human_king"
const CUE_STAR4_GOD := "star4_god"
const CUE_STAR4_UNDEAD_MOTHER := "star4_undead_mother"
const CUE_STAR4_DARK := "star4_dark"
const CUE_STAR4_DEFAULT := "star4_default"
# 9.18：四星大天使 / 四星末日守卫从「神 / 暗」分组里拆出，各自独立音效。
const CUE_STAR4_ARCHANGEL := "star4_archangel"
const CUE_STAR4_DOOM := "star4_doom"
# 9.19：四星「合成」与「战斗技能释放」分离。神王 / 母灵 / 黑龙这三家的
# 合成音是 9.18 之前就在用的原音，9.18 用户给的新素材只该在「战斗里自身棋子
# 释放技能」时响。于是新素材另存一份 `*_skill.mp3`，合成音回滚到原件。
const CUE_STAR4_GOD_SKILL := "star4_god_skill"
const CUE_STAR4_UNDEAD_MOTHER_SKILL := "star4_undead_mother_skill"
const CUE_STAR4_DARK_SKILL := "star4_dark_skill"
const CUE_TREASURE_LINKAGE := "treasure_linkage"
const CUE_TREASURE_CHOICE_OPEN := "treasure_choice_open"

const CUE_BOSS_APPEAR := "boss_appear"
const CUE_HUMAN_KING_DEATH := "human_king_death"
const CUE_BATTLE_VICTORY := "battle_victory"
const CUE_BATTLE_DEFEAT := "battle_defeat"

const CUE_MERC_SUMMON := "merc_summon"
const CUE_UPGRADE_STONE_DRAW := "upgrade_stone_draw"
const CUE_CARROT_FARM_UPGRADE := "carrot_farm_upgrade"
const CUE_HARVEST_TECH_UPGRADE := "harvest_tech_upgrade"

# --- 9.17 第二批（反馈文档 6 条里的第 6 条 + 社交/房间三条素材）-------------
#
# 三条新 cue 对应「音乐\0917」那一批素材：
#   * 聊天新信息 / 朋友申请 —— 一条音，两处触发（私聊到达、朋友申请到达）；
#   * 房间内更换座位 —— **只有自己换座**才响（别人换座不响）；
#   * 己方法阵受击 —— 战斗结算水晶演出里，被打的是我方水晶时**循环**播。
const CUE_CHAT_ALERT := "chat_alert"
const CUE_ROOM_SEAT_CHANGE := "room_seat_change"
const CUE_FORMATION_HIT := "formation_hit"
# 9.18：战斗结算「敌方法阵受击」循环音（我方打敌水晶时播，与己方法阵受击对称）。
const CUE_ENEMY_FORMATION_HIT := "enemy_formation_hit"
# 9.18：社交 / 房间 / 设置 / 资料 / 语音 四条 UI 反馈音。
const CUE_ROOM_READY_SWITCH := "room_ready_switch"
const CUE_PROFILE_SAVE := "profile_save"
const CUE_SETTINGS_SWITCH := "settings_switch"
const CUE_VOICE_SWITCH := "voice_switch"

# --- 9.19 第二批（`音乐/0919/战斗、特效` 9 个素材）--------------------------
#
# 用户口径两条：
#   ① 这批战斗音效**只有自身的棋子**才会播（队友、敌方都不响）；
#   ② 四星前缀的素材不是「合成时」响，而是**该棋子四星、且这次真的触发
#      技能/攻击**的那一下响。所以 1~3 星不响、没触发的那次普攻也不响。
#
# 6 条四星音按「怎么触发」分两张表：
#   * 施法类（剑士盾击 / 法师法术 / 神侍·天使治疗）—— 走 STAR4_SKILL_CUES，
#     由 `star4_cue_for(uid, true)` 在 skill_ready 上升沿派发；
#   * 攻击触发类（弓箭手第 N 击额外伤害 / 牧师第 N 击治疗 / 极光射手每次都有的
#     真伤）—— 它们不产生 skill_ready 边沿，走 STAR4_ATTACK_SKILL_CUES，
#     由 `attack_skill_cue_for(uid)` 在 BattleVfx 判过 `attack_count % every`
#     之后派发（那一步保证「真的触发」）。
const CUE_STAR4_SWORDSMAN_SKILL := "star4_swordsman_skill"
const CUE_STAR4_ARCHER_SKILL := "star4_archer_skill"
const CUE_STAR4_AURORA_SKILL := "star4_aurora_skill"
const CUE_STAR4_MAGE_SKILL := "star4_mage_skill"
const CUE_STAR4_CLERIC_SKILL := "star4_cleric_skill"
const CUE_STAR4_PRIEST_SKILL := "star4_priest_skill"
# 佣兵 3 条（星轨猎人 / 泡沫术士 / 圣愈修女）。**佣兵升不到四星**，所以它们
# 不带星级门，只判「自身棋子」——星级门在这里会把音效整个掐掉。
const CUE_MERC_ARROW_RAIN_SKILL := "merc_arrow_rain_skill"
const CUE_MERC_BUBBLE_HOLY_SONG_SKILL := "merc_bubble_holy_song_skill"
# 人王「战斗结束未阵亡奖励属性」：战斗结束那一刻在自身人王身上响一次。
const CUE_HUMAN_KING_REWARD := "human_king_reward"

# --- 9.20 第二批（`音乐/0920` 10 个素材）-------------------------------------
#
# 用户口径三条：
#   ① 「四星其他棋子合成（非唯一棋子）」「四星神王技能」「四星大天使技能」
#      是**替换**既有素材 —— 三个文件就地覆盖，cue 与路径一个都没动；
#   ② 其余 7 条是**新增**的四星技能音；
#   ③ 四星唯一棋子的**合成音**维持「只有自己听得见」。原因不是取舍而是通道：
#      备战期的消息全部经战斗服务端转发，现有通道（team_prep_mercs / room_state
#      / chat）没有一条能携带「某座位刚合成四星唯一棋子」这种自由格式通知，
#      要让别人也听见就必须加房间级消息 + 重新部署服务端。本批不做，见
#      `docs/9.20*记录.md`。
const CUE_STAR4_SCYTHE_SKILL := "star4_scythe_skill"
const CUE_STAR4_PRIESTESS_SKILL := "star4_priestess_skill"
const CUE_STAR4_ARBITER_SKILL := "star4_arbiter_skill"
# 暗影法师 / 恐惧魔 / 魅魔 三条**共用一个素材** —— 源文件名就是三家并列
# （「四星暗影法师、四星恐惧魔、四星魅魔技能.mp3」）。
const CUE_STAR4_DARK_CASTERS_SKILL := "star4_dark_casters_skill"
# 下面三条的技能在模拟器里**没有 `skill_ready` 边沿**（不是施法型），所以不能靠
# 上面那条派发路径，各自在 BattleVfx 里挂真事件：寄生灵→寄生分身出现的那一刻；
# 自爆灵→死亡毒爆；死侍→绑定生效那一下（没绑到人就不响）。
const CUE_STAR4_PARASITE_SKILL := "star4_parasite_skill"
const CUE_STAR4_BOMB_SKILL := "star4_bomb_skill"
const CUE_STAR4_DEATH_SERVANT_SKILL := "star4_death_servant_skill"

const CUES := {
	CUE_UI_POPUP: "res://assets/audio/sfx/ui/popup.mp3",
	CUE_UI_CONFIRM: "res://assets/audio/sfx/ui/button_confirm.mp3",
	CUE_UI_REJECT: "res://assets/audio/sfx/ui/button_reject.mp3",
	CUE_UI_CURRENCY_GAIN: "res://assets/audio/sfx/ui/currency_gain.mp3",
	CUE_UI_CURRENCY_SPEND: "res://assets/audio/sfx/ui/currency_spend.mp3",

	CUE_SYNERGY_ACTIVATE: "res://assets/audio/sfx/prep/synergy_activate.mp3",
	CUE_SHOP_REFRESH: "res://assets/audio/sfx/prep/shop_refresh.mp3",
	CUE_SHOP_BUY: "res://assets/audio/sfx/prep/shop_buy.mp3",
	CUE_UNIT_SELL: "res://assets/audio/sfx/prep/unit_sell.mp3",
	CUE_STAR4_HUMAN_KING: "res://assets/audio/sfx/prep/star4_human_king.mp3",
	CUE_STAR4_GOD: "res://assets/audio/sfx/prep/star4_god.mp3",
	CUE_STAR4_UNDEAD_MOTHER: "res://assets/audio/sfx/prep/star4_undead_mother.mp3",
	CUE_STAR4_DARK: "res://assets/audio/sfx/prep/star4_dark.mp3",
	CUE_STAR4_DEFAULT: "res://assets/audio/sfx/prep/star4_default.mp3",
	CUE_STAR4_ARCHANGEL: "res://assets/audio/sfx/prep/star4_archangel.mp3",
	CUE_STAR4_DOOM: "res://assets/audio/sfx/prep/star4_doom.mp3",
	CUE_STAR4_GOD_SKILL: "res://assets/audio/sfx/prep/star4_god_skill.mp3",
	CUE_STAR4_UNDEAD_MOTHER_SKILL: "res://assets/audio/sfx/prep/star4_undead_mother_skill.mp3",
	CUE_STAR4_DARK_SKILL: "res://assets/audio/sfx/prep/star4_dark_skill.mp3",
	CUE_TREASURE_LINKAGE: "res://assets/audio/sfx/prep/treasure_linkage.mp3",
	CUE_TREASURE_CHOICE_OPEN: "res://assets/audio/sfx/prep/treasure_choice_open.mp3",

	CUE_BOSS_APPEAR: "res://assets/audio/sfx/battle/boss_appear.wav",
	CUE_HUMAN_KING_DEATH: "res://assets/audio/sfx/battle/human_king_death.mp3",
	CUE_BATTLE_VICTORY: "res://assets/audio/sfx/battle/battle_victory.mp3",
	CUE_BATTLE_DEFEAT: "res://assets/audio/sfx/battle/battle_defeat.mp3",
	CUE_HUMAN_KING_REWARD: "res://assets/audio/sfx/battle/human_king_reward.mp3",
	CUE_STAR4_SWORDSMAN_SKILL: "res://assets/audio/sfx/battle/star4_swordsman_skill.mp3",
	CUE_STAR4_ARCHER_SKILL: "res://assets/audio/sfx/battle/star4_archer_skill.wav",
	CUE_STAR4_AURORA_SKILL: "res://assets/audio/sfx/battle/star4_aurora_skill.mp3",
	CUE_STAR4_MAGE_SKILL: "res://assets/audio/sfx/battle/star4_mage_skill.mp3",
	CUE_STAR4_CLERIC_SKILL: "res://assets/audio/sfx/battle/star4_cleric_skill.mp3",
	CUE_STAR4_PRIEST_SKILL: "res://assets/audio/sfx/battle/star4_priest_skill.mp3",
	CUE_MERC_ARROW_RAIN_SKILL: "res://assets/audio/sfx/battle/merc_arrow_rain_skill.wav",
	CUE_MERC_BUBBLE_HOLY_SONG_SKILL: "res://assets/audio/sfx/battle/merc_bubble_holy_song_skill.mp3",
	# 9.20 第二批：7 条新增的四星技能音（素材全在 battle/ 下）。
	CUE_STAR4_SCYTHE_SKILL: "res://assets/audio/sfx/battle/star4_scythe_skill.mp3",
	CUE_STAR4_PRIESTESS_SKILL: "res://assets/audio/sfx/battle/star4_priestess_skill.mp3",
	CUE_STAR4_ARBITER_SKILL: "res://assets/audio/sfx/battle/star4_arbiter_skill.mp3",
	CUE_STAR4_DARK_CASTERS_SKILL: "res://assets/audio/sfx/battle/star4_dark_casters_skill.mp3",
	CUE_STAR4_PARASITE_SKILL: "res://assets/audio/sfx/battle/star4_parasite_skill.mp3",
	CUE_STAR4_BOMB_SKILL: "res://assets/audio/sfx/battle/star4_bomb_skill.mp3",
	CUE_STAR4_DEATH_SERVANT_SKILL: "res://assets/audio/sfx/battle/star4_death_servant_skill.mp3",

	CUE_MERC_SUMMON: "res://assets/audio/sfx/camp/merc_summon.mp3",
	CUE_UPGRADE_STONE_DRAW: "res://assets/audio/sfx/camp/upgrade_stone_draw.mp3",
	CUE_CARROT_FARM_UPGRADE: "res://assets/audio/sfx/camp/carrot_farm_upgrade.wav",
	CUE_HARVEST_TECH_UPGRADE: "res://assets/audio/sfx/camp/harvest_tech_upgrade.mp3",

	CUE_CHAT_ALERT: "res://assets/audio/sfx/ui/chat_alert.wav",
	CUE_ROOM_SEAT_CHANGE: "res://assets/audio/sfx/ui/room_seat_change.wav",
	CUE_FORMATION_HIT: "res://assets/audio/sfx/battle/formation_hit.mp3",
	CUE_ENEMY_FORMATION_HIT: "res://assets/audio/sfx/battle/enemy_formation_hit.mp3",
	CUE_ROOM_READY_SWITCH: "res://assets/audio/sfx/ui/room_ready_switch.mp3",
	CUE_PROFILE_SAVE: "res://assets/audio/sfx/ui/profile_save.mp3",
	CUE_SETTINGS_SWITCH: "res://assets/audio/sfx/ui/settings_switch.mp3",
	CUE_VOICE_SWITCH: "res://assets/audio/sfx/ui/voice_switch.mp3",
}

# 每条 cue 的最小重触发间隔（毫秒）。缺省是 RETRIGGER_GUARD_MSEC。
#
# 9.17 反馈：**聊天新信息 / 朋友申请 10 秒内只触发一次**，触发满 10 秒后
# 再有新信息 / 新申请才会再响。这是个「节流窗口」，不是去重 ——
# 所以放在服务里按 cue 记时间戳，而不是散到「谁在监听消息」的那几处：
# 散出去的结果是私聊一处、朋友申请另一处，两处各响一遍，10 秒内听两下。
const THROTTLE_MSEC_BY_CUE := {
	CUE_CHAT_ALERT: 10_000,
}

# 四星音效按棋子分流。9.17 起是 5 条（人王 / 神王·大天使共用 / 母灵 /
# 黑龙·末日守卫共用 / 其他）；9.18 用户给了「战斗、特效」一批素材，于是
# 大天使（god_archangel）与末日守卫（dark_doom）从「神 / 暗」分组里拆出，
# 各自独立成 CUE_STAR4_ARCHANGEL / CUE_STAR4_DOOM。
#
# ⚠️ 9.19 修正：**9.18 那一批素材全部是「技能释放」音，不是合成音**
# （源目录 `音乐/0918/战斗、特效/` 五个文件全部叫「…技能释放」，一个合成音都没有）。
# 而 STAR4_CUES 是**合成**分发表，于是大天使 / 末日守卫的合成音也被顶成了技能音
# —— 与神王 / 母灵 / 黑龙同类问题。9.17 时这两家合成音**复用 god / dark 文件**
# （见上「神王·大天使共用」「黑龙·末日守卫共用」），故 9.19 把它们的合成音
# 回滚到 CUE_STAR4_GOD / CUE_STAR4_DARK（二者已是 9.18 前的原合成音）；
# 各自的技能音仍走 STAR4_SKILL_CUES 里的 CUE_STAR4_ARCHANGEL / CUE_STAR4_DOOM。
#
# **用 `def.id` 判定，不用 `def.name`**：客机路径的名字会被
# `DataRegistry.canonicalize_unit_display_names()` 按本地化覆写，而 id 永远稳定。
# 战斗里释放技能时的触发点在 `scenes/battle/BattleVfx.gd`，门控「自身棋子」才响。
const STAR4_CUES := {
	"human_king": CUE_STAR4_HUMAN_KING,
	"god_archangel": CUE_STAR4_GOD,
	"god_king": CUE_STAR4_GOD,
	"undead_mother": CUE_STAR4_UNDEAD_MOTHER,
	"dark_dragon": CUE_STAR4_DARK,
	"dark_doom": CUE_STAR4_DARK,
}

# 战斗里「自身棋子释放技能」时用的四星音。9.18「战斗、特效」那批素材**全部**归这里：
# 神王 / 母灵 / 黑龙走 `*_skill` 副本，大天使 / 末日守卫走各自的 archangel / doom 文件，
# 人王 9.18 没给技能音，合成与技能共用唯一素材。
# 见 9.19「合成音与战斗技能音分离」说明：合成走 STAR4_CUES（默认），
# 技能走本表（star4_cue_for(unit_id, true)）。
const STAR4_SKILL_CUES := {
	"human_king": CUE_STAR4_HUMAN_KING,
	"god_archangel": CUE_STAR4_ARCHANGEL,
	"god_king": CUE_STAR4_GOD_SKILL,
	"undead_mother": CUE_STAR4_UNDEAD_MOTHER_SKILL,
	"dark_dragon": CUE_STAR4_DARK_SKILL,
	"dark_doom": CUE_STAR4_DOOM,
	# 9.19 第二批：**施法型**的四星技能音。它们的技能有 skill_cd、走 skill_ready
	# 节拍，所以和上面六家共用同一个派发点（BattleVfx._play_skill_cast_vfx）。
	# 神侍与天使共用一条素材 —— 用户给的命名就是「四星神侍、四星天使技能释放」。
	"human_swordsman": CUE_STAR4_SWORDSMAN_SKILL,
	"human_mage": CUE_STAR4_MAGE_SKILL,
	"god_priest": CUE_STAR4_PRIEST_SKILL,
	"god_angel": CUE_STAR4_PRIEST_SKILL,
	# 9.20 第二批（`音乐/0920`）。前六条是「施法型」，靠上面那条 skill_ready
	# 上升沿派发；后三条的技能在模拟器里没有上升沿，由 BattleVfx 的真事件触发
	# （见 CUE_STAR4_PARASITE_SKILL 那段注释）。三条特殊音放在**同一张表**里，
	# 是因为它们的归属与星级门控跟施法型完全一致（自身/友军 + 四星），
	# 差别只在「谁来调 star4_cue_for(uid, true)」。
	"dark_scythe": CUE_STAR4_SCYTHE_SKILL,
	"god_priestess": CUE_STAR4_PRIESTESS_SKILL,
	"god_arbiter": CUE_STAR4_ARBITER_SKILL,
	"dark_mage": CUE_STAR4_DARK_CASTERS_SKILL,
	"dark_fear": CUE_STAR4_DARK_CASTERS_SKILL,
	"dark_suc": CUE_STAR4_DARK_CASTERS_SKILL,
	"undead_parasite": CUE_STAR4_PARASITE_SKILL,
	"undead_bomb": CUE_STAR4_BOMB_SKILL,
	"human_death_servant": CUE_STAR4_DEATH_SERVANT_SKILL,
}

# 9.19 第二批：**攻击触发型**的四星技能音。
#
# 这三家的「技能」不是施法，而是普攻的第 N 次触发（极光射手是每次都触发），
# 模拟器里根本没有 skill_ready 边沿可挂（见 BattleSimulator._step_team:636/640
# 与 _perform_attack:697）。派发点因此放在 BattleVfx._play_attack_unit_procedural
# ——那里已经用 `_attack_skill_vfx_ready()` 判过 `attack_count % every == 0`，
# 只有**真的触发**的那一次才会走到。
const STAR4_ATTACK_SKILL_CUES := {
	"human_archer": CUE_STAR4_ARCHER_SKILL,
	"human_cleric": CUE_STAR4_CLERIC_SKILL,
	"god_aurora": CUE_STAR4_AURORA_SKILL,
}

# 9.19 第二批：佣兵专属技能音。
#
# **独立成表而不是并进 STAR4_SKILL_CUES**：佣兵永远到不了四星
# （`EconomyLedger._use_upgrade_stone` 会拒），并进去就等于要求调用方
# 叠一个永远为假的 `star == 4` 判定，结果是一条永远不响的音。
# 这三条只判「自身棋子」。
const MERC_SKILL_CUES := {
	"merc_sagittarius_rain": CUE_MERC_ARROW_RAIN_SKILL,
	"merc_pisces_bubble": CUE_MERC_BUBBLE_HOLY_SONG_SKILL,
	"merc_virgo_heal": CUE_MERC_BUBBLE_HOLY_SONG_SKILL,
}


# --- 状态 -------------------------------------------------------------------

static var _voices: Array[AudioStreamPlayer] = []
static var _next_voice := 0
# path -> AudioStream。load() 本身有资源缓存，这里再存一份是为了改完 loop 标志后
# 不必每次重新取 —— 改过的实例不会回写缓存，不存就会每次重算一遍。
static var _streams: Dictionary = {}
static var _last_play_msec: Dictionary = {}
static var _play_counts: Dictionary = {}
static var _watching := false

# 循环音那一份状态（见 start_loop / stop_loop）。
static var _loop_player: AudioStreamPlayer
static var _loop_path := ""
# 当前循环的 cue id（looping_cue() 读它）。和 _loop_path 分开存：
# 「同一首不重启」要比路径，而门禁/排障要看的是 cue id，两者不是一回事。
static var _loop_cue := ""
static var _loop_streams: Dictionary = {}
# 循环音**真的起播过**几次。只有「播放器已在树里、且真的调了 play()」才 +1。
# 见 loop_start_count() 与 start_loop() 的「冷启动窗口」说明。
static var _loop_start_count := 0

# 代币监视器的基线。`_currency_ready` 为 false 时只记基线不出声 ——
# 冷启动那一刻 gold 从 0 变 100 不是一笔收支。
static var _last_gold := 0
static var _currency_ready := false


# --- 安装 -------------------------------------------------------------------

# 由 Main._ready() 调一次，幂等。
#
# play() 在没装的情况下也会自己把播放器补上，所以「Main 忘了调」的最坏后果是
# 第一个音效之前多建一次节点、以及代币监视器不工作，不是整条链静音。
static func install() -> void:
	_ensure_voices()
	_watch_currency()
	resync_currency_baseline()


static func is_installed() -> bool:
	return _watching


static func _tree() -> SceneTree:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree


# 代币监视器靠 SceneTree.process_frame，而不是自己造一个带 _process 的 Node：
# 少一个自定义脚本、少一处内部类，也就少了「内部类能不能调到外层 static」这种
# 只能靠试才知道的写法。把 static 函数接成信号回调在本仓已有先例
# （UiFeedback.install() 就是把 _on_action_resolved 接上 action_resolved 的）。
static func _watch_currency() -> void:
	if _watching:
		return
	var tree := _tree()
	if tree == null:
		return
	if not tree.process_frame.is_connected(_poll_currency):
		tree.process_frame.connect(_poll_currency)
	_watching = true


# --- 播放 -------------------------------------------------------------------

# 播一条 cue。返回是否真的发声 —— 静音开关关着、cue 未登记、资源缺失或
# 撞上重触发保护时返回 false。
#
# **返回值是给门禁和排障用的，不要拿它当业务判据。** 音效是表现，
# 业务成不成功在调用它之前就已经定下来了。
static func play(cue: String, volume_db := 0.0) -> bool:
	if not Presentation.ui_sound_allowed():
		return false
	var path := str(CUES.get(cue, ""))
	if path.is_empty():
		push_warning("SfxService.play: 未登记的 cue %s" % cue)
		return false
	var now := Time.get_ticks_msec()
	# 每条 cue 的窗口取「40 ms 重触发保护」与「本 cue 自己的节流」里更长的那个。
	# 默认那条 40 ms 挡的是「同一帧里多条路径都判定成功」；chat_alert 的 10 s
	# 挡的是「10 秒内收到一串消息只提醒一次」（见 THROTTLE_MSEC_BY_CUE）。
	var guard := maxi(RETRIGGER_GUARD_MSEC, int(THROTTLE_MSEC_BY_CUE.get(cue, 0)))
	if now - int(_last_play_msec.get(cue, -guard)) < guard:
		return false

	var stream := _stream_for(path)
	if stream == null:
		return false
	var voice := _take_voice()
	if voice == null:
		return false
	_last_play_msec[cue] = now
	_play_counts[cue] = int(_play_counts.get(cue, 0)) + 1
	voice.stream = stream
	voice.set_meta("sfx_cue", cue)
	voice.volume_db = volume_db
	voice.play()
	return true


static func _stream_for(path: String) -> AudioStream:
	if _streams.has(path):
		return _streams[path]
	var stream := load(path) as AudioStream
	if stream == null:
		push_warning("SfxService: 音效读取失败 %s" % path)
		return null
	# 音效一律不循环。导入设置里可能被勾上 loop，那样一条 0.3 s 的按钮音
	# 会变成永不停的嗡鸣 —— 显式关掉，不依赖导入预设。
	if stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = false
	elif stream is AudioStreamWAV:
		(stream as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_DISABLED
	_streams[path] = stream
	return stream


# 轮转发声：挑一个空闲的；都在响就抢最老的那一路。
# 用池而不是单播放器，是因为 AOE 多杀、连点按钮这些场景天生要叠音。
static func _take_voice() -> AudioStreamPlayer:
	if not _ensure_voices():
		return null
	for i in VOICE_COUNT:
		var idx := (_next_voice + i) % VOICE_COUNT
		var voice: AudioStreamPlayer = _voices[idx]
		if not _voice_usable(voice):
			continue
		if not voice.playing:
			_next_voice = (idx + 1) % VOICE_COUNT
			return voice
	var fallback: AudioStreamPlayer = _voices[_next_voice]
	_next_voice = (_next_voice + 1) % VOICE_COUNT
	return fallback if _voice_usable(fallback) else null


# 能不能拿来播。**「在树里」这一条不能省。**
#
# 播放器是延迟挂载的（见 `_ensure_voices`），所以存在「节点已建好但还没进树」
# 的一帧窗口；对没进树的播放器调 `play()` 会打印
# "Playback can only happen when a node is inside the scene tree" 并静默失败 ——
# 也就是说调用方以为响了、其实没有。在这里挡掉，让它干净地算作「这一声没发出去」。
static func _voice_usable(voice: AudioStreamPlayer) -> bool:
	return voice != null and is_instance_valid(voice) and voice.is_inside_tree()


# 建播放器池。**挂载一律走 `add_child.call_deferred`，不做同步 add_child。**
#
# `install()` 的调用点是 `Main._ready()`，而那一刻 root 正处在
# `add_child(Main) -> _propagate_ready()` 里（`data.blocked > 0`）。此时同步
# `add_child()` 会**直接失败**并打印
# "Parent node is busy setting up children, `add_child()` failed"。
#
# 为什么这条值得单独写一段：`add_child()` 返回 void，没有异常可 catch，
# GDScript 侧看不出任何异常 —— 于是 8 个播放器一个都没进树，而**整条音效链
# 是静默的**：`play()` 照样返回 true、门禁计数照样 +1，只有引擎日志里有 8 行
# ERROR。9.17 那一版就是这么写出来的，是 `audio_sfx_check` 的「播放器必须在树里」
# 那条断言把它抓出来的（第一版门禁只验返回值，是绿的）。
#
# 没有公开 API 能查 `data.blocked`，所以也不做「先试同步、失败再延迟」——
# 那会在每次冷启动的日志里留 8 行 ERROR，真出问题时反而淹掉有意义的报错。
# 延迟一个空闲帧的代价是「App 第一帧内发出的音效会被丢掉」，实际为零：
# 音效都由用户操作或业务事件触发，不可能与 `Main._ready()` 同帧。
static func _ensure_voices() -> bool:
	if _voices.size() == VOICE_COUNT and _voices_are_alive():
		return true
	var tree := _tree()
	if tree == null:
		return false
	_voices.clear()
	for i in VOICE_COUNT:
		var name := "%s%d" % [VOICE_PREFIX, i]
		var voice := tree.root.get_node_or_null(name) as AudioStreamPlayer
		if voice == null or not is_instance_valid(voice):
			voice = AudioStreamPlayer.new()
			voice.name = name
			voice.bus = SFX_BUS if AudioServer.get_bus_index(SFX_BUS) >= 0 else "Master"
			# 页面切换、暂停都不该把提示音掐断（同 UiFeedback 的理由）。
			voice.process_mode = Node.PROCESS_MODE_ALWAYS
			tree.root.add_child.call_deferred(voice)
		_voices.append(voice)
	return true


static func _voices_are_alive() -> bool:
	for voice in _voices:
		if not is_instance_valid(voice):
			return false
	return true


static func stop_cue(cue: String) -> void:
	for voice in _voices:
		if is_instance_valid(voice) and str(voice.get_meta("sfx_cue", "")) == cue:
			voice.stop()

static func stop_all() -> void:
	for voice in _voices:
		if voice != null and is_instance_valid(voice):
			voice.stop()
	stop_loop()


# 四星音按棋子分流。9.19 起区分两种场景：
#   * is_skill = false（默认）：备战页**合成 / 升星**时刻，指向各家原合成音；
#   * is_skill = true：战斗里**自身棋子释放技能**时刻，指向 9.18 新素材
#     （STAR4_SKILL_CUES）。门控「自身棋子」在调用方（BattleVfx）做，
#     这里只负责按场景选对 cue。
static func star4_cue_for(unit_id: String, is_skill := false) -> String:
	if is_skill:
		return str(STAR4_SKILL_CUES.get(unit_id, CUE_STAR4_DEFAULT))
	return str(STAR4_CUES.get(unit_id, CUE_STAR4_DEFAULT))


# 9.19 第二批：**攻击触发型**四星技能音。返回空串 = 这只棋子的技能不是
# 「第 N 次普攻触发」这一类，调用方据此直接跳过（不要退回默认音 ——
# 那会让没素材的棋子也跟着响）。
static func attack_skill_cue_for(unit_id: String) -> String:
	return str(STAR4_ATTACK_SKILL_CUES.get(unit_id, ""))


# 9.19 第二批：佣兵专属技能音。同样返回空串表示这只棋子没有专属素材。
static func merc_skill_cue_for(unit_id: String) -> String:
	return str(MERC_SKILL_CUES.get(unit_id, ""))


# --- 循环音（9.17 第二批：己方法阵受击）--------------------------------------

# 播一条 cue 并让它一直循环，直到 stop_loop()。
#
# **为什么单独一路播放器，而不是复用 play() 的池**：`_stream_for()` 会显式
# **关掉** loop（那里的注释写了理由：一条 0.3 s 的按钮音被导入预设勾上 loop
# 就是永不停的嗡鸣）。循环是这一条音**要**的语义，不能靠改那条全局策略去满足，
# 所以这里自己取一份开着 loop 的流，并用一个专用播放器独占它。
#
# 返回是否真的开始循环 —— 静音开关关着、cue 未登记、资源缺失时返回 false。
static func start_loop(cue: String) -> bool:
	if not Presentation.ui_sound_allowed():
		return false
	var path := str(CUES.get(cue, ""))
	if path.is_empty():
		push_warning("SfxService.start_loop: 未登记的 cue %s" % cue)
		return false
	var stream := _loop_stream_for(path)
	if stream == null:
		return false
	var player := _ensure_loop_player()
	if player == null:
		return false
	if _loop_path == path and player.playing:
		return true
	_loop_path = path
	_loop_cue = cue
	player.stream = stream
	_play_loop_when_ready(player)
	return true


# 起播循环音。**循环播放器的 `play()` 只能从这里发出。**
#
# 播放器是 `add_child.call_deferred` 挂到 root 的（同 voices，理由见 `_ensure_voices`），
# 所以**每个进程里的第一次 `start_loop()` 天生落在「节点已建好、还没进树」的那一帧**。
# 对没进树的播放器调 `play()` 会打印
# "Playback can only happen when a node is inside the scene tree" 并**静默失败**。
#
# 后果很隐蔽，值得写清楚，因为四个判据会同时骗人：`start_loop()` 返回 true、
# `looping_cue()` 记下了 cue、计数器也 +1、两帧后 `loop_player_ready()` 还是 true
# （那时播放器已经挂上去了）。全都绿，而**每局第一次的己方法阵受击音根本没响** ——
# 第二场起播放器已在树里，就正常了。产品里表现为「第一次没声、后面都有」，
# 不专门连打两场看不出来（9.17 第三轮反馈就是这一条）。
#
# 所以这里不把这一声丢掉，而是**等它进树再起**（同 MusicService._sync 的先例）：
# 已经在树里就当场起；不在就挂 `ready`（一次性）补一次。
static func _play_loop_when_ready(player: AudioStreamPlayer) -> void:
	if player.is_inside_tree():
		_start_loop_playback(player)
		return
	if not player.ready.is_connected(_on_loop_player_ready):
		player.ready.connect(_on_loop_player_ready, CONNECT_ONE_SHOT)


# `ready` 到了 = 播放器已经进树。**但要先确认这一声还没被取消。**
#
# 从「请求起播」到「进树」隔着一帧，而结算序列完全可能在这中间走到某条早退分支
# 并调了 `stop_loop()`（水晶演出中途退出战斗就是）。那时 `_loop_cue` 已被清空，
# 再补起播就会留下一路**没人收口的循环音**：播放器挂在 root 下，场景没了它照样响。
static func _on_loop_player_ready() -> void:
	if _loop_cue.is_empty():
		return
	var player := _loop_player
	if player == null or not is_instance_valid(player):
		return
	_start_loop_playback(player)


static func _start_loop_playback(player: AudioStreamPlayer) -> void:
	# 这一层守卫不是「防御性编程」，是本文件已经踩过的那个坑：没进树的 play()
	# 会静默失败。它同时给门禁留了一个判据 —— 只有真的起了播，计数才动。
	if not player.is_inside_tree():
		return
	player.play()
	_loop_start_count += 1


static func stop_loop() -> void:
	_loop_path = ""
	_loop_cue = ""
	if _loop_player != null and is_instance_valid(_loop_player):
		_loop_player.stop()


# 当前正在循环的 **cue id**，没有在循环时是空串。
static func looping_cue() -> String:
	return _loop_cue


# 循环音**真的起播过**几次（不是「请求被接受」几次）。
#
# 为什么要和 `start_loop()` 的返回值分开：两者在坏实现上会分叉，而分叉**没有任何
# 其它迹象**。9.17 第二批那版就是「在还没进树的播放器上调 play()」—— 引擎只打印
# "Playback can only happen when a node is inside the scene tree" 然后静默失败，
# 而 `start_loop()` 照样返回 true、`looping_cue()` 照样记着 cue、
# 两帧后 `loop_player_ready()` 也照样是 true（那时播放器已经挂上去了）。
# 三个判据全绿、产品却一声不响 —— 只能靠「到底起播了几次」这个计数器分开。
static func loop_start_count() -> int:
	return _loop_start_count


# cue 的时长（秒）。读不到返回 0.0。
#
# 给「等胜负 BGM 播完再切界面」用（9.17 反馈第 3 条）：调用方拿它和
# RESULT_DISPLAY_SECONDS 取 max，而不是自己写一个「够长」的常数 ——
# 那种写法换了素材就对不上，而且没人会发现。
static func cue_length(cue: String) -> float:
	var path := str(CUES.get(cue, ""))
	if path.is_empty():
		return 0.0
	var stream := _stream_for(path)
	if stream == null:
		return 0.0
	return stream.get_length()


static func _ensure_loop_player() -> AudioStreamPlayer:
	if _loop_player != null and is_instance_valid(_loop_player) and _loop_player.is_inside_tree():
		return _loop_player
	var tree := _tree()
	if tree == null:
		return null
	var existing := tree.root.get_node_or_null(LOOP_PLAYER_NAME) as AudioStreamPlayer
	if existing != null and is_instance_valid(existing):
		_loop_player = existing
		return _loop_player
	var player := AudioStreamPlayer.new()
	player.name = LOOP_PLAYER_NAME
	player.bus = SFX_BUS if AudioServer.get_bus_index(SFX_BUS) >= 0 else "Master"
	player.process_mode = Node.PROCESS_MODE_ALWAYS
	tree.root.add_child.call_deferred(player)
	_loop_player = player
	return _loop_player


# 循环播放器是不是已经挂进树。理由同 voices_ready()：延迟挂载期间
# `play()` 会打印 "Playback can only happen when a node is inside the scene tree"
# 并**静默失败**，调用方以为响了其实没有。
static func loop_player_ready() -> bool:
	if _loop_player == null or not is_instance_valid(_loop_player):
		return false
	return _loop_player.is_inside_tree()


static func _loop_stream_for(path: String) -> AudioStream:
	if _loop_streams.has(path):
		return _loop_streams[path]
	var stream := load(path) as AudioStream
	if stream == null:
		push_warning("SfxService: 循环音读取失败 %s" % path)
		return null
	if stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = true
	elif stream is AudioStreamWAV:
		(stream as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD
	_loop_streams[path] = stream
	return stream


# --- 代币收支监视器 ---------------------------------------------------------

# 口径：**金币（GameState.gold）的任何增减都响**。
#
# 用「每帧比对」而不是在十几处 `gold -= cost` 旁边各插一行：
#   * 局内金币的写点散在 PrepBoardController / PrepFlowController /
#     TreasureChoicePanel / GameState / NetworkService / Main 六七个文件里，
#     逐点插必然漏掉以后新加的那一处；
#   * 战后结算（Main.gd 的 `settle_post_battle_gold`）与联机权威同步是整块赋值，
#     逐点插正好覆盖不到 —— 而「战斗结算飘金币」恰恰是最该响的一声。
#
# **钻石不在这里**：钻石是服务端钱包（`AccountManager.fetch_wallet`），
# 各页面自己 fetch 自己存，没有中心状态可盯。商城页那笔在收据落地处单独接。
static func _poll_currency() -> void:
	if not is_instance_valid(GameState):
		return
	var gold := int(GameState.gold)
	if not _currency_ready:
		_last_gold = gold
		_currency_ready = true
		return
	if gold == _last_gold:
		return
	var delta := gold - _last_gold
	_last_gold = gold
	play(CUE_UI_CURRENCY_GAIN if delta > 0 else CUE_UI_CURRENCY_SPEND)


# 把基线对齐到当前值**且不出声**。
#
# 给「整块替换状态」用：重开一局（GameState.reset_run）与读档（SaveManager.load_run）
# 都不是某笔收支，它们是「换了另一本账」。不对齐的话，上一局剩 300 金、新局从 100
# 起会响一声「扣钱」。
static func resync_currency_baseline() -> void:
	_currency_ready = false
	if is_instance_valid(GameState):
		_last_gold = int(GameState.gold)
	_currency_ready = true


# --- 门禁接缝 ---------------------------------------------------------------

static func play_count(cue: String) -> int:
	return int(_play_counts.get(cue, 0))


static func total_play_count() -> int:
	var total := 0
	for key in _play_counts.keys():
		total += int(_play_counts[key])
	return total


static func cue_path(cue: String) -> String:
	return str(CUES.get(cue, ""))


static func cue_ids() -> Array:
	return CUES.keys()


static func reset_counters_for_check() -> void:
	_play_counts.clear()
	_last_play_msec.clear()
	_loop_start_count = 0


# 8 个播放器是不是都已经挂进树了。
#
# 存在的理由就是上面 `_ensure_voices` 那段讲的坑：**「池建好了」不等于
# 「能发声」**。延迟挂载期间 `_voices.size() == VOICE_COUNT` 成立、节点也
# is_instance_valid，但一个都发不出声。门禁必须先等到这里为 true 再断言静音门，
# 否则它测的是一个恒不发声的实现。
static func voices_ready() -> bool:
	if not _ensure_voices():
		return false
	if _voices.size() != VOICE_COUNT:
		return false
	for voice in _voices:
		if not _voice_usable(voice):
			return false
	return true


# 收尾用：断开代币监视器、释放播放器池与流缓存。
#
# **产品运行时不调**（服务是常驻的，没有「用完要关」这回事），只给 headless
# 检查收尾。调它的收益是可量化的：不调时日志尾巴固定是
# "20 ObjectDB instances were leaked" + "4 resources still in use"；
# 调了之后节点和流缓存都干净了。
#
# **但仍会偶发残留 8 个 ObjectDB + 4 条资源 —— 这一条修不掉，别去修。**
# 实测 5 跑漏 2 跑，且永远是「8+4」或「什么都没有」两种，没有中间值。
# `--verbose` 显示漏的是 `AudioStreamPlaybackMP3` 与对应的 `AudioStreamMP3`：
# 那是**音频服务器混音线程**持有的播放对象，释放时机由那条线程决定，
# GDScript 侧没有任何 API 能催它 flush（`stop()` 只能让它停，不能让它放）。
# 所以这是 headless 退出时机与混音线程的竞态，不是本服务的泄漏；
# 判断依据是它**不影响 CHECK_RESULT**（94 项照过），且产品路径根本不调本函数。
static func shutdown() -> void:
	var tree := _tree()
	if tree != null and tree.process_frame.is_connected(_poll_currency):
		tree.process_frame.disconnect(_poll_currency)
	_watching = false
	_currency_ready = false
	# 整批 stop 完再整批 free，不要 stop 一个 free 一个。
	#
	# 这个顺序是能**减少**残留次数的那一版（逐个拆更差），但它治不了根：
	# 残留的 `AudioStreamPlayback` 归混音线程管，见上面 shutdown 的说明。
	# 写成整批而不是逐个，也顺带让「拆节点」集中在一次迭代里，好读。
	for voice in _voices:
		if voice != null and is_instance_valid(voice):
			voice.stop()
	if _loop_player != null and is_instance_valid(_loop_player):
		_loop_player.stop()
	for voice in _voices:
		if voice == null or not is_instance_valid(voice):
			continue
		# 用 free() 而不是 queue_free()：门禁是「检查完就退出」的，
		# 延迟释放根本没机会 flush。
		voice.free()
	if _loop_player != null and is_instance_valid(_loop_player):
		_loop_player.free()
	_loop_player = null
	_loop_path = ""
	_loop_cue = ""
	_loop_streams.clear()
	_voices.clear()
	_streams.clear()
	_last_play_msec.clear()
	_play_counts.clear()
