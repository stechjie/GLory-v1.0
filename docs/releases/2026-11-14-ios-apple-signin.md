# iOS Apple / Google 登录交付记录（2026-11-14，11-15 更新）

最终交付候选为正式服 **Ad Hoc 1.0.2 (105)** 与 **App Store 1.0.2 (106)**，均已通过成品检查并独立固定精简基线。105 已覆盖安装，由用户本人确认系统 Apple 登录后成功返回原账号大厅，无误顶号，使用新凭据冷启动恢复也已通过；106 仅完成签名包及成品验证，未安装真机、未上传 TestFlight。

**101 为中间验证包；102、103 为此次竞态修复前的历史包，已被 105/106 取代，不作为最新交付候选。** 旧服务未返回 Apple 撤销状态时的客户端提示兼容，继续包含在两份最终候选中。

用户此前在 103 上本人完成 Apple 绑定及冷启动恢复；105 已通过实际 `/v1/auth/provider` Apple 重新登录，玩家身份相同，新的续期凭证已保存，资料与游戏存档字节完全不变。105 最后一次强制结束后使用该新凭据冷启动恢复已通过，玩家身份及资料/存档字节继续一致；最终资料页仍显示相同好友编号和 Apple 绑定。

## 2026-11-15 账号切换竞态修复

主动使用 Apple / Google 切换账号时，服务端 `/v1/auth/provider` 会撤销旧会话；旧 WebSocket 或旧会话 HTTP 响应若先到，原来可能把玩家自己的换号操作误判为被另一台设备顶号。此次处理如下：

- 先暂停旧 WebSocket 传输，保留现有账号凭证；正在进行的续期先收尾，保存已轮换的 refresh 凭证，再进入提供方请求。
- 使用会话 generation 隔离旧 HTTP 响应，防止旧会话的迟到响应污染新登录；切换期间阻止新的旧会话请求与续期。
- Main 的账号连接看门狗在主动切换期间暂时豁免，避免把有意暂停连接当成断线。
- 提供方请求失败时保留原 sid，仅按原有意图恢复旧连接；不自动重新登录、夺取另一台设备的会话，也不清除真正收到的 kicked 状态。

最新 provider 检查 **52 项**、真实 loopback **HTTP/session 集成检查 61 项**通过，覆盖旧 HTTP 409 先于 provider 成功、提供方失败、真实顶号优先及在飞续期先收尾等情况。该集成夹具没有执行真实 loopback WebSocket 握手，不能称为 WebSocket 端到端集成验收。检查所借用的原 **21 份本机测试数据文件已恢复并逐项一致**。

证据为外层 `build/ios-signin-qa/account-provider-switch-fix.log`、`account-switch-integration.log`；成品和真机结果分别记录在后文。

## 最终 App Store 106

准确结果文件：外层 `build/ios-signin-qa/ipa-app-store-login-fixed-result.json`。

| 项目 | 已回读结果 |
| --- | --- |
| 版本 / 构建号 | `1.0.2 (106)` |
| IPA | 外层 `build/ipa/Glory-app-store-20261115-003004-682968-4424191d.ipa` |
| 大小 | 669,773,340 字节 |
| IPA SHA-256 | `fb1f1bb4e37a214d28deecb18b649cf043eac4ac4ae28bec428e999ab4363891` |
| 分发及服务环境 | App Store、iPhoneOS arm64 Release、正式服 |
| 描述文件 UUID | `faf4342d-e8ef-493a-9c25-a08fd3899ed2` |
| 成品验证 | ZIP CRC、codesign、arm64、实际描述文件、PCK 身份、StoreKit、Apple/Google 登录配置、Google SDK 隐私清单、Game Mode 和显示名均通过 |
| 精简基线 | `glory-ios-20261115-prod-signin-appstore-r3`；6,238 个文件逐项匹配该 IPA |
| 分发及设备状态 | 本地产物，未安装真机，尚未上传 TestFlight 或提审 |

105 和 106 均包含本轮账号切换竞态修复及旧服务注销提示兼容，使用相同正式账号接口和战斗环境。成品验证与真机登录、冷启动、跨端恢复分别记录。

## 历史 App Store 102（已被修复版本取代）

准确结果文件：外层 `build/ios-signin-qa/ipa-app-store-final-result.json`。

| 项目 | 已回读结果 |
| --- | --- |
| 版本 / 构建号 | `1.0.2 (102)` |
| Bundle ID | `com.superforge.glory` |
| 设备显示名 | `GLory: Auto Chess & Team PvP`；本地化名称检查覆盖 `en.lproj` |
| 分发方式 | App Store，iPhoneOS arm64 Release |
| IPA | 外层 `build/ipa/Glory-app-store-20261114-224235-143052-4424191d.ipa` |
| 大小 | 669,786,146 字节 |
| IPA SHA-256 | `b14e8a3f8e6ae28c265cc4a54157c85cd8bcc4a85fd8eff65bdb0681f854453c` |
| 源码身份 | `4424191d60a1ef02042bf4453a459cecec94dd16` 对应的本地工作区快照；含未提交变化，以结果文件和固定快照为准 |
| 账号接口 | `https://api.gogoglory.com` |
| 战斗入口 | `battle.gogoglory.com:8080`；正式服 DTLS pin |
| DTLS 证书 SHA-256 | `deb19b3e25862e2008e1e7c00211c41b39f92a5bcf428f990230cb260eca5354` |

使用外层 `./tools/build_ipa.sh --method app-store --server-environment prod --version 1.0.2` 构建，并指定独立 patch 配置与准确结果文件。构建保留原始画质及语音能力，产物位于 GLory 工作区内。

102 当时的 ZIP CRC、codesign、arm64、实际描述文件、PCK 构建身份、StoreKit、Apple 登录、Google 登录、Google SDK 隐私清单、Game Mode 和显示名检查均通过，但不包含 11-15 新增的账号切换竞态修复。上述包内检查不代替提供方授权、服务端登录和设备操作验收。

## 真机直装包

当前修复版准确结果文件为外层 `build/ios-signin-qa/ipa-ad-hoc-login-fixed-result.json`。

| 项目 | 已回读结果 |
| --- | --- |
| 版本 / 构建号 | `1.0.2 (105)` |
| IPA | 外层 `build/ipa/Glory-ad-hoc-20261115-001958-501888-4424191d.ipa` |
| 大小 | 669,772,305 字节 |
| IPA SHA-256 | `c67630540d8ca95694e28e20ff59a43b9b6772e4ab4ffde06007066bbde446a0` |
| 分发及服务环境 | Ad Hoc、iPhoneOS arm64 Release、正式服 |
| 安装资格 | 描述文件登记的唯一设备与已配置的 iPhone 匹配；本记录不保存设备标识 |
| 成品验证 | 签名、Apple 权限、Google 配置及隐私资源、StoreKit、PCK 身份、Game Mode 和名称均通过 |

105 已覆盖安装，`device-app105.json` 实读构建号为 105；安装前后比较的 **7 份账号、资料及存档文件全部逐字节一致**，见 `device-preservation105-after-install.json`。用户随后本人确认原生系统 Apple“登录”，实际 `/v1/auth/provider` 重新登录成功，返回原大厅，无误顶号；玩家身份相同，新的续期凭证已保存，`profile.json` 与游戏存档字节完全不变。

## 分阶段真机证据

103 与 105 的验收按不同阶段分别记录：

- 首次系统 Apple 授权窗口返回原游客界面后，账号及资料保持一致；自动关闭动作未实际执行，不把该次返回描述为代理已点击取消。
- 用户本人确认 Apple 授权后，权威资料列表显示 Apple 已绑定；玩家身份和好友编号相同，新的续期凭证已保存，`profile.json` 与游戏存档字节不变。
- 强制结束并重新启动 103 后恢复同一玩家；大厅昵称、等级/经验与余额一致，资料及游戏存档字节不变。该阶段验证的是保存凭证后的冷启动恢复。
- 105 的实际 Apple 提供方重新登录已通过：用户本人完成系统确认后回到原大厅，无误顶号；玩家身份一致，新的续期凭证已保存，资料和游戏存档字节完全不变，大厅昵称、等级/经验与余额一致。
- 105 使用刚保存的新 Apple 登录凭据，完成强制结束并重新启动，冷启动恢复通过；玩家身份相同，资料和游戏存档字节完全不变，大厅昵称、等级/经验、金币与钻石均为原值，最终资料页确认相同好友编号和 Apple 绑定。此项有独立 105 证据，不借用 103 的结果。
- Google 入口与既有配置保留；本轮未新绑定 Google 或重复执行 Google 真实登录，安卓/iOS 跨端恢复未覆盖。

汇总证据为外层 `build/ios-signin-qa/device-login-acceptance.json`。105 的覆盖安装和 7 文件一致性另有独立记录；原 21 份本机集成测试数据的恢复检查属于开发机数据保护，不与手机文件检查混为一项。

## Apple 签名材料

用户提供的两份新描述文件已从 Downloads 移至外层归档目录：

`ios-signing-20260913/ios_distribution/20261114-apple-signin/`

| 方法 | 归档文件 | UUID |
| --- | --- | --- |
| App Store | `Glory_AppStore_2026.mobileprovision` | `faf4342d-e8ef-493a-9c25-a08fd3899ed2` |
| Ad Hoc | `Glory_AdHoc_2026.mobileprovision` | `3626456c-111c-4ec2-9c2b-bec660d2e3f7` |

两份文件均含 `com.apple.developer.applesignin = [Default]`，并匹配现有分发身份 `iPhone Distribution: KOH CHEE HUI (D5ANXXK2R2)`，公开证书 SHA-1 为 `55A4B50154A26952AE8D6A2727A8D90B09F553E0`。105 和 106 的实际签名及内嵌描述文件已回读通过。收存证据为外层 `build/ios-signin-qa/profiles-installed.json`；本记录不保存设备标识或秘密。

新增描述文件已解除原生 Apple 登录的签名阻断；这不代表本机登录账号已取得该 Apple 开发者团队的管理权限。

## 登录行为与正式账号服务配置

- Apple 使用系统 AuthenticationServices，Google 使用官方 GoogleSignIn iOS SDK 10.1.0。均由玩家点击入口后发起授权；启动页保留游客入口，资料页支持绑定和切换账号，已有账号优先使用保存的续期凭证。
- 每次授权生成随机 nonce，提供方收到 SHA-256，账号服务收到原文。身份证明和一次性授权码仅在内存中使用，不写入日志或存档；取消授权保留当前账号。
- Google 回调覆盖 UIApplicationDelegate 与 UISceneDelegate。最终 IPA 已核对 `GIDClientID`、`GIDServerClientID` 及反向 iOS client ID URL scheme。

| Google 配置 | 公开号 |
| --- | --- |
| iOS OAuth client ID | `434401179227-msjl0r1k8klm3ev0ihvkf40inh9e55ql.apps.googleusercontent.com` |
| Web / server client ID | `434401179227-ilomq9be809omabde230n88bbc1t0do8.apps.googleusercontent.com` |
| 回调 scheme | `com.googleusercontent.apps.434401179227-msjl0r1k8klm3ev0ihvkf40inh9e55ql` |

Google iOS 客户端属于现有登录项目 `434401179227`，绑定 `com.superforge.glory`、App Store ID `6811578280` 和 Team `D5ANXXK2R2`。Google 同意页仍是 **Testing**，可用账号限于其测试用户名单；本轮未变更该发布状态。

正式 Supabase 项目 **`jiqctertgtxoabvyhbid` / `glory-prod`** 已保存并独立回读：

- Apple 已启用，原生受众为 `com.superforge.glory`；原生 ID-token 流程无需配置 Apple OAuth client secret。
- Google 已启用，保留原 Web ID 在前、追加新 iOS ID；`Skip nonce checks=false`，继续校验 nonce，既有 secret 保留。
- `Allow manual linking` 已开启；Steam 及其他既有提供方配置保留。

配置证据位于外层 `build/ios-signin-qa/`：`google-ios-client.json`、`supabase-prod-google-readback.json`、`supabase-prod-apple-readback.json` 和 `supabase-provider-setup.json`。后台配置回读与真实 token 交换分别验收；105 Apple 实际登录证据见前文，Google 真实登录及安卓/iOS 同账号恢复未在本轮覆盖。

测试 Supabase 项目 **`tzkysvnpjmgzfbvazugi`** 仍未配置或验收：正式服管理账号访问时明确收到无项目权限提示，当前本机凭据文件没有测试 Supabase 对应账号。不能将正式项目的配置结果套用于测试项目。

## 注销兼容与待补密钥

102 起已在删除账号前读取其登录绑定，该兼容继续包含在 105/106 中。删除成功后，若现网旧服务未返回 `apple_revocation_required`，客户端会根据已知 Apple 绑定显示常驻手动撤销提示；新服务明确返回的布尔状态优先。此兼容不会把 Google 或游客账号推断为 Apple 账号。

新增后端逻辑可使用一次性授权码兑换并核对当前 Apple 身份，再自动撤销授权。本轮 **未部署该后端变化**。专用 Sign in with Apple `.p8` 与 Key ID 尚待提供及配置，影响的是服务端自动撤销，不阻断原生 Apple 登录。自动撤销仍需部署、配置和真实账号验收；App Store Connect API 密钥不能替代该专用密钥。

## 精简基线固定保留

105 的当前独立基线为 `glory-ios-20261115-prod-signin-adhoc-r2`，固定目录为外层 `build/patch-baselines/glory-ios-20261115-prod-signin-adhoc-r2/`。

- `base.zip` SHA-256：`0d888e2f04301d065ba1e8c2a9dfcb60f35ed69b34acf381e9a218a102ebbefc`。
- **6,238 个基线文件与 105 IPA 逐项一致**；固定目录保留准确结果、清单、配置、精简报告、锁定记录和源码快照。
- 固定记录确认运行源码与本次正式服配置选择一致，含 `AccountManager.gd`、`RealtimeService.gd` 和 `Main.gd` 的切换修复。

106 的当前独立基线为 `glory-ios-20261115-prod-signin-appstore-r3`，固定目录为外层 `build/patch-baselines/glory-ios-20261115-prod-signin-appstore-r3/`。

- `base.zip` SHA-256：`d4256c91f31cf52e441beaabec32e12dbc6cbfcd090e8d3d87b000946bb58feb`。
- **6,238 个基线文件与 106 IPA 逐项一致**，独立保存准确结果、基线清单、配置、精简报告和锁定记录。
- 105/106 各自保留源码快照，均包含 `AccountManager.gd`、`RealtimeService.gd` 与 `Main.gd`；固定记录确认运行源码与各自正式服配置选择一致。不同完整包使用不同 `base_id`。

102 的历史独立基线为 `glory-ios-20261114-prod-signin-appstore-r2`，继续保留，固定目录：

`build/patch-baselines/glory-ios-20261114-prod-signin-appstore-r2/`

- `base.zip` SHA-256：`c6892d920846075fce9d788d954792d37e8cbf86671d09909bb9d28b168a5459`。
- 成品逐文件回读确认 **6,238 个基线文件与 IPA 相同**。
- 固定目录含 `base.zip`、`base.export.json`、`ipa-result.json`、`patch-config.json`、`slim-resources.json`、`baseline-lock.json` 和 `README.txt`。
- `source-snapshot/` 保留本次工程、导出预设、构建身份、精简过滤清单、`patcher/boot.json` 及相关运行脚本；`baseline-lock.json` 记录其哈希，已确认运行源码与所记录正式服选择一致。
- patch 配置使用 `channel=internal`、`backend_url=https://api.gogoglory.com`；后续 patch 使用该固定配置，通过 `tools/workspace/export_patch.py` 重新扫描和精简。

清理构建时须保留整个固定目录及对应 IPA；不可用可变的 `build/ios-auto-work/project` 替代。旧 100 基线继续保留，新包不能复用旧 `base_id`。本轮未发布 patch 或改动 nightly 线上基线。

103 的历史独立基线为 `glory-ios-20261114-prod-signin-adhoc-r1`，固定目录为外层 `build/patch-baselines/glory-ios-20261114-prod-signin-adhoc-r1/`。`base.zip` SHA-256 为 `4ee485e1b8b6e53a246963d607ab850b1a9f563a4cb593dc46e0641fc0bb71c0`，6,238 个基线文件与其 IPA 逐项一致；已保存同类元数据和源码快照。102 和 103 均作为修复前历史包保留，不作为最新交付。旧 100 基线继续保留，不改写或删除。

## 验证记录与交付边界

客户端最新 provider 检查 **52 项**及真实 loopback **HTTP/session 集成 61 项**通过；后端受影响检查 **96 项**是此前通过记录。此前原生生命周期检查 **37 项**、打包检查 **29 项**及 iPhoneOS arm64 原生编译通过，按各自范围保留，不重复相加。61 项不包含真实 WebSocket 握手。相关汇总见外层 `build/ios-signin-qa/RESULT.json`。

| 阶段 | 当前状态 |
| --- | --- |
| App Store 1.0.2 (106) 签名 IPA | 已完成并通过成品检查；6,238 文件独立基线已固定保留 |
| Ad Hoc 1.0.2 (105) 签名 IPA | 已完成并通过成品检查；6,238 文件基线已固定保留 |
| 101 / 102 / 103 | 101 为中间包；102、103 已被新修复版本取代，保留历史证据 |
| 105 真机覆盖安装 | 已完成；7 份文件安装前后逐字节一致 |
| 103 Apple 绑定与冷启动 | 用户本人已完成绑定；同一玩家、资料和游戏存档保持一致，冷启动恢复通过 |
| 105 显式 Apple provider 登录 | 用户本人确认系统登录后已通过；无误顶号，同一玩家，续期凭证已保存，资料及游戏存档字节不变 |
| 105 使用新凭据的最后一次冷启动 | 已通过；同一玩家、资料及存档字节不变，大厅数值与最终资料页的好友编号/Apple 绑定一致 |
| 106 真机安装与运行 | 未执行；105 的真机结果不等同 106 已安装验收 |
| Google 真实授权 / Google 绑定或切换 | 入口与配置保留；本轮未执行新绑定或重复真实登录 |
| 安卓绑定 Google 后在 iOS 恢复同一账号与进度 | 待验收 |
| Apple 注销后手动提示及服务端自动撤销 | 真实账号验收待完成；自动撤销另需专用密钥和后端部署 |
| TestFlight | 本轮新登录包未上传，未申请外部测试或正式提审 |
| 后端部署 | 本轮新增后端变化未部署，未重启服务器 |

SDK 隐私资源通过的是安装包完整性检查；本记录不据此宣称 App Store 隐私标签、隐私政策或真实账号数据处理已完成新一轮审核。
