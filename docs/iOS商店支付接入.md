# iOS App Store 钻石充值

2026-10-28：客户端已接 StoreKit 2，复用现有 Apple 服务端验签、订单、钱包和退款通知接口。

## 客户端与原生组件

- `BillingBridge.gd` 自动选择 `GloryAppleBilling`，Android 继续选择 `GloryBilling`。
- `GloryAppleBilling.swift` 从 App Store 读取 `Product.displayPrice`，购买仅接受消耗型商品。
- 下单后把服务器 `order_id` 作为 `appAccountToken`；服务端验证 Apple 签名里的同一个值和商品编号。
- `AccountManager` 提交原始 JWS 至 `/v1/iap/apple/confirm`。凭证只在内存和 HTTPS 请求中传递，不写日志或本地文件。
- 服务器对同一订单返回 `credited` 后才 `finish()`；经过验签的 `cancelled` / `refunded` 终态也清理队列，包括测试单达到每日限额。网络故障、5xx、429、拒绝或 pending 均不结束交易。
- 启动、回前台和 iOS 登录后每 15 秒从 `Transaction.unfinished` 重交原订单；`Transaction.updates` 同时监听后台批准的购买。补单不新建订单，不跨账号认领；服务器保留原来的订单归属、幂等和防重放检查。
- Ask to Buy 显示等待处理；用户取消显示已取消；付款中网络异常显示处理中。受系统限制的设备不展示可购买流程。Apple 页面使用本平台文案。

支付源码独立于语音逻辑，随已有 `GloryVoice.framework` 编译、装载并注册自己的单例；这是当前工程已在 iOS 使用的原生扩展宿主。无需新增第三方支付 SDK，也不修改 Android AAR。

## 编译与交付

```sh
# 在外层 GLory 目录执行；工作目录可复用本机已有的 godot-cpp 和 SPM 缓存。
build/ios-bgm-build-venv/bin/python GLory-v1.0/native/glory_voice_ios/build.py \
  --work-dir "$PWD/build/ios-voice-work"
./tools/build_ipa.sh --method app-store --version 1.0.2 \
  --result-file "$PWD/delivery/ios-iap-20261028/ipa-result.json"
```

iOS 最低版本保持 15.0。`build-manifest.json` 记录支付源码和原生二进制指纹；IPA 入口预检拒绝旧框架，成包验证再次检查 StoreKit 原生类和交易结束方法，另保留原来的签名、arm64、PCK 身份及语音依赖校验。若构建使用补丁更新器，必须按 `AGENTS.md` 提供新独立基线的 `--patch-config` 并保留精简 stage 的基线产物。

## App Store Connect / 账号服务器启用条件

代码接通不等于商店已允许付款。平台侧应在 `com.superforge.glory` 对应应用完成：

1. 有效的付费应用协议、税务和银行资料。
2. 创建消耗型商品 `diamond_pack_1`、`diamond_pack_2`、`diamond_pack_3`，填本地化、售价、销售地区和审核资料。4–6 档在服务器目录中仍关闭，沿用现有产品策略。客户端以 App Store 返回的本地价格为准，不把设计文档价格当成交价。
3. 在服务器安装公开的 [Apple Root CA - G3](https://www.apple.com/certificateauthority/AppleRootCA-G3.cer)，设置 `GLORY_APPLE_ROOT_CERT_FILE` 和 `GLORY_APPLE_BUNDLE_ID=com.superforge.glory`。
4. 配置 App Store Server Notifications V2：`https://glorytd-api.duckdns.org/iap/apple/notifications`，Sandbox 和 Production 分别核对。现有服务端处理验签退款通知。
5. 商品可被沙盒读取且服务器配置可用后，在受控测试中开启 `GLORY_IAP_APPLE_ENABLED=true`；开关只挡建单，不挡已付款交易补单。

不需要把 App Store Connect 私钥、Apple 账号密码或共享密钥放到客户端。现有服务端直接验证 Apple 签名 JWS，不使用旧版共享密码收据接口。

## 已完成的本地验证与待验收项

- iPhoneOS arm64 Release 原生框架编译成功。
- `tools/iap_check.tscn`：65 项通过，含 Google 原有行为及 Apple 路由、受限设备、待批准、错单、断网不结束交易、补交和服务器确认后结束交易。
- `python3 tools/test_ios_billing_tasks.py`：实际 Swift 支付源码对 SDK 替身通过；覆盖价格、类型、订单 UUID、并发、取消、待批准、未验证交易、网络不确定状态、前台交易更新、未完成交易和 finish。
- `backend/tests/test_iap.py`：139 项通过，覆盖现有 Apple 验签、错账号/商品、测试单、幂等和退款等服务端逻辑。

上述为编译和本地自动验证，不代表 Apple 沙盒真实扣款或真机到账。仍需使用包含此组件的新 IPA 验收：成功充值与余额/首充刷新、取消、待批准、付款后断网/杀进程再启动、重复补单只入账一次、切换游戏账号不能领走他人订单、退款/负余额，以及至少一次 iPhone 和 iPad 商店 UI 检查。TestFlight 上传、处理、测试组分配和平台审核另行核实。

依据：[Apple Transaction](https://developer.apple.com/documentation/storekit/transaction)、[未完成交易](https://developer.apple.com/documentation/storekit/transaction/unfinished)、[签名交易](https://developer.apple.com/documentation/storekit/verificationresult/jwsrepresentation-21vgo)。
