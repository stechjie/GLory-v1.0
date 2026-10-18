# GLory 测试下载入口

固定地址：`https://glorytd-api.duckdns.org/beta/`。二维码始终编码此地址，中间使用游戏水晶图标。

- iPhone/iPad：保留现有 TestFlight 公开测试邀请；普通浏览器自动跳转，`?manual=1` 可查看完整页面。
- Android：使用 Google Play 内部测试邀请，当前为 `https://play.google.com/apps/internaltest/4701302260400909295`。配置模式固定为 `play_internal`，不再使用 Drive 共享 APK 下载入口。
- 测试者使用名单中的同一 Google 账号，依次接受邀请、点击 Download test app，并在 Google Play 安装。未被邀请的账号需先由管理员加入内部测试名单。
- Android 保留引导页供用户阅读步骤；微信、抖音等内置浏览器提示使用系统浏览器。
- 配置只接受 HTTPS 的 TestFlight 邀请和 Google Play 内部测试邀请地址，拒绝 Drive、任意外部地址和带查询参数的跳转。

## 校验和部署

```sh
node --test deploy/beta-site/*.test.mjs
python3 deploy/beta-site/install.py --domain glorytd-api.duckdns.org --check-only
```

尚未完成公开下载验证时保持 `android.ready: false`。仅在有意发布等待状态时使用 `--allow-pending`。

将本目录复制到服务器后运行：

```sh
sudo python3 /已上传目录/install.py --domain glorytd-api.duckdns.org
```

安装器备份 `/opt/glory/public/beta`、Caddy 配置，验证后热重载；失败则恢复。部署只涉及下载页面，不重启账号或战斗服务。上线验收应包含 HTTPS 页面、Google Play 内部测试邀请与受邀账号访问、TestFlight 入口、二维码识别及 `/health`。

2026-10-18 切换为 Google Play 内部测试，版本 0.0.24 (37)。二维码继续指向固定官网地址；发布和公网回读证据位于外层 `delivery/google-play-site-20261018/`。以后更新 Android 版本时沿用 Play 测试邀请，不回填 Drive 共享地址。

## 语言与反馈

页面依据浏览器首选语言（设备/系统语言）自动显示简体中文、繁体中文或英文。`zh-Hant` 与 TW/HK/MO 使用繁体，`zh-Hans` 优先使用简体；其余中文使用简体，非中文使用英文。所有状态、安装说明与按钮同步翻译。

反馈可提交给邀请主播，或点击官方 Discord 反馈群：https://discord.gg/vsVDcrwft 。
