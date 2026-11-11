# iOS 1.0.2：Guideline 2.3.8 修复

## 本次拒审事实

- 提交 ID：`5d04af88-0c8d-4206-8519-1538cf1d415a`。
- Apple 于 2026-11-09 23:29（页面显示时间）反馈，审核设备为 iPad Air 11-inch (M3)，审核包为 1.0.2 (81)。
- 本次唯一列出的条款为 **2.3.8 Performance: Accurate Metadata**：商店名称 `GLory Auto Chess`，设备名称 `Glory Beta 0.04`，容易造成用户混淆。
- 2026-11-11 实时读取：App 已拒绝，三档钻石内购均为“可供审核”，不代表内购已获批。
- 直接读取签名 IPA 证实 81 及后来的测试包 92 都仍带旧 `CFBundleDisplayName`。仅修改商店介绍或游戏内文字无法修复已经上传的包。

## 修复

1. 源工程声明 iOS 专属名称 `GLory Auto Chess`；中英文菜单标题也统一名称。
2. IPA 入口在隔离 stage 中统一名称并清除旧名称覆盖，沿用 Bundle ID `com.superforge.glory`。
3. 在最终 IPA 的 `Info.plist` 和各语言 `InfoPlist.strings` 中校验桌面显示名。名称缺失、旧测试名或语言覆盖不一致均停止交付。
4. iOS 精简 patch 采用同一工程名称规则，避免新基线与后续手工/nightly stage 不一致。名称元数据仍须新 IPA，不能由 patch 修改。
5. 保留桌面/服务器的旧工程名，以免改变其 Godot 存档及服务密钥目录。

## 验证与证据

- iOS 构建回归：24 项通过，覆盖旧名称、未展开的 Xcode 变量、二进制/XML/OpenStep 本地化覆盖等。
- Patch 回归：8 项通过，包含 Android Release/Debug、Windows、iOS 的真实 Godot 导出。iOS 测试模拟从原源码重建 stage，再生成累计补丁。
- 新名称校验能拒绝现有 81/92 旧包，证明可检测这次实际拒审原因。
- 资源同步成功：远端 4,427 个文件，核验 706、跳过未变化 3,705，保留本地版本 16，无错误。
- App Store Connect 中英文描述、Support/Marketing URL、Privacy/隐私选择 URL 已换到 `test-api.gogoglory.com`；保存后重新读取确认，数据收集声明保持原有 15 项。
- 外层工作区证据：`delivery/app-review-20261111/`，包含拒审原文、旧包检查及回归日志；新包构建结果以同目录 `ipa-result.json` 为准。

## 本地正式服候选包

- `1.0.2 (93)`，源码 `b70c9ae9`。
- IPA：外层 `build/ipa/Glory-app-store-20261111-230752-272958-b70c9ae9.ipa`，630.9 MiB。
- SHA-256：`7872ace01b27249713bd849443a1e8cbbfad4699391a9cd592884f6c5565785d`。
- 最终 IPA 读取 `CFBundleDisplayName=GLory Auto Chess`、`CFBundleIdentifier=com.superforge.glory`，设备族 iPhone+iPad。
- ZIP/签名/arm64/描述文件/StoreKit/构建身份及补丁基线逐文件一致性校验通过。排除 365 个无引用资源。
- 正式账号接口 `https://api.gogoglory.com`，战斗 `battle.gogoglory.com`，已选择正式服 DTLS 证书。
- 仅生成本地候选包，未上传、未安装、未重新提审；93 新包真机验收仍需完成。

## 下次提审

- 使用新的正式服候选包，不复用 81。项目 11-11 部署记录表明服务器协议及域名已更新，候选包须显式选 `--server-environment prod`。
- 2026-11-11 已核对正式 API `/health` 返回 `environment=prod` 且配置完整；新候选基线的补丁检查为 `action=none`、`required_patch_seq=0`、无 hotfix。
- 重新安装候选包后，在 iPhone 与 iPad 核对桌面名称、启动、教程/对局、三档商品及支付到账、账号注销。当前构建/代码回归不替代新包真机验收。
- 商店 Support / Privacy 链接已改用已验证返回 HTTP 200 的 `https://test-api.gogoglory.com/beta/support.html`、`https://test-api.gogoglory.com/beta/privacy-en.html`（中文为 `privacy.html`）。隐私选择链接为同站点 `delete-account.html`。测试服旧 DuckDNS 入口已在另一个发布任务中停用；不要恢复旧站点来兼容旧包。
- 提交时保留三档内购关联，更新审核说明/录像中的候选 build，继续手动发布。此任务不自动重新提审。

## 审核回复草稿（更换并验收新包后发送）

Thank you for identifying the naming inconsistency under Guideline 2.3.8. We have corrected the installed app display name from "Glory Beta 0.04" to "GLory Auto Chess", matching the App Store name. The bundle identifier remains com.superforge.glory. We have also added release validation of the final IPA's display name and localized overrides to prevent the old test name from appearing in future builds. Please review the replacement build selected for this version.

参考：[Apple App Review Guidelines 2.3.8](https://developer.apple.com/app-store/review/guidelines/#accurate-metadata)。
