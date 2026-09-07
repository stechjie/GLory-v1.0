# Glory V12 执行状态（2026-09-07）

基线：`f1f8324`，分支：`codex/v12-execution`。

本清单以 `GLORY_V12_DOCX_真机复核与资源修复清单_20260906.md` 为验收来源，但每项先与当前代码和 V2/V3 完成记录对账；已经完成的工作只复验，不重复修改。

| 阶段 | V12 项 | 当前判断 | 下一动作 |
|---|---|---|---|
| 1 | V12-02 宝藏详情/长按误领取 | **完成（待真机触控复核）** | 详情职责已迁入面板；长按/拖动取消不领取；三张 DOCX 卡与中英文已纳入门禁 |
| 2 | V12-10 APK 身份可信 | **工程闭环完成（待真机安装复核）** | 唯一 build ID、dirty 指纹、manifest/bundle/AndroidManifest 全字段回读、产物映射已接入 |
| 3 | V12-03 教程/语言持久化 | **工程闭环完成（待真机强杀复核）** | 语言与 completed/skipped/in_progress 已原子落盘；旧档不猜测完成状态；设置页可重播 |
| 4 | V12-04 教程气泡稳定 | **工程闭环完成（待真机录屏复核）** | 稳定尺寸测量、脏输入缓存、同目标位置黏着、详情暂停与 reduced-motion 已接入 |
| 5 | V12-05 / V12-12 可读性与 QA 入口 | **工程闭环完成（待真机视觉复核）** | 羁绊锁定差额与主题详情底板完成；自测按真实资源能力显隐；大厅重叠已修 |
| 6 | V12-06 / V12-07 战斗与模型表现 | 需要固定阵容/回放；不改仿真 | 建取证矩阵，仅做表现层校正；模型/VFX 改动另行审批 |
| 7 | V12-08 / V12-09 AI 与经济量化 | 只允许一致性修复和量化 | 统一口径测试、至少 100 seeds；不自动改平衡 |
| 8 | V12-11 雷电/PC | 缺精确平台资料 | 仅建立诊断入口；拿到环境后复现 |

## 固定边界

- 不把 DOCX 建议自动视为已批准玩法。
- 不改变宝藏效果、候选、价格、AI 策略或战斗规则。
- 不伪造资源 manifest、构建身份或真机结论。
- 每阶段先跑定向门禁，再跑全量门禁；外部条件不足时明确记录为阻塞项。

## 阶段 0 / 1 验证记录

- 官方冻结包：`glory-assets-ed99230ce8d75f20-f238d981a1b06834.zip`。
- 隔离 worktree 恢复后：`asset_delivery` 2701/2701，missing/size/hash/extras 全为 0，inventory 为 `ed99230ce8d75f20…`。
- 冷导入已从无旧 `.godot` 缓存的状态完成；FBX 内嵌贴图历史警告仍存在，但显式资源门禁为绿，不在 V12-02 中改模型。
- `prep_detail_overlay`：32/32。
- `prep_text_coverage`：93/93。
- `modal_lifecycle`：433/433。
- `dynamic_call`：201/201。
- 正式真机仍需复核 0.5 秒短按、1 秒/4 秒长按、拖出/系统取消、已获得图标以及返回键层级。

## 阶段 2 验证记录

- 旧 V12 APK 实测被新门禁拒绝：build_info 声明与包内 manifest/bundle 不一致，且 build_info 的空 `versionName` 与 AndroidManifest 的 `1.0.0` 不一致。
- 新增 `tools/apk_identity.py`：构建前生成 schema 2 身份；构建后逐字段回读，并输出 APK 条目库存和源资源到 `.ctex/.scn/.gdc` 的映射。
- dirty 身份同时覆盖 tracked diff 与未忽略的 untracked 文件，不再只记录“脏文件数量”。
- Android/Windows 模板显式携带 `assets.manifest.json`、`assets.bundle.json`、`build_info.json`，并显式固定 Android `versionName=1.0.0`（与此前隐式产物一致）。
- 首次新包内容扫描发现 `reports/` 被带入 APK；已加入两个导出模板的排除规则。复验 `APK_CONTENT_SCAN status=PASS entries=3577 violations=0`。
- 新包身份复验：build_info、manifest、bundle、AndroidManifest 一致，642 条产物映射，零 identity failure。
- 当前仅是本机 Debug APK 工程验证；没有私有 keystore，因此不声称完成 Release 签名或商店包验收。

## 阶段 3 验证记录

- `profile.json` schema 升至 v4，新增 `locale`、`language_selected`、`onboarding_version`、`onboarding_status`。
- 旧档统一迁移为 `legacy_unknown`，不会根据金币、宠物、图鉴或局内存档猜测“已经完成教学”；旧用户仍按原行为明确选一次语言并进入/恢复教学。
- 新用户选定语言后原子落盘；已完成或明确跳过的用户冷启动直达主菜单；`in_progress` 用户恢复断点或从教学开头开始。
- 教学完成/跳过严格先写账户状态，再清教程断点；账户写入失败时保留断点。
- 设置页语言选择使用同一持久化入口，并新增中英文“重新体验教学”入口。
- `PlayerProfile` 使用临时文件回读校验、`.bak` 轮换与损坏主档兜底；其初始化早于 `SaveManager`，因此不依赖尚未 ready 的 autoload。
- 新增 `onboarding_persistence` 门禁：20/20，覆盖旧档迁移、语言落盘、完成后三次冷启动、跳过、重播、损坏主档兜底与 Main 调用顺序。
- 定向回归组：`onboarding_persistence` 20/20、`ui_component` 134/134、`tutorial_checkpoint` 180/180、`tutorial_overlay_layout` 424/424、`tutorial_step15_flow` 217/217、`board_readability` PASS；`polluted=false`。（`board_readability` 是旧式检查，未输出 checked 计数。）
- 仍需真机复核：选语言后强杀、教学中强杀、跳过确认后强杀、完成后连续三次冷启动，以及设置页重播入口。

## 阶段 4 验证记录

- 根因确认：`PrepScreen._process()` 每帧刷新教程层，而旧 `_fit_bubble()` 每次 `reset_size()` 后立即读取容器高度；异步布局可在旧/新高度间切换，进而改变候选评分。
- 保留原有安全区、目标可见度和 12 个候选位置；新增步骤/目标/文案/安全区/禁区的脏输入缓存，相同输入直接 no-op。
- 气泡高度改由 `get_combined_minimum_size()` 一次测量后显式固定，不再从刚 reset 的尺寸反推。
- 同一语义目标沿用上次位置；只有超出安全区，或目标/任一禁区遮挡超过 10% 才重新选位。2px 内的容器几何噪声不触发重排，累计真实位移超过阈值仍会更新。
- `layout_debug_snapshot()` 记录 step、输入签名、目标上下文、bubble rect、候选编号、重排次数和原因，供真机日志定位。
- 详情 Popup 打开时暂停整个教程层，关闭后恢复；开启“降低动态效果”时不创建箭头呼吸 tween。
- `tutorial_overlay_layout` 扩为 528/528：四种长宽比、每个可解析步骤执行 600 次无输入刷新，位置与重排计数均不漂移，同时保留 ≥90% 目标/禁区可见度。
- 回归：`tutorial_checkpoint` 180/180、`tutorial_step15_flow` 217/217、`prep_detail_overlay` 32/32、`modal_lifecycle` 433/433、`ui_component` 134/134；`polluted=false`。
- 仍需真机复核：步骤 4/17 原复现路径静止 10 秒，以及商店开闭、切卡、拖拽各 10 次的视觉连续性。

## 阶段 5 验证记录

- 未达成羁绊不再使用 `#686868` 压暗整段；状态明确显示“未解锁 · 还差 N 人 / Locked · Need N more”，正文使用 `GloryTokens.TEXT_SECONDARY`，已达成正文使用主文字色。羁绊阈值和效果未改。
- 羁绊/宝藏共用详情接入 `GloryTheme` 的高不透明 `PopupPanel` 底板，16px 内边距、19px 正文和固定视窗滚动；明亮战场不再直接穿透文字。
- `prep_text_coverage` 扩至 127/127，覆盖中英文四种族最高阈值前后、人族 1/2/6/7、底板不透明度、字号、边距和滚动合同。
- 自测按钮从“仅 Debug”升级为“Debug 且 `OfficeTestScreen.tscn` 实际存在”；普通 Debug APK 仍排除 `officetest/` 时按钮不会出现，本地完整工程中可用。Main 在清空大厅前再次做能力防御。
- `OfficeTestSmoke` 实际通过：6 个阵容单位、140 帧回放、96 个格点、结算与返回编辑态均正常，fails=0。
- 大厅模式状态从 y=167 移到 y=142；资源预载文字从顶部席位区移到右侧朋友栏下方。`responsive_layout` 在六种分辨率逐一验证状态、资源文字与六个席位标题不相交，114/114。
- 回归：`ui_component` 134/134、`release_debug_ui` 9/9、`panel_scene` 43/43、`prep_detail_overlay` 32/32、`tutorial_overlay_layout` 528/528；均为绿色。
- 仍需真机复核：草地背景中英文羁绊详情、人族 1/2/6/7，以及离线大厅在目标设备上的最终视觉间距。QA 真机若要显示自测入口，构建时必须实际包含 `officetest/`；普通包会按能力隐藏。
