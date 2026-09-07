# Glory V12 执行状态（2026-09-07）

基线：`f1f8324`，分支：`codex/v12-execution`。

本清单以 `GLORY_V12_DOCX_真机复核与资源修复清单_20260906.md` 为验收来源，但每项先与当前代码和 V2/V3 完成记录对账；已经完成的工作只复验，不重复修改。

| 阶段 | V12 项 | 当前判断 | 下一动作 |
|---|---|---|---|
| 1 | V12-02 宝藏详情/长按误领取 | **完成（待真机触控复核）** | 详情职责已迁入面板；长按/拖动取消不领取；三张 DOCX 卡与中英文已纳入门禁 |
| 2 | V12-10 APK 身份可信 | **工程闭环完成（待真机安装复核）** | 唯一 build ID、dirty 指纹、manifest/bundle/AndroidManifest 全字段回读、产物映射已接入 |
| 3 | V12-03 教程/语言持久化 | 待对账 | 先核对现有 schema；旧存档策略单独留为产品决定 |
| 4 | V12-04 教程气泡稳定 | 待对账 | 先加脏因记录，再限制无输入重排 |
| 5 | V12-05 / V12-12 可读性与 QA 入口 | V12-12 的 Release 隐藏已有门禁；其余待复验 | 复验羁绊颜色、QA 能力检测和大厅布局 |
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
