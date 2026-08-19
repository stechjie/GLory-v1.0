# BattlePresentationDirector：AI 实施参考清单

> 状态：设计/实施清单，不是已完成代码。
> 目标：在**不改变战斗规则、随机数、回放 payload 或胜负结果**的前提下，把既有回放事件转成可读、可跳过、可降级且可测试的战斗演出。

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
func configure(registry: UnitActorRegistry, resolver: VfxProfileResolver, budget: VFXQualityBudget) -> void
func begin_battle(context: Dictionary) -> void
func enqueue_tick(tick: int, raw_events: Array) -> void
func set_playback_speed(speed: float) -> void
func seek_to_tick(tick: int) -> void
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
| D0：基线 | 固定 seed 的 PVE replay、事件 JSON、最终状态 digest、Android 截图/指标。 | 未记录基线，不做表现重构。 |
| D1：schema | 事件 schema、`event_key`、`source_uid`、`tick`、未知事件日志与 headless 测试。 | 同 replay 的语义事件和最终状态 digest 不变。 |
| D2：Director 空壳 | 生命周期、队列、假 Registry/假 Adapter 单测；`BattleScreen` 能入队。 | 不产生真实 VFX 时也能完整打完/跳过/seek。 |
| D3：单位演员 | Resolver、Registry、五锚点、立绘 fallback；首场 PVE 0 胶囊。 | 坏资源被明确报错，不得默默换胶囊。 |
| D4：四段普攻 | `attack_start → impact → hit_number → death`；远程再加 projectile。 | 伤害公式、单位顺序、回放结果完全不变。 |
| D5：手感与预算 | 五个 profile、VFXQualityBudget、Mobile 评审场景；可选 Juicee adapter。 | 预算溢出只降级，Boss/死亡/控制 cue 不消失。 |
| D6：清理旧路由 | 每迁移一种 type 删除对应 `BattleVfx` 分支，保留 Legacy adapter 直到覆盖完成。 | 无重复播放、无跨局残留、无节点/内存持续增长。 |

## 8. 必做测试清单

- [ ] **纯数据测试：** 输入相同 replay，normalizer 输出的 `event_key`、字段顺序、`presentation_seed` 完全一致；profile 改动不会改变最终战斗 digest。
- [ ] **队列测试：** 同一 uid 连续三次攻击串行；两个不同 uid 可并行；死亡取消未开始攻击；未知 profile 有一次性 fallback/告警。
- [ ] **seek/skip 测试：** 快进、慢放、向后 seek、跳过、战斗结束进入结果页均不重复数字/屏震，不残留 Tween 或池节点。
- [ ] **锚点测试：** 全部首发单位能解析五锚点；坏模型进入立绘 fallback 且报告资源路径。
- [ ] **回放测试：** desktop 与 Android 的事件序列 SHA-256 和最终状态 SHA-256 一致；报告第一个差异 tick/字段。
- [ ] **视觉评审：** `BattleVfxReview.tscn` 能固定 seed、切换 `0.25×/1×/2×` 与质量档，保存截图和 VFX 指标。
- [ ] **真机测试：** 第一场、20+ 回合、Boss 三个真实 APK 样本；无 `SCRIPT ERROR`、无结果页抢跑、无持续节点增长，并记录平均/1% low FPS、显存、draw call、粒子和 dropped cue 数。

## 9. 给后续 AI 的执行提示

每次只完成上表中的一个 D 阶段。先读本文件第 0–4 节和涉及文件的现有实现；提交前运行对应 headless/replay 测试、启动 `BattleVfxReview`、再构建并安装 Android Debug APK。若发现事件字段或模型资源缺失，应停止扩展新效果，先补 schema/资源映射和失败测试；不得以临时胶囊、全局减速或忽略日志作为“战斗效果已改善”的证据。
