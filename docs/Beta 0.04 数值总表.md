# Beta 0.04 数值总表

更新时间：2026-06-05

本文档只记录当前项目中的基础数值和战斗倍率入口，方便快速读取与调参。  
数据来源：

- `data/units/race_units.json`
- `data/boss/bosses.json`
- `data/pve/pve_monsters.json`
- `data/formation/formation_allies.json`
- `scripts/boss/BossService.gd`
- `scripts/pve/PveService.gd`
- `scripts/units/UnitFactory.gd`

## 全局数值规则

| 类型 | 当前规则 |
|---|---|
| 棋子星级 | 最多 3 星 |
| 棋子 1 星 | HP / ATK / DEF 使用基础值 |
| 棋子 2 星 | HP / ATK / DEF = 基础值 x 1.5 |
| 棋子 3 星 | HP / ATK / DEF = 基础值 x 2.25 |
| Boss 整体倍率 | HP / ATK / DEF / skill_damage 额外 x 1.5 |
| Boss 成长 | 每完成 1 次 Boss 后：HP x 1.45，ATK x 1.35，DEF x 1.30，skill_damage x 1.45 |
| PVE 小怪成长 | 每完成 1 次 PVE 后：HP x 1.10，ATK x 1.08，DEF x 1.05，skill_damage x 1.08 |
| PVP 回合 | 第 6 / 12 / 18 / 21 回合为玩家对战回合；Demo 单机无联机对手时改为随机小怪战，联机且有对手时才进入 PVP |
| 法阵友军 | 第 21 回合最终战根据法阵 HP 召唤，不占普通棋子上限 |

## Boss 数值

Boss 战斗实际值 = 基础值 x Boss 整体倍率 x Boss 成长。  
当前 Boss 整体倍率为 x1.5。下表同时列出基础值与第 1 次 Boss 战的实际值。

| ID | 名称 | 元素 | 基础 HP | 基础 ATK | 基础 DEF | 第 1 次 Boss HP | 第 1 次 Boss ATK | 第 1 次 Boss DEF | 攻速 | 射程 | 移速 | 技能 |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| boss_meteor_caster | 天罚投星者 | sky | 1100 | 68 | 10 | 1650 | 102 | 15 | 0.85 | 4 | 2.8 | element_meteor |
| boss_thunder_core | 雷怒核心 | sky | 1250 | 55 | 15 | 1875 | 83 | 23 | 0.75 | 4 | 2.5 | overload_counter |
| boss_mirror_lord | 镜像魔君 | ren | 900 | 70 | 8 | 1350 | 105 | 12 | 0.95 | 1 | 3.0 | mirror_clone |
| boss_holy_priest | 圣愈祭司 | ren | 1000 | 45 | 10 | 1500 | 68 | 15 | 0.80 | 4 | 2.6 | holy_purify |
| boss_rage_beast | 狂战灾兽 | land | 950 | 50 | 5 | 1425 | 75 | 8 | 1.00 | 1 | 3.2 | rage_stack |
| boss_blood_demon | 血怒魔王 | ren | 1300 | 55 | 12 | 1950 | 83 | 18 | 0.85 | 1 | 3.0 | blood_rage |
| boss_soul_devourer | 噬魂领主 | ren | 1050 | 72 | 10 | 1575 | 108 | 15 | 0.90 | 1 | 3.0 | soul_devour |
| boss_twin_gate | 双生守门人 | land | 700 | 58 | 10 | 1050 | 87 | 15 | 0.90 | 1 | 3.0 | twin_revive |
| boss_apocalypse | 灭世裁决者 | sky | 1400 | 60 | 14 | 2100 | 90 | 21 | 0.75 | 4 | 2.6 | apocalypse_charge |

### Boss 技能参数

| ID | 技能参数 |
|---|---|
| boss_meteor_caster | skill_cd 6.0，skill_damage 120；第 1 次 Boss 战实际 skill_damage 180 |
| boss_thunder_core | hit_threshold 8，skill_damage 150；第 1 次 Boss 战实际 skill_damage 225，interrupt_chance 0.25 |
| boss_mirror_lord | 每少 25% 血量召唤分身，分身 HP 30%，分身 ATK 40%，分身 DEF 0 |
| boss_holy_priest | skill_cd 8.0，heal_pct 0.12，shield_pct 0.10 |
| boss_rage_beast | 每次攻击 ATK +3%，攻速 +3%，最多 20 层 |
| boss_blood_demon | 35% HP 触发，ATK +40%，攻速 +30%，吸血 10% |
| boss_soul_devourer | 击杀回复 15% 最大生命，ATK 叠加 +10% |
| boss_twin_gate | 双生体死亡后等待 5.0 秒；倒计时结束时要求另一只双生体仍存活才能复活，复活 HP 30%，每个双生体最多复活 1 次；两只全部死亡时立即取消该组复活队列 |
| boss_apocalypse | skill_cd 10.0，蓄能 2.0 秒，蓄能护盾 10% 最大生命，完成后造成 ATK x 2.5 真实伤害 |

噬魂领主 Boss (`boss_soul_devourer`) 显示模型使用 `boss_soul_devourer_animated.tscn`，`idle` / `attack` / `run` 均从第 30 帧开始；Boss 数值与战斗逻辑未修改。

双生守门人 Boss (`boss_twin_gate`) 使用 `model_by_element`：地属性显示 `boss_twin_gate_land_animated.tscn`，天属性显示 `boss_twin_gate_sky_animated.tscn`；两套 `idle` / `attack` / `run` 均从第 30 帧开始，双生数值、生成与复活逻辑未修改。

## 普通棋子基础数值

下表为 1 星基础值。2 星和 3 星只放大 HP / ATK / DEF，其他字段不随星级放大。

| ID | 名称 | 种族 | 元素 | 阶 | 费用 | HP | ATK | DEF | 攻速 | 射程 | 移速 | 暴击 | 暴伤 | 技能 |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| god_priest | 神侍 | god | ren | 1 | 2 | 320 | 28 | 4 | 0.95 | 4 | 3.2 | 0.05 | 1.5 | lowest_ally_heal |
| god_priestess | 大祭司 | god | ren | 1 | 2 | 300 | 24 | 4 | 0.90 | 4 | 3.15 | 0.05 | 1.5 | nearest_ally_bless |
| god_guard | 光之卫士 | god | land | 2 | 3 | 760 | 42 | 14 | 0.75 | 1 | 3.0 | 0.05 | 1.5 | guardian_shield_taunt |
| god_aurora | 极光射手 | god | sky | 2 | 3 | 360 | 70 | 5 | 1.10 | 4 | 3.2 | 0.10 | 1.6 | true_damage_attack |
| god_angel | 天使 | god | sky | 2 | 3 | 540 | 44 | 8 | 0.95 | 4 | 3.25 | 0.08 | 1.6 | nearby_ally_heal_buff |
| god_arbiter | 裁决者 | god | land | 2 | 3 | 620 | 80 | 12 | 0.80 | 1 | 3.05 | 0.08 | 1.6 | judgement_strike |
| god_archangel | 大天使 | god | sky | 3 | 5 | 850 | 62 | 15 | 0.85 | 4 | 3.05 | 0.10 | 1.75 | random_ally_damage_reduction |
| god_king | 神王 | god | land | 3 | 5 | 900 | 95 | 16 | 0.88 | 1 | 3.0 | 0.12 | 1.75 | global_divine_blast |
| dark_imp | 魔童 | dark | ren | 1 | 2 | 280 | 34 | 4 | 1.05 | 1 | 3.35 | 0.05 | 1.5 | curse_attack |
| dark_mage | 暗影法师 | dark | sky | 1 | 2 | 260 | 44 | 3 | 0.90 | 4 | 3.25 | 0.05 | 1.5 | silence_bolt |
| dark_fear | 恐惧魔 | dark | land | 2 | 3 | 420 | 50 | 7 | 0.85 | 1 | 3.15 | 0.08 | 1.6 | fear |
| dark_queen | 痛苦女王 | dark | sky | 2 | 3 | 460 | 62 | 8 | 0.95 | 1 | 3.2 | 0.08 | 1.6 | same_target_damage_stack |
| dark_scythe | 偷袭者 | dark | ren | 2 | 3 | 390 | 68 | 6 | 1.15 | 1 | 3.55 | 0.12 | 1.6 | blink_low_def_backline |
| dark_suc | 魅魔 | dark | ren | 2 | 3 | 430 | 58 | 7 | 1.00 | 1 | 3.25 | 0.08 | 1.6 | stun |
| dark_doom | 末日守卫 | dark | land | 3 | 5 | 820 | 88 | 16 | 0.78 | 1 | 3.0 | 0.10 | 1.75 | shared_hp_link |
| dark_dragon | 黑龙 | dark | sky | 3 | 5 | 900 | 100 | 14 | 0.80 | 1 | 2.95 | 0.12 | 1.8 | black_hole |
| undead_small | 小灵 | undead | sky | 1 | 1 | 260 | 22 | 2 | 1.10 | 1 | 3.45 | 0.05 | 1.5 | none |
| undead_poison | 毒灵 | undead | ren | 1 | 2 | 260 | 30 | 4 | 1.00 | 1 | 3.3 | 0.05 | 1.5 | poison_attack |
| undead_parasite | 寄生灵 | undead | ren | 2 | 3 | 420 | 52 | 7 | 0.90 | 1 | 3.15 | 0.08 | 1.6 | parasite_on_kill |
| undead_spike | 刺灵 | undead | sky | 2 | 3 | 380 | 56 | 6 | 1.00 | 4 | 3.25 | 0.08 | 1.6 | defense_down_attack |
| undead_fly | 飞灵 | undead | sky | 2 | 3 | 340 | 48 | 5 | 1.20 | 1 | 3.55 | 0.10 | 1.6 | poison_attack |
| undead_bomb | 自爆灵 | undead | ren | 2 | 3 | 300 | 72 | 4 | 0.70 | 1 | 3.0 | 0.08 | 1.6 | death_poison_explosion |
| undead_titan | 巨甲灵 | undead | land | 2 | 3 | 700 | 35 | 16 | 0.65 | 1 | 2.8 | 0.05 | 1.5 | poison_reflect_armor_stack |
| undead_mother | 母灵 | undead | land | 3 | 5 | 780 | 84 | 12 | 0.82 | 4 | 3.0 | 0.10 | 1.75 | unique_death_execute |
| human_militia | 民兵 | human | land | 1 | 2 | 300 | 32 | 5 | 1.00 | 1 | 3.3 | 0.05 | 1.5 | attack_interrupt |
| human_merchant | 商人 | human | ren | 1 | 2 | 280 | 26 | 4 | 0.90 | 1 | 3.2 | 0.05 | 1.5 | post_battle_gold_by_star |
| human_archer | 弓箭手 | human | sky | 2 | 3 | 380 | 64 | 5 | 1.08 | 4 | 3.25 | 0.10 | 1.6 | every_fourth_combo |
| human_swordsman | 剑士 | human | land | 2 | 3 | 560 | 58 | 10 | 0.88 | 1 | 3.1 | 0.08 | 1.6 | front_cone_stun |
| human_mage | 法师 | human | sky | 2 | 3 | 360 | 60 | 5 | 0.00 | 4 | 3.15 | 0.08 | 1.6 | random_attribute_bolt |
| human_cleric | 牧师 | human | ren | 2 | 3 | 420 | 38 | 6 | 0.92 | 4 | 3.2 | 0.08 | 1.6 | every_fifth_group_heal |
| human_death_servant | 死侍 | human | land | 2 | 3 | 820 | 0 | 18 | 0.00 | 1 | 2.8 | 0.00 | 1.0 | left_neighbor_sacrifice |
| human_king | 人王 | human | ren | 3 | 5 | 310 | 32 | 4 | 0.32 | 1 | 1.2 | 0.07 | 1.8 | unique_king_growth |

## 普通棋子技能参数

| ID | 技能参数 |
|---|---|
| god_priest | skill_cd 4.0，heal_pct 0.06，cleanse_chance 0.25，model `res://assets/models/units/god_priest_halo_animated/god_priest_animated.tscn`，idle/attack/run 动作已接入 |
| god_priestess | skill_cd 6.0，atk_bonus 0.08，aspd_bonus 0.15，清除负面状态，model `res://assets/models/units/god_priestess_animated/god_priestess_animated.tscn` |
| god_guard | start_shield_pct 0.20，taunt_radius 180.0：周围敌人优先攻击自己，model `res://assets/models/units/god_guard_crystalbound/god_guard_crystalbound_animated.tscn` |
| god_aurora | true_damage_pct 0.18，model `res://assets/models/units/god_aurora_animated/god_aurora_animated.tscn` |
| god_angel | skill_cd 7.0，opening_cd 2.0，heal_pct 0.15，atk_bonus 0.10，aspd_bonus 0.15，清除负面状态，model `res://assets/models/units/god_angel_animated/god_angel_animated.tscn` |
| god_arbiter | skill_cd 2.0，damage_atk_pct 2.2，def_stack_pct 0.06，max_stacks 5，model `res://assets/models/units/god_arbiter_animated/god_arbiter_animated.tscn` |
| god_archangel | skill_cd 6.0，damage_reduction 0.50，duration 6.0，unique_on_board true，model `res://assets/models/units/god_archangel_animated/god_archangel_animated.tscn` |
| god_king | skill_cd 8.0，damage_atk_pct 1.6，max_hp_bonus_pct 0.08，unique_on_board true，model `res://assets/models/units/god_king_animated/god_king_animated.tscn` |
| dark_imp | attack_down 0.08，aspd_down 0.08，duration 4.0，max_stacks 2 |
| dark_mage | skill_cd 4.0，silence_sec 1.2，damage_atk_pct 1.7，model `res://assets/models/units/dark_mage_violet_necromancer/dark_mage_animated.tscn`，idle/attack/run 动作已接入 |
| dark_fear | skill_cd 6.0，fear_sec 1.5 |
| dark_queen | stack_damage 0.06，max_stacks 5 |
| dark_scythe | damage_atk_pct 2.0，refresh_on_kill true |
| dark_suc | skill_cd 5.0，stun_sec 1.0，model `res://assets/models/units/dark_suc_animated/dark_suc_animated.tscn`，idle/attack/run 动作已接入；attack 从第 150 帧后开始播放 |
| dark_doom | 连接最近非Boss敌人并策反为己方；双方共享受到的生命损失；连接目标或末日守卫死亡后清除连接，本回合不再释放；Boss免疫，unique_on_board true |
| dark_dragon | pull_sec 1.0，damage_atk_pct 2.2，unique_on_board true |
| undead_small | 无技能，model `res://assets/models/units/undead_small_animated/undead_small_animated.tscn`，idle/attack/run 动作已接入 |
| undead_poison | 攻击附带中毒 |
| undead_parasite | 普攻永久标记目标；标记目标死亡时召唤分身，clone_hp_pct 0.10，clone_atk_def_pct 0.50 |
| undead_spike | def_down_pct 0.10，duration 5.0，max_stacks 3 |
| undead_fly | dodge 0.25，攻击附带中毒 |
| undead_bomb | damage_atk_pct 2.5 |
| undead_titan | reflect_taken_damage_pct 0.12，armor_per_hit 2，max_stacks 10 |
| undead_mother | death_threshold 5，tier1_or_merc_chance 0.50，tier2_chance 0.35，tier3_chance 0.10，boss_max_hp_damage 0.20，unique_on_board true |
| human_militia | interrupt_chance 0.12，model `res://assets/models/units/human_militia_little_knight/human_militia_animated.tscn` |
| human_merchant | 战后金币按星级，model `res://assets/models/units/human_merchant_green_cloak/human_merchant_animated.tscn` |
| human_archer | every 4，combo_atk_pct 1.20，model `res://assets/models/units/human_archer.glb` |
| human_swordsman | damage_atk_pct 1.5，stun_sec 1.0，model `res://assets/models/units/human_swordsman_animated/human_swordsman_animated.tscn` |
| human_mage | 无普攻；skill_cd 2.5，damage_atk_pct 3.0，随机火/冰/雷/毒属性伤害，model `res://assets/models/units/human_mage_animated/human_mage_animated.tscn` |
| human_cleric | every 5，heal_pct 0.05 |
| human_death_servant | 周围一圈友军 defense_flat_up +3 持续5秒；绑定左侧棋子，该棋子首次死亡时死侍代替死亡并使其满血复活，model `res://assets/models/units/human_death_servant_animated/human_death_servant_animated.tscn` |
| human_king | post_battle_all_stat_growth 0.20，unique_on_board true，remove_on_death true；升星继承三只材料中成长最高的人王数值，model `res://assets/models/units/human_king.glb` |
| 唯一上阵规则 | 所有 `unique_on_board true` 的普通棋子，棋盘上同名只能存在 1 只；可拖到已有同名同星棋子上合成。 |
| 神族基础特性 | 我方棋子死亡时，随机 1 名我方存活棋子清除负面状态。 |
| 神族羁绊3 | 神族所有伤害按实际伤害 lifesteal 0.20 |
| 神族羁绊7 | 我方神族棋子开战 invulnerable 1.5 秒 |
| 暗族基础特性 | 对方棋子每死亡 3 只，我方暗族获得 1 层伤害加成；每层 +6% 伤害。 |
| 暗族羁绊2 | dark_debuff_strength 0.25：暗族造成的减攻、减速、防御降低等负面效果强度 +25%。 |
| 暗族羁绊5 | dark_damage_bonus 0.25：暗族伤害 +25%。 |
| 暗族羁绊7 | dark_debuff_duration 0.50：暗族造成的负面效果持续时间 +50%。 |
| 灵族基础特性 | 全场累计死亡 30 只时，所有我方自己的死灵棋子各召唤 1 只随机死亡棋子的分身；分身为原目标 40% 数值。 |
| 灵族羁绊4 | 灵族中毒效果 x2 |
| 灵族羁绊7 | undead_threshold_mul 0.75：灵族触发/阈值类效果 x0.75；母灵 5 死变 4 死，30 死召唤变 23 死触发。 |
| 人族基础特性 | 人族每攻击 3 次，第 3 次必定暴击。 |
| 人族羁绊7 | 最后一名普通棋子触发一次：max_hp_mult 2.0，defense_mult 2.0，atk_mult 2.0，attack_speed_mult 2.0，crit_bonus 1.00，crit_dmg_bonus 0.50，heal_max_hp_pct 0.50 |
### 种族关系

> 当前状态：暂时禁用。不会累计或保存关系进度，不应用属性效果，不显示进度条、流光、粒子、连线或长按关系详情。系统代码保留，统一开关为 `RaceRelationService.ENABLED = false`。

| 关系 | 规则 |
|---|---|
| 友好 | 神族↔人族、灵族↔暗族 |
| 敌对 | 神族↔暗族、灵族↔人族 |
| 相邻 | 只计算棋盘上下左右；斜角不计算。第1/2/3/4回合分别为1/2/3/4阶，第4回合进入4阶时效果生效。 |
| 进度继承 | 进度按具体种族组合独立记录；新加入同一种族组合的相邻棋子继承该组合当前进度，不同种族组合从1回合开始。 |
| 断开 | 准备阶段临时移开时，关系立即停用并隐藏，但本准备回合内保留进度；重新连接相同种族组合会恢复。开始战斗时仍未连接，才正式清除对应进度与效果。 |
| 友好效果 | 关系达到4阶时生效，参与棋子的基础HP、攻击、防御+15%；多个友好组合不叠加。 |
| 敌对效果 | 关系达到4阶时生效，参与棋子的基础HP、攻击、防御-15%；多个敌对组合不叠加。 |
| 同时生效 | 同一棋子可同时拥有一次友好和一次敌对效果，两者同时满进度时净倍率为100%。 |
| 棋盘表现 | 1至3阶显示三段静态进度条，进入4阶生效后隐藏。1/2/3阶分别显示7/14/18个模型环绕光点，逐级提高透明度、亮度、环绕速度和呼吸频率；4阶沿用18个光点，并在直接相邻的关联模型腰部之间显示2条细循环发光螺旋线。友好为金色，敌对为带冷灰高光的亮黑色；同一棋子可同时显示两种颜色。 |
| 长按详情 | 棋盘棋子在技能下方显示当前种族关系。1/2/3阶显示33%/67%/100%，3阶标为“蓄力完成”；4阶显示“100%（已生效）”，并追加基础HP、攻击、防御+15%或-15%。未正式生效时不显示属性效果。 |

## Boss规则

| 规则 | 效果 |
|---|---|
| Boss负面状态规则 | Boss受到负面状态效果-50%；控制类持续时间减半，减攻/减速/降防/易伤/治疗降低等数值效果减半，毒/燃烧/流血每跳伤害减半。 |
| Boss占位规则 | 所有 Boss 战斗体积为 2×2 格；近战单位停在 Boss 外缘，Boss 回合小怪出生位置避开 Boss 占位。 |
| Boss回合小怪 | 每个 Boss 回合额外生成 5 只随机 PVE 小怪；小怪使用 PVE 已完成次数成长，不使用 Boss 整体倍率或 Boss 成长。 |

## 法阵友军数值

最终战根据当前法阵 HP 区间召唤对应法阵友军。法阵友军不占普通棋子 7 人上限。

| ID | 名称 | 法阵 HP 区间 | HP | ATK | DEF | 攻速 | 射程 | 移速 | 技能 |
|---|---|---|---:|---:|---:|---:|---:|---:|---|
| ally_flame_claw | 焰爪魔灵 | 1-10 | 700 | 70 | 10 | 1.05 | 1 | 3.2 | burn_claw |
| ally_soul_chain | 暗狱锁魂者 | 11-20 | 900 | 78 | 14 | 0.95 | 4 | 3.0 | soul_chain |
| ally_abyss_beast | 深渊噬兽 | 21-30 | 1250 | 95 | 18 | 0.90 | 1 | 3.0 | devour_bite |
| ally_hell_inferno | 炼狱焚界者 | 31-40 | 1500 | 115 | 20 | 0.92 | 4 | 2.8 | hell_burst |
| ally_eternal_night | 深渊魔君·厄夜 | 41-50 | 1900 | 145 | 24 | 0.90 | 1 | 3.0 | eternal_night |

### 法阵友军技能参数

| ID | 技能参数 |
|---|---|
| ally_flame_claw | burn_dps 18，burn_duration 3.0 |
| ally_soul_chain | skill_cd 6.0，root_sec 2.0，attack_down_pct 0.15，attack_down_duration 4.0 |
| ally_abyss_beast | lifesteal 0.18 |
| ally_hell_inferno | skill_cd 8.0，aoe_damage 180，burn_dps 20，burn_duration 3.0 |
| ally_eternal_night | enemy_attack_down_pct 0.20，enemy_attack_down_duration 6.0，start_aoe_damage 240，clone_count 2，clone_hp_pct 0.30，clone_atk_pct 0.40，clone_attacks 3 |

## PVE 小怪数值

PVE 每回合只会从同一种小怪模板生成一组敌人。PVP 排程回合在 Demo 单机无联机对手时会临时按 PVE 生成随机小怪。  
实际小怪数值 = 基础值 x PVE 已完成次数成长。

### 小怪数量配置表

下表是小怪数量配置；只有实际判定为 PVE 的回合才会生成小怪。联机且有对手时，PVP / 最终PVP 不会因为这里有数字而生成小怪。

| 回合 | 小怪数量 |
|---:|---:|
| 1 | 3 |
| 2 | 4 |
| 3 | 5 |
| 4 | 5 |
| 6 | 6 |
| 7 | 6 |
| 8 | 6 |
| 9 | 6 |
| 11 | 8 |
| 12 | 8 |
| 13 | 8 |
| 14 | 12 |
| 16 | 12 |
| 17 | 12 |
| 18 | 15 |
| 19 | 15 |
| 20 | 18 |

### PVP 回合

| 回合 | 内容 |
|---:|---|
| 3 | 有联机对手时玩家对战；无对手时随机小怪 |
| 6 | 有联机对手时玩家对战；无对手时随机小怪 |
| 9 | 有联机对手时玩家对战；无对手时随机小怪 |
| 12 | 有联机对手时玩家对战；无对手时随机小怪 |
| 18 | 有联机对手时玩家对战；无对手时随机小怪 |
| 21 | 有联机对手时最终玩家对战；无对手时随机小怪 |

PVP 回合只有在联机且存在对手棋盘时才进入玩家对战；Demo 单机测试不会阻止开始战斗。

### PVE 小怪基础表

| ID | 名称 | 系列 | 元素 | HP | ATK | DEF | 攻速 | 射程 | 移速 | 技能 |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|
| pve_sky_cloud_eagle | 云羽鹰 | sky | sky | 260 | 32 | 3 | 1.15 | 1 | 3.5 | dive_backline |
| pve_sky_thunder_spirit | 雷鸣灵 | sky | sky | 300 | 24 | 4 | 1.05 | 4 | 3.2 | chain_lightning |
| pve_sky_star_butterfly | 星辉蝶 | sky | sky | 260 | 18 | 3 | 1.00 | 4 | 3.2 | heal_allies |
| pve_sky_dome_guard | 天穹守卫 | sky | sky | 520 | 20 | 10 | 0.85 | 1 | 3.0 | holy_shield_burst |
| pve_sky_wind_falcon | 风刃隼 | sky | sky | 330 | 28 | 4 | 1.20 | 4 | 3.3 | wind_bleed |
| pve_sky_hymn_spirit | 圣歌灵 | sky | sky | 360 | 24 | 5 | 1.00 | 4 | 3.2 | slow_aura |
| pve_land_rock_beast | 岩甲兽 | land | land | 420 | 28 | 16 | 0.80 | 1 | 2.9 | stun_impact |
| pve_land_vine_guard | 藤蔓守卫 | land | land | 380 | 30 | 14 | 0.85 | 1 | 2.8 | entangle |
| pve_land_vein_worm | 地脉虫 | land | land | 340 | 34 | 8 | 1.00 | 1 | 3.1 | burrow_ambush |
| pve_land_lava_golem | 熔岩傀儡 | land | land | 450 | 28 | 18 | 0.75 | 1 | 2.7 | lava_burst |
| pve_land_ancient_tree | 古树长者 | land | land | 430 | 24 | 16 | 0.80 | 4 | 2.6 | nature_heal |
| pve_land_mountain_giant | 山岳巨人 | land | land | 560 | 32 | 20 | 0.70 | 1 | 2.5 | earth_slam |
| pve_ren_shadow_thief | 影行盗徒 | ren | ren | 240 | 34 | 4 | 1.20 | 1 | 3.6 | backstab |
| pve_ren_voodoo_witch | 巫毒术士 | ren | ren | 280 | 28 | 5 | 1.00 | 4 | 3.2 | curse |
| pve_ren_puppet_master | 傀儡匠 | ren | ren | 300 | 26 | 8 | 0.90 | 4 | 3.0 | summon_puppet |
| pve_ren_wandering_swordsman | 流浪剑客 | ren | ren | 320 | 32 | 10 | 0.95 | 1 | 3.1 | counter_slash |
| pve_ren_poison_doctor | 药毒医师 | ren | ren | 300 | 26 | 6 | 1.00 | 4 | 3.1 | poison_attack |

古树长者显示模型使用 `pve_land_ancient_tree_animated.tscn`，动作映射为 `idle` / `attack` / `run`；数值与战斗逻辑未修改。

云羽鹰显示模型使用 `pve_sky_cloud_eagle_animated.tscn`；`idle` / `attack` / `run` 均从第 30 帧开始，数值与战斗逻辑未修改。

### PVE 小怪技能参数

| ID | 技能参数 |
|---|---|
| pve_sky_cloud_eagle | skill_cd 8.0，skill_atk_pct 1.8 |
| pve_sky_thunder_spirit | skill_cd 8.0，skill_damage 85，skill_bounces 3 |
| pve_sky_star_butterfly | skill_cd 8.0，skill_heal_pct 0.10，skill_heal_min 80 |
| pve_sky_dome_guard | skill_shield_pct 0.15，death_aoe_damage 110 |
| pve_sky_wind_falcon | skill_cd 8.0，skill_damage 90，bleed_dps 20，bleed_duration 3.0 |
| pve_sky_hymn_spirit | skill_cd 8.0，slow_attack_speed_pct 0.15，duration 4.0 |
| pve_land_rock_beast | skill_cd 8.0，skill_atk_pct 1.0，stun_sec 1.0 |
| pve_land_vine_guard | skill_cd 8.0，root_sec 1.5，attack_down_pct 0.15，duration 4.0 |
| pve_land_vein_worm | skill_cd 8.0，skill_atk_pct 1.6 |
| pve_land_lava_golem | skill_cd 8.0，skill_damage 110 |
| pve_land_ancient_tree | skill_cd 8.0，skill_heal_pct 0.12，skill_heal_min 100 |
| pve_land_mountain_giant | skill_cd 8.0，skill_atk_pct 1.2，stun_sec 1.0 |
| pve_ren_shadow_thief | skill_cd 8.0，skill_atk_pct 2.0 |
| pve_ren_voodoo_witch | skill_cd 8.0，attack_down_pct 0.05，max_stacks 5，skill_damage 90 |
| pve_ren_puppet_master | skill_cd 8.0，puppet_hp 180，puppet_atk 20，puppet_def 4 |
| pve_ren_wandering_swordsman | skill_cd 8.0，counter_atk_pct 1.5 |
| pve_ren_poison_doctor | 攻击附带中毒 |

泡沫术士佣兵 (`merc_pisces_bubble`) 显示模型使用 `merc_pisces_bubble_animated.tscn`，动作映射为 `idle` / `attack` / `run`；佣兵数值与战斗逻辑未修改。

甲壳守卫佣兵 (`merc_cancer_shell`) 显示模型使用 `merc_cancer_shell_animated.tscn`，`idle` / `attack` / `run` 均从第 30 帧开始；佣兵数值与战斗逻辑未修改。











