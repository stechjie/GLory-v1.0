# 2026-11-25 iOS Simulator 战斗热点优化与验证

> 本报告针对用户提出的 iPhone 发热问题，在没有真机的条件下记录可验证的代码优化、Simulator 测量结果和验证边界。三轮局部 CPU 基准已完成；完整画面 S2 已自然结束并通过 harness 检查，S1 的中断失败记录仍保留。不得据此宣称 iPhone 温度、功耗或整场 FPS 已改善。

## 1. 当前结论

本轮在保留画质及战斗行为的前提下，减少了三类重复脚本工作：UID 默认字符串的无效构造、状态与单位定义读取时的临时空字典、同一次 VFX 快照中的重复 actor 查询。四个生产文件合计 **43 行新增、20 行删除**。其中三个文件实施 CPU 优化，另一个文件修复实际测试暴露的已释放 actor 生命周期错误。

同一个 iOS Simulator Release 进程内执行原函数和当前函数，交替 AB/BA 顺序；共运行三个独立进程。以每个用例的 **21 对原始批次结果的配对中位数**为主口径，四个真实回合的完整 VFX 快照收集每次调用分别少用 **82.047619、86.970238、318.934524、93.916667 微秒**，对应减少 **18.465%、17.786%、13.770%、28.302%**。这些数值是局部同步脚本循环的耗时，不是整帧耗时，也不能加总成整场收益。[E1][E2]

完整画面 S1 确认 21 个模型建立、28/28 个特效预热任务完成，并实际进入战斗中段。但它在 QA 的 360 秒轮次上限被强制终止，不能计为自然完成一场比赛。中断后报告的 40 个 tween 是中断路径的残留观测，不能据此认定自然结算泄漏，也不能将它忽略成一次完整通过。S2 使用版本 3 的 QA harness，将该显式诊断模式的轮次上限调整为 900 秒；生产代码、预热任务和播放逻辑保持不变。S2 随后完成自然结算，passed=true、failures=[]，退出后运行中 tween 为 0；仍保留原有预算回退记录，见第 8.2 节。[E5][E8]

## 2. 环境、版本与输入

### 2.1 运行环境

| 项目 | 本轮实际值 |
| --- | --- |
| 宿主机 | DeskLink Mac 的 Mac mini；sample 记录 macOS 26.6.2（25G83） |
| 复用的 Simulator | GLory-Duo-27.2-20261125，设备类型 iPhone Duo |
| Simulator runtime | com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4 |
| Simulator UDID | 5EED6FF8-2126-4661-B74C-FAE9FD9E0160 |
| QA 应用 | com.superforge.glory.perfqa，独立于原应用 |
| 构建 | ARM64、iOS Simulator、Release；运行时 debug_build=false |
| Godot | 4.7-stable (custom_build)；运行时 engine.hash 为 unknown，不伪填引擎提交 |
| 渲染器 | gl_compatibility；运行时 video_adapter=Apple Software Renderer |
| CPU 报告 | processor=Simulator、processor_count=10；这是宿主环境，不是 iPhone 芯片配置 |
| 代码基线 | ad76ec05fd564201c3b27eaa2d6f3fafbfe26b9f |
| 工作分支 | perf/ios-battle-20261125 |
| 隔离工作区 | /Volumes/repository/github/GLory/worktrees/ios-perf-20261125 |

本轮复用已安装的替代 Simulator，不把设备名称视为对应真实 iPhone 的 CPU、GPU 或散热模拟。Apple 的 [Simulator 运行说明](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices) 明确说明，模拟器运行在 Mac 上，不能复现实体设备的性能和全部特性。有关 GPU 差异，另见 [Developing Metal apps that run in Simulator](https://developer.apple.com/documentation/metal/developing-metal-apps-that-run-in-simulator)。[E1][E3][E5]

### 2.2 固定输入

基准使用仓库现有 FixedBattleFixture、BattleSimulator 和生产 BattleScreen 回放解码路径，固定种子为 **20260807**。每轮选择开场、变化时刻和结束附近的七个快照，包括死亡后仍保留在 roster 中的单位和实际状态变化；事件演出不进入 CPU 微基准计时区间。

| 回合 | 类型 | Roster 单位数 | 回放帧数 | 采样 tick |
| --- | --- | ---: | ---: | --- |
| 1 | pve | 21 | 53 | 0、13、21、26、39、51、52 |
| 5 | boss | 24 | 79 | 0、11、19、39、51、58、78 |
| 20 | boss | 78 | 306 | 0、24、76、152、228、255、305 |
| 21 | pvp | 26 | 185 | 0、46、50、61、92、138、184 |

三个进程的回合摘要、回放 payload、逐样本输入 SHA256 和采样元数据一致；参与基准的 **12 份源码／配置指纹**也一致。完整哈希和输入保存在聚合文件的 source_manifest、rounds、cases 字段中。基准只使用离线固定数据，独立 QA 入口关闭服务节点的网络处理，不产生线上对局或聊天。[E1][E2][E3]

## 3. 采样看到的负载与可以归因的范围

### 3.1 完整画面中的软件绘制与驱动编译

最早的 shipping 123 入口运行记录到 render_warmup_timeout。随后保留的 sample 中存在 GLRendererFloat 软件光栅化调用；该次失败之后的采样不是成功播放整场战斗的采样。[E4]

S1 以准备报告 ready 为触发点开始短窗口采样。主线程绘制链中可见 glDrawElements_IMM_ES2Exec、gleLLVMVPTransform、GLRendererFloat 的三角形／扫描线绘制。驱动编译线程中可见：

- libGLVMPlugin 的 cvmContentBuildLLVMFunctions；
- libLLVMContainer 的 llvm::MCJIT::finalizeObject、generateCodeForModule 和 emitObject；
- LLVM pass 与寄存器分配调用。

这些栈是当前 Simulator 软件绘制和驱动 JIT 编译负载的直接证据。S1 在 ready 之后，后台仍存在延迟的驱动编译工作，因此这份 sample 不能称为完全稳态样本。主线程的 2083 个采样点属于这次短采样窗口，不能读成整场战斗或整台机器“CPU 100%”，也不能用于估算实体 iPhone 的 GPU 功耗。单纯统计含有某个符号的文本行数也不是 CPU 占比。[E5]

### 3.2 本轮脚本热点的依据

脚本审查找到的重复工作在生产渲染路径上每次执行，随后用原函数与当前函数的同输入对照确认实际收益：

| 热点 | 原先重复工作 | 本轮处理 |
| --- | --- | --- |
| BattleRenderer._visual_id | Dictionary.get 的 fallback 参数先求值，UID 已存在仍格式化 team/id 字符串 | 先检查 uid key 是否存在；只有缺失时构造 fallback |
| BattleVfx._collect_vfx_units | 反复读取 def，并构造未使用的空字典；同一单位的四个锚点反复查询 registry | 保存当前调用内的只读字段引用；复用已经取得的 actor |
| StatusVFXController | statuses、单个状态、非致命流血、poison 的缺省值反复构造空字典 | 复用只读空字典默认值 |

这些结果支持减少指定脚本工作的结论。它们没有证明这三处是用户实体 iPhone 发热的主要来源；软件绘制的 Simulator 调用栈也不能替代那台 iPhone 上的归因。

## 4. 生产改动与行为约束

| 生产文件 | 改动 | 保留的行为 |
| --- | --- | --- |
| scenes/battle/BattleRenderer.gd | UID fallback 延迟构造 | uid 缺失、空字符串、null、数字等转换仍沿用原语义 |
| scenes/battle/BattleVfx.gd | 复用只读默认字典、局部 def 引用，以及当前调用内的 actor | 双缓冲快照、逐帧锚点／变换、FeetAnchor 与 BodyAnchor 别名、actor／锚点缺失 fallback 均保留 |
| scenes/battle/StatusVFXController.gd | 只读空字典默认值复用 | 状态可见性、持续时间、毒叠层、非致命流血、护盾阶段和处理频率不变 |
| effects/runtime/presentation/UnitActorRegistry.gd | is_instance_valid 提前到类型检查之前 | 正常登记／注销行为不变；已释放但未注销的对象安全清理并返回 null |

**生命周期修复单独计入正确性。** 原 get_actor 对已释放对象先执行 Node3D 类型判断，会产生“Left operand of 'is' is a previously freed instance”脚本错误。新顺序先排除无效对象。这个错误由真实的 free 后未注销测试触发，测试没有被改成仅覆盖正常注销路径。新旧 CPU 基准两组共用修复后的 Registry，所以性能百分比不包含这项修复的收益。[E6]

没有修改 BattleSimulator、伤害规则、随机输入、回放时序、帧率或效果调度；没有跨帧缓存 actor。已有双缓冲、静止节点赋值保护、状态空闲处理等优化保持原状，不列为本轮新增成果。

## 5. CPU 基准方法与统计口径

旧函数从基线提交通过 git show 提取，由 scripts/qa/freeze_hotpath_baseline.py 生成冻结文件。静态 poison helper 仅做必要重命名，避免继承静态函数解析误调用新实现。两组共享其余节点与场景基础设施，且在同一个 Release 进程、同一个 PCK 内执行。

每次进程运行含 **17 个用例**：一个合成 UID 边界用例，以及四回合各自的 collect、UID、真实状态序列、缺少 statuses 字段四类用例。每用例先执行三轮不计时预热，再执行七个批次，每批 24 个循环；偶数批 AB、奇数批 BA。计时区间采用 Time.get_ticks_usec 包围同步 CPU 循环。单位数不同导致每批调用次数不同，聚合时使用各自的 calls_per_arm_per_batch 正规化。

状态用例使用真实 StatusVFXController 与 Sprite3D，双方相同地隐藏父节点并关闭自动 process；快照用例使用实际 Node3D 锚点结构。计数用的 Registry 子类只在计时区间外使用。上述隔离是为了测量目标函数，不等于测量完整画面或真实手机电流。[E1][E2]

三个独立进程共得到：

- 51 个用例执行、357 对批次；
- 每用例 21 对批次；
- 每进程 9531 项正确性检查，三次合计 28593 项，全部通过；
- 三组一致的 12 份源码／配置指纹和四回合输入摘要。

主口径对每一对批次分别计算：

~~~text
配对减少比例 = 100 × (1 − 当前批次耗时 / 原版批次耗时)
配对每次调用节省 = (原版批次耗时 − 当前批次耗时) / 每组调用次数
报告值 = 各自 21 个配对数值的中位数
~~~

不丢弃变慢批次，不剔除离群值，不跨回合加权合并。21 对批次嵌套在同一宿主机上的三个进程中，仅作描述统计，不给出独立设备总体的置信区间。

“双方各取中位数再相除”和“21 个配对比例取中位数”不同。例如第 20 回合 collect，前一种计算得到 35.207%，本报告的主口径是 **13.770%**；不得混用两者或用前者替换主结论。配对节省值也不是两侧独立中位数直接相减。[E1]

## 6. CPU 结果

### 6.1 每次完整 VFX 快照收集

单位为一次 _collect_vfx_units(snapshot) 调用，包含该快照内所有有效单位，而非一个单位或一帧全部游戏代码。

| 回合 | Roster | 配对每次调用节省中位数（微秒） | 配对减少比例中位数 | 三次独立运行的配对比例中位数范围 | 变慢批次 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 21 | 82.047619 | 18.465% | 16.742%–19.280% | 1/21 |
| 5 | 24 | 86.970238 | 17.786% | 7.191%–17.982% | 1/21 |
| 20 | 78 | 318.934524 | 13.770% | 12.707%–17.368% | 1/21 |
| 21 | 26 | 93.916667 | 28.302% | 27.221%–28.723% | 1/21 |

独立操作计数确认，存在 actor 的一个单位，其快照内 Registry.get_actor 调用由 **9 次降至 1 次**。这只是该操作的次数变化，不能说整个函数或游戏快了九倍。[E1][E6]

### 6.2 UID 与真实状态序列

| 回合 | UID 配对减少比例 | UID 每次调用节省（微秒） | 真实状态序列配对减少比例 | 状态每次调用节省（微秒） | 状态变慢批次 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 68.429% | 0.401786 | 9.817% | 0.595238 | 7/21 |
| 5 | 68.761% | 0.396810 | 11.132% | 0.720734 | 4/21 |
| 20 | 68.414% | 0.339343 | 10.134% | 0.614164 | 2/21 |
| 21 | 67.828% | 0.326222 | 9.766% | 0.612637 | 1/21 |

常规回放 UID 用例约减少 68%；这不等同于所有边界输入。混合缺失／null 等输入的 UID 边界用例，配对比例中位数为 41.914%，每次节省 0.211806 微秒。缺少 statuses 字段的四个用例配对减少比例中位数分别为 10.767%、9.462%、10.848%、10.712%。[E1]

**不利结果保留：**

| 用例与进程 | 配对比例中位数 | 解释 |
| --- | ---: | --- |
| 第 1 回合真实状态序列，ios-sim-release-01 | −10.289% | 首次运行当前版本较慢；双方独立中位数之比为 −6.085%，两种口径均保留在原始聚合中 |
| 第 5 回合缺失 statuses，ios-sim-release-01 | −0.095% | 配对主口径略慢，不能用同次独立中位数比的正值遮盖 |

因此状态优化的结论限于三次聚合的约 10% 局部耗时下降，不能声称每一批都更快。UID 已包含在 collect 工作内，二者收益不能相加。局部基准没有得到“全游戏提速百分比”。[E1]

## 7. 画质、行为与门禁

### 7.1 画质保留证据

quality-preservation.json 确认生产 project.godot 与基线逐字节一致，SHA256 为：

~~~text
8b9ac7ad2504f08e65f7c1b5fb572c9042032dcd0255964ecb38706d1d915779
~~~

没有受跟踪的资源内容变更；未修改整体分辨率、纹理尺寸／导入设置、粒子数、光源、阴影、帧率目标。项目配置读取值包括逻辑尺寸 1600×720、canvas_items/expand、3D scale=1.0、MSAA=0、iOS high-refresh 开关 false。这些是既有 ProjectSettings 的只读采集值，不代表所有运行时子 Viewport 的实际设置，也不是本轮降档措施。BattleRenderer 中的画质、缩放与子 Viewport 配置逻辑没有修改。S1 的实际窗口为 2034×1398、viewport 为 1600×1099，是已有展开策略下的当前几何，不能与逻辑基准尺寸混为分辨率削减；本轮截图也不能作为像素级前后 A/B 对照。

独立 QA 工程只把主场景改为 ios_perf_entry.tscn；正式项目入口保持不变。缺失的既有资源及其 import／缓存从现有主工作区或构建缓存逐字节借用并核对 SHA，没有重新压缩、降分辨率或改导入参数。这些借用文件与构建产物不纳入本轮提交。[E3][E7]

本轮没有做实体 iPhone 的逐像素前后对照。画质保留的依据是资源／配置不变、运行逻辑约束与针对性等价检查；不能写成所有设备视觉输出已验收。

### 7.2 精准门禁

| 门禁 | 通过项数 | 关键覆盖 |
| --- | ---: | --- |
| battle_hotpath_equivalence_check | 82 | 11 组完整快照、UID 边界、移动／替换锚点、同 UID actor 替换、双缓冲、死亡／缺失单位、正常注销与 free 未注销 |
| viewport_status_regression_check | 27 | 状态、viewport 与表现回归 |
| battle_health_bar_check | 81 | 血条表现回归 |
| unit_anchor_contract_check | 51 | actor／锚点契约 |
| battle_death_exit_check | 42 | 死亡与退出路径 |
| **合计** | **283** | 五个最终日志均无 SCRIPT ERROR、ERROR 或 WARNING |

原始首次等价门禁虽然输出了 PASS 和进程退出 0，但日志出现了已释放对象类型判断错误，因此被判为失败；保留原日志，修复 Registry 后重跑。资源／导入缓存缺失导致的早期失败同样没有被当作通过。最终门禁结果见 gates/hotpath-gates-final.json，生产源码与通过门禁时保存的指纹一致。[E6]

## 8. 完整画面运行

### 8.1 S1：预热完整，战斗被 QA 超时中断

S1 使用工具版本 2、固定第 1 回合与种子 20260807，显式开启 --allow-slow-simulator-preparation。该模式只允许 iOS 的 Apple Software Renderer，准备截止预算从生产的 30000 毫秒调整为诊断用 180000 毫秒；BattleRenderWarmup 自身上限仍为 90000 毫秒。没有跳过任何预热 job。[E5]

| 项目 | S1 实际记录 |
| --- | --- |
| 资源阶段 | 13 个模型资源、66 张纹理；1079 毫秒 |
| 场景模型建立 | 21 个模型；2880 毫秒 |
| 特效预热 | ok=true，rendered=28/jobs=28；56405 毫秒 |
| 特效最长绘制帧 | 6812 毫秒 |
| 预热光照变体 | directional_only、with_omni |
| 模型首次绘制 | 87765 毫秒，两种光照变体均保留 |
| 到 ready 的实际等待 | harness_elapsed_ms=148209 |
| 画面进展 | 保存 start.png 和 mid.png，实际进入战斗中段 |
| 结束方式 | 360 秒 round_timeout，未自然结束 |
| harness 最终状态 | passed=false；rounds=[] |
| 中断后观测 | cross_battle_tween_residue=40 |

preparation.total_ms=14472 来自 BattleScreen 的引擎 delta 累计量；源码 _tick_monotonic_clock 通过逐帧 delta 更新计数。它不是此次墙钟等待时间，不能用 14.472 秒替代 **harness_elapsed_ms=148209**。准备各阶段的 Time.get_ticks_msec 测量与引擎 delta 累计量也不能随意相加或互相替换。

40 个 tween 出现在超时中断后的跨轮采样中。它记录了中断后的现场，尚不能回答自然战斗结算后是否还有相同残留。没有 end 截图和正常结束记录，因此 S1 不计完整可视战斗通过，也不使用其半场数据计算前后 FPS 提升。[E5]

### 8.2 S2：自然结束与回收检查通过

S2 使用 QA 工具版本 3，显式软件渲染诊断的轮次上限为 900 秒；准备预算为 180000 毫秒，Warmup 自身上限仍为 90000 毫秒。没有跳过预热、改质量档或改变播放逻辑，本轮未附加外部 profiler。该模式用于观察完整功能路径，不作为生产 30 秒准备门槛或实体 iPhone 性能验收。[E8]

| 项目 | S2 实际结果 |
| --- | --- |
| PID / 应用 | 96900 / com.superforge.glory.perfqa |
| PCK SHA256 | 186037a18f8977023fb87d96d17fb9e7eec8f7fb9a07a1166bde39259371e2cd |
| 模型与特效 | 21 个模型；28/28 个特效预热任务，ok=true |
| 到 ready 的实际等待 | 144981 毫秒；其中特效 53515 毫秒、模型首次绘制 87761 毫秒 |
| 质量档 | MEDIUM，quality_tier_forced=false，沿用已有自动选择 |
| 自然结算 | player_wins=true、reason=wipeout；玩家存活 12、敌方存活 0 |
| 完成标志 | setup_ready_observed、setup_ready_at_finish、playback_complete_observed 均为 true |
| 到 battle_finished 的单调墙钟 | completion_elapsed_ms=506734；含准备与播放／收尾，不能当作逻辑战斗时长 |
| 逻辑战斗时长 | sim_elapsed_sec=5.2，53 个逻辑帧、238 个演出输入事件 |
| 截图 | start / mid / end 均存在，分别在 replay_frame 3 / 26 / 53；均为 2034×1398 |
| 模型审计 | 21/21 actor 与锚点契约完整；缺失模型路径、缺失存活 actor、可见头像／body fallback 均为 0 |
| Director | resolved_cues=235、drop_count=0、missing_actor_drop_count=0、pending_timers=0 |
| 自然收尾 | 结果页已观察到且未抢跑；前后运行中 tween 均为 0 |
| Harness 结果 | passed=true、failures=[]；diagnostic_only=true |

**审计中的回退与边界仍保留。** Director 记录 budget.degraded=48（important）及两条去重后的 missing target actor for hit_number 目标锚点回退记录；后者不是实际发生次数。MEDIUM 原有 important 每 tick 8 / 同时存活 12 的预算超限时仍播放 cue，只把 profile.recovery_ms 乘以原有 0.35 系数；critical 不受这一限制。BattlePresentationDirector、VFXQualityBudget、UnitVisualResolver 与基线逐字节相同，本轮未新增或改变这一机制；这些记录不能改写成“零降级”或“逐像素全效果验收”，也不应将 235 个已解析 cue 与 238 个不同类型输入事件机械地作一一对应。原始审计保存在 director_audit.json。[E8]

本轮保存 **38 个实际渲染回调间隔样本**，排除了截图引入的后续间隔。wall_clock 统计窗口为 285.181858 秒，平均回调间隔 7504.786 毫秒、中位数 6486.945 毫秒，P95 18314.583 毫秒、最大 18464.915 毫秒；对应样本窗口 0.133248 FPS。这些是当前软件渲染诊断环境的数据，不是 iPhone 性能或优化前后 FPS 比较。旧兼容字段 average_fps=7.492501、max_frame_time_ms=150 基于被限制的引擎 delta，**不得当作墙钟显示帧率**。完整原始值保留在 frame_performance.csv 和 summary.json。[E8]

前后节点数为 33→48、对象数 1827→2716；单次运行不能区分全部缓存、驻留资源与长期泄漏，不能因为 tween=0 或门槛通过就宣称“无内存泄漏”。Release 中 static_mb / orphan monitor 仍不可用。捕获到的 stdout/stderr 没有 SCRIPT ERROR / ERROR / WARNING 行，但 stdout 为空、stderr 仅 85 bytes，不能声称已覆盖全部系统日志。结论限定为这场诊断战斗的自然完成、显式审计与回收检查通过。[E8]


## 9. 原始失败与被排除的推断

| 记录 | 实际情况 | 使用方式 |
| --- | --- | --- |
| shipping123-baseline-A1 | analytics 记录第 1 回合 render_warmup_timeout；失败后的 sample 有软件光栅化栈 | 保留为初始问题证据；不当作成功播放中的 FPS 基线 |
| shipping123-baseline-A2 | 保留再次准备阶段采样与原始日志 | 用于定位准备阶段，不用于完整战斗前后比较 |
| 首次 hotpath 等价门禁 | free 未注销引发脚本错误，尽管进程退出 0 | 判失败；修复生命周期后重新检查 |
| 隔离工作区／QA 初始导出 | 已有未跟踪资源和导入缓存不齐导致报错 | 逐字节复用既有资源后重做；不掩盖最初失败 |
| 第一次 CPU 进程的两个状态用例 | 存在负向配对结果 | 纳入 21 对聚合，不删掉 |
| 完整画面 S1 | 预热完成、战斗中段被 360 秒 QA 上限终止 | 保留失败 manifest；不把中断残留判成自然结算泄漏 |

本轮不报告 iPhone 温度变化、瓦特／焦耳、续航增加、真实 iPhone GPU 吞吐或整场 FPS 提升；没有这些测量。Release 中不可用的 MEMORY_STATIC 与 orphan 计数在 QA 输出为 null／空 CSV 字段，不能将占位零解释为“无内存”或“无泄漏”。[E1][E4][E5][E6][E7]

## 10. 可复现入口

### 10.1 冻结参照与源码身份

在隔离工作区运行以下生成器，可从固定基线提取旧函数并更新当前源码指纹；它会写 QA 冻结文件，运行后应检查 diff：

~~~bash
cd /Volumes/repository/github/GLory/worktrees/ios-perf-20261125
python3 scripts/qa/freeze_hotpath_baseline.py
~~~

基准入口为 scripts/qa/battle_hotpath_benchmark.tscn。独立 Simulator 应用通过 Documents/ios_perf_control.json 读取一次控制文件，再由 ios_perf_entry.tscn 跳转到对应场景。CPU 复现控制内容如下：

~~~json
{
  "mode": "cpu",
  "tool_args": [
    "--run", "repro-cpu-01",
    "--batches", "7",
    "--cycles", "24",
    "--out", "user://repro-cpu-01"
  ]
}
~~~

分别使用新的进程和不同 run/out 名称运行三次，保留每次 results.json、启动日志、运行时信息和 source_manifest；不能用同一文件覆盖前一次结果。每个 results.json 应有 status=finished、passed=true、17 个用例和预期的检查数，同时核对 stderr／stdout 中是否出现脚本错误。

### 10.2 可视战斗诊断

完整画面入口为 scripts/qa/battle_presentation_baseline.tscn。使用 QA 版本 3 的独立 Simulator 应用，控制内容为：

~~~json
{
  "mode": "battle",
  "tool_args": [
    "--rounds", "1",
    "--seed", "20260807",
    "--out", "user://visual-battle-repro",
    "--git-commit", "ad76ec05+ios-perf-worktree",
    "--allow-slow-simulator-preparation"
  ]
}
~~~

必须保存实际准备报告、battle_finished 结果、播放完成标志、start/mid/end 截图、性能样本和最终 manifest。--allow-slow-simulator-preparation 是软件渲染观测模式，不能作为生产准备时限验收。应用容器路径随安装变化，使用设备与 bundle 查询当前容器；本轮启动和导出参数分别保存在 launch.json、qa-pack-v3-result.json，不把历史容器路径硬编码为下次运行路径。

### 10.3 等价门禁

以下入口使用本机既有 Godot，复用已准备的导入缓存：

~~~bash
/Volumes/repository/github/GLory/glory-ios-dev/tools/godot/Godot.app/Contents/MacOS/Godot --headless --path /Volumes/repository/github/GLory/worktrees/ios-perf-20261125 res://tools/battle_hotpath_equivalence_check.tscn
~~~

另外四个回归入口与同名工具位于 tools/。接受条件同时包括退出码、CHECK_RESULT 和错误日志扫描；只看到 PASS 文本或退出 0 不足以通过。

## 11. 平台验证表

本表按照仓库要求记录整个平台层面的验证，状态全部为“仅门禁或替身”。Simulator 与 Mac 上的无界面检查不能替代对应实体设备、桌面平台或服务器部署验证。

| 平台 | 状态 | 证据与实际缺口 |
| --- | --- | --- |
| Android | 仅门禁或替身 | 共享脚本等价与回归门禁；本轮没有 Android 真机或 Android 渲染性能测量 |
| iOS | 仅门禁或替身 | 三次 Release Simulator CPU 基准与 S2 完整可视诊断通过；没有 iPhone 真机温度、功耗、帧时间验收 |
| Windows／Steam | 仅门禁或替身 | 共享脚本门禁；未在 Windows／Steam 构建上运行本轮场景 |
| 战斗服务器（无界面） | 仅门禁或替身 | 固定 BattleSimulator 输入与摘要保持一致；没有服务端部署、联机或负载验收，生产模拟器代码未修改 |

有真机后应在同一设备、固定战斗输入和相同画质设置下，分别采集前后版本的 CPU、帧时间及 Power Profiler 记录；保持亮度、充电状态和热状态可比较。Apple 的 [Power Profiler 文档](https://developer.apple.com/documentation/xcode/measuring-your-app-s-power-use-with-power-profiler)说明它可记录 CPU、GPU、显示和网络的功率影响，以及系统热状态；不同设备型号的 power impact 不能直接比较。充电时整体系统功耗可能显示为 0，不能误作低功耗证据。此项留给能够拿到设备的人员执行。

## 12. 证据索引与源码指纹

所有本机证据的共同根目录：

~~~text
/Volumes/repository/github/GLory/build/ios-perf-20261125
~~~

| 代号 | 根目录下的文件／目录 | 内容 |
| --- | --- | --- |
| E1 | simulator-hotpath-analysis.json | 21 对配对聚合、全部原始配对、负向结果、源指纹与输入摘要 |
| E2 | ios-sim-release-01/results.json；ios-sim-release-02/results.json；ios-sim-release-03/results.json | 三个进程的原始结果 |
| E3 | quality-preservation.json；qa-stage-source.json；qa-install.json | 配置与资源保留、QA 来源、独立安装身份 |
| E4 | baseline-failure-observed.json；shipping123-baseline-A1/；shipping123-baseline-A2/ | 原入口失败、准备阶段和失败后采样；含原 trace／sample |
| E5 | visual-battle-S1/entry.json；sample-trigger.json；render-ready-sample.txt；battle-output/manifest.json；battle-output/round_01/ | S1 条件、ready 触发、短采样、实际失败与截图 |
| E6 | gates/hotpath-gates-final.json；hotpath-implementation-sha256.json 及各门禁日志 | 五项最终门禁、生产身份和原始失败记录 |
| E7 | gates/borrowed-resources.json；qa-reused-resources.json；qa-pack-incomplete-stage.json；qa-pack-v3-result.json | 借用资源指纹、初次失败与版本 3 导出记录 |
| E8 | visual-battle-S2/verified-summary.json；launch.json；observation-timeline.json；battle-output/ | 自然完成的全部结算、38 个原始帧间隔、模型／Director 审计、截图与回收记录 |

E8 的各子文件位于 visual-battle-S2/ 下。E5 的 sample-trigger.json、render-ready-sample.txt 位于 visual-battle-S1/ 下；E6 的 hotpath-implementation-sha256.json 也位于 gates/ 下。上述路径是 Mac 上的实际证据路径，不是要加入 Git 的构建文件。

三轮 results.json 的 SHA256：

| 进程 | SHA256 |
| --- | --- |
| ios-sim-release-01 | d0de0bacf53709590de5cee0b770da6388176d20a99371c64100e77a2b7175d2 |
| ios-sim-release-02 | 8bf91daa56d94fbc5f6d4e8432f948935b46ac9c966e18d2241a073d145b13af |
| ios-sim-release-03 | 9257aba638fc7a979a5b1365cb52223974b8e16b347231fdb18d372a3ce5bf5e |

三次 source_manifest 的规范化 SHA256 均为 503aaff35bc5708462ec131e7decf886fa4c7f3c629551746edf025fea17f87b。四个生产文件的已测量内容指纹：

| 文件 | SHA256 |
| --- | --- |
| scenes/battle/BattleRenderer.gd | 1d5c9b9bbda6fd6dc2f9071672b6660ea9cd3e7b980c0403eb5827056892b64c |
| scenes/battle/BattleVfx.gd | bff19790c44974eac46faa984402e632b0b561c3b51d07ca27464478a418b6f1 |
| scenes/battle/StatusVFXController.gd | 8758e90187ce40d54f755d27c6f7521e1923e80898e870ba56a248b09cd7ff4d |
| effects/runtime/presentation/UnitActorRegistry.gd | 06f22084f5c8ce4fa906cf1200ebbeb553063757df81c7ffe4d77812b11cfd18 |

官方说明核对日期为 2026-11-25。Simulator 与 Power Profiler 的说明只用于限定解释范围，不替代本轮原始日志。新增 QA 入口、冻结函数、等价门禁和本文用于复现与审查，不作为生产优化百分比的来源。
