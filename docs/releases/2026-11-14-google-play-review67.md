# Google Play 1.0.2 (67) 正式候选包

- 来源：干净源码 `781bfc3f748fe501569763087d2f0210f1549103`，官方 AAB 精简入口，`--server-environment prod`。
- 包名：`com.glory.game.google`，版本 `1.0.2 (67)`。
- 成品（外层工作区）：`build/aab/Glory-1.0.2-67-20261114-080951-release.aab`，708557941 字节。
- SHA-256：`502d6762fe36f028ebfe0ee5640f34dc9de05fad015ae702e1f199e7c0f59492`。
- 正式 API `https://api.gogoglory.com`，战斗 `battle.gogoglory.com:8080`、协议46、正式DTLS证书。
- 精简剔除372项无引用资源，保留arm64/armv7及语音；签名、bundletool、Release、SDK36、ARM64 16KiB对齐通过。

## 补丁基线

固定目录 `build/patch-baselines/glory-android-20261114-prod-review67/`（外层）；base.zip SHA-256 `10a00547c4e1668e98012193ebdcaf38c6d0c3bd16946f076128b2fca1daf8cc`。6230个文件与实际签名AAB的 `assetPackInstallTime/assets/` 逐字节一致。

默认指针 `build/patch-baselines/current-android-production.json`，在外层执行：

```sh
./tools/build_android_production_patch.sh --check
./tools/build_android_production_patch.sh
```

新入口仅构建本地累积补丁，不同步、不上传、不更新服务器。11项防护测试通过；保留原包导入缓存的独立副本与输入哈希检查，同源码重导出严格为 `no_changes`。首次无缓存复测的导入噪音仅本地归档，未发布。不得为内容不同的新全量包复用base_id，不得改旧基线，不混用iOS100或旧内部nightly。

## 验收与发布状态（2026-11-14 09:06，UTC+8 回读）

- 正式API健康、新域名解析、真实只读ENet/DTLS协议46握手、30秒心跳及公开房间列表通过。未登录、入座或开局；语音仅验证TLS及未认证WebSocket入口，不声称音频已验收。
- 新base_id补丁接口返回 `action=none`，无不适用的旧补丁。
- 新包已上传Google Play内部轨道，远端哈希及版本回读一致；正式轨道已创建 `release 2`，版本为 `67 (1.0.2)`。已在 Console 最终点击“将更改内容送审”，随后显示“已将11项更改送审”和“正在审核中的更改”，其中包括67正式包及商店资料。回读时快速检查仍在进行，显示“至多还需14分钟”；这只是当时的预检提示，不是人工审核完成时间或获批承诺。
- 自管式发布保持开启；本次没有执行公开发布，旧56也未公开。新67尚未获批，待快速检查及Google后续审核完成后再核对发布状态。提交证据：`publishing67-submitted-ui.txt`、`publishing67-submitted.png`；正式版验证页：`production67-validation-ui.txt`。
- 正式轨最终回读明确显示“版本67 (1.0.2)正在审核中”；应用提交活动记录新增提交编号 **9**，提交时间 **2026-11-14 09:02（UTC+8）**，状态“审核中”，范围为正式版、商品详情、应用内容。证据：`production67-submitted-ui.txt`、`production67-submitted.png`、`submission9-ui.txt`、`submission9.png`、`submission-receipt.json`。此状态不代表已经获批；快速检查完成状态尚未单独验收。
- vivo V2527A 已使用 Play 签名的六个分包从54覆盖安装至67，保留原数据。正式服账号恢复、主菜单、设置、帮助、两次自定义空房联机通过，未开战或购买。记录到两次 `EXIT_SELF/status0`：08:43:57 首次离开空房时返回手机桌面；08:49:36 显式重启后观察期间再次退出。第二次建房及返回主菜单曾正常，但两次退出的根因均未定位，后一次缺少进程日志；没有足够证据把它们归为崩溃或特定按钮问题。基础流程通过不等于稳定性、实战或支付已验收。详见 `phone67-smoke-result.json` 与 `phone67-exit-info-final.txt`。
- 中文 `zh-CN`、英文 `en-US`、马来文（马来西亚）`ms-MY`、印尼文 `id` 的名称、短描述、完整描述均已保存并回读逐字段一致，随本次正式包一并送审。自然覆盖自走棋/auto chess、3v3、阵容与羁绊，无关键词堆砌或排名保证。
- 官网联系地址已保存并回读为 `https://www.gogoglory.com/`；隐私及删号新链接已分别保存，使用新域名下现有静态法律页。
- 六张新图来自用户指定Steam官方页，原图1920x1080，未裁切放大，不称为本次手机实拍。`zh-CN` 默认图组的6张手机截图已保存，远端哈希及排列与选定素材完全一致；其余三种语言没有独立图片覆盖，使用默认图组。四语及图片/官网回读证据为 `store-readback-final.json`（2026-11-14 09:01:44，UTC+8）。
- AI来源标签已通过最终UI只读回验：重新进入已送审商品详情，第2步“标记使用AI”为选中状态；打开标签对话框，应用图标、置顶大图及6张新截图共8个复选框均为 `Value: 1`。证据为 `ai-labels-final-ui.txt`、`ai-labels-final.png`。Publisher API 的 `aiGeneratedStateUnspecified` 没有反映此UI声明，按实际API值保留，不用它否定UI回验结果。本次回验没有修改资料或重复提交。

本地证据位于外层 `delivery/google-play-review-20261114/`。构建、内部上传、正式送审、获批、公开发布及真机支付分别记录。
