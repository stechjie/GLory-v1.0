# GLory 测试下载入口

固定地址：`https://glorytd-api.duckdns.org/beta/`。二维码始终编码此地址，中间使用游戏水晶图标。

- iPhone/iPad：使用现有 TestFlight 公开测试邀请。仅当 `ios.ready` 为 true 时自动跳转；新版尚待处理或审核时显示等待说明，避免继续安装不兼容的旧客户端。
- Android：当前使用 `mode: apk`，官网 `/beta/downloads/` 直接提供已签名的精简 APK；不需要测试群组或 Google Play 报名。
- APK 配置仅接受本站 HTTPS、固定 downloads 目录、明确 APK 文件名，禁止查询参数和任意外部跳转。先上传并验证实际 APK，再更新 ready 配置。
- 保留 `play_closed` 模式，供明确切回 Google Play 封闭测试时使用；该模式仍提供群组与测试报名两步。
- Android 保留安装说明页面；内置浏览器提示使用系统浏览器。`?manual=1` 可查看所有平台入口。
- 0.0.25 (Android 38 / iOS 61) 使用协议 43。旧协议 41 的资源补丁不能完成网络层升级；必须安装整包。

## 校验和部署

```sh
node --test deploy/beta-site/*.test.mjs
python3 deploy/beta-site/install.py --domain glorytd-api.duckdns.org --check-only
```

尚未完成对应平台的公开下载验证时保持该平台 `ready: false`。仅在有意发布等待状态时使用 `--allow-pending`。

将本目录复制到服务器后运行：

```sh
sudo python3 /已上传目录/install.py --domain glorytd-api.duckdns.org
```

安装器备份 `/opt/glory/public/beta`、Caddy 配置，验证后热重载；失败则恢复。部署只涉及下载页面，不重启账号或战斗服务。上线验收应包含 HTTPS 页面、APK 大小与 SHA-256、下载响应、TestFlight 实际可用版本、二维码识别及 `/health`；只有切回 Play 模式时才检查群组与报名。

2026-10-20 因线上对局协议已升级至 43，构建 0.0.25 整包；APK 已上传 Drive，并经服务器完整 SHA-256 校验后开放官网下载。二维码继续指向固定官网地址；本次证据位于外层 `delivery/release-20261020-protocol43/`。iOS 外部测试需在 Apple 处理、测试组分配和审核完成后才设置 ready。

## 语言与反馈

页面依据浏览器首选语言（设备/系统语言）自动显示简体中文、繁体中文或英文。`zh-Hant` 与 TW/HK/MO 使用繁体，`zh-Hans` 优先使用简体；其余中文使用简体，非中文使用英文。所有状态、安装说明与按钮同步翻译。

反馈可提交给邀请主播，或点击官方 Discord 反馈群：https://discord.gg/vsVDcrwft 。

## 2026-10-21 音效版

Android 0.0.26 (39) 更新 29 条战场音效，仍使用协议 43。资源文件和导入配置已通过 Drive 原目录上传并逐文件回读校验；Git 中的 `docs/releases/2026-10-21-audio-assets.json` 记录每个资源的 ID 和哈希。

iOS 0.0.26 (62) 上传后分配既有内测组并提交既有外测组审核。`ios.version` 只表示已获批、公开链接实际可安装的版本；`ios.pending_version` 表示仍在等待审核的新版本，避免将内测可用误报为外测可用。外测获批后更新 `ios.version` 并移除 `pending_version`。
