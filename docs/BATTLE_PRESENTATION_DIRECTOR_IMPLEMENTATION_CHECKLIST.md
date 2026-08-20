# BattlePresentationDirector：AI 实施参考清单

> 状态（2026-08-19）：**D0-D6 Windows/桌面闭环全部完成**，Android 部分按用户要求暂停。下方未勾选项仍是正式验收门槛，不能因已有基础设施而视为通过。
> 目标：在**不改变战斗规则、随机数、回放战斗帧、旧事件语义或胜负结果**的前提下，把既有回放事件转成可读、可跳过、可降级且可测试的战斗演出。

## 当前实施状态（2026-08-19）

| 阶段 | 状态 | 已有证据与剩余边界 |
| --- | --- | --- |
| D0 — 基线与确定性证据 | ✅ 桌面完成 / 实机 digest 已验 | 提交 `931771c69e3f585b19e49f3bc1b846b04aa6f55d` 已生成固定 seed round 1/2 的完整 roster、`frame_events`、result/final-state JSON、SHA-256、actor/fallback/anchor 审计、1280×720 截图和逐帧 CSV；19/19 JSON 可解析、两场 repeatable、0 live actor 缺失、0 fallback。Android 证据已于 2026-08-20 补齐：同一 commit 下固定回合 1/5/20/21 的实机与桌面 digest 逐字段一致，实机截图与演出指标已录（`A4_device_battle_20260820/`）。 |
| D1 — 冻结语义事件 schema | ✅ 桌面完成 / 实机 digest 已验 | `BattlePresentationEvent` v1 已冻结 15 个核心字段、稳定键、视觉 seed、优先级和 timing hint；Round 1/2 新事件 SHA-256 已冻结，D0 final-state/roster 完全不变，2738 项 schema 检查和 28/28 联机回归通过。 |
| D2 — Director 最小排程核心 | ✅ 桌面完成 / 实机 digest 已验 | 已实现 `IDLE/RUNNING/DRAINING/FINISHED` 与 `SEEKING/SKIPPED/DISPOSED`、逐 tick 入队、每 `source_uid` 动作轨、去重、暂停/seek/skip/drain/dispose；`BattleScreen` 已双路入队并保留 Legacy VFX。36/36 Director（含跨局清理）、2738/2738 schema、固定两回合哈希与 28/28 联机回归通过，本阶段不产生真实 VFX。 |
| D3 — 单位演员 | ✅ 桌面完成 / 实机 digest 已验 | 事实订正：`UnitVisualResolver`、`UnitActorRegistry`、`UnitActor3D` 六节点合同与立绘 fallback 早在 E1 已落地并在战斗中运行，D3 补的是 Director 接线与全量锚点测试。Director 现在只经 `UnitActorRegistry.get_anchor()` 取坐标，播放时现解析、不持有 `Node`/`NodePath`；缺 actor 分类 drop 且不阻塞同 tick 其他事件，缺锚点降级到 `ActorRoot` 并进 `report_failure()` 的一次性汇总。锚点检查覆盖全部 74 个可战斗单位（1067/1067），Director 检查 49/49（原 36 项 D2 断言保留），固定两回合 0 drop、0 降级、0 live actor 缺失、0 fallback，四个冻结哈希不变。 |
| D4 — 四段普攻 | ✅ 桌面完成 / 实机 digest 已验 | 模拟层为**全部单位**产出 `attack_start → [projectile_spawn] → impact → hit_number → death`（`death` 此前完全不存在）；视觉按 C4 纵向切片只迁移 `human_militia` / `human_archer` / `pve_sky_thunder_spirit` 三个单位，其余仍走 `BattleVfx` 快照 diff。**迁移必须原子**：产出事件、接 Director、关掉对应 diff 分支必须在同一步完成，否则每个效果播两遍；本阶段靠 `BattlePresentationSlice.gd` 这一份白名单被两侧共读来结构性保证。两个固定样本 0 `missing_actor` 掉落，切片样本实测播出 2 次近战起手、4 次投射物、4 个伤害数字、8 次死亡动画。50/50 Director、1067/1067 锚点、9787/9787 schema 通过；**D4 前后 final-state 哈希完全一致**，证明只改事件流不改战斗。 |
| D5 — 手感与运行时预算 | ✅ 桌面完成 / 实机 digest 已验 | `data/vfx/battle_cues/` 五个 `.tres` profile（§6 十三个字段逐项校验）+ `VfxProfileResolver`（按 `type + skill_id + race + quality_tier` 选择，缺失时降级到内建廉价 cue 并按 type/profile 聚合告警）；**扩展**现有 `VFXQualityBudget.gd` 加 `critical/important/ambient` 的每 tick / 存活上限与降级系数，记账单位是 replay tick；`scenes/debug/BattleVfxReview.tscn` 可切 seed / 回合 / 质量档 / 0.25×–2× 并保存截图与指标；切片扩面到全部单位。133/133 profile 检查、70/70 Director（含真实计时器 seek/skip）通过。修掉 5 个缺陷，其中最要紧的是 `attack_start`/`impact` 被 D1 遗留逻辑判成 ambient。 |
| D6 — 清理旧路由 | ✅ 桌面完成 / 实机 digest 已验 | 已删除 `BattleVfx` 的 `_collect_attack_events`、`_play_melee_slashes`、`_play_ranged_projectiles`、两处调用点、`_play_visual_events` 的 hit_number 分支，以及 `BattlePresentationSlice.gd` 与全部 `is_migrated` 闸门；`slice_*` 更名为 `cue_*`。保留 `mother_execute`、`unit_skill_proc`、`skill_shake`、Boss/种族技能与护盾/层数/治疗分支。三条不可回归条件均有证据：删除前后 adapter 分类播放计数逐项相同（证明删的是死代码）、新增源码级断言防止分支复活、回合间 orphan 与 tween 恒为 0 且节点数稳定不涨。82/82 通过。 |

### 下一执行门

1. Director D0-D6 桌面闭环已全部完成，转入本文件末尾「Director D0-D6 全部完成后」一节：先做 README 的 B4 / E3 启动预热拆分，再做代码/联机 D1、D3，最后 A5。Android 相关全部继续暂停。
2. 事件哈希当前值（D4 新增四段事件、D5 修正 `attack_start`/`impact` 的 priority，两次都按流程重冻）：Round 1 `6d3dd1f7b2e3e105298cbce11e1cc55fff7ea22cc21d8ff5136c7e54bb279110`；Round 2 `16afab6b41a0f5100c1369d2f938399668ab8511f3b2c5fabf89ce3ba73ac27c`。历史值：D1 的 `44e47d20…` / `4f134f2b…`（D2、D3 在其上验证过不变）、D4 的 `310426f7…` / `7d2e60fc…`。后续阶段不得无记录地改变当前值。
3. final-state 哈希继续作为严格不回归门禁，当前值：Round 1 `186f158728e2fdac189d2aac832e1da760af9644635e997b3bb3bb74a1cef505`；Round 2 `443d17206fd1edfe3e36e7ddfbd9c02a909c0d0b99feafe3b3ee0e584b7ea026`。**D4、D5、D6 三个阶段都没有改变它们**，即演出层自始至终只读不写战斗。这两个值也不是被 Director 改掉的：本会话进行中的上游合并 `e50022b` 改了 `data/pve/pve_monsters.json` 的 `name_en`（如 `Ancient Tree` → `Elder Treant`），战斗帧逐行零差异，隔离实验（同一提交、撤回 D4）复现了同样的新值。D0 旧值 `6ff92454…` / `8ce66a51…` 作为历史保留。
4. D2 与 D3 的完整回放都保持上述 D1 event 哈希和 D0 final-state 哈希，两场 repeatable、0 live actor 缺失、0 fallback；D2 证据在 `D2_battle_presentation_director_20260819/D2_VERIFICATION.json` 与 `baseline/`，D3 证据在 `D3_battle_presentation_actors_20260819/D3_VERIFICATION.json` 与 `baseline/`（另含每回合 `director_audit.json`：Round 1 解析 46 cue / 46 锚点，Round 2 解析 36 cue / 36 锚点，两场 0 drop、0 降级）。D1 相对 D0 的首差异记录仍保留在 `D1_battle_presentation_schema_20260819/verified/D1_VERIFICATION.json`。
5. D0 Round 1 的 1% low 9.34 FPS、最大帧 132.27 ms 仍作为 D5/E3 风险保留；D1 验证运行不能覆盖或删除这条历史风险。
6. Android/实机部分继续保持暂停；恢复时再补跨平台哈希、APK、ASTC 与低端机最终战门禁。

### Director D0-D6 全部完成后

1. 回到 README 的 B4 / E3：拆分启动预热并降低首屏时间、峰值显存和包体。
2. 处理 README 的代码/联机 D1、D3：`NetworkService` 拆分、服务器权威回放、重连与确定性加强。
3. 完成 A5 资源清理、第三方来源与许可证总账。
4. 用户恢复移动端工作后，统一补齐所有 Android、APK、ASTC、低端机和双设备 QA 门禁。

## 0. AI 的工作边界

### 可以改动

- `scripts/battle/BattleSimShared.gd` 与 `scripts/battle/DamageService.gd`：只补充稳定、纯数据的语义事件字段；补完后必须更新回放测试。
- `scenes/battle/BattleScreen.gd`：把回放帧事件入队给 Director，并在 seek/跳过/结束时转发生命周期调用。
- `scenes/battle/BattleVfx.gd`：按事件类型逐步删除硬编码消费分支；第一阶段保留兼容桥。
- 新增 `effects/runtime/presentation/`、`data/vfx/battle_cues/`、`scenes/debug/BattleVfxReview.tscn` 和独立测试。

### 绝对不能做

1. 不在 Director、VFX、音频、Tween 或 Juicee adapter 中修改 HP、buff、目标、随机数、金币、胜负或 replay 内容。
2. 不从 Director 调用 `BattleSimulator.step_state()`，也不让模拟层 `load()` 特效场景或访问节点树。
3. 不在 PVP/回放中以 `Engine.time_scale` 影响模拟；所谓 hit-stop 只能是本地镜头/动画的短暂停顿。
4. 不因为资源加载失败而静默生成蓝/红胶囊。必须使用同风格卡牌立绘 fallback，并仅在开发构建输出一次聚合告警。
5. 不把外部开源项目整包复制进来；使用 MIT 代码需保留原版权和 `THIRD_PARTY_NOTICES.md`，无 LICENSE 的项目只参考架构。

## 1. 当前真实链路（改动前必须读）

| 位置 | 当前职责 | Director 改造后的职责 |
| --- | --- | --- |
| `scripts/battle/BattleSimShared.gd::_add_visual_event()` | 写入 `skill_shake` 等视觉事件。 | 只写标准化的语义事件；不能产生节点、Tween 或资源引用。 |
| `scripts/battle/DamageService.gd::_maybe_emit_hit_number()` | 写入 `hit_number`，目前已含目标、伤害、暴击、技能、种族。 | 补 `source_uid`、稳定键和实际战斗 tick；普通攻击要另外产生 `attack_start`/`impact`，而非让伤害数字承担整段动作。 |
| `scripts/battle/BattleSimulator.gd::_replay_capture_frame()` | 将本帧新增 `visual_events` 记录为 `frame_events`。 | 保持原职责；新 schema 必须通过同样路径进入 replay。 |
| `scenes/battle/BattleScreen.gd::_apply_replay_frame()` | 将 `frame_events` 追加回 `_state.visual_events`，由递增游标消费。 | 改为每个新 tick 调 `presentation_director.enqueue_tick(tick, events)`；不得再把无限增长数组作为唯一消费队列。 |
| `scenes/battle/BattleVfx.gd::_play_visual_events()` | 以 `if/elif` 直接播放 `skill_shake`、`mother_execute`、`unit_skill_proc`、`hit_number`。 | 第一阶段成为 compatibility adapter；迁移一个事件类型，删除一个对应分支。 |

## 2. 建议的文件、职责与最小 API

```text
effects/runtime/presentation/
├── BattlePresentationDirector.gd      # 唯一排程者；不持有模拟状态
├── BattlePresentationEvent.gd         # 只读/验证/标准化事件数据
├── BattleCueRequest.gd                # event + profile + resolved anchors
├── BattleActionTrack.gd               # 一个单位的一条动作轨
├── UnitActorRegistry.gd                # sim uid -> Actor3D / anchors
├── UnitVisualResolver.gd               # unit id -> 已验证实例或立绘 fallback
├── VfxProfileResolver.gd               # event -> .tres profile
├── VfxPool3D.gd                        # 节点池与预算借还
└── adapters/
    ├── LegacyBattleVfxAdapter.gd       # 迁移期调用已有 BattleVfx 能力
    ├── CameraFeelAdapter.gd            # 局部屏震/镜头，不碰模拟时钟
    ├── DamageNumberAdapter.gd          # 复用现有数字池
    └── JuiceeBattleFeelAdapter.gd      # 可选，基础切片稳定后才加入
data/vfx/battle_cues/
├── basic_melee.tres
├── basic_ranged.tres
├── crit.tres
├── heal.tres
├── shield.tres
├── death.tres
└── boss_skill.tres
```

`BattlePresentationDirector.gd` 的最小公开接口应保持小而明确：

```gdscript
func configure(registry: UnitActorRegistry, resolver: VfxProfileResolver, budget: VFXQualityBudget, adapter: Variant = null) -> void
func begin_battle(context: Dictionary) -> void
func enqueue_tick(tick: int, raw_events: Array) -> void
func set_playback_speed(speed: float) -> void
func seek_to_tick(tick: int) -> void
func begin_draining() -> void
func skip_to_result() -> void
func has_blocking_cues() -> bool
func dispose() -> void
```

返回值和 signal 也要可测试：`cue_started(event_key)`、`cue_completed(event_key)`、`cue_dropped(event_key, reason)`、`presentation_drained()`。API 不暴露 `BattleSimulator`、单位可变 Dictionary 或场景私有节点给调用方。

## 3. 事件契约：先扩数据，后做效果

每一项传入 Director 的事件必须是纯 Dictionary 或 `BattlePresentationEvent`，最少包含：

| 字段 | 说明 | 来源/规则 |
| --- | --- | --- |
| `event_key` | 全局唯一、可重建的幂等键。 | `battle_id + tick + ordinal`；不能用随机 UUID。 |
| `tick` | 回放中的模拟 tick。 | `BattleSimulator` 捕获时写入，不用 wall-clock 代替。 |
| `type` | 见下表。 | 未知类型只记录一次 `cue_dropped`，不崩溃。 |
| `source_uid` | 发动者模拟 uid。 | 对 `hit_number` 也必须补齐。 |
| `target_uids` | 目标 uid 数组。 | 单目标也用数组，便于 AoE。 |
| `skill_id` | 普攻用 `basic_melee`/`basic_ranged` 或 unit definition 中的稳定 ID。 | 不能用展示名称匹配。 |
| `amount` / `is_crit` / `is_lethal` | 已结算的只读结果。 | 只用于 profile 和 UI，不能反算伤害。 |
| `presentation_seed` | 仅用于粒子散布、数字偏移等视觉随机。 | 由战斗种子/`event_key` 派生，不消费 `RngService`。 |
| `visibility_priority` | `critical`、`important`、`ambient`。 | 决定合并/降级，不能改变事件顺序。 |
| `timing_hint` | `windup_ms`、`impact_ms`、`recovery_ms`。 | 演出建议值，不改变模拟 tick。 |

首批事件类型和迁移要求：

| 类型 | 当前来源 | Director 的基础行为 | 优先级 |
| --- | --- | --- | --- |
| `attack_start` | **待补**，目前普攻往往只有 `hit_number`。 | 朝向目标、起手动作、武器/手部亮起。 | important |
| `projectile_spawn` | **待补**于远程攻击。 | 从 `world_cast` 到目标当时的 `world_hit` 播放可池化投射物。 | important |
| `impact` | **待补**，与命中伤害绑定。 | 命中闪白、受击动作、局部粒子/音效。 | important；暴击为 critical |
| `hit_number` | `DamageService` 已有。 | 调 `DamageNumberAdapter`，不得独立假定攻击者。 | ambient/important |
| `heal` / `shield` | 部分为 `hit_number.kind`，其余待补。 | 绿色数字/护盾环，不能与伤害共用红色 hit profile。 | important |
| `death` | **待补**。 | 停止该 uid 后续 action，播死亡/溶解/倒地，再注销 actor。 | critical |
| `skill_cast` / `unit_skill_proc` | 已有 `unit_skill_proc`。 | 读条、施法锚点、目标线；Boss 加危险范围。 | important/critical |
| `skill_shake` | `BattleSimShared` 已有。 | 只交 `CameraFeelAdapter`；需配合 boss/tier profile。 | important |
| `mother_execute` | `BattleVfx` 已有硬编码支持。 | 先做 Legacy adapter，稳定后转为 `skill_cast + impact + death` 组合 cue。 | critical |

## 4. 调度规则（不能只按数组立即播放）

1. **先标准化。** `enqueue_tick()` 将 raw event 转为只读事件；校验缺字段、uid、profile 和锚点。无效事件不阻塞其他事件。
2. **后解析。** `VfxProfileResolver` 通过 `type + skill_id + race + quality_tier` 选 profile；profile 不存在时使用低成本 fallback，并按 `type/profile` 聚合告警。
3. **每单位一条 ActionTrack。** 同一 `source_uid` 的动作串行；`impact` 可以与目标的受击 track 并行；`death` 取消该 uid 未开始的普通攻击。
4. **跨单位允许并行，但有限制。** `critical` 永不合并；`important` 最多保留最近一项同种 cue；`ambient` 在同一目标的 100ms 窗口内可合并伤害数字和粒子。
5. **演出时钟独立。** Director 用自己的 playback speed 和累加器驱动；模拟/replay tick 仍按原逻辑前进。慢帧不能无限积压：先降低 ambient，再减少粒子/透明层，最后将非关键 action 的收招缩短。
6. **结果页门禁。** 模拟已经结束时进入 `DRAINING`，只等待 `critical`/`important` cue 或总时限；点击跳过立即清空瞬态效果、保留最终血量/状态并进入结果页。
7. **seek 规则。** 向前 seek 可消费未消费 tick；向后 seek 必须 `cancel_all_transient()`、重建 actor 当前姿态与持续性状态，不能把已发生的伤害数字/屏震再次全播。该策略必须有单测。

建议生命周期：`IDLE → RUNNING → DRAINING → FINISHED`；任意状态可进入 `SEEKING`、`SKIPPED`、`DISPOSED`。每一次切换都必须归还池化节点、断开 Tween/signal，防止下一局继承上一局特效。

## 5. 单位、锚点和兜底显示

1. `UnitVisualResolver` 在开战前完成 `unit_id → PackedScene/GLB → UnitActor3D` 验证，建立 `sim_uid → actor` 注册表。
2. 每个 `UnitActor3D` 都必须提供：`ActorRoot`、`FootAnchor`、`HeadAnchor`、`CastAnchor`、`HitAnchor`、`Shadow`。Director 只能通过 `UnitActorRegistry.get_anchor(uid, name)` 取坐标。
3. actor 不存在或坏资源时，用该单位已有的角色立绘、名字、阵营框和血条生成 2.5D fallback；将 `unit_id`、资源路径、消费者记录到一次性错误汇总中。
4. 演出系统不能通过 `NodePath` 缓存跨局对象；只能存 `sim_uid`，每次播放再从 Registry 解析，避免死亡/重生与回放 seek 的悬挂引用。

## 6. `.tres` profile 的必要字段

每个 profile 至少配置：`id`、`event_types`、`priority`、`anchors`、`windup_ms`、`impact_ms`、`recovery_ms`、`camera_mode`、`audio_cue`、`vfx_scene`、`max_concurrent`、`quality_overrides`、`fallback_profile`。

首个切片只做以下 profile，禁止同时迁移全角色技能：

| Profile | 表现要点 | 低档退化 |
| --- | --- | --- |
| `basic_melee` | 朝向、短起手、命中闪白、轻微受击、伤害数。 | 关闭额外粒子和镜头，仅保留动作/闪白/数字。 |
| `basic_ranged` | 起手、可见投射物、命中点。 | 用单 Sprite/mesh 投射物，限制同屏数量。 |
| `crit` | 与普攻不同的颜色、音效和更强受击反馈。 | 不用全局停时；保留颜色、数字缩放和局部闪白。 |
| `heal` | 从施法点到目标的绿色 cue，随后治疗数字。 | 取消轨迹粒子，只保留环和数字。 |
| `death` | 停止动作、死亡 cue、清理 actor。 | 一次性淡出/缩放，不能直接消失。 |

## 7. 分提交实施顺序与验收

| 提交 | 可交付物 | 不可回归条件 |
| --- | --- | --- |
| D0：基线（桌面 ✅ / 实机 digest 已验） | 固定 seed 的 PVE replay、事件 JSON、最终状态 digest、Android 截图/指标。 | 桌面基线已冻结；实机 digest 与指标已补齐。仍不得把未验的项写成通过——当前未验的是粒子数与结果页抢跑（见第 8 节真机测试）。 |
| D1：schema（桌面 ✅ / 实机 digest 已验） | 事件 schema、`event_key`、`source_uid`、`tick`、未知事件一次性告警与 headless 测试已完成。 | 事件类型/顺序/旧字段投影及 D0 最终状态不变；Android 跨平台哈希待恢复。 |
| D2：Director 空壳（桌面 ✅ / 实机 digest 已验） | 生命周期、队列、假 Registry/假 Adapter 单测与 `BattleScreen` 逐 tick 双路入队已完成；空 Adapter 同步完成 cue。 | 固定两回合可完整打完，暂停/seek/skip/drain/dispose 测试通过，D1/D0 哈希不变；未产生真实 VFX。 |
| D3：单位演员（桌面 ✅ / 实机 digest 已验） | Resolver、Registry、五锚点与立绘 fallback 已正式接入 Director；74 个可战斗单位全量锚点测试；固定两回合 0 胶囊。 | 已验证：坏资源与缺锚点都进同一份带 `unit_id`/资源路径/消费者的一次性汇总，缺 actor 只分类 drop，全程无胶囊；四个冻结哈希不变。 |
| D4：四段普攻（桌面 ✅ / 实机 digest 已验） | 全单位产出四段事件 + 远程 projectile；视觉按 C4 切片迁移 3 个单位；`LegacyBattleVfxAdapter` 复用既有表现，不新增美术。 | 已验证：同一提交下 D4 前后 final-state 哈希逐字相同，伤害公式、单位顺序、战斗结果不变；两个固定样本 0 `missing_actor` 掉落。 |
| D5：手感与预算（桌面 ✅ / 实机 digest 已验） | 五个 profile、扩展后的 VFXQualityBudget、`BattleVfxReview.tscn`；未引入 Juicee。 | 已验证：critical 不设上限、不合并、不缩短；important 超预算只让出收招；ambient 仅在溢出且同目标重复时合并。固定样本实测 0 合并、20 次降级。 |
| D6：清理旧路由（桌面 ✅ / 实机 digest 已验） | 已删除三个 diff 函数、两处调用点、hit_number 旧分支与 `BattlePresentationSlice.gd`；未迁移路由保留。 | 已验证：删除前后播放计数逐项相同、源码级断言防复活、回合间 orphan/tween 恒为 0、节点数稳定。 |

## 8. 必做测试清单

- [x] **纯数据测试（桌面）：** 相同 replay 的 `event_key`、字段顺序、`presentation_seed`、同步/异步事件 SHA-256 完全一致；normalizer 不消费 `RngService`，D0 最终战斗 digest 不变。
- [x] **D2 队列核心测试（桌面）：** 同一 uid 连续三次攻击串行；两个不同 uid 并行；死亡取消未开始攻击；重复键与未知事件均只 drop 一次且不崩溃。未知 profile 的真实 fallback 仍属于 D5。
- [x] **D2 seek/skip 核心测试（桌面）：** 暂停、0–4× 速度约束、向后/current seek、跳过、drain 与 dispose 均通过；空 Adapter 无 Tween、池节点或跨局回调残留。
- [x] **D5-D6 真实效果 seek/skip 测试（桌面）：** 新增用例通过真实 `SceneTreeTimer` 完成 cue，断言 seek 与 skip 之后都不留下任何还能回调的计时器、且旧计时器不会迟到地补完 cue；结果页等待有 3 秒上限，跳过时立即返回。D2 那批是空 adapter 跑的，无法证明这一点。
- [x] **锚点测试（桌面）：** 全部 74 个可战斗单位解析五锚点与六节点合同，含 `FeetAnchor`/`BodyAnchor` 兼容别名与跨局 `clear()` 后整体失效；坏模型路径进入立绘 fallback 且资源路径恰好上报一次；Director 侧缺 actor 分类 drop、缺锚点降级并上报。固定两回合回放另有 0 drop / 0 降级的实测审计。
- [x] **回放测试（2026-08-20 完成）：** Windows 两回合事件序列、首差异与最终状态 SHA-256 已记录；**desktop/Android 跨平台一致性已验**——同一 commit 下固定回合 1/5/20/21 的 `roster_sha256`/`replay_sha256`/`frame_events_sha256`/`final_state_sha256`/`repeatable` 五个字段逐字一致。工具 `tools/android_baseline.sh`，证据 `A4_device_battle_20260820/`。
- [x] **视觉评审场景（桌面）：** `scenes/debug/BattleVfxReview.tscn` 可固定 seed、选回合、切 `LOW/MEDIUM/HIGH` 与 `0.25×/0.5×/1×/2×`，保存截图与指标 json（fps、draw call、节点、orphan、tween、显存、解析统计、预算统计、profile 计数）。**注意：工具已具备，但人工美术评审本身尚未进行。**
- [ ] **真机测试（2026-08-20 大部分完成，两项未验）：** 三个样本已在真实 APK 上跑完——第一场（回合 1）、20+ 回合（回合 21）、Boss（回合 5 与 20）。**已验**：无 `SCRIPT ERROR`（设备日志 0 条）；无持续节点增长（跨回合残留 14→33→36→36 趋于平稳，orphan 与 tween 全程为 0）；已记录平均/1% low FPS、显存（video/texture/static）、draw call 与 dropped cue 数（按原因分类）。**未验**：① 粒子数——基线工具根本不采集这项；② 无结果页抢跑——没有对应断言。另注：这批实机指标取自修复召唤物死亡缺陷**之前**的构建，指标本身不受该缺陷影响，但复验尚未做。

## 9. 给后续 AI 的执行提示

每次只完成上表中的一个 D 阶段。先读本文件第 0–4 节和涉及文件的现有实现；提交前运行对应 headless/replay 测试，并在需要视觉验收的阶段启动 `BattleVfxReview`。Android Debug APK、ASTC 与实机测试按用户当前决定暂停，只有用户明确恢复后才执行。若发现事件字段或模型资源缺失，应停止扩展新效果，先补 schema/资源映射和失败测试；不得以临时胶囊、全局减速或忽略日志作为“战斗效果已改善”的证据。
